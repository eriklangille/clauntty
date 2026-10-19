import AppKit
import GhosttyKit
import os.log

let macLog = Logger(subsystem: "com.clauntty.mac", category: "terminal")

/// The ghostty_app_t for the macOS app. The iOS counterpart is GhosttyApp.
@MainActor
final class MacGhosttyApp: ObservableObject {
    @Published private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    init() {
        guard let cfg = ghostty_config_new() else {
            macLog.error("ghostty_config_new failed")
            return
        }
        ghostty_config_finalize(cfg)
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in MacGhosttyApp.wakeup(userdata) },
            action_cb: { _, target, action in MacGhosttyApp.action(target: target, action: action) },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, content, len, _ in MacGhosttyApp.writeClipboard(content, len) },
            close_surface_cb: { _, _ in }
        )
        guard let app = ghostty_app_new(&runtime, cfg) else {
            macLog.error("ghostty_app_new failed")
            return
        }
        self.app = app
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
