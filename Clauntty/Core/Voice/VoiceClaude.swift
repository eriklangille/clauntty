import Foundation

// Claude Code conversations running in a pane, read from Claude's own files on the
// machine. Claude Code draws full-screen, so the terminal only ever holds its current
// screen. Its history is in ~/.claude:
//
//   ~/.claude/sessions/<pid>.json                 each running Claude: sessionId, cwd, status
//   ~/.claude/projects/<dir>/<sessionId>.jsonl    the conversation, one JSON record per line
//
// A pane's Claude is the one running under its rtach session, found from the process
// tree. Input reaches it through the pane's own session, like the keyboard, whether the
// pane is shown or not. Everything here is Foundation only; VoiceAgent runs the scripts
// over SSH.

/// A Claude Code process running in a pane
struct ClaudeAgent: Equatable {
    let pid: Int
    let sessionId: String
    /// Claude's working directory
    let directory: String
    /// "busy" or "idle" as Claude reports it
    let status: String
    /// When `status` last changed (Claude's statusUpdatedAt, ms since 1970)
    var statusChangedAt: Int?
    /// Claude's conversation title (its `ai-title`), if it has made one yet
    var title: String?

    /// The status in words for the model (rtach's pane state says more: a menu)
    var statusText: String {
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

/// The Claudes running in a pane: usually one
struct ClaudeScan: Equatable {
    var agents: [ClaudeAgent] = []
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

    /// Lists the Claudes running in the pane. Prints:
    ///   claude<TAB><a Claude's ~/.claude/sessions/<pid>.json on one line>
    ///   title<TAB><sessionId><TAB>{"aiTitle":"..."}
    ///
    /// The pane's processes are the ones under its rtach session.
    static func find(rtachSessionId: String) -> String? {
        guard isSafe(rtachSessionId) else { return nil }
        return #"""
        { ps -Ao pid=,ppid=,comm= | sed 's/^/P /'; ps -Ao pid=,args= | grep -F -e "\#(rtachSessionId)" | sed 's/^/R /'; } | awk '
        function grow(   p, grew) {
          do { grew = 0; for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; grew = 1 } } while (grew)
        }
        $1 == "P" { parent[$2] = $3; next }
        $1 == "R" { keep[$2] = 1 }
        END { grow(); for (p in keep) print p }' | while read -r pid; do
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
    /// and `partial` first when the conversation is long and only its end was read.
    /// Leaves out thinking, tool results and outputs, attachments, skill text, compaction
    /// summaries and subagents. Bash calls carry Claude's description, never the command,
    /// which can hold secrets (a database URL with its password, say).
    /// A long conversation's file runs to hundreds of MB (tool results, screenshots), more
    /// than can be read in time: only its last `recentBytes` are, from a whole line.
    static func extract(sessionId: String, recentBytes: Int = 30_000_000) -> String? {
        guard isSafe(sessionId) else { return nil }
        return #"""
        for t in "$HOME"/.claude/projects/*/"\#(sessionId)".jsonl; do
          [ -f "$t" ] || continue
          long=$([ "$(wc -c < "$t")" -gt \#(recentBytes) ] && echo 1)
          [ -n "$long" ] && echo partial
          if [ -n "$long" ]; then
            tail -c \#(recentBytes) "$t" | sed 1d
          else
            cat "$t"
          fi | grep -v '"type":"tool_result"' | awk '
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
          }'
          break
        done
        """#
    }

    /// Ids go into shell scripts, so allow only plain characters
    private static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The output of `find`
    static func parse(_ output: String) -> ClaudeScan {
        var scan = ClaudeScan()
        var titles: [String: String] = [:]
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
                    status: json["status"] as? String ?? "unknown",
                    statusChangedAt: (json["statusUpdatedAt"] as? NSNumber)?.intValue
                ))
            case "title"?:
                guard parts.count == 3, let title = ClaudeTranscript.field(parts[2])?.value else { continue }
                titles[String(parts[1])] = title
            default:
                continue
            }
        }
        for i in scan.agents.indices {
            scan.agents[i].title = titles[scan.agents[i].sessionId]
        }
        // Oldest first, so numbers stay put while Claudes come and go
        scan.agents.sort { $0.pid < $1.pid }
        return scan
    }
}

// MARK: - Keys

/// Keys the voice agent can press: their names, and what a terminal sends for them
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
    /// Only the conversation's recent part was read (a long one): turns count from there
    var partial = false

    /// The output of `ClaudeScripts.extract`
    static func parse(_ extracted: String) -> ClaudeTranscript {
        var transcript = ClaudeTranscript()
        for line in extracted.split(separator: "\n") {
            if line == "partial" {
                transcript.partial = true
                continue
            }
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
