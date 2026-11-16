import Foundation

/// The picture upright by its EXIF orientation 1 to 8, as Pillow's `exif_transpose` turns it.
func fixOrientation(_ picture: RGBPicture, exifOrientation: Int) -> RGBPicture {
    guard (2...8).contains(exifOrientation) else { return picture }
    let swapsAxes = exifOrientation >= 5
    let width = swapsAxes ? picture.height : picture.width
    let height = swapsAxes ? picture.width : picture.height
    var pixels = [UInt8](repeating: 0, count: picture.pixels.count)
    for y in 0..<height {
        for x in 0..<width {
            let (sourceX, sourceY) = sourceOfUprightPixel(x: x, y: y, orientation: exifOrientation, picture: picture)
            let source = picture.offset(x: sourceX, y: sourceY)
            let target = (y * width + x) * 3
            pixels[target] = picture.pixels[source]
            pixels[target + 1] = picture.pixels[source + 1]
            pixels[target + 2] = picture.pixels[source + 2]
        }
    }
    return RGBPicture(width: width, height: height, pixels: pixels)
}

private func sourceOfUprightPixel(x: Int, y: Int, orientation: Int, picture: RGBPicture) -> (Int, Int) {
    let lastX = picture.width - 1, lastY = picture.height - 1
    switch orientation {
    case 2: return (lastX - x, y)
    case 3: return (lastX - x, lastY - y)
    case 4: return (x, lastY - y)
    case 5: return (y, x)
    case 6: return (y, lastY - x)
    case 7: return (lastX - y, lastY - x)
    default: return (lastX - y, x)
    }
}
