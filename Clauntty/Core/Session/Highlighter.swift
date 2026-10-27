import Foundation
import HighlightKit

/// What a piece of code is, for its colour. Captures from the queries ("keyword.return",
/// "function.method.call") come down to these few; the review colours them from the
/// terminal's theme.
enum TokenKind: UInt8, CaseIterable {
    case keyword, string, comment, constant, function, type, attribute, `operator`, punctuation

    /// Neovim's capture names, by their first part (the second for a few)
    static func from(capture: String) -> Capture {
        let parts = capture.split(separator: ".")
        guard let first = parts.first else { return .skip }
        switch first {
        // Not highlights: spell checking, concealing, and names a query uses internally
        case "spell", "nospell", "conceal", "conceal_lines", "injection", "local":
            return .skip
        case _ where first.hasPrefix("_"):
            return .skip
        case "none":
            return .plain
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass":
            return .kind(.keyword)
        case "string":
            return parts.count > 1 && (parts[1] == "escape" || parts[1] == "special") ? .kind(.constant) : .kind(.string)
        case "character":
            return .kind(.string)
        case "comment":
            return .kind(.comment)
        case "number", "float", "boolean", "constant":
            return .kind(.constant)
        case "function", "method", "constructor":
            return .kind(.function)
        case "type", "module", "namespace":
            return .kind(.type)
        case "attribute", "label":
            return .kind(.attribute)
        case "tag":
            return parts.count > 1 && parts[1] == "attribute" ? .kind(.attribute) : parts.count > 1 && parts[1] == "delimiter" ? .kind(.punctuation) : .kind(.keyword)
        case "operator":
            return .kind(.operator)
        case "punctuation":
            return .kind(.punctuation)
        case "variable":
            // `self`, `this`
            return parts.count > 1 && parts[1] == "builtin" ? .kind(.keyword) : .plain
        case "markup":
            guard parts.count > 1 else { return .plain }
            switch parts[1] {
            case "heading": return .kind(.keyword)
            case "raw": return .kind(.string)
            case "link": return .kind(.function)
            case "list": return .kind(.punctuation)
            case "quote": return .kind(.comment)
            default: return .plain
            }
        default:
            // variable.member, property, diff.plus, ...: the text's own colour
            return .plain
        }
    }

    enum Capture: Equatable {
        /// Not a highlight: leaves what's under it alone
        case skip
        /// Plain text: paints over what's under it (a variable inside a string)
        case plain
        case kind(TokenKind)
    }
}

/// Code split into lines, each a run of pieces of one kind
struct HighlightedText {
    struct Run: Equatable {
        let text: String
        let kind: TokenKind?
    }

    let lines: [[Run]]
}

/// Highlights whole files with tree-sitter and the grammars in HighlightKit. The whole file,
/// not a hunk: a hunk starts mid-string or mid-function, and parsed alone its colours are
/// wrong. Thread-safe; slow for big files, so call it off the main thread.
final class Highlighter: @unchecked Sendable {
    static let shared = Highlighter()

    final class Grammar {
        let name: String
        let language: OpaquePointer
        let highlightsSource: String
        let injectionsSource: String
        /// Compiled on first use: some take a while (SQL's, C++'s)
        fileprivate var query: HighlightQuery?
        fileprivate var queryError: String?
        fileprivate var injections: HighlightQuery??

        init(_ grammar: HKGrammar) {
            name = String(cString: grammar.name)
            language = grammar.language!()!
            highlightsSource = String(cString: grammar.highlights)
            injectionsSource = String(cString: grammar.injections)
        }
    }

    private let grammars: [Grammar]
    private let byExtension: [String: Grammar]
    private let byFilename: [String: Grammar]
    private let lock = NSLock()

    init() {
        var grammars: [Grammar] = []
        var byExtension: [String: Grammar] = [:]
        var byFilename: [String: Grammar] = [:]
        for i in 0..<Int(hk_grammar_count) {
            let entry = hk_grammar(UInt32(i)).pointee
            let grammar = Grammar(entry)
            grammars.append(grammar)
            for ext in String(cString: entry.extensions).split(separator: " ") { byExtension[String(ext)] = grammar }
            for name in String(cString: entry.filenames).split(separator: " ") { byFilename[String(name)] = grammar }
        }
        self.grammars = grammars
        self.byExtension = byExtension
        self.byFilename = byFilename
    }

