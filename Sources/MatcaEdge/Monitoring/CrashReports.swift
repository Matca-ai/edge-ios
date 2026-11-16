import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// One delivery of the system's crash diagnostics: how many crashes, and when the period they cover ended.
struct CrashReport: Equatable, Sendable {
    let crashCount: Int
    let periodEnd: Date
}

/// The seam over the system's record of the app's crashes, so tests deliver their own.
protocol CrashReportSource: Sendable {
    /// Hands every later delivery to `receive` for as long as `owner` lives.
    func listen(for owner: AnyObject, _ receive: @escaping @Sendable ([CrashReport]) async -> Void)
}

func systemCrashReports() -> any CrashReportSource {
    #if canImport(MetricKit)
    MetricKitCrashReports.shared
    #else
    NoCrashReports()
    #endif
}

struct NoCrashReports: CrashReportSource {
    func listen(for owner: AnyObject, _ receive: @escaping @Sendable ([CrashReport]) async -> Void) {}
}

#if canImport(MetricKit)
/// The process's one MetricKit subscriber, added once and never removed: iOS 16.0 crashed apps whose
/// subscribers changed while MetricKit delivered (fixed in 16.1), so classifiers come and go here instead.
/// From iOS 15 MetricKit delivers a diagnostic as soon as it has one, which for a crash is in a later process.
final class MetricKitCrashReports: NSObject, MXMetricManagerSubscriber, CrashReportSource, @unchecked Sendable {
    static let shared = MetricKitCrashReports()

    private struct Listener {
        weak var owner: AnyObject?
        let receive: @Sendable ([CrashReport]) async -> Void
    }

    private let lock = NSLock()
    private var listeners: [Listener] = []
    private var subscribed = false

    func listen(for owner: AnyObject, _ receive: @escaping @Sendable ([CrashReport]) async -> Void) {
        lock.lock()
        listeners.removeAll { $0.owner == nil }
        listeners.append(Listener(owner: owner, receive: receive))
        let subscribing = !subscribed
        subscribed = true
        lock.unlock()
        if subscribing {
            MXMetricManager.shared.add(self)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.compactMap { payload -> CrashReport? in
            guard let crashes = payload.crashDiagnostics, !crashes.isEmpty else { return nil }
            return CrashReport(crashCount: crashes.count, periodEnd: payload.timeStampEnd)
        }
        guard !reports.isEmpty else { return }
        lock.lock()
        let receivers = listeners.filter { $0.owner != nil }.map(\.receive)
        lock.unlock()
        for receive in receivers {
            Task { await receive(reports) }
        }
    }
}
#endif
