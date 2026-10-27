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
        var shown = lo..<lo
        for index in lo..<lines.tops.count {
            if lines.tops[index] > rect.maxY { break }
            shown = shown.lowerBound..<(index + 1)
        }
        // The tints first, a run of touching lines with the same one as one rectangle: a
        // new file is a tint from top to bottom
        var run: (tint: CGColor, top: CGFloat, bottom: CGFloat)?
        func fill() {
            guard let run else { return }
            ctx.setFillColor(run.tint)
            ctx.fill(CGRect(x: 0, y: run.top, width: width, height: run.bottom - run.top))
        }
        for index in shown {
            let top = lines.tops[index]
            let tint: CGColor?
            switch (lines.part, lines.lines[index].kind) {
            case (.code, .added): tint = addTint
            case (.code, .removed): tint = delTint
            case (.numbers, .added): tint = addGutter
            case (.numbers, .removed): tint = delGutter
            default: tint = nil
            }
            if let tint, let current = run, current.tint === tint, current.bottom == top {
                run?.bottom = top + Self.rowHeight
            } else {
                fill()
                run = tint.map { ($0, top, top + Self.rowHeight) }
            }
        }
        fill()
        // The text's colour: a run's first glyphs drew in whatever fill was set last
        ctx.setFillColor(text)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in shown {
            let top = lines.tops[index]
            guard top + Self.rowHeight > rect.minY else { continue }
            let line = lines.lines[index]
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
            ctx.setFillColor(text)
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
        view.redraw()
    }
}

/// Drawn in tiles, as they come on screen, off the main thread, and kept: a plain view this
/// tall had AppKit redraw everything on screen on every frame of a scroll. The tiles are a
/// layer of their own, drawn by an object of their own: as the view's own layer, with the
/// view drawing, AppKit drew them on the main thread
final class LinesNSView: NSView {
    private let tiles = FastTiledLayer()
    private let painter = TilePainter()

    var lines: DrawnLines? {
        get { painter.lines }
        set { painter.lines = newValue }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tiles.tileSize = CGSize(width: 1024, height: 1024)
        tiles.levelsOfDetail = 1
        tiles.delegate = painter
        tiles.needsDisplayOnBoundsChange = true
        tiles.anchorPoint = .zero
        layer?.addSublayer(tiles)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tiles.frame = CGRect(origin: .zero, size: newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tiles.contentsScale = window?.backingScaleFactor ?? 2
        tiles.setNeedsDisplay()
    }

    func redraw() {
        tiles.setNeedsDisplay()
    }

    // Clicks and drags are the SwiftUI gestures' over it
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws a `LinesNSView`'s tiles, on Core Animation's threads
private final class TilePainter: NSObject, CALayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: DrawnLines?
    var lines: DrawnLines? {
        get { lock.lock(); defer { lock.unlock() }; return _lines }
        set { lock.lock(); _lines = newValue; lock.unlock() }
    }

    /// A tile: its clip is the tile's rect
    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let lines else { return }
        let rect = ctx.boundingBoxOfClipPath
        ctx.saveGState()
        // Not flipped: draw top-down, as the view is
        if !layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: layer.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let flipped = layer.contentsAreFlipped() ? rect : CGRect(x: rect.minX, y: layer.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        lines.style.draw(lines, in: flipped, width: layer.bounds.width, context: ctx)
        ctx.restoreGState()
    }

    /// No animation when it's resized or redrawn
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// Tiles appear at once rather than fading in
private final class FastTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// A hunk's code, `width` wide, scrolling sideways. Not in an NSScrollView: SwiftUI's
/// kept every swipe that started over code, so the page didn't scroll there, and AppKit's
/// laid itself out on every frame the page moved, which had the whole review laid out again
struct SidewaysCode: NSViewRepresentable {
    let lines: DrawnLines
    let width: CGFloat

    func makeNSView(context: Context) -> SidewaysView {
        let view = SidewaysView()
        view.code.lines = lines
        view.codeWidth = width
        return view
    }

    func updateNSView(_ view: SidewaysView, context: Context) {
        view.codeWidth = width
        guard view.code.lines != lines else { return }
        view.code.lines = lines
        view.code.redraw()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidewaysView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// The code moved sideways by the swipes that are mostly sideways (decided as a swipe
/// starts, so it doesn't change hands halfway); the rest go to the page
final class SidewaysView: NSView {
    let code = LinesNSView()
    var codeWidth: CGFloat = 0 { didSet { if codeWidth != oldValue { place() } } }
    private var offset: CGFloat = 0
    private var sideways = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(code)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad swipe's first move, or each notch of a mouse wheel
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        let room = codeWidth - bounds.width
        guard sideways, room > 0.5 else {
            superview?.enclosingScrollView?.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        offset = min(max(0, offset - delta), room)
        place()
    }

    private func place() {
        offset = min(offset, max(0, codeWidth - bounds.width))
        let frame = CGRect(x: -offset, y: 0, width: max(codeWidth, bounds.width), height: bounds.height)
        if code.frame != frame { code.frame = frame }
    }
}
#endif
