import Foundation
@testable import MatcaEdge
import XCTest

/// The tests on a real file (the contract's section 8): Core ML itself opens the tiny model and must give
/// the answers the trainer's exports agreed on.
final class RealModelTests: XCTestCase {
    private struct Expected: Decodable {
        struct Picture: Decodable {
            let label: String
            let confidence: Double
        }

        let tolerance: Double
        let answers: [String: Picture]
    }

    private let expected = try! JSONDecoder().decode(Expected.self, from: Data(contentsOf: tinyModel.appendingPathComponent("expected.json")))
    private let root = TestSigner()
    private var workDirectory = temporaryDirectory()

    private static let tinyModel = Fixtures.url("tiny-model")

    override func setUp() {
        super.setUp()
        FakeEdge.reset()
        workDirectory = temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    func testTheRunnerGivesEachPictureTheTrainersLabelAndConfidence() throws {
        let releaseDirectory = workDirectory.appendingPathComponent("release")
        var release = tinyRelease()
        release.iosFiles = try copyModelFiles(to: releaseDirectory)
        let manifest = try Manifest.parse(Data(release.text(signingKey: root.publicKeyBase64).utf8))
        let runner = try CoreMLModelLoader().load(releaseDirectory: releaseDirectory, manifest: manifest)

        for (name, picture) in expected.answers {
            let decoded = try PictureDecoding.decode(encoded: Fixtures.data(name)).picture
            let scores = try runner.predict(decoded)
            let answer = try Answer(scores: scores, release: manifest.release)
            XCTAssertEqual(answer.label, picture.label, name)
            XCTAssertEqual(answer.confidence, picture.confidence, accuracy: expected.tolerance, name)
            XCTAssertEqual(answer.all.map(\.label).sorted(), ["bright", "dark"], name)
        }
    }

    func testAWholeReleaseFromDiskIsCheckedTakenAnsweredAndReloaded() async throws {
        let bundle = workDirectory.appendingPathComponent("bundle")
        try writeBundledRelease(to: bundle)

        let classifier = try makeClassifier(bundledRelease: bundle)
        for (name, picture) in expected.answers {
            let answer = try await classifier.classify(Fixtures.data(name))
            XCTAssertEqual(answer.label, picture.label, name)
            XCTAssertEqual(answer.confidence, picture.confidence, accuracy: expected.tolerance, name)
            XCTAssertEqual(answer.release, 1, name)
        }

        let afterRestart = try makeClassifier(bundledRelease: nil)
        let reloaded = try await afterRestart.classify(Fixtures.data("cap-upright.default.png"))
        XCTAssertEqual(reloaded.label, "bright")
        XCTAssertEqual(reloaded.release, 1)
    }

    private func tinyRelease() -> TestManifest {
        var release = TestManifest()
        release.classes = ["bright", "dark"]
        return release
    }

    private func writeBundledRelease(to bundle: URL) throws {
        let picture = Fixtures.data("cap-upright.default.png")
        var release = tinyRelease()
        release.iosFiles = try copyModelFiles(to: bundle)
        release.reference = [[
            "path": sha256Hex(picture), "sha256": sha256Hex(picture), "size": picture.count,
            "expected": "bright", "minimum_confidence": 0.5,
        ]]
        try write(picture, to: bundle.appendingPathComponent("reference/\(sha256Hex(picture))"))
        try write(JSONEncoder().encode(release.signed(by: root)), to: bundle.appendingPathComponent("manifest.json"))
    }

    /// What a phone receives: the listed files only.
    private func copyModelFiles(to directory: URL) throws -> [[String: Any]] {
        let package = Self.tinyModel.appendingPathComponent("ios/Model.mlpackage")
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: package.path).filter { subpath in
            try package.appendingPathComponent(subpath).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        return try subpaths.map { subpath in
            let data = try Data(contentsOf: package.appendingPathComponent(subpath))
            let path = "Model.mlpackage/\(subpath)"
            try write(data, to: directory.appendingPathComponent(path))
            return ["path": path, "size": data.count, "sha256": sha256Hex(data)]
        }
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func makeClassifier(bundledRelease: URL?) throws -> Classifier {
        let configuration = EdgeConfiguration(
            baseURL: URL(string: "https://edge.test")!, deliveryKey: "mdk_1_secret", rootPublicKey: root.publicKeyBase64,
            expectedLabels: ["bright", "dark"], bundledRelease: bundledRelease
        )
        return try Classifier(
            model: "cap-detection", configuration: configuration, session: FakeEdge.session(),
            loader: CoreMLModelLoader(), storeDirectory: workDirectory.appendingPathComponent("store"),
            crashReports: FakeCrashReports(), clock: MonitoringClock()
        )
    }
}
