import os
import AVKit
import Photos
import SwiftUI
import UIKit

/// Full-screen viewer: swipe between images, pinch or double-tap to zoom, swipe down
/// or tap Done to close.
///
/// With a pane to send to (the one that ran `clauntty show`), each still has a note field
/// under it and Send, and ✎ marks it up (`ImageMarkupView`). Marks and notes stay with their
/// image (`ImageDrafts`, as on the Mac) until Send, which sends every image that has either,
/// each with its note, else the one shown, as one message, and closes the viewer.
struct ImageViewerView: View {
    @Binding var content: ImageViewerContent?
    /// Send to Claude: each image (marked up) and its note. Nil with no pane to send to.
    var send: (([(image: PlatformImage, note: String)]) -> Void)?

    @State private var page = 0
    @State private var isZoomed = false
    @State private var showChrome = true
    @State private var dragOffset: CGFloat = 0
    /// Images saved to Photos, and ones that couldn't be (no access)
    @State private var saved: Set<UUID> = []
    @State private var saveFailed: Set<UUID> = []
    /// Marking up the image shown, else nil
    @State private var marking: MarkupState?
    /// Its marks when Markup started, put back by Cancel
    @State private var marksBefore: [Mark] = []
    @ObservedObject private var drafts = ImageDrafts.shared
    @FocusState private var noteFocused: Bool
    /// The note's focus, animated: the tools and thumbnails fold away as it starts
    @State private var noteUp = false
    static let foldAnimation = Animation.smooth(duration: 0.25)
    /// Images with marks, as they'll be sent, shown in their place out of Markup
    @State private var markedImages: [UUID: UIImage] = [:]
    /// Where the top bar ends and how tall the bottom one is: the image fits between them
    /// while the note has the keyboard
    @State private var topBarBottom: CGFloat = 0
    @State private var bottomBarHeight: CGFloat = 0

    private var items: [ImageViewerContent.Item] { content?.items ?? [] }

