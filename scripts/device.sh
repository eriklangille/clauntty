#!/bin/bash
# Build, install and launch Clauntty on a connected physical iPhone.
#
# Usage: ./scripts/device.sh [build|install|launch|run|doctor]   (default: run = all three)
#
# Env: DEVICE_ID  device UDID (default: first connected physical iPhone)
#
# Signing needs the login keychain, so Claude Code runs this script outside its
# sandbox (sandbox.excludedCommands in ~/.claude/settings.json).

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.octerm.clauntty"
LOG=/tmp/clauntty-device-build.log

find_device() {
    xcrun devicectl list devices 2>/dev/null |
        awk '/physical/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }'
}

# Remote/multiplexed terminal sessions can start with only System.keychain in the
# search list, which hides the signing key. Add the login keychain back if missing.
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ensure_login_keychain() {
    if ! security list-keychains -d user | grep -q "login.keychain"; then
        echo "Adding login keychain to this session's keychain search list."
        security list-keychains -d user -s "$LOGIN_KEYCHAIN"
    fi
}
ensure_login_keychain

DEVICE_ID="${DEVICE_ID:-$(find_device)}"
if [ -z "$DEVICE_ID" ]; then
    echo "No connected physical iPhone found (xcrun devicectl list devices)." >&2
    exit 1
fi

build() {
    echo "Building for device $DEVICE_ID (log: $LOG)..."
    cd "$APP_DIR"
    if ! xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -allowProvisioningUpdates -quiet build > "$LOG" 2>&1; then
        grep -E 'error' "$LOG" | sort -u | head -20 >&2
        echo "Build failed; see $LOG" >&2
        exit 1
    fi
    echo "Build succeeded."
}

app_path() {
    xcodebuild -project "$APP_DIR/Clauntty.xcodeproj" -scheme Clauntty \
        -destination "platform=iOS,id=$DEVICE_ID" -showBuildSettings 2>/dev/null |
        awk -F' = ' '/ TARGET_BUILD_DIR = /{d=$2} / FULL_PRODUCT_NAME = /{n=$2} END{print d "/" n}'
}

install() {
    local app
    app="$(app_path)"
    echo "Installing $app..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$app" > /dev/null
    echo "Installed."
}

launch() {
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" > /dev/null
    echo "Launched $BUNDLE_ID."
}

doctor() {
    echo "Device: $DEVICE_ID"
    echo "Keychain search list (user domain):"
    security list-keychains -d user
    echo "Keychain search list (effective):"
    security list-keychains
    if [ -r "$LOGIN_KEYCHAIN" ]; then echo "Login keychain file: readable"; else echo "Login keychain file: NOT readable"; fi
    echo "Signing identities visible to this shell:"
    security find-identity -v -p codesigning | sed -E 's/[0-9A-F]{40}/<hash>/'
}

case "${1:-run}" in
    doctor) doctor ;;
    build) build ;;
    install) install ;;
    launch) launch ;;
    run) build; install; launch ;;
    *) echo "Usage: $0 [build|install|launch|run|doctor]" >&2; exit 1 ;;
esac
