#!/bin/bash
# Build TailscaleKit.xcframework (device arm64 + simulator arm64) from ../libtailscale
# and symlink it into Frameworks/, like GhosttyKit.
#
# Requires: Go (brew install go), Xcode.
# Usage: ./scripts/build-tailscalekit.sh

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LTS="$(cd "$APP_DIR/../libtailscale" && pwd)"
SWIFT="$LTS/swift"
PRODUCTS="$SWIFT/build/Build/Products"
# Must match the app's IPHONEOS_DEPLOYMENT_TARGET. TailscaleKit defaults to 18.1,
# but only its Listener API needs iOS 18 and that is @available-gated.
IOS_TARGET=17.0
# Use the Go version libtailscale's go.mod declares; newer Go breaks its pinned
# go-json-experiment dependency. Go downloads this toolchain on demand.
export GOTOOLCHAIN="go$(awk '/^go /{print $2}' "$LTS/go.mod")"

cd "$LTS"
make libtailscale_ios.a
make libtailscale_ios_sim_arm64.a
cp libtailscale_ios_sim_arm64.a libtailscale_ios_sim.a

cd "$SWIFT"
mkdir -p build
for pair in "TailscaleKit (iOS)|generic/platform=iOS" "TailscaleKit (Simulator)|generic/platform=iOS Simulator"; do
    scheme="${pair%%|*}"
    dest="${pair##*|}"
    xcodebuild build -quiet -scheme "$scheme" -derivedDataPath build -configuration Release \
        -destination "$dest" ARCHS=arm64 IPHONEOS_DEPLOYMENT_TARGET=$IOS_TARGET CODE_SIGNING_ALLOWED=NO
done

OUT="$PRODUCTS/Release-iphonefat/TailscaleKit.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -framework "$PRODUCTS/Release-iphoneos/TailscaleKit.framework" \
    -framework "$PRODUCTS/Release-iphonesimulator/TailscaleKit.framework" \
    -output "$OUT"

# Relative, like GhosttyKit, so the link works in any checkout location
ln -sfn "../../libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" "$APP_DIR/Frameworks/TailscaleKit.xcframework"
echo "Built $OUT"
