import SwiftUI

// MARK: - Session Panel

/// Drops down from the voice pill: state, time left, cost, the recent conversation
/// and an End button. After a session it shows how it ended and what it cost.
struct VoicePanelView: View {
    @ObservedObject var agent = VoiceAgent.shared

    private var stateText: String {
        switch agent.phase {
        case .idle: return "Voice agent"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(agent.isActive ? .green : .secondary)
                Text(stateText)
                    .font(.headline)
                Spacer()
                if agent.isActive {
                    Text("\(voiceClockText(agent.remaining)) left")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if agent.isActive {
                costLine(agent.cost)
            } else if let last = agent.lastSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last session: \(last.cost.dollarsText) · \(last.cost.breakdownText)")
                        .font(.subheadline.monospacedDigit())
                    Text(last.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !agent.log.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agent.log.suffix(6)) { entry in
                        VoiceLogRow(entry: entry, limited: true)
                    }
                }
                .padding(.top, 2)
            }

            if agent.isActive {
                Button(role: .destructive) {
                    agent.end(reason: "Ended")
                } label: {
                    Text("End")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 4)
            }
        }
        .padding(16)
        // Opaque: terminal text behind a material made it hard to read
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 8)
    }

    private func costLine(_ cost: VoiceCost) -> some View {
        Text("~\(cost.dollarsText) · \(cost.breakdownText)")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// A line of the conversation: what you said, what Grok said, what it did, or a note
struct VoiceLogRow: View {
    let entry: VoiceAgent.LogEntry
    /// A few lines each, in the drop-down panel
    var limited = false

    var body: some View {
        switch entry.kind {
        case .user:
            (Text("You  ").bold() + Text(entry.text))
                .font(.subheadline)
                .lineLimit(limited ? 3 : nil)
        case .agent:
            (Text("Grok  ").bold() + Text(entry.text))
                .font(.subheadline)
                .lineLimit(limited ? 4 : nil)
        case .tool:
            Text("· \(entry.text)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(limited ? 1 : 2)
        case .system:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.orange)
                .lineLimit(limited ? 2 : nil)
        }
    }
}

// MARK: - Settings

/// The Voice Agent section, shared by Settings and the sheet the voice button opens
/// when no key is set
struct VoiceSettingsSection: View {
    @ObservedObject var agent = VoiceAgent.shared
    @AppStorage(VoiceSettings.voiceKey) private var voice = VoiceSettings.defaultVoice
    @AppStorage(VoiceSettings.reasoningKey) private var reasoning = VoiceSettings.defaultReasoning
    @AppStorage(VoiceSettings.idleHangUpKey) private var idleHangUp = true

    @State private var hasKey = VoiceSettings.hasAPIKey
    @State private var keyInput = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        Section {
            if hasKey {
                HStack {
                    Text("xAI API Key")
                    Spacer()
                    Text("Saved")
                        .foregroundColor(.secondary)
                }
                Button(testing ? "Testing…" : "Test Key") {
                    test()
                }
                .disabled(testing)
                Button("Remove Key", role: .destructive) {
                    VoiceSettings.removeAPIKey()
                    hasKey = false
                    testResult = nil
                }
            } else {
                SecureField("xAI API key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                Button("Save Key", action: save)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let testResult {
                Text(testResult.message)
                    .font(.footnote)
                    .foregroundColor(testResult.ok ? .green : .red)
            }

            Picker("Voice", selection: $voice) {
                ForEach(VoiceSettings.voices, id: \.self) { voice in
                    Text(voice.capitalized).tag(voice)
                }
            }

            Picker("Reasoning", selection: $reasoning) {
                Text("Thorough").tag("high")
                Text("Fast").tag("none")
            }

            Toggle("Hang Up After 3 Min of Silence", isOn: $idleHangUp)

            if let last = agent.lastSession {
                HStack {
                    Text("Last Session")
                    Spacer()
                    Text("\(last.cost.dollarsText) · \(last.cost.breakdownText)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Voice Agent")
        } footer: {
            Text("Talk to Grok about your tabs with the waveform button at the top left. Clauntty connects to xAI directly with your key. Sessions end after 30 minutes; xAI charges about $0.08 a minute.")
        }
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try VoiceSettings.setAPIKey(key)
            keyInput = ""
            hasKey = true
            test()
        } catch {
            testResult = (false, "Couldn't save the key: \(error.localizedDescription)")
        }
    }

    private func test() {
        guard let key = VoiceSettings.apiKey else { return }
        testing = true
        testResult = nil
        Task {
            let result = await VoiceSettings.testAPIKey(key)
            testing = false
            switch result {
            case .success(let message): testResult = (true, message)
            case .failure(let error): testResult = (false, error.localizedDescription)
            }
        }
    }
}

/// Opened by the voice button when there's no API key yet
struct VoiceSettingsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                VoiceSettingsSection()
            }
            .navigationTitle("Voice Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Keep the terminal from taking the keyboard back from the key field
            appState.beginInputSuppression()
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { $0.endEditing(true) }
            NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
        }
        .onDisappear {
            appState.endInputSuppression()
        }
    }
}

