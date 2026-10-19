// The Mac app's icon from the iOS one: iOS masks a full-bleed square itself, macOS
// wants the shape drawn, so the iOS image goes into the macOS grid (an 824pt rounded
// square in a 1024pt canvas, with a shadow) at every size the Mac uses.
//
//   swift scripts/make-mac-icon.swift
//
// Rerun after changing Clauntty/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png.

import AppKit

let source = "Clauntty/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let catalog = "ClaunttyMac/Assets.xcassets"
let iconSet = "\(catalog)/AppIcon.appiconset"

guard let image = NSImage(contentsOfFile: source) else {
    fatalError("Run from the repo root: can't read \(source)")
}

/// The icon at `pixels` square
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    // Apple's macOS icon grid: the shape is 824 of 1024, a little above centre for the shadow
    let rect = NSRect(x: 100 * scale, y: 112 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185.4 * scale, yRadius: 185.4 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    shape.addClip()
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(atPath: iconSet)
try FileManager.default.createDirectory(atPath: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: URL(fileURLWithPath: "\(iconSet)/\(name)"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

func writeJSON(_ object: Any, to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}
let info = ["author": "xcode", "version": 1] as [String: Any]
try writeJSON(["images": images, "info": info], to: "\(iconSet)/Contents.json")
try writeJSON(["info": info], to: "\(catalog)/Contents.json")
print("Wrote \(images.count) icons to \(iconSet)")
