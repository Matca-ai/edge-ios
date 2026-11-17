import Foundation
@testable import MatcaEdge
import XCTest

/// A classifier over the fake edge and the fake model, and the manifests a test offers it.
class ClassifierTestCase: XCTestCase {
    let root = TestSigner()
    let model = "cap-detection"
    let loader = FakeModelLoader()
    let crashReports = FakeCrashReports()
    /// Noon UTC on the fixture report's day.
    let clock = TestClock(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!)
    var storeDirectory = temporaryDirectory()
    let referencePicture = Fixtures.data("cap-upright.jpg")

    override func setUp() {
        super.setUp()
        FakeEdge.reset()
        storeDirectory = temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeDirectory)
        super.tearDown()
    }

    func writeBundle(_ bundled: TestManifest, to bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Model.mlpackage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("reference"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: bundle.appendingPathComponent("Model.mlpackage/Manifest.json"))
        try referencePicture.write(to: bundle.appendingPathComponent("reference/\(sha256Hex(referencePicture))"))
        try JSONEncoder().encode(bundled.signed(by: root)).write(to: bundle.appendingPathComponent("manifest.json"))
    }

    func configuration(
        expectedLabels: [String] = [], bundledRelease: URL? = nil, wifiOnly: Bool = false, checkInterval: TimeInterval = 6 * 60 * 60,
        monitoring: Bool = true
    ) -> EdgeConfiguration {
        EdgeConfiguration(
            baseURL: URL(string: "https://edge.test")!, deliveryKey: "mdk_1_secret", rootPublicKey: root.publicKeyBase64,
            expectedLabels: expectedLabels, bundledRelease: bundledRelease, wifiOnly: wifiOnly, checkInterval: checkInterval,
            monitoring: monitoring
        )
    }

    func makeClassifier(
        model: String? = nil, expectedLabels: [String] = [], bundledRelease: URL? = nil, wifiOnly: Bool = false, checkInterval: TimeInterval = 6 * 60 * 60,
        monitoring: Bool = true, storeDirectory: URL? = nil, retryDelays: [TimeInterval] = asksWithoutModel
    ) throws -> Classifier {
        let configuration = configuration(
            expectedLabels: expectedLabels, bundledRelease: bundledRelease, wifiOnly: wifiOnly, checkInterval: checkInterval, monitoring: monitoring
        )
        return try Classifier(
            model: model ?? self.model, configuration: configuration, session: FakeEdge.session(), loader: loader,
            storeDirectory: storeDirectory ?? self.storeDirectory, crashReports: crashReports, clock: clock.monitoringClock,
            retryDelays: retryDelays
        )
    }

    func manifest(release: Int, sequence: Int) -> TestManifest {
        var manifest = TestManifest()
        manifest.release = release
        manifest.sequence = sequence
        manifest.reference = [[
            "path": sha256Hex(referencePicture), "sha256": sha256Hex(referencePicture), "size": referencePicture.count,
            "expected": "With Cap", "minimum_confidence": 0.5,
        ]]
        return manifest
    }

    func serve(_ manifest: TestManifest) {
        let signed = manifest.signed(by: root)
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", body: try! JSONEncoder().encode(signed))
        let releasePath = "/v1/models/\(model)/releases/\(manifest.release)"
        FakeEdge.route("GET", "\(releasePath)/files/ios/Model.mlpackage/Manifest.json", body: Data("hello".utf8))
        FakeEdge.route("GET", "\(releasePath)/files/reference/\(sha256Hex(referencePicture))", body: referencePicture)
        FakeEdge.route("POST", "\(releasePath)/installs", status: 204)
        FakeEdge.route("POST", "\(releasePath)/failed-checks", status: 204)
    }

    func state() -> StoredState {
        try! JSONDecoder().decode(StoredState.self, from: Data(contentsOf: storeDirectory.appendingPathComponent("state.json")))
    }

    func assertThrows<Value>(_ expression: @autoclosure () async throws -> Value, _ expected: EdgeError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EdgeError, expected, file: file, line: line)
        }
    }
    /// A restart whose release fails to reload, its first automatic check over before the test goes on.
    func restartedWithAReleaseThatDoesNotLoad(_ release: Int) async throws -> Classifier {
        loader.failingReleases = [release]
        let asksBefore = manifestAsks()
        let restarted = try makeClassifier()
        await assertThrows(try await restarted.classify(referencePicture), .noModel)
        while manifestAsks() == asksBefore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await restarted.checkForUpdates()
        return restarted
    }

    func manifestAsks() -> Int {
        FakeEdge.requestedPaths(method: "GET").filter { $0.hasSuffix("/manifest") }.count
    }

    /// A classifier whose first automatic check is over, so the test's own checks are never joined to it.
    func settledClassifier(monitoring: Bool = true, storeDirectory: URL? = nil) async throws -> Classifier {
        let asksBefore = manifestAsks()
        let classifier = try makeClassifier(monitoring: monitoring, storeDirectory: storeDirectory)
        try await waitUntil { self.manifestAsks() > asksBefore }
        try? await classifier.checkForUpdates()
        return classifier
    }

    /// What the store's directory holds, once every write asked before has landed.
    func keptCounts() -> MonitoringCounts {
        MonitoringFile(directory: storeDirectory).loadCounts()
    }

    /// The classifier's counts as a check writes them first.
    func counts(keptBy classifier: Classifier) async -> MonitoringCounts {
        try? await classifier.checkForUpdates()
        return keptCounts()
    }

    /// Days a phone kept from before, each with one answer.
    func seed(_ days: [ReleaseDay]) throws {
        var counts = MonitoringCounts()
        for day in days {
            counts.days[day, default: DayCounts()].countAnswer(
                label: "With Cap", confidence: 0.99, preprocessingMilliseconds: 12, modelMilliseconds: 40
            )
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        MonitoringFile(directory: storeDirectory).writeCounts(counts)
    }

    func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("the condition never held", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
