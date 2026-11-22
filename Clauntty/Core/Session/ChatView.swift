import SwiftUI
import UniformTypeIdentifiers
import os

/// A chat pane's conversation, drawn over its (hidden) terminal in the terminal's colours:
/// the user's messages on the right, Claude's replies as text, each tool call one quiet
/// line that opens on a tap, and what Claude is waiting for (an approval, a question)
/// at the end of the conversation, with the box to type in under it.
struct ChatView: View {
    @ObservedObject var chat: ChatSession
    let colors: ReviewColors
    /// Room the window's pill takes at the top
    var topInset: CGFloat = 0
    /// Typing here: the box is live (in the overview it's only a picture). On the Mac,
    /// the focused pane: its box has the keyboard.
    var isActive = true
    /// Text size: the focused window is smaller than fullscreen, so its text is too
    var type = ChatType.standard

    @State private var draft = ""
    /// Images and files to send with the next message (pasted or dropped)
    @State private var attachments: [Attachment] = []
    #if os(iOS)
    /// The box has the keyboard (a UIKit text view on the phone: `ChatTextView`)
    @State private var typing = false
    #else
    @FocusState private var typing: Bool
    #endif
    @State private var openTools: Set<String> = []
    @State private var picked: [String: Set<String>] = [:]
    /// At the end of the conversation, so it stays there as it grows
    @State private var pinned = true
    #if os(iOS)
    /// Dictating into the box: its edge glows blue with the voice
    @State private var recording = false
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { listContent }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                // A wide pane (the Mac, an iPad) keeps lines a readable length
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
            }
            // Below the window's pill, so text doesn't scroll up under it
            .padding(.top, topInset)
            .modifier(StickToBottom())
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: chat.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: chat.pending) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Following the end as the reply grows (and as a replay fills in), until the
            // user scrolls up; back at the end, it follows again
            .modifier(FollowEnd(pinned: $pinned) { settle(proxy) })
            .modifier(BlankWatch(chat: chat))
            .onChange(of: tail) { _, _ in settle(proxy) }
            .task { settle(proxy) }
        }

        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.takesImages else { return false }
            Self.loadImages(providers) { attach($0) }
            #if os(macOS)
            Self.loadFiles(providers) { attach(files: $0) }
            #endif
            return true
        }
        #if os(macOS)
        // ⌘V with an image or a file: the text field would take only text
        .modifier(PasteImages(enabled: isActive && chat.takesImages) { attach($0) } files: { attach(files: $0) })
        #endif
        .environment(\.chatType, type)
        .background(colors.bg)
        .animation(.easeOut(duration: 0.2), value: chat.pending)
        .animation(.easeOut(duration: 0.2), value: chat.working)
        .onChange(of: chat.focusRequest) { _, _ in typing = true }
        #if os(macOS)
        // The focused pane's chat has the keyboard, as its terminal would
        .onChange(of: isActive, initial: true) { _, active in if active { typing = true } }
        // A new chat's pane was a terminal a moment ago, which took the keyboard as it came
        // on screen (after this, maybe): once it's settled, the box takes it back
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            if isActive { typing = true }
        }
        #endif
    }

    @ViewBuilder
    private var listContent: some View {
                    if chat.loadingHistory && chat.history.isEmpty {
                        ProgressView().tint(colors.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    let items = chat.items
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .padding(.top, spacing(before: index, in: items))
                    }
                    if let pending = chat.pending {
                        PendingView(pending: pending, colors: colors, picked: $picked, chat: chat)
                            .padding(.top, 18)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if chat.working {
                        WorkingRow(label: chat.compacting ? "Compacting the conversation" : chat.thinking ? "Thinking" : "Working",
                                   colors: colors)
                            .padding(.top, 16)
                    }
                    if !chat.queued.isEmpty {
                        QueuedMessages(items: chat.queued, colors: colors) { item in row(item) } sendNow: {
                            chat.interrupt()
                        }
                        .padding(.top, 18)
                    }
                    Color.clear.frame(height: 12).id("end")
                    }

    /// Tool calls in a run sit close together; everything else gets room
    private func spacing(before index: Int, in items: [ChatSession.Item]) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (items[index - 1], items[index]) {
        case (.tool, .tool): return 2
        case (.user, _), (_, .user): return 22
        case (.tool, _), (_, .tool): return 12
        default: return 14
        }
    }

    /// A row of the conversation: equatable, so a streamed word redraws the reply it went
    /// into, not every row
    private func row(_ item: ChatSession.Item) -> some View {
        var actions = ChatRow.Actions()
        var isOpen = false, asking = false
        var images: [PlatformImage] = []
        switch item {
        case .user(let id, _, let count) where count > 0:
            images = chat.sentImages[id] ?? []
            actions.loadImages = { [chat] in await chat.loadImages(for: id) }
        case .tool(let tool):
            isOpen = openTools.contains(tool.id)
            // Waiting on the user, it hasn't started: no time, nothing to background
            asking = chat.pendingToolUseId == tool.id
            if tool.name == "Bash", !tool.done, !asking {
                actions.background = { [chat] in chat.runInBackground(tool.id) }
            }
            actions.toggle = {
                withAnimation(.easeOut(duration: 0.18)) {
                    if openTools.contains(tool.id) { openTools.remove(tool.id) } else { openTools.insert(tool.id) }
                }
            }
        default:
            break
        }
        return ChatRow(item: item, colors: colors, isOpen: isOpen, asking: asking, images: images, actions: actions)
            .equatable()
    }

    @State private var settling: Task<Void, Never>?
    /// A settle was asked for while one ran
    @State private var resettle = false

    /// To the end, if that's where the user is: on the next turn of the run loop (the new
    /// rows aren't laid out yet), and again once the lazy rows have their real heights
    /// One at a time: a streaming reply asks on every word, and each scrolled twice. One
    /// asked meanwhile runs after it, so the last change (a window's animation ending)
    /// always gets its scroll.
    private func settle(_ proxy: ScrollViewProxy) {
        guard pinned else { return }
        if settling != nil {
            resettle = true
            return
        }
        settling = Task { @MainActor in
            for delay in [0, 120, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard pinned else { break }
                proxy.scrollTo("end", anchor: .bottom)
            }
            settling = nil
            if resettle {
                resettle = false
                settle(proxy)
            }
        }
    }

    /// Changes as the conversation grows: a row more, or the last reply longer
    private var tail: Int {
        let items = chat.items
        var length = 0
        if case .reply(_, let text, _) = items.last { length = text.utf8.count }
        return items.count &* 1_000_003 &+ length &+ (chat.pending == nil ? 0 : 1) &+ (chat.working ? 2 : 0)
    }

    /// The conversation's widest
    static let column: CGFloat = 760

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func attach(_ images: [PlatformImage]) {
        withAnimation(.easeOut(duration: 0.15)) {
            attachments += images.map { Attachment(image: $0) }
        }
        typing = true
    }

    private func attach(files: [URL]) {
        withAnimation(.easeOut(duration: 0.15)) {
            attachments += files.map { Attachment(file: $0) }
        }
        typing = true
    }

    private var inputBar: some View {
        // Text across the top, a row of controls under it; one inset all round
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments, colors: colors)
            }
            textField
            controls
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, Self.inset)
        .padding(.bottom, Self.inset - 4)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #if os(iOS)
        .overlay { RecordingEdge(recording: recording) }
        #endif
        .frame(maxWidth: Self.column - 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
        // The conversation fades out behind the box, not peeking out under it
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [colors.bg.opacity(0), colors.bg], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                colors.bg
            }
            .allowsHitTesting(false)
        }
        #if os(iOS)
        .allowsHitTesting(isActive)
        #endif
    }

    /// The box's inset on every side
    static let inset: CGFloat = 14

    private var textField: some View {
        Group {
        #if os(iOS)
        // SwiftUI's field pastes only text; this one takes an image too
        ChatTextView(text: $draft, focused: $typing, placeholder: "Message Claude",
                     size: type.size, colors: colors, submit: send,
                     pasteImages: { if chat.takesImages { attach($0) } })
        #else
        TextField("Message Claude", text: $draft, axis: .vertical)
            .font(type.body)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .focused($typing)
            .foregroundStyle(colors.fg)
            .tint(colors.fg)
            .onSubmit(send)
            .newlineKeys(text: $draft, submit: send)
            // Shift+Tab goes through the permission modes, as in the terminal. AppKit
            // sends it as backtab (U+0019); left alone, it moves the keyboard out of the box.
            // Esc stops Claude, as in Claude Code. Asking for approval, Esc is Deny
            // (the approval's own shortcut), so it's left to that.
            .onKeyPress(.escape, phases: .down) { _ in
                guard chat.pending == nil, chat.working else { return .ignored }
                chat.interrupt()
                return .handled
            }
            // ⌃B: running commands go to the background, as in Claude Code
            .onKeyPress(keys: ["b"], phases: .down) { press in
                guard press.modifiers == .control, chat.hasForegroundCommand else { return .ignored }
                chat.runInBackground()
                return .handled
            }
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                guard press.key == KeyEquivalent("\u{19}") || press.modifiers.contains(.shift),
                      chat.permissionMode != nil else { return .ignored }
                chat.nextPermissionMode()
                return .handled
            }
        #endif
        }
    }

    /// Under the text: the permission mode on the left; on the right how full the context
    /// is (from half the auto-compact point), the model, the mic (phone) and send/stop, all
    /// centred on the button. No separators: spacing and weight tell them apart.
    private var controls: some View {
        HStack(spacing: 12) {
            if let mode = chat.permissionMode {
                ModeMenu(mode: mode, colors: colors, size: type.size) { chat.setPermissionMode($0) }
            }
            Spacer(minLength: 8)
            if let context = chat.context, context.fraction >= ContextLabel.shownFrom {
                ContextLabel(context: context, colors: colors, size: type.size)
            }
            if let model = chat.model.flatMap(ChatView.modelName) {
                Text(model)
                    .font(.system(size: type.size - 4))
                    .foregroundStyle(colors.faint)
                    .lineLimit(1)
                    .fixedSize()
            }
            #if os(iOS)
            DictationButton(text: $draft, recording: $recording, colors: colors,
                            offersDownload: true, size: type.size)
            #endif
            Button {
                if canSend { send() } else if chat.working { chat.interrupt() }
            } label: {
                Image(systemName: canSend || !chat.working ? "arrow.up" : "stop.fill")
                    .font(.system(size: canSend || !chat.working ? 15 : 12, weight: .bold))
                    .foregroundStyle(colors.bg)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(colors.fg.opacity(canSend || chat.working ? 1 : 0.25)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !chat.working)
            #if os(macOS)
            .help(chat.working && !canSend ? "Stop (Esc)" : "Send (Return)")
            #endif
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5" (a date or "[1m]" after it left off)
    static func modelName(_ id: String) -> String? {
        var parts = id.replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && $0.allSatisfy(\.isNumber) }
        guard let family = parts.first, !family.isEmpty else { return nil }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    private func send() {
        // Return in an empty box with a message waiting: interrupt, so it goes now
        // (Claude Code's "enter to interrupt and send")
        guard canSend else {
            if !chat.queued.isEmpty { chat.interrupt() }
            return
        }
        chat.send(draft, images: attachments.compactMap(\.image), files: attachments.compactMap(\.file))
        draft = ""
        attachments = []
        // On the Mac, Return ends the field's editing: stay in it for the next message
        typing = true
    }
}

/// An image going with the next message, or a file (uploaded whole, its path sent)
struct Attachment: Identifiable {
    let id = UUID()
    var image: PlatformImage?
    var file: URL?
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension ChatView {
    /// Dropped images: image files, or image data (from Photos, a browser)
    static func loadImages(_ providers: [NSItemProvider], then done: @escaping @MainActor ([PlatformImage]) -> Void) {
        Task { @MainActor in
            var images: [PlatformImage] = []
            for provider in providers {
                if let image = await loadImage(provider) { images.append(image) }
            }
            if !images.isEmpty { done(images) }
        }
    }

    #if os(macOS)
    /// Dropped files that aren't images (or folders): those go whole, as their paths
    static func loadFiles(_ providers: [NSItemProvider], then done: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var files: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                }
                let values = try? url?.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
                if let url, values?.isDirectory != true, values?.contentType?.conforms(to: .image) != true {
                    files.append(url)
                }
            }
            if !files.isEmpty { done(files) }
        }
    }
    #endif

    private static func loadImage(_ provider: NSItemProvider) async -> PlatformImage? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            guard let url, (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true,
                  let data = try? Data(contentsOf: url) else { return nil }
            return PlatformImage(data: data)
        }
        guard provider.canLoadObject(ofClass: PlatformImage.self) else { return nil }
        return await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: PlatformImage.self) { image, _ in
                done.resume(returning: image as? PlatformImage)
            }
        }
    }
}

