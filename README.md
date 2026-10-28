# Clauntty

A terminal for iPhone and Mac, built for running Claude Code on your own machines and keeping up
with it from wherever you are.

You start Claude in a terminal on your Mac or a server. Clauntty keeps that session alive on the
host, so you can pick it up on your phone, put the phone away mid-task, and come back to the same
screen on your laptop. You see which agents are working, which are done and which need you, and
you answer them by typing, talking, or commenting on the code they changed.

No tmux, no accounts, no telemetry. The host side is one small binary the app installs over SSH.

## What it does

**Sessions that don't end.** Every pane runs under [rtach](https://github.com/eriklangille/rtach),
a small session daemon the app deploys to the host on first connect. Closing the app, losing
signal, switching Wi-Fi or restarting the phone doesn't end anything: on reconnect you get the
screen and recent scrollback back. The same session opens on the phone, the Mac app, or a plain
`ssh` terminal, and the device you're typing on decides its size.

**Built around agents.** Claude Code's hooks (installed with rtach) tell the app what each pane's
agent is doing: working, blocked on you, or done, with the prompt it's working on. The phone shows
a card per workspace with that state; the Mac app shows it in the sidebar. When an agent finishes
or needs you and the app isn't open, you get a notification.

**Workspaces and split panes.** Each tab is a workspace on the host, with panes split side by side
or stacked. The layout lives on the host, so the phone and the Mac show the same workspaces in the
same order.

**The `clauntty` command.** Inside any session, `clauntty` (installed with rtach) lets you, or the
agent, drive the app:

| Command | What it does |
|---------|--------------|
| `clauntty show shot.png` | Show images or videos in the app's viewer |
| `clauntty tab 3000` | Open a local web server in a tab, forwarded over SSH |
| `clauntty open <url>` | Open a URL on the phone (localhost ports forwarded) |
| `clauntty ws new -- claude` | Open workspaces, tabs and split panes, optionally running a command |
| `clauntty review notes.json` | Hand a code change to you as a review (below) and wait for your comments |

**Code review.** An agent can send you its change as a review: the diff in reading order, the
parts that need a careful look first and mechanical changes folded away, with syntax highlighting
and a few comments of its own on the lines that matter. You comment on a line or a run of lines,
reply to its comments, and press Send; your comments go back to the agent that asked. On the Mac
the review sits beside the agent's pane, so its chat stays in view.

