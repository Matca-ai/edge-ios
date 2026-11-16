import Foundation

/// Bilinear resize as Pillow does it: a triangle filter whose support widens when the picture shrinks, so
/// it averages rather than skips; rows first, then columns, each pass rounded to bytes.
func resizeBilinear(_ picture: RGBPicture, toWidth width: Int, height: Int) -> RGBPicture {
    let rows = resampled(picture, axis: .horizontal, to: width)
    return resampled(rows, axis: .vertical, to: height)
}

private enum Axis {
    case horizontal, vertical
}

private struct Taps {
    let start: Int
    let weights: [Double]
}

private func resampled(_ picture: RGBPicture, axis: Axis, to size: Int) -> RGBPicture {
    let width = axis == .horizontal ? size : picture.width
    let height = axis == .vertical ? size : picture.height
    let taps = tapsOfEachOutput(inputSize: axis == .horizontal ? picture.width : picture.height, outputSize: size)
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let tap = taps[axis == .horizontal ? x : y]
            for channel in 0..<3 {
                var sum = 0.0
                for (index, weight) in tap.weights.enumerated() {
                    let sourceX = axis == .horizontal ? tap.start + index : x
                    let sourceY = axis == .vertical ? tap.start + index : y
                    sum += weight * Double(picture.pixels[picture.offset(x: sourceX, y: sourceY) + channel])
                }
                pixels[(y * width + x) * 3 + channel] = UInt8(min(max((sum + 0.5).rounded(.down), 0), 255))
            }
        }
    }
    return RGBPicture(width: width, height: height, pixels: pixels)
}

/// Pillow's `precompute_coeffs` for its bilinear filter (support 1, scaled when shrinking).
private func tapsOfEachOutput(inputSize: Int, outputSize: Int) -> [Taps] {
    let scale = Double(inputSize) / Double(outputSize)
    let filterScale = max(scale, 1)
    let support = filterScale
    return (0..<outputSize).map { output in
        let centre = (Double(output) + 0.5) * scale
        let start = max(Int(centre - support + 0.5), 0)
        let end = min(Int(centre + support + 0.5), inputSize)
        var weights = (start..<end).map { max(1 - abs((Double($0) - centre + 0.5) / filterScale), 0) }
        let total = weights.reduce(0, +)
        if total != 0 {
            weights = weights.map { $0 / total }
        }
        return Taps(start: start, weights: weights)
    }
}
