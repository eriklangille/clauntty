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

    /// Callback when terminal grid size changes (rows, columns)
    var onTerminalSizeChanged: ((UInt16, UInt16) -> Void)?

    /// Callback to provide SSH output writer to the view
    var onSurfaceReady: ((TerminalSurfaceView) -> Void)?

    func makeUIView(context: Context) -> TerminalSurfaceView {
        guard let app = ghosttyApp.app else {
            Logger.clauntty.error("Cannot create TerminalSurfaceView: GhosttyApp not initialized")
            return TerminalSurfaceView(frame: .zero, app: nil)
        }
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), app: app)
        view.onTextInput = onTextInput
        view.onTerminalSizeChanged = onTerminalSizeChanged
        onSurfaceReady?(view)
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        // Update callbacks if they changed
        uiView.onTextInput = onTextInput
        uiView.onTerminalSizeChanged = onTerminalSizeChanged
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
class TerminalSurfaceView: UIView, ObservableObject, UIKeyInput, UITextInputTraits {

    // MARK: - Published Properties

    @Published var title: String = "Terminal"
    @Published var healthy: Bool = true
    @Published var error: Error? = nil

    // MARK: - Ghostty Surface

    private(set) var surface: ghostty_surface_t?

    // MARK: - Terminal Size

    /// Current terminal grid size (rows, columns)
    private(set) var terminalSize: (rows: UInt16, columns: UInt16) = (24, 80)

    /// Callback when terminal grid size changes (for SSH window resize)
    var onTerminalSizeChanged: ((UInt16, UInt16) -> Void)?

