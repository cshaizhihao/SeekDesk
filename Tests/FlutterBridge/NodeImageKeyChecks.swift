import AppKit
import Foundation
import LocalAuthentication
import Security
import WebKit

@MainActor
private final class KeyGate {
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
        fatalError("Fake key-maintenance request did not reach its gate")
    }
}

private struct LeakyStoreError: LocalizedError {
    let secret: String
    var errorDescription: String? { "Storage provider diagnostic: \(secret)" }
}

private final class KeyMatchProbe: @unchecked Sendable {
    struct Snapshot {
        var calls = 0, completed = 0
        var validQueries = true
    }

    private let condition = NSCondition()
    private let result: OSStatus
    private var held: Bool
    private var state = Snapshot()

    init(result: OSStatus, held: Bool = false) {
        self.result = result
        self.held = held
    }

    func match(_ options: [String: Any]) -> OSStatus {
        precondition(!Thread.isMainThread, "The production status helper must never match on the main thread")
        let expectedService = Bundle.main.bundleIdentifier == "com.seekdesk.flutter-preview"
            ? "com.seekdesk.flutter-preview.nodeimage" : "com.seekdesk.client.nodeimage"
        let valid = Set(options.keys) == Set([
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
            kSecMatchLimit as String, kSecUseAuthenticationContext as String
        ]) && (options[kSecClass as String] as? String) == (kSecClassGenericPassword as String)
            && (options[kSecAttrService as String] as? String) == expectedService
            && (options[kSecAttrAccount as String] as? String) == "api-key"
            && (options[kSecMatchLimit as String] as? String) == (kSecMatchLimitOne as String)
            && (options[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        condition.lock(); defer { condition.unlock() }
        state.calls += 1
        state.validQueries = state.validQueries && valid
        while held { condition.wait() }
        state.completed += 1
        return result
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        held = false
        condition.broadcast()
    }

    func snapshot() -> Snapshot { condition.lock(); defer { condition.unlock() }; return state }

    func untilEntered() async throws {
        for _ in 0..<2_000 {
            if snapshot().calls > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("The injected status matcher did not start")
    }
}

@MainActor
private final class MemoryImageKey {
    let sentinel = "fixture-only-do-not-return-this-value"
    var value: String?
    var statuses = 0, reads = 0, saves = 0, removes = 0
    var statusFails = false, readFails = false, saveFails = false, removeFails = false
    var statusGate: KeyGate?, mutationGate: KeyGate?
    var mutationCancelled = false, mutationsCompleted = 0
    var accesses: Int { statuses + reads + saves + removes }

    var store: NativeForumServices.KeyStore {
        .init(configured: {
            self.statuses += 1
            let configured = self.value != nil, failure = self.statusFails
            if let gate = self.statusGate { await gate.wait() }
            if failure { throw LeakyStoreError(secret: self.sentinel) }
            return configured
        }, read: {
            self.reads += 1
            if self.readFails { throw LeakyStoreError(secret: self.sentinel) }
            return self.value
        }, save: { key in
            self.saves += 1
            let failure = self.saveFails
            if let gate = self.mutationGate { await gate.wait() }
            self.mutationCancelled = Task.isCancelled
            self.mutationsCompleted += 1
            if failure { throw LeakyStoreError(secret: key) }
            self.value = key
        }, remove: {
            self.removes += 1
            let failure = self.removeFails
            if let gate = self.mutationGate { await gate.wait() }
            self.mutationCancelled = Task.isCancelled
            self.mutationsCompleted += 1
            if failure { throw LeakyStoreError(secret: self.sentinel) }
            self.value = nil
        })
    }
}

@MainActor
private final class KeyCalls {
    var uploadGate: KeyGate?, writeGate: KeyGate?
    var uploads = 0
}

@MainActor
private final class KeyFixture {
    let suite = "cc.seekdesk.qa.node-image-key." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let memory = MemoryImageKey()
    let calls = KeyCalls()
    let topicURL = Forum.home.appendingPathComponent("post-123-1")

    init(signedIn: Bool = false, configured: (@MainActor () async throws -> Bool)? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        if signedIn { context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10)) }
        else { context.session.observeAccount(false) }
        let calls = calls
        var requests = NativeForumServices.Requests()
        requests.preparePage = { _, _, session in ForumWebPage(dataStore: session.dataStore) }
        requests.uploadImage = { _, _ in
            calls.uploads += 1
            if let gate = calls.uploadGate { await gate.wait() }
            return URL(string: "https://example.invalid/fake-upload.png")!
        }
        requests.sendReply = { _, _, _ in
            let gate = calls.writeGate
            return Task { if let gate { await gate.wait() } }
        }
        requests.publish = { publisher, _, _, accepted in
            publisher.sending = true
            let gate = calls.writeGate
            return Task {
                defer { publisher.sending = false }
                if let gate { await gate.wait() }
                accepted(nil)
            }
        }
        requests.makeEdit = {
            var editor = ForumInlineEdit.Requests()
            editor.read = { _, _ in #"{"title":"Fixture title","markdown":"Fixture original"}"# }
            editor.prepare = { _, markdown, authorized in
                guard authorized() else { throw CancellationError() }
                return markdown
            }
            editor.write = { _, _, _, _ in fatalError("Key tests must use fake saveEdit") }
            return ForumInlineEdit(requests: editor)
        }
        requests.saveEdit = { _, _, authorized in
            if let gate = calls.writeGate { await gate.wait() }
            return authorized()
        }
        var keys = memory.store
        if let configured { keys.configured = configured }
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
        let result = try await call("reader.edit.begin", values)
        values["editToken"] = result["editToken"]
        return values
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct NodeImageKeyChecks {
    @MainActor
    static func main() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { fatalError(label) }
        }
        func status(_ value: [String: Any], _ configured: Bool) {
            require(Set(value.keys) == ["configured"] && value["configured"] as? Bool == configured,
                    "Credential responses expose only the configured Boolean")
        }
        func reject(_ code: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected \(code)") }
            catch let error as NativeBridgeError {
                require(error.code == code, "Expected \(code), got \(error.code)")
                if code == "image_key_store" {
                    require(error.message == "无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。",
                            "Store failures must use the exact fixed message, never provider text or credentials")
                }
            }
        }
        func cancelled(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected cancellation") }
            catch is CancellationError {}
        }
        func flush(_ services: NativeForumServices, response: Bool = true) -> (calls: Int, saved: Bool?) {
            var calls = 0, saved: Bool?
            // Invoke the same native boundary as SeekDeskFlutterBridge; only
            // the Flutter method-channel response is replaced with memory.
            services.flushDrafts(using: { reply in calls += 1; reply(response) }, completion: { saved = $0 })
            return (calls, saved)
        }
        let methods = ["images.keyStatus", "images.setKey", "images.removeKey"]

        do {
            let f = KeyFixture(); defer { f.close() }
            require(!f.services.hasPendingImageKeyMutation, "An idle service has no native credential reservation")
            for response in [false, true] {
                let result = flush(f.services, response: response)
                require(result.calls == 1 && result.saved == response,
                        "An idle native flush preserves both Flutter success and failure")
            }
            require(f.memory.accesses == 0, "The native quit guard never queries the credential store")
            print("PASS idle native flush delegates once and preserves Flutter saved results without credential access")
        }

        do {
            let f = KeyFixture(); defer { f.close() }
            f.memory.readFails = true
            require(!f.context.session.canCompose, "The first fixture is deliberately signed out")
            status(try await f.call("images.keyStatus"), false)
            require(f.memory.reads == 0, "Configuration status must not request decrypted credential data")
            status(try await f.call("images.setKey", ["key": " \t" + f.memory.sentinel + "\t "]), true)
            require(f.memory.value == f.memory.sentinel, "Valid surrounding whitespace is trimmed on save")
            status(try await f.call("images.keyStatus"), true)
            status(try await f.call("images.setKey", ["key": "replacement-fixture-value"]), true)
            require(f.memory.value == "replacement-fixture-value", "Replacement uses the same store")
            status(try await f.call("images.removeKey"), false)
            status(try await f.call("images.keyStatus"), false)
            status(try await f.call("images.removeKey"), false)
            for empty in ["", " \t "] {
                f.memory.value = empty
                status(try await f.call("images.keyStatus"), true)
            }
            require(f.memory.statuses == 5 && f.memory.reads == 0,
                    "Status reports item existence without reading or validating even empty stored data")
            print("PASS signed-out credential maintenance, replace/remove and existence-only status without secret access")
        }

        do {
            let probe = KeyMatchProbe(result: errSecSuccess, held: true)
            let f = KeyFixture(signedIn: true, configured: {
                try await NodeImageKey.configured(matching: { probe.match($0) })
            })
            defer { probe.release(); f.close() }
            let pending = Task { @MainActor in try await f.call("images.keyStatus") }
            try await probe.untilEntered()
            let draft = try await f.call("discussion.getDraft")
            require(draft["content"] as? String == "Fixture body" && probe.snapshot().completed == 0,
                    "MainActor bridge work remains responsive while the production helper's synchronous matcher is held")
            probe.release()
            status(try await pending.value, true)
            let observed = probe.snapshot()
            require(observed.calls == 1 && observed.completed == 1 && observed.validQueries && f.memory.reads == 0,
                    "One off-main query uses the existing namespace and per-query noninteractive context without any return types")
            print("PASS production status helper runs off-main and keeps MainActor responsive using an injected matcher only")
        }

        do {
            let probe = KeyMatchProbe(result: errSecItemNotFound)
            let configured = try await NodeImageKey.configured(matching: { probe.match($0) })
            require(!configured && probe.snapshot().validQueries && probe.snapshot().calls == 1,
                    "Only item-not-found maps to an absent configuration")
            for failure in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled, errSecParam] {
                let failed = KeyMatchProbe(result: failure)
                do {
                    _ = try await NodeImageKey.configured(matching: { failed.match($0) })
                    fatalError("A status-query failure must not become configured false")
                } catch NodeImageError.keychain {}
                require(failed.snapshot().validQueries && failed.snapshot().calls == 1,
                        "Every failure uses the same status-only query and a fixed keychain error")
            }
            print("PASS status-only OSStatus mapping distinguishes item absence from denied unavailable and invalid queries")
        }

        do {
            let pending = Task { @MainActor in
                try await NodeImageKey.configured(matching: { _ in fatalError("Cancelled status must not reach its matcher") })
            }
            pending.cancel()
            try await cancelled { _ = try await pending.value }
            for result in [errSecSuccess, errSecAuthFailed] {
                let probe = KeyMatchProbe(result: result, held: true)
                defer { probe.release() }
                let waiting = Task { @MainActor in
                    try await NodeImageKey.configured(matching: { probe.match($0) })
                }
                try await probe.untilEntered()
                waiting.cancel()
                require(probe.snapshot().completed == 0,
                        "Task cancellation does not pretend to interrupt an active synchronous matcher")
                probe.release()
                try await cancelled { _ = try await waiting.value }
                require(probe.snapshot().completed == 1, "The actual matcher completes before its result is rejected")
            }
            print("PASS production status cancellation is checked before dispatch and after successful or failed matching")
        }

        for failure in [false, true] {
            for invalidation in ["identity", "logout", "dispose", "cancel"] {
                let f = KeyFixture(signedIn: true); defer { f.close() }
                f.memory.value = f.memory.sentinel
                f.memory.statusFails = failure
                let gate = KeyGate()
                f.memory.statusGate = gate
                let pending = Task { @MainActor in try await f.call("images.keyStatus") }
                await gate.untilEntered()
                switch invalidation {
                case "identity":
                    f.context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other fixture", floorsPerPage: 10))
                case "logout": f.context.session.observeAccount(false)
                case "dispose": f.services.dispose()
                default: pending.cancel()
                }
                gate.release()
                if invalidation == "identity" || invalidation == "logout" {
                    try await reject("stale_authorization") { _ = try await pending.value }
                    f.memory.statusGate = nil
                    f.memory.statusFails = false
                    status(try await f.call("images.keyStatus"), true)
                } else {
                    try await cancelled { _ = try await pending.value }
                }
                require(f.memory.reads == 0 && f.memory.saves == 0 && f.memory.removes == 0,
                        "Late status success or failure cannot read secrets or mutate credentials")
            }
        }
        print("PASS status success and failure revalidate identity logout disposal and cancellation before returning")

        do {
            let f = KeyFixture(); defer { f.close() }
            let pending = Task { @MainActor in try await f.call("images.keyStatus") }
            pending.cancel()
            try await cancelled { _ = try await pending.value }
            require(f.memory.accesses == 0, "An already-cancelled status request never enters the injected store")
            let cancelledStore = KeyFixture(configured: { throw CancellationError() })
            defer { cancelledStore.close() }
            try await cancelled { _ = try await cancelledStore.call("images.keyStatus") }
            require(cancelledStore.memory.accesses == 0, "A cancelled status dependency never falls back to secret access")
            print("PASS cancelled status entry and dependency stay cancelled without accessing credentials")
        }

        do {
            let f = KeyFixture(); defer { f.close() }
            f.memory.value = f.memory.sentinel
            for key in ["", " ", "\t", " \t "] {
                try await reject("invalid_image_key") { _ = try await f.call("images.setKey", ["key": key]) }
            }
            for scalar in ["\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
                for key in [scalar + f.memory.sentinel, f.memory.sentinel + scalar, "prefix" + scalar + "suffix"] {
                    try await reject("invalid_image_key") { _ = try await f.call("images.setKey", ["key": key]) }
                }
            }
            for values: [String: Any] in [[:], ["key": 42], ["key": NSNull()]] {
                try await reject("invalid_arguments") { _ = try await f.call("images.setKey", values) }
            }
            require(f.memory.accesses == 0 && f.memory.value == f.memory.sentinel,
                    "Invalid raw credentials are rejected before any store access or mutation")
            print("PASS original-input validation rejects empty text and LF/CR/VT/FF/NEL/LS/PS before trimming or storage")
        }

        do {
            let f = KeyFixture(); defer { f.close() }
            f.memory.value = f.memory.sentinel
            f.memory.statusFails = true
            try await reject("image_key_store") { _ = try await f.call("images.keyStatus") }
            f.memory.statusFails = false
            status(try await f.call("images.keyStatus"), true)
            f.memory.saveFails = true
            try await reject("image_key_store") { _ = try await f.call("images.setKey", ["key": "new-secret-fixture"]) }
            require(f.memory.value == f.memory.sentinel, "Failed save does not replace the stored credential")
            f.memory.saveFails = false
            status(try await f.call("images.setKey", ["key": "new-secret-fixture"]), true)
            f.memory.removeFails = true
            try await reject("image_key_store") { _ = try await f.call("images.removeKey") }
            require(f.memory.value == "new-secret-fixture", "Failed removal leaves the credential configured")
            f.memory.removeFails = false
            status(try await f.call("images.removeKey"), false)
            require(f.memory.reads == 0, "Status failures never fall back to reading credential data")
            print("PASS status failures remain errors, all provider errors are redacted, and failed save/remove can retry")
        }

        do {
            let f = KeyFixture(); defer { f.close() }
            let old = f.args(["key": f.memory.sentinel])
            for method in methods {
                try await reject("stale_authorization") { _ = try await f.services.handle(method, ["key": f.memory.sentinel]) }
            }
            f.context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10))
            for method in methods {
                try await reject("stale_authorization") { _ = try await f.services.handle(method, old) }
            }
            let signedIn = f.args(["key": f.memory.sentinel])
            f.context.session.observeAccount(false)
            for method in methods {
                try await reject("stale_authorization") { _ = try await f.services.handle(method, signedIn) }
            }
            require(f.memory.accesses == 0, "Missing or stale revision is rejected before all store operations")
            status(try await f.call("images.setKey", ["key": f.memory.sentinel]), true)
            status(try await f.call("images.keyStatus"), true)
            print("PASS all key APIs reject missing/stale revisions across login/logout while allowing the current signed-out session")
        }

