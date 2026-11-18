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

struct ReleaseDay: Hashable, Codable, Sendable {
    let release: Int
    let day: Int
}

/// Every release and day this phone holds counts for since its last report, and the ones it already reported,
/// kept in `monitoring.json`.
struct MonitoringCounts: Codable, Equatable, Sendable {
    /// A day is kept this many days, then dropped, sent or not.
    static let daysKept = 7
    static let reportsPerSending = 14

    private struct KeptDay: Codable {
        let release: Int
        let day: Int
        let counts: DayCounts
    }

    private enum CodingKeys: String, CodingKey {
        case days, sent
    }

    var days: [ReleaseDay: DayCounts] = [:]
    /// The releases and days the edge took a report of, so only the first report of each says `first`.
    var sent: Set<ReleaseDay> = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for day in try container.decode([KeptDay].self, forKey: .days) {
            days[ReleaseDay(release: day.release, day: day.day), default: DayCounts()].add(day.counts)
        }
        // A file written by a library before 1.2.0 has no such list.
        sent = Set(try container.decodeIfPresent([ReleaseDay].self, forKey: .sent) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        let kept = days.map { KeptDay(release: $0.key.release, day: $0.key.day, counts: $0.value) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kept, forKey: .days)
        try container.encode(Array(sent), forKey: .sent)
    }

    var isWellFormed: Bool {
        days.values.allSatisfy(\.isWellFormed)
    }

    /// Drops the days past keeping and names every release and day to send now, the running day too, oldest first.
    mutating func reportsDue(today: Int) -> [ReleaseDay] {
        days = days.filter { today - $0.key.day <= Self.daysKept }
        sent = sent.filter { today - $0.day <= Self.daysKept }
        let oldestFirst = days.keys.sorted { ($0.day, $0.release) < ($1.day, $1.release) }
        return Array(oldestFirst.prefix(Self.reportsPerSending))
    }
}

/// One release's counts on one day since the report before, as `POST …/releases/{n}/report` takes it.
struct DayReport: Encodable {
    let format = 2
    /// Whether this is the first report this phone sends for the release and day: the control plane counts a phone for each.
    let first: Bool
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
        case format, first, day, platform, os, library, outcomes, confidence, labels, sessions, crashes
        case speedMs = "speed_ms"
    }

    init(day: Int, first: Bool, counts: DayCounts) {
        self.day = UTCDay.text(day)
        self.first = first
        outcomes = counts.outcomes
        confidence = counts.confidence
        labels = counts.labels
        speedMs = counts.speedMs
        sessions = counts.sessions
        crashes = counts.crashes
    }
}
