import SwiftUI
import UIKit
import GhosttyKit
import Combine
import os.log

// MARK: - Font Size Preference

/// Manages the persisted font size preference for terminals
enum FontSizePreference {
    private static let key = "terminalFontSize"
    private static let defaultSize: Float = 9.0
    private static let minSize: Float = 6.0
    private static let maxSize: Float = 36.0

    /// Get the saved font size, or default if not set
    static var current: Float {
        let saved = UserDefaults.standard.float(forKey: key)
        // Return default if not set (0 means not set)
        return saved > 0 ? saved : defaultSize
    }

    /// Save a new font size preference
    static func save(_ size: Float) {
        let clamped = max(minSize, min(maxSize, size))
        UserDefaults.standard.set(clamped, forKey: key)
        Logger.clauntty.info("Font size preference saved: \(clamped)")
    }

    /// Reset to default
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// SwiftUI wrapper for the Ghostty terminal surface
/// Based on: ~/Projects/ghostty/macos/Sources/Ghostty/SurfaceView_UIKit.swift
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var ghosttyApp: GhosttyApp

    /// Whether this terminal is currently the active tab
    var isActive: Bool = true

    /// Initial font size for this session (nil = use global default)
    var initialFontSize: Float?

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)?

    /// Callback for image paste - upload image and paste path
    var onImagePaste: ((UIImage) -> Void)?

    /// Callback when terminal grid size changes (rows, columns)
    var onTerminalSizeChanged: ((UInt16, UInt16) -> Void)?

    /// Callback when font size changes (for persisting per-session)
    var onFontSizeChanged: ((Float) -> Void)?

    /// Callback to provide SSH output writer to the view
    var onSurfaceReady: ((TerminalSurfaceView) -> Void)?

    func makeUIView(context: Context) -> TerminalSurfaceView {
        guard let app = ghosttyApp.app else {
            Logger.clauntty.error("Cannot create TerminalSurfaceView: GhosttyApp not initialized")
            return TerminalSurfaceView(frame: .zero, app: nil)
        }
        // Start with zero frame - SwiftUI will size it properly via layoutSubviews
        let view = TerminalSurfaceView(frame: .zero, app: app, initialFontSize: initialFontSize)
        view.onTextInput = onTextInput
        view.onImagePaste = onImagePaste
        view.onTerminalSizeChanged = onTerminalSizeChanged
        view.onFontSizeChanged = onFontSizeChanged
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Store in coordinator so we can call onSurfaceReady in updateUIView
        // (calling it here doesn't work because SwiftUI @State updates don't
        // take effect from within makeUIView closures)
        context.coordinator.surfaceView = view

        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        Logger.clauntty.info("updateUIView called, isActive=\(isActive)")
        // Update callbacks if they changed
        uiView.onTextInput = onTextInput
        uiView.onImagePaste = onImagePaste
        uiView.onTerminalSizeChanged = onTerminalSizeChanged
        uiView.onFontSizeChanged = onFontSizeChanged

        // Handle focus changes when active state changes
        uiView.setActive(isActive)

        // Call onSurfaceReady on first update (when coordinator.surfaceView is set but not yet notified)
        // This ensures SwiftUI state updates work properly
        if let surface = context.coordinator.surfaceView {
            context.coordinator.surfaceView = nil  // Only call once
            onSurfaceReady?(surface)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: TerminalSurface
        /// Store reference to surface view for passing back to SwiftUI
        var surfaceView: TerminalSurfaceView?

        init(_ parent: TerminalSurface) {
            self.parent = parent
        }
    }
}

/// UIKit view that hosts the Ghostty terminal
/// Uses CAMetalLayer for GPU-accelerated rendering
class TerminalSurfaceView: UIView, ObservableObject, UIKeyInput, UITextInputTraits {

    // MARK: - Surface Registry (for routing Ghostty callbacks)

    /// Registry to look up surfaces by pointer (for routing Ghostty action callbacks)
    /// Access must be synchronized via registryLock since Ghostty callbacks may come from any thread
    private static var surfaceRegistry: [UnsafeRawPointer: TerminalSurfaceView] = [:]
    private static let registryLock = NSLock()

    /// Look up surface view by Ghostty surface pointer (thread-safe)
    static func find(surface: ghostty_surface_t) -> TerminalSurfaceView? {
        let ptr = UnsafeRawPointer(surface)
        registryLock.lock()
        defer { registryLock.unlock() }
        return surfaceRegistry[ptr]
    }

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

    /// Callback when terminal sets title via OSC escape sequence
    var onTitleChanged: ((String) -> Void)?

    /// Callback when user scrolls near the top of scrollback (for lazy loading)
    /// Called with the current offset from top (0 = at top)
    var onScrollNearTop: ((UInt) -> Void)?

    /// Threshold in rows for triggering onScrollNearTop (default: 100 rows from top)
    var scrollNearTopThreshold: UInt = 100

    /// Callback when active state changes (for power management)
    /// Called with true when tab becomes active, false when inactive
    var onActiveStateChanged: ((Bool) -> Void)?

    // MARK: - Font Size

    /// Current font size in points (tracked for persistence)
    private var currentFontSize: Float = FontSizePreference.current

    /// Callback when font size changes (for per-session persistence)
    var onFontSizeChanged: ((Float) -> Void)?

    // MARK: - Power Management

    /// Subscription to power mode changes
    private var powerModeObserver: AnyCancellable?

    // MARK: - UITextInputTraits

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - Software Keyboard Control

    /// Whether the software keyboard is manually hidden (keeps first responder for hardware keyboard)
    private var isSoftwareKeyboardHidden = false

    /// Flag to ignore spurious keyboardWillHide during show transition
    private var isShowingKeyboardTransition = false

    /// Flag to ignore spurious keyboard notifications during rotation
    private var isRotating = false

    /// Empty view to replace keyboard when hidden (zero height to avoid gray bar)
    private let emptyInputView: UIView = {
        let view = UIView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }()

    /// Constraint for positioning accessory bar above keyboard
    private var accessoryBarBottomConstraint: NSLayoutConstraint?

    /// Override inputView to control software keyboard visibility
    override var inputView: UIView? {
        if isSoftwareKeyboardHidden {
            return emptyInputView  // Empty view = no keyboard
        }
        return nil  // nil = default keyboard
    }

    /// Hide the software keyboard without resigning first responder
    func hideSoftwareKeyboard() {
        Logger.clauntty.info("[KB] hideSoftwareKeyboard() called, isSoftwareKeyboardHidden=\(self.isSoftwareKeyboardHidden)")
        guard !isSoftwareKeyboardHidden else { return }
        isSoftwareKeyboardHidden = true
        reloadInputViews()
        accessoryBar.setKeyboardVisible(false)
        keyboardHeight = 0
        updateSizeForKeyboard()
        updateAccessoryBarPosition(keyboardVisible: false, keyboardHeight: 0)
        Logger.clauntty.info("[KB] hideSoftwareKeyboard() - set flag=true, accessoryBar COLLAPSED")
    }

