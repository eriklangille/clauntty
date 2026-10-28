import SwiftUI

/// A review from `clauntty review` (plans/2026-10-26-clauntty-code-review.md), the web
/// prototype's page made native: the files in reading order with sticky headers, a file list
/// (a sidebar when there's room, else a drawer), Claude's comments as rows of the diff with
/// its symbol in the gutter, lines that scroll sideways beside fixed numbers, and comments of
/// the user's own on a line or a run of lines. Finish review sends them. Colours come from
/// the terminal's theme, and only marks carry them (dots, counts, the symbol), never text.
///
/// Thousands of lines are on screen at once, so nothing that changes often may rebuild
/// them: what's typed lives in `ReviewDrafts` and where the page is scrolled in
/// `PageScroll`, watched only by the views that show them; the page and each hunk are
/// equatable, so a change elsewhere skips them; scrolling a hunk sideways moves nothing but
/// its code; hover and picking are one layer drawn over the lines, from where the rows are.
/// The page is a list of rows made as they come on screen (`PageRows`): a table on the Mac,
/// a collection view on the phone.
struct ReviewView: View, Equatable {
    let review: Review
    let theme: Theme?
    /// Not watched: it publishes whenever a pane does anything, and the review needs it only
    /// to send
    let sessionManager: SessionManager
    /// Leave it for now: it stays on the host, waiting
    let onClose: () -> Void
    /// Its own top bar, with the range and X (the phone); the Mac's window gives it a title
    /// bar like a pane's instead
    let topBar: Bool

    @State private var colors: ReviewColors
    @State private var drafts = ReviewDrafts()
    @State private var scroll = PageScroll()
    @State private var measures = CommentHeights()
    @State private var comments: [ReviewUserComment] = []
    /// Hunks opened against their priority's default (collapsed ones), or closed
    @State private var toggled: Set<String> = []
    @State private var editing: EditTarget?
    /// Lines being picked for a comment (drag in the gutter), by index in the hunk
    @State private var picking: Picking?
    @State private var drawer = false
    @State private var jump: Jump?
    /// Where the page's jump anchor is: a jump scrolls to it
    @State private var sending = false
    @State private var sent: String?
    @State private var error: String?

    init(review: Review, theme: Theme?, sessionManager: SessionManager, topBar: Bool = true, onClose: @escaping () -> Void) {
        self.review = review
        self.theme = theme
        self.sessionManager = sessionManager
        self.topBar = topBar
        self.onClose = onClose
        _colors = State(initialValue: ReviewColors.of(theme))
    }

    /// The same review in the same theme: its host view rebuilds whenever any pane changes,
    /// and this keeps that from reaching the review
    static func == (a: Self, b: Self) -> Bool {
        a.review.id == b.review.id && a.theme?.id == b.theme?.id
    }

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
            // The Mac keeps the file list beside the page however narrow the review is
            // (beside the panes, it's the way around a review); the phone needs the room
            #if os(macOS)
            let wide = true
            #else
            let wide = geometry.size.width >= 860
            #endif
            HStack(spacing: 0) {
                if wide {
                    fileList
                        .frame(width: geometry.size.width >= 1000 ? 270 : 230)
                        .background(colors.sidebar)
                    Rectangle().fill(colors.hairline).frame(width: 1)
                }
                main(wide: wide)
            }
            .overlay(alignment: .bottomTrailing) {
                if !wide && sent == nil && editing == nil {
                    FinishChip(place: scroll.place, count: comments.count, colors: colors) {
                        jump = Jump(file: "", target: "footer")
                    }
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
            if topBar { topBar(wide: wide) }
            pageScroll
                .onAppear { FrameMonitor.shared?.start() }
        }
    }

    private var pageState: PageState {
        PageState(
            review: review, colors: colors, comments: comments, toggled: toggled, editing: editing,
            picking: picking, drafts: drafts, measures: measures, actions: actions
        )
    }

