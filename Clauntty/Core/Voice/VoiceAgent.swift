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
    static let maxDuration: TimeInterval = 30 * 60
    static let warningAt: TimeInterval = 29 * 60
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
    /// The session (pane) the agent is looking at: the one its last tool call was about,
    /// else the one on screen when it started. Agent view puts its eyes there.
    @Published private(set) var lookingAt: UUID?

    var isActive: Bool { phase != .idle }

    private weak var sessionManager: SessionManager?
    private var socket: XAIRealtimeSocket?
    private var audio: VoiceAudio?
    private var timer: Timer?
    private var openedAt: Date?
    private var lastActivity = Date()
    /// When the user last spoke. Only this counts for the idle hang-up: the model
    /// announcing finished turns into an empty room shouldn't keep a session alive.
    private var lastUserSpeech = Date()
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

    /// Each pane's cleaned text as of the model's last read, for "new" reads
    private var snapshots: [UUID: [String]] = [:]
    /// Claudes per pane and conversations per Claude session, briefly, so a search
    /// followed by read_turn fetches once
    private var agentCache: [UUID: (at: Date, scan: ClaudeScan)] = [:]
    private var transcriptCache: [String: (at: Date, transcript: ClaudeTranscript)] = [:]

    /// Each agent pane's state as of the last tick, so the model hears when one finishes
    /// its turn or stops at a menu
    private var paneWatch: [String: String] = [:]
    /// Notes for the model, held until no one is talking
    private var pendingNotes: [String] = []
    private var userSpeaking = false
    /// Prompts sent during the current response, so a duplicate call doesn't send twice
    private var promptsThisResponse: Set<String> = []

    private init() {}

    // MARK: - Start / End

    func start(sessionManager: SessionManager) {
        guard phase == .idle else { return }
        guard let apiKey = VoiceSettings.apiKey else { return }
        self.sessionManager = sessionManager

        phase = .connecting
        lookingAt = sessionManager.activeSession?.id
        cost = VoiceCost()
        remaining = Self.maxDuration
        log = []
        snapshots = [:]
        agentCache = [:]
        transcriptCache = [:]
        paneWatch = [:]
        pendingNotes = []
        userSpeaking = false
        promptsThisResponse = []
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
        lastUserSpeech = Date()
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
        lookingAt = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    #if DEBUG
    /// A pretend session, to work on how it looks without calling xAI (the `fakeVoice`
    /// default): it moves between the tabs and through listening, thinking and speaking.
    func startFake(sessionManager: SessionManager) {
        guard phase == .idle else { return }
        self.sessionManager = sessionManager
        phase = .listening
        cost = VoiceCost()
        remaining = Self.maxDuration
        log = []
        lookingAt = sessionManager.activeSession?.id
        append(.user, "What are my agents up to?")
        append(.agent, "Two are working and one finished. Want me to read the finished one?")
        append(.tool, "read tab 2")
        append(.user, "Tell it to run the tests")
        append(.tool, "sent to Release build for the laptop: Run the tests")
        append(.agent, "Sent. It's running them now.")
        var step = 0
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase != .idle else { return }
                step += 1
                self.remaining = max(0, self.remaining - 2.5)
                self.phase = [.listening, .thinking, .speaking][step % 3]
                // A new tab every other step
                let tabs = self.voiceTabs()
                if step % 2 == 0, !tabs.isEmpty {
                    let index = (tabs.firstIndex { $0.session.id == self.lookingAt } ?? -1) + 1
                    self.lookingAt = tabs[index % tabs.count].session.id
                    self.append(.tool, "read tab \(index % tabs.count + 1)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    #endif

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
            lastUserSpeech = Date()
            userSpeaking = true
            phase = .listening

        case "input_audio_buffer.speech_stopped":
            lastActivity = Date()
            lastUserSpeech = Date()
            userSpeaking = false
            phase = .thinking

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = (event["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                append(.user, transcript)
                voiceTrace("you: \(transcript)")
            } else {
                voiceTrace("you: (no transcript) \(Self.describe(event))")
            }

        case "response.created":
            promptsThisResponse = []
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
            end(reason: "Reached the 30-minute limit")
            return
        }
        if elapsed >= Self.warningAt && !warned {
            warned = true
            say("[Clauntty: one minute left in this voice session. Tell the user in a few words.]")
        }
        if VoiceSettings.idleHangUp, configured, !responseActive, toolsRunning == 0, !(audio?.isPlaying ?? false),
           Date().timeIntervalSince(lastUserSpeech) >= Self.idleLimit {
            end(reason: "Nothing said for 3 minutes")
            return
        }

        if configured {
            watchPanes()
        }
        deliverNotes()
    }

    // MARK: - Watching conversations

    /// Note agents that just finished their turn or stopped at a menu, from the pane
    /// states rtach sends as they change (free: nothing is asked of the machines)
    private func watchPanes() {
        guard let sessionManager else { return }
        for (tab, _) in voiceTabs() {
            for pane in tab.panes {
                guard let state = sessionManager.paneStates[pane.id], state.hasAgent else { continue }
                let now = state.state ?? ""
                let before = paneWatch[pane.id]
                paneWatch[pane.id] = now
                guard let before, before != now else { continue }
                let label = Self.label(pane, in: tab, task: state.task)
                switch now {
                case "done":
                    pendingNotes.append("\(label) just finished its turn and is waiting for the user.")
                case "blocked":
                    pendingNotes.append("\(label) is waiting for the user at a menu or question\(state.note.map { ": \($0)" } ?? "").")
                default:
                    continue
                }
                voiceTrace("watch: \(pane.id) \(before) → \(now)")
            }
        }
    }

    /// "The agent in tab 2, pane 1 (api), on "fix the login redirect","
    private static func label(_ pane: VoicePane, in tab: VoiceTab, task: String?) -> String {
        var label = "The agent in tab \(tab.number)"
        if tab.panes.count > 1 { label += ", pane \(pane.number)" }
        label += " (\(pane.title))"
        if let task, !task.isEmpty, task != pane.title { label += ", on \"\(task)\"," }
        return label
    }

    /// Hand held notes to the model in a quiet moment: not while the user talks, and
    /// not right after, when the model is about to answer them
    private func deliverNotes() {
        guard !pendingNotes.isEmpty, !endRequested, !userSpeaking, !responseActive, toolsRunning == 0,
              !(audio?.isPlaying ?? false), Date().timeIntervalSince(lastActivity) > 2 else { return }
        let notes = pendingNotes
        pendingNotes = []
        notes.forEach { append(.system, $0) }
        say("[Clauntty: \(notes.joined(separator: " "))]")
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
            let output = await perform(name, args)
            finishTool(callId: callId, output: output)
        }
    }

    private func perform(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        let output: [String: Any]
        switch name {
        case "list_tabs":
            append(.tool, "listed tabs")
            output = ["tabs": listTabs()]
        case "read_tab":
            output = await readTab(args)
        case "search_tab":
            output = await searchTab(args)
        case "read_turn":
            output = await readTurn(args)
        case "send_prompt":
            output = await sendPrompt(args)
        case "press_keys":
            output = await pressKeys(args)
        case "run_command":
            output = await runCommand(args)
        case "show_tab":
            output = await showTab(args)
        case "end_session":
            endRequested = true
            output = ["ok": true]
            scheduleHangUpFallback()
        default:
            output = ["error": "Unknown tool \(name)"]
        }
        return output
    }

    #if DEBUG
    /// Run one tool with no session (the `clauntty://voice-tool` URL), to try the tools
    /// against a host without calling xAI. Returns the result as JSON.
    func debugTool(_ name: String, arguments: String, sessionManager: SessionManager) async -> String {
        self.sessionManager = sessionManager
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        var output: [String: Any]
        if name == "watch" {
            // The notes the panes' changes since the last call would give the model
            watchPanes()
            output = ["notes": pendingNotes]
            pendingNotes = []
        } else {
            output = await perform(name, args)
        }
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    #endif

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

    /// Terminal tabs (workspaces) in the app's order, numbered from 1, with their panes
    private func voiceTabs() -> [(tab: VoiceTab, session: Session)] {
        guard let sessionManager else { return [] }
        var result: [(VoiceTab, Session)] = []
        for item in sessionManager.orderedTabs() {
            guard case .terminal(let session) = item else { continue }
            let config = session.connectionConfig
            let group = sessionManager.sessionGroup(for: session)
            let panes = group?.panes ?? []
            let shown = panes.firstIndex { $0.id == group?.activePaneId } ?? 0
            var title = group?.title ?? session.title
            // A workspace named after a folder: what runs in its pane says more
            if title.isEmpty || title == "~" || title.hasPrefix("/"), panes.indices.contains(shown) {
                title = panes[shown].title
            }
            var tab = VoiceTab(number: result.count + 1, title: title, name: config.name, host: "\(config.username)@\(config.host)")
            if !panes.isEmpty {
                tab.panes = panes.enumerated().map { VoicePane(number: $0 + 1, id: $1.id, title: $1.title) }
                tab.shownPane = shown
            } else if let id = session.rtachSessionId {
                tab.panes = [VoicePane(number: 1, id: id, title: session.title)]
            }
            result.append((tab, session))
        }
        return result
    }

    /// The session for one of a tab's panes: made, disconnected, if the app hasn't
    /// shown that pane yet
    private func paneSession(_ tab: VoiceTab, pane index: Int, shown: Session) -> Session {
        guard let sessionManager, let group = sessionManager.sessionGroup(for: shown),
              tab.panes.indices.contains(index) else { return shown }
        return sessionManager.paneSession(for: group, paneId: tab.panes[index].id, config: shown.connectionConfig) ?? shown
    }

    /// Every tab and its panes: what each runs and how its agent is doing, from rtach's
    /// pane states (nothing is asked of the machines)
    private func listTabs() -> [[String: Any]] {
        let activeId = sessionManager?.activeSession?.id
        return voiceTabs().map { tab, session in
            var entry: [String: Any] = [
                "tab": tab.number,
                "title": tab.title,
                "machine": tab.name.isEmpty ? tab.host : "\(tab.name) (\(tab.host))",
                "on_screen": session.id == activeId,
            ]
            if session.state != .connected {
                entry["state"] = "\(session.stateDescription); read_tab connects it"
            }
            entry["panes"] = tab.panes.map { paneEntry($0, in: tab) }
            return entry
        }
    }

    /// A pane for the model: what it runs, and an agent's status and last prompt
    private func paneEntry(_ pane: VoicePane, in tab: VoiceTab) -> [String: Any] {
        var entry: [String: Any] = ["pane": pane.number, "title": pane.title]
        if tab.panes.count > 1 && pane.number - 1 == tab.shownPane {
            entry["showing"] = true
        }
        guard let state = sessionManager?.paneStates[pane.id] else { return entry }
        if state.hasAgent {
            entry["runs"] = state.agent == "claude" ? "Claude Code" : state.agent
            entry["status"] = Self.statusText(state)
            if let task = state.task, !task.isEmpty { entry["last_prompt"] = task }
        } else {
            entry["runs"] = state.fg.flatMap { $0.isEmpty ? nil : $0 } ?? "a shell"
        }
        return entry
    }

    /// An agent's state in words, from rtach (which knows about menus)
    private static func statusText(_ state: RemotePaneState) -> String {
        switch state.state {
        case "working": return "working"
        case "blocked": return "waiting for the user at a menu or question" + (state.note.map { ": \($0)" } ?? "")
        case "done", "idle": return "idle: finished its turn, waiting for the user"
        default: return state.state ?? "unknown"
        }
    }

    /// Panes with an agent in them
    private func agentPanes(_ tab: VoiceTab) -> [VoicePane] {
        tab.panes.filter { sessionManager?.paneStates[$0.id]?.hasAgent == true }
    }

    /// For a Claude conversation: an outline of recent turns, the latest turn in full
    /// and the bottom of its screen. For a plain terminal: what it printed since the
    /// last read.
    private func readTab(_ args: [String: Any]) async -> [String: Any] {
        let target: Target
        switch await resolveTarget(args) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }
        append(.tool, "read \(target.title)")

        guard let agent = target.agent else {
            return readPlain(target)
        }
        guard let transcript = await transcript(for: agent, in: target.session) else {
            return target.ids.merging(["error": "Couldn't read the Claude conversation's history"]) { $1 }
        }
        var output = target.ids
        output["claude"] = describe(agent, in: target)
        if target.tab.panes.count > 1 && args["pane"] == nil {
            output["other_panes"] = target.tab.panes.filter { $0 != target.pane }.map { "\($0.number): \($0.title)" }
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
        output["screen_bottom"] = screenBottom(target.session)
        return output
    }

    /// What a plain terminal printed since the model last read it
    private func readPlain(_ target: Target) -> [String: Any] {
        let session = target.session
        var output = target.ids
        output["title"] = target.title
        guard let whole = session.readTerminalText?(true) else {
            output["error"] = "The pane's terminal isn't ready yet"
            return output
        }
        let lines = TerminalTextCleaner.clean(TerminalStyledText.markup(whole))
        output["waiting_for_input"] = session.isWaitingForInput
        let diff = TerminalTextDiff.newLines(previous: snapshots[session.id], current: lines)
        switch diff.kind {
        case .first: output["note"] = "First read of this pane: its most recent lines"
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
        guard case .success(let (target, transcript)) = found else {
            if case .failure(let error) = found { return error.output }
            return [:]
        }
        append(.tool, "searched \(target.title) for \"\(query)\"")
        let result = transcript.search(query)
        var output = target.ids
        output["total_turns"] = transcript.turns.count
        output["matches"] = result.hits.map { "Turn \($0.turn), \($0.who): \($0.snippet)" }
        if result.total > result.hits.count {
            output["note"] = "Showing the newest \(result.hits.count) of \(result.total) matches"
        } else if result.hits.isEmpty {
            output["note"] = "No matches"
        }
        return output
    }

    private func readTurn(_ args: [String: Any]) async -> [String: Any] {
        let found = await conversation(args)
        guard case .success(let (target, transcript)) = found else {
            if case .failure(let error) = found { return error.output }
            return [:]
        }
        let requested = args["turn"] as? Int ?? Int(args["turn"] as? String ?? "") ?? transcript.turns.count
        guard let text = transcript.render(turn: requested - 1) else {
            return target.ids.merging(["error": "No turn \(requested); the conversation has \(transcript.turns.count)"]) { $1 }
        }
        append(.tool, "read turn \(requested) of \(target.title)")
        return target.ids.merging(["turn": text]) { $1 }
    }

    // MARK: - Acting

    private func sendPrompt(_ args: [String: Any]) async -> [String: Any] {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["error": "Give the text to send"] }
        // The model has issued the same send twice in one reply, to different targets
        let key = text.lowercased()
        guard !promptsThisResponse.contains(key) else {
            return ["error": "Not sent: you already sent this text in this reply. Send each message once."]
        }
        promptsThisResponse.insert(key)
        let target: Target
        switch await resolveTarget(args, fresh: true, acting: true, wantsAgent: true) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }
        guard let agent = target.agent else {
            return target.ids.merging(["error": "No Claude runs in this pane. For a shell command, use run_command."]) { $1 }
        }
        let state = sessionManager?.paneStates[target.pane.id]
        if state?.state == "blocked" {
            return target.ids.merging(["error": "Nothing was sent: Claude is waiting at a menu or question. Read the pane and ask the user how to answer it."]) { $1 }
        }

        target.session.sendData(Data(VoiceKeys.paste(text).utf8))
        try? await Task.sleep(for: .milliseconds(150))
        target.session.sendData(Data("\r".utf8))
        append(.tool, "sent to \(target.title): \(text)")

        var output = await stateAfterAction(target)
        output["sent"] = text
        if agent.status == "busy" || state?.state == "working" {
            // Claude Code holds prompts typed mid-turn until the turn ends
            output["note"] = "Claude was already working, so this prompt is queued and runs when it finishes"
        }
        return output
    }

    private func pressKeys(_ args: [String: Any]) async -> [String: Any] {
        let input = (args["keys"] as? [String])?.joined(separator: " ") ?? args["keys"] as? String ?? ""
        let keys: [String]
        switch VoiceKeys.parse(input) {
        case .success(let parsed) where !parsed.isEmpty && parsed.count <= 10:
            keys = parsed
        case .failure(let unknown):
            return ["error": "Unknown key \"\(unknown.name)\". Keys: 0-9, y, n, enter, esc, up, down, left, right, tab, shift+tab, space, backspace, ctrl+c"]
        default:
            return ["error": "Give one to ten keys, e.g. \"1\" or \"down enter\""]
        }
        let target: Target
        switch await resolveTarget(args, fresh: true, acting: true) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }

        for key in keys {
            target.session.sendData(Data((VoiceKeys.bytes[key] ?? "").utf8))
            try? await Task.sleep(for: .milliseconds(80))
        }
        append(.tool, "pressed \(keys.joined(separator: " ")) in \(target.title)")
        var output = await stateAfterAction(target, settle: .milliseconds(700))
        output["pressed"] = keys.joined(separator: " ")
        return output
    }

    private func runCommand(_ args: [String: Any]) async -> [String: Any] {
        let command = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains("\n") else { return ["error": "Give one command on one line"] }
        let target: Target
        switch await resolveTarget(args, fresh: true) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }
        guard target.agent == nil else {
            return target.ids.merging(["error": "This pane runs Claude; use send_prompt to ask Claude instead"]) { $1 }
        }
        // Enforced here as well as in the instructions: the user hears the command first
        let confirmed = args["confirmed"] as? Bool ?? (args["confirmed"] as? String == "true")
        guard confirmed else {
            return target.ids.merging(["error": "Not run. Read the command back to the user, and call again with confirmed true only after they say yes."]) { $1 }
        }

        // Start from what's there now, so the result is the command's output
        if let whole = target.session.readTerminalText?(true) {
            snapshots[target.session.id] = TerminalTextCleaner.clean(TerminalStyledText.markup(whole))
        }
        target.session.sendData(Data((command + "\r").utf8))
        append(.tool, "ran in \(target.title): \(command)")
        try? await Task.sleep(for: .milliseconds(300))
        await waitForQuietOutput(target.session, settleAfterConnect: true)
        var output = readPlain(target)
        output["ran"] = command
        return output
    }

    private func showTab(_ args: [String: Any]) async -> [String: Any] {
        let target: Target
        switch await resolveTarget(args) {
        case .success(let found): target = found
        case .failure(let error): return error.output
        }
        if let groupId = target.session.groupId {
            sessionManager?.selectPane(groupId: groupId, paneId: target.pane.id)
        }
        sessionManager?.switchTo(target.session)
        append(.tool, "showed \(target.title)")
        return target.ids.merging(["showing": target.title]) { $1 }
    }

    /// The pane's status and screen a moment after an action, so the model can say
    /// what happened rather than assume
    private func stateAfterAction(_ target: Target, settle: Duration = .milliseconds(1200)) async -> [String: Any] {
        // A pane that isn't shown has its output paused: let it through meanwhile, so its
        // screen is the one after the action
        let session = target.session
        let wasPaused = session.isPaused
        if wasPaused { session.resumeOutput() }
        try? await Task.sleep(for: settle)
        if wasPaused && sessionManager?.activeSession?.id != session.id {
            session.pauseOutput()
        }
        agentCache[target.session.id] = nil
        var output = target.ids
        if let agent = target.agent {
            transcriptCache[agent.sessionId] = nil
            let now = await scan(in: target.session, fresh: true)?.agents.first { $0.pid == agent.pid }
            output["claude"] = describe(now ?? agent, in: target)
        }
        output["screen_bottom"] = screenBottom(target.session)
        return output
    }

    // MARK: - Tool helpers

    private struct ToolError: Error {
        let output: [String: Any]
        init(_ output: [String: Any]) { self.output = output }
    }

    /// What a tool call points at: a tab's pane, connected, with the Claude running in
    /// it (nil for a shell)
    private struct Target {
        let tab: VoiceTab
        let pane: VoicePane
        let session: Session
        let agent: ClaudeAgent?

        /// For the panel log
        var title: String { pane.title }
        /// Where, for tool results: the tab, and the pane when it has several
        var ids: [String: Any] {
            tab.panes.count > 1 ? ["tab": tab.number, "pane": pane.number] : ["tab": tab.number]
        }
    }

    /// The pane a tool call means: its `tab` (else the one on screen) and `pane` (else
    /// the one the tab shows; for a tool that needs Claude, `wantsAgent`, the tab's only
    /// agent when the shown pane has none). `acting` (sending, pressing keys) in a tab
    /// named by the model that has several agents: the pane must be named too, not guessed.
    private func resolveTarget(_ args: [String: Any], fresh: Bool = false, acting: Bool = false,
                               wantsAgent: Bool = false) async -> Result<Target, ToolError> {
        let query = (args["tab"] as? Int).map(String.init) ?? args["tab"] as? String ?? ""
        let paneQuery = ((args["pane"] as? Int).map(String.init) ?? args["pane"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let tabs = voiceTabs()
        let index: Int
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let active = sessionManager?.activeSession,
                  let found = tabs.firstIndex(where: { $0.session.id == active.id || (active.groupId != nil && $0.session.groupId == active.groupId) }) else {
                return .failure(ToolError(["error": "No terminal tab is on screen; say which tab"]))
            }
            index = found
        } else {
            switch VoiceTabResolver.resolve(query, in: tabs.map(\.tab)) {
            case .found(let found):
                index = found
            case .notFound:
                return .failure(ToolError(["error": "No tab matches \"\(query)\". Call list_tabs to see them."]))
            case .ambiguous(let indices):
                return .failure(ToolError(["error": "\"\(query)\" matches several tabs", "matches": indices.map { "\(tabs[$0].tab.number): \(tabs[$0].tab.title)" }]))
            }
        }
        let (tab, shown) = tabs[index]

        let paneIndex: Int
        if paneQuery.isEmpty {
            // A guess here types into the wrong agent
            if acting, !query.isEmpty, agentPanes(tab).count > 1 {
                return .failure(ToolError([
                    "tab": tab.number,
                    "error": "Nothing was done: this tab has \(agentPanes(tab).count) agents. Call again with pane set to the one you mean.",
                    "panes": tab.panes.map { paneEntry($0, in: tab) },
                ]))
            }
            let agents = agentPanes(tab)
            if wantsAgent, tab.panes.indices.contains(tab.shownPane), !agents.contains(tab.panes[tab.shownPane]),
               agents.count == 1, let only = tab.panes.firstIndex(of: agents[0]) {
                paneIndex = only
            } else {
                paneIndex = tab.shownPane
            }
        } else {
            guard let found = VoicePaneResolver.resolve(paneQuery, in: tab.panes) else {
                return .failure(ToolError([
                    "tab": tab.number,
                    "error": "No single pane matches \"\(paneQuery)\"",
                    "panes": tab.panes.map { paneEntry($0, in: tab) },
                ]))
            }
            paneIndex = found
        }
        let pane = tab.panes.indices.contains(paneIndex) ? tab.panes[paneIndex] : VoicePane(number: 1, id: "", title: tab.title)
        let session = paneSession(tab, pane: paneIndex, shown: shown)
        lookingAt = session.id

        if let problem = await makeLive(session) {
            return .failure(ToolError(["tab": tab.number, "title": pane.title, "error": problem]))
        }
        guard let scan = await scan(in: session, fresh: fresh) else {
            return .failure(ToolError(["tab": tab.number, "error": "Couldn't check the pane for Claude"]))
        }
        return .success(Target(tab: tab, pane: pane, session: session, agent: scan.agents.last))
    }

    /// The conversation and its history, for search_tab and read_turn
    private func conversation(_ args: [String: Any]) async -> Result<(Target, ClaudeTranscript), ToolError> {
        let target: Target
        switch await resolveTarget(args, wantsAgent: true) {
        case .success(let found): target = found
        case .failure(let error): return .failure(error)
        }
        guard let agent = target.agent else {
            return .failure(ToolError(target.ids.merging(["error": "No Claude runs in this pane; use read_tab"]) { $1 }))
        }
        guard let transcript = await transcript(for: agent, in: target.session) else {
            return .failure(ToolError(target.ids.merging(["error": "Couldn't read the Claude conversation's history"]) { $1 }))
        }
        return .success((target, transcript))
    }

    /// A pane's Claude for the model: its conversation's title, status and directory
    private func describe(_ agent: ClaudeAgent, in target: Target) -> [String: Any] {
        let state = sessionManager?.paneStates[target.pane.id]
        return [
            "title": agent.title ?? "untitled (new, or nothing asked yet)",
            "status": state.flatMap { $0.hasAgent ? Self.statusText($0) : nil } ?? agent.statusText,
            "directory": agent.shortDirectory,
        ]
    }

    /// The Claude running in a pane, or nil if the machine couldn't be asked
    private func scan(in session: Session, fresh: Bool = false) async -> ClaudeScan? {
        if !fresh, let cached = agentCache[session.id], Date().timeIntervalSince(cached.at) < 5 {
            return cached.scan
        }
        guard let id = session.rtachSessionId else { return ClaudeScan() }
        guard let script = ClaudeScripts.find(rtachSessionId: id),
              let output = await runScript(script, in: session) else { return nil }
        let scan = ClaudeScripts.parse(output)
        agentCache[session.id] = (Date(), scan)
        return scan
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

    /// Run a script on the pane's machine, over its host's connection, giving up after
    /// `timeout` seconds
    private func runScript(_ script: String, in session: Session, timeout: Double = 6, quiet: Bool = false) async -> String? {
        final class Once {
            var done = false
        }
        let once = Once()
        let started = Date()
        let config = session.connectionConfig
        let encoded = Data(script.utf8).base64EncodedString()
        let output: String? = await withCheckedContinuation { continuation in
            func finish(_ value: String?) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                do {
                    guard let sessionManager = self.sessionManager else { return finish(nil) }
                    finish(try await sessionManager.withHost(config) { try await $0.executeCommand("echo \(encoded) | base64 -d | sh") })
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
        if !quiet || output == nil {
            voiceTrace("remote script: \(output.map { "\($0.utf8.count) bytes" } ?? "no output") in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        return output
    }

    /// The bottom of a pane's screen: a question, menu or suggestion it's showing
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
    Code, an AI coding agent, in their terminal tabs on remote machines. A tab can be split \
    into panes, each running a shell or a Claude. You're on the user's side of those \
    conversations: you help them keep track of what each Claude is doing, what it's asking \
    them, and what they might tell it next, while they're away from the keyboard. You \
    are Clauntty's voice assistant: if a conversation is about Clauntty's voice agent, \
    it's about you, and a test the user mentions may well be a test of you.

    - Keep replies short: one or two spoken sentences. No lists or markdown. Never read out \
    code, long paths, IDs or raw output; summarize instead.
    - Be quick. When the user asks what's on screen, what they're working on, or what \
    Claude is doing, call read_tab straight away with no arguments (that's the tab and \
    pane on screen), without calling list_tabs first.
    - Answer with the work itself, in one sentence: what the user and Claude are working \
    on right now and where it stands, e.g. "You're testing voice prompts; Claude got \
    yours and is waiting for the results." Take it from the latest turns. Don't lead \
    with tab numbers, titles or directories: titles are set early and are often out of \
    date. Mention them only to tell conversations apart, and never for the \
    conversation on screen.
    - When asked what to reply or what to do next, think it through from what the user \
    and Claude are actually doing. Claude Code's dim suggested prompt is only its guess \
    at the user's next message and is often wrong; don't recommend it just because it's \
    there.
    - Call list_tabs when the user asks about other tabs or agents, or which ones need \
    them. It lists each tab's panes with what they run, and each agent's status and the \
    user's last prompt to it, so it often answers "what needs me" without reading more. \
    In a tab with several panes, showing marks the one it shows; tools without pane use \
    that one.
    - Before saying what a conversation did or asked, or giving advice, read it with \
    read_tab. Read only the conversations the question is about, not all of them.
    - For anything older or more detailed, look it up instead of guessing: search_tab \
    finds turns that mention something, read_turn reads one turn in full. If you still \
    can't find it, say you don't know.
    - A turn is one prompt from the user and everything Claude did for it. Claude's tool calls \
    are listed by what they did, not their full output.
    - In screen text, [dim]...[/dim] is greyed-out text: placeholders, suggestions and \
    hints, not something the user typed. In Claude Code, a dim prompt after the ❯ is a \
    suggested prompt and the input box is otherwise empty. [strike]...[/strike] is \
    crossed-out text, usually a finished item.
    - Refer to tabs and panes by title, or by number if titles are unclear.

    Acting for the user:
    - Act only when the user asks. Never send a prompt, answer a menu or press keys on \
    your own initiative, even when the next step seems obvious; suggest it instead.
    - Send each message once, to one pane: one send_prompt call, never two for the same \
    message. When you name a tab that has several agents, name the pane too, by its \
    number from read_tab or list_tabs.
    - Everything the user says is said to you, not to Claude. Call send_prompt only \
    when they explicitly ask you to pass something on: "tell it...", "send...", \
    "reply...", "ask it...", "say to Claude...". A remark that sounds like an answer \
    to Claude's question ("I still need to run that migration") is them talking to \
    you; if it seems meant for Claude, ask "Want me to send that?" and wait.
    - send_prompt types a prompt into a pane's Claude and submits it. Send the \
    user's words as they said them, minus filler like "um", without asking first, then \
    say briefly what you sent. When the user asks indirectly ("tell it that...", "ask \
    it to..."), write the message as the user would type it to Claude, turning the \
    pronouns around: "I" and "me" mean the user, "you" means you, the voice \
    assistant, and "it" or "Claude" means Claude, so it becomes "you". So "tell \
    Claude I'm heading out" becomes "I'm heading out", "ask it to run the tests" \
    becomes "Run the tests", "ask Claude how it would fix the title" becomes "How \
    would you fix the title?", and "tell it you're testing it" becomes "The voice \
    assistant is testing this right now". Claude hasn't heard your conversation with \
    the user, so when their words point at something only the two of you know about \
    ("this issue", "what we just talked about", "that error"), spell it out so the \
    message makes sense on its own: "tell it to check the logs for this issue" becomes \
    "Check the voice log: my 'commit it' was sent to two conversations and the wrong \
    one committed". Say what you sent. If you wrote the text yourself (the user said "tell it \
    what you think" or similar), read it back first and send it only after they agree.
    - Claude's menus and questions (a permission prompt, a numbered choice) are answered \
    with press_keys, usually a number, or enter on the highlighted option. Read the \
    screen first. Before approving a permission prompt, say in a few words what it \
    allows, unless the user already told you what to answer. esc stops Claude mid-turn \
    and is always fine when the user asks.
    - run_command runs a command in a plain shell pane. Always read the command back and \
    wait for a yes before calling it with confirmed true.
    - show_tab puts a tab, or a pane in it, on the phone's screen.
    - Each action returns the pane's status and screen a moment later. Say what \
    happened from that, e.g. that Claude started working or is asking something.

    - Messages in [Clauntty: ...] come from the app, not the user. When one says an \
    agent finished its turn or is waiting at a menu, tell the user in a few \
    words which one (by what it's working on, if you know) and offer to read it. Don't \
    read it unless they ask. If the user is busy with something else, keep it to one \
    short sentence.
    - When the user says goodbye or asks you to hang up, say a brief goodbye and call end_session.
    - Sessions end after 30 minutes.
    """

    private static let tabParameter: [String: Any] = [
        "type": "string",
        "description": "Tab number from list_tabs, or part of its title, e.g. \"2\" or \"devbox\". Leave it out for the tab on screen.",
    ]
    private static let paneParameter: [String: Any] = [
        "type": "string",
        "description": "Which pane of the tab: its number from list_tabs, or part of its title. Leave it out for the pane the tab shows.",
    ]

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "name": "list_tabs",
            "description": "List the terminal tabs: number, title, machine, which one is on screen, and their panes: what each runs, and for a Claude its status (working, finished, waiting at a menu) and the user's last prompt to it.",
            "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()] as [String: Any],
        ],
        [
            "type": "function",
            "name": "read_tab",
            "description": "Catch up on a pane; with no arguments, the one on screen. For a Claude: the last few turns of its conversation in brief, the latest turn in full, and the bottom of the screen. For a plain terminal: what it printed since you last read it. Connects the pane first if needed.",
            "parameters": [
                "type": "object",
                "properties": ["tab": tabParameter, "pane": paneParameter] as [String: Any],
                "required": [String](),
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
                    "pane": paneParameter,
                ] as [String: Any],
                "required": ["query"],
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
                    "pane": paneParameter,
                ] as [String: Any],
                "required": ["turn"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "send_prompt",
            "description": "Type a prompt into a pane's Claude and submit it. Fails without sending if Claude is waiting at a menu or question; answer that with press_keys first. Returns the pane's status and screen afterwards.",
            "parameters": [
                "type": "object",
                "properties": [
                    "tab": tabParameter,
                    "text": ["type": "string", "description": "The prompt, in the user's words"],
                    "pane": paneParameter,
                ] as [String: Any],
                "required": ["text"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "press_keys",
            "description": "Press keys in a pane, e.g. to answer Claude's menus and permission prompts or to stop it (esc). Returns the status and screen afterwards.",
            "parameters": [
                "type": "object",
                "properties": [
                    "tab": tabParameter,
                    "keys": ["type": "string", "description": "Space-separated keys, pressed in order: 0-9, y, n, enter, esc, up, down, left, right, tab, shift+tab, space, backspace, ctrl+c. E.g. \"1\" or \"down enter\"."],
                    "pane": paneParameter,
                ] as [String: Any],
                "required": ["keys"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "run_command",
            "description": "Run a shell command in a plain terminal pane (not a Claude) and return its output. Only after reading the command back to the user and hearing yes.",
            "parameters": [
                "type": "object",
                "properties": [
                    "tab": tabParameter,
                    "command": ["type": "string", "description": "One command, on one line"],
                    "confirmed": ["type": "boolean", "description": "True only once the user has heard the command and said yes"],
                ] as [String: Any],
                "required": ["tab", "command", "confirmed"],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": "show_tab",
            "description": "Put a tab, or one of its panes, on the phone's screen.",
            "parameters": [
                "type": "object",
                "properties": ["tab": tabParameter, "pane": paneParameter] as [String: Any],
                "required": [String](),
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
