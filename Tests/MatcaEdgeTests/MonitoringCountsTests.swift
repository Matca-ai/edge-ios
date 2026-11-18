import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 7: the counts of a scripted day, the steps, the speed of counting, the kept file.
final class MonitoringCountsTests: XCTestCase {
    private let clock = TestClock(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!)
    private var directory = temporaryDirectory()

    override func setUp() {
        super.setUp()
        directory = temporaryDirectory()
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAScriptedDayGivesTheFixtureReport() throws {
        let fixture = Fixtures.json("report-format-2.json")
        let file = MonitoringFile(directory: directory)
        for session in 0..<(fixture["sessions"] as! Int) {
            var monitoring = Monitoring(file: file, clock: clock.monitoringClock)
            monitoring.startSession(release: 4)
            if session == 0 {
                try script(fixture, into: &monitoring)
            }
            monitoring.write()
        }

        var sending = Monitoring(file: file, clock: clock.monitoringClock)
        let due = sending.reportsDue()
        XCTAssertEqual(due, [ReleaseDay(release: 4, day: clock.today)])
        let firstReport = DayReport(day: due[0].day, first: !sending.hasReported(due[0]), counts: try XCTUnwrap(sending.takeOut(due[0])))
        let report = try JSONSerialization.jsonObject(with: JSONEncoder().encode(firstReport))
        var expected = fixture
        expected["platform"] = "ios"
        expected["os"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        XCTAssertEqual(report as? NSDictionary, expected as NSDictionary)
    }

    /// The steps are the trainer's own, kept once in the shared fixtures (`sdks/test-fixtures/steps.json`), which
    /// the trainer, the control plane and the Android library are held to as well.
    func testTheStepsAreTheSharedOnes() {
        let steps = Fixtures.json("steps.json")
        XCTAssertEqual(steps["confidence_thresholds"] as? [Double], DayCounts.confidenceThresholds)
        XCTAssertEqual(steps["millisecond_thresholds"] as? [Double], DayCounts.millisecondThresholds)
        XCTAssertEqual(steps["confidence_gate"] as? Double, DayCounts.answeredGate)
    }

    func testEachValueFallsInItsStep() {
        let confidence = DayCounts.confidenceThresholds
        XCTAssertEqual(DayCounts.step(of: 0.4999, thresholds: confidence), 0)
        XCTAssertEqual(DayCounts.step(of: 0.5, thresholds: confidence), 1)
        XCTAssertEqual(DayCounts.step(of: 0.9499, thresholds: confidence), 7)
        XCTAssertEqual(DayCounts.step(of: 0.95, thresholds: confidence), 8)
        XCTAssertEqual(DayCounts.step(of: 1, thresholds: confidence), 11)
        let milliseconds = DayCounts.millisecondThresholds
        XCTAssertEqual(DayCounts.step(of: 9.99, thresholds: milliseconds), 0)
        XCTAssertEqual(DayCounts.step(of: 10, thresholds: milliseconds), 1)
        XCTAssertEqual(DayCounts.step(of: 999.9, thresholds: milliseconds), 10)
        XCTAssertEqual(DayCounts.step(of: 1000, thresholds: milliseconds), 11)

        var counts = DayCounts()
        counts.countAnswer(label: "A", confidence: 0.95, preprocessingMilliseconds: 0, modelMilliseconds: 0)
        counts.countAnswer(label: "A", confidence: 0.9499, preprocessingMilliseconds: 0, modelMilliseconds: 0)
        XCTAssertEqual(counts.outcomes.answered, 1)
        XCTAssertEqual(counts.outcomes.belowGate, 1)
    }

    func testAHundredThousandCountsTakeUnderFiftyMilliseconds() throws {
        var monitoring = Monitoring(file: MonitoringFile(directory: directory), clock: MonitoringClock())
        let answer = try Answer(scores: ["With Cap": 0.97, "Without Cap": 0.03], release: 1)
        var counted = 0
        let started = DispatchTime.now().uptimeNanoseconds
        // A while loop: a range's iterator alone costs a debug build several milliseconds over 100,000 turns.
        while counted < 100_000 {
            monitoring.countAnswer(answer, preprocessingNanoseconds: 12_000_000, modelNanoseconds: 40_000_000)
            counted += 1
        }
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("100,000 counts took \(elapsedMilliseconds) ms")
        XCTAssertLessThan(elapsedMilliseconds, 50)
        XCTAssertEqual(monitoring.counts.days.values.map(\.outcomes.answered).reduce(0, +), 100_000)
    }

    func testAnUnreadableFileIsSetAsideAndCountingStartsAfresh() throws {
        let countsURL = directory.appendingPathComponent(MonitoringFile.countsFileName)
        let asideURL = directory.appendingPathComponent(MonitoringFile.unreadableCountsFileName)
        let shortLists = #"{"days":[{"release":1,"day":20395,"counts":{"outcomes":{"answered":1,"below_gate":0,"failed":0,"#
            + #""no_stable_picture":0,"black_screen":0},"confidence":[1],"labels":{},"speed_ms":{"preprocessing":[1],"model":[1]},"#
            + #""sessions":0,"crashes":0}}]}"#
        for unreadable in ["not counts", shortLists] {
            try Data(unreadable.utf8).write(to: countsURL)
            var monitoring = Monitoring(file: MonitoringFile(directory: directory), clock: clock.monitoringClock)
            XCTAssertEqual(monitoring.counts, MonitoringCounts())
            XCTAssertEqual(try Data(contentsOf: asideURL), Data(unreadable.utf8))
            monitoring.countFailure(release: 1)
        }
    }

    func testAFileFromBeforeTheReportedDaysWereKeptStillLoads() throws {
        var kept = MonitoringCounts()
        kept.days[ReleaseDay(release: 1, day: clock.today)] = DayCounts(sessions: 2)
        var written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(kept)) as? [String: Any])
        XCTAssertNotNil(written.removeValue(forKey: "sent"))
        try JSONSerialization.data(withJSONObject: written).write(to: directory.appendingPathComponent(MonitoringFile.countsFileName))

        XCTAssertEqual(MonitoringFile(directory: directory).loadCounts(), kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MonitoringFile.unreadableCountsFileName).path))
    }

    func testTheReportedDaysSurviveTheFileAndDropWithTheDaysPastKeeping() throws {
        let today = clock.today
        var kept = MonitoringCounts()
        for day in [today - 8, today - 7, today] {
            kept.days[ReleaseDay(release: 1, day: day)] = DayCounts(sessions: 1)
            kept.sent.insert(ReleaseDay(release: 2, day: day))
        }
        let file = MonitoringFile(directory: directory)
        file.writeCounts(kept)
        var loaded = file.loadCounts()
        XCTAssertEqual(loaded, kept)

        XCTAssertEqual(loaded.reportsDue(today: today), [ReleaseDay(release: 1, day: today - 7), ReleaseDay(release: 1, day: today)])
        XCTAssertEqual(Set(loaded.days.keys), [ReleaseDay(release: 1, day: today - 7), ReleaseDay(release: 1, day: today)])
        XCTAssertEqual(loaded.sent, [ReleaseDay(release: 2, day: today - 7), ReleaseDay(release: 2, day: today)])
    }

    /// The fixture's day: every answer in its confidence step, label and speed steps, then the other outcomes.
    private func script(_ fixture: [String: Any], into monitoring: inout Monitoring) throws {
        let confidenceInSteps = [0.45, 0.55, 0.65, 0.75, 0.82, 0.87, 0.91, 0.93, 0.96, 0.975, 0.985, 0.995]
        let millisecondsInSteps = [5.0, 15, 25, 40, 60, 90, 120, 175, 250, 400, 750, 1500]
        let speeds = fixture["speed_ms"] as! [String: [Int]]
        let labels = fixture["labels"] as! [String: Int]
        let confidences = expanded(fixture["confidence"] as! [Int], confidenceInSteps)
        let answerLabels = expanded(labels.keys.sorted().map { labels[$0]! }, labels.keys.sorted())
        let preprocessing = expanded(speeds["preprocessing"]!, millisecondsInSteps)
        let model = expanded(speeds["model"]!, millisecondsInSteps)
        for index in confidences.indices {
            let confidence = confidences[index]
            let rest = (1 - confidence) / 2
            let answer = try Answer(scores: [answerLabels[index]: confidence, "rest-a": rest, "rest-b": rest], release: 4)
            monitoring.countAnswer(
                answer, preprocessingNanoseconds: UInt64(preprocessing[index] * 1_000_000), modelNanoseconds: UInt64(model[index] * 1_000_000)
            )
        }
        let outcomes = fixture["outcomes"] as! [String: Int]
        for _ in 0..<outcomes["failed"]! { monitoring.countFailure(release: 4) }
        for _ in 0..<outcomes["no_stable_picture"]! { monitoring.count(.noStablePicture, release: 4) }
        for _ in 0..<outcomes["black_screen"]! { monitoring.count(.blackScreen, release: 4) }
    }

    private func expanded<Value>(_ counts: [Int], _ values: [Value]) -> [Value] {
        zip(counts, values).flatMap { Array(repeating: $1, count: $0) }
    }
}
