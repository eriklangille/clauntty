import Foundation
import os.log

/// Metadata stored for each session in ~/.clauntty/sessions.json
struct SessionMetadata: Codable {
    var name: String
    var created: Date
    var lastAccessed: Date?
}

/// Information about an existing rtach session on a remote server
struct RtachSession: Identifiable {
    let id: String          // Session ID (filename)
    var name: String        // Display name (from metadata or generated)
    var title: String?      // Terminal title from OSC escape sequences (from .title file)
    let lastActive: Date    // Last modification time
    let socketPath: String  // Full path to socket
    let created: Date?      // Creation time from metadata

    /// Display name for UI - prefer OSC title, fall back to verb-noun name
    var displayName: String {
        if let title = title, !title.isEmpty {
            return title
        }
        return name
    }

    /// Human-readable description of last activity
    var lastActiveDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActive, relativeTo: Date())
    }
}

/// Handles deploying rtach to remote servers for session persistence
///
/// Versioned binary deployment: rtach is deployed to ~/.clauntty/bin/rtach-{version}
/// This allows updates without "Text file busy" errors - new sessions use the new binary
/// while old sessions continue with the old one.
class RtachDeployer {
    let connection: SSHConnection

    /// Remote path where rtach is installed (versioned to allow updates without killing sessions)
    static var remoteBinPath: String { "~/.clauntty/bin/rtach-\(expectedVersion)" }
    static let remoteSessionsPath = "~/.clauntty/sessions"
    static let remoteMetadataPath = "~/.clauntty/sessions.json"
    static let claudeSettingsPath = "~/.claude/settings.json"

    /// Expected rtach version - must match rtach's version constant
    /// Increment this when rtach is updated to force redeployment
    /// 1.4.0 - Added shell integration (env var only)
    /// 1.4.1 - Fixed SIGWINCH handling to check on every loop iteration
    /// 1.5.0 - Limit initial scrollback to 16KB for faster reconnects
    /// 1.6.0 - Add request_scrollback for on-demand old scrollback loading
    /// 1.6.1 - Fix ResponseHeader padding (use packed struct for exact 5-byte header)
    /// 1.7.0 - Add client_id to attach packet to prevent duplicate connections from same device
    /// 1.8.0 - Skip scrollback on attach when in alternate screen mode (fixes TUI app corruption)
    /// 1.8.1 - Remove OSC 133 from shell integration (caused resize bugs in Ghostty)
    /// 1.8.2 - Track and restore cursor visibility state on reconnect (fixes dual cursor in Claude Code)
    /// 1.8.3 - Performance: ReleaseFast, writev for scrollback, debug logs in hot paths
    /// 1.8.4 - Explicit SIGWINCH to process group on window size change (fixes TUI redraw)
    /// 1.9.0 - Command pipe: scripts write to $RTACH_CMD_FD to send commands to Clauntty
    /// 2.0.0 - Framed protocol: ALL data from rtach is now framed [type][len][payload]
    ///         Adds handshake on attach with magic "RTCH" and protocol version.
    ///         Fixes race conditions where terminal data was misinterpreted as protocol headers.
    /// 2.0.1 - Send alternate screen escape sequence on reconnect (fixes "@" artifact in Claude Code)
    /// 2.1.0 - Pause/resume/idle: Battery optimization for inactive tabs.
    ///         New messages: pause(8), resume(9) from client; idle(4) from server.
    ///         Paused clients don't receive streaming data; buffered output flushed on resume.
    ///         Idle notification sent after 2s of no PTY output (enables background notifications).
    /// 2.1.1 - Debug logging to /tmp/rtach-debug.log
    /// 2.1.2 - More detailed packet reception and idle timer logging with timestamps
    /// 2.1.3 - Add PID to log prefix for multi-session debugging
    /// 2.1.4 - Fix: client.zig now forwards pause/resume packets to master
    /// 2.2.0 - Phase 2 network optimization complete: pause/resume/idle working
    /// 2.3.0 - OSC 0/1/2 title parsing: saves terminal title to .title file for session picker
    /// 2.4.0 - Shell integration: bash/zsh/fish set title to current directory and running command
    /// 2.5.0 - FIFO command pipe: use RTACH_CMD_PIPE instead of RTACH_CMD_FD (fixes Claude Code subprocess issue)
    ///         Versioned binary path: allows updates without killing existing sessions
    /// 2.5.1 - Fix: client.zig stdin buffer 256→4096 bytes + partial packet buffering (fixes multiline paste)
    /// 2.5.2 - Fix: writeTitleToFile uses cwd-relative file ops (fixes panic with relative socket path)
    /// 2.5.3 - Per-session log files ({socket}.log), ReleaseFast default build
    /// 2.6.0 - Compression: terminal_data payloads are zlib-compressed when beneficial (30-60% bandwidth savings)
    /// 2.6.1 - Fix: client.zig forwards iOS upgrade packet to master for compression handshake
    /// 2.6.2 - Diagnostics: signal handlers, heartbeat logging, allocation failure logging
    /// 2.6.3 - Fix: Always send SIGWINCH on resume (fixes frozen Claude Code after tab switch)
    /// 2.6.4 - Fix: Resume uses monotonic counter to flush buffered output correctly
    /// 2.6.5 - Fix: Proxy client waits for iOS upgrade before upgrading master
    /// 2.6.6 - Fix: Explicit proxy mode flag (avoid TTY detection mismatch)
    /// 2.7.0 - Interactive session picker: run 'rtach' with no args to select a session
    static let expectedVersion = "2.7.0"