// MARK: - Agent view

/// Two eyes, as the Grok bots have: where the voice agent is looking, in place of a
/// pane's status dot. They show the pane's status the way the dot does: glancing side to
/// side while it works, orange and pulsing when it needs you, closed happy when done,
/// blinking now and then otherwise.
struct VoiceEyes: View {
    let status: PaneStatus
    /// The pair's height
    var size: CGFloat = 11
    /// White whatever the status (on the agent's own button)
    var color: Color? = nil
    /// Bouncing, while the agent talks
    var speaking = false
    /// Where they look, toward the terminal: down from a pill (0, 1), left from the rail
    /// (−1, 0)
    var gaze: CGSize = .zero

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.2) {
                eye(t)
                eye(t)
            }
            // Sideways they shift that way; down they stay level with the title beside them
            .offset(x: (gaze.width + glance(t)) * size * 0.14,
                    y: speaking ? -abs(sin(t * 5)) * size * 0.06 : 0)
            .opacity(status == .blocked ? 0.75 + 0.25 * cos(t * 3) : 1)
            .frame(width: size * 1.2, height: size)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        if let color { return color }
        switch status {
        case .none: return .white
        case .idle: return .white.opacity(0.7)
        default: return Color(uiColor: status.tint)
        }
    }

    @ViewBuilder
    private func eye(_ t: TimeInterval) -> some View {
        if status == .done {
            // Closed, smiling: an arc each
            HappyEye()
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.2, lineCap: .round))
                .frame(width: size * 0.42, height: size * 0.3)
                .frame(height: size)
        } else {
            // Rounded ovals, slightly tilted: not bars (that read as a pause button)
            // Looking somewhere, they narrow and lean (the same shape whichever way)
            Ellipse()
                .fill(tint)
                .frame(width: size * 0.42 * (gaze == .zero ? 1 : 0.85),
                       height: size * (status == .blocked ? 0.8 : 0.66) * openness(t))
                .rotationEffect(.degrees(gaze == .zero ? 10 : 18))
                .frame(height: size)
        }
    }

    /// 1 open, down to nearly shut mid-blink. Every few seconds, slower while idle.
    private func openness(_ t: TimeInterval) -> CGFloat {
        guard status != .blocked, status != .working else { return 1 }
        let period: TimeInterval = status == .idle ? 5 : 3.6
        let phase = t.truncatingRemainder(dividingBy: period)
        let blink: TimeInterval = 0.16
        guard phase < blink else { return 1 }
        return max(0.12, abs(phase / blink * 2 - 1))
    }

    /// −0.6 to 0.6: looking a little left or right, held at each side as if reading,
    /// while working
    private func glance(_ t: TimeInterval) -> CGFloat {
        guard status == .working else { return 0 }
        return CGFloat(max(-1, min(1, sin(t * 1.6) * 1.8))) * 0.6
    }
}

/// How the eyes move between windows: they don't travel, they teleport. They shut and
/// shrink away where they were, and open where they land, springing a little wide
/// before they settle, over a soft flash.
extension View {
    func teleportingEyes() -> some View {
        modifier(OpenIn())
            .transition(.asymmetric(insertion: .identity,
                                    removal: .modifier(active: Shut(isOn: true), identity: Shut(isOn: false))))
    }
}

/// Eyes going: closed to short lids, shrinking to nothing (the removal runs in the
/// caller's animation)
private struct Shut: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: isOn ? 0.5 : 1, y: isOn ? 0.1 : 1)
            .opacity(isOn ? 0 : 1)
    }
}

