// swift-tools-version: 5.9
// MatcaEdge 1.2.0. The MatcaEdge product is the prebuilt framework, compiled with optimisation by this repository's
// release workflow from the commit before this one: `gh attestation verify MatcaEdge.xcframework.zip --repo
// Matca-ai/edge-ios` proves it. MatcaEdgeSource builds the same code from Sources/ in the app instead.
import PackageDescription

let package = Package(
    name: "MatcaEdge",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "MatcaEdge", targets: ["MatcaEdge"]),
        .library(name: "MatcaEdgeSource", targets: ["MatcaEdgeSource"]),
    ],
    targets: [
        .binaryTarget(name: "MatcaEdge", url: "https://github.com/Matca-ai/edge-ios/releases/download/1.2.0/MatcaEdge.xcframework.zip", checksum: "d924e25d8ce1ec12acf172341388e7cdde2ff990a34cceed061c2d16966fad59"),
        .target(name: "MatcaEdgeSource", path: "Sources/MatcaEdge", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
    ]
)
