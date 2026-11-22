import AVFoundation
import SwiftUI
import UIKit

/// Markup on the phone: the image to draw on, the marks over it, and the text being typed.
/// One finger draws with the tool (or moves text it lands on); two fingers pinch and pan.
/// A tap with Text starts text there; a tap on text, with any tool, types into it again.
/// The marks are the Mac's (`Mark`, `MarkupState`), in fractions of the image, so they're
/// flattened the same way.
struct ImageMarkupView: View {
    let image: UIImage
    @Binding var state: MarkupState

    /// Where the image is drawn in this view, following zoom and pan
    @State private var imageRect: CGRect = .zero
    /// The mark being dragged out
    @State private var draft: Mark?
    /// A text mark being dragged: its id, and where it was
    @State private var moving: (id: UUID, from: CGPoint)?
    @FocusState private var typingFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkupCanvas(image: image, imageRect: $imageRect, typingAt: typingPoint, drag: dragged, tap: tapped)
            Canvas { context, _ in
                var context = context
                context.translateBy(x: imageRect.minX, y: imageRect.minY)
                Mark.draw(state.allMarks + (draft.map { [$0] } ?? []), in: context, size: imageRect.size)
                if let typing = state.typing { caret(typing, in: context, size: imageRect.size) }
            }
            .allowsHitTesting(false)
            // The keyboard's text goes here and is drawn on the image as it'll be flattened
            TextField("", text: typingText)
                .focused($typingFocused)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { state.commitTyping() }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Where the image is before the canvas says (it does a moment later), so its marks
        // are there from the first frame, not a frame after the image
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard imageRect == .zero else { return }
            imageRect = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: size))
        }
        .onChange(of: state.typing != nil) { _, typing in typingFocused = typing }
        // The keyboard put away: the text stays as a mark
        .onChange(of: typingFocused) { _, focused in if !focused { state.commitTyping() } }
    }

    private var typingText: Binding<String> {
        Binding { state.typing?.text ?? "" } set: { state.typing?.text = $0 }
    }

    /// Where text is being typed, in this view, for the canvas to keep above the keyboard
    private var typingPoint: CGPoint? {
        state.typing.map { CGPoint(x: imageRect.minX + $0.at.x * imageRect.width, y: imageRect.minY + $0.at.y * imageRect.height) }
    }

    /// After the text being typed, as tall as its letters
    private func caret(_ typing: MarkupState.Typing, in context: GraphicsContext, size: CGSize) {
        var context = context
        let font = Mark.fontSize(size)
        let x = typing.at.x * size.width + Mark.textSize(typing.text, size).width + 2
        let rect = CGRect(x: x, y: typing.at.y * size.height - font * 0.55, width: max(2, font * 0.08), height: font * 1.1)
        context.addFilter(.shadow(color: .black.opacity(0.45), radius: 2))
        context.fill(Path(roundedRect: rect, cornerRadius: rect.width / 2), with: .color(state.color))
    }

    private func fraction(_ point: CGPoint) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGPoint(x: min(max((point.x - imageRect.minX) / imageRect.width, 0), 1),
                       y: min(max((point.y - imageRect.minY) / imageRect.height, 0), 1))
    }

    /// The text mark under a point, the one on top
    private func textMark(at point: CGPoint) -> Mark? {
        let size = imageRect.size
        return state.marks.last { mark in
            guard case .text(let text, let at) = mark.kind else { return false }
            let box = Mark.textSize(text, size)
            return CGRect(x: imageRect.minX + at.x * size.width, y: imageRect.minY + at.y * size.height - box.height / 2,
                          width: box.width, height: box.height)
                .insetBy(dx: -12, dy: -12)
                .contains(point)
        }
    }

    private func dragged(_ phase: MarkupCanvas.Drag) {
        switch phase {
        case .began(let start):
            state.commitTyping()
            if let mark = textMark(at: start), case .text(_, let at) = mark.kind { moving = (mark.id, at) }
        case .changed(let start, let now):
            if let moving {
                guard let index = state.marks.firstIndex(where: { $0.id == moving.id }),
                      case .text(let text, _) = state.marks[index].kind else { return }
                let to = fraction(CGPoint(x: imageRect.minX + moving.from.x * imageRect.width + now.x - start.x,
                                          y: imageRect.minY + moving.from.y * imageRect.height + now.y - start.y))
                state.marks[index].kind = .text(text, to)
                return
            }
            let (a, b) = (fraction(start), fraction(now))
            switch state.tool {
            case .pen:
                if case .pen(var points) = draft?.kind {
                    points.append(b)
                    draft?.kind = .pen(points)
                } else {
                    draft = Mark(kind: .pen([a, b]), color: state.color)
                }
            case .ellipse: draft = Mark(kind: .ellipse(a, b), color: state.color)
            case .arrow: draft = Mark(kind: .arrow(a, b), color: state.color)
            case .text: break
            }
        case .ended:
            if moving == nil, let draft { state.marks.append(draft) }
            draft = nil
            moving = nil
        case .cancelled:
            // A second finger: it's a pinch, not a stroke
            draft = nil
            moving = nil
        }
    }

    private func tapped(_ point: CGPoint) {
        // A tap anywhere finishes the text being typed
        if state.typing != nil {
            state.commitTyping()
            return
        }
        if let mark = textMark(at: point), let index = state.marks.firstIndex(where: { $0.id == mark.id }),
           case .text(let text, let at) = mark.kind {
            state.marks.remove(at: index)
            state.color = mark.color
            state.typing = MarkupState.Typing(text: text, at: at, original: mark)
        } else if state.tool == .text, imageRect.contains(point) {
            state.typing = MarkupState.Typing(at: fraction(point))
        }
    }
}

