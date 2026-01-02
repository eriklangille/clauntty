# Clauntty - iOS SSH Terminal with Ghostty

iOS SSH terminal using **libghostty** for GPU-accelerated rendering + **SwiftNIO SSH** for connections.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI Views              Direct I/O          SwiftNIO SSH │
│  ┌──────────────┐         ┌───────────┐      ┌────────────┐  │
│  │ Terminal UI  │ ──────► │ SSH Data  │ ───► │ SSH Channel│  │
│  │ + Keyboard   │ ◄────── │ Flow      │ ◄─── │ (remote)   │  │
│  └──────────────┘         └───────────┘      └────────────┘  │
│         │                                          │         │
│         ▼                                          ▼         │
│  GhosttyKit.xcframework                     Remote Server    │
│  (Metal rendering)                                           │
└─────────────────────────────────────────────────────────────┘
```

**Data Flow**:
- **SSH → Terminal**: `SSHChannelHandler.channelRead()` → `ghostty_surface_write_pty_output()` → rendered
- **Keyboard → SSH**: `insertText()` → `SSHConnection.sendData()` → SSH channel

## Repository Layout

```
~/Projects/clauntty/
├── clauntty/          # iOS app (this repo)
├── ghostty/           # Forked ghostty (git@github.com:eriklangille/ghostty.git)
└── libxev/            # Local libxev fork (iOS fixes)
```

## Key Files

| Location | Purpose |
|----------|---------|
| `../ghostty/include/ghostty.h` | C API header |
| `../ghostty/src/termio/Exec.zig` | iOS process/PTY handling |
| `../ghostty/src/renderer/Metal.zig` | Metal renderer |
| `../libxev/src/backend/kqueue.zig` | Event loop (iOS fixes) |
| `Clauntty/Core/Terminal/` | GhosttyApp, TerminalSurface, GhosttyBridge |
| `Clauntty/Core/SSH/` | SSHConnection, SSHAuthenticator |
| `Clauntty/Core/Terminal/GhosttyApp.swift` | GhosttyApp + Logger extension with `debugOnly()`, `verbose()` |

## Build Commands

**Always use `./scripts/sim.sh` instead of raw `xcrun simctl` or `xcodebuild` commands.**

```bash
# Build GhosttyKit (after ghostty changes)
cd ../ghostty && zig build -Demit-xcframework

# Build & Run (use sim.sh)
./scripts/sim.sh build              # Build app
./scripts/sim.sh run                # Build, install, launch
./scripts/sim.sh debug devbox       # Full cycle: build, install, launch, screenshot, logs
./scripts/sim.sh quick devbox       # Skip build, just reinstall (faster iteration)

# Multi-Tab Debugging (last tab is active on launch)
./scripts/sim.sh debug devbox --tabs "0,1"    # 2 existing sessions (tab 2 active)
./scripts/sim.sh debug devbox --tabs "0,new"  # 1 existing + 1 new (new tab active)
./scripts/sim.sh tap-tab 1 2                   # Switch to tab 1 (of 2 total)
./scripts/sim.sh run-tab 1 2 "ls -la"         # Run command in tab 1

# Logs & Screenshots
./scripts/sim.sh logs 30s            # Show last 30 seconds
./scripts/sim.sh screenshot myshot   # Save screenshot

# See all commands
./scripts/sim.sh help

# Run tests
xcodebuild test -project Clauntty.xcodeproj -scheme ClaunttyTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Build for physical iPhone
xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
  -destination 'platform=iOS,name=iPhone 16' -quiet build

# Install and launch on iPhone
xcrun devicectl device install app --device "iPhone 16" \
  ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphoneos/Clauntty.app
