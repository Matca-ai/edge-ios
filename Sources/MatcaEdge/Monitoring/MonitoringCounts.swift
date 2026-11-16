import Foundation

/// A UTC day as the number of days since 1 January 1970, and as the report writes it.
enum UTCDay {
    private static let secondsPerDay = 86_400.0

    static func number(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / secondsPerDay).rounded(.down))
    }

    static func text(_ day: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date(timeIntervalSince1970: Double(day) * secondsPerDay))
    }
}

struct ReleaseDay: Hashable, Sendable {
    let release: Int
    let day: Int
}

/// Every release and day this phone holds counts for, kept in `monitoring.json` until sent.
struct MonitoringCounts: Codable, Equatable, Sendable {
    /// An unsent day is kept this many days, then dropped.
    static let daysKept = 7
    static let reportsPerCheck = 14

    private struct KeptDay: Codable {
        let release: Int
        let day: Int
        let counts: DayCounts
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }

    var days: [ReleaseDay: DayCounts] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let kept = try decoder.container(keyedBy: CodingKeys.self).decode([KeptDay].self, forKey: .days)
        for day in kept {
            days[ReleaseDay(release: day.release, day: day.day), default: DayCounts()].add(day.counts)
        }
    }

    func encode(to encoder: Encoder) throws {
        let kept = days.map { KeptDay(release: $0.key.release, day: $0.key.day, counts: $0.value) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kept, forKey: .days)
    }

    var isWellFormed: Bool {
        days.values.allSatisfy(\.isWellFormed)
    }

    /// Drops the days past keeping and names the finished ones to send now, oldest first; today is never sent.
    mutating func reportsDue(today: Int) -> [ReleaseDay] {
        days = days.filter { today - $0.key.day <= Self.daysKept }
        let finished = days.keys.filter { $0.day < today }.sorted { ($0.day, $0.release) < ($1.day, $1.release) }
        return Array(finished.prefix(Self.reportsPerCheck))
    }
}

/// One finished day's counts for one release, as `POST …/releases/{n}/report` takes it.
struct DayReport: Encodable {
    let format = 1
    let day: String
    let platform = "ios"
    let os = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    let library = EdgeLibrary.version
    let outcomes: DayCounts.Outcomes
    let confidence: [Int]
    let labels: [String: Int]
    let speedMs: DayCounts.Speeds
    let sessions: Int
    let crashes: Int

    enum CodingKeys: String, CodingKey {
        case format, day, platform, os, library, outcomes, confidence, labels, sessions, crashes
        case speedMs = "speed_ms"
    }

    init(day: Int, counts: DayCounts) {
        self.day = UTCDay.text(day)
        outcomes = counts.outcomes
        confidence = counts.confidence
        labels = counts.labels
        speedMs = counts.speedMs
        sessions = counts.sessions
        crashes = counts.crashes
    }
}
