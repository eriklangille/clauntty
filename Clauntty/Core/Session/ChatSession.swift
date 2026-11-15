import Foundation
import os
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
    struct Tool: Equatable, Codable {
        let id: String
        var name: String
        /// One line: Claude's description of a command, a file's name, a search
        var summary: String
        /// The input in full, for the expanded row (a command, an edit)
        var detail: String
        var result: String?
        var isError = false
        var done = false
        /// When it was first seen running here (not for history): its row counts the
        /// time up, as Claude Code does. A replay starts it again.
        var startedAt: Date?
    }

    enum Item: Identifiable, Equatable, Codable {
        /// `images`: how many it had (they're drawn from `sentImages` when sent from here)
        case user(id: String, text: String, images: Int = 0)
        case reply(id: String, text: String, streaming: Bool)
        case tool(Tool)
        /// "Stopped", "Resumed from the terminal": a quiet line in the conversation
        case note(id: String, text: String)

        var id: String {
            switch self {
            case .user(let id, _, _), .reply(let id, _, _), .note(let id, _): return id
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
    /// The program rtach names for a pane running the chat launcher
    static let launcher = "clauntty-chat"
    /// When its launcher's start was seen (a chat restored or found from the pane's
    /// program started earlier)
    private(set) var startedAt = Date.distantPast

    /// Earlier turns: kept on this device (`ChatCache`), then Claude's transcript on the host
    @Published private(set) var history: [Item] = [] { didSet { rebuildItems() } }
    /// This run's turns, from the pane's output (after a reattach, from rtach's replay:
    /// its last 16KB, often a fragment of one long line)
    @Published private(set) var live: [Item] = [] { didSet { rebuildItems() } }
    /// What's drawn: the history, then the live turns, each message once
    @Published private(set) var items: [Item] = []
    @Published private(set) var pending: Pending?
    /// A turn is under way
    @Published private(set) var working = false
    /// Claude is thinking (before any text of this message)
    @Published private(set) var thinking = false
    @Published private(set) var sessionId: String? {
        didSet { if sessionId != oldValue { loadCache() } }
    }
    @Published private(set) var model: String?
    @Published private(set) var loadingHistory = false
    /// `clauntty-chat` ended: the pane is back at its shell
    @Published private(set) var ended = false {
        didSet { if ended != oldValue { session?.chatModeDidChange() } }
    }
    /// Asks the view to put the cursor in its text box (the window was tapped)
    @Published var focusRequest = 0
    /// Messages sent while Claude works: Claude holds them until the turn ends (or is
    /// interrupted: "Send now", Claude Code's "enter to interrupt and send"), and only then
    /// echoes them. Drawn under the conversation until they go in.
    @Published private(set) var queued: [Item] = []
    /// The images of messages sent from here, by their item's id
    @Published private(set) var sentImages: [String: [PlatformImage]] = [:]
    /// The launcher's version, from its start line: 2 takes images
    private(set) var launcherVersion: Int?
    /// Images can go to this chat: its launcher turns their files into data. One started
    /// before version 2 would pass Claude the path as the data.
    var takesImages: Bool { (launcherVersion ?? 2) >= 2 }

    /// A message can be in both: kept from before a reattach and replayed again. The live
    /// one wins. Replies are also matched by text: one that streamed in before has another
    /// id when a replay begins in the middle of its message.
    private func rebuildItems() {
        guard !live.isEmpty else {
            items = history
            return
        }
        var liveIds = Set<String>()
        var liveReplies = Set<String>()
        for item in live {
            liveIds.insert(item.id)
            if case .reply(_, let text, _) = item { liveReplies.insert(text) }
        }
        items = history.filter { item in
            if liveIds.contains(item.id) { return false }
            if case .reply(_, let text, _) = item, liveReplies.contains(text) { return false }
            return true
        } + live
    }

    private var lineBuffer = Data()
    private var messageId: String?
    /// The live item each content block of the current message is drawn in
    private var blockItems: [Int: String] = [:]
    private var loadedHistoryFor: String?
    /// Messages whose images were asked of the host (each once)
    private var imagesAsked: Set<String> = []

    init(session: Session?, sessionId: String? = nil) {
        self.session = session
        self.sessionId = sessionId
        loadCache()
    }

    // MARK: - Kept on this device

    /// The conversation as last drawn here, per Claude conversation: shown at once when the
    /// chat opens (a restart, a reattach), before the host answers, and kept when it can't
    nonisolated private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatCache", isDirectory: true)
    }

    nonisolated private static func cacheFile(_ sessionId: String) -> URL {
        cacheDirectory.appendingPathComponent(sessionId + ".json")
    }

    private func loadCache() {
        guard history.isEmpty, let sessionId, Self.isSafe(sessionId),
              let data = try? Data(contentsOf: Self.cacheFile(sessionId)),
              let cached = try? JSONDecoder().decode([Item].self, from: data) else { return }
        history = cached
        Logger.clauntty.debugOnly("Chat \(sessionId.prefix(8)): \(cached.count) items from this device")
    }

    /// The last 1000 items, finished; tools' text cut to what their rows show
    private func saveCache() {
        guard let sessionId, Self.isSafe(sessionId) else { return }
        let snapshot: [Item] = items.suffix(1000).compactMap { item in
            switch item {
            case .reply(let id, let text, _): return .reply(id: id, text: text, streaming: false)
            case .tool(var tool):
                tool.done = true
                tool.startedAt = nil
                tool.detail = String(tool.detail.prefix(20_000))
                tool.result = tool.result.map { String($0.prefix(20_000)) }
                return .tool(tool)
            default: return item
            }
        }
        let file = Self.cacheFile(sessionId)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: ChatSession.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
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
        // What this run drew stays (as history): the replay is the pane's last 16KB, often
        // a fragment, and the transcript may not answer. The replay's messages replace
        // their copies (`rebuildItems`).
        let kept = live.filter { if case .reply(_, _, true) = $0 { return false } else { return true } }
        if !kept.isEmpty {
            let known = Set(history.map(\.id))
            history += kept.filter { !known.contains($0.id) }
            saveCache()
        }
        Logger.clauntty.debugOnly("Chat: replay begins, \(self.history.count) items kept")
        live.removeAll()
        pending = nil
        blockItems.removeAll()
        messageId = nil
        working = false
        thinking = false
        // Connected now: earlier turns, if they couldn't be read before
        if sessionId != nil, loadedHistoryFor != sessionId { Task { await loadHistory() } }
    }

    private func handleLine(_ line: Data) {
        guard let start = line.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: line[start...]) as? [String: Any],
              let type = object["type"] as? String else { return }
        // A chat found from the pane's program, with no marker or init in what was replayed:
        // every event names its conversation
        if sessionId == nil, let id = object["session_id"] as? String, Self.isSafe(id) {
            sessionId = id
            session?.chatSessionIdChanged(id)
            Task { await loadHistory() }
        }
        switch type {
        case "clauntty_chat":
            ended = false
            startedAt = Date()
            launcherVersion = object["version"] as? Int
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
            queued = []
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
        case "control_cancel_request":
            // Claude stopped waiting (interrupted)
            if let id = object["request_id"] as? String, pendingRequestId == id { pending = nil }
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
            permissionMode = object["permissionMode"] as? String ?? permissionMode
        case "status":
            // Also comes, with no status, when the mode changes
            if object["status"] is String { working = true }
            permissionMode = object["permissionMode"] as? String ?? permissionMode
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
                    upsert(.tool(Tool(id: id, name: block["name"] as? String ?? "Tool", summary: "", detail: "",
                                      startedAt: Date())))
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
                var tool = existingTool(id) ?? Tool(id: id, name: "", summary: "", detail: "", startedAt: Date())
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
        if let prompt = Self.prompt(blocks) {
            addPrompt(prompt.text, images: prompt.images, uuid: object["uuid"] as? String)
        }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                // Its tool ran or was refused: what it asked is answered, maybe on another
                // device attached to the pane (Claude doesn't repeat the answer), or before a
                // replay of the pane's output began
                if pendingToolUseId == id { pending = nil }
                guard var tool = existingTool(id) else { continue }
                tool.result = Self.resultText(block["content"])
                tool.isError = block["is_error"] as? Bool ?? false
                tool.done = true
                upsert(.tool(tool))
            default:
                continue
            }
        }
    }

    private func addPrompt(_ text: String, images: Int = 0, uuid: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard images > 0 || (!trimmed.isEmpty && !trimmed.hasPrefix("<")) else { return }
        if trimmed.hasPrefix("[Request interrupted") { return }
        let sentHere: (Item) -> Bool = {
            if case .user(let id, let t, let n) = $0 { return id.hasPrefix("local-") && t == trimmed && n == images }
            return false
        }
        // Sent from here while Claude worked: it goes in now, after what that turn said
        if let at = queued.firstIndex(where: sentHere) {
            let old = queued.remove(at: at).id
            let id = uuid ?? old
            if id != old, let sent = sentImages.removeValue(forKey: old) { sentImages[id] = sent }
            live.append(.user(id: id, text: trimmed, images: images))
            return
        }
        // Sent from here: it's in already, waiting for its echo
        if let at = live.lastIndex(where: sentHere) {
            let old = live[at].id
            let id = uuid ?? old
            if id != old, let sent = sentImages.removeValue(forKey: old) { sentImages[id] = sent }
            live[at] = .user(id: id, text: trimmed, images: images)
            return
        }
        let id = uuid ?? "u-\(live.count)-\(trimmed.hashValue)"
        guard !hasItem(id) else { return }
        live.append(.user(id: id, text: trimmed, images: images))
    }

    /// A user message's prompt: its text (Claude Code's own `<tags>` left out) and how
    /// many images it has. Nil for one that's only tool results.
    nonisolated static func prompt(_ blocks: [[String: Any]]) -> (text: String, images: Int)? {
        var texts: [String] = []
        var images = 0
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !text.hasPrefix("<") { texts.append(text) }
            case "image":
                images += 1
            default:
                continue
            }
        }
        guard !texts.isEmpty || images > 0 else { return nil }
        return (texts.joined(separator: "\n\n"), images)
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

    private var pendingRequestId: String? {
        switch pending {
        case .approval(let a): return a.requestId
        case .question(let q): return q.requestId
        case nil: return nil
        }
    }

    /// The tool Claude is asking about (an approval or a question): it hasn't run yet
    var pendingToolUseId: String? {
        switch pending {
        case .approval(let a): return a.toolUseId
        case .question(let q): return q.toolUseId
        case nil: return nil
        }
    }

    private func finishTurn(stopped: Bool) {
        working = false
        thinking = false
        pending = nil
        for (i, item) in live.enumerated() {
            if case .reply(let id, let text, true) = item { live[i] = .reply(id: id, text: text, streaming: false) }
            // A tool that never got its result (refused, interrupted) isn't still running
            if case .tool(var tool) = item, !tool.done { tool.done = true; live[i] = .tool(tool) }
        }
        if stopped { live.append(.note(id: "stop-\(live.count)", text: "Stopped")) }
        // Claude has every waiting message by now: it took them during the turn, or starts
        // the next with them. Their echo can be missed (sent while this device was detached,
        // and past rtach's 16KB replay), which left one waiting for good. In the conversation
        // now, its echo still matches it (`addPrompt`).
        if !queued.isEmpty {
            live += queued
            queued = []
        }
        saveCache()
    }

    // MARK: - Permission mode

    /// What Claude asks before it acts: "default" (asks first), "acceptEdits", "plan",
    /// "auto" (a model decides), as Claude reports it (init, then a status on a change)
    @Published private(set) var permissionMode: String?

    /// The modes offered, in the order Shift+Tab goes through them (as in the terminal)
    static let modes: [(id: String, label: String)] = [
        ("default", "Ask First"), ("acceptEdits", "Accept Edits"), ("plan", "Plan"), ("auto", "Auto"),
    ]

    static func label(mode: String) -> String {
        switch mode {
        case "manual": return "Ask First"
        case "bypassPermissions": return "Bypass Permissions"
        case "dontAsk": return "Don't Ask"
        default: return modes.first { $0.id == mode }?.label ?? mode
        }
    }

    /// The mode new chats start in (`clauntty-chat --mode`): the last one picked, auto
    /// until then (Claude would start a headless session asking first)
    static var preferredMode: String {
        get { UserDefaults.standard.string(forKey: "chatPermissionMode") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "chatPermissionMode") }
    }

    /// Claude says when it changed (a status event); one it refuses (auto where the
    /// account doesn't have it) leaves the mode as it was. New chats start in it too.
    func setPermissionMode(_ mode: String) {
        Self.preferredMode = mode
        write(["type": "control_request", "request_id": "mode-\(UUID().uuidString.prefix(8))",
               "request": ["subtype": "set_permission_mode", "mode": mode]])
    }

    func nextPermissionMode() {
        let at = Self.modes.firstIndex { $0.id == permissionMode } ?? -1
        setPermissionMode(Self.modes[(at + 1) % Self.modes.count].id)
    }

    // MARK: - Input

    func send(_ prompt: String, images: [PlatformImage] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let id = "local-\(UUID().uuidString)"
        if !images.isEmpty { sentImages[id] = images }
        if working {
            queued.append(.user(id: id, text: text, images: images.count))
        } else {
            live.append(.user(id: id, text: text, images: images.count))
        }
        working = true
        guard !images.isEmpty else {
            write(["type": "user", "message": ["role": "user", "content": text]])
            return
        }
        // Each image goes to the host as a file first (an SSH upload, not typed through
        // the pane), and the launcher puts it in the message (`chatLauncher`)
        Task {
            var blocks: [[String: Any]] = []
            for image in images {
                guard let encoded = Self.encode(image),
                      let path = await session?.uploadPaste(encoded.data, ext: encoded.ext) else {
                    live.append(.note(id: "upload-\(id)", text: "The image didn't upload, so this wasn't sent"))
                    working = false
                    return
                }
                blocks.append(["type": "image",
                               "source": ["type": "base64", "media_type": encoded.mediaType, "data": "clauntty-file:" + path]])
            }
            if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            write(["type": "user", "message": ["role": "user", "content": blocks]])
        }
    }

    /// An image as Claude takes it: at most 1568 px on its long side and about 1.15
    /// megapixels (Claude scales bigger ones down anyway, so the rest is upload time).
    /// PNG keeps a screenshot's text sharp; a big one (a photo) goes as JPEG.
    nonisolated static func encode(_ image: PlatformImage) -> (data: Data, mediaType: String, ext: String)? {
        #if canImport(UIKit)
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        #else
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: source.width, height: source.height)
        #endif
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(1, 1568 / max(size.width, size.height), (1_150_000 / (size.width * size.height)).squareRoot())
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawn, so a photo's orientation is applied
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = drawn.cgImage else { return nil }
        #else
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { return nil }
        #endif
        func data(_ type: UTType, _ options: [CFString: Any]) -> Data? {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            return CGImageDestinationFinalize(destination) ? out as Data : nil
        }
        if let png = data(.png, [:]), png.count <= 1_500_000 { return (png, "image/png", "png") }
        guard let jpeg = data(.jpeg, [kCGImageDestinationLossyCompressionQuality: 0.85]) else { return nil }
        return (jpeg, "image/jpeg", "jpg")
    }

    func allow(always suggestion: JSONValue? = nil) {
        guard case .approval(let approval) = pending else { return }
        var response: [String: Any] = ["behavior": "allow", "updatedInput": approval.input.any]
        if let suggestion { response["updatedPermissions"] = [suggestion.any] }
        respond(approval.requestId, response)
        // It runs from now: its time counts from here
        if let id = approval.toolUseId, var tool = existingTool(id) {
            tool.startedAt = Date()
            upsert(.tool(tool))
        }
    }

    func deny() {
        guard let requestId = pendingRequestId else { return }
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

    /// Claude Code's Ctrl+B: the running command (`toolId`), or every one running in the
    /// foreground, carries on in the background, and Claude goes on
    func runInBackground(_ toolId: String? = nil) {
        var request: [String: Any] = ["subtype": "background_tasks"]
        if let toolId { request["tool_use_id"] = toolId }
        write(["type": "control_request", "request_id": "bg-\(UUID().uuidString.prefix(8))", "request": request])
    }

    /// Something runs that can go to the background (a command)
    var hasForegroundCommand: Bool {
        live.contains { if case .tool(let t) = $0 { return !t.done && t.name == "Bash" } else { return false } }
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

    /// A message's images when they weren't sent from here (another device, or before a
    /// restart): from Claude's transcript on the host, which keeps them whole under the
    /// message's id (the echo and the history strip them). Only for messages in its last
    /// 30MB, as the history.
    func loadImages(for id: String) async {
        guard sentImages[id] == nil, UUID(uuidString: id) != nil, !imagesAsked.contains(id),
              let sessionId, Self.isSafe(sessionId), let session else { return }
        imagesAsked.insert(id)
        // The transcript can trail the echo a little
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            let script = """
                export LC_ALL=C
                for t in "$HOME"/.claude/projects/*/"\(sessionId)".jsonl; do
                  [ -f "$t" ] || continue
                  tail -c 30000000 "$t" | grep -F '"uuid":"\(id)"' | head -n 1 | grep -o '"data":"[A-Za-z0-9+/=]*"'
                  break
                done
                """
            guard let output = try? await session.runRemoteScript(script) else { continue }
            let images = output.split(separator: "\n").compactMap { line -> PlatformImage? in
                let base64 = line.dropFirst("\"data\":\"".count).dropLast()
                return Data(base64Encoded: String(base64)).flatMap { PlatformImage(data: $0) }
            }
            if !images.isEmpty {
                sentImages[id] = images
                return
            }
        }
        imagesAsked.remove(id)
    }

    // MARK: - History

    /// Earlier turns, from Claude's transcript on the host. Only its last few MB: a long
    /// conversation's file passes hundreds of MB (tool results, screenshots).
    func loadHistory() async {
        guard let sessionId, loadedHistoryFor != sessionId, Self.isSafe(sessionId), let session else { return }
        loadedHistoryFor = sessionId
        loadingHistory = true
        defer { loadingHistory = false }
        // Bytes, not characters (LC_ALL=C): the cut can fall inside one, and macOS's sed
        // refused the whole stream for it ("illegal byte sequence"), so after a restart the
        // history came back empty, for good. Its first line is cut, so it goes.
        // The last 60MB: a screenshot Claude looked at is two copies of the image in base64
        // (the message and `toolUseResult`), so 6MB was a few minutes of a session. Lines
        // over 300KB go (a screenshot's result: its text isn't worth the bytes), then any
        // long base64 string. About 1.5MB comes back, in a second or two.
        let script = """
            export LC_ALL=C
            for t in "$HOME"/.claude/projects/*/"\(sessionId)".jsonl; do
              [ -f "$t" ] || continue
              tail -c 60000000 "$t" | tail -n +2 | grep -E '"type":"(user|assistant)"|"type":"queued_command"' | grep -v '"isSidechain":true' |
                awk 'length($0) < 300000' | sed -E 's#"[A-Za-z0-9+/=]{200,}"#""#g'
              break
            done
            """
        guard let output = try? await session.runRemoteScript(script) else {
            // Not connected yet, say: the next attach tries again
            loadedHistoryFor = nil
            return
        }
        let parsed = Self.parseTranscript(output)
        Logger.clauntty.debugOnly("Chat \(sessionId.prefix(8)): transcript \(output.utf8.count) bytes, \(parsed.count) items")
        // Nothing read (the transcript not there yet, or the read failed): what's kept here
        // stays, and the next attach tries again
        guard !parsed.isEmpty else {
            loadedHistoryFor = nil
            return
        }
        // Waiting messages the transcript has: Claude took them (their echo was missed)
        let taken = Set(parsed.compactMap { item -> String? in
            if case .user(_, let text, _) = item { return text } else { return nil }
        })
        let found = queued.filter { if case .user(_, let text, _) = $0 { return taken.contains(text) } else { return false } }
        if !found.isEmpty {
            let ids = Set(found.map(\.id))
            queued.removeAll { ids.contains($0.id) }
        }
        // The transcript read is its last 60MB: what's kept here from before that stays
        if let first = parsed.first?.id, let at = history.firstIndex(where: { $0.id == first }) {
            history = Array(history[..<at]) + parsed
        } else {
            history = parsed
        }
        saveCache()
    }

    /// Claude's transcript lines as chat items: prompts, replies and tools with their results
    nonisolated static func parseTranscript(_ text: String) -> [Item] {
        var items: [Item] = []
        var index: [String: Int] = [:]
        var ordinal: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            // A message sent while Claude worked, taken during the turn: Claude's transcript
            // has it as an attachment, not a user message
            if type == "attachment", let attachment = object["attachment"] as? [String: Any],
               attachment["type"] as? String == "queued_command",
               let prompt = (attachment["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty, !prompt.hasPrefix("<") {
                let id = attachment["source_uuid"] as? String ?? object["uuid"] as? String ?? "q-\(items.count)"
                if index[id] == nil {
                    index[id] = items.count
                    items.append(.user(id: id, text: prompt))
                }
                continue
            }
            guard type == "user" || type == "assistant",
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
                    // A prompt with images (their data left out on the host)
                    if let prompt = prompt(blocks) {
                        items.append(.user(id: object["uuid"] as? String ?? "u-\(items.count)",
                                           text: prompt.text, images: prompt.images))
                    }
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
