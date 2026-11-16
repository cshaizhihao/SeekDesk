import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import WebKit

private final class DropDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    func wait() { lock.withLock { entered = true }; semaphore.wait() }
    func release() { semaphore.signal() }
    func untilEntered() async {
        for _ in 0..<100_000 {
            if lock.withLock({ entered }) { return }
            await Task.yield()
        }
        fatalError("Drop codec did not enter")
    }
}

@MainActor
private final class DropFixture {
    let suite = "cc.seekdesk.qa.composer-drop." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let root: URL

    init(codec: NativeComposerClipboard.Codec = .init()) throws {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("seekdesk-drop-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        var clipboard = NativeComposerClipboard.Dependencies()
        clipboard.codec = codec
        clipboard.pasteboard = .init(
            changeCount: { fatalError("Drop must not read the system clipboard") },
            text: { fatalError("Drop must not read clipboard text") },
            png: { fatalError("Drop must not read clipboard PNG") },
            tiff: { fatalError("Drop must not read clipboard TIFF") })
        // Capture and release tests use no upload/Keychain operations. An
        // explicit upload test replaces these after construction below.
        let calls = DropCalls()
        self.calls = calls
        var requests = NativeForumServices.Requests()
        requests.uploadImage = { _, _ in fatalError("Drop must upload its frozen bytes, not a path") }
        requests.uploadClipboardImage = { picture, key in
            precondition(key == "fixture-only-key" && picture.mime == "image/png")
            calls.uploads += 1
            calls.bytes = picture.data
            return URL(string: "https://example.invalid/dropped.png")!
        }
        let keyStore = NativeForumServices.KeyStore(
            configured: { true },
            read: { calls.keyReads += 1; return "fixture-only-key" },
            save: { _ in fatalError("Drop tests must not save keys") },
            remove: { fatalError("Drop tests must not remove keys") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keyStore, clipboard: clipboard)
        let services = services
        context.accessChanged = { services.invalidate() }
    }

    let calls: DropCalls
    var store: NativeComposerDropStore { services.composerDrop }
    func args(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["documentID": "drop-document", "operationID": 1, "accessRevision": context.session.accessRevision]
            .merging(extra) { _, new in new }
    }
    func target(_ revision: Int64 = 1, document: String = "drop-document") -> NativeComposerDropStore.Target {
        let accepted = store.update(["targetRevision": revision, "enabled": true, "documentID": document,
            "accessRevision": context.session.accessRevision, "left": 20.0, "top": 30.0, "width": 300.0, "height": 200.0],
            authorization: context.session.authorization)
        precondition(accepted)
        return store.target!
    }
    func file(_ bytes: Data, name: String = UUID().uuidString + ".txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    func offer(_ file: URL, revision: Int64 = 1) throws -> String {
        try store.offer(file, target: target(revision), authorization: context.session.authorization)
    }
    func call(_ method: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(extra)) as? [String: Any] ?? [:]
    }
    func capture(_ token: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        try await call("system.captureComposerDrop", ["dropToken": token].merging(extra) { _, new in new })
    }
    func close() {
        services.dispose()
        context.accessChanged = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class DropCalls { var keyReads = 0, uploads = 0; var bytes: Data? }

@MainActor private final class DropRenderView: NSView {
    override var isFlipped: Bool { true }
}

/// Implements the OS drag-session contract. The tests invoke the registered
/// NSView destination methods rather than calling the store or bridge directly.
@MainActor
private final class DropSession: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("cc.seekdesk.qa.drag." + UUID().uuidString))
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func files(_ urls: [URL]) {
        draggingPasteboard.clearContents()
        precondition(draggingPasteboard.writeObjects(urls.map { $0 as NSURL }))
    }
    func close() { draggingPasteboard.releaseGlobally() }
}

private func picture(_ type: UTType, frames: Int = 1) -> Data {
    let bytes = Data(repeating: 128, count: 4 * 4 * 4)
    let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

@main
struct ComposerDropChecks {
    @MainActor
    static func main() async throws {
        func reject(_ code: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); preconditionFailure("Expected \(code)") }
            catch let error as NativeBridgeError {
                precondition(error.code == code, "Expected \(code), got \(error.code)")
                precondition(!error.message.contains("seekdesk-drop-fixture") && !error.message.contains("fixture-only-key"))
            }
        }

        do {
            let f = try DropFixture(); defer { f.close() }
            let a = f.target(10)
            let auth = f.context.session.authorization
            precondition(f.store.target(at: CGPoint(x: 25, y: 35), authorization: auth) == a)
            precondition(f.store.target(at: CGPoint(x: 10, y: 35), authorization: auth) == nil)
            precondition(f.store.target(at: CGPoint(x: CGFloat.nan, y: 35), authorization: auth) == nil)
            let b = f.target(11, document: "second-document")
            precondition(!f.store.update(["targetRevision": 10, "enabled": false], authorization: auth))
            precondition(f.store.target == b, "A late old-scope disable must not clear the new editor")
            for invalid in [true, 12.5, -1, "12"] as [Any] {
                precondition(!f.store.update(["targetRevision": invalid, "enabled": false], authorization: auth))
            }
            for changed in [["width": -1], ["height": Double.infinity], ["left": true],
                            ["accessRevision": auth.revision + 1], ["documentID": ""]] as [[String: Any]] {
                let values: [String: Any] = ["targetRevision": 12, "enabled": true, "documentID": "drop-document",
                    "accessRevision": auth.revision, "left": 20, "top": 30, "width": 300, "height": 200]
                precondition(!f.store.update(values.merging(changed) { _, new in new }, authorization: auth))
            }
            precondition(f.store.update(["targetRevision": 12, "enabled": false], authorization: auth))
            precondition(f.store.target == nil)
            let event = a.event("drop", point: CGPoint(x: 25, y: 35), token: "opaque-token")
            precondition(event["targetRevision"] as? Int64 == 10 && event["documentID"] as? String == "drop-document")
            precondition(event["path"] == nil && event["url"] == nil)
            let view = NativeComposerDropView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            precondition(view.hitTest(CGPoint(x: 10, y: 10)) == nil && view.isFlipped)
            precondition(view.registeredDraggedTypes.contains(.fileURL))
            view.unregisterDraggedTypes()
            print("PASS monotonic target leases, geometry/type validation, opaque events and pointer-transparent drag view")
        }

        do {
            let f = try DropFixture(); defer { f.close() }
            _ = f.target()
            // A controller root wraps the flipped Flutter render view. Keep a
            // nonzero content origin to catch accidental root-coordinate use.
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let host = DropRenderView(frame: CGRect(x: 80, y: 60, width: 600, height: 400))
            root.addSubview(host)
            var events: [[String: Any]] = []
            var available = true
            let bridge = NativeComposerDropBridge(hostView: host, store: f.store,
                authorization: { f.context.session.authorization }, available: { available }, send: { events.append($0) })
            defer { bridge.dispose() }
            let view = host.subviews.last as! NativeComposerDropView
            precondition(view.frame == host.bounds && view.superview === host && view.hitTest(CGPoint(x: 40, y: 50)) == nil)
            precondition(root.subviews.count == 1 && root.subviews.first === host)
            host.setFrameSize(CGSize(width: 640, height: 420))
            precondition(view.frame == host.bounds, "The registered destination must follow render-view resizing")
            let session = DropSession(); defer { session.close() }
            let file = try f.file(picture(.png))
            session.files([file])
            session.draggingLocation = view.convert(CGPoint(x: 40, y: 50), to: nil)
            precondition(view.draggingEntered(session) == .copy)
            precondition(events.last?["phase"] as? String == "enter" && events.last?["x"] as? Double == 40)
            precondition(events.last?["y"] as? Double == 50 && events.last?["documentID"] as? String == "drop-document")
            precondition(view.draggingUpdated(session) == .copy && events.last?["phase"] as? String == "update")
            precondition(view.prepareForDragOperation(session) && view.performDragOperation(session))
            precondition(events.last?["phase"] as? String == "drop")
            let token = events.last?["dropToken"] as! String
            precondition(events.last?["path"] == nil && events.last?["url"] == nil)
            let result = try await f.capture(token)
            let snapshot = result["token"] as! String
            _ = try await f.call("images.releaseClipboardSnapshot", ["token": snapshot])
            view.draggingEnded(session)
            precondition(events.last?["phase"] as? String == "drop", "Finishing an accepted drop must not send an exit for an old hover")
            precondition(view.draggingEntered(session) == .copy)
            session.draggingLocation = view.convert(CGPoint(x: 5, y: 5), to: nil)
            precondition(view.draggingUpdated(session).isEmpty && events.last?["phase"] as? String == "exit")
            precondition(!view.prepareForDragOperation(session) && !view.performDragOperation(session))
            session.draggingLocation = view.convert(CGPoint(x: 40, y: 50), to: nil)
            session.draggingSourceOperationMask = .move
            precondition(view.draggingEntered(session).isEmpty)
            session.draggingSourceOperationMask = .copy
            session.files([file, try f.file(picture(.png))])
            precondition(view.draggingEntered(session).isEmpty && !view.performDragOperation(session))
            session.files([file])
            available = false
            precondition(view.draggingEntered(session).isEmpty && !view.performDragOperation(session))
            available = true
            precondition(view.draggingEntered(session) == .copy)
            view.draggingExited(session)
            precondition(events.last?["phase"] as? String == "exit")
            bridge.dispose()
            precondition(host.subviews.isEmpty && view.registeredDraggedTypes.isEmpty && f.store.target == nil)
            precondition(view.draggingEntered(session).isEmpty && f.calls.keyReads == 0 && f.calls.uploads == 0)
            print("PASS real AppKit destination callback forwarding, top-left coordinates, private drag pasteboard, opaque token capture, multi-file/outside/busy rejection and disposal")
        }

        let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
        for (name, bytes) in [("PNG", picture(.png)), ("JPEG", picture(.jpeg)),
                              ("TIFF", picture(.tiff)), ("WebP", webp)] {
            let f = try DropFixture(); defer { f.close() }
            let file = try f.file(bytes) // Deliberately wrong .txt extension.
            let drop = try f.offer(file)
            let result = try await f.capture(drop)
            precondition(result["kind"] as? String == "image" && result["mime"] as? String == "image/png")
            let token = result["token"] as! String
            precondition(result["url"] == nil && result["path"] == nil && f.calls.keyReads == 0)
            try await reject("composer_drop_expired") { _ = try await f.capture(drop) }
            try await reject("clipboard_snapshot_expired") {
                _ = try await f.call("images.uploadClipboardSnapshot", ["token": token, "documentID": "other"])
            }
            let uploaded = try await f.call("images.uploadClipboardSnapshot", ["token": token])
            precondition(uploaded["markdown"] as? String == "![image](https://example.invalid/dropped.png)")
            precondition(f.calls.uploads == 1 && f.calls.keyReads == 1)
            let image = CGImageSourceCreateWithData(f.calls.bytes! as CFData, nil)!
            precondition(CGImageSourceGetType(image) as String? == UTType.png.identifier)
            try await reject("clipboard_snapshot_expired") { _ = try await f.call("images.uploadClipboardSnapshot", ["token": token]) }
            precondition(FileManager.default.fileExists(atPath: file.path), "A copy drop must never delete its source")
            print("PASS \(name) detected from bytes, frozen PNG conversion, one-shot capture and fake upload with no clipboard reads")
        }

        do {
            let f = try DropFixture(); defer { f.close() }
            let file = try f.file(picture(.png))
            let drop = try f.offer(file)
            try await reject("composer_drop_expired") { _ = try await f.capture(drop, ["documentID": "wrong-document"]) }
            try await reject("invalid_clipboard_operation") { _ = try await f.capture(drop, ["operationID": true]) }
            // Disabling hover while the accepted drop enters its busy/key UI
            // must not invalidate the already accepted token.
            precondition(f.store.update(["targetRevision": 2, "enabled": false], authorization: f.context.session.authorization))
            let result = try await f.capture(drop)
            let token = result["token"] as! String
            let released = try await f.call("images.releaseClipboardSnapshot", ["token": token])
            precondition(released["released"] as? Bool == true && f.calls.uploads == 0)
            let old = try f.offer(file, revision: 3)
            let current = try f.offer(file, revision: 4)
            let oldRelease = try await f.call("system.releaseComposerDrop", ["dropToken": old])
            precondition(oldRelease["released"] as? Bool == false)
            let release = try await f.call("system.releaseComposerDrop", ["dropToken": current])
            precondition(release["released"] as? Bool == true)
            try await reject("composer_drop_expired") { _ = try await f.capture(current) }
            let accountDrop = try f.offer(file, revision: 5)
            f.context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10))
            precondition(f.store.target == nil)
            try await reject("composer_drop_expired") { _ = try await f.capture(accountDrop) }
            precondition(f.calls.keyReads == 0 && f.calls.uploads == 0)
            print("PASS document/operation ownership, busy-target deactivation, old release isolation, discard and account invalidation")
        }

        do {
            let f = try DropFixture(); defer { f.close() }
            for (name, data, error) in [("fake.png", Data("not an image".utf8), "clipboard_image_invalid"),
                                      ("empty.png", Data(), "clipboard_image_size"),
                                      ("animated.tiff", picture(.tiff, frames: 2), "clipboard_image_frames"),
                                      ("unsupported.gif", picture(.gif), "clipboard_image_invalid")] {
                let file = try f.file(data, name: name)
                let token = try f.offer(file)
                try await reject(error) { _ = try await f.capture(token) }
            }
            let oversized = try f.file(Data([1]), name: "oversize.png")
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(NodeImageUpload.sizeLimit + 1))
            try handle.close()
            let oversizeDrop = try f.offer(oversized)
            try await reject("clipboard_image_size") { _ = try await f.capture(oversizeDrop) }
            let directoryDrop = try f.offer(f.root)
            try await reject("clipboard_image_invalid") { _ = try await f.capture(directoryDrop) }
            let fifo = f.root.appendingPathComponent("fifo.png")
            precondition(mkfifo(fifo.path, 0o600) == 0)
            let fifoDrop = try f.offer(fifo)
            try await reject("clipboard_image_invalid") { _ = try await f.capture(fifoDrop) }
            precondition(f.calls.keyReads == 0 && f.calls.uploads == 0)
            print("PASS invalid signatures, empty/oversize files, multi-frame rejection and nonblocking directory/FIFO rejection")
        }

        do {
            let f = try DropFixture(); defer { f.close() }
            var now = Date(timeIntervalSince1970: 1000)
            let store = NativeComposerDropStore(now: { now }, lifetime: 1)
            let auth = f.context.session.authorization
            precondition(store.update(["enabled": true, "targetRevision": 1, "documentID": "drop-document",
                "accessRevision": auth.revision, "left": 0, "top": 0, "width": 200, "height": 100], authorization: auth))
            let file = try f.file(picture(.png))
            let token = try store.offer(file, target: store.target!, authorization: auth)
            now.addTimeInterval(2)
            let identity = try NativeComposerClipboard.Identity(f.args(), authorization: auth)
            try await reject("composer_drop_expired") { _ = try store.consume(token, identity: identity) }
            store.invalidate()
            print("PASS token expiry without file or credential reads")
        }

        do {
            let gate = DropDecodeGate()
            var codec = NativeComposerClipboard.Codec()
            let metadata = codec.metadata
            codec.metadata = { data, representation in gate.wait(); return try metadata(data, representation) }
            let f = try DropFixture(codec: codec); defer { f.close() }
            let token = try f.offer(f.file(picture(.png)))
            let conversion = Task { @MainActor in try await f.capture(token) }
            await gate.untilEntered()
            f.context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10))
            gate.release()
            do { _ = try await conversion.value; preconditionFailure("Old account drop converted") }
            catch is CancellationError {}
            precondition(f.calls.keyReads == 0 && f.calls.uploads == 0)
            print("PASS account change during detached conversion cancels the old snapshot without upload")
        }
        print("All composer drop checks passed; generated local files and fake uploads only, no system clipboard/keychain/network access.")
    }
}
