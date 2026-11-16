import Foundation

/// The largest centred square, its corner at the integer halves of what is left.
func centreSquareCrop(_ picture: RGBPicture) -> RGBPicture {
    let side = min(picture.width, picture.height)
    return picture.cropped(left: (picture.width - side) / 2, top: (picture.height - side) / 2, width: side, height: side)
}
