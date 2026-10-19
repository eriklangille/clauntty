// Small seams for code shared by the iOS and macOS apps.

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

extension UIImage {
    /// PNG data, under the same name on both platforms.
    func platformPNGData() -> Data? { pngData() }
    func platformJPEGData(quality: CGFloat) -> Data? { jpegData(compressionQuality: quality) }
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

    func platformJPEGData(quality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
#endif
