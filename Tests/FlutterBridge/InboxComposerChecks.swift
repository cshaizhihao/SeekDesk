import Foundation
import WebKit

@MainActor
private final class MessageGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }
        fatalError("Memory-only message request did not reach its gate")
    }
}

@MainActor
private final class MessageMemory {
    var states: [ObjectIdentifier: ForumAccountReader.State] = [:]
    var reads: [(String, Int?, Int, Int)] = []
    var prepares = 0, refreshes = 0
    var sends: [(Int, String, Bool)] = []
    var prepareGate: MessageGate?, sendGate: MessageGate?
    var response = "sent"
}

@MainActor
private final class MessageFixture {
    let suite = "cc.seekdesk.qa.inbox-composer." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let memory = MessageMemory()
    let image = URL(string: "https://example.invalid/message.png")!
    var content: String { "私信 🐱\n![image](\(image.absoluteString))" }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in fatalError("No subscription networking") }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: { [] }, fetchPage: { _ in fatalError("No listing networking") },
            fetchPeople: { _ in fatalError("No people networking") })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Owner", floorsPerPage: 10))
        let memory = memory
        var requests = NativeForumServices.Requests()
        requests.inbox = { state, kind, peer, refresh, revision, _ in
            memory.reads.append((kind, peer, refresh, revision))
            if kind == "conversation", let peer {
                memory.states[ObjectIdentifier(state)] = .messages(peer: peer, [])
            } else if kind == "messages" {
                memory.states[ObjectIdentifier(state)] = .conversations([
                    .init(id: 404, name: "Recent", preview: "Unread fixture", date: "2026-11-15", unread: true)
                ])
            } else { memory.states[ObjectIdentifier(state)] = .notices([], floorsPerPage: 10) }
        }
        requests.inboxState = { memory.states[ObjectIdentifier($0)] ?? .loading }
        requests.markRead = { _, _, _ in fatalError("Composer tests must not consume unread") }
        requests.reader = { _, _, _, _ in fatalError("No reader networking") }
        requests.profile = { _, _, _ in fatalError("No profile networking") }
        requests.prepareMessage = { _, text, authorized in
            memory.prepares += 1
            if let gate = memory.prepareGate { await gate.wait() }
            guard authorized() else { throw CancellationError() }
            return text + "\nPrepared fixture"
        }
        requests.sendMessage = { _, peer, text, markdown in
            memory.sends.append((peer, text, markdown))
            if let gate = memory.sendGate { await gate.wait() }
            return .init(kind: memory.response, message: nil)
        }
        requests.refreshMessageUnread = { _ in memory.refreshes += 1 }
        requests.uploadImage = { _, _ in fatalError("No image upload") }
        let keys = NativeForumServices.KeyStore(configured: { fatalError("No Keychain status query") }, read: { fatalError("No Keychain read") },
            save: { _ in fatalError("No Keychain write") }, remove: { fatalError("No Keychain delete") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys)
        context.accessChanged = { [weak services] in services?.invalidate() }
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        values.merging(["accessRevision": context.session.accessRevision]) { _, fresh in fresh }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func draft(peer: Int = 404, markdown: Bool = true) async throws {
        _ = try await call("inbox.updateDraft", ["peer": peer, "content": content, "markdown": markdown])
    }
    func ready(markdown: Bool = true) async throws {
        try await draft(markdown: markdown)
        _ = try await call("inbox.load", ["kind": "conversation", "peer": 404])
    }
    func sendArgs(markdown: Bool = true) -> [String: Any] {
        ["peer": 404, "expectedContent": content, "markdown": markdown, "expectedMarkdown": markdown]
    }
    func selection(_ values: [String: Any] = [:]) -> [String: Any] {
        ["peer": 404, "expectedContent": content, "url": image.absoluteString, "ratio": 0.5, "previewWidth": 640.0]
            .merging(values) { _, next in next }
    }
    func login(_ owner: Int) {
        context.session.observeIdentity(.init(signedIn: true, id: owner, name: "Owner", floorsPerPage: 10))
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct InboxComposerChecks {
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
    private static func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    @MainActor
    private static func reject(_ code: String, _ operation: () async throws -> Void) async throws {
        do { try await operation(); fatalError("Expected \(code)") }
        catch let error as NativeBridgeError { check(error.code == code, "Expected \(code), received \(error.code)") }
    }

    @MainActor
    static func main() async throws {
        try legacySnapshot()
        try await ownerPersistence()
        try await snapshotContacts()
        try await atomicDraftUpdates()
        try await imageSizing()
        try await expectedSendIntent()
        try await normalAndUnknownSends()
        try await changedWhilePreparing()
        try await changedWhileSending()
        try await changedAccount()
        print("Passed all 10 native inbox composer groups with memory-only transports.")
    }

    private static func legacySnapshot() throws {
        let saved = ForumDraftSnapshot(replies: ["11": "reply"], messages: [404: "private"],
            discussion: .init(title: "title", content: "body", category: "tech", rank: 0), images: [:])
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        old.removeValue(forKey: "messageMarkdown")
        let restored = try JSONDecoder().decode(ForumDraftSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        check(restored.messages[404] == "private" && restored.replies["11"] == "reply" && restored.discussion.title == "title",
              "A v1 partition without messageMarkdown must retain all original drafts")
        check(restored.messageMarkdown[404, default: true], "Legacy messages default to Markdown")
        var next = restored; next.messageMarkdown = [404: false, 405: true]
        let roundtrip = try JSONDecoder().decode(ForumDraftSnapshot.self, from: JSONEncoder().encode(next))
        check(roundtrip.messageMarkdown == next.messageMarkdown, "Per-peer modes survive Codable roundtrip")
        let sparse = try JSONDecoder().decode(ForumDraftSnapshot.self, from: Data("{\"messages\":{\"404\":\"old\"}}".utf8))
        check(sparse.messages[404] == "old" && sparse.images.isEmpty && sparse.messageMarkdown.isEmpty, "Missing new optional fields preserve sparse drafts")
        print("PASS legacy draft decode, existing initializer and per-peer mode roundtrip")
    }

    @MainActor
    private static func ownerPersistence() async throws {
        let f = MessageFixture(); defer { f.close() }
        try await f.draft(markdown: false)
        try await f.draft(peer: 405, markdown: true)
        _ = try await f.call("inbox.setImageSize", f.selection())
        f.login(202)
        check(f.context.session.messageDrafts.isEmpty && f.context.session.messageMarkdown.isEmpty, "Next owner must not inherit content or mode")
        _ = try await f.call("inbox.updateDraft", ["peer": 404, "content": "other", "markdown": true])
        f.login(101)
        check(f.context.session.messageDrafts[404] == f.content && f.context.session.messageMarkdown[404] == false,
              "Original owner retains content and mode")
        let restored = ForumSession(defaults: f.defaults, dataStore: .nonPersistent())
        check(restored.messageDrafts.isEmpty && restored.messageMarkdown.isEmpty, "Unconfirmed session exposes no old drafts")
        restored.observeIdentity(.init(signedIn: true, id: 101, name: "Owner", floorsPerPage: 10))
        check(restored.messageDrafts[404] == f.content && restored.messageMarkdown[404] == false && restored.messageMarkdown[405] == true,
              "Restart restores per-peer content and mode in confirmed owner partition")
        check(restored.imageSizing(for: .message(404)).sizes[f.image]?.ratio == 0.5, "Message image selections survive restart")
        print("PASS owner-isolated content, Markdown mode and image size persistence")
    }

    @MainActor
    private static func snapshotContacts() async throws {
        let f = MessageFixture(); defer { f.close() }
        f.context.session.rememberConversationContacts([
            .init(id: 404, name: "Recent"), .init(id: 405, name: "Older"), .init(id: 405, name: "Duplicate"),
            .init(id: 101, name: "Self"), .init(id: 0, name: "Invalid")
        ], for: 101)
        let list = try await f.call("inbox.load", ["kind": "messages"])
        let recent = rows(list["items"]), older = rows(list["olderItems"])
        check(recent.count == 1 && recent[0]["unread"] as? Bool == true, "Recent unread list must remain unchanged")
        check(older.count == 1 && older[0]["id"] as? Int == 405 && older[0]["unread"] as? Bool == false,
              "Older list excludes recent peers, self, duplicates and invalid IDs")
        check(older[0]["avatar"] as? String == Forum.avatar(405).absoluteString, "Older row carries avatar URL")
        try await f.draft(markdown: false)
        _ = try await f.call("inbox.setImageSize", f.selection())
        let conversation = try await f.call("inbox.load", ["kind": "conversation", "peer": 404])
        check(conversation["draft"] as? String == f.content && conversation["draftMarkdown"] as? Bool == false, "Conversation carries authoritative draft and mode")
        check(rows(conversation["imageSizing"]).count == 1 && conversation["imageURLs"] as? [String] == [f.image.absoluteString], "Conversation carries image selections and references")
        _ = try await f.call("inbox.load", ["kind": "mentions"])
        _ = try await f.call("inbox.load", ["kind": "messages"])
        check(f.memory.reads.allSatisfy { $0.2 == 0 && $0.3 == 0 }, "Ordinary selection keeps refresh/revision tokens unchanged")
        check(f.memory.sends.isEmpty && f.memory.refreshes == 0, "Snapshot assembly must not write or refresh unread")
        check(JSONSerialization.isValidJSONObject(conversation) && JSONSerialization.isValidJSONObject(list), "Snapshots remain codec-safe")
        print("PASS older contacts, conversation metadata, unchanged cache tokens and no unread consumption")
    }

    @MainActor
    private static func atomicDraftUpdates() async throws {
        let f = MessageFixture(); defer { f.close() }
        try await f.draft(markdown: false)
        let revision = f.context.session.messageDraftRevision(for: 404)
        let local = try await f.call("inbox.getDraft", ["peer": 404])
        check(local["content"] as? String == f.content && local["draft"] as? String == f.content &&
              local["draftMarkdown"] as? Bool == false && f.memory.reads.isEmpty,
              "getDraft returns latest local content/mode without loading or selecting an inbox route")
        try await reject("invalid_arguments") {
            _ = try await f.call("inbox.updateDraft", ["peer": 404, "content": "must not apply", "markdown": 1])
        }
        check(f.context.session.messageDrafts[404] == f.content && f.context.session.messageDraftRevision(for: 404) == revision,
              "Invalid mode must reject the entire update before any text mutation")
        let updated = try await f.call("inbox.updateDraft", ["peer": 404, "content": "updated"])
        check(updated["content"] as? String == "updated" && updated["draftMarkdown"] as? Bool == false, "Legacy content-only update retains the selected mode")
        for peer in [0, -1, 101] {
            try await reject("invalid_peer") { _ = try await f.call("inbox.updateDraft", ["peer": peer, "content": "bad"]) }
            try await reject("invalid_peer") { _ = try await f.call("inbox.getDraft", ["peer": peer]) }
        }
        try await reject("invalid_arguments") { _ = try await f.call("inbox.updateDraft", ["peer": true, "content": "bad"]) }
        let before = f.context.session.messageDraftRevision(for: 404)
        f.context.session.messageMarkdown[404] = true
        f.context.session.messageMarkdown[404] = false
        check(f.context.session.messageDraftRevision(for: 404) > before, "Mode A-B-A retains a mutation revision")
        let oldRead = f.args(["peer": 404]); f.login(202)
        try await reject("stale_authorization") { _ = try await f.services.handle("inbox.getDraft", oldRead) }
        let nextOwner = try await f.call("inbox.getDraft", ["peer": 404])
        check(nextOwner["content"] as? String == "" && nextOwner["draftMarkdown"] as? Bool == true,
              "Local draft read cannot expose another owner's content or mode")
        print("PASS local draft reads, atomic mode validation, legacy updates, peer/account boundary and ABA revisions")
    }

    @MainActor
    private static func imageSizing() async throws {
        let f = MessageFixture(); defer { f.close() }
        try await f.draft()
        let first = try await f.call("inbox.setImageSize", f.selection())
        check(rows(first["imageSizing"]).first?["ratio"] as? Double == 0.5 && first["peer"] as? Int == 404,
              "Image selection returns the exact peer and sizing")
        let before = f.context.session.imageSizing(for: .message(404)).sizes
        let invalid: [(String, [String: Any])] = [
            ("stale_image_draft", ["expectedContent": "old"]),
            ("invalid_arguments", ["expectedContent": NSNull()]),
            ("invalid_image_size", ["ratio": true]), ("invalid_image_size", ["ratio": 0.09]),
            ("invalid_image_size", ["ratio": Double.nan]), ("invalid_image_size", ["previewWidth": 1081]),
            ("invalid_url", ["url": "http://example.invalid/message.png"]),
            ("unsupported_draft_image", ["url": "https://example.invalid/absent.png"]),
            ("invalid_peer", ["peer": 101])
        ]
        for (code, change) in invalid { try await reject(code) { _ = try await f.call("inbox.setImageSize", f.selection(change)) } }
        check(f.context.session.imageSizing(for: .message(404)).sizes == before, "Invalid selections must preserve existing choices")
        f.context.session.sendingMessages.insert(404)
        try await reject("writing") { _ = try await f.call("inbox.setImageSize", f.selection()) }
        f.context.session.sendingMessages.remove(404)
        _ = try await f.call("inbox.updateDraft", ["peer": 404, "content": f.content, "imageSizing": []])
        check(f.context.session.imageSizing(for: .message(404)).sizes == before, "Text updates cannot bypass sizing validation with forged arrays")
        let reset = try await f.call("inbox.setImageSize", f.selection(["ratio": 1.0]))
        check(rows(reset["imageSizing"]).isEmpty, "100 percent restores natural size")
        let stale = f.args(f.selection()); f.login(202)
        try await reject("stale_authorization") { _ = try await f.services.handle("inbox.setImageSize", stale) }
        check(f.context.session.imageSizing(for: .message(404)).sizes.isEmpty, "Retired account must not alter new-owner sizing")
        print("PASS message sizing, reset, stale content, invalid values, send lock and account boundary")
    }

    @MainActor
    private static func expectedSendIntent() async throws {
        let f = MessageFixture(); defer { f.close() }
        try await f.draft(markdown: false)
        try await reject("stale_draft") { _ = try await f.call("inbox.send", f.sendArgs()) }
        try await reject("stale_draft") {
            _ = try await f.call("inbox.send", ["peer": 404, "expectedContent": "old", "expectedMarkdown": false])
        }
        try await reject("stale_draft") {
            _ = try await f.call("inbox.send", ["peer": 404, "expectedMarkdown": false, "markdown": true])
        }
        try await reject("invalid_arguments") { _ = try await f.call("inbox.send", ["peer": 404, "expectedMarkdown": 0]) }
        try await reject("not_ready") { _ = try await f.call("inbox.send", f.sendArgs(markdown: false)) }
        check(f.memory.prepares == 0 && f.memory.sends.isEmpty && f.context.session.sendingMessages.isEmpty,
              "Stale click intent fails before any preparation or send")
        print("PASS expectedContent and expectedMarkdown validation before write readiness")
    }

    @MainActor
    private static func normalAndUnknownSends() async throws {
        for markdown in [false, true] {
            let f = MessageFixture(); defer { f.close() }
            try await f.ready(markdown: markdown)
            _ = try await f.call("inbox.setImageSize", f.selection())
            let result = try await f.call("inbox.send", f.sendArgs(markdown: markdown))
            check(result["kind"] as? String == "sent" && f.memory.sends.count == 1, "One accepted send")
            check(f.memory.prepares == (markdown ? 1 : 0) && f.memory.sends[0].2 == markdown, "Plain text bypasses Markdown image preparation")
            check(f.memory.sends[0].1 == f.content + (markdown ? "\nPrepared fixture" : ""), "Exact captured content reaches the transport")
            check(f.context.session.messageDrafts[404] == nil && f.context.session.imageSizing(for: .message(404)).sizes.isEmpty,
                  "Only unchanged acknowledged draft is cleared")
            check(f.context.session.messageMarkdown[404] == markdown && f.memory.refreshes == 1 && f.services.inboxRevision(for: "messages") == 1,
                  "Mode remains selected; accepted send invalidates messages exactly once")
        }
        let f = MessageFixture(); defer { f.close() }
        try await f.ready(); f.memory.response = "unknown"
        _ = try await f.call("inbox.send", f.sendArgs())
        check(f.context.session.messageDrafts[404] == f.content && f.memory.refreshes == 0 && f.services.inboxRevision(for: "messages") == 0,
              "Unknown send preserves draft and does not manufacture a successful invalidation")
        print("PASS plain and Markdown send paths, selected mode retention and unknown-result preservation")
    }

    @MainActor
    private static func changedWhilePreparing() async throws {
        for change in ["text", "mode", "textABA", "modeABA", "size"] {
            let f = MessageFixture(); defer { f.close() }
            try await f.ready()
            let gate = MessageGate(); f.memory.prepareGate = gate
            let task = Task { @MainActor in try await f.call("inbox.send", f.sendArgs()) }
            await gate.untilEntered()
            mutate(f, change)
            let latest = f.context.session.messageDrafts[404], mode = f.context.session.messageMarkdown[404]
            gate.release()
            try await reject("stale_draft") { _ = try await task.value }
            check(f.memory.sends.isEmpty && f.context.session.sendingMessages.isEmpty, "Changed preparation must never reach send or strand the sending flag")
            check(f.context.session.messageDrafts[404] == latest && f.context.session.messageMarkdown[404] == mode, "Changed preparation preserves latest draft and mode")
        }
        print("PASS text/mode/ABA/image mutation during suspended preparation aborts before send")
    }

    @MainActor
    private static func changedWhileSending() async throws {
        for change in ["text", "mode", "textABA", "modeABA", "size"] {
            let f = MessageFixture(); defer { f.close() }
            try await f.ready()
            let gate = MessageGate(); f.memory.sendGate = gate
            let task = Task { @MainActor in try await f.call("inbox.send", f.sendArgs()) }
            await gate.untilEntered()
            mutate(f, change)
            let latest = f.context.session.messageDrafts[404], mode = f.context.session.messageMarkdown[404]
            gate.release()
            let result = try await task.value
            check(result["kind"] as? String == "sent" && f.memory.sends.count == 1, "Acknowledged old message still reports its send result")
            check(f.context.session.messageDrafts[404] == latest && f.context.session.messageMarkdown[404] == mode,
                  "Late acknowledgement must not clear the newer draft, including ABA")
            if change == "size" { check(!f.context.session.imageSizing(for: .message(404)).sizes.isEmpty, "Late send preserves newer image selections") }
            check(f.context.session.sendingMessages.isEmpty, "Sending flag is released")
        }
        print("PASS late success preserves newer content/mode/ABA/image selections")
    }

    @MainActor
    private static func mutate(_ f: MessageFixture, _ change: String) {
        switch change {
        case "text": f.context.session.messageDrafts[404] = "new content"
        case "mode": f.context.session.messageMarkdown[404] = false
        case "textABA": f.context.session.messageDrafts[404] = "temporary"; f.context.session.messageDrafts[404] = f.content
        case "modeABA": f.context.session.messageMarkdown[404] = false; f.context.session.messageMarkdown[404] = true
        case "size": f.context.session.imageSizing(for: .message(404)).set(0.6, previewWidth: 500, for: f.image)
        default: fatalError("Unknown mutation")
        }
    }

    @MainActor
    private static func changedAccount() async throws {
        for phase in ["prepare", "send"] {
            let f = MessageFixture(); defer { f.close() }
            try await f.ready()
            let gate = MessageGate()
            if phase == "prepare" { f.memory.prepareGate = gate } else { f.memory.sendGate = gate }
            let task = Task { @MainActor in try await f.call("inbox.send", f.sendArgs()) }
            await gate.untilEntered()
            f.login(202)
            _ = try await f.call("inbox.updateDraft", ["peer": 404, "content": "next owner", "markdown": false])
            gate.release()
            do { _ = try await task.value; fatalError("Old account returned a current send receipt") }
            catch is CancellationError { check(phase == "prepare", "Cancellation belongs to retired preparation") }
            catch let error as NativeBridgeError { check(error.code == "stale_authorization", "Owner change must reject stale completion") }
            check(f.context.session.messageDrafts[404] == "next owner" && f.context.session.messageMarkdown[404] == false,
                  "Previous owner's completion cannot clear current owner's draft or mode")
            check(f.memory.refreshes == 0 && f.context.session.sendingMessages.isEmpty, "Retired send cannot refresh or lock new owner")
            if phase == "prepare" { check(f.memory.sends.isEmpty, "Retired preparation must not send") }
        }
        print("PASS owner changes during preparation and send preserve the successor partition")
    }
}
