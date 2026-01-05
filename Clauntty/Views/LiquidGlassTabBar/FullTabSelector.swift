import SwiftUI

/// Full-page tab selector showing all tabs with screenshot previews
struct FullTabSelector: View {
    @EnvironmentObject var sessionManager: SessionManager

    let onDismiss: () -> Void
    var onNewTab: (() -> Void)?

    /// Grid columns - 2 columns on iPhone
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    /// Currently dragging tab (for visual feedback)
    @State private var draggingTab: TabItem?
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                // Header
                ZStack {
                    HStack {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gear")
                                .font(.system(size: 22))
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button(action: onDismiss) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.gray)
                        }
                    }

                    Text("\(allTabs.count) Sessions")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Tab grid
                ScrollView {
                    VStack(spacing: 24) {
                        // Tabs grid
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(allTabs.enumerated()), id: \.element.id) { index, tab in
                                TabCard(
                                    tab: tab,
                                    isActive: isActive(tab),
                                    onSelect: {
                                        selectTab(tab)
                                    },
                                    onClose: {
                                        closeTab(tab)
                                    }
                                )
                                .opacity(draggingTab?.id == tab.id ? 0.5 : 1.0)
                                .scaleEffect(draggingTab?.id == tab.id ? 1.05 : 1.0)
                                .draggable(DraggableTab.from(tab)) {
                                    // Drag preview
                                    TabCard(
                                        tab: tab,
                                        isActive: false,
                                        onSelect: {},
                                        onClose: {}
                                    )
                                    .frame(width: 120, height: 200)
                                    .opacity(0.8)
                                }
                                .dropDestination(for: DraggableTab.self) { droppedItems, _ in
                                    guard let dropped = droppedItems.first else { return false }
                                    return handleDrop(dropped, atIndex: index)
                                } isTargeted: { isTargeted in
                                    // Could add hover highlight here if desired
                                }
                            }

                            // New tab button (also acts as drop target to move tab to end)
                            NewTabCard(onTap: {
                                onDismiss()
                                // Trigger new tab sheet after dismissing
                                onNewTab?()
                            })
                            .dropDestination(for: DraggableTab.self) { droppedItems, _ in
                                guard let dropped = droppedItems.first else { return false }
                                // Move to end of list
                                let droppedId: UUID
                                switch dropped {
                                case .terminal(let id): droppedId = id
                                case .web(let id): droppedId = id
                                }
                                sessionManager.moveTabToEnd(id: droppedId)
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                return true
                            } isTargeted: { _ in }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: allTabs.map { $0.id })

                        // Forwarded ports section
                        if !sessionManager.forwardedPorts.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Forwarded Ports")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.gray)

                                ForEach(sessionManager.forwardedPorts) { port in
                                    ForwardedPortRow(port: port) {
                                        sessionManager.stopForwarding(
                                            port: port.remotePort,
                                            config: port.connectionConfig
                                        )
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    // MARK: - Computed Properties

    private var allTabs: [TabItem] {
        sessionManager.orderedTabs()
    }

    private func isActive(_ tab: TabItem) -> Bool {
        switch (tab, sessionManager.activeTab) {
        case (.terminal(let session), .terminal(let activeId)):
            return session.id == activeId
        case (.web(let webTab), .web(let activeId)):
            return webTab.id == activeId
        default:
            return false
        }
    }

    // MARK: - Actions

    private func selectTab(_ tab: TabItem) {
        switch tab {
        case .terminal(let session):
            sessionManager.switchTo(session)
        case .web(let webTab):
            sessionManager.switchTo(webTab)
        }
        onDismiss()
    }

    private func closeTab(_ tab: TabItem) {
        switch tab {
        case .terminal(let session):
            sessionManager.closeSession(session)
        case .web(let webTab):
            sessionManager.closeWebTab(webTab)
        }

        // If no more tabs, dismiss
        if sessionManager.sessions.isEmpty && sessionManager.webTabs.isEmpty {
            onDismiss()
        }
    }

    /// Handle a tab drop at the specified index
    private func handleDrop(_ dropped: DraggableTab, atIndex targetIndex: Int) -> Bool {
        let droppedId: UUID
        switch dropped {
        case .terminal(let id): droppedId = id
        case .web(let id): droppedId = id
        }

        // Move in the global order
        sessionManager.moveTab(id: droppedId, toGlobalIndex: targetIndex)

        // Trigger haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        return true
    }
}

// MARK: - DraggableTab Extension

extension DraggableTab {
    /// Create a DraggableTab from a TabItem
    static func from(_ tabItem: TabItem) -> DraggableTab {
        switch tabItem {
        case .terminal(let session):
            return .terminal(session.id)
        case .web(let webTab):
            return .web(webTab.id)
        }
    }
}

// MARK: - Tab Card

/// Individual tab card showing screenshot preview and title
struct TabCard: View {
    let tab: TabItem
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Screenshot preview area
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))

                // Screenshot or placeholder
                if let screenshot = screenshot {
                    GeometryReader { geo in
                        Image(uiImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .clipped()
                } else {
                    // Placeholder
                    VStack(spacing: 8) {
                        Image(systemName: iconName)
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(tab.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Remote closure overlay
                if isRemotelyDeleted {
                    ZStack {
                        Color.black.opacity(0.85)

                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title2)
                            Text("Session Ended")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                            if let reason = remoteClosureReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }

                            Button(action: onClose) {
                                Text("Close Tab")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .padding(.top, 4)
                        }
                        .padding()
                    }
                }

                // Close button overlay (only show if not remotely deleted)
                if !isRemotelyDeleted {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                            .padding(8)
                        }
                        Spacer()
                    }
                }

                // Server badge (top-left corner)
                if let server = serverName {
                    VStack {
                        HStack {
                            Text(server)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                                .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Active indicator
                if isActive {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 3)
                }
            }
            .aspectRatio(9/16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(perform: onSelect)

            // Title below card
            HStack(spacing: 4) {
                // Status indicator
                statusIndicator

                Text(tab.title)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
    }

    private var iconName: String {
        switch tab {
        case .terminal: return "terminal"
        case .web: return "globe"
        }
    }

    private var screenshot: UIImage? {
        switch tab {
        case .terminal(let session):
            return session.cachedScreenshot
        case .web(let webTab):
            return webTab.cachedScreenshot
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch tab {
        case .terminal(let session):
            Circle()
                .fill(statusColor(for: session.state))
                .frame(width: 6, height: 6)
        case .web:
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        }
    }

    private func statusColor(for state: Session.State) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        case .remotelyDeleted: return .orange
        }
    }

    /// Server name for display
    private var serverName: String? {
        switch tab {
        case .terminal(let session):
            if !session.connectionConfig.name.isEmpty {
                return session.connectionConfig.name
            }
            return session.connectionConfig.host
        case .web(let webTab):
            return webTab.serverDisplayName
        }
    }

    /// Whether this tab has been remotely deleted
    private var isRemotelyDeleted: Bool {
        if case .terminal(let session) = tab, case .remotelyDeleted = session.state {
            return true
        }
        return false
    }

    /// Remote closure reason
    private var remoteClosureReason: String? {
        if case .terminal(let session) = tab {
            return session.remoteClosureReason
        }
        return nil
    }
}

// MARK: - New Tab Card

/// Card for creating a new tab
struct NewTabCard: View {
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundColor(.gray)
                    )

                Image(systemName: "plus")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.gray)
            }
            .aspectRatio(9/16, contentMode: .fit)
            .onTapGesture(perform: onTap)

            Text("New Tab")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Forwarded Port Row

/// Row showing a forwarded port in the ports section
struct ForwardedPortRow: View {
    @ObservedObject var port: ForwardedPort
    let onStop: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(":\(port.remotePort.port)")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Text("localhost:\(port.localPort) → \(port.connectionConfig.host)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    FullTabSelector(onDismiss: {})
        .environmentObject(SessionManager())
}
