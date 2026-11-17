import Foundation

/// Black outside the largest centred circle. Pillow fills the ellipse inscribed in the box from the square's
/// first to its last pixel inclusive, so the radius is half of `side - 1` around the box's centre. Each row is
/// blanked left and right of where it meets the circle in two runs, so the cost is per row, not per pixel.
func circleMasked(_ picture: RGBPicture) -> RGBPicture {
    let side = min(picture.width, picture.height)
    let radius = Double(side - 1) / 2
    let centreX = Double((picture.width - side) / 2) + radius
    let centreY = Double((picture.height - side) / 2) + radius
    var masked = picture
    masked.pixels.withUnsafeMutableBufferPointer { pixels in
        for y in 0..<picture.height {
            let verticalDistance = Double(y) - centreY
            let inside = { (x: Int) -> Bool in
                let horizontalDistance = Double(x) - centreX
                return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance <= radius * radius
            }
            let (first, last) = insideSpan(width: picture.width, centreX: centreX, room: radius * radius - verticalDistance * verticalDistance, inside: inside)
            let row = y * picture.width * 3
            blank(pixels, from: row, to: row + first * 3)
            blank(pixels, from: row + (last + 1) * 3, to: row + picture.width * 3)
        }
    }
    return masked
}

/// The first and last pixel of a row inside the circle, from the square root and then settled on the exact test, so
/// no rounding of the root moves a pixel across the edge; first past last when the row misses the circle.
private func insideSpan(width: Int, centreX: Double, room: Double, inside: (Int) -> Bool) -> (Int, Int) {
    guard room >= 0 else { return (width, width - 1) }
    var first = max(0, min(width - 1, Int((centreX - room.squareRoot()).rounded(.up))))
    while first > 0, inside(first - 1) { first -= 1 }
    while first < width, !inside(first) { first += 1 }
    guard first < width else { return (width, width - 1) }
    var last = max(first, min(width - 1, Int((centreX + room.squareRoot()).rounded(.down))))
    while last + 1 < width, inside(last + 1) { last += 1 }
    while last > first, !inside(last) { last -= 1 }
    return (first, last)
}

private func blank(_ pixels: UnsafeMutableBufferPointer<UInt8>, from start: Int, to end: Int) {
    guard end > start else { return }
    UnsafeMutableBufferPointer(rebasing: pixels[start..<end]).update(repeating: 0)
}
