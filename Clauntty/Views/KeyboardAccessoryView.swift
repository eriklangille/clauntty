import UIKit
import os.log

/// Keyboard accessory bar with terminal-specific keys and arrow "nipple"
/// iOS Notes-style pill shape with fixed center nipple and evenly distributed buttons
/// Uses UIGlassEffect on iOS 26+ or UIBlurEffect fallback for native look
class KeyboardAccessoryView: UIView {

    /// Callback for sending key data to the terminal
    var onKeyInput: ((Data) -> Void)?

    /// Callback to dismiss keyboard (resign first responder)
    var onDismissKeyboard: (() -> Void)?

    /// Callback to show keyboard (become first responder)
    var onShowKeyboard: (() -> Void)?

    /// Callback for voice input (transcribed text)
    var onVoiceInput: ((String) -> Void)?

    /// Callback to prompt model download (when mic tapped but model not ready)
    var onPromptModelDownload: (() -> Void)?

    /// Callback to start recording
    var onStartRecording: (() -> Void)?

    /// Callback to stop recording and transcribe
    var onStopRecording: (() -> Void)?

    /// Callback to cancel recording without transcribing
    var onCancelRecording: (() -> Void)?

    /// Whether Ctrl modifier is active (sticky toggle)
    private var isCtrlActive = false {
        didSet {
            updateCtrlButton()
        }
    }

    /// Whether Option modifier is active (held via long-press on Ctrl)
    private var isOptionActive = false

    /// Currently visible tooltip (for hold-down feedback)
    private var activeTooltip: HoldTooltip?

    /// Track if keyboard is currently visible (for icon state)
    private(set) var isKeyboardShown = true

    /// Track if mic is currently recording
    private(set) var isRecording = false {
        didSet {
            updateMicButtonAppearance()
        }
    }

    /// Track if speech model is ready
    private(set) var isSpeechModelReady = false {
        didSet {
            updateMicButtonAppearance()
        }
    }

    /// Track if speech model is downloading
    private(set) var isSpeechModelDownloading = false {
        didSet {
            updateMicButtonAppearance()
            updateDownloadProgressVisibility()
        }
    }

    /// Download progress (0-1)
    private(set) var downloadProgress: Float = 0 {
        didSet {
            updateDownloadProgress()
        }
    }

    /// Track mic touch start time to differentiate tap vs hold
    private var micTouchStartTime: Date?

    /// Timer that fires when hold threshold is reached (starts push-to-talk)
    private var micHoldTimer: Timer?

    /// Whether we're in push-to-talk mode (started via hold, not tap)
    private var isPushToTalkMode = false

    /// Threshold to distinguish tap from hold (seconds)
    private let holdThreshold: TimeInterval = 0.3

    // MARK: - Views

