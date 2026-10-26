import AVFoundation
import Foundation
import ImageIO
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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

    /// `pane` out of its place and on `side` of `other`, splitting it in half, as
    /// `rtach ws move PANE OTHER --side` does
    func moving(_ pane: String, beside other: String, _ side: PaneSide) -> PaneLayout {
        guard pane != other, let rest = without([pane]) else { return self }
        return rest.inserting(pane, beside: other, side)
    }

    private func inserting(_ pane: String, beside other: String, _ side: PaneSide) -> PaneLayout {
        switch self {
        case .pane(let id):
            guard id == other else { return self }
            let moved = PaneLayout.pane(pane)
            let before = side == .left || side == .up
            return .split(vertical: side == .up || side == .down, ratio: 0.5,
                          first: before ? moved : self, second: before ? self : moved)
        case .split(let vertical, let ratio, let first, let second):
            return .split(vertical: vertical, ratio: ratio, first: first.inserting(pane, beside: other, side),
                          second: second.inserting(pane, beside: other, side))
        }
    }

    /// The same panes in the same places, whatever the splits' sizes
    func arranged(like other: PaneLayout) -> Bool {
        switch (self, other) {
        case let (.pane(a), .pane(b)):
            return a == b
        case let (.split(v1, _, a1, b1), .split(v2, _, a2, b2)):
            return v1 == v2 && a1.arranged(like: a2) && b1.arranged(like: b2)
        default:
            return false
        }
    }
}

/// Where a pane is moved beside another: `rtach ws move`'s --left, --right, --up, --down
enum PaneSide: String {
    case left, right, up, down
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
        /// What it is: the viewer shows each its own way
        enum Kind: Equatable {
            case still
            /// A GIF with frames: `image` has them all (on the phone an animated UIImage);
            /// the bytes are the GIF, to save or copy as one
            case animated(Data)
            /// Played from its file; `image` is its first frame
            case video(URL)
        }

        let id: UUID
        let name: String
        /// The picture; a video's first frame
        let image: PlatformImage?
        /// Why the image couldn't be shown (download failed, not an image)
        let error: String?
        let arrived: Date
        var kind = Kind.still

        init(id: UUID = UUID(), name: String, image: PlatformImage, arrived: Date = Date(), kind: Kind = .still) {
            self.id = id
            self.name = name
            self.image = image
            self.error = nil
            self.arrived = arrived
            self.kind = kind
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

extension ImageViewerContent.Item {
    /// Videos `clauntty show` takes (rtach's `isMediaPath`): what AVFoundation plays
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// An image's bytes: a still, or a GIF's frames to animate. Nil if it isn't an image.
    static func image(id: UUID = UUID(), name: String, data: Data, arrived: Date = Date()) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetCount(source) > 1, let animated = animatedImage(source, data: data) {
            return .init(id: id, name: name, image: animated, arrived: arrived, kind: .animated(data))
        }
        guard let image = PlatformImage(data: data) else { return nil }
        return .init(id: id, name: name, image: image, arrived: arrived)
    }

    /// A video file, with its first frame to show. Nil if AVFoundation can't read it.
    static func video(id: UUID = UUID(), name: String, file: URL, arrived: Date = Date()) async -> Self? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return video(id: id, name: name, file: file, poster: platformImage(frame), arrived: arrived)
    }

    static func video(id: UUID, name: String, file: URL, poster: PlatformImage, arrived: Date) -> Self {
        .init(id: id, name: name, image: poster, arrived: arrived, kind: .video(file))
    }

    private static func platformImage(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cgImage)
        #else
        NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    private static func animatedImage(_ source: CGImageSource, data: Data) -> PlatformImage? {
        #if canImport(UIKit)
        // UIImage keeps one frame: build an animated one, timed by the frames' delays
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // As browsers do: a delay under 20ms plays at 100ms
            duration += delay < 0.02 ? 0.1 : delay
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : nil
        #else
        // NSImage keeps a GIF's frames, and NSImageView plays them
        return NSImage(data: data)
        #endif
    }
}

/// A workspace's images, kept on disk so they're still there after the app restarts:
/// those waiting in its viewer and those closed, to reopen.
/// `Application Support/<bundle id>/Waiting/<workspace>/` has each image's bytes as
/// downloaded (named by its item's id; a video as `<id>.<ext>` with its first frame in
/// `<id>.poster`) and `manifest.json`. A workspace with neither loses its folder.
enum WaitingImages {
    private struct Manifest: Codable {
        struct Item: Codable {
            let id: UUID
            let name: String
            let arrived: Date
            /// A video's file in the folder
            var video: String?
        }
        struct Group: Codable {
            let host: String
            let source: UUID?
            let items: [Item]
        }
        // The open images, at the top as before closed ones were kept
        let host: String
        let source: UUID?
        let items: [Item]
        /// Closed, to reopen
        let recent: Group?
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
        guard let folder = makeFolder(workspace) else { return }
        do {
            try data.write(to: folder.appendingPathComponent(item.uuidString), options: .atomic)
        } catch {
            Logger.clauntty.warning("WaitingImages: couldn't keep an image: \(error.localizedDescription)")
        }
    }

