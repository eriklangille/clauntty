import XCTest
@testable import Clauntty

final class VoiceAgentTests: XCTestCase {

    // MARK: - Cleaning

    func testCleanerStripsBoxDrawingAndBlankRuns() {
        let screen = """
        ╭──────────────────────────╮
        │ ✻ Welcome to Claude Code │
        ╰──────────────────────────╯


        > run the tests   \u{20}
        ⠋ Running…

        """
        XCTAssertEqual(TerminalTextCleaner.clean(screen), [
            " ✻ Welcome to Claude Code",
            "",
            "> run the tests",
            " Running…",
        ])
    }

    func testCleanerDropsLeadingBlankLines() {
        XCTAssertEqual(TerminalTextCleaner.clean("\n\n  \nhello\r\nworld\n\n"), ["hello", "world"])
    }

    // MARK: - Styling

    func testDimSuggestionIsMarked() {
        // Claude Code's prompt with a suggestion, as Ghostty's VT formatter writes it
        let vt = "\u{1B}[0m❯ \u{1B}[0m\u{1B}[2mTry \"create a util logging.py\"\u{1B}[0m\r\n"
        XCTAssertEqual(TerminalStyledText.markup(vt), "❯ [dim]Try \"create a util logging.py\"[/dim]\n")
    }

