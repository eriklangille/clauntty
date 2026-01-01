import UIKit
import os.log

/// Unified tab item representing either a terminal session or web tab
@MainActor
enum TabItem: Identifiable, Equatable {
    case terminal(Session)
    case web(WebTab)

    nonisolated var id: UUID {
        switch self {
        case .terminal(let session): return session.id
        case .web(let webTab): return webTab.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let session): return session.title
        case .web(let webTab): return webTab.title
        }
    }

    nonisolated static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Safari-style liquid glass tab bar with centered active tab
class LiquidGlassTabBar: UIView {

    // MARK: - Callbacks

    /// Called when a tab is selected
    var onTabSelected: ((TabItem) -> Void)?

    /// Called when plus button is tapped (main + or expanded + button)
    var onNewTab: (() -> Void)?

    /// Called when disconnect is requested (terminal)
    var onDisconnect: ((TabItem) -> Void)?

    /// Called when reconnect is requested (terminal)
    var onReconnect: ((TabItem) -> Void)?

    /// Called when ports button is tapped (show port forwarding)
    var onShowPorts: ((TabItem) -> Void)?

    /// Called when tabs button is tapped (show full selector)
    var onShowTabSelector: (() -> Void)?

    // Web-specific callbacks
    var onWebBack: ((TabItem) -> Void)?
    var onWebForward: ((TabItem) -> Void)?
    var onWebReload: ((TabItem) -> Void)?
    var onWebShare: ((TabItem) -> Void)?
    var onWebNavigate: ((TabItem, String) -> Void)?  // Tab + path to navigate to

    // MARK: - State

    private var allTabs: [TabItem] = []
    private var activeTabId: UUID?
    private var expandedTabId: UUID?

    // MARK: - Constants

    private let barHeight: CGFloat = 48
    private let activeBubbleHeight: CGFloat = 38
    private let inactiveBubbleHeight: CGFloat = 32  // Slightly smaller
    private let activeBubbleWidth: CGFloat = 120
    private let inactiveBubbleWidth: CGFloat = 90   // Smaller width for inactive
    private let plusButtonSize: CGFloat = 36
    private let spacing: CGFloat = 6
    private let horizontalPadding: CGFloat = 8
    private let topPadding: CGFloat = 4

    /// Max visible tabs depends on orientation (3 portrait, 5 landscape)
    private var maxVisibleTabs: Int {
        let isLandscape = bounds.width > bounds.height * 1.5  // Rough check for landscape
        return isLandscape ? 5 : 3
    }

    /// Whether the active tab is expanded
    private var isExpanded: Bool = false

    /// Flag to prevent layoutBubbles from interfering with collapse animation
    private var isCollapseAnimating: Bool = false

    /// Flag to prevent layout during expanded tab transition
    private var isExpandedTransitioning: Bool = false

    /// Direction of expanded tab transition (true = next/left, false = previous/right)
    private var transitionToNext: Bool = true

    /// Track if we have tabs pending layout (when bounds were 0)
    private var hasPendingLayout: Bool = false

    /// Previous container width to detect when bounds become valid
    private var previousContainerWidth: CGFloat = 0

    // MARK: - Views

    /// Container for tab bubbles (allows centering)
    private let bubblesContainer = UIView()

    /// Individual bubble views keyed by tab ID
    private var bubbleViews: [UUID: TabBubble] = [:]

