import SwiftUI
import os.log

/// SwiftUI wrapper for the UIKit LiquidGlassTabBar
struct LiquidGlassTabBarRepresentable: UIViewRepresentable {
    @EnvironmentObject var sessionManager: SessionManager

    /// Called when user wants to open a new tab
    var onNewTab: () -> Void

    /// Called when user wants to see full tab selector
    var onShowTabSelector: () -> Void

    /// Called when user wants to see ports for a session
    var onShowPorts: ((Session) -> Void)?

    /// Hash of session states to trigger updates when states change
    /// This forces SwiftUI to call updateUIView when any session state changes
    var sessionStatesHash: Int

    func makeUIView(context: Context) -> LiquidGlassTabBar {
        let bar = LiquidGlassTabBar()

        bar.onNewTab = onNewTab
        bar.onShowTabSelector = onShowTabSelector

        bar.onTabSelected = { [weak bar] tab in
            switch tab {
            case .terminal(let session):
                context.coordinator.sessionManager?.switchTo(session)
            case .web(let webTab):
                context.coordinator.sessionManager?.switchTo(webTab)
            }
        }

        bar.onDisconnect = { tab in
            switch tab {
            case .terminal(let session):
                context.coordinator.sessionManager?.closeSession(session)
            case .web(let webTab):
                context.coordinator.sessionManager?.closeWebTab(webTab)
            }
        }

        bar.onReconnect = { tab in
            switch tab {
            case .terminal(let session):
                // TODO: Implement reconnect
                Task {
                    try? await context.coordinator.sessionManager?.reconnect(session: session)
                }
            case .web:
                break
            }
        }

        bar.onShowPorts = { tab in
            Logger.clauntty.debugOnly("LiquidGlassTabBarRepresentable: onShowPorts callback fired, coordinator.onShowPorts exists=\(context.coordinator.onShowPorts != nil)")
            if case .terminal(let session) = tab {
                Logger.clauntty.debugOnly("LiquidGlassTabBarRepresentable: calling coordinator.onShowPorts for session \(session.id.uuidString.prefix(8))")
                context.coordinator.onShowPorts?(session)
            }
        }

        // Web-specific callbacks
        bar.onWebBack = { tab in
            if case .web(let webTab) = tab {
                webTab.goBack()
            }
        }

        bar.onWebForward = { tab in
            if case .web(let webTab) = tab {
                webTab.goForward()
            }
        }

        bar.onWebReload = { tab in
            if case .web(let webTab) = tab {
                webTab.reload()
            }
        }

        bar.onWebShare = { tab in
            if case .web(let webTab) = tab {
                // Share the current URL
                guard let url = webTab.currentURL else { return }
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
        }

        bar.onWebNavigate = { tab, path in
            if case .web(let webTab) = tab {
                webTab.navigate(to: path)
            }
        }

        return bar
    }

    func updateUIView(_ bar: LiquidGlassTabBar, context: Context) {
        // Store reference for coordinator
        context.coordinator.sessionManager = sessionManager

        // Update bar with current state (using global tab order)
        bar.update(
            orderedTabs: sessionManager.orderedTabs(),
            activeTab: sessionManager.activeTab
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onShowPorts: onShowPorts)
    }

    class Coordinator {
        weak var sessionManager: SessionManager?
        var onShowPorts: ((Session) -> Void)?

        init(onShowPorts: ((Session) -> Void)? = nil) {
            self.onShowPorts = onShowPorts
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @StateObject var sessionManager = SessionManager()

        var body: some View {
            VStack {
                LiquidGlassTabBarRepresentable(
                    onNewTab: { print("New tab") },
                    onShowTabSelector: { print("Show tab selector") },
                    sessionStatesHash: sessionManager.sessionStateVersion
                )
                .frame(height: 48)
                .environmentObject(sessionManager)

                Spacer()
            }
            .background(Color(.systemBackground))
            .onAppear {
                // Add test sessions
                let config1 = SavedConnection(
                    name: "Production",
                    host: "prod.example.com",
                    port: 22,
                    username: "admin",
                    authMethod: .password
                )
                let config2 = SavedConnection(
                    name: "Development",
                    host: "dev.example.com",
                    port: 22,
                    username: "developer",
                    authMethod: .password
                )

                let session1 = sessionManager.createSession(for: config1)
                session1.state = .connected

                let session2 = sessionManager.createSession(for: config2)
                session2.state = .connecting
            }
        }
    }

    return PreviewWrapper()
}
