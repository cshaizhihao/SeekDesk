import AppKit
import Foundation
import WebKit

@MainActor
private final class DiscussionGate {
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
        fatalError("Fixture operation did not reach its gate")
    }
}

@MainActor
private final class DiscussionCalls {
    var options = 0, publishes = 0, replies = 0, pages = 0, uploads = 0
    var publishers: [DiscussionPublisher] = []
    var drafts: [NewDiscussionDraft] = []
    var phase: DiscussionPublisher.Phase = .ready
    var optionsHook: (@MainActor (DiscussionPublisher, ForumSession, NewDiscussionDraft) async -> Void)?
    var optionsGate: DiscussionGate?, writeGate: DiscussionGate?, uploadGate: DiscussionGate?
    var accepted = false
    var submissionMessage: String? = "没有收到发布结果。请先检查帖子是否已经出现，再决定是否重发。草稿已保留。"
}

@MainActor
private final class DiscussionFixture {
    let suite = "cc.seekdesk.qa.discussion-options." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let calls = DiscussionCalls()
    let topicURL = Forum.home.appendingPathComponent("post-123-1")
    let image = URL(string: "https://example.invalid/preserved-image.png")!

    init(signedIn: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        if signedIn { context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10)) }
        else { context.session.observeAccount(false) }
        let calls = calls
        var requests = NativeForumServices.Requests()
        requests.options = { publisher, session, draft in
            calls.options += 1
            calls.publishers.append(publisher)
            calls.drafts.append(draft)
            if let gate = calls.optionsGate { await gate.wait() }
            if let hook = calls.optionsHook { await hook(publisher, session, draft); return }
            publisher.phase = calls.phase
            publisher.categories = [.init(id: "tech", title: "技术")]
            publisher.maxRank = 4
            // Production load clears its current read message. This fixture
            // verifies the bridge retains submission warnings independently.
            publisher.message = nil
        }
        requests.preparePage = { _, _, session in
            calls.pages += 1
            // Empty nonpersistent page only: no read, navigation, or JS.
            return ForumWebPage(dataStore: session.dataStore)
        }
        requests.sendReply = { _, _, _ in
            calls.replies += 1
            let gate = calls.writeGate
            return Task { if let gate { await gate.wait() } }
        }
        requests.publish = { publisher, _, _, accepted in
            calls.publishes += 1
            publisher.sending = true
            let gate = calls.writeGate
            return Task {
                defer { publisher.sending = false }
                if let gate { await gate.wait() }
                publisher.message = calls.submissionMessage
                if calls.accepted { accepted(nil) }
            }
        }
        requests.uploadImage = { _, _ in
            calls.uploads += 1
            if let gate = calls.uploadGate { await gate.wait() }
            return URL(string: "https://example.invalid/fake-upload.png")!
        }
        requests.reader = { _, _, _, _ in fatalError("Options checks must not read a real thread") }
        requests.inbox = { _, _, _, _, _, _ in fatalError("Options checks must not read a real inbox") }
        requests.profile = { _, _, _ in fatalError("Options checks must not read a real profile") }
        requests.makeEdit = { fatalError("Blocked edit must not create a real editor") }
        requests.saveEdit = { _, _, _ in fatalError("Options checks must not save a real editor") }
        let keyStore = NativeForumServices.KeyStore(
            configured: { fatalError("Options checks must not query Keychain status") },
            read: { "fixture-only-image-key" },
            save: { _ in fatalError("Options checks must not save Keychain") },
            remove: { fatalError("Options checks must not remove Keychain") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keyStore)
        let services = services
        context.accessChanged = { services.invalidate() }
        if signedIn {
            context.session.newDiscussion.title = "Preserved title"
            context.session.newDiscussion.content = "Preserved Markdown **body**"
            context.session.newDiscussion.category = "tech"
            context.session.newDiscussion.imageSizing.set(0.5, previewWidth: 640, for: image)
            context.session.edit("Fixture reply", for: "123")
        }
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        values.merging(["accessRevision": context.session.accessRevision]) { _, revision in revision }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func changeAccount(_ id: Int = 202) {
        context.session.observeIdentity(.init(signedIn: true, id: id, name: "Other fixture", floorsPerPage: 10))
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        calls.optionsHook = nil
        calls.publishers.removeAll()
        calls.drafts.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct DiscussionOptionsChecks {
    @MainActor
    static func main() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { fatalError(label) }
        }
        func reject(_ code: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected \(code)") }
            catch let error as NativeBridgeError { require(error.code == code, "Expected \(code), got \(error.code)") }
        }
        func cancel(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected cancellation") }
            catch is CancellationError {}
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let before = f.context.session.newDiscussion.snapshot
            let sizes = f.context.session.newDiscussion.imageSizing.sizes
            let phases: [(DiscussionPublisher.Phase, String)] = [
                (.loading, "loading"), (.ready, "ready"), (.signedOut, "signedOut"),
                (.verification, "verification"), (.unavailable, "unavailable"),
            ]
            for (phase, name) in phases {
                f.calls.phase = phase
                let result = try await f.call("discussion.loadOptions")
                require(result["phase"] as? String == name && result["ready"] as? Bool == (name == "ready"),
                        "All publisher phases must have stable wire names and compatible ready")
                require(result["verificationURL"] as? String == DiscussionScript.page.absoluteString,
                        "Verification must target the native new-discussion page")
                require(result["accessRevision"] as? Int == f.context.session.accessRevision &&
                        result["lastSubmissionMessage"] is NSNull && JSONSerialization.isValidJSONObject(result),
                        "Options snapshot must be revisioned, nullable and codec-safe")
            }
            require(f.context.session.newDiscussion.snapshot == before &&
                    f.context.session.newDiscussion.imageSizing.sizes == sizes && f.calls.publishes == 0,
                    "Permission reads must preserve text/image sizing and never publish")
            print("PASS complete publisher phase/verification DTO and draft-preserving reads")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let draft = f.context.session.newDiscussion
            draft.category = "removed"; draft.rank = 30
            let title = draft.title, content = draft.content, sizes = draft.imageSizing.sizes
            f.calls.optionsHook = { publisher, _, draft in
                publisher.phase = .ready
                publisher.categories = [.init(id: "tech", title: "技术")]
                publisher.maxRank = 4
                draft.category = ""; draft.rank = 0
            }
            let corrected = try await f.call("discussion.loadOptions")
            require(corrected["category"] as? String == "" && corrected["rank"] as? Int == 0 &&
                    corrected["maxRank"] as? Int == 4, "Snapshot must return native-corrected metadata")
            require(draft.title == title && draft.content == content && draft.imageSizing.sizes == sizes,
                    "Metadata correction must leave the exact existing draft and image sizing intact")
            print("PASS corrected category/rank reaches DTO without replacing text or sizing")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let old = f.args()
            f.changeAccount()
            try await reject("stale_authorization") { _ = try await f.services.handle("discussion.loadOptions", old) }
            try await reject("stale_authorization") { _ = try await f.services.handle("discussion.loadOptions", [:]) }
            require(f.calls.options == 0, "Missing/stale revisions must not start a permissions read")
            let guest = DiscussionFixture(signedIn: false); defer { guest.close() }
            guest.calls.phase = .signedOut
            let result = try await guest.call("discussion.loadOptions")
            require(result["phase"] as? String == "signedOut" && guest.calls.options == 1,
                    "A current guest revision may discover authentication without being allowed to publish")
            print("PASS stale options requests rejected before work and current guest discovery allowed")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let gate = DiscussionGate(); f.calls.optionsGate = gate
            let task = Task { @MainActor in try await f.call("discussion.loadOptions") }
            await gate.untilEntered()
            let pending = try await f.call("discussion.getDraft")
            require(pending["phase"] as? String == "loading" && pending["ready"] as? Bool == false,
                    "Pending permission read must not expose stale ready state")
            let topic: [String: Any] = ["url": f.topicURL.absoluteString, "topicID": "123", "floor": 0]
            for (method, values) in [
                ("discussion.loadOptions", [:]), ("discussion.publish", ["feeAccepted": true]),
                ("discussion.discard", ["confirmed": true]), ("reader.sendReply", topic),
                ("reader.edit.begin", topic), ("reader.edit.save", topic), ("reader.edit.cancel", topic),
            ] as [(String, [String: Any])] {
                try await reject("discussion_options_loading") { _ = try await f.call(method, values) }
            }
            var pickerOpened = false
            try await reject("discussion_options_loading") {
                _ = try await f.services.chooseImage(f.args()) { pickerOpened = true; return nil }
            }
            require(!pickerOpened && f.calls.options == 1 && f.calls.pages == 0 &&
                    f.calls.publishes == 0 && f.calls.replies == 0 && f.calls.uploads == 0,
                    "Options reservation must block competitors before any effect")
            _ = try await f.call("discussion.updateDraft", ["content": "New local text while waiting"])
            gate.release(); _ = try await task.value
            require(f.context.session.newDiscussion.content == "New local text while waiting",
                    "Local draft writes remain available without being replaced by an options result")
            f.calls.optionsGate = nil
            _ = try await f.call("discussion.loadOptions")
            print("PASS options single-flight, reverse editor/media guards and local draft preservation")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let picker = DiscussionGate(), upload = DiscussionGate(); f.calls.uploadGate = upload
            let task = Task { @MainActor in
                try await f.services.chooseImage(f.args()) {
                    await picker.wait(); return URL(fileURLWithPath: "/fixture/not-read.png")
                }
            }
            await picker.untilEntered()
            try await reject("uploading") { _ = try await f.call("discussion.loadOptions") }
            picker.release(); await upload.untilEntered()
            try await reject("uploading") { _ = try await f.call("discussion.loadOptions") }
            require(f.calls.options == 0, "Picker and upload must block before options changes publisher state")
            upload.release(); _ = try await task.value
            _ = try await f.call("discussion.loadOptions")
            print("PASS options reload waits for both file selection and upload completion")
        }

        for method in ["discussion.publish", "reader.sendReply"] {
            let f = DiscussionFixture(); defer { f.close() }
            let gate = DiscussionGate(); f.calls.writeGate = gate
            let task = Task { @MainActor in
                try await f.call(method, ["url": f.topicURL.absoluteString, "feeAccepted": true])
            }
            await gate.untilEntered()
            try await reject("writing") { _ = try await f.call("discussion.loadOptions") }
            require(f.calls.options == 0, "Active editor write must retain its prepared page")
            gate.release(); _ = try await task.value
            _ = try await f.call("discussion.loadOptions")
        }
        print("PASS publish and other editor writes exclude options reload until completion")

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let warning = f.calls.submissionMessage!
            let failed = try await f.call("discussion.publish")
            require(failed["accepted"] as? Bool == false && failed["lastSubmissionMessage"] as? String == warning,
                    "Unknown submission outcome must return its durable warning")
            for phase in [DiscussionPublisher.Phase.verification, .unavailable, .ready] {
                f.calls.phase = phase
                let reloaded = try await f.call("discussion.loadOptions")
                require(reloaded["message"] is NSNull && reloaded["lastSubmissionMessage"] as? String == warning &&
                        f.calls.publishes == 1, "Permission retry must not erase ambiguity or auto-publish")
            }
            f.calls.submissionMessage = "NodeSeek 未接受本次发布。草稿已保留。"
            let rejected = try await f.call("discussion.publish")
            require(rejected["lastSubmissionMessage"] as? String == f.calls.submissionMessage,
                    "A later explicit submission replaces the previous outcome message")
            f.calls.accepted = true
            let accepted = try await f.call("discussion.publish")
            require(accepted["lastSubmissionMessage"] is NSNull, "Success clears prior uncertainty")
            f.calls.accepted = false
            _ = try await f.call("discussion.publish")
            let discarded = try await f.call("discussion.discard", ["confirmed": true])
            require(discarded["lastSubmissionMessage"] is NSNull && discarded["message"] is NSNull,
                    "Confirmed discard clears prior outcome")
            _ = try await f.call("discussion.publish")
            f.changeAccount()
            let other = try await f.call("discussion.getDraft")
            require(other["lastSubmissionMessage"] is NSNull, "Submission warnings must not cross accounts")
            print("PASS unknown submission warning survives permission retries with explicit lifecycle clearing")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let gate = DiscussionGate()
            let original = f.context.session.newDiscussion
            let saved = original.snapshot, sizes = original.imageSizing.sizes
            let oldRevision = f.context.session.accessRevision
            f.calls.optionsHook = { publisher, session, draft in
                if f.calls.options == 1 {
                    await gate.wait()
                    // A stale completion can still touch its captured objects;
                    // these must already be detached from the current owner.
                    publisher.phase = .unavailable
                    publisher.message = "Old owner only"
                    draft.title = "Stale detached title"
                } else {
                    publisher.phase = .ready
                    publisher.categories = [.init(id: "tech", title: "技术")]
                    publisher.maxRank = 4
                }
            }
            let task = Task { @MainActor in try await f.call("discussion.loadOptions") }
            await gate.untilEntered()
            f.changeAccount()
            let other = f.context.session.newDiscussion
            other.title = "Other owner title"; other.content = "Other owner body"
            try await reject("discussion_options_loading") { _ = try await f.call("discussion.loadOptions") }
            gate.release()
            let result = try await task.value
            require(f.calls.options == 2 && f.calls.publishers[0] !== f.calls.publishers[1] &&
                    f.calls.drafts[0] === original && f.calls.drafts[1] === other,
                    "Identity retry must use fresh publisher and the new owner's own draft")
            require(result["phase"] as? String == "ready" && result["title"] as? String == "Other owner title" &&
                    result["content"] as? String == "Other owner body" && result["message"] is NSNull &&
                    result["lastSubmissionMessage"] is NSNull &&
                    result["accessRevision"] as? Int == f.context.session.accessRevision &&
                    f.context.session.accessRevision != oldRevision,
                    "Never label old publisher data or old draft contents with the new revision")
            f.changeAccount(101)
            require(f.context.session.newDiscussion.snapshot == saved &&
                    f.context.session.newDiscussion.imageSizing.sizes == sizes,
                    "Detached old load must not corrupt the original owner's persisted draft")
            print("PASS identity retry keeps the reservation and isolates publisher/draft partitions")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            f.calls.optionsHook = { _, session, _ in
                session.observeIdentity(.init(signedIn: true, id: 200 + f.calls.options, name: "Discovered", floorsPerPage: 10))
            }
            try await reject("stale_authorization") { _ = try await f.call("discussion.loadOptions") }
            require(f.calls.options == 3, "Repeated identity changes must have a bounded retry count")
            f.calls.optionsHook = nil
            let result = try await f.call("discussion.loadOptions")
            require(result["ready"] as? Bool == true, "Exhausted retries must release their reservation")
            print("PASS bounded identity discovery retry and failure lock release")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let gate = DiscussionGate(); f.calls.optionsGate = gate
            let task = Task { @MainActor in try await f.call("discussion.loadOptions") }
            await gate.untilEntered()
            task.cancel(); gate.release()
            try await cancel { _ = try await task.value }
            f.calls.optionsGate = nil
            let result = try await f.call("discussion.loadOptions")
            require(result["ready"] as? Bool == true, "Cancelled read must release its reservation")
            print("PASS cancelled options request cannot return a usable snapshot and releases its lock")
        }

        do {
            let f = DiscussionFixture(); defer { f.close() }
            let gate = DiscussionGate(); f.calls.optionsGate = gate
            let task = Task { @MainActor in try await f.call("discussion.loadOptions") }
            await gate.untilEntered()
            f.services.dispose(); gate.release()
            try await cancel { _ = try await task.value }
            try await cancel { _ = try await f.call("discussion.loadOptions") }
            print("PASS disposed service rejects pending and subsequent options results")
        }
    }
}
