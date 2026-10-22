import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Images from `clauntty show`, over the workspace whose pane ran it, as the phone shows
/// them. The image springs out of that pane, over the workspace blurred, and shrinks back
/// into it on closing. The bar and thumbnails stay; each button says what it does on
/// hover.
///
/// Pinch, double-click or Cmd+= / Cmd+− zoom; scrolling or dragging pans a zoomed
/// image. A two-finger swipe, the arrow keys, the side arrows or a thumbnail turn the
/// page. Esc, Space or a click outside the image closes. Images that arrive while it's
/// open are added, and it moves to the first of them.
struct ImageViewer: View {
    @Binding var content: ImageViewerContent?
    /// Where a session's pane is in the window (from its top left), to open out of and
    /// close back into
    let paneFrame: (UUID) -> CGRect?
    /// Markup's Send to Claude: the marked-up image and the item it was made from. Nil
    /// where there's no pane to send it to.
    var send: ((NSImage, ImageViewerContent.Item) -> Void)?

    /// Cmd+= (+1), Cmd+− (−1) and Cmd+0 (nil) from the View menu, as an NSNumber
    static let zoomCommand = Notification.Name("ImageViewer.zoom")

    @State private var page = 0
    /// Which way the last page turn went, for the slide
    @State private var forward = true
    @State private var zoom = Zoom()
    @State private var pinchStart: Zoom?
    @State private var panStart: CGSize?
    @State private var windowSize: CGSize = .zero
    @State private var pointer: CGPoint?
    @State private var scrollMonitor: Any?
    /// A two-finger swipe so far, in points
    @State private var swipe: CGFloat = 0
    /// Marking up the image shown (Markup), else nil
    @State private var marking: MarkupState?
    @FocusState private var focused: Bool

