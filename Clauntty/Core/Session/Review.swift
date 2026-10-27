import Foundation

// MARK: - Bundle

/// A code change from `clauntty review` (rtach's review.zig): the diff, each file's old
/// and new contents, and the agent's notes, in ~/.clauntty/reviews/<id>.json on the host.
/// The user's comments go back to <id>.reply, which the waiting command prints.
struct ReviewBundle: Decodable {
    let id: String
    /// The pane that ran it: the comments are typed there if the command is gone
    let pane: String
    let repo: String
    let base: String
    /// What's compared, said plainly: `HEAD~1 (e5301ec) → HEAD (493fa38)`
    let range: String
    let workingTree: Bool
    let notes: ReviewNotes
    let diff: String
    let files: [File]
    /// Untracked files past the 50 rtach bundles
    let untrackedMore: Int

    struct File: Decodable {
        let path: String
        let oldPath: String?
        /// added, modified, deleted, renamed, untracked
        let status: String
        let old: String?
        let new: String?
        let added: Int?
        let removed: Int?
        /// Collapsed, with no contents or diff: large, binary, generated, lockfile, minified
        let skipped: String?
    }

    static func decode(_ data: Data) throws -> ReviewBundle {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewBundle.self, from: data)
    }
}

/// What the agent wrote. It writes it by hand, so a field that's wrong is left out
/// rather than failing the whole review.
struct ReviewNotes: Decodable {
    var title: String?
    var summary: String?
    var files: [FileNote] = []
    var comments: [Comment] = []

    struct FileNote: Decodable {
        let path: String
        var priority: ReviewPriority?
        var note: String?
        var hunks: [HunkNote] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            priority = try? c.decodeIfPresent(ReviewPriority.self, forKey: .priority)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
            hunks = (try? c.decodeIfPresent([Lenient<HunkNote>].self, forKey: .hunks))?.compactMap(\.value) ?? []
        }
        enum CodingKeys: String, CodingKey { case path, priority, note, hunks }
    }

    struct HunkNote: Decodable {
        var line: Int?
        var match: String?
        var priority: ReviewPriority
    }

    struct Comment: Decodable {
        let path: String
        var line: Int?
        var match: String?
        var side: ReviewSide?
        let text: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        files = (try? c.decodeIfPresent([Lenient<FileNote>].self, forKey: .files))?.compactMap(\.value) ?? []
        comments = (try? c.decodeIfPresent([Lenient<Comment>].self, forKey: .comments))?.compactMap(\.value) ?? []
    }
    enum CodingKeys: String, CodingKey { case title, summary, files, comments }
}

/// An array element that's dropped when it doesn't decode
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum ReviewPriority: String, Decodable, Comparable, CaseIterable {
    case critical, review, skim, mechanical

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Collapsed until opened
    var collapsed: Bool { self == .skim || self == .mechanical }
}

enum ReviewSide: String, Decodable {
    case new, old
}

// MARK: - Review

/// A review ready to show: the files in the order to read them, their hunks and the
/// agent's comments placed on their lines
struct Review: Identifiable {
    let id: String
    let pane: String
    /// The session it came through, to send the reply over
    let sessionId: UUID
    let host: String
    let title: String
    let summary: String?
    let repo: String
    let range: String
    let workingTree: Bool
    let files: [File]
    let untrackedMore: Int

    struct File: Identifiable {
        var id: String { path }
        let path: String
        let oldPath: String?
        let status: String
        let priority: ReviewPriority
        let note: String?
        let added: Int?
        let removed: Int?
        let skipped: String?
        let binary: Bool
        let hunks: [Hunk]
        /// The agent's comments, on lines of these hunks or (when their line isn't in
        /// the diff) on the file
        let comments: [Comment]

        var name: String { (path as NSString).lastPathComponent }
    }

    struct Hunk: Identifiable {
        let id: Int
        let oldStart: Int
        let newStart: Int
        /// The function or section it's in, from git's `@@` line
        let section: String
        let priority: ReviewPriority
        let lines: [Line]
    }

