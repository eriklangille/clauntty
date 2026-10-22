import AppKit
import SwiftUI

/// Marks drawn on an image in the viewer (Markup): pen strokes, circles, arrows and text.
/// Points are fractions of the image's size, so they land in the same place at any
/// zoom, and on the full-size image they're flattened onto.
struct Mark: Identifiable {
    enum Kind {
        case pen([CGPoint])
        /// The ellipse in the box between two corners
        case ellipse(CGPoint, CGPoint)
        /// From the tail to the head
        case arrow(CGPoint, CGPoint)
        case text(String, CGPoint)
    }

    let id = UUID()
    var kind: Kind
    var color: Color

    /// Strokes and text grow with the image, so marks read the same at any size
    static func lineWidth(_ size: CGSize) -> CGFloat { max(2, 0.006 * max(size.width, size.height)) }
    static func fontSize(_ size: CGSize) -> CGFloat { max(12, 0.032 * max(size.width, size.height)) }

    static func draw(_ marks: [Mark], in context: GraphicsContext, size: CGSize) {
        let width = lineWidth(size)
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        for mark in marks {
            var context = context
            // A soft dark edge, so a mark shows on light and dark pictures
            context.addFilter(.shadow(color: .black.opacity(0.45), radius: width * 0.8))
            switch mark.kind {
            case .pen(let points):
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: point(first))
                for p in points.dropFirst() { path.addLine(to: point(p)) }
                context.stroke(path, with: .color(mark.color), style: style)
            case .ellipse(let a, let b):
                let rect = CGRect(origin: point(a), size: .zero).union(CGRect(origin: point(b), size: .zero))
                context.stroke(Path(ellipseIn: rect), with: .color(mark.color), style: style)
            case .arrow(let tail, let head):
                let (t, h) = (point(tail), point(head))
                let angle = atan2(h.y - t.y, h.x - t.x)
                let length = width * 5
                var path = Path()
                path.move(to: t)
                path.addLine(to: h)
                for side in [-1.0, 1.0] {
                    let a = angle + .pi - side * .pi / 7
                    path.move(to: h)
                    path.addLine(to: CGPoint(x: h.x + cos(a) * length, y: h.y + sin(a) * length))
                }
                context.stroke(path, with: .color(mark.color), style: style)
            case .text(let text, let at):
                let resolved = context.resolve(Text(text)
                    .font(.system(size: fontSize(size), weight: .bold))
                    .foregroundColor(mark.color))
                context.draw(resolved, at: point(at), anchor: .leading)
            }
        }
    }

    /// The image with its marks, at its full pixel size, for pasting into a pane
    @MainActor
    static func render(_ image: NSImage, marks: [Mark]) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let view = Canvas { context, size in
            context.draw(Image(decorative: cgImage, scale: 1), in: CGRect(origin: .zero, size: size))
            draw(marks, in: context, size: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { return nil }
        return NSImage(cgImage: rendered, size: size)
    }
}

/// What Markup draws with
struct MarkupState {
    enum Tool: CaseIterable {
        case pen, ellipse, arrow, text

        var symbol: String {
            switch self {
            case .pen: return "scribble"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            }
        }

        var label: String {
            switch self {
            case .pen: return "Pen"
            case .ellipse: return "Circle"
            case .arrow: return "Arrow"
            case .text: return "Text"
            }
        }
    }

    static let colors: [Color] = [.red, .yellow, .green, .blue, .white, .black]

    /// The image being marked up
    let itemId: UUID
    var marks: [Mark] = []
    var tool = Tool.ellipse
    var color = Color.red
}

/// Over the image while marking it up: draws what's dragged with the tool, and takes
/// text where it's clicked
struct MarkupLayer: View {
    @Binding var state: MarkupState
    /// The mark being dragged out
    @State private var draft: Mark?
    /// Where text is being typed, as a fraction of the image
    @State private var textAt: CGPoint?
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                Mark.draw(state.marks + (draft.map { [$0] } ?? []), in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                dragged(drag, size: size)
            }.onEnded { drag in
                ended(drag, size: size)
            })
            .overlay(alignment: .topLeading) {
                if let textAt {
                    TextField("Text", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: Mark.fontSize(size), weight: .bold))
                        .foregroundStyle(state.color)
                        .frame(minWidth: 120)
                        .fixedSize()
                        .focused($typing)
                        .onSubmit { commitText() }
                        .onExitCommand { self.textAt = nil }
                        .offset(x: textAt.x * size.width, y: textAt.y * size.height - Mark.fontSize(size) * 0.6)
                        .onAppear { typing = true }
                }
            }
        }
        // Another tool, or another color: text being typed is kept first
        .onChange(of: state.tool) { _, _ in commitText() }
    }

    private func fraction(_ location: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / size.width, 0), 1), y: min(max(location.y / size.height, 0), 1))
    }

    private func dragged(_ drag: DragGesture.Value, size: CGSize) {
        let start = fraction(drag.startLocation, size)
        let now = fraction(drag.location, size)
        switch state.tool {
        case .pen:
            if case .pen(var points) = draft?.kind {
                points.append(now)
                draft?.kind = .pen(points)
            } else {
                draft = Mark(kind: .pen([start, now]), color: state.color)
            }
        case .ellipse:
            draft = Mark(kind: .ellipse(start, now), color: state.color)
        case .arrow:
            draft = Mark(kind: .arrow(start, now), color: state.color)
        case .text:
            break
        }
    }

    private func ended(_ drag: DragGesture.Value, size: CGSize) {
        defer { draft = nil }
        if state.tool == .text {
            commitText()
            textAt = fraction(drag.location, size)
            return
        }
        // A click, not a drag: nothing to draw
        let moved = hypot(drag.location.x - drag.startLocation.x, drag.location.y - drag.startLocation.y)
        if let draft, moved > 3 { state.marks.append(draft) }
    }

    private func commitText() {
        defer {
            textAt = nil
            text = ""
        }
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard let textAt, !typed.isEmpty else { return }
        state.marks.append(Mark(kind: .text(typed, textAt), color: state.color))
    }
}

/// Under the image while marking up: tools, colors, undo, and what to do with it
struct MarkupBar: View {
    @Binding var state: MarkupState
    /// Nil when there's no pane to send it to
    let send: (() -> Void)?
    let copy: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarkupState.Tool.allCases, id: \.self) { tool in
                    Button { state.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 30, height: 26)
                            .background(state.tool == tool ? Color.white.opacity(0.22) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(tool.label)
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 6) {
                ForEach(MarkupState.colors, id: \.self) { color in
                    Button { state.color = color } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white.opacity(state.color == color ? 0.95 : 0.25),
                                                           lineWidth: state.color == color ? 2 : 1))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().frame(height: 20)
            Button { _ = state.marks.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                // Here, so it works wherever the keyboard is in the viewer
                .keyboardShortcut("z", modifiers: .command)
                .disabled(state.marks.isEmpty)
                .help("Undo (⌘Z)")
            Button { state.marks.removeAll() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .disabled(state.marks.isEmpty)
                .help("Clear")
            Divider().frame(height: 20)
            Button("Cancel", action: cancel)
                .help("Esc")
            Button("Copy", action: copy)
                .disabled(state.marks.isEmpty)
            if let send {
                Button("Send to Claude", action: send)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .help("Pastes it into the pane (Return)")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}
