import CoreGraphics
import CoreVideo
import Foundation
import os

private let longestCheckInterval: TimeInterval = 1_000_000_000
/// While no release is on the phone, the automatic asks come this long after one another, the last repeating: a first
/// launch without network, or before the first release, takes the model minutes after it can, not a check interval.
let asksWithoutModel: [TimeInterval] = [5, 15, 30, 60, 300]

/// One device model on this phone: the newest verified release, kept up to date (the contract's section 1).
public actor Classifier {
    public nonisolated let model: String
    public nonisolated let configuration: EdgeConfiguration
    public private(set) var preprocessing = PreprocessingOverrides()

    public var currentRelease: Int? { current?.release }

    private let store: ModelStore
    private let delivery: any Delivery
    private let installer: ReleaseInstaller
    private let clock: MonitoringClock
    private var monitoring: Monitoring?
    private var current: LoadedRelease?
    private var localStartup: Task<Void, Never>?
    private var runningCheck: Task<Void, Error>?
    private var sendingReports: Task<Void, Never>?
    private var overridesLogged: Set<String> = []
    private let retryDelays: [TimeInterval]
    private var retriesWithoutModel = 0
    private var lastCheckFailure: Error?
    private var readyWaiters: [UUID: CheckedContinuation<Int, Error>] = [:]

    public init(model: String, configuration: EdgeConfiguration) throws {
        try self.init(
            model: model, configuration: configuration, session: EdgeDelivery.makeSession(),
            loader: CoreMLModelLoader(), storeDirectory: ModelStore.defaultDirectory(model: model),
            crashReports: systemCrashReports(), clock: MonitoringClock()
        )
    }

    init(
        model: String, configuration: EdgeConfiguration, session: URLSession, loader: any ModelLoader, storeDirectory: URL,
        crashReports: any CrashReportSource, clock: MonitoringClock, retryDelays: [TimeInterval] = asksWithoutModel
    ) throws {
        guard Self.isValidModelName(model) else { throw EdgeError.invalidModelName }
        self.model = model
        self.retryDelays = retryDelays.isEmpty ? asksWithoutModel : retryDelays
        self.configuration = configuration
        store = try ModelStore(directory: storeDirectory)
        delivery = EdgeDelivery(model: model, configuration: configuration, session: session)
        installer = ReleaseInstaller(model: model, configuration: configuration, store: store, delivery: delivery, loader: loader)
        self.clock = clock
        let monitoringFile = MonitoringFile(directory: storeDirectory)
        if configuration.monitoring {
            monitoring = Monitoring(file: monitoringFile, clock: clock)
            crashReports.listen(for: self) { [weak self] reports in await self?.countCrashes(reports) }
        } else {
            monitoringFile.deleteAll()
        }
        Task { await self.firstAutomaticCheck() }
    }

    /// The model name forms URLs and a directory: a DNS label, as the control plane names models.
    nonisolated static func isValidModelName(_ model: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return !model.isEmpty && model.count <= 63 && model.allSatisfy(allowed.contains) && !model.hasPrefix("-")
    }

    public func setPreprocessing(_ overrides: PreprocessingOverrides) {
        preprocessing = overrides
    }

    public func classify(_ jpeg: Data) async throws -> Answer {
        try await classify(Frame(jpeg: jpeg))
    }

    public func classify(_ image: CGImage, exifOrientation: Int = 1) async throws -> Answer {
        try await classify(Frame(image: image, exifOrientation: exifOrientation))
    }

    public func classify(_ pixelBuffer: CVPixelBuffer) async throws -> Answer {
        try await classify(Frame(pixelBuffer: pixelBuffer))
    }

    public func classify(_ frame: Frame) async throws -> Answer {
        let decoded: DecodedPicture
        do {
            decoded = try PictureDecoding.decode(frame)
        } catch {
            if let release = await loadedRelease() {
                monitoring?.countFailure(release: release)
                startSendingReportsIfDue()
            }
            throw error
        }
        return try await classify(decoded: decoded)
    }

    func classify(decoded: DecodedPicture) async throws -> Answer {
        await loadLocalReleases()
        guard let current else { throw EdgeError.noModel }
        defer { startSendingReportsIfDue() }
        do {
            return try answer(decoded, by: current)
        } catch {
            monitoring?.countFailure(release: current.release)
            throw error
        }
    }

    func countWatchEvent(_ event: WatchEvent) async {
        if let release = await loadedRelease() {
            monitoring?.count(event, release: release)
        }
    }

    /// Preprocessing runs from the picture handed in, its decoding included, to the pixels the model gets; the
    /// wait for the release on disk to load is not part of it.
    private func answer(_ decoded: DecodedPicture, by release: LoadedRelease) throws -> Answer {
        let preparing = clock.uptimeNanoseconds()
        let (steps, overridden) = preprocessing.applied(to: release.manifest.preprocessing)
        logOverrides(overridden)
        let prepared = try Preprocessor.prepare(decoded, steps: steps, input: release.manifest.input)
        let predicting = clock.uptimeNanoseconds()
        let scores = try release.runner.predict(prepared)
        let predicted = clock.uptimeNanoseconds()
        let answer = try Answer(scores: scores, release: release.release)
        monitoring?.countAnswer(
            answer, preprocessingNanoseconds: decoded.decodingNanoseconds + predicting - preparing, modelNanoseconds: predicted - predicting
        )
        return answer
    }

    private func loadedRelease() async -> Int? {
        await loadLocalReleases()
        return current?.release
    }

    /// Asks the edge now; a check already running is awaited instead of doubled. A failure of any kind
    /// leaves the current model working and is thrown as an `EdgeError` so the app can see why.
    public func checkForUpdates() async throws {
        await loadLocalReleases()
        monitoring?.write()
        do {
            try await runCheck()
            lastCheckFailure = nil
        } catch {
            lastCheckFailure = error
            throw error
        }
    }

    private func runCheck() async throws {
        if let running = runningCheck {
            return try await running.value
        }
        let check = Task { try await self.takeEdgeRelease() }
        runningCheck = check
        defer { runningCheck = nil }
        try await check.value
    }

    /// The release on the phone, once there is one: at once when it is there, else as soon as an ask of the edge
    /// brings one (this call asks at once, and the automatic asks come quickly while there is none). Past the timeout
    /// it throws why none came, the last check's failure or `EdgeError.noModel`; the asks go on after it.
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval = 60) async throws -> Int {
        if let release = await loadedRelease() { return release }
        try? await checkForUpdates()
        if let release = current?.release { return release }
        let waiter = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            Task { self.wait(waiter, continuation, timeout: timeout) }
        }
    }

    private func wait(_ waiter: UUID, _ continuation: CheckedContinuation<Int, Error>, timeout: TimeInterval) {
        if let release = current?.release {
            return continuation.resume(returning: release)
        }
        readyWaiters[waiter] = continuation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            await self?.giveUp(waiter)
        }
    }

    private func giveUp(_ waiter: UUID) {
        readyWaiters.removeValue(forKey: waiter)?.resume(throwing: lastCheckFailure ?? EdgeError.noModel)
    }

    /// The release on disk and the bundled one, once, before the first classification or check.
    private func loadLocalReleases() async {
        if localStartup == nil {
            localStartup = Task {
                self.reloadCurrentRelease()
                if let bundle = self.configuration.bundledRelease {
                    await self.takeBundledRelease(at: bundle)
                }
            }
        }
        await localStartup?.value
    }

    private func reloadCurrentRelease() {
        guard let release = store.loadOrCreateState().currentRelease else { return }
        let releaseURL = store.releaseDirectory(release)
        do {
            guard let text = store.readManifestText(in: releaseURL) else { throw EdgeError.storage("no manifest kept for release \(release)") }
            let manifest = try Manifest.parse(Data(text.utf8))
            use(LoadedRelease(release: release, manifest: manifest, runner: try installer.loader.load(releaseDirectory: releaseURL, manifest: manifest)))
        } catch {
            log.error("release \(release) could not be reloaded: \(describe(error), privacy: .public)")
        }
    }

    private func takeBundledRelease(at bundle: URL) async {
        do {
            let data = try Data(contentsOf: bundle.appendingPathComponent(ReleaseInstaller.bundledManifestFileName))
            try await take(try JSONDecoder().decode(SignedManifest.self, from: data), bundledAt: bundle)
        } catch {
            log.warning("the bundled release was not taken: \(describe(error), privacy: .public)")
        }
    }

    private func firstAutomaticCheck() async {
        await loadLocalReleases()
        await automaticCheck()
    }

    /// Step 1's cadence: once now, then once every `checkInterval` for as long as the classifier lives; quickly,
    /// by `retryDelays`, while no release is on the phone.
    private func automaticCheck() async {
        do {
            try await checkForUpdates()
        } catch {
            log.warning("no new release taken: \(describe(error), privacy: .public)")
        }
        let nanoseconds: UInt64
        if current == nil {
            let delay = retryDelays[min(retriesWithoutModel, retryDelays.count - 1)]
            retriesWithoutModel += 1
            nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        } else {
            nanoseconds = Self.nanosecondsToSleep(configuration.checkInterval)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.automaticCheck()
        }
    }

    /// At least a second, and any interval an app may write, `.infinity` too, fits the sleep's integer.
    nonisolated static func nanosecondsToSleep(_ interval: TimeInterval) -> UInt64 {
        UInt64((interval >= 1 ? min(interval, longestCheckInterval) : 1) * 1_000_000_000)
    }

    /// The reports go after any manifest ask the edge answered, whatever it said.
    private func takeEdgeRelease() async throws {
        let signed: SignedManifest
        do {
            signed = try await delivery.manifest()
        } catch {
            if error as? EdgeError != .edge(status: 0) {
                startSendingReports()
            }
            throw error
        }
        startSendingReports()
        try await take(signed, bundledAt: nil)
    }

    /// Steps 2 to 8 for one signed manifest, from the edge or from the app's bundle.
    private func take(_ signed: SignedManifest, bundledAt bundle: URL?) async throws {
        let manifest = try ManifestVerification.verify(signed, rootPublicKey: configuration.rootPublicKey)
        switch try installer.decide(manifest, state: store.loadOrCreateState(), runningRelease: current?.release) {
        case .skip(let reason):
            log.info("release \(manifest.release) skipped: \(reason, privacy: .public)")
            return
        case .rememberAndSkip(let reason):
            log.info("release \(manifest.release) skipped: \(reason, privacy: .public)")
            try store.rememberSequence(manifest.sequence)
            return
        case .take:
            break
        }
        let releaseURL: URL
        if let bundle {
            releaseURL = try await installer.copyBundled(manifest, from: bundle)
        } else {
            releaseURL = try await installer.download(manifest)
        }
        let loaded: LoadedRelease
        do {
            loaded = try await installer.loadAndCheck(manifest, in: releaseURL)
            try store.switchTo(release: manifest.release, sequence: manifest.sequence, manifestText: signed.manifest)
        } catch {
            store.removeRelease(manifest.release)
            if case EdgeError.referenceCheckFailed = error, bundle == nil {
                try? await delivery.count(.failedChecks, release: manifest.release)
            }
            throw error
        }
        use(loaded)
        if bundle == nil {
            try? await delivery.count(.installs, release: manifest.release)
        }
    }

    private func use(_ loaded: LoadedRelease) {
        current = loaded
        monitoring?.startSession(release: loaded.release)
        let waiters = readyWaiters.values
        readyWaiters = [:]
        for waiter in waiters {
            waiter.resume(returning: loaded.release)
        }
    }

    private func logOverrides(_ overridden: [String]) {
        for step in overridden where overridesLogged.insert(step).inserted {
            log.warning("the app overrides \(step, privacy: .public): pictures differ from what the model learned with")
        }
    }

    private func countCrashes(_ reports: [CrashReport]) {
        monitoring?.countCrashes(reports)
    }

    /// The console shows a release within minutes: the counts also go while the classifier answers, not only after a check.
    private func startSendingReportsIfDue() {
        if monitoring?.isSendingDue == true {
            startSendingReports()
        }
    }

    /// Runs off the path of the check or the classification that starts it; a sending already under way finishes first.
    private func startSendingReports() {
        guard monitoring != nil else { return }
        monitoring?.sendingStarted()
        let previous = sendingReports
        sendingReports = Task {
            await previous?.value
            await self.sendReports()
        }
    }

    /// The tests read what was kept and sent once no report is on its way.
    func waitForReportsOnTheirWay() async {
        await sendingReports?.value
    }

    private func sendReports() async {
        guard let due = monitoring?.reportsDue() else { return }
        for key in due {
            guard let counts = monitoring?.takeOut(key) else { continue }
            let report = DayReport(day: key.day, first: monitoring?.hasReported(key) != true, counts: counts)
            guard let body = try? JSONEncoder().encode(report) else { continue }
            do {
                try await delivery.report(body, release: key.release)
                monitoring?.rememberReported(key)
            } catch let error where Self.keepsReport(after: error) {
                monitoring?.putBack(counts, at: key)
                break
            } catch {
                log.info("the report of release \(key.release) was refused: \(describe(error), privacy: .public)")
            }
        }
        monitoring?.write()
    }

    private static let refusedReportStatuses: Set<Int> = [400, 401, 404, 413]

    /// A refusal is final; anything else may pass at a later sending, within the days a report is kept.
    private static func keepsReport(after error: Error) -> Bool {
        guard case EdgeError.edge(let status) = error else { return true }
        return !refusedReportStatuses.contains(status)
    }
}
