# Clauntty

iOS SSH terminal with persistent sessions and GPU-accelerated rendering.

## Why Clauntty?

Most mobile terminals lose your session when the app backgrounds or your connection drops. Clauntty solves this with **automatic session persistence** - no tmux or screen required.

### Key Features

**Persistent Sessions (via rtach)**
- Sessions survive app backgrounding, connection drops, and device restarts
- Full scrollback history replayed on reconnect
- Zero server-side setup - rtach binary auto-deployed on first connect
- Battery-optimized pause/resume protocol

**GPU-Accelerated Rendering (via Ghostty)**
- Metal-based renderer from [Ghostty](https://ghostty.org)
- Smooth 60fps scrolling and output
- Proper Unicode, emoji, and color support
- 20+ built-in themes (Dracula, Monokai, Solarized, etc.)

**Native iOS Experience**
- Multi-tab with swipe gestures
- Keyboard accessory bar (Esc, Tab, Ctrl, arrows, ^C/^L/^D)
- Text selection with long-press
- Port forwarding with in-app browser
- SSH key authentication (Ed25519)

**Open Source**
- No accounts, no telemetry, no subscriptions

## Requirements

- **Xcode 15+** (full app, not just command-line tools — needed for iOS SDK, simulator, and signing)
- **iOS 17.0+**
- **Zig 0.15.2+** — install via `brew install zig` or from [ziglang.org/download](https://ziglang.org/download/)
- **Metal Toolchain** — required by GhosttyKit build. Install via `xcodebuild -downloadComponent MetalToolchain` (the Justfile installs it automatically)
- **Apple Developer account** — free Apple ID works for simulator and personal device builds; paid ($99/year) required for TestFlight distribution

## Building with Just

The project includes a [Justfile](https://just.systems) that automates the entire build pipeline — cloning repos, checking prerequisites, building dependencies, and compiling the app.

```bash
brew install just
```

### Quick start

```bash
git clone https://github.com/eriklangille/clauntty.git clauntty && cd clauntty
just deps               # Clone repos, check environment, build ghostty + rtach, link framework
just build-only         # Build for iOS Simulator
```

### All recipes

```bash
just -l                 # List all available recipes

# Setup & checks
just setup              # Clone sibling repos (ghostty, rtach, libxev) if missing
just doctor             # Run preflight checks (Xcode, Zig, Metal Toolchain, layout)

# Dependencies
just deps               # Full dependency pipeline (setup + doctor + build + link)
just deps-ghostty       # Build GhosttyKit xcframework only
just deps-rtach         # Build rtach cross-compiled binaries only
just deps-link          # Symlink GhosttyKit.xcframework into Frameworks/
just copy-rtach         # Copy rtach binaries into app resources

# Build & test
just build              # Full build (deps + app)
just build-only         # Build for simulator (skip deps, faster iteration)
just test               # Run unit tests on simulator

# Release
just archive            # Build .xcarchive for device (signing required)
just ipa                # Export .ipa from archive

# Configuration
just configure <bundle_id> <team_id> <url_scheme>  # Patch fork identity

# Clean
just clean              # Clean everything (Xcode, DerivedData, zig outputs, framework link)
just clean-xcode        # Xcode clean only
just clean-derived      # Remove DerivedData
just clean-zig          # Remove zig-out/zig-cache in ghostty + rtach
just clean-link         # Remove framework symlink
```

Most variables can be overridden via environment:

```bash
SIM_DEVICE="iPhone 16 Pro" just build-only    # Different simulator
CONFIGURATION=Release just build-only          # Release build
```

## Building manually

If you prefer not to use Just, follow these steps.

### 1. Clone the repos

The project is a monorepo with 4 sibling repos. **The directory layout matters** — ghostty references `../libxev` at build time.

```bash
mkdir clauntty && cd clauntty
git clone https://github.com/eriklangille/clauntty.git clauntty
git clone -b clauntty https://github.com/eriklangille/ghostty.git ghostty
git clone https://github.com/eriklangille/rtach.git rtach
git clone https://github.com/eriklangille/libxev.git libxev
```

You should end up with:
```
clauntty/
├── clauntty/   # iOS app (this repo)
├── ghostty/    # Ghostty fork (terminal emulator)
├── rtach/      # Session persistence daemon
└── libxev/     # Event loop (iOS fixes)
```

### 2. Build dependencies

Build in this order — each step depends on the previous:

```bash
# 1. Build GhosttyKit framework (requires libxev at ../libxev)
cd ghostty && zig build -Demit-xcframework -Doptimize=ReleaseFast && cd ..

# 2. Build rtach Linux binaries
cd rtach && zig build cross && cd ..
```

After building, verify the framework symlink exists:
```bash
ls clauntty/Frameworks/GhosttyKit.xcframework
```
If missing, create it:
```bash
ln -s ../../ghostty/macos/GhosttyKit.xcframework clauntty/Frameworks/GhosttyKit.xcframework
```

### 3. Build the iOS app

#### Simulator

```bash
cd clauntty
./scripts/sim.sh run                    # Build, install, launch
./scripts/sim.sh debug <connection>     # Full debug cycle with logs
./scripts/sim.sh quick <connection>     # Skip build, faster iteration
./scripts/sim.sh help                   # All commands
```

> `<connection>` is a saved SSH connection profile name (e.g., `devbox`). Create one in the app's connection list UI first, or use the [Docker test server](#testing) for local testing.

`sim.sh` uses [Facebook IDB](https://fbidb.io/) for simulator automation. Install it first:
```bash
./scripts/setup-idb.sh
```

#### Physical Device

Replace `iPhone 16` with your device name (visible in Xcode → Window → Devices):

```bash
xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
  -destination 'platform=iOS,name=<YOUR DEVICE>' -quiet build

xcrun devicectl device install app --device "<YOUR DEVICE>" \
  ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphoneos/Clauntty.app
```

### Building your own fork

To ship under your own identity, use the Justfile:

```bash
just configure com.yourcompany.clauntty YOUR_TEAM_ID yourclauntty
```

Or update manually:

| What | Where | Current value |
|------|-------|---------------|
| Bundle ID | Xcode → Target → Signing & Capabilities | `com.octerm.clauntty` |
| Team ID | Xcode → Target → Signing & Capabilities | `65533RB4LC` |
| Team ID | `ExportOptions.plist` → `teamID` | `65533RB4LC` |
| URL scheme | `Clauntty/Info.plist` → `CFBundleURLSchemes` | `clauntty` |

The easiest way without Just: open `Clauntty.xcodeproj` in Xcode, select the Clauntty target, go to **Signing & Capabilities**, and pick your team. Xcode will update the bundle ID and signing automatically.

## Project Structure

```
Clauntty/
├── Core/
│   ├── Terminal/          # GhosttyApp, TerminalSurface, GhosttyBridge
│   ├── SSH/               # SSHConnection, SSHAuthenticator, RtachDeployer
│   ├── Session/           # SessionManager, Session
│   └── Storage/           # ConnectionStore, SSHKeyStore, KeychainHelper
├── Views/                 # SwiftUI views
├── Models/                # Data models
└── Resources/
    ├── rtach/             # Pre-built rtach binaries for deployment
    ├── Themes/            # Terminal color themes
    └── shell-integration/ # Shell scripts for title updates

RtachClient/               # Swift module for rtach protocol parsing
Frameworks/                # GhosttyKit.xcframework (symlink)
scripts/                   # Build and test automation
```

## Key Files

| File | Purpose |
|------|---------|
| `Core/Terminal/GhosttyApp.swift` | Ghostty C API wrapper, theme management |
| `Core/Terminal/TerminalSurface.swift` | UIViewRepresentable for Metal rendering |
| `Core/SSH/SSHConnection.swift` | SwiftNIO SSH client |
| `Core/SSH/RtachDeployer.swift` | rtach binary deployment, session listing |
| `Core/Session/SessionManager.swift` | Tab/session lifecycle management |
| `RtachClient/` | rtach protocol parsing (Swift) |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI Views                                              │
│  ┌──────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │ Terminal UI  │  │ Connection List │  │ Keyboard Bar   │  │
│  └──────┬───────┘  └─────────────────┘  └────────────────┘  │
│         │                                                    │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ SessionManager                                        │   │
│  │ - Manages tabs (terminal + web)                       │   │
│  │ - Connection pooling (reuse SSH to same server)       │   │
│  │ - Lazy reconnect (only active tab connected)          │   │
│  └──────┬───────────────────────────────────────────────┘   │
│         │                                                    │
│  ┌──────┴──────┐  ┌─────────────────┐  ┌────────────────┐   │
│  │ Session     │  │ GhosttyKit      │  │ RtachClient    │   │
│  │ (per tab)   │  │ (Metal render)  │  │ (protocol)     │   │
│  └──────┬──────┘  └────────┬────────┘  └───────┬────────┘   │
│         │                  │                    │            │
│         └──────────────────┴────────────────────┘            │
│                            │                                 │
│                    SSHConnection (SwiftNIO)                  │
└────────────────────────────┼─────────────────────────────────┘
                             │
                             ▼
                      Remote Server
                    (rtach + $SHELL)
```

## Data Flow

**Input**: User types → Keyboard → RtachClient (frame) → SSH channel → rtach server → PTY → shell

**Output**: Shell → PTY → rtach server → SSH channel → RtachClient (parse) → GhosttyKit → Metal

## Debugging

```bash
# Simulator logs
./scripts/sim.sh logs
./scripts/sim.sh logs 30s

# Physical device logs
idevicesyslog -u $(idevice_id -l) 2>&1 | grep -i clauntty

# Crash reports
uv run scripts/parse_crash.py --latest
```

## Testing

```bash
# Unit tests
xcodebuild test -project Clauntty.xcodeproj -scheme ClaunttyTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Local SSH test server (Docker)
./scripts/docker-ssh/ssh-test-server.sh start
# Connect to localhost:22, user: testuser, pass: testpass
```

## Dependencies

| Dependency | Purpose | Source |
|------------|---------|--------|
| GhosttyKit | Terminal emulation + Metal rendering | [eriklangille/ghostty](https://github.com/eriklangille/ghostty) |
| rtach | Session persistence daemon | [eriklangille/rtach](https://github.com/eriklangille/rtach) |
| libxev | Cross-platform event loop (iOS fixes) | [eriklangille/libxev](https://github.com/eriklangille/libxev) |
| swift-nio-ssh | SSH protocol | [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) |