    /// Show the software keyboard
    func showSoftwareKeyboard() {
        Logger.clauntty.info("[KB] showSoftwareKeyboard() called, isSoftwareKeyboardHidden=\(self.isSoftwareKeyboardHidden), barShown=\(self.accessoryBar.isKeyboardShown)")

        // Allow show if keyboard was manually hidden OR if bar is collapsed (e.g., after Cmd+K)
        guard isSoftwareKeyboardHidden || !accessoryBar.isKeyboardShown else {
            Logger.clauntty.info("[KB] showSoftwareKeyboard() skipped - keyboard already shown")
            return
        }

        isSoftwareKeyboardHidden = false
        isShowingKeyboardTransition = true  // Ignore spurious hide notifications

        // Tell iOS to reload input views BEFORE becoming first responder
        // This ensures inputView returns nil (default keyboard) instead of emptyInputView
        reloadInputViews()

        // Force keyboard to appear by resigning and re-becoming first responder
        // This is necessary after Cmd+K or other external keyboard dismissal
        if isFirstResponder {
            Logger.clauntty.info("[KB] showSoftwareKeyboard() - resigning and re-becoming first responder")
            _ = resignFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                _ = self?.becomeFirstResponder()
                // Reload input views again after becoming first responder to be sure
                self?.reloadInputViews()
            }
        } else {
            // Not first responder - just become it
            _ = becomeFirstResponder()
            reloadInputViews()
        }
        Logger.clauntty.info("[KB] showSoftwareKeyboard() - waiting for keyboardWillShow")

