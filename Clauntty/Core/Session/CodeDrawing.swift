import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A hunk's lines drawn rather than made of views: the code (which scrolls sideways) or the
/// line numbers beside it. A view per line made scrolling and jumps hitch as SwiftUI built
/// hundreds of them at a time; drawn, a line costs nothing until it's on screen, and then
/// only its text. Each line is drawn where `HunkLayout` puts it; the space left for comment
/// rows is left empty, for the comments laid over it.
struct LinesDrawing: View {
    let lines: DrawnLines

    var body: some View {
        LinesView(lines: lines)
    }
}

/// What a `LinesView` draws
struct DrawnLines: Equatable {
    enum Part: Equatable {
        case code
        /// The numbers, right-aligned in this width (less their padding)
        case numbers(width: CGFloat)
    }

    /// The hunk's
    let key: String
    let lines: [Review.Line]
    /// Each line's top, by index
    let tops: [CGFloat]
    let part: Part
    let style: CodeStyle

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.tops == b.tops && a.part == b.part && a.style === b.style && a.lines.count == b.lines.count
    }
}

/// Fonts and colours for drawn code, from the review's colours, made once per theme
final class CodeStyle: @unchecked Sendable {
    static let rowHeight: CGFloat = 19
    static let fontSize: CGFloat = 12.5

    let font: PlatformFont
    let italic: PlatformFont
    /// The text's colours as the platform's colour objects, under the platform's attribute
    /// names: macOS 15's Core Text sends `-set` to a foreground colour, and a CGColor under
    /// `kCTForegroundColorAttributeName` crashed it (newer macOS took either)
    let textColor: PlatformColor
    let text: CGColor
    let tokens: [TokenKind: PlatformColor]
    let addTint: CGColor
    let delTint: CGColor
    let addGutter: CGColor
    let delGutter: CGColor
    let plus: PlatformColor
    let minus: PlatformColor
    let faint: PlatformColor
    /// Where the text sits in a row
    let baseline: CGFloat

    init(_ colors: ReviewColors) {
        let font = PlatformFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        self.font = font
        italic = (CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitItalic, .traitItalic) as PlatformFont?) ?? font
        func cg(_ color: Color) -> CGColor { PlatformColor(color).cgColor }
        textColor = PlatformColor(colors.fg)
        text = textColor.cgColor
        tokens = colors.tokens.mapValues { PlatformColor($0) }
        addTint = cg(colors.add)
        delTint = cg(colors.del)
        addGutter = cg(colors.addGutter)
        delGutter = cg(colors.delGutter)
        plus = PlatformColor(colors.plus.opacity(0.85))
        minus = PlatformColor(colors.minus.opacity(0.85))
        faint = PlatformColor(colors.faint)
        let ascent = CTFontGetAscent(font as CTFont), descent = CTFontGetDescent(font as CTFont)
        baseline = ((Self.rowHeight - ascent - descent) / 2 + ascent).rounded()
    }

    @MainActor static func of(_ colors: ReviewColors) -> CodeStyle {
        if let known = cache.first(where: { $0.0 == colors }) { return known.1 }
        let style = CodeStyle(colors)
        cache.append((colors, style))
        return style
    }

    @MainActor private static var cache: [(ReviewColors, CodeStyle)] = []

    /// A line's code, coloured by its highlighting
    func codeLine(_ line: Review.Line) -> CTLine {
        let string = NSMutableAttributedString()
        func add(_ text: String, _ kind: TokenKind?) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: kind == .comment ? italic : font,
                .foregroundColor: kind.flatMap { tokens[$0] } ?? textColor,
            ]
            string.append(NSAttributedString(string: text, attributes: attributes))
        }
        if let runs = line.runs {
            for run in runs { add(run.text.replacingOccurrences(of: "\t", with: "    "), run.kind) }
        } else {
            add(line.text.replacingOccurrences(of: "\t", with: "    "), nil)
        }
        return CTLineCreateWithAttributedString(string)
    }

    func numberLine(_ line: Review.Line) -> CTLine? {
        guard let number = line.number else { return nil }
        let color = line.kind == .added ? plus : line.kind == .removed ? minus : faint
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: attributes))
    }

    /// Draw the lines that meet `rect`, in a context whose origin is the view's top left
    func draw(_ lines: DrawnLines, in rect: CGRect, width: CGFloat, context ctx: CGContext) {
        guard !lines.tops.isEmpty else { return }
        // The first line reaching into the rect
        var lo = 0, hi = lines.tops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines.tops[mid] <= rect.minY - Self.rowHeight { lo = mid } else { hi = mid - 1 }
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in lo..<lines.tops.count {
            let top = lines.tops[index]
            if top > rect.maxY { break }
            guard top + Self.rowHeight > rect.minY else { continue }
            let line = lines.lines[index]
            let tint: CGColor?
            switch (lines.part, line.kind) {
            case (.code, .added): tint = addTint
            case (.code, .removed): tint = delTint
            case (.numbers, .added): tint = addGutter
            case (.numbers, .removed): tint = delGutter
            default: tint = nil
            }
            if let tint {
                ctx.setFillColor(tint)
                ctx.fill(CGRect(x: 0, y: top, width: width, height: Self.rowHeight))
            }
            // Back to the text's colour: the line's first run drew in the tint just set
            ctx.setFillColor(text)
            switch lines.part {
            case .code:
                ctx.textPosition = CGPoint(x: 8, y: top + baseline)
                CTLineDraw(codeLine(line), ctx)
            case .numbers(let numbersWidth):
                guard let number = numberLine(line) else { continue }
                let lineWidth = CTLineGetTypographicBounds(number, nil, nil, nil)
                ctx.textPosition = CGPoint(x: numbersWidth - 6 - lineWidth, y: top + baseline)
                CTLineDraw(number, ctx)
            }
        }
    }
}

