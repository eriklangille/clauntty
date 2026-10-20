import UIKit

extension PaneStatus {
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