        // Timeout: if keyboard doesn't show within 0.5s, reset state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.isShowingKeyboardTransition {
                Logger.clauntty.info("[KB] showSoftwareKeyboard timeout - keyboard didn't appear, resetting state")
                self.isShowingKeyboardTransition = false
                self.isSoftwareKeyboardHidden = true
                self.accessoryBar.setKeyboardVisible(false)
                self.updateAccessoryBarPosition(keyboardVisible: false, keyboardHeight: 0)
            }
        }
    }

    /// Set up accessory bar in the window (so it appears above keyboard)
    /// Called from didMoveToWindow when we have a window
    private func setupAccessoryBarInWindow() {
        guard let window = window else { return }

        // Only set up once
        guard accessoryBar.superview == nil else { return }

        accessoryBar.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(accessoryBar)

        accessoryBarBottomConstraint = accessoryBar.bottomAnchor.constraint(equalTo: window.bottomAnchor, constant: -8)

        NSLayoutConstraint.activate([
            // Full width spanning the window (minus safe area handled inside the view)
            accessoryBar.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            accessoryBar.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            accessoryBar.heightAnchor.constraint(equalToConstant: 60),
            accessoryBarBottomConstraint!
        ])
        Logger.clauntty.info("[KB] Added accessory bar to window")
    }

    /// Update accessory bar position based on keyboard state
    private func updateAccessoryBarPosition(keyboardVisible: Bool, keyboardHeight: CGFloat) {
        // Position bar above keyboard when visible, at bottom when hidden
        let bottomOffset: CGFloat
        if keyboardVisible && keyboardHeight > 0 {
            // Above keyboard (keyboard height from bottom of window)
            bottomOffset = -keyboardHeight
        } else {
            // At bottom of screen (above safe area)
            let safeBottom = window?.safeAreaInsets.bottom ?? 0
            bottomOffset = -safeBottom - 8
        }

        accessoryBarBottomConstraint?.constant = bottomOffset
        Logger.clauntty.info("[KB] updateAccessoryBarPosition: keyboardVisible=\(keyboardVisible), kbHeight=\(Int(keyboardHeight)), bottomOffset=\(Int(bottomOffset))")
    }

    // MARK: - SSH Data Flow

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)? {
        didSet {
            // Also wire up the accessory bar
            accessoryBar.onKeyInput = onTextInput
        }
    }

    /// Callback for image paste - upload image and paste path
    var onImagePaste: ((UIImage) -> Void)?

    /// Keyboard accessory bar with terminal keys
    private let accessoryBar: KeyboardAccessoryView = {
        let bar = KeyboardAccessoryView(frame: CGRect(x: 0, y: 0, width: 0, height: 60))
        return bar
    }()

    /// Set up accessory bar keyboard callbacks
    private func setupAccessoryBarCallbacks() {
        accessoryBar.onDismissKeyboard = { [weak self] in
            self?.hideSoftwareKeyboard()
        }
        accessoryBar.onShowKeyboard = { [weak self] in
            self?.showSoftwareKeyboard()
        }
    }

    // We don't use inputAccessoryView - we manage the accessory bar as our own subview
    // This gives us full control over positioning and avoids iOS ownership issues

    // MARK: - Initialization

    init(frame: CGRect, app: ghostty_app_t?, initialFontSize: Float? = nil) {
        super.init(frame: frame)

        // Set font size from session preference, or fall back to global default
        let fontSize = initialFontSize ?? FontSizePreference.current
        self.currentFontSize = fontSize

        setupView()
        setupAccessoryBarCallbacks()
        // Accessory bar setup happens in didMoveToWindow when we have a window

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
        // Use session's font size
        config.font_size = fontSize

        // Create the surface
        guard let surface = ghostty_surface_new(app, &config) else {
            Logger.clauntty.error("ghostty_surface_new failed")
            return
        }

        self.surface = surface

        // Set up the PTY input callback for iOS
        // This routes mouse events and other PTY input through to SSH
        // IMPORTANT: This callback is called from Ghostty's internal thread,
        // so we must dispatch to main thread for Session (which is @MainActor)
        ghostty_surface_set_pty_input_callback(surface) { (userdata, data, len) in
            guard let userdata = userdata else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard len > 0, let data = data else { return }
            let inputData = Data(bytes: data, count: Int(len))
            // Log PTY input - show first 50 bytes hex for debugging paste
            let hexPreview = inputData.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " ")
            Logger.clauntty.info("[PTY_INPUT] \(inputData.count) bytes, first 50: \(hexPreview)")
            // Forward to SSH via the same callback as keyboard input
            // Must dispatch to main thread since Session is @MainActor
            DispatchQueue.main.async {
                view.onTextInput?(inputData)
            }
        }

        // Register in static registry for Ghostty callback routing (thread-safe)
        let ptr = UnsafeRawPointer(surface)
        Self.registryLock.lock()
        Self.surfaceRegistry[ptr] = self
        Self.registryLock.unlock()

        // Set initial power mode
        updatePowerMode(PowerManager.shared.currentMode)

        Logger.clauntty.info("Terminal surface created successfully")
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        setupAccessoryBarCallbacks()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        setupAccessoryBarCallbacks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        powerModeObserver?.cancel()

        // Remove accessory bar from window
        accessoryBar.removeFromSuperview()

        if let surface = self.surface {
            // Unregister from static registry (thread-safe)
            let ptr = UnsafeRawPointer(surface)
            Self.registryLock.lock()
            Self.surfaceRegistry.removeValue(forKey: ptr)
            Self.registryLock.unlock()

            ghostty_surface_free(surface)
        }
    }

    // MARK: - Keyboard Handling

    /// Current keyboard height (0 when hidden)
    private var keyboardHeight: CGFloat = 0

    private func setupKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        // Track keyboard frame height for accessory bar positioning
        // Note: We don't use this to subtract from terminal size because the terminal view
        // doesn't extend to the keyboard area (SwiftUI handles the layout)
        let keyboardFrameHeight = keyboardFrame.height

        Logger.clauntty.info("[KB] keyboardWillShow: kbFrame=\(Int(keyboardFrame.width))x\(Int(keyboardFrame.height)), bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)), isSoftwareKeyboardHidden=\(self.isSoftwareKeyboardHidden)")

        // Only treat as "real" keyboard if the keyboard height is substantial (>100 = actual keyboard, not just accessory bar)
        let isRealKeyboard = keyboardFrameHeight > 100

        // Track if keyboard is visible (for accessory bar state) - don't use for terminal size
        let wasKeyboardVisible = keyboardHeight > 0
        if isRealKeyboard {
            keyboardHeight = keyboardFrameHeight  // Store for accessory bar positioning
        }

        // Update terminal size if keyboard visibility changed (affects accessory bar reserve)
        if wasKeyboardVisible != isRealKeyboard {
            Logger.clauntty.info("[KB] Keyboard visibility changed: \(wasKeyboardVisible) -> \(isRealKeyboard)")
            updateSizeForKeyboard()
        }

        // Only expand accessory bar for real keyboard, not just accessory bar height changes
        if isRealKeyboard {
            // Clear the transition flag - keyboard successfully shown
            isShowingKeyboardTransition = false

            // If user had manually hidden keyboard (via button), but iOS is now showing
            // a real keyboard (via Cmd+K or other), respect that and clear our flag
            if isSoftwareKeyboardHidden {
                Logger.clauntty.info("[KB] Real keyboard appeared while flag=hidden, clearing flag (Cmd+K case)")
                isSoftwareKeyboardHidden = false
            }

            accessoryBar.setKeyboardVisible(true)
            updateAccessoryBarPosition(keyboardVisible: true, keyboardHeight: keyboardFrame.height)
            Logger.clauntty.info("[KB] accessoryBar.setKeyboardVisible(true) - EXPANDED")
        } else {
            Logger.clauntty.info("[KB] Skipping expand - not real keyboard (height=\(Int(keyboardFrameHeight)))")
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        Logger.clauntty.info("[KB] keyboardWillHide: bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)), isSoftwareKeyboardHidden=\(self.isSoftwareKeyboardHidden), isShowingTransition=\(self.isShowingKeyboardTransition), isRotating=\(self.isRotating)")

        // Ignore spurious hide notifications during show transition
        if isShowingKeyboardTransition {
            Logger.clauntty.info("[KB] keyboardWillHide IGNORED - in show transition")
            return
        }

        // Ignore spurious hide notifications during rotation
        if isRotating {
            Logger.clauntty.info("[KB] keyboardWillHide IGNORED - during rotation")
            return
        }

        // Ignore if we've manually hidden the keyboard (we already handled it)
        if isSoftwareKeyboardHidden {
            Logger.clauntty.info("[KB] keyboardWillHide IGNORED - already manually hidden")
            return
        }

        // Keyboard was hidden externally (e.g., Cmd+K)
        // Only collapse bar if it's currently expanded
        if accessoryBar.isKeyboardShown {
            if keyboardHeight != 0 {
                keyboardHeight = 0
                Logger.clauntty.info("[KB] Keyboard height changed: 0")
                updateSizeForKeyboard()
            }
            accessoryBar.setKeyboardVisible(false)
            updateAccessoryBarPosition(keyboardVisible: false, keyboardHeight: 0)
            Logger.clauntty.info("[KB] accessoryBar.setKeyboardVisible(false) - COLLAPSED (external hide)")
        } else {
            Logger.clauntty.info("[KB] keyboardWillHide IGNORED - bar already collapsed")
        }
    }

    /// Height to reserve for accessory bar when keyboard is visible (expanded bar)
    /// The bar is positioned above the keyboard but still within our view bounds
    private let expandedAccessoryBarHeight: CGFloat = 68  // 60pt bar + 8pt top padding

    /// Height to reserve for accessory bar when keyboard is hidden (collapsed bar)
    /// Includes safe area margin since bar is at bottom of screen
    private let collapsedAccessoryBarHeight: CGFloat = 76  // 60pt bar + 16pt margin for safe area

    private func updateSizeForKeyboard() {
        // Recalculate size accounting for accessory bar position
        //
        // The accessory bar is ALWAYS within our view bounds (it's a window subview
        // positioned above the keyboard or at the bottom of screen).
        // We must ALWAYS reserve space for it, just different amounts:
        //
        // When keyboard is VISIBLE:
        //   - SwiftUI adjusts our bounds to be the space ABOVE the keyboard
        //   - The accessory bar is positioned just above the keyboard, within our bounds
        //   - Reserve space for the expanded bar
        //
        // When keyboard is HIDDEN:
        //   - Our bounds are nearly full screen
        //   - The accessory bar is at the bottom of screen, within our bounds
        //   - Reserve space for the collapsed bar (includes safe area margin)
        let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
        let effectiveSize = CGSize(
            width: bounds.width,
            height: bounds.height - accessoryBarReserve
        )
        let safeInsets = safeAreaInsets
        Logger.clauntty.info("[KB] updateSizeForKeyboard: bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)), kbVisible=\(self.keyboardHeight > 0), barReserve=\(Int(accessoryBarReserve)), effectiveSize=\(Int(effectiveSize.width))x\(Int(effectiveSize.height)), safeArea=(t:\(Int(safeInsets.top)),b:\(Int(safeInsets.bottom)),l:\(Int(safeInsets.left)),r:\(Int(safeInsets.right)))")
        sizeDidChange(effectiveSize)
    }

    private func setupView() {
        // Set background color from current theme
        updateBackgroundColor()

        // Enable user interaction for keyboard
        isUserInteractionEnabled = true

        // Listen for keyboard show/hide to resize terminal
        setupKeyboardNotifications()

        // Listen for app lifecycle to stop rendering when backgrounded
        setupAppLifecycleNotifications()

        // Listen for theme changes to update background color
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange(_:)),
            name: .themeDidChange,
            object: nil
        )

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

        // Add pinch gesture for font resizing
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)

        // Subscribe to power mode changes for battery optimization
        setupPowerModeObserver()

        // Setup selection handles for adjusting text selection
        setupSelectionHandles()
    }

    // MARK: - App Lifecycle (Background/Foreground)

    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        isAppBackgrounded = true
        guard let surface = self.surface else { return }
        // Tell Ghostty the surface is not visible - stops the renderer
        // This prevents the renderer from holding mutex when iOS suspends threads
        ghostty_surface_set_occlusion(surface, false)
        Logger.clauntty.info("Surface occluded (app backgrounded)")
    }

    @objc private func appWillEnterForeground() {
        isAppBackgrounded = false
        guard let surface = self.surface else { return }
        // Only resume rendering if this is the active tab
        // Inactive tabs stay occluded to prevent mutex contention
        if isActiveTab {
            ghostty_surface_set_occlusion(surface, true)
            Logger.clauntty.info("Surface visible (app foregrounded, active tab)")
        } else {
            Logger.clauntty.info("Surface stays occluded (app foregrounded, inactive tab)")
        }
    }

    // MARK: - Power Mode

    private func setupPowerModeObserver() {
        // Subscribe to power mode changes on main thread
        powerModeObserver = PowerManager.shared.$currentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.updatePowerMode(mode)
            }
    }

    /// Update the Ghostty surface's power mode for battery optimization
    private func updatePowerMode(_ mode: PowerMode) {
        guard let surface = self.surface else { return }
        let ghosttyMode = ghostty_power_mode_e(rawValue: UInt32(mode.rawValue))
        ghostty_surface_set_power_mode(surface, ghosttyMode)
        Logger.clauntty.info("Terminal power mode updated: \(String(describing: mode))")
    }

    // MARK: - Theme

    /// Update background color to match current theme
    private func updateBackgroundColor() {
        if let theme = ThemeManager.shared.theme(withId: UserDefaults.standard.string(forKey: "selectedThemeId") ?? "") {
            backgroundColor = UIColor(theme.backgroundColor)
        } else if let defaultTheme = ThemeManager.shared.defaultTheme(for: UITraitCollection.current.userInterfaceStyle) {
            backgroundColor = UIColor(defaultTheme.backgroundColor)
        } else {
            // Fallback to Ghostty's default background color (#282C34)
            backgroundColor = UIColor(red: 40/255.0, green: 44/255.0, blue: 52/255.0, alpha: 1.0)
        }
    }

    @objc private func themeDidChange(_ notification: Notification) {
        if let theme = notification.object as? Theme {
            backgroundColor = UIColor(theme.backgroundColor)
            Logger.clauntty.info("Terminal background updated for theme: \(theme.name)")
        }
    }

    // MARK: - Pinch to Zoom (Font Resize)

    /// Accumulated scale for pinch gesture
    private var pinchAccumulatedScale: CGFloat = 1.0

    /// Threshold for triggering a font size change
    private let pinchScaleThreshold: CGFloat = 0.15

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let surface = self.surface else { return }

        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0

        case .changed:
            let scale = gesture.scale
            gesture.scale = 1.0  // Reset for incremental tracking

            pinchAccumulatedScale *= scale

            // Check if we've crossed a threshold
            if pinchAccumulatedScale > 1.0 + pinchScaleThreshold {
                // Increase font size
                increaseFontSize(surface: surface)
                pinchAccumulatedScale = 1.0
            } else if pinchAccumulatedScale < 1.0 - pinchScaleThreshold {
                // Decrease font size
                decreaseFontSize(surface: surface)
                pinchAccumulatedScale = 1.0
            }

        case .ended, .cancelled:
            pinchAccumulatedScale = 1.0

        default:
            break
        }
    }

    private func increaseFontSize(surface: ghostty_surface_t) {
        let action = "increase_font_size:1"
        // Dispatch to background queue to avoid potential main thread blocking
        terminalIOQueue.async { [weak self] in
            let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
            if success {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentFontSize = min(self.currentFontSize + 1, 36)
                    FontSizePreference.save(self.currentFontSize)
                    self.onFontSizeChanged?(self.currentFontSize)
                    Logger.clauntty.debugOnly("Font size increased to \(self.currentFontSize)")
                    // Notify SSH of new terminal size after font change
                    self.notifyTerminalSizeChanged(surface: surface)
                    // Update selection handles after font change (positions change)
                    self.scheduleSelectionHandleUpdate()
                }
            }
        }
    }

    private func decreaseFontSize(surface: ghostty_surface_t) {
        let action = "decrease_font_size:1"
        // Dispatch to background queue to avoid potential main thread blocking
        terminalIOQueue.async { [weak self] in
            let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
            if success {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentFontSize = max(self.currentFontSize - 1, 6)
                    FontSizePreference.save(self.currentFontSize)
                    self.onFontSizeChanged?(self.currentFontSize)
                    Logger.clauntty.debugOnly("Font size decreased to \(self.currentFontSize)")
                    // Notify SSH of new terminal size after font change
                    self.notifyTerminalSizeChanged(surface: surface)
                    // Update selection handles after font change (positions change)
                    self.scheduleSelectionHandleUpdate()
                }
            }
        }
    }

    /// Reset font size to default (9pt)
    func resetFontSize() {
        guard let surface = self.surface else { return }
        let action = "reset_font_size"
        // Dispatch to background queue to avoid potential main thread blocking
        terminalIOQueue.async { [weak self] in
            let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
            if success {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentFontSize = 9.0  // Use actual default
                    FontSizePreference.reset()
                    self.onFontSizeChanged?(self.currentFontSize)
                    Logger.clauntty.info("Font size reset to default")
                    // Notify SSH of new terminal size after font change
                    self.notifyTerminalSizeChanged(surface: surface)
                }
            }
        }
    }

    /// Query new terminal size and notify callback if changed
    private func notifyTerminalSizeChanged(surface: ghostty_surface_t) {
        // Small delay to let Ghostty recalculate after font change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            let surfaceSize = ghostty_surface_size(surface)
            let newRows = surfaceSize.rows
            let newCols = surfaceSize.columns

            if newRows != self.terminalSize.rows || newCols != self.terminalSize.columns {
                self.terminalSize = (newRows, newCols)
                Logger.clauntty.info("Font change: terminal now \(newCols)x\(newRows)")
                self.onTerminalSizeChanged?(newRows, newCols)
            }
        }
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

        // Show paste menu if clipboard has content (tap anywhere to paste)
        let hasContent = UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        if hasContent {
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
        hideSelectionHandles()
    }

    // MARK: - Selection & Copy/Paste

    /// Track if we're in selection mode
    private var isSelecting = false

    /// Track if edit menu is currently visible
    private var isEditMenuVisible = false

    /// Selection handle views for adjusting selection bounds
    private lazy var startHandle: SelectionHandleView = {
        let handle = SelectionHandleView(type: .start)
        handle.isHidden = true
        handle.onDragBegan = { [weak self] in
            self?.handleSelectionHandleDragBegan()
        }
        handle.onDrag = { [weak self] point in
            self?.handleStartHandleDrag(to: point)
        }
        handle.onDragEnded = { [weak self] in
            self?.handleSelectionHandleDragEnded()
        }
        return handle
    }()

    private lazy var endHandle: SelectionHandleView = {
        let handle = SelectionHandleView(type: .end)
        handle.isHidden = true
        handle.onDragBegan = { [weak self] in
            self?.handleSelectionHandleDragBegan()
        }
        handle.onDrag = { [weak self] point in
            self?.handleEndHandleDrag(to: point)
        }
        handle.onDragEnded = { [weak self] in
            self?.handleSelectionHandleDragEnded()
        }
        return handle
    }()

    /// Track selection bounds for handle dragging
    private var selectionStartPoint: CGPoint = .zero
    private var selectionEndPoint: CGPoint = .zero

    /// Track which handle is being dragged (for continuous drag)
    private enum DraggingHandle { case none, start, end }
    private var draggingHandle: DraggingHandle = .none

    /// Last drag position for final update
    private var lastDragPoint: CGPoint = .zero

    private func setupSelectionHandles() {
        addSubview(startHandle)
        addSubview(endHandle)
    }

    private func showSelectionHandles() {
        guard let surface = self.surface else { return }
        guard ghostty_surface_has_selection(surface) else {
            hideSelectionHandles()
            return
        }

        // Get selection pixel bounds from Ghostty
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            hideSelectionHandles()
            return
        }
        defer { ghostty_surface_free_text(surface, &text) }

        // Check if selection is visible (valid pixel coordinates)
        guard text.tl_px_x >= 0 && text.tl_px_y >= 0 &&
              text.br_px_x >= 0 && text.br_px_y >= 0 else {
            hideSelectionHandles()
            return
        }

        // Store positions for drag handling
        selectionStartPoint = CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        selectionEndPoint = CGPoint(x: text.br_px_x, y: text.br_px_y)

        // Position and show handles
        startHandle.positionAt(selectionStartPoint)
        endHandle.positionAt(selectionEndPoint)

        startHandle.isHidden = false
        endHandle.isHidden = false

        // Bring handles to front (above Metal layer)
        bringSubviewToFront(startHandle)
        bringSubviewToFront(endHandle)

        // Animate appearance
        startHandle.alpha = 0
        endHandle.alpha = 0
        UIView.animate(withDuration: 0.15) {
            self.startHandle.alpha = 1
            self.endHandle.alpha = 1
        }
    }

    private func hideSelectionHandles() {
        startHandle.isHidden = true
        endHandle.isHidden = true
    }

    /// Work item for debounced handle updates
    private var handleUpdateWorkItem: DispatchWorkItem?

    /// Schedule a debounced selection handle update (for rapid zoom events)
    private func scheduleSelectionHandleUpdate() {
        // Cancel any pending update
        handleUpdateWorkItem?.cancel()

        // Schedule new update with short delay
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateSelectionHandlePositions()
        }
        handleUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Update handle positions from current selection bounds (e.g., after font size change)
    private func updateSelectionHandlePositions() {
        guard let surface = self.surface else { return }
        guard !startHandle.isHidden else { return }  // Only update if handles are visible

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            hideSelectionHandles()
            return
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard text.tl_px_x >= 0 && text.br_px_x >= 0 else {
            hideSelectionHandles()
            return
        }

        selectionStartPoint = CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        selectionEndPoint = CGPoint(x: text.br_px_x, y: text.br_px_y)
        startHandle.positionAt(selectionStartPoint)
        endHandle.positionAt(selectionEndPoint)
    }

    private func handleSelectionHandleDragBegan() {
        // Dismiss edit menu while dragging
        dismissEditMenu()
    }

    private func handleStartHandleDrag(to point: CGPoint) {
        guard let surface = self.surface else { return }

        // Always update handle position visually (smooth)
        startHandle.positionAt(point)
        lastDragPoint = point

        // On first drag event, start the selection from anchor point
        if draggingHandle != .start {
            draggingHandle = .start
            // Press at anchor (end point) to start continuous drag
            ghostty_surface_mouse_pos(surface, Double(selectionEndPoint.x), Double(selectionEndPoint.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        }

        // Move to current drag position (button still held)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
    }

    private func handleEndHandleDrag(to point: CGPoint) {
        guard let surface = self.surface else { return }

        // Always update handle position visually (smooth)
        endHandle.positionAt(point)
        lastDragPoint = point

        // On first drag event, start the selection from anchor point
        if draggingHandle != .end {
            draggingHandle = .end
            // Press at anchor (start point) to start continuous drag
            ghostty_surface_mouse_pos(surface, Double(selectionStartPoint.x), Double(selectionStartPoint.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        }

        // Move to current drag position (button still held)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
    }

    private func handleSelectionHandleDragEnded() {
        guard let surface = self.surface else { return }

        // Release mouse button to finalize selection
        if draggingHandle != .none {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        }

        draggingHandle = .none

        // Update handle positions from actual selection bounds
        var text = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &text) {
            if text.tl_px_x >= 0 && text.br_px_x >= 0 {
                selectionStartPoint = CGPoint(x: text.tl_px_x, y: text.tl_px_y)
                selectionEndPoint = CGPoint(x: text.br_px_x, y: text.br_px_y)
                startHandle.positionAt(selectionStartPoint)
                endHandle.positionAt(selectionEndPoint)
            }
            ghostty_surface_free_text(surface, &text)
        }

        // Show edit menu at end handle position
        if ghostty_surface_has_selection(surface) {
            showEditMenu(at: selectionEndPoint)
        }
    }

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

            // Show handles and edit menu if there's a selection
            if ghostty_surface_has_selection(surface) {
                showSelectionHandles()
                showEditMenu(at: location)
            }

        case .cancelled:
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            isSelecting = false
            hideSelectionHandles()

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
            return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
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
        Logger.clauntty.info("[PASTE] paste() called")

        // Try text first
        if let string = UIPasteboard.general.string {
            Logger.clauntty.info("[PASTE] clipboard has string: \(string.count) chars, \(string.utf8.count) bytes")

            // Convert newlines to carriage returns for terminal
            let terminalText = string.replacingOccurrences(of: "\n", with: "\r")

            // Check if paste contains multiple lines (needs bracketed paste)
            let isMultiline = string.contains("\n") || string.contains("\r")

            if isMultiline {
                // Wrap with bracketed paste for multi-line content
                // This ensures apps like Claude Code, vim, etc. handle it atomically
                // ESC[200~ = start bracketed paste, ESC[201~ = end bracketed paste
                let bracketStart = "\u{1B}[200~"
                let bracketEnd = "\u{1B}[201~"
                let wrappedText = bracketStart + terminalText + bracketEnd
                Logger.clauntty.info("[PASTE] multi-line, sending with bracketed paste wrapper")
                if let data = wrappedText.data(using: .utf8) {
                    onTextInput?(data)
                }
            } else {
                // Single line - send directly without bracketed paste
                Logger.clauntty.info("[PASTE] single-line, sending directly")
                if let data = terminalText.data(using: .utf8) {
                    onTextInput?(data)
                }
            }
            return
        } else {
            Logger.clauntty.info("[PASTE] clipboard has no string")
        }

        // Try images - upload to remote and paste file path
        if let image = UIPasteboard.general.image {
            Logger.clauntty.info("Pasting image from clipboard")
            onImagePaste?(image)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        // TODO: Implement select all if Ghostty supports it
        Logger.clauntty.debugOnly("Select all not yet implemented")
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
                Logger.clauntty.verbose("[SCROLL] calling ghostty_surface_mouse_scroll with y=\(scrollLines)")
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollLines), 0)
                scrollAccumulator = scrollAccumulator.truncatingRemainder(dividingBy: scrollThreshold)

                // Update selection handles after scroll (positions change)
                updateSelectionHandlePositions()

                // Check if we're near the top of scrollback (for lazy loading)
                // Skip this when on alternate screen - no scrollback there
                if let callback = onScrollNearTop, !isAlternateScreen {
                    let offset = scrollbackOffset
                    if offset < scrollNearTopThreshold {
                        callback(offset)
                    }
                }
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
        Logger.clauntty.debugOnly("addSublayer called, layer.bounds=\(NSCoder.string(for: self.layer.bounds))")

        // Store reference first
        ghosttySublayer = sublayer

        // Add to layer hierarchy
        self.layer.addSublayer(sublayer)

        // Immediately trigger size update with current bounds
        // This ensures the sublayer gets the correct size even if layoutSubviews hasn't run yet
        // Always reserve space - different amounts for expanded vs collapsed bar
        let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
        let effectiveSize = CGSize(
            width: bounds.width,
            height: bounds.height - accessoryBarReserve
        )
        sizeDidChange(effectiveSize)
    }

    /// Reference to Ghostty's IOSurfaceLayer for frame updates
    private var ghosttySublayer: CALayer?

    /// Track previous bounds to detect rotation
    private var lastBounds: CGRect = .zero

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        Logger.clauntty.debugOnly("layoutSubviews: bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)), lastBounds=\(Int(self.lastBounds.width))x\(Int(self.lastBounds.height)), keyboardHeight=\(Int(self.keyboardHeight))")

        // Detect rotation (aspect ratio flip)
        let rotated = detectRotation(from: lastBounds, to: bounds)
        lastBounds = bounds

        // Account for accessory bar when calculating effective size
        // Always reserve space - different amounts for expanded vs collapsed bar
        let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
        let effectiveSize = CGSize(
            width: bounds.width,
            height: bounds.height - accessoryBarReserve
        )
        Logger.clauntty.debugOnly("layoutSubviews: effectiveSize=\(Int(effectiveSize.width))x\(Int(effectiveSize.height)), rotated=\(rotated)")
        sizeDidChange(effectiveSize)

        // Update selection handles after layout change
        updateSelectionHandlePositions()

        // After rotation, force aggressive refresh to fix viewport position
        if rotated {
            let safeInsets = safeAreaInsets
            Logger.clauntty.info("[ROTATE] Rotation detected! bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)), kbHeight=\(Int(self.keyboardHeight)), isSoftwareKeyboardHidden=\(self.isSoftwareKeyboardHidden), safeArea=(t:\(Int(safeInsets.top)),b:\(Int(safeInsets.bottom)),l:\(Int(safeInsets.left)),r:\(Int(safeInsets.right)))")

            // Set rotation flag to ignore spurious keyboard notifications
            isRotating = true

            // Re-enforce keyboard hidden state during rotation
            // iOS may send spurious keyboard notifications during rotation
            if isSoftwareKeyboardHidden {
                Logger.clauntty.info("[ROTATE] Re-enforcing keyboard hidden state via reloadInputViews()")
                reloadInputViews()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.handleRotationComplete()
            }
        }
    }

    /// Detect rotation by checking if aspect ratio flipped (portrait ↔ landscape)
    private func detectRotation(from oldBounds: CGRect, to newBounds: CGRect) -> Bool {
        guard oldBounds.width > 0 && oldBounds.height > 0 else { return false }
        guard newBounds.width > 0 && newBounds.height > 0 else { return false }
        let wasPortrait = oldBounds.height > oldBounds.width
        let isPortrait = newBounds.height > newBounds.width
        return wasPortrait != isPortrait
    }

    /// Handle rotation completion - reset viewport and force redraw
    private func handleRotationComplete() {
        guard let surface = self.surface else { return }

        // Clear rotation flag
        isRotating = false
        Logger.clauntty.info("[ROTATE] Rotation complete, cleared isRotating flag")

        let gridSize = ghostty_surface_size(surface)
        let scrollOffset = ghostty_surface_scrollback_offset(surface)
        Logger.clauntty.debugOnly("handleRotationComplete: grid=\(gridSize.columns)x\(gridSize.rows), scrollOffset=\(scrollOffset), isAltScreen=\(self.isAlternateScreen), bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height))")

        // For alternate screen apps (Claude Code, vim, etc.), scroll to bottom
        // to ensure cursor and content are visible
        if isAlternateScreen {
            Logger.clauntty.debugOnly("handleRotationComplete: scrolling to bottom for alt screen")
            // Scroll to bottom of viewport (0 offset = at bottom/current content)
            ghostty_surface_mouse_scroll(surface, 0, -1000, 0)  // Large negative = scroll to bottom
        }

        // Force complete redraw
        Logger.clauntty.debugOnly("handleRotationComplete: calling forceRedraw")
        forceRedraw()

        // Send SIGWINCH to remote app to trigger repaint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            Logger.clauntty.debugOnly("handleRotationComplete: sending SIGWINCH \(self.terminalSize.columns)x\(self.terminalSize.rows)")
            self.onTerminalSizeChanged?(self.terminalSize.rows, self.terminalSize.columns)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Set up accessory bar in window (so it appears above keyboard)
            setupAccessoryBarInWindow()

            let scale = window!.screen.scale
            Logger.clauntty.debugOnly("didMoveToWindow: window scale=\(scale), bounds=\(NSCoder.string(for: self.bounds))")

            // Account for accessory bar when calculating effective size
            // Always reserve space - different amounts for expanded vs collapsed bar
            let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
            let effectiveSize = CGSize(
                width: bounds.width,
                height: bounds.height - accessoryBarReserve
            )
            sizeDidChange(effectiveSize)

            // Auto-show keyboard when terminal appears (only if this is the active tab)
            // Delay slightly to ensure view hierarchy is ready
            if isActiveTab {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self, self.isActiveTab else { return }
                    _ = self.becomeFirstResponder()
                }
            }
        } else {
            // View removed from window - clean up accessory bar
            accessoryBar.removeFromSuperview()
            Logger.clauntty.debugOnly("didMoveToWindow: removed from window, cleaned up accessory bar")
        }
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface = self.surface else { return }

        // Skip invalid sizes (too small to be useful)
        guard size.width > 50 && size.height > 50 else {
            Logger.clauntty.debugOnly("Skipping invalid size: \(Int(size.width))x\(Int(size.height))")
            return
        }

        // Use window's screen scale, or fall back to main screen
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let pixelWidth = UInt32(size.width * scale)
        let pixelHeight = UInt32(size.height * scale)

        Logger.clauntty.debugOnly("sizeDidChange: \(Int(size.width))x\(Int(size.height))pt @\(scale)x = \(pixelWidth)x\(pixelHeight)px")

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

        Logger.clauntty.debugOnly("Terminal grid: \(newCols) cols x \(newRows) rows")

        if newRows != terminalSize.rows || newCols != terminalSize.columns {
            terminalSize = (newRows, newCols)
            Logger.clauntty.debugOnly("Terminal size changed, notifying SSH: \(newCols)x\(newRows)")
            onTerminalSizeChanged?(newRows, newCols)

            // Force re-render after size change with slight delay
            // Skip if already in forceRedraw (to avoid infinite loop)
            if !isForceRedrawing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.forceRedraw()
                }
            }
        }
    }

    /// Flag to prevent recursive forceRedraw calls during size changes
    private var isForceRedrawing = false

    /// Force Ghostty to completely re-render the terminal.
    /// This works by briefly changing the size, which forces Ghostty to
    /// recalculate and redraw everything. Useful after tab switches or
    /// reconnections where the Metal layer may have stale content.
    func forceRedraw() {
        guard !isForceRedrawing else {
            Logger.clauntty.debugOnly("forceRedraw: skipped (already redrawing)")
            return
        }
        guard let surface = self.surface else { return }
        guard bounds.width > 50 && bounds.height > 50 else { return }

        isForceRedrawing = true
        defer { isForceRedrawing = false }

        let scale = window?.screen.scale ?? UIScreen.main.scale
        // Always reserve space for accessory bar - different amounts for expanded vs collapsed
        let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
        let effectiveHeight = bounds.height - accessoryBarReserve
        let w = UInt32(bounds.width * scale)
        let h = UInt32(effectiveHeight * scale)

        // Log state before redraw
        let gridBefore = ghostty_surface_size(surface)
        Logger.clauntty.debugOnly("forceRedraw: BEFORE grid=\(gridBefore.columns)x\(gridBefore.rows), effectiveSize=\(Int(self.bounds.width))x\(Int(effectiveHeight))")

        // Briefly change size then restore - forces Ghostty to re-render
        ghostty_surface_set_size(surface, w - 1, h)
        ghostty_surface_set_size(surface, w, h)
        ghostty_surface_refresh(surface)

        // Log state after redraw
        let gridAfter = ghostty_surface_size(surface)
        Logger.clauntty.debugOnly("forceRedraw: AFTER grid=\(gridAfter.columns)x\(gridAfter.rows)")
    }

    // MARK: - Focus & Active State

    /// Whether this surface is the active tab
    private var isActiveTab: Bool = true

    /// Whether the app is currently backgrounded
    private var isAppBackgrounded: Bool = false

    /// Serial queue for terminal I/O operations
    /// CRITICAL: ghostty_surface_write_pty_output MUST NOT be called from main thread
    /// because it can block forever waiting for surface mailbox space, and the main
    /// thread is the consumer of that mailbox. Calling from main = self-deadlock.
    private let terminalIOQueue = DispatchQueue(label: "com.clauntty.terminal-io", qos: .userInteractive)

    /// Set whether this terminal surface is the active tab
    /// Inactive surfaces don't render their cursor and lose keyboard focus
    func setActive(_ active: Bool) {
        Logger.clauntty.info("setActive(\(active)) called, isActiveTab=\(isActiveTab)")
        guard active != isActiveTab else {
            Logger.clauntty.info("setActive: skipped (already \(active))")
            return
        }
        isActiveTab = active

        // Notify about active state change (for power management)
        onActiveStateChanged?(active)

        if active {
            // Becoming active - gain focus and show keyboard
            Logger.clauntty.debugOnly("Surface becoming active")

            // Re-setup accessory bar in window (in case it was removed)
            setupAccessoryBarInWindow()

            // Show this tab's accessory bar and bring to front
            accessoryBar.isHidden = false
            window?.bringSubviewToFront(accessoryBar)

            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
            focusDidChange(true)

            // Resume rendering for this tab FIRST (before redraw attempts)
            // Must un-occlude before forceRedraw() or the render won't happen
            if let surface = self.surface, !isAppBackgrounded {
                ghostty_surface_set_occlusion(surface, true)
                Logger.clauntty.debugOnly("Tab active: surface visible")
            }

            // Force size update to ensure Metal layer frame is correct after tab switch
            // Always reserve space - different amounts for expanded vs collapsed bar
            let accessoryBarReserve: CGFloat = keyboardHeight > 0 ? expandedAccessoryBarHeight : collapsedAccessoryBarHeight
            let effectiveSize = CGSize(
                width: bounds.width,
                height: bounds.height - accessoryBarReserve
            )
            sizeDidChange(effectiveSize)

            // Force complete re-render by toggling size
            // This fixes blank/partial screen issues when switching tabs
            forceRedraw()

            // Force the remote shell to redraw by sending a SIGWINCH
            // This triggers the shell/app (like Claude Code) to repaint
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.onTerminalSizeChanged?(self.terminalSize.rows, self.terminalSize.columns)
                Logger.clauntty.debugOnly("Tab active: sent SIGWINCH to force remote redraw")
            }
        } else {
            // Becoming inactive - lose focus to hide cursor and accessory bar
            Logger.clauntty.debugOnly("Surface becoming inactive")

            // Stop rendering for inactive tabs to prevent mutex contention
            if let surface = self.surface {
                ghostty_surface_set_occlusion(surface, false)
                Logger.clauntty.debugOnly("Tab inactive: surface occluded")
            }

            // Hide this tab's accessory bar (the active tab's bar will show)
            accessoryBar.isHidden = true

            focusDidChange(false)
            if isFirstResponder {
                _ = resignFirstResponder()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        // Only allow becoming first responder if this is the active tab
        guard isActiveTab else {
            Logger.clauntty.debugOnly("becomeFirstResponder: rejected - not active tab")
            return false
        }

        let result = super.becomeFirstResponder()
        Logger.clauntty.debugOnly("becomeFirstResponder: result=\(result), isFirstResponder=\(self.isFirstResponder)")
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
        Logger.clauntty.verbose("[CURSOR] focusDidChange(\(focused)) BEFORE: \(self.getCursorInfo(surface))")
        ghostty_surface_set_focus(surface, focused)
        Logger.clauntty.verbose("[CURSOR] focusDidChange(\(focused)) AFTER: \(self.getCursorInfo(surface))")
    }

    /// Get cursor position and terminal state for debugging
    private func getCursorInfo(_ surface: ghostty_surface_t) -> String {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let altScreen = ghostty_surface_is_alternate_screen(surface)
        let size = ghostty_surface_size(surface)
        return "cursor=(\(Int(x)),\(Int(y))) altScreen=\(altScreen) grid=\(size.columns)x\(size.rows)"
    }

    // MARK: - SSH Data Flow

    /// Write SSH output to the terminal for display
    /// This feeds data directly to Ghostty's terminal processor
    ///
    /// IMPORTANT: This dispatches to a background queue because ghostty_surface_write_pty_output
    /// can block indefinitely waiting for the surface mailbox. Since the main thread consumes
    /// that mailbox, calling from main thread would deadlock.
    func writeSSHOutput(_ data: Data) {
        guard let surface = self.surface else {
            Logger.clauntty.warning("Cannot write SSH output: no surface")
            return
        }

        // Dispatch to background queue to avoid main thread deadlock
        // The surface mailbox is consumed by the main thread, so calling
        // ghostty_surface_write_pty_output from main = self-deadlock when queue fills
        terminalIOQueue.async { [weak self] in
            guard self != nil else { return }

            Logger.clauntty.debugOnly("writeSSHOutput: processing \(data.count) bytes on terminal-io queue")

            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_write_pty_output(surface, ptr, UInt(data.count))
            }

            Logger.clauntty.debugOnly("writeSSHOutput: completed \(data.count) bytes")
        }
    }

    /// Prepend scrollback data to the beginning of the terminal's scrollback buffer.
    /// This is used for lazy-loading older scrollback history after the current screen
    /// has been displayed.
    /// - Parameter data: Raw terminal data to parse and prepend
    /// - Returns: true if successful, false otherwise
    @discardableResult
    func prependScrollback(_ data: Data) -> Bool {
        guard let surface = self.surface else {
            Logger.clauntty.warning("Cannot prepend scrollback: no surface")
            return false
        }

        Logger.clauntty.debugOnly("prependScrollback: starting with \(data.count) bytes")

        // Copy to contiguous array to ensure proper alignment
        let bytes = [UInt8](data)
        Logger.clauntty.debugOnly("prependScrollback: copied to array, calling ghostty")

        let success = bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard let ptr = buffer.baseAddress else {
                Logger.clauntty.error("prependScrollback: buffer has no base address")
                return false
            }
            // Cast UInt8 pointer to CChar pointer (both are 1-byte aligned)
            return ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { charPtr in
                return ghostty_surface_prepend_scrollback(surface, charPtr, UInt(bytes.count))
            }
        }

        Logger.clauntty.debugOnly("prependScrollback: ghostty returned \(success)")

        if success {
            Logger.clauntty.debugOnly("Prepended \(data.count) bytes of scrollback")
        } else {
            Logger.clauntty.warning("Failed to prepend scrollback")
        }
        return success
    }

    /// Get the current scrollback offset (distance from top of scrollback buffer).
    /// Returns 0 when viewport is at the very top, increases as user scrolls down.
    /// This can be used to detect when to lazy-load additional scrollback.
    var scrollbackOffset: UInt {
        guard let surface = self.surface else { return 0 }
        return ghostty_surface_scrollback_offset(surface)
    }

    /// Returns true if the terminal is on the alternate screen (vim, less, htop, etc.)
    /// When on the alternate screen, there is no scrollback and scroll events go to the app.
    var isAlternateScreen: Bool {
        guard let surface = self.surface else { return false }
        return ghostty_surface_is_alternate_screen(surface)
    }

    // MARK: - Text Capture (for testing)

    /// Capture all visible text in the terminal viewport.
    /// Used for automated testing to verify rendering is correct.
    /// - Returns: The visible terminal text as a string, or nil if capture failed
    func captureVisibleText() -> String? {
        guard let surface = self.surface else {
            Logger.clauntty.warning("captureVisibleText: no surface")
            return nil
        }

        // Log terminal state for debugging
        let gridSize = ghostty_surface_size(surface)
        let scrollOffset = ghostty_surface_scrollback_offset(surface)
        let isAltScreen = ghostty_surface_is_alternate_screen(surface)

        // Get cursor position
        var cursorX: Double = 0
        var cursorY: Double = 0
        var cursorW: Double = 0
        var cursorH: Double = 0
        ghostty_surface_ime_point(surface, &cursorX, &cursorY, &cursorW, &cursorH)

        Logger.clauntty.debugOnly("captureVisibleText: grid=\(gridSize.columns)x\(gridSize.rows), scrollOffset=\(scrollOffset), altScreen=\(isAltScreen), cursor=(\(Int(cursorX)),\(Int(cursorY))), bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height))")

        // Create selection spanning entire visible viewport
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
        sel.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        sel.top_left.x = 0
        sel.top_left.y = 0
        sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        sel.bottom_right.x = 0
        sel.bottom_right.y = 0
        sel.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else {
            Logger.clauntty.warning("captureVisibleText: ghostty_surface_read_text failed")
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else {
            Logger.clauntty.info("captureVisibleText: empty text")
            return ""
        }

        let result = String(cString: ptr)
        Logger.clauntty.debugOnly("captureVisibleText: captured \(result.count) chars, lines=\(result.components(separatedBy: "\n").count)")

        return result
    }

    /// Capture a screenshot of the terminal surface.
    /// Used for tab selector preview when switching tabs.
    /// - Returns: A UIImage of the current terminal content, or nil if capture failed
    func captureScreenshot() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else {
            Logger.clauntty.debugOnly("captureScreenshot: invalid bounds")
            return nil
        }

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }

        Logger.clauntty.debugOnly("captureScreenshot: captured \(Int(image.size.width))x\(Int(image.size.height)) image")
        return image
    }

    // MARK: - UIKeyInput

    var hasText: Bool {
        return true
    }

    func insertText(_ text: String) {
        Logger.clauntty.verbose("insertText called: '\(text)' (\(text.count) chars)")

        // Check if Ctrl modifier is active from accessory bar
        if accessoryBar.consumeCtrlModifier() {
            // Convert character to control character (Ctrl+A = 0x01, Ctrl+C = 0x03, etc.)
            if let char = text.lowercased().first,
               let asciiValue = char.asciiValue,
               asciiValue >= 97 && asciiValue <= 122 {  // a-z
                let ctrlChar = UInt8(asciiValue - 96)  // a=1, b=2, ..., z=26
                onTextInput?(Data([ctrlChar]))
                Logger.clauntty.debugOnly("Ctrl+\(char) sent as 0x\(String(format: "%02X", ctrlChar))")
                return
            }
        }

        // Convert newline (LF) to carriage return (CR) for terminal compatibility
        // iOS keyboard sends \n but terminals expect \r for Enter
        let terminalText = text.replacingOccurrences(of: "\n", with: "\r")

        // Send text input to SSH (not directly to Ghostty)
        // SSH server will echo it back if needed, and we'll display via writeSSHOutput
        if let data = terminalText.data(using: .utf8) {
            onTextInput?(data)
        }
    }

    func deleteBackward() {
        Logger.clauntty.verbose("deleteBackward called")
        // Send backspace (ASCII DEL 0x7F or BS 0x08) to SSH
        let backspace = Data([0x7F])  // DEL character
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
