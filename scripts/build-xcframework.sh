#!/usr/bin/env bash
# Builds this library as a prebuilt MatcaEdge.xcframework.zip for iPhone, the iOS Simulator and macOS, and prints its
# SwiftPM checksum. The release workflow (.github/workflows/release.yml) runs it on GitHub from the released commit
# and signs where the zip came from; an app that installs the package gets this binary, compiled with optimisation,
# so the picture steps run at their speed even in the app's own Debug build. Built with library evolution
# (BUILD_LIBRARY_FOR_DISTRIBUTION), so an app on this Xcode or a newer one can link it. Needs Xcode on a Mac.
#   Usage: scripts/build-xcframework.sh <folder the zip goes to>
set -euo pipefail

OUT="$(mkdir -p "${1:?the folder the zip goes to}" && cd "$1" && pwd)"
LIBRARY="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

rsync -a --exclude .build --exclude .swiftpm --exclude dist "$LIBRARY/" "$WORK/package/"
# xcodebuild makes a framework of a dynamic library product only; the mirror's own manifest is not touched.
sed -i '' 's/\.library(name: "MatcaEdge", targets:/.library(name: "MatcaEdge", type: .dynamic, targets:/' "$WORK/package/Package.swift"
# The privacy manifest goes into each framework below, so no resource bundle (and no accessor for one) is built.
sed -i '' 's/\.target(name: "MatcaEdge", resources: \[\.copy("Resources\/PrivacyInfo.xcprivacy")\])/.target(name: "MatcaEdge", exclude: ["Resources"])/' "$WORK/package/Package.swift"
grep -q 'type: .dynamic' "$WORK/package/Package.swift" && grep -q 'exclude: \["Resources"\]' "$WORK/package/Package.swift" \
  || { echo "Package.swift no longer names the MatcaEdge library and its resources as expected" >&2; exit 1; }

frameworks=()
for platform in "iOS:Release-iphoneos" "iOS Simulator:Release-iphonesimulator" "macOS:Release"; do
  (cd "$WORK/package" && xcodebuild build -scheme MatcaEdge -configuration Release -destination "generic/platform=${platform%%:*}" \
    SYMROOT="$WORK/products" OBJROOT="$WORK/intermediates" BUILD_LIBRARY_FOR_DISTRIBUTION=YES -quiet)
  products="$WORK/products/${platform##*:}"
  framework="$products/PackageFrameworks/MatcaEdge.framework"
  # macOS frameworks keep their contents in a version folder, iOS ones flat.
  if [ -d "$framework/Versions" ]; then
    contents="$framework/Versions/A"
    resources="$contents/Resources"
    mkdir -p "$contents/Modules"
    ln -s Versions/Current/Modules "$framework/Modules"
  else
    contents="$framework"
    resources="$framework"
    mkdir -p "$contents/Modules"
  fi
  cp -R "$products/MatcaEdge.swiftmodule" "$contents/Modules/"
  # The public interface only: the build's project files and the package-internal interfaces stay out.
  rm -rf "$contents/Modules/MatcaEdge.swiftmodule/Project"
  rm -f "$contents"/Modules/MatcaEdge.swiftmodule/*.private.swiftinterface "$contents"/Modules/MatcaEdge.swiftmodule/*.package.swiftinterface
  # Where Xcode collects a framework's privacy manifest into the app's privacy report.
  cp "$LIBRARY/Sources/MatcaEdge/Resources/PrivacyInfo.xcprivacy" "$resources/"
  frameworks+=(-framework "$framework")
done

xcodebuild -create-xcframework "${frameworks[@]}" -output "$WORK/MatcaEdge.xcframework" >/dev/null
rm -f "$OUT/MatcaEdge.xcframework.zip"
(cd "$WORK" && ditto -c -k --norsrc --noextattr --noacl --keepParent MatcaEdge.xcframework "$OUT/MatcaEdge.xcframework.zip")
swift package compute-checksum "$OUT/MatcaEdge.xcframework.zip"
