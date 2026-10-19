import AppKit
import GhosttyKit

/// An NSView hosting a Ghostty surface with the manual IO backend: there's no
/// local process. The owner feeds program output in with `write` and gets what
/// the terminal sends back (keys, mouse, paste, query replies) from `onInput`.
///
/// Key, text input and mouse handling follow Ghostty's own macOS view
/// (ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift).
final class MacTerminalView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    /// Bytes for the program: keys, mouse reports, paste, query replies. Main thread.
    var onInput: ((Data) -> Void)?
    /// The terminal resized to this grid (after Ghostty's resize coalescing). Main thread.
    var onResize: ((_ columns: UInt16, _ rows: UInt16) -> Void)?
    /// Scrolled to within `nearTopRows` of the oldest line: time to load older history.
    var onScrollNearTop: (() -> Void)?
    /// Took the keyboard (clicked, or made first responder). Main thread.
    var onFocus: (() -> Void)?
    private let nearTopRows: UInt = 100

    /// Program output goes through here: ghostty_surface_write_pty_output can
    /// block when the termio queue is full, so never on the main thread.
    private let outputQueue = DispatchQueue(label: "clauntty.terminal-output")

    /// Ghostty's callbacks carry an ID, not a pointer, so one arriving after
    /// the view is gone finds nothing instead of a freed object.
    private static var registry: [Int: Weak] = [:]
    private static var nextID = 1
    private static let registryLock = NSLock()
    private struct Weak { weak var view: MacTerminalView? }
    private let registryID: Int

    private var markedText = NSMutableAttributedString()
    /// Non-nil while in keyDown: text the input system commits lands here.
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?

    init(app: ghostty_app_t, fontSize: Float = 0) {
        Self.registryLock.lock()
        registryID = Self.nextID
        Self.nextID += 1
        Self.registryLock.unlock()

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        Self.registryLock.lock()
        Self.registry[registryID] = Weak(view: self)
        Self.registryLock.unlock()

        var config = ghostty_surface_config_new()
        config.userdata = UnsafeMutableRawPointer(bitPattern: registryID)
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = fontSize
        config.manual_io = true

        guard let surface = ghostty_surface_new(app, &config) else {
            macLog.error("ghostty_surface_new failed")
            return
        }
        self.surface = surface

        // Both callbacks come from Ghostty's threads.
        ghostty_surface_set_pty_input_callback(surface) { userdata, bytes, len in
            guard let bytes, len > 0 else { return }
            let data = Data(bytes: bytes, count: Int(len))
            DispatchQueue.main.async { MacTerminalView.find(userdata)?.onInput?(data) }
        }
        ghostty_surface_set_pty_resize_callback(surface) { userdata, columns, rows, _, _ in
            DispatchQueue.main.async { MacTerminalView.find(userdata)?.onResize?(columns, rows) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        Self.registryLock.lock()
        Self.registry.removeValue(forKey: registryID)
        Self.registryLock.unlock()
        if let surface {
            // Let queued output finish before the surface goes away.
            outputQueue.sync {}
            ghostty_surface_free(surface)
        }
    }

    static func find(_ userdata: UnsafeMutableRawPointer?) -> MacTerminalView? {
        let id = Int(bitPattern: userdata)
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[id]?.view
    }

    // MARK: Output

    /// Program output, as if read from the pty.
    func write(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        outputQueue.async {
            data.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_write_pty_output(surface, ptr, UInt(raw.count))
            }
        }
    }

    /// Older output, from rtach's history, added above the scrollback. Through the
    /// output queue, so it can't land in the middle of a write.
    func prependHistory(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        outputQueue.async {
            data.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                _ = ghostty_surface_prepend_scrollback(surface, ptr, UInt(raw.count))
            }
        }
    }

    /// Run a Ghostty keybinding action (`copy_to_clipboard`, `set_font_size:14`...).
    @discardableResult
    func perform(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    /// The terminal's grid right now.
    var gridSize: (columns: UInt16, rows: UInt16)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (size.columns, size.rows)
    }

    // MARK: Size and focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        // Not during the SwiftUI update that may have made us first responder
        DispatchQueue.main.async { [weak self] in self?.onFocus?() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Which pane gets the keyboard is TerminalContainer's call
        guard let window else { return }
        updateScale()
        if let surface,
           let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        if let surface {
            let backing = convertToBacking(NSRect(x: 0, y: 0, width: 100, height: 100))
            ghostty_surface_set_content_scale(surface, backing.width / 100, backing.height / 100)
        }
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let size = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        // interpretKeyEvents runs the input system (dead keys, IMEs), which
        // commits text through insertText into the accumulator.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        syncPreedit()

        let composing = markedText.length > 0 || markedBefore
        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list { _ = keyAction(action, event: event, text: text) }
        } else {
            _ = keyAction(action, event: event, text: event.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Control combos AppKit would otherwise route to menus or swallow
    /// (ctrl+/, ctrl+return) go to the terminal. Cmd combos stay with the app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
            return false
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Pressed, unless it's the other side's key still being held.
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.composing = composing
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // Control and command never produce text on macOS; assume the rest did.
        key.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        // Control characters are encoded by Ghostty itself, from the key and mods.
        guard let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 else {
            return ghostty_surface_key(surface, key)
        }
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Outside a key press (emoji picker, dictation): send it as text.
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(strlen(ptr))) }
    }

    /// Selectors like insertNewline: come here; the key itself is encoded in keyDown.
    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        }
        // Outside keyDown (e.g. the input source changed), update now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    private func syncPreedit() {
        guard let surface else { return }
        if markedText.length > 0 {
            markedText.string.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr))) }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange() }
    func selectedRange() -> NSRange { NSRange() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME's candidate window goes: the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let local = NSRect(x: x, y: frame.height - y, width: w, height: h)
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func otherMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    override func otherMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Bit 0: precise; bits 1-3: momentum phase.
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | momentum << 1)
        // Scrolling back toward the oldest line: fetch older history (not on the
        // alternate screen, which has no scrollback)
        if y > 0, !ghostty_surface_is_alternate_screen(surface),
           ghostty_surface_scrollback_offset(surface) < nearTopRows {
            onScrollNearTop?()
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform("paste_from_clipboard") }
    @IBAction override func selectAll(_ sender: Any?) { perform("select_all") }
}

