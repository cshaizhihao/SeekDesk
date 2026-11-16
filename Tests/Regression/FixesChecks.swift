import AppKit
import Combine
import ImageIO
import JavaScriptCore
import UniformTypeIdentifiers
import WebKit

@main struct FixesChecks {
    @MainActor static func main() async throws {
        try await accounts()
        try await profiles()
        await profileEntries()
        readingPositions()
        readingDestinations()
        readerLayoutBudget()
        inboxCache()
        imageSourceCoordinates()
        try await readerLifecycle()
        try await readerFreshness()
        try await readerWriteIsolation()
        try await restoredInlineEditing()
        discussionAbandonment()
        markdownTextCache()
        signatureCache()
        try markdownAndReports()
        try images()
        unread()
        print("Passed all F01–F09 regression checks without forum requests or user data changes.")
    }

    static func inboxCache() {
        var cache = InboxReadCache<String>()
        let first = InboxReadCache<String>.Key(route: "conversation", peer: 1)
        let second = InboxReadCache<String>.Key(route: "conversation", peer: 2)
        cache.prepare(access: 1, refresh: 0)
        cache.insert("first", for: first, cost: 10)
        cache.insert("second", for: second, cost: 10)
        precondition(cache.value(for: first) == "first")
        // Repeated switches stay local until an explicit invalidation, rather
        // than dropping the result after a thirty-second reading interval.
        for _ in 0..<100 {
            cache.prepare(access: 1, refresh: 0)
            precondition(cache.value(for: second) == "second")
            precondition(cache.value(for: first) == "first")
        }
        cache.updateValues { key, value in key == first ? "read" : value }
        precondition(cache.value(for: first) == "read")
        precondition(cache.value(for: second) == "second")
        precondition(cache.value(for: first, revision: 1) == nil)
        precondition(cache.value(for: second) == "second")
        cache.prepare(access: 2, refresh: 0)
        precondition(cache.value(for: second) == nil)
        cache.insert("new", for: first, cost: 10)
        cache.prepare(access: 2, refresh: 1)
        precondition(cache.value(for: first) == nil)
        for id in 1...9 { cache.insert(String(id), for: .init(route: "conversation", peer: id), cost: 1) }
        precondition(cache.value(for: first) == nil)
        precondition(cache.value(for: second) == "2")
        cache.insert("large", for: first, cost: 3 * 1024 * 1024)
        precondition(cache.value(for: first) == nil)
        cache.removeAll()
        precondition(cache.value(for: second) == nil)

        var revisions = InboxCategoryRevisions()
        let old = ForumUnreadCounts(mentions: 2, replies: 0, messages: 0)
        let new = ForumUnreadCounts(mentions: 1, replies: 1, messages: 0)
        revisions.incoming(from: old, to: new)
        precondition(revisions.value(for: .mentions) == 0)
        precondition(revisions.value(for: .replies) == 1)
        precondition(revisions.value(for: .messages) == 0)
        revisions.incoming(from: new, to: new)
        revisions.incoming(from: new, to: ForumUnreadCounts())
        precondition(revisions.value(for: .replies) == 1)
        revisions.invalidate(.messages)
        precondition(revisions.value(for: .messages) == 1)

        let mentions = InboxReadCache<String>.Key(route: "mentions", peer: nil)
        let replies = InboxReadCache<String>.Key(route: "replies", peer: nil)
        cache.insert("mentions", for: mentions, cost: 10, revision: revisions.value(for: .mentions))
        cache.insert("replies", for: replies, cost: 10, revision: revisions.value(for: .replies))
        revisions.incoming(from: ForumUnreadCounts(), to: ForumUnreadCounts(messages: 1))
        precondition(cache.value(for: mentions, revision: revisions.value(for: .mentions)) == "mentions")
        precondition(cache.value(for: replies, revision: revisions.value(for: .replies)) == "replies")
        print("Passed inbox switch retention, category-specific incoming/write revisions, confirmed-read updates, account/manual refresh invalidation and memory budgets.")
    }

