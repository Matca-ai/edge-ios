import Accelerate
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

/// One pass along an axis. The sums run in Accelerate's vector routines, one call per tap over a whole column or row,
/// so the pass costs the same in a Debug build as in an optimised one; the taps and the rounding are Pillow's.
private func resampled(_ picture: RGBPicture, axis: Axis, to size: Int) -> RGBPicture {
    let width = axis == .horizontal ? size : picture.width
    let height = axis == .vertical ? size : picture.height
    let taps = tapsOfEachOutput(inputSize: axis == .horizontal ? picture.width : picture.height, outputSize: size)
    var input = [Double](repeating: 0, count: picture.pixels.count)
    vDSP_vfltu8D(picture.pixels, 1, &input, 1, vDSP_Length(picture.pixels.count))
    var sums = [Double](repeating: 0, count: width * height * 3)
    input.withUnsafeBufferPointer { source in
        sums.withUnsafeMutableBufferPointer { target in
            switch axis {
            case .horizontal:
                // Each output column of a channel, down every row at once: the input strides a row, the output too.
                for (x, tap) in taps.enumerated() {
                    for (index, weight) in tap.weights.enumerated() {
                        var weight = weight
                        for channel in 0..<3 {
                            let from = source.baseAddress! + (tap.start + index) * 3 + channel
                            let to = target.baseAddress! + x * 3 + channel
                            vDSP_vsmaD(from, picture.width * 3, &weight, to, width * 3, to, width * 3, vDSP_Length(height))
                        }
                    }
                }
            case .vertical:
                // Each output row, every channel at once: the weights of a row apply alike to its bytes.
                let rowLength = width * 3
                for (y, tap) in taps.enumerated() {
                    for (index, weight) in tap.weights.enumerated() {
                        var weight = weight
                        let from = source.baseAddress! + (tap.start + index) * rowLength
                        let to = target.baseAddress! + y * rowLength
                        vDSP_vsmaD(from, 1, &weight, to, 1, to, 1, vDSP_Length(rowLength))
                    }
                }
            }
        }
    }
    return RGBPicture(width: width, height: height, pixels: roundedToBytes(sums))
}

/// Pillow's rounding of a pass: half up, then clamped to a byte.
private func roundedToBytes(_ sums: [Double]) -> [UInt8] {
    var count = Int32(sums.count)
    var half = 0.5, lowest = 0.0, highest = 255.0
    var shifted = [Double](repeating: 0, count: sums.count)
    vDSP_vsaddD(sums, 1, &half, &shifted, 1, vDSP_Length(sums.count))
    var floored = [Double](repeating: 0, count: sums.count)
    vvfloor(&floored, shifted, &count)
    vDSP_vclipD(floored, 1, &lowest, &highest, &floored, 1, vDSP_Length(sums.count))
    var bytes = [UInt8](repeating: 0, count: sums.count)
    vDSP_vfixu8D(floored, 1, &bytes, 1, vDSP_Length(sums.count))
    return bytes
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