    /// Main container (pill-shaped glass effect)
    private let containerEffectView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = true
            effect = glassEffect
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        let view = UIVisualEffectView(effect: effect)
        view.clipsToBounds = true
        return view
    }()

    /// Left stack view for buttons before nipple
    private let leftStackView = UIStackView()

    /// Right stack view for buttons after nipple
    private let rightStackView = UIStackView()

    /// Fixed center nipple container
    private let nippleContainerView = UIView()

    /// The arrow nipple
    private let nippleView = ArrowNippleView()

    /// Ctrl button reference for state updates
    private let ctrlButton = UIButton(type: .system)

    /// Ctrl container reference for expanded hit area
    private var ctrlContainer: UIView?

    /// Tab button reference for tooltip positioning
    private let tabButton = UIButton(type: .system)

    /// Tab container reference for expanded hit area
    private var tabContainer: UIView?

    /// Mic button (replaces keyboard toggle)
    private let micButton = UIButton(type: .system)

    /// Progress indicator for model download
    private let downloadProgressView = CircularProgressView()

    /// Container for mic button and progress indicator
    private var micContainer: UIStackView?

    /// Spacer views for equal edge spacing (equalSpacing distribution needs items at edges)
    private let leftLeadingSpacer = UIView()
    private let leftTrailingSpacer = UIView()
    private let rightLeadingSpacer = UIView()
    private let rightTrailingSpacer = UIView()

    // MARK: - Constraints

    private var containerLeadingConstraint: NSLayoutConstraint!
    private var containerTrailingConstraint: NSLayoutConstraint!
    private var containerWidthConstraint: NSLayoutConstraint!
    private var containerCenterXConstraint: NSLayoutConstraint!

    // MARK: - Constants

    private let barHeight: CGFloat = 44
    private let nippleSize: CGFloat = 36
    private let horizontalPadding: CGFloat = 12
    private let iconSize: CGFloat = 12
    private let textSize: CGFloat = 14
    private let topPadding: CGFloat = 8
    private let collapsedWidth: CGFloat = 110  // keyboard button + nipple + padding

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear

        setupContainerView()
        setupNipple()
        setupStackViews()
        setupButtons()
        setupConstraints()
        setupDismissGestures()
    }

    // MARK: - Container Setup

    private func setupContainerView() {
        containerEffectView.layer.cornerRadius = barHeight / 2
        containerEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerEffectView)
    }

    private func setupNipple() {
        // Nipple is added to self so it can be truly screen-centered
        nippleContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nippleContainerView)

        nippleView.onArrowInput = { [weak self] direction in
            self?.sendArrow(direction)
        }
        nippleView.translatesAutoresizingMaskIntoConstraints = false
        nippleContainerView.addSubview(nippleView)

        // Bring nipple to front
        bringSubviewToFront(nippleContainerView)
    }

    private func setupStackViews() {
        // Left stack view - evenly distributed, centered vertically
        leftStackView.axis = .horizontal
        leftStackView.distribution = .equalSpacing
        leftStackView.alignment = .center
        leftStackView.translatesAutoresizingMaskIntoConstraints = false
        containerEffectView.contentView.addSubview(leftStackView)

        // Right stack view - evenly distributed, centered vertically
        rightStackView.axis = .horizontal
        rightStackView.distribution = .equalSpacing
        rightStackView.alignment = .center
        rightStackView.translatesAutoresizingMaskIntoConstraints = false
        containerEffectView.contentView.addSubview(rightStackView)
    }

    private func setupButtons() {
        // Left section buttons: spacer, keyboard toggle, Esc, Tab, Ctrl, spacer
        // Spacers create equal edge spacing with .equalSpacing distribution

        // Leading spacer (creates gap at left edge)
        leftStackView.addArrangedSubview(leftLeadingSpacer)

        // Mic button (replaces keyboard toggle)
        updateMicButtonAppearance()
        micButton.tintColor = .label
        micButton.accessibilityIdentifier = "Mic"
        micButton.addTarget(self, action: #selector(micTouchDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micTouchUp), for: [.touchUpInside, .touchUpOutside])
        micButton.addTarget(self, action: #selector(micTouchCancelled), for: .touchCancel)

        // Setup download progress view (initially hidden)
        downloadProgressView.isHidden = true
        downloadProgressView.translatesAutoresizingMaskIntoConstraints = false

        let micContainerStack = createButtonWithHint(micButton, hint: nil)
        // Add progress view below the mic button stack
        let micWithProgress = UIStackView(arrangedSubviews: [micContainerStack, downloadProgressView])
        micWithProgress.axis = .vertical
        micWithProgress.alignment = .center
        micWithProgress.spacing = 2

        NSLayoutConstraint.activate([
            downloadProgressView.widthAnchor.constraint(equalToConstant: 24),
            downloadProgressView.heightAnchor.constraint(equalToConstant: 4),
        ])

        leftStackView.addArrangedSubview(micWithProgress)
        micContainer = micWithProgress

        // Esc button
        let escButton = createIconButton("escape", accessibilityId: "Esc", tooltip: "esc") { [weak self] in
            self?.sendEscape()
        }
        let escContainer = createButtonWithHint(escButton, hint: nil)
        leftStackView.addArrangedSubview(escContainer)

        // Tab button with long-press for Shift+Tab
        // Gestures on container so hint label is part of hit area
        tabButton.setImage(
            UIImage(systemName: "arrow.right.to.line")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        tabButton.tintColor = .label
        tabButton.accessibilityIdentifier = "Tab"
        tabButton.isAccessibilityElement = true
        tabButton.isUserInteractionEnabled = false  // Let container handle touches
        let tabContainerView = createButtonWithHint(tabButton, hint: "⇧⇥")
        let tabTap = UITapGestureRecognizer(target: self, action: #selector(handleTabTap))
        tabContainerView.addGestureRecognizer(tabTap)
        let tabLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTabLongPress(_:)))
        tabLongPress.minimumPressDuration = 0.2
        tabContainerView.addGestureRecognizer(tabLongPress)
        leftStackView.addArrangedSubview(tabContainerView)
        tabContainer = tabContainerView

        // Ctrl button (tap toggles Ctrl, long-press activates Option)
        // Gestures on container so hint label is part of hit area
        ctrlButton.setImage(
            UIImage(systemName: "control")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        ctrlButton.tintColor = .label
        ctrlButton.accessibilityIdentifier = "Ctrl"
        ctrlButton.isAccessibilityElement = true
        ctrlButton.isUserInteractionEnabled = false  // Let container handle touches
        let ctrlContainerView = createButtonWithHint(ctrlButton, hint: "⌥")
        let ctrlTap = UITapGestureRecognizer(target: self, action: #selector(handleCtrlTap))
        ctrlContainerView.addGestureRecognizer(ctrlTap)
        let ctrlLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCtrlLongPress(_:)))
        ctrlLongPress.minimumPressDuration = 0.2
        ctrlContainerView.addGestureRecognizer(ctrlLongPress)
        leftStackView.addArrangedSubview(ctrlContainerView)
        ctrlContainer = ctrlContainerView

        // Trailing spacer (creates gap before nipple)
        leftStackView.addArrangedSubview(leftTrailingSpacer)

        // Right section buttons: spacer, ^C, ^O, ^B, Enter, spacer

        // Leading spacer (creates gap after nipple)
        rightStackView.addArrangedSubview(rightLeadingSpacer)

        let ctrlCButton = createTextButton("^C") { [weak self] in
            self?.sendCtrlC()
        }
        rightStackView.addArrangedSubview(ctrlCButton)

        let ctrlOButton = createTextButton("^O") { [weak self] in
            self?.sendCtrlO()
        }
        rightStackView.addArrangedSubview(ctrlOButton)

        let ctrlBButton = createTextButton("^B") { [weak self] in
            self?.sendCtrlB()
        }
        rightStackView.addArrangedSubview(ctrlBButton)

        let enterButton = createIconButton("return", accessibilityId: "Enter", tooltip: "↵") { [weak self] in
            self?.sendEnter()
        }
        rightStackView.addArrangedSubview(enterButton)

        // Trailing spacer (creates gap at right edge)
        rightStackView.addArrangedSubview(rightTrailingSpacer)
    }

    private func setupConstraints() {
        // Container view - pill shape
        // Expanded mode: leading/trailing constraints
        containerLeadingConstraint = containerEffectView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding)
        containerTrailingConstraint = containerEffectView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding)

        // Collapsed mode: centered with fixed width
        containerCenterXConstraint = containerEffectView.centerXAnchor.constraint(equalTo: centerXAnchor)
        containerWidthConstraint = containerEffectView.widthAnchor.constraint(equalToConstant: collapsedWidth)
        containerCenterXConstraint.isActive = false
        containerWidthConstraint.isActive = false

        NSLayoutConstraint.activate([
            containerLeadingConstraint,
            containerTrailingConstraint,
            containerEffectView.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
            containerEffectView.heightAnchor.constraint(equalToConstant: barHeight),

            // Nipple container - centered on SELF (screen center)
            nippleContainerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            nippleContainerView.topAnchor.constraint(equalTo: topAnchor, constant: topPadding + (barHeight - nippleSize) / 2),
            nippleContainerView.widthAnchor.constraint(equalToConstant: nippleSize),
            nippleContainerView.heightAnchor.constraint(equalToConstant: nippleSize),

            // Nipple view inside container
            nippleView.topAnchor.constraint(equalTo: nippleContainerView.topAnchor),
            nippleView.bottomAnchor.constraint(equalTo: nippleContainerView.bottomAnchor),
            nippleView.leadingAnchor.constraint(equalTo: nippleContainerView.leadingAnchor),
            nippleView.trailingAnchor.constraint(equalTo: nippleContainerView.trailingAnchor),

            // Left stack view - from container leading to nipple (no fixed padding, spacers create gaps)
            leftStackView.leadingAnchor.constraint(equalTo: containerEffectView.contentView.leadingAnchor, constant: 8),
            leftStackView.trailingAnchor.constraint(equalTo: nippleContainerView.leadingAnchor, constant: -4),
            leftStackView.centerYAnchor.constraint(equalTo: containerEffectView.contentView.centerYAnchor),
            leftStackView.heightAnchor.constraint(equalToConstant: barHeight - 8),

            // Right stack view - from nipple to container trailing (no fixed padding, spacers create gaps)
            rightStackView.leadingAnchor.constraint(equalTo: nippleContainerView.trailingAnchor, constant: 4),
            rightStackView.trailingAnchor.constraint(equalTo: containerEffectView.contentView.trailingAnchor, constant: -8),
            rightStackView.centerYAnchor.constraint(equalTo: containerEffectView.contentView.centerYAnchor),
            rightStackView.heightAnchor.constraint(equalToConstant: barHeight - 8),
        ])
    }

    // MARK: - Layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Force layout update now that we have correct safe area from window
            updateConstraintsForSafeArea()
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateConstraintsForSafeArea()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateConstraintsForSafeArea()
    }

    private func updateConstraintsForSafeArea() {
        let safeInsets: UIEdgeInsets
        if let window = window {
            safeInsets = window.safeAreaInsets
        } else {
            safeInsets = safeAreaInsets
        }

        containerLeadingConstraint.constant = max(horizontalPadding, safeInsets.left + horizontalPadding)
        containerTrailingConstraint.constant = -max(horizontalPadding, safeInsets.right + horizontalPadding)
    }

    // MARK: - Button Creation

    private func createIconButton(_ systemName: String, accessibilityId: String, tooltip: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: systemName)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        button.tintColor = .label
        button.accessibilityIdentifier = accessibilityId
        button.isAccessibilityElement = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)

        // Add tooltip feedback on touch
        if let tooltipText = tooltip {
            button.addAction(UIAction { [weak self] _ in
                self?.showTooltip(above: button, text: tooltipText)
            }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in
                self?.hideTooltipAfterDelay()
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        return button
    }

    private func createTextButton(_ title: String, tooltip: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: textSize, weight: .medium)
        button.setTitleColor(.label, for: .normal)
        button.accessibilityIdentifier = title
        button.isAccessibilityElement = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)

        // Add tooltip feedback on touch
        let tooltipText = tooltip ?? title
        button.addAction(UIAction { [weak self] _ in
            self?.showTooltip(above: button, text: tooltipText)
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            self?.hideTooltipAfterDelay()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private func createHintLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 8, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    private func createButtonWithHint(_ button: UIButton, hint: String?) -> UIStackView {
        let hintLabel = createHintLabel(hint ?? "")
        if hint == nil {
            hintLabel.alpha = 0  // Invisible spacer to maintain consistent height
        }
        let stack = UIStackView(arrangedSubviews: [button, hintLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        return stack
    }

    private func updateCtrlButton() {
        if isCtrlActive {
            ctrlButton.tintColor = .systemBlue
        } else {
            ctrlButton.tintColor = .label
        }
    }

    private func updateMicButtonAppearance() {
        let iconName: String
        let tintColor: UIColor

        if isRecording {
            iconName = "mic.circle.fill"
            tintColor = .systemRed
        } else if isSpeechModelDownloading {
            iconName = "mic.fill"
            tintColor = .systemBlue  // Blue while downloading
        } else {
            iconName = "mic.fill"
            tintColor = isSpeechModelReady ? .label : .secondaryLabel
        }

        micButton.setImage(
            UIImage(systemName: iconName)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        micButton.tintColor = tintColor
    }

    /// Called when keyboard visibility changes externally
    func setKeyboardVisible(_ visible: Bool) {
        Logger.clauntty.debugOnly("[AccessoryBar] setKeyboardVisible(\(visible)) called, was=\(self.isKeyboardShown)")
        isKeyboardShown = visible
    }

    /// Update speech model ready state
    func setSpeechModelReady(_ ready: Bool) {
        isSpeechModelReady = ready
    }

    /// Update recording state
    func setRecording(_ recording: Bool) {
        isRecording = recording
    }

    /// Update speech model downloading state
    func setSpeechModelDownloading(_ downloading: Bool) {
        isSpeechModelDownloading = downloading
    }

    /// Update download progress (0-1)
    func setDownloadProgress(_ progress: Float) {
        downloadProgress = progress
    }

    private func updateDownloadProgressVisibility() {
        downloadProgressView.isHidden = !isSpeechModelDownloading
    }

    private func updateDownloadProgress() {
        downloadProgressView.progress = CGFloat(downloadProgress)
    }

    // MARK: - Dismiss Gestures

    private func setupDismissGestures() {
        // Swipe down = instant dismiss
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeToDismiss))
        swipeDown.direction = .down
        containerEffectView.addGestureRecognizer(swipeDown)

        // Swipe up = instant show keyboard
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeToShow))
        swipeUp.direction = .up
        containerEffectView.addGestureRecognizer(swipeUp)

        // Drag/pan = interactive dismiss/show
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture))
        pan.delegate = self
        containerEffectView.addGestureRecognizer(pan)
    }

    @objc private func handleSwipeToDismiss(_ gesture: UISwipeGestureRecognizer) {
        Logger.clauntty.debugOnly("[AccessoryBar] swipe down to dismiss")
        onDismissKeyboard?()
    }

    @objc private func handleSwipeToShow(_ gesture: UISwipeGestureRecognizer) {
        Logger.clauntty.debugOnly("[AccessoryBar] swipe up to show keyboard")
        onShowKeyboard?()
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        let velocity = gesture.velocity(in: self)

        switch gesture.state {
        case .changed:
            if translation.y > 0 {
                // Dragging down - move container down
                containerEffectView.transform = CGAffineTransform(translationX: 0, y: min(translation.y, 100))
            } else if translation.y < 0 {
                // Dragging up - move container up slightly for feedback
                containerEffectView.transform = CGAffineTransform(translationX: 0, y: max(translation.y, -30))
            }
        case .ended, .cancelled:
            if translation.y > 0 {
                // Was dragging down - dismiss if far enough
                let shouldDismiss = translation.y > 50 || velocity.y > 500

                if shouldDismiss {
                    UIView.animate(withDuration: 0.2) {
                        self.containerEffectView.transform = CGAffineTransform(translationX: 0, y: 100)
                    } completion: { _ in
                        self.containerEffectView.transform = .identity
                        self.onDismissKeyboard?()
                    }
                } else {
                    // Snap back
                    UIView.animate(withDuration: 0.2) {
                        self.containerEffectView.transform = .identity
                    }
                }
            } else if translation.y < 0 {
                // Was dragging up - show keyboard if far enough
                let shouldShow = translation.y < -30 || velocity.y < -500

                UIView.animate(withDuration: 0.2) {
                    self.containerEffectView.transform = .identity
                }

                if shouldShow {
                    Logger.clauntty.debugOnly("[AccessoryBar] drag up to show keyboard")
                    onShowKeyboard?()
                }
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.containerEffectView.transform = .identity
                }
            }
        default:
            break
        }
    }

    // MARK: - Mic Button Actions

    @objc private func micTouchDown() {
        micTouchStartTime = Date()
        isPushToTalkMode = false

        // If model not ready or downloading, we'll handle on touch up
        guard isSpeechModelReady, !isSpeechModelDownloading else { return }

        // If already recording (toggle mode), don't start a new timer
        guard !isRecording else { return }

        // Start timer - if user holds past threshold, start push-to-talk recording
        micHoldTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isPushToTalkMode = true
            self.startRecordingWithFeedback()
            Logger.clauntty.debugOnly("[AccessoryBar] hold threshold reached, starting push-to-talk recording")
        }
    }

    @objc private func micTouchUp() {
        guard micTouchStartTime != nil else { return }
        micTouchStartTime = nil

        // Cancel the hold timer if it hasn't fired yet
        micHoldTimer?.invalidate()
        micHoldTimer = nil

        // If model is downloading, show status tooltip instead of re-prompting
        if isSpeechModelDownloading {
            let progressPercent = Int(downloadProgress * 100)
            showTooltip(above: micButton, text: "Downloading... \(progressPercent)%")
            hideTooltipAfterDelay(delay: 1.5)
            Logger.clauntty.debugOnly("[AccessoryBar] mic tap during download, progress: \(progressPercent)%")
            return
        }

        // If model not ready, prompt download
        guard isSpeechModelReady else {
            Logger.clauntty.debugOnly("[AccessoryBar] mic tap, model not ready - prompting download")
            onPromptModelDownload?()
            return
        }

        if isPushToTalkMode {
            // Was in push-to-talk mode, stop and transcribe on release
            Logger.clauntty.debugOnly("[AccessoryBar] mic release, stopping push-to-talk recording")
            isRecording = false
            onStopRecording?()
        } else {
            // Tap mode - toggle recording
            if isRecording {
                // Was recording, stop and transcribe
                Logger.clauntty.debugOnly("[AccessoryBar] mic tap to stop recording (toggle mode)")
                isRecording = false
                onStopRecording?()
            } else {
                // Not recording, start recording (will stop on next tap)
                Logger.clauntty.debugOnly("[AccessoryBar] mic tap to start recording (toggle mode)")
                startRecordingWithFeedback()
            }
        }

        isPushToTalkMode = false
    }

    @objc private func micTouchCancelled() {
        micTouchStartTime = nil
        micHoldTimer?.invalidate()
        micHoldTimer = nil
        isPushToTalkMode = false

        if isRecording {
            onCancelRecording?()
            isRecording = false
            Logger.clauntty.debugOnly("[AccessoryBar] mic touch cancelled, recording stopped without transcription")
        }
    }

    private func startRecordingWithFeedback() {
        onStartRecording?()
        isRecording = true

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Key Actions

    private func sendEscape() {
        onKeyInput?(Data([0x1B]))
    }

    private func sendTab() {
        onKeyInput?(Data([0x09]))
    }

    @objc private func handleTabTap() {
        showTooltip(above: tabButton, text: "⇥")
        hideTooltipAfterDelay()
        sendTab()
    }

    @objc private func handleTabLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            sendShiftTab()
            showTooltip(above: tabButton, text: "⇧⇥")
        case .ended, .cancelled:
            hideTooltip()
        default:
            break
        }
    }

    @objc private func handleCtrlTap() {
        // Show ⌃ for Ctrl, or ⌥ if deactivating Option
        let tooltipText = isOptionActive ? "⌥" : "⌃"
        showTooltip(above: ctrlButton, text: tooltipText)
        hideTooltipAfterDelay()
        toggleCtrl()
    }

    @objc private func handleCtrlLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if isOptionActive {
                // If Option already active, deactivate it
                isOptionActive = false
                resetToCtrlState()
            } else {
                // Clear Ctrl if active, activate Option (sticky)
                isCtrlActive = false
                isOptionActive = true
                showOptionState()
                showTooltip(above: ctrlButton, text: "⌥")
            }
        case .ended, .cancelled:
            hideTooltip()
        default:
            break
        }
    }

    private func showOptionState() {
        UIView.animate(withDuration: 0.15) {
            self.ctrlButton.transform = CGAffineTransform(translationX: 0, y: -3)
        }
        ctrlButton.setImage(
            UIImage(systemName: "option")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        ctrlButton.tintColor = .systemBlue
    }

    private func resetToCtrlState() {
        UIView.animate(withDuration: 0.15) {
            self.ctrlButton.transform = .identity
        }
        ctrlButton.setImage(
            UIImage(systemName: "control")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        updateCtrlButton()  // Restore correct color based on isCtrlActive
    }

    private func sendShiftTab() {
        // Shift+Tab = CSI Z (Back Tab / CBT)
        onKeyInput?(Data([0x1B, 0x5B, 0x5A]))  // ESC [ Z
    }

    private func toggleCtrl() {
        // If Option is active, tapping deactivates Option
        if isOptionActive {
            isOptionActive = false
            resetToCtrlState()
            return
        }
        // Otherwise toggle Ctrl as normal
        isCtrlActive.toggle()
    }

    /// Check if Ctrl is active and consume the state
    /// Returns true if Ctrl was active (and clears it)
    func consumeCtrlModifier() -> Bool {
        if isCtrlActive {
            isCtrlActive = false
            return true
        }
        return false
    }

    /// Check if Option is active and consume the state
    /// Returns true if Option was active (and clears it)
    func consumeOptionModifier() -> Bool {
        if isOptionActive {
            isOptionActive = false
            resetToCtrlState()
            return true
        }
        return false
    }

    // MARK: - Tooltip

    private func showTooltip(above button: UIView, text: String) {
        hideTooltip()

        let tooltip = HoldTooltip(text: text)
        addSubview(tooltip)

        // Position tooltip above the button
        tooltip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tooltip.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            tooltip.bottomAnchor.constraint(equalTo: containerEffectView.topAnchor, constant: -4),
        ])

        // Animate in
        tooltip.alpha = 0
        tooltip.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animate(withDuration: 0.15) {
            tooltip.alpha = 1
            tooltip.transform = .identity
        }

        activeTooltip = tooltip
    }

    private func hideTooltip() {
        guard let tooltip = activeTooltip else { return }
        UIView.animate(withDuration: 0.1, animations: {
            tooltip.alpha = 0
            tooltip.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }, completion: { _ in
            tooltip.removeFromSuperview()
        })
        activeTooltip = nil
    }

    private func hideTooltipAfterDelay(delay: TimeInterval = 0.1) {
        // Brief delay so the tooltip is visible momentarily
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.hideTooltip()
        }
    }

    private func sendArrow(_ direction: ArrowNippleView.Direction) {
        let data: Data
        switch direction {
        case .up:
            data = Data([0x1B, 0x5B, 0x41])    // ESC [ A
        case .down:
            data = Data([0x1B, 0x5B, 0x42])    // ESC [ B
        case .right:
            data = Data([0x1B, 0x5B, 0x43])    // ESC [ C
        case .left:
            data = Data([0x1B, 0x5B, 0x44])    // ESC [ D
        }
        onKeyInput?(data)

        // If Ctrl was active, clear it after use
        if isCtrlActive {
            isCtrlActive = false
        }
    }

    private func sendCtrlC() {
        onKeyInput?(Data([0x03]))  // ETX
    }

    private func sendCtrlO() {
        onKeyInput?(Data([0x0F]))  // SI (Ctrl+O)
    }

    private func sendCtrlB() {
        onKeyInput?(Data([0x02]))  // STX (Ctrl+B)
    }

    private func sendEnter() {
        onKeyInput?(Data([0x0D]))  // CR (Return/Enter)
    }

    override var intrinsicContentSize: CGSize {
        // topPadding above bar + barHeight + bottom padding for spacing to keyboard
        return CGSize(width: UIView.noIntrinsicMetric, height: topPadding + barHeight + 8)
    }

    // MARK: - Touch Handling

    /// Horizontal padding to expand hit areas for Tab and Ctrl buttons
    private let expandedHitPadding: CGFloat = 12

    /// Override hitTest to expand vertical hit areas for all buttons
    /// and horizontal hit areas for Tab and Ctrl
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Hidden views must not receive touches
        // UIKit normally skips hidden views, but we override hitTest so we must check manually
        guard !isHidden else { return nil }

        // Check nipple FIRST - it's on top and overlaps the container
        let nippleFrame = nippleContainerView.frame
        if nippleFrame.contains(point) {
            let nipplePoint = convert(point, to: nippleContainerView)
            if let hitView = nippleContainerView.hitTest(nipplePoint, with: event) {
                Logger.clauntty.verbose("[AccessoryBar] hitTest: hit nipple subview")
                return hitView
            }
            Logger.clauntty.verbose("[AccessoryBar] hitTest: hit nipple background")
            return nippleContainerView
        }

        // Check if touch is within the horizontal bounds of the container
        // but expand vertical bounds to the full bar area
        let containerFrame = containerEffectView.frame
        let expandedFrame = CGRect(
            x: containerFrame.minX,
            y: bounds.minY,
            width: containerFrame.width,
            height: bounds.height
        )

        if expandedFrame.contains(point) {
            // Check expanded hit areas for Ctrl and Tab first (they need wider touch targets)
            if let ctrl = ctrlContainer {
                let ctrlFrame = ctrl.convert(ctrl.bounds, to: self)
                let expandedCtrlFrame = ctrlFrame.insetBy(dx: -expandedHitPadding, dy: 0)
                    .union(CGRect(x: ctrlFrame.minX - expandedHitPadding, y: bounds.minY,
                                  width: ctrlFrame.width + expandedHitPadding * 2, height: bounds.height))
                if expandedCtrlFrame.contains(point) {
                    Logger.clauntty.verbose("[AccessoryBar] hitTest: expanded Ctrl hit")
                    return ctrl
                }
            }

            if let tab = tabContainer {
                let tabFrame = tab.convert(tab.bounds, to: self)
                let expandedTabFrame = CGRect(x: tabFrame.minX - expandedHitPadding, y: bounds.minY,
                                              width: tabFrame.width + expandedHitPadding * 2, height: bounds.height)
                if expandedTabFrame.contains(point) {
                    Logger.clauntty.verbose("[AccessoryBar] hitTest: expanded Tab hit")
                    return tab
                }
            }

            // Find which button is at this horizontal position by checking both stacks
            // Use the center Y of the container for the hit test
            let centerY = containerFrame.midY
            let adjustedPoint = CGPoint(x: point.x, y: centerY)
            let containerPoint = convert(adjustedPoint, to: containerEffectView)

            if let hitView = containerEffectView.hitTest(containerPoint, with: event) {
                Logger.clauntty.verbose("[AccessoryBar] hitTest: expanded hit on \(String(describing: type(of: hitView)))")
                return hitView
            }

            // If no subview handles it, return the container itself
            Logger.clauntty.verbose("[AccessoryBar] hitTest: hit container background (expanded)")
            return containerEffectView
        }

        // Touch is outside visible elements - pass through to views below
        Logger.clauntty.verbose("[AccessoryBar] hitTest: passing through at \(Int(point.x)),\(Int(point.y))")
        return nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension KeyboardAccessoryView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pan gesture to work with other gestures
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only begin pan if it's primarily vertical (for dismiss)
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x) && velocity.y > 0
        }
        return true
    }
}

