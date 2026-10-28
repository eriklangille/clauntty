#if os(iOS)
import SwiftUI
import UIKit

/// The review's page on the phone: a collection view whose rows (`PageRows`) are SwiftUI,
/// made as they come on screen and reused as they leave. In SwiftUI's scroll view the whole
/// page was laid out on every frame of a scroll, with hitches of a third of a second. A
/// section per file, its header the file's, which the layout keeps at the top while the file
/// is under it; Finish review is a section of its own.
struct PageCollection: UIViewRepresentable {
    let state: PageState
    /// Finish review, the last row
    let footer: AnyView
    let place: PagePlace
    /// Hands over what scrolls the page to a place (`PageScroll.jumper`)
    let jumper: (@escaping (String, CGFloat) -> Void) -> Void
    /// A swipe in from the left edge shows the file list (none when it's beside the page)
    let openFiles: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: PageRows(state: state, footer: footer), place: place)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionHeadersPinToVisibleBounds = true
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        // Down under the home indicator, inset for it (the review's view lets it reach there);
        // SwiftUI keeps it clear of the keyboard
        view.contentInsetAdjustmentBehavior = .always
        // Heights are the rows' (`PageRows`), not the cells' own
        view.selfSizingInvalidation = .disabled
        view.register(RowCell.self, forCellWithReuseIdentifier: Coordinator.cell)
        view.register(RowCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: Coordinator.cell)
        context.coordinator.attach(view)
        let coordinator = context.coordinator
        jumper { [weak coordinator] key, fraction in coordinator?.jump(to: key, at: fraction) }
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.openFiles = openFiles
        context.coordinator.update(state: state, footer: footer)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        static let cell = "row"
        private let rows: PageRows
        private let place: PagePlace
        /// Each section's header row (none for Finish review's) and its other rows
        private var sections: [(header: Int?, items: [Int])] = []
        private var positions: [Int: IndexPath] = [:]
        private weak var view: UICollectionView?
        var openFiles: (() -> Void)?
        private weak var tapAway: UITapGestureRecognizer?
        private weak var hold: UILongPressGestureRecognizer?
        private weak var edge: UIScreenEdgePanGestureRecognizer?
        /// The hunk a hold on its numbers is picking lines in, and its row
        private var held: (file: Review.File, hunk: Review.Hunk, row: Int)?

        init(rows: PageRows, place: PagePlace) {
            self.rows = rows
            self.place = place
            super.init()
            for (row, kind) in rows.rows.enumerated() {
                if case .header = kind {
                    sections.append((row, []))
                    continue
                }
                if kind == .footer { sections.append((nil, [])) }
                let section = sections.count - 1
                positions[row] = IndexPath(item: sections[section].items.count, section: section)
                sections[section].items.append(row)
            }
            rows.apply = { [weak self] changes in self?.apply(changes) }
        }

        func attach(_ view: UICollectionView) {
            self.view = view
            view.dataSource = self
            view.delegate = self
            if let monitor = FrameMonitor.shared {
                monitor.scrollTo = { [weak view] y in view?.contentOffset.y = y }
                monitor.pageHeight = { [weak view] in
                    guard let view else { return 0 }
                    return max(0, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
                }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown), name: UIResponder.keyboardDidShowNotification, object: nil)
            // Beside the rows' own taps, not instead of them
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedAway))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            tapAway = tap
            // Here, not in SwiftUI: once it's held, the page doesn't scroll under the finger
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(holding))
            hold.minimumPressDuration = 0.3
            hold.delegate = self
            view.addGestureRecognizer(hold)
            self.hold = hold
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipedIn))
            edge.edges = .left
            edge.delegate = self
            view.addGestureRecognizer(edge)
            view.panGestureRecognizer.require(toFail: edge)
            self.edge = edge
        }

        func update(state: PageState, footer: AnyView) {
            guard let view else { return }
            rows.update(state: state, footer: footer) { [weak self] row in self?.shown(row) ?? false }
            // What's on screen, given the new state; a row keeps its SwiftUI state
            for path in view.indexPathsForVisibleItems {
                (view.cellForItem(at: path) as? RowCell)?.show(rows.view(sections[path.section].items[path.item]))
            }
            for path in view.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
                guard let header = sections[path.section].header else { continue }
                (view.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path) as? RowCell)?
                    .show(rows.view(header))
            }
        }

        private func shown(_ row: Int) -> Bool {
            guard let view else { return false }
            if let path = positions[row] { return view.cellForItem(at: path) != nil }
            guard let section = sections.firstIndex(where: { $0.header == row }) else { return false }
            return view.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader,
                                          at: IndexPath(item: 0, section: section)) != nil
        }

        private func apply(_ changes: [Int: CGFloat]) {
            guard let view else { rows.set(changes); return }
            let top = view.contentOffset.y + view.adjustedContentInset.top
            // Rows wholly above the top edge: the page moves by what they grew, so what's
            // on screen doesn't
            var shift: CGFloat = 0
            for (row, height) in changes where top > 0 && rows.tops[row] + rows.heights[row] <= top + 0.5 {
                shift += height - rows.heights[row]
            }
            // Finish review growing with the note typed in it, at the bottom of the page:
            // the page stays at the bottom, so Send stays above the keyboard
            let pinned = changes[rows.rows.count - 1] != nil && view.contentOffset.y >= bottomOffset - 1
            rows.set(changes)
            UIView.performWithoutAnimation {
                view.collectionViewLayout.invalidateLayout()
                view.layoutIfNeeded()
            }
            if pinned {
                view.contentOffset.y = max(view.contentOffset.y, bottomOffset)
            } else if shift != 0 {
                view.contentOffset.y += shift
            }
        }

        /// The offset that shows the end of the page
        private var bottomOffset: CGFloat {
            guard let view else { return 0 }
            return max(-view.adjustedContentInset.top, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
        }

        // MARK: Scrolling

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let place = rows.place(top: top, bottom: top + scrollView.bounds.height)
            self.place.set(current: place.current, footerShown: place.footerShown)
        }

        private func scroll(to y: CGFloat) {
            guard let view else { return }
            let insets = view.adjustedContentInset
            let bottom = max(0, view.contentSize.height + insets.bottom - view.bounds.height)
            view.setContentOffset(CGPoint(x: 0, y: min(max(0, y), bottom) - insets.top), animated: false)
        }

        /// A place (`PageRows.target`), `fraction` of the way down the view
        func jump(to key: String, at fraction: CGFloat) {
            go(key, fraction)
            guard key.hasPrefix("line:") else { return }
            // Again once the rows there are made and have measured themselves (comments
            // above the line in its hunk, an estimate until then)
            view?.layoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.rows.flush()
                self?.go(key, fraction)
            }
        }

        private func go(_ key: String, _ fraction: CGFloat) {
            guard let view, let target = rows.target(key) else { return }
            scroll(to: rows.tops[target.row] + target.offset - fraction * view.bounds.height)
        }

        /// A comment's field, scrolled into what the keyboard leaves, with the line it's on
        /// above it clear of the file's header kept at the top. The note's is in Finish
        /// review, with Send under it: the page goes to its end.
        @objc private func keyboardShown() {
            guard let view, let field = Self.firstResponder(in: view) else { return }
            let frame = field.convert(field.bounds, to: view)
            if let path = view.indexPathForItem(at: CGPoint(x: frame.midX, y: frame.midY)),
               sections[path.section].items[path.item] == rows.rows.count - 1 {
                view.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: true)
                return
            }
            let above = rows.headerHeight + 3 * HunkView.rowHeight + 8
            view.scrollRectToVisible(CGRect(x: 0, y: frame.minY - above, width: 1, height: frame.height + above + 16), animated: true)
        }

        /// A tap away from the text box being typed in (and the buttons under it: Save,
        /// Send, the mic) puts the keyboard away
        @objc private func tappedAway(_ tap: UITapGestureRecognizer) {
            guard let view, let field = Self.firstResponder(in: view) else { return }
            let frame = field.convert(field.bounds, to: view)
            let keep = CGRect(x: 0, y: frame.minY - 8, width: view.bounds.width, height: frame.height + 64)
            if !keep.contains(tap.location(in: view)) { view.endEditing(true) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === tapAway
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === hold, let view {
                return lineUnder(gestureRecognizer.location(in: view)) != nil
            }
            if gestureRecognizer === edge { return openFiles != nil }
            return true
        }

        // MARK: Picking lines

        /// The line under a point on the page: in an open hunk, not on a comment, not under
        /// the file's header kept at the top
        private func lineUnder(_ point: CGPoint) -> (file: Review.File, hunk: Review.Hunk, row: Int, index: Int)? {
            guard let view, point.y - view.contentOffset.y - view.adjustedContentInset.top > rows.headerHeight,
                  let row = rows.row(at: point.y), case .hunk(let f, let h) = rows.rows[row] else { return nil }
            let state = rows.state, file = state.review.files[f], hunk = file.hunks[h]
            guard state.isOpen(file, hunk),
                  let index = state.hunk(file, hunk).line(atY: point.y - rows.tops[row] - rows.closedHunk, exactly: true)
            else { return nil }
            return (file, hunk, row, index)
        }

        /// Hold a line (its number or its code), then drag over more: the comment's editor
        /// opens on them
        @objc private func holding(_ hold: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = hold.location(in: view)
            let pick = rows.state.actions.pick
            switch hold.state {
            case .began:
                guard let line = lineUnder(point) else { return }
                held = (line.file, line.hunk, line.row)
                Haptic.selectStart.play()
                pick(.began(line.index), line.file.path, line.hunk, PageState.key(line.file, line.hunk))
            case .changed:
                guard let held else { return }
                // Past the hunk's ends, its first or last line
                let y = point.y - rows.tops[held.row] - rows.closedHunk
                let index = y < 0 ? 0 : rows.state.hunk(held.file, held.hunk).line(atY: y, exactly: false) ?? 0
                pick(.moved(min(index, held.hunk.lines.count - 1)), held.file.path, held.hunk, PageState.key(held.file, held.hunk))
            default:
                guard let held else { return }
                self.held = nil
                pick(.ended, held.file.path, held.hunk, PageState.key(held.file, held.hunk))
            }
        }

        @objc private func swipedIn(_ edge: UIScreenEdgePanGestureRecognizer) {
            guard edge.state == .began else { return }
            openFiles?()
        }

        private static func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for subview in view.subviews {
                if let found = firstResponder(in: subview) { return found }
            }
            return nil
        }

        // MARK: Collection

        func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cell, for: indexPath) as! RowCell
            cell.show(rows.view(sections[indexPath.section].items[indexPath.item]))
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: Self.cell,
                                                                         for: indexPath) as! RowCell
            if let row = sections[indexPath.section].header { header.show(rows.view(row)) }
            return header
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            CGSize(width: collectionView.bounds.width, height: max(1, rows.heights[sections[indexPath.section].items[indexPath.item]]))
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            referenceSizeForHeaderInSection section: Int) -> CGSize {
            guard let header = sections[section].header else { return .zero }
            return CGSize(width: collectionView.bounds.width, height: rows.heights[header])
        }
    }
}

/// A row, or a file's header: its SwiftUI view, sized by the layout
private final class RowCell: UICollectionViewCell {
    func show(_ row: PageRowView) {
        contentConfiguration = UIHostingConfiguration { row }.margins(.all, 0)
    }
}
#endif