    // MARK: - UITextInputTraits

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - SSH Data Flow

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)? {
        didSet {
            // Also wire up the accessory bar
            accessoryBar.onKeyInput = onTextInput
        }
    }

    /// Keyboard accessory bar with terminal keys
    private let accessoryBar = KeyboardAccessoryView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))

    override var inputAccessoryView: UIView? {
        return accessoryBar
    }

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

        // Add tap gesture for keyboard and paste menu
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)

        // Add scroll gesture (one-finger drag to scroll terminal history)
        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.minimumNumberOfTouches = 1
        scrollGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(scrollGesture)

        // Add long press gesture for text selection
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3
        addGestureRecognizer(longPressGesture)

        // Allow scroll and long press to work together
        scrollGesture.require(toFail: longPressGesture)
        tapGesture.require(toFail: longPressGesture)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        // Clear any existing selection
        clearSelection()

        // If edit menu is visible, dismiss it and don't show a new one
        if isEditMenuVisible {
            dismissEditMenu()
            return
        }

        // Become first responder to show keyboard
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }

        // Only show paste menu if tapping near the cursor and clipboard has content
        if isNearCursor(location) && UIPasteboard.general.hasStrings {
            showEditMenu(at: location)
        }
    }

    /// Check if a point is near the cursor position
    private func isNearCursor(_ point: CGPoint) -> Bool {
        guard let surface = self.surface else { return false }

        // Get cursor position from Ghostty (IME point = cursor location)
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Define a hit area around the cursor (generous for touch)
        let hitRadius: CGFloat = 50.0
        let cursorRect = CGRect(
            x: CGFloat(x) - hitRadius,
            y: CGFloat(y) - hitRadius,
            width: CGFloat(width) + hitRadius * 2,
            height: CGFloat(height) + hitRadius * 2
        )

        return cursorRect.contains(point)
    }

    /// Clear the current selection by simulating a click
    private func clearSelection() {
        guard let surface = self.surface else { return }
        // A click (press + release at same spot) clears selection
        ghostty_surface_mouse_pos(surface, 0, 0, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    // MARK: - Selection & Copy/Paste

    /// Track if we're in selection mode
    private var isSelecting = false

    /// Track if edit menu is currently visible
    private var isEditMenuVisible = false

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface = self.surface else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // Start selection with mouse press at location
            isSelecting = true
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)

        case .changed:
            // Update selection as finger moves
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)

        case .ended:
            // End selection
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            isSelecting = false

            // Show edit menu if there's a selection
            if ghostty_surface_has_selection(surface) {
                showEditMenu(at: location)
            }

        case .cancelled:
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            isSelecting = false

        default:
            break
        }
    }

    private func showEditMenu(at location: CGPoint) {
        // Use UIEditMenuInteraction (iOS 16+)
        let menuConfig = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        if let interaction = interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
            interaction.presentEditMenu(with: menuConfig)
        } else {
            let editInteraction = UIEditMenuInteraction(delegate: self)
            addInteraction(editInteraction)
            editInteraction.presentEditMenu(with: menuConfig)
        }
        isEditMenuVisible = true
    }

    private func dismissEditMenu() {
        if let interaction = interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
            interaction.dismissMenu()
        }
        isEditMenuVisible = false
    }

    // MARK: - UIResponder Copy/Paste

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return surface != nil && ghostty_surface_has_selection(surface!)
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        if action == #selector(selectAll(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc override func copy(_ sender: Any?) {
        guard let surface = self.surface else { return }

        var text = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &text) {
            if let ptr = text.text, text.text_len > 0 {
                let string = String(cString: ptr)
                UIPasteboard.general.string = string
                Logger.clauntty.info("Copied \(text.text_len) characters to clipboard")
            }
            ghostty_surface_free_text(surface, &text)
        }

        // Clear selection after copying
        clearSelection()
    }

    @objc override func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string else { return }
        if let data = string.data(using: .utf8) {
            onTextInput?(data)
            Logger.clauntty.info("Pasted \(data.count) bytes from clipboard")
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        // TODO: Implement select all if Ghostty supports it
        Logger.clauntty.debug("Select all not yet implemented")
    }

    // MARK: - Scroll Handling

    /// Accumulated scroll delta for smoother scrolling
    private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 10.0  // Points per "line" of scroll

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard let surface = self.surface else { return }

        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            scrollAccumulator = 0

        case .changed:
            // Accumulate vertical scroll (negative = scroll up to see history)
            scrollAccumulator += translation.y

            // Convert to scroll "lines" - Ghostty expects scroll delta in lines
            // Positive y in gesture = finger moving down = scroll up in history
            let scrollLines = scrollAccumulator / scrollThreshold

            if abs(scrollLines) >= 1 {
                // Send scroll to Ghostty (y positive = scroll up/back in history)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollLines), 0)
                scrollAccumulator = scrollAccumulator.truncatingRemainder(dividingBy: scrollThreshold)
            }

            // Reset translation for incremental tracking
            gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled:
            scrollAccumulator = 0

        default:
            break
        }
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

            // Auto-show keyboard when terminal appears
            // Delay slightly to ensure view hierarchy is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                _ = self?.becomeFirstResponder()
            }
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
        }

        // Query terminal grid size and notify if changed
        let surfaceSize = ghostty_surface_size(surface)
        let newRows = surfaceSize.rows
        let newCols = surfaceSize.columns

        if newRows != terminalSize.rows || newCols != terminalSize.columns {
            terminalSize = (newRows, newCols)
            print("[Clauntty] Terminal grid size changed: \(newCols)x\(newRows)")
            onTerminalSizeChanged?(newRows, newCols)
        }
    }

    // MARK: - Focus

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
        // Check if Ctrl modifier is active from accessory bar
        if accessoryBar.consumeCtrlModifier() {
            // Convert character to control character (Ctrl+A = 0x01, Ctrl+C = 0x03, etc.)
            if let char = text.lowercased().first,
               let asciiValue = char.asciiValue,
               asciiValue >= 97 && asciiValue <= 122 {  // a-z
                let ctrlChar = UInt8(asciiValue - 96)  // a=1, b=2, ..., z=26
                onTextInput?(Data([ctrlChar]))
                Logger.clauntty.debug("Ctrl+\(char) sent as 0x\(String(format: "%02X", ctrlChar))")
                return
            }
        }

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

// MARK: - UIEditMenuInteractionDelegate

extension TerminalSurfaceView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        // Return default menu with Copy/Paste
        return UIMenu(children: suggestedActions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion {
            self.isEditMenuVisible = false
        }
    }
}

// MARK: - Preview

#Preview {
    TerminalSurface(ghosttyApp: GhosttyApp())
        .ignoresSafeArea()
}