    private var shownItem: ImageViewerContent.Item? { items.indices.contains(page) ? items[page] : nil }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(abs(dragOffset) / 400, 0.6))
                .ignoresSafeArea()

            // Markup draws over the same image in the same place, so going in and out of
            // it changes only the bars: no fade (two copies of one image fading across
            // each other dimmed it halfway), and the pages stay as they are underneath
            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    pageView(item)
                        // Centered on the whole area, as Markup's canvas is (a page keeps the
                        // screen's safe areas otherwise, which put it 14 pt lower)
                        .ignoresSafeArea()
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .modifier(ImageArea(insets: imageInsets, keyboard: noteFocused))
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDrag)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            }
            .opacity(marking == nil ? 1 : 0)
            .allowsHitTesting(marking == nil)

            if let state = marking, let image = items.first(where: { $0.id == state.itemId })?.image {
                ImageMarkupView(image: image, state: markingBinding)
                    .id(state.itemId)
                    .modifier(ImageArea(insets: imageInsets, keyboard: noteFocused))
            }

            // With the note's keyboard up, a tap on the image puts it away
            if noteFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { noteFocused = false }
            }

            if showChrome || marking != nil {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showChrome && marking == nil)
        .onChange(of: noteFocused) { _, focused in
            withAnimation(Self.foldAnimation) { noteUp = focused }
        }

        .onAppear {
            page = content?.selection ?? 0
            for item in items { flatten(item.id) }
        }
        // Images that arrive while it's open are added after; the page stays where it is
        .onChange(of: page) { _, _ in isZoomed = false }
    }

    /// The whole screen, but while the note has the keyboard, between the bars above it
    private var imageInsets: EdgeInsets {
        noteFocused ? EdgeInsets(top: topBarBottom, leading: 0, bottom: bottomBarHeight, trailing: 0) : EdgeInsets()
    }

    /// The image (a page, or Markup) laid out the same way in both
    private struct ImageArea: ViewModifier {
        let insets: EdgeInsets
        let keyboard: Bool

        func body(content: Content) -> some View {
            content
                .padding(insets)
                // Under the keyboard, except when it's the note's: then above it, between the
                // bars (typing on the image, Markup's canvas keeps the text in view itself)
                .ignoresSafeArea(keyboard ? .container : .all)
        }
    }

    @ViewBuilder
    private func pageView(_ item: ImageViewerContent.Item) -> some View {
        if case .video(let file) = item.kind {
            VideoPage(file: file)
        } else if let image = markedImages[item.id] ?? item.image {
            ZoomableImageView(image: image, isZoomed: $isZoomed)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(item.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(item.error ?? "Could not load image")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding()
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            Group {
                if marking != nil { markupTopBar } else { topBar }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.8))
            .environment(\.colorScheme, .dark)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }

            Spacer()

            bottomBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
        }
        // On the note's keyboard, in step with it (iOS moves it); typing on the image, under it
        .ignoresSafeArea(noteFocused ? [] : .keyboard)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button("Done") { close() }
                .fontWeight(.semibold)
                .frame(minWidth: 60, alignment: .leading)

            Spacer()

            VStack(spacing: 2) {
                Text(shownItem?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            HStack(spacing: 20) {
                if let item = shownItem, item.image != nil {
                    Button { save(item) } label: {
                        Image(systemName: saved.contains(item.id) ? "checkmark"
                            : saveFailed.contains(item.id) ? "exclamationmark.triangle" : "square.and.arrow.down")
                    }
                    .disabled(saved.contains(item.id))
                }
                if let item = shownItem, let image = item.image {
                    if case .video(let file) = item.kind {
                        ShareLink(item: file, preview: SharePreview(item.name, image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview(item.name, image: Image(uiImage: image))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                if let item = shownItem, item.kind == .still, item.image != nil {
                    Button { startMarking(item) } label: { Image(systemName: "pencil.tip.crop.circle") }
                        .accessibilityLabel("Markup")
                }
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
    }

    /// Markup's: Cancel puts the marks back, Done keeps them
    private var markupTopBar: some View {
        HStack {
            Button("Cancel") { cancelMarking() }
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Text(items.first { $0.id == marking?.itemId }?.name ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Done") { endMarking() }
                .fontWeight(.semibold)
                .frame(minWidth: 60, alignment: .trailing)
        }
        // As tall as the viewer's, so the image doesn't move under it
        .frame(minHeight: 36)
    }

    /// Under the image: the thumbnails (with more than one), then one card with the note
    /// and Send, and Markup's tools above them while marking up. Typing a note, the tools
    /// and thumbnails fold away as the keyboard comes up; going into Markup, the card grows.
    private var bottomBar: some View {
        let item = marking.flatMap { m in items.first { $0.id == m.itemId } } ?? shownItem
        let note = send != nil && item.map(sendable) == true
        return VStack(spacing: 10) {
            if items.count > 1, !noteUp {
                thumbnails { index in
                    if marking != nil {
                        turnMarking(to: index)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { page = index }
                    }
                }
                .transition(.opacity)
            }
            if note || marking != nil {
                // The tools fold up into the card, rather than coming and going: a row fading
                // out where it was sat over the note as the card shrank under it
                let folded = marking == nil || noteUp
                VStack(spacing: 0) {
                    ImageMarkupTools(state: markingBinding)
                        .padding(.bottom, 4)
                        .frame(height: folded ? 0 : 44, alignment: .top)
                        .clipped()
                        .opacity(folded ? 0 : 1)
                        .allowsHitTesting(!folded)
                    if note, let item {
                        noteRow(item)
                    }
                }
                .padding(6)
                .glass(in: .rect(cornerRadius: 26))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.25), value: marking != nil)
        .environment(\.colorScheme, .dark)
    }

    /// The note on an image, and Send
    private func noteRow(_ item: ImageViewerContent.Item) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Note on this image", text: drafts.noteBinding(item.id), axis: .vertical)
                .lineLimit(1...4)
                .focused($noteFocused)
                .padding(.leading, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { sendAll() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())
            }
            .padding(2)
            .accessibilityLabel(sendLabel)
        }
    }

    /// A thumbnail per image, the shown one outlined; a dot on those Send will take
    private func thumbnails(_ pick: @escaping (Int) -> Void) -> some View {
        let current = marking.flatMap { m in items.firstIndex { $0.id == m.itemId } } ?? page
        return ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { pick(index) } label: {
                            thumbnail(item, selected: index == current)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: CGFloat(items.count) * 58 + 8)
            .onChange(of: current) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation { scroller.scrollTo(items[index].id, anchor: .center) }
            }
        }
    }

    private func thumbnail(_ item: ImageViewerContent.Item, selected: Bool) -> some View {
        Group {
            if let image = markedImages[item.id] ?? item.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: 50, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
        .opacity(selected ? 1 : 0.6)
        .overlay(alignment: .topTrailing) {
            if drafts.touched(item.id) {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .frame(width: 9, height: 9)
                    .offset(x: 3, y: -3)
            }
        }
    }

    // MARK: Markup

    private var markingBinding: Binding<MarkupState> {
        Binding {
            marking ?? MarkupState(itemId: UUID())
        } set: { state in
            marking = state
            drafts.marks[state.itemId] = state.marks
        }
    }

    private func startMarking(_ item: ImageViewerContent.Item, tool: MarkupState.Tool = .pen, color: Color = .red) {
        noteFocused = false
        isZoomed = false
        marksBefore = drafts.marks[item.id] ?? []
        marking = MarkupState(itemId: item.id, marks: marksBefore, tool: tool, color: color)
    }

    /// The image's marks drawn on it, for showing it out of Markup
    private func flatten(_ id: UUID) {
        let marks = drafts.marks[id] ?? []
        guard !marks.isEmpty, let image = items.first(where: { $0.id == id })?.image else {
            markedImages[id] = nil
            return
        }
        markedImages[id] = Mark.render(image, marks: marks)
    }

    /// Out of Markup, the marks kept (the text being typed too)
    private func endMarking() {
        guard var state = marking else { return }
        state.commitTyping()
        drafts.marks[state.itemId] = state.marks
        flatten(state.itemId)
        marking = nil
        showChrome = true
    }

    /// Out of Markup, the image's marks as they were when it started
    private func cancelMarking() {
        guard let state = marking else { return }
        drafts.marks[state.itemId] = marksBefore
        flatten(state.itemId)
        marking = nil
        showChrome = true
    }

    /// Markup goes on with another image, with the same tool and color; the page follows
    private func turnMarking(to index: Int) {
        guard let state = marking, items.indices.contains(index) else { return }
        let item = items[index]
        guard item.id != state.itemId else { return }
        var done = state
        done.commitTyping()
        drafts.marks[done.itemId] = done.marks
        flatten(done.itemId)
        page = index
        if sendable(item) {
            marksBefore = drafts.marks[item.id] ?? []
            marking = MarkupState(itemId: item.id, marks: marksBefore, tool: state.tool, color: state.color)
        } else {
            marking = nil
        }
    }

    // MARK: Send

    /// Stills, the only images marks and notes go on
    private func sendable(_ item: ImageViewerContent.Item) -> Bool {
        item.kind == .still && item.image != nil
    }

    /// What Send sends: every still with marks or a note, in order, else the one shown
    private var outgoing: [ImageViewerContent.Item] {
        let touched = items.filter { sendable($0) && drafts.touched($0.id) }
        if !touched.isEmpty { return touched }
        return shownItem.map { sendable($0) ? [$0] : [] } ?? []
    }

    private var sendLabel: String {
        let count = outgoing.count
        return count > 1 ? "Send \(count) images to Claude" : "Send to Claude"
    }

    private func sendAll() {
        guard let send else { return }
        // Sent from Markup: its marks as they are, the text being typed too
        if marking != nil { endMarking() }
        let batch = outgoing.compactMap { item -> (image: PlatformImage, note: String)? in
            guard let image = item.image else { return nil }
            let marks = drafts.marks[item.id] ?? []
            guard let shown = marks.isEmpty ? image : Mark.render(image, marks: marks) else { return nil }
            return (shown, drafts.note(item.id))
        }
        guard !batch.isEmpty else { return }
        for item in outgoing { drafts.forget(item.id) }
        noteFocused = false
        send(batch)
        close()
    }

    private var subtitle: String {
        guard let host = content?.host else { return "" }
        return items.count > 1 ? "\(host) · \(page + 1) of \(items.count)" : host
    }

    /// Drag down (when not zoomed) to close
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isZoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed else { return }
                if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        content = nil
    }

    /// Add the image to Photos (agent mode clears images once they've been viewed)
    private func save(_ item: ImageViewerContent.Item) {
        guard let image = item.image else { return }
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            do {
                guard status == .authorized || status == .limited else { throw CocoaError(.userCancelled) }
                try await PHPhotoLibrary.shared().performChanges {
                    switch item.kind {
                    case .still:
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    case .animated(let gif):
                        // As a GIF, so it still plays in Photos
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: gif, options: nil)
                    case .video(let file):
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                    }
                }
                saved.insert(item.id)
                saveFailed.remove(item.id)
                Haptic.saved.play()
            } catch {
                saveFailed.insert(item.id)
                Logger.clauntty.warning("ImageViewer: couldn't save \(item.name) to Photos: \(error.localizedDescription)")
            }
        }
    }
}

/// A video with the system's controls, muted at first, paused when paged away
private struct VideoPage: View {
    let file: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let player = AVPlayer(url: file)
                player.isMuted = true
                player.play()
                self.player = player
            }
            .onDisappear { player?.pause() }
    }
}

/// UIScrollView-backed image with pinch and double-tap zoom
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
        // Paging away resets zoom
        if !isZoomed && scrollView.zoomScale != 1 {
            scrollView.setZoomScale(1, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var imageView: UIImageView?

        init(parent: ZoomableImageView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let zoomed = scale > 1.01
            if parent.isZoomed != zoomed {
                parent.isZoomed = zoomed
            }
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                // Zoom in around the tapped point
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 3
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
