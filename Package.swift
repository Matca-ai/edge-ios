// swift-tools-version: 5.9
// MatcaEdge 1.1.0. The MatcaEdge product is the prebuilt framework, compiled with optimisation by this repository's
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
        .binaryTarget(name: "MatcaEdge", url: "https://github.com/Matca-ai/edge-ios/releases/download/1.1.0/MatcaEdge.xcframework.zip", checksum: "d3e088dc4f2b0a7adc80d5eeced8177275fce0e37e9e281d7b1b25c261ff044a"),
        .target(name: "MatcaEdgeSource", path: "Sources/MatcaEdge", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
    ]
)