    /// Unique client ID for this app instance (prevents duplicate connections from same device)
    /// Generated once and stored in UserDefaults - no device info leaves the app
    static var clientId: String {
        let key = "rtach_client_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// Deploy rtach to the remote server if not already present
    /// Returns the command to wrap the shell with rtach
    func deployIfNeeded(sessionId: String = "default") async throws -> String {
        Logger.clauntty.debugOnly("Checking rtach deployment status...")

        // 1. Check remote architecture
        let arch = try await getRemoteArch()
        Logger.clauntty.debugOnly("Remote architecture: \(arch)")

        // 2. Check if rtach exists and is executable
        let exists = try await rtachExists()

        if !exists {
            Logger.clauntty.debugOnly("rtach not found, deploying...")
            try await deploy(arch: arch)
        } else {
            Logger.clauntty.debugOnly("rtach already deployed")
        }

        // 3. Ensure sessions directory exists
        _ = try await connection.executeCommand("mkdir -p \(Self.remoteSessionsPath)")

        // 4. Return the wrapped shell command with client ID
        let sessionPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        return "\(Self.remoteBinPath) --proxy -A -C \(Self.clientId) \(sessionPath) $SHELL"
    }

    /// Get the shell command for rtach (assumes already deployed)
    func shellCommand(sessionId: String = "default") -> String {
        let sessionPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        return "\(Self.remoteBinPath) --proxy -A -C \(Self.clientId) \(sessionPath) $SHELL"
    }

    /// List existing rtach sessions on the remote server
    /// Returns sessions sorted by last active time (most recent first)
    func listSessions() async throws -> [RtachSession] {
        // Use stat to get modification times (epoch format for easy parsing)
        // Format: filename epoch_time
        let output = try await connection.executeCommand(
            "for f in \(Self.remoteSessionsPath)/*; do " +
            "[ -S \"$f\" ] && stat -c '%n %Y' \"$f\" 2>/dev/null; " +
            "done || true"
        )

        // Load existing metadata
        var metadata = try await loadSessionMetadata()
        var metadataChanged = false

        // Collect session IDs first
        var sessionIds: [String] = []
        var sessionData: [(id: String, fullPath: String, epochTime: Double)] = []

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let epochTime = Double(parts[parts.count - 1]) else {
                continue
            }

            let fullPath = String(parts[0..<(parts.count - 1)].joined(separator: " "))
            let sessionId = (fullPath as NSString).lastPathComponent
            sessionIds.append(sessionId)
            sessionData.append((id: sessionId, fullPath: fullPath, epochTime: epochTime))
        }

        // Read all .title files in one command (more efficient than per-session)
        // Output format: sessionId<TAB>title (one per line)
        var titles: [String: String] = [:]
        if !sessionIds.isEmpty {
            let titleOutput = try await connection.executeCommand(
                "for f in \(Self.remoteSessionsPath)/*.title; do " +
                "[ -f \"$f\" ] && echo -e \"$(basename \"$f\" .title)\\t$(cat \"$f\")\"; " +
                "done 2>/dev/null || true"
            )
            for line in titleOutput.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 {
                    let sessionId = String(parts[0])
                    let title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        titles[sessionId] = title
                    }
                }
            }
        }

        var sessions: [RtachSession] = []

        for data in sessionData {
            // Get or create metadata for this session
            let sessionMeta: SessionMetadata
            if let existing = metadata[data.id] {
                sessionMeta = existing
            } else {
                // Generate new name for sessions without metadata
                sessionMeta = SessionMetadata(
                    name: SessionNameGenerator.generate(),
                    created: Date(timeIntervalSince1970: data.epochTime),
                    lastAccessed: nil
                )
                metadata[data.id] = sessionMeta
                metadataChanged = true
            }

            // Use lastAccessed from metadata if available, otherwise fall back to file mtime
            let lastActiveDate = sessionMeta.lastAccessed ?? Date(timeIntervalSince1970: data.epochTime)

            let session = RtachSession(
                id: data.id,
                name: sessionMeta.name,
                title: titles[data.id],
                lastActive: lastActiveDate,
                socketPath: data.fullPath,
                created: sessionMeta.created
            )
            sessions.append(session)
        }

        // Save metadata if we generated new names
        if metadataChanged {
            try await saveSessionMetadata(metadata)
        }

        // Sort by most recent first
        sessions.sort { $0.lastActive > $1.lastActive }

        Logger.clauntty.debugOnly("Found \(sessions.count) existing rtach sessions")
        return sessions
    }

    /// Check if rtach is available (deployed) on the remote server
    func isDeployed() async throws -> Bool {
        return try await rtachExists()
    }

    /// Deploy rtach if needed (without creating a session)
    /// Checks version and redeploys if outdated
    func ensureDeployed() async throws {
        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: checking if update needed...")
        if try await needsUpdate() {
            Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: update needed, getting arch...")
            let arch = try await getRemoteArch()
            Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: deploying for \(arch)...")
            try await deploy(arch: arch)
        }
        // Ensure sessions directory exists
        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: creating sessions directory...")
        _ = try await connection.executeCommand("mkdir -p \(Self.remoteSessionsPath)")

        // Deploy helper scripts (forward-port, open-tab)
        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: deploying helper scripts...")
        try await deployHelperScripts()

        // Deploy Claude Code hook for input detection
        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: deploying Claude Code hook...")
        try await deployClaudeHook()

        // Clean up old unused binaries
        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: cleaning up old binaries...")
        await cleanupOldBinaries()

        Logger.clauntty.debugOnly("RtachDeployer.ensureDeployed: done")
    }

    /// Clean up old rtach binaries that are no longer in use
    /// Keeps: current version + any versions with running processes
    private func cleanupOldBinaries() async {
        do {
            let platform = try await getRemotePlatform()

            // Build cleanup command based on OS
            // Linux: use /proc/{pid}/exe symlink
            // macOS: use lsof to find binary paths
            let findInUseCmd: String
            if platform.os == "linux" {
                findInUseCmd = "for pid in $(pgrep -f rtach 2>/dev/null); do readlink /proc/$pid/exe 2>/dev/null; done | sort -u"
            } else {
                // macOS/Darwin - use lsof
                findInUseCmd = "lsof -c rtach 2>/dev/null | awk '/rtach-[0-9]/ {print $9}' | sort -u"
            }

            // Get list of binaries currently in use
            let inUseOutput = try await connection.executeCommand(findInUseCmd)
            let inUseBinaries = Set(inUseOutput.split(separator: "\n").map { String($0) })

            // Get all rtach binaries in ~/.clauntty/bin/
            let listCmd = "ls -1 ~/.clauntty/bin/rtach-* 2>/dev/null || true"
            let allOutput = try await connection.executeCommand(listCmd)
            let allBinaries = allOutput.split(separator: "\n").map { String($0) }

            var deleted = 0
            for binary in allBinaries {
                let binaryPath = binary.trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip if current version
                if binaryPath.hasSuffix("rtach-\(Self.expectedVersion)") {
                    continue
                }

                // Skip if in use
                if inUseBinaries.contains(binaryPath) {
                    Logger.clauntty.debugOnly("Keeping \(binaryPath) (in use)")
                    continue
                }

                // Delete unused binary
                _ = try await connection.executeCommand("rm -f '\(binaryPath)'")
                deleted += 1
                Logger.clauntty.debugOnly("Deleted old binary: \(binaryPath)")
            }

            if deleted > 0 {
                Logger.clauntty.info("Cleaned up \(deleted) old rtach binaries")
            }
        } catch {
            // Non-fatal - don't break deployment if cleanup fails
            Logger.clauntty.warning("Failed to cleanup old binaries: \(error)")
        }
    }

    // MARK: - Helper Scripts

    /// Deploy helper scripts for port forwarding
    private func deployHelperScripts() async throws {
        // Deploy forward-port script (handles both "8000" and "http://localhost:8000")
        // Uses RTACH_CMD_PIPE (FIFO path) to send commands to Clauntty
        _ = try await connection.executeCommand(
            "cat > ~/.clauntty/bin/forward-port << 'EOF'\n" +
            "#!/bin/bash\n" +
            "arg=\"$1\"\n" +
            "# Extract port from URL if needed (http://localhost:8000 -> 8000)\n" +
            "if [[ \"$arg\" == *://* ]]; then\n" +
            "  port=\"${arg##*:}\"\n" +
            "  port=\"${port%%/*}\"\n" +
            "else\n" +
            "  port=\"$arg\"\n" +
            "fi\n" +
            "if [ -z \"$RTACH_CMD_PIPE\" ]; then\n" +
            "  echo \"Error: RTACH_CMD_PIPE not set (not running in rtach session)\" >&2\n" +
            "  exit 1\n" +
            "fi\n" +
            "if ! echo \"forward;$port\" > \"$RTACH_CMD_PIPE\" 2>/dev/null; then\n" +
            "  echo \"Error: Failed to write to RTACH_CMD_PIPE\" >&2\n" +
            "  exit 1\n" +
            "fi\n" +
            "echo \"Port $port forwarded\"\n" +
            "EOF\n" +
            "chmod +x ~/.clauntty/bin/forward-port"
        )

        // Deploy open-tab script (handles both "8000" and "http://localhost:8000")
        // Uses RTACH_CMD_PIPE (FIFO path) to send commands to Clauntty
        _ = try await connection.executeCommand(
            "cat > ~/.clauntty/bin/open-tab << 'EOF'\n" +
            "#!/bin/bash\n" +
            "arg=\"$1\"\n" +
            "# Extract port from URL if needed (http://localhost:8000 -> 8000)\n" +
            "if [[ \"$arg\" == *://* ]]; then\n" +
            "  port=\"${arg##*:}\"\n" +
            "  port=\"${port%%/*}\"\n" +
            "else\n" +
            "  port=\"$arg\"\n" +
            "fi\n" +
            "if [ -z \"$RTACH_CMD_PIPE\" ]; then\n" +
            "  echo \"Error: RTACH_CMD_PIPE not set (not running in rtach session)\" >&2\n" +
            "  exit 1\n" +
            "fi\n" +
            "if ! echo \"open;$port\" > \"$RTACH_CMD_PIPE\" 2>/dev/null; then\n" +
            "  echo \"Error: Failed to write to RTACH_CMD_PIPE\" >&2\n" +
            "  exit 1\n" +
            "fi\n" +
            "echo \"Opened port $port\"\n" +
            "EOF\n" +
            "chmod +x ~/.clauntty/bin/open-tab"
        )

        Logger.clauntty.debugOnly("Helper scripts deployed (forward-port, open-tab)")
    }

    // MARK: - Claude Code Settings

    /// Deploy Claude Code settings (PATH and permissions for helper scripts)
    private func deployClaudeHook() async throws {
        // Read existing settings
        let output = try await connection.executeCommand(
            "cat \(Self.claudeSettingsPath) 2>/dev/null || echo '{}'"
        )

        let jsonString = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Invalid JSON or empty, create fresh settings
            try await writeClaudeSettings([:])
            return
        }

        var needsUpdate = false

        // Add PATH for helper scripts (Claude sessions only)
        // Include /usr/bin:/bin to ensure system tools like base64 are available in Claude Code snapshots
        var env = settings["env"] as? [String: String] ?? [:]
        let expectedPath = "/usr/bin:/bin:$HOME/.clauntty/bin:$PATH"
        if env["PATH"] != expectedPath {
            env["PATH"] = expectedPath
            settings["env"] = env
            needsUpdate = true
        }

        // Add permissions for helper scripts (use full path to avoid PATH issues)
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        let requiredPerms = [
            "Bash(~/.clauntty/bin/forward-port:*)",
            "Bash(~/.clauntty/bin/open-tab:*)"
        ]
        for perm in requiredPerms {
            if !allow.contains(perm) {
                allow.append(perm)
                needsUpdate = true
            }
        }
        permissions["allow"] = allow
        settings["permissions"] = permissions

        if needsUpdate {
            try await writeClaudeSettings(settings)
            Logger.clauntty.debugOnly("Claude Code settings deployed (env, permissions)")
        } else {
            Logger.clauntty.debugOnly("Claude Code settings already configured")
        }
    }

    /// Write Claude settings to remote server
    private func writeClaudeSettings(_ settings: [String: Any]) async throws {
        // Ensure directory exists
        _ = try await connection.executeCommand("mkdir -p ~/.claude")

        // Build settings with env and permissions if empty
        var finalSettings = settings
        if finalSettings.isEmpty {
            finalSettings = [
                "env": [
                    "PATH": "/usr/bin:/bin:$HOME/.clauntty/bin:$PATH"
                ],
                "permissions": [
                    "allow": [
                        "Bash(~/.clauntty/bin/forward-port:*)",
                        "Bash(~/.clauntty/bin/open-tab:*)"
                    ]
                ]
            ]
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: finalSettings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            Logger.clauntty.error("Failed to serialize Claude settings")
            return
        }

        try await connection.executeWithStdin(
            "cat > \(Self.claudeSettingsPath)",
            stdinData: data
        )
    }

    // MARK: - Session Metadata

    /// Load session metadata from remote server
    func loadSessionMetadata() async throws -> [String: SessionMetadata] {
        let output = try await connection.executeCommand(
            "cat \(Self.remoteMetadataPath) 2>/dev/null || echo '{}'"
        )

        let jsonString = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            return try decoder.decode([String: SessionMetadata].self, from: data)
        } catch {
            Logger.clauntty.warning("Failed to decode session metadata: \(error)")
            return [:]
        }
    }

    /// Save session metadata to remote server
    func saveSessionMetadata(_ metadata: [String: SessionMetadata]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(metadata)

        // Write metadata file
        try await connection.executeWithStdin(
            "cat > \(Self.remoteMetadataPath)",
            stdinData: data
        )

        Logger.clauntty.debugOnly("Saved session metadata (\(metadata.count) sessions)")
    }

    /// Delete a session (kills the process and removes the socket)
    func deleteSession(sessionId: String) async throws {
        Logger.clauntty.debugOnly("Deleting session: \(sessionId)")

        // 1. Kill any rtach processes for this session
        _ = try await connection.executeCommand(
            "pkill -f 'rtach.*\(sessionId)' 2>/dev/null || true"
        )

        // 2. Remove the socket and associated files (.log, .cmd, .title)
        let socketPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        _ = try await connection.executeCommand("rm -f \(socketPath) \(socketPath).log \(socketPath).cmd \(socketPath).title")

        // 3. Remove from metadata
        var metadata = try await loadSessionMetadata()
        metadata.removeValue(forKey: sessionId)
        try await saveSessionMetadata(metadata)

        Logger.clauntty.debugOnly("Session deleted: \(sessionId)")
    }

    /// Rename a session
    func renameSession(sessionId: String, newName: String) async throws {
        guard SessionNameGenerator.isValid(newName) else {
            throw RtachDeployError.invalidSessionName
        }

        var metadata = try await loadSessionMetadata()

        if var sessionMeta = metadata[sessionId] {
            sessionMeta.name = newName
            metadata[sessionId] = sessionMeta
        } else {
            // Create metadata if it doesn't exist
            metadata[sessionId] = SessionMetadata(name: newName, created: Date(), lastAccessed: nil)
        }

        try await saveSessionMetadata(metadata)
        Logger.clauntty.debugOnly("Session renamed: \(sessionId) -> \(newName)")
    }

    /// Update last accessed time for a session (call when connecting)
    func updateLastAccessed(sessionId: String) async throws {
        var metadata = try await loadSessionMetadata()

        if var sessionMeta = metadata[sessionId] {
            sessionMeta.lastAccessed = Date()
            metadata[sessionId] = sessionMeta
        } else {
            // Create metadata if it doesn't exist
            metadata[sessionId] = SessionMetadata(
                name: SessionNameGenerator.generate(),
                created: Date(),
                lastAccessed: Date()
            )
        }

        try await saveSessionMetadata(metadata)
        Logger.clauntty.debugOnly("Updated last accessed for session: \(sessionId)")
    }

    // MARK: - Private

    /// Remote platform info (OS and architecture)
    struct RemotePlatform {
        let os: String      // "linux" or "darwin"
        let arch: String    // "x86_64" or "aarch64"
    }

    private func getRemotePlatform() async throws -> RemotePlatform {
        let output = try await connection.executeCommand("uname -sm")
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2 else {
            throw RtachDeployError.unsupportedArchitecture(output)
        }

        let osName = String(parts[0]).lowercased()
        let archName = String(parts[1])

        // Normalize OS
        let os: String
        switch osName {
        case "linux":
            os = "linux"
        case "darwin":
            os = "darwin"
        default:
            throw RtachDeployError.unsupportedArchitecture("\(osName) \(archName)")
        }

        // Normalize arch names
        let arch: String
        switch archName {
        case "x86_64", "amd64":
            arch = "x86_64"
        case "aarch64", "arm64":
            arch = "aarch64"
        default:
            throw RtachDeployError.unsupportedArchitecture(archName)
        }

        return RemotePlatform(os: os, arch: arch)
    }

    private func getRemoteArch() async throws -> String {
        let platform = try await getRemotePlatform()
        return platform.arch
    }

    private func rtachExists() async throws -> Bool {
        let output = try await connection.executeCommand("test -x \(Self.remoteBinPath) && echo exists || echo missing")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "exists"
    }

    /// Get the version of rtach installed on remote server (nil if not installed or version unknown)
    private func getRemoteVersion() async throws -> String? {
        let output = try await connection.executeCommand("\(Self.remoteBinPath) --version 2>/dev/null || echo unknown")
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == "unknown" ? nil : version
    }

    /// Check if remote rtach needs to be updated
    private func needsUpdate() async throws -> Bool {
        guard try await rtachExists() else {
            return true // Not installed, needs deployment
        }

        guard let remoteVersion = try await getRemoteVersion() else {
            Logger.clauntty.debugOnly("Remote rtach version unknown, will redeploy")
            return true // Can't determine version, redeploy to be safe
        }

        let needsUpdate = remoteVersion != Self.expectedVersion
        if needsUpdate {
            Logger.clauntty.debugOnly("Remote rtach version \(remoteVersion) != expected \(Self.expectedVersion), will update")
        } else {
            Logger.clauntty.debugOnly("Remote rtach version \(remoteVersion) is up to date")
        }
        return needsUpdate
    }

    private func deploy(arch: String) async throws {
        // Get full platform info for binary selection
        let platform = try await getRemotePlatform()

        // Get the binary from app bundle
        guard let binaryData = loadBundledBinary(for: platform) else {
            throw RtachDeployError.binaryNotFound("\(platform.os)-\(platform.arch)")
        }

        Logger.clauntty.debugOnly("Uploading rtach binary for \(platform.os)-\(platform.arch) (\(binaryData.count) bytes)...")

        // Create directory
        _ = try await connection.executeCommand("mkdir -p ~/.clauntty/bin")

        // Upload binary via stdin
        // Use 'cat > file' trick since we don't have SFTP
        try await connection.executeWithStdin(
            "cat > \(Self.remoteBinPath) && chmod +x \(Self.remoteBinPath)",
            stdinData: binaryData
        )

        // Verify deployment
        let verified = try await rtachExists()
        if !verified {
            throw RtachDeployError.deploymentFailed
        }

        // Create/update symlink for easy command-line access
        // This allows users to run 'rtach' instead of 'rtach-2.6.6'
        _ = try await connection.executeCommand(
            "ln -sf \(Self.remoteBinPath) ~/.clauntty/bin/rtach"
        )

        Logger.clauntty.debugOnly("rtach deployed successfully")
    }

    private func loadBundledBinary(for platform: RemotePlatform) -> Data? {
        let binaryName: String
        switch (platform.os, platform.arch) {
        case ("linux", "x86_64"):
            binaryName = "rtach-x86_64-linux-musl"
        case ("linux", "aarch64"):
            binaryName = "rtach-aarch64-linux-musl"
        case ("darwin", "x86_64"):
            binaryName = "rtach-x86_64-macos"
        case ("darwin", "aarch64"):
            binaryName = "rtach-aarch64-macos"
        default:
            return nil
        }

        // Try to find in bundle
        if let url = Bundle.main.url(forResource: binaryName, withExtension: nil, subdirectory: "rtach") {
            return try? Data(contentsOf: url)
        }

        // Fallback: try without subdirectory
        if let url = Bundle.main.url(forResource: binaryName, withExtension: nil) {
            return try? Data(contentsOf: url)
        }

        Logger.clauntty.error("Could not find bundled binary: \(binaryName)")
        return nil
    }
}

// MARK: - Errors

enum RtachDeployError: Error, LocalizedError {
    case unsupportedArchitecture(String)
    case binaryNotFound(String)
    case deploymentFailed
    case metadataSaveFailed
    case invalidSessionName

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Unsupported remote architecture: \(arch)"
        case .binaryNotFound(let arch):
            return "rtach binary not found for architecture: \(arch)"
        case .deploymentFailed:
            return "Failed to deploy rtach to remote server"
        case .metadataSaveFailed:
            return "Failed to save session metadata"
        case .invalidSessionName:
            return "Invalid session name. Use only letters, numbers, and hyphens."
        }
    }
}
