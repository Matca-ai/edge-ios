import Foundation

/// Which release a process ran and since when, so the crash its successor learns of is counted against it.
struct Session: Codable, Equatable, Sendable {
    let release: Int?
    let startedAt: Date
}

/// `monitoring.json` and `session.json` in the library's own directory, which is kept out of backups. Every
/// write goes through one serial queue, off the classifications' path and in the order it was asked; a read
/// waits for the writes asked before it.
struct MonitoringFile: Sendable {
    static let countsFileName = "monitoring.json"
    static let unreadableCountsFileName = "monitoring.json.unreadable"
    static let sessionFileName = "session.json"

    private static let queue = DispatchQueue(label: "ai.matca.edge.monitoring")

    private let countsURL: URL
    private let unreadableCountsURL: URL
    private let sessionURL: URL

    init(directory: URL) {
        countsURL = directory.appendingPathComponent(Self.countsFileName)
        unreadableCountsURL = directory.appendingPathComponent(Self.unreadableCountsFileName)
        sessionURL = directory.appendingPathComponent(Self.sessionFileName)
    }

    /// The kept counts; a file that cannot be read is moved aside and counting starts afresh.
    func loadCounts() -> MonitoringCounts {
        Self.queue.sync {
            guard let data = try? Data(contentsOf: countsURL) else { return MonitoringCounts() }
            if let counts = try? JSONDecoder().decode(MonitoringCounts.self, from: data), counts.isWellFormed {
                return counts
            }
            try? FileManager.default.removeItem(at: unreadableCountsURL)
            try? FileManager.default.moveItem(at: countsURL, to: unreadableCountsURL)
            return MonitoringCounts()
        }
    }

    func writeCounts(_ counts: MonitoringCounts) {
        write(counts, to: countsURL)
    }

    func loadSession() -> Session? {
        Self.queue.sync {
            (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        }
    }

    func writeSession(_ session: Session) {
        write(session, to: sessionURL)
    }

    func deleteAll() {
        Self.queue.async { [countsURL, sessionURL] in
            try? FileManager.default.removeItem(at: countsURL)
            try? FileManager.default.removeItem(at: sessionURL)
        }
    }

    private func write<Kept: Encodable & Sendable>(_ value: Kept, to url: URL) {
        Self.queue.async {
            do {
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
            } catch {
                log.warning("monitoring counts could not be kept: \(describe(error), privacy: .public)")
            }
        }
    }
}