/// How full Claude's context is, by the mode: shown from half full ("62%"), and near the
/// point Claude compacts, a warning colour and what happens ("Compacts soon · 91%")
private struct ContextLabel: View {
    static let shownFrom = 0.5
    static let warnFrom = 0.85
    let context: ChatSession.ContextUsage
    let colors: ReviewColors
    let size: CGFloat

    var body: some View {
        let percent = min(100, Int((context.fraction * 100).rounded()))
        let warn = context.fraction >= Self.warnFrom
        // Orange near the point Claude compacts; the tooltip (Mac) says what that means
        Text("\(percent)% context")
            .font(.system(size: size - 4).monospacedDigit())
            .foregroundStyle(warn ? Color.orange : colors.faint)
            .lineLimit(1)
            .fixedSize()
            #if os(macOS)
            .help(context.autoCompacts
                  ? "Context used: \(context.tokens / 1000)k of \(context.limit / 1000)k tokens. Claude compacts the conversation at 100%."
                  : "Context used: \(context.tokens / 1000)k of \(context.limit / 1000)k tokens. Auto-compact is off.")
            #endif
            .accessibilityLabel("Context \(percent) percent used")
    }
}

/// What Claude asks before it acts, in the box beside the send button: a native menu
private struct ModeMenu: View {
    let mode: String
    let colors: ReviewColors
    let size: CGFloat
    let pick: (String) -> Void