// MARK: - Collapsed Keyboard Bar

/// Floating mini bar shown when keyboard is hidden
/// Contains just the keyboard show button and arrow nipple
class CollapsedKeyboardBar: UIView {

    /// Callback to show keyboard
    var onShowKeyboard: (() -> Void)?

    /// Callback for arrow input
    var onArrowInput: ((ArrowNippleView.Direction) -> Void)?

    // MARK: - Views

    private let containerEffectView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = true
            effect = glassEffect
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        let view = UIVisualEffectView(effect: effect)
        view.clipsToBounds = true
        return view
    }()

    private let keyboardButton = UIButton(type: .system)
    private let nippleView = ArrowNippleView()

    // MARK: - Constants

    private let barHeight: CGFloat = 44
    private let nippleSize: CGFloat = 36
    private let iconSize: CGFloat = 14

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear

        // Container - pill shape
        containerEffectView.layer.cornerRadius = barHeight / 2
        containerEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerEffectView)

        // Keyboard button
        keyboardButton.setImage(
            UIImage(systemName: "keyboard")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            ),
            for: .normal
        )
        keyboardButton.tintColor = .label
        keyboardButton.addAction(UIAction { [weak self] _ in
            self?.onShowKeyboard?()
        }, for: .touchUpInside)
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        containerEffectView.contentView.addSubview(keyboardButton)

        // Nipple
        nippleView.onArrowInput = { [weak self] direction in
            self?.onArrowInput?(direction)
        }
        nippleView.translatesAutoresizingMaskIntoConstraints = false
        containerEffectView.contentView.addSubview(nippleView)

        // Constraints
        NSLayoutConstraint.activate([
            // Container size
            containerEffectView.topAnchor.constraint(equalTo: topAnchor),
            containerEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerEffectView.heightAnchor.constraint(equalToConstant: barHeight),
            containerEffectView.widthAnchor.constraint(equalToConstant: barHeight + nippleSize + 16),

            // Keyboard button
            keyboardButton.leadingAnchor.constraint(equalTo: containerEffectView.contentView.leadingAnchor, constant: 12),
            keyboardButton.centerYAnchor.constraint(equalTo: containerEffectView.contentView.centerYAnchor),

            // Nipple
            nippleView.trailingAnchor.constraint(equalTo: containerEffectView.contentView.trailingAnchor, constant: -6),
            nippleView.centerYAnchor.constraint(equalTo: containerEffectView.contentView.centerYAnchor),
            nippleView.widthAnchor.constraint(equalToConstant: nippleSize),
            nippleView.heightAnchor.constraint(equalToConstant: nippleSize),
        ])
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: barHeight + nippleSize + 16, height: barHeight)
    }
}

