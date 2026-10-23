import UIKit

/// iOS-style teardrop selection handle for adjusting text selection bounds
class SelectionHandleView: UIView {

    enum HandleType {
        case start  // Top-left of selection (teardrop points down-right)
        case end    // Bottom-right of selection (teardrop points up-left)
    }

    // MARK: - Properties

    let handleType: HandleType

    /// Called when handle is dragged. Provides the new position in superview coordinates.
    var onDrag: ((CGPoint) -> Void)?

    /// Called when drag begins
    var onDragBegan: (() -> Void)?

    /// Called when drag ends
    var onDragEnded: (() -> Void)?

    /// The teardrop circle diameter
    private let circleDiameter: CGFloat = 12

    /// The line width extending from circle
    private let lineWidth: CGFloat = 1.5

    /// The line length extending from circle
    private let lineLength: CGFloat = 17

    /// Total view size to accommodate teardrop + touch target
    private let touchTargetSize: CGFloat = 64

    // MARK: - Initialization

    init(type: HandleType) {
        self.handleType = type
        super.init(frame: CGRect(x: 0, y: 0, width: touchTargetSize, height: touchTargetSize))
        setupView()
    }

    required init?(coder: NSCoder) {
        self.handleType = .end
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        // Add pan gesture for dragging
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panGesture)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let color = UIColor.systemBlue

        // Calculate positions based on handle type
        // Start handle: circle at top-left, line extends down-right
        // End handle: circle at bottom-right, line extends up-left
        let circleCenter: CGPoint
        let lineStart: CGPoint
        let lineEnd: CGPoint

        switch handleType {
        case .start:
            // Circle at TOP of view, line extends DOWN (points into text below)
            circleCenter = CGPoint(x: bounds.midX, y: circleDiameter / 2 + 4)
            lineStart = CGPoint(x: circleCenter.x, y: circleCenter.y + circleDiameter / 2)
            lineEnd = CGPoint(x: circleCenter.x, y: circleCenter.y + circleDiameter / 2 + lineLength)

        case .end:
            // Circle at BOTTOM of view, line extends UP (points into text above)
            circleCenter = CGPoint(x: bounds.midX, y: bounds.maxY - circleDiameter / 2 - 4)
            lineStart = CGPoint(x: circleCenter.x, y: circleCenter.y - circleDiameter / 2)
            lineEnd = CGPoint(x: circleCenter.x, y: circleCenter.y - circleDiameter / 2 - lineLength)
        }

        // Draw the line first (behind circle)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: lineStart)
        context.addLine(to: lineEnd)
        context.strokePath()

        // Draw the circle
        context.setFillColor(color.cgColor)
        let circleRect = CGRect(
            x: circleCenter.x - circleDiameter / 2,
            y: circleCenter.y - circleDiameter / 2,
            width: circleDiameter,
            height: circleDiameter
        )
        context.fillEllipse(in: circleRect)
    }

    // MARK: - Gesture Handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }

        switch gesture.state {
        case .began:
            Haptic.handleGrab.play()
            onDragBegan?()

        case .changed:
            let location = gesture.location(in: superview)
            onDrag?(location)

        case .ended, .cancelled:
            onDragEnded?()

        default:
            break
        }
    }

    // MARK: - Positioning

    /// The Y offset from view origin to the line tip
    private var lineTipOffsetY: CGFloat {
        switch handleType {
        case .start:
            // Circle at top, line extends down
            // Line tip Y = circleCenter.y + circleDiameter/2 + lineLength
            // circleCenter.y = circleDiameter/2 + 4
            return (circleDiameter / 2 + 4) + circleDiameter / 2 + lineLength
        case .end:
            // Circle at bottom, line extends up
            // Line tip Y = circleCenter.y - circleDiameter/2 - lineLength
            // circleCenter.y = bounds.maxY - circleDiameter/2 - 4 = touchTargetSize - circleDiameter/2 - 4
            return (touchTargetSize - circleDiameter / 2 - 4) - circleDiameter / 2 - lineLength
        }
    }

    /// Position the handle at the given point (in superview coordinates)
    /// The handle will be offset so the teardrop tip points to the given location
    func positionAt(_ point: CGPoint) {
        // Calculate center position so line tip aligns with point
        // view.frame.origin.y + lineTipOffsetY = point.y
        // view.center.y = view.frame.origin.y + bounds.height/2
        // Therefore: center.y = point.y - lineTipOffsetY + bounds.height/2
        var yPos = point.y - lineTipOffsetY + bounds.height / 2

        // End handle needs additional upward offset to align with text baseline
        if handleType == .end {
            yPos -= (circleDiameter / 2 + lineLength / 2)
        }

        center = CGPoint(x: point.x, y: yPos)
    }
}
