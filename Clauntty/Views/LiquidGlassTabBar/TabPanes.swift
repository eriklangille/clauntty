import UIKit

/// Agent state of one pane
enum PaneStatus: Equatable {
    /// No agent in the pane (a shell, a dev server)
    case none
    case idle
    case working
    case blocked
    case done

    var tint: UIColor {
        switch self {
        case .none: return UIColor.label.withAlphaComponent(0.35)
        case .idle: return UIColor.label.withAlphaComponent(0.6)
        case .working: return .systemCyan
        case .blocked: return .systemOrange
        case .done: return .systemGreen
        }
    }
}

/// One pane inside a session tab
struct TabPane: Equatable {
    let id: String
    var title: String
    var status: PaneStatus
    /// Tab the pane belongs to within its group. Panes in the same tab are splits on the desktop.
    var group: Int
}

/// Session menu actions on the pane a workspace tab shows
enum PaneAction {
    /// A new pane next to it (a split on the desktop)
    case split
    /// A new tab in the workspace, with one pane
    case newTab
    /// End the pane
    case close
}

// MARK: - Status Indicator

/// Small glyph for a pane's agent state: a spinning arc while working, a pulsing
/// orange dot when blocked, green when done, a hollow ring when idle
final class PaneStatusIndicator: UIView {

    var status: PaneStatus = .none {
        didSet {
            if oldValue != status { refresh() }
        }
    }

    private let dotLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 1.5
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)
        layer.addSublayer(dotLayer)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ringLayer.frame = bounds
        dotLayer.frame = bounds
        ringLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
        let dotInset: CGFloat = status == .none ? bounds.width * 0.3 : bounds.width * 0.1
        dotLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: dotInset, dy: dotInset)).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Animations are dropped when the layer leaves the window
        if window != nil { refresh() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refresh()
    }

    private func refresh() {
        let tint = status.tint.resolvedColor(with: traitCollection).cgColor
        ringLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
        ringLayer.strokeStart = 0
        ringLayer.strokeEnd = 1

        switch status {
        case .none, .done:
            ringLayer.isHidden = true
            dotLayer.isHidden = false
            dotLayer.fillColor = tint
        case .idle:
            ringLayer.isHidden = false
            dotLayer.isHidden = true
            ringLayer.strokeColor = tint
        case .working:
            ringLayer.isHidden = false
            dotLayer.isHidden = true
            ringLayer.strokeColor = tint
            ringLayer.strokeEnd = 0.7
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 0.9
            spin.repeatCount = .infinity
            ringLayer.add(spin, forKey: "spin")
        case .blocked:
            ringLayer.isHidden = true
            dotLayer.isHidden = false
            dotLayer.fillColor = tint
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(pulse, forKey: "pulse")
        }
        setNeedsLayout()
    }
}

// MARK: - Collapsed Indicator

/// Row of dots under the collapsed tab's title, one per pane. The current pane is a
/// short capsule; other panes show orange when blocked and green when done.
final class PaneDotsView: UIView {

    static let height: CGFloat = 4

    private let dotSize: CGFloat = 4
    private let activeDotWidth: CGFloat = 10
    private let gap: CGFloat = 3
    private let maxDots = 7

    private var panes: [TabPane] = []
    private var activeIndex = 0
    private var dotLayers: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(panes: [TabPane], activeIndex: Int) {
        self.panes = panes
        self.activeIndex = activeIndex
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !panes.isEmpty, bounds.width > 0 else {
            dotLayers.forEach { $0.isHidden = true }
            return
        }

        // Show a window of dots around the current pane when there are many
        let count = min(panes.count, maxDots)
        let start = min(max(activeIndex - count / 2, 0), panes.count - count)

        while dotLayers.count < count {
            let dot = CALayer()
            layer.addSublayer(dot)
            dotLayers.append(dot)
        }

        let totalWidth = CGFloat(count - 1) * (dotSize + gap) + activeDotWidth
        var x = (bounds.width - totalWidth) / 2

        for (slot, dot) in dotLayers.enumerated() {
            guard slot < count else {
                dot.isHidden = true
                continue
            }
            let index = start + slot
            let isActive = index == activeIndex
            let width = isActive ? activeDotWidth : dotSize
            dot.isHidden = false
            dot.frame = CGRect(x: x, y: (bounds.height - dotSize) / 2, width: width, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = color(for: panes[index], isActive: isActive).resolvedColor(with: traitCollection).cgColor
            x += width + gap
        }
    }

    private func color(for pane: TabPane, isActive: Bool) -> UIColor {
        if isActive { return UIColor.label.withAlphaComponent(0.9) }
        switch pane.status {
        case .blocked, .done: return pane.status.tint
        default: return UIColor.label.withAlphaComponent(0.3)
        }
    }
}

// MARK: - Expanded Tab

extension PaneStatus {
    /// Subtitle for a pane in the session menu, empty when there's nothing worth saying
    var label: String {
        switch self {
        case .working: return "Working"
        case .blocked: return "Needs you"
        case .done: return "Done"
        case .idle, .none: return ""
        }
    }

