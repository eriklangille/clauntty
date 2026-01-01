import SwiftUI
import UIKit
import GhosttyKit
import os.log

// MARK: - Logger

extension Logger {
    static let clauntty = Logger(subsystem: "com.clauntty", category: "terminal")

    // MARK: - Debug-Only Logging (compiled out in release builds)

    /// Cached at startup - only checked once, not on every log call
    /// Set CLAUNTTY_VERBOSE=1 environment variable to enable verbose logging
    @usableFromInline
    static let isVerbose: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLAUNTTY_VERBOSE"] != nil
        #else
        return false
        #endif
    }()

    /// Only logs in DEBUG builds - zero cost in release
    /// Use for detailed flow information that's useful during development
    @inline(__always)
    func debugOnly(_ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        self.debug("\(msg)")
        #endif
    }

    /// Verbose logging - only in DEBUG builds AND when CLAUNTTY_VERBOSE=1
    /// Use for expensive operations like hex dumps, per-packet logging, cursor tracking
    /// Performance: Release = zero cost, Debug = single bool check
    @inline(__always)
    func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG
        if Self.isVerbose {
            let msg = message()
            self.info("\(msg)")
        }
        #endif
    }

    /// Check if verbose logging is enabled (useful for guarding expensive computations)
    @inlinable
    static var verboseLoggingEnabled: Bool {
        #if DEBUG
        return isVerbose
        #else
        return false
        #endif
    }
}

/// Wrapper around ghostty_app_t for iOS
/// Based on: ~/Projects/ghostty/macos/Sources/Ghostty/Ghostty.App.swift
@MainActor
class GhosttyApp: ObservableObject {
    enum Readiness: String {
        case loading, error, ready
    }

    @Published var readiness: Readiness = .loading

    /// The ghostty app instance
    @Published private(set) var app: ghostty_app_t? = nil {
        didSet {
            guard let old = oldValue else { return }
            ghostty_app_free(old)
        }
    }

    /// The configuration
    private var config: ghostty_config_t? = nil {
        didSet {
            guard let old = oldValue else { return }
            ghostty_config_free(old)
        }
    }

    /// Current theme ID (persisted via UserDefaults)
    @Published var currentThemeId: String {
        didSet {
            UserDefaults.standard.set(currentThemeId, forKey: "selectedThemeId")
        }
    }

    /// Current theme (computed from ID)
    var currentTheme: Theme? {
        ThemeManager.shared.theme(withId: currentThemeId)
    }

    init() {
        Logger.clauntty.info("GhosttyApp initializing...")

        // Load saved theme ID or use empty string for first-launch default
        self.currentThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? ""

        // Create configuration
        guard let cfg = ghostty_config_new() else {
            Logger.clauntty.error("ghostty_config_new failed")
            readiness = .error
            return
        }

        // Apply theme before finalization
        applyInitialTheme(to: cfg)

        // Finalize config
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create runtime config with callbacks
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,  // iOS doesn't have selection clipboard
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyApp.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state in GhosttyApp.readClipboard(userdata, location: loc, state: state) },
            confirm_read_clipboard_cb: { userdata, str, state, request in GhosttyApp.confirmReadClipboard(userdata, string: str, state: state, request: request) },
            write_clipboard_cb: { userdata, loc, content, len, confirm in GhosttyApp.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { userdata, processAlive in GhosttyApp.closeSurface(userdata, processAlive: processAlive) }
        )

