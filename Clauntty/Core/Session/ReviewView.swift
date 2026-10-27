import SwiftUI

/// A review from `clauntty review` (plans/2026-10-26-clauntty-code-review.md), the web
/// prototype's page made native: the files in reading order with sticky headers, a file list
/// (a sidebar when there's room, else a drawer), Claude's comments as rows of the diff with
/// its symbol in the gutter, lines that scroll sideways under pinned numbers, and comments
/// of the user's own on a line or a run of lines. Finish review sends them. Colours come from
/// the terminal's theme, and only marks carry them (dots, counts, the symbol), never text.
struct ReviewView: View {
    let review: Review
    let theme: Theme?
    /// Leave it for now: it stays on the host, waiting
    let onClose: () -> Void

    @EnvironmentObject private var sessionManager: SessionManager

    @State private var comments: [ReviewUserComment] = []
    @State private var note = ""
    /// Hunks opened against their priority's default (collapsed ones), or closed
    @State private var toggled: Set<String> = []
    @State private var editing: EditTarget?
    @State private var draft = ""
    /// Lines being picked for a comment (drag in the gutter), by index in the hunk
    @State private var picking: Picking?
    @State private var drawer = false
    @State private var footerShown = false
    @State private var jump: Jump?
    @State private var sending = false
    @State private var sent: String?
    @State private var error: String?
    /// The file whose header was last pinned, for the file list
    @State private var current: String?
    /// How far the page is scrolled, how tall it shows, and where each file's header (and,
    /// as "", Finish review) is on it
    @State private var scrollY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var tops: [String: CGFloat] = [:]

    private var colors: ReviewColors { ReviewColors(theme: theme) }

    struct EditTarget: Equatable {
        let path: String
        /// The run's lines, in order
        let lines: [Review.Line]
        /// The comment being changed
        var existing: UUID?

        var last: Review.Line { lines[lines.count - 1] }
    }

    struct Picking: Equatable {
        let path: String
        let hunk: String
        let anchor: Int
        var current: Int
    }

