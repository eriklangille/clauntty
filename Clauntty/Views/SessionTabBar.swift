import SwiftUI

/// Tab bar showing all active terminal sessions
struct SessionTabBar: View {
    @EnvironmentObject var sessionManager: SessionManager

    /// Callback when user wants to open a new tab
    var onNewTab: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Session tabs
                ForEach(sessionManager.sessions) { session in
                    SessionTab(
                        session: session,
                        isActive: session.id == sessionManager.activeSessionId,
                        onSelect: {
                            sessionManager.switchTo(session)
                        },
                        onClose: {
                            sessionManager.closeSession(session)
                        }
                    )
                }

                // New tab button
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(.systemGray6))
    }
}

/// Individual session tab
struct SessionTab: View {
    @ObservedObject var session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Connection status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Tab title
            Text(session.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundColor(isActive ? .primary : .secondary)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color(.systemBackground) : Color(.systemGray5))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture(perform: onSelect)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @StateObject var sessionManager = SessionManager()

        var body: some View {
            VStack {
                SessionTabBar(onNewTab: { print("New tab") })
                    .environmentObject(sessionManager)

                Spacer()
            }
            .onAppear {
                // Add some test sessions
                let config1 = SavedConnection(
                    name: "Production",
                    host: "prod.example.com",
                    port: 22,
                    username: "admin",
                    authMethod: .password
                )
                let config2 = SavedConnection(
                    name: "",
                    host: "dev.example.com",
                    port: 22,
                    username: "developer",
                    authMethod: .password
                )

                _ = sessionManager.createSession(for: config1)
                let session2 = sessionManager.createSession(for: config2)
                session2.state = .connecting
            }
        }
    }

    return PreviewWrapper()
}