/// Eyes arriving, a moment after the old ones shut: closed and small, then opening
/// past full and settling, over a soft flash that fades
private struct OpenIn: ViewModifier {
    @State private var open = false
    @State private var flashed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: open ? 1 : 0.5, y: open ? 1 : 0.1)
            .opacity(open ? 1 : 0)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.35), .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: 10))
                    .scaleEffect(flashed ? 1.6 : 0.4)
                    .opacity(flashed ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5).delay(0.1)) { open = true }
                withAnimation(.easeOut(duration: 0.5).delay(0.1)) { flashed = true }
            }
    }
}

/// A closed eye: an arc bowing up
private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return path
    }
}

/// While a voice session runs, in place of the voice button: the agent's eyes.
/// Tap for the conversation and End.
struct VoiceSessionButton: View {
    @ObservedObject var agent = VoiceAgent.shared
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VoiceEyes(status: agent.phase == .thinking || agent.phase == .connecting ? .working : .none,
                      size: size * 0.4, color: .white, speaking: agent.phase == .speaking)
                .frame(width: size, height: size)
                .glass(in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice session")
    }
}

/// The voice session as a sheet (agent view): how it's going, everything said so far,
/// and End. After a session, how it ended and what it cost.
struct VoiceSessionSheet: View {
    @ObservedObject var agent = VoiceAgent.shared

    private var stateText: String {
        switch agent.phase {
        case .idle: return "Voice agent"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if agent.isActive {
                    VoiceSessionButton(size: 28) {}
                        .allowsHitTesting(false)
                }
                Text(stateText)
                    .font(.headline)
                Spacer()
                if agent.isActive {
                    Text("\(voiceClockText(agent.remaining)) left")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if agent.isActive {
                Text("~\(agent.cost.dollarsText) · \(agent.cost.breakdownText)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let last = agent.lastSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(last.cost.dollarsText) · \(last.cost.breakdownText)")
                        .font(.subheadline.monospacedDigit())
                    Text(last.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(agent.log) { entry in
                            VoiceLogRow(entry: entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // The newest at the bottom, in view
                .onAppear { scroller.scrollTo(agent.log.last?.id, anchor: .bottom) }
                .onChange(of: agent.log.last?.text) { _, _ in
                    withAnimation { scroller.scrollTo(agent.log.last?.id, anchor: .bottom) }
                }
            }

            if agent.isActive {
                Button(role: .destructive) {
                    agent.end(reason: "Ended")
                } label: {
                    Text("End")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The voice session in the key bar, which grows up to hold it in place of its keys (the
/// mic's place opens it; the handle closes it). The conversation as two sides: yours on
/// the right, Grok's on the left. Of what Grok did, only actions show (a prompt sent,
/// keys pressed, a command run); its reads are where its eyes are.
struct VoiceTranscriptPanel: View {
    @ObservedObject var agent = VoiceAgent.shared
    let onClose: () -> Void

    private var status: String {
        switch agent.phase {
        case .idle:
            guard let last = agent.lastSession else { return "Ended" }
            return "\(last.reason) · \(last.cost.dollarsText)"
        case .connecting: return "Connecting"
        case .listening: return "Listening · \(voiceClockText(agent.remaining)) left"
        case .thinking: return "Thinking · \(voiceClockText(agent.remaining)) left"
        case .speaking: return "Speaking · \(voiceClockText(agent.remaining)) left"
        }
    }

    /// What's worth reading: what was said, actions, and problems
    private var entries: [VoiceAgent.LogEntry] {
        agent.log.filter { entry in
            guard entry.kind == .tool else { return true }
            return ["sent ", "pressed ", "ran "].contains { entry.text.hasPrefix($0) }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                // The newest at the bottom, in view
                .onAppear { scroller.scrollTo(agent.log.last?.id, anchor: .bottom) }
                .onChange(of: agent.log.last?.text) { _, _ in
                    withAnimation { scroller.scrollTo(entries.last?.id, anchor: .bottom) }
                }
            }
            Group {
                if agent.isActive {
                    Button("End", role: .destructive) { agent.end(reason: "Ended") }
                        .tint(.red)
                } else {
                    Button("Close", action: onClose)
                        .tint(.white)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func row(_ entry: VoiceAgent.LogEntry) -> some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .agent:
            Text(entry.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
        case .tool:
            Label(entry.text, systemImage: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        }
    }
}
