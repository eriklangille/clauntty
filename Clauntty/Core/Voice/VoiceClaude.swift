import Foundation

// Claude Code conversations running in a tab, read from Claude's own files on the
// machine. Claude Code draws full-screen, so the terminal (and a multiplexer like
// Herdr or tmux) only ever holds its current screen. Its history is in ~/.claude:
//
//   ~/.claude/sessions/<pid>.json                 each running Claude: sessionId, cwd, status
//   ~/.claude/projects/<dir>/<sessionId>.jsonl    the conversation, one JSON record per line
//
// A tab's Claudes are the ones running under its rtach session, found from the process
// tree, so this works whether Claude runs in the tab directly or inside a multiplexer.
// Input reaches a Claude in Herdr through Herdr (any pane, shown or not), and one in
// the tab itself through the tab. Everything here is Foundation only; VoiceAgent runs
// the scripts over SSH.

/// A Claude Code process running in a tab
struct ClaudeAgent: Equatable {
    /// How input reaches it
    enum Route: Equatable {
        /// Claude runs in the tab itself: write to the tab, like the keyboard
        case tab
        /// Through Herdr, to this pane, whichever pane Herdr is showing
        case herdr(pane: String)
        /// Inside a multiplexer there's no way to type into yet
        case unsupported(multiplexer: String)
    }

    let pid: Int
    let sessionId: String
    /// Claude's working directory
    let directory: String
    /// "busy" or "idle" as Claude reports it
    let status: String
    /// Claude's conversation title (its `ai-title`), if it has made one yet
    var title: String?
    /// This tab shows its pane (Herdr only, for now; see ClaudeScan.markShowing)
    var focused = false
    /// Herdr's view of it: "working", "idle", "blocked" (at a menu or question), ...
    var herdrStatus: String?
    var route: Route = .tab

    /// The status in words for the model
    var statusText: String {
        if herdrStatus == "blocked" {
            return "waiting for the user at a menu or question"
        }
        switch status {
        case "busy": return "working"
        case "idle": return "idle: finished its turn, waiting for the user"
        default: return status
        }
    }