    /// SF Symbol for menus, which can't host the animated indicator
    var symbolName: String {
        switch self {
        case .working: return "circle.dotted"
        case .blocked: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "circle"
        case .none: return "terminal"
        }
    }
}

/// Native menu for the active session tab: the tab's actions as an icon row, then
/// its panes, one section per tab in the group
enum SessionTabMenu {
    static func make(
        title: String,
        panes: [TabPane],
        activeIndex: Int,
        onSelectPane: @escaping (Int) -> Void,
        onTabs: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        onPorts: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPaneAction: ((PaneAction) -> Void)? = nil
    ) -> UIMenu {
        let actions = UIMenu(options: .displayInline, preferredElementSize: .small, children: [
            UIAction(title: "All Tabs", image: UIImage(systemName: "square.on.square")) { _ in onTabs() },
            UIAction(title: "New Tab", image: UIImage(systemName: "plus")) { _ in onNewTab() },
            UIAction(title: "Ports", image: UIImage(systemName: "globe")) { _ in onPorts() },
            UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in onClose() },
        ])

        var sections: [UIMenuElement] = [actions]
        // Workspace tabs: actions on the pane shown
        if let onPaneAction, !panes.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "New Pane", image: UIImage(systemName: "rectangle.split.2x1")) { _ in onPaneAction(.split) },
                UIAction(title: "New Workspace Tab", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { _ in onPaneAction(.newTab) },
                UIAction(title: "End Pane", image: UIImage(systemName: "xmark.rectangle"), attributes: .destructive) { _ in onPaneAction(.close) },
            ]))
        }
        var groupStart = 0
        for index in panes.indices where index == panes.count - 1 || panes[index + 1].group != panes[index].group {
            let children = (groupStart...index).map { paneIndex -> UIAction in
                let pane = panes[paneIndex]
                let image = UIImage(systemName: pane.status.symbolName)?
                    .withTintColor(pane.status.tint, renderingMode: .alwaysOriginal)
                let action = UIAction(title: pane.title, image: image, state: paneIndex == activeIndex ? .on : .off) { _ in
                    onSelectPane(paneIndex)
                }
                if !pane.status.label.isEmpty {
                    action.subtitle = pane.status.label
                }
                return action
            }
            sections.append(UIMenu(options: .displayInline, children: children))
            groupStart = index + 1
        }
        return UIMenu(title: title, children: sections)
    }
}

/// Holds the session menu without taking touches; the tab presents it on tap
final class PassthroughMenuButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

// MARK: - Fake Data

#if DEBUG
/// Fake panes for prototyping the pane UI without real session groups.
/// Enable with `-fakeTabPanes YES` as a launch argument.
enum FakeTabPanes {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "fakeTabPanes")
    }

    private static let scenarios: [[TabPane]] = [
        [
            TabPane(id: "w1:p1", title: "Competitor scrape results", status: .working, group: 0),
            TabPane(id: "w1:p2", title: "zsh", status: .none, group: 0),
            TabPane(id: "w1:p3", title: "Fix login redirect", status: .blocked, group: 1),
        ],
        [
            TabPane(id: "w2:p1", title: "Refactor billing", status: .done, group: 0),
            TabPane(id: "w2:p2", title: "npm run dev", status: .none, group: 1),
        ],
        [
            TabPane(id: "w3:p1", title: "Herdr tab plan", status: .idle, group: 0),
            TabPane(id: "w3:p2", title: "Review diff", status: .working, group: 1),
            TabPane(id: "w3:p3", title: "bun test --watch", status: .none, group: 1),
            TabPane(id: "w3:p4", title: "tail -f server.log", status: .none, group: 2),
            TabPane(id: "w3:p5", title: "Voice bar shader", status: .done, group: 3),
        ],
        [
            TabPane(id: "w4:p1", title: "Projects", status: .idle, group: 0),
        ],
    ]

    /// A stable scenario per tab, so a tab keeps its panes across updates
    static func panes(for tabId: UUID) -> [TabPane] {
        let sum = withUnsafeBytes(of: tabId.uuid) { bytes in bytes.reduce(0) { $0 + Int($1) } }
        return scenarios[sum % scenarios.count]
    }
}
#endif
