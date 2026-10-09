import Foundation

// Pure helpers for the voice agent: what terminal text it sees, which tab it means,
// and what a session costs. Foundation only, so they're easy to test.

// MARK: - Styling

/// Turns styled terminal text (VT/SGR sequences, from ghostty_surface_read_text_vt)
/// into plain text for the model. Styling that changes what text means is kept as
/// markers: dim text, which is how Claude Code draws placeholders and suggestions
/// (`Try "..."`), becomes [dim]…[/dim], and crossed-out text [strike]…[/strike].
/// Hidden (concealed) text is dropped, so it's never sent. Everything else
/// (colors, bold, cursor moves, links) is removed.
enum TerminalStyledText {
    static func markup(_ vt: String) -> String {
        let escape: Unicode.Scalar = "\u{1B}"
        let bell: Unicode.Scalar = "\u{07}"
        let scalars = Array(vt.unicodeScalars)
        var out = String.UnicodeScalarView()
        var style = Style()
        var dimOpen = false, strikeOpen = false

        // Bring the open markers in line with the wanted style
        func sync(dim: Bool, strike: Bool) {
            if strikeOpen && (!strike || dimOpen != dim) {
                out.append(contentsOf: "[/strike]".unicodeScalars)
                strikeOpen = false
            }
            if dimOpen && !dim {
                out.append(contentsOf: "[/dim]".unicodeScalars)
                dimOpen = false
            }
            if dim && !dimOpen {
                out.append(contentsOf: "[dim]".unicodeScalars)
                dimOpen = true
            }
            if strike && !strikeOpen {
                out.append(contentsOf: "[strike]".unicodeScalars)
                strikeOpen = true
            }
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == escape {
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                if next == "[" {
                    // CSI: parameters, then a final byte
                    var j = i + 2
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                    if j < scalars.count, scalars[j] == "m" {
                        style.apply(String(String.UnicodeScalarView(scalars[(i + 2)..<j])))
                    }
                    i = j + 1
                } else if next == "]" {
                    // OSC (e.g. hyperlinks): skip to BEL or ESC \
                    var j = i + 2
                    while j < scalars.count, scalars[j] != bell, scalars[j] != escape { j += 1 }
                    i = j < scalars.count && scalars[j] == bell ? j + 1 : j + 2
                } else {
                    i += 2
                }
                continue
            }
            i += 1
            switch c {
            case "\r":
                continue
            case "\n":
                // Markers never span lines, so each line reads on its own
                sync(dim: false, strike: false)
                out.append(c)
            default:
                if style.hidden { continue }
                sync(dim: style.dim, strike: style.strike)
                out.append(c)
            }
        }
        sync(dim: false, strike: false)
        return String(out)
    }

    private struct Style {
        var dim = false
        var strike = false
        var hidden = false

        mutating func apply(_ params: String) {
            let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            var k = 0
            while k < parts.count {
                let part = parts[k]
                switch Int(part.split(separator: ":").first ?? "") ?? 0 {
                case 0: self = Style()
                case 2: dim = true
                case 22: dim = false
                case 8: hidden = true
                case 28: hidden = false
                case 9: strike = true
                case 29: strike = false
                case 38, 48, 58:
                    // Colors: skip their arguments so "38;2;r;g;b" isn't read as dim and
                    // so on. The colon form (38:2:r:g:b) is a single part.
                    if !part.contains(":"), k + 1 < parts.count {
                        k += parts[k + 1] == "5" ? 2 : parts[k + 1] == "2" ? 4 : 0
                    }
                default:
                    break
                }
                k += 1
            }
        }
    }
}

// MARK: - Cleaning

/// Turns a terminal screen into the lines worth sending to the model: no box
/// drawing, block art or braille spinners, no trailing spaces, single blank lines.
enum TerminalTextCleaner {
    static func clean(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: raw.unicodeScalars.filter { !isDecoration($0) })
            var line = removeEmptyMarkers(String(scalars))
            while let last = line.last, last.isWhitespace { line.removeLast() }
            if line.allSatisfy({ $0.isWhitespace }) { line = "" }
            // One blank line between blocks, none at the start
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Drop markers around nothing (a dim border once its box drawing is gone) or
    /// only spaces, and markers closed and reopened back to back
    private static func removeEmptyMarkers(_ line: String) -> String {
        guard line.contains("[") else { return line }
        var result = line
        for marker in ["dim", "strike"] {
            result = result.replacingOccurrences(of: "[/\(marker)][\(marker)]", with: "")
            result = result.replacingOccurrences(of: #"\[\#(marker)\](\s*)\[/\#(marker)\]"#, with: "$1", options: .regularExpression)
        }
        return result
    }

    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x257F,  // box drawing (Claude Code's borders and rules)
             0x2580...0x259F,  // block elements (its logo)
             0x2800...0x28FF:  // braille (spinners)
            return true
        default:
            return false
        }
    }
}

