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
        context.coordinator.update(state: state, footer: footer)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        static let cell = "row"
        private let rows: PageRows
        private let place: PagePlace
        /// Each section's header row (none for Finish review's) and its other rows
        private var sections: [(header: Int?, items: [Int])] = []
        private var positions: [Int: IndexPath] = [:]
        private weak var view: UICollectionView?

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
            rows.set(changes)
            UIView.performWithoutAnimation {
                view.collectionViewLayout.invalidateLayout()
                view.layoutIfNeeded()
            }
            if shift != 0 { view.contentOffset.y += shift }
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
        /// above it clear of the file's header kept at the top
        @objc private func keyboardShown() {
            guard let view, let field = Self.firstResponder(in: view) else { return }
            let frame = field.convert(field.bounds, to: view)
            let above = rows.headerHeight + 3 * HunkView.rowHeight + 8
            view.scrollRectToVisible(CGRect(x: 0, y: frame.minY - above, width: 1, height: frame.height + above + 16), animated: true)
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
