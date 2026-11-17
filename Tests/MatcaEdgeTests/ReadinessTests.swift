import Foundation
@testable import MatcaEdge
import XCTest

/// A first launch before the model reached the phone: the classifier asks again soon, and an app can wait for it.
final class ReadinessTests: ClassifierTestCase {
    func testWaitUntilReadyAnswersOnceTheEdgeHasARelease() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try makeClassifier()
        let release = try await classifier.waitUntilReady(timeout: 5)
        XCTAssertEqual(release, 1)
        let again = try await classifier.waitUntilReady(timeout: 0)
        XCTAssertEqual(again, 1, "at once when the model is already on the phone")
    }

    func testWithoutAModelTheClassifierAsksAgainSoonNotAfterTheCheckInterval() async throws {
        // Nothing released yet: the edge answers 404 until the release appears a moment later.
        let classifier = try makeClassifier(retryDelays: [0.1])
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = await classifier.currentRelease
        XCTAssertNil(before)
        serve(manifest(release: 1, sequence: 1))
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = await classifier.currentRelease
        XCTAssertEqual(after, 1, "taken by the automatic asks alone")
    }

    func testAWaiterGetsTheReleaseTheAutomaticAsksBring() async throws {
        let classifier = try makeClassifier(retryDelays: [0.1])
        async let waited = classifier.waitUntilReady(timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        serve(manifest(release: 1, sequence: 1))
        let release = try await waited
        XCTAssertEqual(release, 1)
    }

    func testAWaitThatTimesOutSaysWhyNoModelCame() async throws {
        let classifier = try makeClassifier(retryDelays: [60])
        await assertThrows(try await classifier.waitUntilReady(timeout: 0.2), .edge(status: 404))
    }
}