    /// Where a jump goes: the place it was measured at, and how far down the view to put it
    private func destination(_ jump: Jump) -> (key: String, fraction: CGFloat) {
        let key = jump.target == "footer" ? "" : jump.target ?? jump.file
        return (key, jump.target == nil || jump.target == "footer" ? 0 : 0.3)
    }

    /// The page's rows, made as they come on screen (`PageRows`): as one SwiftUI view in a
    /// scroll view, the whole page was laid out on every frame of a scroll
    private var pageScroll: some View {
        PageList(
            state: pageState,
            footer: AnyView(footer),
            place: scroll.place,
            jumper: { [scroll] jumper in scroll.jumper = jumper }
        )
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
        .onChange(of: jump) { _, jump in
            guard let jump else { return }
            let (key, fraction) = destination(jump)
            // After the list has the rows the jump opened (a collapsed hunk)
            DispatchQueue.main.async { scroll.jumper?(key, fraction) }
        }
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

    // MARK: Commenting

    private var actions: PageActions {
        PageActions(
            toggle: { key in if toggled.contains(key) { toggled.remove(key) } else { toggled.insert(key) } },
            pick: { event, path, hunk, key in pick(event, path: path, hunk: hunk, key: key) },
            edit: { path, lines, existing in startEditing(path, lines: lines, existing: existing) },
            save: { saveDraft() },
            cancel: { editing = nil },
            delete: { id in comments.removeAll { $0.id == id } }
        )
    }

    /// Dragging in the gutter: the run so far; at the end the editor opens on it
    private func pick(_ event: HunkView.PickEvent, path: String, hunk: Review.Hunk, key: String) {
        switch event {
        case .began(let index):
            editing = nil
            picking = Picking(path: path, hunk: key, anchor: index, current: index)
        case .moved(let index):
            if picking?.current != index { picking?.current = index }
        case .ended:
            guard let p = picking else { return }
            let range = min(p.anchor, p.current)...max(p.anchor, p.current)
            picking = nil
            startEditing(path, lines: Array(hunk.lines[range]), existing: nil)
        }
    }

    private func startEditing(_ path: String, lines: [Review.Line], existing: UUID?) {
        guard !lines.isEmpty else { return }
        drafts.draft = existing.flatMap { id in comments.first { $0.id == id }?.text } ?? ""
        editing = EditTarget(path: path, lines: lines, existing: existing)
    }

    private func saveDraft() {
        guard let target = editing else { return }
        let text = drafts.draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
        drafts.draft = ""
    }

    // MARK: File list

    private var fileList: some View {
        FileList(files: review.files, comments: comments, colors: colors, place: scroll.place) { file, target in
            go(file: file, target: target)
        }
        .equatable()
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
                            go(file: c.path, target: file.lineId(c.side, c.line))
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
                NoteField(drafts: drafts, colors: colors, send: send)
                HStack {
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(colors.minus)
                    }
                    Spacer()
                    SendButton(drafts: drafts, hasComments: !comments.isEmpty, sending: sending, colors: colors, send: send)
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
                if let message = try await sessionManager.sendReview(review, note: drafts.note, comments: orderedComments) {
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

// MARK: - A graph of its own

/// The review in a hosting view of its own, so the rest of the window can't reach it: in
/// the window's own graph, every change a pane made (an agent's state, a title) had
/// SwiftUI update the page's thousands of views, though none of them changed. It's given a
/// new review or theme, and nothing else.
struct ReviewHost: View {
    let review: Review
    let theme: Theme?
    let sessionManager: SessionManager
    var topBar = true
    let onClose: () -> Void

    var body: some View {
        IsolatedHost(id: "\(review.id)|\(theme?.id ?? "")") {
            ReviewView(review: review, theme: theme, sessionManager: sessionManager, topBar: topBar, onClose: onClose)
        }
    }
}

#if os(macOS)
private struct IsolatedHost<Content: View>: NSViewRepresentable {
    let id: String
    let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content())
        // Fills what it's given rather than asking for its content's size
        view.sizingOptions = []
        // Under the window's title bar, which is the panes' and the review's own: nothing to
        // keep clear of
        view.safeAreaRegions = []
        context.coordinator.id = id
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        view.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var id = ""
    }
}
#else
private struct IsolatedHost<Content: View>: UIViewControllerRepresentable {
    let id: String
    let content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content())
        controller.view.backgroundColor = .clear
        context.coordinator.id = id
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        controller.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var id = ""
    }
}
#endif

