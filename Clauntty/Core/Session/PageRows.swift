import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The list of the page's rows: a table on the Mac, a collection view on the phone
#if os(macOS)
typealias PageList = PageTable
#else
typealias PageList = PageCollection
#endif

/// A row of the review's page: each file's header, its note, each hunk, the gap under it,
/// and Finish review last
enum ReviewRow: Equatable {
    case header(Int)
    case intro(Int)
    case hunk(Int, Int)
    /// Under a file's last hunk
    case gap(Int)
    case footer

    var file: Int? {
        switch self {
        case .header(let f), .intro(let f), .hunk(let f, _), .gap(let f): return f
        case .footer: return nil
        }
    }
}

/// The page's rows and their heights, for the list that shows them, made as they come on
/// screen (`PageTable` on the Mac, `PageCollection` on the phone). As one SwiftUI view in
/// a scroll view, the whole page was laid out on every frame of a scroll.
///
/// Heights are known before a row is made, so a jump lands where it's aimed: a hunk is its
/// summary plus 19 points a line, and its comment rows are measured once (`CommentHeights`)
/// and guessed until then. A row measures itself when it's made and corrects its height;
/// the list moves the page by what a row above the top edge grew, so what's on screen stays
/// put (`apply`).
@MainActor
final class PageRows {
    private(set) var state: PageState
    private(set) var footer: AnyView
    let rows: [ReviewRow]
    private(set) var heights: [CGFloat] = []
    /// Each row's top on the page
    private(set) var tops: [CGFloat] = []
    /// What a hunk's height depends on, as of its height: when it changes off screen, the
    /// height is guessed again
    private var inputs: [String] = []
    /// A line's row, and a file's header's, for jumps
    private var lineRows: [Int: Int] = [:]
    private var headerRows: [String: Int] = [:]
    /// Heights measured, waiting to go to the list: not while it lays out
    private var pending: [Int: CGFloat] = [:]
    private var applyQueued = false
    private(set) var headerHeight: CGFloat = 33
    /// A hunk's summary row, and the room above it
    private(set) var closedHunk: CGFloat = 30

    /// The list's: give it these heights (by row; `heights` still has the old ones, to move
    /// the page by what rows above the top edge grew), then `set` them
    var apply: (([Int: CGFloat]) -> Void)?

    init(state: PageState, footer: AnyView) {
        self.state = state
        self.footer = footer
        var rows: [ReviewRow] = []
        for (f, file) in state.review.files.enumerated() {
            headerRows[file.path] = rows.count
            rows.append(.header(f))
            if file.hasIntro { rows.append(.intro(f)) }
            for (h, hunk) in file.hunks.enumerated() {
                for line in hunk.lines { lineRows[line.id] = rows.count }
                rows.append(.hunk(f, h))
            }
            rows.append(.gap(f))
        }
        rows.append(.footer)
        self.rows = rows
        measureFixed()
        heights = rows.map(estimate)
        inputs = rows.map(inputsOf)
        sumTops()
    }

    /// The review's state changed: a hunk off screen (`shown` says) whose comments or
    /// opening changed is guessed again; one on screen measures itself
    func update(state: PageState, footer: AnyView, shown: (Int) -> Bool) {
        self.state = state
        self.footer = footer
        for (row, kind) in rows.enumerated() {
            guard case .hunk = kind else { continue }
            let now = inputsOf(kind)
            guard now != inputs[row] else { continue }
            inputs[row] = now
            if !shown(row) {
                let height = estimate(kind)
                if height != heights[row] { pending[row] = height }
            }
        }
        flush()
    }

    func set(_ changes: [Int: CGFloat]) {
        for (row, height) in changes { heights[row] = height }
        sumTops()
    }

    private func sumTops() {
        var y: CGFloat = 0
        tops = heights.map { height in
            defer { y += height }
            return y
        }
    }