    /// Plus button
    private let plusButton: UIVisualEffectView = {
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

    private let plusIconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = UIImage(systemName: "square.on.square", withConfiguration: config)
        let imageView = UIImageView(image: image)
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()


    // MARK: - Gesture State

    private var panStartX: CGFloat = 0
    private var panStartActiveIndex: Int = 0

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
        clipsToBounds = false  // Allow expanded overlay to extend beyond bounds

        // Setup bubbles container
        bubblesContainer.translatesAutoresizingMaskIntoConstraints = false
        bubblesContainer.backgroundColor = .clear
        addSubview(bubblesContainer)

        // Setup plus button
        setupPlusButton()

        setupConstraints()
        setupGestures()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // When view is added to window, force layout if we have pending tabs
        if window != nil && !allTabs.isEmpty && bubbleViews.isEmpty {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    private func setupPlusButton() {
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.layer.cornerRadius = plusButtonSize / 2
        addSubview(plusButton)

        plusIconView.translatesAutoresizingMaskIntoConstraints = false
        plusButton.contentView.addSubview(plusIconView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePlusTap))
        plusButton.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            plusIconView.centerXAnchor.constraint(equalTo: plusButton.contentView.centerXAnchor),
            plusIconView.centerYAnchor.constraint(equalTo: plusButton.contentView.centerYAnchor),
        ])
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Bubbles container - fills available space minus plus button
            bubblesContainer.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
            bubblesContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            bubblesContainer.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -spacing),
            bubblesContainer.heightAnchor.constraint(equalToConstant: barHeight - topPadding * 2),

            // Plus button - right side
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            plusButton.centerYAnchor.constraint(equalTo: bubblesContainer.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: plusButtonSize),
            plusButton.heightAnchor.constraint(equalToConstant: plusButtonSize),
        ])
    }

    private func setupGestures() {
        // Pan gesture for scrolling through tabs
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        bubblesContainer.addGestureRecognizer(pan)
    }

    @objc private func handlePlusTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        onShowTabSelector?()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            panStartX = translation.x
            if let activeId = activeTabId,
               let index = allTabs.firstIndex(where: { $0.id == activeId }) {
                panStartActiveIndex = index
            }

        case .changed:
            // Provide visual feedback during pan
            break

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self)
            let threshold: CGFloat = 50

            if translation.x > threshold || velocity.x > 500 {
                // Swiped right - go to previous tab
                switchToPreviousTab()
            } else if translation.x < -threshold || velocity.x < -500 {
                // Swiped left - go to next tab
                switchToNextTab()
            }

        default:
            break
        }
    }

    private func switchToPreviousTab() {
        guard let activeId = activeTabId,
              let currentIndex = allTabs.firstIndex(where: { $0.id == activeId }),
              currentIndex > 0 else { return }

        let previousTab = allTabs[currentIndex - 1]
        triggerHaptic()
        onTabSelected?(previousTab)
    }

    private func switchToNextTab() {
        guard let activeId = activeTabId,
              let currentIndex = allTabs.firstIndex(where: { $0.id == activeId }),
              currentIndex < allTabs.count - 1 else { return }

        let nextTab = allTabs[currentIndex + 1]
        triggerHaptic()
        onTabSelected?(nextTab)
    }

    /// Switch to next tab while keeping expanded state (slide animation)
    private func switchToNextTabExpanded() {
        guard let activeId = activeTabId,
              let currentIndex = allTabs.firstIndex(where: { $0.id == activeId }),
              currentIndex < allTabs.count - 1,
              let currentBubble = bubbleViews[activeId] else { return }

        let nextTab = allTabs[currentIndex + 1]
        triggerHaptic()

        // Mark that we're transitioning
        isExpandedTransitioning = true
        transitionToNext = true

        // Get or create the next bubble
        let nextBubble = getOrCreateBubble(for: nextTab)

        // Perform the slide transition
        performExpandedSlideTransition(
            from: currentBubble,
            to: nextBubble,
            newTab: nextTab,
            slideLeft: true
        )
    }

    /// Switch to previous tab while keeping expanded state (slide animation)
    private func switchToPreviousTabExpanded() {
        guard let activeId = activeTabId,
              let currentIndex = allTabs.firstIndex(where: { $0.id == activeId }),
              currentIndex > 0,
              let currentBubble = bubbleViews[activeId] else { return }

        let previousTab = allTabs[currentIndex - 1]
        triggerHaptic()

        // Mark that we're transitioning
        isExpandedTransitioning = true
        transitionToNext = false

        // Get or create the previous bubble
        let prevBubble = getOrCreateBubble(for: previousTab)

        // Perform the slide transition
        performExpandedSlideTransition(
            from: currentBubble,
            to: prevBubble,
            newTab: previousTab,
            slideLeft: false
        )
    }

    /// Perform slide animation between two expanded tabs
    private func performExpandedSlideTransition(from oldBubble: TabBubble, to newBubble: TabBubble, newTab: TabItem, slideLeft: Bool) {
        let expandedHeight: CGFloat = 108
        let fullWidth = bounds.width - horizontalPadding * 2
        let topY = topPadding

        // Current (old) bubble's frame
        let centerFrame = CGRect(x: horizontalPadding, y: topY, width: fullWidth, height: expandedHeight)

        // Position where old bubble will slide to (off screen)
        let offscreenOffset = bounds.width + 20
        let oldTargetX = slideLeft ? (horizontalPadding - offscreenOffset) : (horizontalPadding + offscreenOffset)

        // Position where new bubble starts (off screen, opposite side)
        let newStartX = slideLeft ? (horizontalPadding + offscreenOffset) : (horizontalPadding - offscreenOffset)

        // Move new bubble to self (like the old one) and position it off-screen
        if newBubble.superview != self {
            newBubble.removeFromSuperview()
            addSubview(newBubble)
        }

        // Set up new bubble in expanded state at starting position (off-screen)
        newBubble.frame = CGRect(x: newStartX, y: topY, width: fullWidth, height: expandedHeight)
        newBubble.isActiveTab = true
        newBubble.setExpandedSilently(true)  // Set expanded without triggering pop animation
        newBubble.setGlassCornerRadius(26)
        newBubble.alpha = 1

        // Show expanded content on new bubble immediately (no pop animation)
        newBubble.showExpandedContentInstant()

        // Animate both bubbles
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            // Slide old bubble out
            oldBubble.frame.origin.x = oldTargetX

            // Slide new bubble in
            newBubble.frame = centerFrame
        } completion: { _ in
            // Hide old bubble content and reset its state (silently, no animation)
            oldBubble.setExpandedSilently(false)
            oldBubble.alpha = 0

            // Move old bubble back to container
            oldBubble.removeFromSuperview()
            self.bubblesContainer.addSubview(oldBubble)

            // Update state
            self.expandedTabId = newTab.id
            self.activeTabId = newTab.id
            self.isExpandedTransitioning = false

            // Notify that tab changed
            self.onTabSelected?(newTab)
        }
    }

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBubbles()
    }

    /// Layout bubbles with active tab always centered under dynamic island
    private func layoutBubbles() {
        // Skip layout during collapse animation to prevent interference
        guard !isCollapseAnimating else {
            Logger.clauntty.info("layoutBubbles SKIPPED: isCollapseAnimating=true")
            return
        }
        // Skip layout during expanded-to-expanded transition (slide animation handles it)
        guard !isExpandedTransitioning else {
            Logger.clauntty.info("layoutBubbles SKIPPED: isExpandedTransitioning=true")
            return
        }
        guard !allTabs.isEmpty else { return }

        let containerWidth = bubblesContainer.bounds.width
        let containerHeight = bubblesContainer.bounds.height

        // Track if bounds became valid after being 0
        if containerWidth > 0 && previousContainerWidth == 0 && hasPendingLayout {
            Logger.clauntty.debugOnly("LiquidGlassTabBar: bounds now valid, laying out \(allTabs.count) pending tabs")
            hasPendingLayout = false
        }
        previousContainerWidth = containerWidth

        guard containerWidth > 0 else {
            // Mark that we have tabs waiting for valid bounds
            hasPendingLayout = true
            return
        }

        // If expanded, show only the active tab at full width
        if isExpanded, let activeId = activeTabId, let activeTab = allTabs.first(where: { $0.id == activeId }) {
            layoutExpandedBubble(activeTab: activeTab, containerWidth: containerWidth)
            return
        }

        // Calculate which tabs to show (max 3, active always in middle)
        let visibleTabs = calculateVisibleTabs()
        guard !visibleTabs.isEmpty else { return }

        // Find the active tab's position in visible tabs
        let activeIndex = visibleTabs.firstIndex(where: { $0.id == activeTabId }) ?? 0

        // Center the ACTIVE tab under the dynamic island
        // Calculate where the active tab's center should be
        let barCenterX = bounds.width / 2
        let containerOriginX = horizontalPadding
        let centerInContainer = barCenterX - containerOriginX

        // Calculate width of tabs before the active tab
        var widthBeforeActive: CGFloat = 0
        for _ in 0..<activeIndex {
            widthBeforeActive += inactiveBubbleWidth + spacing
        }

        // The active tab's center should be at centerInContainer
        // So active tab's left edge is at: centerInContainer - activeBubbleWidth/2
        // And the first tab's left edge is at: activeTabLeftEdge - widthBeforeActive
        let activeTabLeftEdge = centerInContainer - activeBubbleWidth / 2
        var currentX = activeTabLeftEdge - widthBeforeActive

        // Position each visible bubble
        for tab in visibleTabs {
            let bubble = getOrCreateBubble(for: tab)

            // Move bubble back to bubblesContainer if it was in self (from expanded state)
            if bubble.superview != bubblesContainer {
                bubble.removeFromSuperview()
                bubblesContainer.addSubview(bubble)
            }

            let isActive = tab.id == activeTabId
            let bubbleWidth = isActive ? activeBubbleWidth : inactiveBubbleWidth
            let bubbleHeight = isActive ? activeBubbleHeight : inactiveBubbleHeight
            let y = (containerHeight - bubbleHeight) / 2  // Vertically center

            let frame = CGRect(x: currentX, y: y, width: bubbleWidth, height: bubbleHeight)
            currentX += bubbleWidth + spacing

            // Check if this is a newly created bubble - set frame instantly, no animation
            if newlyCreatedBubbleIds.contains(tab.id) {
                newlyCreatedBubbleIds.remove(tab.id)
                bubble.frame = frame
                bubble.alpha = 1
                bubble.transform = .identity
            } else {
                // Existing bubble - animate position change
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    bubble.frame = frame
                    bubble.alpha = 1
                    bubble.transform = .identity
                }
            }

            bubble.isActiveTab = isActive
            bubble.isExpanded = false
        }

        // Hide bubbles not in visible set
        for (id, bubble) in bubbleViews {
            if !visibleTabs.contains(where: { $0.id == id }) {
                UIView.animate(withDuration: 0.2) {
                    bubble.alpha = 0
                }
            }
        }
    }

    /// Layout for expanded state - active tab takes full screen width with two rows
    private func layoutExpandedBubble(activeTab: TabItem, containerWidth: CGFloat) {
        let bubble = getOrCreateBubble(for: activeTab)
        let expandedHeight: CGFloat = 108  // Two rows: 8 + 44 + 4 + 44 + 8
        let fullWidth = bounds.width - horizontalPadding * 2
        let targetCenterY = topPadding + expandedHeight / 2
        let targetFrame = CGRect(
            x: horizontalPadding,
            y: topPadding,
            width: fullWidth,
            height: expandedHeight
        )

        // If bubble is already expanded and in self (from slide transition), skip animation
        if bubble.isExpanded && bubble.superview == self {
            // Just ensure frame is correct without animation
            UIView.performWithoutAnimation {
                bubble.frame = targetFrame
                bubble.setGlassCornerRadius(26)
                // Hide other bubbles and plus button
                for (id, otherBubble) in bubbleViews {
                    if id != activeTab.id {
                        otherBubble.alpha = 0
                    }
                }
                plusButton.alpha = 0
            }
            return
        }

        // Move bubble to self (the bar) so it can extend full width
        if bubble.superview != self {
            // Convert current frame to self's coordinate system
            let frameInSelf = bubblesContainer.convert(bubble.frame, to: self)
            bubble.removeFromSuperview()
            addSubview(bubble)
            bubble.frame = frameInSelf
        }

        // Get current frame - this is the point we expand FROM
        let startFrame = bubble.frame

        // Set expanded state
        bubble.isActiveTab = true

        // Hide other bubbles and plus button immediately
        for (id, otherBubble) in bubbleViews {
            if id != activeTab.id {
                otherBubble.alpha = 0
            }
        }
        plusButton.alpha = 0

        // Calculate scale factors
        let scaleX = fullWidth / startFrame.width
        let scaleY = expandedHeight / startFrame.height

        // Hide content before scaling (so only glass scales, not text)
        bubble.hideContentForExpansion()

        // Store starting corner radius and calculate target
        let startCornerRadius = bubble.glassCornerRadius
        let endCornerRadius: CGFloat = 26

        // Use scale transform animation - this ALWAYS expands from center
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut]) {
            bubble.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            // Also move center vertically
            bubble.center.y = targetCenterY
        } completion: { _ in
            // Remove transform and set final frame
            bubble.transform = .identity
            bubble.frame = targetFrame

            // Animate corner radius AFTER transform is removed (scale affects visual radius)
            let cornerAnimation = CABasicAnimation(keyPath: "cornerRadius")
            cornerAnimation.fromValue = startCornerRadius
            cornerAnimation.toValue = endCornerRadius
            cornerAnimation.duration = 0.1
            cornerAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.setGlassCornerRadius(endCornerRadius)
            bubble.glassLayer.add(cornerAnimation, forKey: "cornerRadius")

            // Show expanded content with pop animation
            bubble.showExpandedContent()
        }
    }

    /// Calculate which tabs should be visible (maxVisibleTabs varies by orientation)
    /// Active tab is always centered when possible
    private func calculateVisibleTabs() -> [TabItem] {
        guard !allTabs.isEmpty else { return [] }
        guard let activeId = activeTabId,
              let activeIndex = allTabs.firstIndex(where: { $0.id == activeId }) else {
            // No active tab, show first tabs up to max
            return Array(allTabs.prefix(min(maxVisibleTabs, allTabs.count)))
        }

        let totalTabs = allTabs.count
        let maxVisible = maxVisibleTabs

        // If we have fewer tabs than max visible, show all
        if totalTabs <= maxVisible {
            return allTabs
        }

        // Calculate how many tabs to show on each side of active
        // For maxVisible=3: 1 on each side. For maxVisible=5: 2 on each side
        let slotsPerSide = (maxVisible - 1) / 2

        // Calculate start and end indices
        var startIndex = activeIndex - slotsPerSide
        var endIndex = activeIndex + slotsPerSide

        // Adjust if we're near the start
        if startIndex < 0 {
            endIndex += (-startIndex)  // Add the overflow to the end
            startIndex = 0
        }

        // Adjust if we're near the end
        if endIndex >= totalTabs {
            startIndex -= (endIndex - totalTabs + 1)  // Subtract the overflow from start
            endIndex = totalTabs - 1
        }

        // Clamp to valid range
        startIndex = max(0, startIndex)
        endIndex = min(totalTabs - 1, endIndex)

        return Array(allTabs[startIndex...endIndex])
    }

    /// Track which bubbles are newly created (need instant positioning, no animation)
    private var newlyCreatedBubbleIds: Set<UUID> = []

    private func getOrCreateBubble(for tab: TabItem) -> TabBubble {
        if let existing = bubbleViews[tab.id] {
            // Update existing bubble
            switch tab {
            case .terminal(let session):
                existing.configure(session: session)
            case .web(let webTab):
                existing.configure(webTab: webTab)
            }
            return existing
        }

        // Create new bubble - mark as new so layoutBubbles skips animation
        newlyCreatedBubbleIds.insert(tab.id)
        let bubble = TabBubble()
        switch tab {
        case .terminal(let session):
            bubble.configure(session: session)
        case .web(let webTab):
            bubble.configure(webTab: webTab)
        }

        // Tap handler (collapsed state)
        bubble.onTap = { [weak self] in
            self?.handleBubbleTap(tab)
        }

        // Long press handler - expands active tab immediately
        bubble.onLongPress = { [weak self] in
            guard let self = self else { return }
            // Only expand if this is the active tab
            if tab.id == self.activeTabId && !self.isExpanded {
                self.triggerHaptic()
                self.isExpanded = true
                self.expandedTabId = self.activeTabId
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }

        // Swipe handlers for expanded state - switch tabs while keeping expanded
        bubble.onSwipeLeft = { [weak self] in
            self?.switchToNextTabExpanded()
        }

        bubble.onSwipeRight = { [weak self] in
            self?.switchToPreviousTabExpanded()
        }

        // Swipe handlers for collapsed state - switch tabs normally
        bubble.onSwipeLeftCollapsed = { [weak self] in
            self?.switchToNextTab()
        }

        bubble.onSwipeRightCollapsed = { [weak self] in
            self?.switchToPreviousTab()
        }

        // Expanded state action handlers
        bubble.onDisconnect = { [weak self] in
            self?.collapseExpanded()
            self?.onDisconnect?(tab)
        }

        bubble.onReconnect = { [weak self] in
            self?.collapseExpanded()
            self?.onReconnect?(tab)
        }

        bubble.onPorts = { [weak self] in
            Logger.clauntty.info("LiquidGlassTabBar: onPorts callback fired, onShowPorts exists=\(self?.onShowPorts != nil)")
            self?.collapseExpanded()
            self?.onShowPorts?(tab)
        }

        bubble.onTabs = { [weak self] in
            self?.collapseExpanded()
            self?.onShowTabSelector?()
        }

        bubble.onNewTab = { [weak self] in
            self?.collapseExpanded()
            self?.onNewTab?()
        }

        bubble.onDismiss = { [weak self] in
            self?.collapseExpanded()
        }

        // Web-specific handlers
        bubble.onBack = { [weak self] in
            self?.onWebBack?(tab)
        }

        bubble.onForward = { [weak self] in
            self?.onWebForward?(tab)
        }

        bubble.onReload = { [weak self] in
            self?.onWebReload?(tab)
        }

        bubble.onShare = { [weak self] in
            self?.onWebShare?(tab)
        }

        bubble.onNavigate = { [weak self] path in
            self?.onWebNavigate?(tab, path)
        }

        bubbleViews[tab.id] = bubble
        bubblesContainer.addSubview(bubble)

        return bubble
    }

    private func handleBubbleTap(_ tab: TabItem) {
        if tab.id == activeTabId {
            // Tapped active tab - toggle expansion
            triggerHaptic()
            toggleExpansion()
        } else {
            // Tapped inactive tab - switch to it
            triggerHaptic()
            onTabSelected?(tab)
        }
    }

    /// Toggle the expanded state of the active tab
    private func toggleExpansion() {
        if isExpanded {
            // Collapsing - use scale animation
            collapseExpanded()
        } else {
            // Expanding - trigger layout which will call layoutExpandedBubble
            isExpanded = true
            expandedTabId = activeTabId
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    /// Collapse the expanded tab (called from TabBubble actions)
    func collapseExpanded() {
        guard isExpanded, !isCollapseAnimating, let activeId = activeTabId, let bubble = bubbleViews[activeId] else { return }

        Logger.clauntty.info("COLLAPSE START: setting isCollapseAnimating=true")
        isCollapseAnimating = true

        // Store the bubble ID to check if it's still valid after animation
        let collapsingBubbleId = activeId

        Logger.clauntty.info("COLLAPSE: bubble.frame=\(NSCoder.string(for: bubble.frame)), bubble.bounds=\(NSCoder.string(for: bubble.bounds))")

        // DON'T set isExpanded = false here - it triggers layoutSubviews which interferes with animation
        expandedTabId = nil

        // Calculate collapsed size
        let collapsedWidth = activeBubbleWidth
        let collapsedHeight = activeBubbleHeight

        // Calculate scale factors (reverse of expand)
        let currentWidth = bubble.bounds.width
        let currentHeight = bubble.bounds.height
        let scaleX = collapsedWidth / currentWidth
        let scaleY = collapsedHeight / currentHeight

        Logger.clauntty.info("COLLAPSE: currentSize=\(currentWidth)x\(currentHeight), collapsedSize=\(collapsedWidth)x\(collapsedHeight)")
        Logger.clauntty.info("COLLAPSE: scaleX=\(scaleX), scaleY=\(scaleY) (should both be < 1)")

        // Calculate target center Y for collapsed state (where small tab should end up)
        // Collapsed tab sits vertically centered in bubblesContainer
        let containerHeight = bubblesContainer.bounds.height
        let collapsedCenterYInContainer = (containerHeight - collapsedHeight) / 2 + collapsedHeight / 2
        let targetCenterY = topPadding + collapsedCenterYInContainer

        Logger.clauntty.info("COLLAPSE: bubble.center.y=\(bubble.center.y), targetCenterY=\(targetCenterY)")

        // Hide ALL content immediately (both expanded and collapsed content, so only glass shrinks)
        bubble.hideContentForCollapse()

        // Calculate corner radius for collapsed state (pill shape)
        let startCornerRadius = bubble.glassCornerRadius
        let endCornerRadius = min(collapsedHeight / 2, 20)

        // Animate scale down AND move center up to where collapsed tab should be
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .overrideInheritedDuration, .overrideInheritedOptions]) {
            Logger.clauntty.info("COLLAPSE ANIMATING: applying scale transform + moving center up")
            bubble.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            bubble.center.y = targetCenterY  // Move up while shrinking
            self.plusButton.alpha = 1
        } completion: { _ in
            Logger.clauntty.info("COLLAPSE COMPLETE: removing transform and repositioning")

            // Check if bubble was removed during animation (e.g., tab was closed)
            guard self.bubbleViews[collapsingBubbleId] != nil else {
                Logger.clauntty.info("COLLAPSE: bubble was removed during animation, skipping re-add")
                self.isExpanded = false
                self.isCollapseAnimating = false
                // Trigger layout since it was skipped while isCollapseAnimating was true
                self.setNeedsLayout()
                self.layoutIfNeeded()
                return
            }

            // Remove transform first
            bubble.transform = .identity

            // Calculate collapsed frame - center under dynamic island
            let barCenterX = self.bounds.width / 2
            let containerOriginX = self.bubblesContainer.frame.origin.x
            let xInContainer = barCenterX - containerOriginX - collapsedWidth / 2
            let finalContainerHeight = self.bubblesContainer.bounds.height
            let y = (finalContainerHeight - collapsedHeight) / 2

            // Move bubble back to container with correct frame
            bubble.removeFromSuperview()
            self.bubblesContainer.addSubview(bubble)
            bubble.frame = CGRect(x: xInContainer, y: y, width: collapsedWidth, height: collapsedHeight)

            // Animate corner radius AFTER transform is removed
            let cornerAnimation = CABasicAnimation(keyPath: "cornerRadius")
            cornerAnimation.fromValue = startCornerRadius
            cornerAnimation.toValue = endCornerRadius
            cornerAnimation.duration = 0.1
            cornerAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.setGlassCornerRadius(endCornerRadius)
            bubble.glassLayer.add(cornerAnimation, forKey: "cornerRadius")

            // Show collapsed content with pop animation
            bubble.showCollapsedContent()

            // Now safe to update state - layout will run but bubble is already positioned
            self.isExpanded = false
            self.isCollapseAnimating = false
            Logger.clauntty.info("COLLAPSE DONE: isCollapseAnimating=false, bubble.frame=\(NSCoder.string(for: bubble.frame))")
        }
    }

    // MARK: - Public Update

    /// Update the tab bar with current state
    func update(sessions: [Session], webTabs: [WebTab], activeTab: SessionManager.ActiveTab?) {
        // Build unified tab list (terminal tabs first, then web tabs)
        var tabs: [TabItem] = sessions.map { .terminal($0) }
        tabs.append(contentsOf: webTabs.map { .web($0) })
        allTabs = tabs

        // Update active tab ID
        switch activeTab {
        case .terminal(let id):
            activeTabId = id
        case .web(let id):
            activeTabId = id
        case .none:
            activeTabId = nil
        }

        // Remove bubbles for tabs that no longer exist
        let currentIds = Set(tabs.map { $0.id })
        for (id, bubble) in bubbleViews {
            if !currentIds.contains(id) {
                bubble.removeFromSuperview()
                bubbleViews.removeValue(forKey: id)
            }
        }

        // Force re-configure existing bubbles with current state
        // This ensures status colors and titles are updated when session state changes
        for session in sessions {
            if let bubble = bubbleViews[session.id] {
                bubble.configure(session: session)
            }
        }
        for webTab in webTabs {
            if let bubble = bubbleViews[webTab.id] {
                bubble.configure(webTab: webTab)
            }
        }

        // Collapse if active tab changed
        if let expandedId = expandedTabId, expandedId != activeTabId {
            collapseExpanded()
        }

        setNeedsLayout()

        // If bounds are not yet valid, schedule a retry after the view is laid out
        // This handles the case where update() is called before the view has valid bounds
        if bubblesContainer.bounds.width == 0 && !allTabs.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsLayout()
                self?.layoutIfNeeded()
            }
        }
    }

    // MARK: - Hit Testing

    /// Ensure the tab bar captures all touches within its bounds (blocks terminal underneath)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // When expanded, we need special handling
        if isExpanded, let expandedId = expandedTabId, let bubble = bubbleViews[expandedId] {
            let bubblePoint = convert(point, to: bubble)
            if bubble.bounds.contains(bubblePoint) {
                // Let the bubble handle hit testing for its buttons
                if let hitView = bubble.hitTest(bubblePoint, with: event) {
                    return hitView
                }
                return bubble
            } else {
                // Tap is OUTSIDE the expanded bubble - return self to capture and collapse
                // This prevents the tap from reaching the terminal
                return self
            }
        }

        // First check if any subview should handle the touch
        if let hitView = super.hitTest(point, with: event) {
            return hitView
        }

        // If point is within our bounds, capture the touch (don't let it pass to terminal)
        if bounds.contains(point) {
            return self
        }

        return nil
    }

    /// Handle touches to collapse expanded tab when tapping outside
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isExpanded, let touch = touches.first, let expandedId = expandedTabId, let bubble = bubbleViews[expandedId] {
            let point = touch.location(in: self)
            let bubblePoint = convert(point, to: bubble)
            // If tap is outside the expanded bubble, collapse it
            if !bubble.bounds.contains(bubblePoint) {
                collapseExpanded()
                return
            }
        }
        super.touchesBegan(touches, with: event)
    }

    /// Allow touches outside bounds when expanded (to capture taps and collapse)
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // When expanded, capture ALL touches so we can collapse on tap outside
        if isExpanded {
            return true
        }
        return bounds.contains(point)
    }
}
