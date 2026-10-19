import Foundation

/// The hosts in ~/.ssh/config, resolved the way ssh does: for each option the
/// first value from a matching `Host` block wins, so `Host *` at the end gives
/// defaults. `Include` is followed; `Match` blocks are skipped.
struct SSHConfig {
    struct Host: Identifiable, Equatable {
        /// The name after `Host`, what you'd type after `ssh`
        let alias: String
        let hostName: String
        let user: String
        let port: Int
        /// Key files to offer, in order, `~` expanded
        let identityFiles: [String]
        /// A command to carry the connection (ProxyCommand, or ProxyJump made into one)
        let proxyCommand: String?
        /// Options this app can't follow yet (ProxyJump...); the connection may fail
        let unsupported: [String]

        var id: String { alias }

        /// The first key file that exists, else ssh's default keys
        var keyFile: String? {
            let fm = FileManager.default
            if let file = identityFiles.first(where: { fm.fileExists(atPath: $0) }) { return file }
            let ssh = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
            return ["id_ed25519", "id_ecdsa"].map { (ssh as NSString).appendingPathComponent($0) }
                .first { fm.fileExists(atPath: $0) }
        }
    }

    private struct Block {
        /// Host patterns; nil for `Match` blocks, which are skipped
        let patterns: [String]?
        var options: [(key: String, value: String)] = []
    }

    private var blocks: [Block] = []

    /// ~/.ssh/config, or `CLAUNTTY_SSH_CONFIG` (tests point it at a scratch file)
    static var defaultPath: String {
        ProcessInfo.processInfo.environment["CLAUNTTY_SSH_CONFIG"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    init(path: String = SSHConfig.defaultPath) {
        // Options before the first Host apply to every host
        blocks = [Block(patterns: ["*"])]
        read(path, depth: 0)
    }

    /// Host names to list: every alias that's a plain name, not a pattern
    var aliases: [String] {
        var seen = Set<String>()
        return blocks.compactMap(\.patterns).flatMap { $0 }
            .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            .filter { seen.insert($0).inserted }
    }

    var hosts: [Host] { aliases.map(resolve) }

    func resolve(_ alias: String) -> Host {
        var values: [String: String] = [:]
        var identityFiles: [String] = []
        for block in blocks {
            guard let patterns = block.patterns, Self.matches(alias, patterns) else { continue }
            for (key, value) in block.options {
                if key == "identityfile" {
                    identityFiles.append(value)
                } else if values[key] == nil {
                    values[key] = value
                }
            }
        }
        let hostName = (values["hostname"] ?? alias).replacingOccurrences(of: "%h", with: alias)
        let user = values["user"] ?? NSUserName()
        let expand = { (path: String) -> String in
            var path = path
                .replacingOccurrences(of: "%d", with: NSHomeDirectory())
                .replacingOccurrences(of: "%u", with: NSUserName())
                .replacingOccurrences(of: "%r", with: user)
                .replacingOccurrences(of: "%h", with: hostName)
            if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
            return path
        }
        let unsupported = ["localforward", "remoteforward"].filter { values[$0] != nil }
        // ssh turns ProxyJump into `ssh -W` through the jump host; so do we
        let set = { (key: String) in values[key].flatMap { $0.lowercased() == "none" ? nil : $0 } }
        let proxyCommand = set("proxycommand") ?? set("proxyjump").map { "ssh -W '[%h]:%p' \($0)" }
        return Host(
            alias: alias,
            hostName: hostName,
            user: user,
            port: values["port"].flatMap(Int.init) ?? 22,
            identityFiles: identityFiles.map(expand),
            proxyCommand: proxyCommand,
            unsupported: unsupported
        )
    }

    // MARK: Parsing

    private mutating func read(_ path: String, depth: Int) {
        guard depth < 8, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = Self.parse(String(rawLine)) else { continue }
            switch key {
            case "host":
                blocks.append(Block(patterns: Self.words(value)))
            case "match":
                blocks.append(Block(patterns: nil))
            case "include":
                let enclosing = blocks[blocks.count - 1].patterns
                let before = blocks.count
                for pattern in Self.words(value) {
                    for file in Self.glob(pattern) { read(file, depth: depth + 1) }
                }
                // Options after the Include still belong to the enclosing block
                if blocks.count != before { blocks.append(Block(patterns: enclosing)) }
            default:
                blocks[blocks.count - 1].options.append((key, value))
            }
        }
    }

    /// `Keyword value`, `Keyword=value` or `Keyword = value`; keywords are case-insensitive
    private static func parse(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = trimmed[..<split].lowercased()
        var value = trimmed[split...].drop { $0 == " " || $0 == "\t" || $0 == "=" }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
        return (key, String(value).trimmingCharacters(in: .whitespaces))
    }

    private static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0).trimmingCharacters(in: ["\""]) }
    }

    /// ssh's `Host` matching: any pattern matches, and no negated (`!`) one does
    private static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false }
            } else if fnmatch(pattern, alias, 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    /// An `Include` path: relative ones are under ~/.ssh
    private static func glob(_ pattern: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + path)
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}
