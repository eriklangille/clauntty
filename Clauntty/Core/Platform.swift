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
