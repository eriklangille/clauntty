import UIKit
import os.log

private let logger = Logger(subsystem: "com.clauntty", category: "TabBubble")

/// Represents the type of tab for styling purposes
enum TabType {
    case terminal(Session.State)
    case web(WebTab.State)
}

/// Individual tab bubble with liquid glass effect
/// Expands Safari-style with two rows when tapped
class TabBubble: UIView {

    // MARK: - Properties

    var tabId: UUID?
    var tabType: TabType = .terminal(.disconnected)
    var title: String = "" {
        didSet { updateTitleLabel() }
    }
    /// Title to show when expanded (URL for web tabs)
    var expandedTitle: String = "" {
        didSet { updateTitleLabel() }
    }
    /// Port for web tabs (e.g., 3000)
    var webPort: Int = 0 {
        didSet { portPrefixLabel.text = ":\(webPort)" }
    }
    /// Path for web tabs (e.g., /api/users)
    var webPath: String = "/" {
        didSet { syncURLTextFieldIfNeeded() }
    }
    /// Connection string like "ubuntu@devbox.example.com"
    var connectionInfo: String = "" {
        didSet { connectionLabel.text = connectionInfo }
    }

    private func updateTitleLabel() {
        // In expanded state for web tabs, show the URL
        if isExpanded && !expandedTitle.isEmpty {
            titleLabel.text = expandedTitle
        } else if !isExpanded, let rollingTitle {
            titleLabel.text = rollingTitle
        } else {
            titleLabel.text = title
        }
    }

    /// Panes in this session's group (empty for plain terminals and web tabs)
    private(set) var panes: [TabPane] = []
    private(set) var activePaneIndex = 0

    private var hasPanes: Bool { !panes.isEmpty }
    private var hasMultiplePanes: Bool { panes.count > 1 }

    /// Session tabs with panes show the current pane's agent state instead of the
    /// connection dot. It comes from the group, not the pane's connection, so it holds
    /// before a pane is attached too; only a failed session shows its state.
    private var showsPaneStatus: Bool {
        guard hasPanes, case .terminal(let state) = tabType else { return false }
        switch state {
        case .error, .remotelyDeleted: return false
        default: return true
        }
    }

    /// Pane title shown briefly in the collapsed tab after switching panes
    private var rollingTitle: String?
    private var rollBackWork: DispatchWorkItem?
    private func syncURLTextFieldIfNeeded() {
        guard !isEditingURL else { return }
        urlTextField.text = webPath
    }
    var isActiveTab: Bool = false {
        didSet { updateActiveState() }
    }
    /// Skip animation on next isExpanded change (for slide transitions)
    private var skipExpandAnimation: Bool = false
    private var isEditingURL: Bool = false

    var isExpanded: Bool = false {
        didSet {
            if oldValue != isExpanded && !skipExpandAnimation {
                animateExpansion()
            }
            skipExpandAnimation = false
        }
    }

    /// Set expanded state without triggering animation
    func setExpandedSilently(_ expanded: Bool) {
        skipExpandAnimation = true
        isExpanded = expanded
    }

    /// Callback when this bubble is tapped (collapsed state)
    var onTap: (() -> Void)?

    /// Callback when bubble is long pressed (to expand active tab without release)
    var onLongPress: (() -> Void)?

    /// Callbacks for swipe gestures (expanded state)
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    /// Callbacks for swipe gestures (collapsed state)
    var onSwipeLeftCollapsed: (() -> Void)?
    var onSwipeRightCollapsed: (() -> Void)?

    /// Callbacks for expanded state actions
    var onDisconnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onPorts: (() -> Void)?  // Show port forwarding UI
    var onTabs: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onDismiss: (() -> Void)?

    // Web-specific callbacks
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onShare: (() -> Void)?
    var onNavigate: ((String) -> Void)?  // Called when user enters a new path

    // Pane callbacks
    var onPaneStep: ((Int) -> Void)?  // +1 next pane (swipe down), -1 previous (swipe up)
    var onPaneSelected: ((Int) -> Void)?  // Chip tapped in the expanded tab
    var onPaneToggle: (() -> Void)?  // Double tap: back to the previous pane

    // MARK: - Constants

