#!/usr/bin/env bash
# Prints the Package.swift a release carries: MatcaEdge as the prebuilt framework attached to the release, named by
# URL and checksum, and MatcaEdgeSource as the same code built from Sources/ in the app, for those who would rather
# not take a binary. The release workflow commits it on top of the released source commit, which is all it changes.
#   Usage: scripts/release-manifest.sh <version> <checksum> <the framework zip's download URL>
set -euo pipefail

VERSION="${1:?the version}"
CHECKSUM="${2:?the SwiftPM checksum of the zip}"
URL="${3:?the download URL of the zip}"
[[ "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]] || { echo "a checksum is 64 hex digits" >&2; exit 1; }

cat <<EOF
// swift-tools-version: 5.9
// MatcaEdge $VERSION. The MatcaEdge product is the prebuilt framework, compiled with optimisation by this repository's
// release workflow from the commit before this one: \`gh attestation verify MatcaEdge.xcframework.zip --repo
// Matca-ai/edge-ios\` proves it. MatcaEdgeSource builds the same code from Sources/ in the app instead.
import PackageDescription

let package = Package(
    name: "MatcaEdge",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "MatcaEdge", targets: ["MatcaEdge"]),
        .library(name: "MatcaEdgeSource", targets: ["MatcaEdgeSource"]),
    ],
    targets: [
        .binaryTarget(name: "MatcaEdge", url: "$URL", checksum: "$CHECKSUM"),
        .target(name: "MatcaEdgeSource", path: "Sources/MatcaEdge", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
    ]
)
EOF