// MARK: - Hold Tooltip

/// Small floating tooltip shown when holding down a button for alternate action
private class HoldTooltip: UIView {

    init(text: String) {
        super.init(frame: .zero)

        backgroundColor = .systemBackground
        layer.cornerRadius = 6
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Arrow Nipple View

class ArrowNippleView: UIView {

    enum Direction {
        case up, down, left, right
    }

    var onArrowInput: ((Direction) -> Void)?

    private let nipple = UIView()
    private var repeatTimer: Timer?
    private var repeatDelayTimer: Timer?
    private var currentDirection: Direction?
    private var currentMagnitude: CGFloat = 0
    private var hasSentInitialInput = false

    /// Minimum threshold before any arrow is triggered (in points)
    private let activationThreshold: CGFloat = 20.0

    /// Maximum drag distance for fastest repeat (in points)
    private let maxDragDistance: CGFloat = 50.0

    /// Delay before repeat starts (to distinguish flick from hold)
    private let repeatDelay: TimeInterval = 0.3

    /// Slowest repeat interval (at activation threshold)
    private let slowestRepeat: TimeInterval = 0.2

    /// Fastest repeat interval (at max drag)
    private let fastestRepeat: TimeInterval = 0.04

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // More visible background
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 8

        // Center nipple - more visible
        nipple.backgroundColor = .secondaryLabel
        nipple.layer.cornerRadius = 8
        nipple.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nipple)

        NSLayoutConstraint.activate([
            nipple.centerXAnchor.constraint(equalTo: centerXAnchor),
            nipple.centerYAnchor.constraint(equalTo: centerYAnchor),
            nipple.widthAnchor.constraint(equalToConstant: 16),
            nipple.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Pan gesture for arrow input
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let translation = gesture.translation(in: self)

            // Calculate magnitude of drag
            let absX = abs(translation.x)
            let absY = abs(translation.y)
            let magnitude = max(absX, absY)

            // Animate nipple offset (always, even below threshold)
            let maxOffset: CGFloat = 8
            let offsetX = min(max(translation.x, -maxOffset), maxOffset)
            let offsetY = min(max(translation.y, -maxOffset), maxOffset)
            nipple.transform = CGAffineTransform(translationX: offsetX, y: offsetY)

            // Only activate if past threshold
            guard magnitude > activationThreshold else {
                // Below threshold - cancel any pending repeat
                if currentDirection != nil {
                    stopRepeat()
                    currentDirection = nil
                    hasSentInitialInput = false
                }
                return
            }

            // Determine direction based on which axis has greater magnitude
            let newDirection: Direction
            if absX > absY {
                newDirection = translation.x > 0 ? .right : .left
            } else {
                newDirection = translation.y > 0 ? .down : .up
            }

            // Update magnitude for repeat speed calculation
            currentMagnitude = magnitude

            // If direction changed or first activation
            if currentDirection != newDirection {
                stopRepeat()
                currentDirection = newDirection
                hasSentInitialInput = false
            }

            // Send initial input once when direction is first set
            if !hasSentInitialInput {
                hasSentInitialInput = true
                onArrowInput?(newDirection)
                // Start delay timer - repeat only starts after holding
                startRepeatDelay()
            }

        case .ended, .cancelled:
            stopRepeat()
            currentDirection = nil
            currentMagnitude = 0
            hasSentInitialInput = false

            // Animate nipple back to center
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                self.nipple.transform = .identity
            }

        default:
            break
        }
    }

