import AppKit
import FlutterMacOS
import Foundation
import WebKit

@MainActor
private final class ReaderContextGate {
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
        fatalError("Memory-only reader request did not reach its gate")
    }
}

@MainActor
private final class ReaderContextMemory {
    var readerError: ForumPageError?
    var readerGate: ReaderContextGate?
    var profileGates: [Int: ReaderContextGate] = [:]
    var profileCalls: [(Int, Bool, ObjectIdentifier)] = []
    var authorStarts: [Int] = []
    var profileFailure = false
    var activeProfiles = 0, maximumProfiles = 0
    var cacheOnly = false, nilPreparedPage = false
    var readerTitle = "Reader context"
    var readerReports = false
    var readerFetches = 0
    var page: ForumWebPage?
    var editors: [ForumInlineEdit] = []
    var editWrites = 0
    var events: [(domain: String, payload: [String: Any], revision: Int)] = []
}

@MainActor
private final class ReaderContextFixture {
    let suite = "cc.seekdesk.qa.reader-context." + UUID().uuidString
    let defaults: UserDefaults
    let memory = ReaderContextMemory()
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let url = Forum.home.appendingPathComponent("post-123-1")

    init(observeAuthorStarts: Bool = false) {
        defaults = UserDefaults(suiteName: suite)!
        let memory = memory
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        let sessionRequests = ForumSession.Requests(
            reply: { _, _, _ in fatalError("Reader context fixtures must not send replies") },
            profile: { page, id, includeReadme in
                memory.profileCalls.append((id, includeReadme, ObjectIdentifier(page)))
                memory.activeProfiles += 1
                memory.maximumProfiles = max(memory.maximumProfiles, memory.activeProfiles)
                defer { memory.activeProfiles -= 1 }
                if let gate = memory.profileGates[id] { await gate.wait() }
                if memory.profileFailure { throw ForumPageError.network }
                let data = try JSONSerialization.data(withJSONObject: [
                    "member_id": id, "member_name": "Author \(id)", "rank": 7,
                    "roles": [["display_text": "Member"]], "bio": "Author bio",
                    "signature_markdown": "[signature](https://example.invalid)",
                ])
                return String(decoding: data, as: UTF8.self)
            })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(),
            sessionRequests: sessionRequests, proxy: proxy, fetchFeed: { [] })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Owner", floorsPerPage: 10))
        var requests = NativeForumServices.Requests()
        requests.reader = { topic, state, session, _ in
            if memory.cacheOnly {
                return await state.load(topic, session: session, fetch: { _, _ in
                    fatalError("Cache-only reader must not fetch")
                })
            }
            return await state.load(topic, session: session, force: true, fetch: { url, session in
                memory.readerFetches += 1
                let gate = memory.readerGate, error = memory.readerError
                let title = memory.readerTitle, reports = memory.readerReports
                if let gate { await gate.wait() }
                if let error { throw error }
                let number = Int(url.lastPathComponent.split(separator: "-").last!)!
                let page = ForumWebPage(dataStore: session.dataStore)
                memory.page = page
                return (Self.thread(page: number, title: title, reports: reports), page)
            })
        }
        // Deliberately use the production readerAuthor default: its call to the
        // real session cache/concurrency layer ends at sessionRequests.profile.
        if observeAuthorStarts {
            requests.readerAuthor = { id, page, session in
                memory.authorStarts.append(id)
                await session.loadProfile(id, using: page, includeReadme: false)
            }
        }
        requests.profile = { _, _, _ in fatalError("Reader authors must not use profile-screen loading") }
        requests.preparePage = { _, _, session in
            memory.nilPreparedPage ? nil : ForumWebPage(dataStore: session.dataStore)
        }
        requests.makeEdit = {
            var edit = ForumInlineEdit.Requests()
            edit.read = { _, _ in "{\"markdown\":\"Original\",\"title\":\"Original title\"}" }
            edit.prepare = { _, text, authorized in
                guard authorized() else { throw CancellationError() }
                return text
            }
            edit.write = { _, _, _, _ in
                memory.editWrites += 1
                return "{\"kind\":\"saved\"}"
            }
            let value = ForumInlineEdit(requests: edit)
            memory.editors.append(value)
            return value
        }
        requests.sendReply = { _, _, _ in fatalError("Busy reader must not send") }
        requests.uploadImage = { _, _ in fatalError("Reader context fixtures must not upload") }
        requests.publish = { _, _, _, _ in fatalError("Reader context fixtures must not publish") }
        services = NativeForumServices(context: context, requests: requests)
        let services = services
        context.accessChanged = { services.invalidate() }
        let eventContext = context
        context.event = { [weak eventContext] domain, payload in
            memory.events.append((domain, payload as? [String: Any] ?? [:], eventContext?.session.accessRevision ?? -1))
        }
    }

    static func thread(page: Int = 1, title: String = "Reader context", reports: Bool = false) -> ForumThread {
        let nestedReport = ForumBlock(kind: "tabs", text: "", url: nil,
            tabs: [.init(label: "NQ", blocks: [.init(kind: "terminal", text: "\u{001B}[31mTAB RED\u{001B}[0m",
                url: nil, tabs: nil, rows: nil, terminal: nil)])], rows: nil, terminal: nil)
        let listReport = ForumBlock(kind: "list", text: "", url: nil, tabs: nil, rows: nil, terminal: nil,
            items: [.init(marker: "•", blocks: [.init(kind: "terminal", text: "\u{001B}[32mLIST GREEN\u{001B}[0m",
                url: nil, tabs: nil, rows: nil, terminal: nil)])])
        let floors = (201...204).map { id in
            ForumFloor(id: String(id - 200), author: "Author \(id)", authorID: id, isAuthor: false,
                avatar: nil, tags: ["Visible"], date: "2026-11-15", dateLabel: "now",
                blocks: [.init(kind: "text", text: "Memory body", url: nil, tabs: nil, rows: nil, terminal: nil)] +
                    (reports && id == 201 ? [nestedReport, listReport] : []))
        }
        return ForumThread(title: title, category: "tech", root: floors.first,
            replies: Array(floors.dropFirst()), pages: [], page: page, replyRestriction: nil)
    }

    func call(_ method: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args.merging(["accessRevision": context.session.accessRevision]) { _, new in new }) as? [String: Any] ?? [:]
    }
    func load(_ address: URL? = nil, force: Bool = true) async throws -> [String: Any] {
        try await call("reader.load", ["url": (address ?? url).absoluteString, "force": force])
    }
    func author(_ id: Int = 201, url: URL? = nil) async throws -> [String: Any] {
        try await call("reader.author", ["url": (url ?? self.url).absoluteString, "id": id])
    }
    func editArgs() -> [String: Any] { ["url": url.absoluteString, "topicID": "123", "floor": 0] }
    func beginEdit() async throws -> [String: Any] {
        var args = editArgs()
        args["editToken"] = try await call("reader.edit.begin", args)["editToken"]
        return args
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        context.event = nil
        memory.profileGates.values.forEach { $0.release() }
        memory.readerGate?.release()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct ReaderContextChecks {
    @MainActor
    static func main() async throws {
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
        func reject(_ code: String, _ action: () async throws -> Void) async throws {
            do { try await action(); fatalError("Expected \(code)") }
            catch let issue as NativeBridgeError { require(issue.code == code, "Expected \(code), got \(issue.code)") }
        }
        func retired(_ action: () async throws -> Void) async throws {
            do { try await action(); fatalError("Retired author request returned a payload") }
            catch is CancellationError {}
            catch let issue as NativeBridgeError { require(issue.code == "stale_authorization", "Unexpected retirement error") }
        }
        var duplicateDocumentEvents = 0
        var duplicateDocumentScenarios: [String] = []
        func recordDocumentEvents(_ name: String, _ fixture: ReaderContextFixture, result: [String: Any]? = nil) {
            let readerEvents = fixture.memory.events.filter { $0.domain == "reader" }
            let documents = readerEvents.filter { $0.payload["thread"] is [String: Any] }
            func bytes(_ events: [(domain: String, payload: [String: Any], revision: Int)]) -> Int {
                events.reduce(0) { total, event in
                    total + FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope([
                        "domain": event.domain, "data": event.payload, "accessRevision": event.revision
                    ]).count
                }
            }
            duplicateDocumentEvents += documents.count
            if !documents.isEmpty { duplicateDocumentScenarios.append(name) }
            let methodBytes = result.map { FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope($0).count } ?? 0
            let workspaceEvents = fixture.memory.events.filter { $0.domain == "workspace" }.count
            print("MEASURE \(name) readerEvents=\(readerEvents.count) readerEventBytes=\(bytes(readerEvents)) fullDocumentEvents=\(documents.count) fullDocumentEventBytes=\(bytes(documents)) correlatedMethodBytes=\(methodBytes) workspaceEvents=\(workspaceEvents)")
            fflush(stdout)
        }
        func hasWorkspaceTitle(_ fixture: ReaderContextFixture, _ title: String) -> Bool {
            fixture.memory.events.contains { event in
                event.domain == "workspace" && (event.payload["tabs"] as? [[String: Any]])?.contains {
                    $0["id"] as? String == "123" && $0["title"] as? String == title
                } == true
            }
        }
        func requireDocument(_ value: [String: Any], _ fixture: ReaderContextFixture, title: String) {
            let thread = map(value["thread"]), root = map(thread["root"])
            require(value["url"] as? String == fixture.url.absoluteString && value["topicID"] as? String == "123" &&
                    value["accessRevision"] as? Int == fixture.context.session.accessRevision && value["loading"] as? Bool == false,
                    "The correlated reader response keeps its URL, topic, revision and settled loading state")
            require(thread["title"] as? String == title && thread["page"] as? Int == 1 &&
                    (thread["replies"] as? [Any])?.count == 3 && root["authorID"] as? Int == 201,
                    "The method response retains the requested document and all floor metadata")
            let blocks = root["blocks"] as? [[String: Any]] ?? []
            require(blocks.first?["text"] as? String == "Memory body", "Ordinary body text survives DTO normalization")
            let tabBlock = blocks.first { $0["kind"] as? String == "tabs" } ?? [:]
            let tab = (tabBlock["tabs"] as? [[String: Any]])?.first ?? [:]
            let tabTerminal = (tab["blocks"] as? [[String: Any]])?.first ?? [:]
            let listBlock = blocks.first { $0["kind"] as? String == "list" } ?? [:]
            let item = (listBlock["items"] as? [[String: Any]])?.first ?? [:]
            let listTerminal = (item["blocks"] as? [[String: Any]])?.first ?? [:]
            require(tab["label"] as? String == "NQ" && item["marker"] as? String == "•",
                    "Nested report labels and list markers remain in the correlated document")
            for (terminal, expected) in [(tabTerminal, "TAB RED"), (listTerminal, "LIST GREEN")] {
                let spans = (terminal["terminal"] as? [[[String: Any]]] ?? []).flatMap { $0 }
                require(spans.compactMap { $0["text"] as? String }.joined() == expected &&
                        spans.contains { $0["foreground"] is String },
                        "Nested tabs and list descendants retain parsed ANSI text and foreground spans in the method response")
            }
            require(JSONSerialization.isValidJSONObject(value), "The complete method payload remains codec-safe")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.readerReports = true
            require(f.context.workspace.openTopicLink(f.url), "The reader fixture opens its local tab")
            _ = try await f.call("reader.rememberPosition", ["url": f.url.absoluteString, "offset": 341.25,
                "bodyAnchor": ["floor": "2", "dy": 18.5], "anchor": "floor-2"])
            _ = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": "Retained fixture draft"])
            func requirePosition(_ value: [String: Any]) {
                require(value["scrollOffset"] as? Double == 341.25 && map(value["bodyAnchor"])["floor"] as? String == "2" &&
                        map(value["bodyAnchor"])["dy"] as? Double == 18.5 && value["anchor"] as? String == "floor-2" &&
                        value["draft"] as? String == "Retained fixture draft" && value["authorProfilesSupported"] as? Bool == true,
                        "Method responses retain independent body/legacy anchors, draft and author capability")
            }
            f.memory.events.removeAll()
            let cold = try await f.load()
            requireDocument(cold, f, title: "Reader context")
            requirePosition(cold)
            require(f.memory.readerFetches == 1 && cold["error"] is NSNull && cold["refreshFailed"] as? Bool == false &&
                    hasWorkspaceTitle(f, "Reader context"), "Cold read returns once and preserves current title events")
            recordDocumentEvents("cold-reader", f, result: cold)

            f.memory.events.removeAll()
            f.memory.cacheOnly = true
            let cached = try await f.load(force: false)
            requireDocument(cached, f, title: "Reader context")
            requirePosition(cached)
            require(f.memory.readerFetches == 1 && hasWorkspaceTitle(f, "Reader context"),
                    "A warm cache read retains the workspace result without fetching")
            recordDocumentEvents("warm-cache-reader", f, result: cached)

            f.memory.events.removeAll()
            f.memory.cacheOnly = false
            f.memory.readerTitle = "Refreshed reader"
            let refreshed = try await f.load()
            requireDocument(refreshed, f, title: "Refreshed reader")
            requirePosition(refreshed)
            require(f.memory.readerFetches == 2 && refreshed["refreshFailed"] as? Bool == false &&
                    hasWorkspaceTitle(f, "Refreshed reader"), "Explicit refresh returns the new body and publishes its title")
            recordDocumentEvents("warm-reader-refresh", f, result: refreshed)

            f.memory.events.removeAll()
            f.memory.readerError = .network
            let failed = try await f.load()
            requireDocument(failed, f, title: "Refreshed reader")
            requirePosition(failed)
            require(f.memory.readerFetches == 3 && failed["refreshFailed"] as? Bool == true &&
                    failed["errorCode"] as? String == "network" && failed["error"] is String &&
                    hasWorkspaceTitle(f, "Refreshed reader"), "Refresh errors keep the usable document and workspace title")
            recordDocumentEvents("retained-reader-refresh-error", f, result: failed)

            f.memory.events.removeAll()
            f.context.session.rememberTitle("Independent title update", for: "123")
            require(hasWorkspaceTitle(f, "Independent title update") && f.memory.readerFetches == 3,
                    "A title-only update still reaches the open tab without any reader request")
            recordDocumentEvents("independent-title-event", f)
            print("PASS correlated cold/cache/refresh/error payloads preserve nested ANSI reports, positions, drafts and workspace/title events")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.readerReports = true
            _ = f.context.workspace.openTopicLink(f.url)
            let oldGate = ReaderContextGate(), currentGate = ReaderContextGate()
            defer { oldGate.release(); currentGate.release() }
            f.memory.readerTitle = "Superseded reader"; f.memory.readerGate = oldGate
            let old = Task { @MainActor in try await f.load() }
            await oldGate.untilEntered()
            f.memory.readerTitle = "Replacement reader"; f.memory.readerGate = currentGate
            let current = Task { @MainActor in try await f.load() }
            await currentGate.untilEntered()
            oldGate.release()
            try await retired { _ = try await old.value }
            require(f.context.session.cachedThread(at: f.url) == nil,
                    "An older completion cannot install a body while its replacement is still pending")
            currentGate.release()
            let loaded = try await current.value
            requireDocument(loaded, f, title: "Replacement reader")
            require(f.memory.readerFetches == 2 && hasWorkspaceTitle(f, "Replacement reader") &&
                    !hasWorkspaceTitle(f, "Superseded reader"), "Only the current reader request can return or publish a title")
            recordDocumentEvents("out-of-order-reader-replacement", f, result: loaded)
            print("PASS superseded reader completion cannot retire the pending replacement or publish its document")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.readerReports = true
            _ = f.context.workspace.openTopicLink(f.url)
            _ = try await f.load()
            f.memory.events.removeAll()
            let oldGate = ReaderContextGate(), currentGate = ReaderContextGate()
            defer { oldGate.release(); currentGate.release() }
            f.memory.readerTitle = "Closed reader"; f.memory.readerGate = oldGate
            let old = Task { @MainActor in try await f.load() }
            await oldGate.untilEntered()
            f.context.workspace.close("123"); f.services.closeReader("123")
            _ = f.context.workspace.openTopicLink(f.url)
            f.memory.readerTitle = "Reopened reader"; f.memory.readerGate = currentGate
            let current = Task { @MainActor in try await f.load() }
            await currentGate.untilEntered()
            oldGate.release()
            try await retired { _ = try await old.value }
            currentGate.release()
            let loaded = try await current.value
            requireDocument(loaded, f, title: "Reopened reader")
            require(f.memory.readerFetches == 3 && hasWorkspaceTitle(f, "Reopened reader") && !hasWorkspaceTitle(f, "Closed reader"),
                    "A closed request cannot replace a reopened reader's method result or tab title")
            recordDocumentEvents("close-reopen-reader", f, result: loaded)
            print("PASS closing and reopening the same URL keeps the replacement reader's correlated result")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.readerReports = true
            _ = f.context.workspace.openTopicLink(f.url)
            _ = try await f.load()
            f.memory.events.removeAll()
            let gate = ReaderContextGate(); f.memory.readerGate = gate
            f.memory.readerTitle = "Cancelled reader"
            let pending = Task { @MainActor in try await f.load() }
            await gate.untilEntered()
            pending.cancel(); gate.release()
            try await retired { _ = try await pending.value }
            require(f.context.session.cachedThread(at: f.url)?.title == "Reader context" && !hasWorkspaceTitle(f, "Cancelled reader"),
                    "Cancellation retains the prior cache without returning or publishing the cancelled document")
            recordDocumentEvents("cancelled-reader-refresh", f)
            print("PASS cancelled reader refresh neither returns a late body nor changes the retained title")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            let post = FeedPost(id: "123", url: f.url, title: "Preview title", author: "Preview author", category: "tech",
                published: Date(timeIntervalSince1970: 123), summary: "RSS summary", authorID: 201,
                readingRank: 255, featured: true)
            f.context.workspace.open(post, background: false)
            let snapshot = f.context.workspaceSnapshot(), tab = map((snapshot["tabs"] as? [Any])?.first)
            require(tab["featured"] as? Bool == true && tab["readingRank"] as? Int == 255, "Retained tab keeps access badges")
            require(tab["category"] as? String == "tech" && tab["summary"] as? String == "RSS summary", "Retained tab keeps category and fallback summary")
            require(tab["authorID"] as? Int == 201 && tab["published"] as? Double == 123_000, "Retained tab keeps author and publication date")
            f.context.workspace.close("123")
            let closed = map((f.context.workspaceSnapshot()["closedTabs"] as? [Any])?.first)
            require(closed["summary"] as? String == "RSS summary" && closed["url"] as? String == f.url.absoluteString,
                    "Closed tab snapshot preserves the same preview without changing its URL")
            print("PASS open and closed tab preview metadata")
        }

        for (issue, code) in [(ForumPageError.verification, "verification_required"), (.signInRequired, "sign_in_required"),
                              (.missing, "unavailable"), (.changed, "changed"), (.timedOut, "timed_out"), (.network, "network")] {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.readerError = issue
            let snapshot = try await f.load()
            require(snapshot["errorCode"] as? String == code && snapshot["refreshFailed"] as? Bool == false,
                    "Initial reader error has a stable code")
            require(snapshot["thread"] is NSNull && snapshot["authorProfilesSupported"] as? Bool == true,
                    "Failed reader exposes capability without fabricated content")
            try await reject("not_ready") { _ = try await f.author() }
            require(f.memory.profileCalls.isEmpty, "Failed reader never requests an author")
        }
        do {
            let f = ReaderContextFixture(); defer { f.close() }
            _ = try await f.load()
            f.memory.readerError = .network
            let refreshed = try await f.load()
            require(refreshed["refreshFailed"] as? Bool == true && refreshed["errorCode"] as? String == "network" &&
                    map(refreshed["thread"])["title"] as? String == "Reader context", "Refresh failure retains readable body")
            try await reject("not_ready") { _ = try await f.author() }
            require(f.memory.profileCalls.isEmpty, "Refresh failure cannot create profile requests")
            print("PASS six structured errors, refresh failure preservation and zero author reads on failures")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            try await reject("not_ready") { _ = try await f.author() }
            _ = try await f.load()
            try await reject("invalid_author") { _ = try await f.author(999) }
            try await reject("invalid_author") { _ = try await f.author(0) }
            try await reject("invalid_arguments") { _ = try await f.call("reader.author", ["url": f.url.absoluteString, "id": true]) }
            try await reject("invalid_url") { _ = try await f.call("reader.author", ["url": "https://example.invalid/post-123-1", "id": 201]) }
            try await reject("not_ready") { _ = try await f.author(url: Forum.home.appendingPathComponent("post-123-2")) }
            try await reject("stale_authorization") {
                _ = try await f.services.handle("reader.author", ["url": f.url.absoluteString, "id": 201,
                    "accessRevision": f.context.session.accessRevision - 1])
            }
            require(f.memory.profileCalls.isEmpty, "Invalid authors/pages never reach the profile hook")
            f.memory.events.removeAll()
            let author = try await f.author(), profile = map(author["profile"])
            require(profile["member_id"] as? Int == 201 && profile["rank"] as? Int == 7 && profile["readme"] == nil,
                    "Lightweight response uses original profile fields and excludes readme")
            require(author["accessRevision"] as? Int == f.context.session.accessRevision, "Author response has ownership")
            require(f.memory.profileCalls.count == 1 && f.memory.profileCalls[0].1 == false &&
                    f.memory.profileCalls[0].2 == ObjectIdentifier(f.memory.page!), "Author uses existing page without readme")
            _ = try await f.author()
            require(f.memory.profileCalls.count == 1 && f.memory.events.isEmpty, "Cache hit neither repeats request nor emits global events")
            print("PASS author allowlist, page identity, original metadata, cache and no global emissions")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.context.session.cacheThread(ReaderContextFixture.thread(), at: f.url)
            f.memory.cacheOnly = true
            _ = try await f.load()
            let missing = try await f.author()
            require(missing["profile"] is NSNull && f.memory.profileCalls.isEmpty, "Cache-only body never prepares a WebKit page")
            let encoded = Data("{\"member_id\":201,\"member_name\":\"Cached\",\"rank\":3,\"readme\":\"Private profile screen cache\"}".utf8)
            f.context.session.profileStore.update(try JSONDecoder().decode(ForumUserProfile.self, from: encoded))
            let cached = map(try await f.author()["profile"])
            require(cached["member_name"] as? String == "Cached" && cached["readme"] == nil && f.memory.profileCalls.isEmpty,
                    "Cache-only author can expose bounded cached metadata but not readme")
            let own = NativeForumServices.readerAuthorProfile(f.context.session.profiles[201], authorID: 201,
                authorName: "Visible author", ownSignature: "")
            require(own?["ownSignature"] as? String == "" && own?["readme"] == nil,
                    "An explicitly empty personal signature remains distinguishable from missing metadata")
            let minimal = NativeForumServices.readerAuthorProfile(nil, authorID: 201, authorName: "Visible author", ownSignature: "")
            require(minimal?["member_id"] as? Int == 201 && minimal?["ownSignature"] as? String == "",
                    "Known personal signature clearing survives an unavailable rich profile")
            print("PASS cache-only author fallback without a new page or network")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            _ = try await f.load()
            f.memory.profileFailure = true
            let failed = try await f.author()
            require(failed["profile"] is NSNull && f.memory.profileCalls.count == 1, "Profile failure returns no fabricated identity or fallback fetch")
        }
        for invalidation in ["account", "close", "closeAll", "dispose", "refresh", "cancel"] {
            let f = ReaderContextFixture(); defer { f.close() }
            _ = try await f.load()
            let gate = ReaderContextGate()
            f.memory.profileGates[201] = gate
            let task = Task { @MainActor in try await f.author() }
            await gate.untilEntered()
            switch invalidation {
            case "account": f.context.session.observeIdentity(.init(signedIn: true, id: 102, name: "Next", floorsPerPage: 10))
            case "close": f.services.closeReader("123")
            case "closeAll": f.services.closeAllReaders()
            case "dispose": f.services.dispose()
            case "refresh": _ = try await f.load()
            default: task.cancel()
            }
            gate.release()
            try await retired { _ = try await task.value }
            require(f.context.session.profiles[201] == nil && f.memory.profileCalls.count == 1,
                    "Retired author neither returns nor installs a late profile or starts a second fetch")
        }
        print("PASS author failure and account/close/disposal/refresh/cancellation ownership")

        do {
            let f = ReaderContextFixture(observeAuthorStarts: true); defer { f.close() }
            _ = try await f.load()
            let gate = ReaderContextGate()
            f.memory.profileGates[201] = gate
            let first = Task { @MainActor in try await f.author() }
            await gate.untilEntered()
            let second = Task { @MainActor in try await f.author() }
            for _ in 0..<10_000 {
                if f.memory.authorStarts.count == 2 { break }
                await Task.yield()
            }
            require(f.memory.authorStarts.count == 2 && f.memory.profileCalls.count == 1,
                    "Duplicate author waits for the existing per-member profile read")
            gate.release()
            let a = try await first.value, b = try await second.value
            require(map(a["profile"])["member_id"] as? Int == 201 && map(b["profile"])["member_id"] as? Int == 201 &&
                    f.memory.profileCalls.count == 1, "Concurrent same-author consumers reuse one cache result")
            print("PASS concurrent same-author cache reuse")
        }

        do {
            let f = ReaderContextFixture(observeAuthorStarts: true); defer { f.close() }
            _ = try await f.load()
            for id in 201...203 { f.memory.profileGates[id] = ReaderContextGate() }
            var tasks: [Task<[String: Any], Error>] = []
            for id in 201...203 {
                tasks.append(Task { @MainActor in try await f.author(id) })
                await f.memory.profileGates[id]!.untilEntered()
            }
            tasks.append(Task { @MainActor in try await f.author(204) })
            for _ in 0..<10_000 {
                if f.memory.authorStarts.count == 4 { break }
                await Task.yield()
            }
            require(f.memory.authorStarts.count == 4, "Fourth author entered the shared concurrency queue")
            require(f.memory.profileCalls.count == 3 && f.memory.maximumProfiles == 3,
                    "Concurrent authors use the existing session limit of three")
            f.services.closeReader("123")
            f.memory.profileGates.values.forEach { $0.release() }
            for task in tasks { try await retired { _ = try await task.value } }
            require(f.memory.profileCalls.count == 3, "Closing reader cancels queued author before it can issue a request")
            print("PASS per-session concurrency and queued author cancellation before external work")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            _ = try await f.load()
            let args = try await f.beginEdit()
            _ = try await f.call("reader.edit.update", args.merging(["content": "Pending save"]) { _, new in new })
            let gate = ReaderContextGate()
            f.memory.readerGate = gate
            let refresh = Task { @MainActor in try await f.load() }
            await gate.untilEntered()
            try await reject("not_ready") { _ = try await f.author() }
            f.memory.nilPreparedPage = true
            try await reject("not_ready") { _ = try await f.call("reader.edit.save", args) }
            require(f.memory.editWrites == 0 && f.memory.profileCalls.isEmpty,
                    "Author and edit save cannot issue work against a loading page")
            gate.release()
            _ = try await refresh.value
            require(f.memory.editors.last?.content == "Pending save", "Busy-page failure retains the current edit lease")
            print("PASS loading author rejection and retryable edit preparation without a login error")
        }

        do {
            let f = ReaderContextFixture(); defer { f.close() }
            f.memory.nilPreparedPage = true
            try await reject("not_ready") { _ = try await f.beginEdit() }
            try await reject("not_ready") { _ = try await f.call("reader.sendReply", ["url": f.url.absoluteString]) }
            require(f.memory.editWrites == 0 && f.memory.editors.first?.ready == false,
                    "Loading reader cannot be misreported as sign-in-required or start a write")
            f.memory.nilPreparedPage = false
            let old = try await f.beginEdit()
            _ = try await f.call("reader.edit.update", old.merging(["content": "Edited", "title": "Edited title"]) { _, new in new })
            weak var completedEditor = f.memory.editors.last
            f.memory.editors.removeLast()
            let saved = try await f.call("reader.edit.save", old)
            require(saved["accepted"] as? Bool == true && saved["content"] as? String == "Edited" &&
                    saved["editToken"] as? String == old["editToken"] as? String, "Accepted receipt retains the completed lease snapshot")
            require(completedEditor == nil, "Successful save releases native document after constructing its receipt")
            try await reject("stale_editor") { _ = try await f.call("reader.edit.update", old) }
            let current = try await f.beginEdit()
            require(current["editToken"] as? String != old["editToken"] as? String, "Reopening creates a distinct native lease")
            try await reject("stale_editor") { _ = try await f.call("reader.edit.cancel", old) }
            require(f.memory.editors.last?.target != nil && f.memory.editWrites == 1, "Old close cannot erase or re-save replacement")
            weak var disposedEditor = f.memory.editors.last
            f.memory.editors.removeAll()
            f.services.dispose()
            require(disposedEditor == nil, "Service disposal releases retained edit instances")
            try await retired { _ = try await f.call("reader.edit.update", current) }
            print("PASS loading preparation error, completed lease cleanup and safe reopen")
        }
        require(duplicateDocumentEvents == 0,
                "Full reader documents must travel only in correlated method responses; duplicate scenarios: \(duplicateDocumentScenarios.joined(separator: ", "))")
        print("PASS cold/cache/refresh/error/replacement/close/cancel paths emit zero duplicate full-document reader payloads")
    }
}
