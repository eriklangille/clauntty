#!/bin/bash
# Simulator automation CLI for Clauntty testing
# Uses Facebook IDB - runs inside simulator, doesn't take over your screen
#
# Usage:
#   ./scripts/sim.sh tap 200 400       # Tap at coordinates
#   ./scripts/sim.sh swipe up          # Swipe direction
#   ./scripts/sim.sh type "hello"      # Type text
#   ./scripts/sim.sh key 40            # Send key code (40=return)
#   ./scripts/sim.sh screenshot        # Take screenshot
#   ./scripts/sim.sh button home       # Press hardware button

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_ID="com.clauntty.app"
SCREENSHOTS_DIR="$PROJECT_DIR/screenshots"
DEVICE_NAME="iPhone 17"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure screenshots directory exists
mkdir -p "$SCREENSHOTS_DIR"

# Get device UDID
get_udid() {
    xcrun simctl list devices booted -j 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(next((dev['udid'] for r in d.get('devices',{}).values() for dev in r if dev.get('state')=='Booted'),''))" 2>/dev/null || echo ""
}

# Check if IDB companion is running for the device
is_companion_running() {
    local udid=$1
    idb list-targets 2>/dev/null | grep "$udid" | grep -q "companion.sock"
}

# Start IDB companion for device
start_companion() {
    local udid=$1
    if ! is_companion_running "$udid"; then
        echo -e "${BLUE}Starting IDB companion...${NC}" >&2
        # Start companion in background, find available port
        nohup idb_companion --udid "$udid" > /tmp/idb_companion.log 2>&1 &
        sleep 2

        # Get the port from the log
        local port=$(grep -o '"grpc_port":[0-9]*' /tmp/idb_companion.log 2>/dev/null | head -1 | grep -o '[0-9]*')
        if [ -n "$port" ]; then
            idb connect localhost "$port" >/dev/null 2>&1
        fi
    fi
}

# Ensure simulator is booted and IDB is connected
ensure_ready() {
    local udid=$(get_udid)
    if [ -z "$udid" ]; then
        echo -e "${BLUE}Booting $DEVICE_NAME...${NC}" >&2
        xcrun simctl boot "$DEVICE_NAME" 2>/dev/null || true
        sleep 3
        udid=$(get_udid)
    fi

    # Start companion if needed
    start_companion "$udid"
    echo "$udid"
}

# Main command dispatch
case "${1:-help}" in
    boot)
        ensure_ready > /dev/null
        echo -e "${GREEN}Simulator booted and IDB connected${NC}"
        ;;

    tap)
        udid=$(ensure_ready)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 tap <x> <y>"
            exit 1
        fi
        echo -e "${BLUE}Tapping at ($2, $3)...${NC}"
        idb ui tap --udid "$udid" "$2" "$3"
        ;;

    swipe)
        udid=$(ensure_ready)
        if [ -z "$2" ]; then
            echo "Usage: $0 swipe <up|down|left|right> [duration_sec]"
            exit 1
        fi
        duration="${3:-0.5}"

        # Screen center and swipe offsets (iPhone 17: 393x852)
        cx=196
        cy=426
        offset=200

        case "$2" in
            up)    sx=$cx; sy=$((cy + offset)); ex=$cx; ey=$((cy - offset)) ;;
            down)  sx=$cx; sy=$((cy - offset)); ex=$cx; ey=$((cy + offset)) ;;
            left)  sx=$((cx + offset)); sy=$cy; ex=$((cx - offset)); ey=$cy ;;
            right) sx=$((cx - offset)); sy=$cy; ex=$((cx + offset)); ey=$cy ;;
            *)
                echo -e "${RED}Unknown direction: $2${NC}"
                exit 1
                ;;
        esac

        echo -e "${BLUE}Swiping $2...${NC}"
        idb ui swipe --udid "$udid" "$sx" "$sy" "$ex" "$ey" --duration "$duration"
        ;;

    type)
        udid=$(ensure_ready)
        if [ -z "$2" ]; then
            echo "Usage: $0 type \"text\""
            exit 1
        fi
        echo -e "${BLUE}Typing: $2${NC}"
        idb ui text --udid "$udid" "$2"
        ;;

    key)
        udid=$(ensure_ready)
        if [ -z "$2" ]; then
            cat <<EOF
