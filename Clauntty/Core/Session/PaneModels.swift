import Foundation
import os

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

/// A tab's split layout, as rtach keeps it: a pane, or two halves side by side
/// (`"split":"h"`) or stacked (`"v"`), the first taking `ratio` of the space.
indirect enum PaneLayout: Equatable, Decodable {
    case pane(String)
    case split(vertical: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

    private enum Keys: String, CodingKey { case split, ratio, a, b }

    init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self = .pane(id)
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        self = .split(
            vertical: try container.decode(String.self, forKey: .split) == "v",
            ratio: try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
            first: try container.decode(PaneLayout.self, forKey: .a),
            second: try container.decode(PaneLayout.self, forKey: .b)
        )
    }

    /// Pane ids left to right, top to bottom
    var paneIds: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.paneIds + second.paneIds
        }
    }

    /// The split between two panes (the smallest holding both) giving `pane`'s side
    /// `ratio`, kept between 0.1 and 0.9, as `rtach ws resize` does
    func resized(_ pane: String, _ other: String, ratio: Double) -> PaneLayout {
        guard case .split(let vertical, let current, let first, let second) = self else { return self }
        switch (first.paneIds.contains(pane), first.paneIds.contains(other)) {
        case (true, true):
            return .split(vertical: vertical, ratio: current, first: first.resized(pane, other, ratio: ratio), second: second)
        case (false, false):
            return .split(vertical: vertical, ratio: current, first: first, second: second.resized(pane, other, ratio: ratio))
        case (let paneFirst, _):
            return .split(vertical: vertical, ratio: min(max(paneFirst ? ratio : 1 - ratio, 0.1), 0.9),
                          first: first, second: second)
        }
    }

    /// Without some panes, a split's other half taking its place; nil if none are left
    func without(_ ids: Set<String>) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return ids.contains(id) ? nil : self
        case .split(let vertical, let ratio, let first, let second):
            switch (first.without(ids), second.without(ids)) {
            case let (first?, second?): return .split(vertical: vertical, ratio: ratio, first: first, second: second)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }
}

/// Session menu actions on a workspace tab
enum PaneAction {
    /// A new pane next to the one shown (a split on the desktop)
    case split
    /// A new pane below the one shown
    case splitDown
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
        let id: UUID
        let name: String
        let image: PlatformImage?
        /// Why the image couldn't be shown (download failed, not an image)
        let error: String?
        let arrived: Date

        init(id: UUID = UUID(), name: String, image: PlatformImage, arrived: Date = Date()) {
            self.id = id
            self.name = name
            self.image = image
            self.error = nil
            self.arrived = arrived
        }

        init(name: String, error: String) {
            self.id = UUID()
            self.name = name
            self.image = nil
            self.error = error
            self.arrived = Date()
        }
    }

    let id = UUID()
    let host: String
    var items: [Item]
    /// Page to show; set when more images arrive while the viewer is open
    var selection = 0
    /// The session that ran `clauntty show`: the Mac opens the viewer out of its pane
    var source: UUID?
}

/// Images waiting in a workspace's viewer, kept on disk so they're still there after the
/// app restarts: `Application Support/<bundle id>/Waiting/<workspace>/`, each image's
/// bytes as downloaded (named by its item's id) and `manifest.json`. A workspace whose
/// viewer is closed loses its folder.
enum WaitingImages {
    private struct Manifest: Codable {
        struct Item: Codable {
            let id: UUID
            let name: String
            let arrived: Date
        }
        let host: String
        let source: UUID?
        let items: [Item]
    }

    private static let manifestName = "manifest.json"

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Clauntty", isDirectory: true)
            .appendingPathComponent("Waiting", isDirectory: true)
    }

    private static func folder(_ workspace: UUID) -> URL {
        directory.appendingPathComponent(workspace.uuidString, isDirectory: true)
    }

    /// Keep a downloaded image's bytes, for `save` to list
    static func store(_ data: Data, item: UUID, workspace: UUID) {
        let folder = folder(workspace)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Not worth a backup: the host had them for 6 hours at most
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            try data.write(to: folder.appendingPathComponent(item.uuidString), options: .atomic)
        } catch {
            Logger.clauntty.warning("WaitingImages: couldn't keep an image: \(error.localizedDescription)")
        }
    }

    /// Match the disk to what each workspace's viewer holds: a manifest of its images
    /// that were stored, and no folder for a workspace with none
    static func save(_ contents: [UUID: ImageViewerContent]) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let workspace = UUID(uuidString: folder.lastPathComponent),
                  let content = contents[workspace] else {
                try? fileManager.removeItem(at: folder)
                continue
            }
            let files = Set((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            let items = content.items.filter { files.contains($0.id.uuidString) }
            guard !items.isEmpty else {
                try? fileManager.removeItem(at: folder)
                continue
            }
            let manifest = Manifest(host: content.host, source: content.source,
                                    items: items.map { .init(id: $0.id, name: $0.name, arrived: $0.arrived) })
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: folder.appendingPathComponent(manifestName), options: .atomic)
            }
            // Images the viewer no longer has
            let kept = Set(items.map(\.id.uuidString)).union([manifestName])
            for file in files where !kept.contains(file) {
                try? fileManager.removeItem(at: folder.appendingPathComponent(file))
            }
        }
    }

    /// What was waiting when the app last ran, for these workspaces, without anything
    /// older than the host keeps an inbox entry
    static func load(workspaces: Set<UUID>) -> [UUID: ImageViewerContent] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var contents: [UUID: ImageViewerContent] = [:]
        for folder in folders {
            guard let workspace = UUID(uuidString: folder.lastPathComponent), workspaces.contains(workspace),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let items = manifest.items.compactMap { item -> ImageViewerContent.Item? in
                guard Date().timeIntervalSince(item.arrived) < ImageInbox.maxAge,
                      let bytes = try? Data(contentsOf: folder.appendingPathComponent(item.id.uuidString)),
                      let image = PlatformImage(data: bytes) else { return nil }
                return .init(id: item.id, name: item.name, image: image, arrived: item.arrived)
            }
            if !items.isEmpty {
                contents[workspace] = ImageViewerContent(host: manifest.host, items: items, source: manifest.source)
            }
        }
        return contents
    }
}
