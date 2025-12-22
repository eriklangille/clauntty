import SwiftUI
import UIKit
import GhosttyKit
import os.log

/// SwiftUI wrapper for the Ghostty terminal surface
/// Based on: ~/Projects/ghostty/macos/Sources/Ghostty/SurfaceView_UIKit.swift
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var ghosttyApp: GhosttyApp

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)?

    /// Callback to provide SSH output writer to the view
    var onSurfaceReady: ((TerminalSurfaceView) -> Void)?

    func makeUIView(context: Context) -> TerminalSurfaceView {
        guard let app = ghosttyApp.app else {
            Logger.clauntty.error("Cannot create TerminalSurfaceView: GhosttyApp not initialized")
            return TerminalSurfaceView(frame: .zero, app: nil)
        }
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), app: app)
        view.onTextInput = onTextInput
        onSurfaceReady?(view)
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        // Update callbacks if they changed
        uiView.onTextInput = onTextInput
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: TerminalSurface

        init(_ parent: TerminalSurface) {
            self.parent = parent
        }
    }
}

/// UIKit view that hosts the Ghostty terminal
/// Uses CAMetalLayer for GPU-accelerated rendering
class TerminalSurfaceView: UIView, ObservableObject, UIKeyInput {

    // MARK: - Published Properties

    @Published var title: String = "Terminal"
    @Published var healthy: Bool = true
    @Published var error: Error? = nil

    // MARK: - Ghostty Surface

    private(set) var surface: ghostty_surface_t?

