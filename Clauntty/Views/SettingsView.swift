import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var appState: AppState
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var notificationManager = NotificationManager.shared
    @ObservedObject var powerManager = PowerManager.shared
    @ObservedObject var speechManager = SpeechManager.shared
    @State private var showingDownloadConfirmation = false
    @AppStorage("sessionManagementEnabled") private var sessionManagementEnabled = true
    @State private var fontSize: Float = FontSizePreference.current
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        HStack {
                            Text("Theme")
                            Spacer()
                            Text(ghosttyApp.currentTheme?.name ?? "Default")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Stepper("", value: $fontSize, in: 6...36, step: 1)
                            .labelsHidden()
                            .onChange(of: fontSize) { _, newValue in
                                FontSizePreference.save(newValue)
                            }
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle("Session Management", isOn: $sessionManagementEnabled)
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("When enabled, terminal sessions persist on the server using rtach. Reconnecting restores your session with scrollback history.")
                }

                Section {
                    voiceInputContent
                } header: {
                    Text("Voice Input")
                } footer: {
                    Text("Speak commands instead of typing. Uses on-device speech recognition for privacy.")
                }

                Section {
                    Toggle("Battery Saver", isOn: $powerManager.batterySaverEnabled)
                } header: {
                    Text("Performance")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reduces rendering frequency to extend battery life.")
                        if powerManager.currentMode == .lowPower && !powerManager.batterySaverEnabled {
                            Text("Currently active due to low battery, thermal throttling, or iOS Low Power Mode.")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section {
                    Picker("Input notifications", selection: $notificationManager.notificationMode) {
                        ForEach(NotificationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    // Show system settings link if permission denied
                    if !notificationManager.isAuthorized && notificationManager.hasPromptedForPermission {
                        Button("Enable in Settings") {
                            openNotificationSettings()
                        }
                        .foregroundColor(.blue)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified when a terminal is waiting for your input while the app is in the background.")
                }
            }
            .navigationTitle("Settings")
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
            appState.beginInputSuppression()
            dismissTerminalInput()
        }
        .onDisappear {
            appState.endInputSuppression()
        }
    }

    @ViewBuilder
    private var voiceInputContent: some View {
        switch speechManager.modelState {
        case .notDownloaded:
            Button {
                showingDownloadConfirmation = true
            } label: {
                HStack {
                    Label("Enable Voice Input", systemImage: "mic.fill")
                    Spacer()
                    Text("~800 MB")
                        .foregroundColor(.secondary)
                }
            }
            .alert("Download Speech Model?", isPresented: $showingDownloadConfirmation) {
                Button("Download") {
                    Task {
                        await speechManager.downloadModel()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will download approximately 800 MB of data for on-device speech recognition. The model runs entirely on your device for privacy.")
            }

        case .downloading(let progress):
            HStack {
                Label("Downloading...", systemImage: "arrow.down.circle")
                Spacer()
                if progress > 0 {
                    ProgressView(value: Double(progress))
                        .frame(width: 100)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

        case .ready:
            HStack {
                Label("Voice input enabled", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Spacer()
            }
            Button("Delete Speech Model", role: .destructive) {
                speechManager.deleteModel()
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry") {
                    Task {
                        await speechManager.downloadModel()
                    }
                }
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }
}

#Preview {
    SettingsView()
        .environmentObject(GhosttyApp())
        .environmentObject(AppState())
}