// MARK: - State the page doesn't watch

/// What's being typed: a comment and the note. Only their text fields (and Send's label)
/// watch it, so a keystroke redraws those, not the page.
final class ReviewDrafts: ObservableObject {
    @Published var draft = ""
    @Published var note = ""
}

/// Where the page is: the file at its top and whether Finish review is in view (`place`),
/// and how to scroll it to a place (`jumper`, from the list of its rows)
final class PageScroll {
    let place = PagePlace()
    /// Scrolls to a place (`PageRows.target`'s key), that fraction of the way down the view
    var jumper: ((String, CGFloat) -> Void)?
}

/// The file at the top of the page (lit in the file list), and whether Finish review is
/// on screen (the phone's chip hides then)
final class PagePlace: ObservableObject {
    @Published private(set) var current: String?
    @Published private(set) var footerShown = false

    /// Published only when they change: it's called on every frame of a scroll
    func set(current: String?, footerShown: Bool) {
        if self.current != current { self.current = current }
        if self.footerShown != footerShown { withAnimation(.easeOut(duration: 0.15)) { self.footerShown = footerShown } }
    }
}

/// What the page's hunks can do, as closures into the review's state
struct PageActions {
    let toggle: (String) -> Void
    let pick: (HunkView.PickEvent, String, Review.Hunk, String) -> Void
    let edit: (String, [Review.Line], UUID?) -> Void
    let save: () -> Void
    let cancel: () -> Void
    let delete: (UUID) -> Void
}

/// Finish review on the phone, until it's on screen
private struct FinishChip: View {
    @ObservedObject var place: PagePlace
    let count: Int
    let colors: ReviewColors
    let action: () -> Void

    var body: some View {
        if !place.footerShown {
            Button(action: action) {
                HStack(spacing: 0) {
                    Text("Finish review")
                    if count > 0 { Text("\(count)").foregroundStyle(colors.dim).fontWeight(.regular).padding(.leading, 8) }
                }
            }
            .buttonStyle(ChipStyle(colors: colors))
            .padding(12)
            .transition(.opacity)
        }
    }
}

private struct NoteField: View {
    @ObservedObject var drafts: ReviewDrafts
    let colors: ReviewColors
    let send: () -> Void

    var body: some View {
        TextField("Note for Claude (optional)", text: $drafts.note, axis: .vertical)
            .textFieldStyle(.plain)
            .newlineKeys(text: $drafts.note, submit: send)
            .lineLimit(2...8)
            .font(.system(size: ReviewView.inputSize))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(colors.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.fg.opacity(0.12)))
    }
}

/// "Looks good" until there's something to say
private struct SendButton: View {
    @ObservedObject var drafts: ReviewDrafts
    let hasComments: Bool
    let sending: Bool
    let colors: ReviewColors
    let send: () -> Void

    var body: some View {
        Button(sending ? "Sending…" : !hasComments && drafts.note.isEmpty ? "Looks good" : "Send", action: send)
            .buttonStyle(PrimaryStyle(colors: colors))
            .disabled(sending)
    }
}

// MARK: - File list