        for phase in ["picker", "upload"] {
            let f = KeyFixture(signedIn: true); defer { f.close() }
            f.memory.value = f.memory.sentinel
            let gate = KeyGate()
            if phase == "upload" { f.calls.uploadGate = gate }
            let media = Task { @MainActor in
                try await f.services.chooseImage(f.args()) {
                    if phase == "picker" { await gate.wait(); return nil }
                    return URL(fileURLWithPath: "/fixture/not-read-or-uploaded.png")
                }
            }
            await gate.untilEntered()
            try await reject("uploading") { _ = try await f.call("images.setKey", ["key": "replacement-fixture"]) }
            try await reject("uploading") { _ = try await f.call("images.removeKey") }
            status(try await f.call("images.keyStatus"), true)
            require(f.memory.saves == 0 && f.memory.removes == 0 && f.memory.value == f.memory.sentinel,
                    "The picker and upload both exclude credential mutations but allow status reads")
            gate.release(); _ = try await media.value
            status(try await f.call("images.setKey", ["key": "replacement-fixture"]), true)
        }
        print("PASS picker and upload ownership block key replacement/removal until completion without blocking status")

        for method in ["reader.sendReply", "discussion.publish", "reader.edit.save"] {
            let f = KeyFixture(signedIn: true); defer { f.close() }
            f.memory.value = f.memory.sentinel
            let args = method == "reader.edit.save" ? try await f.beginEdit() : ["url": f.topicURL.absoluteString]
            let gate = KeyGate(); f.calls.writeGate = gate
            let writing = Task { @MainActor in try await f.call(method, args) }
            await gate.untilEntered()
            try await reject("writing") { _ = try await f.call("images.setKey", ["key": "replacement-fixture"]) }
            try await reject("writing") { _ = try await f.call("images.removeKey") }
            status(try await f.call("images.keyStatus"), true)
            require(f.memory.saves == 0 && f.memory.removes == 0, "No actual editor submission may race credential changes")
            gate.release(); _ = try await writing.value
            status(try await f.call("images.removeKey"), false)
        }
        print("PASS reply/publish/edit reservations block credential mutation until the actual write completes")