xcrun devicectl device process launch --device "iPhone 16" com.clauntty.app
```

## Logging & Debugging

### Log Levels

The app uses a tiered logging system optimized for performance:

| Method | When Logged | Use Case |
|--------|-------------|----------|
| `Logger.clauntty.error()` | Always | Errors, failures |
| `Logger.clauntty.warning()` | Always | Warnings |
| `Logger.clauntty.debugOnly()` | DEBUG builds only | Lifecycle events, state changes |
| `Logger.clauntty.verbose()` | DEBUG + CLAUNTTY_VERBOSE=1 | Per-packet, per-frame, per-touch |

**When to use each level:**
- **`error/warning`**: Problems that need attention
- **`debugOnly()`**: Session lifecycle, tab switching, connection events, one-time init - things you want during normal debugging
- **`verbose()`**: High-frequency logs that would flood output - per-keystroke, per-SSH-packet, per-frame animation, hit tests, layout passes

**Performance:**
- **Release builds**: `debugOnly()` and `verbose()` compiled out entirely (zero overhead)
- **Debug builds**: `verbose()` has single boolean check - negligible overhead
- **`@autoclosure`**: Message strings only constructed if logging is enabled

### Viewing Logs

```bash
# Stream logs live (shows debugOnly level)
./scripts/sim.sh logs

# Show last N seconds/minutes
./scripts/sim.sh logs 30s
./scripts/sim.sh logs 5m

# Debug command shows logs at end
./scripts/sim.sh debug devbox

# Screenshot
./scripts/sim.sh screenshot myshot   # Save to screenshots/myshot.png

# Parse crash reports (simulator)
uv run scripts/parse_crash.py --latest        # Formatted view
uv run scripts/parse_crash.py --raw --latest  # Raw stack trace

# Pull crash reports from physical iPhone
idevicecrashreport -e /tmp/clauntty_crashes   # Pull all crashes to folder
ls /tmp/clauntty_crashes | grep -i clauntty   # List Clauntty crashes
uv run scripts/parse_crash.py /tmp/clauntty_crashes/Clauntty-YYYY-MM-DD-HHMMSS.ips
```

**Note:** `sim.sh` streams at debug level. Historical logs (`log show`) don't persist debug-level by default - use live streaming.

### Enable Verbose Logging

Verbose logs are disabled by default (too noisy). Enable with `CLAUNTTY_VERBOSE=1`:

```bash
# sim.sh debug automatically sets CLAUNTTY_VERBOSE=1
./scripts/sim.sh debug devbox

# Manual: set environment variable before launch
SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted com.clauntty.app

# In Xcode: Edit Scheme → Run → Arguments → Environment Variables
# Add: CLAUNTTY_VERBOSE = 1
```

Expected: idle ~2 FPS (cursor blink), active output 30-100 FPS, low power max 33 FPS.

## GhosttyKit API

```c
// Init (MUST call ghostty_init() first!)
ghostty_app_t ghostty_app_new(ghostty_runtime_config_s*, ghostty_config_t);
ghostty_surface_t ghostty_surface_new(ghostty_app_t, ghostty_surface_config_s*);

// Lifecycle
void ghostty_app_tick(ghostty_app_t);
void ghostty_surface_set_size(ghostty_surface_t, uint32_t w, uint32_t h);
void ghostty_surface_set_focus(ghostty_surface_t, bool);

// Input (keyboard → terminal)
void ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
void ghostty_surface_text(ghostty_surface_t, const char*, size_t);

