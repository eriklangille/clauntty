import Foundation

// A Claude pane in chat mode (plan: plans/2026-10-25-clauntty-agent-chat.md). The pane's
// rtach session runs `clauntty-chat`, which runs Claude headless:
//
//   claude -p --input-format stream-json --output-format stream-json --verbose
//          --include-partial-messages --replay-user-messages --permission-prompt-tool stdio
//
// with the terminal raw, so the pane's output is Claude's JSON lines and its input is ours.
// The terminal still gets the bytes (hidden under the chat); this reads them too.
// Earlier turns come from Claude's transcript on the host (~/.claude/projects/*/<id>.jsonl),
// since the stream only carries what happens from now on.

@MainActor
final class ChatSession: ObservableObject {
    struct Tool: Equatable {
        let id: String
        var name: String
        /// One line: Claude's description of a command, a file's name, a search
        var summary: String
        /// The input in full, for the expanded row (a command, an edit)
        var detail: String
        var result: String?
        var isError = false
        var done = false
    }

    enum Item: Identifiable, Equatable {
        case user(id: String, text: String)
        case reply(id: String, text: String, streaming: Bool)
        case tool(Tool)
        /// "Stopped", "Resumed from the terminal": a quiet line in the conversation
        case note(id: String, text: String)

        var id: String {
            switch self {
            case .user(let id, _), .reply(let id, _, _), .note(let id, _): return id
            case .tool(let tool): return tool.id
            }
        }
    }

    /// Claude asks before running a tool
    struct Approval: Equatable {
        let requestId: String
        let toolUseId: String?
        let toolName: String
        let summary: String
        let detail: String
        /// Ready-made "always allow" rules, sent back as they came
        let suggestions: [JSONValue]
        let input: JSONValue
    }

    /// AskUserQuestion: Claude's questions and their options
    struct Question: Equatable {
        struct Option: Equatable, Hashable {
            let label: String
            let description: String
        }
        struct Entry: Equatable {
            let question: String
            let header: String
            let options: [Option]
            let multiSelect: Bool
        }
        let requestId: String
        let toolUseId: String?
        let entries: [Entry]
        let input: JSONValue
    }

    enum Pending: Equatable {
        case approval(Approval)
        case question(Question)
    }

    weak var session: Session?

    @Published private(set) var history: [Item] = []
    @Published private(set) var live: [Item] = []
    @Published private(set) var pending: Pending?
    /// A turn is under way
    @Published private(set) var working = false
    /// Claude is thinking (before any text of this message)
    @Published private(set) var thinking = false
    @Published private(set) var sessionId: String?
    @Published private(set) var model: String?
    @Published private(set) var loadingHistory = false
    /// `clauntty-chat` ended: the pane is back at its shell
    @Published private(set) var ended = false {
        didSet { if ended != oldValue { session?.chatModeDidChange() } }
    }
    /// Asks the view to put the cursor in its text box (the window was tapped)
    @Published var focusRequest = 0

    var items: [Item] { history + live }

    private var lineBuffer = Data()
    private var messageId: String?
    /// The live item each content block of the current message is drawn in
    private var blockItems: [Int: String] = [:]
    private var loadedHistoryFor: String?

    init(session: Session?, sessionId: String? = nil) {
        self.session = session
        self.sessionId = sessionId
    }

    // MARK: - Output

