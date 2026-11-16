import CryptoKit
import Foundation

/// The edge's answer, and the shape of a bundled release's `manifest.json`: the text exactly as it was signed.
struct SignedManifest: Codable, Sendable {
    let manifest: String
    let signature: String
}

/// A release as the control plane describes it, read only after its signature verified. Other fields are ignored.
struct Manifest: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let width: Int
        let height: Int
    }

    struct File: Decodable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    struct Reference: Decodable, Sendable {
        let path: String
        let sha256: String
        let size: Int
        let expected: String
        let minimumConfidence: Double
    }

    let format: Int
    let model: String
    let release: Int
    let sequence: Int
    let rolloutShare: Int
    let classes: [String]
    let input: Input
    let preprocessing: PreprocessingSettings
    let requires: [String]
    let files: [String: [File]]
    let reference: [Reference]

    var iosFiles: [File] { files["ios"] ?? [] }

    static func parse(_ text: Data) throws -> Manifest {
        do {
            return try snakeCaseDecoder().decode(Manifest.self, from: text)
        } catch {
            throw EdgeError.unreadableManifest(String(describing: error))
        }
    }
}

func snakeCaseDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

/// Steps 2 and 3 of the contract's section 4: the signature over the signed bytes, then the signer's right
/// to sign, then the manifest as data.
enum ManifestVerification {
    private struct Certificate: Decodable {
        let expires: String
        let signature: String
    }

    private struct Signing: Decodable {
        let key: String
        let certificate: Certificate?
    }

    private struct SigningBlock: Decodable {
        let signing: Signing
    }

    static func verify(_ signed: SignedManifest, rootPublicKey: String, now: Date = Date()) throws -> Manifest {
        let text = Data(signed.manifest.utf8)
        // Only the signer's name is read before the signature is checked: the text itself is never rebuilt.
        guard let block = try? snakeCaseDecoder().decode(SigningBlock.self, from: text) else {
            throw EdgeError.unreadableManifest("no signing block")
        }
        let signingKey = try publicKey(base64: block.signing.key, named: "signing key")
        guard isValid(signatureBase64: signed.signature, over: text, key: signingKey) else {
            throw EdgeError.invalidSignature
        }
        try trust(block.signing, signingKey: signingKey, rootPublicKey: rootPublicKey, now: now)
        return try Manifest.parse(text)
    }

    private static func trust(
        _ signing: Signing, signingKey: P256.Signing.PublicKey, rootPublicKey: String, now: Date
    ) throws {
        let root = try publicKey(base64: rootPublicKey, named: "root key")
        if root.derRepresentation == signingKey.derRepresentation { return }
        guard let certificate = signing.certificate,
              let expires = ISO8601DateFormatter().date(from: certificate.expires), expires > now,
              isValid(
                  signatureBase64: certificate.signature,
                  over: Data(certificateText(key: signing.key, expires: certificate.expires).utf8),
                  key: root
              )
        else { throw EdgeError.untrustedSigningKey }
    }

    /// The control plane's `certificate_text`: keys sorted, no spaces, the values as the manifest carries them.
    static func certificateText(key: String, expires: String) -> String {
        "{\"expires\":\"\(expires)\",\"key\":\"\(key)\"}"
    }

    private static func publicKey(base64: String, named name: String) throws -> P256.Signing.PublicKey {
        guard let der = Data(base64Encoded: base64), let key = try? P256.Signing.PublicKey(derRepresentation: der)
        else { throw EdgeError.unreadableManifest("the \(name) is not a P-256 public key") }
        return key
    }

    private static func isValid(signatureBase64: String, over text: Data, key: P256.Signing.PublicKey) -> Bool {
        guard let der = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der)
        else { return false }
        return key.isValidSignature(signature, for: text)
    }
}
