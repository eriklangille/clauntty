import Foundation
import NIOCore
import NIOSSH
import os.log

/// Represents a single terminal session (one tab)
/// Each session has its own SSH channel and terminal surface
@MainActor
class Session: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    let connectionConfig: SavedConnection
    let createdAt: Date

    // MARK: - State

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .disconnected

    /// Display title for tab
    var title: String {
        if !connectionConfig.name.isEmpty {
            return connectionConfig.name
        }
        return "\(connectionConfig.username)@\(connectionConfig.host)"
    }

    // MARK: - SSH Channel

    /// The SSH child channel for this session
    private(set) var sshChannel: Channel?

    /// Channel handler for data flow
    private(set) var channelHandler: SSHChannelHandler?

    /// Reference to parent connection (for sending data)
    weak var parentConnection: SSHConnection?

    // MARK: - Scrollback Buffer

    /// Buffer of all received data (for persistence)
    private(set) var scrollbackBuffer = Data()

    /// Maximum scrollback buffer size (50KB)
    private let maxScrollbackSize = 50 * 1024

    // MARK: - Callbacks

    /// Called when data is received from SSH (to display in terminal)
    var onDataReceived: ((Data) -> Void)?

    /// Called when session state changes
    var onStateChanged: ((State) -> Void)?

    // MARK: - Initialization

    init(connectionConfig: SavedConnection) {
        self.id = UUID()
        self.connectionConfig = connectionConfig
        self.createdAt = Date()
    }

    // MARK: - Channel Management

    /// Attach an SSH channel to this session
    func attach(channel: Channel, handler: SSHChannelHandler, connection: SSHConnection) {
        self.sshChannel = channel
        self.channelHandler = handler
        self.parentConnection = connection
        self.state = .connected
        onStateChanged?(.connected)
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel attached")
    }

    /// Detach the channel (on disconnect)
    func detach() {
        sshChannel = nil
        channelHandler = nil
        parentConnection = nil
        state = .disconnected
        onStateChanged?(.disconnected)
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel detached")
    }

    // MARK: - Data Flow

    /// Handle data received from SSH
    func handleDataReceived(_ data: Data) {
        // Append to scrollback buffer
        scrollbackBuffer.append(data)

        // Trim if too large (keep most recent data)
        if scrollbackBuffer.count > maxScrollbackSize {
            let excess = scrollbackBuffer.count - maxScrollbackSize
            scrollbackBuffer.removeFirst(excess)
        }

        // Forward to terminal
        onDataReceived?(data)
    }

    /// Send data to remote (keyboard input)
    func sendData(_ data: Data) {
        channelHandler?.sendToRemote(data)
    }

    /// Send window size change
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        guard let channel = sshChannel else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot send window change, no channel")
            return
        }

        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(columns),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(windowChange, promise: nil)
        }
        Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): window change \(columns)x\(rows)")
    }

    // MARK: - Scrollback Persistence

    /// Get scrollback data for restoration
    func getScrollbackData() -> Data {
        return scrollbackBuffer
    }

    /// Restore scrollback from saved data
    func restoreScrollback(_ data: Data) {
        scrollbackBuffer = data
        // Note: Terminal surface will need to replay this data
    }

    /// Clear scrollback buffer
    func clearScrollback() {
        scrollbackBuffer.removeAll()
    }
}

// MARK: - Hashable

extension Session: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