    var body: some View {
        Menu {
            Picker("Permission Mode", selection: Binding(get: { mode }, set: pick)) {
                ForEach(ChatSession.modes, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(ChatSession.label(mode: mode))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: size - 7, weight: .semibold))
            }
            .font(.system(size: size - 4))
            .foregroundStyle(colors.dim)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .help("What Claude asks before it acts (⇧Tab to change)")
        #endif
    }
}

/// The images and files waiting to go with the next message, above the text, each with
/// a button that takes it out
private struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]
    let colors: ReviewColors

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    preview(attachment)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(.black.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .help("Remove")
                        }
                }
            }
        }
    }

    /// An image as itself; a file as its icon, name and size
    @ViewBuilder
    private func preview(_ attachment: Attachment) -> some View {
        if let image = attachment.image {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56)
        } else if let file = attachment.file {
            HStack(spacing: 8) {
                #if os(macOS)
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                #else
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(colors.dim)
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(colors.dim)
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 26)
            .frame(maxHeight: .infinity)
            .background(colors.fg.opacity(0.08))
        }
    }
}

/// A sent message's images: the pictures when they were sent from here, else a tile each
private struct SentImages: View {
    let images: [PlatformImage]
    let count: Int
    let colors: ReviewColors

    var body: some View {
        HStack(spacing: 6) {
            if images.isEmpty {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.card)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(colors.dim)
                        }
                }
            } else {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: images.count == 1 ? 240 : 120, maxHeight: images.count == 1 ? 200 : 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

#if os(iOS)
/// The phone's message box: a UITextView, so Paste takes an image as well as text
/// (SwiftUI's TextField offers Paste only for text). Return sends, as the field did; it
/// grows to six lines, then scrolls.
private struct ChatTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let size: CGFloat
    let colors: ReviewColors
    let submit: () -> Void
    let pasteImages: ([PlatformImage]) -> Void

    final class Box: UITextView {
        var pasteImages: (([UIImage]) -> Void)?
        let placeholderLabel = UILabel()

        /// Only an image on the clipboard: it's added to the message
        private var imageOnly: Bool {
            let board = UIPasteboard.general
            return board.hasImages && !board.hasStrings && !board.hasURLs
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), imageOnly { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if imageOnly, let images = UIPasteboard.general.images, !images.isEmpty {
                pasteImages?(images)
            } else {
                super.paste(sender)
            }
        }
    }

    func makeUIView(context: Context) -> Box {
        let view = Box()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(view.placeholderLabel)
        NSLayoutConstraint.activate([
            view.placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            view.placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        return view
    }

    func updateUIView(_ view: Box, context: Context) {
        context.coordinator.parent = self
        view.pasteImages = pasteImages
        // Only what changed: this runs on every update of the chat (each streamed word),
        // and setting the tint again restarted the caret's blink, so it flickered
        if view.font?.pointSize != size {
            let font = UIFont.systemFont(ofSize: size)
            view.font = font
            view.placeholderLabel.font = font
        }
        if context.coordinator.color != colors.fg {
            context.coordinator.color = colors.fg
            view.textColor = UIColor(colors.fg)
            view.tintColor = UIColor(colors.fg)
            view.placeholderLabel.textColor = UIColor(colors.fg).withAlphaComponent(0.4)
        }
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        if view.placeholderLabel.isHidden != !text.isEmpty { view.placeholderLabel.isHidden = !text.isEmpty }
        // On the next turn (the view may not be in a window yet), and only once while
        // one is on its way
        if focused != view.isFirstResponder, !context.coordinator.focusing {
            context.coordinator.focusing = true
            DispatchQueue.main.async {
                context.coordinator.focusing = false
                let want = context.coordinator.parent.focused
                if want, !view.isFirstResponder { view.becomeFirstResponder() }
                if !want, view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: Box, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = view.font?.lineHeight ?? size * 1.2
        let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fit, line), (line * 6).rounded(.up))
        let scrolls = fit > height + 0.5
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatTextView
        /// The text colour last applied
        var color: Color?
        /// A first-responder change is on its way
        var focusing = false
        init(_ parent: ChatTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Return sends (a pasted newline goes in)
            guard text == "\n" else { return true }
            parent.submit()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? Box)?.placeholderLabel.isHidden = !textView.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}
#endif

#if os(macOS)
import AppKit

/// ⌘V with images on the clipboard (and no text) adds them to the message. The text
/// field's editor would take the paste and find nothing it can use.
private struct PasteImages: ViewModifier {
    let enabled: Bool
    let paste: ([PlatformImage]) -> Void
    let files: ([URL]) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: enabled) { _, _ in install() }
    }

    private func install() {
        remove()
        guard enabled else { return }
        let paste = paste, pasteFiles = files
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  // The chat's box has the keyboard, not a terminal or another field
                  NSApp.keyWindow?.firstResponder is NSTextView else { return event }
            let images = NSPasteboard.general.pastedImages(), files = NSPasteboard.general.pastedFiles()
            guard images != nil || files != nil else { return event }
            if let images { paste(images) }
            if let files { pasteFiles(files) }
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

/// One row of the conversation. Equal rows aren't redrawn: the view's whole body runs on
/// every streamed word, and without this every row on screen did too.
private struct ChatRow: View, Equatable {
    struct Actions {
        var toggle: () -> Void = {}
        var background: (() -> Void)?
        var loadImages: () async -> Void = {}
    }

    @Environment(\.chatType) private var type
    let item: ChatSession.Item
    let colors: ReviewColors
    let isOpen: Bool
    let asking: Bool
    let images: [PlatformImage]
    let actions: Actions

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.item == b.item && a.colors == b.colors && a.isOpen == b.isOpen && a.asking == b.asking
            && a.images.count == b.images.count && zip(a.images, b.images).allSatisfy { $0 === $1 }
    }

    var body: some View {
        switch item {
        case .user(let id, let text, let count):
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if count > 0 {
                        SentImages(images: images, count: count, colors: colors)
                            // Sent elsewhere, or before a restart: from the host
                            .task(id: id) { await actions.loadImages() }
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(type.body)
                            .foregroundStyle(colors.fg)
                            .textSelection(.enabled)
                            // Its full height: on the Mac a long message was cut to three
                            // lines and "…"
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        case .reply(_, let text, _):
            MarkdownText(text: text, colors: colors)
        case .tool(let tool):
            ToolRow(tool: tool, colors: colors, isOpen: isOpen, asking: asking,
                    background: actions.background, toggle: actions.toggle)
        case .note(_, let text):
            Text(text)
                .font(type.footnote)
                .foregroundStyle(colors.faint)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The chat's text sizes, all from one body size (17 is the system's body)
struct ChatType: Equatable {
    var size: CGFloat
    static let standard = ChatType(size: 17)

    var body: Font { .system(size: size) }
    var small: Font { .system(size: (size * 0.88).rounded()) }
    var footnote: Font { .system(size: (size * 0.77).rounded()) }
    var caption: Font { .system(size: (size * 0.71).rounded()) }
    var title: Font { .system(size: (size * 1.18).rounded()) }
    var code: Font { .system(size: size * 0.74, design: .monospaced) }
    var inlineCode: Font { .system(size: size * 0.86, design: .monospaced) }
}

private struct ChatTypeKey: EnvironmentKey {
    static let defaultValue = ChatType.standard
}

extension EnvironmentValues {
    var chatType: ChatType {
        get { self[ChatTypeKey.self] }
        set { self[ChatTypeKey.self] = newValue }
    }
}

#if os(iOS)
/// The box's edge while dictating: blue, brighter with the voice, as the keyboard's bar and
/// a review's box do. Watching the level here redraws only this.
private struct RecordingEdge: View {
    let recording: Bool
    @ObservedObject private var speech = SpeechManager.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 21, style: .continuous)
        let level = recording ? CGFloat(min(speech.audioLevel * 4, 1)) : 0
        let blue = Color(uiColor: .systemBlue)
        shape
            .strokeBorder(recording ? blue : .clear, lineWidth: 1 + level * 2.5)
            .shadow(color: recording ? blue.opacity(0.3 + level * 0.6) : .clear, radius: recording ? 8 + level * 12 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: level)
            .animation(.easeOut(duration: 0.15), value: recording)
    }
}
#endif

/// Whether the user has left the end: only their own scrolling changes it (the content
/// growing under a still view moves the end away too, and that shouldn't count)
private struct FollowEnd: ViewModifier {
    @Binding var pinned: Bool
    /// The view's height changed (the keyboard came or went)
    let resized: () -> Void
    @State private var dragging = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollPhaseChange { _, phase in dragging = phase == .interacting || phase == .decelerating }
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height + g.contentInsets.bottom - 40
                } action: { _, atEnd in
                    if dragging || atEnd { pinned = atEnd }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, _ in resized() }
        } else {
            content
        }
    }
}