    func testColorArgumentsAreNotStyles() {
        // The 2 and 9 here are color values, not dim or strikethrough
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[0m\u{1B}[38;2;2;9;8mred\u{1B}[0m"), "red")
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[38;5;2mgreen\u{1B}[48;5;9m!"), "green!")
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[38:2::2:9:8mcolon\u{1B}[0m"), "colon")
    }

    func testStrikethroughAndHidden() {
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[0m\u{1B}[9mwrite tests\u{1B}[0m ship it"), "[strike]write tests[/strike] ship it")
        XCTAssertEqual(TerminalStyledText.markup("password: \u{1B}[0m\u{1B}[8mhunter2\u{1B}[0m!"), "password: !")
    }

    func testMarkersCloseAtLineEnds() {
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[2mone\r\ntwo\u{1B}[0m three"), "[dim]one[/dim]\n[dim]two[/dim] three")
        XCTAssertEqual(TerminalStyledText.markup("\u{1B}[2;9mboth\u{1B}[29m dim"), "[dim][strike]both[/strike] dim[/dim]")
    }

    func testLinksAndOtherSequencesAreRemoved() {
        let vt = "see \u{1B}]8;;https://example.com\u{1B}\\the docs\u{1B}]8;;\u{07} \u{1B}[1mnow\u{1B}[0m\u{1B}[?25h"
        XCTAssertEqual(TerminalStyledText.markup(vt), "see the docs now")
    }

    func testCleanerDropsEmptyMarkers() {
        // A dim border is nothing once its box drawing is removed
        XCTAssertEqual(TerminalTextCleaner.clean("[dim]────[/dim]\n❯ [dim]   [/dim]\n[dim]a[/dim][dim]b[/dim]"), ["❯", "[dim]ab[/dim]"])
    }

    // MARK: - New text

    func testFirstReadReturnsRecentLines() {
        let lines = (1...100).map { "line \($0)" }
        let result = TerminalTextDiff.newLines(previous: nil, current: lines, maxLines: 80)
        XCTAssertEqual(result.kind, .first)
        XCTAssertEqual(result.lines.first, "line 21")
        XCTAssertEqual(result.lines.count, 80)
        XCTAssertEqual(result.omitted, 20)
    }

    func testNewLinesAboveRedrawnPromptBox() {
        // Claude Code keeps its prompt box and status line at the bottom, so new output
        // appears above lines the model has already seen
        let before = ["$ claude", "> fix the bug", "Looking at main.swift", "> ", "status: opus"]
        let after = ["$ claude", "> fix the bug", "Looking at main.swift", "Fixed the off-by-one", "Tests pass", "> ", "status: opus"]
        let result = TerminalTextDiff.newLines(previous: before, current: after)
        XCTAssertEqual(result.kind, .new)
        XCTAssertEqual(result.lines, ["Fixed the off-by-one", "Tests pass"])
        XCTAssertEqual(result.omitted, 0)
    }

    func testNothingNew() {
        let lines = ["a", "b", "c"]
        let result = TerminalTextDiff.newLines(previous: lines, current: lines)
        XCTAssertEqual(result.kind, .new)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testNewLinesCappedAtMax() {
        let before = ["start"]
        let after = ["start"] + (1...100).map { "out \($0)" }
        let result = TerminalTextDiff.newLines(previous: before, current: after, maxLines: 80)
        XCTAssertEqual(result.lines.count, 80)
        XCTAssertEqual(result.lines.first, "out 21")
        XCTAssertEqual(result.omitted, 20)
    }

    func testClearedScreenIsAReset() {
        let before = (1...20).map { "old \($0)" }
        let after = (1...20).map { "new \($0)" }
        let result = TerminalTextDiff.newLines(previous: before, current: after)
        XCTAssertEqual(result.kind, .reset)
        XCTAssertEqual(result.lines, after)
    }

    // MARK: - Tabs

    private let tabs = [
        VoiceTab(number: 1, title: "✳ Fix login bug", name: "devbox", host: "me@devbox"),
        VoiceTab(number: 2, title: "zsh", name: "studio", host: "me@studio.local"),
        VoiceTab(number: 3, title: "✳ Voice agent", name: "studio", host: "me@studio.local"),
    ]

    func testResolveByNumber() {
        XCTAssertEqual(VoiceTabResolver.resolve("2", in: tabs), .found(1))
        XCTAssertEqual(VoiceTabResolver.resolve("tab 3", in: tabs), .found(2))
        XCTAssertEqual(VoiceTabResolver.resolve("#1", in: tabs), .found(0))
        XCTAssertEqual(VoiceTabResolver.resolve("4", in: tabs), .notFound)
    }

    func testResolveByName() {
        XCTAssertEqual(VoiceTabResolver.resolve("devbox", in: tabs), .found(0))
        XCTAssertEqual(VoiceTabResolver.resolve("Voice", in: tabs), .found(2))
        XCTAssertEqual(VoiceTabResolver.resolve("zsh", in: tabs), .found(1))
        XCTAssertEqual(VoiceTabResolver.resolve("studio", in: tabs), .ambiguous([1, 2]))
        XCTAssertEqual(VoiceTabResolver.resolve("nothing", in: tabs), .notFound)
    }

    // MARK: - Claude conversations

    func testParseAgents() {
        let output = """
        claude\t{"pid":9106,"sessionId":"04b4335c-edfc","cwd":"/Users/ana/sessions/3","status":"idle","name":"3-3a"}
        title\t04b4335c-edfc\t{"aiTitle":"Label \\"decisions\\" migration"}
        claude\t{"pid":884,"sessionId":"ab0ec4c3-ae3a","cwd":"/Users/ana/sessions/2","status":"busy"}
        claude\tnot json
        focus\t9106
        """
        let agents = ClaudeScripts.parseAgents(output)
        XCTAssertEqual(agents.map(\.pid), [884, 9106])
        XCTAssertNil(agents[0].title)
        XCTAssertEqual(agents[0].statusText, "working")
        XCTAssertEqual(agents[1].title, "Label \"decisions\" migration")
        XCTAssertEqual(agents[1].shortDirectory, "sessions/3")
        XCTAssertEqual(agents.map(\.focused), [false, true])
    }

    func testScriptsRejectUnsafeIds() {
        XCTAssertNil(ClaudeScripts.find(rtachSessionId: "abc; rm -rf ~"))
        XCTAssertNil(ClaudeScripts.extract(sessionId: "$(whoami)"))
        XCTAssertNotNil(ClaudeScripts.extract(sessionId: "04b4335c-edfc-4373-921f-c92f07b2274f"))
    }

    private let extracted = """
    user\t{"content":"review the migration"}
    tool\t{"name":"Bash"}\t{"description":"Show the migration"}
    tool\t{"name":"Edit"}\t{"file_path":"/repo/central/lib/reconcile.ts"}
    tool\t{"name":"TodoWrite"}\t
    text\t{"text":"It's safe.\\n\\nOne issue: the threshold isn't in the hash."}
    title\t{"aiTitle":"Migration review"}
    user\t{"content":"<command-name>/clear</command-name>"}
    user\t{"content":"fix the hash"}
    text\t{"text":"Fixing it"}
    user\t{"content":"[Request interrupted by user]"}
    user\t{"text":"no, only review"}
    text\t{"text":"Understood. Want me to check the other agent's fix?"}
    """

    func testParseTranscript() {
        let t = ClaudeTranscript.parse(extracted)
        XCTAssertEqual(t.title, "Migration review")
        XCTAssertEqual(t.turns.map(\.prompt), ["review the migration", "fix the hash", "no, only review"])
        XCTAssertEqual(t.turns[0].steps, [
            .tool("Bash: Show the migration"),
            .tool("Edit: reconcile.ts"),
            .tool("TodoWrite"),
            .reply("It's safe.\n\nOne issue: the threshold isn't in the hash."),
        ])
        XCTAssertTrue(t.turns[1].interrupted)
        XCTAssertFalse(t.turns[2].interrupted)
    }

    func testOutlineAndRender() {
        let t = ClaudeTranscript.parse(extracted)
        XCTAssertEqual(t.outline(0..<2), """
        Turn 1. User: review the migration
          Claude (3 tool calls): It's safe. One issue: the threshold isn't in the hash.
        Turn 2. User: fix the hash
          Claude: Fixing it
          (the user interrupted this turn)
        """)
        XCTAssertEqual(t.render(turn: 0), """
        Turn 1 of 3
        User: review the migration
          - Bash: Show the migration
          - Edit: reconcile.ts
          - TodoWrite
        Claude: It's safe.

        One issue: the threshold isn't in the hash.
        """)
        XCTAssertNil(t.render(turn: 3))
    }

    func testRenderKeepsTheEndOfALongLastReply() {
        let reply = "Start. " + String(repeating: "x", count: 5000) + " Want me to ship it?"
        let t = ClaudeTranscript(turns: [.init(prompt: "go", steps: [.reply(reply)])])
        let text = t.render(turn: 0, limit: 1500)!
        XCTAssertLessThan(text.count, 1700)
        XCTAssertTrue(text.contains("Start."))
        XCTAssertTrue(text.hasSuffix("Want me to ship it?"))
        XCTAssertTrue(text.contains("characters left out"))
    }

    func testSearch() {
        let t = ClaudeTranscript.parse(extracted)
        // Every word in one paragraph beats a single word
        XCTAssertEqual(t.search("threshold hash").hits, [
            .init(turn: 1, who: "Claude", snippet: "One issue: the threshold isn't in the hash."),
        ])
        // Otherwise the most words, newest first
        XCTAssertEqual(t.search("hash nothing").hits.map(\.turn), [2, 1])
        XCTAssertEqual(t.search("reconcile").hits.first?.who, "Claude's tool call")
        XCTAssertTrue(t.search("zebra").hits.isEmpty)
    }

    // MARK: - Cost

    func testCost() {
        var cost = VoiceCost(seconds: 142, textInputs: 6)
        XCTAssertEqual(cost.dollars, 142.0 / 60 * 0.08 + 6 * 0.004, accuracy: 0.0001)
        XCTAssertEqual(cost.dollarsText, "$0.21")
        XCTAssertEqual(cost.breakdownText, "2m 22s · 6 text inputs")

        cost = VoiceCost(seconds: 15 * 60, textInputs: 1)
        XCTAssertEqual(cost.dollarsText, "$1.20")
        XCTAssertEqual(cost.breakdownText, "15m 0s · 1 text input")
    }

    func testClockText() {
        XCTAssertEqual(voiceClockText(761), "12:41")
        XCTAssertEqual(voiceClockText(59.2), "1:00")
        XCTAssertEqual(voiceClockText(-3), "0:00")
    }
}