/// The files in reading order, with Claude's comments and the user's under each; the file
/// under the page's top edge lit
private struct FileList: View, Equatable {
    let files: [Review.File]
    let comments: [ReviewUserComment]
    let colors: ReviewColors
    /// Not watched here: only each file's light does
    let place: PagePlace
    let go: (String, String?) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.files.map(\.path) == b.files.map(\.path) && a.comments == b.comments && a.colors == b.colors
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(files) { file in
                        Button { go(file.path, nil) } label: {
                            HStack(spacing: 0) {
                                PriorityDot(priority: file.priority, colors: colors)
                                    .padding(.trailing, 8)
                                Text(file.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Counts(file: file, colors: colors)
                            }
                            .font(.system(size: 14))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(CurrentFile(place: place, path: file.path, colors: colors))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(file.path)

                        ForEach(file.comments) { comment in
                            Button { go(file.path, comment.line.flatMap { file.lineId(comment.side, $0) }) } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    ClaudeLogo().fill(ReviewColors.claude).frame(width: 11, height: 11).padding(.top, 3)
                                    Text(gist(comment.text)).lineLimit(2)
                                }
                                .sidebarComment(colors: colors, mine: false)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(comments.filter { $0.path == file.path }) { mine in
                            Button { go(file.path, file.lineId(mine.side, mine.line)) } label: {
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
            // Always at the bottom of the list: the review's one primary action
            Button { go("", "footer") } label: {
                HStack(spacing: 6) {
                    Text("Finish review")
                    if !comments.isEmpty { Text("· \(comments.count)").fontWeight(.regular) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryStyle(colors: colors))
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(colors.hairline).frame(height: 1) }
        }
    }

    /// The light behind the file at the top of the page: a view of its own that watches
    /// it, as the list is equatable and wasn't redrawn when it changed
    private struct CurrentFile: View {
        @ObservedObject var place: PagePlace
        let path: String
        let colors: ReviewColors

        var body: some View {
            RoundedRectangle(cornerRadius: 6).fill(place.current == path ? colors.fg.opacity(0.08) : .clear)
        }
    }

    private func gist(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "`", with: "")
        if let end = plain.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            return String(plain[..<end.lowerBound]) + String(plain[end.lowerBound])
        }
        return plain
    }
}

extension Review.File {
    /// The page's id for a line of this file, to jump to
    func lineId(_ side: ReviewSide, _ number: Int) -> String? {
        for hunk in hunks {
            if let line = hunk.lines.first(where: { $0.side == side && $0.number == number }) { return "line:\(line.id)" }
        }
        return nil
    }

    /// Room for its longest line number, as the web page's 3.4em
    var gutterWidth: CGFloat {
        let biggest = hunks.flatMap(\.lines).compactMap(\.number).max() ?? 0
        return max(44, CGFloat(String(biggest).count) * 7.6 + 16)
    }
}

// MARK: - The page

/// What the page shows, and the user's work on it: its rows (`PageRows`) are drawn from this
struct PageState: Equatable {
    let review: Review
    let colors: ReviewColors
    let comments: [ReviewUserComment]
    let toggled: Set<String>
    let editing: ReviewView.EditTarget?
    let picking: ReviewView.Picking?
    let drafts: ReviewDrafts
    let measures: CommentHeights
    let actions: PageActions

    static func == (a: Self, b: Self) -> Bool {
        a.review.id == b.review.id && a.colors == b.colors && a.comments == b.comments && a.toggled == b.toggled
            && a.editing == b.editing && a.picking == b.picking
    }

    static func key(_ file: Review.File, _ hunk: Review.Hunk) -> String { "\(file.path)#\(hunk.id)" }

    func isOpen(_ file: Review.File, _ hunk: Review.Hunk) -> Bool {
        hunk.priority.collapsed == toggled.contains(Self.key(file, hunk))
    }

    func hunk(_ file: Review.File, _ hunk: Review.Hunk, open: Bool? = nil) -> HunkView {
        let key = Self.key(file, hunk)
        return HunkView(
            file: file, hunk: hunk, key: key, colors: colors, gutter: file.gutterWidth,
            open: open ?? isOpen(file, hunk),
            showPriority: hunk.priority != file.priority,
            comments: comments.filter { $0.path == file.path },
            editing: editing?.path == file.path ? editing : nil,
            picking: picking?.hunk == key ? picking : nil,
            drafts: drafts, measures: measures, actions: actions
        )
    }
}

/// Comment rows' heights by hunk, as measured: a hunk drawn again (the Mac's rows are
/// made as they come on screen) starts at its size rather than growing into it
final class CommentHeights {
    private var byHunk: [String: [String: CGFloat]] = [:]

    subscript(hunk: String) -> [String: CGFloat] {
        get { byHunk[hunk] ?? [:] }
        set { byHunk[hunk] = newValue }
    }
}

extension PageState {
    /// Under each file's last hunk
    static let fileGap: CGFloat = 12
}

extension Review.File {
    /// Claude's comments on lines that aren't in the diff
    var orphanComments: [Review.Comment] {
        comments.filter { comment in
            !hunks.contains { $0.lines.contains { $0.side == comment.side && $0.number == comment.line } }
        }
    }

    /// Whether it has anything above its hunks
    var hasIntro: Bool { note != nil || skipped != nil || !orphanComments.isEmpty }
}

/// What's above a file's hunks: its note, why it isn't shown, comments off the diff
struct FileIntro: View {
    let file: Review.File
    let colors: ReviewColors

    var body: some View {
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
        ForEach(file.orphanComments) { comment in
            ClaudeRow(text: comment.text, colors: colors, gutter: file.gutterWidth)
                .padding(.top, 6)
        }
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
}

struct FileHeader: View {
    let file: Review.File
    let colors: ReviewColors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            pathText
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(1)
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(colors.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
            PriorityMark(priority: file.priority, colors: colors)
            Counts(file: file, colors: colors)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.hairline).frame(height: 1) }
    }

    private var pathText: Text {
        let name = (file.path as NSString).lastPathComponent
        let dir = String(file.path.dropLast(name.count))
        return Text(dir).foregroundColor(colors.dim) + Text(name).fontWeight(.semibold)
    }

    private var status: String? {
        switch file.status {
        case "untracked": return "untracked"
        case "added": return "new"
        case "deleted": return "deleted"
        case "renamed": return file.oldPath.map { "from \(($0 as NSString).lastPathComponent)" } ?? "renamed"
        default: return nil
        }
    }
}

private struct Counts: View {
    let file: Review.File
    let colors: ReviewColors

