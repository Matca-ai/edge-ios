import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 7: which days go and when, what the edge's answer does to each report, which one says
/// `first`, and that neither a classification nor a check waits for them.
final class ReportSendingTests: ClassifierTestCase {
    func testEveryDayHeldTodayTooGoesOldestFirstAfterACheckTheEdgeAnswered() async throws {
        let today = clock.today
        try seed([
            ReleaseDay(release: 1, day: today - 1), ReleaseDay(release: 2, day: today - 2), ReleaseDay(release: 1, day: today),
            ReleaseDay(release: 1, day: today - 8), ReleaseDay(release: 1, day: today - 7),
        ])
        routeReports(of: [1, 2], status: 204)
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: FakeEdge.noConnection)
        let classifier = try await settledClassifier()
        XCTAssertEqual(FakeEdge.requests(endingWith: "/report"), [], "nothing goes without an answer from the edge")

        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: 404)
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        await classifier.waitForReportsOnTheirWay()
        let sent = [
            ReleaseDay(release: 1, day: today - 7), ReleaseDay(release: 2, day: today - 2), ReleaseDay(release: 1, day: today - 1),
            ReleaseDay(release: 1, day: today),
        ]
        XCTAssertEqual(sentReports(), sent.map { SentReport(release: $0.release, day: UTCDay.text($0.day), first: true, answers: 1) })
        XCTAssertEqual(keptCounts().days, [:])
        XCTAssertEqual(keptCounts().sent, Set(sent))
        let request = try XCTUnwrap(FakeEdge.requests(endingWith: "/report").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mdk_1_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "matca-edge-ios/1.2.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["format"] as? Int, 2)

        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        await classifier.waitForReportsOnTheirWay()
        XCTAssertEqual(sentReports().count, 4, "a day with nothing counted since its last report is not sent")
    }

    func testFirstIsSaidOncePerReleaseAndDayAlsoAfterARestart() async throws {
        serve(manifest(release: 1, sequence: 1))
        routeReports(of: [1], status: 204)
        let classifier = try await settledClassifier()
        for _ in 0..<2 {
            _ = try await classifier.classify(referencePicture)
            try await classifier.checkForUpdates()
            await classifier.waitForReportsOnTheirWay()
        }
        let beforeTheRestart = sentReports()
        XCTAssertGreaterThanOrEqual(beforeTheRestart.count, 2)
        XCTAssertEqual(beforeTheRestart.map(\.first), [true] + Array(repeating: false, count: beforeTheRestart.count - 1))

        let restarted = try await settledClassifier()
        _ = try await restarted.classify(referencePicture)
        try await restarted.checkForUpdates()
        await restarted.waitForReportsOnTheirWay()
        let ofTheDay = sentReports()
        XCTAssertGreaterThan(ofTheDay.count, beforeTheRestart.count)
        XCTAssertEqual(ofTheDay.filter(\.first).count, 1)
        XCTAssertEqual(ofTheDay.map(\.answers).reduce(0, +), 3, "every answer goes once")

        clock.advance(seconds: 24 * 60 * 60)
        _ = try await restarted.classify(referencePicture)
        await restarted.waitForReportsOnTheirWay()
        XCTAssertEqual(sentReports().last, SentReport(release: 1, day: UTCDay.text(clock.today), first: true, answers: 1))
    }

    func testWhatIsCountedWhileAReportIsOnItsWayGoesWithTheNextOne() async throws {
        serve(manifest(release: 1, sequence: 1))
        routeReports(of: [1], status: 204)
        let classifier = try await settledClassifier()
        await classifier.waitForReportsOnTheirWay()
        let reportsAtCreation = sentReports().count
        let edgeAnswers = DispatchSemaphore(value: 0)
        FakeEdge.observeRequests { edgeAnswers.wait() }
        defer { edgeAnswers.signal() }

        try await classify(2, by: classifier)
        clock.advance(seconds: 60)
        try await classify(1, by: classifier)
        try await waitUntil { self.sentReports().count == reportsAtCreation + 1 }
        try await classify(2, by: classifier)
        FakeEdge.observeRequests {}
        edgeAnswers.signal()
        await classifier.waitForReportsOnTheirWay()
        clock.advance(seconds: 15 * 60)
        try await classify(1, by: classifier)
        await classifier.waitForReportsOnTheirWay()

        XCTAssertEqual(sentReports().dropFirst(reportsAtCreation).map(\.answers), [3, 3])
        XCTAssertEqual(keptCounts().days, [:])
    }

    func testAClassificationStartsASendingAMinuteAfterCreationAndThenFifteenMinutesAfterTheLastSending() async throws {
        serve(manifest(release: 1, sequence: 1))
        routeReports(of: [1], status: 204)
        let classifier = try await settledClassifier()
        await classifier.waitForReportsOnTheirWay()
        let atCreation = sentReports().count

        clock.advance(seconds: 59)
        try await assertReports(atCreation, afterAClassificationBy: classifier)
        clock.advance(seconds: 1)
        try await assertReports(atCreation + 1, afterAClassificationBy: classifier)
        clock.advance(seconds: 15 * 60 - 1)
        try await assertReports(atCreation + 1, afterAClassificationBy: classifier)
        clock.advance(seconds: 1)
        try await assertReports(atCreation + 2, afterAClassificationBy: classifier)

        clock.advance(seconds: 14 * 60)
        try await assertReports(atCreation + 2, afterAClassificationBy: classifier)
        try await classifier.checkForUpdates()
        clock.advance(seconds: 60)
        try await assertReports(atCreation + 3, afterAClassificationBy: classifier, "the check's sending is the last one")
        clock.advance(seconds: 14 * 60)
        try await assertReports(atCreation + 4, afterAClassificationBy: classifier)
    }

    func testA429KeepsTheReportAsTheFirstAndEndsTheSendingUntilTheNextOne() async throws {
        try seed([ReleaseDay(release: 1, day: clock.today - 2), ReleaseDay(release: 2, day: clock.today - 1)])
        routeReports(of: [1], status: 429)
        routeReports(of: [2], status: 204)
        let classifier = try await classifierThatHasNotSentYet()

        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.sentReports().count == 1 }
        routeReports(of: [1], status: 204)
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.keptCounts().days.isEmpty }
        XCTAssertEqual(sentReports().map(\.release), [1, 1, 2])
        XCTAssertEqual(sentReports().map(\.first), [true, true, true])
    }

    func testARefusalDropsTheReportAndAServerErrorOrNoConnectionKeepsIt() async throws {
        try seed((1...4).map { ReleaseDay(release: $0, day: clock.today - 3) } + [ReleaseDay(release: 5, day: clock.today - 1)])
        for (release, status) in [(1, 400), (2, 401), (3, 404), (4, 413), (5, 503)] {
            routeReports(of: [release], status: status)
        }
        let classifier = try await classifierThatHasNotSentYet()

        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { Array(self.keptCounts().days.keys) == [ReleaseDay(release: 5, day: self.clock.today - 1)] }
        XCTAssertEqual(sentReports().map(\.release), [1, 2, 3, 4, 5])
        routeReports(of: [5], status: FakeEdge.noConnection)
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.sentReports().count == 6 }
        routeReports(of: [5], status: 204)
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.keptCounts().days.isEmpty }
        XCTAssertEqual(sentReports().map(\.release), [1, 2, 3, 4, 5, 5, 5])
        XCTAssertEqual(keptCounts().sent, [ReleaseDay(release: 5, day: clock.today - 1)], "only a report the edge took is remembered")
    }

    func testAtMostFourteenReportsGoPerSending() async throws {
        let days = (1...7).flatMap { daysAgo in (1...3).map { ReleaseDay(release: $0, day: clock.today - daysAgo) } }
        try seed(days)
        routeReports(of: [1, 2, 3], status: 204)
        let classifier = try await classifierThatHasNotSentYet()

        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.keptCounts().days.count == 7 }
        XCTAssertEqual(sentReports().count, 14)
        XCTAssertEqual(sentReports().last, SentReport(release: 2, day: UTCDay.text(clock.today - 3), first: true, answers: 1))
        await assertThrows(try await classifier.checkForUpdates(), .edge(status: 404))
        try await waitUntil { self.keptCounts().days.isEmpty }
        XCTAssertEqual(sentReports().count, 21)
    }

    func testNeitherAClassificationNorACheckWaitsForAReportTheEdgeNeverAnswers() async throws {
        try seed([ReleaseDay(release: 1, day: clock.today - 1)])
        serve(manifest(release: 1, sequence: 1))
        routeReports(of: [1], status: FakeEdge.neverAnswers)
        let monitored = try await settledClassifier()
        try await waitUntil { FakeEdge.requests(endingWith: "/report").count == 1 }
        try await monitored.checkForUpdates()

        let unmonitoredDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unmonitoredDirectory) }
        let unmonitored = try await settledClassifier(monitoring: false, storeDirectory: unmonitoredDirectory)
        let withMonitoring = try await secondsToClassify(20, by: monitored)
        let withoutMonitoring = try await secondsToClassify(20, by: unmonitored)
        print("20 classifications: \(withMonitoring) s with a report hanging, \(withoutMonitoring) s with monitoring off")
        XCTAssertLessThan(withMonitoring, withoutMonitoring * 1.5 + 0.02)
        XCTAssertEqual(FakeEdge.requests(endingWith: "/report").count, 1)
    }

    private struct SentReport: Equatable {
        let release: Int
        let day: String
        let first: Bool
        let answers: Int
    }

    /// No report goes at creation: the edge does not answer its first manifest asks; it answers 404 from then on.
    private func classifierThatHasNotSentYet() async throws -> Classifier {
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: FakeEdge.noConnection)
        let classifier = try await settledClassifier()
        FakeEdge.route("GET", "/v1/models/\(model)/manifest", status: 404)
        return classifier
    }

    private func routeReports(of releases: [Int], status: Int) {
        for release in releases {
            FakeEdge.route("POST", "/v1/models/\(model)/releases/\(release)/report", status: status)
        }
    }

    private func sentReports() -> [SentReport] {
        FakeEdge.requests(endingWith: "/report").map { request in
            let release = Int(request.url!.deletingLastPathComponent().lastPathComponent)!
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let outcomes = body?["outcomes"] as? [String: Int] ?? [:]
            return SentReport(
                release: release, day: body?["day"] as? String ?? "", first: body?["first"] as? Bool ?? false,
                answers: (outcomes["answered"] ?? 0) + (outcomes["below_gate"] ?? 0)
            )
        }
    }

    private func classify(_ times: Int, by classifier: Classifier) async throws {
        for _ in 0..<times {
            _ = try await classifier.classify(referencePicture)
        }
    }

    private func assertReports(
        _ expected: Int, afterAClassificationBy classifier: Classifier, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await classify(1, by: classifier)
        await classifier.waitForReportsOnTheirWay()
        XCTAssertEqual(sentReports().count, expected, message, file: file, line: line)
    }

    private func secondsToClassify(_ times: Int, by classifier: Classifier) async throws -> Double {
        _ = try await classifier.classify(referencePicture)
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<times {
            _ = try await classifier.classify(referencePicture)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }
}
