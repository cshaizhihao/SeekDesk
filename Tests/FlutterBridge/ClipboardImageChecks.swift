import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

@MainActor
private final class ClipboardGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async {
        for _ in 0..<10_000 { if entered { return }; await Task.yield() }
        fatalError("Fixture did not reach clipboard gate")
    }
}

private actor ClipboardTimer {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func fire() { let current = waiters; waiters.removeAll(); current.values.forEach { $0.resume() } }
    func untilWaiting() async {
        for _ in 0..<10_000 { if !waiters.isEmpty { return }; await Task.yield() }
        fatalError("Fixture expiry timer did not start")
    }
}

/// A controlled codec suspension on a worker, never an actual image decode.
private final class ClipboardDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var started = false
    func wait() { lock.lock(); started = true; lock.unlock(); signal.wait() }
    func release() { signal.signal() }
    private func isEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    func untilEntered() async {
        for _ in 0..<100_000 { if isEntered() { return }; await Task.yield() }
        fatalError("Fixture codec did not start")
    }
}

private final class ClipboardCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class ClipboardMemory {
    var text: String?, png: Data?, tiff: Data?
    var change = 1, textReads = 0, pngReads = 0, tiffReads = 0
    var changeOnText = false, changeOnImage = false
    var now = Date(timeIntervalSince1970: 1000)
    var key: String? = "fixture-only-key"
    var keyReads = 0, keyWrites = 0, uploads = 0, pages = 0
    var keyError: Error?, uploadError: Error?
    var keyGate: ClipboardGate?, uploadGate: ClipboardGate?, optionsGate: ClipboardGate?
    var uploadedData: [Data] = []
    var keyReadCancelled = false, uploadCancelled = false
    var destination = URL(string: "https://example.invalid/clipboard.png")!
}

@MainActor
private final class ClipboardFixture {
    let suite = "cc.seekdesk.qa.clipboard-image." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let memory = ClipboardMemory()
    let timer = ClipboardTimer()

    init(signedIn: Bool = true, codec: NativeComposerClipboard.Codec = .init()) {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        if signedIn { context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10)) }
        else { context.session.observeAccount(false) }
        let memory = memory, timer = timer
        var clipboard = NativeComposerClipboard.Dependencies()
        clipboard.pasteboard = .init(
            changeCount: { memory.change },
            text: { memory.textReads += 1; if memory.changeOnText { memory.change += 1 }; return memory.text },
            png: { memory.pngReads += 1; if memory.changeOnImage { memory.change += 1 }; return memory.png },
            tiff: { memory.tiffReads += 1; return memory.tiff })
        clipboard.codec = codec
        clipboard.now = { memory.now }
        clipboard.sleep = { _ in try await timer.wait() }
        var requests = NativeForumServices.Requests()
        requests.uploadImage = { _, _ in fatalError("Clipboard tests must not select or upload files") }
        requests.uploadClipboardImage = { picture, key in
            precondition(key == memory.key && picture.mime == "image/png" && picture.name == "clipboard.png")
            memory.uploads += 1; memory.uploadedData.append(picture.data)
            if let gate = memory.uploadGate { await gate.wait() }
            memory.uploadCancelled = Task.isCancelled
            if let error = memory.uploadError { throw error }
            return memory.destination
        }
        requests.options = { publisher, _, _ in
            if let gate = memory.optionsGate { await gate.wait() }
            publisher.phase = .ready
        }
        requests.preparePage = { _, _, _ in memory.pages += 1; fatalError("Clipboard fixture must never prepare forum pages") }
        requests.publish = { _, _, _, _ in fatalError("Clipboard fixture must never publish") }
        requests.sendReply = { _, _, _ in fatalError("Clipboard fixture must never reply") }
        let keys = NativeForumServices.KeyStore(
            configured: { memory.key != nil },
            read: {
                memory.keyReads += 1
                let key = memory.key, error = memory.keyError
                if let gate = memory.keyGate { await gate.wait() }
                memory.keyReadCancelled = Task.isCancelled
                if let error { throw error }
                return key
            },
            save: { memory.keyWrites += 1; memory.key = $0 },
            remove: { memory.key = nil })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys, clipboard: clipboard)
        let services = services
        context.accessChanged = { services.invalidate() }
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        ["documentID": "fixture-document", "operationID": 1, "accessRevision": context.session.accessRevision]
            .merging(values) { _, value in value }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func capture(_ values: [String: Any] = [:]) async throws -> String {
        let result = try await call("system.captureComposerPaste", values)
        guard result["kind"] as? String == "image", let token = result["token"] as? String,
              result["mime"] as? String == "image/png", (result["byteCount"] as? Int ?? 0) > 0 else {
            fatalError("Expected an image DTO")
        }
        return token
    }
    func upload(_ token: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await call("images.uploadClipboardSnapshot", values.merging(["token": token]) { _, token in token })
    }
    func release(_ token: String, _ values: [String: Any] = [:]) async throws -> Bool {
        try await call("images.releaseClipboardSnapshot", values.merging(["token": token]) { _, token in token })["released"] as? Bool == true
    }
    func busy() async throws -> Bool { try await call("discussion.getDraft")["uploading"] as? Bool == true }
    func changeAccount() { context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10)) }
    func close() { services.dispose(); context.accessChanged = nil; defaults.removePersistentDomain(forName: suite) }
}