// Output (SSH → terminal display) - iOS-specific
void ghostty_surface_write_pty_output(ghostty_surface_t, const char*, size_t);
```

The `ghostty_surface_write_pty_output` function feeds data directly to the terminal for rendering, bypassing the PTY. This is used on iOS to display SSH output since no local process is spawned.

## Current Status

**Working:**
- Terminal surface rendering (Metal) ✓
- GhosttyKit initialization ✓
- Connection list UI ✓
- SSH connection wiring ✓
- Keyboard input → SSH ✓
- SSH output → Terminal display ✓
- SSH password authentication ✓
- SSH Ed25519 key authentication ✓
- Keyboard accessory bar (Esc, Tab, Ctrl, arrow nipple, ^C, ^L, ^D) ✓
- Paste menu near cursor ✓
- Terminal resize → SSH window change ✓
- Scrollback history (one-finger scroll) ✓
- Text selection + copy (long press to select) ✓
- Connection editing (swipe left → Edit) ✓
- Duplicate connection detection ✓

**TODO:**
- [ ] RSA/ECDSA key support
- [ ] Host key verification
- [ ] Multiple sessions/tabs
- [ ] rtach integration (session persistence)
- [ ] Extract rtach protocol parsing to separate Swift module (enables fast unit tests without simulator)

## rtach Integration

**rtach** (`../rtach/`) provides session persistence with scrollback. On SSH disconnect, the session survives and can be reattached.

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│  Remote Server                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌────────────────┐  │
│  │ SSH Channel │◄──►│   rtach     │◄──►│  $SHELL (bash) │  │
│  │             │    │ (scrollback)│    │                │  │
│  └─────────────┘    └─────────────┘    └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Integration Steps

1. **Bundle binaries** in app:
   - `rtach-x86_64-linux-musl` (117KB)
   - `rtach-aarch64-linux-musl` (114KB)

2. **On SSH connect**, check remote:
   ```bash
   test -x ~/.clauntty/bin/rtach && echo "exists"
   ```

3. **Upload if missing** via SFTP:
   ```swift
   // Detect arch
   let arch = sshExec("uname -m")  // x86_64 or aarch64
   // Upload matching binary
   sftp.upload(rtachBinary, to: "~/.clauntty/bin/rtach")
   sshExec("chmod +x ~/.clauntty/bin/rtach")
   ```

4. **Wrap shell command**:
   ```bash
   # Instead of: $SHELL
   ~/.clauntty/bin/rtach -A ~/.clauntty/sessions/{session-id} $SHELL
   ```

5. **On reconnect**, same command auto-reattaches with scrollback replay.

### Build rtach

```bash
cd ../rtach
zig build cross         # Build Linux binaries
ls zig-out/bin/rtach-*  # x86_64 + aarch64, ~100KB each

# Copy to iOS app resources (required after rtach changes)
cp zig-out/bin/rtach-* ../clauntty/Clauntty/Resources/rtach/

# Clean iOS build to pick up new binaries (Xcode caches resources)
xcodebuild -project ../clauntty/Clauntty.xcodeproj -scheme Clauntty clean
```

### Test rtach

```bash
cd ../rtach/tests
bun test                # 24 tests, all should pass
bun run load-test.ts    # Performance: ~16K msg/sec
```

## iOS Fixes Applied

### libxev mach_port Fix
**File**: `../libxev/src/backend/kqueue.zig`

Changed `.macos` checks to `.isDarwin()` to include iOS:
```zig
// Line 957 & 1073: .macos → .isDarwin()
```

ghostty's `build.zig.zon` uses local libxev: `.path = "../libxev"`

### Ghostty Exec.zig
**File**: `../ghostty/src/termio/Exec.zig`

- Skip process spawn on iOS (sandbox restriction)
- PTY created for external data source (SSH)

### Ghostty embedded.zig (iOS API)
**File**: `../ghostty/src/apprt/embedded.zig`

Added `ghostty_surface_write_pty_output()` function to write SSH data directly to terminal:
```zig
export fn ghostty_surface_write_pty_output(
    surface: *Surface,
    ptr: [*]const u8,
    len: usize,
) void {
    surface.core_surface.io.processOutput(ptr[0..len]);
}
```

### Metal.zig
**File**: `../ghostty/src/renderer/Metal.zig` line 127

- Fixed selector: `addSublayer` → `addSublayer:` (needs colon for ObjC parameter)

## Key Info

- **Bundle ID**: `com.clauntty.app`
- **iOS target**: 17.0+
- **Zig version**: 0.15.2+
- **Dependencies**: swift-nio-ssh 0.12.0, swift-nio 2.92.0
- Metal tests require simulator (headless XCTest won't work)

## Visual Testing

Golden screenshot comparison for rendering validation:

```bash
# Capture screenshot
xcrun simctl io booted screenshot /tmp/clauntty_actual.png

