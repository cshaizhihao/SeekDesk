import Foundation
import WebKit

@MainActor
private final class TitleGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }
        fatalError("Memory request did not reach its gate")
    }
}

@MainActor
private final class TitleMemory {
    var rows: [FeedPost] = []
    var feedRows: [FeedPost] = []
    var listingFailure = false
    var listingGate: TitleGate?
    var pageReads = 0, feedReads = 0
    var readerReads: [String] = []
    var readerTitles: [String: String] = [:]
    var events: [(String, [String: Any])] = []
    var allowEditor = false
    var editWrites = 0
}

@MainActor
private final class TitleFixture {
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let memory = TitleMemory()

    init(defaults: UserDefaults) {
        let memory = memory
        let proxy = DeskProxyController(defaults: defaults, readVault: { fatalError("No Keychain/vault reads") },
            saveVault: { _, _ in fatalError("No proxy vault writes") },
            fetchSubscription: { _ in fatalError("No subscription networking") },
            measureNode: { _ in fatalError("No node probes") })
        let sessionRequests = ForumSession.Requests(
            reply: { _, _, _ in fatalError("No reply writes") },
            profile: { _, _, _ in fatalError("No profile networking") })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(),
            sessionRequests: sessionRequests, proxy: proxy,
            fetchFeed: {
                memory.feedReads += 1
                return memory.feedRows
            }, fetchPage: { _ in
                memory.pageReads += 1
                let rows = memory.rows
                if let gate = memory.listingGate { await gate.wait() }
                if memory.listingFailure { throw ForumPageError.network }
                return .init(posts: rows, next: nil)
            }, fetchPeople: { _ in fatalError("No people networking") })
        var requests = NativeForumServices.Requests()
        requests.reader = { topic, reader, session, _ in
            memory.readerReads.append(topic.id)
            guard let title = memory.readerTitles[topic.id] else { fatalError("Unexpected reader request") }
            return await reader.load(topic, session: session, force: true, fetch: { _, session in
                (Self.thread(title), ForumWebPage(dataStore: session.dataStore))
            })
        }
        requests.image = { _, _ in fatalError("No image networking") }
        requests.inbox = { _, _, _, _, _, _ in fatalError("No inbox networking") }
        requests.inboxPreview = { _, _, _ in fatalError("No inbox preview networking") }
        requests.markRead = { _, _, _ in fatalError("No mark-read writes") }
        requests.profile = { _, _, _ in fatalError("No profile networking") }
        requests.readerAuthor = { _, _, _ in fatalError("No author networking") }
        requests.options = { _, _, _ in fatalError("No composer networking") }
        requests.preparePage = { _, _, session in
            guard memory.allowEditor else { fatalError("Unexpected page preparation") }
            return ForumWebPage(dataStore: session.dataStore)
        }
        requests.prepareMessage = { _, _, _ in fatalError("No message preparation") }
        requests.sendMessage = { _, _, _, _ in fatalError("No message sends") }
        requests.refreshMessageUnread = { _ in fatalError("No unread networking") }
        requests.sendReply = { _, _, _ in fatalError("No reply writes") }
        requests.publish = { _, _, _, _ in fatalError("No publication") }
        requests.makeEdit = {
            guard memory.allowEditor else { fatalError("Unexpected editor") }
            var edit = ForumInlineEdit.Requests()
            edit.read = { _, _ in #"{"markdown":"Original content","title":"Original title"}"# }
            edit.prepare = { _, markdown, authorized in
                guard authorized() else { throw CancellationError() }
                return markdown
            }
            edit.write = { _, _, _, _ in
                memory.editWrites += 1
                return #"{"kind":"saved"}"#
            }
            return ForumInlineEdit(requests: edit)
        }
        requests.saveEdit = { editor, page, authorized in
            guard memory.allowEditor else { fatalError("Unexpected edit") }
            return await editor.save(on: page, authorized: authorized)
        }
        requests.uploadImage = { _, _ in fatalError("No image uploads") }
        requests.uploadClipboardImage = { _, _ in fatalError("No clipboard uploads") }
        let keys = NativeForumServices.KeyStore(configured: { fatalError("No Keychain status query") }, read: { fatalError("No Keychain reads") },
            save: { _ in fatalError("No Keychain writes") }, remove: { fatalError("No Keychain removals") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys)
        let services = services
        context.accessChanged = { services.invalidate() }
        context.event = { domain, value in memory.events.append((domain, value as? [String: Any] ?? [:])) }
    }

    static func thread(_ title: String) -> ForumThread {
        .init(title: title, category: "tech", root: nil, replies: [], pages: [], page: 3, replyRestriction: nil)
    }
    func identify(_ owner: Int) {
        context.session.observeIdentity(.init(signedIn: true, id: owner, name: "Fixture", floorsPerPage: 10))
    }
    func load(_ id: String, title: String) async throws {
        memory.readerTitles[id] = title
        _ = try await services.handle("reader.load", ["url": Self.url(id).absoluteString,
            "force": true, "accessRevision": context.session.accessRevision])
    }
    func call(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let value = try await services.handle(method, args) as? [String: Any] else {
            fatalError("Expected a bridge dictionary for \(method)")
        }
        return value
    }
    static func url(_ id: String) -> URL { Forum.home.appendingPathComponent("post-\(id)-3") }
    static func post(_ id: String, _ title: String) -> FeedPost {
        .init(id: id, url: url(id), title: title, author: "Fixture", category: "tech", published: nil, summary: "")
    }
    func shutdown() {
        services.dispose()
        context.accessChanged = nil
        context.event = nil
        context.prepareForShutdown()
    }
}

@main
struct StartupTitleChecks {
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
    }
    private static func tabs(_ snapshot: [String: Any], key: String = "tabs") -> [String: String] {
        Dictionary(uniqueKeysWithValues: (snapshot[key] as? [[String: Any]] ?? []).map {
            ($0["id"] as! String, $0["title"] as! String)
        })
    }
    @MainActor
    private static func isolated(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "cc.seekdesk.qa.startup-titles." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    @MainActor
    static func main() async throws {
        try await isolated { try await coldStartupAndShutdown($0) }
        try await isolated { try await ownershipAndLegacy($0) }
        await isolated { await staleSources($0) }
        try await isolated { try await sourcePriorityAndFeed($0) }
        try await isolated { try await requestOrderAndCache($0) }
        await isolated { await publicReadAndClosedStorage($0) }
        await isolated { storeBoundaries($0) }
        print("Passed all 7 startup-title groups with memory-only transports and production identity/shutdown paths.")
    }

    @MainActor
    private static func coldStartupAndShutdown(_ defaults: UserDefaults) async throws {
        var navigation = ReadingSession()
        for id in ["701", "702", "703", "704"] {
            navigation.open(URL(string: TitleFixture.url(id).absoluteString + "#comment-27")!,
                            title: "Unowned legacy fixture", background: true)
            navigation.update(id) { $0.scroll = 317.5 }
        }
        navigation.select("701")
        defaults.set(try JSONEncoder().encode(navigation), forKey: "readingSession.v1")
        let first = TitleFixture(defaults: defaults)
        first.identify(101)
        first.memory.rows = [TitleFixture.post("701", "Listed selected"), TitleFixture.post("702", "Listed history"),
            TitleFixture.post("703", "Background list-only"), TitleFixture.post("704", "Closed source")]
        await first.context.workspace.refresh()
        for id in ["701", "702", "703", "704"] {
            check(first.context.workspace.openTopicInBackground(TitleFixture.url(id)), "Open real background navigation")
        }
        try await first.load("701", title: "Selected body title")
        try await first.load("702", title: "History body title")
        try await first.load("704", title: "Closed body title")
        first.context.workspace.close("704")
        first.context.workspace.select("701")
        _ = first.context.workspace.moveTab("703", to: "702")
        first.context.workspace.showList()
        // Real retention wiring must protect both the list-only open tab and
        // the closed tab while many unrelated listing titles enter the cache.
        first.memory.rows = (1000...1600).map { TitleFixture.post(String($0), "Unrelated listed \($0)") }
        await first.context.workspace.refresh()
        first.context.session.edit("Retained draft", for: "701")
        let expected = ["701": "Selected body title", "702": "History body title", "703": "Background list-only"]
        let urls = first.context.workspace.session.topics.map(\.url)
        let ids = first.context.workspace.session.topics.map(\.id)
        let scrolls = first.context.workspace.session.topics.map(\.scroll)
        let token = first.context.session.authorization
        let saved = defaults.data(forKey: ForumTitleStore.storageKey)
        check(saved != nil && tabs(first.context.workspaceSnapshot()) == expected, "All valid source kinds reach DTO")
        check(first.memory.readerReads == ["701", "702", "704"], "Background list-only tab never loads a reader")
        // Exercise the exact context shutdown method called by the real bridge.
        first.shutdown()
        first.shutdown()
        check(!first.context.session.authorizes(token), "Shutdown revokes the prior write token")
        check(defaults.data(forKey: ForumTitleStore.storageKey) == saved, "Shutdown does not persist a redacted title view")
        let raw = try JSONDecoder().decode(ReadingSession.self, from: defaults.data(forKey: "readingSession.v1")!)
        check(raw.topics.allSatisfy { $0.title.isEmpty && $0.preview == nil } &&
            raw.closedTopics.allSatisfy { $0.topic.title.isEmpty && $0.topic.preview == nil },
            "Workspace open/closed metadata redaction remains intact")

        for _ in 0..<2 {
            let next = TitleFixture(defaults: defaults)
            defer { next.shutdown() }
            check(next.context.workspace.session.topics.map(\.url) == urls &&
                next.context.workspace.session.topics.map(\.id) == ids &&
                next.context.workspace.session.topics.map(\.scroll) == scrolls &&
                scrolls.allSatisfy { $0 == 317.5 } && urls.allSatisfy { $0.fragment == "comment-27" } &&
                next.context.workspace.session.selection == "701" && !next.context.workspace.showReader,
                "Production startup preserves order, URL page/fragment, scroll, selection and overview")
            check(tabs(next.context.workspaceSnapshot()).allSatisfy { $0.value == "帖子 #\($0.key)" }, "Unconfirmed snapshot does not reveal prior titles")
            next.context.workspace.showList() // A pre-confirmation persist must not erase the separate owner cache.
            check(defaults.data(forKey: ForumTitleStore.storageKey) == saved, "Empty pre-confirmation navigation cannot overwrite owner labels")
            next.memory.events.removeAll()
            next.identify(101)
            check(tabs(next.context.workspaceSnapshot()) == expected, "Same confirmed owner restores all historical labels")
            check(tabs(next.context.workspaceSnapshot(), key: "closedTabs")["704"] == "Closed body title", "Closed history restores its title")
            check(next.context.workspace.session.closedTopics.first?.topic.scroll == 317.5 &&
                next.context.workspace.session.closedTopics.first?.topic.url.fragment == "comment-27",
                "Closed-tab title recovery preserves the saved reading location")
            check(next.context.session.drafts["701"] == "Retained draft", "Production shutdown retains account draft persistence")
            check(next.memory.events.contains { $0.0 == "workspace" && tabs($0.1) == expected }, "Owner confirmation emits restored workspace without a reader")
            check(next.memory.readerReads.isEmpty && next.memory.pageReads == 0 && next.memory.feedReads == 0,
                "Historical title restoration performs no eager reads")
            let beforeReads = defaults.data(forKey: ForumTitleStore.storageKey)
            for _ in 0..<5 { _ = next.context.workspaceSnapshot() }
            check(defaults.data(forKey: ForumTitleStore.storageKey) == beforeReads, "DTO getters never write cache")
            check(next.context.workspace.reopenClosedTab("704") &&
                tabs(next.context.workspaceSnapshot())["704"] == "Closed body title", "Reopen retains cached title")
            next.context.workspace.close("704")
            next.context.workspace.select("701")
            next.context.workspace.showList()
        }
        print("PASS list/body sources, open/closed titles, two same-owner cold starts, shutdown, draft flush and explicit overview events")
    }

    @MainActor
    private static func ownershipAndLegacy(_ defaults: UserDefaults) async throws {
        var old = ReadingSession()
        old.open(TitleFixture.url("801"), title: "Unowned legacy private title", background: false)
        defaults.set(try JSONEncoder().encode(old), forKey: "readingSession.v1")
        let f = TitleFixture(defaults: defaults); defer { f.shutdown() }
        check(tabs(f.context.workspaceSnapshot())["801"] == "帖子 #801", "Legacy metadata remains redacted")
        f.context.session.observeAccount(true)
        check(f.context.session.memberID == nil && f.context.session.titles.isEmpty, "Signed-in boolean alone cannot restore a title owner")
        f.identify(101)
        check(f.context.session.titles.isEmpty && defaults.data(forKey: ForumTitleStore.storageKey) == nil, "Legacy title is never guessed to belong to the new owner")
        try await f.load("801", title: "A private title")
        f.context.session.observeAccount(false)
        check(f.context.session.titles.isEmpty && tabs(f.context.workspaceSnapshot())["801"] == "帖子 #801", "Signing out removes visible private labels")
        f.identify(202)
        check(f.context.session.titles.isEmpty, "B cannot hydrate A's cache")
        try await f.load("801", title: "B title")
        f.identify(101)
        check(tabs(f.context.workspaceSnapshot())["801"] == "A private title", "Returning to A restores only its partition")
        f.identify(202)
        check(tabs(f.context.workspaceSnapshot())["801"] == "B title", "Same topic ID has independent account labels")
        check(f.memory.readerReads.count == 2, "Owner switches never fetch a hidden reader for title recovery")
        print("PASS unconfirmed/signed-in-without-owner/legacy redaction and independent A/B title partitions")
    }

    @MainActor
    private static func staleSources(_ defaults: UserDefaults) async {
        let f = TitleFixture(defaults: defaults); defer { f.shutdown() }
        f.identify(101)
        let token = f.context.session.authorization
        let listingGate = TitleGate()
        f.memory.listingGate = listingGate
        f.memory.rows = [TitleFixture.post("901", "Late A listing")]
        let listing = Task { @MainActor in await f.context.workspace.refresh() }
        await listingGate.untilEntered()
        f.identify(202)
        listingGate.release()
        await listing.value
        check(f.context.session.titles["901"] == nil, "Old-owner listing completion cannot enter B cache")
        check(ForumTitleStore(defaults: defaults).titles(for: 101)["901"] == nil, "Rejected late response is not silently written to A either")
        f.memory.listingGate = nil
        f.context.session.rememberTitle("Stale direct body", for: "901", authorization: token)
        check(f.context.session.titles["901"] == nil, "Explicit old authorization is rejected")

        f.identify(101)
        let oldSameOwner = f.context.session.authorization
        let gate = TitleGate()
        let topic = Topic(id: "902", url: TitleFixture.url("902"), title: "")
        let reader = ForumReaderState(topic: topic, session: f.context.session)
        let pending = Task { @MainActor in
            await reader.load(topic, session: f.context.session, force: true, fetch: { _, session in
                await gate.wait()
                return (TitleFixture.thread("Late previous-revision body"), ForumWebPage(dataStore: session.dataStore))
            })
        }
        await gate.untilEntered()
        f.context.session.observeAccount(false)
        f.identify(101)
        gate.release()
        let loaded = await pending.value
        check(!loaded, "Production reader rejects a previous revision even for the same owner")
        f.context.session.rememberTitle("Same-owner stale token", for: "902", authorization: oldSameOwner)
        check(f.context.session.titles["902"] == nil && ForumTitleStore(defaults: defaults).titles(for: 101)["902"] == nil,
            "Old revision never repopulates durable or visible labels")
        reader.cancel()
        print("PASS late listing, old owner, same-owner old revision and real reader cancellation reject stale cache writes")
    }

    @MainActor
    private static func sourcePriorityAndFeed(_ defaults: UserDefaults) async throws {
        let f = TitleFixture(defaults: defaults); defer { f.shutdown() }
        f.identify(101)
        f.memory.rows = [TitleFixture.post("911", "Listed title")]
        await f.context.workspace.refresh()
        check(f.context.session.titles["911"] == "Listed title", "Production listing fetch captures a valid label")
        try await f.load("911", title: "Verified body")
        let saved = defaults.data(forKey: ForumTitleStore.storageKey)
        let eventCount = f.memory.events.filter { $0.0 == "workspace" }.count
        for value in ["", "  \n", "帖子 #911", "未命名帖子", "Bad\u{0000}title"] {
            f.context.session.rememberTitle(value, for: "911", authorization: f.context.session.authorization)
        }
        f.memory.rows = [TitleFixture.post("911", "帖子 #911"),
            FeedPost(id: "912", url: TitleFixture.url("913"), title: "Mismatched identity", author: "", category: "tech", published: nil, summary: "")]
        await f.context.workspace.refresh()
        check(f.context.session.titles["911"] == "Verified body" && f.context.session.titles["912"] == nil,
            "Invalid titles and listing ID/URL association are enforced")
        check(defaults.data(forKey: ForumTitleStore.storageKey) == saved &&
            f.memory.events.filter { $0.0 == "workspace" }.count == eventCount,
            "Rejected/unchanged title updates neither rewrite cache nor publish feedback events")
        try await f.load("911", title: "Updated verified title")
        check(ForumTitleStore(defaults: defaults).titles(for: 101)["911"] == "Updated verified title",
            "A later successful production reader replaces and persists the previous body title")
        f.memory.rows = (2000...2600).map { TitleFixture.post(String($0), "New listing \($0)") }
        await f.context.workspace.refresh()
        check(f.context.session.titles["911"] == nil, "Unretained title can be evicted at the fixed bound")
        let topic = Topic(id: "911", url: TitleFixture.url("911"), title: "")
        let cached = ForumReaderState(topic: topic, session: f.context.session)
        let restored = await cached.load(topic, session: f.context.session, fetch: { _, _ in
            fatalError("Fresh cached reader must not fetch to restore its known title")
        })
        check(restored && f.context.session.titles["911"] == "Updated verified title",
            "A current-account cached body can refill an evicted label without networking")
        cached.cancel()
        f.memory.listingFailure = true
        f.memory.feedRows = [TitleFixture.post("914", "Public RSS title")]
        // Home's first failed listing uses the existing public-feed fallback;
        // use a fresh context so an already ready listing does not suppress it.
        let feed = TitleFixture(defaults: defaults); defer { feed.shutdown() }
        feed.identify(101)
        try await feed.load("915", title: "Authoritative body")
        feed.memory.rows = [TitleFixture.post("916", "Authoritative listing")]
        await feed.context.workspace.refresh()
        // A separate context restores these labels with request order 0, then
        // takes the production RSS fallback. Source protection survives restart.
        feed.shutdown()
        let fallback = TitleFixture(defaults: defaults); defer { fallback.shutdown() }
        fallback.identify(101)
        fallback.memory.listingFailure = true
        fallback.memory.feedRows = f.memory.feedRows + [TitleFixture.post("915", "RSS stale body"),
            TitleFixture.post("916", "RSS stale listing")]
        await fallback.context.workspace.refresh()
        check(fallback.memory.feedReads == 1 && fallback.context.session.titles["914"] == "Public RSS title" &&
            fallback.context.session.titles["915"] == "Authoritative body" &&
            fallback.context.session.titles["916"] == "Authoritative listing",
            "Production RSS fills a missing label without replacing a restored forum title")
        fallback.memory.listingFailure = false
        fallback.memory.rows = [TitleFixture.post("914", "Forum replaces RSS")]
        await fallback.context.workspace.refresh()
        check(fallback.context.session.titles["914"] == "Forum replaces RSS", "A real forum list promotes a feed label")
        let olderForum = fallback.context.session.beginTitleRead()
        let newerFeed = fallback.context.session.beginTitleRead()
        fallback.context.session.rememberListingTitles([TitleFixture.post("917", "Feed placeholder")], request: newerFeed, feed: true)
        fallback.context.session.rememberListingTitles([TitleFixture.post("917", "Confirmed forum title")], request: olderForum)
        check(fallback.context.session.titles["917"] == "Confirmed forum title", "RSS request order cannot suppress an authoritative response")
        print("PASS empty/placeholder rejection, malformed URL identity, no write loop, cache refill and RSS fallback/promotion")
    }

    @MainActor
    private static func requestOrderAndCache(_ defaults: UserDefaults) async throws {
        let f = TitleFixture(defaults: defaults); defer { f.shutdown() }
        f.identify(101)
        try await f.load("941", title: "Current body title")
        let listingGate = TitleGate()
        f.memory.listingGate = listingGate
        f.memory.rows = [TitleFixture.post("941", "Late old listing"), TitleFixture.post("942", "Independent row")]
        let pending = Task { @MainActor in await f.context.workspace.refresh() }
        await listingGate.untilEntered()
        // The newer body response has an unchanged title: it must still advance
        // the per-topic order without needing a different persisted payload.
        try await f.load("941", title: "Current body title")
        listingGate.release()
        await pending.value
        f.memory.listingGate = nil
        check(f.context.session.titles["941"] == "Current body title" &&
            f.context.session.titles["942"] == "Independent row",
            "L1 starts, B2 completes, L1 returns: newer body wins while unrelated listing rows survive")

        f.memory.rows = [TitleFixture.post("941", "Renamed by later forum list")]
        await f.context.workspace.refresh()
        check(f.context.session.titles["941"] == "Renamed by later forum list" &&
            ForumTitleStore(defaults: defaults).titles(for: 101)["941"] == "Renamed by later forum list",
            "A later forum listing can update and persist a previously read title")
        let topic = Topic(id: "941", url: TitleFixture.url("941"), title: "")
        let cached = ForumReaderState(topic: topic, session: f.context.session)
        let loaded = await cached.load(topic, session: f.context.session, fetch: { _, _ in
            fatalError("Fresh cached body must not fetch")
        })
        check(loaded && f.context.session.titles["941"] == "Renamed by later forum list",
            "An old body cache hit does not resurrect a title superseded by a new forum list")
        cached.cancel()

        // Reverse arrival ordering, through a real reader transport as well.
        let bodyGate = TitleGate()
        let reader = ForumReaderState(topic: topic, session: f.context.session)
        let oldBody = Task { @MainActor in
            await reader.load(topic, session: f.context.session, force: true, fetch: { _, session in
                await bodyGate.wait()
                return (TitleFixture.thread("Late old body"), ForumWebPage(dataStore: session.dataStore))
            })
        }
        await bodyGate.untilEntered()
        f.memory.rows = [TitleFixture.post("941", "New list while body pending")]
        await f.context.workspace.refresh()
        bodyGate.release()
        _ = await oldBody.value
        check(f.context.session.titles["941"] == "New list while body pending", "An earlier body request cannot overwrite a later accepted forum list")
        reader.cancel()

        let editGate = TitleGate()
        f.memory.listingGate = editGate
        f.memory.rows = [TitleFixture.post("941", "Before acknowledged edit")]
        let beforeEdit = Task { @MainActor in await f.context.workspace.refresh() }
        await editGate.untilEntered()
        f.memory.allowEditor = true
        var args: [String: Any] = ["url": topic.url.absoluteString, "topicID": topic.id,
            "floor": 0, "accessRevision": f.context.session.accessRevision]
        let editor = try await f.call("reader.edit.begin", args)
        args["editToken"] = editor["editToken"]
        args["title"] = "Acknowledged edited title"
        _ = try await f.call("reader.edit.update", args)
        let receipt = try await f.call("reader.edit.save", args)
        check(receipt["accepted"] as? Bool == true && f.memory.editWrites == 1 &&
            f.context.session.titles["941"] == "Acknowledged edited title", "Production edit success immediately records its confirmed title")
        editGate.release()
        await beforeEdit.value
        check(f.context.session.titles["941"] == "Acknowledged edited title", "A read started before edit acknowledgement cannot overwrite it")
        f.memory.listingGate = nil
        // An invalid newer result must not become an accepted ordering fence.
        let earlier = f.context.session.beginTitleRead(), later = f.context.session.beginTitleRead()
        f.context.session.rememberTitle("帖子 #943", for: "943", request: later)
        f.context.session.rememberTitle("Valid earlier result", for: "943", request: earlier)
        check(f.context.session.titles["943"] == "Valid earlier result", "Rejected titles do not advance accepted request order")
        f.shutdown()
        let restored = TitleFixture(defaults: defaults); defer { restored.shutdown() }
        restored.identify(101)
        check(restored.context.session.titles["941"] == "Acknowledged edited title", "Latest accepted name survives restart")
        restored.memory.rows = [TitleFixture.post("941", "New process rename")]
        await restored.context.workspace.refresh()
        check(restored.context.session.titles["941"] == "New process rename", "Restored labels have order zero and accept the new process's first read")
        print("PASS real request-start ordering, later listing rename, cache non-overwrite, confirmed inline edit and restart order zero")
    }

    @MainActor
    private static func publicReadAndClosedStorage(_ defaults: UserDefaults) async {
        let f = TitleFixture(defaults: defaults)
        f.context.session.observeAccount(false)
        let token = f.context.session.authorization
        f.context.session.rememberTitle("Public current read", for: "921", authorization: token)
        check(f.context.session.titles["921"] == "Public current read" && defaults.data(forKey: ForumTitleStore.storageKey) == nil,
            "Current guest titles may display but are never persisted under a guessed owner")
        f.shutdown()
        f.context.session.rememberTitle("After shutdown", for: "922", authorization: token)
        f.identify(101)
        check(f.context.session.memberID == nil && f.context.session.titles.isEmpty &&
            f.context.session.authorization != token &&
            defaults.data(forKey: ForumTitleStore.storageKey) == nil, "Closed session cannot reactivate title storage")
        print("PASS public in-memory labels and post-shutdown stale identity/title rejection")
    }

    @MainActor
    private static func storeBoundaries(_ defaults: UserDefaults) {
        let store = ForumTitleStore(defaults: defaults)
        store.record([.init(id: "1", title: "Pinned opened tab", source: .reader)], owner: 101)
        let rows = (2...700).map { ForumTitleStore.Entry(id: String($0), title: "Listed \($0)", source: .listing) }
        store.record(rows, owner: 101, preserving: ["1"])
        check(store.titles(for: 101).count == ForumTitleStore.maximumTitles && store.titles(for: 101)["1"] == "Pinned opened tab",
            "Capacity bounds hold while retained navigation titles are preferred")
        let boundary = String(repeating: "x", count: ForumTitleStore.maximumTitleBytes)
        store.record([.init(id: "800", title: boundary, source: .reader)], owner: 101)
        check(store.titles(for: 101)["800"] == boundary, "Maximum valid title bytes are accepted")
        let before = defaults.data(forKey: ForumTitleStore.storageKey)
        for id in ["", "0", "-1", "01", "x", "99999999999999999999"] {
            store.record([.init(id: id, title: "Invalid ID", source: .reader)], owner: 101)
        }
        store.record([.init(id: "800", title: boundary + "x", source: .reader)], owner: 101)
        store.record([.init(id: "801", title: "Invalid owner", source: .reader)], owner: 0)
        check(defaults.data(forKey: ForumTitleStore.storageKey) == before, "Invalid IDs/owner/length cannot replace a valid cache")
        check(ForumTitleStore(defaults: defaults).titles(for: 101) == store.titles(for: 101), "Bounded source metadata survives codec roundtrip")
        for owner in 102...105 { store.record([.init(id: "1", title: "Owner \(owner)", source: .reader)], owner: owner) }
        check(store.titles(for: 101).isEmpty && store.titles(for: 102)["1"] == "Owner 102" &&
            store.titles(for: 105)["1"] == "Owner 105", "Only the four most recently changed account partitions are retained")
        // Exercise the actual Foundation encoder at every supported bound,
        // including ASCII escape worst cases and multibyte Unicode. Long IDs
        // also include the maximum metadata envelope for each of 2048 entries.
        let unicodeUnit = "漢🙂é\u{2028}\u{2029}\"\\/"
        let unicodePrefix = String(repeating: unicodeUnit, count: ForumTitleStore.maximumTitleBytes / unicodeUnit.utf8.count)
        let maximumUnicode = unicodePrefix + String(repeating: "\\", count: ForumTitleStore.maximumTitleBytes - unicodePrefix.utf8.count)
        let escapedTitles = [String(repeating: "\"", count: ForumTitleStore.maximumTitleBytes),
            String(repeating: "\\", count: ForumTitleStore.maximumTitleBytes),
            String(repeating: "/", count: ForumTitleStore.maximumTitleBytes), maximumUnicode]
        check(escapedTitles.allSatisfy { $0.utf8.count == ForumTitleStore.maximumTitleBytes }, "Every escaping fixture fills the raw UTF-8 byte limit")
        var expected: [Int: [String: String]] = [:]
        for owner in 201..<(201 + ForumTitleStore.maximumOwners) {
            let full = (0..<ForumTitleStore.maximumTitles).map { index in
                ForumTitleStore.Entry(id: String(Int.max - index), title: escapedTitles[index % escapedTitles.count], source: .reader)
            }
            expected[owner] = Dictionary(uniqueKeysWithValues: full.map { ($0.id, $0.title) })
            store.record(full, owner: owner)
        }
        guard let encoded = defaults.data(forKey: ForumTitleStore.storageKey) else { fatalError("Full-capacity cache was not persisted") }
        check(encoded.count > 4 * 1024 * 1024 && encoded.count <= ForumTitleStore.maximumStoredBytes,
            "Escaped full-capacity JSON fits the 12 MiB bound and includes real escaping overhead")
        let roundTrip = ForumTitleStore(defaults: defaults)
        for (owner, titles) in expected {
            check(titles.count == ForumTitleStore.maximumTitles && roundTrip.titles(for: owner) == titles,
                "All four full partitions survive actual JSON encoding, persistence and reconstruction")
        }
        check(roundTrip.titles(for: 105).isEmpty, "Full-capacity reconstruction retains only the current four partitions")
        for broken in [Data("broken".utf8), Data(#"{"version":2,"partitions":[]}"#.utf8),
                       Data(repeating: 0x20, count: ForumTitleStore.maximumStoredBytes + 1)] {
            defaults.set(broken, forKey: ForumTitleStore.storageKey)
            let corrupt = ForumTitleStore(defaults: defaults)
            check(expected.keys.allSatisfy { corrupt.titles(for: $0).isEmpty }, "Corrupt/unsupported/oversize cache safely degrades")
            check(defaults.data(forKey: ForumTitleStore.storageKey) == broken, "Reads of bad storage do not mutate other persisted state")
        }
        print("PASS 4-owner/512-title/2048-byte bounds, pinned navigation, strict IDs, full escaped Unicode codec (\(encoded.count) bytes) and corrupt storage")
    }
}
