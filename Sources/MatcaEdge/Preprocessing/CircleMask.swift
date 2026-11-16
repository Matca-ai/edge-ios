import Foundation

/// Black outside the largest centred circle. Pillow fills the ellipse inscribed in the box from the square's
/// first to its last pixel inclusive, so the radius is half of `side - 1` around the box's centre.
func circleMasked(_ picture: RGBPicture) -> RGBPicture {
    let side = min(picture.width, picture.height)
    let radius = Double(side - 1) / 2
    let centreX = Double((picture.width - side) / 2) + radius
    let centreY = Double((picture.height - side) / 2) + radius
    var masked = picture
    for y in 0..<picture.height {
        let verticalDistance = Double(y) - centreY
        for x in 0..<picture.width {
            let horizontalDistance = Double(x) - centreX
            if horizontalDistance * horizontalDistance + verticalDistance * verticalDistance > radius * radius {
                let offset = picture.offset(x: x, y: y)
                masked.pixels[offset] = 0
                masked.pixels[offset + 1] = 0
                masked.pixels[offset + 2] = 0
            }
        }
    }
    return masked
}
