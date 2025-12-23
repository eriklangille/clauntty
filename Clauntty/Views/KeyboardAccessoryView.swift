import UIKit

/// Keyboard accessory bar with terminal-specific keys and arrow "nipple"
class KeyboardAccessoryView: UIView {

    /// Callback for sending key data to the terminal
    var onKeyInput: ((Data) -> Void)?

    /// Whether Ctrl modifier is active (sticky toggle)
    private var isCtrlActive = false {
        didSet {
            updateCtrlButton()
        }
    }

    private let ctrlButton = UIButton(type: .system)
    private let nippleView = ArrowNippleView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = UIColor(white: 0.12, alpha: 1.0)

        // Create buttons
        let escButton = createButton("Esc") { [weak self] in
            self?.sendEscape()
        }

        let tabButton = createButton("Tab") { [weak self] in
            self?.sendTab()
        }

        ctrlButton.setTitle("Ctrl", for: .normal)
        ctrlButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        ctrlButton.setTitleColor(.white, for: .normal)
        ctrlButton.backgroundColor = UIColor(white: 0.25, alpha: 1.0)
        ctrlButton.layer.cornerRadius = 6
        ctrlButton.accessibilityIdentifier = "Ctrl"
        ctrlButton.isAccessibilityElement = true
        ctrlButton.addAction(UIAction { [weak self] _ in
            self?.toggleCtrl()
        }, for: .touchUpInside)

        // Arrow nipple
        nippleView.onArrowInput = { [weak self] direction in
            self?.sendArrow(direction)
        }

        let ctrlCButton = createButton("^C") { [weak self] in
            self?.sendCtrlC()
        }

        let ctrlLButton = createButton("^L") { [weak self] in
            self?.sendCtrlL()
        }

        let ctrlDButton = createButton("^D") { [weak self] in
            self?.sendCtrlD()
        }

        // Layout with stack view
        let stackView = UIStackView(arrangedSubviews: [
            escButton, tabButton, ctrlButton, nippleView, ctrlCButton, ctrlLButton, ctrlDButton
        ])
        stackView.axis = .horizontal
        stackView.distribution = .fill
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            // Fixed sizes for buttons
            escButton.widthAnchor.constraint(equalToConstant: 44),
            escButton.heightAnchor.constraint(equalToConstant: 36),
            tabButton.widthAnchor.constraint(equalToConstant: 44),
            tabButton.heightAnchor.constraint(equalToConstant: 36),
            ctrlButton.widthAnchor.constraint(equalToConstant: 44),
            ctrlButton.heightAnchor.constraint(equalToConstant: 36),
            ctrlCButton.widthAnchor.constraint(equalToConstant: 36),
            ctrlCButton.heightAnchor.constraint(equalToConstant: 36),
            ctrlLButton.widthAnchor.constraint(equalToConstant: 36),
            ctrlLButton.heightAnchor.constraint(equalToConstant: 36),
            ctrlDButton.widthAnchor.constraint(equalToConstant: 36),
            ctrlDButton.heightAnchor.constraint(equalToConstant: 36),

            // Nipple is square and takes remaining space
            nippleView.widthAnchor.constraint(equalTo: nippleView.heightAnchor),
            nippleView.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func createButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.25, alpha: 1.0)
        button.layer.cornerRadius = 6
        button.accessibilityIdentifier = title
        button.isAccessibilityElement = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func updateCtrlButton() {
        if isCtrlActive {
            ctrlButton.backgroundColor = UIColor.systemBlue
        } else {
            ctrlButton.backgroundColor = UIColor(white: 0.25, alpha: 1.0)
        }
    }

    // MARK: - Key Actions

    private func sendEscape() {
        onKeyInput?(Data([0x1B]))
    }

    private func sendTab() {
        onKeyInput?(Data([0x09]))
    }

    private func toggleCtrl() {
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

    private func sendCtrlL() {
        onKeyInput?(Data([0x0C]))  // FF
    }

    private func sendCtrlD() {
        onKeyInput?(Data([0x04]))  // EOT
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: 48)
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
    private var currentDirection: Direction?
    private var currentMagnitude: CGFloat = 0

    /// Minimum threshold before any arrow is triggered (in points)
    private let activationThreshold: CGFloat = 20.0

    /// Maximum drag distance for fastest repeat (in points)
    private let maxDragDistance: CGFloat = 50.0

    /// Slowest repeat interval (at activation threshold)
    private let slowestRepeat: TimeInterval = 0.25

    /// Fastest repeat interval (at max drag)
    private let fastestRepeat: TimeInterval = 0.05

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        layer.cornerRadius = 8

        // Center nipple
        nipple.backgroundColor = UIColor(white: 0.5, alpha: 1.0)
        nipple.layer.cornerRadius = 10
        nipple.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nipple)

        NSLayoutConstraint.activate([
            nipple.centerXAnchor.constraint(equalTo: centerXAnchor),
            nipple.centerYAnchor.constraint(equalTo: centerYAnchor),
            nipple.widthAnchor.constraint(equalToConstant: 20),
            nipple.heightAnchor.constraint(equalToConstant: 20),
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

            // Only activate if past threshold
            guard magnitude > activationThreshold else {
                // Below threshold - just animate nipple, no arrow input
                let maxOffset: CGFloat = 8
                let offsetX = min(max(translation.x, -maxOffset), maxOffset)
                let offsetY = min(max(translation.y, -maxOffset), maxOffset)
                nipple.transform = CGAffineTransform(translationX: offsetX, y: offsetY)
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

            // If direction changed or first activation, send key and start repeat
            if currentDirection != newDirection {
                currentDirection = newDirection
                onArrowInput?(newDirection)
                startRepeat()
            }

            // Animate nipple offset (cap at max visual offset)
            let maxOffset: CGFloat = 10
            let offsetX = min(max(translation.x, -maxOffset), maxOffset)
            let offsetY = min(max(translation.y, -maxOffset), maxOffset)
            nipple.transform = CGAffineTransform(translationX: offsetX, y: offsetY)

        case .ended, .cancelled:
            stopRepeat()
            currentDirection = nil
            currentMagnitude = 0

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

    private func startRepeat() {
        stopRepeat()
        scheduleNextRepeat()
    }

    private func scheduleNextRepeat() {
        let interval = repeatInterval()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, let dir = self.currentDirection else { return }
            self.onArrowInput?(dir)
            self.scheduleNextRepeat()  // Schedule next with potentially new interval
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
