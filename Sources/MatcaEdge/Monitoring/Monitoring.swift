import Foundation

/// The wall clock gives the UTC day; the monotonic one times answers and paces the writes.
struct MonitoringClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var uptimeNanoseconds: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
}

enum WatchEvent: Sendable {
    case noStablePicture
    case blackScreen
}

/// The counts a classifier holds in memory of how its releases do, and when they reach the file (the
/// contract's section 11). Counting only adds in memory; the file is written on its own queue.
struct Monitoring {
    private static let writeIntervalNanoseconds: UInt64 = 60 * 1_000_000_000

    private(set) var counts: MonitoringCounts
    private let file: MonitoringFile
    private let clock: MonitoringClock
    private let startedAt: Date
    private let previousSession: Session?
    private var lastWrittenAt: UInt64
    private var sessionsCounted: Set<Int> = []
    private var lastCrashPeriodCounted: Date?

    /// Reads what the process before kept, and records this process's session.
    init(file: MonitoringFile, clock: MonitoringClock) {
        self.file = file
        self.clock = clock
        counts = file.loadCounts()
        previousSession = file.loadSession()
        startedAt = clock.now()
        lastWrittenAt = clock.uptimeNanoseconds()
        file.writeSession(Session(release: nil, startedAt: startedAt))
    }

    private var today: Int {
        UTCDay.number(of: clock.now())
    }

    mutating func countAnswer(_ answer: Answer, preprocessingNanoseconds: UInt64, modelNanoseconds: UInt64) {
        counts.days[ReleaseDay(release: answer.release, day: today), default: DayCounts()].countAnswer(
            label: answer.label, confidence: answer.confidence,
            preprocessingMilliseconds: Self.milliseconds(preprocessingNanoseconds), modelMilliseconds: Self.milliseconds(modelNanoseconds)
        )
        writeIfAMinutePassed()
    }

    mutating func countFailure(release: Int) {
        counts.days[ReleaseDay(release: release, day: today), default: DayCounts()].outcomes.failed += 1
        writeIfAMinutePassed()
    }

    mutating func count(_ event: WatchEvent, release: Int) {
        let key = ReleaseDay(release: release, day: today)
        switch event {
        case .noStablePicture:
            counts.days[key, default: DayCounts()].outcomes.noStablePicture += 1
        case .blackScreen:
            counts.days[key, default: DayCounts()].outcomes.blackScreen += 1
        }
    }

    /// A release loaded or taken: one session per classifier and release, and the release this process now runs.
    mutating func startSession(release: Int) {
        if sessionsCounted.insert(release).inserted {
            counts.days[ReleaseDay(release: release, day: today), default: DayCounts()].sessions += 1
        }
        file.writeSession(Session(release: release, startedAt: startedAt))
    }

    /// A crash ended the process before this one, so it counts against the release that process ran, on the
    /// day the crash's period ended. A period already counted, or one before that session, is not counted again.
    mutating func countCrashes(_ reports: [CrashReport]) {
        guard let previousSession, let release = previousSession.release else { return }
        for report in reports.sorted(by: { $0.periodEnd < $1.periodEnd }) {
            guard report.periodEnd >= previousSession.startedAt, lastCrashPeriodCounted.map({ report.periodEnd > $0 }) ?? true else { continue }
            lastCrashPeriodCounted = report.periodEnd
            counts.days[ReleaseDay(release: release, day: UTCDay.number(of: report.periodEnd)), default: DayCounts()].crashes += report.crashCount
        }
    }

    mutating func write() {
        lastWrittenAt = clock.uptimeNanoseconds()
        file.writeCounts(counts)
    }

    /// Drops the days past keeping and names the finished ones to send now, oldest first.
    mutating func reportsDue() -> [ReleaseDay] {
        counts.reportsDue(today: today)
    }

    /// The day's counts leave the memory while their report is on its way, so nothing counted meanwhile is sent twice.
    mutating func takeOut(_ key: ReleaseDay) -> DayCounts? {
        counts.days.removeValue(forKey: key)
    }

    mutating func putBack(_ kept: DayCounts, at key: ReleaseDay) {
        counts.days[key, default: DayCounts()].add(kept)
    }

    private mutating func writeIfAMinutePassed() {
        if clock.uptimeNanoseconds() >= lastWrittenAt + Self.writeIntervalNanoseconds {
            write()
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