    private struct Jump: Equatable {
        let id = UUID()
        let file: String
        let target: String?
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 860
            HStack(spacing: 0) {
                if wide {
                    fileList
                        .frame(width: 270)
                        .background(colors.sidebar)
                    Rectangle().fill(colors.hairline).frame(width: 1)
                }
                main(wide: wide)
            }
            .overlay(alignment: .bottomTrailing) {
                if !wide && !footerShown && sent == nil && editing == nil {
                    Button { jump = Jump(file: "", target: "footer") } label: { finishLabel(chip: true) }
                        .buttonStyle(ChipStyle(colors: colors))
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .leading) {
                if !wide && drawer {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { drawer = false } }
                        fileList
                            .frame(width: min(geometry.size.width * 0.82, 320))
                            .background(colors.bg.overlay(colors.sidebar).ignoresSafeArea())
                            .shadow(color: .black.opacity(0.5), radius: 20, x: 4)
                            .transition(.move(edge: .leading))
                    }
                }
            }
        }
        .background(colors.bg.ignoresSafeArea())
        .foregroundStyle(colors.fg)
        .environment(\.colorScheme, colors.isLight ? .light : .dark)
        .tint(colors.fg)
    }

    // MARK: Main column

    private func main(wide: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(wide: wide)
            ScrollViewReader { proxy in
                ScrollView {
                    page
                }
                .scrollDismissesKeyboard(.interactively)
                .trackingScrollY($scrollY, viewport: $viewportHeight)
                // The pinned header: the plain stack doesn't pin them
                .overlay(alignment: .top) {
                    if let file = review.files.last(where: { (tops[$0.path] ?? .infinity) <= scrollY + 1 }), scrollY > 0 {
                        fileHeader(file)
                    }
                }
                .onChange(of: scrollY) { _, _ in followScroll() }
                .onChange(of: tops) { _, _ in followScroll() }
                .onChange(of: jump) { _, jump in
                    guard let jump else { return }
                    let target = jump.target == "footer" ? "footer" : "file:" + jump.file
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: jump.target == "footer" ? .bottom : .top)
                    }
                    // A line inside a file is only there once the file is laid out
                    if let line = jump.target, line != "footer" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.3)) }
                        }
                    }
                }
            }
        }
    }

    /// The files with their headers, then Finish review, in a plain stack: a lazy one guesses
    /// the height of what it hasn't laid out, and a jump past a big file landed on nothing
    /// (the Mac) or under the wrong pinned header (the phone). So the header that stays at
    /// the top is drawn over the page, from where it's scrolled.
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) { pageContent }
            .coordinateSpace(name: Self.pageSpace)
            .onPreferenceChange(TopsKey.self) { tops = $0 }
    }

    @ViewBuilder
    private var pageContent: some View {
        ForEach(review.files) { file in
            Section {
                fileBody(file)
            } header: {
                fileHeader(file)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TopsKey.self, value: [file.path: g.frame(in: .named(Self.pageSpace)).minY])
                    })
            }
            .id("file:" + file.path)
        }
        footer
            .id("footer")
            .background(GeometryReader { g in
                Color.clear.preference(key: TopsKey.self, value: ["": g.frame(in: .named(Self.pageSpace)).minY])
            })
    }

    private static let pageSpace = "review-page"

    /// The file under the top edge and whether Finish review is in view, from where the page
    /// is scrolled
    private func followScroll() {
        if let file = review.files.last(where: { (tops[$0.path] ?? .infinity) <= scrollY + 1 }) ?? review.files.first,
           current != file.path {
            current = file.path
        }
        let shown = (tops[""] ?? .infinity) < scrollY + viewportHeight
        if shown != footerShown { withAnimation(.easeOut(duration: 0.15)) { footerShown = shown } }
    }

    private func topBar(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.dim)
            .help("Close (the review waits on the host)")
            Text(review.range)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(colors.dim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !wide {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { drawer = true }
                } label: {
                    Text("Files")
                }
                .buttonStyle(ChipStyle(colors: colors))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.hairline).frame(height: 1) }
    }

    // MARK: Files

    private func fileHeader(_ file: Review.File) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            pathText(file.path)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(1)
            if let status = statusText(file) {
                Text(status).font(.system(size: 12)).foregroundStyle(colors.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
            PriorityMark(priority: file.priority, colors: colors)
            counts(file)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.hairline).frame(height: 1) }
    }

    private func pathText(_ path: String) -> Text {
        let name = (path as NSString).lastPathComponent
        let dir = String(path.dropLast(name.count))
        return Text(dir).foregroundColor(colors.dim) + Text(name).fontWeight(.semibold)
    }

    private func statusText(_ file: Review.File) -> String? {
        switch file.status {
        case "untracked": return "untracked"
        case "added": return "new"
        case "deleted": return "deleted"
        case "renamed": return file.oldPath.map { "from \(($0 as NSString).lastPathComponent)" } ?? "renamed"
        default: return nil
        }
    }

    @ViewBuilder
    private func counts(_ file: Review.File) -> some View {
        if let added = file.added, let removed = file.removed {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(colors.plus)
                Text("−\(removed)").foregroundStyle(colors.minus)
            }
            .font(.system(size: 12, design: .monospaced))
            .fixedSize()
        }
    }

    /// Not in a stack of its own: on the phone each hunk is then an item of the page's lazy
    /// stack, laid out as it comes on screen
    @ViewBuilder
    private func fileBody(_ file: Review.File) -> some View {
        Group {
            if let note = file.note {
                Text(markdown(note))
                    .font(.system(size: 14))
                    .foregroundStyle(colors.fg.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if let skipped = file.skipped {
                Text("Not shown: \(skippedReason(skipped))")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.dim)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            // Comments whose line isn't in the diff
            ForEach(file.comments.filter { comment in !file.hunks.contains { hunkHas($0, comment) } }) { comment in
                ClaudeRow(text: comment.text, colors: colors, gutter: gutterWidth(file))
                    .padding(.top, 6)
                    .id("claude:\(comment.id)")
            }
            ForEach(file.hunks) { hunk in
                let key = "\(file.path)#\(hunk.id)"
                HunkView(
                    file: file, hunk: hunk, key: key, colors: colors, gutter: gutterWidth(file),
                    open: hunk.priority.collapsed == toggled.contains(key),
                    showPriority: hunk.priority != file.priority,
                    comments: comments.filter { $0.path == file.path },
                    editing: editing?.path == file.path ? editing : nil,
                    draft: $draft,
                    picking: picking?.hunk == key ? picking : nil,
                    toggle: { if toggled.contains(key) { toggled.remove(key) } else { toggled.insert(key) } },
                    pick: { pick($0, file: file, hunk: hunk, key: key) },
                    edit: { lines, existing in startEditing(file.path, lines: lines, existing: existing) },
                    save: { saveDraft() },
                    cancel: { editing = nil },
                    delete: { id in comments.removeAll { $0.id == id } }
                )
            }
            Spacer().frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hunkHas(_ hunk: Review.Hunk, _ comment: Review.Comment) -> Bool {
        hunk.lines.contains { $0.side == comment.side && $0.number == comment.line }
    }

    /// Room for the file's longest line number, as the web page's 3.4em
    private func gutterWidth(_ file: Review.File) -> CGFloat {
        let biggest = file.hunks.flatMap(\.lines).compactMap(\.number).max() ?? 0
        return max(44, CGFloat(String(biggest).count) * 7.6 + 16)
    }

    private func skippedReason(_ reason: String) -> String {
        switch reason {
        case "large": return "too large to show"
        case "lockfile": return "a lockfile"
        case "generated": return "generated"
        case "minified": return "minified"
        default: return "binary"
        }
    }

    // MARK: Commenting

    /// Dragging in the gutter: the run so far; at the end the editor opens on it
    private func pick(_ event: HunkView.PickEvent, file: Review.File, hunk: Review.Hunk, key: String) {
        switch event {
        case .began(let index):
            editing = nil
            picking = Picking(path: file.path, hunk: key, anchor: index, current: index)
        case .moved(let index):
            picking?.current = index
        case .ended:
            guard let p = picking else { return }
            let range = min(p.anchor, p.current)...max(p.anchor, p.current)
            picking = nil
            startEditing(file.path, lines: Array(hunk.lines[range]), existing: nil)
        }
    }

    private func startEditing(_ path: String, lines: [Review.Line], existing: UUID?) {
        guard !lines.isEmpty else { return }
        draft = existing.flatMap { id in comments.first { $0.id == id }?.text } ?? ""
        editing = EditTarget(path: path, lines: lines, existing: existing)
    }

    private func saveDraft() {
        guard let target = editing else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = target.existing, let index = comments.firstIndex(where: { $0.id == id }) {
            if text.isEmpty { comments.remove(at: index) } else { comments[index].text = text }
        } else if !text.isEmpty, let number = target.last.number {
            let first = target.lines[0]
            comments.append(ReviewUserComment(
                path: target.path, side: target.last.side, line: number,
                from: target.lines.count > 1 ? first.number : nil,
                code: target.lines.map(\.text).joined(separator: "\n"), text: text))
        }
        editing = nil
        draft = ""
    }

    // MARK: File list

    private var fileList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(review.files) { file in
                        Button { go(file: file.path, target: nil) } label: {
                            HStack(spacing: 0) {
                                PriorityDot(priority: file.priority, colors: colors)
                                    .padding(.trailing, 8)
                                Text(file.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                counts(file)
                            }
                            .font(.system(size: 14))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(current == file.path ? colors.fg.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(file.path)

                        ForEach(file.comments) { comment in
                            Button { go(file: file.path, target: comment.line.flatMap { lineId(file, comment.side, $0) }) } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    ClaudeLogo().fill(ReviewColors.claude).frame(width: 11, height: 11).padding(.top, 3)
                                    Text(gist(comment.text)).lineLimit(2)
                                }
                                .sidebarComment(colors: colors, mine: false)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(comments.filter { $0.path == file.path }) { mine in
                            Button { go(file: file.path, target: lineId(file, mine.side, mine.line)) } label: {
                                Text(mine.text).lineLimit(2)
                                    .sidebarComment(colors: colors, mine: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            // Always at the bottom of the list
            Button { go(file: "", target: "footer") } label: {
                finishLabel(chip: false)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(colors.hairline).frame(height: 1) }
        }
    }

    private func finishLabel(chip: Bool) -> some View {
        HStack(spacing: 0) {
            Text("Finish review")
            if !chip { Spacer(minLength: 10) }
            if !comments.isEmpty {
                Text("\(comments.count)").foregroundStyle(colors.dim).fontWeight(.regular).padding(.leading, chip ? 8 : 0)
            }
        }
    }

    private func go(file: String, target: String?) {
        if let target, target.hasPrefix("line:"), let id = Int(target.dropFirst(5)) {
            // Open the hunk the line is in
            for f in review.files where f.path == file {
                for hunk in f.hunks where hunk.lines.contains(where: { $0.id == id }) && hunk.priority.collapsed {
                    toggled.insert("\(f.path)#\(hunk.id)")
                }
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { drawer = false }
        jump = Jump(file: file, target: target)
    }

    private func lineId(_ file: Review.File, _ side: ReviewSide, _ number: Int) -> String? {
        for hunk in file.hunks {
            if let line = hunk.lines.first(where: { $0.side == side && $0.number == number }) { return "line:\(line.id)" }
        }
        return nil
    }

    private func gist(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "`", with: "")
        if let end = plain.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            return String(plain[..<end.lowerBound]) + String(plain[end.lowerBound])
        }
        return plain
    }

    // MARK: Finish

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finish review").font(.system(size: 15, weight: .semibold))
            if let sent {
                Text(sent).font(.system(size: 14)).foregroundStyle(colors.dim).padding(.top, 4)
                Button("Close", action: onClose)
                    .buttonStyle(PrimaryStyle(colors: colors))
                    .padding(.top, 12)
            } else {
                Text(countLine).font(.system(size: 13.5)).foregroundStyle(colors.dim).padding(.top, 2).padding(.bottom, 10)
                ForEach(orderedComments) { c in
                    Button {
                        if let file = review.files.first(where: { $0.path == c.path }) {
                            go(file: c.path, target: lineId(file, c.side, c.line))
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\((c.path as NSString).lastPathComponent):\(c.from.map { "\($0)–" } ?? "")\(c.line)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(colors.dim)
                            Text(c.text).lineLimit(1).font(.system(size: 13.5))
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { Rectangle().fill(colors.hairline).frame(height: 1) }
                }
                if !comments.isEmpty {
                    Rectangle().fill(colors.hairline).frame(height: 1).padding(.bottom, 12)
                }
                TextField("Note for Claude (optional)", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .font(.system(size: Self.inputSize))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(colors.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.fg.opacity(0.12)))
                HStack {
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(colors.minus)
                    }
                    Spacer()
                    Button(sending ? "Sending…" : comments.isEmpty && note.isEmpty ? "Looks good" : "Send") { send() }
                        .buttonStyle(PrimaryStyle(colors: colors))
                        .disabled(sending)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(colors.hairline).frame(height: 1) }
    }

    /// 16 on the phone: iOS zooms into smaller text fields
    #if os(iOS)
    static let inputSize: CGFloat = 16
    #else
    static let inputSize: CGFloat = 14
    #endif

    private var countLine: String {
        switch comments.count {
        case 0: return Self.hint
        case 1: return "1 comment"
        default: return "\(comments.count) comments"
        }
    }

    #if os(iOS)
    private static let hint = "No comments. Tap a line to add one, or hold a line number and drag for several."
    #else
    private static let hint = "No comments. Click a line number to add one, or drag down the numbers for several."
    #endif

    /// In the order of the page: by file, then line
    private var orderedComments: [ReviewUserComment] {
        let order = Dictionary(uniqueKeysWithValues: review.files.enumerated().map { ($1.path, $0) })
        return comments.sorted { (order[$0.path] ?? 0, $0.line) < (order[$1.path] ?? 0, $1.line) }
    }

    private func send() {
        saveDraft()
        sending = true
        error = nil
        Task {
            do {
                if let message = try await sessionManager.sendReview(review, note: note, comments: orderedComments) {
                    sent = message
                } else {
                    sessionManager.closeReview(review)
                }
            } catch {
                self.error = "Couldn't send: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}

// MARK: - A hunk

/// One hunk: its summary line, then its lines in one sideways scroll, with the line numbers
/// and the comment rows pinned to the left edge as the code scrolls (the web page's sticky)
struct HunkView: View {
    let file: Review.File
    let hunk: Review.Hunk
    let key: String
    let colors: ReviewColors
    let gutter: CGFloat
    let open: Bool
    let showPriority: Bool
    let comments: [ReviewUserComment]
    let editing: ReviewView.EditTarget?
    @Binding var draft: String
    let picking: ReviewView.Picking?
    let toggle: () -> Void
    let pick: (PickEvent) -> Void
    let edit: ([Review.Line], UUID?) -> Void
    let save: () -> Void
    let cancel: () -> Void
    let delete: (UUID) -> Void

    enum PickEvent { case began(Int), moved(Int), ended }

    @State private var scrollX: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var hovered: Int?
    /// Each line's frame in the rows, for a drag in the gutter
    @State private var frames: [Int: CGRect] = [:]

    private static let rowHeight: CGFloat = 19
    /// The sideways scroll's frame, to tell how far it's scrolled
    private var space: String { "hunk:" + key }
    /// The rows' own, for where each line is
    private var rowsSpace: String { "rows:" + key }
    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if open {
                // In a container of its own: named on the scroll view, the space would
                // move with its content
                ZStack(alignment: .topLeading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        rows
                            .coordinateSpace(name: rowsSpace)
                            .frame(minWidth: viewport, alignment: .leading)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ScrollXKey.self, value: -g.frame(in: .named(space)).minX)
                            })
                    }
                    .trackingScrollX($scrollX)
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(ScrollXKey.self) { scrollX = max(0, $0) }
                .onPreferenceChange(LineFramesKey.self) { frames = $0 }
                // Where the page jumps to for a comment: outside the sideways scroll, which
                // would otherwise be the one scrolled to show it
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(targets, id: \.self) { index in
                            // A spacer above it, not an offset or padding: scrolling to it
                            // goes by its own laid-out frame
                            VStack(spacing: 0) {
                                Color.clear.frame(width: 1, height: frames[index]?.minY ?? CGFloat(index) * Self.rowHeight)
                                Color.clear.frame(width: 1, height: Self.rowHeight)
                                    .id("line:\(hunk.lines[index].id)")
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { viewport = g.size.width }
                        .onChange(of: g.size.width) { _, width in viewport = width }
                })
            }
        }
        .padding(.top, 6)
    }

    private var summary: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(open ? "▾" : "▸")
                Text("@@ \(hunk.newStart) \(hunk.section)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if showPriority { Text(hunk.priority.rawValue) }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(colors.dim)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.fg.opacity(0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines.indices, id: \.self) { index in
                let line = hunk.lines[index]
                lineRow(line, index: index)
                ForEach(file.comments.filter { $0.side == line.side && $0.line == line.number }) { comment in
                    pinned(ClaudeRow(text: comment.text, colors: colors, gutter: gutter))
                }
                ForEach(comments.filter { $0.side == line.side && $0.line == line.number }) { mine in
                    if editing?.existing == mine.id {
                        editor
                    } else {
                        pinned(MineRow(comment: mine, colors: colors, gutter: gutter,
                                       edit: { edit(linesOf(mine), mine.id) }, delete: { delete(mine.id) }))
                    }
                }
                if let editing, editing.existing == nil, editing.last.id == line.id {
                    editor
                }
            }
        }
    }

    /// A row as wide as what's on screen, kept at its left edge
    private func pinned(_ row: some View) -> some View {
        row.frame(width: max(viewport, 1), alignment: .leading).offset(x: scrollX)
    }

    @ViewBuilder
    private var editor: some View {
        if let editing {
            pinned(EditorRow(target: editing, draft: $draft, colors: colors, gutter: gutter, save: save, cancel: cancel))
        }
    }

    /// Lines with a comment on them, by index: the file list and Finish review jump there
    private var targets: [Int] {
        hunk.lines.indices.filter { i in
            let line = hunk.lines[i]
            return file.comments.contains { $0.side == line.side && $0.line == line.number }
                || comments.contains { $0.side == line.side && $0.line == line.number }
        }
    }

    /// The lines a comment of the user's covers, to edit it with its code
    private func linesOf(_ comment: ReviewUserComment) -> [Review.Line] {
        guard let last = hunk.lines.firstIndex(where: { $0.side == comment.side && $0.number == comment.line }) else { return [] }
        guard let from = comment.from, let first = hunk.lines.firstIndex(where: { $0.number == from }), first <= last else {
            return [hunk.lines[last]]
        }
        return Array(hunk.lines[first...last])
    }

    private func lineRow(_ line: Review.Line, index: Int) -> some View {
        let inPick = picking.map { min($0.anchor, $0.current)...max($0.anchor, $0.current) }?.contains(index) == true
        let inEdit = editing.map { $0.existing == nil && $0.lines.contains { $0.id == line.id } } == true
        return HStack(spacing: 0) {
            number(line, index: index)
                .offset(x: scrollX)
                .zIndex(1)
            code(line)
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize()
                .padding(.leading, 8)
                .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .background(rowTint(line))
        // The hover's and the pick's light, not something to click
        .overlay((inPick || inEdit ? colors.fg.opacity(0.10) : hovered == index ? colors.fg.opacity(0.04) : .clear).allowsHitTesting(false))
        .background(GeometryReader { g in
            Color.clear.preference(key: LineFramesKey.self, value: [index: g.frame(in: .named(rowsSpace))])
        })
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        #if os(iOS)
        // On the phone a tap anywhere on the line comments on it
        .onTapGesture { edit([line], nil) }
        #endif
    }

    @ViewBuilder
    private func number(_ line: Review.Line, index: Int) -> some View {
        #if os(macOS)
        // A button for the click, with the drag beside it
        Button { edit([line], nil) } label: { numberLabel(line, index: index) }
            .buttonStyle(.plain)
            .simultaneousGesture(gutterGesture(line, index: index))
        #else
        numberLabel(line, index: index)
            .gesture(gutterGesture(line, index: index))
        #endif
    }

    private func numberLabel(_ line: Review.Line, index: Int) -> some View {
        Text(line.number.map(String.init) ?? "")
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(numberColor(line))
            .frame(width: gutter - 6, alignment: .trailing)
            .padding(.trailing, 6)
            .frame(height: Self.rowHeight)
            // Opaque: the code scrolls under it
            .background(gutterTint(line))
            .background(colors.bg)
            .overlay(alignment: .trailing) {
                // With a mouse, a + where comments start
                if !Self.touch && hovered == index && picking == nil && editing == nil {
                    PlusMark(colors: colors).offset(x: 22)
                }
            }
            .contentShape(Rectangle())
    }

    /// A click on a number comments on its line; dragging down the numbers picks a run of
    /// lines. On the phone, hold a number, then drag.
    private func gutterGesture(_ line: Review.Line, index: Int) -> some Gesture {
        let drag = DragGesture(minimumDistance: Self.touch ? 0 : 2, coordinateSpace: .named(rowsSpace))
            .onChanged { value in
                if picking == nil { pick(.began(index)) }
                if let at = frames.first(where: { $0.value.minY <= value.location.y && value.location.y < $0.value.maxY })?.key {
                    pick(.moved(at))
                }
            }
            .onEnded { _ in pick(.ended) }
        #if os(iOS)
        return LongPressGesture(minimumDuration: 0.3).sequenced(before: drag).onEnded { _ in pick(.ended) }
        #else
        return drag
        #endif
    }

    private func code(_ line: Review.Line) -> Text {
        guard let runs = line.runs else { return Text(line.text) }
        return runs.reduce(Text("")) { text, run in
            guard let kind = run.kind, let colour = colors.tokens[kind] else { return text + Text(run.text) }
            let piece = Text(run.text).foregroundColor(colour)
            return text + (kind == .comment ? piece.italic() : piece)
        }
    }

    private func rowTint(_ line: Review.Line) -> Color {
        switch line.kind {
        case .added: return colors.add
        case .removed: return colors.del
        case .context: return .clear
        }
    }

    private func gutterTint(_ line: Review.Line) -> Color {
        switch line.kind {
        case .added: return colors.addGutter
        case .removed: return colors.delGutter
        case .context: return .clear
        }
    }

    private func numberColor(_ line: Review.Line) -> Color {
        switch line.kind {
        case .added: return colors.plus.opacity(0.85)
        case .removed: return colors.minus.opacity(0.85)
        case .context: return colors.faint
        }
    }
}

private extension View {
    /// How far a sideways scroll is scrolled, as it scrolls. iOS 18 and macOS 15 say so; on
    /// older ones the content's frame (ScrollXKey) does, though not always while scrolling.
    @ViewBuilder
    func trackingScrollX(_ x: Binding<CGFloat>) -> some View {
        if #available(iOS 18, macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, new in
                x.wrappedValue = max(0, new)
            }
        } else {
            self
        }
    }
}

private extension View {
    /// How far the page is scrolled and how tall it shows (iOS 18 and macOS 15; older ones
    /// get no header kept at the top, and the Finish review chip stays)
    @ViewBuilder
    func trackingScrollY(_ y: Binding<CGFloat>, viewport: Binding<CGFloat>) -> some View {
        if #available(iOS 18, macOS 15, *) {
            onScrollGeometryChange(for: CGRect.self, of: { CGRect(x: 0, y: $0.contentOffset.y + $0.contentInsets.top, width: 0, height: $0.containerSize.height) }) { _, new in
                y.wrappedValue = new.minY
                viewport.wrappedValue = new.height
            }
        } else {
            self
        }
    }
}

private struct TopsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ScrollXKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct LineFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Rows

/// Claude's comment: a row of the diff, its text where the code starts, its symbol in the gutter
private struct ClaudeRow: View {
    let text: String
    let colors: ReviewColors
    let gutter: CGFloat

    var body: some View {
        Text(markdown(text))
            .font(.system(size: 14))
            .foregroundStyle(colors.fg.opacity(0.88))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, gutter + 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                ClaudeLogo().fill(ReviewColors.claude).frame(width: 14, height: 14).padding(.leading, 15).padding(.top, 10)
            }
            .commentBand(colors)
    }
}

/// The user's own comment, as Claude's are, with Edit and Delete
private struct MineRow: View {
    let comment: ReviewUserComment
    let colors: ReviewColors
    let gutter: CGFloat
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("You").fontWeight(.semibold).foregroundStyle(colors.dim)
                if let from = comment.from {
                    Text("lines \(from)–\(comment.line)").foregroundStyle(colors.dim)
                }
                Button("Edit", action: edit).buttonStyle(LinkStyle(colors: colors)).padding(.leading, 4)
                Button("Delete", action: delete).buttonStyle(LinkStyle(colors: colors))
            }
            .font(.system(size: 12))
            Text(comment.text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, gutter + 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .commentBand(colors)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }
}

/// The comment being written looks like the one it becomes: the same band, label and place
private struct EditorRow: View {
    let target: ReviewView.EditTarget
    @Binding var draft: String
    let colors: ReviewColors
    let gutter: CGFloat
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("You").fontWeight(.semibold)
                if target.lines.count > 1, let from = target.lines.first?.number, let to = target.last.number {
                    Text("lines \(from)–\(to)")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(colors.dim)
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: ReviewView.inputSize))
                .lineLimit(1...12)
                .focused($focused)
            HStack(spacing: 4) {
                #if os(macOS)
                Text("⌘↩ to save").font(.system(size: 12)).foregroundStyle(colors.faint)
                #endif
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(LinkStyle(colors: colors))
                    .keyboardShortcut(.cancelAction)
                    .padding(.horizontal, 8)
                Button("Save", action: save)
                    .buttonStyle(PrimaryStyle(colors: colors, small: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, gutter + 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .commentBand(colors)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        let name = (target.path as NSString).lastPathComponent
        if target.lines.count > 1, let from = target.lines.first?.number, let to = target.last.number {
            return "Comment on \(name) lines \(from)–\(to)"
        }
        return "Comment on \(name):\(target.last.number ?? 0)"
    }
}

private extension View {
    func commentBand(_ colors: ReviewColors) -> some View {
        background(colors.bg.overlay(colors.card))
            .overlay(alignment: .top) { Rectangle().fill(colors.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(colors.hairline).frame(height: 1) }
    }

    func sidebarComment(colors: ReviewColors, mine: Bool) -> some View {
        font(.system(size: 12.5))
            .foregroundStyle(mine ? colors.fg.opacity(0.78) : colors.dim)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, mine ? 26 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .padding(.leading, 15)
            .contentShape(Rectangle())
    }
}

/// Inline Markdown (`code`, emphasis) in a comment
private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

// MARK: - Marks

/// A priority: its dot in colour, its word in grey
private struct PriorityMark: View {
    let priority: ReviewPriority
    let colors: ReviewColors

    var body: some View {
        HStack(spacing: 6) {
            PriorityDot(priority: priority, colors: colors)
            Text(priority.rawValue).font(.system(size: 12.5)).foregroundStyle(colors.dim)
        }
        .fixedSize()
    }
}

private struct PriorityDot: View {
    let priority: ReviewPriority
    let colors: ReviewColors

    var body: some View {
        Circle().fill(colors.priority[priority] ?? colors.dim).frame(width: 7, height: 7)
    }
}

/// The + by the hovered line's number, drawn rather than a glyph so it sits centred
private struct PlusMark: View {
    let colors: ReviewColors

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colors.fg.opacity(0.9))
            .frame(width: 18, height: 18)
            .overlay {
                ZStack {
                    Rectangle().frame(width: 10, height: 2)
                    Rectangle().frame(width: 2, height: 10)
                }
                .foregroundStyle(colors.bg)
            }
            .allowsHitTesting(false)
    }
}

/// Claude's symbol (Wikimedia Commons, Claude_AI_symbol.svg), from its SVG path
struct ClaudeLogo: Shape {
    func path(in rect: CGRect) -> Path {
        Self.symbol.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private static let symbol = SVGPath.parse(
        "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z")
}

/// The few SVG path commands Claude's symbol uses: M L H V C Z, absolute and relative
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var point = CGPoint.zero
        var start = CGPoint.zero
        var command: Character?
        var numbers: [CGFloat] = []

        /// Draw what the current command's numbers say, as many times as they repeat
        func flush() {
            guard let command else { return }
            let relative = command.isLowercase
            var n = numbers[...]
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y)
            }
            var first = true
            loop: while !n.isEmpty {
                switch command.uppercased() {
                case "M", "L":
                    guard n.count >= 2 else { break loop }
                    point = at(n.removeFirst(), n.removeFirst())
                    // A move's later pairs are lines
                    if command.uppercased() == "M" && first { path.move(to: point); start = point } else { path.addLine(to: point) }
                case "H":
                    let x = n.removeFirst()
                    point = CGPoint(x: relative ? point.x + x : x, y: point.y)
                    path.addLine(to: point)
                case "V":
                    let y = n.removeFirst()
                    point = CGPoint(x: point.x, y: relative ? point.y + y : y)
                    path.addLine(to: point)
                case "C":
                    guard n.count >= 6 else { break loop }
                    let c1 = at(n.removeFirst(), n.removeFirst())
                    let c2 = at(n.removeFirst(), n.removeFirst())
                    point = at(n.removeFirst(), n.removeFirst())
                    path.addCurve(to: point, control1: c1, control2: c2)
                default:
                    break loop
                }
                first = false
            }
        }

        var token = ""
        func endNumber() {
            if let v = Double(token) { numbers.append(CGFloat(v)) }
            token = ""
        }
        for c in d {
            if c.isLetter {
                endNumber()
                flush()
                numbers = []
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    point = start
                    command = nil
                } else {
                    command = c
                }
            } else if c == "-" {
                endNumber()
                token.append(c)
            } else if c == "." {
                // A second point starts a number: ".3.5" is 0.3 then 0.5
                if token.contains(".") { endNumber() }
                token.append(c)
            } else if c == " " || c == "," {
                endNumber()
            } else {
                token.append(c)
            }
        }
        endNumber()
        flush()
        return path
    }
}