// MARK: - New text since the last read

/// What a tab printed since the model last read it. Claude Code redraws its prompt
/// box and status line at the bottom, so "what comes after the last tail" doesn't
/// work; instead diff the two snapshots and return the lines that were added.
enum TerminalTextDiff {
    enum Kind: String {
        case first   // nothing read before: the recent lines
        case new     // lines added since the last read
        case reset   // too little in common (cleared screen): the recent lines
    }

    struct Result: Equatable {
        var kind: Kind
        var lines: [String]
        /// Lines left out at the start to stay under the limit
        var omitted: Int
    }

    static func newLines(previous: [String]?, current: [String], maxLines: Int = 80, window: Int = 400) -> Result {
        guard let previous, !previous.isEmpty else {
            return tail(of: current, kind: .first, maxLines: maxLines)
        }

        let old = Array(previous.suffix(window))
        let cur = Array(current.suffix(window))
        let matched = matchedIndices(old, cur)

        // Barely anything in common: the screen was cleared or replaced
        if cur.count >= 10 && old.count >= 10 && matched.count < 3 {
            return tail(of: current, kind: .reset, maxLines: maxLines)
        }

        let added = cur.indices.filter { !matched.contains($0) && !cur[$0].isEmpty }.map { cur[$0] }
        let omitted = max(0, added.count - maxLines)
        return Result(kind: .new, lines: Array(added.suffix(maxLines)), omitted: omitted)
    }

    private static func tail(of lines: [String], kind: Kind, maxLines: Int) -> Result {
        Result(kind: kind, lines: Array(lines.suffix(maxLines)), omitted: max(0, lines.count - maxLines))
    }

    /// Indices in `b` that are part of a longest common subsequence with `a`
    private static func matchedIndices(_ a: [String], _ b: [String]) -> Set<Int> {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        // lengths[i][j] = LCS of a[i...] and b[j...]
        var lengths = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                matched.insert(j)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }
}

// MARK: - Tabs

/// A terminal tab as the model sees it. Numbers follow the tab bar, terminals only.
struct VoiceTab: Equatable {
    let number: Int
    let title: String
    let name: String
    let host: String
}

enum VoiceTabResolver {
    enum Resolution: Equatable {
        case found(Int)          // index into the tabs
        case notFound
        case ambiguous([Int])
    }

    /// Resolve "2", "tab 2", "#2", or part of a title, connection name or host
    static func resolve(_ query: String, in tabs: [VoiceTab]) -> Resolution {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["tab ", "#"] where q.hasPrefix(prefix) {
            q = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !q.isEmpty else { return .notFound }

        if let number = Int(q) {
            if let index = tabs.firstIndex(where: { $0.number == number }) { return .found(index) }
            return .notFound
        }

        let exact = tabs.indices.filter { tabs[$0].title.lowercased() == q || tabs[$0].name.lowercased() == q }
        if exact.count == 1 { return .found(exact[0]) }

        let partial = tabs.indices.filter {
            tabs[$0].title.lowercased().contains(q) || tabs[$0].name.lowercased().contains(q) || tabs[$0].host.lowercased().contains(q)
        }
        switch partial.count {
        case 0: return .notFound
        case 1: return .found(partial[0])
        default: return .ambiguous(partial)
        }
    }
}

// MARK: - Cost

/// Estimated cost of a session. xAI reports no usage over the socket, so this uses
/// the published prices (checked 2026-10-08). A "text input" is a text message the
/// app adds to the conversation (the greeting cue, the one-minute warning); results
/// of the model's tool calls aren't billed. Checked against the xAI console: 12
/// sessions with 12 messages and 33 tool results were billed 10 text inputs.
struct VoiceCost: Equatable {
    static let dollarsPerMinute = 0.08
    static let dollarsPerTextInput = 0.004

    var seconds: TimeInterval = 0
    var textInputs: Int = 0

    var dollars: Double {
        seconds / 60 * Self.dollarsPerMinute + Double(textInputs) * Self.dollarsPerTextInput
    }

    /// "$0.19"
    var dollarsText: String {
        String(format: "$%.2f", dollars)
    }

    /// "2m 22s · 6 text inputs"
    var breakdownText: String {
        let total = Int(seconds)
        let time = total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
        return "\(time) · \(textInputs) text input\(textInputs == 1 ? "" : "s")"
    }
}

/// "12:41"
func voiceClockText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
