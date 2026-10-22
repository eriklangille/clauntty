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
- **Keyboard → SSH**: `insertText()` → `Session.sendData()` → the pane's SSH channel

**Connections** (`SessionManager+Connections.swift`): one SSH connection per host, shared. Each pane
is a channel on it running `rtach -a`; commands (deploys, `rtach ws`, listing, uploads) and port
forwards use the host's first connection. sshd allows 10 sessions per connection by default
(`MaxSessions`, every pane and running command is one), so a host gets another connection past
`panesPerConnection` (6) panes; a server that refuses a channel sooner sets that connection's
`paneLimit`. A pane takes its place when its connection is chosen (`paneConnection`) and gives it
back when its channel closes. Closing a pane closes only its channel. Only one connect per host runs
at a time (`connectingHosts`); the task records the new connection itself, so waiters find it.
`connect()` opens no shell: an unread login shell used to sit on the host for every connection.
rtach is checked once per host per launch (`hostDeployer`): one command for the binary's version
(deployed, and old sessions upgraded, only when it isn't this version); the rest of the deploy
(`finishDeploy`: helper scripts, the Claude hook, cleanup, spawnd) runs after, without holding up
panes. Data that reaches a session before `attach()` (the handshake can) is held for it
(`expectAttach`/`handleChannelData`).
Idle panes let their channel go (`releaseIdlePanes`, 2s after switching or attaching settles): each
host keeps the panes on screen, its 8 most recently shown (`Session.lastShownAt`) and busy agents'
panes; the rest `rest()`, keeping their terminal, and attach again when shown, without a Connecting
notice (`isResting`). Every attach's first output starts with a full reset (`resetBeforeReplay`):
rtach replays the screen and recent scrollback, which otherwise showed twice.

## Repository Layout

```
~/Projects/clauntty/
├── clauntty/          # iOS app (this repo)
├── ghostty/           # Forked ghostty (git@github.com:eriklangille/ghostty.git), branch clauntty
├── rtach/             # Session persistence daemon (bundled into Clauntty/Resources/rtach/)
└── libtailscale/      # Upstream libtailscale (github.com/tailscale/libtailscale); builds TailscaleKit.xcframework
```

`Frameworks/GhosttyKit.xcframework` is a symlink into `../ghostty/macos/`.

The ghostty fork's `clauntty` branch is upstream Ghostty (Sep 2026) plus a few patches. Two patches
restore upstream's dropped iOS xcframework slices. The rest add the `manual` termio backend and the
iOS C API below. The audit of every patch is in `~/Projects/plans/2026-09-27-clauntty-ghostty-upgrade.md`.
`main` tracks upstream; the pre-upgrade fork is tagged `clauntty-old`.

`Frameworks/TailscaleKit.xcframework` is a symlink into `../libtailscale/swift/build/`. A fresh checkout
needs `brew install go`, the libtailscale clone, and `./scripts/build-tailscalekit.sh` before Xcode builds.
The script pins Go to libtailscale's `go.mod` version (newer Go breaks a pinned dependency).

## Key Files

| Location | Purpose |
|----------|---------|
| `../ghostty/include/ghostty.h` | C API header |
| `../ghostty/src/termio/Manual.zig` | iOS termio backend: no process/pty, the app feeds output and gets input |
| `../ghostty/src/apprt/embedded.zig` | C API exports, including the iOS ones |
| `Clauntty/Core/Terminal/` | GhosttyApp, TerminalSurface, GhosttyBridge |
| `Clauntty/Core/SSH/` | SSHConnection, SSHAuthenticator |
| `Clauntty/Core/Terminal/GhosttyApp.swift` | GhosttyApp + Logger extension with `debugOnly()`, `verbose()` |

## Build Commands

**Always use `./scripts/sim.sh` instead of raw `xcrun simctl` or `xcodebuild` commands.**

```bash
# Build GhosttyKit (after ghostty changes). Zig 0.16 (`brew install zig`); ~2 min cold
cd ../ghostty && zig build -Demit-xcframework -Demit-macos-app=false -Doptimize=ReleaseFast -Dsentry=false

# Build TailscaleKit (embedded Tailscale; needs Go, uses ../libtailscale)
./scripts/build-tailscalekit.sh

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

# Build, install and launch on the connected iPhone (doctor = keychain/signing state)
./scripts/device.sh run
CLAUNTTY_VERBOSE=1 ./scripts/device.sh run   # with verbose logging
```

**Don't run the unit tests** (`ClaunttyTests`): they're broken and hang. Check changes by building and
running the app in the simulator against the test container (see SSH Testing).

**`simctl` hangs after an Xcode update** (so does `sim.sh`): Xcode's first-launch install hasn't run and
CoreSimulator is out of date. Run `sudo xcodebuild -runFirstLaunch` in a real terminal on the Mac (over
SSH, `ssh -t`). It asks for a password, so `!` in Claude Code can't run it.

**Agent view** (`AgentSwitcherView`) is the phone's only layout: one window per workspace, drawn as
its terminal under a glass pill (status glyph, title, pane dots). Tap one to type into it; swipe it to
switch panes; fullscreen it to work. (The old tab bar was removed on 2026-10-20.)

**Workspace tabs:** with rtach, every terminal tab is an rtach workspace (`rtach ws`): a `SessionGroup`
in `SessionManager+Groups.swift`, its panes the window's dots, swipes and menu sections. A new tab is `ws new` in
`~`; Close is `ws end` (asks first with several panes); sessions in no workspace are adopted with
`ws add` when a host syncs. The app refreshes `rtach ws list --json` when a host deploys, on foreground,
when a tab's menu opens and when rtach sends `workspace;…` (a `rtach ws` change from a terminal or an
agent, shown right away). The server row's context menu has "New Workspace…". A host's workspaces
keep one order on the host (`ws reorder`): `followHostOrder` puts a host's tabs in it within the places
they have in `tabOrder` (other hosts' tabs and pages stay local), and a drag sends `ws reorder` once it
settles (`moveWorkspaceOnHost`). A new tab goes after the one you're in (`ws new --after`). Plain tabs only exist
with rtach turned off. To try it in the simulator, run `rtach ws new demo` and `rtach ws split -v` in a tab on the
test container, then open the window's menu.

**Voice in agent view:** the pane the voice agent is looking at (`VoiceAgent.lookingAt`, its last
tool call's pane) has its eyes (`VoiceEyes`) in its window's pill, looking down, and on the rail,
looking left; its border is a little whiter. The eyes show the pane's status and teleport between
windows (`teleportingEyes`). During a session the overview's voice button is the eyes (it opens
`VoiceSessionSheet`), and the key bar's mic becomes a transcript button: the bar grows upward
around `VoiceTranscriptPanel` (its keys fade out; its chevron, the handle or a swipe down closes
it). Every pane has its own key bar; the transcript is open or closed in all of them at once
(`transcriptShown`). The bar's `hitTest` widens the keys' targets, so while the transcript is open
it hands touches to the panel instead. To work on the look
without xAI, `defaults write com.octerm.clauntty fakeVoice -bool YES` (Debug builds): the voice
button then starts a pretend session that moves between the tabs.

**The voice agent's tools** (`VoiceAgent`) see tabs as workspaces, in the app's order, and their
panes, with the state rtach reports for each (`paneStates`: agent, working/blocked/done, last
prompt), so `list_tabs` asks nothing of the machines. Tools take `tab` and `pane` (default: the pane
the tab shows; for tools that need Claude, the tab's only agent). A pane's Claude is found under its
rtach session (`ClaudeScripts.find`) and read from `~/.claude` (only the last 30MB of a long
conversation: its file can pass 900MB); prompts and keys are typed into the
pane's own session, shown or not. "Finished" and "needs you" notes come from rtach's pane states.
To try a tool without xAI (Debug builds): `xcrun simctl openurl booted
'clauntty://voice-tool?name=read_tab&args=<url-encoded JSON>'`; the result is in the app container's
`tmp/voice_tool.json` (`name=watch` gives the notes pane changes would make).

## IPA / TestFlight

```bash
# Local .ipa → build/export/Clauntty.ipa
./scripts/build-ipa.sh

# Archive + upload to App Store Connect (TestFlight)
./scripts/build-ipa.sh --upload

# Other options
./scripts/build-ipa.sh --export-only   # re-export existing archive
./scripts/build-ipa.sh --archive-only  # archive only
./scripts/build-ipa.sh --method ad-hoc # ad-hoc / development / app-store-connect
./scripts/build-ipa.sh --help
```

**Prerequisites:**
- Distribution certificate: "Apple Distribution: Octerm Technologies, Inc."
- App created in App Store Connect with bundle ID `com.octerm.clauntty`
- Team ID `65533RB4LC` (set in the script / Xcode signing)

**After upload:**
1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. Select Clauntty → TestFlight
3. Wait for build processing (5-30 min)
4. Add testers (internal = instant, external = requires review)

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

### Tailscale Log (Phone)

Debug builds (what `device.sh` installs) write the embedded Tailscale node's logs to `Library/Caches/tailscale.log`, timestamped in local time, next to the app's own network-change, dial and connection-check events (`clauntty:` lines). It starts over at launch once past 10 MB. Useful for roaming and connection problems after the fact, when live `idevicesyslog` wasn't running. Copy it off the phone (works over Wi-Fi, no cable):

```bash
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.octerm.clauntty --source Library/Caches/tailscale.log --destination tailscale.log
grep -a "clauntty:\|LinkChange\|Rebind" tailscale.log   # -a: the file can contain binary bytes
```

### Enable Verbose Logging

Verbose logs are disabled by default (too noisy). Enable with `CLAUNTTY_VERBOSE=1`:

```bash
# sim.sh debug automatically sets CLAUNTTY_VERBOSE=1
./scripts/sim.sh debug devbox

# Manual: set environment variable before launch
SIMCTL_CHILD_CLAUNTTY_VERBOSE=1 xcrun simctl launch booted com.octerm.clauntty

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

// iOS (manual termio backend): the app is the other end of the "pty"
void ghostty_surface_write_pty_output(ghostty_surface_t, const char*, uintptr_t);   // SSH output → terminal
void ghostty_surface_set_pty_input_callback(ghostty_surface_t, ghostty_surface_pty_input_cb);   // keys, mouse, query replies → SSH
void ghostty_surface_set_pty_resize_callback(ghostty_surface_t, ghostty_surface_pty_resize_cb); // terminal resized → SSH window change
bool ghostty_surface_is_alternate_screen(ghostty_surface_t);
bool ghostty_surface_prepend_scrollback(ghostty_surface_t, const char*, uintptr_t);
uintptr_t ghostty_surface_scrollback_offset(ghostty_surface_t);
void ghostty_surface_set_power_mode(ghostty_surface_t, int);   // 0 normal, 1 low power
void ghostty_surface_clear_selection(ghostty_surface_t);       // no click: a TUI taking the mouse would get it, and Shift extends
```

Send the SSH window change from the resize callback, not after `ghostty_surface_set_size`. The terminal
resizes about 25ms later on the termio thread, so telling the remote earlier lets a full-screen app's redraw
for the new size land in the old one (half-drawn Claude Code after rotating).

**A pane another device is using** (a laptop attached to the same rtach session, typed on last): rtach
2.26.0+ sends `pty_size` with the PTY's size and whether it's this client's (`Session.ptySize`). When it
isn't, `TerminalSurfaceView.setOtherDeviceGrid` sizes the surface to that grid (its cells plus this view's
padding), scales Ghostty's layer down to fit from the top left, and shows "In use on another device ·
Tap to use here" under it. A tap claims the pane back. Window changes aren't sent meanwhile (the grid isn't
the phone's), and output is held until the terminal has actually resized, so the program's redraw for
the new size doesn't land in the old grid.

The phone only takes a pane's size when it's used: typing, or Tap to use here. Its attaches are
background ones (`--background`) and its automatic claims (connect, foreground, switching windows)
are for commands only (`claimActive(commandsOnly: true)`, rtach 2.32.0), so opening the app doesn't
resize what a laptop is using. A pane no other device is attached to gets the phone's size anyway;
one the laptop switched away from keeps the laptop's. The Mac app claims in full: the panes it shows
while it's in front.

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
zig build cross   # all targets, gzipped into ../clauntty/Clauntty/Resources/rtach/
# Bump src/main.zig version and RtachDeployer.expectedVersion together, or phones won't redeploy it

# Clean iOS build to pick up new binaries (Xcode caches resources)
xcodebuild -project ../clauntty/Clauntty.xcodeproj -scheme Clauntty clean
```

### Test rtach

```bash
cd ../rtach/tests
bun test                # 24 tests, all should pass
bun run load-test.ts    # Performance: ~16K msg/sec
```

## iOS Support in the Ghostty Fork

- **Build**: upstream dropped iOS from the full library in Aug 2026. Two patches bring it back: a revert of `7a171895d`, and `-fblocks` for iOS in `pkg/macos/build.zig`. Upstream no longer builds iOS, so an upgrade may need more fixes like these.
- **termio `manual` backend** (`src/termio/Manual.zig`): iOS can't spawn processes, so the surface uses a backend with no process or pty. Other platforms opt in with the surface config's `manual_io` (the macOS app). It passes resizes to the embedder and sets `shell_redraws_prompt = .false`, since a remote shell doesn't redraw its prompt after a resize.
- **Rendering**: Ghostty adds its Metal layer to the view's layer directly; the app adopts and sizes it (`adoptGhosttySublayer`).
- **Sentry is off** (`-Dsentry=false`): its crash handlers broke the app's own handling.

## macOS App (in progress)

`ClaunttyMac/` is the desktop app (plan: `plans/2026-10-19-clauntty-macos-app.md`). It shares
`Clauntty/Core` and `Clauntty/Models` with the iOS app through synchronized folders in
`ClaunttyMac.xcodeproj`, minus the iOS-only files listed in `scripts/gen-mac-project.py`. New
shared files need no project change; to change what's excluded, packages or settings, edit
that script and rerun it (`python3 scripts/gen-mac-project.py`). Don't hand-edit the Mac pbxproj.

- **Shared code:** platform differences go behind `#if os(iOS)` / `canImport(UIKit)` seams;
  `Core/Platform.swift` has `PlatformImage`/`PlatformColor`/`PlatformApp`. A new file under
  `Clauntty/Core` must still be added to `Clauntty.xcodeproj` for iOS (it lists files
  explicitly): `python3 scripts/add-ios-source.py Clauntty/Core/X/New.swift Sibling.swift`.
- **Connections:** hosts come from `~/.ssh/config` (`ClaunttyMac/Connections/SSHConfig.swift`),
  opened ones are kept in the shared `ConnectionStore`. Key files via `.sshKey(keyId:
  "file:<path>")`; `ProxyCommand` (and `ProxyJump`, as `ssh -W`) runs as a process that SSH
  goes over. With no key, auth falls back to "none", which is all Tailscale SSH needs.
- **Sessions:** the shared `SessionManager` (workspaces, panes, reconnects) drives the
  sidebar; `TerminalViews` keeps one terminal view per session object.
- **Splits:** the detail shows the whole tab the active pane is in, laid out from rtach's
  split tree (`SessionGroup.layouts`, from `ws list --json`). `showSplitPanes()` keeps every
  pane on screen streaming (`SessionManager.shownTogether` stops `switchTo` pausing them) and
  claims their size only while the app is in front. A pane can briefly have two containers
  when the tree changes shape; `TerminalViews.show(_:in:)` gives the view to the newest.
  Cmd+D / Cmd+Shift+D split (`ws split -h|-v`), Cmd+K is the pane switcher.
- **Another device's size:** when rtach says the PTY isn't ours (`Session.ptySize`), the
  terminal is drawn at that grid and `PaneHostView` scales it down from the top left; a
  click takes the pane back. Output waits for the resize, as on the phone.
- **Sidebar:** one single-line row per workspace (its name, or what runs in its shown pane
  for one named after a folder; the status of its most pressing pane; its pane dots); panes are in the split, each under a title bar with split,
  zoom and close. Zoom (`WindowState.zoomedPane`) is local only. Dragging a divider
  (`DividerHandle`) resizes the split here and on the host (`ws resize`), holding the
  terminals' sizes until the drag stops. Workspaces drag to reorder; the host's name
  has a "…" menu (New Workspace, Refresh, Remove Host); the section's own hover chevron
  folds it. `StatusGlyph` draws the phone's `PaneStatusIndicator` in SwiftUI; change both
  together.
- **No title bar** (`.hiddenTitleBar`): the pane title bars (and a web page's address bar)
  are the top of the window, `PaneHeader.height` to line up with the window's buttons, and
  move the window through `WindowDragArea`. The sidebar's toggle and + sit beside the
  window's buttons. Toggle the sidebar with `WindowState.toggleSidebar()`: it holds every
  terminal's size (`PaneHostView.holdResizes`) until the slide ends, so each resizes once.
- **Pasting images:** Cmd+V, Ctrl+V (only with nothing but an image on the clipboard) and
  dropping image files upload to the host's /tmp (`Session.uploadImage`) and paste the
  path, as the phone does, so Claude Code attaches it.
- **Images and pages:** `clauntty show` images go with the workspace of the pane that
  ran it (`windowImages`, by workspace, as agent mode on the phone). `ImageViewer` shows
  them over that workspace's panes only, when it's on screen; another workspace's wait,
  with a photo badge on its sidebar row, until you go there. Closing the viewer clears
  them. Until then they're on disk (`WaitingImages`: Application Support/<bundle id>/Waiting,
  a folder per workspace, synced from `windowImages`' didSet, loaded with the saved
  workspaces), so a restart doesn't lose them; the host's inbox entry is gone once
  downloaded. The phone's windows keep theirs the same way. It opens out of the pane that ran it (`ImageViewerContent.source`,
  `TerminalViews.frameInWindow`). Zoom, paging, the
  bar (always shown; each button's label under it on hover) and the thumbnails are all SwiftUI; Cmd+=/−/0 go to it while it's open. `clauntty tab PORT` makes a `WebTab`, listed under the
  workspace that opened it and shown in `WebPane` (WKWebView on the forwarded port).
- **Settings** (Cmd+,, `MacSettings`): General: what Cmd+1–9 go to (`PaneCommands.NumberKeys`:
  the nth workspace, the default, or the nth pane; holding Cmd alone for 0.3s shows each
  workspace's number on its sidebar row, `WindowState.commandHeld`). Appearance: font size (`TerminalViews.setFontSize`,
  as Cmd +/−) and the theme (`MacGhosttyApp.setTheme`: `ghostty_app_update_config`, remembered as
  `themeId`; the window goes light or dark with it, `ThemeColors.background(theme)`). Sounds: chimes
  on/off, each chime, their volume (`agentChimeVolume`), a play button for each. Notifications:
  banners on/off (`agentBanners`), whether macOS allows them, and a link to its settings.
- **Notifications:** an agent that needs you or finished posts a notification, as on the phone
  (`MacNotifications`, from `SessionManager.onPaneAttention`, rtach's pane states), unless the
  pane is on screen with the app in front (a banner when it's in another workspace). One per pane:
  showing the pane, or its agent working again, clears it. Clicking one brings the app forward
  on the pane. The Dock icon counts the panes waiting at a menu or question.
  A finished agent's green dot lasts until its pane is seen: rtach's state has `done_at` (2.33.0)
  and `SessionManager.seenDoneAt` (UserDefaults) the finish each pane last showed, so a
  restart keeps the dot, and an agent that finished while the app was closed gets one.
  Each plays a chime: `agent-done.wav` when an agent finishes, `agent-needs-you.wav` when it
  needs you (`ClaunttyMac/Sounds`, synthesized by `scripts/make-chimes.py`: edit its notes and
  rerun it). A pane on screen with the app in front gets the chime alone, no notification. The
  app plays it (`NSSound`), not the notification, so it's heard with notifications off or a
  Focus on (the user keeps one on all day); those only hold back the banner. Pane > Chime When
  Agents Finish turns it off (`agentChime`), as does Settings > Sounds.
- **Terminal:** `MacTerminalView` hosts a Ghostty surface with `manual_io` (the fork's flag
  for the manual termio backend on macOS); keys and mouse follow Ghostty's own AppKit view.
  One surface has focus at a time (`focusedView`): it blinks, the others draw a hollow box, and
  with another app in front all do. A view moved between containers can lose the keyboard
  without `resignFirstResponder`, so gaining it unfocuses the previous one.
- **Release:** `./scripts/mac.sh release` builds Release for arm64 and x86_64, zips it to
  `build/mac/Clauntty.zip` and prints the command that installs it on another Mac over ssh.
  Signed with Apple Development (there's no Developer ID); copied over ssh it has no
  quarantine flag, so Gatekeeper doesn't check it. Each Release's build number is the commit
  count, and the install command re-registers the app (`lsregister -f`): with the same number,
  the Dock kept showing the old icon after the icon changed.
- **Icon:** drawn in `design/AppIcon.svg`. `scripts/render-icon.sh` renders it into the iOS
  `AppIcon.png`, then the Mac sizes (the same icon in the macOS grid) with
  `make-mac-icon.swift`. Edit the SVG, not the PNGs.
- **Testing:** `scripts/mac.sh` is the counterpart of `sim.sh`: `run`, `shot`, `click`, `drag`,
  `scroll`, `type`, `key cmd+t`, `size W H`, `logs`. Input and screenshots go through
  mac-driver (sim-stream repo), which holds Screen Recording and Accessibility; it refuses
  input while the screen is locked. Test against the SSH container with a scratch config, so
  your real hosts aren't touched: `CLAUNTTY_SSH_CONFIG=/tmp/test/config ./scripts/mac.sh run`
  (a `Host` for the container with an `IdentityFile` authorized for testuser there).

## Key Info

- **Bundle ID**: `com.octerm.clauntty`
- **iOS target**: 17.0+
- **Zig version**: 0.16 (ghostty and rtach)
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

### Container Test Server (Recommended)

For Macs without Docker: the same test image in Apple's native `container` VM.

```bash
./scripts/docker-ssh/container-ssh-server.sh start   # prints the IP, usually 192.168.64.2
./scripts/docker-ssh/container-ssh-server.sh stop

# Launch the app with a seeded connection to it and two new tabs
CLAUNTTY_SEED_PASSWORD=testpass ./scripts/sim.sh quick container --seed-name container \
  --seed-host 192.168.64.2 --seed-user testuser --tabs "new,new"
```

Test against the container, not the Mac itself: simulator tabs on the Mac leave rtach sessions in
its `~/.clauntty/sessions`, and a phone adopts each one as a tab the next time it connects there.

### Docker Test Server (machines with Docker)

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

### Network Chaos Testing (netfuzz)

Tests SSH+rtach resilience under degraded networks. Docker container with `tc netem` + headless Swift test harness.

```bash
# Start chaos server (port 2222, testuser/testpass, rtach pre-installed)
./scripts/netfuzz/netfuzz.sh start

# Apply chaos conditions
./scripts/netfuzz/netfuzz.sh throttle 200 5         # 200ms latency + 5% loss
./scripts/netfuzz/netfuzz.sh drop 5                  # 5s total blackout
./scripts/netfuzz/netfuzz.sh bandwidth 256           # 256 kbps limit
./scripts/netfuzz/netfuzz.sh flicker 10 2            # 10 disconnect/reconnect cycles
./scripts/netfuzz/netfuzz.sh scenario flaky          # 2 min random chaos
./scripts/netfuzz/netfuzz.sh clear                   # remove all chaos rules
./scripts/netfuzz/netfuzz.sh status                  # show active rules

# Automated Swift harness test (SSH + RtachClient, no simulator)
./scripts/netfuzz/netfuzz.sh test-rtach              # default: 5s drop
./scripts/netfuzz/netfuzz.sh test-rtach "drop 10"    # custom chaos
./scripts/netfuzz/netfuzz.sh test-rtach "throttle 500 10"

# Manual harness
cd scripts/netfuzz/harness && swift build
.build/debug/NetfuzzHarness --duration 30 --help

# Stop
./scripts/netfuzz/netfuzz.sh stop
```

Available scenarios: `reconnect-storm`, `degraded`, `mobile-switch`, `satellite`, `lossy`, `flaky`.

The Swift harness (`scripts/netfuzz/harness/`) is a standalone SPM package that imports `RtachClient` directly. It connects via real SwiftNIO SSH to the netfuzz container, runs `rtach --proxy`, and logs all protocol events. Key detail: rtach requires `--proxy` flag for external clients (the iOS app uses this too — see `RtachDeployer.swift`).

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
