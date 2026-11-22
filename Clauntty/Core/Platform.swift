// Small seams for code shared by the iOS and macOS apps.

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

extension UIImage {
    /// PNG data, under the same name on both platforms.
    func platformPNGData() -> Data? { pngData() }
}
#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

extension NSImage {
    /// PNG data, under the same name on both platforms.
    func platformPNGData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension NSPasteboard {
    /// Images to paste: image files (copied in Finder), else an image with no text
    /// (a screenshot copied to the clipboard). Nil when it's text.
    func pastedImages() -> [NSImage]? {
        let files = (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = files.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }
        if !imageFiles.isEmpty {
            let images = imageFiles.compactMap { NSImage(contentsOf: $0) }
            return images.isEmpty ? nil : images
        }
        guard files.isEmpty, string(forType: .string) == nil, let image = NSImage(pasteboard: self) else { return nil }
        return [image]
    }

    /// Files to paste that aren't images (those go as `pastedImages`): copied in Finder,
    /// or dragged in. Not folders, yet. Nil when there are none.
    func pastedFiles() -> [URL]? {
        let files = (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let others = files.filter {
            let values = try? $0.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            return values?.isDirectory != true && values?.contentType?.conforms(to: .image) != true
        }
        return others.isEmpty ? nil : others
    }
}
#endif

/// App-level calls shared code makes, per platform.
@MainActor
enum PlatformApp {
    /// The app is in the foreground and may use the network. An iOS app gets
    /// suspended in the background; a Mac app keeps running either way.
    static var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    static func open(_ url: URL) async {
        #if canImport(UIKit)
        await UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if !os(iOS)
/// The Mac reaches the tailnet through the system's Tailscale, so there's no
/// embedded node to log about.
enum TailscaleDebugLog {
    static func note(_ message: String) {}
}
#endif
