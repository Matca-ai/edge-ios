import Foundation
import MatcaEdge

struct EdgeFields: Equatable {
    private struct IncompleteFields: LocalizedError {
        var errorDescription: String? {
            "Fill in an https edge URL, the delivery key, the root public key and the model name."
        }
    }

    let edgeURL: String
    let deliveryKey: String
    let rootPublicKey: String
    let modelName: String

    /// A paste often brings a trailing newline, which would break the key's header and the root key's base64.
    init(edgeURL: String, deliveryKey: String, rootPublicKey: String, modelName: String) {
        self.edgeURL = edgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deliveryKey = deliveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPublicKey = rootPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paired phone's calls for what the fields say; the edge refuses them for an app's own key.
    func testPhone() -> TestPhone? {
        guard let baseURL = URL(string: edgeURL), baseURL.scheme == "https", !deliveryKey.isEmpty, !modelName.isEmpty
        else { return nil }
        return TestPhone(edgeURL: baseURL, key: deliveryKey, model: modelName)
    }

    func makeClassifier() throws -> Classifier {
        guard let baseURL = URL(string: edgeURL), baseURL.scheme == "https", baseURL.host != nil,
              !deliveryKey.isEmpty, !rootPublicKey.isEmpty, !modelName.isEmpty
        else { throw IncompleteFields() }
        let configuration = EdgeConfiguration(baseURL: baseURL, deliveryKey: deliveryKey, rootPublicKey: rootPublicKey)
        return try Classifier(model: modelName, configuration: configuration)
    }
}

/// What the screen shows, and the one classifier behind it: two over the same store would race for its files.
@MainActor
final class EdgeTester: ObservableObject {
    @Published private(set) var release: Int?
    @Published private(set) var answer: Answer?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    private var classifier: Classifier?
    private var classifierFields: EdgeFields?

    func checkForUpdates(with fields: EdgeFields) async {
        await run(with: fields) { classifier in
            try await classifier.checkForUpdates()
        }
    }

    @Published private(set) var triesAnswered: Int?

    /// A picture taken or chosen here, answered on this phone; a paired phone sends the answer, never the picture.
    func classify(_ picture: Data, named name: String, with fields: EdgeFields) async {
        answer = nil
        await run(with: fields) { classifier in
            let (answered, milliseconds) = try await timed { try await classifier.classify(picture) }
            answer = answered
            try await fields.testPhone()?.sendAnswer(to: nil, picture: name, release: answered.release, scores: scores(of: answered), milliseconds: milliseconds)
        }
    }

    /// The pairing link's code spent for the four fields, which the screen then keeps.
    func pair(_ link: PairingLink) async -> Paired? {
        isBusy = true
        defer { isBusy = false }
        do {
            let paired = try await TestPhone.pair(link)
            lastError = nil
            return paired
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Every try picture this phone has not answered: fetched, answered on this phone's chip, the answer sent.
    func answerTries(with fields: EdgeFields) async {
        await run(with: fields) { classifier in
            guard let phone = fields.testPhone() else { return }
            try await classifier.checkForUpdates()
            let open = try await phone.openPictures()
            for picture in open {
                let data = try await phone.picture(picture)
                let (answered, milliseconds) = try await timed { try await classifier.classify(data) }
                try await phone.sendAnswer(to: picture, picture: "", release: answered.release, scores: scores(of: answered), milliseconds: milliseconds)
            }
            triesAnswered = open.count
        }
    }

    private func scores(of answer: Answer) -> [String: Double] {
        Dictionary(answer.all.map { ($0.label, $0.confidence) }, uniquingKeysWith: { first, _ in first })
    }

    private func timed<Result>(_ work: () async throws -> Result) async rethrows -> (Result, Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await work()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func run(with fields: EdgeFields, _ action: (Classifier) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await action(try classifier(for: fields))
            lastError = nil
        } catch {
            lastError = (error as? EdgeError).map { String(describing: $0) } ?? error.localizedDescription
        }
        release = await classifier?.currentRelease
    }

    private func classifier(for fields: EdgeFields) throws -> Classifier {
        if let classifier, classifierFields == fields { return classifier }
        classifier = nil
        let fresh = try fields.makeClassifier()
        classifier = fresh
        classifierFields = fields
        return fresh
    }
}
