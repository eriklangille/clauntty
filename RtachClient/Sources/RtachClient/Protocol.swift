import Foundation

// MARK: - Client → Server Message Types

/// Message types sent from client to rtach server
public enum MessageType: UInt8, Sendable {
    /// Data from client to PTY (keyboard input)
    case push = 0
    /// Client attach request
    case attach = 1
    /// Client detach notification
    case detach = 2
    /// Window size change
    case winch = 3
    /// Request screen redraw
    case redraw = 4
    /// Request old scrollback (legacy, sends all at once)
    case requestScrollback = 5
    /// Request paginated scrollback
    case requestScrollbackPage = 6
    /// Upgrade to framed protocol mode
    case upgrade = 7
    /// Pause terminal output streaming (battery optimization)
    case pause = 8
    /// Resume terminal output streaming
    case resume = 9
    /// Claim active client for window size and command routing
    case claimActive = 10
    /// Request a page of history before a stream position (masters with
    /// ProtocolConstants.handshakeFlagHistory only)
    case requestHistory = 11
}

// MARK: - Server → Client Response Types

/// Response types sent from rtach server to client
public enum ResponseType: UInt8, Sendable {
    /// Terminal data (PTY output)
    case terminalData = 0
    /// Old scrollback data (legacy)
    case scrollback = 1
    /// Command from server-side scripts
    case command = 2
    /// Paginated scrollback with metadata
    case scrollbackPage = 3
    /// Shell is idle (waiting for input, no PTY output for 2s)
    case idle = 4
    /// Protocol handshake
    case handshake = 5
    /// Page of scrollback history with HistoryPageMeta
    case historyPage = 6
}

// MARK: - Protocol Constants

public enum ProtocolConstants {
    /// Maximum payload size for client packets (fits in u8 len field)
    public static let maxPayloadSize: Int = 255

    /// Client ID size (UUID = 16 bytes)
    public static let clientIdSize: Int = 16

    /// Handshake magic bytes "RTCH"
    public static let handshakeMagic: UInt32 = 0x48435452

    /// Current protocol version
    public static let protocolVersionMajor: UInt8 = 2
    public static let protocolVersionMinor: UInt8 = 0

    /// Compression flag (high bit of response type byte)
    /// When set, payload is zlib-compressed
    public static let compressionFlag: UInt8 = 0x80

    /// Compression types for upgrade packet payload
    public static let compressionNone: UInt8 = 0x00
    public static let compressionZlib: UInt8 = 0x01

    /// Response header size (type: 1 + len: 4)
    public static let responseHeaderSize: Int = 5

    /// Client packet header size (type: 1 + len: 1)
    public static let clientHeaderSize: Int = 2

    /// Scrollback page request payload size
    public static let scrollbackRequestSize: Int = 8

    /// Scrollback page metadata size
    public static let scrollbackMetaSize: Int = 8

    /// History page metadata size (start: u64, end: u64, oldest: u64)
    public static let historyMetaSize: Int = 24

    /// Handshake flag: the master supports request_history
    public static let handshakeFlagHistory: UInt16 = 1 << 0

    /// request_history `before` meaning "where my attach replay started"
    public static let historyBeforeReplay: UInt64 = .max

    /// Handshake payload size
    public static let handshakeSize: Int = 8

    /// Window size payload size
    public static let winsizeSize: Int = 8
}

// MARK: - Handshake Structure

/// Handshake received from rtach server
public struct Handshake: Sendable, Equatable {
    public let magic: UInt32
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let flags: UInt16

    public var isValid: Bool {
        magic == ProtocolConstants.handshakeMagic
    }

    public init(magic: UInt32, versionMajor: UInt8, versionMinor: UInt8, flags: UInt16) {
        self.magic = magic
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.flags = flags
    }

    public init?(from data: Data) {
        guard data.count >= ProtocolConstants.handshakeSize else { return nil }

        // Use manual byte loading to avoid alignment issues
        self.magic = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        self.versionMajor = data[4]
        self.versionMinor = data[5]
        self.flags = UInt16(data[6]) | (UInt16(data[7]) << 8)
    }
}

// MARK: - Scrollback Page Metadata

/// Metadata for paginated scrollback response
public struct ScrollbackPageMeta: Sendable, Equatable {
    /// Total scrollback size available
    public let totalLength: UInt32
    /// Byte offset this chunk starts at
    public let offset: UInt32

    public init(totalLength: UInt32, offset: UInt32) {
        self.totalLength = totalLength
        self.offset = offset
    }

    public init?(from data: Data) {
        guard data.count >= ProtocolConstants.scrollbackMetaSize else { return nil }

        // Use manual byte loading to avoid alignment issues
        self.totalLength = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        self.offset = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
    }
}

// MARK: - History Page Metadata

/// Metadata for a history page. Positions are absolute stream positions (bytes written
/// since the session started). The page covers start..<end minus alternate-screen
/// output; request the next one with before = start. Complete when start <= oldest.
public struct HistoryPageMeta: Sendable, Equatable {
    public let start: UInt64
    public let end: UInt64
    public let oldest: UInt64

    public init(start: UInt64, end: UInt64, oldest: UInt64) {
        self.start = start
        self.end = end
        self.oldest = oldest
    }

    public init?(from data: Data) {
        guard data.count >= ProtocolConstants.historyMetaSize else { return nil }
        let bytes = [UInt8](data.prefix(ProtocolConstants.historyMetaSize))
        func u64(_ at: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | (UInt64(bytes[at + $1]) << (8 * UInt64($1))) }
        }
        self.start = u64(0)
        self.end = u64(8)
        self.oldest = u64(16)
    }

    /// No older history is stored
    public var reachedOldest: Bool { start <= oldest }
}

// MARK: - Window Size

/// Terminal window size
public struct WindowSize: Sendable, Equatable {
    public let rows: UInt16
    public let cols: UInt16
    public let xpixel: UInt16
    public let ypixel: UInt16

    public init(rows: UInt16, cols: UInt16, xpixel: UInt16 = 0, ypixel: UInt16 = 0) {
        self.rows = rows
        self.cols = cols
        self.xpixel = xpixel
        self.ypixel = ypixel
    }
}