/// The image in a scroll view that zooms and pans with two fingers, leaving one finger
/// to draw. Says where the image is drawn as that changes, and keeps the text being typed
/// above the keyboard.
struct MarkupCanvas: UIViewRepresentable {
    enum Drag {
        case began(CGPoint)
        case changed(start: CGPoint, now: CGPoint)
        case ended
        case cancelled
    }

    let image: UIImage
    @Binding var imageRect: CGRect
    var typingAt: CGPoint?
    let drag: (Drag) -> Void
    let tap: (CGPoint) -> Void

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(image: image)
        view.coordinator = context.coordinator
        context.coordinator.view = view
        let draw = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drew(_:)))
        draw.maximumNumberOfTouches = 1
        draw.delegate = context.coordinator
        view.scrollView.addGestureRecognizer(draw)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.scrollView.addGestureRecognizer(tap)
        view.scrollView.pinchGestureRecognizer?.addTarget(context.coordinator, action: #selector(Coordinator.pinched(_:)))
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        context.coordinator.parent = self
        if view.imageView.image !== image { view.imageView.image = image }
        view.typingAt = typingAt
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkupCanvas
        weak var view: CanvasView?
        private var start: CGPoint?

        init(parent: MarkupCanvas) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.imageView }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { report() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { report() }

        func report() {
            guard let view else { return }
            let rect = view.imageRect
            guard rect != parent.imageRect else { return }
            // Not while SwiftUI is updating (layout runs then too)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.imageRect != rect else { return }
                self.parent.imageRect = rect
            }
        }

        @objc func drew(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let now = gesture.location(in: view)
            switch gesture.state {
            case .began:
                // Where the finger went down, before the pan's slop
                let moved = gesture.translation(in: view)
                let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
                self.start = start
                parent.drag(.began(start))
                parent.drag(.changed(start: start, now: now))
            case .changed:
                guard let start else { return }
                parent.drag(.changed(start: start, now: now))
            case .ended:
                guard start != nil else { return }
                start = nil
                parent.drag(.ended)
            default:
                guard start != nil else { return }
                start = nil
                parent.drag(.cancelled)
            }
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            // Two fingers: drop the stroke the first one started
            guard gesture.state == .began, start != nil else { return }
            start = nil
            parent.drag(.cancelled)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            parent.tap(gesture.location(in: view))
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPinchGestureRecognizer
        }
    }

    final class CanvasView: UIView {
        let scrollView = UIScrollView()
        let imageView: UIImageView
        weak var coordinator: Coordinator?
        /// Where text is being typed: kept above the keyboard
        var typingAt: CGPoint? {
            didSet { if typingAt != nil, oldValue == nil { keepTypingVisible() } }
        }
        private var keyboardOverlap: CGFloat = 0

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init(frame: .zero)
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 6
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.backgroundColor = .clear
            // One finger draws
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
            scrollView.delaysContentTouches = false
            imageView.contentMode = .scaleAspectFit
            addSubview(scrollView)
            scrollView.addSubview(imageView)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                   name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                   name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard scrollView.frame.size != bounds.size else { return }
            scrollView.zoomScale = 1
            scrollView.frame = bounds
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            scrollView.contentSize = bounds.size
            coordinator?.report()
        }

        /// The picture's rect in this view: aspect-fit in the image view, as zoomed and panned
        var imageRect: CGRect {
            guard let image = imageView.image else { return .zero }
            let fitted = AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
            return imageView.convert(fitted, to: self)
        }

        @objc private func keyboardChanged(_ note: Notification) {
            guard let window else { return }
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let hiding = note.name == UIResponder.keyboardWillHideNotification
            let mine = convert(bounds, to: window)
            keyboardOverlap = hiding ? 0 : max(0, mine.maxY - frame.minY)
            // Room to scroll the image up above the keyboard
            scrollView.contentInset.bottom = keyboardOverlap
            keepTypingVisible()
        }

        private func keepTypingVisible() {
            guard let at = typingAt, keyboardOverlap > 0 else { return }
            let visibleBottom = bounds.height - keyboardOverlap - 60
            guard at.y > visibleBottom else { return }
            var offset = scrollView.contentOffset
            offset.y += at.y - visibleBottom
            scrollView.setContentOffset(offset, animated: true)
        }
    }
}

