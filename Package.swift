// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MatcaEdge",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MatcaEdge", targets: ["MatcaEdge"])],
    targets: [
        .target(name: "MatcaEdge", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(name: "MatcaEdgeTests", dependencies: ["MatcaEdge"], resources: [.copy("Fixtures")]),
    ]
)