    /// A row's height as laid out, from the row itself
    func measured(_ row: Int, _ height: CGFloat) {
        guard row < heights.count, abs(heights[row] - height) > 0.5 else { return }
        pending[row] = height
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    /// Hands what's been measured to the list
    func flush() {
        applyQueued = false
        guard !pending.isEmpty else { return }
        let changes = pending
        pending = [:]
        if let apply { apply(changes) } else { set(changes) }
    }

    // MARK: Guessing

    /// A file header's height and a closed hunk's: one line each, whatever the file
    private func measureFixed() {
        func height<V: View>(_ view: V) -> CGFloat {
            #if canImport(UIKit)
            UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 900, height: 10_000)).height
            #else
            NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 900, height: 10_000)).height
            #endif
        }
        guard let file = state.review.files.first else { return }
        headerHeight = height(FileHeader(file: file, colors: state.colors))
        if let owner = state.review.files.first(where: { !$0.hunks.isEmpty }), let hunk = owner.hunks.first {
            closedHunk = height(state.hunk(owner, hunk, open: false))
        }
    }

    private func estimate(_ row: ReviewRow) -> CGFloat {
        switch row {
        case .header: return headerHeight
        case .intro: return 44
        case .gap: return PageState.fileGap
        case .footer: return 240
        case .hunk(let f, let h):
            let file = state.review.files[f], hunk = file.hunks[h]
            guard state.isOpen(file, hunk) else { return closedHunk }
            let known = state.measures[PageState.key(file, hunk)]
            let comments = known.isEmpty ? CGFloat(commentCount(file, hunk)) * 44 : known.values.reduce(0, +)
            return closedHunk + CGFloat(hunk.lines.count) * HunkView.rowHeight + comments
        }
    }

    private func commentCount(_ file: Review.File, _ hunk: Review.Hunk) -> Int {
        hunk.lines.reduce(0) { count, line in
            count + file.comments.filter { $0.side == line.side && $0.line == line.number }.count
                + state.comments.filter { $0.path == file.path && $0.side == line.side && $0.line == line.number }.count
                + (state.editing.map { $0.path == file.path && $0.last.id == line.id } == true ? 1 : 0)
        }
    }

    private func inputsOf(_ row: ReviewRow) -> String {
        guard case .hunk(let f, let h) = row else { return "" }
        let file = state.review.files[f], hunk = file.hunks[h]
        let ids = Set(hunk.lines.map(\.id))
        let mine = state.comments.filter { comment in
            comment.path == file.path && hunk.lines.contains { $0.side == comment.side && $0.number == comment.line }
        }
        let editing = state.editing.map { $0.path == file.path && ids.contains($0.last.id) } == true
        return "\(state.isOpen(file, hunk)) \(editing) " + mine.map { "\($0.id)\($0.text.count)" }.joined(separator: ",")
    }

    // MARK: Places

    /// The row at a height on the page
    func row(at y: CGFloat) -> Int? {
        guard !tops.isEmpty, y >= 0 else { return nil }
        var lo = 0, hi = tops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The file at the top of the page scrolled to `y` (lit in the file list), and whether
    /// Finish review is above `bottom`
    func place(top y: CGFloat, bottom: CGFloat) -> (current: String?, footerShown: Bool) {
        let paths = state.review.files.map(\.path)
        let row = y > 0 ? row(at: y + 1) : nil
        let current = row.map { rows[$0].file.map { paths[$0] } ?? paths.last } ?? paths.first
        return (current, (tops.last ?? 0) < bottom)
    }

    /// Where a jump goes: a file's header (`key` its path), a commented line ("line:<id>")
    /// or Finish review (""), as the row and how far into it
    func target(_ key: String) -> (row: Int, offset: CGFloat)? {
        if key.isEmpty { return (rows.count - 1, 0) }
        guard key.hasPrefix("line:") else { return headerRows[key].map { ($0, 0) } }
        guard let id = Int(key.dropFirst(5)), let row = lineRows[id], case .hunk(let f, let h) = rows[row] else { return nil }
        let file = state.review.files[f]
        return (row, closedHunk + (state.hunk(file, file.hunks[h]).top(ofLine: id) ?? 0))
    }

    func view(_ row: Int) -> PageRowView {
        PageRowView(row: rows[row], index: row, state: state, footer: footer) { [weak self] index, height in
            self?.measured(index, height)
        }
    }
}

/// One row of the page, as tall as it is, reporting that height
struct PageRowView: View {
    let row: ReviewRow
    let index: Int
    let state: PageState
    let footer: AnyView
    let measured: (Int, CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            // Not a GeometryReader: SwiftUI runs those again whenever the row moves
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured(index, $0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A hosting view of its own, which the window's environment doesn't reach
            .foregroundStyle(state.colors.fg)
            .environment(\.colorScheme, state.colors.isLight ? .light : .dark)
            .tint(state.colors.fg)
            // A row made for another one starts afresh (a hunk's measured comments, hover)
            .id(id)
    }

    @ViewBuilder
    private var content: some View {
        let files = state.review.files
        switch row {
        case .header(let f): FileHeader(file: files[f], colors: state.colors)
        case .intro(let f):
            VStack(alignment: .leading, spacing: 0) { FileIntro(file: files[f], colors: state.colors) }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .hunk(let f, let h): state.hunk(files[f], files[f].hunks[h]).equatable()
        case .gap: Color.clear.frame(height: PageState.fileGap)
        case .footer: footer
        }
    }

    private var id: String {
        switch row {
        case .header(let f): return "h\(f)"
        case .intro(let f): return "i\(f)"
        case .hunk(let f, let h): return "k\(f).\(h)"
        case .gap(let f): return "g\(f)"
        case .footer: return "footer"
        }
    }
}
