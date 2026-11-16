import AppKit
import Foundation
import WebKit

@MainActor
private final class UploadGate {
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
private final class UploadCalls {
    var prepare = 0, replies = 0, publishes = 0, saves = 0, uploads = 0
    var prepareGate: UploadGate?
    var writeGate: UploadGate?
    var uploadGate: UploadGate?
    var uploadFails = false
    var key: String? = "fixture-only-file-key"
    var keyReads = 0
    var keyGate: UploadGate?
    var keyError: Error?
    var keyReadCancelled = false
}

@MainActor
private final class UploadFixture {
    let suite = "cc.seekdesk.qa.upload-lifecycle." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let calls = UploadCalls()
    let file = URL(fileURLWithPath: "/fixture/not-read-or-uploaded.png")
    let uploaded = URL(string: "https://example.invalid/fixture.png")!
    let topicURL = Forum.home.appendingPathComponent("post-123-1")

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10))
        let calls = calls, uploaded = uploaded
        var requests = NativeForumServices.Requests()
        requests.preparePage = { _, _, session in
            calls.prepare += 1
            if let gate = calls.prepareGate { await gate.wait() }
            // No read/load/navigation is invoked on this nonpersistent page.
            return ForumWebPage(dataStore: session.dataStore)
        }
        requests.sendReply = { _, _, _ in
            calls.replies += 1
            let gate = calls.writeGate
            return Task { if let gate { await gate.wait() } }
        }
        requests.publish = { publisher, _, _, accepted in
            calls.publishes += 1
            let gate = calls.writeGate
            publisher.sending = true
            return Task {
                defer { publisher.sending = false }
                if let gate { await gate.wait() }
                accepted(nil)
            }
        }
        requests.saveEdit = { _, _, authorized in
            calls.saves += 1
            if let gate = calls.writeGate { await gate.wait() }
            return authorized()
        }
        requests.makeEdit = {
            var editorRequests = ForumInlineEdit.Requests()
            editorRequests.read = { _, _ in #"{"markdown":"Fixture original","title":"Fixture title"}"# }
            editorRequests.prepare = { _, markdown, authorized in
                guard authorized() else { throw CancellationError() }
                return markdown
            }
            editorRequests.write = { _, _, _, _ in fatalError("Upload lifecycle tests must use the fake saveEdit") }
            return ForumInlineEdit(requests: editorRequests)
        }
        requests.uploadImage = { _, key in
            precondition(key == calls.key, "File upload must receive the injected key")
            calls.uploads += 1
            if let gate = calls.uploadGate { await gate.wait() }
            if calls.uploadFails { throw NodeImageError.connection }
            return uploaded
        }
        let keys = NativeForumServices.KeyStore(
            configured: { calls.key != nil },
            read: {
                calls.keyReads += 1
                let key = calls.key, error = calls.keyError
                if let gate = calls.keyGate { await gate.wait() }
                calls.keyReadCancelled = Task.isCancelled
                if let error { throw error }
                return key
            },
            save: { calls.key = $0 },
            remove: { calls.key = nil })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys)
        let services = services
        context.accessChanged = { services.invalidate() }
        context.session.newDiscussion.title = "Fixture discussion"
        context.session.newDiscussion.content = "Fixture body"
        context.session.newDiscussion.category = "tech"
        context.session.edit("Fixture reply", for: "123")
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        values.merging(["accessRevision": context.session.accessRevision]) { _, revision in revision }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func beginEdit() async throws -> [String: Any] {
        var values: [String: Any] = ["topicID": "123", "url": topicURL.absoluteString, "floor": 0]
        let snapshot = try await call("reader.edit.begin", values)
        values["editToken"] = snapshot["editToken"]
        return values
    }
    func isUploading() async throws -> Bool { try await call("discussion.getDraft")["uploading"] as? Bool == true }
    func changeAccount() {
        context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other fixture", floorsPerPage: 10))
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct UploadLifecycleChecks {
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
            let f = UploadFixture(); defer { f.close() }
            let picker = UploadGate()
            let task = Task { @MainActor in try await f.services.chooseImage(f.args()) { await picker.wait(); return nil } }
            await picker.untilEntered()
            let uploading = try await f.isUploading()
            require(uploading, "Choosing a file must reserve the media operation before upload")
            for (method, values) in [
                ("discussion.publish", ["feeAccepted": true] as [String: Any]),
                ("discussion.discard", ["confirmed": true]),
                ("reader.sendReply", ["url": f.topicURL.absoluteString]),
                ("reader.edit.save", ["url": f.topicURL.absoluteString]),
                ("reader.edit.cancel", ["url": f.topicURL.absoluteString]),
            ] {
                try await reject("uploading") { _ = try await f.call(method, values) }
            }
            var secondPickerOpened = false
            try await reject("uploading") {
                _ = try await f.services.chooseImage(f.args()) { secondPickerOpened = true; return nil }
            }
            require(!secondPickerOpened && f.calls.prepare == 0 && f.calls.uploads == 0,
                    "Entry guards must reject before preparing pages, opening another picker, or uploading")
            _ = try await f.call("discussion.updateDraft", ["content": "Newer local draft"])
            _ = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": "Newer local reply"])
            require(f.context.session.newDiscussion.content == "Newer local draft" &&
                    f.context.session.drafts["123"] == "Newer local reply", "Local autosave stays available")
            picker.release()
            let cancelled = try await task.value
            require(cancelled["cancelled"] as? Bool == true, "Cancel is reported without upload")
            let afterCancel = try await f.isUploading()
            require(!afterCancel, "Picker cancellation releases media busy state")
            f.context.session.newDiscussion.category = "inside"
            try await reject("confirmation_required") { _ = try await f.call("discussion.publish") }
            require(f.calls.publishes == 0, "Fee confirmation remains separate from upload errors")
            print("PASS picker reservation, five entry guards, autosave, cancellation and distinct fee confirmation")
        }

        do {
            let f = UploadFixture(); defer { f.close() }
            let gate = UploadGate(); f.calls.uploadGate = gate
            let task = Task { @MainActor in try await f.services.chooseImage(f.args()) { f.file } }
            await gate.untilEntered()
            try await reject("uploading") { _ = try await f.call("discussion.publish") }
            gate.release()
            let uploaded = try await task.value
            require(uploaded["markdown"] as? String == "![image](\(f.uploaded.absoluteString))", "Only completed upload returns insertion")
            f.calls.uploadGate = nil
            f.calls.uploadFails = true
            do { _ = try await f.services.chooseImage(f.args()) { f.file }; fatalError("Expected fake upload failure") }
            catch is NodeImageError {}
            let afterFailure = try await f.isUploading()
            require(!afterFailure, "Upload error releases busy state")
            f.calls.uploadFails = false
            _ = try await f.services.chooseImage(f.args()) { f.file }
            require(f.calls.uploads == 3, "Upload can retry after failure")
            print("PASS upload result ownership, failure cleanup and retry without real file/key/network access")
        }

        for method in ["reader.sendReply", "reader.edit.save"] {
            let f = UploadFixture(); defer { f.close() }
            let values = method == "reader.edit.save" ? try await f.beginEdit() : ["url": f.topicURL.absoluteString]
            let preparation = UploadGate(), picker = UploadGate()
            f.calls.prepareGate = preparation
            let send = Task { @MainActor in try await f.call(method, values) }
            await preparation.untilEntered()
            let media = Task { @MainActor in try await f.services.chooseImage(f.args()) { await picker.wait(); return nil } }
            await picker.untilEntered()
            preparation.release()
            try await reject("uploading") { _ = try await send.value }
            require(f.calls.replies == 0 && f.calls.saves == 0, "Upload started during page preparation must block the actual write")
            picker.release(); _ = try await media.value
        }
        print("PASS reply and edit recheck upload state after asynchronous page preparation")

        for method in ["reader.sendReply", "reader.edit.save", "discussion.publish"] {
            let f = UploadFixture(); defer { f.close() }
            let values = method == "reader.edit.save" ? try await f.beginEdit() : ["url": f.topicURL.absoluteString]
            let gate = UploadGate(); f.calls.writeGate = gate
            let send = Task { @MainActor in try await f.call(method, values) }
            await gate.untilEntered()
            var opened = false
            try await reject("writing") { _ = try await f.services.chooseImage(f.args()) { opened = true; return nil } }
            require(!opened && f.calls.uploads == 0, "No picker or upload may start while writing")
            try await reject(method == "discussion.publish" ? "publishing" : "writing") {
                _ = try await f.call("discussion.discard", ["confirmed": true])
            }
            try await reject("writing") { _ = try await f.call("reader.edit.cancel", ["url": f.topicURL.absoluteString]) }
            _ = try await f.call("discussion.updateDraft", ["content": "Still save locally"])
            gate.release(); _ = try await send.value
            _ = try await f.services.chooseImage(f.args()) { nil }
        }
        print("PASS actual publish/reply/edit write exclusion, accurate discard errors and local autosave")

        for (phase, failure) in [("picker", false), ("key", false), ("key", true), ("upload", false)] {
            let f = UploadFixture(); defer { f.close() }
            let old = UploadGate(), current = UploadGate()
            if phase == "upload" { f.calls.uploadGate = old }
            if phase == "key" { f.calls.keyGate = old }
            if failure {
                f.calls.keyError = NSError(domain: "fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-old-file-key"])
            }
            let first = Task { @MainActor in
                try await f.services.chooseImage(f.args()) {
                    if phase == "picker" { await old.wait() }
                    return f.file
                }
            }
            await old.untilEntered()
            f.changeAccount()
            f.calls.keyError = nil
            if phase == "upload" { f.calls.uploadGate = current }
            if phase == "key" { f.calls.keyGate = current }
            let second = Task { @MainActor in
                try await f.services.chooseImage(f.args()) {
                    if phase == "picker" { await current.wait() }
                    return f.file
                }
            }
            await current.untilEntered()
            old.release()
            try await reject("stale_authorization") { _ = try await first.value }
            if phase == "key" {
                require(f.calls.keyReadCancelled && f.calls.uploads == 0,
                        "The cancelled old key read cannot start either uploader")
            }
            let stillUploading = try await f.isUploading()
            require(stillUploading, "Old completion must not release the new account's media operation")
            try await reject("uploading") { _ = try await f.services.chooseImage(f.args()) { nil } }
            current.release(); _ = try await second.value
            let settled = try await f.isUploading()
            require(!settled, "Current media operation eventually releases itself")
        }
        print("PASS account invalidation of picker/key/upload and old completion cannot release newer upload")

        for failure in [false, true] {
            for invalidation in ["account", "logout", "dispose", "cancel"] {
                let f = UploadFixture(); defer { f.close() }
                let gate = UploadGate(); f.calls.keyGate = gate
                if failure {
                    f.calls.keyError = NSError(domain: "fixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-file-key"])
                }
                let task = Task { @MainActor in try await f.services.chooseImage(f.args()) { f.file } }
                await gate.untilEntered()
                let status = try await f.call("images.keyStatus")
                require(status["configured"] as? Bool == true && f.calls.uploads == 0,
                        "Status remains responsive while file upload awaits credentials")
                switch invalidation {
                case "account": f.changeAccount()
                case "logout": f.context.session.observeAccount(false)
                case "dispose": f.services.dispose()
                default: task.cancel()
                }
                gate.release()
                if invalidation == "dispose" || invalidation == "cancel" {
                    try await cancel { _ = try await task.value }
                } else {
                    try await reject("stale_authorization") { _ = try await task.value }
                }
                require(f.calls.keyReadCancelled && f.calls.uploads == 0,
                        "Late successful/failed file key reads receive cancellation and never reach the uploader")
            }
        }
        print("PASS pending file-key success/error rejected after account/logout/dispose/cancel without network")

        do {
            let f = UploadFixture(); defer { f.close() }
            for key in [nil, "", " \t "] as [String?] {
                f.calls.key = key
                do { _ = try await f.services.chooseImage(f.args()) { f.file }; fatalError("Expected missing key") }
                catch NodeImageError.missingKey {}
            }
            f.calls.key = "fixture-only-file-key"
            f.calls.keyError = NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-file-key"])
            do { _ = try await f.services.chooseImage(f.args()) { f.file }; fatalError("Expected redacted key failure") }
            catch let error as NativeBridgeError {
                require(error.code == "image_key_store" &&
                        error.message == "无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。",
                        "File credential failures use the fixed redacted storage error")
            }
            require(f.calls.keyReads == 4 && f.calls.uploads == 0, "Missing/failed file keys stop before network")
            f.calls.keyError = nil
            _ = try await f.services.chooseImage(f.args()) { f.file }
            require(f.calls.uploads == 1, "File upload retries with the injected key after failure")
        }
        print("PASS file upload injected credentials, preserved missing-key errors, redaction and retry")

        do {
            let f = UploadFixture(); defer { f.close() }
            let old = UploadGate(), current = UploadGate()
            f.calls.writeGate = old
            let first = Task { @MainActor in try await f.call("reader.sendReply", ["url": f.topicURL.absoluteString]) }
            await old.untilEntered()
            f.changeAccount(); f.calls.writeGate = current
            let currentEdit = try await f.beginEdit()
            let second = Task { @MainActor in try await f.call("reader.edit.save", currentEdit) }
            await current.untilEntered()
            old.release()
            try await reject("stale_authorization") { _ = try await first.value }
            try await reject("writing") { _ = try await f.services.chooseImage(f.args()) { nil } }
            current.release(); _ = try await second.value
        }
        print("PASS old write completion cannot release a new account's active write reservation")

        for method in ["reader.sendReply", "reader.edit.save"] {
            for invalidation in ["account", "dispose"] {
                let f = UploadFixture(); defer { f.close() }
                let values = method == "reader.edit.save" ? try await f.beginEdit() : ["url": f.topicURL.absoluteString]
                let gate = UploadGate(); f.calls.prepareGate = gate
                let task = Task { @MainActor in try await f.call(method, values) }
                await gate.untilEntered()
                if invalidation == "account" { f.changeAccount() } else { f.services.dispose() }
                gate.release()
                if invalidation == "account" { try await reject("stale_authorization") { _ = try await task.value } }
                else { try await cancel { _ = try await task.value } }
                require(f.calls.replies == 0 && f.calls.saves == 0, "Stale preparation must never reach a write")
            }
        }
        for phase in ["picker", "key", "upload"] {
            let f = UploadFixture(); defer { f.close() }
            let gate = UploadGate()
            if phase == "upload" { f.calls.uploadGate = gate }
            if phase == "key" { f.calls.keyGate = gate }
            let task = Task { @MainActor in
                try await f.services.chooseImage(f.args()) {
                    if phase == "picker" { await gate.wait() }
                    return f.file
                }
            }
            await gate.untilEntered(); f.services.dispose(); gate.release()
            try await cancel { _ = try await task.value }
            try await cancel { _ = try await f.services.chooseImage(f.args()) { fatalError("Disposed picker opened") } }
            require(phase == "upload" || f.calls.uploads == 0, "Disposed picker/key read cannot start upload")
        }
        print("PASS account/disposal revalidation after awaits and no insertion or new work after disposal")
    }
}