    struct Line: Identifiable, Equatable {
        enum Kind { case context, added, removed }
        let id: Int
        let kind: Kind
        let text: String
        let old: Int?
        let new: Int?
        /// Highlighted from the whole file: removed lines from the old one, the rest from
        /// the new. Nil without a grammar or the file's contents.
        var runs: [HighlightedText.Run]?

        var side: ReviewSide { kind == .removed ? .old : .new }
        var number: Int? { kind == .removed ? old : new }
    }

    struct Comment: Identifiable, Equatable {
        let id: Int
        let side: ReviewSide
        /// Nil when its line isn't in the diff
        let line: Int?
        let text: String
    }

    var commentCount: Int { files.reduce(0) { $0 + $1.comments.count } }
}

extension Review {
    init(bundle: ReviewBundle, sessionId: UUID, host: String) {
        let parsed = ReviewDiff.parse(bundle.diff)
        let notes = bundle.notes
        let order = Dictionary(notes.files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        var lineId = 0
        var commentId = 0

        var files: [(file: File, order: Int)] = []
        for (index, entry) in bundle.files.enumerated() {
            let diff = parsed.first { $0.newPath == entry.path || ($0.status == "deleted" && $0.oldPath == entry.path) }
            let note = notes.files.first { $0.path == entry.path || (entry.oldPath != nil && $0.path == entry.oldPath) }
            let binary = entry.skipped == "binary" || diff?.binary == true
            // Unlisted: skim, or mechanical for a binary (a rebuilt artifact)
            let priority = note?.priority ?? (binary ? .mechanical : .skim)
            let lines = Contents(old: entry.old, new: entry.new)
            let highlighted = (old: entry.old.flatMap { Highlighter.shared.highlight($0, path: entry.oldPath ?? entry.path) },
                               new: entry.new.flatMap { Highlighter.shared.highlight($0, path: entry.path) })

            func lineOf(_ side: ReviewSide, _ match: String) -> Int? {
                lines.lineOf(side, match, in: diff?.hunks ?? [])
            }

            let diffHunks = diff?.hunks ?? []
            let hunks: [Hunk] = diffHunks.enumerated().map { i, hunk in
                // The most important mark in it. A file that's one hunk (a new file) keeps
                // the file's: a mark meant for part of it would collapse all of it.
                let marked = diffHunks.count < 2 ? nil : note?.hunks.filter { mark in
                    guard let line = mark.line ?? mark.match.flatMap({ lineOf(.new, $0) ?? lineOf(.old, $0) }) else { return false }
                    return hunk.contains(line)
                }.map(\.priority).min()
                let rows = hunk.lines.map { raw -> Line in
                    lineId += 1
                    let source = raw.kind == .removed ? highlighted.old : highlighted.new
                    let number = raw.kind == .removed ? raw.old : raw.new
                    // Only if the file's line is the diff's: a file changed since would be off
                    let runs = number.flatMap { n in source.flatMap { n - 1 < $0.lines.count ? $0.lines[n - 1] : nil } }
                        .flatMap { $0.map(\.text).joined() == raw.text ? $0 : nil }
                    return Line(id: lineId, kind: raw.kind, text: raw.text, old: raw.old, new: raw.new, runs: runs)
                }
                return Hunk(id: i, oldStart: hunk.oldStart, newStart: hunk.newStart, section: hunk.section,
                            priority: marked ?? priority, lines: rows)
            }

            let comments = notes.comments.filter { $0.path == entry.path }.map { c -> Comment in
                let side = c.side ?? .new
                commentId += 1
                return Comment(id: commentId, side: side, line: c.line ?? c.match.flatMap { lineOf(side, $0) }, text: c.text)
            }

            let file = File(path: entry.path, oldPath: entry.oldPath, status: entry.status, priority: priority,
                            note: note?.note, added: entry.added, removed: entry.removed, skipped: entry.skipped,
                            binary: binary, hunks: hunks, comments: comments)
            files.append((file, order[file.path] ?? 10_000 + index))
        }
        files.sort { ($0.file.priority, $0.order) < ($1.file.priority, $1.order) }

        self.init(id: bundle.id, pane: bundle.pane, sessionId: sessionId, host: host,
                  title: notes.title ?? "Review", summary: notes.summary, repo: bundle.repo,
                  range: bundle.range, workingTree: bundle.workingTree, files: files.map(\.file),
                  untrackedMore: bundle.untrackedMore)
    }
}

/// A file's old and new contents by line, for finding a `match`
private struct Contents {
    let old: [Substring]
    let new: [Substring]

