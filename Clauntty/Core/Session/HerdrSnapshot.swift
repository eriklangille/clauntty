import CryptoKit
import Foundation

/// Agent state of a Herdr pane
enum HerdrAgentStatus: Equatable {
    /// No agent in the pane (a shell, a dev server)
    case none
    case idle
    case working
    case blocked
    case done
}

/// A pane as the tab bar shows it
struct HerdrPaneInfo: Equatable {
    let paneId: String
    let terminalId: String
    let title: String
    let status: HerdrAgentStatus
    /// Index of the Herdr tab the pane is in. Panes sharing one are splits on the laptop.
    let group: Int
}

/// One Herdr session (workspace), shown as one Clauntty tab
struct HerdrWorkspaceInfo: Equatable {
    let workspaceId: String
    let label: String
    /// In Herdr's order: tabs by number, then panes in layout order
    let panes: [HerdrPaneInfo]
    /// The pane focused in the workspace's active tab, the default to show
    let focusedPaneId: String?
}

/// What `herdr api snapshot` reports, cut down to what the tab bar needs
struct HerdrSnapshot: Decodable {
    struct Workspace: Decodable {
        let workspaceId: String
        let label: String
        let number: Int
        let activeTabId: String?
    }

    struct Tab: Decodable {
        let tabId: String
        let workspaceId: String
        let number: Int
    }

    struct Pane: Decodable {
        let paneId: String
        let tabId: String
        let workspaceId: String
        let terminalId: String
        let agent: String?
        let agentStatus: String?
        let terminalTitleStripped: String?
        let cwd: String?
        let foregroundCwd: String?
    }

    struct Layout: Decodable {
        struct Entry: Decodable {
            let paneId: String
        }

        let tabId: String
        let focusedPaneId: String?
        let panes: [Entry]
    }

    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let layouts: [Layout]

    /// Parse `herdr api snapshot` output: `{"id":…,"result":{"snapshot":{…}}}`
    static func parse(_ data: Data) throws -> HerdrSnapshot {
        struct Response: Decodable {
            struct Result: Decodable { let snapshot: HerdrSnapshot }
            let result: Result
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data).result.snapshot
    }

    /// Workspaces in Herdr's order, each with its panes in Herdr's order
    func workspaceInfos() -> [HerdrWorkspaceInfo] {
        let panesById = Dictionary(panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
        let layoutsByTab = Dictionary(layouts.map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })

        return workspaces.sorted { $0.number < $1.number }.map { workspace in
            let workspaceTabs = tabs.filter { $0.workspaceId == workspace.workspaceId }.sorted { $0.number < $1.number }
            var infos: [HerdrPaneInfo] = []
            for (group, tab) in workspaceTabs.enumerated() {
                // Layout order first, then any pane the layout doesn't list
                var ordered = layoutsByTab[tab.tabId]?.panes.compactMap { panesById[$0.paneId] } ?? []
                for pane in panes where pane.tabId == tab.tabId && !ordered.contains(where: { $0.paneId == pane.paneId }) {
                    ordered.append(pane)
                }
                infos += ordered.map { pane in
                    HerdrPaneInfo(
                        paneId: pane.paneId,
                        terminalId: pane.terminalId,
                        title: Self.title(for: pane),
                        status: Self.status(for: pane),
                        group: group
                    )
                }
            }
            let focused = workspace.activeTabId.flatMap { layoutsByTab[$0]?.focusedPaneId }
            return HerdrWorkspaceInfo(
                workspaceId: workspace.workspaceId,
                label: workspace.label,
                panes: infos,
                focusedPaneId: focused
            )
        }
    }

    /// Claude names its conversation in the terminal title; otherwise the agent, or the folder
    static func title(for pane: Pane) -> String {
        if let title = pane.terminalTitleStripped?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title
        }
        if let agent = pane.agent, !agent.isEmpty {
            return agent
        }
        let folder = (pane.foregroundCwd ?? pane.cwd).map { ($0 as NSString).lastPathComponent } ?? ""
        return folder.isEmpty ? pane.paneId : folder
    }

    static func status(for pane: Pane) -> HerdrAgentStatus {
        guard pane.agent != nil else { return .none }
        switch pane.agentStatus {
        case "working": return .working
        case "blocked": return .blocked
        case "done": return .done
        default: return .idle
        }
    }
}

/// Shell commands the app runs on a machine with Herdr
enum HerdrCommands {
    /// Finds herdr even when ~/.local/bin isn't on a non-interactive PATH
    static let findHerdr = #"H=$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"#

    static let snapshot = findHerdr + #"; "$H" api snapshot"#

    /// Herdr ids are short ASCII handles; anything else is refused rather than quoted
    static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":") }
    }

    /// The rtach session that shows a pane: one per Herdr terminal, so reopening a pane
    /// reattaches to the same session
    static func rtachSessionId(terminalId: String) -> String {
        "herdr-" + terminalId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func isPaneSession(_ rtachSessionId: String) -> Bool {
        rtachSessionId.hasPrefix("herdr-")
    }

    /// rtach runs one program with no arguments, so each pane gets a tiny script that
    /// attaches to it. Returns the script path (for rtach) and the command that writes it.
    static func attachScript(rtachSessionId: String, terminalId: String) -> (path: String, write: String)? {
        guard isSafe(terminalId), isSafe(rtachSessionId) else { return nil }
        let path = "$HOME/.clauntty/herdr/\(rtachSessionId)"
        let write = """
        mkdir -p "$HOME/.clauntty/herdr" && cat > "\(path)" <<'EOF'
        #!/bin/sh
        \(findHerdr)
        export TERM="${TERM:-xterm-256color}"
        # rtach sizes the terminal once the app attaches, and herdr refuses a zero-sized
        # one. Until then stty fails or prints zeros (it varies by stty), so wait for both.
        i=0
        while [ $i -lt 50 ]; do
          set -- $(stty size 2>/dev/null)
          [ "${1:-0}" -gt 0 ] 2>/dev/null && [ "${2:-0}" -gt 0 ] 2>/dev/null && break
          sleep 0.1
          i=$((i+1))
        done
        exec "$H" terminal attach \(terminalId) --takeover
        EOF
        chmod +x "\(path)"
        """
        return (path, write)
    }

    /// A stable tab id for a workspace on a machine, so its bubble survives pane switches
    /// and app launches
    static func tabId(connectionId: UUID, workspaceId: String) -> UUID {
        let digest = SHA256.hash(data: Data("herdr|\(connectionId.uuidString)|\(workspaceId)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
