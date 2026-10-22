import AppKit
import GhosttyKit
import os.log

let macLog = Logger(subsystem: "com.clauntty.mac", category: "terminal")

/// The ghostty_app_t for the macOS app. The iOS counterpart is GhosttyApp.
@MainActor
final class MacGhosttyApp: ObservableObject {
    @Published private(set) var app: ghostty_app_t?
    /// The app's terminal views, once Ghostty is up
    @Published private(set) var terminalViews: TerminalViews?
    /// The terminals' theme (Settings > Appearance); the window's chrome follows it
    @Published private(set) var theme: Theme?
    private var config: ghostty_config_t?

    static let themeKey = "themeId"

    init() {
        // The one picked, else the phone's default dark theme, so both look alike
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap { ThemeManager.shared.theme(withId: $0) }
            ?? ThemeManager.shared.defaultTheme(dark: true)
        guard let cfg = Self.makeConfig(theme) else {
            macLog.error("ghostty_config_new failed")
            return
        }
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in MacGhosttyApp.wakeup(userdata) },
            action_cb: { _, target, action in MacGhosttyApp.action(target: target, action: action) },
            // The userdata of these is the surface's: MacTerminalView handles them
            read_clipboard_cb: { userdata, _, state, mimes, mimesLen, list in
                MacTerminalView.readClipboard(userdata, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                MacTerminalView.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, _, content, len, _ in MacGhosttyApp.writeClipboard(content, len) },
            close_surface_cb: { _, _ in }
        )
        guard let app = ghostty_app_new(&runtime, cfg) else {
            macLog.error("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_color_scheme(app, theme?.isLight == true ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
        terminalViews = TerminalViews(app: app)
    }

    private static func makeConfig(_ theme: Theme?) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if let theme { ThemeManager.shared.applyTheme(theme, to: cfg) }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Every pane takes the theme at once, and it's remembered
    func setTheme(_ theme: Theme) {
        guard let app, let cfg = Self.makeConfig(theme) else { return }
        ghostty_app_update_config(app, cfg)
        ghostty_app_set_color_scheme(app, theme.isLight ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
        if let old = config { ghostty_config_free(old) }
        config = cfg
        self.theme = theme
        UserDefaults.standard.set(theme.id, forKey: Self.themeKey)
    }

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        DispatchQueue.main.async {
            let me = Unmanaged<MacGhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            if let app = me.app { ghostty_app_tick(app) }
        }
    }

    nonisolated static func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            return true
        default:
            return false
        }
    }

    nonisolated static func writeClipboard(_ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int) {
        guard let content else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}
