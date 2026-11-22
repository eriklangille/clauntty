import AppKit
import SwiftUI

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

/// The viewer's top bar while marking up: tools, colors, undo, Copy and Done. Send is
/// in the bar under the image.
struct MarkupBar: View {
    @Binding var state: MarkupState
    let copy: () -> Void
    /// Leaves Markup; the marks stay on the image
    let done: () -> Void

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
            Button("Copy", action: copy)
                .disabled(state.allMarks.isEmpty)
            Button("Done", action: done)
                .help("Keeps the marks (M or Esc)")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}