/// Diagnosis for a chat that showed nothing though it could scroll (2026-11-15, after
/// sending, until the reply came): when the scroll view's visible part holds none of its
/// content, the geometry and the conversation go in the phone's log (`device.sh log chat:`)
private struct BlankWatch: ViewModifier {
    let chat: ChatSession
    @State private var lastNote = Date.distantPast

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: String?.self) { g in
                let top = g.contentOffset.y, bottom = top + g.containerSize.height
                // The content is laid out from 0 to contentSize; the box's room is at the end
                let blank = top > g.contentSize.height + g.contentInsets.bottom - 40 || bottom < 0
                return blank ? "offset \(Int(top)) view \(Int(g.containerSize.height)) content \(Int(g.contentSize.height)) insets \(Int(g.contentInsets.top))/\(Int(g.contentInsets.bottom))" : nil
            } action: { _, geometry in
                guard let geometry, Date().timeIntervalSince(lastNote) > 2 else { return }
                lastNote = Date()
                Logger.clauntty.debugOnly("chat: blank? \(geometry)")
                TailscaleDebugLog.note("chat: blank? \(geometry), items \(chat.items.count) (history \(chat.history.count), live \(chat.live.count)), working \(chat.working)")
            }
        } else {
            content
        }
    }
}

/// Kept at the end as the reply grows (while it's there: scrolled up to read, it stays)
private struct StickToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