        for method in ["images.setKey", "images.removeKey"] {
            let f = KeyFixture(signedIn: true); defer { f.close() }
            f.memory.value = f.memory.sentinel
            let edit = try await f.beginEdit(), gate = KeyGate()
            f.memory.mutationGate = gate
            let mutation = Task { @MainActor in try await f.call(method, ["key": "replacement-fixture"]) }
            await gate.untilEntered()
            let blockedFlush = flush(f.services)
            require(f.services.hasPendingImageKeyMutation && blockedFlush.calls == 0 && blockedFlush.saved == false,
                    "A pending native credential mutation rejects quit before requesting Flutter lifecycle.flush")
            status(try await f.call("images.keyStatus"), true)
            try await reject("writing") { _ = try await f.call("images.setKey", ["key": "competing-fixture"]) }
            try await reject("writing") { _ = try await f.call("images.removeKey") }
            var pickerOpened = false
            try await reject("writing") {
                _ = try await f.services.chooseImage(f.args()) { pickerOpened = true; return nil }
            }
            for (write, values) in [
                ("reader.sendReply", ["url": f.topicURL.absoluteString] as [String: Any]),
                ("discussion.publish", [:]),
                ("reader.edit.save", edit),
            ] {
                try await reject("writing") { _ = try await f.call(write, values) }
            }
            _ = try await f.call("discussion.updateDraft", ["content": "Autosave remains responsive"])
            require(!pickerOpened && f.calls.uploads == 0 && f.memory.mutationsCompleted == 0 &&
                    f.memory.saves + f.memory.removes == 1 && f.memory.reads == 0,
                    "A pending mutation excludes all competing writes and uploads without blocking status/autosave")
            gate.release()
            status(try await mutation.value, method == "images.setKey")
            let finishedFlush = flush(f.services)
            require(!f.services.hasPendingImageKeyMutation && finishedFlush.calls == 1 && finishedFlush.saved == true,
                    "Native flush can approve quit only after the actual credential mutation settles")
            f.memory.mutationGate = nil
            status(try await f.call("images.removeKey"), false)
        }
        print("PASS pending save/remove reverse contention, responsive status/autosave and release on real completion")

