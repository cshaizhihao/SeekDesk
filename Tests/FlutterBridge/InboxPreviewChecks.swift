import Foundation
import WebKit

@MainActor
private final class PreviewGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
    func untilEntered() async {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }
        fatalError("Memory-only preview did not reach its gate")
    }
}

@MainActor
private final class PreviewMemory {
    var calls: [(URL, String)] = []
    var gates: [Int: PreviewGate] = [:]
    var document: NativeInboxPreview.Document?
    var failure: ForumPageError?
    var events: [String] = []

    func fetch(_ url: URL, _ floor: String, _ session: ForumSession) async throws -> NativeInboxPreview.Document {
        calls.append((url, floor))
        let post = Int(Forum.topicID(url)!)!
        // Deliberately ignore Task cancellation until return: the caller must
        // reject a late value even when a transport does not cooperate.
        if let gate = gates[post] { await gate.wait() }
        if let failure { throw failure }
        return document ?? Self.document(url: url, floor: floor)
    }

    static func block(_ kind: String, _ text: String = "") -> ForumBlock {
        ForumBlock(kind: kind, text: text, url: nil, tabs: nil, rows: nil, terminal: nil)
    }

    static func floor(_ id: String, author: Int? = 303, blocks: [ForumBlock]? = nil) -> ForumFloor {
        ForumFloor(id: id, author: "Fixture Author", authorID: author, isAuthor: id == "0", avatar: nil,
            tags: [], date: "2026-11-15", dateLabel: "Today", blocks: blocks ?? [block("text", "Reply \(id)")])
    }

    static func document(url: URL, floor id: String, author: Int? = 303,
                         blocks: [ForumBlock]? = nil) -> NativeInboxPreview.Document {
        let page = Int(url.lastPathComponent.split(separator: "-").last!)!
        let reply = floor(id, author: author, blocks: blocks)
        return .init(thread: ForumThread(title: "Fixture", category: "tech", root: id == "0" ? reply : nil,
            replies: id == "0" ? [] : [reply], pages: [], page: page, replyRestriction: nil), url: url)
    }
}

