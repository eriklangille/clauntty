import SwiftUI
import os.log

/// Wrapper class to hold terminal surface reference (works with SwiftUI @StateObject)
@MainActor
class TerminalSurfaceHolder: ObservableObject {
    @Published var surface: TerminalSurfaceView?
}

struct TerminalView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var appState: AppState
    @ObservedObject var themeManager = ThemeManager.shared

    /// The session this terminal view is displaying
    @ObservedObject var session: Session

    /// Whether the full tab selector is currently presented
    var isTabSelectorPresented: Bool

    /// Reference to the terminal surface view for SSH data flow (wrapped in class for SwiftUI)
    @StateObject private var surfaceHolder = TerminalSurfaceHolder()

    /// Background color from current theme
    private var terminalBackgroundColor: Color {
        if let theme = themeManager.theme(withId: ghosttyApp.currentThemeId) {
            return theme.backgroundColor
        }
        // Fallback to Ghostty's default (#282C34)
        return Color(red: 40/255.0, green: 44/255.0, blue: 52/255.0)
    }

    /// Whether this terminal is currently the active tab
    private var isActive: Bool {
        sessionManager.activeTab == .terminal(session.id)
            && !isTabSelectorPresented
            && !appState.isInputSuppressed
    }

    var body: some View {
        ZStack {
            // Show terminal surface based on GhosttyApp readiness
            switch ghosttyApp.readiness {
            case .loading:
                terminalBackgroundColor
                    .ignoresSafeArea()
                VStack {
                    ProgressView()
                        .tint(.white)
                    Text("Initializing terminal...")
                        .foregroundColor(.gray)
                        .padding(.top)
                }

            case .error:
                terminalBackgroundColor
                    .ignoresSafeArea()
                VStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.largeTitle)
                    Text("Failed to initialize terminal")
                        .foregroundColor(.white)
                        .padding(.top)
                }

            case .ready:
                // Terminal background extends under notch in landscape
                terminalBackgroundColor
                    .ignoresSafeArea()

                // Terminal surface - use full available space
                // Use .id(session.id) to ensure a new surface is created for each session
                TerminalSurface(
                    ghosttyApp: ghosttyApp,
                    sessionId: String(session.id.uuidString.prefix(8)),
                    isActive: isActive,
                    initialFontSize: session.fontSize,
                    onTextInput: { data in
                        // Send keyboard input to SSH via session
                        Logger.clauntty.verbose("[INPUT] onTextInput called with \(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
                        session.sendData(data)
                    },
                    onImagePaste: { image in
                        // Upload image to remote and paste file path
                        session.uploadImageAndPaste(image)
                    },
                    onTerminalSizeChanged: { rows, columns in
                        // Send window size change to SSH server
                        session.sendWindowChange(rows: rows, columns: columns)
                    },
                    onFontSizeChanged: { newSize in
                        // Persist font size for this session
                        session.fontSize = newSize
                    },
                    onSurfaceReady: { surface in
                        Logger.clauntty.debugOnly("onSurfaceReady called for session \(session.id.uuidString.prefix(8)), state=\(String(describing: session.state))")
                        surfaceHolder.surface = surface
                        connectSession(surface: surface)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(session.id)  // Force new surface per session
                .onChange(of: session.state) { oldState, newState in
                    // Force re-render when session connects/reconnects
                    // This fixes blank/partial rendering after reconnection
                    if case .connected = newState {
                        Logger.clauntty.debugOnly("Session state changed to connected, forcing redraw (from \(String(describing: oldState)))")

                        // First redraw after short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            surfaceHolder.surface?.forceRedraw()
                        }

                        // Second redraw after scrollback has time to load
                        // This is especially important after reconnect when rtach sends scrollback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            surfaceHolder.surface?.forceRedraw()

                            // Send SIGWINCH after scrollback is processed
                            // This triggers TUI apps (like Claude Code) to repaint
                            if let surface = surfaceHolder.surface {
                                let size = surface.terminalSize
                                Logger.clauntty.debugOnly("Session connected, sending window change: \(size.columns)x\(size.rows)")
                                session.sendWindowChange(rows: size.rows, columns: size.columns)
                            }
                        }

                        // Third redraw in case of slow scrollback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            surfaceHolder.surface?.forceRedraw()
                        }
                    }
                }

                // Show connecting overlay
                if session.state == .connecting {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    VStack {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                        Text("Connecting...")
                            .foregroundColor(.white)
                            .padding(.top)
                    }
                }

                // Show error overlay
                if case .error(let errorMessage) = session.state {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 48))
                        Text("Connection Failed")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text(errorMessage)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Close Tab") {
                            sessionManager.closeSession(session)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top)
                    }
                }

                // Show remotely deleted overlay (session ended on server)
                if case .remotelyDeleted = session.state {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 48))
                        Text("Session Ended")
                            .foregroundColor(.white)
                            .font(.headline)
                        if let reason = session.remoteClosureReason {
                            Text(reason)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button("Close Tab") {
                            sessionManager.closeSession(session, killRemote: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .padding(.top)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureTerminalText)) { _ in
            // Only capture if this is the active terminal
            guard isActive, let surface = surfaceHolder.surface else { return }
            handleCaptureTerminalText(surface: surface)
        }
        .onChange(of: sessionManager.activeTab) { oldTab, newTab in
            // Compute active state from the actual tab change
            // (Can't use .onChange on computed `isActive` - SwiftUI doesn't track it)
            let wasActive = oldTab == .terminal(session.id)
            let nowActive = newTab == .terminal(session.id)

            guard wasActive != nowActive else { return }

            // Update surface active state when tab visibility changes
            if let surface = surfaceHolder.surface {
                surface.setActive(nowActive)
            }

            // Capture screenshot when switching away from this tab
            if wasActive && !nowActive, let surface = surfaceHolder.surface {
                session.cachedScreenshot = surface.captureScreenshot()
            }
        }
    }

    /// Handle request to capture terminal text (from URL scheme)
    private func handleCaptureTerminalText(surface: TerminalSurfaceView) {
        Logger.clauntty.debugOnly("Capturing terminal text for session \(session.id.uuidString.prefix(8))")

        guard let text = surface.captureVisibleText() else {
            Logger.clauntty.error("Failed to capture terminal text")
            return
        }

        // Write to app's Documents directory (accessible via simctl)
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Logger.clauntty.error("Failed to get Documents directory")
            return
        }
        let filePath = documentsPath.appendingPathComponent("clauntty_dump.txt")

        do {
            try text.write(to: filePath, atomically: true, encoding: .utf8)
            Logger.clauntty.debugOnly("Terminal text written to \(filePath.path) (\(text.count) chars)")
        } catch {
            Logger.clauntty.error("Failed to write terminal text: \(error.localizedDescription)")
        }
    }

    private func connectSession(surface: TerminalSurfaceView) {
        Logger.clauntty.debugOnly("connectSession called for session \(session.id.uuidString.prefix(8)), state=\(String(describing: session.state))")

        // Always wire up the display - we need this for data flow regardless of connection state
        wireSessionToSurface(surface: surface)

        // If already connected, just send window change to fix terminal size
        // This handles the case where auto-connect ran before surface was ready
        if case .connected = session.state {
            Logger.clauntty.debugOnly("connectSession: session already connected, sending window change")
            let size = surface.terminalSize
            session.sendWindowChange(rows: size.rows, columns: size.columns)
            return
        }

        // If not disconnected (e.g., connecting), wait for connection to complete
        guard session.state == .disconnected else {
            Logger.clauntty.debugOnly("connectSession: session not disconnected (state=\(String(describing: session.state))), returning")
            return
        }

        // Set initial terminal size from actual surface dimensions before connecting
        // This ensures PTY is created with correct size from the start
        let size = surface.terminalSize
        session.initialTerminalSize = (rows: Int(size.rows), columns: Int(size.columns))
        Logger.clauntty.debugOnly("Setting initial terminal size: \(size.columns)x\(size.rows)")

        // Start connection via SessionManager
        Task {
            do {
                try await sessionManager.connect(session: session, rtachSessionId: session.rtachSessionId)
                Logger.clauntty.debugOnly("Session connected: \(session.id.uuidString.prefix(8))")

                // Force send actual terminal size immediately after connection
                // This ensures the remote PTY has correct dimensions before user types anything
                await MainActor.run {
                    let size = surface.terminalSize
                    Logger.clauntty.debugOnly("Sending initial window size: \(size.columns)x\(size.rows)")
                    session.sendWindowChange(rows: size.rows, columns: size.columns)
                }

                // Replay any scrollback buffer that was accumulated
                if !session.scrollbackBuffer.isEmpty {
                    if session.usesRtach {
                        Logger.clauntty.debugOnly("Skipping local scrollback replay for rtach session \(session.id.uuidString.prefix(8))")
                    } else {
                        await MainActor.run {
                            surface.writeSSHOutput(session.scrollbackBuffer)
                        }
                    }
                }
            } catch {
                Logger.clauntty.error("Session connection failed: \(error.localizedDescription)")
                // Error state is already set by SessionManager
            }
        }
    }

    private func wireSessionToSurface(surface: TerminalSurfaceView) {
        Logger.clauntty.debugOnly("wireSessionToSurface called for session \(session.id.uuidString.prefix(8))")

        // Set up callback for session data → terminal display
        // This is called from Session.processTerminalData which is @MainActor isolated.
        // writeSSHOutput internally dispatches to terminalIOQueue, so no threading needed here.
        session.onDataReceived = { data in
            surface.writeSSHOutput(data)
        }

        // Set up callback for old scrollback → prepend to terminal
        // Called from Session's RtachSessionDelegate which dispatches via Task { @MainActor }.
        session.onScrollbackReceived = { [weak surface] data in
            guard let surface = surface else { return }
            surface.prependScrollback(data)
        }

        // Set up callback for terminal title changes → session title
        surface.onTitleChanged = { [weak session] title in
            session?.dynamicTitle = title
        }

        // Set up callback for scroll-triggered scrollback loading
        // When user scrolls near the top, request old scrollback (paginated)
        // Skip if on alternate screen (vim, less, Claude Code) - no scrollback there
        surface.onScrollNearTop = { [weak session, weak surface] offset in
            let isAlt = surface?.isAlternateScreen ?? true
            Logger.clauntty.verbose("[SCROLL] onScrollNearTop: offset=\(offset), isAlternateScreen=\(isAlt)")
            guard let surface = surface, !surface.isAlternateScreen else {
                Logger.clauntty.verbose("[SCROLL] onScrollNearTop: skipping (alt screen or no surface)")
                return
            }
            session?.loadMoreScrollbackIfNeeded()
        }

        // Set up callback for active state changes (power management)
        // Pause output streaming when tab is inactive, resume when active
        surface.onActiveStateChanged = { [weak session] active in
            if active {
                session?.resumeOutput()
            } else {
                session?.pauseOutput()
            }
        }
    }
}

#Preview {
    let config = SavedConnection(
        name: "Test Server",
        host: "example.com",
        username: "user",
        authMethod: .password
    )
    let session = Session(connectionConfig: config)

    return NavigationStack {
        TerminalView(session: session, isTabSelectorPresented: false)
            .environmentObject(GhosttyApp())
            .environmentObject(SessionManager())
            .environmentObject(AppState())
    }
}
