import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 5: the stability detector, the black screen, the warm-up, the gate and the agreement.
final class WatchTests: XCTestCase {
    private final class Answers: @unchecked Sendable {
        var queued: [(String, Double)]
        var classified = 0
        init(_ queued: [(String, Double)]) { self.queued = queued }
    }

    func testTheWarmUpDropsTheFirstAnswersThenSaysReadyAndAgreesFourTimesAtTheStart() async throws {
        let answers = Answers(Array(repeating: ("With Cap", 0.99), count: 12))
        let states = await collect(watch(answers).states(of: greyFrames(200, count: 12, every: 0.3)))
        XCTAssertEqual(states, [.ready, .label("With Cap", confidence: 0.99, release: 1)])
        XCTAssertEqual(answers.classified, 12)
    }

    func testReadyComesOnTheLastOfTheIgnoredAnswers() async throws {
        let threeAnswers = watch(Answers(Array(repeating: ("A", 0.99), count: 3)))
        let afterThree = await collect(threeAnswers.states(of: greyFrames(200, count: 3, every: 0.3)))
        XCTAssertEqual(afterThree, [])
        let fourAnswers = watch(Answers(Array(repeating: ("A", 0.99), count: 4)))
        let afterFour = await collect(fourAnswers.states(of: greyFrames(200, count: 4, every: 0.3)))
        XCTAssertEqual(afterFour, [.ready])
    }

    func testAFrameWithNoAnswerIsDroppedAndTheWatchGoesOn() async throws {
        final class Unanswered: @unchecked Sendable { var left = 3 }
        let unanswered = Unanswered()
        var watch = Watch { _ in
            if unanswered.left > 0 {
                unanswered.left -= 1
                throw EdgeError.noModel
            }
            return try Answer(scores: ["A": 0.99, "other": 0.01], release: 1)
        }
        watch.ignoreFirstAnswers = 0
        watch.agreementAtStart = 1
        let states = await collect(watch.states(of: greyFrames(200, count: 4, every: 0.3)))
        XCTAssertEqual(states, [.ready, .label("A", confidence: 0.99, release: 1)])
    }

    func testAnUndecodableFrameIsDroppedAndTheWatchGoesOn() async throws {
        var watch = watch(Answers([("A", 0.99)]))
        watch.ignoreFirstAnswers = 0
        watch.agreementAtStart = 1
        let frames = [Frame(jpeg: Data([1, 2, 3]), at: 0), Frame(image: solidGreyImage(200), at: 0.3)]
        let states = await collect(watch.states(of: MatcaEdgeTests.frames(frames)))
        XCTAssertEqual(states, [.ready, .label("A", confidence: 0.99, release: 1)])
    }

    func testOnlyAChangeOfLabelIsReportedAfterThreeAgreeingAnswers() async throws {
        let sequence: [(String, Double)] = [("A", 0.99), ("A", 0.99), ("B", 0.99), ("B", 0.99), ("A", 0.99), ("B", 0.99), ("B", 0.99), ("B", 0.99), ("B", 0.99)]
        var watch = watch(Answers(sequence))
        watch.ignoreFirstAnswers = 0
        watch.agreementAtStart = 2
        watch.agreement = 3
        let states = await collect(watch.states(of: greyFrames(200, count: sequence.count, every: 0.3)))
        XCTAssertEqual(states, [.ready, .label("A", confidence: 0.99, release: 1), .label("B", confidence: 0.99, release: 1)])
    }

    func testAnAnswerBelowTheGateIsDropped() async throws {
        var watch = watch(Answers([("A", 0.5), ("A", 0.949), ("A", 0.95)]))
        watch.ignoreFirstAnswers = 0
        watch.agreementAtStart = 1
        let states = await collect(watch.states(of: greyFrames(200, count: 3, every: 0.3)))
        XCTAssertEqual(states, [.ready, .label("A", confidence: 0.95, release: 1)])
    }

    func testFramesInsideTheIntervalAreDropped() async throws {
        let answers = Answers(Array(repeating: ("A", 0.99), count: 10))
        let frames = (0..<10).map { Frame(image: solidGreyImage(200), at: Double($0) * 0.1) }
        _ = await collect(watch(answers).states(of: MatcaEdgeTests.frames(frames)))
        XCTAssertEqual(answers.classified, 4)
    }

    func testClassificationWaitsForTwelveStableFrames() async throws {
        let answers = Answers(Array(repeating: ("A", 0.99), count: 20))
        var watch = watch(answers)
        watch.waitForStablePicture = true
        _ = await collect(watch.states(of: greyFrames(200, count: 20, every: 0.3)))
        XCTAssertEqual(answers.classified, 20 - 12)
    }

    func testTheWaitForASteadyPictureSeesEveryFrameNotOnlyThePacedOnes() async throws {
        // A camera at 15 frames a second: the picture settles on its 13th frame (0.8 s), which is answered at once;
        // the next answer would be due 0.25 s later, after the last frame here.
        let answers = Answers(Array(repeating: ("A", 0.99), count: 15))
        var watch = watch(answers)
        watch.waitForStablePicture = true
        _ = await collect(watch.states(of: greyFrames(200, count: 15, every: 1.0 / 15)))
        XCTAssertEqual(answers.classified, 1)
    }

