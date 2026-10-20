import SwiftUI

/// The window's own state: the switcher (Cmd+K) and a zoomed pane.
@MainActor
final class WindowState: ObservableObject {
    @Published var switcherShown = false
    /// A pane shown alone in its split (Cmd+Shift+Return); the host's layout is unchanged
    @Published var zoomedPane: String?
    /// The sidebar, shown or not; change it with `toggleSidebar()`
    @Published var sidebar: NavigationSplitViewVisibility = .all

    /// Terminals keep their size while the sidebar slides and resize once at the end:
    /// a TUI redraws badly at every step in between
    func toggleSidebar() {
        PaneHostView.holdResizes()
        withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
    }
}

/// Cmd+K: type part of a pane, workspace or host name, Enter goes there. Arrows
/// move, Esc closes.
struct PaneSwitcher: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool

    private struct Item: Identifiable {
        let id: PaneSelection
        let title: String
        /// Workspace, and host when there's more than one
        let place: String
        let status: PaneStatus
        let isShown: Bool
    }

    /// Every pane in sidebar order, those matching every word of the query
    private var items: [Item] {
        let words = query.lowercased().split(separator: " ")
        let shownPane = sessionManager.activeSession?.pane?.paneId
        return PaneCommands.groups(sessionManager, hosts).flatMap { group -> [Item] in
            let host = hosts.opened.count > 1 ? hosts.opened.first { $0.id == group.connectionId }?.name : nil
            let place = [group.panes.count > 1 ? group.title : nil, host].compactMap { $0 }.joined(separator: " · ")
            return group.panes.map { pane in
                Item(id: PaneSelection(groupId: group.id, paneId: pane.id),
                     title: group.panes.count > 1 ? pane.title : group.title,
                     place: place, status: pane.status, isShown: pane.id == shownPane)
            }
        }
        .filter { item in
            let text = "\(item.title) \(item.place)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            TextField("Go to pane", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($fieldFocused)
                .onSubmit { choose(items) }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.escape) { window.switcherShown = false; return .handled }
            Divider()
            if items.isEmpty {
                Text("No panes match")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == selected)
                                    .onTapGesture {
                                        selected = index
                                        choose(items)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selected) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
            }
        }
        .frame(width: 520)
        .glass(in: .rect(cornerRadius: 14))
        // After the terminal has let go of the keyboard
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            StatusGlyph(status: item.status)
                .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.place.isEmpty {
                Text(item.place)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // The status is the glyph's
            if item.isShown {
                Text("Shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func move(_ offset: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        selected = (selected + offset + items.count) % items.count
    }

    private func choose(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        window.switcherShown = false
        MainView.show(items[selected].id, sessionManager)
    }
}