# Compare with golden (ImageMagick)
compare -metric AE /tmp/clauntty_actual.png Tests/Golden/terminal_empty.png null: 2>&1

# Generate diff image if pixels differ
compare /tmp/clauntty_actual.png Tests/Golden/terminal_empty.png /tmp/diff.png

# Update golden after intentional changes
xcrun simctl io booted screenshot Tests/Golden/terminal_empty.png
```

Store goldens in `Tests/Golden/` (e.g., `terminal_empty.png`, `terminal_colors.png`).

**Note**: Metal rendering only works in simulator, not headless XCTest.

## Terminal Text Capture (Render Testing)

Programmatically capture and compare terminal text to detect rendering bugs (blank screens, missing content).

### URL Scheme

The app registers `clauntty://` URL scheme:
- `clauntty://dump-text` - Captures visible terminal text to `/tmp/clauntty_dump.txt`

### sim.sh Commands

```bash
# Capture terminal text to file
./scripts/sim.sh capture-text [output_file]

# Compare two captures
./scripts/sim.sh diff-text [file1] [file2]

# Verify render isn't broken (checks for blank screen)
./scripts/sim.sh verify-render [min_lines]

# Full tab switch render test
./scripts/sim.sh test-tab-switch
```

### Test Tab Switching Rendering

```bash
# Setup: Open 2 tabs
./scripts/sim.sh debug devbox --tabs "0,new" --wait 5

# Run the full test (capture, switch, compare)
./scripts/sim.sh test-tab-switch

# Or manually:
./scripts/sim.sh capture-text /tmp/before.txt
./scripts/sim.sh tap-tab 2 2 && sleep 1
./scripts/sim.sh tap-tab 1 2 && sleep 1
./scripts/sim.sh capture-text /tmp/after.txt
./scripts/sim.sh diff-text /tmp/before.txt /tmp/after.txt
```

### How It Works

1. `captureVisibleText()` in `TerminalSurfaceView` uses Ghostty's `ghostty_surface_read_text()` API
2. URL scheme triggers via `xcrun simctl openurl booted "clauntty://dump-text"`
3. Active terminal captures text and writes to `/tmp/clauntty_dump.txt`
4. sim.sh reads the file from simulator filesystem

### Key Files

| File | Purpose |
|------|---------|
| `Clauntty/Core/Terminal/TerminalSurface.swift` | `captureVisibleText()` method |
| `Clauntty/ClaunttyApp.swift` | URL scheme handler |
| `Clauntty/Info.plist` | URL scheme registration |
| `scripts/sim.sh` | CLI commands for capture/diff/verify |

## SSH Testing

### Docker Test Server (Recommended)

Spin up an isolated SSH server for safe testing:

```bash
# Start the test server (uses port 22 by default)
./scripts/docker-ssh/ssh-test-server.sh start

# Or use a different port if 22 is in use:
# SSH_PORT=2222 ./scripts/docker-ssh/ssh-test-server.sh start

# Test credentials:
# Host: localhost
# Port: 22 (or SSH_PORT if overridden)
# Username: testuser
# Password: testpass

# SSH key is auto-generated at:
# scripts/docker-ssh/keys/test_key

# Stop when done
./scripts/docker-ssh/ssh-test-server.sh stop
```

### Local Mac SSH (Alternative)

Enable on Mac: System Settings > General > Sharing > Remote Login

In simulator, connect to `localhost:22` with your Mac username.

## Simulator Automation (IDB)

Facebook IDB allows automated interaction with the simulator without taking over your screen. Taps, swipes, and text input run inside the simulator process.

### Setup

```bash
# Install IDB (one-time setup)
./scripts/setup-idb.sh
```

This installs:
- `idb_companion` (Homebrew, from facebook/fb tap)
- `idb` Python client (via uv)

### Usage