@main
struct ClipboardImageChecks {
    private static func picture(_ type: UTType, frames: Int = 1) -> Data {
        let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        for _ in 0..<frames { CGImageDestinationAddImage(destination, context.makeImage()!, nil) }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor
    static func main() async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
        func reject(_ code: String, _ action: () async throws -> Void) async throws {
            do { try await action(); fatalError("Expected \(code)") }
            catch let error as NativeBridgeError { require(error.code == code, "Expected \(code), got \(error.code)") }
        }
        func cancelled(_ action: () async throws -> Void) async throws {
            do { try await action(); fatalError("Expected cancellation") } catch is CancellationError {}
        }
        let png = picture(.png), tiff = picture(.tiff)

        for text in ["Plain text", " ", "\n", "\t"] {
            let f = ClipboardFixture(signedIn: false); defer { f.close() }
            f.memory.text = text; f.memory.png = Data([0])
            let result = try await f.call("system.captureComposerPaste")
            require(result["text"] as? String == text && result["kind"] as? String == "text", "Nonempty text wins unchanged")
            require(f.memory.pngReads == 0 && f.memory.tiffReads == 0 && f.memory.keyReads == 0 && f.memory.uploads == 0,
                    "Text cannot touch image providers, credentials or upload")
        }
        print("PASS explicit guest text capture preserves whitespace and bypasses all image/key/upload work")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            require(f.memory.textReads == 0, "Service initialization never reads the clipboard")
            let empty = try await f.call("system.captureComposerPaste")
            require(empty["kind"] as? String == "empty", "Empty board is explicit")
            f.memory.text = ""; f.memory.png = png; f.memory.tiff = Data([0]); f.memory.key = nil
            let token = try await f.capture()
            require(f.memory.tiffReads == 1 && f.memory.keyReads == 0, "PNG has priority over TIFF and capture does not read keys")
            let busy = try await f.busy(); require(!busy, "A token does not reserve the upload lock")
            _ = try await f.call("images.setKey", ["key": "fixture-new-key"])
            f.memory.png = Data([9]); f.memory.change += 1
            let result = try await f.upload(token)
            require(f.memory.uploadedData == [png] && f.memory.pngReads == 2, "Upload uses the frozen initial PNG without rereading")
            require(result["markdown"] as? String == "![image](https://example.invalid/clipboard.png)", "Successful upload returns one insertion")
            require(f.memory.keyWrites == 1 && f.memory.keyReads == 1, "Initial key setup succeeds before consuming the snapshot")
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(token) }
        }
        print("PASS empty classification, PNG priority, initial key setup and frozen single-use image snapshot")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.tiff = tiff
            let token = try await f.capture(); _ = try await f.upload(token)
            let encoded = f.memory.uploadedData[0]
            require(encoded.starts(with: [137, 80, 78, 71]), "Real TIFF is converted into PNG")
            let source = CGImageSourceCreateWithData(encoded as CFData, nil)!
            require(CGImageSourceGetCount(source) == 1, "Converted image stays single frame")
            f.memory.tiff = picture(.tiff, frames: 2)
            try await reject("clipboard_image_frames") { _ = try await f.capture() }
            f.memory.png = Data([0, 1, 2])
            try await reject("clipboard_image_invalid") { _ = try await f.capture() }
            f.memory.png = Data()
            try await reject("clipboard_image_size") { _ = try await f.capture() }
        }
        print("PASS real small PNG/TIFF codec, corrupt and empty data, and multi-page rejection before bitmap allocation")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.text = "text"; f.memory.changeOnText = true
            try await reject("clipboard_changed") { _ = try await f.call("system.captureComposerPaste") }
            f.memory.changeOnText = false; f.memory.text = nil; f.memory.png = png; f.memory.changeOnImage = true
            try await reject("clipboard_changed") { _ = try await f.capture() }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "Changed board cannot proceed to external stages")
        }
        print("PASS pasteboard changeCount prevents mixed text and image snapshots")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            let invalidOperations: [Any] = [0, -1, true, 1.0, 1.5, "1", NSNull()]
            for operation in invalidOperations {
                try await reject("invalid_clipboard_operation") { _ = try await f.capture(["operationID": operation]) }
            }
            let invalidDocuments: [Any] = ["", String(repeating: "x", count: 257), 1, NSNull()]
            for document in invalidDocuments {
                try await reject("invalid_clipboard_operation") { _ = try await f.capture(["documentID": document]) }
            }
            require(f.memory.textReads == 0, "Invalid identities fail before clipboard reads")
            f.memory.png = png
            let token = try await f.capture()
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(token, ["documentID": "other"]) }
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(token, ["operationID": 2]) }
            let wrong = try await f.release(token, ["documentID": "other"])
            require(!wrong && f.memory.keyReads == 0, "Wrong document cannot consume or release another snapshot")
            _ = try await f.upload(token)
        }
        print("PASS strict bounded document/operation identity and cross-document token validation before key access")

        do {
            try NativeComposerClipboard.validateByteCount(100 * 1024 * 1024)
            for count in [0, -1, 100 * 1024 * 1024 + 1, Int.max] {
                try await reject("clipboard_image_size") { try NativeComposerClipboard.validateByteCount(count) }
            }
            let counter = ClipboardCounter()
            for (metadata, code) in [
                (NativeComposerClipboard.Metadata(width: 6001, height: 4000, frames: 1), "clipboard_image_pixels"),
                (.init(width: Double.greatestFiniteMagnitude, height: Double.greatestFiniteMagnitude, frames: 1), "clipboard_image_pixels"),
                (.init(width: .infinity, height: 1, frames: 1), "clipboard_image_invalid"),
                (.init(width: .nan, height: 1, frames: 1), "clipboard_image_invalid"),
                (.init(width: 0, height: 1, frames: 1), "clipboard_image_invalid"),
                (.init(width: 3, height: 2, frames: 2), "clipboard_image_frames"),
            ] {
                var codec = NativeComposerClipboard.Codec()
                codec.metadata = { _, _ in metadata }
                codec.encodePNG = { _, _ in counter.increment(); return png }
                try await reject(code) { _ = try codec.prepare(png, .png) }
            }
            require(counter.value == 0, "All rejected metadata must stop before decode/conversion")
            var codec = NativeComposerClipboard.Codec()
            codec.metadata = { _, _ in .init(width: 6000, height: 4000, frames: 1) }
            codec.encodePNG = { _, _ in png }
            let accepted = try codec.prepare(png, .tiff)
            require(accepted == png, "Exactly 24 MP remains allowed")
            codec.encodePNG = { _, _ in Data() }
            try await reject("clipboard_image_size") { _ = try codec.prepare(png, .tiff) }
        }
        print("PASS 100MB and 24MP boundary checks, overflow-safe metadata guards and encoded byte validation without huge allocations")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            let old = try await f.capture()
            let newer = try await f.capture(["operationID": 2])
            let staleReleased = try await f.release(old)
            require(!staleReleased, "Old token cannot release the new operation")
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(old) }
            let released = try await f.release(newer, ["operationID": 2])
            let again = try await f.release(newer, ["operationID": 2])
            require(released && !again, "Release is idempotent")
            let current = try await f.capture(["operationID": 3])
            await f.timer.untilWaiting()
            f.memory.now = f.memory.now.addingTimeInterval(121)
            await f.timer.fire()
            for _ in 0..<20 { await Task.yield() }
            let expiredRelease = try await f.release(current, ["operationID": 3])
            require(!expiredRelease, "Timer proactively releases bytes without a subsequent consume")
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(current, ["operationID": 3]) }
            require(f.memory.keyReads == 0, "Expired tokens do not read credentials")
        }
        print("PASS one pending snapshot, stale release isolation, idempotence and proactive timer expiry")

        do {
            let f = ClipboardFixture(signedIn: false); defer { f.close() }
            f.memory.png = png
            let token = try await f.capture()
            try await reject("stale_authorization") { _ = try await f.upload(token) }
            require(f.memory.keyReads == 0, "Guest cannot consume an image")
            f.changeAccount()
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(token) }
            let current = try await f.capture(["operationID": 2])
            _ = try await f.upload(current, ["operationID": 2])
        }
        print("PASS guest capture does not grant upload access and account transitions invalidate old tokens")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            let token = try await f.capture(), gate = ClipboardGate()
            f.memory.uploadGate = gate
            let first = Task { @MainActor in try await f.upload(token) }
            await gate.untilEntered()
            let busy = try await f.busy(); require(busy, "Actual clipboard upload reserves media lock")
            for method in ["discussion.publish", "discussion.discard", "reader.sendReply", "reader.edit.begin"] {
                try await reject("uploading") { _ = try await f.call(method, ["confirmed": true, "url": "https://www.nodeseek.com/post-123-1", "topicID": "123", "floor": 0]) }
            }
            try await reject("uploading") { _ = try await f.call("images.setKey", ["key": "fixture-changed"]) }
            let released = try await f.release(token); require(released, "Release matches an in-flight token")
            let next = try await f.capture(["operationID": 2]), secondGate = ClipboardGate()
            f.memory.uploadGate = secondGate
            let second = Task { @MainActor in try await f.upload(next, ["operationID": 2]) }
            await secondGate.untilEntered()
            gate.release()
            try await reject("stale_authorization") { _ = try await first.value }
            require(f.memory.uploadCancelled, "Release cancels the old upload task")
            let stillBusy = try await f.busy(); require(stillBusy, "Old completion cannot release a newer upload")
            let oldRelease = try await f.release(token); require(!oldRelease, "Old release remains harmless")
            secondGate.release(); _ = try await second.value
            let finallyBusy = try await f.busy(); require(!finallyBusy && f.memory.pages == 0, "Successful upload frees lock without forum operations")
        }
        print("PASS upload mutual exclusion, in-flight release cancellation and old completion cannot unlock a newer upload")

        for invalidation in ["account", "dispose", "cancel", "expiry"] {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            let token = try await f.capture(), gate = ClipboardGate()
            f.memory.uploadGate = gate
            let uploading = Task { @MainActor in try await f.upload(token) }
            await gate.untilEntered()
            switch invalidation {
            case "account": f.changeAccount()
            case "dispose": f.services.dispose()
            case "cancel": uploading.cancel()
            default:
                await f.timer.untilWaiting(); f.memory.now = f.memory.now.addingTimeInterval(121)
                await f.timer.fire(); for _ in 0..<20 { await Task.yield() }
            }
            gate.release()
            if invalidation == "dispose" || invalidation == "cancel" {
                try await cancelled { _ = try await uploading.value }
            } else {
                try await reject("stale_authorization") { _ = try await uploading.value }
            }
            require(f.memory.uploadCancelled, "Invalidation cancels the provider task")
        }
        print("PASS account, disposal, task cancellation and expiry reject late upload results")

        for failure in [false, true] {
            for invalidation in ["account", "dispose", "cancel", "expiry", "replacement"] {
                let f = ClipboardFixture(); defer { f.close() }
                f.memory.png = png
                let token = try await f.capture(), gate = ClipboardGate()
                f.memory.keyGate = gate
                if failure {
                    f.memory.keyError = NSError(domain: "fixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-clipboard-key"])
                }
                let uploading = Task { @MainActor in try await f.upload(token) }
                await gate.untilEntered()
                let status = try await f.call("images.keyStatus")
                require(status["configured"] as? Bool == true && f.memory.uploads == 0,
                        "Status remains responsive while clipboard upload waits for credentials")
                switch invalidation {
                case "account": f.changeAccount()
                case "dispose": f.services.dispose()
                case "cancel": uploading.cancel()
                case "replacement":
                    let pngReads = f.memory.pngReads
                    try await reject("uploading") { _ = try await f.capture(["operationID": 2]) }
                    let stillBusy = try await f.busy()
                    require(stillBusy && f.memory.pngReads == pngReads && f.memory.keyReads == 1,
                            "Rejected replacement preserves the active upload and never rereads the pasteboard")
                    let released = try await f.release(token)
                    require(released, "The original token remains valid until explicitly released")
                    _ = try await f.capture(["operationID": 2])
                default:
                    await f.timer.untilWaiting(); f.memory.now = f.memory.now.addingTimeInterval(121)
                    await f.timer.fire(); for _ in 0..<20 { await Task.yield() }
                }
                gate.release()
                if invalidation == "dispose" || invalidation == "cancel" {
                    try await cancelled { _ = try await uploading.value }
                } else {
                    try await reject("stale_authorization") { _ = try await uploading.value }
                }
                require(f.memory.keyReadCancelled && f.memory.uploads == 0,
                        "Obsolete clipboard key success/error must receive cancellation and never begin network work")
            }
        }
        print("PASS pending clipboard-key success/error rejected after account/dispose/cancel/expiry/token replacement")

        for failure in [false, true] {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            let token = try await f.capture(), old = ClipboardGate(), current = ClipboardGate()
            f.memory.keyGate = old
            if failure {
                f.memory.keyError = NSError(domain: "fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-old-key"])
            }
            let first = Task { @MainActor in try await f.upload(token) }
            await old.untilEntered()
            let released = try await f.release(token)
            require(released, "Release cancels an upload still waiting for its credential")
            let next = try await f.capture(["operationID": 2])
            f.memory.keyGate = current; f.memory.keyError = nil
            let second = Task { @MainActor in try await f.upload(next, ["operationID": 2]) }
            await current.untilEntered()
            old.release()
            try await reject("stale_authorization") { _ = try await first.value }
            let stillBusy = try await f.busy()
            require(stillBusy && f.memory.keyReadCancelled && f.memory.uploads == 0,
                    "Late key success/error cannot clear or start the newer clipboard operation")
            try await reject("uploading") { _ = try await f.call("images.removeKey") }
            current.release(); _ = try await second.value
            require(f.memory.uploads == 1 && !f.memory.keyReadCancelled,
                    "Only the current key read reaches the uploader and remains uncancelled")
        }
        print("PASS released pending clipboard key cannot clear a newer reservation on late success or failure")

        for invalidation in ["account", "dispose", "cancel", "replacement"] {
            let gate = ClipboardDecodeGate()
            var codec = NativeComposerClipboard.Codec()
            codec.metadata = { _, _ in gate.wait(); return .init(width: 3, height: 2, frames: 1) }
            codec.encodePNG = { data, _ in data }
            let f = ClipboardFixture(codec: codec); defer { f.close() }
            f.memory.png = png
            let capturing = Task { @MainActor in try await f.capture() }
            await gate.untilEntered()
            switch invalidation {
            case "account": f.changeAccount()
            case "dispose": f.services.dispose()
            case "cancel": capturing.cancel()
            default:
                f.memory.text = "newer text"
                let result = try await f.call("system.captureComposerPaste", ["operationID": 2])
                require(result["text"] as? String == "newer text", "Replacement capture owns the current generation")
            }
            gate.release()
            try await cancelled { _ = try await capturing.value }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "Obsolete conversion cannot continue to credentials/upload")
        }
        print("PASS detached conversion cannot resurrect tokens after cancellation, replacement, account change or disposal")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            var token = try await f.capture()
            f.memory.key = nil
            try await reject("image_key_missing") { _ = try await f.upload(token) }
            f.memory.key = "fixture-only-key"
            f.memory.keyError = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-KEY"])
            token = try await f.capture(["operationID": 2])
            try await reject("image_key_store") { _ = try await f.upload(token, ["operationID": 2]) }
            f.memory.keyError = nil
            f.memory.uploadError = NativeBridgeError(code: "DO-NOT-EXPOSE-KEY", message: "DO-NOT-EXPOSE-KEY")
            token = try await f.capture(["operationID": 3])
            do { _ = try await f.upload(token, ["operationID": 3]); fatalError("Expected sanitized upload failure") }
            catch let error as NativeBridgeError {
                require(error.code == "clipboard_upload_failed" && !error.message.contains("DO-NOT-EXPOSE"), "Provider diagnostics never escape")
            }
            f.memory.uploadError = NodeImageError.invalidKey
            token = try await f.capture(["operationID": 4])
            try await reject("image_key_invalid") { _ = try await f.upload(token, ["operationID": 4]) }
            f.memory.uploadError = nil
            f.memory.destination = URL(string: "http://example.invalid/unsafe.png")!
            token = try await f.capture(["operationID": 5])
            try await reject("clipboard_upload_failed") { _ = try await f.upload(token, ["operationID": 5]) }
            let busy = try await f.busy(); require(!busy, "All upload/key failures release busy state")
        }
        print("PASS missing/failed credentials and provider failures are sanitized and release consumed snapshots")

        do {
            let f = ClipboardFixture(); defer { f.close() }
            f.memory.png = png
            let token = try await f.capture(), gate = ClipboardGate()
            f.memory.optionsGate = gate
            let options = Task { @MainActor in try await f.call("discussion.loadOptions") }
            await gate.untilEntered()
            try await reject("discussion_options_loading") { _ = try await f.upload(token) }
            gate.release(); _ = try await options.value
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(token) }
            require(f.memory.keyReads == 0, "Busy preflight releases token before reading a key")
            let next = try await f.capture(["operationID": 2]), picker = ClipboardGate()
            let selecting = Task { @MainActor in try await f.services.chooseImage(f.args()) { await picker.wait(); return nil } }
            await picker.untilEntered()
            try await reject("uploading") { _ = try await f.upload(next, ["operationID": 2]) }
            picker.release(); _ = try await selecting.value
            try await reject("clipboard_snapshot_expired") { _ = try await f.upload(next, ["operationID": 2]) }
        }
        print("PASS options and file-picker reservations reject clipboard consumption before any key or upload work")
    }
}
