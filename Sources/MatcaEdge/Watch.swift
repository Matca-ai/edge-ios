import Foundation

public enum WatchState: Equatable, Sendable {
    case ready
    case blackScreen
    case label(String, confidence: Double, release: Int)
}

/// A stream of frames into a stream of states, with the app's own steps (the contract's section 7).
public struct Watch {
    public var frameInterval: TimeInterval = 0.25
    public var waitForStablePicture = false
    public var detectBlackScreen = false
    public var ignoreFirstAnswers = 4
    public var confidenceGate = 0.95
    public var agreement = 3
    public var agreementAtStart = 4

    private let classify: @Sendable (DecodedPicture) async throws -> Answer
    private let countEvent: @Sendable (WatchEvent) async -> Void

    public init(classifier: Classifier) {
        classify = { try await classifier.classify(decoded: $0) }
        countEvent = { await classifier.countWatchEvent($0) }
    }

    init(
        classify: @escaping @Sendable (DecodedPicture) async throws -> Answer,
        countEvent: @escaping @Sendable (WatchEvent) async -> Void = { _ in }
    ) {
        self.classify = classify
        self.countEvent = countEvent
    }

    public func states(of frames: AsyncStream<Frame>) -> AsyncStream<WatchState> {
        AsyncStream { continuation in
            let task = Task {
                var progress = WatchProgress()
                for await frame in frames {
                    guard !Task.isCancelled, await observe(frame, progress: &progress, into: continuation) else { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One frame through the steps; false once the watch is over.
    private func observe(_ frame: Frame, progress: inout WatchProgress, into continuation: AsyncStream<WatchState>.Continuation) async -> Bool {
        guard progress.lastClassifiedTime.map({ frame.time - $0 >= frameInterval }) ?? true else { return true }
        progress.lastClassifiedTime = frame.time
        guard let decoded = answered(progress: &progress, { try PictureDecoding.decode(frame) }) else { return true }
        if waitForStablePicture || detectBlackScreen {
            let thumbnail = FrameThumbnail(of: decoded.picture)
            if detectBlackScreen, progress.blackScreen.isBlack(after: thumbnail, at: frame.time) {
                await countEvent(.blackScreen)
                continuation.yield(.blackScreen)
                return false
            }
            if waitForStablePicture, !progress.stable {
                progress.stable = progress.stability.isStable(after: thumbnail, at: frame.time)
                guard progress.stable else { return true }
                if progress.stability.timedOut {
                    await countEvent(.noStablePicture)
                }
            }
        }
        let answer: Answer
        do {
            answer = try await classify(decoded)
        } catch {
            noteDropped(error, progress: &progress)
            return true
        }
        for state in report(answer, progress: &progress) {
            continuation.yield(state)
        }
        return true
    }

    private func answered<Value>(progress: inout WatchProgress, _ work: () throws -> Value) -> Value? {
        do {
            return try work()
        } catch {
            noteDropped(error, progress: &progress)
            return nil
        }
    }

    /// A frame that gets no answer is dropped and the watch goes on: a release may still be on its way.
    private func noteDropped(_ error: Error, progress: inout WatchProgress) {
        let failure = describe(error)
        if failure != progress.lastFailure {
            log.warning("a frame was dropped: \(failure, privacy: .public)")
        }
        progress.lastFailure = failure
    }

    /// The warm-up, the gate and the agreement for one answer.
    private func report(_ answer: Answer, progress: inout WatchProgress) -> [WatchState] {
        progress.answersSeen += 1
        var states: [WatchState] = []
        if !progress.readySent, progress.answersSeen >= ignoreFirstAnswers {
            progress.readySent = true
            states.append(.ready)
        }
        guard progress.answersSeen > ignoreFirstAnswers, answer.confidence >= confidenceGate else { return states }
        progress.runCount = answer.label == progress.runLabel ? progress.runCount + 1 : 1
        progress.runLabel = answer.label
        let needed = progress.reportedLabel == nil ? agreementAtStart : agreement
        if progress.runCount >= needed, answer.label != progress.reportedLabel {
            progress.reportedLabel = answer.label
            states.append(.label(answer.label, confidence: answer.confidence, release: answer.release))
        }
        return states
    }
}

private struct WatchProgress {
    var lastClassifiedTime: TimeInterval?
    var stability = FrameStabilityDetector()
    var blackScreen = BlackScreenDetector()
    var stable = false
    var answersSeen = 0
    var readySent = false
    var runLabel: String?
    var runCount = 0
    var reportedLabel: String?
    var lastFailure: String?
}
