import SwiftUI

/// A chat pane's conversation, drawn over its (hidden) terminal in the terminal's colours:
/// the user's messages on the right, Claude's replies as text, each tool call one quiet
/// line that opens on a tap, and what Claude is waiting for (an approval, a question)
/// at the end of the conversation, with the box to type in under it.
struct ChatView: View {
    @ObservedObject var chat: ChatSession
    let colors: ReviewColors
    /// Room the window's pill takes at the top
    var topInset: CGFloat = 0
    /// Typing here: the box is live (in the overview it's only a picture)
    var isActive = true
    /// Text size: the focused window is smaller than fullscreen, so its text is too
    var type = ChatType.standard

    @State private var draft = ""
    @FocusState private var typing: Bool
    @State private var openTools: Set<String> = []
    @State private var picked: [String: Set<String>] = [:]
    /// At the end of the conversation, so it stays there as it grows
    @State private var pinned = true
    /// Dictating into the box: its edge glows blue with the voice
    @State private var recording = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                        WorkingRow(thinking: chat.thinking, colors: colors)
                            .padding(.top, 16)
                    }
                    Color.clear.frame(height: 12).id("end")
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            // Below the window's pill, so text doesn't scroll up under it
            .padding(.top, topInset)
            .modifier(StickToBottom())
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: chat.pending) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Following the end as the reply grows (and as a replay fills in), until the
            // user scrolls up; back at the end, it follows again
            .modifier(FollowEnd(pinned: $pinned) { settle(proxy) })
            .onChange(of: tail) { _, _ in settle(proxy) }
            .task { settle(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .environment(\.chatType, type)
        .background(colors.bg)
        .animation(.easeOut(duration: 0.2), value: chat.pending)
        .animation(.easeOut(duration: 0.2), value: chat.working)
        .onChange(of: chat.focusRequest) { _, _ in typing = true }
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

    @ViewBuilder
    private func row(_ item: ChatSession.Item) -> some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(type.body)
                    .foregroundStyle(colors.fg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .reply(_, let text, _):
            MarkdownText(text: text, colors: colors)
        case .tool(let tool):
            ToolRow(tool: tool, colors: colors, isOpen: openTools.contains(tool.id)) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if openTools.contains(tool.id) { openTools.remove(tool.id) } else { openTools.insert(tool.id) }
                }
            }
        case .note(_, let text):
            Text(text)
                .font(type.footnote)
                .foregroundStyle(colors.faint)
                .frame(maxWidth: .infinity)
        }
    }

    @State private var settling: Task<Void, Never>?

    /// To the end, if that's where the user is: on the next turn of the run loop (the new
    /// rows aren't laid out yet), and again once the lazy rows have their real heights
    private func settle(_ proxy: ScrollViewProxy) {
        guard pinned else { return }
        settling?.cancel()
        settling = Task { @MainActor in
            for delay in [0, 120] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, pinned else { return }
                proxy.scrollTo("end", anchor: .bottom)
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

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude", text: $draft, axis: .vertical)
                .font(type.body)
                .lineLimit(1...6)
                .focused($typing)
                .foregroundStyle(colors.fg)
                .tint(colors.fg)
                .padding(.leading, 16)
                .padding(.vertical, 10)
                .onSubmit(send)
            DictationButton(text: $draft, recording: $recording, colors: colors,
                            offersDownload: true, size: type.size)
                .padding(.bottom, 4)
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
            .padding(.trailing, 6)
            .padding(.bottom, 5)
        }
        .glass(in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay { RecordingEdge(recording: recording) }
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
        .allowsHitTesting(isActive)
    }

    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
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

/// Whether the user has left the end: only their own scrolling changes it (the content
/// growing under a still view moves the end away too, and that shouldn't count)
private struct FollowEnd: ViewModifier {
    @Binding var pinned: Bool
    /// The view's height changed (the keyboard came or went)
    let resized: () -> Void
    @State private var dragging = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
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

/// Kept at the end as the reply grows (while it's there: scrolled up to read, it stays)
private struct StickToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
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
                    } else if tool.isError {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
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
            UIPasteboard.general.string = text
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
    let thinking: Bool
    let colors: ReviewColors
    @State private var turning = false

    var body: some View {
        HStack(spacing: 8) {
            ClaudeLogo()
                .fill(ReviewColors.claude)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: turning)
            Text(thinking ? "Thinking" : "Working")
                .font(type.small)
                .foregroundStyle(colors.faint)
        }
        .onAppear { turning = true }
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
        }
    }

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
            if needsSend(q) {
                Button { send(q) } label: { Text("Send").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton(colors: colors))
                    .disabled(!q.entries.allSatisfy { !(picked[$0.question] ?? []).isEmpty })
            }
            Button("Skip") { chat.deny() }
                .font(type.small)
                .foregroundStyle(colors.dim)
                .frame(maxWidth: .infinity)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
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
