import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var notificationManager = NotificationManager.shared
    @ObservedObject var powerManager = PowerManager.shared
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
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(GhosttyApp())
}