    var names: [String] { grammars.map(\.name) }

    /// The grammar for a file, by its name, then its extension
    func grammar(forPath path: String) -> Grammar? {
        let name = (path as NSString).lastPathComponent
        if let grammar = byFilename[name] { return grammar }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : byExtension[ext]
    }

    func grammar(named name: String) -> Grammar? {
        grammars.first { $0.name == name }
    }

    /// The grammar's highlight query, compiled once. Nil (with the reason) if it doesn't
    /// compile against its grammar: a node or field the grammar doesn't have.
    func query(for grammar: Grammar) -> Result<HighlightQuery, HighlightQueryError> {
        lock.lock()
        defer { lock.unlock() }
        if let query = grammar.query { return .success(query) }
        if let error = grammar.queryError { return .failure(HighlightQueryError(message: error)) }
        switch HighlightQuery.compile(grammar.highlightsSource, language: grammar.language) {
        case .success(let query):
            grammar.query = query
            return .success(query)
        case .failure(let error):
            grammar.queryError = error.message
            return .failure(error)
        }
    }

    /// The grammar's injection query (where other languages are inside it), compiled
    /// once; nil if it has none or it doesn't compile
    private func injections(for grammar: Grammar) -> HighlightQuery? {
        lock.lock()
        defer { lock.unlock() }
        if let compiled = grammar.injections { return compiled }
        let source = grammar.injectionsSource
        let compiled = source.isEmpty ? nil : try? HighlightQuery.compile(source, language: grammar.language).get()
        grammar.injections = .some(compiled)
        return compiled
    }

    /// The grammar for a language named in an injection: a grammar's name, or what a
    /// Markdown fence's info string or a `<script type>` says ("ts", "text/javascript")
    func grammar(forLanguage raw: String) -> Grammar? {
        var name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = Self.languageAliases[name] ?? name
        return grammar(named: name) ?? byExtension[name]
    }

    private static let languageAliases: [String: String] = [
        "shell": "bash", "zsh": "bash", "sh": "bash", "console": "bash", "ecmascript": "javascript",
        "node": "javascript", "module": "javascript", "golang": "go", "py": "python", "python3": "python",
        "rb": "ruby", "c++": "cpp", "objective-c": "objc", "objectivec": "objc", "obj-c": "objc",
        "csharp": "c_sharp", "cs": "c_sharp", "c#": "c_sharp", "yml": "yaml", "md": "markdown",
        "docker": "dockerfile", "makefile": "make", "postgres": "sql", "postgresql": "sql", "psql": "sql",
        "pgsql": "sql", "plpgsql": "sql", "jsonc": "json", "html5": "html", "xhtml": "html",
    ]

    /// `text` in coloured runs, line by line; nil when there's no grammar for `path`
    func highlight(_ text: String, path: String) -> HighlightedText? {
        guard let grammar = grammar(forPath: path) else { return nil }
        return highlight(text, grammar: grammar)
    }

    func highlight(_ text: String, grammar: Grammar) -> HighlightedText? {
        guard case .success = query(for: grammar) else { return nil }
        let source = HighlightSource(Array(text.utf8))
        var canvas = HighlightCanvas(count: source.bytes.count)
        layer(grammar, ranges: nil, source: source, canvas: &canvas, depth: 0)
        return HighlightedText(lines: Self.lines(source.bytes, paint: canvas.paint))
    }

    /// Most nesting there is in practice: Markdown, its inline text, HTML in that
    private static let maxDepth = 3

