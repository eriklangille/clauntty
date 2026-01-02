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
        echo -e "${BLUE}Launching Clauntty (verbose logging enabled)...${NC}"
        xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
        sleep 0.5
        # Launch with CLAUNTTY_VERBOSE=1 for verbose debug logging
        # SIMCTL_CHILD_ prefix passes env vars to launched app
        if [ -n "$mode" ]; then
            SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted "$BUNDLE_ID" "$mode"
        else
            SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted "$BUNDLE_ID"
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
        # Stream or show recent app logs
        duration="${2:-stream}"
        if [ "$duration" = "stream" ]; then
            echo -e "${BLUE}Streaming Clauntty logs (Ctrl+C to stop)...${NC}"
            xcrun simctl spawn booted log stream --level debug \
                --predicate 'subsystem == "com.clauntty" OR subsystem == "com.mitchellh.ghostty"'
        else
            echo -e "${BLUE}Showing last ${duration} of logs...${NC}"
            xcrun simctl spawn booted log show --debug --last "$duration" \
                --predicate 'subsystem == "com.clauntty"' 2>&1 | tail -100
        fi
        ;;

    debug)
        # All-in-one debug: build, install, launch, screenshot, logs
        # Usage: debug [connection_name] [--type "text"] [--wait N] [--tabs "0,1"]
        shift  # Remove 'debug' from args

        # Parse arguments
        connection=""
        type_text=""
        wait_time=8
        show_logs="30s"
        tabs_spec=""

        while [ $# -gt 0 ]; do
            case "$1" in
                --type|-t)
                    type_text="$2"
                    shift 2
                    ;;
                --wait|-w)
                    wait_time="$2"
                    shift 2
                    ;;
                --logs|-l)
                    show_logs="$2"
                    shift 2
                    ;;
                --no-logs)
                    show_logs=""
                    shift
                    ;;
                --no-build)
                    no_build=1
                    shift
                    ;;
                --tabs)
                    tabs_spec="$2"
                    shift 2
                    ;;
                *)
                    connection="$1"
                    shift
                    ;;
            esac
        done

        echo -e "${BLUE}=== Debug Session ===${NC}"

        # Build (unless --no-build)
        if [ -z "$no_build" ]; then
            echo -e "${BLUE}[1/5] Building...${NC}"
            cd "$PROJECT_DIR"
            xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
                -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
                -quiet build
            echo -e "${GREEN}Build complete${NC}"
        else
            echo -e "${YELLOW}[1/5] Skipping build${NC}"
        fi

        # Install
        echo -e "${BLUE}[2/5] Installing...${NC}"
        ensure_ready > /dev/null
        APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphonesimulator -name "Clauntty.app" -type d 2>/dev/null | head -1)
        xcrun simctl install booted "$APP_PATH"

        # Launch (with verbose logging enabled)
        echo -e "${BLUE}[3/5] Launching (verbose logging enabled)...${NC}"
        xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
        sleep 0.5
        # SIMCTL_CHILD_ prefix passes env vars to launched app
        if [ -n "$connection" ] && [ -n "$tabs_spec" ]; then
            SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted "$BUNDLE_ID" -- --connect "$connection" --tabs "$tabs_spec"
            echo -e "${GREEN}Launched with --connect $connection --tabs $tabs_spec${NC}"
        elif [ -n "$connection" ]; then
            SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted "$BUNDLE_ID" -- --connect "$connection"
            echo -e "${GREEN}Launched with --connect $connection${NC}"
        else
            SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted "$BUNDLE_ID"
            echo -e "${GREEN}Launched${NC}"
        fi

        # Wait for connection/load
        echo -e "${BLUE}[4/5] Waiting ${wait_time}s...${NC}"
        sleep "$wait_time"

        # Optional: type text
        if [ -n "$type_text" ]; then
            echo -e "${BLUE}Typing: $type_text${NC}"
            udid=$(get_udid)
            idb ui text --udid "$udid" "$type_text"
            sleep 1
        fi

        # Screenshot
        timestamp=$(date +%H%M%S)
        ss_name="debug_${timestamp}"
        ss_path="$SCREENSHOTS_DIR/${ss_name}.png"
        xcrun simctl io booted screenshot "$ss_path"
        echo -e "${GREEN}[5/5] Screenshot: $ss_path${NC}"

        # Show logs
        if [ -n "$show_logs" ]; then
            echo ""
            echo -e "${BLUE}=== Recent Logs (last $show_logs) ===${NC}"
            xcrun simctl spawn booted log show --debug --last "$show_logs" \
                --predicate 'subsystem == "com.clauntty"' 2>&1 | \
                grep -v "^Timestamp" | grep -v "^getpwuid" | tail -50
        fi

        echo ""
        echo -e "${GREEN}=== Debug Complete ===${NC}"
        echo -e "Screenshot: ${BLUE}$ss_path${NC}"
        echo -e "Open: ${YELLOW}open $ss_path${NC}"
        ;;

    quick|q)
        # Quick debug: skip build, just reinstall and launch
        # Usage: quick [connection_name] [--type "text"]
        shift
        $0 debug --no-build "$@"
        ;;

    tabs)
        # Show tab coordinates for tapping
        # Tab bar is 44pt tall, positioned below status bar (~54pt on Dynamic Island devices)
        # Available width = 393 - 44 (+ button) - 4 (padding) = 345pt for tabs
        udid=$(ensure_ready)
        num_tabs="${2:-2}"

        # Screen width for iPhone 17 is 393pt
        screen_width=393
        plus_button_width=44
        padding=4
        status_bar_height=54  # Dynamic Island area
        tab_bar_height=44
        tab_y=$((status_bar_height + tab_bar_height / 2))  # Center of tab bar = 76

        available_width=$((screen_width - plus_button_width - padding))
        tab_width=$((available_width / num_tabs))

        echo -e "${BLUE}Tab coordinates for $num_tabs tabs:${NC}"
        echo "Tab bar: below status bar, centered at y=$tab_y"
        echo ""

        for i in $(seq 1 $num_tabs); do
            # Center of each tab
            tab_x=$(( (i - 1) * tab_width + tab_width / 2 + 2 ))
            echo -e "  Tab $i: ${GREEN}./scripts/sim.sh tap $tab_x $tab_y${NC}  or  ${GREEN}./scripts/sim.sh tap-tab $i $num_tabs${NC}"
        done

        echo ""
        echo -e "  + Button: ${GREEN}./scripts/sim.sh tap 371 $tab_y${NC}"
        echo ""
        echo "To open multiple tabs:"
        echo -e "  ${YELLOW}./scripts/sim.sh debug devbox --tabs \"0,1\"${NC}      # 2 existing sessions"
        echo -e "  ${YELLOW}./scripts/sim.sh debug devbox --tabs \"0,new\"${NC}    # 1 existing + 1 new"
        echo -e "  ${YELLOW}./scripts/sim.sh debug devbox --tabs \"0,:3000\"${NC}  # 1 terminal + port 3000"
        ;;

    tap-tab)
        # Tap a specific tab by number (1-indexed)
        tab_num="${2:-1}"
        num_tabs="${3:-2}"

        screen_width=393
        plus_button_width=44
        padding=4
        status_bar_height=54
        tab_bar_height=44
        tab_y=$((status_bar_height + tab_bar_height / 2))  # 76

        available_width=$((screen_width - plus_button_width - padding))
        tab_width=$((available_width / num_tabs))
        tab_x=$(( (tab_num - 1) * tab_width + tab_width / 2 + 2 ))

        echo -e "${BLUE}Tapping tab $tab_num (of $num_tabs) at ($tab_x, $tab_y)...${NC}"
        $0 tap $tab_x $tab_y
        ;;

    type-tab)
        # Type text in a specific tab
        # Usage: type-tab <tab_num> <total_tabs> "text"
        tab_num="${2:-1}"
        num_tabs="${3:-2}"
        text="$4"

        if [ -z "$text" ]; then
            echo "Usage: $0 type-tab <tab_num> <total_tabs> \"text\""
            echo "Example: $0 type-tab 1 2 \"ls -la\""
            exit 1
        fi

        echo -e "${BLUE}Switching to tab $tab_num and typing...${NC}"
        $0 tap-tab "$tab_num" "$num_tabs"
        sleep 0.5
        $0 type "$text"
        ;;

    run-tab)
        # Type text and press enter in a specific tab (run a command)
        # Usage: run-tab <tab_num> <total_tabs> "command"
        tab_num="${2:-1}"
        num_tabs="${3:-2}"
        cmd="$4"

        if [ -z "$cmd" ]; then
            echo "Usage: $0 run-tab <tab_num> <total_tabs> \"command\""
            echo "Example: $0 run-tab 1 2 \"ls -la\""
            exit 1
        fi

        echo -e "${BLUE}Running command in tab $tab_num: $cmd${NC}"
        $0 tap-tab "$tab_num" "$num_tabs"
        sleep 0.5
        $0 type "$cmd"
        sleep 0.2
        $0 key 40  # Enter key
        ;;

    enter)
        # Send enter key
        udid=$(ensure_ready)
        echo -e "${BLUE}Pressing Enter...${NC}"
        idb ui key --udid "$udid" 40
        ;;

    settings|prefs)
        # Read app settings/saved connections from simulator
        udid=$(get_udid)
        if [ -z "$udid" ]; then
            echo -e "${RED}No booted simulator found${NC}"
            exit 1
        fi

        # Find the app's preferences plist
        plist_path=$(find ~/Library/Developer/CoreSimulator/Devices/"$udid"/data/Containers/Data/Application/*/Library/Preferences/com.clauntty.app.plist 2>/dev/null | head -1)

        if [ -z "$plist_path" ]; then
            echo -e "${RED}App preferences not found. Run the app first.${NC}"
            exit 1
        fi

        echo -e "${BLUE}Reading saved connections...${NC}"
        python3 - "$plist_path" <<'PYTHON'
import sys
import plistlib
import json

plist_path = sys.argv[1]
with open(plist_path, 'rb') as f:
    data = plistlib.load(f)

if 'savedConnections' not in data:
    print("No saved connections found")
    sys.exit(0)

# savedConnections is JSON-encoded bytes
connections = json.loads(data['savedConnections'])

print(f"\nSaved Connections ({len(connections)} total):")
print("=" * 60)

for i, conn in enumerate(connections, 1):
    name = conn.get('name', '(unnamed)')
    host = conn.get('host', '?')
    port = conn.get('port', 22)
    username = conn.get('username', '?')
    auth = conn.get('authMethod', {})

    if isinstance(auth, dict):
        if 'password' in auth:
            auth_str = "password"
        elif 'sshKey' in auth:
            key_id = auth['sshKey'].get('keyId', '?')
            auth_str = f"sshKey({key_id[:16]}...)" if len(key_id) > 16 else f"sshKey({key_id})"
        else:
            auth_str = str(auth)
    else:
        auth_str = str(auth)

    print(f"\n{i}. {name}")
    print(f"   Host: {host}:{port}")
    print(f"   User: {username}")
    print(f"   Auth: {auth_str}")
PYTHON
        ;;

    # MARK: - Rotation

    rotate-left|rl)
        # Rotate simulator left (landscape)
        echo -e "${BLUE}Rotating left...${NC}"
        osascript -e '
tell application "Simulator" to activate
delay 0.2
tell application "System Events"
    keystroke (ASCII character 28) using {command down}
end tell
'
        sleep 0.5
        echo -e "${GREEN}Rotated left${NC}"
        ;;

    rotate-right|rr)
        # Rotate simulator right (landscape)
        echo -e "${BLUE}Rotating right...${NC}"
        osascript -e '
tell application "Simulator" to activate
delay 0.2
tell application "System Events"
    keystroke (ASCII character 29) using {command down}
end tell
'
        sleep 0.5
        echo -e "${GREEN}Rotated right${NC}"
        ;;

    rotate|rot)
        # Rotate to specific orientation
        # Usage: rotate <portrait|landscape|left|right>
        orientation="${2:-landscape}"
        case "$orientation" in
            left|l)
                $0 rotate-left
                ;;
            right|r)
                $0 rotate-right
                ;;
            portrait|p)
                # Rotate twice to get back to portrait (or use specific key)
                echo -e "${BLUE}Rotating to portrait...${NC}"
                # Cmd+Up = portrait
                osascript -e '
tell application "Simulator" to activate
delay 0.2
tell application "System Events"
    keystroke (ASCII character 30) using {command down}
end tell
'
                sleep 0.5
                echo -e "${GREEN}Rotated to portrait${NC}"
                ;;
            landscape|land)
                $0 rotate-left
                ;;
            *)
                echo -e "${RED}Unknown orientation: $orientation (use: portrait, landscape, left, right)${NC}"
                exit 1
                ;;
        esac
        ;;

    # MARK: - Terminal Text Capture (for render testing)

    capture-text|ct)
        # Capture visible terminal text to a file
        # Usage: capture-text [output_file]
        udid=$(ensure_ready)
        output_file="${2:-/tmp/clauntty_capture.txt}"

        echo -e "${BLUE}Triggering text capture...${NC}"

        # Trigger capture via URL scheme
        xcrun simctl openurl booted "clauntty://dump-text"
        sleep 0.5

        # Find the app's Documents directory in the simulator
        app_container=$(find ~/Library/Developer/CoreSimulator/Devices/"$udid"/data/Containers/Data/Application -name "clauntty_dump.txt" -exec dirname {} \; 2>/dev/null | head -1)
        if [ -z "$app_container" ]; then
            # Try to find by bundle ID
            app_container=$(find ~/Library/Developer/CoreSimulator/Devices/"$udid"/data/Containers/Data/Application -name ".com.apple.mobile_container_manager.metadata.plist" -exec sh -c 'grep -l "com.clauntty.app" "$1" 2>/dev/null && dirname "$1"' _ {} \; 2>/dev/null | head -1)
            if [ -n "$app_container" ]; then
                app_container="$app_container/Documents"
            fi
        fi

        sim_file=""
        if [ -n "$app_container" ]; then
            sim_file="$app_container/clauntty_dump.txt"
        fi

        # Fallback: search directly
        if [ -z "$sim_file" ] || [ ! -f "$sim_file" ]; then
            sim_file=$(find ~/Library/Developer/CoreSimulator/Devices/"$udid" -name "clauntty_dump.txt" 2>/dev/null | head -1)
        fi

        if [ -n "$sim_file" ] && [ -f "$sim_file" ]; then
            cp "$sim_file" "$output_file"
            lines=$(wc -l < "$output_file" | tr -d ' ')
            chars=$(wc -c < "$output_file" | tr -d ' ')
            echo -e "${GREEN}Captured to: $output_file ($lines lines, $chars chars)${NC}"
        else
            echo -e "${RED}Capture failed - dump file not found${NC}"
            exit 1
        fi
        ;;

    diff-text|dt)
        # Compare two terminal text captures
        # Usage: diff-text [file1] [file2]
        file1="${2:-/tmp/clauntty_before.txt}"
        file2="${3:-/tmp/clauntty_after.txt}"

        if [ ! -f "$file1" ]; then
            echo -e "${RED}File not found: $file1${NC}"
            exit 1
        fi
        if [ ! -f "$file2" ]; then
            echo -e "${RED}File not found: $file2${NC}"
            exit 1
        fi

        if diff -q "$file1" "$file2" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ No differences${NC}"
        else
            echo -e "${RED}✗ Differences found:${NC}"
            diff --color=always "$file1" "$file2" || true
        fi
        ;;

    verify-render|vr)
        # Verify terminal rendering is not broken
        # Usage: verify-render [min_lines]
        min_lines="${2:-10}"
        tmp_file="/tmp/clauntty_verify.txt"

        $0 capture-text "$tmp_file"

        if [ ! -s "$tmp_file" ]; then
            echo -e "${RED}✗ FAIL: Empty terminal (blank screen)${NC}"
            exit 1
        fi

        lines=$(wc -l < "$tmp_file" | tr -d ' ')
        if [ "$lines" -lt "$min_lines" ]; then
            echo -e "${YELLOW}⚠ WARNING: Only $lines lines (expected >= $min_lines)${NC}"
        fi

        # Check for prompt character
        if grep -q '[$#>]' "$tmp_file"; then
            echo -e "${GREEN}✓ Prompt visible${NC}"
        else
            echo -e "${YELLOW}⚠ No prompt character found${NC}"
        fi

        echo -e "${GREEN}✓ Render check passed ($lines lines)${NC}"
        ;;

    test-tab-switch|tts)
        # Test tab switching rendering
        # Usage: test-tab-switch
        echo -e "${BLUE}=== Tab Switch Render Test ===${NC}"

        # Capture tab 1 before
        echo -e "${BLUE}[1/4] Capturing tab 1 (before)...${NC}"
        $0 capture-text /tmp/clauntty_tab1_before.txt

        # Switch to tab 2
        echo -e "${BLUE}[2/4] Switching to tab 2...${NC}"
        $0 tap-tab 2 2
        sleep 1
        $0 verify-render

        # Switch back to tab 1
        echo -e "${BLUE}[3/4] Switching back to tab 1...${NC}"
        $0 tap-tab 1 2
        sleep 1

        # Capture tab 1 after
        echo -e "${BLUE}[4/4] Capturing tab 1 (after)...${NC}"
        $0 capture-text /tmp/clauntty_tab1_after.txt

        # Compare
        echo -e "${BLUE}Comparing before/after...${NC}"
        $0 diff-text /tmp/clauntty_tab1_before.txt /tmp/clauntty_tab1_after.txt

        echo -e "${GREEN}=== Test Complete ===${NC}"
        ;;

    test-rotation|tr)
        # Test rendering after rotation
        # Usage: test-rotation
        echo -e "${BLUE}=== Rotation Render Test ===${NC}"

        # Capture in portrait
        echo -e "${BLUE}[1/5] Ensuring portrait mode...${NC}"
        $0 rotate portrait
        sleep 1

        echo -e "${BLUE}[2/5] Capturing portrait...${NC}"
        $0 capture-text /tmp/clauntty_portrait.txt
        $0 verify-render

        # Rotate to landscape
        echo -e "${BLUE}[3/5] Rotating to landscape...${NC}"
        $0 rotate landscape
        sleep 1

        echo -e "${BLUE}[4/5] Verifying landscape render...${NC}"
        $0 verify-render

        # Rotate back to portrait
        echo -e "${BLUE}[5/5] Rotating back to portrait...${NC}"
        $0 rotate portrait
        sleep 1

        # Capture and compare
        $0 capture-text /tmp/clauntty_portrait_after.txt

        echo -e "${BLUE}Comparing portrait before/after rotation cycle...${NC}"
        $0 diff-text /tmp/clauntty_portrait.txt /tmp/clauntty_portrait_after.txt

        echo -e "${GREEN}=== Rotation Test Complete ===${NC}"
        ;;

    test-rotation-stress|trs)
        # Stress test: multiple rotations with text capture after each
        # Usage: test-rotation-stress [connection] [rotations]
        # Example: test-rotation-stress devbox 5
        connection="${2:-}"
        rotations="${3:-4}"

        echo -e "${BLUE}=== Rotation Stress Test ===${NC}"
        echo -e "Rotations: $rotations"
        echo ""

        # Build and launch if connection provided
        if [ -n "$connection" ]; then
            echo -e "${BLUE}[Setup] Building and launching with connection: $connection${NC}"
            $0 debug "$connection" --wait 5 --no-logs
        fi

        # Ensure portrait mode to start
        echo -e "${BLUE}[Setup] Starting in portrait mode...${NC}"
        $0 rotate portrait
        sleep 1

        # Capture baseline
        echo -e "${BLUE}[Baseline] Capturing initial terminal state...${NC}"
        $0 capture-text /tmp/clauntty_rotation_baseline.txt
        baseline_lines=$(wc -l < /tmp/clauntty_rotation_baseline.txt | tr -d ' ')
        baseline_chars=$(wc -c < /tmp/clauntty_rotation_baseline.txt | tr -d ' ')
        echo -e "${GREEN}Baseline: $baseline_lines lines, $baseline_chars chars${NC}"
        echo ""
        echo -e "${YELLOW}--- Baseline Text ---${NC}"
        cat /tmp/clauntty_rotation_baseline.txt
        echo -e "${YELLOW}--- End Baseline ---${NC}"
        echo ""

        # Track failures
        failures=0

        # Rotation cycle
        for i in $(seq 1 $rotations); do
            echo -e "${BLUE}[Rotation $i/$rotations]${NC}"

            # Alternate between landscape and portrait
            if [ $((i % 2)) -eq 1 ]; then
                orientation="Landscape"
                $0 rotate landscape 2>/dev/null
            else
                orientation="Portrait"
                $0 rotate portrait 2>/dev/null
            fi
            sleep 2  # Wait for Ghostty to finish re-rendering

            # Capture and verify
            capture_file="/tmp/clauntty_rotation_$i.txt"
            $0 capture-text "$capture_file" 2>/dev/null

            current_lines=$(wc -l < "$capture_file" | tr -d ' ')
            current_chars=$(wc -c < "$capture_file" | tr -d ' ')

            # Check for significant text loss (>20% fewer chars)
            threshold=$((baseline_chars * 80 / 100))
            if [ "$current_chars" -lt "$threshold" ]; then
                echo -e "  → $orientation: ${RED}FAIL: $current_lines lines, $current_chars chars (lost >20%)${NC}"
                failures=$((failures + 1))
            elif [ "$current_chars" -lt "$baseline_chars" ]; then
                echo -e "  → $orientation: ${YELLOW}WARN: $current_lines lines, $current_chars chars${NC}"
            else
                echo -e "  → $orientation: ${GREEN}OK: $current_lines lines, $current_chars chars${NC}"
            fi

            # Always show the captured text
            echo -e "${YELLOW}--- $orientation Text ---${NC}"
            cat "$capture_file"
            echo ""
            echo -e "${YELLOW}--- End ---${NC}"
            echo ""
        done

        # Return to portrait
        echo ""
        echo -e "${BLUE}[Cleanup] Returning to portrait...${NC}"
        $0 rotate portrait
        sleep 1

        # Final comparison
        echo ""
        echo -e "${BLUE}[Final] Capturing final state...${NC}"
        $0 capture-text /tmp/clauntty_rotation_final.txt
        final_lines=$(wc -l < /tmp/clauntty_rotation_final.txt | tr -d ' ')
        final_chars=$(wc -c < /tmp/clauntty_rotation_final.txt | tr -d ' ')

        echo ""
        echo -e "${BLUE}=== Results ===${NC}"
        echo "  Baseline: $baseline_lines lines, $baseline_chars chars"
        echo "  Final:    $final_lines lines, $final_chars chars"

        # Show diff if different
        if ! diff -q /tmp/clauntty_rotation_baseline.txt /tmp/clauntty_rotation_final.txt > /dev/null 2>&1; then
            echo ""
            echo -e "${YELLOW}Differences between baseline and final:${NC}"
            diff --color=always /tmp/clauntty_rotation_baseline.txt /tmp/clauntty_rotation_final.txt || true
        fi

        echo ""
        if [ $failures -gt 0 ]; then
            echo -e "${RED}=== FAILED: $failures rotation(s) had significant text loss ===${NC}"
            exit 1
        else
            echo -e "${GREEN}=== PASSED: All rotations maintained text ===${NC}"
        fi
        ;;

    test-pause-resume|tpr)
        # Run pause/resume/idle test suite
        if [ -z "$2" ]; then
            echo "Usage: $0 test-pause-resume <connection_name>"
            echo "Example: $0 tpr devbox"
            exit 1
        fi
        "$SCRIPT_DIR/test-pause-resume.sh" "$2"
        ;;

    stream-pause-logs|spl)
        # Stream logs filtered for pause/resume/idle messages
        echo -e "${BLUE}Streaming pause/resume/idle logs (Ctrl+C to stop)...${NC}"
        xcrun simctl spawn booted log stream --level debug \
            --predicate 'subsystem == "com.clauntty" AND (message CONTAINS "pause" OR message CONTAINS "resume" OR message CONTAINS "idle" OR message CONTAINS "backgrounded" OR message CONTAINS "activated")'
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

Debug (all-in-one):
  debug [conn] [options]   Build, install, launch, screenshot, show logs
    Options:
      --tabs "spec"        Open multiple tabs (e.g., "0,1" or "0,new,:3000")
      --type|-t "text"     Type text after launching
      --wait|-w N          Wait N seconds before screenshot (default: 8)
      --logs|-l TIME       Show logs from last TIME (default: 30s)
      --no-logs            Don't show logs
      --no-build           Skip build step
  quick|q [conn] [opts]    Same as 'debug --no-build'

Tab Helpers:
  tabs [N]                 Show tap coordinates for N tabs (default: 2)
  tap-tab <num> [total]    Tap tab number (1-indexed, default total: 2)
  type-tab <n> <t> "text"  Switch to tab n (of t) and type text
  run-tab <n> <t> "cmd"    Switch to tab n, type cmd, press enter
  enter                    Press enter key

Interaction (runs inside simulator):
  tap <x> <y>              Tap at coordinates
  swipe <direction>        Swipe up/down/left/right
  type "text"              Type text
  key <keycode>            Send key (40=return, 41=esc, 43=tab)
  button <name>            Press button (home, lock, siri)
  screenshot [name]        Take screenshot

Convenience:
  tap-add                  Tap Add button
  tap-terminal             Tap terminal center
  tap-close                Tap close/back
  tap-save                 Tap Save button

Test Sequences:
  test-keyboard            Keyboard accessory screenshot
  test-connections         Connections list screenshot
  test-new-connection      New connection form screenshot
  test-flow                Full UI flow with screenshots

Logs & Debugging:
  logs [TIME]              Stream logs, or show last TIME (e.g., 30s, 1m)
  ui [filter]              List UI elements with tap coordinates
  settings                 Show saved connections from app prefs

Rotation:
  rotate|rot <orientation> Rotate to orientation (portrait, landscape, left, right)
  rotate-left|rl           Rotate simulator left
  rotate-right|rr          Rotate simulator right

Render Testing:
  capture-text|ct [file]   Capture terminal text to file (default: /tmp/clauntty_capture.txt)
  diff-text|dt [f1] [f2]   Compare two text captures
  verify-render|vr [lines] Verify terminal rendered correctly (check for blank screen)
  test-tab-switch|tts      Full tab switch render test (capture, switch, compare)
  test-rotation|tr         Full rotation render test (portrait -> landscape -> portrait)
  test-rotation-stress|trs Stress test with multiple rotations, prints text each time
                           Usage: trs [connection] [num_rotations]

Power Management Testing:
  test-pause-resume|tpr    Test pause/resume/idle functionality
                           Usage: tpr <connection_name>
  stream-pause-logs|spl    Stream logs filtered for pause/resume/idle messages

Examples:
  $0 debug devbox                    # Full debug cycle connecting to devbox
  $0 debug devbox --tabs "0,1"       # Open 2 existing sessions
  $0 debug devbox --tabs "0,new"     # 1 existing + 1 new session
  $0 debug devbox -t "ls -la"        # Connect and type command
  $0 quick devbox                    # Skip build, just reinstall & test
  $0 tabs 3                          # Show coordinates for 3 tabs
  $0 tap-tab 2 3                     # Tap tab 2 (of 3 total)
  $0 logs 1m                         # Show last 1 minute of logs

Render Testing:
  $0 capture-text before.txt         # Capture terminal text
  $0 tap-tab 2 2 && sleep 1          # Switch tabs
  $0 capture-text after.txt          # Capture again
  $0 diff-text before.txt after.txt  # Compare
  $0 test-tab-switch                 # Or use the all-in-one test
  $0 trs devbox 6                    # Rotation stress: 6 rotations with text output

Screenshots: $SCREENSHOTS_DIR
EOF
        ;;
esac
