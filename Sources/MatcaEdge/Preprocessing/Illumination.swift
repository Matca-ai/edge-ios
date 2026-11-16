import Accelerate
import Foundation

/// Below this spread between the two percentiles there is nothing to stretch (the trainer's `FLAT_CONTRAST`).
private let flatContrast = 1e-6

/// Rec. 601 luma divided by a Gaussian estimate of the illumination, stretched between two percentiles to
/// 8-bit grey, optionally smoothed with [1 2 1]/4: the trainer's `illumination_normalised`, in its arithmetic.
func illuminationNormalised(_ picture: RGBPicture, settings: IlluminationSettings) throws -> RGBPicture {
    let width = picture.width, height = picture.height
    let luma = picture.luma()
    let sigma = settings.sigmaPercent / 100 * Double(min(width, height))
    let field = separableFilter(luma, width: width, height: height, kernel: gaussianKernel(sigma: sigma))
    var flat = [Float](repeating: 0, count: luma.count)
    for index in 0..<flat.count {
        flat[index] = luma[index] / (field[index] + 1)
    }
    let low = percentile(of: flat, settings.percentileLow)
    let high = percentile(of: flat, settings.percentileHigh)
    guard high - low > flatContrast else { throw EdgeError.uniformPicture }
    var stretched = flat.map { min(max((Double($0) - low) / (high - low) * 255, 0), 255) }
    if settings.smoothing {
        stretched = smoothed(stretched, width: width, height: height)
    }
    return RGBPicture.grey(width: width, height: height, values: stretched.map { UInt8($0) })
}

/// Truncated at 4 sigma as SciPy does, leaving under 1e-4 of the mass outside the window.
func gaussianKernel(sigma: Double) -> [Float] {
    let radius = max(1, Int((4 * sigma).rounded(.up)))
    let variance = Float(2 * sigma * sigma)
    let kernel = (-radius...radius).map { offset in expf(-Float(offset * offset) / variance) }
    let sum = kernel.reduce(0, +)
    return kernel.map { $0 / sum }
}

/// The linear-interpolated percentile numpy takes by default.
func percentile(of values: [Float], _ percent: Double) -> Double {
    let sorted = values.sorted()
    let position = percent / 100 * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let fraction = position - Double(lower)
    return Double(sorted[lower]) + fraction * (Double(sorted[upper]) - Double(sorted[lower]))
}

/// The kernel along each axis in turn, edges extended.
func separableFilter(_ plane: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
    let rows = convolvedRows(plane, width: width, height: height, kernel: kernel)
    let columns = convolvedRows(transposed(rows, width: width, height: height), width: height, height: width, kernel: kernel)
    return transposed(columns, width: height, height: width)
}

private func convolvedRows(_ plane: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
    let radius = kernel.count / 2
    var padded = [Float](repeating: 0, count: width + 2 * radius)
    var out = [Float](repeating: 0, count: width * height)
    out.withUnsafeMutableBufferPointer { outBuffer in
        for y in 0..<height {
            let row = plane[y * width..<(y + 1) * width]
            padded.replaceSubrange(radius..<radius + width, with: row)
            padded.replaceSubrange(0..<radius, with: repeatElement(row.first ?? 0, count: radius))
            padded.replaceSubrange(radius + width..<padded.count, with: repeatElement(row.last ?? 0, count: radius))
            vDSP_conv(padded, 1, kernel, 1, outBuffer.baseAddress! + y * width, 1, vDSP_Length(width), vDSP_Length(kernel.count))
        }
    }
    return out
}

private func transposed(_ plane: [Float], width: Int, height: Int) -> [Float] {
    var out = [Float](repeating: 0, count: plane.count)
    for y in 0..<height {
        for x in 0..<width {
            out[x * height + y] = plane[y * width + x]
        }
    }
    return out
}

/// [1 2 1] / 4 along each axis, edges extended, in double precision as numpy carries the stretched plane.
private func smoothed(_ plane: [Double], width: Int, height: Int) -> [Double] {
    var rows = plane
    for y in 0..<height {
        for x in 0..<width {
            let left = plane[y * width + max(x - 1, 0)], right = plane[y * width + min(x + 1, width - 1)]
            rows[y * width + x] = 0.25 * left + 0.5 * plane[y * width + x] + 0.25 * right
        }
    }
    var out = rows
    for y in 0..<height {
        for x in 0..<width {
            let above = rows[max(y - 1, 0) * width + x], below = rows[min(y + 1, height - 1) * width + x]
            out[y * width + x] = 0.25 * above + 0.5 * rows[y * width + x] + 0.25 * below
        }
    }
    return out
}