// MARK: - Rows

private struct ToolRow: View {
    @Environment(\.chatType) private var type
    let tool: ChatSession.Tool
    let colors: ReviewColors
    let isOpen: Bool
    /// Claude is asking the user about it: it hasn't run yet
    var asking = false
    /// A command still running: it can go to the background
    var background: (() -> Void)?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.icon(tool.name))
                        .font(.system(size: type.size * 0.7, weight: .medium))
                        .foregroundStyle(colors.faint)
                        .frame(width: 16)
                    Text(label)
                        .font(type.small)
                        .foregroundStyle(colors.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !tool.done {
                        ProgressView().controlSize(.mini).tint(colors.faint)
                            #if os(iOS)
                            // iOS draws its spinner at one size (about 20 pt), mini or not
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            #endif
                            // Centred on the label's letters: a spinner has no baseline of
                            // its own, so its bottom sat on the text's and it hung below
                            .alignmentGuide(.firstTextBaseline) { d in
                                d[VerticalAlignment.center] + (type.size * 0.88).rounded() * 0.35
                            }
                    } else if tool.isError {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    if !tool.done, !asking, let started = tool.startedAt {
                        Elapsed(since: started, colors: colors)
                        if let background {
                            // Claude Code's Ctrl+B (also ⌃B on the Mac)
                            Button("Run in background", action: background)
                                .buttonStyle(.plain)
                                .font(type.small)
                                .foregroundStyle(colors.dim)
                                .underline()
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if !tool.detail.isEmpty {
                        CodeText(text: tool.detail, colors: colors, diff: tool.name == "Edit",
                                 language: tool.name == "Bash" ? "bash" : nil)
                    }
                    if let result = tool.result, !result.isEmpty {
                        Rectangle().fill(colors.hairline).frame(height: 1)
                        CodeText(text: Self.clip(result), colors: colors, dimmed: true)
                    }
                }
                .background(colors.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, 24)
                .padding(.bottom, 6)
            }
        }
    }

    private var label: String {
        let verb: String = {
            switch tool.name {
            case "Bash": return ""
            case "Read": return "Read "
            case "Edit": return "Edited "
            case "Write": return "Wrote "
            case "Grep", "Glob": return "Searched "
            case "WebFetch": return "Fetched "
            case "WebSearch": return "Searched the web: "
            case "AskUserQuestion": return "Asked: "
            default: return tool.name + " "
            }
        }()
        return tool.summary.isEmpty ? tool.name : verb + tool.summary
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "AskUserQuestion": return "questionmark.bubble"
        case "Task", "Agent": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    /// The first 40 lines of a long result
    static func clip(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 40 else { return text }
        return lines.prefix(40).joined(separator: "\n") + "\n… \(lines.count - 40) more lines"
    }
}