    init(old: String?, new: String?) {
        self.old = old?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        self.new = new?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
    }

    /// The first line on `side` with `match` in it: in the diff, else anywhere in the file.
    /// The diff's own text stands in for a file that came without contents.
    func lineOf(_ side: ReviewSide, _ match: String, in hunks: [ReviewDiff.Hunk]) -> Int? {
        let needle = match.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        for hunk in hunks {
            for line in hunk.lines {
                guard let no = side == .new ? line.new : line.old else { continue }
                if side == .old && line.kind != .removed { continue }
                if line.text.contains(needle) { return no }
            }
        }
        let lines = side == .new ? new : old
        return lines.firstIndex { $0.contains(needle) }.map { $0 + 1 }
    }
}

// MARK: - Diff

/// git's unified diff, by file
enum ReviewDiff {
    struct File {
        var oldPath: String
        var newPath: String
        var status = "modified"
        var binary = false
        var hunks: [Hunk] = []
    }

    struct Hunk {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String
        var lines: [(kind: Review.Line.Kind, text: String, old: Int?, new: Int?)] = []

        func contains(_ line: Int) -> Bool {
            (line >= newStart && line < newStart + max(newCount, 1)) ||
                (newCount == 0 && line >= oldStart && line < oldStart + max(oldCount, 1))
        }
    }

    static func parse(_ text: String) -> [File] {
        var files: [File] = []
        var inHunk = false
        var oldNo = 0
        var newNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                let (a, b) = headerPaths(line)
                files.append(File(oldPath: a, newPath: b))
                inHunk = false
                continue
            }
            guard !files.isEmpty else { continue }
            let i = files.count - 1
            if !inHunk {
                if line.hasPrefix("new file mode") { files[i].status = "added" }
                else if line.hasPrefix("deleted file mode") { files[i].status = "deleted" }
                else if line.hasPrefix("rename from ") { files[i].status = "renamed"; files[i].oldPath = String(line.dropFirst(12)) }
                else if line.hasPrefix("rename to ") { files[i].newPath = String(line.dropFirst(10)) }
                else if line.hasPrefix("Binary files ") { files[i].binary = true }
                else if line.hasPrefix("--- ") { if line != "--- /dev/null" { files[i].oldPath = path(line.dropFirst(4)) } }
                else if line.hasPrefix("+++ ") { if line != "+++ /dev/null" { files[i].newPath = path(line.dropFirst(4)) } }
            }
            if line.hasPrefix("@@"), let hunk = hunkHeader(line) {
                files[i].hunks.append(hunk)
                oldNo = hunk.oldStart
                newNo = hunk.newStart
                inHunk = true
            } else if inHunk, let first = line.first, first == " " || first == "+" || first == "-" {
                let text = String(line.dropFirst())
                let h = files[i].hunks.count - 1
                switch first {
                case "+":
                    files[i].hunks[h].lines.append((.added, text, nil, newNo)); newNo += 1
                case "-":
                    files[i].hunks[h].lines.append((.removed, text, oldNo, nil)); oldNo += 1
                default:
                    files[i].hunks[h].lines.append((.context, text, oldNo, newNo)); oldNo += 1; newNo += 1
                }
            }
        }
        return files
    }

    /// `a/x b/x` from `diff --git a/x b/x`. A path with a space is ambiguous here; the
    /// `---`/`+++` lines that follow say it for certain (rtach sets core.quotePath=false).
    private static func headerPaths(_ line: String) -> (String, String) {
        let rest = line.dropFirst("diff --git ".count)
        let half = rest.count / 2
        let a = rest.prefix(half)
        let b = rest.suffix(rest.count - half - 1)
        if a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) {
            return (String(a.dropFirst(2)), String(b.dropFirst(2)))
        }
        return (String(rest), String(rest))
    }

    /// `a/path` (or `b/path`), git's tab-terminated form for names with spaces
    private static func path(_ field: Substring) -> String {
        var p = field
        if let tab = p.firstIndex(of: "\t") { p = p[..<tab] }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p = p.dropFirst(2) }
        return String(p)
    }

    /// `@@ -12,7 +12,9 @@ func resume()`
    private static func hunkHeader(_ line: String) -> Hunk? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@" else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",")
            guard let start = Int(nums.first ?? "") else { return nil }
            return (start, nums.count > 1 ? Int(nums[1]) ?? 1 : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return Hunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1,
                    section: parts.count > 4 ? String(parts[4]) : "")
    }
}