    /// How far the image is zoomed past fitting the window, and where it's moved to
    private struct Zoom: Equatable {
        var scale: CGFloat = 1
        var pan: CGSize = .zero
        var isZoomed: Bool { scale > 1.01 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let content, !content.items.isEmpty {
                    let items = content.items
                    let index = min(page, items.count - 1)
                    let area = imageArea(in: geometry.size, thumbnails: items.count > 1)
                    backdrop
                        .transition(.opacity)
                    // The pane where it is in this view, which may not start at the
                    // window's corner
                    let origin = geometry.frame(in: .global).origin
                    let pane = content.source.flatMap(paneFrame)?.offsetBy(dx: -origin.x, dy: -origin.y)
                    stage(items[index], area: area)
                        .transition(opening(from: pane, in: geometry.size))
                    chrome(content, index: index, size: geometry.size)
                        .transition(.opacity)
                }
            }
            .onAppear { windowSize = geometry.size }
            .onChange(of: geometry.size) { _, size in windowSize = size }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: content == nil)
        .onChange(of: content == nil) { _, closed in closed ? didClose() : didOpen() }
        // Shown with images already there: going back to a workspace that has some
        .onAppear { if content != nil { didOpen() } }
        .onDisappear { didClose() }
        .onChange(of: content?.selection) { _, selection in
            if let selection { turn(to: selection) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.zoomCommand)) { note in
            zoomCommand((note.object as? NSNumber)?.floatValue)
        }
    }

    // MARK: Pieces

    /// The window behind, blurred and darkened; a click on it closes
    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.35))
            .environment(\.colorScheme, .dark)
            .contentShape(Rectangle())
            .onTapGesture { if marking == nil { close() } }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                case .ended:
                    pointer = nil
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { if marking == nil { turn(by: -1) }; return .handled }
            .onKeyPress(.rightArrow) { if marking == nil { turn(by: 1) }; return .handled }
            // Marking up: Esc leaves Markup, not the viewer
            .onKeyPress(.escape) {
                if marking != nil { marking = nil } else { close() }
                return .handled
            }
            .onKeyPress(.space) { if marking == nil { close() }; return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "s")) { press in
                guard press.modifiers.contains(.command), let item = shownItem else { return .ignored }
                save(item)
                return .handled
            }
            .onCopyCommand {
                guard let item = shownItem else { return [] }
                if item.kind == .still, let image = item.image { return [NSItemProvider(object: image)] }
                return Self.file(for: item).flatMap { NSItemProvider(contentsOf: $0) }.map { [$0] } ?? []
            }
    }

    /// The image, in the space between the bar and the thumbnails; a page turn slides
    /// the next one in
    private func stage(_ item: ImageViewerContent.Item, area: CGRect) -> some View {
        ZStack {
            Group {
                if case .video(let file) = item.kind, let poster = item.image {
                    video(file, poster: poster, area: area)
                } else if let image = item.image {
                    picture(image, item: item, area: area)
                } else {
                    Label(item.error ?? "Can't show this image", systemImage: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .id(item.id)
            .transition(.asymmetric(
                insertion: .offset(x: forward ? 80 : -80).combined(with: .opacity),
                removal: .opacity
            ))
        }
        .frame(width: area.width, height: area.height)
        .clipped()
        .position(x: area.midX, y: area.midY)
        .environment(\.colorScheme, .dark)
    }

    private func picture(_ image: NSImage, item: ImageViewerContent.Item, area: CGRect) -> some View {
        let fit = fitted(image, in: area)
        let size = CGSize(width: fit.width * zoom.scale, height: fit.height * zoom.scale)
        let shown = Group {
            if case .animated = item.kind {
                AnimatedImage(image: image)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            }
        }
            .frame(width: size.width, height: size.height)
            .overlay {
                if marking?.itemId == item.id {
                    MarkupLayer(state: Binding { marking ?? MarkupState(itemId: item.id) } set: { marking = $0 })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: zoom.isZoomed ? 0 : 10))
            .shadow(color: .black.opacity(zoom.isZoomed ? 0 : 0.5), radius: 30, y: 12)
            .offset(clamped(zoom.pan, image: size, area: area.size))
            .gesture(pinch)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                doubleClicked(at: tap.location, image: image, fit: fit, area: area)
            })
        return Group {
            if marking != nil {
                // Drags draw
                shown
            } else if zoom.isZoomed {
                // Dragging moves around a zoomed image
                shown.gesture(DragGesture().onChanged { drag in
                    let start = panStart ?? zoom.pan
                    panStart = start
                    zoom.pan = clamped(CGSize(width: start.width + drag.translation.width,
                                              height: start.height + drag.translation.height),
                                       image: size, area: area.size)
                }.onEnded { _ in panStart = nil })
            } else {
                // Else drags out, to Finder or another app, as a file
                shown.onDrag { dragProvider(item) }
            }
        }
    }

    /// A video, fitted, with the player's own controls; no zooming
    private func video(_ file: URL, poster: NSImage, area: CGRect) -> some View {
        let fit = fitted(poster, in: area)
        return VideoPlayerView(file: file)
            .frame(width: fit.width, height: fit.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }

    /// The bar, the side arrows (when the mouse comes near) and the thumbnails
    private func chrome(_ content: ImageViewerContent, index: Int, size: CGSize) -> some View {
        let items = content.items
        let nearLeft = (pointer?.x ?? .infinity) < 160 && index > 0
        let nearRight = (pointer?.x ?? -.infinity) > size.width - 160 && index < items.count - 1
        return ZStack {
            VStack {
                topBar(items[index], host: content.host, index: index, count: items.count)
                    .padding(.top, 14)
                Spacer()
                if marking != nil {
                    MarkupBar(state: Binding { marking ?? MarkupState(itemId: items[index].id) } set: { marking = $0 },
                              send: send == nil ? nil : { sendMarkup() },
                              copy: { copyMarkup() },
                              cancel: { marking = nil })
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if items.count > 1 {
                    thumbnails(items, index: index)
                        .padding(.bottom, 18)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: marking == nil)
            HStack {
                SideArrow(symbol: "chevron.left", help: "Previous (←)") { turn(by: -1) }
                    .opacity(nearLeft && marking == nil ? 1 : 0)
                    .scaleEffect(nearLeft ? 1 : 0.8)
                    .allowsHitTesting(nearLeft && marking == nil)
                Spacer()
                SideArrow(symbol: "chevron.right", help: "Next (→)") { turn(by: 1) }
                    .opacity(nearRight && marking == nil ? 1 : 0)
                    .scaleEffect(nearRight ? 1 : 0.8)
                    .allowsHitTesting(nearRight && marking == nil)
            }
            .padding(.horizontal, 18)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: nearLeft)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: nearRight)
        }
        .environment(\.colorScheme, .dark)
    }

    private func topBar(_ item: ImageViewerContent.Item, host: String, index: Int, count: Int) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(count > 1 ? "\(host) · \(index + 1) of \(count)" : host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            Spacer(minLength: 16)
            if let image = item.image {
                ChromeButton(symbol: "doc.on.doc", label: "Copy (⌘C)") { copy(item) }
                ChromeButton(symbol: "square.and.arrow.down", label: "Save… (⌘S)") { save(item) }
                if item.kind == .still {
                    ShareLink(item: Image(nsImage: image), preview: SharePreview(item.name, image: Image(nsImage: image))) {
                        HoverIcon(symbol: "square.and.arrow.up", label: "Share")
                    }
                    .buttonStyle(PressStyle())
                } else if let file = Self.file(for: item) {
                    // The GIF or the video itself
                    ShareLink(item: file, preview: SharePreview(item.name, image: Image(nsImage: image))) {
                        HoverIcon(symbol: "square.and.arrow.up", label: "Share")
                    }
                    .buttonStyle(PressStyle())
                }
                ChromeButton(symbol: "arrow.up.forward.app", label: Self.isVideo(item) ? "Open in QuickTime Player" : "Open in Preview") {
                    openInPreview(item)
                }
                if item.kind == .still && marking == nil {
                    ChromeButton(symbol: "pencil.tip.crop.circle", label: "Markup") {
                        marking = MarkupState(itemId: item.id)
                    }
                }
            }
            ChromeButton(symbol: "xmark", label: "Close (Esc)") { close() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 680)
        .glass(in: .capsule)
        .padding(.horizontal, 24)
    }

    private func thumbnails(_ items: [ImageViewerContent.Item], index: Int) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        Thumbnail(item: item, selected: offset == index) { turn(to: offset) }
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            // As wide as the thumbnails, up to a point
            .frame(width: min(CGFloat(items.count) * 62 - 8 + 20, 620))
            .onChange(of: index) { _, index in
                withAnimation { scroller.scrollTo(items[index].id, anchor: .center) }
            }
        }
        .glass(in: .rect(cornerRadius: 16))
    }

    // MARK: Layout

    /// Where the image goes: clear of the bar, and of the thumbnails when there are some
    private func imageArea(in size: CGSize, thumbnails: Bool) -> CGRect {
        let side: CGFloat = 48, top: CGFloat = 70, bottom: CGFloat = thumbnails ? 100 : 40
        return CGRect(x: side, y: top, width: max(0, size.width - side * 2), height: max(0, size.height - top - bottom))
    }

    /// The image fitted into `area`, no bigger than it is
    private func fitted(_ image: NSImage, in area: CGRect) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, area.width / size.width, area.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// A zoomed image moves no further than its edges
    private func clamped(_ pan: CGSize, image: CGSize, area: CGSize) -> CGSize {
        let x = max(0, (image.width - area.width) / 2), y = max(0, (image.height - area.height) / 2)
        return CGSize(width: min(max(pan.width, -x), x), height: min(max(pan.height, -y), y))
    }

    /// Opens out of the pane that ran `clauntty show` and closes back into it; from the
    /// middle when that pane isn't on screen
    private func opening(from pane: CGRect?, in size: CGSize) -> AnyTransition {
        guard let pane, size.width > 0, size.height > 0 else {
            return .scale(scale: 0.9).combined(with: .opacity)
        }
        let scale = max(0.15, min(pane.width / size.width, pane.height / size.height))
        let offset = CGSize(width: pane.midX - size.width / 2, height: pane.midY - size.height / 2)
        return .modifier(active: Opening(scale: scale, offset: offset, opacity: 0),
                         identity: Opening(scale: 1, offset: .zero, opacity: 1))
    }

    private struct Opening: ViewModifier {
        let scale: CGFloat
        let offset: CGSize
        let opacity: Double

        func body(content: Content) -> some View {
            content
                .scaleEffect(scale)
                .offset(offset)
                .opacity(opacity)
        }
    }

    // MARK: Zoom

    private var shownItem: ImageViewerContent.Item? {
        guard let items = content?.items, !items.isEmpty else { return nil }
        return items[min(page, items.count - 1)]
    }

    /// The shown image's fitted size and area, for zooming from the menu or the keyboard
    private var shownGeometry: (image: NSImage, fit: CGSize, area: CGRect)? {
        guard let content, let image = shownItem?.image else { return nil }
        let area = imageArea(in: windowSize, thumbnails: content.items.count > 1)
        return (image, fitted(image, in: area), area)
    }

    /// The most it zooms: well past actual size, so small text is readable
    private func maxScale(_ image: NSImage, fit: CGSize) -> CGFloat {
        guard fit.width > 0 else { return 1 }
        return max(4, image.size.width / fit.width * 2)
    }

    /// Zoom to `scale` keeping `point` (from the area's middle) where it is
    private func zoom(to scale: CGFloat, around point: CGPoint, from start: Zoom, image: NSImage, fit: CGSize, area: CGRect) {
        let scale = min(max(scale, 1), maxScale(image, fit: fit))
        let ratio = scale / start.scale
        let pan = CGSize(width: point.x - (point.x - start.pan.width) * ratio,
                         height: point.y - (point.y - start.pan.height) * ratio)
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        zoom = Zoom(scale: scale, pan: scale > 1.01 ? clamped(pan, image: size, area: area.size) : .zero)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let shown = shownGeometry else { return }
                let start = pinchStart ?? zoom
                pinchStart = start
                // Around the point under the fingers, from the middle of the area
                let size = CGSize(width: shown.fit.width * start.scale, height: shown.fit.height * start.scale)
                let point = CGPoint(x: (value.startAnchor.x - 0.5) * size.width + start.pan.width,
                                    y: (value.startAnchor.y - 0.5) * size.height + start.pan.height)
                zoom(to: start.scale * value.magnification, around: point, from: start,
                     image: shown.image, fit: shown.fit, area: shown.area)
            }
            .onEnded { _ in
                pinchStart = nil
                if !zoom.isZoomed {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { zoom = Zoom() }
                }
            }
    }

    /// Fit ↔ actual size (or 2.5×, for an image no bigger than the window), at the click
    private func doubleClicked(at location: CGPoint, image: NSImage, fit: CGSize, area: CGRect) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if zoom.isZoomed {
                zoom = Zoom()
            } else {
                let actual = fit.width > 0 ? image.size.width / fit.width : 1
                let point = CGPoint(x: location.x - fit.width / 2, y: location.y - fit.height / 2)
                zoom(to: actual > 1.2 ? actual : 2.5, around: point, from: zoom, image: image, fit: fit, area: area)
            }
        }
    }

    private func zoomCommand(_ step: Float?) {
        guard let shown = shownGeometry else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            guard let step else {
                zoom = Zoom()
                return
            }
            // Around the middle of what's shown
            zoom(to: step > 0 ? zoom.scale * 1.5 : zoom.scale / 1.5, around: .zero, from: zoom,
                 image: shown.image, fit: shown.fit, area: shown.area)
        }
    }

    /// Two fingers: pan a zoomed image, else a sideways swipe turns the page
    private func scrolled(_ event: NSEvent) -> NSEvent? {
        guard content != nil else { return event }
        if zoom.isZoomed, let shown = shownGeometry {
            let size = CGSize(width: shown.fit.width * zoom.scale, height: shown.fit.height * zoom.scale)
            zoom.pan = clamped(CGSize(width: zoom.pan.width + event.scrollingDeltaX,
                                      height: zoom.pan.height + event.scrollingDeltaY),
                               image: size, area: shown.area.size)
            return nil
        }
        // Trackpad only, and not the coasting after the fingers lift
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return nil }
        if event.phase == .began { swipe = 0 }
        swipe += event.scrollingDeltaX
        if event.phase == .ended || event.phase == .cancelled {
            if abs(swipe) > 50 { turn(by: swipe > 0 ? -1 : 1) }
            swipe = 0
        }
        return nil
    }

    // MARK: Paging, showing and closing

    private func turn(by offset: Int) {
        guard let count = content?.items.count else { return }
        turn(to: min(max(page + offset, 0), count - 1))
    }

    private func turn(to index: Int) {
        guard index != page else { return }
        forward = index > page
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            page = index
            zoom = Zoom()
        }
        marking = nil
    }

    private func didOpen() {
        page = content?.selection ?? 0
        zoom = Zoom()
        // After the terminal has let go of the keyboard
        DispatchQueue.main.async { focused = true }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            scrolled(event)
        }
    }

    private func didClose() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        pointer = nil
        marking = nil
    }

    private func close() {
        content = nil
    }

    // MARK: Actions

    /// The marked-up image, flattened at full size
    private var markedImage: (NSImage, ImageViewerContent.Item)? {
        guard let marking, let item = content?.items.first(where: { $0.id == marking.itemId }),
              let image = item.image, let marked = Mark.render(image, marks: marking.marks) else { return nil }
        return (marked, item)
    }

    private func sendMarkup() {
        guard let (marked, item) = markedImage else { return }
        marking = nil
        send?(marked, item)
    }

    private func copyMarkup() {
        guard let (marked, _) = markedImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([marked])
    }

    /// A still as an image; a GIF or a video as its file, so it stays one
    private func copy(_ item: ImageViewerContent.Item) {
        NSPasteboard.general.clearContents()
        if item.kind == .still, let image = item.image {
            NSPasteboard.general.writeObjects([image])
        } else if let file = Self.file(for: item) {
            NSPasteboard.general.writeObjects([file as NSURL])
        }
    }

    private func save(_ item: ImageViewerContent.Item) {
        guard let file = Self.file(for: item) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = UTType(filenameExtension: file.pathExtension).map { [$0] } ?? []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: file, to: url)
    }

    /// A video in its default player (QuickTime Player), an image in Preview
    private func openInPreview(_ item: ImageViewerContent.Item) {
        guard let url = Self.file(for: item) else { return }
        if Self.isVideo(item) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func isVideo(_ item: ImageViewerContent.Item) -> Bool {
        if case .video = item.kind { return true }
        return false
    }

    /// As a file, so Finder takes it as one
    private func dragProvider(_ item: ImageViewerContent.Item) -> NSItemProvider {
        guard let url = Self.file(for: item), let provider = NSItemProvider(contentsOf: url) else {
            return item.image.map { NSItemProvider(object: $0) } ?? NSItemProvider()
        }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// The item as a file, for saving, Preview, sharing and dragging out: a video's own;
    /// a GIF's bytes, or a still as a PNG, in a temporary folder
    private static func file(for item: ImageViewerContent.Item) -> URL? {
        let data: Data
        let name: String
        switch item.kind {
        case .video(let file):
            return file
        case .animated(let gif):
            data = gif
            name = fileName(item.name, ext: "gif")
        case .still:
            guard let png = item.image.flatMap(png) else { return nil }
            data = png
            name = fileName(item.name, ext: "png")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clauntty Images", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func fileName(_ name: String, ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + "." + ext
    }
}

// MARK: - Controls

/// An icon in the bar: a soft circle comes up under it on hover, and what it does just
/// below the bar (sooner than a system tooltip)
private struct HoverIcon: View {
    let symbol: String
    let label: String
    @State private var hovering = false
    @State private var labelShown = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0)))
            .scaleEffect(hovering ? 1.08 : 1)
            .contentShape(Circle())
            .overlay(alignment: .top) {
                if labelShown {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.8)))
                        // Under the bar: the icon, the bar's padding, a gap
                        .offset(y: 30 + 8 + 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { self.hovering = hovering }
                withAnimation(.easeOut(duration: 0.15).delay(hovering ? 0.25 : 0)) { labelShown = hovering }
            }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { HoverIcon(symbol: symbol, label: label) }
            .buttonStyle(PressStyle())
    }
}

/// Dips when pressed
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The big arrows at the sides, shown when the mouse comes near
private struct SideArrow: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .glass(in: .circle)
                .scaleEffect(hovering ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { self.hovering = hovering }
        }
    }
}

/// One image in the strip: dim until hovered or shown, lifting a little on hover
private struct Thumbnail: View {
    let item: ImageViewerContent.Item
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.08))
                }
            }
            .frame(width: 54, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(selected ? 0.9 : hovering ? 0.35 : 0), lineWidth: 2)
            )
            .opacity(selected || hovering ? 1 : 0.55)
            .scaleEffect(hovering && !selected ? 1.08 : 1)
            .offset(y: hovering && !selected ? -2 : 0)
        }
        .buttonStyle(PressStyle())
        .help(item.name)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { self.hovering = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// MARK: - Media

/// A GIF, playing: NSImageView animates an NSImage's frames, SwiftUI's Image doesn't.
/// Clicks and drags go through to the viewer's gestures.
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = PassThroughImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    private final class PassThroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A video with the system's controls. It starts muted, so a screen recording doesn't
/// blare, and plays once.
private struct VideoPlayerView: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: file)
        player.isMuted = true
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