/// Monospaced text that scrolls sideways
private struct CodeText: View {
    @Environment(\.chatType) private var type
    let text: String
    let colors: ReviewColors
    var dimmed = false
    var diff = false
    /// Coloured as this language (a fence's info string: "swift", "ts", "sh")
    var language: String?
    @State private var colored: AttributedString?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if diff {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .foregroundStyle(line.hasPrefix("+ ") ? colors.plus : line.hasPrefix("- ") ? colors.minus : colors.dim)
                        }
                    }
                } else if let colored {
                    Text(colored).foregroundStyle(dimmed ? colors.dim : colors.fg)
                } else {
                    Text(text).foregroundStyle(dimmed ? colors.dim : colors.fg)
                }
            }
            .font(type.code)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .padding(10)
        }
        .task(id: language.map { $0 + "\u{0}" + text }) {
            guard let language, !diff else { colored = nil; return }
            colored = await CodeColoring.color(text, language: language, colors: colors)
        }
    }
}

/// Code in its language's colours, through the review's highlighter. Off the main thread,
/// a moment after the code stops changing (a block streaming in changes on every word),
/// and kept, so scrolling back doesn't do it again.
@MainActor
private enum CodeColoring {
    private static var cache: [String: HighlightedText] = [:]

    static func color(_ code: String, language: String, colors: ReviewColors) async -> AttributedString? {
        let key = language + "\u{0}" + code
        if let known = cache[key] { return attributed(known, colors: colors) }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return nil }
        let result = await Task.detached(priority: .userInitiated) { () -> HighlightedText? in
            guard let grammar = Highlighter.shared.grammar(forLanguage: language) else { return nil }
            return Highlighter.shared.highlight(code, grammar: grammar)
        }.value
        guard let result, !Task.isCancelled else { return nil }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        return attributed(result, colors: colors)
    }

    private static func attributed(_ text: HighlightedText, colors: ReviewColors) -> AttributedString {
        var out = AttributedString()
        for (i, line) in text.lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            for run in line {
                var piece = AttributedString(run.text)
                if let kind = run.kind, let color = colors.tokens[kind] { piece.foregroundColor = color }
                out += piece
            }
        }
        return out
    }
}

/// Copies a code block; a tick for a moment after
private struct CopyButton: View {
    let text: String
    let colors: ReviewColors
    @Environment(\.chatType) private var type
    @State private var copied = false

    var body: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: type.size * 0.72, weight: .medium))
                .foregroundStyle(copied ? colors.fg : colors.faint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy code")
    }
}

/// Claude's spark, turning while it works
private struct WorkingRow: View {
    @Environment(\.chatType) private var type
    let label: String
    let colors: ReviewColors

    var body: some View {
        HStack(spacing: 8) {
            // Still: the word moving is enough
            ClaudeLogo()
                .fill(ReviewColors.claude)
                .frame(width: 14, height: 14)
            // A light passing over the word, left to right, every 1.8 s
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let period = 1.8
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let x = -0.4 + phase * 1.8
                Text(label)
                    .font(type.small)
                    .foregroundStyle(LinearGradient(colors: [colors.faint, colors.fg, colors.faint],
                                                    startPoint: UnitPoint(x: x - 0.35, y: 0.5),
                                                    endPoint: UnitPoint(x: x + 0.35, y: 0.5)))
            }
            #if os(macOS)
            // As Claude Code puts it beside its spinner
            Text("esc to interrupt")
                .font(type.footnote)
                .foregroundStyle(colors.faint)
                .padding(.leading, 6)
            #endif
        }
    }
}

