import AppKit
import WebKit

/// Actual DOM/content-world checks, with synthetic HTML and no window or account.
@main
enum TerminalRecoveryChecks {
    private static func check(_ value: Bool, _ message: String = "Terminal recovery assertion") { precondition(value, message) }
    private static let url = URL(string: "https://www.nodeseek.com/post-101-1")!
    private static let emptyTerminal = "<div class='terminal-container'><div class='xterm'><canvas></canvas></div></div>"
    private static func fence(_ text: String) -> String { "```ansi\n" + text + "\n```" }
    private static func item(_ id: Int, _ body: String, attributes: String = "") -> String {
        "<div class='content-item' id='\(id)' \(attributes)><div class='post-content'>\(body)</div><div class='comment-menu'><button title='点赞'>0</button></div></div>"
    }
    private static func allBlocks(_ blocks: [ForumBlock]) -> [ForumBlock] {
        blocks.flatMap { [$0] + ($0.tabs ?? []).flatMap { allBlocks($0.blocks) } +
            ($0.items ?? []).flatMap { allBlocks($0.blocks) } }
    }
    private static func terminals(_ thread: ForumThread) -> [ForumBlock] {
        allBlocks((thread.root?.blocks ?? []) + thread.replies.flatMap(\.blocks)).filter { $0.kind == "terminal" }
    }

