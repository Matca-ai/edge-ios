import CoreGraphics
import CoreVideo
import Foundation

public struct Answer: Sendable {
    public let label: String
    public let confidence: Double
    /// Every label with its confidence, highest first.
    public let all: [(label: String, confidence: Double)]
    public let release: Int

    init(scores: [String: Double], release: Int) throws {
        guard !scores.values.contains(where: \.isNaN) else { throw EdgeError.predictionFailed("a score is not a number") }
        let scored: [(label: String, confidence: Double)] = scores.map { (label: $0.key, confidence: $0.value) }
        let sorted = scored.sorted { first, second in
            if first.confidence == second.confidence { return first.label < second.label }
            return first.confidence > second.confidence
        }
        guard let top = sorted.first else { throw EdgeError.predictionFailed("the model answered no label") }
        label = top.label
        confidence = top.confidence
        all = sorted
        self.release = release
    }
}

/// One picture in a form the platform hands out, with the moment it was taken (a `Watch` paces by it).
public struct Frame: @unchecked Sendable {
    enum Source {
        case jpeg(Data)
        case image(CGImage, exifOrientation: Int)
        case pixelBuffer(CVPixelBuffer)
    }

    let source: Source
    public let time: TimeInterval

    public init(jpeg: Data, at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        source = .jpeg(jpeg)
        self.time = time
    }

    /// `exifOrientation` is the EXIF value 1 to 8 of the picture as the app holds it; 1 means upright.
    public init(image: CGImage, exifOrientation: Int = 1, at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        source = .image(image, exifOrientation: exifOrientation)
        self.time = time
    }

    public init(pixelBuffer: CVPixelBuffer, at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        source = .pixelBuffer(pixelBuffer)
        self.time = time
    }
}