extension MacTerminalView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return surface.map { ghostty_surface_has_selection($0) } ?? false
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }
}

// MARK: - Clipboard requests from Ghostty

extension MacTerminalView {
    /// Ghostty wants the clipboard (a paste, or a program asking with OSC 52).
    /// Plain text only, from the general pasteboard.
    static func readClipboard(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?,
                              mimes: UnsafePointer<UnsafePointer<CChar>?>?, mimesLen: Int,
                              list: Bool) -> ghostty_clipboard_read_result_e {
        guard let view = find(userdata), let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let text = NSPasteboard.general.string(forType: .string)
        var wanted: [String] = []
        for i in 0..<mimesLen {
            guard let ptr = mimes?[i] else { continue }
            let mime = String(cString: ptr)
            if mime.hasPrefix("text/plain"), !wanted.contains(mime) { wanted.append(mime) }
        }
        let contents = text.map { text in wanted.map { ($0, text) } } ?? []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: text == nil ? [] : ["text/plain"],
                 confirmed: false, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks before a paste it finds risky (several lines, control
    /// characters) and before a program reads the clipboard. Your own paste goes
    /// ahead; a program reading it is refused.
    static func confirmReadClipboard(_ userdata: UnsafeMutableRawPointer?,
                                     confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                     state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let view = find(userdata), let surface = view.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c = confirm?.pointee else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        var contents: [(String, String)] = []
        for i in 0..<c.contents_len {
            guard let item = c.contents?[i], let mime = item.mime, let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            contents.append((String(cString: mime), text))
        }
        complete(surface, contents: contents, available: [], confirmed: true, state: state)
    }

    private static func complete(_ surface: ghostty_surface_t, contents: [(mime: String, text: String)],
                                 available: [String], confirmed: Bool, state: UnsafeMutableRawPointer?) {
        // C strings that live until Ghostty has copied them
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        let dup = { (s: String) -> UnsafeMutablePointer<CChar> in
            let p = strdup(s)!
            owned.append(p)
            return p
        }
        let cContents = contents.map { entry in
            ghostty_clipboard_content_s(mime: dup(entry.mime), data: dup(entry.text), len: entry.text.utf8.count)
        }
        let cAvailable: [UnsafePointer<CChar>?] = available.map { UnsafePointer(dup($0)) }
        cContents.withUnsafeBufferPointer { contentsBuf in
            cAvailable.withUnsafeBufferPointer { availableBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress, contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress, available_len: availableBuf.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
}

private extension NSEvent {
    /// The text Ghostty should get for a key event: control characters without
    /// control (Ghostty encodes those itself), nothing for function keys.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}
