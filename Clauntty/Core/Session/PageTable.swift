#if os(macOS)
import SwiftUI
import AppKit

/// The review's page on the Mac: a table whose rows (`PageRows`) are SwiftUI, made as they
/// come on screen and reused as they leave. In a scroll view, AppKit has a hosting view lay
/// itself out whenever it moves in the window, so only the few rows on screen may move.
/// File headers are the table's group rows, which it keeps at the top while their file is
/// under it.
struct PageTable: NSViewRepresentable {
    let state: PageState
    /// Finish review, the last row
    let footer: AnyView
    let place: PagePlace
    /// Hands over what scrolls the page to a place (`PageScroll.jumper`)
    let jumper: (@escaping (String, CGFloat) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: PageRows(state: state, footer: footer), place: place)
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

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let rows: PageRows
        private let place: PagePlace
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?

        private static let cell = NSUserInterfaceItemIdentifier("row")

        init(rows: PageRows, place: PagePlace) {
            self.rows = rows
            self.place = place
            super.init()
            rows.apply = { [weak self] changes in self?.apply(changes) }
        }

        func attach(_ view: NSScrollView, table: NSTableView) {
            scrollView = view
            self.table = table
            table.dataSource = self
            table.delegate = self
            table.reloadData()
            let clip = view.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: clip)
        }

        func update(state: PageState, footer: AnyView) {
            guard let table else { return }
            rows.update(state: state, footer: footer) { row in
                table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
            }
            table.enumerateAvailableRowViews { rowView, row in
                (rowView.view(atColumn: 0) as? RowHost)?.rootView = self.rows.view(row)
            }
        }

        private func apply(_ changes: [Int: CGFloat]) {
            guard let table, let view = scrollView else { rows.set(changes); return }
            let top = view.contentView.bounds.minY
            // Rows wholly above the top edge: the page moves by what they grew, so what's
            // on screen doesn't
            var shift: CGFloat = 0
            for (row, height) in changes where top > 0 && table.rect(ofRow: row).maxY <= top + 0.5 {
                shift += height - rows.heights[row]
            }
            rows.set(changes)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(changes.keys))
            }
            if shift != 0 { scroll(to: top + shift) }
        }

        // MARK: Scrolling

        @objc private func scrolled() {
            guard let clip = scrollView?.contentView else { return }
            let place = rows.place(top: clip.bounds.minY, bottom: clip.bounds.maxY)
            self.place.set(current: place.current, footerShown: place.footerShown)
        }

        private func scroll(to y: CGFloat) {
            guard let view = scrollView, let table else { return }
            let clip = view.contentView
            let bottom = max(0, table.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), bottom)))
            view.reflectScrolledClipView(clip)
        }

        /// A place (`PageRows.target`), `fraction` of the way down the view
        func jump(to key: String, at fraction: CGFloat) {
            go(key, fraction)
            guard key.hasPrefix("line:") else { return }
            // Again once the rows there are made and have measured themselves (comments
            // above the line in its hunk, an estimate until then)
            table?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.rows.flush()
                self?.go(key, fraction)
            }
        }

        private func go(_ key: String, _ fraction: CGFloat) {
            guard let table, let clip = scrollView?.contentView, let target = rows.target(key) else { return }
            scroll(to: table.rect(ofRow: target.row).minY + target.offset - fraction * clip.bounds.height)
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { rows.rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            max(1, rows.heights[row])
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = rows.rows[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            PlainRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let host = tableView.makeView(withIdentifier: Self.cell, owner: nil) as? RowHost {
                host.rootView = rows.view(row)
                return host
            }
            let host = RowHost(rootView: rows.view(row))
            host.identifier = Self.cell
            // The row's size is the table's; the title bar's safe area means nothing here
            host.sizingOptions = []
            host.safeAreaRegions = []
            return host
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