    /// Where a video goes once downloaded (AVFoundation plays files): with its workspace's
    /// images, or for one with no workspace, the temporary folder
    static func videoFile(item: UUID, name: String, workspace: UUID?) -> URL? {
        let ext = (name as NSString).pathExtension.lowercased()
        let folder = workspace.flatMap(makeFolder)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("clauntty-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(item.uuidString).\(ext)")
    }

    /// A video's first frame, so a restart shows it without reading the video
    static func storePoster(_ image: PlatformImage, item: UUID, workspace: UUID) {
        guard let folder = makeFolder(workspace), let data = image.platformPNGData() else { return }
        try? data.write(to: folder.appendingPathComponent("\(item.uuidString).poster"), options: .atomic)
    }

    private static func makeFolder(_ workspace: UUID) -> URL? {
        let folder = folder(workspace)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger.clauntty.warning("WaitingImages: no folder: \(error.localizedDescription)")
            return nil
        }
        // Not worth a backup: the host had them for 6 hours at most
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return folder
    }

    /// The item a file belongs to: its name starts with the item's id
    private static func itemId(_ file: String) -> String { String(file.prefix(36)) }

    /// Match the disk to each workspace's images: a manifest of those that were stored,
    /// open and closed, and no folder for a workspace with none
    static func save(open: [UUID: ImageViewerContent], recent: [UUID: ImageViewerContent]) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let workspace = UUID(uuidString: folder.lastPathComponent)
            let files = Set((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            let stored = Set(files.map(itemId))
            let opened = workspace.flatMap { open[$0] }
            let closed = workspace.flatMap { recent[$0] }
            let openItems = opened?.items.filter { stored.contains($0.id.uuidString) } ?? []
            let closedItems = closed?.items.filter { stored.contains($0.id.uuidString) } ?? []
            guard !openItems.isEmpty || !closedItems.isEmpty else {
                try? fileManager.removeItem(at: folder)
                continue
            }
            let manifest = Manifest(
                host: opened?.host ?? closed?.host ?? "",
                source: opened?.source ?? closed?.source,
                items: openItems.map(entry),
                recent: closed.map { .init(host: $0.host, source: $0.source, items: closedItems.map(entry)) }
            )
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: folder.appendingPathComponent(manifestName), options: .atomic)
            }
            // Images neither has any more
            let kept = Set((openItems + closedItems).map(\.id.uuidString))
            for file in files where file != manifestName && !kept.contains(itemId(file)) {
                try? fileManager.removeItem(at: folder.appendingPathComponent(file))
            }
        }
    }

    private static func entry(_ item: ImageViewerContent.Item) -> Manifest.Item {
        var entry = Manifest.Item(id: item.id, name: item.name, arrived: item.arrived)
        if case .video(let file) = item.kind { entry.video = file.lastPathComponent }
        return entry
    }

    /// Each workspace's images when the app last ran, open and closed, without anything
    /// older than the host keeps an inbox entry
    static func load(workspaces: Set<UUID>) -> (open: [UUID: ImageViewerContent], recent: [UUID: ImageViewerContent]) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var open: [UUID: ImageViewerContent] = [:]
        var recent: [UUID: ImageViewerContent] = [:]
        for folder in folders {
            guard let workspace = UUID(uuidString: folder.lastPathComponent), workspaces.contains(workspace),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let items = images(manifest.items, in: folder)
            if !items.isEmpty {
                open[workspace] = ImageViewerContent(host: manifest.host, items: items, source: manifest.source)
            }
            if let group = manifest.recent {
                let items = images(group.items, in: folder)
                if !items.isEmpty {
                    recent[workspace] = ImageViewerContent(host: group.host, items: items, source: group.source)
                }
            }
        }
        return (open, recent)
    }

    private static func images(_ entries: [Manifest.Item], in folder: URL) -> [ImageViewerContent.Item] {
        entries.compactMap { item in
            guard Date().timeIntervalSince(item.arrived) < ImageInbox.maxAge else { return nil }
            if let video = item.video {
                let file = folder.appendingPathComponent(video)
                guard FileManager.default.fileExists(atPath: file.path),
                      let bytes = try? Data(contentsOf: folder.appendingPathComponent("\(item.id.uuidString).poster")),
                      let poster = PlatformImage(data: bytes) else { return nil }
                return .video(id: item.id, name: item.name, file: file, poster: poster, arrived: item.arrived)
            }
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(item.id.uuidString)) else { return nil }
            return .image(id: item.id, name: item.name, data: bytes, arrived: item.arrived)
        }
    }
}

