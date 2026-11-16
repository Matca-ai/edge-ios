import Foundation

/// What one release did on one UTC day on this phone (the contract's section 11), named as the report names it.
struct DayCounts: Codable, Equatable, Sendable {
    struct Outcomes: Codable, Equatable, Sendable {
        var answered = 0
        var belowGate = 0
        var failed = 0
        var noStablePicture = 0
        var blackScreen = 0

        enum CodingKeys: String, CodingKey {
            case answered, failed
            case belowGate = "below_gate"
            case noStablePicture = "no_stable_picture"
            case blackScreen = "black_screen"
        }
    }

    struct Speeds: Codable, Equatable, Sendable {
        var preprocessing = DayCounts.emptySteps
        var model = DayCounts.emptySteps
    }

    /// The trainer's gate thresholds (`score.py`, `GATES`), so the field's curve lies on the test's own.
    static let confidenceThresholds = [0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.92, 0.95, 0.97, 0.98, 0.99]
    static let millisecondThresholds: [Double] = [10, 20, 30, 50, 75, 100, 150, 200, 300, 500, 1000]
    /// The gate the trainer scores against: an answer at or above it counts as answered.
    static let answeredGate = 0.95
    private static let stepCount = 12
    private static let emptySteps = [Int](repeating: 0, count: stepCount)

    var outcomes = Outcomes()
    var confidence = emptySteps
    var labels: [String: Int] = [:]
    var speedMs = Speeds()
    var sessions = 0
    var crashes = 0

    enum CodingKeys: String, CodingKey {
        case outcomes, confidence, labels, sessions, crashes
        case speedMs = "speed_ms"
    }

    /// A file that decodes may still hold lists of another length, which counting would index past.
    var isWellFormed: Bool {
        [confidence, speedMs.preprocessing, speedMs.model].allSatisfy { $0.count == Self.stepCount }
    }

    mutating func countAnswer(label: String, confidence answerConfidence: Double, preprocessingMilliseconds: Double, modelMilliseconds: Double) {
        if answerConfidence >= Self.answeredGate {
            outcomes.answered += 1
        } else {
            outcomes.belowGate += 1
        }
        confidence[Self.step(of: answerConfidence, thresholds: Self.confidenceThresholds)] += 1
        labels[label, default: 0] += 1
        speedMs.preprocessing[Self.step(of: preprocessingMilliseconds, thresholds: Self.millisecondThresholds)] += 1
        speedMs.model[Self.step(of: modelMilliseconds, thresholds: Self.millisecondThresholds)] += 1
    }

    /// Below the first threshold is step 0; at or above the last, the final step. A binary search, as it runs
    /// three times for every answer.
    static func step(of value: Double, thresholds: [Double]) -> Int {
        var low = 0
        var high = thresholds.count
        while low < high {
            let middle = (low + high) / 2
            if value < thresholds[middle] {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// Counts made while a report of the same day was on its way, put together with that report when it is kept.
    mutating func add(_ other: DayCounts) {
        outcomes.answered += other.outcomes.answered
        outcomes.belowGate += other.outcomes.belowGate
        outcomes.failed += other.outcomes.failed
        outcomes.noStablePicture += other.outcomes.noStablePicture
        outcomes.blackScreen += other.outcomes.blackScreen
        confidence = zip(confidence, other.confidence).map(+)
        labels.merge(other.labels, uniquingKeysWith: +)
        speedMs.preprocessing = zip(speedMs.preprocessing, other.speedMs.preprocessing).map(+)
        speedMs.model = zip(speedMs.model, other.speedMs.model).map(+)
        sessions += other.sessions
        crashes += other.crashes
    }
}
