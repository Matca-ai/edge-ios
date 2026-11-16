import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, tests 2, 4 and 6: the sequence rule, the atomic switch with failures, the rollout.
final class ClassifierTests: ClassifierTestCase {
    func testAReleaseIsTakenAndTheInstallCounted() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST"), ["/v1/models/cap-detection/releases/1/installs"])
        XCTAssertEqual(state().currentRelease, 1)
        XCTAssertEqual(state().lastSequence, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/1/Model.mlpackage/Manifest.json").path))
        let header = FakeEdge.requests.first?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(header, "matca-edge-ios/\(EdgeLibrary.version)")
        XCTAssertEqual(FakeEdge.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer mdk_1_secret")

        let answer = try await classifier.classify(referencePicture)
        XCTAssertEqual(answer.label, "With Cap")
        XCTAssertEqual(answer.release, 1)
        XCTAssertEqual(answer.all.map(\.label), ["With Cap", "Without Cap"])
    }

    func testAManifestWithASequenceNotAboveTheLastChangesNothing() async throws {
        serve(manifest(release: 1, sequence: 5))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()
        FakeEdge.reset()

        serve(manifest(release: 2, sequence: 5))
        try await classifier.checkForUpdates()

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "GET"), ["/v1/models/cap-detection/manifest"])
        XCTAssertEqual(state().currentRelease, 1)
    }

    func testAManifestForTheReleaseThisPhoneRunsFetchesNothingAndKeepsItsFiles() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()
        FakeEdge.reset()

        // A wider rollout signs the same release again; this edge serves the manifest and no file.
        let signed = manifest(release: 1, sequence: 2).signed(by: root)
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", body: try JSONEncoder().encode(signed))
        try await classifier.checkForUpdates()

        XCTAssertEqual(state().lastSequence, 2)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "GET"), ["/v1/models/cap-detection/manifest"])
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST"), [])
        let restarted = try makeClassifier()
        let answer = try await restarted.classify(referencePicture)
        XCTAssertEqual(answer.release, 1)
    }

    func testAFailedDownloadLeavesThePreviousReleaseInPlace() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        var corrupt = manifest(release: 2, sequence: 2)
        corrupt.iosFiles = [["path": "Model.mlpackage/Manifest.json", "size": 5, "sha256": sha256Hex("other")]]
        serve(corrupt)
        await assertThrows(try await classifier.checkForUpdates(), .fileMismatch(path: "Model.mlpackage/Manifest.json"))

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(state().currentRelease, 1)
        XCTAssertEqual(state().lastSequence, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/1").path))
        let answered = try await classifier.classify(referencePicture)
        XCTAssertEqual(answered.release, 1)
    }

    func testAFailedReferenceCheckIsCountedAndLeavesThePreviousRelease() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        loader.scoresByRelease[2] = ["With Cap": 0.2, "Without Cap": 0.8]
        serve(manifest(release: 2, sequence: 2))
        await assertThrows(try await classifier.checkForUpdates(), .referenceCheckFailed(path: sha256Hex(referencePicture)))

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST").last, "/v1/models/cap-detection/releases/2/failed-checks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/2").path))
    }

    func testAModelThatDoesNotLoadLeavesThePreviousRelease() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        loader.failingReleases = [2]
        serve(manifest(release: 2, sequence: 2))
        await assertThrows(try await classifier.checkForUpdates(), .modelLoadFailed("fake"))

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
        XCTAssertEqual(state().currentRelease, 1)
    }

    func testTheSwitchMovesThePointerAndDropsThePreviousRelease() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        serve(manifest(release: 2, sequence: 2))
        try await classifier.checkForUpdates()

        let release = await classifier.currentRelease
        XCTAssertEqual(release, 2)
        XCTAssertEqual(state(), StoredState(lastSequence: 2, rolloutNumber: state().rolloutNumber, currentRelease: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("releases/1").path))
        let answered = try await classifier.classify(referencePicture)
        XCTAssertEqual(answered.release, 2)
    }

    func testTheReleaseOnDiskIsReloadedByANewClassifier() async throws {
        serve(manifest(release: 1, sequence: 1))
        let first = try makeClassifier()
        try await first.checkForUpdates()
        FakeEdge.reset()

        let second = try makeClassifier()
        let answer = try await second.classify(referencePicture)
        XCTAssertEqual(answer.release, 1)
        XCTAssertEqual(loader.loadedReleases, [1, 1])
    }

    func testTheRolloutShareDecidesByTheDevicesNumber() async throws {
        try ModelStore(directory: storeDirectory).writeState(StoredState(lastSequence: 0, rolloutNumber: 50, currentRelease: nil))
        var narrow = manifest(release: 1, sequence: 1)
        narrow.rolloutShare = 50
        serve(narrow)
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()

        var release = await classifier.currentRelease
        XCTAssertNil(release)
        XCTAssertEqual(state().lastSequence, 1)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "GET").filter { $0.contains("/files/") }, [])

        var wide = manifest(release: 1, sequence: 2)
        wide.rolloutShare = 51
        serve(wide)
        try await classifier.checkForUpdates()
        release = await classifier.currentRelease
        XCTAssertEqual(release, 1)
    }

    func testAReleaseThatNeedsANewerLibraryIsRefused() async throws {
        var demanding = manifest(release: 1, sequence: 1)
        demanding.requires = ["fix_orientation", "depth_map"]
        serve(demanding)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.checkForUpdates(), .needsNewerLibrary(features: ["depth_map"]))
        XCTAssertEqual(state().lastSequence, 0)
    }

    func testAReleaseMissingAnExpectedLabelIsRefused() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier(expectedLabels: ["With Cap", "Hat"])
        await assertThrows(try await classifier.checkForUpdates(), .missingLabels(["Hat"]))
    }

    func testAReleaseWithoutIOSFilesIsSkippedQuietly() async throws {
        var androidOnly = manifest(release: 1, sequence: 1)
        androidOnly.iosFiles = []
        serve(androidOnly)
        let classifier = try makeClassifier()
        try await classifier.checkForUpdates()
        let release = await classifier.currentRelease
        XCTAssertNil(release)
    }

    func testABundledReleaseIsTakenBeforeAnyNetworkWithoutAnInstallCount() async throws {
        let bundle = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try writeBundle(manifest(release: 1, sequence: 1), to: bundle)
        FakeEdge.route("GET", "/v1/models/cap-detection/manifest", status: 404)
        let stateFile = storeDirectory.appendingPathComponent(ModelStore.stateFileName)
        let asked = expectation(description: "the edge was asked")
        FakeEdge.observeRequests {
            let state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(StoredState.self, from: $0) }
            XCTAssertEqual(state?.currentRelease, 1, "the bundled release comes before any network")
            asked.fulfill()
        }

        let classifier = try makeClassifier(bundledRelease: bundle)
        let answer = try await classifier.classify(referencePicture)
        XCTAssertEqual(answer.release, 1)
        await fulfillment(of: [asked], timeout: 5)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST"), [])
    }

    func testABundledReleaseThatFailsItsCheckIsNotCounted() async throws {
        let bundle = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try writeBundle(manifest(release: 1, sequence: 1), to: bundle)
        loader.scoresByRelease[1] = ["With Cap": 0.2, "Without Cap": 0.8]
        FakeEdge.route("GET", "/v1/models/cap-detection/manifest", status: 404)

        let classifier = try makeClassifier(bundledRelease: bundle)
        await assertThrows(try await classifier.classify(referencePicture), .noModel)
        XCTAssertEqual(FakeEdge.requestedPaths(method: "POST"), [])
    }

    func testWithoutAReleaseClassifyingThrowsNoModel() async throws {
        FakeEdge.route("GET", "/v1/models/cap-detection/manifest", status: 404)
        let classifier = try makeClassifier()
        await assertThrows(try await classifier.classify(referencePicture), .noModel)
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
    }

    func testAModelNameThatIsNotADNSLabelIsRefused() {
        XCTAssertThrowsError(try makeClassifier(model: "../other")) { error in
            XCTAssertEqual(error as? EdgeError, .invalidModelName)
        }
    }
}
