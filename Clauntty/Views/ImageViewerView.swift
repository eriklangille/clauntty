import os
import AVKit
import Photos
import SwiftUI
import UIKit

/// Full-screen viewer: swipe between images, pinch or double-tap to zoom, swipe down
/// or tap Done to close
struct ImageViewerView: View {
    @Binding var content: ImageViewerContent?

    @State private var page = 0
    @State private var isZoomed = false
    @State private var showChrome = true
    @State private var dragOffset: CGFloat = 0
    /// Images saved to Photos, and ones that couldn't be (no access)
    @State private var saved: Set<UUID> = []
    @State private var saveFailed: Set<UUID> = []

    private var items: [ImageViewerContent.Item] { content?.items ?? [] }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(abs(dragOffset) / 400, 0.6))
                .ignoresSafeArea()

            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    pageView(item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDrag)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() } }

            if showChrome {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showChrome)
        .onAppear { page = content?.selection ?? 0 }
        .onChange(of: content?.selection) { _, selection in
            if let selection { withAnimation { page = selection } }
        }
        .onChange(of: page) { _, _ in isZoomed = false }
    }

    @ViewBuilder
    private func pageView(_ item: ImageViewerContent.Item) -> some View {
        if case .video(let file) = item.kind {
            VideoPage(file: file)
        } else if let image = item.image {
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
        VStack {
            HStack(alignment: .center) {
                Button("Done") { close() }
                    .fontWeight(.semibold)
                    .frame(minWidth: 60, alignment: .leading)

                Spacer()

                VStack(spacing: 2) {
                    Text(items.indices.contains(page) ? items[page].name : "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                HStack(spacing: 20) {
                    if items.indices.contains(page), items[page].image != nil {
                        let item = items[page]
                        Button { save(item) } label: {
                            Image(systemName: saved.contains(item.id) ? "checkmark"
                                : saveFailed.contains(item.id) ? "exclamationmark.triangle" : "square.and.arrow.down")
                        }
                        .disabled(saved.contains(item.id))
                    }
                    if items.indices.contains(page), let image = items[page].image {
                        if case .video(let file) = items[page].kind {
                            ShareLink(item: file, preview: SharePreview(items[page].name, image: Image(uiImage: image))) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        } else {
                            ShareLink(
                                item: Image(uiImage: image),
                                preview: SharePreview(items[page].name, image: Image(uiImage: image))
                            ) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .frame(minWidth: 60, alignment: .trailing)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.8))
            .environment(\.colorScheme, .dark)

            Spacer()
        }
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