@MainActor
private final class PreviewFixture {
    let suite = "cc.seekdesk.qa.inbox-preview." + UUID().uuidString
    let defaults: UserDefaults
    let memory = PreviewMemory()
    let context: SeekDeskBridgeContext
    let services: NativeForumServices

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: { [] }, fetchPage: { _ in fatalError("Preview must not load a workspace listing") },
            fetchPeople: { _ in fatalError("Preview must not load people") })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Owner", floorsPerPage: 10))
        let memory = memory
        var requests = NativeForumServices.Requests()
        requests.inboxPreview = { try await memory.fetch($0, $1, $2) }
        requests.reader = { _, _, _, _ in fatalError("Preview must not load a workspace reader") }
        requests.inbox = { _, _, _, _, _, _ in fatalError("Preview must not load or mark the inbox") }
        requests.preparePage = { _, _, _ in fatalError("Preview must not prepare writes") }
        requests.profile = { _, _, _ in fatalError("Preview must not load a profile") }
        services = NativeForumServices(context: context, requests: requests)
        context.accessChanged = { [weak services] in services?.invalidate() }
        context.event = { domain, _ in memory.events.append(domain) }
    }

    func args(_ id: String = UUID().uuidString, post: Int = 123, page: Int = 2, floor: Int = 11,
              author: Int? = 303, force: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["requestID": id, "accessRevision": context.session.accessRevision,
            "url": "https://www.nodeseek.com/post-\(post)-\(page)#\(floor)", "postID": post, "floor": floor,
            "force": force]
        if let author { result["authorID"] = author }
        return result
    }

    func load(_ args: [String: Any]) async throws -> [String: Any] {
        try await services.handle("inbox.preview", args) as? [String: Any] ?? [:]
    }

    func close() {
        services.dispose()
        context.accessChanged = nil
        context.event = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct InboxPreviewChecks {
    private static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    private static func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @MainActor
    private static func rejected(_ fixture: PreviewFixture, _ args: [String: Any], code: String? = nil) async {
        do { _ = try await fixture.load(args); fatalError("Invalid preview was accepted") }
        catch let issue as NativeBridgeError {
            if let code { check(issue.code == code, "Expected \(code), got \(issue.code)") }
        } catch { fatalError("Expected a bridge validation failure, got \(error)") }
    }

    @MainActor
    private static func cancelled(_ task: Task<[String: Any], Error>) async {
        do { _ = try await task.value; fatalError("Retired preview returned a payload") }
        catch is CancellationError {}
        catch { fatalError("Retired preview must be cancellation, got \(error)") }
    }

    @MainActor
    static func main() async throws {
        try await semanticsAndIsolation()
        await invalidTargets()
        try await exactDocumentsAndCaches()
        try await cancellationAndAccess()
        print("Passed all native inbox preview checks using memory-only fetch substitutes.")
    }

    @MainActor
    private static func semanticsAndIsolation() async throws {
        let f = PreviewFixture(); defer { f.close() }
        _ = f.context.workspace.openTopicLink(Forum.home.appendingPathComponent("post-999-1"))
        f.context.session.messageDrafts[404] = "Untouched message draft"
        let workspace = try encoded(f.context.workspaceSnapshot())
        let unread = f.context.session.unread
        let target = URL(string: f.args()["url"] as! String)!
        let table = ForumBlock(kind: "table", text: "", url: nil, tabs: nil, rows: [["Name", "Value"], ["GB5", "430"]], terminal: nil)
        let image = ForumBlock(kind: "image", text: "Fixture", url: URL(string: "https://example.invalid/image.png"),
            tabs: nil, rows: nil, terminal: nil, imageSize: .init(width: 100, height: 200))
        let tabs = ForumBlock(kind: "tabs", text: "", url: nil,
            tabs: [.init(label: "NQ", blocks: [PreviewMemory.block("terminal", "\u{1b}[32m430\u{1b}[0m")])], rows: nil, terminal: nil)
        let disclosure = ForumBlock(kind: "disclosure", text: "Details", url: nil,
            tabs: [.init(label: "", blocks: [PreviewMemory.block("quote", "Quoted")])], rows: nil, terminal: nil)
        let blocks = [PreviewMemory.block("heading", "Heading"), PreviewMemory.block("text", "**Bold** [link](https://example.invalid)"),
                      PreviewMemory.block("code", "print(1)"), table, image, tabs, disclosure]
        f.memory.document = PreviewMemory.document(url: target, floor: "11", blocks: blocks)
        let requestID = "\(f.context.session.accessRevision):1763183500000000:1"
        let value = try await f.load(f.args(requestID))
        check(value["requestID"] as? String == requestID && value["floor"] as? Int == 11 && value["page"] as? Int == 2,
              "Preview must correlate the exact request and target")
        check(value["accessRevision"] as? Int == f.context.session.accessRevision, "Preview must carry the account revision")
        let output = value["blocks"] as? [[String: Any]] ?? []
        check(output.compactMap { $0["kind"] as? String } == blocks.map(\.kind), "Block kinds must retain their semantics")
        check(output[1]["text"] as? String == blocks[1].text && output[3]["rows"] as? [[String]] == table.rows, "Text and tables must remain intact")
        check(map(output[4]["imageSize"])["height"] as? Double == 200, "Image dimensions must remain intact")
        let tab = (output[5]["tabs"] as? [[String: Any]])?.first ?? [:]
        let terminal = (tab["blocks"] as? [[String: Any]])?.first ?? [:]
        check(terminal["terminal"] is [[Any]], "Nested ANSI must be normalized at the DTO boundary")
        check(JSONSerialization.isValidJSONObject(value), "Preview must be codec-safe")
        check(try encoded(f.context.workspaceSnapshot()) == workspace, "Preview must not change reader/workspace selection or tabs")
        check(f.context.session.unread == unread && f.context.session.messageDrafts[404] == "Untouched message draft", "Preview must not consume unread or mutate drafts")
        check(f.context.session.cachedThread(at: target) == nil && f.memory.events.isEmpty, "Preview must not publish state or populate the workspace reader cache")
        check(f.memory.calls.count == 1 && f.memory.calls[0].1 == "11", "Transport must request only the trigger floor")
        do {
            _ = try await f.services.handle("inbox.send", ["peer": 404, "expectedContent": "Outdated click intent",
                "accessRevision": f.context.session.accessRevision])
            fatalError("Stale draft click must not reach a send")
        } catch let error as NativeBridgeError {
            check(error.code == "stale_draft", "Expected atomic stale-draft validation before preparing the conversation")
        }
        check(f.context.session.messageDrafts[404] == "Untouched message draft" && f.context.session.sendingMessages.isEmpty,
              "Rejected send must preserve the newer shared draft and must not start a write")
        for expected in [nil, "Untouched message draft"] as [String?] {
            var sendArgs: [String: Any] = ["peer": 404, "accessRevision": f.context.session.accessRevision]
            if let expected { sendArgs["expectedContent"] = expected }
            do {
                _ = try await f.services.handle("inbox.send", sendArgs)
                fatalError("A fixture with no prepared conversation must not send")
            } catch let error as NativeBridgeError {
                check(error.code == "not_ready", "Matching/absent expectedContent must retain the existing send-readiness contract")
            }
        }
        print("PASS correlated semantic blocks, ANSI normalization, exact floor and no workspace/inbox writes")
    }

    @MainActor
    private static func invalidTargets() async {
        let f = PreviewFixture(); defer { f.close() }
        let urls = ["http://www.nodeseek.com/post-123-2#11", "https://example.invalid/post-123-2#11",
                    "https://user@www.nodeseek.com/post-123-2#11", "https://www.nodeseek.com:444/post-123-2#11",
                    "https://www.nodeseek.com/post-124-2#11", "https://www.nodeseek.com/post-0123-2#11",
                    "https://www.nodeseek.com/post-123-02#11", "https://www.nodeseek.com/post-123-2-extra#11",
                    "https://www.nodeseek.com/post-123-2?x=1#11", "https://www.nodeseek.com/post-123-2#12",
                    "https://www.nodeseek.com/post-123-2#011", "https://www.nodeseek.com/post-123-2#comment-12",
                    "https://www.nodeseek.com/post-%31%32%33-2#11", "https://www.nodeseek.com/post-123-0#11"]
        for url in urls {
            var args = f.args(); args["url"] = url
            await rejected(f, args)
        }
        for (key, value) in [("postID", true as Any), ("floor", -1 as Any), ("floor", 1.5 as Any),
                             ("floor", 9_007_199_254_740_992 as Any), ("authorID", 0 as Any),
                             ("requestID", "" as Any), ("requestID", "bad\nID" as Any),
                             ("requestID", String(repeating: "x", count: 129) as Any), ("force", 1 as Any)] {
            var args = f.args(); args[key] = value
            await rejected(f, args)
        }
        await rejected(f, f.args(page: 2, floor: 0))
        var stale = f.args(); stale["accessRevision"] = -1
        await rejected(f, stale, code: "stale_authorization")
        check(f.memory.calls.isEmpty, "Invalid targets must fail before any read")
        print("PASS strict scheme/host/post/page/floor/fragment/request/revision validation without transport")
    }

    @MainActor
    private static func exactDocumentsAndCaches() async throws {
        let f = PreviewFixture(); defer { f.close() }
        let args = f.args(force: true), url = URL(string: args["url"] as! String)!
        for document in [
            PreviewMemory.document(url: Forum.home.appendingPathComponent("post-124-2"), floor: "11"),
            PreviewMemory.document(url: Forum.home.appendingPathComponent("post-123-1"), floor: "11"),
            PreviewMemory.document(url: url, floor: "12"), PreviewMemory.document(url: url, floor: "11", author: 404),
            PreviewMemory.document(url: url, floor: "11", author: nil), PreviewMemory.document(url: url, floor: "11", blocks: [])
        ] {
            f.memory.document = document
            await rejected(f, args)
        }
        let reply = PreviewMemory.floor("11")
        f.memory.document = .init(thread: ForumThread(title: "", category: "", root: nil, replies: [reply, reply], pages: [], page: 2, replyRestriction: nil), url: url)
        await rejected(f, args, code: "preview_unavailable")
        f.memory.document = .init(thread: ForumThread(title: "", category: "", root: nil, replies: [], pages: [], page: 2, replyRestriction: nil), url: url)
        await rejected(f, args, code: "preview_unavailable")
        f.memory.document = .init(thread: ForumThread(title: "", category: "", root: nil, replies: [reply], pages: [], page: 1, replyRestriction: nil), url: url)
        await rejected(f, args, code: "preview_unavailable")
        f.memory.document = nil
        _ = try await f.load(f.args("cache-one"))
        let reads = f.memory.calls.count
        let cached = try await f.load(f.args("cache-two"))
        check(f.memory.calls.count == reads && cached["requestID"] as? String == "cache-two", "Cache must reuse content with the current correlation ID")
        _ = try await f.load(f.args("forced", force: true))
        check(f.memory.calls.count == reads + 1, "Force must bypass the preview cache")
        f.context.session.invalidateThread("123")
        _ = try await f.load(f.args("after-edit"))
        check(f.memory.calls.count == reads + 2, "Thread writes must invalidate preview content")
        f.context.session.cacheThread(PreviewMemory.document(url: url, floor: "11").thread, at: url)
        _ = try await f.load(f.args("reader-cache", author: nil))
        check(f.memory.calls.count == reads + 2, "Fresh exact reader cache may satisfy preview without navigation")
        _ = try await f.load(f.args("reader-cache-force", author: nil, force: true))
        check(f.memory.calls.count == reads + 3, "Force must bypass the reader cache too")
        var clock = Date(timeIntervalSince1970: 10_000)
        let preview = NativeInboxPreview(session: f.context.session, fetch: { try await f.memory.fetch($0, $1, $2) }, now: { clock })
        defer { preview.dispose() }
        _ = try await preview.load(f.args("ttl-one", post: 222))
        let ttlReads = f.memory.calls.count
        clock.addTimeInterval(119)
        _ = try await preview.load(f.args("ttl-two", post: 222))
        check(f.memory.calls.count == ttlReads, "Preview cache must remain usable inside its lifetime")
        clock.addTimeInterval(2)
        _ = try await preview.load(f.args("ttl-three", post: 222))
        check(f.memory.calls.count == ttlReads + 1, "Preview cache must expire")
        for post in 300...308 { _ = try await preview.load(f.args(post: post)) }
        let lruReads = f.memory.calls.count
        _ = try await preview.load(f.args(post: 300))
        check(f.memory.calls.count == lruReads + 1, "Preview cache must evict beyond eight entries")
        let bigArgs = f.args("big-one", post: 500)
        let bigURL = URL(string: bigArgs["url"] as! String)!
        f.memory.document = PreviewMemory.document(url: bigURL, floor: "11", blocks: [PreviewMemory.block("text", String(repeating: "x", count: 1_100_000))])
        _ = try await preview.load(bigArgs)
        let bigReads = f.memory.calls.count
        _ = try await preview.load(f.args("big-two", post: 500))
        check(f.memory.calls.count == bigReads + 1, "Oversized previews may display but must not enter the 2 MiB cache")
        f.memory.document = nil
        print("PASS missing/duplicate/hidden-equivalent floor rejection, author/page binding, bounded caches and force/write/age invalidation")
    }

    @MainActor
    private static func cancellationAndAccess() async throws {
        let f = PreviewFixture(); defer { f.close() }
        let a = PreviewGate(), b = PreviewGate()
        f.memory.gates[400] = a; f.memory.gates[401] = b
        let first = Task { @MainActor in try await f.load(f.args("first", post: 400)) }
        await a.untilEntered()
        let second = Task { @MainActor in try await f.load(f.args("second", post: 401)) }
        await b.untilEntered()
        let staleCancel = map(try await f.services.handle("inbox.cancelPreview", ["requestID": "first", "accessRevision": f.context.session.accessRevision]))
        check(staleCancel["cancelled"] as? Bool == false, "Old cancellation must not cancel the new selection")
        a.release(); await cancelled(first)
        b.release()
        let latest = try await second.value
        check(latest["requestID"] as? String == "second", "Latest preview must survive stale cancellation")
        let c = PreviewGate(); f.memory.gates[402] = c
        let explicit = Task { @MainActor in try await f.load(f.args("explicit", post: 402)) }
        await c.untilEntered()
        let result = map(try await f.services.handle("inbox.cancelPreview", ["requestID": "explicit", "accessRevision": f.context.session.accessRevision]))
        check(result["cancelled"] as? Bool == true, "Explicit matching cancellation must retire its request")
        c.release(); await cancelled(explicit)
        let d = PreviewGate(); f.memory.gates[403] = d
        let outer = Task { @MainActor in try await f.load(f.args("outer", post: 403)) }
        await d.untilEntered(); outer.cancel(); d.release(); await cancelled(outer)
        let e = PreviewGate(); f.memory.gates[404] = e
        let account = Task { @MainActor in try await f.load(f.args("account", post: 404)) }
        await e.untilEntered()
        f.context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10))
        e.release(); await cancelled(account)
        f.memory.gates.removeAll()
        let after = try await f.load(f.args("new-owner", post: 401))
        check(after["accessRevision"] as? Int == f.context.session.accessRevision && f.memory.calls.filter({ Forum.topicID($0.0) == "401" }).count == 2,
              "New account must not reuse the previous owner's preview cache")
        let edit = PreviewGate(); f.memory.gates[405] = edit
        let invalidated = Task { @MainActor in try await f.load(f.args("write", post: 405)) }
        await edit.untilEntered(); f.context.session.invalidateThread("405"); edit.release(); await cancelled(invalidated)
        let late = PreviewGate(); f.memory.gates[406] = late
        let closing = Task { @MainActor in try await f.load(f.args("closing", post: 406)) }
        await late.untilEntered(); f.services.dispose(); late.release(); await cancelled(closing)
        print("PASS overlapping selections, explicit/outer cancellation, access changes, in-flight edits and disposal")
    }
}
