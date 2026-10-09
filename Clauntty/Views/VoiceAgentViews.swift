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
                        logRow(entry)
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

    @ViewBuilder
    private func logRow(_ entry: VoiceAgent.LogEntry) -> some View {
        switch entry.kind {
        case .user:
            (Text("You  ").bold() + Text(entry.text))
                .font(.subheadline)
                .lineLimit(3)
        case .agent:
            (Text("Grok  ").bold() + Text(entry.text))
                .font(.subheadline)
                .lineLimit(4)
        case .tool:
            Text("· \(entry.text)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .system:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.orange)
                .lineLimit(2)
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
            Text("Talk to Grok about your tabs with the waveform button at the top left. Clauntty connects to xAI directly with your key. Sessions end after 15 minutes; xAI charges about $0.08 a minute.")
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
