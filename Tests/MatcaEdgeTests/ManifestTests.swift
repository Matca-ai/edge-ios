import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 1: the fixture verifies, the tampered copy and a wrong key do not, and the certificate rules.
final class ManifestTests: XCTestCase {
    private let fixture = Fixtures.json("manifest.json")
    private var fixtureKey: String { fixture["public_key"] as! String }
    private var fixtureManifest: SignedManifest {
        SignedManifest(manifest: fixture["manifest"] as! String, signature: fixture["signature"] as! String)
    }

    func testTheFixtureManifestVerifiesUnderItsKeyAndReadsAsSigned() throws {
        let manifest = try ManifestVerification.verify(fixtureManifest, rootPublicKey: fixtureKey)
        XCTAssertEqual(manifest.model, "cap-detection")
        XCTAssertEqual(manifest.sequence, 7)
        XCTAssertEqual(manifest.iosFiles.map(\.path), ["Model.mlpackage/Manifest.json"])
        XCTAssertEqual(manifest.reference.first?.minimumConfidence, 0.5)
        XCTAssertNil(manifest.preprocessing.cropFactor)
    }

    func testTheTamperedCopyIsRefused() {
        let tampered = SignedManifest(manifest: fixture["tampered"] as! String, signature: fixtureManifest.signature)
        XCTAssertThrowsError(try ManifestVerification.verify(tampered, rootPublicKey: fixtureKey)) { error in
            XCTAssertEqual(error as? EdgeError, .invalidSignature)
        }
    }

    func testAnotherRootKeyWithoutACertificateIsRefused() {
        XCTAssertThrowsError(try ManifestVerification.verify(fixtureManifest, rootPublicKey: TestSigner().publicKeyBase64)) { error in
            XCTAssertEqual(error as? EdgeError, .untrustedSigningKey)
        }
    }

    func testASignatureByAnotherKeyIsRefused() {
        let other = TestSigner()
        let forged = SignedManifest(manifest: fixtureManifest.manifest, signature: other.sign(fixtureManifest.manifest))
        XCTAssertThrowsError(try ManifestVerification.verify(forged, rootPublicKey: fixtureKey)) { error in
            XCTAssertEqual(error as? EdgeError, .invalidSignature)
        }
    }

    func testAKeyEqualToTheRootIsTrustedWithoutACertificate() throws {
        let root = TestSigner()
        XCTAssertNoThrow(try ManifestVerification.verify(TestManifest().signed(by: root), rootPublicKey: root.publicKeyBase64))
    }

    func testACertifiedEnvironmentKeyIsTrustedUntilItExpires() throws {
        let root = TestSigner(), environment = TestSigner()
        let valid = certified(environment, by: root, expires: "2027-01-01T00:00:00+00:00")
        XCTAssertNoThrow(try ManifestVerification.verify(valid, rootPublicKey: root.publicKeyBase64))

        let expired = certified(environment, by: root, expires: "2020-01-01T00:00:00+00:00")
        XCTAssertThrowsError(try ManifestVerification.verify(expired, rootPublicKey: root.publicKeyBase64)) { error in
            XCTAssertEqual(error as? EdgeError, .untrustedSigningKey)
        }
    }

    func testACertificateSignedByAnotherKeyIsRefused() {
        let root = TestSigner(), environment = TestSigner(), impostor = TestSigner()
        let wrongly = certified(environment, by: impostor, expires: "2027-01-01T00:00:00+00:00")
        XCTAssertThrowsError(try ManifestVerification.verify(wrongly, rootPublicKey: root.publicKeyBase64)) { error in
            XCTAssertEqual(error as? EdgeError, .untrustedSigningKey)
        }
    }

    func testNothingButTheSigningBlockIsReadBeforeTheSignatureVerifies() {
        let root = TestSigner()
        let text = "{\"signing\":{\"certificate\":null,\"key\":\"\(root.publicKeyBase64)\"}}"
        let forged = SignedManifest(manifest: text, signature: TestSigner().sign(text))
        XCTAssertThrowsError(try ManifestVerification.verify(forged, rootPublicKey: root.publicKeyBase64)) { error in
            XCTAssertEqual(error as? EdgeError, .invalidSignature)
        }
    }

    func testAFieldTheLibraryDoesNotReadMayComeOrGo() throws {
        let without = fixtureManifest.manifest
            .replacingOccurrences(of: "\"title\":\"Cap detection\"", with: "\"added\":{\"x\":1}")
            .replacingOccurrences(of: "\"channel\":\"test\",", with: "")
            .replacingOccurrences(of: "\"issued_at\":\"2026-11-01T15:00:00+00:00\",", with: "")
        XCTAssertFalse(without.contains("issued_at"))
        XCTAssertEqual(try Manifest.parse(Data(without.utf8)).sequence, 7)
    }

    func testADeepDocumentIsARefusalNotACrash() {
        let deep = String(repeating: "{\"a\":", count: 100_000) + "1" + String(repeating: "}", count: 100_000)
        XCTAssertThrowsError(try ManifestVerification.verify(SignedManifest(manifest: deep, signature: "c2ln"), rootPublicKey: fixtureKey)) { error in
            XCTAssertNotNil(error as? EdgeError)
        }
    }

    func testTheCertificateTextIsTheControlPlanesCanonicalForm() {
        XCTAssertEqual(ManifestVerification.certificateText(key: "K", expires: "E"), #"{"expires":"E","key":"K"}"#)
    }

    private func certified(_ environment: TestSigner, by root: TestSigner, expires: String) -> SignedManifest {
        var manifest = TestManifest()
        let text = ManifestVerification.certificateText(key: environment.publicKeyBase64, expires: expires)
        manifest.certificate = ["expires": expires, "signature": root.sign(text)]
        return manifest.signed(by: environment)
    }
}
