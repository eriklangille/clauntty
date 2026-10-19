#!/bin/bash
# macOS app automation for Clauntty, the counterpart of sim.sh.
# Builds and runs ClaunttyMac on this Mac; screenshots and input go through
# mac-driver (sim-stream repo), which has Screen Recording and Accessibility.
#
# Usage:
#   ./scripts/mac.sh build                 # Debug build
#   ./scripts/mac.sh run [-- app args]     # build, quit the running app, launch
#                                          # (CLAUNTTY_SSH_CONFIG=file: another ssh config)
#   ./scripts/mac.sh quit
#   ./scripts/mac.sh shot [name]           # window screenshot -> screenshots/mac-<name>.png
#   ./scripts/mac.sh click X Y [right|double]
#   ./scripts/mac.sh drag X0 Y0 X1 Y1
#   ./scripts/mac.sh scroll X Y DY [DX]    # lines, +DY scrolls down
#   ./scripts/mac.sh type "text"
#   ./scripts/mac.sh key cmd+t             # combos: cmd/shift/ctrl/opt + key name or char
#   ./scripts/mac.sh size W H [X Y]        # resize (and move) the window
#   ./scripts/mac.sh window                # the window's frame
#   ./scripts/mac.sh logs [30s]            # the app's log
#
# Coordinates are window points from the window's top-left, title bar included.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_ID="com.octerm.clauntty.mac"
DERIVED="$PROJECT_DIR/build/mac"
APP="$DERIVED/Build/Products/Debug/Clauntty.app"
SCREENSHOTS_DIR="$PROJECT_DIR/screenshots"
DRIVER="http://127.0.0.1:${MAC_DRIVER_PORT:-8091}"

ensure_driver() {
    curl -sf "$DRIVER/status" >/dev/null && return
    if [ -d "$HOME/Applications/mac-driver.app" ]; then
        open -g "$HOME/Applications/mac-driver.app"
        for _ in $(seq 1 20); do curl -sf "$DRIVER/status" >/dev/null && return; sleep 0.25; done
    fi
    echo "mac-driver isn't running (build it: sim-stream/mac-driver/build.sh)" >&2
    exit 1
}

# POST a JSON body to mac-driver; print errors, stay quiet on success.
post() {
    ensure_driver
    local out
    out=$(curl -s -X POST -d "$2" "$DRIVER/$1")
    if [[ "$out" == *'"error"'* ]]; then
        echo "$out" >&2
        exit 1
    fi
}

json_string() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

build() {
    xcodebuild -project "$PROJECT_DIR/ClaunttyMac.xcodeproj" -scheme ClaunttyMac -configuration Debug \
        -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build 2>&1 \
        | grep -E "error:|warning: .*ClaunttyMac/|BUILD (SUCCEEDED|FAILED)" | grep -v "^--- xcodebuild" || true
    [ -x "$APP/Contents/MacOS/Clauntty" ]
}

quit_app() {
    # The full path, so the simulator's Clauntty is left alone.
    pkill -f "$APP/Contents/MacOS/Clauntty" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Clauntty" >/dev/null || return 0; sleep 0.1; done
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    build)
        build
        ;;
    run)
        [ "${1:-}" = "--" ] && shift
        build
        quit_app
        # CLAUNTTY_SSH_CONFIG points the app at another ssh config (tests use a scratch one)
        env_args=()
        [ -n "${CLAUNTTY_SSH_CONFIG:-}" ] && env_args=(--env "CLAUNTTY_SSH_CONFIG=$CLAUNTTY_SSH_CONFIG")
        open -n ${env_args[@]+"${env_args[@]}"} "$APP" --args "$@"
        for _ in $(seq 1 40); do
            curl -sf "$DRIVER/windows?app=$BUNDLE_ID" 2>/dev/null | grep -q '"window"' && { echo "Running."; exit 0; }
            sleep 0.25
        done
        echo "The app didn't show a window; see ./scripts/mac.sh logs 30s" >&2
        exit 1
        ;;
    quit)
        quit_app
        ;;
    shot)
        ensure_driver
        mkdir -p "$SCREENSHOTS_DIR"
        out="$SCREENSHOTS_DIR/mac-${1:-$(date +%H%M%S)}.png"
        code=$(curl -s -o "$out" -w "%{http_code}" "$DRIVER/shot?app=$BUNDLE_ID")
        if [ "$code" != 200 ]; then cat "$out" >&2; rm -f "$out"; exit 1; fi
        echo "$out"
        ;;
    click)
        extra=""
        [ "${3:-}" = "right" ] && extra=',"right":true'
        [ "${3:-}" = "double" ] && extra=',"count":2'
        post click "{\"app\":\"$BUNDLE_ID\",\"x\":$1,\"y\":$2$extra}"
        ;;
    drag)
        post drag "{\"app\":\"$BUNDLE_ID\",\"x0\":$1,\"y0\":$2,\"x1\":$3,\"y1\":$4}"
        ;;
    scroll)
        post scroll "{\"app\":\"$BUNDLE_ID\",\"x\":$1,\"y\":$2,\"dy\":$3,\"dx\":${4:-0}}"
        ;;
    type)
        post type "{\"app\":\"$BUNDLE_ID\",\"text\":$(json_string "$1")}"
        ;;
    key)
        post key "{\"app\":\"$BUNDLE_ID\",\"combo\":$(json_string "$1")}"
        ;;
    size)
        pos=""
        [ $# -ge 4 ] && pos=",\"x\":$3,\"y\":$4"
        post window "{\"app\":\"$BUNDLE_ID\",\"w\":$1,\"h\":$2$pos}"
        ;;
    window)
        ensure_driver
        curl -s "$DRIVER/windows?app=$BUNDLE_ID"
        ;;
    logs)
        /usr/bin/log show --last "${1:-30s}" --style compact \
            --predicate 'subsystem BEGINSWITH "com.clauntty"' 2>/dev/null | tail -100
        ;;
    help|*)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        ;;
esac
