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

## Build Commands

```bash
# Build GhosttyKit (after ghostty changes)
cd ../ghostty && zig build -Demit-xcframework

# Build Clauntty
xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet build

# Run in simulator
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphonesimulator/Clauntty.app
xcrun simctl launch booted com.clauntty.app

# Run tests
xcodebuild test -project Clauntty.xcodeproj -scheme ClaunttyTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Logging & Debugging

```bash
# Stream app logs
xcrun simctl spawn booted log stream --level=info \
  --predicate 'subsystem == "com.clauntty" OR subsystem == "com.mitchellh.ghostty"'

# View recent logs
xcrun simctl spawn booted log show --predicate 'subsystem == "com.clauntty"' --last 5m

# Screenshot
xcrun simctl io booted screenshot /tmp/clauntty.png

# Parse crash reports
uv run scripts/parse_crash.py --latest        # Formatted view
uv run scripts/parse_crash.py --raw --latest  # Raw stack trace
```

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

# Get UI element coordinates (uses IDB accessibility)
./scripts/sim.sh ui                 # List all UI elements with tap coordinates
./scripts/sim.sh ui button          # Filter to elements matching "button"
./scripts/sim.sh ui "Docker"        # Filter to elements matching "Docker"

# Test sequences (automated UI validation)
./scripts/sim.sh test-keyboard      # Screenshot keyboard accessory bar
./scripts/sim.sh test-connections   # Screenshot connection list
./scripts/sim.sh test-flow          # Full flow with multiple screenshots

# Convenience taps (pre-defined UI locations)
./scripts/sim.sh tap-add            # Tap Add button
./scripts/sim.sh tap-first-connection
./scripts/sim.sh tap-terminal       # Focus terminal
./scripts/sim.sh tap-close          # Tap back/close

# See all commands
./scripts/sim.sh help
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