Usage: $0 key <keycode>

Common keycodes:
  40  - Return/Enter
  41  - Escape
  42  - Backspace/Delete
  43  - Tab
  44  - Space
  79  - Right Arrow
  80  - Left Arrow
  81  - Down Arrow
  82  - Up Arrow
EOF
            exit 1
        fi
        echo -e "${BLUE}Sending keycode: $2${NC}"
        idb ui key --udid "$udid" "$2"
        ;;

    button)
        udid=$(ensure_ready)
        btn="${2:-home}"
        echo -e "${BLUE}Pressing $btn button...${NC}"
        case "$btn" in
            home)
                idb ui button --udid "$udid" HOME
                ;;
            lock|side|power)
                idb ui button --udid "$udid" LOCK
                ;;
            siri)
                idb ui button --udid "$udid" SIRI
                ;;
            *)
                echo -e "${RED}Unknown button: $btn (use: home, lock, siri)${NC}"
                exit 1
                ;;
        esac
        ;;

    screenshot|ss)
        udid=$(ensure_ready)
        name="${2:-screenshot_$(date +%s)}"
        path="$SCREENSHOTS_DIR/${name}.png"
        # Use simctl for screenshots (more reliable)
        xcrun simctl io booted screenshot "$path"
        echo -e "${GREEN}Screenshot: $path${NC}"
        ;;

    launch)
        udid=$(ensure_ready)
        mode="${2:-}"
        echo -e "${BLUE}Launching Clauntty...${NC}"
        xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
        sleep 0.5
        if [ -n "$mode" ]; then
            xcrun simctl launch booted "$BUNDLE_ID" "$mode"
        else
            xcrun simctl launch booted "$BUNDLE_ID"
        fi
        sleep 2
        echo -e "${GREEN}Launched${NC}"
        ;;

    install)
        ensure_ready > /dev/null
        echo -e "${BLUE}Installing Clauntty...${NC}"
        APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphonesimulator -name "Clauntty.app" -type d 2>/dev/null | head -1)
        if [ -z "$APP_PATH" ]; then
            echo -e "${RED}No built app found. Run 'xcodebuild' first.${NC}"
            exit 1
        fi
        xcrun simctl install booted "$APP_PATH"
        echo -e "${GREEN}Installed from: $APP_PATH${NC}"
        ;;

    build)
        echo -e "${BLUE}Building Clauntty...${NC}"
        cd "$PROJECT_DIR"
        xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
            -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
            -quiet build
        echo -e "${GREEN}Build complete${NC}"
        ;;

    run)
        # Full cycle: build, install, launch
        $0 build
        $0 install
        $0 launch "${2:-}"
        ;;

    # Convenience: Common UI actions
    tap-add)
        # Tap the add button (top right nav bar)
        $0 tap 360 60
        ;;

    tap-first-connection)
        # Tap the first connection in the list
        $0 tap 196 180
        ;;

    tap-terminal)
        # Tap center of terminal to focus/show keyboard
        $0 tap 196 450
        ;;

    tap-close)
        # Tap close/back button (top left)
        $0 tap 40 60
        ;;

    tap-save)
        # Tap save button in form
        $0 tap 360 60
        ;;

    # Test sequences
    test-keyboard)
        echo -e "${BLUE}Testing keyboard accessory bar...${NC}"
        $0 launch --preview-terminal
        sleep 2
        $0 tap-terminal
        sleep 1
        $0 screenshot "keyboard_accessory"
        echo -e "${GREEN}Screenshot saved. Opening...${NC}"
        open "$SCREENSHOTS_DIR/keyboard_accessory.png"
        ;;

    test-connections)
        echo -e "${BLUE}Testing connections view...${NC}"
        $0 launch
        sleep 2
        $0 screenshot "connections"
        open "$SCREENSHOTS_DIR/connections.png"
        ;;

    test-new-connection)
        echo -e "${BLUE}Testing new connection form...${NC}"
        $0 launch
        sleep 1
        $0 tap-add
        sleep 1
        $0 screenshot "new_connection"
        open "$SCREENSHOTS_DIR/new_connection.png"
        ;;

    test-flow)
        # Full flow: connections -> add -> save -> connect
        echo -e "${BLUE}Running full UI flow test...${NC}"
        $0 launch
        sleep 1
        $0 screenshot "01_connections"

        $0 tap-add
        sleep 1
        $0 screenshot "02_new_form"

        # Type in the form
        $0 tap 196 200  # Host field
        sleep 0.3
        $0 type "localhost"
        $0 tap 196 280  # Username field
        sleep 0.3
        $0 type "testuser"
        sleep 0.5
        $0 screenshot "03_filled_form"

        $0 tap-save
        sleep 1
        $0 screenshot "04_saved"

        echo -e "${GREEN}Flow test complete. Screenshots in: $SCREENSHOTS_DIR${NC}"
        open "$SCREENSHOTS_DIR"
        ;;

    ui)
        # Dump UI element hierarchy with coordinates
        udid=$(ensure_ready)
        filter="${2:-}"
        echo -e "${BLUE}Fetching UI elements...${NC}" >&2

        # Get JSON and format it nicely
        idb ui describe-all --udid "$udid" 2>/dev/null | python3 -c "