    func testADarkPictureNeverStabilisesUntilTheTimeout() async throws {
        let answers = Answers(Array(repeating: ("A", 0.99), count: 20))
        var watch = watch(answers)
        watch.waitForStablePicture = true
        _ = await collect(watch.states(of: greyFrames(50, count: 20, every: 0.3)))
        XCTAssertEqual(answers.classified, 20 - 14)
    }

    func testADarkSteadyPictureSettlesWhenTheAppAllowsDarkness() async throws {
        let answers = Answers(Array(repeating: ("A", 0.99), count: 20))
        var watch = watch(answers)
        watch.waitForStablePicture = true
        watch.stablePictureMinimumBrightness = 0
        _ = await collect(watch.states(of: greyFrames(50, count: 20, every: 0.3)))
        XCTAssertEqual(answers.classified, 20 - 12, "as soon as a bright picture would, not after the timeout")
    }

    func testTheAppSetsTheWaitsTimeoutAndItsSteadyFrames() async throws {
        let darkAnswers = Answers(Array(repeating: ("A", 0.99), count: 20))
        var shortWait = watch(darkAnswers)
        shortWait.waitForStablePicture = true
        shortWait.stablePictureTimeout = 1
        _ = await collect(shortWait.states(of: greyFrames(50, count: 20, every: 0.3)))
        XCTAssertEqual(darkAnswers.classified, 20 - 4, "the frame at 1.2 s ends a 1 s wait")
        let brightAnswers = Answers(Array(repeating: ("A", 0.99), count: 20))
        var fewFrames = watch(brightAnswers)
        fewFrames.waitForStablePicture = true
        fewFrames.stablePictureFrames = 3
        _ = await collect(fewFrames.states(of: greyFrames(200, count: 20, every: 0.3)))
        XCTAssertEqual(brightAnswers.classified, 20 - 3)
    }

    func testTheStabilityDetectorResetsOnAChangedFrame() {
        var detector = FrameStabilityDetector()
        let bright = FrameThumbnail(of: RGBPicture.grey(width: 64, height: 64, values: [UInt8](repeating: 200, count: 64 * 64)))
        let other = FrameThumbnail(of: RGBPicture.grey(width: 64, height: 64, values: [UInt8](repeating: 150, count: 64 * 64)))
        for frame in 0..<12 {
            XCTAssertFalse(detector.isStable(after: bright, at: Double(frame) * 0.3))
        }
        XCTAssertFalse(detector.isStable(after: other, at: 3.6))
        XCTAssertFalse(detector.isStable(after: bright, at: 3.7))
        XCTAssertTrue(detector.isStable(after: bright, at: 4.0))
    }

    func testSixDarkFramesAfterTheGraceMeanABlackScreenAndEndTheWatch() async throws {
        let answers = Answers(Array(repeating: ("A", 0.99), count: 30))
        var watch = watch(answers)
        watch.detectBlackScreen = true
        watch.ignoreFirstAnswers = 100
        let states = await collect(watch.states(of: greyFrames(0, count: 30, every: 0.3)))
        XCTAssertEqual(states, [.blackScreen])
        // Frames at 0 to 1.8 s run before the grace; the six from 2.1 s end the watch.
        XCTAssertEqual(answers.classified, 7 + 5)
    }

    func testTheThumbnailKeepsLumaAsFloatSoAFractionOverTheLimitIsNotDark() {
        // Rec. 601 of (6, 5, 5) is 5.299: truncated to a byte it would read as dark.
        let pixels = (0..<64 * 64 * 3).map { UInt8($0 % 3 == 0 ? 6 : 5) }
        let thumbnail = FrameThumbnail(of: RGBPicture(width: 64, height: 64, pixels: pixels))
        XCTAssertEqual(thumbnail.brightness, 5.299, accuracy: 0.001)
        var detector = BlackScreenDetector()
        XCTAssertFalse((0...20).map { detector.isBlack(after: thumbnail, at: Double($0) * 0.25) }.contains(true))
    }

    func testABrightFrameBreaksTheDarkRun() {
        var detector = BlackScreenDetector()
        let dark = FrameThumbnail(of: RGBPicture.grey(width: 8, height: 8, values: [UInt8](repeating: 3, count: 64)))
        let bright = FrameThumbnail(of: RGBPicture.grey(width: 8, height: 8, values: [UInt8](repeating: 60, count: 64)))
        XCTAssertFalse(detector.isBlack(after: dark, at: 0))
        for frame in 0..<5 {
            XCTAssertFalse(detector.isBlack(after: dark, at: 2 + Double(frame) * 0.3))
        }
        XCTAssertFalse(detector.isBlack(after: bright, at: 3.5))
        for frame in 0..<5 {
            XCTAssertFalse(detector.isBlack(after: dark, at: 3.8 + Double(frame) * 0.3))
        }
        XCTAssertTrue(detector.isBlack(after: dark, at: 5.3))
    }

    private func watch(_ answers: Answers) -> Watch {
        Watch { _ in
            answers.classified += 1
            let (label, confidence) = answers.queued.removeFirst()
            return try Answer(scores: [label: confidence, "other": 1 - confidence], release: 1)
        }
    }

    private func greyFrames(_ value: UInt8, count: Int, every interval: TimeInterval) -> AsyncStream<Frame> {
        frames((0..<count).map { Frame(image: solidGreyImage(value), at: Double($0) * interval) })
    }
}
