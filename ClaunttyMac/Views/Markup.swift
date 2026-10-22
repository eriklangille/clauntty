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

    /// How much room text takes, drawn on an image this size
    static func textSize(_ text: String, _ size: CGSize) -> CGSize {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize(size), weight: .bold)])
    }

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

        /// Picks it while marking up and not typing
        var key: Character {
            switch self {
            case .pen: return "p"
            case .ellipse: return "c"
            case .arrow: return "a"
            case .text: return "t"
            }
        }
    }

    /// Picked with 1 to 6
    static let colors: [Color] = [.red, .yellow, .green, .blue, .white, .black]

    /// Text being typed: drawn by the layer, with a caret, and a mark once committed
    struct Typing {
        var text = ""
        /// The middle of its left edge, as a fraction of the image
        var at: CGPoint
        /// The text mark being changed, put back as it was on Esc
        var original: Mark?
    }

    /// The image being marked up
    let itemId: UUID
    var marks: [Mark] = []
    /// Another tool keeps text being typed
    var tool = Tool.ellipse { didSet { commitTyping() } }
    var color = Color.red
    var typing: Typing?

    /// The marks, and the text being typed
    var allMarks: [Mark] {
        guard let typing, !typing.text.isEmpty else { return marks }
        return marks + [Mark(kind: .text(typing.text, typing.at), color: color)]
    }

    mutating func commitTyping() {
        guard let typing else { return }
        self.typing = nil
        let text = typing.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { marks.append(Mark(kind: .text(text, typing.at), color: color)) }
    }

    mutating func cancelTyping() {
        if let original = typing?.original { marks.append(original) }
        typing = nil
    }

    mutating func undo() {
        if typing != nil { cancelTyping() } else { _ = marks.popLast() }
    }

    /// Backspace: the last character typed
    mutating func deleteBackward() {
        if typing?.text.isEmpty == false { typing?.text.removeLast() }
    }

    /// A key while marking up: a character for the text being typed, else a tool's or a
    /// color's key. False when it's none of those.
    mutating func type(_ press: KeyPress) -> Bool {
        if typing != nil {
            // Not arrows and other function keys (private use characters), nor Tab
            let printable = !press.characters.isEmpty && press.characters.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
            guard printable else { return false }
            typing?.text += press.characters
            return true
        }
        let key = press.characters.lowercased()
        if let tool = Tool.allCases.first(where: { String($0.key) == key }) {
            self.tool = tool
            return true
        }
        if let number = Int(key), (1...Self.colors.count).contains(number) {
            color = Self.colors[number - 1]
            return true
        }
        return false
    }
}

/// Over the image while marking up: draws what's dragged with the tool, moves text that's
/// dragged, and starts text where it's clicked (with Text, or a double-click with any tool).
/// Keys go to the viewer, which hands them to `MarkupState.type`, and the text is drawn here
/// as it'll be flattened, so typing doesn't move it.
struct MarkupLayer: View {
    @Binding var state: MarkupState
    /// The mark being dragged out
    @State private var draft: Mark?
    /// A text mark being dragged: its id, and where it was
    @State private var moving: (id: UUID, from: CGPoint)?
    /// The drag's first change has been seen
    @State private var began = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                Mark.draw(state.allMarks + (draft.map { [$0] } ?? []), in: context, size: size)
                if let typing = state.typing { caret(typing, in: context, size: size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                dragged(drag, size: size)
            }.onEnded { drag in
                ended(drag, size: size)
            })
        }
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

    private func fraction(_ location: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / size.width, 0), 1), y: min(max(location.y / size.height, 0), 1))
    }

    /// The text mark under a point, the one on top
    private func textMark(at location: CGPoint, size: CGSize) -> Mark? {
        state.marks.last { mark in
            guard case .text(let text, let at) = mark.kind else { return false }
            let box = Mark.textSize(text, size)
            return CGRect(x: at.x * size.width, y: at.y * size.height - box.height / 2, width: box.width, height: box.height)
                .insetBy(dx: -6, dy: -6)
                .contains(location)
        }
    }

    private func dragged(_ drag: DragGesture.Value, size: CGSize) {
        if !began {
            began = true
            // A click anywhere finishes the text being typed, which can then be dragged
            state.commitTyping()
            if let mark = textMark(at: drag.startLocation, size: size), case .text(_, let at) = mark.kind {
                moving = (mark.id, at)
            }
        }
        let start = fraction(drag.startLocation, size)
        let now = fraction(drag.location, size)
        if let moving {
            guard let index = state.marks.firstIndex(where: { $0.id == moving.id }),
                  case .text(let text, _) = state.marks[index].kind else { return }
            let to = fraction(CGPoint(x: moving.from.x * size.width + drag.translation.width,
                                      y: moving.from.y * size.height + drag.translation.height), size)
            state.marks[index].kind = .text(text, to)
            return
        }
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
        defer {
            draft = nil
            moving = nil
            began = false
        }
        let moved = hypot(drag.translation.width, drag.translation.height)
        if moved > 3 {
            if moving == nil, let draft { state.marks.append(draft) }
            return
        }
        // A click: text there, with the Text tool or a double-click with any. On a text
        // mark, that text is typed into again.
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        guard state.tool == .text || clicks >= 2 else { return }
        if let id = moving?.id, let index = state.marks.firstIndex(where: { $0.id == id }),
           case .text(let text, let at) = state.marks[index].kind {
            let mark = state.marks.remove(at: index)
            state.color = mark.color
            state.typing = MarkupState.Typing(text: text, at: at, original: mark)
        } else {
            state.typing = MarkupState.Typing(at: fraction(drag.location, size))
        }
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
                            // Its key, small in the corner
                            .overlay(alignment: .bottomTrailing) {
                                Text(String(tool.key).uppercased())
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.label) (\(String(tool.key).uppercased()))")
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 6) {
                ForEach(Array(MarkupState.colors.enumerated()), id: \.offset) { number, color in
                    Button { state.color = color } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white.opacity(state.color == color ? 0.95 : 0.25),
                                                           lineWidth: state.color == color ? 2 : 1))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .help("\(number + 1)")
                }
            }
            Divider().frame(height: 20)
            Button { state.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                // Here, so it works wherever the keyboard is in the viewer
                .keyboardShortcut("z", modifiers: .command)
                .disabled(state.marks.isEmpty && state.typing == nil)
                .help("Undo (⌘Z)")
            Button {
                state.marks.removeAll()
                state.typing = nil
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .disabled(state.marks.isEmpty && state.typing == nil)
                .help("Clear")
            Divider().frame(height: 20)
            Button("Cancel", action: cancel)
                .help("Esc")
            Button("Copy", action: copy)
                .disabled(state.allMarks.isEmpty)
            if let send {
                // Return is the viewer's: it finishes text being typed first
                Button("Send to Claude", action: send)
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