```bash
# Boot simulator and connect IDB
./scripts/sim.sh boot

# Basic interactions
./scripts/sim.sh tap 196 400        # Tap at coordinates
./scripts/sim.sh swipe up           # Swipe direction
./scripts/sim.sh type "hello"       # Type text

# Build and run
./scripts/sim.sh build              # Build app
./scripts/sim.sh run                # Build, install, launch
./scripts/sim.sh run --preview-terminal  # Launch in terminal mode

# Screenshots
./scripts/sim.sh screenshot myshot  # Save to screenshots/myshot.png

# See all commands
./scripts/sim.sh help
```

### Debug Commands (All-in-One)

The `debug` command combines build, install, launch, screenshot, and logs into one step:

```bash
# Full debug cycle: build → install → launch → wait → screenshot → show logs
./scripts/sim.sh debug devbox                    # Connect to 'devbox' profile
./scripts/sim.sh debug devbox -t "ls -la"        # Type command after connecting
./scripts/sim.sh debug devbox --wait 15          # Wait 15s before screenshot
./scripts/sim.sh debug devbox --logs 1m          # Show last 1 minute of logs
./scripts/sim.sh debug devbox --no-logs          # Skip log output

# Quick debug (skip build, just reinstall and launch)
./scripts/sim.sh quick devbox                    # Faster iteration
./scripts/sim.sh q devbox -t "echo test"         # Shorthand
```

Options:
- `--tabs "spec"` - Open multiple tabs (see Multi-Tab below)
- `--type|-t "text"` - Type text after app launches
- `--wait|-w N` - Wait N seconds before screenshot (default: 8)
- `--logs|-l TIME` - Show logs from last TIME (default: 30s)
- `--no-logs` - Don't show logs
- `--no-build` - Skip build step (same as `quick`)

### Multi-Tab Debugging

Open multiple tabs for testing tab switching and rendering:

```bash
# Tab spec format: comma-separated list of:
#   N     = rtach session index (0-based)
#   new   = create new session
#   :PORT = port forward (web tab)

./scripts/sim.sh debug devbox --tabs "0,1"       # 2 existing sessions
./scripts/sim.sh debug devbox --tabs "0,new"     # 1 existing + 1 new
./scripts/sim.sh debug devbox --tabs "0,:3000"   # 1 terminal + port 3000

# Show tap coordinates for tabs
./scripts/sim.sh tabs 2                          # Coordinates for 2 tabs
./scripts/sim.sh tabs 3                          # Coordinates for 3 tabs

# Switch between tabs
./scripts/sim.sh tap-tab 1 2                     # Tap tab 1 (of 2 total)
./scripts/sim.sh tap-tab 2 2                     # Tap tab 2 (of 2 total)

# Type in specific tabs
./scripts/sim.sh type-tab 1 2 "hello"            # Switch to tab 1 and type
./scripts/sim.sh run-tab 1 2 "ls -la"            # Switch to tab 1, type, press enter
./scripts/sim.sh run-tab 2 2 "echo test"         # Run command in tab 2
./scripts/sim.sh enter                           # Just press enter
```

### Logs

```bash
./scripts/sim.sh logs              # Stream logs (Ctrl+C to stop)
./scripts/sim.sh logs 30s          # Show last 30 seconds
./scripts/sim.sh logs 2m           # Show last 2 minutes
```

### UI Inspection

```bash
# Get UI element coordinates (uses IDB accessibility)
./scripts/sim.sh ui                 # List all UI elements with tap coordinates
./scripts/sim.sh ui button          # Filter to elements matching "button"
./scripts/sim.sh ui "Docker"        # Filter to elements matching "Docker"

```

### Test Sequences

```bash
./scripts/sim.sh test-keyboard      # Screenshot keyboard accessory bar
./scripts/sim.sh test-connections   # Screenshot connection list
./scripts/sim.sh test-flow          # Full flow with multiple screenshots
```

### Preview Modes

Launch app with specific UI state for testing:

```bash
./scripts/sim.sh launch --preview-terminal      # Terminal view
./scripts/sim.sh launch --preview-keyboard      # Terminal + keyboard hint
./scripts/sim.sh launch --preview-connections   # Connection list
./scripts/sim.sh launch --preview-new-connection # New connection form
```

Screenshots are saved to `screenshots/` directory.
