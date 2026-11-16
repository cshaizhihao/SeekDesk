import Foundation
import FlutterMacOS
import WebKit

@MainActor
private final class SidebarGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct SidebarServiceChecks {
    @MainActor
    static func main() async throws {
        checkWindowChromeProtocol()
        let suite = "cc.seekdesk.qa.sidebar-bridge." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["hot", "block", "keywords"], forKey: "extensions.installed")
        defaults.set(["hot", "block"], forKey: "extensions.enabled")
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        let gate = SidebarGate()
        var pageReads: [URL] = []
        var peopleReads: [String] = []
        var feedReads = 0
        var failPage = false
        var delayPage = false
        let post = FeedPost(id: "700", url: Forum.home.appendingPathComponent("post-700-1"),
            title: "Local fixture", author: "Fixture", category: "tech", published: nil,
            summary: "Local content", authorID: 101)
        let context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: { feedReads += 1; return [] }, fetchPage: { url in
                pageReads.append(url)
                if delayPage { await gate.wait() }
                if failPage { throw ForumPageError.network }
                return .init(posts: [post], next: nil)
            }, fetchPeople: { query in
                peopleReads.append(query)
                return [.init(id: 77, name: "Local Person", avatar: nil, tags: [])]
            })
        let workspace = context.workspace
        let session = context.session
        session.observeIdentity(.init(signedIn: true, id: 101, name: "First", floorsPerPage: 20))
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
        func checkBoardURL(_ snapshot: [String: Any], _ expected: String) throws {
            require(snapshot["boardURL"] as? String == expected, "Snapshot must expose the native board's canonical browser URL")
            let validated = try NativeDTO.url(snapshot, key: "boardURL", forumOnly: true)
            require(validated.absoluteString == expected, "Board browser URL must pass existing official-site validation")
        }

        let initial = context.workspaceSnapshot()
        try checkBoardURL(initial, "https://www.nodeseek.com/")
        require(initial["boardCategoryID"] is NSNull && initial["appliedSearchScope"] as? [String] == [] &&
                initial["appliedSearchKind"] as? String == "all", "Initial search metadata must represent an unscoped, empty search")
        let boards = rows(initial["boards"])
        let originals = [Board.home] + Board.sections
        require(boards.count == originals.count, "Board catalog count must remain unchanged")
        for (row, board) in zip(boards, originals) {
            require(row["id"] as? String == board.id && row["title"] as? String == board.title &&
                    row["icon"] as? String == board.icon, "Board catalog must preserve native order, names and icons")
            require(row["searchable"] as? Bool == Board.searchableIDs.contains(board.id),
                    "Search scope choices must come from the native searchable board catalog")
        }
        require(!boards.contains { $0["id"] as? String == "award" }, "Award stays in shortcuts, not regular boards")
        require(JSONSerialization.isValidJSONObject(initial), "Workspace payload must be codec safe")
        print("PASS workspace board catalog preserves native icons and ordering")

        require(workspace.openTopicLink(post.url), "Open a local navigation URL without fetching")
        let selection = workspace.session.selection
        let backgroundURL = Forum.home.appendingPathComponent("post-701-1")
        let originalReader = workspace.showReader
        require(workspace.openTopicInBackground(backgroundURL), "Background URL accepted")
        require(workspace.session.selection == selection && workspace.showReader == originalReader,
                "Background open preserves foreground reader")
        require(workspace.session.topics.contains { $0.id == "701" } && pageReads.isEmpty,
                "Background adds tab without page reads")
        require(workspace.openTopicInBackground(URL(string: post.url.absoluteString + "#comment-99")!), "Existing background tab accepted")
        require(workspace.session.selectedTopic?.url == post.url && workspace.session.topics.count == 2,
                "Existing background tab preserves URL and avoids duplication")
        workspace.showList()
        require(workspace.openTopicInBackground(Forum.home.appendingPathComponent("post-702-1")), "Overview background accepted")
        require(!workspace.showReader && workspace.session.selection == selection && pageReads.isEmpty,
                "Background opening from overview must not reveal reader or fetch")
        require(!workspace.openTopicInBackground(URL(string: "https://example.com/post-703-1")!),
                "Non-forum background URL rejected")
        workspace.close("701")
        workspace.close("702")
        require(workspace.openTopicLink(post.url), "Restore local reader fixture")
        print("PASS background tabs preserve reading location and overview without fetching")
        workspace.chooseFeedOrder(.replies)
        let award = try await context.selectBoard("award")
        try checkBoardURL(award, "https://www.nodeseek.com/award")
        require(award["boardCategoryID"] is NSNull, "Award must not become a search category")
        require(pageReads == [ForumShortcut.award.url], "Award must request /award without category path or sortBy")
        require(award["board"] as? String == "award" && award["showReader"] as? Bool == false, "Award uses the main listing")
        require(rows(award["posts"]).first?["id"] as? String == "700", "Award must return the injected listing")
        require(workspace.session.selection == selection && workspace.session.selectedTopic?.url == post.url,
                "Choosing a listing must preserve the selected reading tab")
        require(award["feedOrder"] as? String == ForumFeedOrder.replies.rawValue, "Award must not overwrite the saved list order")

        do { _ = try await context.selectBoard("not-a-board"); fatalError("Unknown board accepted") }
        catch let error as NativeBridgeError { require(error.code == "invalid_board", "Unknown board error code") }
        require(pageReads.count == 1 && workspace.board == .award, "Invalid board must not request or mutate navigation")
        let tech = Board.sections.first { $0.id == "tech" }!
        let technology = try await context.selectBoard(tech.id)
        try checkBoardURL(technology, "https://www.nodeseek.com/categories/tech")
        require(technology["boardCategoryID"] as? String == "tech", "Ordinary boards expose their search category")
        require(pageReads.last == tech.latestURL(order: .replies), "Ordinary board retains current sorting")
        let home = try await context.selectBoard(Board.home.id)
        try checkBoardURL(home, "https://www.nodeseek.com/")
        require(pageReads.last == Board.home.latestURL(order: .replies), "Home keeps its original request route")
        require(feedReads == 0, "Successful native pages must not trigger RSS fallback")
        print("PASS board selections preserve reading tabs and expose canonical browser URLs without listing sort parameters")

        workspace.invalidateForumAccess()
        failPage = true
        let failed = try await context.selectBoard("award")
        try checkBoardURL(failed, "https://www.nodeseek.com/award")
        require(rows(failed["posts"]).isEmpty && failed["error"] is String, "Failed award must not expose another board's feed")
        require(feedReads == 0, "Failed award must never fall back to the home RSS feed")
        failPage = false
        delayPage = true
        let oldRevision = session.accessRevision
        let pending = Task { @MainActor in try await context.selectBoard("award") }
        while !gate.entered { await Task.yield() }
        session.observeIdentity(.init(signedIn: true, id: 202, name: "Second", floorsPerPage: 20))
        gate.release()
        let switched = try await pending.value
        require(rows(switched["posts"]).isEmpty && workspace.posts.isEmpty, "Late award response must not cross account revision")
        require(workspace.session.selection == selection, "Account invalidation keeps navigation identity")
        do { _ = try context.requireAuthorization(["accessRevision": oldRevision]); fatalError("Stale authorization accepted") }
        catch let error as NativeBridgeError { require(error.code == "stale_authorization", "Existing authorization rejection retained") }
        require(feedReads == 0 && !session.dataStore.isPersistent, "Regression remains local and isolated")
        print("PASS award failure and account-switch race retain access isolation without network fallback")

        delayPage = false
        workspace.choose(tech)
        let beforeSearchPages = pageReads.count
        workspace.beginSearch()
        require(workspace.showingSearch && workspace.searchText.isEmpty && workspace.searchScope == ["tech"] &&
                workspace.searchKind == .all, "An empty search opens with the current board and all result types")
        require(pageReads.count == beforeSearchPages && peopleReads.isEmpty,
                "Opening the search panel must not make a request")
        workspace.searchText = "  Fixture query  "
        workspace.searchScope = ["tech", "daily", "award", "", "not-a-board"]
        workspace.searchKind = .posts
        workspace.search()
        let searched = context.workspaceSnapshot()
        require(searched["query"] as? String == "Fixture query" &&
                searched["appliedSearchScope"] as? [String] == ["daily", "tech"] &&
                searched["appliedSearchKind"] as? String == "posts", "Submitted search trims text and removes nonsearchable scope IDs")
        require(searched["board"] as? String == "" && searched["boardCategoryID"] is NSNull &&
                searched["showReader"] as? Bool == false && !workspace.showingSearch,
                "A multi-board search returns to the overview without creating a category")
        require(workspace.session.selection == selection && pageReads.count == beforeSearchPages && peopleReads.isEmpty,
                "Submitting a search preserves reading tabs and leaves reads to the caller")
        let savedSearch = workspace.searchHistory[0]
        let history = rows(searched["searchHistory"])
        require(history.first?["query"] as? String == "Fixture query" &&
                Set(history.first?["scope"] as? [String] ?? []) == ["daily", "tech"] &&
                history.first?["kind"] as? String == "posts", "History carries query, scope and kind together")
        require(JSONSerialization.isValidJSONObject(searched), "Search metadata and searchable booleans must be codec safe")
        workspace.searchText = "Unsubmitted draft"
        workspace.searchScope = ["inside"]
        workspace.searchKind = .people
        let draftSnapshot = context.workspaceSnapshot()
        require(draftSnapshot["query"] as? String == "Fixture query" &&
                draftSnapshot["appliedSearchScope"] as? [String] == ["daily", "tech"] &&
                draftSnapshot["appliedSearchKind"] as? String == "posts", "Draft edits must not overwrite submitted snapshot metadata")
        workspace.beginSearch()
        require(workspace.searchText == "Fixture query" && workspace.searchScope == ["daily", "tech"] &&
                workspace.searchKind == .posts, "A nonempty query restores applied metadata instead of the current board default")
        workspace.showingSearch = false
        await workspace.refresh()
        require(pageReads.count == beforeSearchPages + 1 && pageReads.last == Forum.search("Fixture query") && peopleReads.isEmpty,
                "Explicit post-search refresh reads exactly one injected search page and no people")
        require(rows(context.workspaceSnapshot()["posts"]).first?["id"] as? String == "700",
                "The native search result reaches the bridge snapshot")
        print("PASS search snapshots preserve applied metadata, current-board defaults and draft isolation")

        workspace.searchText = "Person"
        workspace.searchScope = ["tech", "daily"]
        workspace.searchKind = .people
        workspace.search()
        let peopleSearch = context.workspaceSnapshot()
        require(peopleSearch["appliedSearchScope"] as? [String] == [] &&
                peopleSearch["appliedSearchKind"] as? String == "people" && workspace.searchScope.isEmpty,
                "People search clears any submitted category scope")
        require(peopleSearch["boardCategoryID"] is NSNull && rows(peopleSearch["posts"]).isEmpty,
                "People search cannot inherit a category or show unrelated posts")
        let beforePeoplePages = pageReads.count
        await workspace.refresh()
        let loadedPeople = context.workspaceSnapshot()
        require(peopleReads == ["Person"] && pageReads.count == beforePeoplePages,
                "People-only refresh uses the injected directory without reading posts")
        require(rows(loadedPeople["people"]).first?["id"] as? Int == 77 && JSONSerialization.isValidJSONObject(loadedPeople),
                "People search exposes the local directory result through a codec-safe snapshot")
        let historyIDs = workspace.searchHistory.map(\.id)
        let persisted = Workspace(defaults: defaults, fetchFeed: { [] }, fetchPage: { _ in .init(posts: [], next: nil) },
                                  fetchPeople: { _ in [] })
        require(persisted.searchHistory.map(\.id) == historyIDs &&
                persisted.searchHistory.last?.scope == savedSearch.scope && persisted.searchHistory.last?.kind == .posts,
                "Persisted history restores query, scope and kind from isolated defaults")
        workspace.clearSearch()
        let cleared = context.workspaceSnapshot()
        require(cleared["query"] as? String == "" && cleared["appliedSearchScope"] as? [String] == [] &&
                cleared["appliedSearchKind"] as? String == "all" && rows(cleared["people"]).isEmpty,
                "Clearing a search resets applied metadata and people results")
        require(workspace.searchHistory.map(\.id) == historyIDs && pageReads.count == beforePeoplePages && peopleReads == ["Person"],
                "Clearing a search keeps history and does not request the forum")
        workspace.repeatSearch(savedSearch)
        let repeated = context.workspaceSnapshot()
        require(repeated["query"] as? String == "Fixture query" &&
                repeated["appliedSearchScope"] as? [String] == ["daily", "tech"] &&
                repeated["appliedSearchKind"] as? String == "posts" && workspace.searchHistory.first?.id == savedSearch.id,
                "Repeating history restores all submitted search fields")
        require(workspace.searchHistory.count == historyIDs.count && Set(workspace.searchHistory.map(\.id)) == Set(historyIDs),
                "Repeating history moves the existing item without duplicating it")
        print("PASS people search, history persistence/replay and clearing remain isolated and preserve scope semantics")

        let historyBeforeLink = workspace.searchHistory.map(\.id)
        let link = URL(string: "https://www.nodeseek.com/post-701-2#31")!
        workspace.beginSearch()
        workspace.searchText = "  \(link.absoluteString)  "
        workspace.search()
        let linked = context.workspaceSnapshot()
        require(linked["showReader"] as? Bool == true && linked["selectedTab"] as? String == "701" &&
                workspace.session.selectedTopic?.url == link && !workspace.showingSearch,
                "A pasted topic URL opens the reader at its explicit page and fragment")
        require(linked["query"] as? String == "Fixture query" &&
                linked["appliedSearchScope"] as? [String] == ["daily", "tech"] &&
                linked["appliedSearchKind"] as? String == "posts", "Topic URL navigation preserves the underlying submitted search")
        require(workspace.searchHistory.map(\.id) == historyBeforeLink &&
                pageReads.count == beforePeoplePages && peopleReads == ["Person"],
                "Topic URL navigation neither records a search nor refreshes the retained search or board")
        workspace.clearSearchHistory()
        require(rows(context.workspaceSnapshot()["searchHistory"]).isEmpty && defaults.data(forKey: "search.history") == nil,
                "Clearing history removes both the snapshot entries and the isolated persisted key")
        workspace.clearSearch()
        print("PASS pasted topic URLs preserve explicit location and skip unrelated search/listing requests")

        let beforeDispatchPages = pageReads.count
        let beforeDispatchPeople = peopleReads.count
        let dispatched = await context.search(query: "Dispatch", scope: ["tech"], kind: .posts)
        require(pageReads.count == beforeDispatchPages + 1 && pageReads.last == Forum.search("Dispatch") &&
                peopleReads.count == beforeDispatchPeople && rows(dispatched["posts"]).count == 1,
                "The native listing.search dispatch must await the real injected post search once")
        require(dispatched["boardCategoryID"] as? String == "tech" && !workspace.hasForumPage,
                "Searching a single category does not fabricate a cached category listing")
        let restoredBoard = await context.clearSearch()
        require(pageReads.count == beforeDispatchPages + 2 && pageReads.last == tech.latestURL(order: .replies) &&
                restoredBoard["query"] as? String == "" && rows(restoredBoard["posts"]).count == 1,
                "Clearing search loads an uncached destination board exactly once")
        _ = await context.clearSearch()
        require(pageReads.count == beforeDispatchPages + 2 && peopleReads.count == beforeDispatchPeople,
                "Clearing search with a cached listing must not request it again")
        _ = await context.search(query: "Directory dispatch", scope: ["tech"], kind: .people)
        require(pageReads.count == beforeDispatchPages + 2 && peopleReads.count == beforeDispatchPeople + 1 &&
                peopleReads.last == "Directory dispatch", "People-only dispatch reads only the injected directory")
        let combined = await context.search(query: "Combined dispatch", scope: [], kind: .all)
        require(pageReads.count == beforeDispatchPages + 3 && pageReads.last == Forum.search("Combined dispatch") &&
                peopleReads.count == beforeDispatchPeople + 2 && peopleReads.last == "Combined dispatch" &&
                rows(combined["posts"]).count == 1 && rows(combined["people"]).count == 1,
                "Combined dispatch awaits one post read and one directory read")
        let dispatchedLink = await context.search(query: link.absoluteString, scope: ["inside"], kind: .people)
        require(dispatchedLink["showReader"] as? Bool == true && workspace.session.selectedTopic?.url == link &&
                dispatchedLink["query"] as? String == "Combined dispatch" &&
                dispatchedLink["appliedSearchKind"] as? String == "all" &&
                pageReads.count == beforeDispatchPages + 3 && peopleReads.count == beforeDispatchPeople + 2,
                "Bridge topic-link dispatch preserves the reader location without refreshing the retained search")
        _ = await context.clearSearch()
        require(pageReads.count == beforeDispatchPages + 4 && pageReads.last == Board.home.latestURL(order: .replies),
                "Clearing a multi-board search loads an uncached home listing")
        _ = await context.search(query: "  ", scope: [], kind: .all)
        require(pageReads.count == beforeDispatchPages + 4 && peopleReads.count == beforeDispatchPeople + 2 &&
                workspace.query.isEmpty, "Blank search restores a cached listing without issuing an empty search")
        workspace.clearSearchHistory()
        print("PASS native search dispatch performs required reads and skips URL, cached-clear and blank-search requests")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(RankingSnapshot.self, from: Data(#"""
        {"updated_at":12345,"posts":[
          {"post":{"id":700,"title":"First","author":"ÉＸample","author_id":101,"category":"tech","views":12,"comments":3},"score":3},
          {"post":{"id":701,"title":"Second","author":"ＳＨＡＲＥＤ"},"score":2},
          {"post":{"id":700,"title":"Duplicate","author":"Renamed","author_id":null},"score":1}
        ]}
        """#.utf8))
        let ranked = NativeDTO.rankingSnapshot(period: .realtime, snapshot: snapshot, failed: false)
        let rankingPosts = rows(ranked["posts"])
        require(ranked["period"] as? String == "hot" && ranked["updatedAt"] as? Double == 12345,
                "Ranking retains raw period and seconds timestamp")
        require(rankingPosts.compactMap { $0["id"] as? String } == ["700", "701", "700"] &&
                rankingPosts.compactMap { $0["position"] as? Int } == [1, 2, 3], "Raw ranking order and positions must precede client filters")
        require(rankingPosts[0]["authorID"] as? Int == 101 && rankingPosts[1]["authorID"] is NSNull &&
                rankingPosts[2]["authorID"] is NSNull, "Known author ID is integer; missing and explicit null IDs stay null")
        require(rankingPosts[0]["normalizedAuthor"] as? String == "example" &&
                rankingPosts[1]["normalizedAuthor"] as? String == "shared", "Normalization uses native case, diacritic and width folding")
        require(rankingPosts[0]["url"] as? String == post.url.absoluteString &&
                rankingPosts[1]["category"] as? String == "" && rankingPosts[1]["views"] as? Int == 0,
                "Ranking preserves URL and optional field defaults")
        require(ranked["error"] is NSNull && JSONSerialization.isValidJSONObject(ranked), "Successful ranking codec")
        let stale = NativeDTO.rankingSnapshot(period: .realtime, snapshot: snapshot, failed: true)
        require(stale["updatedAt"] as? Double == 12345 && rows(stale["posts"]).count == 3 && stale["error"] is String,
                "Failed refresh must retain stale content and its original timestamp")
        let empty = NativeDTO.rankingSnapshot(period: .weekly, snapshot: nil, failed: true)
        require(rows(empty["posts"]).isEmpty && empty["updatedAt"] is NSNull && empty["error"] is String,
                "First failed ranking has no fabricated content or freshness")
        require(JSONSerialization.isValidJSONObject(stale) && JSONSerialization.isValidJSONObject(empty), "Failure ranking codecs")
        print("PASS rankings preserve author identity, original ranks, native normalization and stale failure payloads")

        let extensions = context.extensions
        extensions.confirmBlock(.init(memberID: 101, name: "ÉＸample"))
        extensions.confirmBlock(.init(memberID: nil, name: "ＳＨＡＲＥＤ"))
        let preferences = NativePreferencesServices(context: context, openSystemSettings: { _ in false })
        let extensionSnapshot = preferences.extensionsSnapshot()
        let blocked = rows(extensionSnapshot["blocked"])
        require(blocked.count == 2 && blocked[0]["id"] as? String == "member:101" && blocked[0]["memberId"] as? Int == 101,
                "Blocked string identity is distinct from the nullable integer memberId")
        require(blocked[0]["normalizedName"] as? String == rankingPosts[0]["normalizedAuthor"] as? String &&
                blocked[1]["normalizedName"] as? String == rankingPosts[1]["normalizedAuthor"] as? String,
                "Ranking and blocklist must use the same native normalization")
        require(blocked[1]["id"] as? String == "name:shared" && blocked[1]["memberId"] is NSNull,
                "Name-only block retains its native identity")
        require(extensions.blocks(101, name: "Renamed") && !extensions.blocks(999, name: "example"),
                "When both IDs exist, only matching IDs block; different IDs must not fall back to names")
        require(extensions.blocks(nil, name: "example") && extensions.blocks(999, name: "shared"),
                "Either missing ID uses native normalized-name fallback")
        require(!extensions.blocks(nil, name: " example "), "Native normalization does not trim username whitespace")
        let items = rows(extensionSnapshot["items"])
        require(items.first { $0["id"] as? String == "hot" }?["active"] as? Bool == true &&
                items.first { $0["id"] as? String == "keywords" }?["active"] as? Bool == false,
                "Installed but disabled keywords must not be active")
        require(extensionSnapshot["unread"] as? Int == 0 && JSONSerialization.isValidJSONObject(extensionSnapshot),
                "Keyword unread is its own integer field with a codec-safe extension payload")
        extensions.setEnabled(.block, false)
        require(!extensions.blocks(101, name: "example"), "Disabled blocker cannot filter author rows")
        print("PASS blocklist DTO, native fallback matching and extension active/unread contract")
        try await checkNavigationRestoration()
        try await checkListingIssues()
    }

    @MainActor
    private static func checkNavigationRestoration() async throws {
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        let review = Board.sections.first { $0.id == "review" }!
        for board in [Board.home, Board.award, review] {
            let suite = "cc.seekdesk.qa.sidebar-restoration." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(board.id, forKey: "workspace.lastBoard")
            defaults.set("boards", forKey: "workspace.sidebarSection")
            defaults.set(ForumFeedOrder.replies.rawValue, forKey: "feed.order")
            var saved = ReadingSession()
            let url = Forum.home.appendingPathComponent("post-810-4")
            saved.open(url, title: "Previous account private title", background: false)
            saved.update("810") { $0.scroll = 283.75; $0.draft = "Previous account private draft" }
            saved.open(Forum.home.appendingPathComponent("post-811-1"), title: "Closed private title", background: true)
            saved.close("811")
            defaults.set(try JSONEncoder().encode(saved), forKey: "readingSession.v1")
            defaults.set(false, forKey: "reading.showReader")
            var reads: [URL] = []
            let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
                saveVault: { _, _ in fatalError("Navigation restoration must not write the proxy vault") },
                fetchSubscription: { _ in fatalError("Navigation restoration must not fetch a subscription") },
                measureNode: { _ in fatalError("Navigation restoration must not probe a node") })
            let context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
                fetchFeed: { fatalError("A successful restored listing must not fetch RSS") },
                fetchPage: { requested in
                    reads.append(requested)
                    return .init(posts: [], next: nil)
                }, fetchPeople: { _ in fatalError("Restoring a board must not search people") })
            let initial = context.workspaceSnapshot()
            require(initial["board"] as? String == board.id && initial["boardURL"] as? String == board.url.absoluteString,
                    "The first bridge snapshot must expose the restored canonical board")
            require(initial["showReader"] as? Bool == false && initial["selectedTab"] as? String == "810" && reads.isEmpty,
                    "Overview restoration must preserve tab selection without an eager read")
            require(context.workspace.session.selectedTopic?.url == url && context.workspace.session.selectedTopic?.scroll == 283.75,
                    "Restoring a board must not change the retained page or scroll offset")
            require(context.workspace.session.selectedTopic?.title == "" && context.workspace.session.selectedTopic?.draft == "" &&
                    context.workspace.session.closedTopics.first?.topic.title == "",
                    "Restoration must retain the existing account metadata redaction")
            context.workspace.showSettings()
            context.workspace.returnToForum()
            require(context.workspace.destination == .board(board) && !context.workspace.showReader,
                    "Returning from settings uses the restored last board and overview state")
            await context.workspace.refresh()
            require(reads == [board.latestURL(order: .replies)],
                    "The first explicit read must use the restored board and saved ordering")
            context.session.observeIdentity(.init(signedIn: true, id: 808, name: "New fixture", floorsPerPage: 20))
            require(context.workspace.board == board && context.workspace.session.selection == "810" &&
                    context.workspace.session.selectedTopic?.scroll == 283.75 &&
                    defaults.string(forKey: "workspace.lastBoard") == board.id,
                    "Account invalidation must not reset restored navigation or reading locations")
            require(defaults.string(forKey: "workspace.sidebarSection") == "boards" && !context.session.dataStore.isPersistent,
                    "Bridge navigation leaves sidebar preferences untouched and stays isolated")
            require(JSONSerialization.isValidJSONObject(context.workspaceSnapshot()), "Restored navigation snapshot must be codec safe")
        }
        print("PASS restored home, award and review snapshots, first read routes, metadata redaction and account-safe positions")
    }

    @MainActor
    private static func checkWindowChromeProtocol() {
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        require(NSStringFromSelector(NativeWindowChromeBridge.toolbarActionSelector) == "performToolbarAction:" &&
                NativeWindowChromeBridge.instancesRespond(to: NativeWindowChromeBridge.toolbarActionSelector),
                "Toolbar target/action must resolve to its own ObjC entry, never NSObject.performSelector:")
        let menuTarget = NSObject()
        for hasExistingMenu in [false, true] {
            let item = NSToolbarItem(itemIdentifier: .init("search"))
            item.label = "搜索帖子"
            if hasExistingMenu {
                item.menuFormRepresentation = NSMenuItem(title: "搜索帖子", action: nil, keyEquivalent: "")
            }
            let existingMenu = item.menuFormRepresentation
            NativeWindowChromeBridge.bindMenuRepresentation(of: item, title: "搜索帖子", target: menuTarget)
            let menu = item.menuFormRepresentation
            let correctlyBound = menu?.target === menuTarget &&
                menu?.action == NativeWindowChromeBridge.toolbarActionSelector &&
                menu?.representedObject as? String == "search" && menu?.title == "搜索帖子"
            require(correctlyBound, "Existing and new overflow menus must carry the toolbar action and identity")
            if let existingMenu {
                require(menu === existingMenu, "Overflow binding must preserve an existing menu item")
            }
        }
        var state = NativeWindowChromeState()
        let actions = NativeWindowChromeState.Action.allCases
        let avatar = Data([0x89, 0x50, 0x4e, 0x47])
        let snapshot: [String: Any] = [
            "enabledActions": actions.map(\.rawValue), "compact": false, "sidebarOpen": true,
            "showBack": true, "showOffice": true, "officeLabel": "切换办公视图", "officeCovered": false,
            "accountLabel": "我的账号，Fixture", "accountName": "Fixture", "unreadCount": 137,
            "connecting": false, "dark": true, "appearance": "dark", "palette": "Teal",
            "avatarBytes": FlutterStandardTypedData(bytes: avatar),
        ]
        for value in [NSNull(), ["protocol": true], ["protocol": 1.0], ["protocol": "1"],
                      ["protocol": 0], ["protocol": 2], ["protocol": 1, "extra": true]] as [Any] {
            require(state.attach(value) == nil && state.attachment == nil,
                    "Unsupported chrome attach must not establish a lease")
        }
        guard let attached = state.attach(["protocol": 1]), let first = attached["attachment"] as? String else {
            fatalError("Valid toolbar protocol was not attached")
        }
        require(attached["installed"] as? Bool == true && UUID(uuidString: first) != nil,
                "Chrome attachment must return an opaque UUID")
        require(state.generation == -1 && actions.allSatisfy { state.performArguments(for: $0) == nil },
                "Attaching alone must leave every native action disabled")
        func update(_ generation: Any, _ body: [String: Any]? = nil, attachment: String? = nil) -> [String: Any] {
            ["attachment": attachment ?? first, "generation": generation, "snapshot": body ?? snapshot]
        }
        require(state.update(update(0)), "The initial generation zero is valid")
        require(state.snapshot?.avatarBytes == avatar && state.snapshot?.accountName == "Fixture" &&
                state.snapshot?.unreadCount == 137 && state.snapshot?.palette == "Teal",
                "Valid snapshots preserve bounded display values and Uint8 bytes")
        for action in actions {
            let args = state.performArguments(for: action)
            require(args?["attachment"] as? String == first && args?["generation"] as? Int64 == 0 &&
                    args?["action"] as? String == action.rawValue,
                    "Every native action must carry the current attachment and generation")
        }
        require(!state.update(update(0)) && state.update(update(2)) && !state.update(update(1)),
                "Duplicate and out-of-order chrome snapshots must never replace the current generation")
        for value in [true, -1, 3.0, "3", Double.nan, Double.infinity, NSNull(), Int64.max] as [Any] {
            require(!state.update(update(value)) && state.generation == 2,
                    "Non-integer, negative or unrepresentable generations must not consume a generation")
        }
        require(!state.update(update(3, attachment: UUID().uuidString)) && state.generation == 2,
                "An unrelated attachment cannot publish chrome state")
        print("PASS native window chrome attachment, disabled handshake and strictly increasing generation contract")

        let invalidFields: [(String, Any)] = [
            ("enabledActions", ["home", "home"]), ("enabledActions", ["home", "publish"]),
            ("enabledActions", "home"), ("compact", 1), ("sidebarOpen", "true"),
            ("showBack", NSNull()), ("showOffice", 0), ("officeCovered", 1),
            ("connecting", "false"), ("dark", 0), ("unreadCount", true),
            ("unreadCount", -1), ("unreadCount", 1.0), ("unreadCount", "1"),
            ("appearance", "automatic"), ("appearance", true),
            ("palette", "not-a-palette"), ("accountLabel", 17),
            ("accountName", false), ("officeLabel", 17),
            ("avatarBytes", avatar), ("avatarBytes", "https://example.invalid/avatar.png"),
            ("avatarBytes", FlutterStandardTypedData(int32: Data(repeating: 0, count: 4))),
        ]
        for (key, value) in invalidFields {
            var invalid = snapshot
            invalid[key] = value
            require(!state.update(update(3, invalid)) && state.generation == 2 &&
                    state.snapshot?.accountName == "Fixture",
                    "Invalid snapshot field \(key) must be rejected atomically")
        }
        for key in snapshot.keys where key != "avatarBytes" {
            var missing = snapshot
            missing.removeValue(forKey: key)
            require(!state.update(update(3, missing)) && state.generation == 2,
                    "Required chrome field \(key) cannot silently default")
        }
        var withoutAvatar = snapshot
        withoutAvatar.removeValue(forKey: "avatarBytes")
        require(state.update(update(3, withoutAvatar)) && state.snapshot?.avatarBytes == nil,
                "Omitted avatar explicitly clears the old account image")
        withoutAvatar["avatarBytes"] = NSNull()
        require(state.update(update(4, withoutAvatar)), "A null avatar must use the system account symbol")
        for bytes in [Data(), Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
            var oversized = snapshot
            oversized["avatarBytes"] = FlutterStandardTypedData(bytes: bytes)
            let parsed = NativeWindowChromeState.Snapshot(oversized)
            require(parsed?.avatarBytes == nil && parsed?.allows(.search) == true,
                    "Optional empty or oversized avatars must not disable toolbar navigation")
        }
        for appearance in ["system", "light", "dark"] {
            var themed = snapshot
            themed["appearance"] = appearance
            require(NativeWindowChromeState.Snapshot(themed)?.appearance == appearance,
                    "System inheritance must remain distinct from explicit light and dark appearance")
        }
        var longLabels = snapshot
        longLabels["showOffice"] = false
        longLabels["officeLabel"] = "  一行\n\t二行  " + String(repeating: "长", count: 160)
        longLabels["accountLabel"] = "First\n\r\tSecond\u{0}"
        longLabels["accountName"] = String(repeating: "👩‍💻", count: 40)
        guard let normalized = NativeWindowChromeState.Snapshot(longLabels) else {
            fatalError("Legacy display labels must not invalidate the toolbar")
        }
        require(normalized.officeLabel.hasPrefix("一行 二行 ") && normalized.officeLabel.hasSuffix("…") &&
                normalized.officeLabel.utf8.count <= 256 && normalized.accountLabel == "First Second" &&
                normalized.accountName.hasPrefix("👩‍💻") && normalized.accountName.hasSuffix("…") &&
                normalized.accountName.utf8.count <= 160 && normalized.allows(.search),
                "Display labels must normalize whitespace and truncate complete graphemes without disabling navigation")
        require((longLabels["officeLabel"] as? String)?.contains("\n") == true,
                "Toolbar normalization must not mutate the original preference snapshot")
        print("PASS native window chrome strict field types, atomic invalid snapshot rejection and bounded avatar payloads")

        var hidden = snapshot
        hidden["showBack"] = false
        hidden["showOffice"] = false
        require(state.update(update(5, hidden)), "Hidden toolbar controls may be represented in a snapshot")
        require(state.performArguments(for: .back) == nil && state.performArguments(for: .office) == nil &&
                state.performArguments(for: .sidebar) != nil,
                "Hidden back and office controls cannot be invoked even if erroneously listed as enabled")
        var covered = snapshot
        covered["officeCovered"] = true
        covered["connecting"] = true
        require(state.update(update(6, covered)), "Office cover snapshot accepted")
        require(actions.allSatisfy { state.performArguments(for: $0) == nil } &&
                state.snapshot?.accountName == "" && state.snapshot?.accountLabel == "" &&
                state.snapshot?.officeLabel == "" && state.snapshot?.avatarBytes == nil &&
                state.snapshot?.unreadCount == 0 && state.snapshot?.connecting == false &&
                state.snapshot?.showBack == false && state.snapshot?.showOffice == false,
                "Office cover must sanitize forum information and disable every native action")
        require(!state.update(update(5, snapshot)) && state.snapshot?.officeCovered == true,
                "An older visible snapshot cannot reveal the covered forum")
        require(state.update(update(7, snapshot)) && state.performArguments(for: .search) != nil,
                "A fresh uncovered snapshot restores actions")
        print("PASS native window chrome office privacy, hidden-action rejection and stale uncover protection")

        require(!state.detach(["attachment": "wrong"]) && state.attachment == first,
                "A stale detach cannot tear down current chrome")
        guard let reattached = state.attach(["protocol": 1]), let second = reattached["attachment"] as? String else {
            fatalError("Chrome reattachment rejected")
        }
        require(second != first && state.generation == -1 && state.snapshot == nil,
                "Reattachment must rotate the UUID and reset all presentation state")
        require(!state.update(update(8)) && !state.detach(["attachment": first]),
                "An old isolate cannot update or detach the new attachment")
        require(state.update(update(0, attachment: second)), "A new lease starts its own generation sequence")
        require(state.detach(["attachment": second]) && state.attachment == nil && state.snapshot == nil &&
                state.generation == -1 && actions.allSatisfy { state.performArguments(for: $0) == nil },
                "Detach must revoke all actions and release state")
        require(!state.update(update(1, attachment: second)) && !state.detach(["attachment": second]),
                "Detached leases cannot resume or detach again")
        print("PASS native window chrome reattachment and detach prevent stale isolate actions")
    }

    @MainActor
    private static func checkListingIssues() async throws {
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
        let requested = Forum.search("local fixture")
        for status in [200, 204, 299] {
            try ForumListing.validateResponse(status: status, challenged: false, actual: requested, requested: requested)
        }
        let rejected: [(Int?, Bool, URL?, ForumListingIssue)] = [
            (401, false, requested, .signInRequired), (200, false, Forum.signIn, .signInRequired),
            (403, true, requested, .verification), (401, true, requested, .verification),
            (429, false, requested, .rateLimited), (404, false, requested, .missing),
            (410, false, requested, .missing), (403, false, requested, .network),
            (503, false, requested, .network), (304, false, requested, .network),
            (nil, false, requested, .network), (200, false, nil, .network),
            (200, false, URL(string: "https://example.invalid/search"), .network),
        ]
        for (status, challenged, actual, expected) in rejected {
            do {
                try ForumListing.validateResponse(status: status, challenged: challenged, actual: actual, requested: requested)
                fatalError("Non-success or invalid listing response accepted")
            } catch let issue as ForumListingIssue {
                require(issue == expected, "HTTP response validation must preserve safe, stable failure classifications")
            }
        }
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private diagnostic marker"))
        let unknown = NSError(domain: "FixtureTransport", code: NSURLErrorTimedOut,
                              userInfo: [NSLocalizedDescriptionKey: "private diagnostic marker"])
        require(ForumListingIssue.classify(decoding) == .changed, "Malformed payloads are parsing failures")
        require(ForumListingIssue.classify(URLError(.timedOut)) == .timedOut &&
                ForumListingIssue.classify(unknown) == .network, "Timeout classification must verify the error domain")
        require(ForumListingIssue.classify(CancellationError()) == nil &&
                ForumListingIssue.classify(URLError(.cancelled)) == nil, "Cancellation is not a user-visible read failure")
        print("PASS listing response gates reject HTTP failures before parsing and classify errors without raw details")

        let suite = "cc.seekdesk.qa.listing-issues." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        let post = FeedPost(id: "801", url: Forum.home.appendingPathComponent("post-801-1"),
                           title: "Local fixture", author: "Fixture", category: "tech", published: nil, summary: "")
        let tech = Board.sections.first { $0.id == "tech" }!
        var pageIssue: Error?, peopleIssue: Error?, feedIssue: Error?
        var pageGate: SidebarGate?, peopleGate: SidebarGate?
        var next: URL?
        var feedReads = 0, pageReads = 0, peopleReads = 0
        let context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: {
                feedReads += 1
                if let feedIssue { throw feedIssue }
                return [post]
            }, fetchPage: { _ in
                pageReads += 1
                if let pageGate { await pageGate.wait() }
                if let pageIssue { throw pageIssue }
                return .init(posts: [post], next: next)
            }, fetchPeople: { _ in
                peopleReads += 1
                if let peopleGate { await peopleGate.wait() }
                if let peopleIssue { throw peopleIssue }
                return [.init(id: 77, name: "Local Person", avatar: nil, tags: [])]
            })
        let workspace = context.workspace
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 20))
        let ready = try await context.selectBoard(tech.id)
        require(ready["errorCode"] is NSNull && ready["peopleErrorCode"] is NSNull &&
                ready["peopleError"] is NSNull && ready["peopleLoading"] as? Bool == false &&
                ready["showsPeopleResults"] as? Bool == false && ready["hasForumPage"] as? Bool == true &&
                ready["failedToRefresh"] as? Bool == false && ready["failedToLoadOlder"] as? Bool == false,
                "Successful listing exposes explicit independent error and source fields")
        let timestamp = ready["lastRefresh"] as? Double
        let failures: [(Error, String)] = [
            (ForumPageError.verification, "verification"), (ForumPageError.missing, "missing"),
            (ForumPageError.changed, "changed"), (ForumPageError.timedOut, "timedOut"),
            (ForumPageError.network, "network"), (ForumListingIssue.rateLimited, "rateLimited"),
            (decoding, "changed"), (unknown, "network"),
        ]
        for (error, code) in failures {
            pageIssue = error
            await workspace.refresh()
            let failed = context.workspaceSnapshot()
            require(failed["errorCode"] as? String == code && failed["error"] is String,
                    "Listing refresh must retain the specific error code and safe message")
            require(rows(failed["posts"]).count == 1 && failed["lastRefresh"] as? Double == timestamp &&
                    failed["hasForumPage"] as? Bool == true && failed["failedToLoadOlder"] as? Bool == false,
                    "Refresh failure preserves existing content, freshness and pagination state")
            let encoded = try JSONSerialization.data(withJSONObject: failed, options: [.sortedKeys])
            require(!String(decoding: encoded, as: UTF8.self).contains("private diagnostic marker"),
                    "Snapshots must never expose raw transport or decoding descriptions")
        }
        require(feedReads == 0, "A cached ordinary listing failure cannot request the home RSS fallback")
        pageIssue = ForumPageError.signInRequired
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] as? String == "signInRequired" && !workspace.hasForumPage,
                "Sign-in failures preserve the existing policy of invalidating privileged listing caches")
        pageIssue = nil
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] is NSNull && workspace.hasForumPage,
                "A successful explicit retry clears the error and restores the forum listing")
        print("PASS listing issues preserve stale data safely, distinguish reasons and clear after recovery")

        next = tech.url.appendingPathComponent("page-2")
        await workspace.refresh()
        pageIssue = ForumListingIssue.rateLimited
        await workspace.loadOlder()
        let older = context.workspaceSnapshot()
        require(older["errorCode"] as? String == "rateLimited" && older["failedToLoadOlder"] as? Bool == true &&
                older["failedToRefresh"] as? Bool == false && rows(older["posts"]).count == 1 && workspace.hasOlderPosts,
                "Pagination failure retains its cursor and data without becoming an initial refresh failure")
        pageIssue = ForumPageError.verification
        await workspace.refresh()
        let bothListingFailures = context.workspaceSnapshot()
        require(bothListingFailures["errorCode"] as? String == "verification" &&
                bothListingFailures["failedToRefresh"] as? Bool == true &&
                bothListingFailures["failedToLoadOlder"] as? Bool == true && rows(bothListingFailures["posts"]).count == 1,
                "A refresh failure after pagination failure takes message priority while exposing both failed operations")
        pageIssue = nil
        await workspace.loadOlder()
        let listingOlderRecovered = context.workspaceSnapshot()
        require(listingOlderRecovered["errorCode"] as? String == "verification" &&
                listingOlderRecovered["failedToRefresh"] as? Bool == true &&
                listingOlderRecovered["failedToLoadOlder"] as? Bool == false,
                "Successful pagination retry clears only its error and cannot hide the unresolved refresh failure")
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] is NSNull &&
                context.workspaceSnapshot()["failedToRefresh"] as? Bool == false && !workspace.failedToLoadOlder,
                "Successful listing refresh clears both failure flags and the prioritized message")
        next = Forum.home.appendingPathComponent("search/page-2")
        _ = await context.search(query: "Local fixture", scope: [], kind: .posts)
        pageIssue = ForumPageError.verification
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] as? String == "verification" &&
                rows(context.workspaceSnapshot()["posts"]).count == 1 && !workspace.failedToLoadOlder,
                "Search refresh retains content and a specific failure independently of pagination")
        pageIssue = URLError(.timedOut)
        await workspace.loadOlder()
        let bothSearchFailures = context.workspaceSnapshot()
        require(bothSearchFailures["errorCode"] as? String == "verification" &&
                bothSearchFailures["failedToRefresh"] as? Bool == true &&
                bothSearchFailures["failedToLoadOlder"] as? Bool == true && rows(bothSearchFailures["posts"]).count == 1,
                "A later search pagination failure cannot replace the refresh failure's message or retry priority")
        pageIssue = nil
        await workspace.loadOlder()
        let searchOlderRecovered = context.workspaceSnapshot()
        require(searchOlderRecovered["errorCode"] as? String == "verification" &&
                searchOlderRecovered["failedToRefresh"] as? Bool == true &&
                searchOlderRecovered["failedToLoadOlder"] as? Bool == false,
                "Successful search pagination retry leaves an unresolved refresh failure visible")
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] is NSNull &&
                context.workspaceSnapshot()["failedToRefresh"] as? Bool == false && !workspace.failedToLoadOlder,
                "Successful search refresh clears both error channels after either failure order")
        pageIssue = URLError(.timedOut)
        await workspace.loadOlder()
        require(context.workspaceSnapshot()["errorCode"] as? String == "timedOut" &&
                workspace.failedToLoadOlder && !workspace.failedToRefresh && workspace.hasOlderPosts,
                "Search pagination preserves the timed-out cursor and does not mark initial search failed")
        pageIssue = nil
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] is NSNull && !workspace.failedToLoadOlder,
                "Refreshing search successfully also resets old pagination failure")
        print("PASS ordinary and search pagination failures have independent codes, cached content and retry state")

        next = nil
        _ = await context.search(query: "Local fixture", scope: [], kind: .all)
        peopleIssue = ForumPageError.signInRequired
        await workspace.refresh()
        let peopleFailed = context.workspaceSnapshot()
        require(peopleFailed["errorCode"] is NSNull && peopleFailed["peopleErrorCode"] as? String == "signInRequired" &&
                peopleFailed["peopleError"] is String && peopleFailed["showsPeopleResults"] as? Bool == true &&
                rows(peopleFailed["people"]).count == 1 && rows(peopleFailed["posts"]).count == 1,
                "A people-only failure stays visible without hiding successful posts or retained user results")
        pageIssue = ForumPageError.verification
        peopleIssue = ForumPageError.timedOut
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] as? String == "verification" &&
                context.workspaceSnapshot()["peopleErrorCode"] as? String == "timedOut",
                "Combined search reports independent post and directory failures")
        let beforePeopleOnly = pageReads
        let peopleOnly = await context.search(query: "Person", scope: [tech.id], kind: .people)
        require(peopleOnly["errorCode"] is NSNull && peopleOnly["peopleErrorCode"] as? String == "timedOut" &&
                rows(peopleOnly["posts"]).isEmpty && pageReads == beforePeopleOnly,
                "People-only errors do not become post errors or trigger a post request")
        peopleIssue = nil
        let directoryGate = SidebarGate()
        peopleGate = directoryGate
        let loadingPeople = Task { @MainActor in await workspace.refresh() }
        while !directoryGate.entered { await Task.yield() }
        let busy = context.workspaceSnapshot()
        require(busy["peopleLoading"] as? Bool == true && busy["loading"] as? Bool == true &&
                busy["peopleErrorCode"] is NSNull && busy["showsPeopleResults"] as? Bool == true,
                "Directory retry exposes its own loading state and clears the previous failure")
        directoryGate.release()
        await loadingPeople.value
        peopleGate = nil
        require(context.workspaceSnapshot()["peopleLoading"] as? Bool == false &&
                context.workspaceSnapshot()["peopleErrorCode"] is NSNull && rows(context.workspaceSnapshot()["people"]).count == 1,
                "A successful people retry clears the error and loading state")
        workspace.clearSearch()
        require(context.workspaceSnapshot()["peopleErrorCode"] is NSNull &&
                context.workspaceSnapshot()["showsPeopleResults"] as? Bool == false && rows(context.workspaceSnapshot()["people"]).isEmpty,
                "Clearing a search clears independent people status")
        print("PASS post and people errors remain independent, preserve stale users and expose real loading/recovery")

        workspace.invalidateForumAccess()
        pageIssue = ForumPageError.verification
        let fallback = try await context.selectBoard(Board.home.id)
        require(fallback["errorCode"] as? String == "verification" && fallback["hasForumPage"] as? Bool == false &&
                rows(fallback["posts"]).count == 1 && feedReads == 1,
                "Successful RSS fallback keeps the primary HTML diagnosis and identifies the fallback source")
        feedIssue = URLError(.timedOut)
        await workspace.refresh()
        require(context.workspaceSnapshot()["errorCode"] as? String == "verification" &&
                rows(context.workspaceSnapshot()["posts"]).count == 1 && feedReads == 2,
                "Failed RSS fallback does not overwrite the original HTML diagnosis or erase available data")
        pageIssue = nil
        feedIssue = nil
        await workspace.refresh()
        require(workspace.hasForumPage && context.workspaceSnapshot()["errorCode"] is NSNull && feedReads == 2,
                "Recovered HTML becomes the authoritative source without an unnecessary RSS request")
        for cancellation in [CancellationError() as Error, URLError(.cancelled) as Error] {
            pageIssue = cancellation
            await workspace.refresh()
            require(context.workspaceSnapshot()["errorCode"] is NSNull && feedReads == 2,
                    "Cancelled listing reads must not publish failures or invoke fallback")
            _ = await context.search(query: "Local fixture", scope: [], kind: .posts)
            require(context.workspaceSnapshot()["errorCode"] is NSNull,
                    "Cancelled search reads must not fabricate errors")
            peopleIssue = cancellation
            _ = await context.search(query: "Person", scope: [], kind: .people)
            require(context.workspaceSnapshot()["peopleErrorCode"] is NSNull,
                    "Cancelled people reads must not fabricate errors")
            workspace.clearSearch()
        }
        print("PASS RSS preserves the primary error and cancellation cannot create errors or fallback requests")

        pageIssue = ForumPageError.verification
        peopleIssue = ForumPageError.signInRequired
        let latePage = SidebarGate(), latePeople = SidebarGate()
        pageGate = latePage
        peopleGate = latePeople
        let lateSearch = Task { @MainActor in await context.search(query: "Local fixture", scope: [], kind: .all) }
        while !latePage.entered || !latePeople.entered { await Task.yield() }
        context.session.observeIdentity(.init(signedIn: true, id: 202, name: "New fixture", floorsPerPage: 20))
        latePage.release()
        latePeople.release()
        let invalidated = await lateSearch.value
        require(invalidated["errorCode"] is NSNull && invalidated["peopleErrorCode"] is NSNull &&
                invalidated["peopleLoading"] as? Bool == false && invalidated["failedToLoadOlder"] as? Bool == false &&
                invalidated["query"] as? String == "" && rows(invalidated["people"]).isEmpty,
                "Delayed post and directory failures cannot repopulate errors or people after an account boundary")
        require(!context.session.dataStore.isPersistent && peopleReads > 0 && JSONSerialization.isValidJSONObject(invalidated),
                "All failure regressions stay in nonpersistent local fixtures with codec-safe payloads")
        print("PASS account invalidation discards late search and directory failure state")
    }
}
