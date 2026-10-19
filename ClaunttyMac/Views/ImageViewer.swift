import AppKit
import SwiftUI

/// Images from `clauntty show`, over the whole window: one at a time, arrows (or the
/// arrow keys) page through them, Esc or a click outside closes. Images that arrive
/// while it's open are added, and it moves to the first of them.
struct ImageViewer: View {
    @Binding var content: ImageViewerContent?
    @State private var page = 0
    @FocusState private var focused: Bool

    var body: some View {
        if let content, !content.items.isEmpty {
            let items = content.items
            let index = min(page, items.count - 1)
            let item = items[index]
            ZStack {
                Color.black.opacity(0.85)
                    .onTapGesture { self.content = nil }
                VStack(spacing: 14) {
                    header(item, host: content.host, index: index, count: items.count)
                    Group {
                        if let image = item.image {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                // No bigger than the image itself
                                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        } else {
                            Label(item.error ?? "Can't show this image", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if items.count > 1 {
                        pager(index: index, count: items.count)
                    }
                }
                .padding(24)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { turn(-1, count: items.count); return .handled }
            .onKeyPress(.rightArrow) { turn(1, count: items.count); return .handled }
            .onKeyPress(.escape) { self.content = nil; return .handled }
            .onAppear {
                page = content.selection
                // After the terminal has let go of the keyboard
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: content.selection) { _, selection in page = selection }
        }
    }

    private func header(_ item: ImageViewerContent.Item, host: String, index: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(count > 1 ? "\(host) · \(index + 1) of \(count)" : host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let image = item.image {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Button("Close", systemImage: "xmark") { self.content = nil }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 640)
    }

    private func pager(index: Int, count: Int) -> some View {
        HStack(spacing: 16) {
            Button { turn(-1, count: count) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Button { turn(1, count: count) } label: { Image(systemName: "chevron.right") }
                .disabled(index == count - 1)
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func turn(_ offset: Int, count: Int) {
        page = min(max(page + offset, 0), count - 1)
    }
}