    /// Parse (only `ranges` of the file, for an injected language), paint, then do the same
    /// for each language inside it, over what's painted
    private func layer(_ grammar: Grammar, ranges: [TSRange]?, source: HighlightSource, canvas: inout HighlightCanvas, depth: Int) {
        guard case .success(let query) = query(for: grammar), let parser = ts_parser_new() else { return }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, grammar.language) else { return }
        if let ranges {
            guard ranges.withUnsafeBufferPointer({ ts_parser_set_included_ranges(parser, $0.baseAddress, UInt32($0.count)) }) else { return }
        }
        let tree = source.bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ts_parser_parse_string(parser, nil, $0, UInt32(buffer.count))
            }
        }
        guard let tree else { return }
        defer { ts_tree_delete(tree) }
        query.paint(tree: tree, source: source.bytes, into: &canvas)

        guard depth < Self.maxDepth, let injectionQuery = injections(for: grammar) else { return }
        // Combined injections (all of a language's pieces parsed as one) by language;
        // the rest one by one
        var combined: [String: (Grammar, [TSRange])] = [:]
        for injection in injectionQuery.injections(tree: tree, source: source) {
            guard let inner = self.grammar(forLanguage: injection.language) else { continue }
            if injection.combined {
                combined[inner.name, default: (inner, [])].1.append(contentsOf: injection.ranges)
            } else {
                layer(inner, ranges: injection.ranges, source: source, canvas: &canvas, depth: depth + 1)
            }
        }
        for (inner, ranges) in combined.values {
            layer(inner, ranges: ranges.sorted { $0.start_byte < $1.start_byte }, source: source, canvas: &canvas, depth: depth + 1)
        }
    }

    /// Split into lines, and each line into runs of one kind
    private static func lines(_ bytes: [UInt8], paint: [UInt8]) -> [[HighlightedText.Run]] {
        var lines: [[HighlightedText.Run]] = []
        var lineStart = 0
        func run(_ a: Int, _ b: Int) -> HighlightedText.Run {
            let kind = paint[a] == HighlightQuery.plain ? nil : TokenKind(rawValue: paint[a])
            return .init(text: String(decoding: bytes[a..<b], as: UTF8.self), kind: kind)
        }
        for end in 0...bytes.count where end == bytes.count || bytes[end] == 0x0A {
            var runs: [HighlightedText.Run] = []
            var start = lineStart
            for k in lineStart..<end where paint[k] != paint[start] {
                // Only at a character's first byte: a capture never ends mid-character
                runs.append(run(start, k))
                start = k
            }
            if start < end || runs.isEmpty { runs.append(start < end ? run(start, end) : .init(text: "", kind: nil)) }
            lines.append(runs)
            lineStart = end + 1
        }
        return lines
    }
}

struct HighlightQueryError: Error {
    let message: String
}

/// The file being highlighted: its bytes, and where its lines start (for tree-sitter's
/// row and column points)
struct HighlightSource {
    let bytes: [UInt8]
    let lineStarts: [Int]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var starts = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(i + 1) }
        lineStarts = starts
    }

    func point(_ byte: Int) -> TSPoint {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= byte { lo = mid } else { hi = mid - 1 }
        }
        return TSPoint(row: UInt32(lo), column: UInt32(byte - lineStarts[lo]))
    }

    /// A byte from a row and column, clamped to the file
    func byte(row: Int, column: Int) -> Int {
        guard row >= 0 else { return 0 }
        guard row < lineStarts.count else { return bytes.count }
        return min(lineStarts[row] + max(column, 0), bytes.count)
    }

    func range(_ start: Int, _ end: Int) -> TSRange {
        TSRange(start_point: point(start), end_point: point(end), start_byte: UInt32(start), end_byte: UInt32(end))
    }
}

/// Each byte's kind and the priority it was painted with
struct HighlightCanvas {
    var paint: [UInt8]
    var priority: [Int16]

    init(count: Int) {
        paint = [UInt8](repeating: HighlightQuery.plain, count: count)
        priority = [Int16](repeating: 0, count: count)
    }
}

/// Another language inside a file: Markdown's fenced code, HTML's <script>
struct HighlightInjection {
    let language: String
    let ranges: [TSRange]
    /// Every piece of this language in the file parsed together, as one document
    let combined: Bool
}

/// A compiled highlight query: its captures' kinds, and each pattern's predicates and
/// priority (Neovim's `#set! priority`)
final class HighlightQuery: @unchecked Sendable {
    /// Paint for "no colour" (TokenKind's raw values are below it)
    static let plain: UInt8 = 255