// MARK: - How a workspace reads in a list (the Mac's sidebar cards, the phone's windows)

extension SessionGroup {
    /// The workspace's name and what's running in the pane it shows. Workspaces named
    /// after a folder (`~`, a path) take the running thing's name instead, and so does a
    /// named one whose shown pane's agent says what it's on: its name goes after
    /// (`nameAfterTitle`), as in the pill.
    var sidebarTitles: (title: String, subtitle: String?) {
        let shown = panes.first { $0.id == activePaneId } ?? panes.first
        let paneTitle = shown?.title ?? ""
        guard isNamed else {
            return (paneTitle.isEmpty || paneTitle == "~" ? "shell" : paneTitle, nil)
        }
        if let agentTitle { return (agentTitle, nil) }
        // A shell at home says nothing more than the name
        return (title, paneTitle == title || paneTitle == "~" || paneTitle.isEmpty ? nil : paneTitle)
    }

    /// The workspace's own name, small after the title, when its agent's title took its place
    var nameAfterTitle: String? {
        isNamed && agentTitle != nil ? title : nil
    }

    /// Named, not after a folder
    private var isNamed: Bool {
        !title.isEmpty && title != "~" && !title.hasPrefix("/")
    }

    /// What the shown pane's agent is on: Claude's title for the conversation, else the
    /// last prompt (`SessionManager.paneTitle`); not when that's only the agent's name
    private var agentTitle: String? {
        guard let shown = panes.first(where: { $0.id == activePaneId }) ?? panes.first,
              shown.status != .none else { return nil }
        let paneTitle = shown.title
        return paneTitle.isEmpty || paneTitle == title || ["claude", "agent"].contains(paneTitle) ? nil : paneTitle
    }

    /// What needs you most among its panes: one waiting on you beats one that's done,
    /// which beats one working
    var mostPressingStatus: PaneStatus {
        panes.map(\.status).max { $0.urgency < $1.urgency } ?? .none
    }

    /// The pane a card speaks for: the one that needs you most, else the one shown
    var leadPane: TabPane? {
        let shown = panes.first { $0.id == activePaneId } ?? panes.first
        guard let pressing = panes.max(by: { $0.status.urgency < $1.status.urgency }),
              let shown else { return shown }
        return pressing.status.urgency > shown.status.urgency ? pressing : shown
    }
}

extension PaneStatus {
    /// What a pane is doing, beside its glyph (which says its state): the task, what it's
    /// waiting on when it needs you, or a shell's program; nil when there's nothing to say
    func detail(state: RemotePaneState?, title: String, subtitle: String?) -> String? {
        // Not when it's already the title (a workspace named after its folder takes it)
        let task = state?.task.flatMap { $0.isEmpty || title.hasPrefix($0) || $0.hasPrefix(title) ? nil : $0 }
        switch self {
        case .blocked: return state?.note.flatMap { $0.isEmpty ? nil : $0 } ?? task
        case .working, .done, .idle: return task
        case .none: return subtitle ?? state?.fg
        }
    }

    /// Which of two statuses to show for a workspace: what needs you first
    var urgency: Int {
        switch self {
        case .blocked: return 4
        case .done: return 3
        case .working: return 2
        case .idle: return 1
        case .none: return 0
        }
    }
}

extension RemotePaneState {
    /// Where a pane is, for one with nothing else to say: the program in front unless
    /// it's the shell, and the folder from home ("claude · ~/Projects/clauntty")
    var place: String? {
        let folder = Self.folder(cwd)
        let shells: Set = ["bash", "zsh", "fish", "sh", "dash", "login"]
        let program = fg.flatMap { $0.isEmpty || shells.contains($0.trimmingCharacters(in: ["-"])) ? nil : $0 }
        switch (program, folder) {
        case let (program?, folder?): return "\(program) · \(folder)"
        case let (program, folder): return program ?? folder
        }
    }

    /// A folder from home: "~/Projects/clauntty"
    static func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        let home = parts.first == "Users" || parts.first == "home" ? 2 : parts.first == "root" ? 1 : 0
        guard home > 0, parts.count >= home else { return path }
        return (["~"] + parts.dropFirst(home)).joined(separator: "/")
    }
}

extension Date {
    /// How long before `now`: "now", "4m", "2h", "3d"
    func shortAge(now: Date) -> String {
        let seconds = max(now.timeIntervalSince(self), 0)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
