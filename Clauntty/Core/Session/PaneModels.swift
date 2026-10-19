import Foundation

// Models for panes and tabs that Core (SessionManager) and the views of both apps use.

/// Agent state of one pane
enum PaneStatus: Equatable {
    /// No agent in the pane (a shell, a dev server)
    case none
    case idle
    case working
    case blocked
    case done
}

/// One pane inside a session tab
struct TabPane: Equatable {
    let id: String
    var title: String
    var status: PaneStatus
    /// Tab the pane belongs to within its group. Panes in the same tab are splits on the desktop.
    var group: Int
}

/// Session menu actions on a workspace tab
enum PaneAction {
    /// A new pane next to the one shown (a split on the desktop)
    case split
    /// A new workspace (tab) on the same host
    case newWorkspace
    /// End the pane shown; the last one takes its workspace along
    case close
}

extension PaneStatus {
    /// Subtitle for a pane in the session menu, empty when there's nothing worth saying
    var label: String {
        switch self {
        case .working: return "Working"
        case .blocked: return "Needs you"
        case .done: return "Done"
        case .idle, .none: return ""
        }
    }

    /// SF Symbol for menus, which can't host the animated indicator
    var symbolName: String {
        switch self {
        case .working: return "circle.dotted"
        case .blocked: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "circle"
        case .none: return "terminal"
        }
    }
}

/// Unified tab item representing either a terminal session or web tab
@MainActor
enum TabItem: Identifiable, Equatable {
    case terminal(Session)
    case web(WebTab)

    nonisolated var id: UUID {
        switch self {
        // Every pane of a session group is one tab
        case .terminal(let session): return session.groupId ?? session.id
        case .web(let webTab): return webTab.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let session): return session.title
        case .web(let webTab): return webTab.title
        }
    }

    nonisolated static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Images sent from a remote host with `clauntty show`
struct ImageViewerContent: Identifiable {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let image: PlatformImage?
        /// Why the image couldn't be shown (download failed, not an image)
        let error: String?

        init(name: String, image: PlatformImage) {
            self.name = name
            self.image = image
            self.error = nil
        }

        init(name: String, error: String) {
            self.name = name
            self.image = nil
            self.error = error
        }
    }

    let id = UUID()
    let host: String
    var items: [Item]
    /// Page to show; set when more images arrive while the viewer is open
    var selection = 0
}
