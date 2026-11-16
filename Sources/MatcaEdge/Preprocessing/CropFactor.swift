import Foundation

/// The middle share of the picture, each side truncated to whole pixels as the trainer's `int()` does, at least one.
func cropByFactor(_ picture: RGBPicture, factor: Double) -> RGBPicture {
    let width = max(1, Int(Double(picture.width) * factor))
    let height = max(1, Int(Double(picture.height) * factor))
    return picture.cropped(left: (picture.width - width) / 2, top: (picture.height - height) / 2, width: width, height: height)
}
