import Foundation
import UIKit

/// What the edge's install page opens: matcaedge://pair?edge=https://…&code=…&platform=ios.
struct PairingLink: Equatable {
    let edgeURL: URL
    let code: String

    init?(_ url: URL) {
        guard url.scheme == "matcaedge", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let edge = items.first(where: { $0.name == "edge" })?.value.flatMap(URL.init(string:)),
              edge.scheme == "https", edge.host != nil,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: "^[A-Za-z0-9_-]{20,64}$", options: .regularExpression) != nil
        else { return nil }
        edgeURL = edge
        self.code = code
    }
}

/// What the pairing gives the app: the four fields it would otherwise ask a person to type.
struct Paired: Decodable {
    let key: String
    let model: String
    let rootPublicKey: String

    enum CodingKeys: String, CodingKey {
        case key, model
        case rootPublicKey = "root_public_key"
    }
}

/// A picture of a try this phone has not answered yet.
struct OpenPicture: Equatable {
    let tryID: Int
    let position: Int
}

/// The test phone's side of trying pictures (docs/on-device-models-plan.md, section 5): the pairing, the tries it
/// answers and the answers it sends. Plain HTTPS to the edge with the paired key; only answers and timings leave the
/// phone, never a picture.
struct TestPhone {
    struct Refused: LocalizedError {
        let status: Int

        var errorDescription: String? {
            switch status {
            case 401: return "The edge does not know this phone's key: pair it again."
            case 404: return "The edge does not have that any more: a pairing code lasts an hour and pairs once."
            case 429: return "The edge asks to wait a moment."
            default: return "The edge answered \(status)."
            }
        }
    }

    private struct TryRead: Decodable {
        struct Picture: Decodable {
            let position: Int
            let answered: Bool
        }

        let id: Int
        let pictures: [Picture]
    }

    let edgeURL: URL
    let key: String
    let model: String

    /// The code spent once for this phone's key on the test channel.
    @MainActor
    static func pair(_ link: PairingLink) async throws -> Paired {
        let device = UIDevice.current
        let phone: [String: String] = [
            "platform": "ios",
            "device": deviceWords("\(device.model) \(machineName())"),
            "system": deviceWords("\(device.systemName) \(device.systemVersion)"),
            "app_version": deviceWords(appVersion()),
        ]
        let body = try JSONSerialization.data(withJSONObject: phone)
        let data = try await send(link.edgeURL.appendingPathComponent("v1/pairings/\(link.code)"), key: nil, method: "POST", body: body)
        return try JSONDecoder().decode(Paired.self, from: data)
    }

    func openPictures() async throws -> [OpenPicture] {
        let data = try await Self.send(edgeURL.appendingPathComponent("v1/models/\(model)/tries"), key: key, method: "GET", body: nil)
        return try JSONDecoder().decode([TryRead].self, from: data).flatMap { attempt in
            attempt.pictures.filter { !$0.answered }.map { OpenPicture(tryID: attempt.id, position: $0.position) }
        }
    }

    func picture(_ open: OpenPicture) async throws -> Data {
        try await Self.send(edgeURL.appendingPathComponent("v1/models/\(model)/tries/\(open.tryID)/pictures/\(open.position)"), key: key, method: "GET", body: nil)
    }

    /// One answer: a try's picture, or one taken here under its name; the scores by label, the time it took.
    func sendAnswer(to open: OpenPicture?, picture: String, release: Int, scores: [String: Double], milliseconds: Double) async throws {
        var answer: [String: Any] = [
            "picture": String(picture.prefix(80)),
            "release": release,
            "scores": scores,
            "milliseconds": min(max(milliseconds, 0), 60_000),
        ]
        if let open {
            answer["try_id"] = open.tryID
            answer["position"] = open.position
        }
        let body = try JSONSerialization.data(withJSONObject: answer)
        _ = try await Self.send(edgeURL.appendingPathComponent("v1/models/\(model)/answers"), key: key, method: "POST", body: body)
    }

    private static func send(_ url: URL, key: String?, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Refused(status: status) }
        return data
    }

    /// What the control plane takes for a phone's name, system and app version.
    static func deviceWords(_ text: String) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,()_+-").contains(scalar) ? Character(scalar) : " "
        }
        let words = String(kept).trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "iPhone" : String(words.prefix(60))
    }

    /// The hardware's own name, iPhone15,2 and the like: the marketing name is not on the phone.
    private static func machineName() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