    var body: some View {
        if let added = file.added, let removed = file.removed {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(colors.plus)
                Text("−\(removed)").foregroundStyle(colors.minus)
            }
            .font(.system(size: 12, design: .monospaced))
            .fixedSize()
        }
    }
}

// MARK: - A hunk

/// One hunk: its summary line, then its lines, numbers in a column of their own beside the
/// code (which scrolls sideways), and the comments as rows across both, over spaces left
/// for them in the two columns. The columns are equatable: hovering, picking and typing
/// don't rebuild them.
struct HunkView: View, Equatable {
    let file: Review.File
    let hunk: Review.Hunk
    let key: String
    let colors: ReviewColors
    let gutter: CGFloat
    let open: Bool
    let showPriority: Bool
    /// The user's comments on this file
    let comments: [ReviewUserComment]
    /// The comment being written, if it's on this file
    let editing: ReviewView.EditTarget?
    let picking: ReviewView.Picking?
    let drafts: ReviewDrafts
    let measures: CommentHeights
    let actions: PageActions

    enum PickEvent { case began(Int), moved(Int), ended }

    init(file: Review.File, hunk: Review.Hunk, key: String, colors: ReviewColors, gutter: CGFloat, open: Bool,
         showPriority: Bool, comments: [ReviewUserComment], editing: ReviewView.EditTarget?,
         picking: ReviewView.Picking?, drafts: ReviewDrafts, measures: CommentHeights, actions: PageActions) {
        self.file = file
        self.hunk = hunk
        self.key = key
        self.colors = colors
        self.gutter = gutter
        self.open = open
        self.showPriority = showPriority
        self.comments = comments
        self.editing = editing
        self.picking = picking
        self.drafts = drafts
        self.measures = measures
        self.actions = actions
        _heights = State(initialValue: measures[key])
    }

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.open == b.open && a.showPriority == b.showPriority && a.colors == b.colors
            && a.gutter == b.gutter && a.comments == b.comments && a.editing == b.editing && a.picking == b.picking
    }

    /// Comment rows' heights, measured
    @State private var heights: [String: CGFloat] = [:]
    /// The line under the pointer: only its light watches it, so hovering (and scrolling
    /// under a still pointer) doesn't rebuild the hunk
    @State private var hover = HoveredLine()
    @State private var viewport: CGFloat = 0

    static let rowHeight: CGFloat = 19
    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if open {
                let layout = HunkLayout(items: items, heights: heights)
                let style = CodeStyle.of(colors)
                HStack(alignment: .top, spacing: 0) {
                    LinesDrawing(lines: DrawnLines(key: key, lines: hunk.lines, tops: layout.lineTops, part: .numbers(width: gutter), style: style))
                        .frame(width: gutter, height: layout.height)
                        .contentShape(Rectangle())
                        .gesture(gutterGesture(layout))
                    #if os(macOS)
                    // As wide as the longest line, or the room there is, in AppKit's scroll
                    // view: SwiftUI's kept the page's vertical swipes
                    SidewaysCode(
                        lines: DrawnLines(key: key, lines: hunk.lines, tops: layout.lineTops, part: .code, style: style),
                        width: max(viewport - gutter, codeWidth)
                    )
                    .frame(height: layout.height)
                    #else
                    ScrollView(.horizontal, showsIndicators: false) {
                        // As wide as the longest line, or the room there is
                        LinesDrawing(lines: DrawnLines(key: key, lines: hunk.lines, tops: layout.lineTops, part: .code, style: style))
                            .frame(width: max(viewport - gutter, codeWidth), height: layout.height)
                            .contentShape(Rectangle())
                            // On the phone a tap anywhere on a line comments on it
                            .gesture(SpatialTapGesture().onEnded { tap in
                                if let index = layout.line(at: tap.location.y) { actions.edit(file.path, [hunk.lines[index]], nil) }
                            })
                    }
                    #endif
                }
                // Not GeometryReaders: SwiftUI runs those again whenever the view moves on
                // screen, so on every frame of a scroll
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                .overlay(alignment: .topLeading) { lights(layout).allowsHitTesting(false) }
                #if os(macOS)
                // Its + takes a click, as the line's number does
                .overlay(alignment: .topLeading) {
                    if picking == nil {
                        HoverLight(hover: hover, layout: layout, gutter: gutter, colors: colors, plus: editing == nil) { index in
                            actions.edit(file.path, [hunk.lines[index]], nil)
                        }
                    }
                }
                #endif
                .overlay(alignment: .topLeading) { commentRows(layout) }
                #if os(macOS)
                .onContinuousHover { phase in
                    var index: Int?
                    if case .active(let at) = phase { index = layout.line(at: at.y, exactly: true) }
                    if hover.index != index { hover.index = index }
                }
                #endif
            }
        }
        .padding(.top, 6)
    }

    /// The longest line's width in the code's monospaced font
    private var codeWidth: CGFloat {
        let longest = hunk.lines.map { $0.text.count + $0.text.filter { $0 == "\t" }.count * 3 }.max() ?? 0
        return CGFloat(longest) * 7.6 + 24
    }

    private var summary: some View {
        Button { actions.toggle(key) } label: {
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

    /// The rows in order: each line, then the comments on it (Claude's, the user's, the one
    /// being written)
    private var items: [HunkLayout.Item] {
        var items: [HunkLayout.Item] = []
        for (index, line) in hunk.lines.enumerated() {
            items.append(.line(index))
            for comment in file.comments where comment.side == line.side && comment.line == line.number {
                items.append(.claude(comment))
            }
            for mine in comments where mine.side == line.side && mine.line == line.number {
                items.append(editing?.existing == mine.id ? .editor : .mine(mine))
            }
            if let editing, editing.existing == nil, editing.last.id == line.id {
                items.append(.editor)
            }
        }
        return items
    }

    /// The lines being picked or commented on
    @ViewBuilder
    private func lights(_ layout: HunkLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if let picking {
                band(layout, min(picking.anchor, picking.current), max(picking.anchor, picking.current), 0.10)
            } else if let editing, editing.existing == nil,
                      let first = hunk.lines.firstIndex(where: { $0.id == editing.lines[0].id }),
                      let last = hunk.lines.firstIndex(where: { $0.id == editing.last.id }) {
                band(layout, first, last, 0.10)
            }
        }
    }

    private func band(_ layout: HunkLayout, _ first: Int, _ last: Int, _ opacity: Double) -> some View {
        HunkView.band(layout, first, last, colors.fg.opacity(opacity))
    }

    static func band(_ layout: HunkLayout, _ first: Int, _ last: Int, _ color: Color) -> some View {
        let top = layout.y(ofLine: first)
        let bottom = layout.y(ofLine: last) + rowHeight
        return color
            .frame(height: bottom - top)
            .frame(maxWidth: .infinity)
            .offset(y: top)
    }

    /// The comment rows, across the numbers and the code, over the space left for them
    private func measured(_ row: String, _ height: CGFloat) {
        guard heights[row] != height else { return }
        heights[row] = height
        measures[key] = heights
    }

    /// How far down the hunk's lines a line is (its id), from the comments as measured
    func top(ofLine id: Int) -> CGFloat? {
        hunk.lines.firstIndex { $0.id == id }.map { HunkLayout(items: items, heights: measures[key]).y(ofLine: $0) }
    }

    private func commentRows(_ layout: HunkLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.placed.filter { !$0.item.isLine }, id: \.item.key) { placed in
                commentRow(placed.item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [key = placed.item.key] height in
                        measured(key, height)
                    }
                    .offset(y: placed.y)
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ item: HunkLayout.Item) -> some View {
        switch item {
        case .claude(let comment):
            ClaudeRow(text: comment.text, colors: colors, gutter: gutter)
        case .mine(let mine):
            MineRow(comment: mine, colors: colors, gutter: gutter,
                    edit: { actions.edit(file.path, linesOf(mine), mine.id) }, delete: { actions.delete(mine.id) })
        case .editor:
            if let editing {
                EditorRow(target: editing, drafts: drafts, colors: colors, gutter: gutter, save: actions.save, cancel: actions.cancel)
            }
        case .line:
            EmptyView()
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

    /// A click on a number comments on its line; dragging down the numbers picks a run of
    /// lines. On the phone, hold a number, then drag.
    private func gutterGesture(_ layout: HunkLayout) -> some Gesture {
        let drag = DragGesture(minimumDistance: Self.touch ? 0 : 2)
            .onChanged { value in
                guard let at = layout.line(at: value.location.y) else { return }
                if picking == nil, let start = layout.line(at: value.startLocation.y) {
                    actions.pick(.began(start), file.path, hunk, key)
                }
                actions.pick(.moved(at), file.path, hunk, key)
            }
            .onEnded { _ in actions.pick(.ended, file.path, hunk, key) }
        #if os(iOS)
        return LongPressGesture(minimumDuration: 0.3).sequenced(before: drag)
            .onEnded { _ in actions.pick(.ended, file.path, hunk, key) }
        #else
        return drag.exclusively(before: SpatialTapGesture().onEnded { tap in
            if let index = layout.line(at: tap.location.y) { actions.edit(file.path, [hunk.lines[index]], nil) }
        })
        #endif
    }
}

/// Where a hunk's rows are: lines are a row high, comment rows as tall as they measured
struct HunkLayout: Equatable {
    enum Item: Equatable {
        case line(Int)
        case claude(Review.Comment)
        case mine(ReviewUserComment)
        case editor

        var key: String {
            switch self {
            case .line(let i): return "l\(i)"
            case .claude(let c): return "c\(c.id)"
            case .mine(let m): return "m\(m.id)"
            case .editor: return "editor"
            }
        }

        var isLine: Bool { if case .line = self { return true } else { return false } }
    }

    struct Placed: Equatable {
        let item: Item
        let y: CGFloat
        let height: CGFloat
    }

    let placed: [Placed]
    /// Each line's top, by index in the hunk
    let lineTops: [CGFloat]

    init(items: [Item], heights: [String: CGFloat]) {
        var placed: [Placed] = []
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for item in items {
            let height: CGFloat
            if case .line = item {
                height = HunkView.rowHeight
                tops.append(y)
            } else {
                height = heights[item.key] ?? 0
            }
            placed.append(Placed(item: item, y: y, height: height))
            y += height
        }
        self.placed = placed
        lineTops = tops
    }

    var height: CGFloat { placed.last.map { $0.y + $0.height } ?? 0 }

    func y(ofLine index: Int) -> CGFloat {
        index < lineTops.count ? lineTops[index] : 0
    }

    /// The line at a height in the hunk; over a comment row, the line it's on (or none,
    /// `exactly`)
    func line(at y: CGFloat, exactly: Bool = false) -> Int? {
        guard !lineTops.isEmpty, y >= 0 else { return nil }
        var lo = 0, hi = lineTops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineTops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        if exactly && y >= lineTops[lo] + HunkView.rowHeight { return nil }
        return lo
    }
}

private extension View {
    /// The Mac's text fields: Shift+Return (and Option+Return) adds a line, as in Messages
    /// and Slack; a vertical TextField otherwise ends editing on any Return. ⌘Return submits.
    /// Plain Return is left as it was.
    @ViewBuilder
    func newlineKeys(text: Binding<String>, submit: @escaping () -> Void) -> some View {
        #if os(macOS)
        onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                submit()
                return .handled
            }
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                text.wrappedValue += "\n"
                return .handled
            }
            return .ignored
        }
        #else
        self
        #endif
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
    /// Watched here only: a keystroke redraws this row, not the page
    @ObservedObject var drafts: ReviewDrafts
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
            TextField(placeholder, text: $drafts.draft, axis: .vertical)
                .newlineKeys(text: $drafts.draft, submit: save)
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

final class HoveredLine: ObservableObject {
    @Published var index: Int?
}

/// The hovered line's light, and its + by the number, which comments on the line
private struct HoverLight: View {
    @ObservedObject var hover: HoveredLine
    let layout: HunkLayout
    let gutter: CGFloat
    let colors: ReviewColors
    let plus: Bool
    let add: (Int) -> Void

    var body: some View {
        if let index = hover.index {
            ZStack(alignment: .topLeading) {
                HunkView.band(layout, index, index, colors.fg.opacity(0.04))
                    .allowsHitTesting(false)
                if plus {
                    Button { add(index) } label: { PlusMark(colors: colors) }
                        .buttonStyle(.plain)
                        .offset(x: gutter + 4, y: layout.y(ofLine: index) + 0.5)
                }
            }
        }
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
struct ReviewColors: Equatable {
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

    /// A theme's colours, worked out from its text once
    @MainActor static func of(_ theme: Theme?) -> ReviewColors {
        let key = theme?.id ?? ""
        if let known = cache[key] { return known }
        let colors = ReviewColors(theme: theme)
        cache[key] = colors
        return colors
    }

    @MainActor private static var cache: [String: ReviewColors] = [:]

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

