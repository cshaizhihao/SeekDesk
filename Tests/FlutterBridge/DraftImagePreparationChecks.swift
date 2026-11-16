import Foundation

@MainActor
private final class PreparationGate {
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
        fatalError("Fixture did not reach the preparation gate")
    }
}

private enum FixtureError: Error { case failed }

private final class PreparationQueueProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var started = false
    private var queued = false
    private var reads = 0

    func block() {
        condition.lock()
        started = true
        while held { condition.wait() }
        condition.unlock()
    }

    func markQueued() {
        condition.lock(); defer { condition.unlock() }
        queued = true
    }

    func read() -> String {
        condition.lock(); defer { condition.unlock() }
        reads += 1
        return "fixture-only-not-a-real-key"
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        held = false
        condition.broadcast()
    }

    func snapshot() -> (started: Bool, queued: Bool, reads: Int) {
        condition.lock(); defer { condition.unlock() }
        return (started, queued, reads)
    }
}

@MainActor
private final class PreparationCalls {
    var allowed = true
    var reads = 0, resizes = 0, uploads = 0
    var urls: [URL] = []
    var scales: [MarkdownImageScale] = []
    var read: (() async throws -> String?)?
    var resize: ((URL, MarkdownImageScale) async throws -> NodeImageUpload.Picture)?
    var upload: ((NodeImageUpload.Picture, String) async throws -> URL)?
    static let key = "fixture-only-not-a-real-key"
    static let picture = NodeImageUpload.Picture(data: Data([1, 2, 3]), name: "fixture.png", mime: "image/png")

    func clearHooks() { read = nil; resize = nil; upload = nil }
}

@MainActor
private final class PreparationFixture {
    let calls = PreparationCalls()
    let sizing: DraftImageSizing
    let first = URL(string: "https://example.invalid/first.png")!
    let second = URL(string: "https://example.invalid/second.png")!
    var markdown: String { "Before\n![first](\(first))\n![second](\(second))\nAfter" }
    var oneImage: String { "Before ![first](\(first)) After" }

    init(selected: Bool = true) {
        let calls = calls
        var requests = DraftImageSizing.Requests()
        requests.readKey = {
            calls.reads += 1
            if let read = calls.read { return try await read() }
            return PreparationCalls.key
        }
        requests.resize = { url, scale in
            calls.resizes += 1; calls.urls.append(url); calls.scales.append(scale)
            if let resize = calls.resize { return try await resize(url, scale) }
            return PreparationCalls.picture // No file decoding or image request.
        }
        requests.upload = { picture, key in
            calls.uploads += 1
            precondition(picture.data == PreparationCalls.picture.data && key == PreparationCalls.key,
                         "Only fake bytes and the fixture key may reach the fake uploader")
            if let upload = calls.upload { return try await upload(picture, key) }
            return URL(string: "https://example.invalid/upload-\(calls.uploads).png")!
        }
        sizing = DraftImageSizing(requests: requests)
        if selected {
            sizing.set(0.5, previewWidth: 800, for: first)
            sizing.set(0.5, previewWidth: 800, for: second)
        }
    }

    func prepare(_ text: String? = nil) async throws -> String {
        let calls = calls
        return try await sizing.prepare(text ?? markdown, authorized: { calls.allowed })
    }
}

