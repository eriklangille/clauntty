import Foundation

// Checks HighlightKit with the app's own Highlighter.swift, on the Mac
// (scripts/highlight-check.sh builds and runs it):
//
//   highlight-check queries              compile every grammar's query; list failures
//   highlight-check html OUT FILE...     render files to one HTML page, to look at

let args = Array(CommandLine.arguments.dropFirst())
let highlighter = Highlighter.shared

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

switch args.first {
case "queries":
    var failed = 0
    for name in highlighter.names {
        guard let grammar = highlighter.grammar(named: name) else { continue }
        let start = Date()
        switch highlighter.query(for: grammar) {
        case .success:
            print(String(format: "ok    %-16@ %4.0f ms", name as NSString, Date().timeIntervalSince(start) * 1000))
        case .failure(let error):
            failed += 1
            print("FAIL  \(name): \(error.message)")
        }
    }
    exit(failed == 0 ? 0 : 1)

case "html":
    guard args.count >= 3 else { fail("usage: highlight-check html OUT FILE...") }
    // The web prototype's colours, to compare like with like
    let colours: [TokenKind: String] = [
        .keyword: "#c74ded", .string: "#96e072", .comment: "#a0a1a7", .constant: "#f39c12",
        .function: "#ffe66d", .type: "#00e8c6", .attribute: "#ee5d43", .operator: "#ee5d43",
        .punctuation: "#b8bcc4",
    ]
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    var html = """
        <!doctype html><meta charset="utf-8"><style>
        body { background: #1e2128; color: #e6e6e6; font: 12.5px/19px ui-monospace, Menlo, monospace; margin: 0; padding: 12px; }
        h2 { font: 600 13px -apple-system, sans-serif; color: #9da3ad; margin: 18px 0 6px; }
        pre { margin: 0; white-space: pre; } .c { font-style: italic; }
        </style>
        """
    for path in args.dropFirst(2) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
        let start = Date()
        let result = highlighter.highlight(text, path: path)
        let ms = Date().timeIntervalSince(start) * 1000
        let grammar = highlighter.grammar(forPath: path)?.name ?? "none"
        html += "<h2>\(esc((path as NSString).lastPathComponent)) · \(grammar) · \(String(format: "%.0f", ms)) ms</h2><pre>"
        for line in result?.lines ?? text.components(separatedBy: "\n").map({ [.init(text: $0, kind: nil)] }) {
            for run in line {
                if let kind = run.kind, let colour = colours[kind] {
                    html += "<span\(kind == .comment ? " class=c" : "") style=\"color:\(colour)\">\(esc(run.text))</span>"
                } else {
                    html += esc(run.text)
                }
            }
            html += "\n"
        }
        html += "</pre>"
    }
    try! html.write(toFile: args[1], atomically: true, encoding: .utf8)
    print(args[1])

default:
    fail("usage: highlight-check queries | html OUT FILE...")
}