    /// Calculate repeat interval based on drag magnitude (further = faster)
    private func repeatInterval() -> TimeInterval {
        // Normalize magnitude to 0-1 range (activation threshold to max)
        let normalizedMagnitude = min(
            (currentMagnitude - activationThreshold) / (maxDragDistance - activationThreshold),
            1.0
        )
        // Interpolate between slowest and fastest
        return slowestRepeat - (normalizedMagnitude * (slowestRepeat - fastestRepeat))
    }

    private func startRepeatDelay() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in
            // After delay, start repeating if still holding
            self?.startRepeat()
        }
    }

    private func startRepeat() {
        repeatTimer?.invalidate()
        scheduleNextRepeat()
    }

    private func scheduleNextRepeat() {
        guard currentDirection != nil else { return }
        let interval = repeatInterval()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, let dir = self.currentDirection else { return }
            self.onArrowInput?(dir)
            self.scheduleNextRepeat()  // Schedule next with potentially new interval
        }
    }

    private func stopRepeat() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

// MARK: - Circular Progress View

/// Simple linear progress bar for download indication
private class CircularProgressView: UIView {

    var progress: CGFloat = 0 {
        didSet {
            setNeedsLayout()
        }
    }

    private let trackLayer = CALayer()
    private let progressLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Track (background)
        trackLayer.backgroundColor = UIColor.secondarySystemFill.cgColor
        layer.addSublayer(trackLayer)

        // Progress fill
        progressLayer.backgroundColor = UIColor.systemBlue.cgColor
        layer.addSublayer(progressLayer)

        // Rounded corners
        layer.cornerRadius = 2
        clipsToBounds = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2

        let progressWidth = bounds.width * min(max(progress, 0), 1)
        progressLayer.frame = CGRect(x: 0, y: 0, width: progressWidth, height: bounds.height)
        progressLayer.cornerRadius = bounds.height / 2
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        trackLayer.backgroundColor = UIColor.secondarySystemFill.cgColor
        progressLayer.backgroundColor = UIColor.systemBlue.cgColor
    }
}