    @MainActor
    private static func fixture(root: String = emptyTerminal, replies: String = "", comments: [[String: Any]],
                                postID: Int = 101, rootAttributes: String = "", capture: Bool = false) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if capture {
            config.userContentController.addUserScript(WKUserScript(source: ForumPageScript.captureTerminals,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 940, height: 700), configuration: config)
        view.loadHTMLString("""
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <main id="nsk-body-left"><section class="nsk-post-wrapper"><h1><a class="post-title-link">Fixture</a></h1>
        \(item(0, root, attributes: rootAttributes))</section><section class="comments">\(replies)</section></main>
        """, baseURL: url)
        var ready = false
        for _ in 0..<300 {
            if (try? await view.callAsyncJavaScript("return document.readyState === 'complete' && Boolean(document.querySelector('#nsk-body-left'));",
                arguments: [:], in: nil, contentWorld: .page)) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(ready, "Synthetic document must load without network")
        let data: [String: Any] = ["user": ["token": "must-not-cross-worlds"], "postData": ["postId": postID, "comments": comments]]
        let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        _ = try await view.callAsyncJavaScript("window.__config__ = JSON.parse(value); window.__networkCalls = 0; window.fetch = () => { window.__networkCalls++; throw Error('network forbidden'); }; return true;",
            arguments: ["value": json], in: nil, contentWorld: .page)
        // Missing-renderer timeout is unrelated to these source/DOM assertions.
        _ = try await view.callAsyncJavaScript("globalThis.setTimeout = callback => { callback(); return 1; }; return true;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        return view
    }

    @MainActor
    private static func source(_ view: WKWebView, floor: String = "", expected: URL = url) async throws -> String {
        (try await view.callAsyncJavaScript(ForumPageScript.terminalMarkdown,
            arguments: ["expectedURL": expected.absoluteString, "onlyFloor": floor], in: nil, contentWorld: .page)) as? String ?? ""
    }

    @MainActor
    private static func extract(_ view: WKWebView, floor: String = "", supplied: String? = nil) async throws -> ForumThread {
        let payload: String
        if let supplied { payload = supplied } else { payload = try await source(view, floor: floor) }
        let value = try await view.callAsyncJavaScript(ForumPageScript.extract,
            arguments: ["onlyFloor": floor, "terminalSources": payload], in: nil, contentWorld: .defaultClient)
        check((try await view.callAsyncJavaScript("return window.__networkCalls;", arguments: [:], in: nil, contentWorld: .page)) as? Int == 0)
        return try JSONDecoder().decode(ForumThread.self, from: Data((value as! String).utf8))
    }

    @MainActor
    static func main() async throws {
        let longReport = (0..<300).map { "\u{1b}[32mNQ row \($0) 中文\u{1b}[0m" }.joined(separator: "\n")
        let longView = try await fixture(comments: [["floorIndex": 0, "markdown": fence(longReport)]])
        let longPayload = try await source(longView)
        check(!longPayload.contains("must-not-cross-worlds") && !longPayload.contains("user"))
        let longThread = try await extract(longView)
        check(terminals(longThread).map(\.text) == [longReport], "Empty canvas must recover every line, not a viewport slice")
        check((try await longView.callAsyncJavaScript("return typeof window.__config__;", arguments: [:], in: nil, contentWorld: .defaultClient)) as? String == "undefined")
        print("PASS empty canvas, complete long ANSI text and minimal isolated-world payload")

        let tabs = "<div class='nsk-magic-tabs'><div class='nsk-magic-tab-title'>基本信息</div><div class='nsk-magic-tab-body'>\(emptyTerminal)</div><div class='nsk-magic-tab-title'>IP质量</div><div class='nsk-magic-tab-body' style='display:none'>\(emptyTerminal)</div></div>"
        let tabView = try await fixture(root: tabs, comments: [["floorIndex": 0, "markdown": fence("NQ first") + "\n" + fence("NQ second")]])
        check(terminals(try await extract(tabView)).map(\.text) == ["NQ first", "NQ second"])
        print("PASS active and inactive report tabs retain source order")

        let mixed = try await fixture(root: emptyTerminal + "<pre><code class='language-ansi'>intact report</code></pre>", comments: [["floorIndex": 0, "markdown": fence("converted report") + "\n" + fence("intact report")]])
        check(terminals(try await extract(mixed)).map(\.text) == ["converted report", "intact report"])
        let mixedReverse = try await fixture(root: "<pre><code class='language-ansi'>intact report</code></pre>" + emptyTerminal,
            replies: item(1, emptyTerminal), comments: [["floorIndex": 1, "markdown": fence("reply")],
                ["floorIndex": 0, "markdown": fence("intact report") + "\n" + fence("converted report")]])
        check(terminals(try await extract(mixedReverse)).map(\.text) == ["intact report", "converted report", "reply"])
        let mismatched = try await fixture(comments: [["floorIndex": 0, "markdown": fence("one") + "\n" + fence("two")]])
        check(terminals(try await extract(mismatched)).isEmpty, "Ambiguous count must never guess a report")
        print("PASS converted/intact ANSI ordering and mismatched count rejection")

        let floors = try await fixture(replies: item(1, emptyTerminal) + item(2, "<p>Locked content</p>"), comments: [
            ["floorIndex": 0, "markdown": fence("root")], ["floorIndex": 1, "markdown": fence("reply")], ["floorIndex": 2, "markdown": fence("must stay hidden")]])
        let onlyReply = try await extract(floors, floor: "1")
        check(onlyReply.root == nil && onlyReply.replies.map(\.id) == ["1"] && terminals(onlyReply).map(\.text) == ["reply"])
        let replyPayload = try await source(floors, floor: "1")
        check(!replyPayload.contains("root") && !replyPayload.contains("must stay hidden"))
        check(terminals(try await extract(floors)).map(\.text) == ["root", "reply"])
        print("PASS exact floor scoping and no recovery without a rendered terminal")

        let duplicateData = try await fixture(comments: [["floorIndex": 0, "markdown": fence("first")], ["floorIndex": 0, "markdown": fence("second")]])
        check(terminals(try await extract(duplicateData)).isEmpty)
        let duplicateDOM = try await fixture(root: "<p>root</p>", replies: item(1, emptyTerminal) + item(1, emptyTerminal), comments: [["floorIndex": 1, "markdown": fence("ambiguous")]])
        check(terminals(try await extract(duplicateDOM)).isEmpty)
        let wrongPost = try await fixture(comments: [["floorIndex": 0, "markdown": fence("wrong post")]], postID: 102)
        check(try await source(wrongPost) == "")
        check(try await source(longView, expected: URL(string: "https://www.nodeseek.com/post-101-2")!) == "")
        let foreignPayload = longPayload.replacingOccurrences(of: "\"postID\":101", with: "\"postID\":102")
        check(terminals(try await extract(longView, supplied: foreignPayload)).isEmpty)
        let wrongPage = longPayload.replacingOccurrences(of: "\"page\":1", with: "\"page\":2")
        check(terminals(try await extract(longView, supplied: wrongPage)).isEmpty)
        for invalid in ["-1", "01", "not-a-floor", "999", "+1", " 0", "9007199254740992"] {
            check(try await source(longView, floor: invalid) == "")
            let raw = try await longView.callAsyncJavaScript(ForumPageScript.extract,
                arguments: ["onlyFloor": invalid, "terminalSources": longPayload], in: nil, contentWorld: .defaultClient)
            check((raw as? String) == #"{"error":"missing"}"#, "Invalid floor must not broaden to all floors")
        }
        print("PASS duplicate ownership, wrong post and stale page rejection")

        let markdown = "````text\n```ansi\nexample only\n```\n````\n" + fence("actual report")
        let nested = try await fixture(comments: [["floorIndex": 0, "markdown": markdown]])
        check(terminals(try await extract(nested)).map(\.text) == ["actual report"])
        let unclosed = try await fixture(comments: [["floorIndex": 0, "markdown": "```ansi\nincomplete"]])
        check(terminals(try await extract(unclosed)).isEmpty)
        let tildes = try await fixture(comments: [["floorIndex": 0, "markdown": "~~~ANSI\r\nreport\r\n~~~"]])
        check(terminals(try await extract(tildes)).map(\.text) == ["report"])
        print("PASS nested ordinary fences, incomplete fences and CRLF tilde ANSI")

        let drawn = try await fixture(root: "<div class='xterm'><div class='xterm-rows'><div><span style='color:rgb(255,0,0)'>painted</span></div></div></div>", comments: [])
        check(terminals(try await extract(drawn)).first?.terminal?.first?.first?.text == "painted")
        let encoded = try await fixture(root: "<pre><code class='language-ansi'><span data-ansicode='27'>[ESC]</span>[32mgreen<span data-ansicode='27'>[ESC]</span>[0m</code></pre>", comments: [])
        check(terminals(try await extract(encoded)).map(\.text) == ["\u{1b}[32mgreen\u{1b}[0m"])
        print("PASS drawn DOM fallback and encoded ESC preservation")

        let captured = try await fixture(root: "<pre><code class='language-ansi'><span data-ansicode='27'>[ESC]</span>[32mold</code></pre>", comments: [], capture: true)
        _ = try await captured.callAsyncJavaScript("""
        await Promise.resolve();
        const code = document.querySelector('pre code');
        code.lastChild.data = '[32mupdated report';
        await Promise.resolve();
        const terminal = document.createElement('div');
        terminal.className = 'xterm';
        code.closest('pre').replaceWith(terminal);
        await Promise.resolve();
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        check(terminals(try await extract(captured, supplied: "")).map(\.text) == ["\u{1b}[32mupdated report"])
        _ = try await captured.callAsyncJavaScript("document.querySelector('.post-content').setAttribute('hidden',''); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        check(terminals(try await extract(captured, supplied: "")).isEmpty)
        print("PASS document-start capture, characterData updates, encoded ESC and hidden capture rejection")

        let hidden = try await fixture(root: "<section hidden>\(emptyTerminal)</section>", comments: [["floorIndex": 0, "markdown": fence("hidden report")]])
        check(terminals(try await extract(hidden)).isEmpty, "Hidden content must stay hidden")
        let hiddenFloor = try await fixture(comments: [["floorIndex": 0, "markdown": fence("hidden floor")]], rootAttributes: "hidden")
        check(try await source(hiddenFloor) == "")
        for attributes in ["aria-hidden='true'", "style='visibility:hidden'", "style='display:none'"] {
            let wrapped = try await fixture(root: "<div \(attributes)>\(emptyTerminal)</div>", comments: [["floorIndex": 0, "markdown": fence("hidden")]])
            check(terminals(try await extract(wrapped)).isEmpty)
        }
        for attributes in ["hidden", "aria-hidden='true'"] {
            let pane = "<div class='nsk-magic-tabs'><div class='nsk-magic-tab-title'>hidden</div><div class='nsk-magic-tab-body' \(attributes)>\(emptyTerminal)</div></div>"
            let hiddenTab = try await fixture(root: pane, comments: [["floorIndex": 0, "markdown": fence("hidden")]])
            check(terminals(try await extract(hiddenTab)).isEmpty)
        }
        _ = try await floors.callAsyncJavaScript("document.querySelector('.comments').hidden = true; document.querySelector('.post-content').style.display = 'none'; return true;",
            arguments: [:], in: nil, contentWorld: .page)
        check(try await source(floors) == "")
        check(terminals(try await extract(floors)).isEmpty)
        _ = try await drawn.callAsyncJavaScript("document.querySelector('.xterm').setAttribute('aria-hidden','true'); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        check(terminals(try await extract(drawn)).isEmpty)
        let oversized = try await fixture(comments: [["floorIndex": 0, "markdown": fence(String(repeating: "X", count: 512 * 1024))]])
        check(terminals(try await extract(oversized)).isEmpty)
        print("PASS hidden content and oversized payload rejection")
        print("Passed all terminal recovery checks without network requests or an app window.")
    }
}