    /// "work/api" for /home/me/work/api
    var shortDirectory: String {
        let parts = directory.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

/// What runs in a tab: its Claudes, and the multiplexers it's attached to
struct ClaudeScan: Equatable {
    var agents: [ClaudeAgent] = []
    var multiplexers: [String] = []
    /// What each Claude's Herdr pane shows, as plain text, by pane id
    var paneScreens: [String: String] = [:]

    /// Mark the conversation whose pane this tab is showing. Herdr's own focus is one
    /// per server, but each attached client (each Clauntty tab) can show a different
    /// pane, so match the tab's screen instead: the pane whose lines appear on it, using
    /// only lines no other pane has (Claude's status bar is the same everywhere).
    mutating func markShowing(screen: String) {
        for i in agents.indices { agents[i].focused = false }
        guard paneScreens.count > 0 else { return }
        let shown = Set(Self.normalizedLines(screen))
        let shownText = shown.joined(separator: "\n")
        var owners: [String: Set<String>] = [:]
        for (pane, text) in paneScreens {
            for line in Self.normalizedLines(text) where line.count >= 6 {
                owners[line, default: []].insert(pane)
            }
        }
        var scores: [String: Int] = [:]
        for (line, panes) in owners where panes.count == 1 && (shown.contains(line) || shownText.contains(line)) {
            scores[panes.first!, default: 0] += 1
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, ranked.count == 1 || ranked[1].value * 2 < best.value else { return }
        for i in agents.indices where agents[i].route == .herdr(pane: best.key) {
            agents[i].focused = true
        }
    }

    /// Trimmed lines with single spaces, no box drawing, no empty ones
    private static func normalizedLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let kept = raw.unicodeScalars.filter { !(0x2500...0x259F).contains($0.value) }
            let line = String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.isEmpty ? nil : line
        }
    }
}

enum ClaudeScripts {
    /// awk: print one field of the current JSON line as a small JSON object, e.g.
    /// {"description":"Run the tests"}. Strings stay JSON-escaped, so the app decodes
    /// them and a tab inside one can't split the output.
    private static let grab = #"""
    function grab(key,   re) {
      re = "\"" key "\":\"([^\"\\\\]|\\\\.)*\""
      if (match($0, re)) return "{" substr($0, RSTART, RLENGTH) "}"
      return ""
    }
    """#

    /// Finds herdr even when ~/.local/bin isn't on a non-interactive PATH
    private static let findHerdr = #"H=$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"#

    /// Lists what runs in the tab. Prints:
    ///   claude<TAB><a Claude's ~/.claude/sessions/<pid>.json on one line>
    ///   title<TAB><sessionId><TAB>{"aiTitle":"..."}
    ///   mux<TAB><multiplexer the tab is attached to>
    /// and when that's Herdr, its agents, and the process in each agent's pane and what
    /// the pane shows (base64 plain text):
    ///   herdr<TAB><`herdr agent list` output>
    ///   pane<TAB><pid><TAB><pane id>
    ///   visible<TAB><pane id><TAB><base64>
    ///
    /// The tab's processes are the ones under its rtach session. A multiplexer's client
    /// (Herdr, tmux, zellij, screen) only draws; its panes, and the Claudes in them, run
    /// under its server, which isn't under the tab. So when the tab runs one, every
    /// process under that multiplexer counts too.
    /// `screens: false` leaves out what each pane shows, for the frequent status
    /// checks that don't need it.
    static func find(rtachSessionId: String, screens: Bool = true) -> String? {
        guard isSafe(rtachSessionId) else { return nil }
        return #"""
        { ps -Ao pid=,ppid=,comm= | sed 's/^/P /'; ps -Ao pid=,args= | grep -F -e "\#(rtachSessionId)" | sed 's/^/R /'; } | awk '
        function grow(   p, grew) {
          do { grew = 0; for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; grew = 1 } } while (grew)
        }
        $1 == "P" { parent[$2] = $3; n = $4; sub(/.*\//, "", n); name[$2] = n; next }
        $1 == "R" { keep[$2] = 1 }
        END {
          grow()
          for (p in keep) if (name[p] ~ /^(herdr|tmux|zellij|screen)$/) mux[name[p]] = 1
          for (p in name) if (name[p] in mux) keep[p] = 1
          grow()
          for (m in mux) print "mux", m
          for (p in keep) print "pid", p
        }' | while read -r kind pid; do
          if [ "$kind" = mux ]; then
            printf 'mux\t%s\n' "$pid"
            [ "$pid" = herdr ] || continue
            \#(findHerdr)
            agents=$("$H" agent list 2>/dev/null | tr -d '\n')
            printf 'herdr\t%s\n' "$agents"
            for pane in $(printf '%s' "$agents" | tr ',' '\n' | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p'); do
              pg=$("$H" pane process-info --pane "$pane" 2>/dev/null | sed -n 's/.*"foreground_process_group_id":\([0-9]*\).*/\1/p')
              [ -n "$pg" ] && printf 'pane\t%s\t%s\n' "$pg" "$pane"
              \#(screens ? #"printf 'visible\t%s\t' "$pane"; "$H" agent read "$pane" --source visible --format text 2>/dev/null | base64 | tr -d '\n'; echo"# : ":")
            done
            continue
          fi
          f="$HOME/.claude/sessions/$pid.json"
          [ -f "$f" ] || continue
          printf 'claude\t'; tr -d '\n' < "$f"; echo
          sid=$(sed -n 's/.*"sessionId":"\([0-9a-fA-F-]*\)".*/\1/p' "$f")
          [ -n "$sid" ] || continue
          for t in "$HOME"/.claude/projects/*/"$sid".jsonl; do
            [ -f "$t" ] || continue
            grep -F '"type":"ai-title"' "$t" | tail -n 1 | awk -v sid="$sid" '
        \#(grab)
            { t = grab("aiTitle"); if (t != "") print "title\t" sid "\t" t }'
          done
        done
        """#
    }

    /// Prints the conversation's prompts, replies, tool calls and titles, one per line:
    ///   user<TAB>{"content":"..."}       (or {"text":"..."})
    ///   text<TAB>{"text":"..."}
    ///   tool<TAB>{"name":"Bash"}<TAB>{"description":"..."}
    ///   title<TAB>{"aiTitle":"..."}
    /// Leaves out thinking, tool results and outputs, attachments, skill text, compaction
    /// summaries and subagents. Bash calls carry Claude's description, never the command,
    /// which can hold secrets (a database URL with its password, say).
    static func extract(sessionId: String) -> String? {
        guard isSafe(sessionId) else { return nil }
        return #"""
        for t in "$HOME"/.claude/projects/*/"\#(sessionId)".jsonl; do
          [ -f "$t" ] || continue
          awk '
        \#(grab)
          /"isMeta":true/ || /"isCompactSummary":true/ || /"isSidechain":true/ { next }
          /"type":"ai-title"/ { t = grab("aiTitle"); if (t != "" && t != last) print "title\t" t; last = t; next }
          /"role":"user"/ {
            if (/"type":"tool_result"/) next
            c = grab("content"); if (c == "") c = grab("text")
            if (c != "") print "user\t" c
            next
          }
          /"role":"assistant"/ {
            if (/"type":"text"/) { c = grab("text"); if (c != "") print "text\t" c; next }
            if (/"type":"tool_use"/) {
              d = grab("description"); if (d == "") d = grab("file_path"); if (d == "") d = grab("pattern"); if (d == "") d = grab("query")
              print "tool\t" grab("name") "\t" d
            }
          }' "$t"
          break
        done
        """#
    }

    // MARK: Herdr actions

    /// Submit a prompt and wait (up to 6s) until Claude starts on it or stops at a menu,
    /// not for the whole turn. Herdr pastes it with bracketed paste and refuses with
    /// agent_blocked when a menu is already up.
    /// A slash command (`/rename …`) doesn't start a turn, so there's nothing to wait for.
    static func herdrPrompt(pane: String, text: String) -> String? {
        guard isSafe(pane, extra: ":") else { return nil }
        let encoded = Data(text.utf8).base64EncodedString()
        let wait = isSlashCommand(text) ? "" : " --wait --until working --until blocked --timeout 6000"
        return """
        \(findHerdr)
        T=$(printf '%s' '\(encoded)' | base64 -d)
        "$H" agent prompt '\(pane)' "$T"\(wait) 2>&1
        """
    }

    static func isSlashCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    /// Press keys in a pane. `keys` are VoiceKeys names, which Herdr accepts as is.
    static func herdrKeys(pane: String, keys: [String]) -> String? {
        guard isSafe(pane, extra: ":"), !keys.isEmpty, keys.allSatisfy({ VoiceKeys.bytes[$0] != nil }) else { return nil }
        return findHerdr + "\n\"$H\" agent send-keys '\(pane)' " + keys.map { "'\($0)'" }.joined(separator: " ") + " 2>&1"
    }

    /// What a pane shows, styled (ANSI), so the dim suggestion can be marked
    static func herdrScreen(pane: String) -> String? {
        guard isSafe(pane, extra: ":") else { return nil }
        return findHerdr + "\n\"$H\" agent read '\(pane)' --source visible --format ansi 2>/dev/null"
    }

    static func herdrFocus(pane: String) -> String? {
        guard isSafe(pane, extra: ":") else { return nil }
        return findHerdr + "\n\"$H\" agent focus '\(pane)' 2>&1"
    }

    /// Herdr's error code in a command's output ("agent_blocked"), if it failed
    static func herdrError(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["code"] as? String ?? error["message"] as? String ?? "error"
    }

    /// Ids go into shell scripts, so allow only plain characters
    private static func isSafe(_ id: String, extra: String = "") -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0) || extra.contains($0)) }
    }

    /// The output of `find`
    static func parse(_ output: String) -> ClaudeScan {
        var scan = ClaudeScan()
        var titles: [String: String] = [:]
        var panes: [Int: String] = [:]
        var herdrStatus: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            switch parts.first {
            case "claude"?:
                guard parts.count >= 2,
                      let json = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
                      let pid = json["pid"] as? Int, let sessionId = json["sessionId"] as? String else { continue }
                scan.agents.append(ClaudeAgent(
                    pid: pid,
                    sessionId: sessionId,
                    directory: json["cwd"] as? String ?? "",
                    status: json["status"] as? String ?? "unknown"
                ))
            case "title"?:
                guard parts.count == 3, let title = ClaudeTranscript.field(parts[2])?.value else { continue }
                titles[String(parts[1])] = title
            case "mux"?:
                if parts.count >= 2 { scan.multiplexers.append(String(parts[1])) }
            case "herdr"?:
                guard parts.count >= 2,
                      let json = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
                      let agents = (json["result"] as? [String: Any])?["agents"] as? [[String: Any]] else { continue }
                for agent in agents {
                    if let pane = agent["pane_id"] as? String, let status = agent["agent_status"] as? String {
                        herdrStatus[pane] = status
                    }
                }
            case "pane"?:
                if parts.count == 3, let pid = Int(parts[1]) { panes[pid] = String(parts[2]) }
            case "visible"?:
                if parts.count == 3, let data = Data(base64Encoded: String(parts[2])) {
                    scan.paneScreens[String(parts[1])] = String(decoding: data, as: UTF8.self)
                }
            default:
                continue
            }
        }
        scan.multiplexers.sort()
        for i in scan.agents.indices {
            let pid = scan.agents[i].pid
            scan.agents[i].title = titles[scan.agents[i].sessionId]
            if let pane = panes[pid] {
                scan.agents[i].route = .herdr(pane: pane)
                scan.agents[i].herdrStatus = herdrStatus[pane]
            } else if let multiplexer = scan.multiplexers.first {
                scan.agents[i].route = .unsupported(multiplexer: multiplexer)
            }
        }
        // Oldest first, so numbers stay put while Claudes come and go
        scan.agents.sort { $0.pid < $1.pid }
        return scan
    }
}

// MARK: - Watching

/// Notices when a Claude conversation finishes its turn or stops at a menu, from
/// status checks a few seconds apart. A new state counts once two checks in a row
/// agree, so a flicker mid-turn says nothing. The first check of a conversation only
/// records where it stands.
struct ClaudeWatch {
    enum State: Equatable {
        case working, idle, blocked
    }

    enum Change: Equatable {
        /// working → idle
        case finished
        /// anything → waiting at a menu or question
        case blocked
    }

    struct Event: Equatable {
        let key: String
        let change: Change
    }

    private var confirmed: [String: State] = [:]
    private var candidate: [String: State] = [:]

    /// Herdr's view when there is one (it knows about menus), else Claude's own
    static func state(of agent: ClaudeAgent) -> State {
        switch agent.herdrStatus {
        case "blocked"?: return .blocked
        case "working"?: return .working
        case "idle"?, "done"?: return .idle
        default: return agent.status == "busy" ? .working : .idle
        }
    }

    /// Feed one round of checks: every conversation seen, by a stable key
    mutating func update(_ states: [String: State]) -> [Event] {
        var events: [Event] = []
        for (key, state) in states {
            guard let current = confirmed[key] else {
                confirmed[key] = state
                continue
            }
            if state == current {
                candidate[key] = nil
            } else if candidate[key] == state {
                candidate[key] = nil
                confirmed[key] = state
                switch (current, state) {
                case (.working, .idle): events.append(Event(key: key, change: .finished))
                case (_, .blocked): events.append(Event(key: key, change: .blocked))
                default: break
                }
            } else {
                candidate[key] = state
            }
        }
        // Conversations that ended
        for key in confirmed.keys where states[key] == nil {
            confirmed[key] = nil
            candidate[key] = nil
        }
        return events.sorted { $0.key < $1.key }
    }
}

// MARK: - Keys

/// Keys the voice agent can press. The names are Herdr's, so they pass straight to
/// `herdr agent send-keys`; the bytes are what a terminal sends for them.
enum VoiceKeys {
    static let bytes: [String: String] = {
        var keys: [String: String] = [
            "enter": "\r", "esc": "\u{1B}", "tab": "\t", "shift+tab": "\u{1B}[Z",
            "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
            "space": " ", "backspace": "\u{7F}", "ctrl+c": "\u{03}", "y": "y", "n": "n",
        ]
        for digit in 0...9 { keys["\(digit)"] = "\(digit)" }
        return keys
    }()

    private static let aliases: [String: String] = [
        "escape": "esc", "return": "enter", "ctrl-c": "ctrl+c", "control+c": "ctrl+c", "^c": "ctrl+c",
        "shift-tab": "shift+tab", "backtab": "shift+tab", "arrow-up": "up", "arrow-down": "down",
    ]

    /// "1", "1 enter", "Escape, ctrl-c" → key names. Fails with the first unknown key.
    static func parse(_ input: String) -> Result<[String], UnknownKey> {
        var keys: [String] = []
        for word in input.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }) {
            let name = aliases[String(word)] ?? String(word)
            guard bytes[name] != nil else { return .failure(UnknownKey(name: String(word))) }
            keys.append(name)
        }
        return .success(keys)
    }

    struct UnknownKey: Error, Equatable {
        let name: String
    }

    /// A prompt as a bracketed paste, so a leading `?`, `!` or `#` is text rather than
    /// a Claude Code shortcut. Escapes are dropped so the text can't end the paste early.
    static func paste(_ text: String) -> String {
        "\u{1B}[200~" + text.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~"
    }
}

// MARK: - Conversation

struct ClaudeTranscript: Equatable {
    struct Turn: Equatable {
        /// What the user typed
        var prompt: String
        var steps: [Step] = []
        /// The user stopped Claude during this turn
        var interrupted = false

        var toolCount: Int { steps.filter { if case .tool = $0 { return true } else { return false } }.count }
        var lastReply: String? {
            for step in steps.reversed() { if case .reply(let text) = step { return text } }
            return nil
        }
    }

    enum Step: Equatable {
        case reply(String)
        /// "Bash: Run the tests", "Edit: label-reconcile.ts"
        case tool(String)
    }

    var title: String?
    var turns: [Turn] = []

    /// The output of `ClaudeScripts.extract`
    static func parse(_ extracted: String) -> ClaudeTranscript {
        var transcript = ClaudeTranscript()
        for line in extracted.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "title":
                transcript.title = field(parts[1])?.value ?? transcript.title
            case "user":
                guard let text = field(parts[1])?.value.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if text.hasPrefix("[Request interrupted") {
                    if !transcript.turns.isEmpty { transcript.turns[transcript.turns.count - 1].interrupted = true }
                    continue
                }
                // Slash commands, ! commands and their output, subagent notifications
                if text.hasPrefix("<") { continue }
                transcript.turns.append(Turn(prompt: text))
            case "text":
                guard !transcript.turns.isEmpty,
                      let text = field(parts[1])?.value.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                transcript.turns[transcript.turns.count - 1].steps.append(.reply(text))
            case "tool":
                guard !transcript.turns.isEmpty else { continue }
                let name = field(parts[1])?.value ?? "tool"
                var label = name
                if parts.count >= 3, let detail = field(parts[2]) {
                    var text = detail.key == "file_path" ? (detail.value as NSString).lastPathComponent : detail.value
                    text = text.split(separator: "\n").first.map(String.init) ?? ""
                    if text.count > 100 { text = String(text.prefix(100)) + "…" }
                    if !text.isEmpty { label += ": \(text)" }
                }
                transcript.turns[transcript.turns.count - 1].steps.append(.tool(label))
            default:
                continue
            }
        }
        return transcript
    }

    /// {"key":"value"} → (key, value)
    static func field(_ json: Substring) -> (key: String, value: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let first = object.first, let text = first.value as? String else { return nil }
        return (first.key, text)
    }

    // MARK: Views for the model

    /// One or two lines per turn: what the user asked and how Claude's reply starts
    func outline(_ range: Range<Int>) -> String {
        range.clamped(to: turns.indices).map { index in
            let turn = turns[index]
            var line = "Turn \(index + 1). User: \(Self.oneLine(turn.prompt, 160))"
            let tools = turn.toolCount
            let did = tools > 0 ? "Claude (\(tools) tool call\(tools == 1 ? "" : "s"))" : "Claude"
            if let reply = turn.lastReply {
                line += "\n  \(did): \(Self.oneLine(reply, 220))"
            } else {
                line += "\n  \(did): no reply yet"
            }
            if turn.interrupted { line += "\n  (the user interrupted this turn)" }
            return line
        }.joined(separator: "\n")
    }

    /// A whole turn in order: the prompt, Claude's replies, and its tool calls one per
    /// line. Over `limit`, earlier replies are shortened and the last reply keeps its
    /// start and end (where Claude usually asks the user something).
    func render(turn index: Int, limit: Int = 6000) -> String? {
        guard turns.indices.contains(index) else { return nil }
        let turn = turns[index]
        let header = "Turn \(index + 1) of \(turns.count)" + (turn.interrupted ? " (the user interrupted it)" : "")

        func build(promptLimit: Int, replyLimit: Int, maxTools: Int, lastReplyLimit: Int) -> String {
            var lines = [header, "User: \(Self.shorten(turn.prompt, promptLimit))"]
            let lastReplyIndex = turn.steps.lastIndex { if case .reply = $0 { return true } else { return false } }
            let toolIndices = turn.steps.indices.filter { if case .tool = turn.steps[$0] { return true } else { return false } }
            let shownTools = Set(toolIndices.suffix(maxTools))
            var skipped = 0
            for (i, step) in turn.steps.enumerated() {
                switch step {
                case .tool(let label):
                    if shownTools.contains(i) {
                        if skipped > 0 { lines.append("  (\(skipped) earlier tool calls)"); skipped = 0 }
                        lines.append("  - \(label)")
                    } else {
                        skipped += 1
                    }
                case .reply(let text):
                    if skipped > 0 { lines.append("  (\(skipped) earlier tool calls)"); skipped = 0 }
                    lines.append("Claude: \(Self.shorten(text, i == lastReplyIndex ? lastReplyLimit : replyLimit))")
                }
            }
            if skipped > 0 { lines.append("  (\(skipped) earlier tool calls)") }
            if lastReplyIndex == nil { lines.append("Claude: no reply yet") }
            return lines.joined(separator: "\n")
        }

        let full = build(promptLimit: .max, replyLimit: .max, maxTools: .max, lastReplyLimit: .max)
        if full.count <= limit { return full }
        let shorter = build(promptLimit: 1000, replyLimit: 300, maxTools: 12, lastReplyLimit: .max)
        if shorter.count <= limit { return shorter }
        let withoutLast = build(promptLimit: 1000, replyLimit: 300, maxTools: 12, lastReplyLimit: 0)
        return build(promptLimit: 1000, replyLimit: 300, maxTools: 12, lastReplyLimit: max(500, limit - withoutLast.count))
    }

    struct Hit: Equatable {
        let turn: Int
        let who: String
        let snippet: String
    }

    /// Prompts, reply paragraphs and tool calls that contain every word of the query
    /// (or, if none do, the most words), newest first
    func search(_ query: String, limit: Int = 8) -> (hits: [Hit], total: Int) {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return ([], 0) }

        var scored: [(score: Int, hit: Hit)] = []
        for (index, turn) in turns.enumerated().reversed() {
            var units: [(String, String)] = []
            for step in turn.steps.reversed() {
                switch step {
                case .reply(let text):
                    units += text.components(separatedBy: "\n\n").reversed().map { ("Claude", $0) }
                case .tool(let label):
                    units.append(("Claude's tool call", label))
                }
            }
            units.append(("User", turn.prompt))
            for (who, text) in units {
                let lower = text.lowercased()
                let found = words.filter { lower.contains($0) }
                guard !found.isEmpty else { continue }
                scored.append((found.count, Hit(turn: index + 1, who: who, snippet: Self.snippet(text, around: found[0]))))
            }
        }
        guard let best = scored.map(\.score).max() else { return ([], 0) }
        let matches = scored.filter { $0.score == best }.map(\.hit)
        return (Array(matches.prefix(limit)), matches.count)
    }

    // MARK: Text helpers

    static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// Keep the start and the end of long text
    static func shorten(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 0 else { return "(\(text.count) characters left out)" }
        let head = text.prefix(limit * 3 / 5)
        let tail = text.suffix(limit * 2 / 5)
        return "\(head)\n[… \(text.count - head.count - tail.count) characters left out …]\n\(tail)"
    }

    private static func snippet(_ text: String, around word: String, width: Int = 280) -> String {
        let flat = oneLine(text, .max)
        guard flat.count > width, let range = flat.range(of: word, options: .caseInsensitive) else { return oneLine(flat, width) }
        let start = flat.index(range.lowerBound, offsetBy: -100, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
