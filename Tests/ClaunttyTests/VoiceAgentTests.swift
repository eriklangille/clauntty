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
        """
        let agents = ClaudeScripts.parse(output).agents
        XCTAssertEqual(agents.map(\.pid), [884, 9106])
        XCTAssertNil(agents[0].title)
        XCTAssertEqual(agents[0].statusText, "working")
        XCTAssertEqual(agents[1].title, "Label \"decisions\" migration")
        XCTAssertEqual(agents[1].shortDirectory, "sessions/3")
    }

    func testScriptsRejectUnsafeIds() {
        XCTAssertNil(ClaudeScripts.find(rtachSessionId: "abc; rm -rf ~"))
        XCTAssertNil(ClaudeScripts.extract(sessionId: "$(whoami)"))
        XCTAssertNotNil(ClaudeScripts.extract(sessionId: "04b4335c-edfc-4373-921f-c92f07b2274f"))
        XCTAssertNil(ClaudeScripts.herdrPrompt(pane: "w1:p1'; rm -rf ~; '", text: "hi"))
        XCTAssertNil(ClaudeScripts.herdrKeys(pane: "w1:p1", keys: ["enter", "rm -rf ~"]))
        XCTAssertNotNil(ClaudeScripts.herdrKeys(pane: "w1:p1", keys: ["1", "enter"]))
    }

    func testPromptTextTravelsEncoded() {
        // Quotes, backticks and $( ) never reach the shell as code
        let text = "it's ok? run `ls` $(whoami)"
        let script = ClaudeScripts.herdrPrompt(pane: "w4:p4", text: text)!
        XCTAssertFalse(script.contains("whoami"))
        XCTAssertTrue(script.contains(Data(text.utf8).base64EncodedString()))
        XCTAssertTrue(script.contains("--wait"))
        // A slash command doesn't start a turn, so don't wait for one
        XCTAssertFalse(ClaudeScripts.herdrPrompt(pane: "w4:p4", text: "/rename Voice tests")!.contains("--wait"))
    }

    func testHerdrRoutesAndStatus() {
        let output = """
        mux\therdr
        claude\t{"pid":9106,"sessionId":"aaaa-1","cwd":"/w/api","status":"busy"}
        claude\t{"pid":884,"sessionId":"bbbb-2","cwd":"/w/web","status":"idle"}
        herdr\t{"result":{"agents":[{"pane_id":"w4:p4","agent_status":"blocked"},{"pane_id":"w3:p1","agent_status":"idle"}]}}
        pane\t9106\tw4:p4
        """
        let scan = ClaudeScripts.parse(output)
        XCTAssertEqual(scan.multiplexers, ["herdr"])
        XCTAssertEqual(scan.agents.map(\.pid), [884, 9106])
        // 884 has no pane in the list, so it can't be typed into
        XCTAssertEqual(scan.agents[0].route, .unsupported(multiplexer: "herdr"))
        XCTAssertEqual(scan.agents[1].route, .herdr(pane: "w4:p4"))
        XCTAssertEqual(scan.agents[1].statusText, "waiting for the user at a menu or question")
        // A Claude in the tab itself
        let direct = ClaudeScripts.parse("claude\t{\"pid\":5,\"sessionId\":\"c-3\",\"cwd\":\"/w\",\"status\":\"idle\"}")
        XCTAssertEqual(direct.agents.first?.route, .tab)
        XCTAssertEqual(ClaudeScripts.herdrError(#"{"error":{"code":"agent_blocked","message":"x"},"id":"cli"}"#), "agent_blocked")
        XCTAssertNil(ClaudeScripts.herdrError(#"{"id":"cli","result":{"ok":true}}"#))
    }

    func testShowingPaneIsMatchedFromTheTabsScreen() {
        let statusBar = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        let output = """
        mux\therdr
        claude\t{"pid":1,"sessionId":"a-1","cwd":"/w/api","status":"idle"}
        claude\t{"pid":2,"sessionId":"b-2","cwd":"/w/web","status":"idle"}
        pane\t1\tw1:p1
        pane\t2\tw2:p1
        visible\tw1:p1\t\(Data("❯ fix the login redirect\n⏺ Fixed it in auth.ts and added a test\n\(statusBar)".utf8).base64EncodedString())
        visible\tw2:p1\t\(Data("❯ /clear\n  (no content)\n\(statusBar)".utf8).base64EncodedString())
        """
        var scan = ClaudeScripts.parse(output)
        // The tab draws Herdr's sidebar beside the pane
        scan.markShowing(screen: "api  │ ❯ fix the login redirect\nweb  │ ⏺ Fixed it in auth.ts and added a test\n     │\(statusBar)")
        XCTAssertEqual(scan.agents.map(\.focused), [true, false])
        scan.markShowing(screen: "     │ ❯ /clear\n     │   (no content)\n     │\(statusBar)")
        XCTAssertEqual(scan.agents.map(\.focused), [false, true])
        // Only the shared status bar: no way to tell
        scan.markShowing(screen: statusBar)
        XCTAssertEqual(scan.agents.map(\.focused), [false, false])
    }

    func testWatchReportsSettledChangesOnly() {
        var watch = ClaudeWatch()
        // The first check only records where each one stands
        XCTAssertEqual(watch.update(["a": .working, "b": .idle]), [])
        // A change counts once two checks agree
        XCTAssertEqual(watch.update(["a": .idle, "b": .idle]), [])
        XCTAssertEqual(watch.update(["a": .idle, "b": .blocked]), [.init(key: "a", change: .finished)])
        XCTAssertEqual(watch.update(["a": .working, "b": .blocked]), [.init(key: "b", change: .blocked)])
        // A one-check flicker says nothing; starting work isn't news
        XCTAssertEqual(watch.update(["a": .idle, "b": .blocked]), [])
        XCTAssertEqual(watch.update(["a": .working, "b": .working]), [])
        XCTAssertEqual(watch.update(["a": .working, "b": .working]), [])
        // A conversation that ends is forgotten; if it comes back it starts over
        XCTAssertEqual(watch.update(["b": .idle]), [])
        XCTAssertEqual(watch.update(["a": .idle, "b": .idle]), [.init(key: "b", change: .finished)])
        XCTAssertEqual(watch.update(["a": .idle, "b": .idle]), [])
    }

    func testWatchStatePrefersHerdr() {
        var agent = ClaudeAgent(pid: 1, sessionId: "s", directory: "/w", status: "idle")
        XCTAssertEqual(ClaudeWatch.state(of: agent), .idle)
        agent = ClaudeAgent(pid: 1, sessionId: "s", directory: "/w", status: "busy")
        XCTAssertEqual(ClaudeWatch.state(of: agent), .working)
        // Herdr knows about menus; Claude's own status doesn't
        agent.herdrStatus = "blocked"
        XCTAssertEqual(ClaudeWatch.state(of: agent), .blocked)
        agent.herdrStatus = "done"
        XCTAssertEqual(ClaudeWatch.state(of: agent), .idle)
        XCTAssertFalse(ClaudeScripts.find(rtachSessionId: "abc", screens: false)!.contains("--source visible"))
        XCTAssertTrue(ClaudeScripts.find(rtachSessionId: "abc")!.contains("--source visible"))
    }

    func testKeys() {
        XCTAssertEqual(try VoiceKeys.parse("1").get(), ["1"])
        XCTAssertEqual(try VoiceKeys.parse("Escape, ctrl-c down Enter shift-tab").get(), ["esc", "ctrl+c", "down", "enter", "shift+tab"])
        XCTAssertEqual(VoiceKeys.parse("1 banana"), .failure(VoiceKeys.UnknownKey(name: "banana")))
        XCTAssertEqual(VoiceKeys.bytes["shift+tab"], "\u{1B}[Z")
        XCTAssertEqual(VoiceKeys.bytes["ctrl+c"], "\u{03}")
        // A pasted prompt can't end the paste early
        XCTAssertEqual(VoiceKeys.paste("? help\u{1B}[201~x"), "\u{1B}[200~? help[201~x\u{1B}[201~")
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