/// Markup's tools on the phone, the top row of the card under the image (the note and
/// Send are under them): the tools, the color (a dot that opens the six), undo and clear
struct ImageMarkupTools: View {
    @Binding var state: MarkupState
    @State private var choosingColor = false

    var body: some View {
        HStack(spacing: 2) {
            if choosingColor {
                ForEach(Array(MarkupState.colors.enumerated()), id: \.offset) { _, color in
                    Button {
                        state.color = color
                        withAnimation(.snappy(duration: 0.2)) { choosingColor = false }
                    } label: {
                        swatch(color, selected: state.color == color)
                    }
                }
                .transition(.opacity)
                Spacer(minLength: 0)
            } else {
                Group {
                    ForEach(MarkupState.Tool.allCases, id: \.self) { tool in
                        Button { state.tool = tool } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 17))
                                .frame(width: 40, height: 40)
                                .background(state.tool == tool ? Color.white.opacity(0.16) : .clear, in: Circle())
                        }
                        .accessibilityLabel(tool.label)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { choosingColor = true }
                    } label: {
                        swatch(state.color, selected: true)
                    }
                    .accessibilityLabel("Color")
                    .padding(.leading, 6)
                    Spacer(minLength: 0)
                    Button { state.undo() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 16)).frame(width: 40, height: 40)
                    }
                    .disabled(state.marks.isEmpty && state.typing == nil)
                    .accessibilityLabel("Undo")
                    Button {
                        state.marks.removeAll()
                        state.typing = nil
                    } label: {
                        Image(systemName: "trash").font(.system(size: 16)).frame(width: 40, height: 40)
                    }
                    .disabled(state.marks.isEmpty && state.typing == nil)
                    .accessibilityLabel("Clear")
                }
                .transition(.opacity)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func swatch(_ color: Color, selected: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3), lineWidth: selected ? 2 : 1))
            .frame(width: 40, height: 40)
    }
}