    private let statusSize: CGFloat = 8
    private let horizontalPadding: CGFloat = 16
    private let buttonSize: CGFloat = 44
    private let topRowHeight: CGFloat = 44
    private let bottomRowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 4

    // MARK: - Views

    /// Glass effect container
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

    /// Darker background for top row (expanded state)
    private let topRowBackground: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        view.layer.cornerRadius = 22
        view.alpha = 0
        return view
    }()

    /// Status indicator - circle for terminal
    private let statusView = UIView()

    /// Pulsing ring for waiting-for-input state
    private let waitingRingView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.layer.borderColor = UIColor.systemBlue.cgColor
        view.layer.borderWidth = 1.5
        view.isHidden = true
        return view
    }()

    /// Whether this tab is waiting for input (shows pulsing ring)
    var isWaitingForInput: Bool = false {
        didSet {
            updateWaitingRing()
        }
    }

    /// Globe icon for web tabs
    private let globeImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = UIImage(systemName: "globe", withConfiguration: config)
        let imageView = UIImageView(image: image)
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    /// Title label (session name / URL) - used in collapsed state and terminal expanded
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// Port prefix label (non-editable :3000 part)
    private let portPrefixLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.alpha = 0
        return label
    }()

    /// Editable path field for web tabs (expanded state only)
    private let urlTextField: UITextField = {
        let field = UITextField()
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = .label
        field.textAlignment = .left
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.placeholder = "/"
        field.alpha = 0
        return field
    }()

    /// Connection info label (ubuntu@host.com) - shown in bottom row when expanded
    private let connectionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.alpha = 0
        return label
    }()

    // MARK: - Pane Views

    /// Agent state of the current pane, in place of the status dot
    private let paneStatusIndicator: PaneStatusIndicator = {
        let view = PaneStatusIndicator()
        view.isHidden = true
        return view
    }()

    /// One dot per pane on the collapsed tab's right edge
    private let paneDotsView: PaneDotsView = {
        let view = PaneDotsView()
        view.isHidden = true
        return view
    }()

    /// Holds the session menu; terminal tabs open it instead of expanding
    private let menuButton: PassthroughMenuButton = {
        let button = PassthroughMenuButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.isHidden = true
        return button
    }()

    private var isTerminal: Bool {
        if case .terminal = tabType { return true }
        return false
    }

    /// Terminal tabs open the session menu; web tabs expand (they need the URL field)
    var usesMenu: Bool { isTerminal }

    // MARK: - Top Row Buttons (expanded)

    /// Terminal icon (left of title in top row) or Disconnect for terminal
    private let leftActionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: "terminal", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    /// Reconnect/Reload button (right of title in top row)
    private let rightActionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    // MARK: - Bottom Row Buttons (expanded)

    /// Tabs button (left side of bottom row)
    private let tabsButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "square.on.square", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    /// New tab button (right side of bottom row)
    private let newTabButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "plus", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    // Web-specific bottom row buttons
    private let backButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    private let forwardButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "chevron.right", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        button.alpha = 0
        return button
    }()

    private let shareButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

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

        // Setup container with glass effect
        containerEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerEffectView)

        // Setup top row background (for expanded state)
        topRowBackground.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(topRowBackground)

        // Setup status indicator (circle)
        statusView.translatesAutoresizingMaskIntoConstraints = true
        statusView.layer.cornerRadius = statusSize / 2
        containerEffectView.contentView.addSubview(statusView)

        // Setup waiting ring (pulsing blue ring around status)
        waitingRingView.translatesAutoresizingMaskIntoConstraints = true
        waitingRingView.layer.cornerRadius = 6  // Slightly larger than status (8/2 + 2)
        containerEffectView.contentView.addSubview(waitingRingView)

        // Setup globe icon (hidden by default)
        globeImageView.translatesAutoresizingMaskIntoConstraints = true
        globeImageView.isHidden = true
        containerEffectView.contentView.addSubview(globeImageView)

        // Setup labels
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(titleLabel)

        // Setup URL components for web tabs
        portPrefixLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(portPrefixLabel)

        urlTextField.translatesAutoresizingMaskIntoConstraints = true
        urlTextField.delegate = self
        containerEffectView.contentView.addSubview(urlTextField)

        connectionLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(connectionLabel)

        // Pane views
        containerEffectView.contentView.addSubview(paneStatusIndicator)
        containerEffectView.contentView.addSubview(paneDotsView)
        addSubview(menuButton)
        titleLabel.clipsToBounds = true  // Keeps the title roll inside the label

        // Setup buttons
        setupButtons()
        setupConstraints()
        setupGestures()
    }

    private func setupButtons() {
        let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                       backButton, forwardButton, shareButton]

        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            containerEffectView.contentView.addSubview(button)
        }

        // Add targets
        leftActionButton.addTarget(self, action: #selector(handleLeftAction), for: .touchUpInside)
        rightActionButton.addTarget(self, action: #selector(handleRightAction), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(handleTabs), for: .touchUpInside)
        newTabButton.addTarget(self, action: #selector(handleNewTab), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            containerEffectView.topAnchor.constraint(equalTo: topAnchor),
            containerEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    private lazy var doubleTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        gesture.numberOfTapsRequired = 2
        return gesture
    }()
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))

    private func setupGestures() {
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)

        // Only active when the session has several panes (see gestureRecognizerShouldBegin),
        // so single taps elsewhere don't wait for it
        doubleTapGesture.delegate = self
        addGestureRecognizer(doubleTapGesture)

        longPressGesture.minimumPressDuration = 0.3  // Quick long press
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        // Terminal tabs: press and hold opens the session menu; slide to a pane and let go
        addInteraction(UIContextMenuInteraction(delegate: self))

        panGesture.delegate = self
        addGestureRecognizer(panGesture)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onPaneToggle?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        // Only trigger long press in collapsed state for active tabs
        if !isExpanded {
            onLongPress?()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }

        let translation = gesture.translation(in: self)
        let velocity = gesture.velocity(in: self)
        let threshold: CGFloat = 50

        if isExpanded {
            // Expanded state - use expanded callbacks
            if translation.x > threshold || velocity.x > 500 {
                onSwipeRight?()
            } else if translation.x < -threshold || velocity.x < -500 {
                onSwipeLeft?()
            }
        } else {
            // Vertical swipe on the active tab steps through its panes
            if isActiveTab && hasMultiplePanes && abs(translation.y) > abs(translation.x) {
                if translation.y > 20 || velocity.y > 400 {
                    onPaneStep?(1)
                } else if translation.y < -20 || velocity.y < -400 {
                    onPaneStep?(-1)
                }
                return
            }

            // Collapsed state - use collapsed callbacks
            if translation.x > threshold || velocity.x > 500 {
                onSwipeRightCollapsed?()
            } else if translation.x < -threshold || velocity.x < -500 {
                onSwipeLeftCollapsed?()
            }
        }
    }

    // MARK: - Actions

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if isExpanded {
            // Tap on background area dismisses
            let location = gesture.location(in: containerEffectView.contentView)
            let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                          backButton, forwardButton, shareButton]
            for button in buttons where button.alpha > 0 && button.frame.contains(location) {
                return // Let button handle it
            }
            onDismiss?()
        } else {
            onTap?()
        }
    }

    @objc private func handleLeftAction() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Close button for both terminal and web tabs
        onDisconnect?()
    }

    @objc private func handleRightAction() {
        logger.info("TabBubble: handleRightAction called, tabType=\(String(describing: self.tabType))")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch tabType {
        case .terminal:
            logger.info("TabBubble: calling onPorts callback (exists=\(self.onPorts != nil))")
            onPorts?()  // Show port forwarding UI
        case .web:
            onReload?()
        }
    }

    @objc private func handleTabs() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTabs?()
    }

    @objc private func handleNewTab() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onNewTab?()
    }

    @objc private func handleBack() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onBack?()
    }

    @objc private func handleForward() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onForward?()
    }

    @objc private func handleShare() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch tabType {
        case .web:
            onPorts?()
        case .terminal:
            onShare?()
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        containerEffectView.layer.cornerRadius = isExpanded ? 26 : min(bounds.height / 2, 20)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        let height = bounds.height

        guard width > 0 && height > 0 else { return }

        if isExpanded {
            layoutExpandedContent(width: width, height: height)
        } else {
            layoutCollapsedContent(width: width, height: height)
        }
    }

    private func layoutCollapsedContent(width: CGFloat, height: CGFloat) {
        let centerY = height / 2

        // Determine icon size based on tab type
        let isWeb: Bool
        switch tabType {
        case .web: isWeb = true
        case .terminal: isWeb = false
        }

        let iconSize: CGFloat = isWeb ? 14 : statusSize  // Globe is 14, status dot is 8

        // Pane dots sit under the title; the title moves up to make room
        let dotsLift: CGFloat = hasMultiplePanes ? 4 : 0
        if hasMultiplePanes {
            paneDotsView.frame = CGRect(x: horizontalPadding, y: height - 10, width: width - horizontalPadding * 2, height: PaneDotsView.height)
        } else {
            paneDotsView.frame = .zero
        }

        // Calculate actual text width for proper centering
        let maxTitleWidth = width - iconSize - 6 - horizontalPadding * 2
        let actualTitleSize = titleLabel.sizeThatFits(CGSize(width: maxTitleWidth, height: height))
        let titleWidth = min(actualTitleSize.width, maxTitleWidth)

        let gap: CGFloat = 6
        let contentWidth = iconSize + gap + titleWidth
        let startX = (width - contentWidth) / 2

        statusView.frame = CGRect(x: startX, y: centerY - dotsLift - statusSize / 2, width: statusSize, height: statusSize)
        paneStatusIndicator.frame = statusView.frame.insetBy(dx: -1, dy: -1)
        // Center waiting ring on status (12x12 ring around 8x8 status)
        let ringSize: CGFloat = 12
        waitingRingView.frame = CGRect(
            x: statusView.frame.midX - ringSize / 2,
            y: statusView.frame.midY - ringSize / 2,
            width: ringSize,
            height: ringSize
        )
        globeImageView.frame = CGRect(x: startX, y: centerY - dotsLift - 7, width: 14, height: 14)

        let titleX = startX + iconSize + gap
        titleLabel.frame = CGRect(x: titleX, y: -dotsLift, width: titleWidth, height: height)
        titleLabel.textAlignment = .left

        // Hide expanded elements
        topRowBackground.frame = .zero
        connectionLabel.frame = .zero
        urlTextField.frame = .zero
        portPrefixLabel.frame = .zero

        // Hide all buttons off-screen
        let offscreen = CGRect(x: -100, y: 0, width: buttonSize, height: buttonSize)
        [leftActionButton, rightActionButton, tabsButton, newTabButton,
         backButton, forwardButton, shareButton].forEach { $0.frame = offscreen }
    }

    private func layoutExpandedContent(width: CGFloat, height: CGFloat) {
        let padding = horizontalPadding
        let topRowY: CGFloat = 8
        let bottomRowY = topRowY + topRowHeight + rowSpacing

        // Top row background (darker pill)
        let topRowBgInset: CGFloat = 8
        topRowBackground.frame = CGRect(
            x: topRowBgInset,
            y: topRowY,
            width: width - topRowBgInset * 2,
            height: topRowHeight
        )

        // Top row: [leftAction] [status] [title] [rightAction]
        let topRowCenterY = topRowY + topRowHeight / 2

        leftActionButton.frame = CGRect(
            x: padding,
            y: topRowCenterY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )

        rightActionButton.frame = CGRect(
            x: width - padding - buttonSize,
            y: topRowCenterY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )

        // Status/globe next to left button
        let statusX = leftActionButton.frame.maxX + 8
        statusView.frame = CGRect(x: statusX, y: topRowCenterY - statusSize / 2, width: statusSize, height: statusSize)
        paneStatusIndicator.frame = statusView.frame.insetBy(dx: -1, dy: -1)
        paneDotsView.frame = .zero
        // Center waiting ring on status in expanded state
        let expandedRingSize: CGFloat = 12
        waitingRingView.frame = CGRect(
            x: statusView.frame.midX - expandedRingSize / 2,
            y: statusView.frame.midY - expandedRingSize / 2,
            width: expandedRingSize,
            height: expandedRingSize
        )
        globeImageView.frame = CGRect(x: statusX, y: topRowCenterY - 8, width: 16, height: 16)

        // Title/URL centered in remaining space
        let titleX = statusX + statusSize + 8
        let titleWidth = rightActionButton.frame.minX - titleX - 8
        let titleFrame = CGRect(x: titleX, y: topRowY, width: titleWidth, height: topRowHeight)

        switch tabType {
        case .terminal:
            titleLabel.frame = titleFrame
            titleLabel.textAlignment = .center
            urlTextField.frame = .zero
            portPrefixLabel.frame = .zero
        case .web:
            // Web tabs: [port prefix :3000] [editable path field /api/users]
            titleLabel.frame = .zero

            // Calculate port prefix width
            let portText = ":\(webPort)"
            let portSize = (portText as NSString).size(withAttributes: [.font: portPrefixLabel.font!])
            let portWidth = ceil(portSize.width) + 4

            portPrefixLabel.frame = CGRect(x: titleX, y: topRowY, width: portWidth, height: topRowHeight)
            urlTextField.frame = CGRect(x: titleX + portWidth, y: topRowY, width: titleWidth - portWidth, height: topRowHeight)
        }

        // Bottom row layout depends on tab type
        let bottomRowCenterY = bottomRowY + bottomRowHeight / 2

        switch tabType {
        case .terminal:
            // Terminal: [tabs] [connection info] [+]
            tabsButton.frame = CGRect(
                x: padding,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            newTabButton.frame = CGRect(
                x: width - padding - buttonSize,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            // Connection label in center
            let connX = tabsButton.frame.maxX + 8
            let connWidth = newTabButton.frame.minX - connX - 8
            connectionLabel.frame = CGRect(x: connX, y: bottomRowY, width: connWidth, height: bottomRowHeight)

            // Hide web buttons
            [backButton, forwardButton, shareButton].forEach { $0.frame = CGRect(x: -100, y: 0, width: buttonSize, height: buttonSize) }

        case .web:
            // Web: [<] [>] [share] [tabs] [+] - like Safari
            let buttonSpacing = (width - padding * 2 - buttonSize * 5) / 4

            backButton.frame = CGRect(
                x: padding,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            forwardButton.frame = CGRect(
                x: backButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            shareButton.frame = CGRect(
                x: forwardButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            tabsButton.frame = CGRect(
                x: shareButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            newTabButton.frame = CGRect(
                x: tabsButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            // Hide connection label for web
            connectionLabel.frame = .zero
        }
    }

    /// Hide content before glass expansion animation
    func hideContentForExpansion() {
        statusView.alpha = 0
        paneStatusIndicator.alpha = 0
        paneDotsView.alpha = 0
        globeImageView.alpha = 0
        titleLabel.alpha = 0
    }

    /// Access to the glass effect layer for corner radius animation
    var glassLayer: CALayer {
        return containerEffectView.layer
    }

    /// Get current corner radius
    var glassCornerRadius: CGFloat {
        return containerEffectView.layer.cornerRadius
    }

    /// Set corner radius (for animation)
    func setGlassCornerRadius(_ radius: CGFloat) {
        containerEffectView.layer.cornerRadius = radius
    }

    /// Hide all content before glass collapse animation
    func hideContentForCollapse() {
        // Hide everything - both expanded and collapsed content
        statusView.alpha = 0
        globeImageView.alpha = 0
        titleLabel.alpha = 0
        topRowBackground.alpha = 0
        leftActionButton.alpha = 0
        rightActionButton.alpha = 0
        tabsButton.alpha = 0
        newTabButton.alpha = 0
        connectionLabel.alpha = 0
        backButton.alpha = 0
        forwardButton.alpha = 0
        shareButton.alpha = 0
        portPrefixLabel.alpha = 0
        urlTextField.alpha = 0
        paneStatusIndicator.alpha = 0
        paneDotsView.alpha = 0
    }

    /// Show expanded content with pop animation (called after scale animation completes)
    func showExpandedContent() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update button icons with appropriate sizes
        if isTerminal {
            // Terminate button - smaller icon
            let terminateConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: terminateConfig), for: .normal)
            leftActionButton.tintColor = .white
            // Ports button for terminal (globe icon)
            let portsConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            rightActionButton.setImage(UIImage(systemName: "globe", withConfiguration: portsConfig), for: .normal)
            rightActionButton.tintColor = .white
            rightActionButton.isHidden = false
        } else {
            // Web tab: close button (X) on left, reload on right
            let webConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: webConfig), for: .normal)
            leftActionButton.tintColor = .white
            let reloadConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: reloadConfig), for: .normal)
            rightActionButton.tintColor = .white
            rightActionButton.isHidden = false
        }

        // Update tabs and new tab button icons - slightly smaller
        let bottomRowConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        tabsButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: bottomRowConfig), for: .normal)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: bottomRowConfig), for: .normal)

        // Update title
        updateTitleLabel()
        if !isTerminal {
            syncURLTextFieldIfNeeded()
        }

        // Layout for expanded state
        isExpanded = true
        layoutContent()

        // Get views to animate (rightActionButton is ports for terminal, reload for web)
        let expandedViews: [UIView] = isTerminal
            ? [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, connectionLabel, statusView, paneStatusIndicator, titleLabel]
            : [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, backButton, forwardButton, shareButton, portPrefixLabel, urlTextField, globeImageView]

        // Set initial state
        for view in expandedViews {
            view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            view.alpha = 0
        }

        // Animate to visible
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            for view in expandedViews {
                view.transform = .identity
                view.alpha = 1
            }
        }
    }

    /// Show expanded content immediately without animation (for slide transitions)
    func showExpandedContentInstant() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update button icons
        if isTerminal {
            let terminateConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: terminateConfig), for: .normal)
            leftActionButton.tintColor = .white
            let portsConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            rightActionButton.setImage(UIImage(systemName: "globe", withConfiguration: portsConfig), for: .normal)
            rightActionButton.tintColor = .white
            rightActionButton.isHidden = false
        } else {
            let webConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: webConfig), for: .normal)
            leftActionButton.tintColor = .white
            let reloadConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: reloadConfig), for: .normal)
            rightActionButton.tintColor = .white
            rightActionButton.isHidden = false
        }

        let bottomRowConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        tabsButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: bottomRowConfig), for: .normal)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: bottomRowConfig), for: .normal)

        // Update title
        updateTitleLabel()
        if !isTerminal {
            syncURLTextFieldIfNeeded()
        }

        // Layout for expanded state (without animation)
        UIView.performWithoutAnimation {
            isExpanded = true
            layoutContent()

            // Show all expanded views immediately
            let expandedViews: [UIView] = isTerminal
                ? [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, connectionLabel, statusView, paneStatusIndicator, titleLabel]
                : [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, backButton, forwardButton, shareButton, portPrefixLabel, urlTextField, globeImageView]

            for view in expandedViews {
                view.transform = .identity
                view.alpha = 1
            }

            // Force layout to apply immediately
            self.layoutIfNeeded()
        }
    }

    /// Show collapsed content with pop animation (called after collapse scale animation completes)
    func showCollapsedContent() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update title for collapsed state
        isExpanded = false
        updateTitleLabel()
        layoutContent()

        // Get views to animate
        let collapsedViews: [UIView] = isTerminal
            ? [statusView, paneStatusIndicator, paneDotsView, titleLabel]
            : [globeImageView, titleLabel]

        // Set initial state
        for view in collapsedViews {
            view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            view.alpha = 0
        }

        // Animate to visible
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            for view in collapsedViews {
                view.transform = .identity
                view.alpha = 1
            }
        }
    }

    private func animateExpansion() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update button icons based on tab type
        if isTerminal {
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: config), for: .normal)
            leftActionButton.tintColor = .white
            rightActionButton.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
            rightActionButton.tintColor = .white
        } else {
            // Web tab: close button (X) on left, reload on right
            let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: config), for: .normal)
            leftActionButton.tintColor = .white
            let reloadConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: reloadConfig), for: .normal)
            rightActionButton.tintColor = .white
        }

        // Update title for expanded state (URL for web tabs)
        updateTitleLabel()

        // Update URL text field text for web tabs (just the path, not port)
        if !isTerminal && isExpanded {
            syncURLTextFieldIfNeeded()
        }

        // Layout content first so positions are correct
        layoutContent()

        if isExpanded {
            // Pop-in animation: start scaled down and invisible, then pop to full size
            // For terminal: show title in top row, connection label below, ports button
            // For web: show globe + URL components
            let expandedViews: [UIView] = isTerminal
                ? [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, connectionLabel, statusView, paneStatusIndicator, titleLabel]
                : [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, backButton, forwardButton, shareButton, portPrefixLabel, urlTextField, globeImageView]

            // Set initial state: scaled down and invisible
            for view in expandedViews {
                view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                view.alpha = 0
            }

            // Animate to full size with spring
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                for view in expandedViews {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
        } else {
            // Collapsing - reverse scale animation (pop in from center)
            // First hide expanded content instantly
            topRowBackground.alpha = 0
            leftActionButton.alpha = 0
            rightActionButton.alpha = 0
            tabsButton.alpha = 0
            newTabButton.alpha = 0
            connectionLabel.alpha = 0
            backButton.alpha = 0
            forwardButton.alpha = 0
            shareButton.alpha = 0
            urlTextField.alpha = 0
            portPrefixLabel.alpha = 0

            // Collapsed content - start scaled down
            let collapsedViews: [UIView] = isTerminal
                ? [statusView, paneStatusIndicator, paneDotsView, titleLabel]
                : [globeImageView, titleLabel]

            for view in collapsedViews {
                view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                view.alpha = 0
            }

            // Pop in collapsed content
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                for view in collapsedViews {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
        }
    }

    // MARK: - Configuration

    func configure(session: Session) {
        tabId = session.id
        tabType = .terminal(session.state)
        title = session.title
        connectionInfo = session.connectionString
        isWaitingForInput = session.isWaitingForInput

        statusView.isHidden = false
        globeImageView.isHidden = true

        updateStatusColor()
    }

    func configure(webTab: WebTab) {
        tabId = webTab.id
        tabType = .web(webTab.state)
        title = webTab.title
        expandedTitle = webTab.urlDisplayString  // Show port + path when expanded
        connectionInfo = ""  // Not used for web tabs

        // Set port and path for editable URL
        webPort = webTab.localPort
        if let url = webTab.currentURL {
            var path = url.path
            if let query = url.query { path += "?\(query)" }
            webPath = path.isEmpty ? "/" : path
        } else {
            webPath = "/"
        }

        statusView.isHidden = true
        globeImageView.isHidden = false

        updateGlobeColor()
    }

    /// Set the session's panes. Call after configure(session:), which resets the status dot.
    func setPanes(_ panes: [TabPane], activeIndex: Int) {
        self.panes = panes
        activePaneIndex = panes.isEmpty ? 0 : min(max(activeIndex, 0), panes.count - 1)

        paneDotsView.configure(panes: panes, activeIndex: activePaneIndex)
        paneDotsView.isHidden = !hasMultiplePanes

        let showPane = showsPaneStatus
        paneStatusIndicator.isHidden = !showPane
        if case .terminal = tabType {
            statusView.isHidden = showPane
        }
        if showPane {
            paneStatusIndicator.status = panes[activePaneIndex].status
        }
        updateWaitingRing()
        updateMenu()
        setNeedsLayout()
    }

    /// Rebuild the session menu with the current host and panes
    private func updateMenu() {
        guard usesMenu else {
            menuButton.menu = nil
            return
        }
        menuButton.menu = SessionTabMenu.make(
            title: connectionInfo,
            panes: panes,
            activeIndex: activePaneIndex,
            onSelectPane: { [weak self] index in self?.onPaneSelected?(index) },
            onTabs: { [weak self] in self?.onTabs?() },
            onNewTab: { [weak self] in self?.onNewTab?() },
            onPorts: { [weak self] in self?.onPorts?() },
            onClose: { [weak self] in self?.onDisconnect?() }
        )
    }

    /// Open the session menu from the tab
    func presentMenu() {
        menuButton.frame = bounds
        menuButton.isHidden = false
        if #available(iOS 17.4, *) {
            menuButton.performPrimaryAction()
        }
    }

    /// Roll the collapsed title to the new pane's name, hold it, then settle back
    /// to the session name
    func showPaneChange(direction: Int) {
        guard !isExpanded, panes.indices.contains(activePaneIndex) else { return }
        rollBackWork?.cancel()
        rollingTitle = panes[activePaneIndex].title
        // Swiping down brings the next pane in from the top, like an odometer
        rollTitle(subtype: direction > 0 ? .fromTop : .fromBottom)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rollingTitle = nil
            self.rollTitle(subtype: nil)
        }
        rollBackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// Nudge the tab when there's no pane further in that direction
    func bumpPaneEdge(direction: Int) {
        let offset: CGFloat = direction > 0 ? 4 : -4
        UIView.animate(withDuration: 0.08, animations: {
            self.transform = CGAffineTransform(translationX: 0, y: offset)
        }, completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0) {
                self.transform = .identity
            }
        })
    }

    /// Change the title with a push (pane change) or a fade (back to the session name)
    private func rollTitle(subtype: CATransitionSubtype?) {
        let transition = CATransition()
        transition.type = subtype == nil ? .fade : .push
        transition.subtype = subtype
        transition.duration = subtype == nil ? 0.3 : 0.22
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        titleLabel.layer.add(transition, forKey: "paneRoll")
        updateTitleLabel()
        UIView.animate(withDuration: 0.22) {
            self.layoutContent()
        }
    }

    private func updateStatusColor() {
        switch tabType {
        case .terminal(let state):
            switch state {
            case .connected:
                statusView.backgroundColor = .systemGreen
            case .connecting:
                statusView.backgroundColor = .systemOrange
            case .disconnected:
                statusView.backgroundColor = .systemGray
            case .error:
                statusView.backgroundColor = .systemRed
            case .remotelyDeleted:
                statusView.backgroundColor = .systemOrange
            }
        case .web:
            break
        }
    }

    private func updateWaitingRing() {
        // Only show ring for non-active tabs waiting for input
        // Sessions with panes show agent state on the pane indicator instead
        let shouldShowRing = isWaitingForInput && !isActiveTab && !hasPanes

        if shouldShowRing {
            waitingRingView.isHidden = false
            // Start pulsing animation
            startPulsingAnimation()
        } else {
            waitingRingView.isHidden = true
            // Stop pulsing animation
            waitingRingView.layer.removeAnimation(forKey: "pulseAnimation")
        }
    }

    private func startPulsingAnimation() {
        // Remove existing animation
        waitingRingView.layer.removeAnimation(forKey: "pulseAnimation")

        // Create pulsing opacity animation
        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 0.3
        pulseAnimation.duration = 0.8
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        waitingRingView.layer.add(pulseAnimation, forKey: "pulseAnimation")
    }

    private func updateGlobeColor() {
        switch tabType {
        case .web(let state):
            switch state {
            case .connected:
                globeImageView.tintColor = .systemBlue
            case .connecting:
                globeImageView.tintColor = .systemOrange
            case .error:
                globeImageView.tintColor = .systemRed
            case .closed:
                globeImageView.tintColor = .systemGray
            }
        case .terminal:
            break
        }
    }

    private func updateActiveState() {
        titleLabel.textColor = isActiveTab ? .label : .secondaryLabel
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isExpanded && bounds.contains(point) {
            let contentPoint = convert(point, to: containerEffectView.contentView)

            // Check URL text field first (for web tabs)
            if urlTextField.alpha > 0 && urlTextField.frame.contains(contentPoint) {
                return urlTextField
            }

            let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                          backButton, forwardButton, shareButton]
            for button in buttons where button.alpha > 0 && button.frame.contains(contentPoint) {
                return button
            }
            return self
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TabBubble: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === doubleTapGesture {
            return isActiveTab && hasMultiplePanes && !isExpanded
        }
        if gestureRecognizer === longPressGesture {
            // The context menu handles press and hold on terminal tabs
            return !usesMenu
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A single tap waits to see if it's a double tap only when double tap means something
        gestureRecognizer === tapGesture && otherGestureRecognizer === doubleTapGesture
            && isActiveTab && hasMultiplePanes && !isExpanded
    }
}

// MARK: - UITextFieldDelegate

extension TabBubble: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // User pressed "Go" - navigate to the entered path
        if let path = textField.text {
            onNavigate?(path)
        }
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        isEditingURL = true
        // Select all text for easy replacement
        textField.selectAll(nil)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        isEditingURL = false
        syncURLTextFieldIfNeeded()
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension TabBubble: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard usesMenu, isActiveTab, !isExpanded, let menu = menuButton.menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    /// Lift the tab itself, clipped to its pill, rather than a rectangular snapshot
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: glassCornerRadius)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: parameters)
    }
}