// MARK: - Styles

/// The review's colours, from the terminal's theme: its background and text, and its 16
/// colours for the highlighting, the diff and the marks
struct ReviewColors {
    let bg: Color
    let fg: Color
    let isLight: Bool
    let sidebar: Color
    let card: Color
    let add: Color
    let addGutter: Color
    let del: Color
    let delGutter: Color
    let plus: Color
    let minus: Color
    let tokens: [TokenKind: Color]
    let priority: [ReviewPriority: Color]

    var dim: Color { fg.opacity(0.58) }
    var faint: Color { fg.opacity(0.38) }
    var hairline: Color { fg.opacity(0.08) }

    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)

    init(theme: Theme?) {
        let light = theme?.isLight ?? false
        bg = theme?.backgroundColor ?? Color(red: 0.149, green: 0.165, blue: 0.2)
        fg = theme?.foregroundColor ?? Color(red: 0.9, green: 0.9, blue: 0.9)
        isLight = light
        func palette(_ i: Int, _ fallback: Color) -> Color { theme?.paletteColor(i) ?? fallback }
        let red = palette(1, Color(red: 0.88, green: 0.33, blue: 0.33))
        let green = palette(2, Color(red: 0.02, green: 0.74, blue: 0.47))
        let yellow = palette(3, Color(red: 1.0, green: 0.9, blue: 0.43))
        let blue = palette(4, Color(red: 0.38, green: 0.6, blue: 0.95))
        let magenta = palette(5, Color(red: 0.78, green: 0.3, blue: 0.93))
        let cyan = palette(6, Color(red: 0.0, green: 0.82, blue: 0.75))
        let grey = palette(8, Color(red: 0.55, green: 0.56, blue: 0.6))

        sidebar = light ? Color.black.opacity(0.03) : Color.black.opacity(0.14)
        card = fg.opacity(light ? 0.04 : 0.05)
        add = green.opacity(light ? 0.12 : 0.14)
        addGutter = green.opacity(light ? 0.12 : 0.13)
        del = red.opacity(light ? 0.11 : 0.15)
        delGutter = red.opacity(light ? 0.11 : 0.14)
        plus = green
        minus = red
        tokens = [
            .keyword: magenta, .string: green, .comment: grey, .constant: yellow, .function: blue,
            .type: cyan, .attribute: red, .operator: fg.opacity(0.75), .punctuation: fg.opacity(0.62),
        ]
        priority = [.critical: red, .review: yellow, .skim: fg.opacity(0.45), .mechanical: fg.opacity(0.25)]
    }
}

/// The one primary action: light on dark (dark on light), as the web page's
private struct PrimaryStyle: ButtonStyle {
    let colors: ReviewColors
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 13 : 13.5, weight: .semibold))
            .foregroundStyle(colors.bg)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 4 : 7)
            .background(colors.fg.opacity(configuration.isPressed ? 0.75 : 0.92), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

/// Grey text that reads as a button
private struct LinkStyle: ButtonStyle {
    let colors: ReviewColors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(configuration.isPressed ? colors.fg : colors.dim)
            .contentShape(Rectangle())
    }
}

/// Files and Finish review on the phone: a small chip over the content
private struct ChipStyle: ButtonStyle {
    let colors: ReviewColors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.fg.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
