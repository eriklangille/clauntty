import SwiftUI

/// A review from `clauntty review`, plainly: the files in reading order, their hunks
/// (skim and mechanical ones collapsed), the agent's comments under their lines, the
/// user's comments (tap a line), and Send. A stand-in for the real screen, to try the
/// command and the reply end to end (plans/2026-10-26-clauntty-code-review.md).
struct ReviewView: View {
    let review: Review
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var comments: [ReviewUserComment] = []
    @State private var note = ""
    @State private var opened: Set<String> = []
    @State private var editing: Editing?
    @State private var sending = false
    @State private var result: String?
    @State private var error: String?

    private struct Editing: Identifiable {
        let id = UUID()
        let path: String
        let line: Review.Line
        var existing: ReviewUserComment?
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(review.files) { file in
                        fileSection(file)
                    }
                    footer
                }
            }
            .navigationTitle(review.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu("Close") {
                        Button("Later") { close() }
                        Button("Discard Review", role: .destructive) { sessionManager.dismissReview(review) }
                    }
                }
            }
        }
        .sheet(item: $editing) { editing in
            CommentEditor(title: "\(name(editing.path)):\(editing.line.number ?? 0)",
                          code: editing.line.text,
                          text: editing.existing?.text ?? "") { text in
                save(text, for: editing)
            }
        }
        .alert("Sent", isPresented: Binding(get: { result != nil }, set: { if !$0 { finish() } })) {
            Button("OK") { finish() }
        } message: {
            Text(result ?? "")
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 600)
        #endif
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(review.range)
            Text("\(review.host) · \(review.repo)").foregroundStyle(.secondary)
            if let summary = review.summary {
                Text(summary).padding(.top, 6)
            }
            if review.untrackedMore > 0 {
                Text("\(review.untrackedMore) more untracked files not shown").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding()
    }

    private func fileSection(_ file: Review.File) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(file.path).font(.system(.subheadline, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text(file.priority.rawValue).foregroundStyle(.secondary)
                if let added = file.added, let removed = file.removed {
                    Text("+\(added)").foregroundStyle(.green)
                    Text("−\(removed)").foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            VStack(alignment: .leading, spacing: 2) {
                if file.status != "modified" {
                    Text(file.status == "renamed" ? "renamed from \(file.oldPath ?? "")" : file.status)
                }
                if let skipped = file.skipped {
                    Text("Not shown: \(skippedReason(skipped))")
                }
                if let note = file.note { Text(note).foregroundStyle(.primary) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)

            ForEach(file.comments.filter { comment in
                !file.hunks.contains { $0.lines.contains { $0.side == comment.side && $0.number == comment.line } }
            }) { comment in
                claudeComment(comment.text)
            }

            ForEach(file.hunks) { hunk in
                hunkView(hunk, in: file)
            }
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: Review.Hunk, in file: Review.File) -> some View {
        let key = "\(file.path)#\(hunk.id)"
        let open = !hunk.priority.collapsed || opened.contains(key)
        Button {
            if open { opened.remove(key) } else { opened.insert(key) }
        } label: {
            HStack {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                Text("@@ \(hunk.newStart) \(hunk.section)").lineLimit(1)
                Spacer()
                if hunk.priority != file.priority { Text(hunk.priority.rawValue) }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hunk.priority.collapsed)

        if open {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        lineRow(line, in: file)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: Review.Line, in file: Review.File) -> some View {
        HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .frame(width: 14)
            Text(line.text)
                .fixedSize()
                .padding(.trailing, 16)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(minWidth: 0, alignment: .leading)
        .background(line.kind == .added ? Color.green.opacity(0.15) : line.kind == .removed ? Color.red.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            editing = Editing(path: file.path, line: line, existing: userComment(file.path, line))
        }

        ForEach(file.comments.filter { $0.side == line.side && $0.line == line.number }) { comment in
            claudeComment(comment.text)
        }
        if let mine = userComment(file.path, line) {
            commentRow(label: "You", text: mine.text)
                .onTapGesture { editing = Editing(path: file.path, line: line, existing: mine) }
        }
    }

    private func claudeComment(_ text: String) -> some View {
        commentRow(label: "Claude", text: text)
    }

    private func commentRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(.init(text)).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish review").font(.headline)
            Text(comments.isEmpty ? "No comments. Tap a line to add one." : "\(comments.count) comment\(comments.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("A note on the whole change (optional)", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                send()
            } label: {
                Text(sending ? "Sending…" : comments.isEmpty && note.isEmpty ? "Looks good" : "Send")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending)
        }
        .padding()
        .padding(.bottom, 24)
    }

    // MARK: Actions

    private func userComment(_ path: String, _ line: Review.Line) -> ReviewUserComment? {
        comments.first { $0.path == path && $0.side == line.side && $0.line == line.number }
    }

    private func save(_ text: String, for editing: Editing) {
        comments.removeAll { $0.id == editing.existing?.id }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let number = editing.line.number else { return }
        comments.append(ReviewUserComment(path: editing.path, side: editing.line.side, line: number,
                                          code: editing.line.text, text: trimmed))
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                let message = try await sessionManager.sendReview(review, note: note, comments: orderedComments)
                if let message { result = message } else { close() }
            } catch {
                self.error = "Couldn't send: \(error.localizedDescription)"
            }
            sending = false
        }
    }

    /// In the order of the page: by file, then line
    private var orderedComments: [ReviewUserComment] {
        let order = Dictionary(uniqueKeysWithValues: review.files.enumerated().map { ($1.path, $0) })
        return comments.sorted { (order[$0.path] ?? 0, $0.line) < (order[$1.path] ?? 0, $1.line) }
    }

    private func close() {
        sessionManager.closeReview(review)
    }

    private func finish() {
        result = nil
        close()
    }

    private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func skippedReason(_ reason: String) -> String {
        switch reason {
        case "large": return "too large"
        case "lockfile": return "lockfile"
        case "generated": return "generated"
        case "minified": return "minified"
        default: return "binary"
        }
    }
}

/// Write or change a comment on a line
private struct CommentEditor: View {
    let title: String
    let code: String
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                TextField("Comment", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focused)
                Spacer()
            }
            .padding()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 240)
        #endif
    }
}
