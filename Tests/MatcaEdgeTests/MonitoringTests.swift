import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 7, through the classifier: what it counts, when it keeps it, the switch and the crashes.
final class MonitoringTests: ClassifierTestCase {
    func testEachClassificationIsCountedForItsReleaseAndNoneWithoutARelease() async throws {
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: 404)
        let classifier = try await settledClassifier()
        await assertThrows(try await classifier.classify(referencePicture), .noModel)
        serve(manifest(release: 1, sequence: 1))
        try await classifier.checkForUpdates()

        _ = try await classifier.classify(referencePicture)
        let runner = try XCTUnwrap(loader.lastRunner)
        runner.scores = ["With Cap": 0.97, "Without Cap": 0.03]
        _ = try await classifier.classify(referencePicture)
        runner.throwsOnPredict = true
        await assertThrows(try await classifier.classify(referencePicture), .predictionFailed("fake"))
        await assertThrows(try await classifier.classify(Data([1, 2, 3])), .undecodablePicture)

        let kept = await counts(keptBy: classifier)
        XCTAssertEqual(Array(kept.days.keys), [ReleaseDay(release: 1, day: clock.today)])
        let day = try XCTUnwrap(kept.days[ReleaseDay(release: 1, day: clock.today)])
        XCTAssertEqual(day.outcomes, DayCounts.Outcomes(answered: 1, belowGate: 1, failed: 2, noStablePicture: 0, blackScreen: 0))
        XCTAssertEqual(day.confidence, [0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0])
        XCTAssertEqual(day.labels, ["With Cap": 2])
        XCTAssertEqual(day.speedMs.preprocessing.reduce(0, +), 2)
        XCTAssertEqual(day.speedMs.model.reduce(0, +), 2)
        XCTAssertEqual(day.sessions, 1)
    }

    func testPreprocessingTimeRunsFromTheFrameHandedInWithItsDecoding() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try await settledClassifier()
        var decoded = try PictureDecoding.decode(Frame(jpeg: referencePicture))
        XCTAssertGreaterThan(decoded.decodingNanoseconds, 0)
        decoded.decodingNanoseconds = 150_000_000
        _ = try await classifier.classify(decoded: decoded)

        let day = await counts(keptBy: classifier).days[ReleaseDay(release: 1, day: clock.today)]
        XCTAssertEqual(day?.speedMs.preprocessing, [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(day?.speedMs.model, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testASessionIsCountedOncePerClassifierAndRelease() async throws {
        serve(manifest(release: 1, sequence: 1))
        let first = try await settledClassifier()
        try await first.checkForUpdates()
        XCTAssertEqual(keptCounts().days[ReleaseDay(release: 1, day: clock.today)]?.sessions, 1)

        let restarted = try await settledClassifier()
        _ = try await restarted.classify(referencePicture)
        serve(manifest(release: 2, sequence: 2))
        try await restarted.checkForUpdates()
        serve(manifest(release: 1, sequence: 3))
        try await restarted.checkForUpdates()
        let movedBack = await restarted.currentRelease
        XCTAssertEqual(movedBack, 1)
        let kept = await counts(keptBy: restarted)
        XCTAssertEqual(kept.days[ReleaseDay(release: 1, day: clock.today)]?.sessions, 2)
        XCTAssertEqual(kept.days[ReleaseDay(release: 2, day: clock.today)]?.sessions, 1)
    }

    func testAWatchCountsAWaitThatTimedOutAndABlackScreen() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try await settledClassifier()
        var waiting = Watch(classifier: classifier)
        waiting.waitForStablePicture = true
        _ = await collect(waiting.states(of: greyFrames(50, count: 20)))
        var watchingForBlack = Watch(classifier: classifier)
        watchingForBlack.detectBlackScreen = true
        _ = await collect(watchingForBlack.states(of: greyFrames(0, count: 20)))
        var stable = Watch(classifier: classifier)
        stable.waitForStablePicture = true
        _ = await collect(stable.states(of: greyFrames(200, count: 20)))

        let day = await counts(keptBy: classifier).days[ReleaseDay(release: 1, day: clock.today)]
        XCTAssertEqual(day?.outcomes.noStablePicture, 1)
        XCTAssertEqual(day?.outcomes.blackScreen, 1)
    }

    func testTheCountsAreWrittenByTheFirstClassificationAfterAMinute() async throws {
        serve(manifest(release: 1, sequence: 1))
        let classifier = try await settledClassifier()
        _ = try await classifier.classify(referencePicture)
        clock.advance(seconds: 59)
        _ = try await classifier.classify(referencePicture)
        XCTAssertEqual(keptCounts().days[ReleaseDay(release: 1, day: clock.today)]?.outcomes.belowGate ?? 0, 0)

        clock.advance(seconds: 1)
        _ = try await classifier.classify(referencePicture)
        XCTAssertEqual(keptCounts().days[ReleaseDay(release: 1, day: clock.today)]?.outcomes.belowGate, 3)
    }

    func testMonitoringOffCountsAndSendsNothingAndDeletesWhatWasKept() async throws {
        try seed([ReleaseDay(release: 1, day: clock.today - 1)])
        MonitoringFile(directory: storeDirectory).writeSession(Session(release: 1, startedAt: clock.now))
        serve(manifest(release: 1, sequence: 1))
        FakeEdge.route("POST", "/v1/models/\(model)/releases/1/report", status: 204)

        let classifier = try await settledClassifier(monitoring: false)
        _ = try await classifier.classify(referencePicture)
        try await classifier.checkForUpdates()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(MonitoringFile(directory: storeDirectory).loadSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent(MonitoringFile.countsFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent(MonitoringFile.sessionFileName).path))
        XCTAssertEqual(FakeEdge.requests(endingWith: "/report"), [])
    }

    func testACrashIsCountedOnceAgainstTheReleaseTheSessionBeforeRan() async throws {
        serve(manifest(release: 1, sequence: 1))
        let crashed = try await settledClassifier()
        let crashedStartedAt = clock.now
        clock.advance(seconds: 60 * 60)
        serve(manifest(release: 2, sequence: 2))
        let next = try await settledClassifier()

        let crash = CrashReport(crashCount: 1, periodEnd: crashedStartedAt + 30 * 60)
        let beforeThatSession = CrashReport(crashCount: 1, periodEnd: crashedStartedAt - 60)
        await crashReports.deliver([crash, beforeThatSession])
        await crashReports.deliver([crash])

        let kept = await counts(keptBy: next)
        XCTAssertEqual(kept.days[ReleaseDay(release: 1, day: clock.today)]?.crashes, 1)
        XCTAssertEqual(kept.days[ReleaseDay(release: 2, day: clock.today)]?.crashes, 0)
        withExtendedLifetime(crashed) {}
    }

    private func greyFrames(_ value: UInt8, count: Int) -> AsyncStream<Frame> {
        frames((0..<count).map { Frame(image: solidGreyImage(value), at: Double($0) * 0.3) })
    }
}