// MARK: - Reply

/// The user's comment on a line, or on a run of lines
struct ReviewUserComment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let side: ReviewSide
    /// The last line; `from` the first when it's a run
    let line: Int
    var from: Int?
    /// The lines' code, for the report
    let code: String
    var text: String
}

enum ReviewReply {
    /// What the waiting command prints, and the agent reads: the same as the web
    /// prototype's, so the skill's description of it holds
    static func report(title: String, note: String, comments: [ReviewUserComment]) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ["Review of \"\(title)\": \(comments.isEmpty && note.isEmpty ? "looks good" : "comments")"]
        if !note.isEmpty { out += ["", note] }
        for c in comments {
            let at = c.from.map { "\($0)-\(c.line)" } ?? "\(c.line)"
            let removed = c.side == .old ? " (removed line\(c.from != nil ? "s" : ""))" : ""
            let code = c.code.split(separator: "\n", omittingEmptySubsequences: false)
            let indent = code.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            out += ["", "\(c.path):\(at)\(removed)"]
            out += code.map { line in
                var quoted = "  > " + line.dropFirst(min(indent, line.count))
                while quoted.last == " " { quoted.removeLast() }
                return quoted
            }
            out.append("  " + c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  "))
        }
        return out.joined(separator: "\n")
    }

    /// `<unix ms>-<pid>-<index>`: digits and dashes, so safe in a shell command
    static func isValidId(_ id: String) -> Bool {
        ImageInbox.isValidId(id)
    }

    /// Lists reviews waiting on the host, one id per line
    static let listCommand = #"sh -c 'cd ~/.clauntty/reviews 2>/dev/null || exit 0; for f in [0-9]*.json; do [ -f "$f" ] && echo "${f%.json}"; done; exit 0'"#

    static func bundlePath(_ id: String) -> String { "~/.clauntty/reviews/\(id).json" }

    /// Hands the report to the waiting command: it takes `<id>.reply` by renaming
    /// it, so the reply still being there after a few seconds means nobody is waiting.
    /// Then whoever renames it first wins, so it's never both delivered and given up on.
    /// Prints `delivered`, `gone` (comments go into the pane instead) or `answered` (the
    /// review was closed, e.g. sent from another device).
    static func sendScript(_ id: String, report: String) -> String {
        """
        f=~/.clauntty/reviews/\(id)
        [ -f "$f.json" ] || { echo answered; exit 0; }
        echo \(Data(report.utf8).base64EncodedString()) | base64 -d > "$f.reply.tmp" && mv -f "$f.reply.tmp" "$f.reply" || exit 1
        i=0
        while [ $i -lt 15 ]; do
          [ -f "$f.reply" ] || { echo delivered; exit 0; }
          sleep 0.2 2>/dev/null || sleep 1
          i=$((i+1))
        done
        mv -f "$f.reply" "$f.withdrawn" 2>/dev/null || { echo delivered; exit 0; }
        rm -f "$f.withdrawn" "$f.json"
        echo gone
        """
    }

    /// Closes a review without comments: the waiting command says so and exits
    static func dismissCommand(_ id: String) -> String {
        "rm -f ~/.clauntty/reviews/\(id).json"
    }
}
