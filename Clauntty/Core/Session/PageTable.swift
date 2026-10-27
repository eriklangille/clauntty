#if os(macOS)
import SwiftUI
import AppKit

/// The review's page on the Mac: a table whose rows (each file's header, its note, each
/// hunk, the gap under it, Finish review) are SwiftUI, made as they come on screen and
/// reused as they leave. As one SwiftUI view in a scroll view, the whole page was laid out
/// on every frame of a scroll: SwiftUI's own scroll view tells its content where it's
/// scrolled to, and in AppKit's a hosting view lays itself out whenever it moves in the
/// window. Only the few rows on screen move now.
///
/// Row heights are known before a row is made, so a jump lands where it's aimed: a hunk is
/// its summary plus 19 points a line, and its comment rows are measured once
/// (`CommentHeights`) and guessed until then. A row measures itself when it's made and
/// corrects its height; one that changes above the top edge moves the page by as much, so
/// what's on screen stays put. File headers are the table's group rows, which it keeps at
/// the top while their file is under it.
struct PageTable: NSViewRepresentable {
    let state: PageState
    /// Finish review, the last row
    let footer: AnyView
    let place: PagePlace
    let files: [String]
    /// Hands over what scrolls the page to a place (`PageScroll.jumper`)
    let jumper: (@escaping (String, CGFloat) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, footer: footer, place: place, files: files)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = false
        view.contentView.drawsBackground = false
        let table = PageTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.allowsTypeSelect = false
        table.floatsGroupRows = true
        table.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        view.documentView = table
        context.coordinator.attach(view, table: table)
        let coordinator = context.coordinator
        jumper { [weak coordinator] key, fraction in coordinator?.jump(to: key, at: fraction) }
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(state: state, footer: footer)
    }

    enum Row: Equatable {
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

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var state: PageState
        private var footer: AnyView
        private let place: PagePlace
        private let files: [String]
        private var rows: [Row] = []
        private var heights: [CGFloat] = []
        /// What a hunk's height depends on, as of its height: when it changes off screen,
        /// the height is guessed again
        private var inputs: [String] = []
        /// A line's row, and a file's header's, for jumps
        private var lineRows: [Int: Int] = [:]
        private var headerRows: [String: Int] = [:]
        /// Heights measured, waiting to be given to the table: not while it lays out
        private var pendingHeights: [Int: CGFloat] = [:]
        private var applyQueued = false
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?
        private var headerHeight: CGFloat = 33
        private var closedHunk: CGFloat = 30

        private static let cell = NSUserInterfaceItemIdentifier("row")

        init(state: PageState, footer: AnyView, place: PagePlace, files: [String]) {
            self.state = state
            self.footer = footer
            self.place = place
            self.files = files
            super.init()
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
        }

        func attach(_ view: NSScrollView, table: NSTableView) {
            scrollView = view
            self.table = table
            measureFixed()
            heights = rows.map(estimate)
            inputs = rows.map(inputsOf)
            table.dataSource = self
            table.delegate = self
            table.reloadData()
            let clip = view.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: clip)
        }

        func update(state: PageState, footer: AnyView) {
            self.state = state
            self.footer = footer
            guard let table else { return }
            // A hunk off screen whose comments or opening changed: guessed again. One on
            // screen measures itself
            var guessed = IndexSet()
            for (row, kind) in rows.enumerated() {
                guard case .hunk = kind else { continue }
                let now = inputsOf(kind)
                guard now != inputs[row] else { continue }
                inputs[row] = now
                if table.view(atColumn: 0, row: row, makeIfNecessary: false) == nil {
                    let height = estimate(kind)
                    if height != heights[row] {
                        pendingHeights[row] = height
                        guessed.insert(row)
                    }
                }
            }
            if !guessed.isEmpty { applyMeasured() }
            table.enumerateAvailableRowViews { rowView, row in
                (rowView.view(atColumn: 0) as? RowHost)?.rootView = self.view(row)
            }
        }

        // MARK: Heights

        /// A file header's height and a closed hunk's: one line each, whatever the file
        private func measureFixed() {
            guard let file = state.review.files.first else { return }
            func height<V: View>(_ view: V) -> CGFloat {
                NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 900, height: 10_000)).height
            }
            headerHeight = height(FileHeader(file: file, colors: state.colors))
            if let hunk = state.review.files.first(where: { !$0.hunks.isEmpty })?.hunks.first,
               let owner = state.review.files.first(where: { !$0.hunks.isEmpty }) {
                closedHunk = height(state.hunk(owner, hunk, open: false))
            }
        }

        private func estimate(_ row: Row) -> CGFloat {
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

        private func inputsOf(_ row: Row) -> String {
            guard case .hunk(let f, let h) = row else { return "" }
            let file = state.review.files[f], hunk = file.hunks[h]
            let ids = Set(hunk.lines.map(\.id))
            let mine = state.comments.filter { comment in
                comment.path == file.path && hunk.lines.contains { $0.side == comment.side && $0.number == comment.line }
            }
            let editing = state.editing.map { $0.path == file.path && ids.contains($0.last.id) } == true
            return "\(state.isOpen(file, hunk)) \(editing) " + mine.map { "\($0.id)\($0.text.count)" }.joined(separator: ",")
        }

        /// A row's height as laid out, from the row itself
        private func didMeasure(_ row: Int, _ height: CGFloat) {
            guard row < heights.count, abs(heights[row] - height) > 0.5 else { return }
            pendingHeights[row] = height
            guard !applyQueued else { return }
            applyQueued = true
            DispatchQueue.main.async { [weak self] in self?.applyMeasured() }
        }

        private func applyMeasured() {
            applyQueued = false
            guard let table, let view = scrollView, !pendingHeights.isEmpty else { return }
            let changes = pendingHeights
            pendingHeights = [:]
            let clip = view.contentView
            let top = clip.bounds.minY
            // Rows wholly above the top edge: the page moves by what they grew, so what's
            // on screen doesn't
            var shift: CGFloat = 0
            for (row, height) in changes {
                if top > 0 && table.rect(ofRow: row).maxY <= top + 0.5 { shift += height - heights[row] }
                heights[row] = height
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(changes.keys))
            }
            if shift != 0 { scroll(to: top + shift) }
        }

        // MARK: Scrolling

        @objc private func scrolled() {
            guard let table, let clip = scrollView?.contentView, !rows.isEmpty else { return }
            let top = clip.bounds.minY
            let row = top > 0 ? table.row(at: NSPoint(x: 1, y: top + 1)) : -1
            let current = row >= 0 ? (rows[row].file.map { files[$0] } ?? files.last) : files.first
            place.set(current: current, footerShown: table.rect(ofRow: rows.count - 1).minY < clip.bounds.maxY)
        }

        private func scroll(to y: CGFloat) {
            guard let view = scrollView, let table else { return }
            let clip = view.contentView
            let bottom = max(0, table.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), bottom)))
            view.reflectScrolledClipView(clip)
        }

        /// A file's header (`key` its path), a commented line ("line:<id>") or Finish
        /// review (""), `fraction` of the way down the view
        func jump(to key: String, at fraction: CGFloat) {
            let row: Int?
            if key.isEmpty {
                row = rows.count - 1
            } else if key.hasPrefix("line:") {
                row = Int(key.dropFirst(5)).flatMap { lineRows[$0] }
            } else {
                row = headerRows[key]
            }
            guard let row else { return }
            go(row, key, fraction)
            guard key.hasPrefix("line:") else { return }
            // Again once the rows there are made and have measured themselves (comments
            // above the line in its hunk, an estimate until then)
            table?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.applyMeasured()
                self?.go(row, key, fraction)
            }
        }

        private func go(_ row: Int, _ key: String, _ fraction: CGFloat) {
            guard let table, let clip = scrollView?.contentView else { return }
            var offset: CGFloat = 0
            if key.hasPrefix("line:"), let id = Int(key.dropFirst(5)), case .hunk(let f, let h) = rows[row] {
                let file = state.review.files[f]
                offset = closedHunk + (state.hunk(file, file.hunks[h]).top(ofLine: id) ?? 0)
            }
            scroll(to: table.rect(ofRow: row).minY + offset - fraction * clip.bounds.height)
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            max(1, heights[row])
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = rows[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            PlainRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let host = tableView.makeView(withIdentifier: Self.cell, owner: nil) as? RowHost {
                host.rootView = view(row)
                return host
            }
            let host = RowHost(rootView: view(row))
            host.identifier = Self.cell
            // The row's size is the table's; the title bar's safe area means nothing here
            host.sizingOptions = []
            host.safeAreaRegions = []
            return host
        }

        private func view(_ row: Int) -> PageRowView {
            PageRowView(
                row: rows[row], index: row, state: state, footer: footer,
                measured: { [weak self] index, height in self?.didMeasure(index, height) }
            )
        }
    }
}

/// One row of the page, as tall as it is, reporting that height
struct PageRowView: View {
    let row: PageTable.Row
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

/// A row: laid out by the table, by frame. When it moves in the window AppKit asks it to
/// update its constraints, and that went up to the review's hosting view, which laid the
/// whole review out again on every frame of a scroll
final class RowHost: NSHostingView<PageRowView> {
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set { if !newValue { super.needsUpdateConstraints = false } }
    }
}

private final class PageTableView: NSTableView {
    /// A comment's field takes a click at once, as anywhere else: a table otherwise wants
    /// its row selected first
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

/// No selection, separators or group row backgrounds: the rows draw themselves
private final class PlainRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}
#endif