/// Messages waiting for Claude's turn to end, dimmed under the conversation, and the way
/// to send them now
private struct QueuedMessages<Row: View>: View {
    @Environment(\.chatType) private var type
    let items: [ChatSession.Item]
    let colors: ReviewColors
    @ViewBuilder let row: (ChatSession.Item) -> Row
    let sendNow: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(items) { item in
                row(item).opacity(0.55)
            }
            HStack(spacing: 6) {
                Text("Sends when Claude finishes ·")
                    .foregroundStyle(colors.faint)
                Button("Send now", action: sendNow)
                    .buttonStyle(.plain)
                    .foregroundStyle(colors.dim)
                    .underline()
                    #if os(macOS)
                    .help("Interrupt Claude and send it (Return in the empty box)")
                    #endif
            }
            .font(type.small)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// How long a running tool has run, counting up as Claude Code does: nothing for the first
/// two seconds, then "5s", "1m 5s"
private struct Elapsed: View {
    @Environment(\.chatType) private var type
    let since: Date
    let colors: ReviewColors

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            if seconds >= 2 {
                Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")
                    .font(type.small.monospacedDigit())
                    .foregroundStyle(colors.faint)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Waiting for the user

private struct PendingView: View {
    @Environment(\.chatType) private var type
    let pending: ChatSession.Pending
    let colors: ReviewColors
    @Binding var picked: [String: Set<String>]
    let chat: ChatSession

    var body: some View {
        switch pending {
        case .approval(let approval): approvalView(approval)
        case .question(let question): questionView(question)
        }
    }

    private func approvalView(_ a: ChatSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ClaudeLogo().fill(ReviewColors.claude).frame(width: 12, height: 12)
                Text(Self.ask(a))
                    .font(type.small.weight(.medium))
                    .foregroundStyle(colors.fg)
            }
            if !a.detail.isEmpty {
                CodeText(text: a.detail, colors: colors, diff: a.toolName == "Edit",
                         language: a.toolName == "Bash" ? "bash" : nil)
                    .frame(maxHeight: 220)
                    .background(colors.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            #if os(macOS)
            macApprovalButtons(a)
            #else
            HStack(spacing: 10) {
                Button("Deny") { chat.deny() }
                    .buttonStyle(QuietButton(colors: colors))
                if let always = a.suggestions.first, let rule = always.ruleLabel {
                    Menu {
                        Button("Allow once") { chat.allow() }
                        Button("Always allow \(rule)") { chat.allow(always: always) }
                    } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    } primaryAction: {
                        chat.allow()
                    }
                    .buttonStyle(PrimaryButton(colors: colors))
                } else {
                    Button { chat.allow() } label: { Text("Allow").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButton(colors: colors))
                }
            }
            if a.suggestions.first?.ruleLabel != nil {
                Text("Hold Allow to always allow it")
                    .font(type.caption)
                    .foregroundStyle(colors.faint)
            }
            #endif
        }
    }

    #if os(macOS)
    /// As a Mac dialog's: native buttons on the right, Allow the default. ⌘Return allows and
    /// Esc denies, with the cursor in the message box or not (plain Return is the box's).
    private func macApprovalButtons(_ a: ChatSession.Approval) -> some View {
        HStack(spacing: 8) {
            if let always = a.suggestions.first, let rule = always.ruleLabel {
                Button("Always Allow \(rule)") { chat.allow(always: always) }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Allow this, and from now on \(rule) without asking")
            }
            Spacer(minLength: 8)
            Button("Deny") { chat.deny() }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Deny (Esc)")
            Button("Allow") { chat.allow() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Allow (⌘Return)")
        }
        .controlSize(.large)
    }
    #endif

    private static func ask(_ a: ChatSession.Approval) -> String {
        switch a.toolName {
        case "Bash": return a.summary.isEmpty ? "Run this command?" : "\(a.summary)?"
        case "Edit": return "Edit \(a.summary)?"
        case "Write": return "Write \(a.summary)?"
        case "WebFetch": return "Fetch \(a.summary)?"
        default: return a.summary.isEmpty ? "Use \(a.toolName)?" : "\(a.toolName): \(a.summary)?"
        }
    }

    private func questionView(_ q: ChatSession.Question) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(q.entries, id: \.question) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ClaudeLogo().fill(ReviewColors.claude).frame(width: 12, height: 12)
                        Text(entry.question)
                            .font(type.body.weight(.medium))
                            .foregroundStyle(colors.fg)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(entry.options.enumerated()), id: \.offset) { i, option in
                            if i > 0 { Rectangle().fill(colors.hairline).frame(height: 1).padding(.leading, 14) }
                            optionRow(option, entry: entry, question: q)
                        }
                    }
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            #if os(macOS)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Skip") { chat.deny() }
                    .keyboardShortcut(.escape, modifiers: [])
                if needsSend(q) {
                    Button("Send") { send(q) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!q.entries.allSatisfy { !(picked[$0.question] ?? []).isEmpty })
                }
            }
            .controlSize(.large)
            #else
            if needsSend(q) {
                Button { send(q) } label: { Text("Send").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton(colors: colors))
                    .disabled(!q.entries.allSatisfy { !(picked[$0.question] ?? []).isEmpty })
            }
            Button("Skip") { chat.deny() }
                .font(type.small)
                .foregroundStyle(colors.dim)
                .frame(maxWidth: .infinity)
            #endif
        }
    }

    /// One single-choice question answers on a tap; anything more needs Send
    private func needsSend(_ q: ChatSession.Question) -> Bool {
        q.entries.count > 1 || q.entries.contains { $0.multiSelect }
    }

    private func optionRow(_ option: ChatSession.Question.Option, entry: ChatSession.Question.Entry, question: ChatSession.Question) -> some View {
        let isPicked = picked[entry.question]?.contains(option.label) == true
        return Button {
            var set = picked[entry.question] ?? []
            if entry.multiSelect {
                if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
            }
            picked[entry.question] = set
            if !needsSend(question) { send(question) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(type.body)
                        .foregroundStyle(colors.fg)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(type.footnote)
                            .foregroundStyle(colors.dim)
                    }
                }
                Spacer(minLength: 0)
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.system(size: type.size * 0.76, weight: .semibold))
                        .foregroundStyle(colors.fg)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func send(_ q: ChatSession.Question) {
        var answers: [String: String] = [:]
        for entry in q.entries {
            let labels = entry.options.map(\.label).filter { picked[entry.question]?.contains($0) == true }
            if !labels.isEmpty { answers[entry.question] = labels.joined(separator: ", ") }
        }
        picked = [:]
        chat.answer(answers)
    }
}