import sys, json

data = json.load(sys.stdin)
filter_text = '$filter'.lower()

print()
print('UI Elements (tap coordinates = center of frame)')
print('=' * 70)

for el in data:
    label = el.get('AXLabel') or el.get('title') or ''
    el_type = el.get('type', '')
    unique_id = el.get('AXUniqueId') or ''
    frame = el.get('frame', {})

    # Skip if filter provided and doesn't match
    if filter_text:
        searchable = f'{label} {el_type} {unique_id}'.lower()
        if filter_text not in searchable:
            continue

    x = frame.get('x', 0)
    y = frame.get('y', 0)
    w = frame.get('width', 0)
    h = frame.get('height', 0)

    # Calculate center point for tapping
    cx = int(x + w / 2)
    cy = int(y + h / 2)

    # Format output
    if label:
        name = f'{el_type}: \"{label}\"'
    elif unique_id:
        name = f'{el_type}: [{unique_id}]'
    else:
        name = el_type or '(unknown)'

    print(f'{name}')
    print(f'  tap: ({cx}, {cy})  frame: ({int(x)}, {int(y)}, {int(w)}x{int(h)})')
    print()
"
        echo -e "${GREEN}Usage: ./scripts/sim.sh tap <x> <y>${NC}"
        ;;

    logs)
        # Stream app logs
        echo -e "${BLUE}Streaming Clauntty logs (Ctrl+C to stop)...${NC}"
        xcrun simctl spawn booted log stream --level=info \
            --predicate 'subsystem == "com.clauntty" OR subsystem == "com.mitchellh.ghostty"'
        ;;

    help|*)
        cat <<EOF
Clauntty Simulator CLI (uses IDB - runs in background, won't interrupt your work)

Usage: $0 <command> [args...]

Setup:
  boot                     Boot simulator and connect IDB

Build & Run:
  build                    Build the app
  install                  Install to simulator
  launch [mode]            Launch app (with optional --preview-* mode)
  run [mode]               Build, install, and launch

Interaction (runs inside simulator):
  tap <x> <y>              Tap at coordinates
  swipe <direction>        Swipe up/down/left/right
  type "text"              Type text
  key <keycode>            Send key (40=return, 41=esc, 43=tab)
  button <name>            Press button (home, lock, siri)
  screenshot [name]        Take screenshot

Convenience:
  tap-add                  Tap Add button
  tap-first-connection     Tap first connection
  tap-terminal             Tap terminal center
  tap-close                Tap close/back
  tap-save                 Tap Save button

Test Sequences:
  test-keyboard            Keyboard accessory screenshot
  test-connections         Connections list screenshot
  test-new-connection      New connection form screenshot
  test-flow                Full UI flow with screenshots

Debugging:
  ui [filter]              List UI elements with tap coordinates
  logs                     Stream app logs

Examples:
  $0 run --preview-terminal
  $0 tap 196 400
  $0 test-keyboard

Screenshots: $SCREENSHOTS_DIR
EOF
        ;;
esac
