import SwiftUI
import os.log

struct ContentView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager

    @State private var showingNewTabSheet = false
    @State private var hasCheckedAutoConnect = false

    /// Edge swipe detection threshold (distance from edge to start gesture)
    private let edgeThreshold: CGFloat = 30

    /// Minimum swipe distance to trigger action
    private let swipeThreshold: CGFloat = 80

    var body: some View {
        NavigationStack {
            if sessionManager.hasSessions {
                // Show tabs + content when there are active sessions or web tabs
                VStack(spacing: 0) {
                    SessionTabBar(onNewTab: {
                        showingNewTabSheet = true
                    })

                    // Keep ALL views alive, but only show the active one.
                    // This preserves terminal state (font size, scrollback, etc.) across tab switches.
                    GeometryReader { geometry in
                        ZStack {
                            // Terminal tabs
                            ForEach(sessionManager.sessions) { session in
                                TerminalView(session: session)
                                    .opacity(sessionManager.activeTab == .terminal(session.id) ? 1 : 0)
                                    .allowsHitTesting(sessionManager.activeTab == .terminal(session.id))
                            }

                            // Web tabs
                            ForEach(sessionManager.webTabs) { webTab in
                                WebTabView(webTab: webTab)
                                    .opacity(sessionManager.activeTab == .web(webTab.id) ? 1 : 0)
                                    .allowsHitTesting(sessionManager.activeTab == .web(webTab.id))
                            }

                            // Edge swipe gesture overlay
                            EdgeSwipeGestureView(
                                screenWidth: geometry.size.width,
                                edgeThreshold: edgeThreshold,
                                swipeThreshold: swipeThreshold,
                                onSwipeLeft: {
                                    // Swipe left from right edge → go to next tab waiting for input
                                    if sessionManager.switchToNextWaitingTab() {
                                        triggerHaptic()
                                    }
                                },
                                onSwipeRight: {
                                    // Swipe right from left edge → go to previous tab
                                    sessionManager.switchToPreviousTab()
                                    triggerHaptic()
                                }
                            )
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showingNewTabSheet) {
                    NavigationStack {
                        ConnectionListView()
                            .navigationTitle("New Tab")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") {
                                        showingNewTabSheet = false
                                    }
                                }
                            }
                    }
                }
                .onChange(of: sessionManager.sessions.count) { oldCount, newCount in
                    // Dismiss sheet when a new session is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
                .onChange(of: sessionManager.webTabs.count) { oldCount, newCount in
                    // Dismiss sheet when a new web tab is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
            } else {
                // Show connection list when no sessions
                ConnectionListView()
            }
        }
        .onAppear {
            checkAutoConnect()
        }
    }

    /// Check for --connect <name> launch argument and auto-connect
    private func checkAutoConnect() {
        guard !hasCheckedAutoConnect else { return }
        hasCheckedAutoConnect = true

        guard let connectionName = LaunchArgs.autoConnectName() else { return }

        Logger.clauntty.info("Auto-connect requested for: \(connectionName)")

        // Find connection by name (case-insensitive)
        guard let connection = connectionStore.connections.first(where: {
            $0.name.lowercased() == connectionName.lowercased() ||
            $0.host.lowercased() == connectionName.lowercased()
        }) else {
            let available = connectionStore.connections.map { "\($0.name) (\($0.host))" }.joined(separator: ", ")
            Logger.clauntty.error("Auto-connect: connection '\(connectionName)' not found. Available: \(available)")
            return
        }

        Logger.clauntty.info("Auto-connect: found connection \(connection.name) (\(connection.host))")

        // Create session and connect
        Task {
            do {
                // First, establish SSH and deploy rtach
                Logger.clauntty.info("Auto-connect: establishing SSH and deploying rtach...")
                let _ = try await sessionManager.connectAndListSessions(for: connection)
                Logger.clauntty.info("Auto-connect: rtach deployed, creating session...")

                // Now create and connect the terminal session
                let session = sessionManager.createSession(for: connection)
                try await sessionManager.connect(session: session)
                Logger.clauntty.info("Auto-connect: session connected successfully")
            } catch {
                Logger.clauntty.error("Auto-connect failed: \(error.localizedDescription)")
            }
        }
    }

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}

// MARK: - Edge Swipe Gesture View

/// Invisible view that detects edge swipes without blocking touch events in the center
struct EdgeSwipeGestureView: UIViewRepresentable {
    let screenWidth: CGFloat
    let edgeThreshold: CGFloat
    let swipeThreshold: CGFloat
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> EdgeSwipeUIView {
        let view = EdgeSwipeUIView()
        view.screenWidth = screenWidth
        view.edgeThreshold = edgeThreshold
        view.swipeThreshold = swipeThreshold
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: EdgeSwipeUIView, context: Context) {
        uiView.screenWidth = screenWidth
        uiView.edgeThreshold = edgeThreshold
        uiView.swipeThreshold = swipeThreshold
        uiView.onSwipeLeft = onSwipeLeft
        uiView.onSwipeRight = onSwipeRight
    }
}

/// UIView subclass that handles edge swipe gestures
class EdgeSwipeUIView: UIView {
    var screenWidth: CGFloat = 0
    var edgeThreshold: CGFloat = 30
    var swipeThreshold: CGFloat = 80
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    private var touchStartX: CGFloat = 0
    private var touchStartedFromEdge: Bool = false
    private var isLeftEdge: Bool = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only handle touches that start near the edges
        let isNearLeftEdge = point.x < edgeThreshold
        let isNearRightEdge = point.x > bounds.width - edgeThreshold

        if isNearLeftEdge || isNearRightEdge {
            return self
        }

        // Pass through touches in the center
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)

        touchStartX = location.x
        isLeftEdge = location.x < edgeThreshold
        touchStartedFromEdge = isLeftEdge || location.x > bounds.width - edgeThreshold
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Optional: could add visual feedback here
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touchStartedFromEdge else {
            touchStartedFromEdge = false
            return
        }

        let location = touch.location(in: self)
        let deltaX = location.x - touchStartX

        if isLeftEdge && deltaX > swipeThreshold {
            // Swiped right from left edge → go to previous tab
            onSwipeRight?()
        } else if !isLeftEdge && deltaX < -swipeThreshold {
            // Swiped left from right edge → go to next waiting tab
            onSwipeLeft?()
        }

        touchStartedFromEdge = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStartedFromEdge = false
    }
}

#Preview {
    ContentView()
        .environmentObject(ConnectionStore())
        .environmentObject(AppState())
        .environmentObject(SessionManager())
}