#if canImport(UIKit)
typealias PlatformFont = UIFont

private struct LinesView: UIViewRepresentable {
    let lines: DrawnLines

    func makeUIView(context: Context) -> TiledLinesView {
        let view = TiledLinesView()
        view.lines = lines
        return view
    }

    func updateUIView(_ view: TiledLinesView, context: Context) {
        guard view.lines != lines else { return }
        view.lines = lines
        view.setNeedsDisplay()
    }
}

/// Drawn in tiles, as they come on screen: a whole hunk at once would be a bitmap of
/// thousands of points
final class TiledLinesView: UIView {
    override class var layerClass: AnyClass { FastTiledLayer.self }

    private let lock = NSLock()
    private var _lines: DrawnLines?
    /// Read while tiles draw, on other threads
    var lines: DrawnLines? {
        get { lock.lock(); defer { lock.unlock() }; return _lines }
        set { lock.lock(); _lines = newValue; lock.unlock() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        // Taps are the SwiftUI gestures' over it
        isUserInteractionEnabled = false
        contentScaleFactor = UIScreen.main.scale
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 512 * contentScaleFactor, height: 512 * contentScaleFactor)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let lines, let ctx = UIGraphicsGetCurrentContext() else { return }
        lines.style.draw(lines, in: rect, width: bounds.width, context: ctx)
    }
}

/// Tiles appear at once rather than fading in
private final class FastTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}
#else
typealias PlatformFont = NSFont

private struct LinesView: NSViewRepresentable {
    let lines: DrawnLines

    func makeNSView(context: Context) -> LinesNSView {
        let view = LinesNSView()
        view.lines = lines
        return view
    }

    func updateNSView(_ view: LinesNSView, context: Context) {
        guard view.lines != lines else { return }
        view.lines = lines
        view.needsDisplay = true
    }
}

/// Draws only what it's asked to (what's on screen): AppKit tiles a big layer-backed view
final class LinesNSView: NSView {
    var lines: DrawnLines?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let lines, let ctx = NSGraphicsContext.current?.cgContext else { return }
        lines.style.draw(lines, in: dirtyRect, width: bounds.width, context: ctx)
    }

    // Clicks and drags are the SwiftUI gestures' over it
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
