import AppKit
import Foundation
import WebKit

@MainActor
private final class EditGate {
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
        fatalError("Fake editor request did not reach its gate")
    }
}

@MainActor
private final class EditCalls {
    var pages = 0, reads = 0, preparations = 0, writes = 0
    var pageGates: [EditGate] = [], readGates: [EditGate] = [], prepareGates: [EditGate] = [], writeGates: [EditGate] = []
    var writeResults = ["verification"]
    var readFails = false, prepareFails = false
    var preparedMarkdown: [String] = []
    var prepareAuthorizations: [Bool] = []
    var prepareSuffix = ""
    var editors: [ForumInlineEdit] = []
    var written: [(ForumInlineEdit.Target, String, String)] = []
}

@MainActor
private final class EditFixture {
    let suite = "cc.seekdesk.qa.edit-verification." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let calls = EditCalls()
    let image = URL(string: "https://example.invalid/preserved-image.png")!

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10))
        let calls = calls
        var requests = NativeForumServices.Requests()
        requests.preparePage = { _, _, session in
            calls.pages += 1
            if !calls.pageGates.isEmpty { await calls.pageGates.removeFirst().wait() }
            // Construct an empty page only. No read, navigation, or JS is used.
            return ForumWebPage(dataStore: session.dataStore)
        }
        requests.makeEdit = {
            var editorRequests = ForumInlineEdit.Requests()
            editorRequests.read = { _, target in
                calls.reads += 1
                if !calls.readGates.isEmpty { await calls.readGates.removeFirst().wait() }
                if calls.readFails { return nil }
                let data = try JSONSerialization.data(withJSONObject: [
                    "markdown": "Original floor \(target.floor)", "title": "Original title",
                ])
                return String(decoding: data, as: UTF8.self)
            }
            editorRequests.prepare = { _, markdown, authorized in
                let initiallyAuthorized = authorized()
                calls.prepareAuthorizations.append(initiallyAuthorized)
                guard initiallyAuthorized else { throw CancellationError() }
                calls.preparations += 1
                calls.preparedMarkdown.append(markdown)
                if !calls.prepareGates.isEmpty { await calls.prepareGates.removeFirst().wait() }
                calls.prepareAuthorizations.append(authorized())
                // Deliberately return or throw even when the resumed authorization
                // is false: save itself must reject stale preparation results.
                if calls.prepareFails { throw NodeImageError.connection }
                return markdown + calls.prepareSuffix // Never resize, read a key, read a file, or upload.
            }
            editorRequests.write = { _, target, title, content in
                calls.writes += 1
                calls.written.append((target, title, content))
                if !calls.writeGates.isEmpty { await calls.writeGates.removeFirst().wait() }
                let kind = calls.writeResults.isEmpty ? "verification" : calls.writeResults.removeFirst()
                return "{\"kind\":\"\(kind)\"}"
            }
            let editor = ForumInlineEdit(requests: editorRequests)
            calls.editors.append(editor)
            return editor
        }
        requests.uploadImage = { _, _ in fatalError("Verification tests must never upload") }
        requests.sendReply = { _, _, _ in fatalError("Verification tests must never reply") }
        requests.publish = { _, _, _, _ in fatalError("Verification tests must never publish") }
        services = NativeForumServices(context: context, requests: requests)
        let services = services
        context.accessChanged = { services.invalidate() }
    }

    func arguments(topic: String = "123", floor: Int = 0) -> [String: Any] {
        ["topicID": topic, "url": Forum.home.appendingPathComponent("post-\(topic)-1").absoluteString,
         "floor": floor, "accessRevision": context.session.accessRevision]
    }
    func call(_ method: String, _ values: [String: Any]) async throws -> [String: Any] {
        try await services.handle(method, values) as? [String: Any] ?? [:]
    }
    func begin(topic: String = "123", floor: Int = 0) async throws -> [String: Any] {
        var args = arguments(topic: topic, floor: floor)
        let snapshot = try await call("reader.edit.begin", args)
        args["editToken"] = snapshot["editToken"]
        return args
    }
    func update(_ args: [String: Any], title: String = "Edited title", content: String = "Edited body") async throws -> [String: Any] {
        try await call("reader.edit.update", args.merging(["title": title, "content": content]) { _, edited in edited })
    }
    func changeAccount() {
        context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other fixture", floorsPerPage: 10))
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        calls.editors.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct EditVerificationChecks {
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
        let mutations = ["reader.edit.update", "reader.edit.save", "reader.edit.cancel", "reader.edit.continueVerification"]

        do {
            let f = EditFixture(); defer { f.close() }
            for invalidFloor: Any in [-1, true, 0.5] {
                var args = f.arguments(); args["floor"] = invalidFloor
                try await reject("stale_editor") { _ = try await f.call("reader.edit.begin", args) }
            }
            var mismatch = f.arguments(); mismatch["topicID"] = "456"
            try await reject("stale_editor") { _ = try await f.call("reader.edit.begin", mismatch) }
            for method in mutations {
                try await reject("stale_editor") { _ = try await f.call(method, f.arguments()) }
            }
            require(f.calls.editors.isEmpty && f.calls.pages == 0 && f.calls.writes == 0,
                    "Invalid targets and missing editors must not create an editor or start work")
            let args = try await f.begin(floor: 3)
            let snapshot = try await f.update(args)
            require(UUID(uuidString: args["editToken"] as? String ?? "") != nil, "Begin returns a unique editor token")
            require(snapshot["topicID"] as? String == "123" && snapshot["floor"] as? Int == 3 &&
                    snapshot["accessRevision"] as? Int == f.context.session.accessRevision,
                    "Snapshots echo the complete authorized target")
            for method in mutations {
                for bad in [["editToken": "invalid"], ["editToken": UUID().uuidString], ["floor": 4], ["topicID": "456"]] as [[String: Any]] {
                    let invalid = args.merging(bad) { _, replacement in replacement }
                    try await reject("stale_editor") { _ = try await f.call(method, invalid) }
                }
                var missing = args; missing.removeValue(forKey: "editToken")
                try await reject("stale_editor") { _ = try await f.call(method, missing) }
            }
            require(f.calls.editors[0].content == "Edited body" && f.calls.writes == 0,
                    "Invalid token and target operations do not mutate or submit the current draft")
            print("PASS strict target input, required token, authorized snapshot and mutation rejection without implicit editors")
        }

        do {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            let body = "Unsaved body ![image](\(f.image.absoluteString))"
            _ = try await f.update(args, title: "Unsaved title", content: body)
            let editor = f.calls.editors[0]
            editor.sizing.set(0.5, previewWidth: 640, for: f.image)
            let sizes = editor.sizing.sizes
            let challenged = try await f.call("reader.edit.save", args)
            require(challenged["needsVerification"] as? Bool == true && challenged["canSave"] as? Bool == false &&
                    challenged["accepted"] as? Bool == false, "Actual save state machine preserves a verification challenge")
            require(f.calls.writes == 1 && f.calls.reads == 1 && f.calls.preparations == 1,
                    "The first explicit save invokes one fake write")
            for _ in 0..<2 {
                let continued = try await f.call("reader.edit.continueVerification", args)
                require(continued["needsVerification"] as? Bool == false && continued["canSave"] as? Bool == true &&
                        continued["accepted"] as? Bool == false && continued["editToken"] as? String == args["editToken"] as? String,
                        "Continue is idempotent and permits an explicit retry without claiming success")
                require(continued["title"] as? String == "Unsaved title" && continued["content"] as? String == body &&
                        editor.sizing.sizes == sizes, "Continue preserves title, content and image sizing")
            }
            require(f.calls.writes == 1 && f.calls.reads == 1 && f.calls.preparations == 1,
                    "Continue neither reloads nor prepares/uploads/submits the draft")
            let challengedAgain = try await f.call("reader.edit.save", args)
            require(challengedAgain["needsVerification"] as? Bool == true, "An unsuccessful verification can be retried again")
            _ = try await f.call("reader.edit.continueVerification", args)
            f.calls.writeResults = ["saved"]
            let saved = try await f.call("reader.edit.save", args)
            require(saved["accepted"] as? Bool == true && f.calls.writes == 3 && f.calls.reads == 1,
                    "Only the user's later explicit save submits the preserved document")
            require(f.calls.written.allSatisfy { $0.1 == "Unsaved title" && $0.2 == body }, "Every attempt submits the same retained content")
            print("PASS real verification state machine, repeatable explicit retry, preserved title/content/sizing and no automatic work")
        }

        do {
            let f = EditFixture(); defer { f.close() }
            f.calls.readFails = true
            let args = try await f.begin()
            _ = try await f.update(args)
            try await reject("not_ready") { _ = try await f.call("reader.edit.continueVerification", args) }
            require(f.calls.writes == 0 && f.calls.editors[0].content == "Edited body", "Unavailable original cannot be declared ready")
            print("PASS failed initial read cannot be resumed as a ready editor and retains local text")
        }

        for newFloor in [1, 0] {
            let f = EditFixture(); defer { f.close() }
            let old = try await f.begin()
            _ = try await f.update(old, content: "Old unsaved text")
            let current = try await f.begin(floor: newFloor)
            _ = try await f.update(current, content: "Current unsaved text")
            require(old["editToken"] as? String != current["editToken"] as? String, "Reopening even the same floor creates a new token")
            for method in mutations {
                try await reject("stale_editor") { _ = try await f.call(method, old) }
            }
            let currentSnapshot = try await f.call("reader.edit.continueVerification", current)
            require(currentSnapshot["content"] as? String == "Current unsaved text" && f.calls.writes == 0,
                    "Old floor/token cannot update, save, resume or cancel the replacement editor")
            let cancelled = try await f.call("reader.edit.cancel", current)
            require(cancelled["editToken"] as? String == current["editToken"] as? String &&
                    cancelled["ready"] as? Bool == false && cancelled["cancelled"] as? Bool == true,
                    "Only the current token can clear its editor, and its completion retains that token")
        }
        print("PASS same-topic floor changes and same-floor reopen reject every old-token mutation including cancellation")

        for phase in ["page", "read"] {
            let f = EditFixture(); defer { f.close() }
            let gate = EditGate()
            if phase == "page" { f.calls.pageGates = [gate] } else { f.calls.readGates = [gate] }
            let old = Task { @MainActor in try await f.begin(floor: 1) }
            await gate.untilEntered()
            let current = try await f.begin(floor: 2)
            _ = try await f.update(current, content: "New editor wins")
            gate.release()
            try await reject("stale_editor") { _ = try await old.value }
            let snapshot = try await f.call("reader.edit.continueVerification", current)
            require(snapshot["content"] as? String == "New editor wins" && snapshot["floor"] as? Int == 2,
                    "Older begin completion never replaces or clears the newer slot")
            require(f.calls.reads == (phase == "page" ? 1 : 2), "Stale page preparation cannot even start its Markdown read")
        }
        print("PASS overlapping begins during page preparation and Markdown read keep only the latest editor ownership")

        for replacement in ["floor", "same-floor", "same-instance-target"] {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            let gate = EditGate(); f.calls.pageGates = [gate]
            let saving = Task { @MainActor in try await f.call("reader.edit.save", args) }
            await gate.untilEntered()
            if replacement == "same-instance-target" {
                f.calls.editors[0].begin(.init(topicID: 123, floor: 0, owner: 101))
            } else {
                _ = try await f.begin(floor: replacement == "floor" ? 1 : 0)
            }
            gate.release()
            try await reject("stale_editor") { _ = try await saving.value }
            require(f.calls.writes == 0 && f.calls.preparations == 0,
                    "Save must revalidate Target.id and instance after page preparation before any write work")
        }
        print("PASS save rechecks both editor instance and exact Target.id after asynchronous preparation")

        for preflight in ["unauthorized", "cancelled"] {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            let editor = f.calls.editors[0]
            let page = ForumWebPage(dataStore: f.context.session.dataStore)
            let accepted: Bool
            if preflight == "unauthorized" {
                accepted = await editor.save(on: page, authorized: { false })
            } else {
                let entry = EditGate()
                let saving = Task { @MainActor in
                    await entry.wait()
                    return await editor.save(on: page, authorized: { true })
                }
                await entry.untilEntered()
                saving.cancel()
                entry.release()
                accepted = await saving.value
            }
            require(!accepted && f.calls.preparations == 0 && f.calls.prepareAuthorizations.isEmpty && f.calls.writes == 0,
                    "Unauthorized or already-cancelled saves must not enter preparation or write")
            require(editor.message == nil && !editor.saving && editor.content == "Edited body",
                    "Preflight cancellation retains local text without a connection error or a busy editor")
        }
        print("PASS save preflight rejects authorization loss and pre-existing Task cancellation before preparation")

        for invalidation in ["account", "dispose"] {
            for prepareFails in [false, true] {
                let f = EditFixture(); defer { f.close() }
                let args = try await f.begin()
                _ = try await f.update(args)
                let editor = f.calls.editors[0]
                let gate = EditGate()
                f.calls.prepareGates = [gate]
                f.calls.prepareFails = prepareFails
                let saving = Task { @MainActor in try await f.call("reader.edit.save", args) }
                await gate.untilEntered()
                require(f.calls.prepareAuthorizations == [true] && editor.saving && f.calls.writes == 0,
                        "Preparation begins under a live authorization and suspends before any write")
                if invalidation == "account" { f.changeAccount() } else { f.services.dispose() }
                gate.release()
                if invalidation == "account" {
                    try await reject("stale_authorization") { _ = try await saving.value }
                } else {
                    try await cancel { _ = try await saving.value }
                }
                require(f.calls.preparations == 1 && f.calls.prepareAuthorizations == [true, false] && f.calls.writes == 0,
                        "The preparation authorization must expire and neither a late value nor error may start a write")
                require(editor.message == nil && !editor.needsVerification && !editor.saving && editor.content == "Edited body",
                        "Account/disposal invalidation must not become a connection/verification error or alter the draft")
            }
        }
        print("PASS suspended preparation loses account/disposal authorization without writes or misleading connection errors")

        for prepareFails in [false, true] {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            let editor = f.calls.editors[0]
            let originalTarget = editor.target
            let page = ForumWebPage(dataStore: f.context.session.dataStore)
            let gate = EditGate()
            f.calls.prepareGates = [gate]
            f.calls.prepareFails = prepareFails
            // Keep authorization true to isolate Task cancellation from the
            // bridge's own Task-aware authorization closure.
            let saving = Task { @MainActor in
                await editor.save(on: page, authorized: { true })
            }
            await gate.untilEntered()
            saving.cancel()
            gate.release()
            let accepted = await saving.value
            require(!accepted && f.calls.preparations == 1 && f.calls.prepareAuthorizations == [true, true] && f.calls.writes == 0,
                    "Task cancellation alone must block both a prepared value and a preparation error from starting a write")
            require(editor.target == originalTarget && editor.message == nil && !editor.saving && editor.content == "Edited body",
                    "Cancelled preparation preserves the target and draft without reporting a connection failure")
        }
        print("PASS Task cancellation after preparation starts prevents writes even while authorization remains true")

        for prepareFails in [false, true] {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            let editor = f.calls.editors[0]
            let gate = EditGate(), replacementGate = EditGate()
            f.calls.prepareGates = [gate, replacementGate]
            f.calls.prepareFails = prepareFails
            f.calls.writeResults = ["saved"]
            let saving = Task { @MainActor in try await f.call("reader.edit.save", args) }
            await gate.untilEntered()
            editor.clear()
            require(editor.target == nil && !editor.saving, "Clearing an editor invalidates the target and releases its old saving state")
            let replacement = ForumInlineEdit.Target(topicID: 123, floor: 1, owner: 101)
            editor.begin(replacement)
            require(editor.target == replacement, "A cleared editor must accept its replacement target immediately")
            let page = ForumWebPage(dataStore: f.context.session.dataStore)
            await editor.load(on: page)
            require(editor.ready && editor.content == "Original floor 1", "The replacement target loads its own fake original")
            editor.title = "Replacement title"
            editor.content = "Replacement body"
            let replacementSave = Task { @MainActor in
                await editor.save(on: page, authorized: { true })
            }
            await replacementGate.untilEntered()
            gate.release()
            try await reject("stale_editor") { _ = try await saving.value }
            require(f.calls.preparations == 2 && f.calls.prepareAuthorizations == [true, true, false] && f.calls.writes == 0,
                    "Target invalidation during preparation must block both a late value and a late error")
            require(editor.target == replacement && editor.saving && editor.content == "Replacement body" &&
                    editor.title == "Replacement title" && editor.message == nil && !editor.needsVerification,
                    "An obsolete preparation cannot clear the replacement target, reset its active save, or attach an old error")
            replacementGate.release()
            let replacementAccepted = await replacementSave.value
            require(replacementAccepted == !prepareFails && editor.target == replacement && !editor.saving,
                    "The replacement save completes under its own target and releases only its own busy state")
            require(f.calls.writes == (prepareFails ? 0 : 1) && f.calls.prepareAuthorizations == [true, true, false, true],
                    "Only the replacement target may write once its own valid preparation completes")
            if !prepareFails {
                require(f.calls.written[0].0 == replacement && f.calls.written[0].1 == "Replacement title" &&
                        f.calls.written[0].2 == "Replacement body", "The only write belongs to the replacement document")
            }
        }
        print("PASS clear/reopen preserves the new target and active saving state when an obsolete preparation completes")

        do {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            let originalBody = "Start body ![image](\(f.image.absoluteString))"
            _ = try await f.update(args, title: "  Start title \n", content: originalBody)
            let editor = f.calls.editors[0]
            let originalTarget = editor.target!
            let gate = EditGate()
            f.calls.prepareGates = [gate]
            f.calls.prepareSuffix = "\n[prepared fixture]"
            f.calls.writeResults = ["saved"]
            let saving = Task { @MainActor in try await f.call("reader.edit.save", args) }
            await gate.untilEntered()
            editor.title = "Newer local title"
            editor.content = "Newer local body"
            gate.release()
            let snapshot = try await saving.value
            require(snapshot["accepted"] as? Bool == true && f.calls.writes == 1 && f.calls.preparations == 1,
                    "One explicitly started save produces exactly one fake preparation and one fake write")
            require(f.calls.preparedMarkdown == [originalBody] && f.calls.prepareAuthorizations == [true, true],
                    "Preparation receives the body captured at the start of that save")
            let written = f.calls.written[0]
            require(written.0 == originalTarget && written.1 == "Start title" && written.2 == originalBody + "\n[prepared fixture]",
                    "The write must pair the captured trimmed title with the prepared captured body, never a later title")
            require(editor.title == "Newer local title" && editor.content == "Newer local body" && !editor.saving,
                    "Saving a captured snapshot must not overwrite edits made while preparation was suspended")
            print("PASS save submits one consistent title/body snapshot while preserving newer local edits")
        }

        do {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            f.calls.prepareFails = true
            let snapshot = try await f.call("reader.edit.save", args)
            let editor = f.calls.editors[0]
            require(snapshot["accepted"] as? Bool == false && f.calls.preparations == 1 && f.calls.writes == 0,
                    "A genuine preparation error blocks submission")
            require(editor.message?.contains(NodeImageError.connection.localizedDescription) == true &&
                    editor.message?.contains("修改已保留") == true && editor.content == "Edited body" && !editor.saving,
                    "Live preparation failures still report their real error and retain the draft")
            print("PASS live preparation errors retain their connection feedback instead of being mistaken for cancellation")
        }

        do {
            let f = EditFixture(); defer { f.close() }
            let args = try await f.begin()
            _ = try await f.update(args)
            let gate = EditGate(); f.calls.writeGates = [gate]
            let saving = Task { @MainActor in try await f.call("reader.edit.save", args) }
            await gate.untilEntered()
            for method in mutations + ["reader.edit.begin"] {
                try await reject("writing") { _ = try await f.call(method, args) }
            }
            gate.release(); _ = try await saving.value
            let picker = EditGate()
            let media = Task { @MainActor in
                try await f.services.chooseImage(["accessRevision": f.context.session.accessRevision]) { await picker.wait(); return nil }
            }
            await picker.untilEntered()
            for method in mutations + ["reader.edit.begin"] {
                try await reject("uploading") { _ = try await f.call(method, args) }
            }
            picker.release(); _ = try await media.value
            print("PASS duplicate continuation, replacement and mutations cannot cross an active save or media picker")
        }

        for phase in ["page", "read", "save-page", "write"] {
            for invalidation in ["account", "dispose"] {
                let f = EditFixture(); defer { f.close() }
                let gate = EditGate()
                let task: Task<[String: Any], Error>
                if phase == "page" || phase == "read" {
                    if phase == "page" { f.calls.pageGates = [gate] } else { f.calls.readGates = [gate] }
                    task = Task { @MainActor in try await f.begin() }
                } else {
                    let args = try await f.begin()
                    _ = try await f.update(args)
                    if phase == "save-page" { f.calls.pageGates = [gate] } else { f.calls.writeGates = [gate] }
                    task = Task { @MainActor in try await f.call("reader.edit.save", args) }
                }
                await gate.untilEntered()
                if invalidation == "account" { f.changeAccount() } else { f.services.dispose() }
                gate.release()
                if invalidation == "account" { try await reject("stale_authorization") { _ = try await task.value } }
                else { try await cancel { _ = try await task.value } }
                require(f.calls.writes == (phase == "write" ? 1 : 0), "Invalidated asynchronous work cannot start a new write")
                if phase == "write" { require(!f.calls.editors[0].needsVerification, "Stale write result must not change editor verification state") }
            }
        }
        print("PASS account and disposal revalidation at every begin/save await without stale payloads or state mutation")

        do {
            let f = EditFixture(); defer { f.close() }
            let old = try await f.begin()
            _ = try await f.update(old)
            _ = try await f.call("reader.edit.save", old)
            f.changeAccount()
            let current = try await f.begin()
            _ = try await f.update(current, content: "New account draft")
            for method in mutations {
                try await reject("stale_authorization") { _ = try await f.call(method, old) }
                var forgedRevision = old; forgedRevision["accessRevision"] = f.context.session.accessRevision
                try await reject("stale_editor") { _ = try await f.call(method, forgedRevision) }
            }
            let snapshot = try await f.call("reader.edit.continueVerification", current)
            require(snapshot["content"] as? String == "New account draft" && f.calls.writes == 1,
                    "Old verification cannot resume or clear a new account's editor even with its current revision")
            print("PASS stale verification continuation cannot cross account ownership or borrow a newer access revision")
        }
    }
}
