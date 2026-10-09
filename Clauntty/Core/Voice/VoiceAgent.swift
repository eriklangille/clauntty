import AVFoundation
import Combine
import UIKit
import os.log

/// A voice session with xAI's Grok voice model that can look at the terminal tabs.
/// Mirrors switchboard's realtime session: configure with session.update, stream mic
/// audio, play audio deltas, answer function calls, then ask for the next response.
@MainActor
final class VoiceAgent: ObservableObject {
    static let shared = VoiceAgent()

    static let model = "grok-voice-think-fast-2.0"
    /// xAI bills connection time, silence included; cap every session
    static let maxDuration: TimeInterval = 15 * 60
    static let warningAt: TimeInterval = 14 * 60
    /// Optional hang-up after this long without anyone talking
    static let idleLimit: TimeInterval = 3 * 60

    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
    }

    struct LogEntry: Identifiable, Equatable {
        enum Kind { case user, agent, tool, system }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    struct Summary: Equatable {
        let cost: VoiceCost
        let reason: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var cost = VoiceCost()
    @Published private(set) var remaining: TimeInterval = VoiceAgent.maxDuration
    @Published private(set) var log: [LogEntry] = []
    /// The last finished session, shown in the panel and Settings
    @Published private(set) var lastSession: Summary?

    var isActive: Bool { phase != .idle }

    private weak var sessionManager: SessionManager?
    private var socket: XAIRealtimeSocket?
    private var audio: VoiceAudio?
    private var timer: Timer?
    private var openedAt: Date?
    private var lastActivity = Date()
    private var sentConfig = false
    private var configured = false
    private var warned = false
    private var interruptionObserver: NSObjectProtocol?

    /// A response is being generated
    private var responseActive = false
    /// Tool calls from the current response still running
    private var toolsRunning = 0
    /// The current response made tool calls, so ask for another once they're answered
    private var needsFollowUp = false
    /// Ask for a response once the current one is done (e.g. after the one-minute warning)
    private var responseQueued = false
    /// end_session was called: hang up once the goodbye has played
    private var endRequested = false
    /// The agent line being built from transcript deltas
    private var agentEntryId: UUID?

    /// Each tab's cleaned text as of the model's last read, for "new" reads
    private var snapshots: [UUID: [String]] = [:]
    /// Claudes per tab and conversations per Claude session, briefly, so a search
    /// followed by read_turn fetches once
    private var agentCache: [UUID: (at: Date, agents: [ClaudeAgent])] = [:]
    private var transcriptCache: [String: (at: Date, transcript: ClaudeTranscript)] = [:]

    private init() {}

    // MARK: - Start / End

    func start(sessionManager: SessionManager) {
        guard phase == .idle else { return }
        guard let apiKey = VoiceSettings.apiKey else { return }
        self.sessionManager = sessionManager

        phase = .connecting
        cost = VoiceCost()
        remaining = Self.maxDuration
        log = []
        snapshots = [:]
        agentCache = [:]
        transcriptCache = [:]
        openedAt = nil
        sentConfig = false
        configured = false
        warned = false
        responseActive = false
        toolsRunning = 0
        needsFollowUp = false
        responseQueued = false
        endRequested = false
        agentEntryId = nil
        lastActivity = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                end(reason: "Microphone access is off for Clauntty (Settings > Clauntty)")
                return
            }
            guard phase == .connecting else { return }
            // Set up audio first: xAI is told the mic's rate in session.update
            let audio = VoiceAudio()
            do {
                try audio.prepare()
            } catch {
                end(reason: "Couldn't start audio: \(error.localizedDescription)")
                return
            }
            self.audio = audio
            connect(apiKey: apiKey)
        }
    }

    private func connect(apiKey: String) {
        let socket = XAIRealtimeSocket(apiKey: apiKey, model: Self.model)
        socket.onOpen = { [weak self] in self?.socketOpened() }
        socket.onEvent = { [weak self] event in self?.handle(event) }
        socket.onClose = { [weak self] reason in self?.end(reason: reason) }
        self.socket = socket
        socket.connect()
        voiceTrace("connecting (\(Self.model))")
    }

    func end(reason: String) {
        guard phase != .idle else { return }
        voiceTrace("ending: \(reason)")

        timer?.invalidate()
        timer = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        audio?.stop()
        audio = nil
        socket?.onClose = nil
        socket?.close()
        socket = nil

        updateClock()
        lastSession = Summary(cost: cost, reason: reason)
        phase = .idle
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Socket

    private func socketOpened() {
        openedAt = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so it keeps ticking while something scrolls
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Configure on the server's first event, or after a moment if it sends none
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.phase == .connecting else { return }
            self.configure()
        }
    }

    private func configure() {
        guard !sentConfig else { return }
        sentConfig = true
        let inputRate = audio?.inputRate ?? 24000
        voiceTrace("sending session.update (voice=\(VoiceSettings.voice), reasoning=\(VoiceSettings.reasoning), mic \(inputRate)Hz)")
        socket?.send([
            "type": "session.update",
            "session": [
                "instructions": Self.instructions,
                "voice": VoiceSettings.voice,
                "reasoning": ["effort": VoiceSettings.reasoning],
                "turn_detection": ["type": "server_vad"],
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": inputRate]],
                    "output": ["format": ["type": "audio/pcm", "rate": Int(VoiceAudio.outputRate)]],
                ],
                "tools": Self.tools,
            ] as [String: Any],
        ])
    }

    private func startAudio() {
        guard let audio else { return }
        let socket = self.socket
        var chunks = 0
        audio.onInput = { pcm in
            chunks += 1
            if chunks == 1 || chunks % 50 == 0 {
                // Peak level tells a silent mic (all zeros) from one that hears something
                let peak = pcm.withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
                }
                voiceTrace("sent \(chunks) mic chunks (\(pcm.count) bytes, peak \(peak))")
            }
            socket?.send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        }
        audio.onPlaybackDrained = { [weak self] in
            self?.playbackDrained()
        }
        audio.onInputRateChanged = { [weak self] rate in
            // e.g. AirPods connected mid-session: tell xAI the new rate
            self?.socket?.send([
                "type": "session.update",
                "session": ["audio": ["input": ["format": ["type": "audio/pcm", "rate": rate]]]],
            ])
        }
        do {
            try audio.start()
        } catch {
            end(reason: "Couldn't start audio: \(error.localizedDescription)")
            return
        }

        // A phone call or Siri takes the audio session
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.end(reason: "Audio was interrupted") }
        }
    }

    private func handle(_ event: [String: Any]) {
        guard phase != .idle, let type = event["type"] as? String else { return }
        if !type.hasSuffix(".delta") {
            voiceTrace("event \(type)")
        }

        switch type {
        case "session.created", "conversation.created":
            configure()

        case "session.updated":
            voiceTrace("session.updated: \(Self.describe(event["session"]))")
            guard !configured else { return }
            configured = true
            startAudio()
            if phase == .connecting {
                phase = .listening
            }
            // Greet first. This may also cover xAI's slow first turn (5s in the first test); unconfirmed
            say("[Clauntty: the voice session just started. Greet the user in a few words and ask what they need.]")

        case "input_audio_buffer.speech_started":
            // Barge-in: stop playing what the model was saying
            audio?.flush()
            agentEntryId = nil
            lastActivity = Date()
            phase = .listening

        case "input_audio_buffer.speech_stopped":
            lastActivity = Date()
            phase = .thinking

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = (event["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                append(.user, transcript)
                voiceTrace("you: \(transcript)")
            } else {
                voiceTrace("you: (no transcript) \(Self.describe(event))")
            }

        case "response.created":
            responseActive = true
            lastActivity = Date()
            if phase != .speaking {
                phase = .thinking
            }

        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String, let pcm = Data(base64Encoded: delta) {
                audio?.play(pcm)
                phase = .speaking
            }

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                appendAgentText(delta)
            }

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let transcript = event["transcript"] as? String, let id = agentEntryId,
               let index = log.firstIndex(where: { $0.id == id }) {
                log[index].text = transcript
            }
            let spoken = event["transcript"] as? String ?? agentEntryId.flatMap { id in log.first { $0.id == id }?.text } ?? "(no transcript)"
            voiceTrace("grok: \(spoken)")
            agentEntryId = nil

        case "response.function_call_arguments.done":
            guard let name = event["name"] as? String, let callId = event["call_id"] as? String else { return }
            let arguments = event["arguments"] as? String ?? "{}"
            runTool(name: name, arguments: arguments, callId: callId)

        case "response.done":
            responseActive = false
            agentEntryId = nil
            if let response = event["response"] as? [String: Any],
               let status = response["status"] as? String, status == "failed" {
                append(.system, "Response failed")
                voiceTrace("response failed: \(String(describing: response["status_details"]))")
            }
            if endRequested {
                // The goodbye was in this response; hang up once it has played
                needsFollowUp = false
                if toolsRunning == 0 && !(audio?.isPlaying ?? false) {
                    end(reason: "Hung up")
                }
            } else if (needsFollowUp || responseQueued) && toolsRunning == 0 {
                requestResponse()
            } else if !(audio?.isPlaying ?? false) {
                playbackDrained()
            }

        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Unknown error: \(event)"
            voiceTrace("xAI error: \(Self.describe(event))")
            append(.system, "xAI: \(message)")

        default:
            break
        }
    }

    private func requestResponse() {
        needsFollowUp = false
        responseQueued = false
        socket?.send(["type": "response.create"])
    }

    private func playbackDrained() {
        guard !responseActive else { return }
        if endRequested && toolsRunning == 0 {
            end(reason: "Hung up")
            return
        }
        if phase == .speaking || phase == .thinking {
            phase = .listening
        }
    }

    // MARK: - Clock

    private func tick() {
        guard phase != .idle else { return }
        updateClock()

        let elapsed = cost.seconds
        if elapsed >= Self.maxDuration {
            end(reason: "Reached the 15-minute limit")
            return
        }
        if elapsed >= Self.warningAt && !warned {
            warned = true
            say("[Clauntty: one minute left in this voice session. Tell the user in a few words.]")
        }
        if VoiceSettings.idleHangUp, configured, !responseActive, toolsRunning == 0, !(audio?.isPlaying ?? false),
           Date().timeIntervalSince(lastActivity) >= Self.idleLimit {
            end(reason: "No one talked for 3 minutes")
        }
    }

    private func updateClock() {
        guard let openedAt else { return }
        cost.seconds = min(Date().timeIntervalSince(openedAt), Self.maxDuration)
        remaining = Self.maxDuration - cost.seconds
    }

    /// Give the model a note from the app and let it respond
    private func say(_ text: String) {
        socket?.send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ] as [String: Any],
        ])
        cost.textInputs += 1
        if responseActive || toolsRunning > 0 {
            responseQueued = true
        } else {
            requestResponse()
        }
    }

    // MARK: - Log

    private func append(_ kind: LogEntry.Kind, _ text: String) {
        log.append(LogEntry(kind: kind, text: text))
        if log.count > 50 {
            log.removeFirst(log.count - 50)
        }
    }

    private func appendAgentText(_ delta: String) {
        if let id = agentEntryId, let index = log.firstIndex(where: { $0.id == id }) {
            log[index].text += delta
        } else {
            append(.agent, delta)
            agentEntryId = log.last?.id
        }
    }

    // MARK: - Tools

    private func runTool(name: String, arguments: String, callId: String) {
        lastActivity = Date()
        needsFollowUp = true
        toolsRunning += 1
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        voiceTrace("tool \(name) \(arguments)")

        Task {
            let output: [String: Any]
            switch name {
            case "list_tabs":
                append(.tool, "listed tabs")
                output = ["tabs": await listTabs()]
            case "read_tab":
                output = await readTab(args)
            case "search_tab":
                output = await searchTab(args)
            case "read_turn":
                output = await readTurn(args)
            case "end_session":
                endRequested = true
                output = ["ok": true]
                scheduleHangUpFallback()
            default:
                output = ["error": "Unknown tool \(name)"]
            }
            finishTool(callId: callId, output: output)
        }
    }

    /// Don't wait forever for the goodbye to finish playing
    private func scheduleHangUpFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.endRequested else { return }
            self.end(reason: "Hung up")
        }
    }

    private func finishTool(callId: String, output: [String: Any]) {
        guard phase != .idle else { return }
        let json = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        voiceTrace("tool result (\(json.count) chars): \(json.prefix(600))")
        socket?.send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callId, "output": json],
        ])
        cost.textInputs += 1
        toolsRunning -= 1

        guard toolsRunning == 0, !responseActive else { return }
        if endRequested {
            // Hang up after the goodbye instead of asking for more
            needsFollowUp = false
            if !(audio?.isPlaying ?? false) {
                end(reason: "Hung up")
            }
        } else if needsFollowUp {
            requestResponse()
        }
    }

    /// Terminal tabs in tab-bar order, numbered from 1
    private func voiceTabs() -> [(tab: VoiceTab, session: Session)] {
        guard let sessionManager else { return [] }
        var result: [(VoiceTab, Session)] = []
        for item in sessionManager.orderedTabs() {
            guard case .terminal(let session) = item else { continue }
            let config = session.connectionConfig
            let tab = VoiceTab(
                number: result.count + 1,
                title: session.title,
                name: config.name,
                host: "\(config.username)@\(config.host)"
            )
            result.append((tab, session))
        }
        return result
    }

    /// Every tab with the Claude conversations running in it. Tabs on one machine that
    /// run the same multiplexer share their Claudes; those are listed once.
    private func listTabs() async -> [[String: Any]] {
        let activeId = sessionManager?.activeSession?.id
        let tabs = voiceTabs()
        // Look up every connected tab at once
        var found: [UUID: [ClaudeAgent]] = [:]
        await withTaskGroup(of: (UUID, [ClaudeAgent]?).self) { group in
            for (_, session) in tabs where session.state == .connected && session.sshConnection != nil {
                group.addTask { @MainActor in (session.id, await self.claudes(in: session)) }
            }
            for await (id, agents) in group {
                found[id] = agents
            }
        }

        var listedOn: [String: Int] = [:]  // "host pid" → tab number
        return tabs.map { tab, session in
            var entry: [String: Any] = [
                "tab": tab.number,
                "title": tab.title,
                "machine": tab.name.isEmpty ? tab.host : "\(tab.name) (\(tab.host))",
                "on_screen": session.id == activeId,
            ]
            guard session.state == .connected else {
                entry["state"] = "\(session.stateDescription); read_tab connects it"
                return entry
            }
            guard let agents = found[session.id] else {
                entry["claude"] = "couldn't check"
                return entry
            }
            let keys = agents.map { "\(tab.host) \($0.pid)" }
            if !keys.isEmpty, let earlier = keys.compactMap({ listedOn[$0] }).first, keys.allSatisfy({ listedOn[$0] != nil }) {
                entry["claude"] = "same conversations as tab \(earlier)"
                return entry
            }
            keys.forEach { listedOn[$0] = listedOn[$0] ?? tab.number }
            entry["claude"] = agents.isEmpty ? "none (a plain terminal)" : agents.enumerated().map { Self.describe($1, number: $0 + 1) }
            return entry
        }
    }

    /// For a Claude tab: an outline of recent turns, the latest turn in full and the
    /// bottom of the screen. For a plain terminal: what it printed since the last read.
    private func readTab(_ args: [String: Any]) async -> [String: Any] {
        let target: (tab: VoiceTab, session: Session)
        switch resolveTab(args) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }
        let (tab, session) = target
        append(.tool, "read \(tab.title)")

        if let problem = await makeLive(session) {
            return ["tab": tab.number, "title": tab.title, "error": problem]
        }

        if let agents = await claudes(in: session), !agents.isEmpty {
            let agent: ClaudeAgent
            switch pickConversation(args, from: agents, tab: tab) {
            case .success(let picked): agent = picked
            case .failure(let error): return error.output
            }
            guard let transcript = await transcript(for: agent, in: session) else {
                return ["tab": tab.number, "error": "Couldn't read the Claude conversation's history"]
            }
            var output: [String: Any] = ["tab": tab.number, "claude": Self.describe(agent, number: (agents.firstIndex(of: agent) ?? 0) + 1)]
            if agents.count > 1 && args["conversation"] == nil {
                output["other_conversations_in_tab"] = agents.enumerated().filter { $1 != agent }.map { "\($0 + 1): \($1.title ?? "untitled")" }
            }
            let count = transcript.turns.count
            if count == 0 {
                output["note"] = "Nothing asked in this conversation yet"
            } else {
                output["total_turns"] = count
                if count > 1 {
                    output["earlier_turns"] = transcript.outline(max(0, count - 5)..<(count - 1))
                }
                output["latest_turn"] = transcript.render(turn: count - 1, limit: 3500)
            }
            output["screen_bottom"] = screenBottom(session)
            output["screen_note"] = agent.focused || agents.count == 1
                ? "The bottom of what the tab shows now"
                : "The bottom of what the tab shows now, which is a different pane than this conversation"
            return output
        }

        // A plain terminal
        guard let whole = session.readTerminalText?(true) else {
            return ["tab": tab.number, "title": tab.title, "error": "The tab's terminal isn't ready yet"]
        }
        let lines = TerminalTextCleaner.clean(TerminalStyledText.markup(whole))
        var output: [String: Any] = [
            "tab": tab.number,
            "title": tab.title,
            "waiting_for_input": session.isWaitingForInput,
        ]
        let diff = TerminalTextDiff.newLines(previous: snapshots[session.id], current: lines)
        switch diff.kind {
        case .first: output["note"] = "First read of this tab: its most recent lines"
        case .reset: output["note"] = "The screen changed completely since the last read: its most recent lines"
        case .new:
            if diff.lines.isEmpty {
                output["note"] = "Nothing new since the last read"
                output["screen_bottom"] = screenBottom(session)
            }
        }
        if diff.omitted > 0 {
            output["omitted_earlier_lines"] = diff.omitted
        }
        if !diff.lines.isEmpty {
            output["text"] = diff.lines.joined(separator: "\n")
        }
        snapshots[session.id] = lines
        return output
    }

    private func searchTab(_ args: [String: Any]) async -> [String: Any] {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ["error": "Give a query"] }
        let found = await conversation(args)
        guard case .success(let (tab, transcript)) = found else {
            if case .failure(let error) = found { return error.output }
            return [:]
        }
        append(.tool, "searched \(tab.title) for \"\(query)\"")
        let result = transcript.search(query)
        var output: [String: Any] = [
            "tab": tab.number,
            "total_turns": transcript.turns.count,
            "matches": result.hits.map { "Turn \($0.turn), \($0.who): \($0.snippet)" },
        ]
        if result.total > result.hits.count {
            output["note"] = "Showing the newest \(result.hits.count) of \(result.total) matches"
        } else if result.hits.isEmpty {
            output["note"] = "No matches"
        }
        return output
    }

    private func readTurn(_ args: [String: Any]) async -> [String: Any] {
        let found = await conversation(args)
        guard case .success(let (tab, transcript)) = found else {
            if case .failure(let error) = found { return error.output }
            return [:]
        }
        let requested = args["turn"] as? Int ?? Int(args["turn"] as? String ?? "") ?? transcript.turns.count
        guard let text = transcript.render(turn: requested - 1) else {
            return ["tab": tab.number, "error": "No turn \(requested); the conversation has \(transcript.turns.count)"]
        }
        append(.tool, "read turn \(requested) of \(tab.title)")
        return ["tab": tab.number, "turn": text]
    }

    // MARK: - Tool helpers

    private struct ToolError: Error {
        let output: [String: Any]
        init(_ output: [String: Any]) { self.output = output }
    }

    private func resolveTab(_ args: [String: Any]) -> Result<(tab: VoiceTab, session: Session), ToolError> {
        let query = (args["tab"] as? Int).map(String.init) ?? args["tab"] as? String ?? ""
        let tabs = voiceTabs()
        switch VoiceTabResolver.resolve(query, in: tabs.map(\.tab)) {
        case .found(let index):
            return .success(tabs[index])
        case .notFound:
            return .failure(ToolError(["error": "No tab matches \"\(query)\". Call list_tabs to see them."]))
        case .ambiguous(let indices):
            return .failure(ToolError(["error": "\"\(query)\" matches several tabs", "matches": indices.map { "\(tabs[$0].tab.number): \(tabs[$0].tab.title)" }]))
        }
    }

    /// The conversation a tool call means: one Claude in the tab, or the one the
    /// `conversation` argument names (a number from list_tabs, or part of its title)
    private func pickConversation(_ args: [String: Any], from agents: [ClaudeAgent], tab: VoiceTab) -> Result<ClaudeAgent, ToolError> {
        let query = ((args["conversation"] as? Int).map(String.init) ?? args["conversation"] as? String ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            if agents.count == 1 { return .success(agents[0]) }
            // The one the multiplexer is showing
            if let focused = agents.first(where: \.focused) { return .success(focused) }
            return .failure(ToolError([
                "tab": tab.number,
                "note": "This tab has \(agents.count) Claude conversations. Call again with conversation set to one of these.",
                "conversations": agents.enumerated().map { Self.describe($1, number: $0 + 1) },
            ]))
        }
        if let number = Int(query), agents.indices.contains(number - 1) {
            return .success(agents[number - 1])
        }
        let matches = agents.filter { ($0.title ?? "").lowercased().contains(query) || $0.directory.lowercased().contains(query) }
        if matches.count == 1 { return .success(matches[0]) }
        return .failure(ToolError([
            "tab": tab.number,
            "error": matches.isEmpty ? "No conversation matches \"\(query)\"" : "\"\(query)\" matches several conversations",
            "conversations": agents.enumerated().map { Self.describe($1, number: $0 + 1) },
        ]))
    }

    /// The tab and conversation for search_tab and read_turn
    private func conversation(_ args: [String: Any]) async -> Result<(VoiceTab, ClaudeTranscript), ToolError> {
        let target: (tab: VoiceTab, session: Session)
        switch resolveTab(args) {
        case .success(let found): target = found
        case .failure(let error): return .failure(error)
        }
        let (tab, session) = target
        if let problem = await makeLive(session) {
            return .failure(ToolError(["tab": tab.number, "error": problem]))
        }
        guard let agents = await claudes(in: session) else {
            return .failure(ToolError(["tab": tab.number, "error": "Couldn't check the tab for Claude"]))
        }
        guard !agents.isEmpty else {
            return .failure(ToolError(["tab": tab.number, "error": "No Claude conversation runs in this tab; use read_tab"]))
        }
        switch pickConversation(args, from: agents, tab: tab) {
        case .success(let agent):
            guard let transcript = await transcript(for: agent, in: session) else {
                return .failure(ToolError(["tab": tab.number, "error": "Couldn't read the Claude conversation's history"]))
            }
            return .success((tab, transcript))
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func describe(_ agent: ClaudeAgent, number: Int) -> [String: Any] {
        var entry: [String: Any] = [
            "conversation": number,
            "title": agent.title ?? "untitled (new, or nothing asked yet)",
            "status": agent.statusText,
            "directory": agent.shortDirectory,
        ]
        if agent.focused {
            entry["showing_in_tab"] = true
        }
        return entry
    }

    /// The Claudes running in a tab, or nil if the machine couldn't be asked
    private func claudes(in session: Session) async -> [ClaudeAgent]? {
        if let cached = agentCache[session.id], Date().timeIntervalSince(cached.at) < 5 {
            return cached.agents
        }
        guard let id = session.rtachSessionId else { return [] }
        guard let script = ClaudeScripts.find(rtachSessionId: id),
              let output = await runScript(script, in: session) else { return nil }
        let agents = ClaudeScripts.parseAgents(output)
        agentCache[session.id] = (Date(), agents)
        return agents
    }

    private func transcript(for agent: ClaudeAgent, in session: Session) async -> ClaudeTranscript? {
        if let cached = transcriptCache[agent.sessionId], Date().timeIntervalSince(cached.at) < 5 {
            return cached.transcript
        }
        guard let script = ClaudeScripts.extract(sessionId: agent.sessionId),
              let output = await runScript(script, in: session, timeout: 10) else { return nil }
        let transcript = ClaudeTranscript.parse(output)
        voiceTrace("read conversation \(agent.sessionId.prefix(8)): \(output.utf8.count) bytes, \(transcript.turns.count) turns")
        transcriptCache[agent.sessionId] = (Date(), transcript)
        return transcript
    }

    /// Run a script on the tab's machine, giving up after `timeout` seconds
    private func runScript(_ script: String, in session: Session, timeout: Double = 6) async -> String? {
        final class Once {
            var done = false
        }
        let once = Once()
        let started = Date()
        let output: String? = await withCheckedContinuation { continuation in
            func finish(_ value: String?) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                do {
                    finish(try await session.runRemoteScript(script))
                } catch {
                    voiceTrace("remote script failed: \(error.localizedDescription)")
                    finish(nil)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                finish(nil)
            }
        }
        voiceTrace("remote script: \(output.map { "\($0.utf8.count) bytes" } ?? "no output") in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return output
    }

    /// The last lines of the tab's screen: a question, menu or suggestion it's showing
    private func screenBottom(_ session: Session) -> String {
        let screen = TerminalTextCleaner.clean(TerminalStyledText.markup(session.readTerminalText?(false) ?? ""))
        return screen.suffix(12).joined(separator: "\n")
    }

    /// Make sure a tab is connected and its terminal is current. Returns a problem, or nil.
    private func makeLive(_ session: Session) async -> String? {
        guard let sessionManager else { return "Clauntty isn't ready" }
        var reconnected = false

        switch session.state {
        case .error(let message):
            return "The tab has a connection error: \(message)"
        case .remotelyDeleted:
            return "The tab's session no longer exists on the machine"
        case .disconnected, .connecting, .connected:
            break
        }

        if session.state == .disconnected || (session.state == .connected && !session.hasAttachedChannel) {
            do {
                try await sessionManager.reconnect(session: session)
            } catch {
                return "Couldn't connect the tab: \(error.localizedDescription)"
            }
            reconnected = true
        }
        // Wait out a connect in progress (ours or one already running)
        for _ in 0..<40 where !(session.state == .connected && session.hasAttachedChannel) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard session.state == .connected, session.hasAttachedChannel else {
            return "The tab didn't connect"
        }

        // A background tab's output is paused (rtach buffers it); let it through
        let wasPaused = session.isPaused
        if wasPaused {
            session.resumeOutput()
        }
        await waitForQuietOutput(session, settleAfterConnect: reconnected)
        if (wasPaused || reconnected) && sessionManager.activeSession?.id != session.id {
            session.pauseOutput()
        }
        return nil
    }

    /// Wait until the tab's output stops arriving (at most a few seconds)
    private func waitForQuietOutput(_ session: Session, settleAfterConnect: Bool) async {
        var lastCount = session.totalBytesToTerminal
        var quietFor = 0
        let needed = settleAfterConnect ? 800 : 400
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            let count = session.totalBytesToTerminal
            if count == lastCount {
                quietFor += 150
                if quietFor >= needed { return }
            } else {
                quietFor = 0
                lastCount = count
            }
        }
    }

    /// An event as compact JSON for the log, cut short
    private static func describe(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return String(describing: value) }
        return String(decoding: data.prefix(1500), as: UTF8.self)
    }

    // MARK: - Model Setup

    static let instructions = """
    You are the voice assistant in Clauntty, an iPhone terminal app. The user runs Claude \
    Code, an AI coding agent, in their terminal tabs on remote machines, sometimes several \
    in one tab through a multiplexer like Herdr or tmux. You're on the user's side of those \
    conversations: you help them keep track of what each Claude is doing, what it's asking \
    them, and what they might tell it next, while they're away from the keyboard.

    - Keep replies short: one or two spoken sentences. No lists or markdown. Never read out \
    code, long paths, IDs or raw output; summarize instead.
    - Call list_tabs to see the tabs and the Claude conversations in them (title and \
    whether each is working or waiting for the user). When a tab has several, \
    showing_in_tab marks the one its multiplexer is showing, and read_tab without a \
    conversation reads that one.
    - Before saying what a conversation is about, what Claude did or asked, or giving \
    advice, call read_tab. It gives the last few turns in brief, the latest turn in full \
    and the bottom of the screen. Don't guess from titles.
    - Read only the conversations the question is about, not all of them. Every read_tab \
    includes the bottom of the tab's screen, so one read shows what's on screen.
    - For anything older or more detailed, look it up instead of guessing: search_tab \
    finds turns that mention something, read_turn reads one turn in full. If you still \
    can't find it, say you don't know.
    - A turn is one prompt from the user and everything Claude did for it. Claude's tool calls \
    are listed by what they did, not their full output.
    - In screen text, [dim]...[/dim] is greyed-out text: placeholders, suggestions and \
    hints, not something the user typed. In Claude Code, a dim prompt after the ❯ is a \
    suggested prompt and the input box is otherwise empty. [strike]...[/strike] is \
    crossed-out text, usually a finished item.
    - Refer to tabs and conversations by title, or by number if titles are unclear.
    - For now you can only look. You can't type into tabs, answer Claude, press keys or \
    switch tabs yet; if the user asks, say that's coming soon.
    - When the user says goodbye or asks you to hang up, say a brief goodbye and call end_session.
    - Sessions end after 15 minutes.
    """

    private static let tabParameter: [String: Any] = [
        "type": "string",
        "description": "Tab number from list_tabs, or part of its title, e.g. \"2\" or \"devbox\"",
    ]
    private static let conversationParameter: [String: Any] = [
        "type": "string",
        "description": "Which Claude conversation, when the tab has several: its number from list_tabs, or part of its title",
    ]

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "name": "list_tabs",
            "description": "List the terminal tabs: number, title, machine, which one is on screen, and the Claude conversations running in each (title, working or waiting, directory).",
            "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()] as [String: Any],
        ],
        [
            "type": "function",
            "name": "read_tab",
            "description": "Catch up on a tab. For a Claude conversation: the last few turns in brief, the latest turn in full, and the bottom of the screen. For a plain terminal: what it printed since you last read it. Connects the tab first if needed.",
            "parameters": [
                "type": "object",
                "properties": ["tab": tabParameter, "conversation": conversationParameter] as [String: Any],
                "required": ["tab"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "search_tab",
            "description": "Search a Claude conversation's whole history: the user's prompts, Claude's replies and its tool calls. Returns matching snippets with their turn numbers, newest first.",
            "parameters": [
                "type": "object",
                "properties": [
                    "tab": tabParameter,
                    "query": ["type": "string", "description": "Words to look for, e.g. \"migration prod\""],
                    "conversation": conversationParameter,
                ] as [String: Any],
                "required": ["tab", "query"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "read_turn",
            "description": "Read one turn of a Claude conversation in full: the user's prompt, Claude's replies and its tool calls.",
            "parameters": [
                "type": "object",
                "properties": [
                    "tab": tabParameter,
                    "turn": ["type": "integer", "description": "Turn number, from read_tab or search_tab"],
                    "conversation": conversationParameter,
                ] as [String: Any],
                "required": ["tab", "turn"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "end_session",
            "description": "Hang up this voice session. Say goodbye before calling it.",
            "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()] as [String: Any],
        ],
    ]
}

/// Voice events go to the console and, in debug builds, to the log file that can be
/// copied off the phone over Wi-Fi (Library/Caches/tailscale.log, see TailscaleDebugLog)
func voiceTrace(_ message: String) {
    Logger.clauntty.debugOnly("Voice: \(message)")
    TailscaleDebugLog.note("voice: \(message)")
}