    @MainActor static func imageSourceCoordinates() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = root
        let space = DeskImageCoordinateSpace.Space(frame: root.bounds)
        root.addSubview(space)
        let moving = NSView(frame: NSRect(x: 100, y: 100, width: 500, height: 800))
        root.addSubview(moving)
        let image = DeskImageSourceAnchor.Anchor(frame: NSRect(x: 20, y: 300, width: 200, height: 120))
        moving.addSubview(image)
        precondition(image.sourceRect == CGRect(x: 120, y: 80, width: 200, height: 120))
        moving.frame.origin.y += 75
        precondition(image.sourceRect == CGRect(x: 120, y: 5, width: 200, height: 120))
        space.removeFromSuperview()
        precondition(image.sourceRect == .zero)
        print("Passed image source coordinates after scroll movement and detached-view fallback.")
    }

    static func markdownTextCache() {
        let samples = ["普通中文内容与 emoji 🔥", "**加粗** 和 *斜体* 与 ~~删除线~~",
                       "[NodeSeek](https://www.nodeseek.com/) 与 `code`",
                       "第一行\n第二行 & <文本>", String(repeating: "长正文 ", count: 8_000)]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for source in samples {
            let expected = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
            precondition(DeskMarkdownText.inline(source) == expected)
            precondition(DeskMarkdownText.inline(source) == expected)
            DeskMarkdownText.removeAll()
            precondition(DeskMarkdownText.inline(source) == expected)
        }
        DeskMarkdownText.removeAll()
        print("Passed bounded Markdown cache equivalence, long text and reset checks.")
    }

    static func signatureCache() {
        let samples = [
            "中文 🔥 [主页](/space/42) · https://example.com/test?q=1",
            "**链接** [禁止](javascript:alert) [凭据](https://name:secret@example.com/) https://example.org/",
            "`代码` 与 *斜体*\n[NodeSeek](https://www.nodeseek.com/)",
            String(repeating: "长签名 无链接 ", count: 2_000)
        ]
        for source in samples {
            ForumMarkdownLink.removeAll()
            let first = ForumMarkdownLink.format(source)
            precondition(ForumMarkdownLink.format(source) == first)
            precondition(first.runs.allSatisfy { $0.link.map(ForumMarkdownLink.canOpen) ?? true })
            ForumMarkdownLink.removeAll()
            precondition(ForumMarkdownLink.format(source) == first)
        }
        let links = ForumMarkdownLink.format(samples[0]).runs.compactMap { $0.link?.absoluteURL }
        precondition(links.contains(URL(string: "https://www.nodeseek.com/space/42")!))
        precondition(links.contains(URL(string: "https://example.com/test?q=1")!))
        ForumMarkdownLink.removeAll()
        print("Passed bounded signature cache equivalence, safe links, relative links, long text and reset checks.")
    }

    @MainActor static func readingDestinations() {
        func floor(_ id: String, author: Bool = false) -> ForumFloor {
            ForumFloor(id: id, author: author ? "OP" : "Guest", authorID: nil, isAuthor: author, avatar: nil, tags: nil,
                date: "", dateLabel: "", blocks: [])
        }
        let thread = ForumThread(title: "Fixture", category: "tech", root: floor("0", author: true),
            replies: [floor("31"), floor("33", author: true), floor("35"), floor("39", author: true)], pages: [], page: 4, replyRestriction: nil)
        func target(_ anchor: String?, fragment: String? = nil, only: Bool = false) -> String {
            ForumReadingDestination.anchor(in: thread, preferred: anchor, fragment: fragment, authorOnly: only)
        }
        precondition(target(nil) == "thread-discussion")
        precondition(target("floor-34") == "floor-33")
        precondition(target("floor-35", only: true) == "floor-33")
        precondition(target(nil, fragment: "comment-39") == "floor-39")
        precondition(target("floor-33", fragment: "comment-39") == "floor-33")
        precondition(target("floor-0") == "floor-0")
        precondition(target("invalid") == "thread-discussion")
        let empty = ForumThread(title: "", category: "", root: nil, replies: [], pages: [], page: 1, replyRestriction: nil)
        precondition(ForumReadingDestination.anchor(in: empty, preferred: "floor-99", fragment: nil, authorOnly: true) == "thread-title")
        precondition(!ReadingProgress.valid("floor-１２") && !ReadingProgress.valid("floor--1"))
        for size in [CGSize(width: 4000, height: 600), CGSize(width: 600, height: 4000), CGSize(width: 1000, height: 20000)] {
            for bounds in [CGRect(x: 24, y: 82, width: 582, height: 296), CGRect(x: 24, y: 82, width: 1200, height: 650)] {
                let fit = DeskImageGeometry.fit(size, in: bounds)
                precondition(fit.width <= bounds.width + 0.01 && fit.height <= bounds.height + 0.01)
                precondition(abs(fit.width / fit.height - size.width / size.height) < 0.001)
                let small = DeskImageGeometry.scaled(fit, by: 0.5)
                precondition(small.midX == fit.midX && small.midY == fit.midY && small.width == fit.width / 2)
            }
        }
        print("Passed deleted-floor, fragment, author-filter, empty-page and image aspect-ratio fallbacks.")
    }

    static func readerLayoutBudget() {
        func floor(_ id: Int, blocks: [ForumBlock]) -> ForumFloor {
            ForumFloor(id: String(id), author: "fixture", authorID: nil, isAuthor: id == 0,
                       avatar: nil, tags: nil, date: "", dateLabel: "", blocks: blocks)
        }
        func block(_ kind: String = "text", text: String = "本地阅读样本") -> ForumBlock {
            ForumBlock(kind: kind, text: text, url: nil, tabs: nil, rows: nil, terminal: nil)
        }
        func thread(_ floors: [ForumFloor]) -> ForumThread {
            ForumThread(title: "fixture", category: "", root: floors.first,
                        replies: Array(floors.dropFirst()), pages: [], page: 1, replyRestriction: nil)
        }
        let normal = (0..<20).map { floor($0, blocks: [block()]) }
        precondition(ReaderLayoutPolicy.preparesWholePage(thread(normal)))
        precondition(!ReaderLayoutPolicy.preparesWholePage(thread((0..<25).map { floor($0, blocks: [block()]) })))
        for kind in ["image", "terminal", "tabs", "table", "disclosure", "unknown"] {
            precondition(!ReaderLayoutPolicy.preparesWholePage(thread([floor(0, blocks: [block(kind)])])))
        }
        precondition(!ReaderLayoutPolicy.preparesWholePage(thread([floor(0, blocks: [block(text: String(repeating: "字", count: 20_000))])])))
        let manyBlocks = floor(0, blocks: Array(repeating: block(), count: 129))
        precondition(!ReaderLayoutPolicy.preparesWholePage(thread([manyBlocks])))
        precondition(ReaderLayoutPolicy.preparesWholePage(thread([])))
        print("Passed bounded small-page preparation and lazy fallback for long pages, oversized text, images, reports and nested content.")
    }

    @MainActor static func readerLifecycle() async throws {
        let suite = "SeekDesk.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        let url = Forum.home.appendingPathComponent("post-101-1")
        let topic = Topic(id: "101", url: url, title: "")
        let thread = ForumThread(title: "Fixture", category: "tech", root: nil, replies: [], pages: [], page: 1, replyRestriction: nil)
        let reader = ForumReaderState(topic: topic, session: session)
        var pending: CheckedContinuation<(ForumThread, ForumWebPage), Error>?
        let oldRequest = Task { await reader.load(topic, session: session, fetch: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        reader.cancel()
        precondition(!reader.isLoading && reader.page == nil)
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        await oldRequest.value
        precondition(reader.page == nil && session.cachedThread(at: url) == nil)
        weak var released: ForumReaderState?
        weak var releasedPage: ForumWebPage?
        for _ in 0..<12 {
            let temporary = ForumReaderState(topic: topic, session: session)
            released = temporary
            await temporary.load(topic, session: session, force: true, fetch: { _, _ in
                let page = ForumWebPage(dataStore: session.dataStore)
                releasedPage = page
                return (thread, page)
            })
            precondition(temporary.page != nil)
            temporary.cancel()
        }
        precondition(released == nil && releasedPage == nil)
        let cancelled = Task { await reader.load(topic, session: session, force: true, fetch: { _, _ in
            try await Task.sleep(for: .seconds(20))
            throw ForumPageError.network
        }) }
        while !reader.isLoading { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        precondition(!reader.isLoading)
        let floor = ForumFloor(id: "8", author: "Author", authorID: 42, isAuthor: false, avatar: nil,
                               tags: nil, date: "", dateLabel: "", blocks: [])
        let cachedThread = ForumThread(title: "Cached", category: "tech", root: nil,
                                       replies: [floor], pages: [], page: 1, replyRestriction: nil)
        session.cacheThread(cachedThread, at: url)
        let cachedReader = ForumReaderState(topic: topic, session: session)
        let beforeReady = cachedReader.profileTaskKey(for: 42)
        precondition(!cachedReader.pageReady && cachedReader.floorIDs == ["floor-8"])
        var phaseChanges = 0
        var readyValues: [Bool] = []
        let phaseObservation = cachedReader.$phase.dropFirst().sink { _ in phaseChanges += 1 }
        let readyObservation = cachedReader.$pageReady.dropFirst().sink { readyValues.append($0) }
        await cachedReader.load(topic, session: session, force: true, fetch: { _, _ in
            (cachedThread, ForumWebPage(dataStore: session.dataStore))
        })
        precondition(phaseChanges == 0, "An unchanged cached document does not need to publish its content again.")
        precondition(cachedReader.pageReady && cachedReader.page != nil && readyValues == [true])
        precondition(cachedReader.profileTaskKey(for: 42) != beforeReady,
                     "Cached floors must restart their profile task when the WebKit page becomes available.")
        precondition(cachedReader.floorIDs == ["floor-8"])
        let changedThread = ForumThread(title: "Changed", category: "tech", root: floor,
                                        replies: [], pages: [], page: 1, replyRestriction: nil)
        await cachedReader.load(topic, session: session, force: true, fetch: { _, _ in
            (changedThread, ForumWebPage(dataStore: session.dataStore))
        })
        precondition(phaseChanges == 1 && cachedReader.floorIDs == ["floor-0"] && readyValues == [true])
        cachedReader.cancel()
        precondition(!cachedReader.pageReady && readyValues == [true, false])
        precondition(cachedReader.profileTaskKey(for: 42) == beforeReady)
        session.observeAccount(false)
        precondition(cachedReader.floorIDs.isEmpty)
        withExtendedLifetime((phaseObservation, readyObservation)) {}
        print("Passed late load rejection, cancelled loading state and release of 12 reader/WebKit lifecycles.")
        print("Passed cached reader page-ready task restart, unchanged-content refresh and floor identity invalidation.")
    }

    @MainActor static func readerFreshness() async throws {
        let suite = "SeekDesk.freshness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 100)
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent(), threadNow: { now })
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let url = Forum.home.appendingPathComponent("post-101-1")
        let topic = Topic(id: "101", url: url, title: "Fixture")
        let thread = ForumThread(title: "Fixture", category: "tech", root: nil,
                                 replies: [], pages: [], page: 1, replyRestriction: nil)
        session.cacheThread(thread, at: url)
        let reader = ForumReaderState(topic: topic, session: session)
        var requests = 0
        let fetch: ForumReaderState.Fetch = { _, _ in
            requests += 1
            return (thread, ForumWebPage(dataStore: session.dataStore))
        }
        for _ in 0..<5 { await reader.load(topic, session: session, fetch: fetch) }
        precondition(requests == 0 && reader.page == nil && !reader.isLoading)
        guard case .ready = reader.phase else { preconditionFailure("A fresh revisit must show its parsed content") }
        let prepared = await reader.preparePage(topic, session: session, fetch: fetch)
        let reused = await reader.preparePage(topic, session: session, fetch: fetch)
        precondition(prepared != nil && reused === prepared && requests == 1)
        await reader.load(topic, session: session, force: true, fetch: fetch)
        precondition(requests == 2)
        let failed = await reader.load(topic, session: session, force: true, fetch: { _, _ in throw ForumPageError.network })
        precondition(!failed && reader.refreshIssue == .network)
        guard case .ready = reader.phase else { preconditionFailure("A failed refresh must keep readable content") }
        let retried = await reader.preparePage(topic, session: session, fetch: fetch)
        precondition(retried != nil && requests == 3)

        reader.cancel()
        now += 121
        precondition(!session.threadIsFresh(at: url) && session.cachedThread(at: url) != nil)
        await reader.load(topic, session: session, fetch: fetch)
        precondition(requests == 4 && session.threadIsFresh(at: url))
        session.invalidateThread(topic.id)
        precondition(session.cachedThread(at: url) == nil)
        await reader.load(topic, session: session, fetch: fetch)
        precondition(requests == 5)

        reader.cancel()
        let unavailable = await reader.preparePage(topic, session: session, fetch: { _, _ in throw ForumPageError.network })
        precondition(unavailable == nil)
        let recovered = await reader.preparePage(topic, session: session, fetch: fetch)
        precondition(recovered != nil && requests == 6)
        reader.cancel()

        var pending: CheckedContinuation<(ForumThread, ForumWebPage), Error>?
        let preparing = Task { await reader.preparePage(topic, session: session, fetch: { _, _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        await reader.load(topic, session: session, fetch: fetch)
        precondition(reader.isLoading && requests == 7, "An ordinary cached appearance must not cancel interactive preparation")
        let duplicate = await reader.preparePage(topic, session: session, fetch: fetch)
        precondition(duplicate == nil && requests == 7)
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        pending = nil
        let preparingResult = await preparing.value
        precondition(preparingResult != nil)
        reader.cancel()

        let cancelled = Task { await reader.preparePage(topic, session: session, fetch: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        reader.cancel()
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        pending = nil
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil && reader.page == nil)

        let oldWriteRead = Task { await reader.load(topic, session: session, force: true, fetch: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        session.invalidateThread(topic.id)
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        pending = nil
        let oldWriteResult = await oldWriteRead.value
        precondition(!oldWriteResult)
        precondition(session.cachedThread(at: url) == nil && reader.page == nil)
        precondition(!reader.isLoading && reader.refreshIssue == .changed)
        guard case .ready = reader.phase else { preconditionFailure("A written topic keeps readable content with retry feedback") }

        session.cacheThread(thread, at: url)
        let oldAccount = Task { await reader.preparePage(topic, session: session, fetch: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        session.observeIdentity(.init(signedIn: true, id: 8, name: nil, floorsPerPage: nil))
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        pending = nil
        let oldAccountResult = await oldAccount.value
        precondition(oldAccountResult == nil)
        precondition(session.cachedThread(at: url) == nil && reader.page == nil)

        let huge = ForumThread(title: "Report", category: "tech", root: nil,
            replies: [ForumFloor(id: "1", author: "Guest", authorID: nil, isAuthor: false, avatar: nil,
                tags: nil, date: "", dateLabel: "", blocks: [ForumBlock(kind: "line",
                    text: String(repeating: "x", count: 8_500_000), url: nil, tabs: nil, rows: nil, terminal: nil)])],
            pages: [], page: 1, replyRestriction: nil)
        await reader.load(topic, session: session, force: true, fetch: { _, _ in
            (huge, ForumWebPage(dataStore: session.dataStore))
        })
        precondition(session.cachedThread(at: url) == nil)
        let hugePage = await reader.preparePage(topic, session: session, fetch: { _, _ in
            preconditionFailure("The active oversized page must remain usable without cache retention")
        })
        precondition(hugePage != nil)
        reader.cancel()
        print("Passed fresh cache-only revisits, expiry/manual/write refresh, on-demand page reuse/retry, oversized pages, preparation single-flight and late cancel/account/write rejection.")
    }

    @MainActor static func readerWriteIsolation() async throws {
        let suite = "SeekDesk.reader-write-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let topic = Topic(id: "202", url: Forum.home.appendingPathComponent("post-202-1"), title: "Pending B")
        let thread = ForumThread(title: "Pending B", category: "tech", root: nil,
                                 replies: [], pages: [], page: 1, replyRestriction: nil)
        var pending: CheckedContinuation<(ForumThread, ForumWebPage), Error>?
        let reader = ForumReaderState(topic: topic, session: session)
        let loading = Task { await reader.load(topic, session: session, fetch: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }) }
        while pending == nil { await Task.yield() }
        guard case .loading = reader.phase else { preconditionFailure("Fixture must begin with a cold reader") }
        session.invalidateThread("101")
        pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore)))
        pending = nil
        let loaded = await loading.value
        precondition(loaded && !reader.isLoading && reader.pageReady)
        guard case .ready(let actual) = reader.phase, actual == thread else {
            preconditionFailure("Writing A must not silently discard a cold first load of B")
        }
        precondition(session.cachedThread(at: topic.url) == thread)
        reader.cancel()

        for staleError in [false, true] {
            session.invalidateThread(topic.id)
            let cold = ForumReaderState(topic: topic, session: session)
            let first = Task { await cold.load(topic, session: session, fetch: { _, _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }) }
            while pending == nil { await Task.yield() }
            guard case .loading = cold.phase else { preconditionFailure("Same-topic fixture must begin cold") }
            session.invalidateThread(topic.id)
            if staleError { pending?.resume(throwing: ForumPageError.network) }
            else { pending?.resume(returning: (thread, ForumWebPage(dataStore: session.dataStore))) }
            pending = nil
            let result = await first.value
            precondition(!result && !cold.isLoading && !cold.pageReady && cold.page == nil)
            guard case .failed(.changed) = cold.phase else {
                preconditionFailure("A same-topic write during cold load must settle to a retryable changed state")
            }
            var retries = 0
            let retry = await cold.load(topic, session: session, fetch: { _, _ in
                retries += 1
                return (thread, ForumWebPage(dataStore: session.dataStore))
            })
            precondition(retry && retries == 1 && !cold.isLoading && cold.refreshIssue == nil)
            guard case .ready = cold.phase else { preconditionFailure("Changed state must allow a successful retry") }
            cold.cancel()
        }
        print("Passed cold-reader cross-topic write isolation and same-topic stale-success/error retry states.")
    }

    @MainActor static func restoredInlineEditing() async throws {
        let suite = "SeekDesk.restored-inline-edit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let topic = Topic(id: "101", url: Forum.home.appendingPathComponent("post-101-1"), title: "Original title")
        let thread = ForumThread(title: "Original title", category: "tech", root: nil,
                                 replies: [], pages: [], page: 1, replyRestriction: nil)
        let page = ForumWebPage(dataStore: session.dataStore)
        page.webView.loadHTMLString(#"""
        <!doctype html><html><head><script>
        window.__fixtureReady = true;
        window.__writes = 0;
        window.__config__ = {user:{member_id:7},postData:{postId:101,title:'Original title',rank:0,
            comments:[{floorIndex:0,markdown:'Original content',poster:{isMe:true}}]}};
        window.fetch = async () => { window.__writes += 1;
            return {ok:true,status:200,headers:{get:()=>null},json:async()=>({success:true})}; };
        </script></head><body></body></html>
        """#, baseURL: topic.url)
        var fixtureReady = false
        for _ in 0..<300 {
            if let ready = try? await page.webView.callAsyncJavaScript("return window.__fixtureReady === true;", arguments: [:], in: nil, contentWorld: .page),
               (ready as? Bool) == true { fixtureReady = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(fixtureReady, "Local HTML fixture must settle without forum requests")
        let edit = ForumInlineEdit()
        edit.begin(.init(topicID: 101, floor: 0, owner: 7))
        await edit.load(on: page)
        precondition(edit.ready && edit.content == "Original content")
        edit.content = "Preserved local draft 中文"
        edit.title = "Preserved title"
        session.rememberEdit(edit, at: topic.url)
        session.cacheThread(thread, at: topic.url)
        let revisited = ForumReaderState(topic: topic, session: session)
        precondition(revisited.page == nil && session.pendingEdit(at: topic.url) === edit && edit.canSave)
        var preparations = 0
        let prepared = await revisited.preparePage(topic, session: session, force: true, fetch: { _, _ in
            preparations += 1
            return (thread, page)
        })
        precondition(prepared === page && preparations == 1)
        precondition(session.pendingEdit(at: topic.url) === edit && edit.content == "Preserved local draft 中文" &&
                     edit.title == "Preserved title" && edit.ready && edit.canSave,
                     "On-demand preparation for a restored edit must not reload or overwrite its draft")
        let failedPreparation = await revisited.preparePage(topic, session: session, force: true, fetch: { _, _ in
            throw ForumPageError.network
        })
        precondition(failedPreparation == nil && revisited.refreshIssue == .network,
                     "Forced edit preparation must not fall back to a previously retained page")
        precondition(edit.content == "Preserved local draft 中文" && edit.title == "Preserved title" && edit.canSave)
        let rejected = await edit.save(on: page, authorized: { false })
        precondition(!rejected && !edit.saving && edit.content == "Preserved local draft 中文")
        let writes = try await page.webView.callAsyncJavaScript("return window.__writes;", arguments: [:], in: nil, contentWorld: .page)
        precondition((writes as? Int) == 0, "An expired authorization/snapshot must not send a write")
        revisited.cancel()
        print("Passed restored inline-edit on-demand preparation, forced-failure rejection, draft retention and unauthorized zero-write checks.")
    }

    @MainActor static func discussionAbandonment() {
        let suite = "SeekDesk.discussion-abandonment.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let draft = session.newDiscussion
        precondition(DiscussionAbandonment.decision(for: draft, publishing: false, uploading: false) == .close)
        draft.title = " \n "
        draft.content = "\t\n "
        precondition(DiscussionAbandonment.decision(for: draft, publishing: false, uploading: false) == .close,
                     "Whitespace-only text must close without a destructive-content confirmation")
        precondition(DiscussionAbandonment.discard(draft, publishing: false, uploading: false))
        precondition(draft === session.newDiscussion && draft.snapshot == .init())

        let image = URL(string: "https://images.example/discussion.png")!
        let changes: [(NewDiscussionDraft) -> Void] = [
            { $0.title = "Only a title" }, { $0.content = "Only body 中文" },
            { $0.category = "tech" }, { $0.rank = 255 },
            { $0.imageSizing.set(0.5, previewWidth: 640, for: image) }
        ]
        for change in changes {
            draft.clear()
            change(draft)
            precondition(DiscussionAbandonment.decision(for: draft, publishing: false, uploading: false) == .confirm)
            let snapshot = draft.snapshot
            let sizes = draft.imageSizing.sizes
            for (sending, uploading) in [(true, false), (false, true), (true, true)] {
                precondition(DiscussionAbandonment.decision(for: draft, publishing: sending, uploading: uploading) == .blocked)
                precondition(!DiscussionAbandonment.discard(draft, publishing: sending, uploading: uploading))
                precondition(draft.snapshot == snapshot && draft.imageSizing.sizes == sizes,
                             "Publishing or image upload must protect the live draft from abandonment")
            }
            precondition(DiscussionAbandonment.discard(draft, publishing: false, uploading: false))
            precondition(draft === session.newDiscussion && draft.snapshot == .init() && draft.imageSizing.sizes.isEmpty)
        }
        draft.title = "Discard me"
        draft.content = "Discard this body"
        draft.category = "tech"
        draft.rank = 2
        draft.imageSizing.set(0.5, previewWidth: 640, for: image)
        precondition(DiscussionAbandonment.discard(draft, publishing: false, uploading: false))
        let restored = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        restored.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        precondition(restored.newDiscussion.snapshot == .init() && restored.newDiscussion.imageSizing.sizes.isEmpty,
                     "A confirmed abandonment must persist the cleared draft for the same owner")
        print("Passed discussion abandonment empty/nonempty confirmation, publishing/upload protection, draft identity and persisted cleanup.")
    }

    @MainActor static func readingPositions() {
        let suite = "SeekDesk.reading-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let first = Forum.home.appendingPathComponent("post-101-1")
        let token = session.authorization
        session.rememberAnchor("floor-21", at: first, authorization: token)
        for id in 101...109 {
            let url = Forum.home.appendingPathComponent("post-\(id)-1")
            let thread = ForumThread(title: "Fixture", category: "tech", root: nil, replies: [], pages: [], page: 1, replyRestriction: nil)
            session.cacheThread(thread, at: url)
        }
        precondition(session.cachedThread(at: first) == nil && session.anchor(at: first) == "floor-21")

        // A five-tab cycle should fit within the bounded parsed-page cache. A
        // cache hit also becomes most-recently-used, so the first page remains
        // available when a sixth page is added.
        let tabSession = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        let tabURLs = (201...208).map { Forum.home.appendingPathComponent("post-\($0)-1") }
        for (index, url) in tabURLs.enumerated() {
            let thread = ForumThread(title: "Tab \(index)", category: "tech", root: nil,
                                     replies: [], pages: [], page: 1, replyRestriction: nil)
            tabSession.cacheThread(thread, at: url)
        }
        precondition(tabURLs.allSatisfy { tabSession.cachedThread(at: $0) != nil })
        _ = tabSession.cachedThread(at: tabURLs[0])
        let ninth = Forum.home.appendingPathComponent("post-209-1")
        tabSession.cacheThread(ForumThread(title: "Tab 9", category: "tech", root: nil,
                                        replies: [], pages: [], page: 1, replyRestriction: nil), at: ninth)
        precondition(tabSession.cachedThread(at: tabURLs[0]) != nil)
        precondition(tabSession.cachedThread(at: tabURLs[1]) == nil)

        // A single report above the weighted budget is bypassed while the
        // existing small pages remain usable.
        let oversizedText = String(repeating: "x", count: 8_500_000)
        let oversizedBlock = ForumBlock(kind: "line", text: oversizedText, url: nil,
                                        tabs: nil, rows: nil, terminal: nil)
        let oversized = ForumThread(title: "Oversized", category: "tech", root: nil,
                                    replies: [ForumFloor(id: "1", author: "Guest", authorID: nil,
                                                         isAuthor: false, avatar: nil, tags: nil,
                                                         date: "", dateLabel: "", blocks: [oversizedBlock])],
                                    pages: [], page: 1, replyRestriction: nil)
        precondition(ForumThreadCacheCost.estimate(oversized) > ForumThreadCacheCost.limit)
        let oversizedURL = Forum.home.appendingPathComponent("post-207-1")
        tabSession.cacheThread(oversized, at: oversizedURL)
        precondition(tabSession.cachedThread(at: oversizedURL) == nil)
        precondition(tabSession.cachedThread(at: tabURLs[0]) != nil)
        session.observeIdentity(.init(signedIn: true, id: 8, name: nil, floorsPerPage: nil))
        session.rememberAnchor("floor-99", at: first, authorization: token)
        precondition(session.anchor(at: first) == nil)
        session.rememberAnchor("floor-8", at: first, authorization: session.authorization)
        session.observeAccount(false)
        precondition(session.anchor(at: first) == nil)
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        precondition(session.anchor(at: first) == "floor-21")
        session.readingProgress.flush()
        let restarted = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        restarted.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        precondition(restarted.anchor(at: first) == "floor-21")
        print("Passed reading-position cache eviction, stale view rejection, account isolation and restart restore.")
    }

    @MainActor static func accounts() async throws {
        let suite = "SeekDesk.regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func profile(_ id: Int) -> ForumProfile {
            .init(id: id, name: "Account \(id)", rank: 2, joined: nil, bio: nil, topics: nil,
                  replies: nil, following: nil, followers: nil, coin: nil)
        }
        func login(_ session: ForumSession, _ id: Int) {
            session.observeAccount(true)
            session.updateOwnProfile(profile(id))
        }
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        login(session, 7)
        let image = URL(string: "https://example.com/report.png")!
        session.edit("A reply", for: "101")
        session.messageDrafts[11] = "A private message"
        session.newDiscussion.title = "A title"
        session.newDiscussion.content = "A discussion"
        session.imageSizing(for: .reply("101")).set(0.5, previewWidth: 640, for: image)
        session.newDiscussion.imageSizing.set(0.75, previewWidth: 500, for: image)
        let oldDiscussion = session.newDiscussion
        let oldToken = session.authorization
        session.observeAccount(false)
        precondition(session.drafts.isEmpty && session.messageDrafts.isEmpty && session.newDiscussion.content.isEmpty)
        precondition(!session.authorizes(oldToken))
        login(session, 8)
        precondition(session.drafts.isEmpty && session.messageDrafts.isEmpty && session.newDiscussion.content.isEmpty)
        oldDiscussion.content = "delayed editor result"
        session.edit("B reply", for: "101")
        session.observeAccount(false)
        login(session, 7)
        precondition(session.drafts["101"] == "A reply" && session.messageDrafts[11] == "A private message")
        precondition(session.newDiscussion.content == "A discussion" && session.newDiscussion.title == "A title")
        precondition(session.imageSizing(for: .reply("101")).sizes[image]?.ratio == 0.5)
        precondition(session.newDiscussion.imageSizing.sizes[image]?.ratio == 0.75)
        let restored = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        precondition(restored.drafts.isEmpty && restored.newDiscussion.content.isEmpty)
        login(restored, 7)
        precondition(restored.drafts["101"] == "A reply" && restored.messageDrafts[11] == "A private message")
        precondition(restored.newDiscussion.content == "A discussion")
        restored.edit("", for: "101")
        let restoredAgain = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        login(restoredAgain, 7)
        precondition(restoredAgain.drafts["101"] == nil)
        print("Passed F01/F04 owner-scoped reply, DM, discussion, image settings, relogin and restart persistence.")

        let url = URL(string: "https://www.nodeseek.com/post-101-1")!
        let topic = Topic(id: "101", url: url, title: "Restricted")
        let thread = ForumThread(title: "A restricted thread", category: "inside", root: nil, replies: [],
                                 pages: [], page: 1, replyRestriction: nil)
        session.cacheThread(thread, at: url)
        let reader = ForumReaderState(topic: topic, session: session)
        await reader.load(topic, session: session, fetch: { _, _ in throw ForumPageError.network })
        guard case .ready = reader.phase else { preconditionFailure("Same-account offline content should remain") }
        session.observeAccount(false)
        guard case .loading = reader.phase else { preconditionFailure("Logout must synchronously clear visible content") }
        login(session, 8)
        await reader.load(topic, session: session, fetch: { _, _ in throw ForumPageError.network })
        guard case .failed = reader.phase else { preconditionFailure("B must never fall back to A's content") }
        var authorized = true
        let row = FeedPost(id: "201", url: url, title: "A restricted title", author: "A", category: "inside", published: nil, summary: "")
        let workspace = Workspace(defaults: defaults, fetchFeed: { [] }, fetchPage: { _ in
            guard authorized else { throw ForumPageError.signInRequired }
            return ForumListingPage(posts: [row], next: nil)
        })
        workspace.choose(.inside)
        await workspace.refresh()
        precondition(workspace.filteredPosts.count == 1)
        authorized = false
        await workspace.refresh()
        precondition(workspace.filteredPosts.isEmpty)
        var listingContinuation: CheckedContinuation<ForumListingPage, Never>?
        let delayedList = Workspace(defaults: defaults, fetchFeed: { [] }, fetchPage: { _ in
            await withCheckedContinuation { listingContinuation = $0 }
        })
        delayedList.choose(.inside)
        let listTask = Task { await delayedList.refresh() }
        while listingContinuation == nil { await Task.yield() }
        delayedList.invalidateForumAccess()
        listingContinuation?.resume(returning: .init(posts: [row], next: nil))
        await listTask.value
        precondition(delayedList.filteredPosts.isEmpty)
        print("Passed F02 synchronous reader invalidation, same-account offline use and stale/restricted listings.")

        for response in [#"{"kind":"signIn"}"#, #"{"kind":"verification"}"#,
                         #"{"kind":"response","response":{"success":true,"redirect":"/post-101-1"}}"#] {
            var continuation: CheckedContinuation<String?, Never>?
            var completed = false
            let transport = ForumSession.Requests(reply: { _, _, _ in
                let result = await withCheckedContinuation { continuation = $0 }
                completed = true
                return result
            }, profile: { _, _, _ in nil })
            let pending = ForumSession(defaults: defaults, dataStore: .nonPersistent(), requests: transport)
            login(pending, 7)
            pending.edit("pending A reply", for: "101")
            let sendTask = pending.send(topic: topic, on: ForumWebPage(dataStore: pending.dataStore))
            while continuation == nil { await Task.yield() }
            pending.finishAccess(true)
            login(pending, 8)
            pending.edit("B current draft", for: "101")
            continuation?.resume(returning: response)
            await sendTask?.value
            precondition(completed)
            precondition(pending.account == .signedIn && pending.memberID == 8 && pending.ownProfile?.id == 8)
            precondition(pending.drafts["101"] == "B current draft" && pending.receipts.isEmpty)
        }
        print("Passed F03 delayed old-account reply success, sign-in failure and verification responses.")
    }

    @MainActor static func profiles() async throws {
        let suite = "SeekDesk.profile-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        var value: String?
        var now = Date()
        var holdRequest = false
        var pending: CheckedContinuation<String?, Never>?
        let requests = ForumSession.Requests(reply: { _, _, _ in nil }, profile: { _, _, _ in
            count += 1
            if holdRequest { return await withCheckedContinuation { pending = $0 } }
            return value
        })
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent(), requests: requests, profileNow: { now })
        let page = ForumWebPage(dataStore: session.dataStore)
        var sessionChanges = 0
        var requestChanges = 0
        let sessionObservation = session.objectWillChange.sink { sessionChanges += 1 }
        let requestObservation = session.profileRequestState.objectWillChange.sink { requestChanges += 1 }
        defer { sessionObservation.cancel(); requestObservation.cancel() }
        await session.loadProfile(42, using: page)
        precondition(session.profileFailures.contains(42) && !session.profileLoading.contains(42))
        precondition(sessionChanges == 0 && requestChanges == 3,
                     "Failure/loading feedback must update profile UI without invalidating the reader's session.")
        requestChanges = 0
        value = #"{"member_id":42,"member_name":"fixture","bio":"old","readme":"old"}"#
        await session.loadProfile(42, using: page, includeReadme: true, force: true)
        precondition(session.profiles[42]?.bio == "old" && session.profileFailures.isEmpty)
        precondition(sessionChanges == 0 && requestChanges == 3,
                     "Retry publishes profile data and loading/error feedback outside the reader's session.")
        sessionChanges = 0
        requestChanges = 0
        let loaded = count
        value = #"{"member_id":42,"member_name":"fixture","bio":"new","readme":"new"}"#
        await session.loadProfile(42, using: page, includeReadme: true)
        precondition(count == loaded)
        precondition(sessionChanges == 0 && requestChanges == 0)
        now = now.addingTimeInterval(181)
        await session.loadProfile(42, using: page, includeReadme: true)
        precondition(count == loaded + 1 && session.profiles[42]?.bio == "new")
        precondition(sessionChanges == 0 && requestChanges == 2,
                     "Successful refresh keeps both profile data and request feedback outside the reader's session.")
        sessionChanges = 0
        requestChanges = 0
        value = nil
        await session.loadProfile(42, using: page, force: true)
        precondition(session.profileFailures.contains(42) && session.profiles[42]?.bio == "new")
        precondition(sessionChanges == 0 && requestChanges == 3)

        // Removing a missing failure/loading entry or repeating the same status is silent.
        let feedback = ForumProfileRequestState()
        var feedbackChanges = 0
        let feedbackObservation = feedback.objectWillChange.sink { feedbackChanges += 1 }
        defer { feedbackObservation.cancel() }
        feedback.reset()
        feedback.finish(42)
        precondition(feedbackChanges == 0)
        feedback.begin(42)
        feedback.begin(42)
        precondition(feedbackChanges == 1)
        feedback.fail(42)
        feedback.fail(42)
        precondition(feedbackChanges == 2)
        feedback.finish(42)
        feedback.finish(42)
        precondition(feedbackChanges == 3)
        feedback.reset()
        feedback.reset()
        precondition(feedbackChanges == 4)

        // Clearing account/route state also rejects late feedback from the old request.
        for proxyChange in [false, true] {
            holdRequest = false
            await session.loadProfile(42, using: page, force: true)
            precondition(session.profileFailures.contains(42))
            holdRequest = true
            pending = nil
            let delayed = Task { await session.loadProfile(43, using: page, force: true) }
            while pending == nil { await Task.yield() }
            precondition(session.profileLoading.contains(43))
            let changesBeforeReset = requestChanges
            if proxyChange { NotificationCenter.default.post(name: .deskProxyRouteChanged, object: nil) }
            else { session.finishAccess(nil) }
            precondition(session.profileLoading.isEmpty && session.profileFailures.isEmpty)
            precondition(requestChanges > changesBeforeReset, "Profile UI must observe account/route cleanup.")
            let changesAfterReset = requestChanges
            pending?.resume(returning: nil)
            await delayed.value
            precondition(session.profileLoading.isEmpty && session.profileFailures.isEmpty)
            precondition(requestChanges == changesAfterReset, "Discarded requests must not restore stale feedback.")
        }
        print("Passed F09 cache expiry, force refresh, failure state, retry and stale-data retention.")
        print("Passed profile request notification isolation, silent no-ops and account/proxy feedback cleanup.")
    }

    @MainActor static func profileEntries() async {
        let suite = "SeekDesk.profile-entries.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var label = "old"
        var heldID: Int?
        var pending: CheckedContinuation<String?, Never>?
        var requestsMade = 0
        func payload(_ id: Int, _ name: String) -> String {
            "{\"member_id\":\(id),\"member_name\":\"\(name)\",\"rank\":2,\"readme\":\"fixture\",\"roles\":[{\"display_text\":\"member\"}]}"
        }
        let requests = ForumSession.Requests(reply: { _, _, _ in nil }, profile: { _, id, _ in
            requestsMade += 1
            if id == heldID { return await withCheckedContinuation { pending = $0 } }
            return payload(id, label)
        })
        let session = ForumSession(defaults: defaults, dataStore: .nonPersistent(), requests: requests, profileNow: { now })
        session.observeIdentity(.init(signedIn: true, id: 7, name: nil, floorsPerPage: nil))
        let page = ForumWebPage(dataStore: session.dataStore)
        let first = session.profileStore.entry(for: 42)
        let second = session.profileStore.entry(for: 43)
        precondition(first === session.profileStore.entry(for: 42))
        var sessionChanges = 0, firstChanges = 0, secondChanges = 0
        let sessionObservation = session.objectWillChange.sink { sessionChanges += 1 }
        let firstObservation = first.objectWillChange.sink { firstChanges += 1 }
        let secondObservation = second.objectWillChange.sink { secondChanges += 1 }
        defer { sessionObservation.cancel(); firstObservation.cancel(); secondObservation.cancel() }

        await session.loadProfile(42, using: page)
        precondition(first.profile == session.profiles[42] && first.profile?.member_name == "old")
        precondition(sessionChanges == 0 && firstChanges == 1 && secondChanges == 0)
        await session.loadProfile(43, using: page)
        precondition(sessionChanges == 0 && firstChanges == 1 && secondChanges == 1)
        let beforeForce = requestsMade
        await session.loadProfile(42, using: page, force: true)
        precondition(requestsMade == beforeForce + 1)
        precondition(sessionChanges == 0 && firstChanges == 1 && secondChanges == 1,
                     "A forced equal profile, including equal role data, must not publish a value change.")
        label = "updated"
        await session.loadProfile(42, using: page, force: true)
        precondition(first.profile?.member_name == "updated" && second.profile?.member_name == "old")
        precondition(sessionChanges == 0 && firstChanges == 2 && secondChanges == 1)

        // Live cells survive an eviction: they clear once and receive future
        // data through the same identity instead of becoming orphaned views.
        session.profileStore.remove(42)
        precondition(first.profile == nil && session.profiles[42] == nil && firstChanges == 3)
        session.profileStore.remove(42)
        precondition(firstChanges == 3 && first === session.profileStore.entry(for: 42))
        await session.loadProfile(42, using: page)
        precondition(first.profile?.member_name == "updated" && firstChanges == 4 && sessionChanges == 0)

        heldID = 44
        let delayed = Task { await session.loadProfile(44, using: page, force: true) }
        while pending == nil { await Task.yield() }
        session.observeIdentity(.init(signedIn: true, id: 8, name: nil, floorsPerPage: nil))
        precondition(session.profiles.isEmpty && first.profile == nil && second.profile == nil)
        precondition(firstChanges == 5 && secondChanges == 2)
        let changesAfterAccount = sessionChanges
        pending?.resume(returning: payload(44, "old account"))
        await delayed.value
        precondition(session.profiles.isEmpty && sessionChanges == changesAfterAccount)
        heldID = nil
        label = "new account"
        await session.loadProfile(42, using: page)
        precondition(first === session.profileStore.entry(for: 42) && first.profile?.member_name == "new account")
        precondition(firstChanges == 6 && secondChanges == 2 && sessionChanges == changesAfterAccount)

        // Keep the existing 240-member cache cap; eviction clears mounted
        // entries without sending an unrelated session notification.
        for id in 1_000..<1_241 {
            now = now.addingTimeInterval(1)
            await session.loadProfile(id, using: page)
        }
        precondition(session.profiles.count == 240 && first.profile == nil)
        precondition(session.profiles[1_000] == nil && session.profiles[1_240] != nil)
        precondition(firstChanges == 7 && secondChanges == 2 && sessionChanges == changesAfterAccount)
        print("Passed per-member profile notifications, equal force refresh, live-cell eviction, account isolation and 240-member retention.")
    }

    static func markdownAndReports() throws {
        let url = URL(string: "https://example.com/image(1).png")!
        for source in [#"![report](https://example.com/image(1).png)"#,
                       #"![a\]b](https://example.com/image(1).png)"#,
                       #"![nested [label]](<https://example.com/image(1).png> 'title')"#] {
            let inline = MarkdownPreviewDocument.inline(source)
            guard case .image(let parsed, _, false) = inline.first, inline.count == 1 else { preconditionFailure(source) }
            precondition(parsed == url)
            let references = MarkdownPreviewDocument.imageReferences(source, selected: [url])
            precondition(references.count == 1)
            let replacement = URL(string: "https://example.com/new.png")!
            precondition(MarkdownPreviewDocument.replacingImages(source, references: references, with: [url: replacement]).contains(replacement.absoluteString))
        }
        let selection = "a]b"
        let edit = MarkdownCommand.image.edit(source: selection, selection: NSRange(location: 0, length: selection.utf16.count))!
        let generated = edit.text.replacingOccurrences(of: "https://", with: "https://example.com/image.png")
        guard case .image(_, let label, _) = MarkdownPreviewDocument.inline(generated).first else { preconditionFailure(generated) }
        precondition(label == selection)
        let tick = String(UnicodeScalar(96))
        let example = "![report](https://example.com/image(1).png)"
        precondition(MarkdownPreviewDocument.imageReferences(tick + example + tick, selected: [url]).isEmpty)
        precondition(MarkdownPreviewDocument.imageReferences("~~~\n" + example + "\n~~~", selected: [url]).isEmpty)
        for count in [249, 250, 251, 300, 1500] {
            let input = (1...count).map { "report line \($0)" }.joined(separator: "\n")
            let lines = ForumTerminalANSI.lines(input)
            precondition(lines.count == count)
            precondition(lines.map { $0.map(\.text).joined() }.joined(separator: "\n") == input)
        }
        let longLine = String(repeating: "x", count: 250_001)
        precondition(ForumTerminalANSI.lines(longLine)[0].map(\.text).joined() == longLine)
        print("Passed F07/F08 escaped/nested Markdown images, editor roundtrip, code exclusions and complete long reports.")
    }

    static func images() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        let width = 1000, height = 20000
        let data = Data(repeating: 180, count: width * height)
        let bitmap = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: data as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, bitmap, nil)
        precondition(CGImageDestinationFinalize(output))
        let decoded = try ForumImageRequest.decode(file)
        precondition(decoded.image.width == width && decoded.image.height == height)
        precondition(decoded.originalSize == CGSize(width: width, height: height))
        let original = try ForumImageRequest.decode(file, kind: .original)
        precondition(original.image.width == width && original.image.height == height)
        let resized = try NodeImageUpload.resizedPicture(file: file, scale: .init(ratio: 0.5, previewWidth: 1000))
        let source = CGImageSourceCreateWithData(resized.data as CFData, nil)!
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        precondition(info[kCGImagePropertyPixelWidth as String] as? Int == 500)
        precondition(info[kCGImagePropertyPixelHeight as String] as? Int == 10000)
        print("Passed F06 readable long-image decoding, original dimensions and proportional upload resizing.")
    }

    static func unread() {
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error?.toString() ?? "JS failure") }
        context.evaluateScript(#"""
        var result, rows = [];
        var location = {protocol:'https:',host:'www.nodeseek.com'};
        var AbortController = class { constructor(){ this.signal = {}; } abort() {} };
        var setTimeout = () => 1, clearTimeout = () => {};
        var fetch = async () => ({status:200,ok:true,headers:{get:()=>null},json:async()=>({success:true,msgArray:rows})});
        """#)
        context.evaluateScript("var read = async (route, selfID, peerID) => {\(ForumAccountScript.read)};")
        for latest in ["{sender_id:7,receiver_id:11,created_at:'2026-11-10T02:00:00Z'}",
                       "{sender_id:11,receiver_id:7,viewed:1,created_at:'2026-11-10T02:00:00Z'}"] {
            for reverse in [false, true] {
                context.evaluateScript("rows=[{sender_id:11,receiver_id:7,viewed:0,created_at:'2026-11-10T01:00:00Z'},\(latest)]; \(reverse ? "rows.reverse();" : "") read('messages',7,0).then(v=>result=JSON.parse(v));")
                precondition(context.evaluateScript("result.data[0].unread && result.data[0].date === '2026-11-10T02:00:00Z'").toBool())
            }
        }
        print("Passed F05 unread aggregation independent of latest message and server ordering.")
    }
}
