import Foundation

/// A picture as the steps work on it: interleaved RGB bytes, rows from the top, no padding.
struct RGBPicture: Equatable, Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3, "an RGB picture holds three bytes per pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func offset(x: Int, y: Int) -> Int {
        (y * width + x) * 3
    }

    func cropped(left: Int, top: Int, width croppedWidth: Int, height croppedHeight: Int) -> RGBPicture {
        var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight * 3)
        let rowBytes = croppedWidth * 3
        for row in 0..<croppedHeight {
            let source = offset(x: left, y: top + row)
            cropped.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: pixels[source..<source + rowBytes])
        }
        return RGBPicture(width: croppedWidth, height: croppedHeight, pixels: cropped)
    }

    /// Rec. 601 luma, as the trainer computes it in single precision.
    func luma() -> [Float] {
        var luma = [Float](repeating: 0, count: width * height)
        for index in 0..<luma.count {
            let source = index * 3
            luma[index] = 0.299 * Float(pixels[source]) + 0.587 * Float(pixels[source + 1]) + 0.114 * Float(pixels[source + 2])
        }
        return luma
    }

    static func grey(width: Int, height: Int, values: [UInt8]) -> RGBPicture {
        var pixels = [UInt8](repeating: 0, count: values.count * 3)
        for (index, value) in values.enumerated() {
            pixels[index * 3] = value
            pixels[index * 3 + 1] = value
            pixels[index * 3 + 2] = value
        }
        return RGBPicture(width: width, height: height, pixels: pixels)
    }
}
