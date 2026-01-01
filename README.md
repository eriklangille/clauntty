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

- Xcode 15+
- iOS 17.0+
- Zig 0.15.2+ (for building GhosttyKit and rtach)

## Building

### Prerequisites

Build the dependencies first (from monorepo root):

```bash
# Build GhosttyKit framework
cd ../ghostty && zig build -Demit-xcframework -Doptimize=ReleaseFast

# Build rtach binaries (auto-copies to Resources/)
cd ../rtach && zig build cross
```

### Simulator

Always use `sim.sh` for simulator builds:

```bash
./scripts/sim.sh run              # Build, install, launch
./scripts/sim.sh debug devbox     # Full debug cycle with logs
./scripts/sim.sh quick devbox     # Skip build, faster iteration
./scripts/sim.sh help             # All commands
```

### Physical Device

```bash
xcodebuild -project Clauntty.xcodeproj -scheme Clauntty \
  -destination 'platform=iOS,name=iPhone 16' -quiet build

xcrun devicectl device install app --device "iPhone 16" \
  ~/Library/Developer/Xcode/DerivedData/Clauntty-*/Build/Products/Debug-iphoneos/Clauntty.app
```

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
  -destination 'platform=iOS Simulator,name=iPhone 16'

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