private struct PrimaryButton: ButtonStyle {
    let colors: ReviewColors
    @Environment(\.chatType) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.small.weight(.semibold))
            .foregroundStyle(colors.bg)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(colors.fg.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuietButton: ButtonStyle {
    let colors: ReviewColors
    @Environment(\.chatType) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.small.weight(.medium))
            .foregroundStyle(colors.fg)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(colors.card.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Markdown

/// Claude's markdown as native text: paragraphs, headings, lists, quotes, code blocks
/// and tables; inline styles (bold, code, links) through AttributedString
struct MarkdownText: View {
    @Environment(\.chatType) private var type
    let text: String
    let colors: ReviewColors

    /// Parsed once per text: a reply is drawn again whenever its row comes back on screen
    @MainActor private static var parsed: [String: [MarkdownBlock]] = [:]

    @MainActor static func blocks(_ text: String) -> [MarkdownBlock] {
        if let blocks = parsed[text] { return blocks }
        let blocks = MarkdownBlock.parse(text)
        // A streaming reply leaves one entry per word: start over now and then
        if parsed.count > 400 { parsed.removeAll(keepingCapacity: true) }
        parsed[text] = blocks
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s).font(type.body).foregroundStyle(colors.fg)
        case .heading(let level, let s):
            inline(s)
                .font(level <= 1 ? type.title.weight(.semibold) : level == 2 ? type.body.weight(.semibold) : type.small.weight(.semibold))
                .foregroundStyle(colors.fg)
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(type.body.monospacedDigit())
                            .foregroundStyle(colors.dim)
                            .frame(minWidth: 12, alignment: .trailing)
                        inline(item.text).font(type.body).foregroundStyle(colors.fg)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let s):
            inline(s).font(type.body).italic().foregroundStyle(colors.dim).padding(.leading, 14)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(language)
                        .font(type.caption)
                        .foregroundStyle(colors.faint)
                    Spacer(minLength: 0)
                    CopyButton(text: code, colors: colors)
                }
                .padding(.leading, 10)
                .padding(.top, 2)
                CodeText(text: code, colors: colors, language: language.isEmpty ? nil : language)
                    .padding(.top, -8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let rows):
            CodeText(text: rows, colors: colors)
                .background(colors.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Rectangle().fill(colors.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = type.inlineCode
            attributed[run.range].backgroundColor = colors.card
        }
        return Text(attributed)
    }
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable {
        let marker: String
        let text: String
        let indent: Int
    }
    case paragraph(String)
    case heading(Int, String)
    case list([Item])
    case quote(String)
    case code(String, String)
    case table(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [Item] = []
        var quote: [String] = []
        var table: [String] = []
        var code: (language: String, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(tidyTable(table))); table = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.language, open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); blocks.append(.rule); continue }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
               trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if list.isEmpty { flush() }
                list.append(Item(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                if list.isEmpty { flush() }
                list.append(Item(marker: String(trimmed[...dot]), text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]), indent: indent))
                continue
            }
            // A continuation line of a list item
            if !list.isEmpty, line.hasPrefix("  ") {
                let last = list.removeLast()
                list.append(Item(marker: last.marker, text: last.text + " " + trimmed, indent: last.indent))
                continue
            }
            if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
        }
        // A reply still streaming can end inside a code block
        if let open = code { flush(); blocks.append(.code(open.language, open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// A markdown table with its columns lined up, the separator row as a line
    private static func tidyTable(_ rows: [String]) -> String {
        let cells = rows.map { row -> [String] in
            var r = row.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "") }
        }
        let isRule: ([String]) -> Bool = { $0.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } } }
        let columns = cells.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columns)
        for row in cells where !isRule(row) {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        return cells.map { row in
            if isRule(row) { return widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ") }
            return row.enumerated().map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
