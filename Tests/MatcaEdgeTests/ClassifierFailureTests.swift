import Foundation
@testable import MatcaEdge
import OSLog
import XCTest

/// What must hold when things go wrong: the current model stays, the reason reaches the app, nothing is left behind.
final class ClassifierFailureTests: ClassifierTestCase {
    func testAModelThatThrowsOrAnswersNotANumberFailsTheReferenceCheckAndIsCounted() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        loader.throwingOnPredict = [2]
        serve(manifest(release: 2, sequence: 2))
        await assertThrows(try await classifier.checkForUpdates(), .referenceCheckFailed(path: sha256Hex(referencePicture)))
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST").last, "/v1/models/cap-detection/releases/2/failed-checks")

        loader.throwingOnPredict = []
        loader.scoresByRelease[3] = ["With Cap": 0.9, "Without Cap": .nan]
        serve(manifest(release: 3, sequence: 3))
        await assertThrows(try await classifier.checkForUpdates(), .referenceCheckFailed(path: sha256Hex(referencePicture)))
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST").last, "/v1/models/cap-detection/releases/3/failed-checks")
        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
    }

    func testAReferencePictureThatIsNotTheListedOneStopsTheRelease() async throws {
        var wrong = manifest(release: 1, sequence: 1)
        wrong.reference = [[
            "path": sha256Hex(referencePicture), "sha256": sha256Hex("other"), "size": referencePicture.count,
            "expected": "With Cap", "minimum_confidence": 0.5,
        ]]
        serve(wrong)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .fileMismatch(path: sha256Hex(referencePicture)))
        XCTAssertFalse(FakeEdge.requestedPaths(method: "POST").contains { $0.hasSuffix("failed-checks") })
    }

    func testASwitchThatCannotBeWrittenLeavesThePreviousReleaseAndNothingOfTheNewOne() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        serve(manifest(release: 2, sequence: 2))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDirectory.path) }
        await assertThrows(try await classifier.checkForUpdates(), .storage("cannot write the state file"))

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(state().currentRelease, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/2").path))
        XCTAssertFalse(FakeEdge.requestedPaths(method: "POST").contains { $0.contains("releases/2") })
    }

    func testAReleaseThatNoLongerLoadsComesBackFromTheEdge() async throws {
        serve(manifest(release: 1, sequence: 1))
        let first = try makeClassifier()
        try await first.checkForUpdates()

        let restarted = try await restartedWithAReleaseThatDoesNotLoad(1)
        loader.failingReleases = []
        try await restarted.checkForUpdates()
        let answer = try await restarted.classify(referencePicture)
        XCTAssertEqual(answer.release, 1)
    }

    func testTheSameReleaseUnderANewSequenceAlsoComesBack() async throws {
        serve(manifest(release: 1, sequence: 1))
        let first = try makeClassifier()
        try await first.checkForUpdates()

        let restarted = try await restartedWithAReleaseThatDoesNotLoad(1)
        loader.failingReleases = []
        serve(manifest(release: 1, sequence: 2))
        try await restarted.checkForUpdates()
        let release = await restarted.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(state().lastSequence, 2)
    }

    func testAClassificationAnswersWhileANewReleaseLoads() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        let loading = expectation(description: "the new release is loading")
        let finishLoading = DispatchSemaphore(value: 0)
        loader.whileLoading = {
            loading.fulfill()
            finishLoading.wait()
        }
        serve(manifest(release: 2, sequence: 2))
        let update = Task { try await classifier.checkForUpdates() }
        await fulfillment(of: [loading], timeout: 5)
        let answered = expectation(description: "the current release answered")
        Task {
            _ = try await classifier.classify(referencePicture)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        finishLoading.signal()
        try await update.value
    }

    func testAnUnreadableStateIsSetAsideAndRebuiltFromTheKeptManifest() async throws {
        serve(manifest(release: 5, sequence: 5))
        let first = try makeClassifier()
        try await first.checkForUpdates()

        let stateURL = storeDirectory.appendingPathComponent("state.json")
        try Data("not a state".utf8).write(to: stateURL)
        serve(manifest(release: 3, sequence: 3))
        let restarted = try makeClassifier()
        try await restarted.checkForUpdates()

        let release = await restarted.currentRelease
        XCTAssertEqual(release, 5)
        XCTAssertEqual(state().lastSequence, 5)
        XCTAssertEqual(try Data(contentsOf: storeDirectory.appendingPathComponent("state.json.unreadable")), Data("not a state".utf8))
    }

    func testTheFilesComeFromTheSignedReleaseWhateverTheEdgeSaysBesideIt() async throws {
        let signed = manifest(release: 3, sequence: 1).signed(by: root)
        var answer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as! [String: Any]
        answer["release"] = 99
        serve(manifest(release: 3, sequence: 1))
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", body: try JSONSerialization.data(withJSONObject: answer))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()
        let release = await classifier.currentRelease
        XCTAssertEqual(release, 3)
    }

    func testAManifestThisLibraryCannotUseIsRefused() async throws {
        var otherFormat = manifest(release: 1, sequence: 1)
        otherFormat.format = 2
        serve(otherFormat)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .unreadableManifest("format 2"))
        var otherModel = manifest(release: 1, sequence: 1)
        otherModel.model = "other-model"
        serve(otherModel)
        await assertThrows(try await classifier.checkForUpdates(), .wrongModel)
        XCTAssertEqual(state().lastSequence, 0)
    }

    func testAPathThatCouldLeaveTheStoreIsRefusedAndNothingIsWritten() async throws {
        for path in ["../state.json", "a/../../state.json", "/etc/passwd"] {
            var escaping = manifest(release: 1, sequence: 1)
            escaping.iosFiles = [["path": path, "size": 5, "sha256": sha256Hex("hello")]]
            let store = try ModelStore(directory: storeDirectory)
            let installer = ReleaseInstaller(model: model, configuration: configuration(), store: store, delivery: StaticDelivery(), loader: loader)
            do {
                _ = try await installer.download(try Manifest.parse(Data(escaping.text(signingKey: "k").utf8)))
                XCTFail("\(path) was taken")
            } catch {
                XCTAssertEqual(error as? EdgeError, .fileMismatch(path: path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/1").path))
        }
    }

    func testAManifestAnswerOverOneMebibyteIsRefused() async throws {
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", body: Data(repeating: 32, count: (1 << 20) + 1))
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .unreadableManifest("the answer is over 1 MiB"))
    }

    func testAFileLongerThanItsSizeIsNotReadOn() async throws {
        FakeEdge.route("GET", "/v1/models/\(model)/releases/1/files/ios/x", body: Data("hello".utf8))
        let delivery = EdgeDelivery(model: model, configuration: configuration(), session: FakeEdge.session())
        await assertThrows(try await delivery.file(release: 1, platform: "ios", path: "x", expectedSize: 4), .fileMismatch(path: "x"))
    }

    func testAnEdgeThatDoesNotAnswerIsAnEdgeError() async throws {
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: FakeEdge.noConnection)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 0))
    }

    func testARedirectIsNotFollowed() async throws {
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: FakeEdge.redirect)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 302))
        XCTAssertFalse(FakeEdge.requestedPaths(method: "GET").contains(FakeEdge.elsewhere))
    }

    func testWiFiOnlyAsksTheManifestAnywhereAndTheFilesOnlyOffCellular() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier(wifiOnly: true)
        try await classifier.checkForUpdates()
        let requests = FakeEdge.requests
        XCTAssertTrue(requests.filter { $0.url?.path.contains("/files/") == true }.allSatisfy { !$0.allowsCellularAccess })
        XCTAssertTrue(requests.contains { $0.url?.path.contains("/files/") == true })
        XCTAssertTrue(requests.filter { $0.url?.path.hasSuffix("/manifest") == true }.allSatisfy(\.allowsCellularAccess))
    }

    func testEachOverriddenStepIsWarnedAboutOnceWithItsNameReadable() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date())

        var overrides = PreprocessingOverrides()
        overrides.circleMask = true
        await classifier.setPreprocessing(overrides)
        _ = try await classifier.classify(referencePicture)
        _ = try await classifier.classify(referencePicture)
        overrides.centreSquareCrop = false
        await classifier.setPreprocessing(overrides)
        _ = try await classifier.classify(referencePicture)

        let warnings = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == 'ai.matca.edge'"))
            .map(\.composedMessage).filter { $0.hasPrefix("the app overrides") }
        XCTAssertEqual(warnings, [
            "the app overrides circle_mask: pictures differ from what the model learned with",
            "the app overrides centre_square_crop: pictures differ from what the model learned with",
        ])
    }

    func testTheCheckIsAskedAgainAfterTheInterval() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier(checkInterval: 1)
        let deadline = Date().addingTimeInterval(5)
        while manifestAsks() < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(manifestAsks(), 2)
        withExtendedLifetime(classifier) {}
    }

    func testAnyIntervalAnAppMayWriteFitsTheSleep() {
        XCTAssertEqual(Classifier.nanosecondsToSleep(.infinity), 1_000_000_000 * 1_000_000_000)
        XCTAssertEqual(Classifier.nanosecondsToSleep(.nan), 1_000_000_000)
        XCTAssertEqual(Classifier.nanosecondsToSleep(0), 1_000_000_000)
        XCTAssertEqual(Classifier.nanosecondsToSleep(6), 6_000_000_000)
    }
}

/// Answers every file with the bytes the tests list, to reach the store's own guard.
private struct StaticDelivery: Delivery {
    func manifest() async throws -> SignedManifest { throw EdgeError.edge(status: 404) }
    func file(release: Int, platform: String, path: String, expectedSize: Int) async throws -> Data { Data("hello".utf8) }
    func count(_ event: DeliveryCount, release: Int) async throws {}
    func report(_ body: Data, release: Int) async throws {}
}
