import SwiftUI

/// The Settings window (Cmd+,): the keys, the terminals' look, chimes and banners.
struct MacSettings: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .frame(height: 150)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .frame(height: 560)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            SoundSettings()
                .frame(height: 300)
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            NotificationSettings()
                .frame(height: 300)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PaneCommands.numberKeysKey) private var numberKeys = PaneCommands.NumberKeys.workspace

    var body: some View {
        Form {
            Picker("⌘1 to ⌘9 go to", selection: $numberKeys) {
                Text("Workspaces").tag(PaneCommands.NumberKeys.workspace)
                Text("Panes").tag(PaneCommands.NumberKeys.pane)
            }
            .pickerStyle(.radioGroup)
            Text(numberKeys == .workspace
                 ? "The nth workspace in the sidebar, on the pane it last showed."
                 : "The nth pane, counting every workspace's panes in sidebar order.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @EnvironmentObject private var ghostty: MacGhosttyApp
    @ObservedObject private var themes = ThemeManager.shared
    @State private var fontSize: Float = 13

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Font") {
                    LabeledContent("Size") {
                        HStack {
                            Text("\(Int(fontSize)) pt")
                                .monospacedDigit()
                            Stepper("Size", value: $fontSize, in: TerminalViews.fontSizes, step: 1)
                                .labelsHidden()
                        }
                    }
                    .onChange(of: fontSize) { _, size in
                        guard let views = ghostty.terminalViews, size != views.effectiveFontSize else { return }
                        views.setFontSize(size)
                    }
                }
                ThemeRows(title: "Dark Themes", themes: themes.darkThemes, selected: ghostty.theme) { ghostty.setTheme($0) }
                ThemeRows(title: "Light Themes", themes: themes.lightThemes, selected: ghostty.theme) { ghostty.setTheme($0) }
            }
            .formStyle(.grouped)
            .onAppear {
                fontSize = ghostty.terminalViews?.effectiveFontSize ?? 13
                proxy.scrollTo(ghostty.theme?.id, anchor: .center)
            }
        }
    }
}

private struct ThemeRows: View {
    let title: String
    let themes: [Theme]
    let selected: Theme?
    let pick: (Theme) -> Void

    var body: some View {
        Section(title) {
            ForEach(themes) { theme in
                Button { pick(theme) } label: {
                    HStack(spacing: 10) {
                        // What a terminal in it looks like
                        Text("Aa")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.foregroundColor)
                            .frame(width: 32, height: 20)
                            .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        Text(theme.name)
                        Spacer()
                        if theme.id == selected?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(theme.id)
            }
        }
    }
}

private struct SoundSettings: View {
    @AppStorage(MacNotifications.chimeKey) private var chimes = true
    @AppStorage(MacNotifications.doneChimeKey) private var doneChime = true
    @AppStorage(MacNotifications.needsYouChimeKey) private var needsYouChime = true
    @AppStorage(MacNotifications.chimeVolumeKey) private var volume: Double = 1

    var body: some View {
        Form {
            Section {
                Toggle("Play chimes", isOn: $chimes)
            } footer: {
                Text("Played by the app, so they're heard with notifications off or a Focus on.")
            }
            Section {
                chime("When an agent finishes", isOn: $doneChime, needsYou: false)
                chime("When an agent needs you", isOn: $needsYouChime, needsYou: true)
                LabeledContent("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1) { editing in
                            // Hear it where you let go
                            if !editing { MacNotifications.shared.playChime(needsYou: false) }
                        }
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!chimes)
        }
        .formStyle(.grouped)
    }

    private func chime(_ title: String, isOn: Binding<Bool>, needsYou: Bool) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Button {
                MacNotifications.shared.playChime(needsYou: needsYou)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Play it")
        }
    }
}

private struct NotificationSettings: View {
    @AppStorage(MacNotifications.bannersKey) private var banners = true
    /// nil until macOS has said
    @State private var allowed: Bool?

    var body: some View {
        Form {
            Section {
                Toggle("Show banners", isOn: $banners)
            } footer: {
                Text("For an agent that finishes or needs you in a pane that isn't on screen. Clicking one goes to the pane.")
            }
            Section {
                LabeledContent("macOS") {
                    switch allowed {
                    case true?:
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case false?:
                        Label("Not allowed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    case nil:
                        ProgressView().controlSize(.small)
                    }
                }
                Button("Open Notification Settings…") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Banners also follow macOS's notification settings and Focus.")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        // Back from System Settings
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        allowed = await MacNotifications.shared.bannersAllowed()
    }
}
