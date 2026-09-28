import Foundation

/// Represents a saved SSH connection configuration
struct SavedConnection: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var lastConnected: Date?
    /// Connect through clauntty's embedded Tailscale node
    var useTailscale: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod,
        lastConnected: Date? = nil,
        useTailscale: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.lastConnected = lastConnected
        self.useTailscale = useTailscale
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, lastConnected, useTailscale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        // Added later; connections saved before Tailscale support lack it
        useTailscale = try c.decodeIfPresent(Bool.self, forKey: .useTailscale) ?? false
    }

    /// Whether the host looks like a tailnet address (100.64.0.0/10 or MagicDNS)
    static func looksLikeTailnetHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Display name - uses custom name or falls back to user@host
    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    /// SSH endpoint with optional custom port.
    /// Uses raw numeric port formatting (no locale grouping separators).
    var endpointDisplay: String {
        if port == 22 {
            return "\(username)@\(host)"
        }
        
        return "\(username)@\(host):\(port)"
    }
}

/// Authentication method for SSH connections
enum AuthMethod: Codable, Hashable {
    case password
    case sshKey(keyId: String)

    var displayName: String {
        switch self {
        case .password:
            return "Password"
        case .sshKey:
            return "SSH Key"
        }
    }
}