    /// The pane's output: whole lines are events, anything else (the shell's prompt, the
    /// typed command, a partial line from a replay that started mid-line) is skipped
    /// The pane's output, line by line. When the launcher's end comes, the rest isn't the
    /// chat's: it's returned (the terminal's again, maybe with the next chat's start in it).
    @discardableResult
    func ingest(_ data: Data) -> Data? {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handleLine(Data(line))
            if ended {
                let rest = Data(lineBuffer)
                lineBuffer.removeAll()
                return rest
            }
        }
        // A line this long without an end isn't ours
        if lineBuffer.count > 8_000_000 { lineBuffer.removeAll() }
        return nil
    }

    /// rtach is about to replay the pane's recent output: it builds the live part again
    func beginReplay() {
        lineBuffer.removeAll()
        live.removeAll()
        pending = nil
        blockItems.removeAll()
        messageId = nil
        working = false
        thinking = false
    }

    private func handleLine(_ line: Data) {
        guard let start = line.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: line[start...]) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "clauntty_chat":
            ended = false
            // `clauntty-chat --resume ID`: the conversation is known before Claude says anything
            let args = (object["args"] as? String ?? "").split(separator: " ").map(String.init)
            if let at = args.firstIndex(where: { $0 == "--resume" || $0 == "--session-id" }), at + 1 < args.count,
               args[at + 1] != sessionId {
                sessionId = args[at + 1]
                session?.chatSessionIdChanged(args[at + 1])
            }
            if loadedHistoryFor != sessionId { Task { await loadHistory() } }
        case "clauntty_chat_ended":
            ended = true
            working = false
            thinking = false
            pending = nil
            session?.chatDidEnd()
        case "system":
            system(object)
        case "stream_event":
            if let event = object["event"] as? [String: Any] { streamEvent(event) }
        case "assistant":
            if let message = object["message"] as? [String: Any] { assistant(message) }
        case "user":
            user(object)
        case "control_request":
            controlRequest(object)
        case "result":
            finishTurn(stopped: (object["subtype"] as? String) == "error_during_execution")
        default:
            break
        }
    }

    private func system(_ object: [String: Any]) {
        switch object["subtype"] as? String {
        case "init":
            if let id = object["session_id"] as? String, id != sessionId {
                sessionId = id
                session?.chatSessionIdChanged(id)
            }
            model = object["model"] as? String ?? model
            working = true
            if loadedHistoryFor != sessionId { Task { await loadHistory() } }
        case "status":
            working = true
        case "thinking_tokens":
            thinking = true
        default:
            break
        }
    }

    private func streamEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            messageId = (event["message"] as? [String: Any])?["id"] as? String
            blockItems.removeAll()
            working = true
        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any] else { return }
            switch block["type"] as? String {
            case "text":
                let id = "\(messageId ?? "m"):\(index)"
                blockItems[index] = id
                upsert(.reply(id: id, text: block["text"] as? String ?? "", streaming: true))
                thinking = false
            case "thinking":
                thinking = true
            case "tool_use":
                guard let id = block["id"] as? String else { return }
                blockItems[index] = id
                thinking = false
                if !hasItem(id) {
                    upsert(.tool(Tool(id: id, name: block["name"] as? String ?? "Tool", summary: "", detail: "")))
                }
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int, let id = blockItems[index],
                  let delta = event["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta", let text = delta["text"] as? String,
                  let at = live.firstIndex(where: { $0.id == id }),
                  case .reply(_, let sofar, _) = live[at] else { return }
            live[at] = .reply(id: id, text: sofar + text, streaming: true)
        default:
            break
        }
    }

    /// A finished content block (a whole message's worth, in practice one block each)
    private func assistant(_ message: [String: Any]) {
        let mid = message["id"] as? String ?? "m"
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                // The block it streamed into, else a new one (the replay began after it started)
                let id = live.last(where: {
                    if case .reply(let id, _, true) = $0 { return id.hasPrefix(mid + ":") } else { return false }
                })?.id ?? "\(mid):t\(live.count)"
                upsert(.reply(id: id, text: text, streaming: false))
            case "tool_use":
                guard let id = block["id"] as? String else { continue }
                var tool = existingTool(id) ?? Tool(id: id, name: "", summary: "", detail: "")
                tool.name = block["name"] as? String ?? tool.name
                let input = block["input"] as? [String: Any] ?? [:]
                tool.summary = Self.summary(tool: tool.name, input: input)
                tool.detail = Self.detail(tool: tool.name, input: input)
                upsert(.tool(tool))
            default:
                continue
            }
        }
    }

    private func user(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            addPrompt(text, uuid: object["uuid"] as? String)
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, var tool = existingTool(id) else { continue }
                tool.result = Self.resultText(block["content"])
                tool.isError = block["is_error"] as? Bool ?? false
                tool.done = true
                upsert(.tool(tool))
            case "text":
                if let text = block["text"] as? String { addPrompt(text, uuid: object["uuid"] as? String) }
            default:
                continue
            }
        }
    }

    private func addPrompt(_ text: String, uuid: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return }
        if trimmed.hasPrefix("[Request interrupted") { return }
        // Sent from here: it's in already, waiting for its echo
        if let at = live.lastIndex(where: { if case .user(let id, let t) = $0 { return id.hasPrefix("local-") && t == trimmed } else { return false } }) {
            live[at] = .user(id: uuid ?? live[at].id, text: trimmed)
            return
        }
        let id = uuid ?? "u-\(live.count)-\(trimmed.hashValue)"
        guard !hasItem(id) else { return }
        live.append(.user(id: id, text: trimmed))
    }

    private func controlRequest(_ object: [String: Any]) {
        guard let requestId = object["request_id"] as? String,
              let request = object["request"] as? [String: Any],
              (request["subtype"] as? String) == "can_use_tool" else { return }
        let toolName = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let toolUseId = request["tool_use_id"] as? String
        if toolName == "AskUserQuestion" {
            let entries = (input["questions"] as? [[String: Any]] ?? []).map { q in
                Question.Entry(
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        Question.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                    },
                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            pending = .question(Question(requestId: requestId, toolUseId: toolUseId, entries: entries, input: JSONValue(input)))
        } else {
            pending = .approval(Approval(
                requestId: requestId, toolUseId: toolUseId, toolName: toolName,
                summary: Self.summary(tool: toolName, input: input),
                detail: Self.detail(tool: toolName, input: input),
                suggestions: (request["permission_suggestions"] as? [Any] ?? []).map(JSONValue.init),
                input: JSONValue(input)))
        }
    }

    private func finishTurn(stopped: Bool) {
        working = false
        thinking = false
        pending = nil
        for (i, item) in live.enumerated() {
            if case .reply(let id, let text, true) = item { live[i] = .reply(id: id, text: text, streaming: false) }
        }
        if stopped { live.append(.note(id: "stop-\(live.count)", text: "Stopped")) }
    }

    // MARK: - Input

    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        live.append(.user(id: "local-\(UUID().uuidString)", text: text))
        working = true
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    func allow(always suggestion: JSONValue? = nil) {
        guard case .approval(let approval) = pending else { return }
        var response: [String: Any] = ["behavior": "allow", "updatedInput": approval.input.any]
        if let suggestion { response["updatedPermissions"] = [suggestion.any] }
        respond(approval.requestId, response)
    }

    func deny() {
        let requestId: String
        switch pending {
        case .approval(let a): requestId = a.requestId
        case .question(let q): requestId = q.requestId
        case nil: return
        }
        respond(requestId, ["behavior": "deny", "message": "The user said no from Clauntty."])
    }

    /// Answers by question text, as AskUserQuestion takes them (several labels joined)
    func answer(_ answers: [String: String]) {
        guard case .question(let question) = pending else { return }
        var input = question.input.any as? [String: Any] ?? [:]
        input["answers"] = answers
        respond(question.requestId, ["behavior": "allow", "updatedInput": input])
        let said = question.entries.compactMap { answers[$0.question] }.joined(separator: ", ")
        if !said.isEmpty { live.append(.user(id: "answer-\(question.requestId)", text: said)) }
    }

    func interrupt() {
        write(["type": "control_request", "request_id": "stop-\(UUID().uuidString.prefix(8))", "request": ["subtype": "interrupt"]])
    }

    /// Ends the headless Claude; the pane's shell comes back
    func end() {
        session?.sendData(Data("{\"type\":\"clauntty_end\"}\n".utf8))
    }

    private func respond(_ requestId: String, _ response: [String: Any]) {
        pending = nil
        write(["type": "control_response", "response": ["subtype": "success", "request_id": requestId, "response": response]])
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        session?.sendData(data)
    }

    // MARK: - History

    /// Earlier turns, from Claude's transcript on the host. Only its last few MB: a long
    /// conversation's file passes hundreds of MB (tool results, screenshots).
    func loadHistory() async {
        guard let sessionId, loadedHistoryFor != sessionId, Self.isSafe(sessionId), let session else { return }
        loadedHistoryFor = sessionId
        loadingHistory = true
        defer { loadingHistory = false }
        let script = """
            for t in "$HOME"/.claude/projects/*/"\(sessionId)".jsonl; do
              [ -f "$t" ] || continue
              tail -c 6000000 "$t" | grep -E '"type":"(user|assistant)"' | grep -v '"isSidechain":true'
              break
            done
            """
        guard let output = try? await session.runRemoteScript(script) else { return }
        let parsed = Self.parseTranscript(output)
        let liveIds = Set(live.map(\.id))
        history = parsed.filter { !liveIds.contains($0.id) }
    }

    /// Claude's transcript lines as chat items: prompts, replies and tools with their results
    nonisolated static func parseTranscript(_ text: String) -> [Item] {
        var items: [Item] = []
        var index: [String: Int] = [:]
        var ordinal: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any] else { continue }
            if type == "user" {
                if let text = message["content"] as? String {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !t.hasPrefix("<") else { continue }
                    if t.hasPrefix("[Request interrupted") {
                        items.append(.note(id: "n-\(items.count)", text: "Stopped"))
                        continue
                    }
                    let id = object["uuid"] as? String ?? "u-\(items.count)"
                    index[id] = items.count
                    items.append(.user(id: id, text: t))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where (block["type"] as? String) == "tool_result" {
                        guard let id = block["tool_use_id"] as? String, let at = index[id],
                              case .tool(var tool) = items[at] else { continue }
                        tool.result = resultText(block["content"])
                        tool.isError = block["is_error"] as? Bool ?? false
                        tool.done = true
                        items[at] = .tool(tool)
                    }
                }
                continue
            }
            let mid = message["id"] as? String ?? "m\(items.count)"
            for block in message["content"] as? [[String: Any]] ?? [] {
                let n = ordinal[mid, default: 0]
                ordinal[mid] = n + 1
                switch block["type"] as? String {
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    items.append(.reply(id: "\(mid):\(n)", text: t, streaming: false))
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    index[id] = items.count
                    items.append(.tool(Tool(id: id, name: name, summary: summary(tool: name, input: input),
                                            detail: detail(tool: name, input: input), done: true)))
                default:
                    continue
                }
            }
        }
        return items
    }

    // MARK: - Helpers

    private func hasItem(_ id: String) -> Bool { live.contains { $0.id == id } }

    private func existingTool(_ id: String) -> Tool? {
        for item in live.reversed() { if case .tool(let t) = item, t.id == id { return t } }
        return nil
    }

    private func upsert(_ item: Item) {
        if let at = live.firstIndex(where: { $0.id == item.id }) {
            live[at] = item
        } else {
            live.append(item)
        }
    }

    /// One line for a tool call
    nonisolated static func summary(tool: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let text: String? = {
            switch tool {
            case "Bash": return s("description") ?? s("command")
            case "Read", "Edit", "Write", "NotebookEdit": return s("file_path").map { ($0 as NSString).lastPathComponent }
            case "Grep", "Glob": return s("pattern")
            case "WebFetch": return s("url")
            case "WebSearch": return s("query")
            case "Task", "Agent": return s("description")
            case "AskUserQuestion": return ((input["questions"] as? [[String: Any]])?.first?["question"] as? String)
            default: return s("description") ?? s("file_path") ?? s("pattern") ?? s("query")
            }
        }()
        let line = (text ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    /// The input in full for the expanded row
    nonisolated static func detail(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Edit":
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            let minus = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }
            let plus = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }
            return ((input["file_path"] as? String).map { [$0] } ?? []).joined() + "\n" + (minus + plus).joined(separator: "\n")
        case "Write":
            return (input["file_path"] as? String ?? "") + "\n" + String((input["content"] as? String ?? "").prefix(4000))
        case "Read":
            return input["file_path"] as? String ?? ""
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    nonisolated static func resultText(_ content: Any?) -> String {
        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        return text.count > 6000 ? String(text.prefix(6000)) + "\n…" : text
    }

    nonisolated private static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// A JSON value kept as it came, so it can be sent back unchanged (Equatable, unlike Any)
struct JSONValue: Equatable {
    let any: Any
    private let encoded: String

    init(_ any: Any) {
        self.any = any
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) {
            encoded = String(decoding: data, as: UTF8.self)
        } else {
            encoded = "\(any)"
        }
    }

    static func == (a: JSONValue, b: JSONValue) -> Bool { a.encoded == b.encoded }

    /// The rule an "always allow" suggestion adds, in words: `Bash(file *)`
    var ruleLabel: String? {
        guard let object = any as? [String: Any] else { return nil }
        if let rules = object["rules"] as? [[String: Any]], let rule = rules.first {
            let tool = rule["toolName"] as? String ?? ""
            if let content = rule["ruleContent"] as? String, !content.isEmpty { return "\(tool)(\(content))" }
            return tool
        }
        if let mode = object["mode"] as? String {
            return mode == "acceptEdits" ? "edits this session" : mode
        }
        if let dirs = object["directories"] as? [String], let dir = dirs.first { return (dir as NSString).lastPathComponent + "/" }
        return nil
    }
}