    // MARK: - SSH Data Flow

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)?

    // MARK: - Initialization

    init(frame: CGRect, app: ghostty_app_t?) {
        super.init(frame: frame)
        setupView()

        guard let app = app else {
            Logger.clauntty.error("TerminalSurfaceView: No app provided")
            return
        }

        // Create surface configuration for iOS
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = UIScreen.main.scale
        config.font_size = 12.0  // Smaller font for mobile

        // Create the surface
        guard let surface = ghostty_surface_new(app, &config) else {
            Logger.clauntty.error("ghostty_surface_new failed")
            return
        }

        self.surface = surface
        Logger.clauntty.info("Terminal surface created successfully")
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        if let surface = self.surface {
            ghostty_surface_free(surface)
        }
    }

    private func setupView() {
        // Configure for Metal rendering
        backgroundColor = .black

        // Enable user interaction for keyboard
        isUserInteractionEnabled = true
    }

    // MARK: - Layer

    // NOTE: We do NOT override layerClass to CAMetalLayer because Ghostty
    // adds its own IOSurfaceLayer as a sublayer. Using default CALayer.

    /// Called by GhosttyKit's Metal renderer to add its IOSurfaceLayer
    /// GhosttyKit calls this on the view, but it's a CALayer method,
    /// so we forward to our layer and set the sublayer's frame.
    @objc(addSublayer:)
    func addSublayer(_ sublayer: CALayer) {
        print("[Clauntty] addSublayer called, layer.bounds=\(self.layer.bounds)")

        // Store reference first
        ghosttySublayer = sublayer

        // Add to layer hierarchy
        self.layer.addSublayer(sublayer)

        // Immediately trigger size update with current bounds
        // This ensures the sublayer gets the correct size even if layoutSubviews hasn't run yet
        sizeDidChange(self.bounds.size)
    }

    /// Reference to Ghostty's IOSurfaceLayer for frame updates
    private var ghosttySublayer: CALayer?

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        print("[Clauntty] layoutSubviews: bounds=\(self.bounds)")

        // sizeDidChange will update both the surface AND the sublayer
        sizeDidChange(self.bounds.size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            print("[Clauntty] didMoveToWindow: window scale=\(window!.screen.scale)")
            // Now we have access to correct screen scale - update everything
            sizeDidChange(self.bounds.size)
        }
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface = self.surface else { return }

        // Use window's screen scale, or fall back to main screen
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let pixelWidth = UInt32(size.width * scale)
        let pixelHeight = UInt32(size.height * scale)

        print("[Clauntty] sizeDidChange: \(Int(size.width))x\(Int(size.height)) @\(scale)x = \(pixelWidth)x\(pixelHeight)px")

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)

        // Update sublayer frame and scale to match
        if let sublayer = ghosttySublayer {
            sublayer.frame = CGRect(origin: .zero, size: size)
            sublayer.contentsScale = scale
            print("[Clauntty] sizeDidChange: sublayer frame=\(sublayer.frame), contentsScale=\(sublayer.contentsScale)")
        }
    }

    // MARK: - Focus

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDidChange(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focusDidChange(false)
        }
        return result
    }

    func focusDidChange(_ focused: Bool) {
        guard let surface = self.surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: - SSH Data Flow

    /// Write SSH output to the terminal for display
    /// This feeds data directly to Ghostty's terminal processor
    func writeSSHOutput(_ data: Data) {
        guard let surface = self.surface else {
            Logger.clauntty.warning("Cannot write SSH output: no surface")
            return
        }

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_pty_output(surface, ptr, UInt(data.count))
        }
        Logger.clauntty.debug("SSH output written: \(data.count) bytes")
    }

    // MARK: - UIKeyInput

    var hasText: Bool {
        return true
    }

    func insertText(_ text: String) {
        // Send text input to SSH (not directly to Ghostty)
        // SSH server will echo it back if needed, and we'll display via writeSSHOutput
        if let data = text.data(using: .utf8) {
            onTextInput?(data)
        }
    }

    func deleteBackward() {
        // Send backspace (ASCII DEL 0x7F or BS 0x08) to SSH
        let backspace = Data([0x7F])  // DEL character
        Logger.clauntty.debug("Keyboard input: backspace")
        onTextInput?(backspace)
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Become first responder to show keyboard
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    // MARK: - Hardware Keyboard Support

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if let data = dataForKey(key) {
                onTextInput?(data)
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Convert UIKey to terminal escape sequence data
    private func dataForKey(_ key: UIKey) -> Data? {
        switch key.keyCode {
        // Escape key
        case .keyboardEscape:
            return Data([0x1B])  // ESC

        // Arrow keys (send ANSI escape sequences)
        case .keyboardUpArrow:
            return Data([0x1B, 0x5B, 0x41])  // ESC [ A
        case .keyboardDownArrow:
            return Data([0x1B, 0x5B, 0x42])  // ESC [ B
        case .keyboardRightArrow:
            return Data([0x1B, 0x5B, 0x43])  // ESC [ C
        case .keyboardLeftArrow:
            return Data([0x1B, 0x5B, 0x44])  // ESC [ D

        // Tab
        case .keyboardTab:
            return Data([0x09])  // TAB

        // Enter/Return
        case .keyboardReturnOrEnter:
            return Data([0x0D])  // CR

        // Function keys
        case .keyboardF1:
            return Data([0x1B, 0x4F, 0x50])  // ESC O P
        case .keyboardF2:
            return Data([0x1B, 0x4F, 0x51])  // ESC O Q
        case .keyboardF3:
            return Data([0x1B, 0x4F, 0x52])  // ESC O R
        case .keyboardF4:
            return Data([0x1B, 0x4F, 0x53])  // ESC O S

        // Home/End/PageUp/PageDown
        case .keyboardHome:
            return Data([0x1B, 0x5B, 0x48])  // ESC [ H
        case .keyboardEnd:
            return Data([0x1B, 0x5B, 0x46])  // ESC [ F
        case .keyboardPageUp:
            return Data([0x1B, 0x5B, 0x35, 0x7E])  // ESC [ 5 ~
        case .keyboardPageDown:
            return Data([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~

        // Delete (forward delete)
        case .keyboardDeleteForward:
            return Data([0x1B, 0x5B, 0x33, 0x7E])  // ESC [ 3 ~

        default:
            // Check for Ctrl+key combinations
            if key.modifierFlags.contains(.control), let char = key.characters.first {
                let asciiValue = char.asciiValue ?? 0
                // Ctrl+A through Ctrl+Z = 0x01 through 0x1A
                if asciiValue >= 97 && asciiValue <= 122 {  // a-z
                    return Data([UInt8(asciiValue - 96)])
                }
            }
            return nil
        }
    }
}

// MARK: - Preview

#Preview {
    TerminalSurface(ghosttyApp: GhosttyApp())
        .ignoresSafeArea()
}
