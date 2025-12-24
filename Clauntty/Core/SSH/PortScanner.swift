import Foundation
import os.log

/// Represents a listening port on a remote server
struct RemotePort: Identifiable, Equatable {
    let id: Int  // Same as port number
    let port: Int
    let process: String?
    let address: String  // "127.0.0.1", "0.0.0.0", etc.

    var displayName: String {
        if let process = process {
            return ":\(port) - \(process)"
        }
        return ":\(port)"
    }

    /// Priority for sorting (lower = higher priority)
    var sortPriority: Int {
        // Priority 1: Common dev ports
        let commonPorts = [3000, 3005, 8000, 8080, 5173, 4200, 5000, 9000]
        if commonPorts.contains(port) {
            return 0
        }

        // Priority 2: Dev process names
        if let process = process?.lowercased() {
            let devProcesses = ["node", "python", "bun", "npm", "yarn", "vite", "next", "nuxt"]
            if devProcesses.contains(where: { process.contains($0) }) {
                return 1
            }
        }

        // Priority 3: Everything else
        return 2
    }
}

/// Scans for listening ports on a remote server via SSH
class PortScanner {
    private let connection: SSHConnection

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// List all listening TCP ports on the remote server
    /// Returns ports sorted by priority (common dev ports first)
    func listListeningPorts() async throws -> [RemotePort] {
        // Try ss first (modern Linux), fall back to netstat
        let output = try await connection.executeCommand(
            "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo 'SCAN_FAILED'"
        )

        if output.contains("SCAN_FAILED") {
            Logger.clauntty.warning("PortScanner: neither ss nor netstat available")
            return []
        }

        let ports = parseOutput(output)
        let sorted = ports.sorted { $0.sortPriority < $1.sortPriority || ($0.sortPriority == $1.sortPriority && $0.port < $1.port) }

        Logger.clauntty.info("PortScanner: found \(sorted.count) listening ports")
        return sorted
    }

    /// Parse ss or netstat output
    private func parseOutput(_ output: String) -> [RemotePort] {
        var ports: [RemotePort] = []
        var seenPorts = Set<Int>()

        for line in output.split(separator: "\n") {
            let lineStr = String(line)

            // Skip header lines
            if lineStr.contains("State") || lineStr.contains("Proto") || lineStr.hasPrefix("Netid") {
                continue
            }

            // Try to parse as ss output first, then netstat
            if let port = parseSsLine(lineStr) ?? parseNetstatLine(lineStr) {
                if !seenPorts.contains(port.port) {
                    seenPorts.insert(port.port)
                    ports.append(port)
                }
            }
        }

        return ports
    }

    /// Parse a line from `ss -tlnp` output
    /// Example: "LISTEN 0      4096       127.0.0.1:3000       0.0.0.0:*    users:(("node",pid=1234,fd=19))"
    private func parseSsLine(_ line: String) -> RemotePort? {
        // Look for LISTEN state
        guard line.contains("LISTEN") else { return nil }

        // Extract address:port - look for pattern like "127.0.0.1:3000" or "*:8080" or ":::8080"
        let components = line.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }

        // Find the local address component (usually 4th or 5th field)
        var address = "0.0.0.0"
        var port: Int?

        for component in components {
            // Match patterns like "127.0.0.1:3000", "*:3000", ":::3000", "[::]:3000"
            if let colonIndex = component.lastIndex(of: ":") {
                let portStr = String(component[component.index(after: colonIndex)...])
                if let portNum = Int(portStr), portNum > 0 && portNum < 65536 {
                    let addrPart = String(component[..<colonIndex])
                    // Skip if this looks like a peer address (after local address)
                    if port != nil { continue }

                    port = portNum
                    if addrPart == "*" || addrPart == "[::]" || addrPart == "" {
                        address = "0.0.0.0"
                    } else {
                        address = addrPart.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    }
                }
            }
        }

        guard let portNum = port else { return nil }

        // Extract process name from users:(("name",...))
        var process: String?
        if let usersStart = line.range(of: "users:((\"") {
            let afterQuote = line[usersStart.upperBound...]
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                process = String(afterQuote[..<endQuote])
            }
        }

        return RemotePort(id: portNum, port: portNum, process: process, address: address)
    }

    /// Parse a line from `netstat -tlnp` output
    /// Example: "tcp        0      0 127.0.0.1:3000          0.0.0.0:*               LISTEN      1234/node"
    private func parseNetstatLine(_ line: String) -> RemotePort? {
        guard line.hasPrefix("tcp") else { return nil }
        guard line.contains("LISTEN") else { return nil }

        let components = line.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
        guard components.count >= 4 else { return nil }

        // Local address is usually the 4th field (index 3)
        let localAddr = components[3]

        guard let colonIndex = localAddr.lastIndex(of: ":") else { return nil }
        let portStr = String(localAddr[localAddr.index(after: colonIndex)...])
        guard let portNum = Int(portStr), portNum > 0 && portNum < 65536 else { return nil }

        let addrPart = String(localAddr[..<colonIndex])
        let address = addrPart == "0.0.0.0" || addrPart == "::" ? "0.0.0.0" : addrPart

        // Process is usually the last field, format: "pid/name"
        var process: String?
        if let lastComponent = components.last, lastComponent.contains("/") {
            let parts = lastComponent.split(separator: "/")
            if parts.count >= 2 {
                process = String(parts[1])
            }
        }

        return RemotePort(id: portNum, port: portNum, process: process, address: address)
    }
}
