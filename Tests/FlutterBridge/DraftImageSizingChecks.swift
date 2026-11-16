import AppKit
import Foundation
import WebKit

@MainActor
private final class SizingGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }
        fatalError("Fixture did not reach the sizing gate")
    }
}

@MainActor
private final class SizingCalls {
    var pages = 0, reads = 0, options = 0, publishes = 0, replies = 0, edits = 0, uploads = 0
    var optionGate: SizingGate?, writeGate: SizingGate?, readGate: SizingGate?
    var publishers: [DiscussionPublisher] = []
    var editors: [ForumInlineEdit] = []
    var original = ""
}

@MainActor
private final class SizingFixture {
    let suite = "cc.seekdesk.qa.draft-image-sizing." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let calls = SizingCalls()
    let first = URL(string: "https://example.invalid/first.png")!
    let second = URL(string: "https://example.invalid/second.png")!
    let topicURL = Forum.home.appendingPathComponent("post-123-1")
    var content: String { "图片正文 🐱\n![first](\(first))\n![second](\(second))\n![again](\(first))" }

    init(signedIn: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        if signedIn { context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10)) }
        else { context.session.observeAccount(false) }
        let calls = calls
        var requests = NativeForumServices.Requests()
        requests.reader = { _, _, _, _ in fatalError("Sizing checks must not read real threads") }
        requests.inbox = { _, _, _, _, _, _ in fatalError("Sizing checks must not read real messages") }
        requests.profile = { _, _, _ in fatalError("Sizing checks must not read a real profile") }
        requests.options = { publisher, _, _ in
            calls.options += 1; calls.publishers.append(publisher)
            if let gate = calls.optionGate { await gate.wait() }
            publisher.phase = .ready
            publisher.categories = [.init(id: "tech", title: "技术")]
            publisher.maxRank = 4
        }
        requests.preparePage = { _, _, session in
            calls.pages += 1
            // An empty nonpersistent page only: never read, navigate, or run JS.
            return ForumWebPage(dataStore: session.dataStore)
        }
        requests.makeEdit = {
            var requests = ForumInlineEdit.Requests()
            requests.read = { _, _ in
                calls.reads += 1
                if let gate = calls.readGate { await gate.wait() }
                let value = try JSONSerialization.data(withJSONObject: ["markdown": calls.original, "title": "Fixture title"])
                return String(decoding: value, as: UTF8.self)
            }
            requests.prepare = { _, _, _ in fatalError("Sizing checks must not prepare or upload images") }
            requests.write = { _, _, _, _ in fatalError("Sizing checks must not write to the forum") }
            let editor = ForumInlineEdit(requests: requests)
            calls.editors.append(editor)
            return editor
        }
        requests.saveEdit = { _, _, authorized in
            calls.edits += 1
            if let gate = calls.writeGate { await gate.wait() }
            _ = authorized()
            return false // Fake result, never prepare images or invoke the forum.
        }
        requests.publish = { publisher, _, _, _ in
            calls.publishes += 1; publisher.sending = true
            let gate = calls.writeGate
            return Task {
                defer { publisher.sending = false }
                if let gate { await gate.wait() }
            }
        }
        requests.sendReply = { _, _, _ in
            calls.replies += 1
            let gate = calls.writeGate
            return Task { if let gate { await gate.wait() } }
        }
        requests.uploadImage = { _, _ in
            calls.uploads += 1
            return URL(string: "https://example.invalid/fake-upload.png")!
        }
        let keys = NativeForumServices.KeyStore(
            configured: { fatalError("Sizing checks must not query Keychain status") },
            read: { fatalError("Sizing checks must not read Keychain") },
            save: { _ in fatalError("Sizing checks must not save Keychain") },
            remove: { fatalError("Sizing checks must not remove Keychain") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys)
        let services = services
        context.accessChanged = { services.invalidate() }
        calls.original = content
        if signedIn {
            context.session.newDiscussion.title = "Preserved title"
            context.session.newDiscussion.content = content
            context.session.newDiscussion.category = "tech"
            context.session.edit(content, for: "123")
        }
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        values.merging(["accessRevision": context.session.accessRevision]) { _, revision in revision }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func selection(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["url": first.absoluteString, "ratio": 0.5, "previewWidth": 800.0, "expectedContent": content]
            .merging(extra) { _, value in value }
    }
    func beginEdit(floor: Int = 0) async throws -> [String: Any] {
        var values: [String: Any] = ["topicID": "123", "url": topicURL.absoluteString, "floor": floor]
        let result = try await call("reader.edit.begin", values)
        values["editToken"] = result["editToken"]
        return values
    }
    func changeAccount(_ id: Int = 202) {
        context.session.observeIdentity(.init(signedIn: true, id: id, name: "Other fixture", floorsPerPage: 10))
    }
    func close() {
        services.dispose(); context.accessChanged = nil
        calls.editors.removeAll(); calls.publishers.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct DraftImageSizingChecks {
    @MainActor
    static func main() async throws {
        func require(_ value: @autoclosure () -> Bool, _ label: String) {
            if !value() { fatalError(label) }
        }
        func sizes(_ value: [String: Any]) -> [[String: Any]] { value["imageSizing"] as? [[String: Any]] ?? [] }
        func urls(_ value: [String: Any]) -> [String] { value["imageURLs"] as? [String] ?? [] }
        func reject(_ code: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected \(code)") }
            catch let error as NativeBridgeError { require(error.code == code, "Expected \(code), got \(error.code)") }
        }
        func cancel(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected cancellation") }
            catch is CancellationError {}
        }

        do {
            let f = SizingFixture(signedIn: false); defer { f.close() }
            let nested = "https://example.invalid/b(c).png"
            let quoted = "https://example.invalid/quoted.png"
            let table = "https://example.invalid/table.png"
            let markdown = [
                "![one](\(f.first))", "![duplicate](\(f.first))", "![nested](<\(nested)> \"title\")",
                "![relative](/uploads/local.png)", "> ![quote](\(quoted))", "| Picture | Other |", "| --- | --- |",
                "| ![table](\(table)) | x |", "`![inline](https://example.invalid/code.png)`", "~~~md",
                "![fence](https://example.invalid/fence.png)", "~~~", "    ![indent](https://example.invalid/indent.png)",
                "![表情](https://example.invalid/sticker.png)", "![reference][ref]", "[ref]: https://example.invalid/reference.png",
                "<img src=\"https://example.invalid/html.png\">", "![http](http://example.invalid/insecure.png)",
                "![userinfo](https://user:pass@example.invalid/private.png)", "\\![escaped](https://example.invalid/escaped.png)",
            ].joined(separator: "\r\n")
            let before = f.context.session.newDiscussion.snapshot
            let result = try await f.call("images.draftReferences", ["content": markdown])
            let expected = [f.first.absoluteString, nested, Forum.home.appendingPathComponent("uploads/local.png").absoluteString, quoted, table]
            require(urls(result) == expected && result["content"] as? String == markdown &&
                    result["accessRevision"] as? Int == f.context.session.accessRevision,
                    "Native enumeration must preserve content, order, canonical relative URLs and supported syntax only")
            require(MarkdownPreviewDocument.imageReferences(markdown, selected: []).isEmpty &&
                    MarkdownPreviewDocument.imageReferences(markdown, selected: [f.first]).count == 2,
                    "Optional enumeration must preserve explicitly empty and filtered reference semantics")
            require(f.context.session.newDiscussion.snapshot == before && f.calls.pages == 0 && f.calls.uploads == 0 &&
                    JSONSerialization.isValidJSONObject(result), "Reference enumeration is codec-safe, local and read-only")
            try await reject("stale_authorization") { _ = try await f.services.handle("images.draftReferences", ["content": markdown]) }
            print("PASS pure native image enumeration matches publication syntax without saving or loading anything")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            let draft = f.context.session.newDiscussion.snapshot
            let initial = try await f.call("discussion.getDraft")
            require(sizes(initial).isEmpty && urls(initial) == [f.first.absoluteString, f.second.absoluteString],
                    "New draft returns explicit empty sizing and deduplicated supported image URLs")
            let first = try await f.call("discussion.setImageSize", f.selection(["previewWidth": 801.4]))
            require(sizes(first).count == 1 && sizes(first)[0]["url"] as? String == f.first.absoluteString &&
                    sizes(first)[0]["ratio"] as? Double == 0.5 && sizes(first)[0]["previewWidth"] as? Int == 801,
                    "Sizing DTO must expose the actual rounded stored preview width")
            _ = try await f.call("discussion.setImageSize", f.selection(["url": f.second.absoluteString, "ratio": 0.25]))
            let reset = try await f.call("discussion.setImageSize", f.selection(["ratio": 1]))
            require(sizes(reset).count == 1 && sizes(reset)[0]["url"] as? String == f.second.absoluteString &&
                    f.context.session.newDiscussion.snapshot == draft && JSONSerialization.isValidJSONObject(reset),
                    "100% removes only its URL; changes preserve original text/title/category/rank")
            require(f.calls.uploads == 0 && f.calls.pages == 0 && f.calls.publishes == 0,
                    "Changing publication size must not upload, navigate or publish")
            print("PASS discussion size patch DTO, stored width rounding and per-URL reset without external effects")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            _ = try await f.call("discussion.setImageSize", f.selection(["ratio": 0.25]))
            _ = try await f.call("reader.setReplyImageSize", f.selection(["topicID": "123", "ratio": 0.75]))
            let post = try await f.call("discussion.updateDraft", ["content": f.content, "imageSizing": []])
            let reply = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": f.content, "imageSizing": []])
            let other = try await f.call("reader.replyDraft", ["topicID": "456"])
            require(sizes(post).first?["ratio"] as? Double == 0.25 && sizes(reply).first?["ratio"] as? Double == 0.75 &&
                    sizes(other).isEmpty && reply["topicID"] as? String == "123" &&
                    reply["accessRevision"] as? Int == f.context.session.accessRevision,
                    "Text autosave cannot replace sizing tables or mix discussion/reply/topic scopes")
            let cleared = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": ""])
            require(!sizes(cleared).isEmpty && urls(cleared).isEmpty,
                    "Ordinary text deletion retains hidden selection for text undo")
            let restored = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": f.content])
            require(sizes(restored).first?["ratio"] as? Double == 0.75 && urls(restored).count == 2,
                    "Restoring text restores the existing URL selection")
            print("PASS scope isolation and text-only autosave retain image sizes through clear/undo")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            _ = try await f.call("reader.setReplyImageSize", f.selection(["topicID": "123"]))
            let before = f.context.session.imageSizing(for: .reply("123")).sizes
            for extra in [[:], ["confirmed": false]] as [[String: Any]] {
                try await reject("confirmation_required") {
                    _ = try await f.call("reader.discardReplyDraft", ["topicID": "123"].merging(extra) { _, value in value })
                }
            }
            require(f.context.session.drafts["123"] == f.content &&
                    f.context.session.imageSizing(for: .reply("123")).sizes == before, "Unconfirmed discard must preserve content and sizing")
            let discarded = try await f.call("reader.discardReplyDraft", ["topicID": "123", "confirmed": true])
            require(discarded["content"] as? String == "" && sizes(discarded).isEmpty && urls(discarded).isEmpty,
                    "Explicit reply discard clears both original text and its sizing scope")
            print("PASS explicit reply discard requires confirmation and clears its sizing scope")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            _ = try await f.call("discussion.setImageSize", f.selection())
            let before = f.context.session.newDiscussion.imageSizing.sizes
            for invalid: Any in [true, false, NSNumber(value: true), "0.5", NSNull(), Double.nan, Double.infinity, -Double.infinity, 0.09, 1.01] {
                try await reject("invalid_image_size") { _ = try await f.call("discussion.setImageSize", f.selection(["ratio": invalid])) }
            }
            for invalid: Any in [true, "800", NSNull(), Double.nan, Double.infinity, 0, -1, 1080.1] {
                try await reject("invalid_image_size") { _ = try await f.call("discussion.setImageSize", f.selection(["previewWidth": invalid])) }
            }
            for invalid in ["http://example.invalid/first.png", "https://user:pass@example.invalid/first.png", "file:///tmp/no.png", "not a url"] {
                try await reject("invalid_url") { _ = try await f.call("discussion.setImageSize", f.selection(["url": invalid])) }
            }
            try await reject("stale_image_draft") { _ = try await f.call("discussion.setImageSize", f.selection(["expectedContent": "Older draft"])) }
            try await reject("unsupported_draft_image") {
                _ = try await f.call("discussion.setImageSize", f.selection(["url": "https://example.invalid/not-in-draft.png"]))
            }
            var missing = f.selection(); missing.removeValue(forKey: "expectedContent")
            try await reject("invalid_arguments") { _ = try await f.call("discussion.setImageSize", missing) }
            require(f.context.session.newDiscussion.imageSizing.sizes == before &&
                    f.context.session.newDiscussion.content == f.content, "All invalid patches must fail without partial mutation")
            _ = try await f.call("discussion.setImageSize", f.selection(["ratio": 0.1, "previewWidth": 1]))
            _ = try await f.call("discussion.setImageSize", f.selection(["ratio": 1, "previewWidth": 1080]))
            print("PASS strict numeric/URL/content/reference validation rejects invalid patches atomically")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            let target = try await f.beginEdit(floor: 3)
            let selection = target.merging(f.selection()) { _, imageValue in imageValue }
            let result = try await f.call("reader.edit.setImageSize", selection)
            require(result["editToken"] as? String == target["editToken"] as? String && result["floor"] as? Int == 3 &&
                    result["topicID"] as? String == "123" && result["canSave"] as? Bool == true &&
                    sizes(result).count == 1 && urls(result).count == 2 && result["content"] as? String == f.content,
                    "Inline sizing must preserve the exact loaded editor and make size-only changes savable")
            require(f.calls.pages == 1 && f.calls.reads == 1 && f.calls.uploads == 0,
                    "Inline image URL must never be interpreted as a topic URL or trigger another page read")
            for patch in [["editToken": UUID().uuidString], ["floor": 4], ["topicID": "456"]] as [[String: Any]] {
                try await reject("stale_editor") {
                    _ = try await f.call("reader.edit.setImageSize", selection.merging(patch) { _, value in value })
                }
            }
            for (method, base) in [("reader.setReplyImageSize", f.selection(["topicID": "123"])), ("reader.edit.setImageSize", selection)] {
                try await reject("invalid_image_size") { _ = try await f.call(method, base.merging(["ratio": true]) { _, value in value }) }
                try await reject("stale_image_draft") { _ = try await f.call(method, base.merging(["expectedContent": "old"]) { _, value in value }) }
                try await reject("unsupported_draft_image") {
                    _ = try await f.call(method, base.merging(["url": "https://example.invalid/missing.png"]) { _, value in value })
                }
            }
            let newer = try await f.beginEdit(floor: 3)
            try await reject("stale_editor") { _ = try await f.call("reader.edit.setImageSize", selection) }
            let cancelled = try await f.call("reader.edit.cancel", newer)
            require(sizes(cancelled).isEmpty && urls(cancelled).isEmpty, "Cancelling inline editing drops its private sizing")
            try await reject("stale_editor") {
                _ = try await f.call("reader.edit.setImageSize", newer.merging(f.selection()) { _, value in value })
            }
            print("PASS inline target tokens, URL namespace and shared setter validation preserve editor identity")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            _ = try await f.call("discussion.setImageSize", f.selection())
            _ = try await f.call("reader.setReplyImageSize", f.selection(["topicID": "123"]))
            let target = try await f.beginEdit()
            let stale = [
                ("discussion.setImageSize", f.args(f.selection())),
                ("reader.setReplyImageSize", f.args(f.selection(["topicID": "123"]))),
                ("reader.edit.setImageSize", f.args(target.merging(f.selection()) { _, value in value })),
                ("reader.discardReplyDraft", f.args(["topicID": "123", "confirmed": true])),
                ("images.draftReferences", f.args(["content": f.content])),
            ]
            f.changeAccount()
            for (method, args) in stale {
                try await reject("stale_authorization") { _ = try await f.services.handle(method, args) }
            }
            let other = try await f.call("discussion.getDraft")
            require(sizes(other).isEmpty && urls(other).isEmpty, "New account cannot observe old draft selections")
            f.changeAccount(101)
            let restoredPost = try await f.call("discussion.getDraft")
            let restoredReply = try await f.call("reader.replyDraft", ["topicID": "123"])
            require(sizes(restoredPost).count == 1 && sizes(restoredReply).count == 1,
                    "Account-owned discussion and reply image selections survive partition restore")
            try await reject("stale_editor") {
                _ = try await f.call("reader.edit.setImageSize", target.merging(f.selection()) { _, value in value })
            }
            print("PASS account/revision isolation with persistent draft sizing and nonpersistent inline tokens")
        }

        for busy in ["options", "picker"] {
            let f = SizingFixture(); defer { f.close() }
            let target = try await f.beginEdit()
            let gate = SizingGate()
            let task: Task<[String: Any], Error>
            if busy == "options" {
                f.calls.optionGate = gate
                task = Task { @MainActor in try await f.call("discussion.loadOptions") }
            } else {
                task = Task { @MainActor in try await f.services.chooseImage(f.args()) { await gate.wait(); return nil } }
            }
            await gate.untilEntered()
            for (method, values) in [
                ("discussion.setImageSize", f.selection()), ("reader.setReplyImageSize", f.selection(["topicID": "123"])),
                ("reader.edit.setImageSize", target.merging(f.selection()) { _, value in value }),
                ("reader.discardReplyDraft", ["topicID": "123", "confirmed": true]),
            ] as [(String, [String: Any])] {
                try await reject(busy == "options" ? "discussion_options_loading" : "uploading") { _ = try await f.call(method, values) }
            }
            let refs = try await f.call("images.draftReferences", ["content": f.content])
            require(urls(refs).count == 2 && f.calls.uploads == 0 && f.context.session.newDiscussion.imageSizing.sizes.isEmpty,
                    "Pure preview enumeration stays available while mutations are blocked before effects")
            gate.release(); _ = try await task.value
            _ = try await f.call("discussion.setImageSize", f.selection())
        }
        print("PASS options/file-picker reservations exclude sizing/discard but permit read-only enumeration")

        for method in ["discussion.publish", "reader.sendReply", "reader.edit.save"] {
            let f = SizingFixture(); defer { f.close() }
            let target = try await f.beginEdit()
            let gate = SizingGate(); f.calls.writeGate = gate
            let values = method == "reader.edit.save" ? target : ["url": f.topicURL.absoluteString, "feeAccepted": true]
            let task = Task { @MainActor in try await f.call(method, values) }
            await gate.untilEntered()
            for (setter, args) in [
                ("discussion.setImageSize", f.selection()), ("reader.setReplyImageSize", f.selection(["topicID": "123"])),
                ("reader.edit.setImageSize", target.merging(f.selection()) { _, value in value }),
                ("reader.discardReplyDraft", ["topicID": "123", "confirmed": true]),
            ] as [(String, [String: Any])] {
                try await reject("writing") { _ = try await f.call(setter, args) }
            }
            gate.release(); _ = try await task.value
            _ = try await f.call("discussion.setImageSize", f.selection())
        }
        print("PASS active publish/reply/inline writes reject size mutations and reply discard")

        do {
            let f = SizingFixture(); defer { f.close() }
            let gate = SizingGate(); f.calls.readGate = gate
            let begin = Task { @MainActor in try await f.beginEdit() }
            await gate.untilEntered()
            let editor = f.calls.editors[0], target = editor.target!
            try await reject("not_ready") {
                _ = try await f.call("reader.edit.setImageSize", f.selection([
                    "topicID": "123", "floor": 0, "editToken": target.id.uuidString,
                ]))
            }
            gate.release(); _ = try await begin.value
            _ = try await f.call("discussion.loadOptions")
            let publisher = f.calls.publishers[0]
            publisher.sending = true
            try await reject("publishing") { _ = try await f.call("discussion.setImageSize", f.selection()) }
            publisher.sending = false
            print("PASS target loading and independent publisher sending state also block sizing")
        }

        do {
            let f = SizingFixture(); defer { f.close() }
            for invalid in ["", "0", "-1", "00123", "1.5", "not-a-topic"] {
                try await reject("invalid_topic") {
                    _ = try await f.call("reader.setReplyImageSize", f.selection(["topicID": invalid]))
                }
                try await reject("invalid_topic") {
                    _ = try await f.call("reader.discardReplyDraft", ["topicID": invalid, "confirmed": true])
                }
            }
            let task = Task { @MainActor in try await f.call("discussion.setImageSize", f.selection()) }
            task.cancel(); try await cancel { _ = try await task.value }
            require(f.context.session.newDiscussion.imageSizing.sizes.isEmpty, "Cancelled entry must not mutate sizing")
            f.services.dispose()
            try await cancel { _ = try await f.call("images.draftReferences", ["content": f.content]) }
            try await cancel { _ = try await f.call("discussion.setImageSize", f.selection()) }
            print("PASS invalid target IDs, cancelled entry and disposed bridge cannot mutate or enumerate drafts")
        }
    }
}