**Voice.** Dictate into the terminal with an on-device speech model
([Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) through
[FluidAudio](https://github.com/FluidInference/FluidAudio)); nothing leaves the phone. There's also
a voice agent you can talk to hands-free, which reads your panes and types into them (it needs an
xAI API key).

**A real terminal.** Rendering is [Ghostty](https://ghostty.org)'s, on Metal, with its themes,
Unicode and colour support. On the phone, a key bar has Esc, Tab, Ctrl, arrows and the mic.

**Tailscale built in.** The app can join your tailnet itself, so hosts on it are reachable without
the Tailscale app or a VPN profile.

**The Mac app** opens hosts from `~/.ssh/config` (including `ProxyJump`), and terminals on the Mac
itself, which the phone can then open too.

## Requirements

- macOS with **Xcode** (the full app: iOS SDK, simulator, signing), and its Metal toolchain for
  Ghostty's shaders: `xcodebuild -downloadComponent MetalToolchain` (since Xcode 26 it's a separate
  download)
- **Zig 0.16** (`brew install zig`) for Ghostty and rtach
- **Go** (`brew install go`) for the Tailscale framework; any recent version, the build script
  fetches the one libtailscale pins
- **Python 3** for the highlighting framework's build script
- An **Apple ID** in Xcode for the simulator and your own devices
- iPhone on **iOS 17** or later; Mac on **macOS 14** or later

Hosts need SSH and nothing else: rtach is copied over (Linux x86_64 and arm64, glibc or musl;
macOS).

## Building

### 1. Clone the repos side by side

The app builds against its siblings by relative path, so the layout matters:

```bash
mkdir clauntty && cd clauntty
git clone https://github.com/eriklangille/clauntty.git clauntty
git clone -b clauntty https://github.com/eriklangille/ghostty.git ghostty
git clone https://github.com/eriklangille/rtach.git rtach
git clone -b clauntty https://github.com/eriklangille/libtailscale.git libtailscale
```

```
clauntty/
├── clauntty/       # the app, iOS and macOS (this repo)
├── ghostty/        # Ghostty fork, branch clauntty: the terminal
├── rtach/          # the session daemon and the clauntty command
└── libtailscale/   # Tailscale's embeddable library, fork, branch clauntty
```

### 2. Build the frameworks and rtach

```bash
# Ghostty: GhosttyKit.xcframework (a few minutes the first time)
cd ghostty
zig build -Demit-xcframework -Demit-macos-app=false -Doptimize=ReleaseFast -Dsentry=false
cd ..

# rtach for every host platform, copied into the app's resources
cd rtach && zig build cross && cd ..

cd clauntty
# Tailscale: TailscaleKit.xcframework
./scripts/build-tailscalekit.sh
# Syntax highlighting for code review: HighlightKit.xcframework (about 30 s)
python3 scripts/build-highlightkit.py
```

`Frameworks/` holds a link to each of the three; check they all resolve before building the app:

```bash
ls Frameworks/*/Info.plist
```

### 3. Build the app

From `clauntty/clauntty`:

```bash
./scripts/sim.sh run       # iOS simulator: build, install, launch (sim.sh help for more)
./scripts/device.sh run    # the iPhone connected by cable or on the same Wi-Fi
./scripts/mac.sh run       # the Mac app
```

Or open `Clauntty.xcodeproj` (iOS) or `ClaunttyMac.xcodeproj` (macOS) in Xcode.

`device.sh` builds Debug; `CONFIG=Release ./scripts/device.sh run` for a Release build, which is
what to judge speed on. `sim.sh` drives the simulator with
[IDB](https://fbidb.io/): run `./scripts/setup-idb.sh` once.

### Building under your own Apple ID

Open the project in Xcode, select the Clauntty target, and under **Signing & Capabilities** pick
your team; Xcode sets up signing. To ship your own build, change these too:

| What | Where | Current value |
|------|-------|---------------|
| Bundle ID | Xcode → Target → Signing & Capabilities | `com.octerm.clauntty` |
| Team ID | Xcode → Target → Signing & Capabilities | `65533RB4LC` |
| Team ID | `ExportOptions.plist` → `teamID` | `65533RB4LC` |
| URL scheme | `Clauntty/Info.plist` → `CFBundleURLSchemes` | `clauntty` |

## Testing against a throwaway host

Point the app at a test SSH server rather than a machine with real sessions on it:

```bash
./scripts/docker-ssh/ssh-test-server.sh start            # with Docker
./scripts/docker-ssh/container-ssh-server.sh start       # with Apple's container, no Docker
```

Log in as `testuser` / `testpass`.

## How it works

```
 iPhone / Mac app                                   Host
┌────────────────────────────┐                ┌──────────────────────────────┐
│ SwiftUI                    │                │ rtach (one per pane)         │
│ SessionManager             │   SSH, one     │  PTY, screen, scrollback     │
│  workspaces, panes,        │   connection   │  agent state from hooks      │
│  reconnects                │◄──────────────►│  workspaces, clauntty CLI    │
│ GhosttyKit (Metal)         │   per host,    │        │                     │
│ SwiftNIO SSH               │   a channel    │        ▼                     │
└────────────────────────────┘   per pane     │ $SHELL → claude, vim, …      │
                                              └──────────────────────────────┘
```

Each pane is an SSH channel running `rtach`, which attaches to the pane's session on the host,
starting it if needed. rtach keeps the terminal state while no device is attached and replays it
when one comes back. Keystrokes go app → SSH → rtach → the PTY; output comes back the same way
into Ghostty, which draws it.

`CLAUDE.md` in each repo has the details: the protocol, the connection handling, the Mac app, code
review, debugging and logs.

## Dependencies

| Dependency | Used for |
|------------|----------|
| [Ghostty](https://github.com/eriklangille/ghostty) (fork) | Terminal emulation and Metal rendering |
| [rtach](https://github.com/eriklangille/rtach) | Session persistence on the host, the `clauntty` command |
| [libtailscale](https://github.com/eriklangille/libtailscale) (fork) | Embedded Tailscale |
| [tree-sitter](https://tree-sitter.github.io) and [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)'s queries | Highlighting in code review |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | SSH |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | On-device speech to text |
| [libxev](https://github.com/mitchellh/libxev) | Event loop for Ghostty and rtach |
