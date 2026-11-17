import Accelerate
import Foundation

/// The picture upright by its EXIF orientation 1 to 8, as Pillow's `exif_transpose` turns it. vImage moves the pixels,
/// so a camera frame turns at the same cost in a Debug build as in an optimised one; no pixel's value changes.
func fixOrientation(_ picture: RGBPicture, exifOrientation: Int) -> RGBPicture {
    guard (2...8).contains(exifOrientation) else { return picture }
    var argb = FourChannelPicture(picture)
    switch exifOrientation {
    case 2: argb = argb.reflected(horizontally: true)
    case 3: argb = argb.rotated(UInt8(kRotate180DegreesClockwise))
    case 4: argb = argb.reflected(horizontally: false)
    case 5: argb = argb.rotated(UInt8(kRotate90DegreesClockwise)).reflected(horizontally: true)
    case 6: argb = argb.rotated(UInt8(kRotate90DegreesClockwise))
    case 7: argb = argb.rotated(UInt8(kRotate90DegreesClockwise)).reflected(horizontally: false)
    default: argb = argb.rotated(UInt8(kRotate90DegreesCounterClockwise))
    }
    return argb.rgb()
}

/// vImage turns and mirrors four-byte pixels only, so the three bytes travel with an opaque fourth.
private struct FourChannelPicture {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(_ picture: RGBPicture) {
        var source = picture.pixels
        var pixels = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
        withBuffers(&source, picture.width * 3, &pixels, picture.width * 4, picture.width, picture.height) { from, to in
            vImageConvert_RGB888toARGB8888(&from, nil, 255, &to, false, vImage_Flags(kvImageNoFlags))
        }
        self.init(width: picture.width, height: picture.height, pixels: pixels)
    }

    func rotated(_ rotation: UInt8) -> FourChannelPicture {
        let quarterTurn = rotation == UInt8(kRotate90DegreesClockwise) || rotation == UInt8(kRotate90DegreesCounterClockwise)
        let turnedWidth = quarterTurn ? height : width, turnedHeight = quarterTurn ? width : height
        var source = pixels
        var turned = [UInt8](repeating: 0, count: pixels.count)
        var background: [UInt8] = [255, 0, 0, 0]
        withBuffers(&source, width * 4, width, height, &turned, turnedWidth * 4, turnedWidth, turnedHeight) { from, to in
            vImageRotate90_ARGB8888(&from, &to, rotation, &background, vImage_Flags(kvImageNoFlags))
        }
        return FourChannelPicture(width: turnedWidth, height: turnedHeight, pixels: turned)
    }

    func reflected(horizontally: Bool) -> FourChannelPicture {
        var source = pixels
        var mirrored = [UInt8](repeating: 0, count: pixels.count)
        withBuffers(&source, width * 4, &mirrored, width * 4, width, height) { from, to in
            horizontally
                ? vImageHorizontalReflect_ARGB8888(&from, &to, vImage_Flags(kvImageNoFlags))
                : vImageVerticalReflect_ARGB8888(&from, &to, vImage_Flags(kvImageNoFlags))
        }
        return FourChannelPicture(width: width, height: height, pixels: mirrored)
    }

    func rgb() -> RGBPicture {
        var source = pixels
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        withBuffers(&source, width * 4, &rgb, width * 3, width, height) { from, to in
            vImageConvert_ARGB8888toRGB888(&from, &to, vImage_Flags(kvImageNoFlags))
        }
        return RGBPicture(width: width, height: height, pixels: rgb)
    }
}

/// Two pictures of one size as vImage buffers for the length of a call; a failure here is a programming error.
private func withBuffers(
    _ source: inout [UInt8], _ sourceRowBytes: Int, _ target: inout [UInt8], _ targetRowBytes: Int, _ width: Int, _ height: Int,
    _ work: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error
) {
    withBuffers(&source, sourceRowBytes, width, height, &target, targetRowBytes, width, height, work)
}

private func withBuffers(
    _ source: inout [UInt8], _ sourceRowBytes: Int, _ sourceWidth: Int, _ sourceHeight: Int,
    _ target: inout [UInt8], _ targetRowBytes: Int, _ targetWidth: Int, _ targetHeight: Int,
    _ work: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error
) {
    let error = source.withUnsafeMutableBytes { from in
        target.withUnsafeMutableBytes { to in
            var sourceBuffer = vImage_Buffer(
                data: from.baseAddress, height: vImagePixelCount(sourceHeight), width: vImagePixelCount(sourceWidth), rowBytes: sourceRowBytes
            )
            var targetBuffer = vImage_Buffer(
                data: to.baseAddress, height: vImagePixelCount(targetHeight), width: vImagePixelCount(targetWidth), rowBytes: targetRowBytes
            )
            return work(&sourceBuffer, &targetBuffer)
        }
    }
    precondition(error == kvImageNoError, "vImage refused a picture of \(sourceWidth)×\(sourceHeight): \(error)")
}
