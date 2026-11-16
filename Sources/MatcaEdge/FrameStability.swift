import Foundation

/// A 32 × 32 grey thumbnail of a frame's centre half, Rec. 601 luma kept as float, and what the detectors read off it.
struct FrameThumbnail {
    static let side = 32

    let grey: [Float]
    let brightness: Double

    init(of picture: RGBPicture) {
        let width = max(1, picture.width / 2), height = max(1, picture.height / 2)
        let centre = picture.cropped(left: (picture.width - width) / 2, top: (picture.height - height) / 2, width: width, height: height)
        grey = resizeBilinear(centre, toWidth: Self.side, height: Self.side).luma()
        brightness = grey.reduce(0.0) { $0 + Double($1) } / Double(grey.count)
    }

    func meanAbsoluteDifference(from other: FrameThumbnail) -> Double {
        var total = 0.0
        for index in 0..<grey.count {
            total += abs(Double(grey[index]) - Double(other.grey[index]))
        }
        return total / Double(grey.count)
    }
}

/// Stable once twelve frames in a row barely differ from their predecessor, are bright enough and drift
/// little across the window; or after the timeout, when the picture is taken as it is.
struct FrameStabilityDetector {
    var framesNeeded = 12
    var differenceLimit = 2.0
    var minimumBrightness = 130.0
    var driftLimit = 1.5
    var timeout: TimeInterval = 4

    /// True once the wait ended on the timeout rather than on a stable picture.
    private(set) var timedOut = false
    private var previous: FrameThumbnail?
    private var windowBrightness: [Double] = []
    private var firstFrameTime: TimeInterval?

    mutating func isStable(after thumbnail: FrameThumbnail, at time: TimeInterval) -> Bool {
        let start = firstFrameTime ?? time
        firstFrameTime = start
        defer { previous = thumbnail }
        if time - start >= timeout {
            timedOut = true
            return true
        }
        guard let previous, thumbnail.meanAbsoluteDifference(from: previous) <= differenceLimit,
              thumbnail.brightness >= minimumBrightness
        else {
            windowBrightness = []
            return false
        }
        windowBrightness.append(thumbnail.brightness)
        guard windowBrightness.count >= framesNeeded else { return false }
        windowBrightness.removeFirst(windowBrightness.count - framesNeeded)
        return windowBrightness.max()! - windowBrightness.min()! <= driftLimit
    }
}

/// After a grace period, six dark frames in a row mean the device shows nothing.
struct BlackScreenDetector {
    var brightnessLimit = 5.0
    var framesNeeded = 6
    var grace: TimeInterval = 2

    private var darkFramesInARow = 0
    private var firstFrameTime: TimeInterval?

    mutating func isBlack(after thumbnail: FrameThumbnail, at time: TimeInterval) -> Bool {
        let start = firstFrameTime ?? time
        firstFrameTime = start
        guard time - start >= grace else { return false }
        darkFramesInARow = thumbnail.brightness <= brightnessLimit ? darkFramesInARow + 1 : 0
        return darkFramesInARow >= framesNeeded
    }
}