    let pointer: OpaquePointer
    private let captures: [TokenKind.Capture]
    private let patterns: [Pattern]
    /// Regexes from `#match?` and `#lua-match?`, compiled once
    private var regexes: [String: NSRegularExpression?] = [:]
    private let regexLock = NSLock()

    private struct Pattern {
        var predicates: [Predicate] = []
        var priority = 100
        /// `#set! key value` (or `#set! key` for a flag): injection.language, injection.combined
        var settings: [String: String] = [:]
        /// `#offset! @capture start-row start-col end-row end-col`
        var offset: (Int, Int, Int, Int)?
    }

    private struct Predicate {
        let name: String
        /// Capture ids and strings, in order
        let args: [Arg]
    }

    private enum Arg {
        case capture(UInt32)
        case string(String)
    }

    /// Capture names, by id
    private let names: [String]

    private init(pointer: OpaquePointer, names: [String], patterns: [Pattern]) {
        self.pointer = pointer
        self.names = names
        captures = names.map(TokenKind.from(capture:))
        self.patterns = patterns
    }

    deinit { ts_query_delete(pointer) }

    static func compile(_ source: String, language: OpaquePointer) -> Result<HighlightQuery, HighlightQueryError> {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        let pointer = utf8.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ts_query_new(language, $0, UInt32(buffer.count), &errorOffset, &errorType)
            }
        }
        guard let pointer else {
            // The line it failed on, for the error
            let before = utf8.prefix(Int(errorOffset))
            let line = before.filter { $0 == 0x0A }.count + 1
            let rest = utf8.dropFirst(Int(errorOffset)).prefix { $0 != 0x0A }
            return .failure(HighlightQueryError(message: "error \(errorType.rawValue) at line \(line): \(String(decoding: rest, as: UTF8.self))"))
        }

        var names: [String] = []
        for id in 0..<ts_query_capture_count(pointer) {
            var length: UInt32 = 0
            names.append(string(ts_query_capture_name_for_id(pointer, id, &length)!, length))
        }

        var patterns: [Pattern] = []
        for index in 0..<ts_query_pattern_count(pointer) {
            var count: UInt32 = 0
            let steps = ts_query_predicates_for_pattern(pointer, index, &count)
            var pattern = Pattern()
            var current: [TSQueryPredicateStep] = []
            for i in 0..<Int(count) {
                let step = steps![i]
                guard step.type == TSQueryPredicateStepTypeDone else {
                    current.append(step)
                    continue
                }
                if let first = current.first, first.type == TSQueryPredicateStepTypeString {
                    var length: UInt32 = 0
                    let name = string(ts_query_string_value_for_id(pointer, first.value_id, &length)!, length)
                    let args: [Arg] = current.dropFirst().map { step in
                        if step.type == TSQueryPredicateStepTypeCapture { return .capture(step.value_id) }
                        var length: UInt32 = 0
                        return .string(string(ts_query_string_value_for_id(pointer, step.value_id, &length)!, length))
                    }
                    if name == "set!" {
                        // `#set! @capture key value` sets it for one capture: the same to us
                        let strings = args.compactMap { arg -> String? in if case .string(let s) = arg { return s } else { return nil } }
                        if let key = strings.first {
                            pattern.settings[key] = strings.count > 1 ? strings[1] : ""
                            if key == "priority", strings.count > 1, let n = Int(strings[1]) { pattern.priority = n }
                        }
                    } else if name == "offset!" {
                        let n = args.compactMap { arg -> Int? in if case .string(let s) = arg { return Int(s) } else { return nil } }
                        if n.count == 4 { pattern.offset = (n[0], n[1], n[2], n[3]) }
                    } else if name.hasSuffix("?") {
                        pattern.predicates.append(Predicate(name: name, args: args))
                    }
                }
                current = []
            }
            patterns.append(pattern)
        }
        return .success(HighlightQuery(pointer: pointer, names: names, patterns: patterns))
    }

    private static func string(_ pointer: UnsafePointer<CChar>, _ length: UInt32) -> String {
        String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    /// Paint each capture's kind (`plain` for none) Neovim's way: captures in order, inner
    /// nodes over outer ones and, for the same node, a later pattern over an earlier one; a
    /// higher priority over a lower one whatever the order
    func paint(tree: OpaquePointer, source: [UInt8], into canvas: inout HighlightCanvas) {
        struct Hit {
            let start: Int
            let end: Int
            let pattern: Int
            let capture: TokenKind.Capture
            let priority: Int
        }
        var hits: [Hit] = []
        forEachMatch(tree: tree, source: source) { patternIndex, nodes in
            for capture in nodes {
                let kind = captures[Int(capture.index)]
                guard kind != .skip else { continue }
                let start = Int(ts_node_start_byte(capture.node))
                let end = Int(ts_node_end_byte(capture.node))
                guard end > start else { continue }
                hits.append(Hit(start: start, end: end, pattern: patternIndex, capture: kind, priority: patterns[patternIndex].priority))
            }
        }
        hits.sort { ($0.start, -$0.end, $0.pattern) < ($1.start, -$1.end, $1.pattern) }

        for hit in hits {
            let value: UInt8
            switch hit.capture {
            case .kind(let kind): value = kind.rawValue
            default: value = Self.plain
            }
            let priority = Int16(clamping: hit.priority)
            for k in hit.start..<min(hit.end, source.count) where priority >= canvas.priority[k] {
                canvas.paint[k] = value
                canvas.priority[k] = priority
            }
        }
    }

    /// For an injection query: the other languages in the file and where they are
    func injections(tree: OpaquePointer, source: HighlightSource) -> [HighlightInjection] {
        var found: [HighlightInjection] = []
        forEachMatch(tree: tree, source: source.bytes) { patternIndex, nodes in
            let pattern = patterns[patternIndex]
            var language = pattern.settings["injection.language"]
            var ranges: [TSRange] = []
            for capture in nodes {
                switch names[Int(capture.index)] {
                case "injection.language":
                    language = text(capture.node, source.bytes)
                case "injection.content":
                    var start = Int(ts_node_start_byte(capture.node))
                    var end = Int(ts_node_end_byte(capture.node))
                    if let (r1, c1, r2, c2) = pattern.offset {
                        let a = ts_node_start_point(capture.node)
                        let b = ts_node_end_point(capture.node)
                        start = source.byte(row: Int(a.row) + r1, column: Int(a.column) + c1)
                        end = source.byte(row: Int(b.row) + r2, column: Int(b.column) + c2)
                    }
                    if end > start { ranges.append(source.range(start, end)) }
                default:
                    break
                }
            }
            guard let language, !language.isEmpty, !ranges.isEmpty else { return }
            found.append(HighlightInjection(language: language, ranges: ranges, combined: pattern.settings["injection.combined"] != nil))
        }
        return found
    }

    /// Each match whose predicates hold: its pattern and captured nodes
    private func forEachMatch(tree: OpaquePointer, source: [UInt8], _ body: (Int, [TSQueryCapture]) -> Void) {
        let cursor = ts_query_cursor_new()!
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_exec(cursor, pointer, ts_tree_root_node(tree))
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            let pattern = patterns[Int(match.pattern_index)]
            let nodes = (0..<Int(match.capture_count)).map { match.captures[$0] }
            guard pattern.predicates.allSatisfy({ satisfied($0, nodes: nodes, source: source) }) else { continue }
            body(Int(match.pattern_index), nodes)
        }
    }

    // MARK: Predicates

    private func satisfied(_ predicate: Predicate, nodes: [TSQueryCapture], source: [UInt8]) -> Bool {
        var name = predicate.name
        let negated = name.hasPrefix("not-")
        if negated { name.removeFirst(4) }
        // `any-eq?`: true if any of a quantified capture's nodes passes, not all
        let any = name.hasPrefix("any-") && name != "any-of?"
        if any { name.removeFirst(4) }

        guard case .capture(let id) = predicate.args.first else { return true }
        let targets = nodes.filter { $0.index == id }.map(\.node)
        guard !targets.isEmpty else { return true }
        let rest = Array(predicate.args.dropFirst())
        let strings = rest.compactMap { arg -> String? in if case .string(let s) = arg { return s } else { return nil } }

        let test: (TSNode) -> Bool
        switch name {
        case "eq?":
            if case .capture(let other)? = rest.first {
                let otherText = nodes.first { $0.index == other }.map { text($0.node, source) }
                test = { self.text($0, source) == otherText }
            } else {
                test = { self.text($0, source) == strings.first }
            }
        case "any-of?":
            let set = Set(strings)
            test = { set.contains(self.text($0, source)) }
        case "match?", "vim-match?":
            guard let pattern = strings.first, let regex = regex(pattern, lua: false) else { return true }
            test = { Self.matches(regex, self.text($0, source)) }
        case "lua-match?":
            guard let pattern = strings.first, let regex = regex(pattern, lua: true) else { return true }
            test = { Self.matches(regex, self.text($0, source)) }
        case "contains?":
            test = { node in let t = self.text(node, source); return strings.contains { t.contains($0) } }
        case "has-ancestor?":
            let types = Set(strings)
            test = { node in
                var parent = ts_node_parent(node)
                while !ts_node_is_null(parent) {
                    if types.contains(String(cString: ts_node_type(parent))) { return true }
                    parent = ts_node_parent(parent)
                }
                return false
            }
        case "has-parent?":
            let types = Set(strings)
            test = { node in
                let parent = ts_node_parent(node)
                return !ts_node_is_null(parent) && types.contains(String(cString: ts_node_type(parent)))
            }
        case "kind-eq?":
            let types = Set(strings)
            test = { types.contains(String(cString: ts_node_type($0))) }
        default:
            // Unknown to us: don't let it hide the pattern
            return true
        }
        let passed = any ? targets.contains(where: test) : targets.allSatisfy(test)
        return negated ? !passed : passed
    }

    private func text(_ node: TSNode, _ source: [UInt8]) -> String {
        let start = Int(ts_node_start_byte(node))
        let end = min(Int(ts_node_end_byte(node)), source.count)
        return start < end ? String(decoding: source[start..<end], as: UTF8.self) : ""
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func regex(_ pattern: String, lua: Bool) -> NSRegularExpression? {
        let key = (lua ? "lua:" : "re:") + pattern
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = regexes[key] { return cached }
        let source = lua ? Self.luaToRegex(pattern) : Self.vimToRegex(pattern)
        let regex = try? NSRegularExpression(pattern: source)
        regexes[key] = regex
        return regex
    }

    /// A Lua pattern as a regular expression: `%a` classes, `%` escapes, `-` (lazy `*`)
    static func luaToRegex(_ pattern: String) -> String {
        var out = ""
        var chars = Array(pattern)[...]
        var inSet = false
        while let c = chars.popFirst() {
            switch c {
            case "%":
                guard let next = chars.popFirst() else { break }
                switch next {
                case "a": out += inSet ? "A-Za-z" : "[A-Za-z]"
                case "d": out += inSet ? "0-9" : "[0-9]"
                case "l": out += inSet ? "a-z" : "[a-z]"
                case "u": out += inSet ? "A-Z" : "[A-Z]"
                case "s": out += "\\s"
                case "w": out += inSet ? "A-Za-z0-9" : "[A-Za-z0-9]"
                case "x": out += inSet ? "0-9A-Fa-f" : "[0-9A-Fa-f]"
                case "p": out += inSet ? "!-/:-@\\[-`{-~" : "[!-/:-@\\[-`{-~]"
                case "c": out += inSet ? "\\x00-\\x1f" : "[\\x00-\\x1f]"
                default: out += NSRegularExpression.escapedPattern(for: String(next))
                }
            case "[":
                inSet = true
                out.append(c)
                if chars.first == "^" { out.append(chars.removeFirst()) }
            case "]":
                inSet = false
                out.append(c)
            case "-" where !inSet:
                out += "*?"
            case "\\", "{", "}", "|":
                out += "\\" + String(c)
            case "(", ")":
                out += inSet ? "\\" + String(c) : String(c)
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Neovim's `#match?` is a Vim regex; the queries use the part that's also an ICU one,
    /// apart from a leading `\v` ("very magic", which is ICU syntax already) and `\<`/`\>`
    static func vimToRegex(_ pattern: String) -> String {
        var p = pattern
        if p.hasPrefix("\\v") { p.removeFirst(2) }
        return p.replacingOccurrences(of: "\\<", with: "\\b").replacingOccurrences(of: "\\>", with: "\\b")
    }
}
