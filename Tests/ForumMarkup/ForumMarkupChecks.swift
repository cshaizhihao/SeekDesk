import AppKit
import WebKit

@main
enum ForumMarkupChecks {
    struct Fixture: Decodable {
        let name: String
        let html: String
        let warning: String?
        let signature: String?
        let blocks: [ForumBlock]
        let signatureMarkdown: String?
        let visible: [String]
        let signatureVisible: String?
        let link: String?
    }

    static func visibleText(_ blocks: [ForumBlock]) -> [String] {
        blocks.flatMap { block in
            switch block.kind {
            case "tabs", "disclosure": return (block.tabs ?? []).flatMap { visibleText($0.blocks) }
            case "list": return (block.items ?? []).flatMap { visibleText($0.blocks) }
            case "table": return (block.rows ?? []).flatMap { $0 }
            case "code", "notice", "terminal": return [block.text]
            default: return [String(DeskMarkdownText.inline(block.text).characters)]
            }
        }
    }

    static func allBlocks(_ blocks: [ForumBlock]) -> [ForumBlock] {
        blocks.flatMap { [$0] + ($0.tabs ?? []).flatMap { allBlocks($0.blocks) } +
            ($0.items ?? []).flatMap { allBlocks($0.blocks) } }
    }

    @MainActor
    static func main() async throws {
        let fixtures = try ["forum-markup", "forum-lists"].flatMap { name in
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/\(name).json"))
            return try JSONDecoder().decode([Fixture].self, from: data)
        }
        var failures = 0
        for fixture in fixtures {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(WKUserScript(source: """
                window.__requests = 0;
                window.fetch = () => { window.__requests++; throw Error('Network forbidden'); };
                XMLHttpRequest.prototype.open = () => { window.__requests++; throw Error('Network forbidden'); };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
            let warning = fixture.warning.map { "<div class='topic-warning'>\($0)</div>" } ?? ""
            let signature = fixture.signature.map { "<div class='signature'>\($0)</div>" } ?? ""
            view.loadHTMLString("""
                <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
                <main id="nsk-body-left"><section class="nsk-post-wrapper"><h1><a class="post-title-link">Fixture</a></h1>
                <div class="content-item" id="0"><div class="post-content">\(fixture.html)</div>\(warning)\(signature)
                <div class="comment-menu"><button title="点赞">0</button></div></div></section></main>
                """, baseURL: URL(string: "https://www.nodeseek.com/post-101-1"))
            var ready = false
            for _ in 0..<300 {
                ready = (try? await view.callAsyncJavaScript("return document.readyState === 'complete' && Boolean(document.querySelector('#nsk-body-left'));",
                    arguments: [:], in: nil, contentWorld: .page)) as? Bool == true
                if ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard ready else { fatalError("Synthetic document did not load") }
            let result = try await view.callAsyncJavaScript(ForumPageScript.extract,
                arguments: ["onlyFloor": "", "terminalSources": ""], in: nil, contentWorld: .defaultClient)
            let thread = try JSONDecoder().decode(ForumThread.self, from: Data((result as! String).utf8))
            let requests = try await view.callAsyncJavaScript("return window.__requests;", arguments: [:], in: nil, contentWorld: .page)
            let blocks = thread.root?.blocks ?? []
            let charactersMatch = visibleText(blocks) == fixture.visible
            let signatureMatch = thread.root?.signature.map { String(ForumMarkdownLink.format($0).characters) } == fixture.signatureVisible
            let links = allBlocks(blocks).flatMap { Array(DeskMarkdownText.inline($0.text).runs).compactMap { $0.link?.absoluteString } }
            let linkMatch = fixture.link.map { links.contains($0) } ?? true
            let encoded = try JSONEncoder().encode(thread)
            let roundTrip = try JSONDecoder().decode(ForumThread.self, from: encoded)
            let passed = thread.root?.blocks == fixture.blocks && thread.root?.signature == fixture.signatureMarkdown &&
                charactersMatch && signatureMatch && linkMatch && requests as? Int == 0 && roundTrip == thread
            print("\(passed ? "PASS" : "FAIL") \(fixture.name)")
            if !passed { print("DTO:\(thread.root?.blocks == fixture.blocks) characters:\(charactersMatch) signature:\(signatureMatch) links:\(linkMatch)") }
            if !passed { failures += 1 }
        }
        print("Forum markup: \(fixtures.count - failures)/\(fixtures.count) cases passed without network or app window.")
        if failures > 0 { exit(1) }
        let sample = fixtures.first { $0.name == "mixed nested lists preserve parent continuation" }!.blocks
        func thread(_ blocks: [ForumBlock]) -> ForumThread {
            ForumThread(title: "Fixture", category: "", root: ForumFloor(id: "0", author: "A", authorID: nil,
                isAuthor: true, avatar: nil, tags: nil, date: "", dateLabel: "", blocks: blocks),
                replies: [], pages: [], page: 1, replyRestriction: nil)
        }
        let quoted = ForumFloorDraft.insertion(for: thread(sample).root!, in: URL(string: "https://www.nodeseek.com/post-101-1")!, quoting: true, after: "")!
        precondition(quoted.contains("> • Parent\n>   3. Inner first\n>      • Deep child\n>   4. Inner second\n>   Parent continuation\n> • Sibling"))
        let large = ForumBlock(kind: "text", text: String(repeating: "x", count: ForumThreadCacheCost.limit), url: nil, tabs: nil, rows: nil, terminal: nil)
        let list = ForumBlock(kind: "list", text: "", url: nil, tabs: nil, rows: nil, terminal: nil,
            items: [ForumListItem(marker: "1.", blocks: [large])])
        precondition(ForumThreadCacheCost.estimate(thread([list])) > ForumThreadCacheCost.limit)
        let terminal = fixtures.first { $0.name == "terminal report survives list and tab nesting" }!.blocks
        precondition(terminal.contains { $0.hasTerminal })
        print("PASS nested list quote, bounded recursive cache cost, terminal detection and DTO round trips")
    }
}