@main
struct DraftImagePreparationChecks {
    @MainActor
    static func main() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { fatalError(label) }
        }
        func cancelled(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected CancellationError") }
            catch is CancellationError {}
        }
        func failed(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected injected failure") }
            catch FixtureError.failed {}
        }
        func until(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<2_000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            fatalError(label)
        }
        func noRequests(_ f: PreparationFixture) {
            require(f.calls.reads == 0 && f.calls.resizes == 0 && f.calls.uploads == 0,
                    "No credential, resizing or upload request may run")
        }

        do {
            let f = PreparationFixture(selected: false)
            let text = f.markdown
            let unchanged = try await f.prepare(text)
            require(unchanged == text, "Unselected/100% pictures preserve their original URLs")
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            let examples = "`![code](\(f.first))`\n~~~\n![code](\(f.first))\n~~~\n![表情](\(f.first))"
            let untouched = try await f.prepare(examples)
            require(untouched == examples, "Code examples and stickers are not publication resizing targets")
            noRequests(f)
            print("PASS unselected images, code and stickers preserve text without external requests")
        }

        for selected in [false, true] {
            let f = PreparationFixture(selected: selected)
            f.calls.allowed = false
            try await cancelled { _ = try await f.prepare() }
            f.calls.allowed = true
            let task = Task { @MainActor in try await f.prepare() }
            task.cancel()
            try await cancelled { _ = try await task.value }
            noRequests(f)
        }
        print("PASS denied or already-cancelled entry checks apply even without selected images")

        do {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let calls = f.calls
            calls.read = { calls.allowed = false; return PreparationCalls.key }
            try await cancelled { _ = try await f.prepare() }
            require(calls.reads == 1 && calls.resizes == 0 && calls.uploads == 0,
                    "Authorization lost during key read must stop before image preparation")
            calls.allowed = true
            calls.read = { calls.allowed = false; throw FixtureError.failed }
            try await cancelled { _ = try await f.prepare() }
            require(calls.reads == 2 && calls.resizes == 0 && calls.uploads == 0,
                    "Authorization loss also wins over a late credential provider failure")
            print("PASS post-key authorization stops both successful and failing credential reads")
        }

        for failure in [false, true] {
            for invalidation in ["authorization", "set", "reset", "restore", "retire", "cancel"] {
                let f = PreparationFixture(); defer { f.calls.clearHooks() }
                let gate = PreparationGate(), saved = f.sizing.sizes
                f.calls.read = {
                    await gate.wait()
                    if failure { throw FixtureError.failed }
                    return PreparationCalls.key
                }
                let task = Task { @MainActor in try await f.prepare(f.oneImage) }
                await gate.untilEntered()
                try await cancelled { _ = try await f.prepare(f.oneImage) }
                require(f.calls.reads == 1 && f.calls.resizes == 0 && f.calls.uploads == 0,
                        "Pending credentials retain single-flight ownership while MainActor can validate another request")
                switch invalidation {
                case "authorization": f.calls.allowed = false
                case "set": f.sizing.set(0.25, previewWidth: 800, for: f.first)
                case "reset": f.sizing.reset()
                case "restore": f.sizing.restore(saved)
                case "retire": f.sizing.cancelPendingCredentialRead()
                default: task.cancel()
                }
                gate.release()
                try await cancelled { _ = try await task.value }
                require(f.calls.reads == 1 && f.calls.resizes == 0 && f.calls.uploads == 0,
                        "An invalidated credential success or failure cannot resize, upload, or populate the result cache")
                if invalidation == "reset" {
                    require(f.sizing.sizes.isEmpty, "A late credential read cannot undo a draft reset")
                }
                f.calls.allowed = true
                f.calls.clearHooks()
                f.sizing.set(0.5, previewWidth: 800, for: f.first)
                let prepared = try await f.prepare(f.oneImage)
                require(prepared.contains("upload-1.png") && f.calls.reads == 2 &&
                        f.calls.resizes == 1 && f.calls.uploads == 1,
                        "Rejected credential results release ownership and leave a fresh authorized retry possible")
            }
        }
        print("PASS asynchronous key waits reject account, draft mutation and cancellation on both success and failure")

        for invalidation in ["authorization", "set", "reset", "restore", "retire", "cancel"] {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.draft-queued-read")
            let probe = PreparationQueueProbe()
            let f = PreparationFixture(), saved = f.sizing.sizes
            defer { probe.release(); f.calls.clearHooks() }
            let blocker = Task { @MainActor in try await worker.run { probe.block() } }
            try await until("The fake worker blocker never started") { probe.snapshot().started }
            f.calls.read = {
                try await worker.run(onQueued: { probe.markQueued() }) { probe.read() }
            }
            var settled = false
            let pending = Task { @MainActor in
                defer { settled = true }
                return try await f.prepare(f.oneImage)
            }
            try await until("The draft credential read never entered the queue") { probe.snapshot().queued }
            switch invalidation {
            case "authorization":
                f.calls.allowed = false
                f.sizing.cancelPendingCredentialRead()
            case "set": f.sizing.set(0.25, previewWidth: 800, for: f.first)
            case "reset": f.sizing.reset()
            case "restore": f.sizing.restore(saved)
            case "retire": f.sizing.cancelPendingCredentialRead()
            default: pending.cancel()
            }
            try await until("A cancelled queued draft read still waits for the active backend") { settled }
            try await cancelled { _ = try await pending.value }
            require(probe.snapshot().reads == 0 && f.calls.resizes == 0 && f.calls.uploads == 0,
                    "Retiring a queued credential read must skip the backend, image work and uploads")
            probe.release()
            try await blocker.value
            // This tail completes only after the queue passes the cancelled
            // request, proving it is skipped when the blocker is released.
            try await worker.run {}
            require(probe.snapshot().reads == 0, "Queue drain must not revive an obsolete credential request")
            f.calls.allowed = true
            f.calls.clearHooks()
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            let result = try await f.prepare(f.oneImage)
            require(result.contains("upload-1.png") && f.calls.reads == 2 &&
                    f.calls.resizes == 1 && f.calls.uploads == 1,
                    "A cancelled queued read releases preparation ownership for a fresh authorized retry")
        }
        print("PASS confirmed queued draft reads cancel before backend entry on mutation, retirement and parent cancellation")

        for throwsAfterWait in [false, true] {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate()
            f.calls.resize = { _, _ in
                await gate.wait()
                if throwsAfterWait { throw FixtureError.failed }
                return PreparationCalls.picture
            }
            let sizes = f.sizing.sizes
            let task = Task { @MainActor in try await f.prepare() }
            await gate.untilEntered()
            f.calls.allowed = false; gate.release()
            try await cancelled { _ = try await task.value }
            require(f.calls.reads == 1 && f.calls.resizes == 1 && f.calls.uploads == 0 && f.sizing.sizes == sizes,
                    "A stale resize must not upload, start a second image, or alter draft choices")
            f.calls.allowed = true; f.calls.clearHooks()
            _ = try await f.prepare(f.oneImage)
            require(f.calls.reads == 2 && f.calls.resizes == 2 && f.calls.uploads == 1,
                    "Aborted resize must release its reservation and permit a fresh preparation")
        }
        print("PASS authorization loss during resize blocks uploads and dominates late errors")

        for throwsAfterWait in [false, true] {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate()
            f.calls.upload = { _, _ in
                await gate.wait()
                if throwsAfterWait { throw FixtureError.failed }
                return URL(string: "https://example.invalid/stale-result.png")!
            }
            let original = f.markdown, sizes = f.sizing.sizes
            let task = Task { @MainActor in try await f.prepare(original) }
            await gate.untilEntered()
            f.calls.allowed = false; gate.release()
            try await cancelled { _ = try await task.value }
            require(f.calls.reads == 1 && f.calls.resizes == 1 && f.calls.uploads == 1 &&
                    f.sizing.sizes == sizes && f.markdown == original,
                    "Stale upload must not start another image or replace the original draft")
            f.calls.allowed = true; f.calls.clearHooks()
            let prepared = try await f.prepare()
            require(f.calls.reads == 3 && f.calls.resizes == 3 && f.calls.uploads == 3 &&
                    !prepared.contains("stale-result"), "Stale successful upload must not enter the retry cache")
        }
        print("PASS stale upload completions cannot populate cache or proceed to another image")

        for stage in ["resize", "upload"] {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate()
            if stage == "resize" {
                f.calls.resize = { _, _ in await gate.wait(); return PreparationCalls.picture }
            } else {
                f.calls.upload = { _, _ in
                    await gate.wait(); return URL(string: "https://example.invalid/cancelled-result.png")!
                }
            }
            let task = Task { @MainActor in try await f.prepare() }
            await gate.untilEntered()
            task.cancel(); gate.release()
            try await cancelled { _ = try await task.value }
            require(f.calls.reads == 1 && f.calls.resizes == 1 &&
                    f.calls.uploads == (stage == "resize" ? 0 : 1), "Cancellation stops after the in-flight stage")
            f.calls.clearHooks()
            let priorUploads = f.calls.uploads
            _ = try await f.prepare(f.oneImage)
            require(f.calls.reads == 2 && f.calls.resizes == 2 && f.calls.uploads == priorUploads + 1,
                    "A cancelled result must not be cached and must release single-flight state")
        }
        print("PASS task cancellation during resize or upload prevents further work and cached results")

        for mutation in ["set", "reset", "restore"] {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate(), saved = f.sizing.sizes
            f.calls.upload = { _, _ in
                await gate.wait(); return URL(string: "https://example.invalid/pre-mutation-result.png")!
            }
            let task = Task { @MainActor in try await f.prepare(f.oneImage) }
            await gate.untilEntered()
            switch mutation {
            case "set": f.sizing.set(0.25, previewWidth: 800, for: f.first)
            case "reset": f.sizing.reset()
            default: f.sizing.restore(saved)
            }
            gate.release()
            try await cancelled { _ = try await task.value }
            if mutation == "reset" { require(f.sizing.sizes.isEmpty, "Reset must not be undone by old completion") }
            f.calls.clearHooks()
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            let prepared = try await f.prepare(f.oneImage)
            require(f.calls.reads == 2 && f.calls.resizes == 2 && f.calls.uploads == 2 &&
                    !prepared.contains("pre-mutation-result"), "Mutation must invalidate in-flight cache insertion")
        }
        print("PASS set/reset/restore generations prevent old uploads from reviving stale state")

        do {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate()
            f.calls.resize = { _, _ in await gate.wait(); return PreparationCalls.picture }
            let task = Task { @MainActor in try await f.prepare(f.oneImage) }
            await gate.untilEntered()
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            gate.release()
            let result = try await task.value
            require(result.contains("upload-1.png") && f.calls.uploads == 1,
                    "Writing an identical selection must not invalidate a legitimate preparation")
            print("PASS unchanged size selections do not cancel a valid preparation")
        }

        do {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let gate = PreparationGate()
            f.calls.resize = { _, _ in await gate.wait(); return PreparationCalls.picture }
            let first = Task { @MainActor in try await f.prepare(f.oneImage) }
            await gate.untilEntered()
            try await cancelled { _ = try await f.prepare(f.oneImage) }
            require(f.calls.reads == 1 && f.calls.resizes == 1 && f.calls.uploads == 0,
                    "Overlapping preparation must be rejected before a second external request")
            gate.release(); _ = try await first.value
            f.calls.clearHooks()
            _ = try await f.prepare(f.oneImage)
            require(f.calls.reads == 1 && f.calls.resizes == 1 && f.calls.uploads == 1,
                    "Rejected competitor must not invalidate the first request or its completed cache")
            print("PASS single-flight rejection leaves the original request and cache ownership intact")
        }

        do {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let second = f.second
            f.calls.resize = { url, _ in
                if url == second { throw FixtureError.failed }
                return PreparationCalls.picture
            }
            let source = "![one](\(f.first))\n![duplicate](\(f.first))\n![two](\(f.second))"
            let sizes = f.sizing.sizes
            try await failed { _ = try await f.prepare(source) }
            require(f.calls.reads == 2 && f.calls.resizes == 2 && f.calls.uploads == 1 && f.sizing.sizes == sizes,
                    "First image may complete while second failure leaves all draft selections intact")
            f.calls.clearHooks()
            let result = try await f.prepare(source)
            require(f.calls.reads == 3 && f.calls.resizes == 3 && f.calls.uploads == 2,
                    "Valid retry must retain the first completed cache and only prepare the failed second image")
            require(result.components(separatedBy: "upload-1.png").count - 1 == 2 && result.contains("upload-2.png"),
                    "Repeated original URLs share one upload and replacements retain their exact occurrences")
            print("PASS legitimate partial failure retry preserves completed cache and deduplicates URLs")
        }

        do {
            let f = PreparationFixture()
            _ = try await f.prepare(f.oneImage)
            let sizes = f.sizing.sizes
            f.sizing.set(0.25, previewWidth: 800, for: f.first)
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            _ = try await f.prepare(f.oneImage)
            require(f.calls.uploads == 1, "An unchanged cached URL/scale remains reusable after selection changes")
            f.sizing.restore(sizes)
            _ = try await f.prepare(f.oneImage)
            require(f.calls.uploads == 2, "Restore must clear upload cache even when restoring equal selections")
            f.sizing.reset()
            f.sizing.set(0.5, previewWidth: 800, for: f.first)
            _ = try await f.prepare(f.oneImage)
            require(f.calls.uploads == 3, "Reset must clear completed upload cache")
            let other = PreparationFixture()
            _ = try await other.prepare(other.oneImage)
            require(other.calls.uploads == 1, "Separate sizing instances must never share uploaded results")
            print("PASS restore/reset clear completed caches while separate draft instances stay isolated")
        }

        do {
            let f = PreparationFixture()
            _ = try await f.prepare(f.oneImage)
            f.calls.allowed = false
            try await cancelled { _ = try await f.prepare(f.oneImage) }
            f.calls.allowed = true
            var checks = 0
            try await cancelled {
                _ = try await f.sizing.prepare(f.oneImage, authorized: { checks += 1; return checks < 4 })
            }
            require(checks >= 4 && f.calls.reads == 1 && f.calls.resizes == 1 && f.calls.uploads == 1,
                    "Cached paths must recheck authorization through their final return, without new requests")
            print("PASS cached results cannot bypass entry or final authorization checks")
        }

        do {
            let f = PreparationFixture(); defer { f.calls.clearHooks() }
            let sizes = f.sizing.sizes
            for key in [nil, ""] as [String?] {
                f.calls.read = { key }
                do { _ = try await f.prepare(); fatalError("Expected missing fixture key") }
                catch NodeImageError.missingKey {}
            }
            require(f.calls.reads == 2 && f.calls.resizes == 0 && f.calls.uploads == 0 && f.sizing.sizes == sizes,
                    "Missing keys must not resize/upload or erase saved selections")
            f.calls.clearHooks()
            f.calls.upload = { _, _ in throw FixtureError.failed }
            try await failed { _ = try await f.prepare(f.oneImage) }
            f.calls.clearHooks()
            _ = try await f.prepare(f.oneImage)
            require(f.calls.reads == 4 && f.calls.resizes == 2 && f.calls.uploads == 2 && f.sizing.sizes == sizes,
                    "Ordinary upload failures propagate and release the lock without caching or clearing draft choices")
            print("PASS ordinary key/upload failures preserve selections and allow a clean retry")
        }
    }
}