        for method in ["images.setKey", "images.removeKey"] {
            for failure in [false, true] {
                for invalidation in ["account", "logout", "dispose", "cancel"] {
                    let f = KeyFixture(signedIn: true); defer { f.close() }
                    f.memory.value = f.memory.sentinel
                    f.memory.saveFails = failure; f.memory.removeFails = failure
                    var flushCalls = 0, flushResult: Bool?
                    var replyToFlush: ((Bool) -> Void)?
                    f.services.flushDrafts(using: { reply in
                        flushCalls += 1; replyToFlush = reply
                    }, completion: { flushResult = $0 })
                    require(flushCalls == 1 && replyToFlush != nil && flushResult == nil,
                            "The Flutter lifecycle response is held before a native credential mutation begins")
                    let gate = KeyGate(); f.memory.mutationGate = gate
                    let mutation = Task { @MainActor in try await f.call(method, ["key": "late-fixture-value"]) }
                    await gate.untilEntered()
                    switch invalidation {
                    case "account":
                        f.context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other fixture", floorsPerPage: 10))
                    case "logout": f.context.session.observeAccount(false)
                    case "dispose": f.services.dispose()
                    default: mutation.cancel()
                    }
                    if invalidation == "dispose" {
                        try await cancelled { _ = try await f.call("images.removeKey") }
                    } else {
                        status(try await f.call("images.keyStatus"), true)
                        try await reject("writing") { _ = try await f.call("images.setKey", ["key": "competing-fixture"]) }
                        try await reject("writing") { _ = try await f.call("images.removeKey") }
                    }
                    require(f.memory.mutationsCompleted == 0 && f.memory.saves + f.memory.removes == 1,
                            "Invalidation/cancellation must retain the reservation until the actual store returns")
                    replyToFlush?(true); replyToFlush = nil
                    let blockedFlush = flush(f.services)
                    require(f.services.hasPendingImageKeyMutation && flushResult == false &&
                            blockedFlush.calls == 0 && blockedFlush.saved == false,
                            "Both late Flutter saved=true and new quit attempts fail while an invalidated mutation still runs")
                    gate.release()
                    if invalidation == "dispose" || invalidation == "cancel" {
                        try await cancelled { _ = try await mutation.value }
                    } else {
                        try await reject("stale_authorization") { _ = try await mutation.value }
                    }
                    require(f.memory.mutationCancelled && f.memory.mutationsCompleted == 1,
                            "Child storage receives cancellation and its late success/error cannot become a UI result")
                    let stored = failure ? f.memory.sentinel : (method == "images.setKey" ? "late-fixture-value" : nil)
                    require(f.memory.value == stored,
                            "An already-running successful write may finish after cancellation without reporting UI success")
                    let finishedFlush = flush(f.services)
                    require(!f.services.hasPendingImageKeyMutation && finishedFlush.calls == 1 && finishedFlush.saved == true,
                            "The native quit reservation retires on actual store completion, including failure and disposal")
                    if invalidation != "dispose" {
                        f.memory.mutationGate = nil; f.memory.saveFails = false; f.memory.removeFails = false
                        status(try await f.call("images.setKey", ["key": "current-fixture-value"]), true)
                        require(f.memory.value == "current-fixture-value", "Current authorization can retry after actual completion")
                    }
                }
            }
        }
        print("PASS pending save/remove success/error across account/logout/dispose/cancel retain reservation and reject late results")
        print("PASS native quit checks before lifecycle.flush and after delayed saved=true across mutation invalidation and completion")

        do {
            let f = KeyFixture(); defer { f.close() }
            f.services.dispose()
            for method in methods {
                do { _ = try await f.call(method, ["key": f.memory.sentinel]); fatalError("Disposed key operation was accepted") }
                catch is CancellationError {}
            }
            require(f.memory.accesses == 0, "Disposed services never access storage")
            print("PASS disposed credential API calls never reach the injected store")
        }
    }
}