        // Create the ghostty app
        guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
            Logger.clauntty.error("ghostty_app_new failed")
            readiness = .error
            return
        }

        self.app = app

        // Set color scheme based on theme
        let colorScheme: ghostty_color_scheme_e = currentTheme?.isLight == true
            ? GHOSTTY_COLOR_SCHEME_LIGHT
            : GHOSTTY_COLOR_SCHEME_DARK
        ghostty_app_set_color_scheme(app, colorScheme)

        self.readiness = .ready
        Logger.clauntty.info("GhosttyApp initialized successfully with theme: \(self.currentTheme?.name ?? "default")")
    }

    // MARK: - Theme Management

    /// Apply initial theme to config (called during init)
    private func applyInitialTheme(to config: ghostty_config_t) {
        let themeManager = ThemeManager.shared
        let theme: Theme

        if currentThemeId.isEmpty {
            // First launch - pick default based on system appearance
            let systemStyle = UITraitCollection.current.userInterfaceStyle
            if let defaultTheme = themeManager.defaultTheme(for: systemStyle) {
                theme = defaultTheme
                currentThemeId = theme.id
            } else {
                Logger.clauntty.warning("No themes available, using ghostty defaults")
                return
            }
        } else if let savedTheme = themeManager.theme(withId: currentThemeId) {
            theme = savedTheme
        } else {
            // Saved theme not found, pick a default
            let systemStyle = UITraitCollection.current.userInterfaceStyle
            if let defaultTheme = themeManager.defaultTheme(for: systemStyle) {
                theme = defaultTheme
                currentThemeId = theme.id
            } else {
                Logger.clauntty.warning("Saved theme not found and no defaults available")
                return
            }
        }

        themeManager.applyTheme(theme, to: config)
    }

    /// Change to a new theme (updates config and notifies observers)
    func setTheme(_ theme: Theme) {
        currentThemeId = theme.id

        // Create new config with theme applied
        guard let cfg = ghostty_config_new() else {
            Logger.clauntty.error("Failed to create new config for theme change")
            return
        }

        ThemeManager.shared.applyTheme(theme, to: cfg)
        ghostty_config_finalize(cfg)

        // Update app config
        if let app = self.app {
            ghostty_app_update_config(app, cfg)

            // Update color scheme
            let colorScheme: ghostty_color_scheme_e = theme.isLight
                ? GHOSTTY_COLOR_SCHEME_LIGHT
                : GHOSTTY_COLOR_SCHEME_DARK
            ghostty_app_set_color_scheme(app, colorScheme)
        }

        // Store new config (old one is freed via didSet)
        self.config = cfg

        Logger.clauntty.info("Theme changed to: \(theme.name)")

        // Post notification for views that need to update
        NotificationCenter.default.post(name: .themeDidChange, object: theme)
    }

    // NOTE: deinit removed due to Swift actor isolation constraints
    // GhosttyApp is expected to live for the entire app lifetime
    // Resources are freed via property didSet when replaced

    // MARK: - App Operations

    func appTick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Static Callbacks (called from C)

    /// Called by ghostty to wake up the main thread
    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            guard let userdata = userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            app.appTick()
        }
    }

    /// Handle ghostty actions
    static func action(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // Handle actions like render, set_title, etc.
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            // Rendering is handled by Metal layer automatically
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            // Extract title and route to the correct surface
            Logger.clauntty.info("GHOSTTY_ACTION_SET_TITLE received")
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surfacePtr = target.target.surface {
                let titlePtr = action.action.set_title.title
                if let titlePtr = titlePtr, let title = String(cString: titlePtr, encoding: .utf8) {
                    DispatchQueue.main.async {
                        if let view = TerminalSurfaceView.find(surface: surfacePtr) {
                            view.title = title
                            let hasCallback = view.onTitleChanged != nil
                            Logger.clauntty.info("Title set: '\(title.prefix(30))', onTitleChanged=\(hasCallback)")
                            view.onTitleChanged?(title)
                        } else {
                            Logger.clauntty.warning("SET_TITLE: TerminalSurfaceView.find returned nil!")
                        }
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            // Cell size changed
            Logger.clauntty.debug("Action: cell_size")
            return true

        default:
            Logger.clauntty.debug("Unhandled action: \(action.tag.rawValue)")
            return false
        }
    }

    /// Read from iOS clipboard
    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata = userdata else { return }
        let _ = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()

        // Read from UIPasteboard
        let content = UIPasteboard.general.string ?? ""
        Logger.clauntty.debug("Clipboard read: \(content.prefix(20))...")

        // Complete the request if we have a surface
        // Note: This needs the surface reference to complete - will be wired up in Phase 2
    }

    /// Confirm clipboard read (for security prompts)
    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // iOS auto-confirms clipboard reads (no security prompt needed)
        Logger.clauntty.debug("Clipboard confirm read")
    }

    /// Write to iOS clipboard
    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content = content, len > 0 else { return }

        // Extract text/plain content
        for i in 0..<len {
            let item = content[i]
            if let mime = item.mime,
               String(cString: mime) == "text/plain",
               let data = item.data {
                let text = String(cString: data)
                UIPasteboard.general.string = text
                Logger.clauntty.debug("Clipboard write: \(text.prefix(20))...")
                break
            }
        }
    }

    /// Called when a surface should be closed
    static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        Logger.clauntty.info("Surface closed, processAlive: \(processAlive)")
        NotificationCenter.default.post(
            name: .ghosttySurfaceClosed,
            object: nil,
            userInfo: ["processAlive": processAlive]
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let ghosttySurfaceClosed = Notification.Name("ghosttySurfaceClosed")
    static let themeDidChange = Notification.Name("themeDidChange")
}
