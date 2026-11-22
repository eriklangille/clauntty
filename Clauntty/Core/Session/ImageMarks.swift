import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias MarkFont = UIFont
#else
import AppKit
private typealias MarkFont = NSFont
#endif

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
        (text as NSString).size(withAttributes: [.font: MarkFont.systemFont(ofSize: fontSize(size), weight: .bold)])
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
    static func render(_ image: PlatformImage, marks: [Mark]) -> PlatformImage? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let view = Canvas { context, size in
            context.draw(Image(decorative: cgImage, scale: 1), in: CGRect(origin: .zero, size: size))
            draw(marks, in: context, size: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: rendered)
        #else
        return NSImage(cgImage: rendered, size: size)
        #endif
    }
}

/// What the user has put on the viewer's images to send: marks and a note each, by item.
/// Kept when the page turns or the viewer closes (reopening brings them back), until sent.
@MainActor
final class ImageDrafts: ObservableObject {
    static let shared = ImageDrafts()

    @Published var marks: [UUID: [Mark]] = [:]
    @Published var notes: [UUID: String] = [:]

    /// Marked up or noted: it goes with the next Send
    func touched(_ id: UUID) -> Bool {
        marks[id]?.isEmpty == false || !note(id).isEmpty
    }

    func note(_ id: UUID) -> String {
        notes[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func noteBinding(_ id: UUID) -> Binding<String> {
        Binding { self.notes[id] ?? "" } set: { self.notes[id] = $0 }
    }

    func forget(_ id: UUID) {
        marks[id] = nil
        notes[id] = nil
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
    var tool = Tool.pen { didSet { commitTyping() } }
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

