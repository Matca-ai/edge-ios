import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// A picture as decoded, before any step, with the EXIF orientation that `fix_orientation` applies.
struct DecodedPicture {
    let picture: RGBPicture
    let exifOrientation: Int
    /// A frame's decoding is part of the preprocessing time the monitoring counts, whoever decodes it.
    var decodingNanoseconds: UInt64 = 0
}

enum PictureDecoding {
    /// The trainer's bound on what a crafted header may ask for.
    static let maximumPixels = 50_000_000

    static func decode(_ frame: Frame) throws -> DecodedPicture {
        let started = DispatchTime.now().uptimeNanoseconds
        var decoded = try decodeSource(of: frame)
        decoded.decodingNanoseconds = DispatchTime.now().uptimeNanoseconds - started
        return decoded
    }

    private static func decodeSource(of frame: Frame) throws -> DecodedPicture {
        switch frame.source {
        case .jpeg(let data):
            return try decode(encoded: data)
        case .image(let image, let exifOrientation):
            return DecodedPicture(picture: try rgb(of: image), exifOrientation: exifOrientation)
        case .pixelBuffer(let pixelBuffer):
            return DecodedPicture(picture: try rgb(of: pixelBuffer), exifOrientation: 1)
        }
    }

    /// JPEG or PNG bytes through ImageIO, which leaves the pixels as stored and reports the orientation apart.
    static func decode(encoded data: Data) throws -> DecodedPicture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width * height <= maximumPixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw EdgeError.undecodablePicture }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return DecodedPicture(picture: try rgb(of: image), exifOrientation: (1...8).contains(orientation) ? orientation : 1)
    }

    static func rgb(of image: CGImage) throws -> RGBPicture {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= maximumPixels else { throw EdgeError.undecodablePicture }
        // Drawing into the picture's own RGB space keeps the bytes as stored; another space would convert them.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        var rgbx = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EdgeError.undecodablePicture }
        return stripped(rgbx, width: width, height: height, order: [0, 1, 2])
    }

    static func rgb(of pixelBuffer: CVPixelBuffer) throws -> RGBPicture {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width * height <= maximumPixels else { throw EdgeError.undecodablePicture }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            return stripped(packedBytes(pixelBuffer, bytesPerPixel: 4), width: width, height: height, order: [2, 1, 0])
        case kCVPixelFormatType_32ARGB:
            return stripped(packedBytes(pixelBuffer, bytesPerPixel: 4), width: width, height: height, order: [1, 2, 3])
        case kCVPixelFormatType_32RGBA:
            return stripped(packedBytes(pixelBuffer, bytesPerPixel: 4), width: width, height: height, order: [0, 1, 2])
        case kCVPixelFormatType_24RGB:
            return RGBPicture(width: width, height: height, pixels: packedBytes(pixelBuffer, bytesPerPixel: 3))
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return try rgbOfBiPlanar(pixelBuffer, width: width, height: height)
        default:
            throw EdgeError.unsupportedPixelFormat
        }
    }

    /// The camera's usual frame: two planes converted by vImage with the ITU-R 601 matrix, as the format says.
    private static func rgbOfBiPlanar(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> RGBPicture {
        let fullRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var pixelRange = fullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        var conversion = vImage_YpCbCrToARGB()
        var matrix = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4.pointee
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
            &matrix, &pixelRange, &conversion, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { throw EdgeError.unsupportedPixelFormat }
        var lumaPlane = vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        )
        var chromaPlane = vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1), height: vImagePixelCount((height + 1) / 2),
            width: vImagePixelCount((width + 1) / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        )
        var argb = [UInt8](repeating: 0, count: width * height * 4)
        let converted = argb.withUnsafeMutableBytes { buffer -> Bool in
            var destination = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageConvert_420Yp8_CbCr8ToARGB8888(
                &lumaPlane, &chromaPlane, &destination, &conversion, nil, 255, vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError
        }
        guard converted else { throw EdgeError.unsupportedPixelFormat }
        return stripped(argb, width: width, height: height, order: [1, 2, 3])
    }

    private static func packedBytes(_ pixelBuffer: CVPixelBuffer, bytesPerPixel: Int) -> [UInt8] {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        var packed = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for row in 0..<height {
            let source = UnsafeBufferPointer(start: base + row * rowBytes, count: width * bytesPerPixel)
            packed.replaceSubrange(row * width * bytesPerPixel..<(row + 1) * width * bytesPerPixel, with: source)
        }
        return packed
    }

    /// Three channels out of four-byte pixels, `order` naming where red, green and blue sit.
    private static func stripped(_ bytes: [UInt8], width: Int, height: Int, order: [Int]) -> RGBPicture {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            pixels[index * 3] = bytes[index * 4 + order[0]]
            pixels[index * 3 + 1] = bytes[index * 4 + order[1]]
            pixels[index * 3 + 2] = bytes[index * 4 + order[2]]
        }
        return RGBPicture(width: width, height: height, pixels: pixels)
    }
}
