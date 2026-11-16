import AppKit
import Foundation
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers
import WebKit

@MainActor
private final class CustomStickerGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async {
        for _ in 0..<20_000 { if entered { return }; await Task.yield() }
        fatalError("Custom sticker fixture did not reach its gate")
    }
}

@MainActor
private final class CustomStickerMemory {
    var libraryReads = 0, keyReads = 0, uploads = 0, replies = 0
    var key: String? = "fixture-DO-NOT-EXPOSE-key"
    var keyError: Error?, uploadError: Error?
    var keyGate: CustomStickerGate?, uploadGate: CustomStickerGate?, writeGate: CustomStickerGate?
    var uploadedData: [Data] = [], uploadedMIME: [String] = []
    var keyReadCancelled = false, uploadCancelled = false
    var destination = URL(string: "https://example.invalid/sticker.png")!
}

private func customStickerPNG() -> Data {
    let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
    let data = NSMutableData()
    let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
    return data as Data
}

/// Keep a recognizable PNG while truncating its image metadata or data. A
/// nonincremental PNG source can report `.statusComplete` before dimensions are
/// readable, so the fixture must not assume a particular decoder status. It
/// still satisfies the former source/count/type-only upload guard.
private func customStickerTruncatedPNG(_ complete: Data) -> Data {
    for length in (8..<complete.count).reversed() {
        let bytes = Data(complete.prefix(length))
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let format = CGImageSourceGetType(source), let type = UTType(format as String),
              type == .png, type.preferredMIMEType == "image/png" else { continue }
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let width = info?[kCGImagePropertyPixelWidth as String] as? Double ?? .nan
        let height = info?[kCGImagePropertyPixelHeight as String] as? Double ?? .nan
        if CGImageSourceGetStatus(source) != .statusComplete ||
            !width.isFinite || !height.isFinite || width <= 0 || height <= 0 {
            return bytes
        }
    }
    fatalError("PNG fixture must expose recognizable, incomplete image bytes")
}

@MainActor
private final class CustomStickerFixture {
    let suite = "cc.seekdesk.qa.custom-sticker." + UUID().uuidString
    let defaults: UserDefaults
    let root: URL, libraryDirectory: URL, sourceDirectory: URL
    let library: StickerLibrary
    let context: SeekDeskBridgeContext
    let services: NativeForumServices
    let memory = CustomStickerMemory()
    let png = customStickerPNG()
    let topicURL = Forum.home.appendingPathComponent("post-123-1")

    init(signedIn: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("seekdesk-custom-fixture-" + UUID().uuidString, isDirectory: true)
        libraryDirectory = root.appendingPathComponent("managed", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        library = StickerLibrary(directory: libraryDirectory)
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        if signedIn { context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10)) }
        else { context.session.observeAccount(false) }
        let memory = memory, library = library
        var requests = NativeForumServices.Requests()
        requests.uploadImage = { _, _ in fatalError("Custom sticker tests must never invoke file selection upload") }
        requests.uploadClipboardImage = { picture, key in
            precondition(key == memory.key)
            memory.uploads += 1
            memory.uploadedData.append(picture.data)
            memory.uploadedMIME.append(picture.mime)
            if let gate = memory.uploadGate { await gate.wait() }
            memory.uploadCancelled = Task.isCancelled
            if let error = memory.uploadError { throw error }
            return memory.destination
        }
        requests.preparePage = { _, _, session in ForumWebPage(dataStore: session.dataStore) }
        requests.sendReply = { _, _, _ in
            memory.replies += 1
            let gate = memory.writeGate
            return Task { if let gate { await gate.wait() } }
        }
        requests.publish = { _, _, _, _ in fatalError("Custom sticker fixture must not publish") }
        requests.saveEdit = { _, _, _ in fatalError("Custom sticker fixture must not edit the forum") }
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
            save: { _ in fatalError("Custom sticker fixture must not save a real key") },
            remove: { fatalError("Custom sticker fixture must not delete a real key") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys,
            customStickerLibrary: { memory.libraryReads += 1; return library })
        let services = services
        context.accessChanged = { services.invalidate() }
        context.session.edit("Fixture reply", for: "123")
    }

    func args(_ values: [String: Any] = [:]) -> [String: Any] {
        values.merging(["accessRevision": context.session.accessRevision]) { _, revision in revision }
    }
    func call(_ method: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        try await services.handle(method, args(values)) as? [String: Any] ?? [:]
    }
    func source(_ name: String = "picture.png", data: Data? = nil) throws -> URL {
        let file = sourceDirectory.appendingPathComponent(name)
        try (data ?? png).write(to: file)
        return file
    }
    func seed() async throws -> (UUID, String) {
        let group = try library.create("Fixture")
        _ = try await library.importImages([try source()], to: group, authorized: { true })
        let item = try library.checkedGroups().first(where: { $0.id == group })!.images.first!
        return (group, item)
    }
    func upload(_ group: UUID, _ item: String) async throws -> [String: Any] {
        try await call("stickers.custom.upload", ["groupID": group.uuidString, "itemID": item,
            "requestId": "sticker-fixture-" + UUID().uuidString])
    }
    func busy() async throws -> Bool { try await call("discussion.getDraft")["uploading"] as? Bool == true }
    func changeAccount() { context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10)) }
    func close() {
        services.dispose()
        context.accessChanged = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@main
struct CustomStickerChecks {
    @MainActor
    static func main() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        func reject(_ code: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected \(code)") }
            catch let error as NativeBridgeError {
                require(error.code == code, "Expected \(code), got \(error.code)")
                require(!error.message.contains("DO-NOT-EXPOSE") && !error.message.contains("/private/") &&
                    !error.message.contains("fixture-secret"), "Native failure leaked provider or filesystem details")
            }
        }
        func cancelled(_ operation: () async throws -> Void) async throws {
            do { try await operation(); fatalError("Expected cancellation") } catch is CancellationError {}
        }

        do {
            let f = try CustomStickerFixture(signedIn: false); defer { f.close() }
            require(f.memory.libraryReads == 0, "Initializing native services must not open a sticker library")
            let official = try await f.call("stickers.list")
            require(official["packs"] is [[String: Any]] && f.memory.libraryReads == 0,
                "Official metadata must stay independent of custom library access")
            let created = try await f.call("stickers.custom.create", ["name": "  本地表情  "])
            let id = UUID(uuidString: created["groupID"] as! String)!
            let listed = try await f.call("stickers.custom.list")
            let groups = listed["groups"] as! [[String: Any]]
            require(groups.count == 1 && groups[0]["name"] as? String == "本地表情", "Guest can manage local groups")
            let encoded = String(data: try JSONSerialization.data(withJSONObject: listed), encoding: .utf8)!
            require(!encoded.contains(f.root.path) && !encoded.contains("file://"), "Library metadata cannot expose local paths")
            try await reject("sticker_duplicate") { _ = try await f.call("stickers.custom.create", ["name": "本地表情"]) }
            try await reject("sticker_name") { _ = try await f.call("stickers.custom.create", ["name": "  "]) }
            try await reject("stale_authorization") { _ = try await f.upload(id, "not-uploaded.png") }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "Guest management never reads keys or uploads")
            print("PASS lazy library dependency, unchanged official metadata, guest groups and path-free DTO")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let group = try f.library.create("Import")
            let good = try f.source(), bad = try f.source("broken.png", data: Data([0, 1, 2]))
            let before = try Data(contentsOf: f.libraryDirectory.appendingPathComponent("groups.json"))
            let cancellation = try await f.services.chooseStickerImages(f.args(["groupID": group.uuidString])) { nil }
            require(cancellation["cancelled"] as? Bool == true && cancellation["importedCount"] as? Int == 0,
                "Picker cancellation is an explicit no-op")
            let afterCancel = try Data(contentsOf: f.libraryDirectory.appendingPathComponent("groups.json"))
            require(before == afterCancel, "Cancel cannot rewrite the index")
            let imported = try await f.services.chooseStickerImages(f.args(["groupID": group.uuidString])) { [good, bad] }
            require(imported["cancelled"] as? Bool == false && imported["importedCount"] as? Int == 1 &&
                imported["skippedCount"] as? Int == 1, "Mixed selection must report committed and skipped counts")
            let item = try f.library.checkedGroups().first!.images.first!
            let managed = try f.library.resolve(groupID: group, itemID: item)
            let managedBytes = try Data(contentsOf: managed)
            require(managed != good && managedBytes == f.png, "Imported file is a managed copy")
            try FileManager.default.removeItem(at: good)
            let thumbnail = try await f.call("stickers.custom.thumbnail", ["groupID": group.uuidString, "itemID": item])
            let bytes = (thumbnail["bytes"] as! FlutterStandardTypedData).data
            require(bytes.starts(with: [137, 80, 78, 71]), "Thumbnail is PNG and survives removing the chooser source")
            _ = try await f.call("stickers.custom.remove", ["groupID": group.uuidString, "itemID": item])
            let afterRemoval = try f.library.checkedGroups()
            require(afterRemoval.first!.images.isEmpty, "Removing an item updates the group")
            require(!FileManager.default.fileExists(atPath: managed.path) && FileManager.default.fileExists(atPath: bad.path),
                "Removal deletes only the selected managed copy")
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "All import/thumbnail/remove work remains local")
            print("PASS chooser cancellation, partial import, managed copy, local PNG thumbnail and safe removal")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let other = try f.library.create("Other")
            let invalidMembership: [[String: Any]] = [
                ["groupID": "../not-a-group", "itemID": item],
                ["groupID": other.uuidString, "itemID": item],
                ["groupID": group.uuidString, "itemID": "missing.png"],
            ]
            for values in invalidMembership {
                try await reject("sticker_missing") {
                    _ = try await f.call("stickers.custom.upload", values.merging(["requestId": "sticker-fixture-1"]) { _, value in value })
                }
            }
            for id in ["../outside.png", "/absolute.png", "child/file.png", "..", "a\\b.png", "bad\u{0}.png"] {
                try await reject("sticker_invalid") { _ = try await f.upload(group, id) }
            }
            try await reject("sticker_invalid") {
                _ = try await f.call("stickers.custom.upload", ["groupID": group.uuidString, "itemID": item])
            }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "Invalid membership and paths fail before keys or upload")
            let stale = f.args(["groupID": group.uuidString, "itemID": item])
            f.changeAccount()
            try await reject("stale_authorization") { _ = try await f.services.handle("stickers.custom.remove", stale) }
            let afterStaleMutation = try f.library.checkedGroups()
            require(afterStaleMutation.first!.images == [item], "Stale mutations cannot alter the shared local library")
            print("PASS malformed IDs, traversal, group membership, required request identity and stale mutation guards")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let managed = try f.library.resolve(groupID: group, itemID: item)
            let original = try Data(contentsOf: managed)
            let result = try await f.upload(group, item)
            require(result["markdown"] as? String == "![表情](<https://example.invalid/sticker.png>)", "Custom insertion keeps its sticker label")
            require(f.memory.uploadedData == [original] && f.memory.uploadedMIME == ["image/png"], "Fake uploader receives frozen original bytes")
            let managedAfterUpload = try Data(contentsOf: managed)
            let sourceAfterUpload = try Data(contentsOf: f.sourceDirectory.appendingPathComponent("picture.png"))
            require(managedAfterUpload == original && sourceAfterUpload == original,
                "Upload cannot move, resize, delete or modify managed/source originals")
            let busy = try await f.busy(); require(!busy, "Completed upload releases the shared operation")
            print("PASS successful custom upload DTO, frozen source bytes, original retention and upload-lock cleanup")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            f.memory.key = nil
            try await reject("image_key_missing") { _ = try await f.upload(group, item) }
            f.memory.key = "fixture-DO-NOT-EXPOSE-key"
            f.memory.keyError = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-key"])
            try await reject("image_key_store") { _ = try await f.upload(group, item) }
            f.memory.keyError = nil
            f.memory.uploadError = NodeImageError.invalidKey
            try await reject("image_key_invalid") { _ = try await f.upload(group, item) }
            f.memory.uploadError = NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-key /private/fixture-secret"])
            try await reject("sticker_upload_failed") { _ = try await f.upload(group, item) }
            f.memory.uploadError = nil
            for destination in ["http://example.invalid/image.png", "https://user:DO-NOT-EXPOSE@example.invalid/image.png"] {
                f.memory.destination = URL(string: destination)!
                try await reject("sticker_upload_failed") { _ = try await f.upload(group, item) }
            }
            let managed = try f.library.resolve(groupID: group, itemID: item)
            try Data([0, 1, 2]).write(to: managed)
            let keys = f.memory.keyReads, uploads = f.memory.uploads
            try await reject("sticker_invalid") { _ = try await f.upload(group, item) }
            require(f.memory.keyReads == keys && f.memory.uploads == uploads, "Unreadable original fails before credential access")
            let busy = try await f.busy(); require(!busy, "Every failure releases its own upload reservation")
            print("PASS safe fixed errors for missing/keychain/key/provider/URL/corrupt original failures")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let managed = try f.library.resolve(groupID: group, itemID: item)
            let truncated = customStickerTruncatedPNG(f.png)
            let indexURL = f.libraryDirectory.appendingPathComponent("groups.json")
            let originalIndex = try Data(contentsOf: indexURL)
            try truncated.write(to: managed)
            try await reject("sticker_invalid") { _ = try await f.upload(group, item) }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0,
                "A recognizable but truncated imported image must fail before credentials or uploader")
            let managedAfterFailure = try Data(contentsOf: managed)
            let sourceAfterFailure = try Data(contentsOf: f.sourceDirectory.appendingPathComponent("picture.png"))
            let indexAfterFailure = try Data(contentsOf: indexURL)
            require(managedAfterFailure == truncated && sourceAfterFailure == f.png && indexAfterFailure == originalIndex,
                "Rejected truncated image cannot rewrite the managed file, original source or index")
            let busy = try await f.busy(); require(!busy, "Truncated image rejection releases the upload reservation")
            print("PASS imported image truncated afterward fails before credentials/upload and preserves local files")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let gate = CustomStickerGate(); f.memory.uploadGate = gate
            let task = Task { @MainActor in try await f.upload(group, item) }
            await gate.untilEntered()
            try await reject("uploading") { _ = try await f.upload(group, item) }
            try await reject("uploading") { _ = try await f.services.chooseImage(f.args()) { fatalError("Nested chooser opened") } }
            for (method, values) in [
                ("discussion.publish", ["feeAccepted": true] as [String: Any]),
                ("discussion.discard", ["confirmed": true]),
                ("reader.sendReply", ["url": f.topicURL.absoluteString]),
                ("reader.edit.save", ["url": f.topicURL.absoluteString]),
                ("reader.edit.cancel", ["url": f.topicURL.absoluteString]),
            ] { try await reject("uploading") { _ = try await f.call(method, values) } }
            _ = try await f.call("reader.updateReplyDraft", ["topicID": "123", "content": "Local edits remain available"])
            gate.release(); _ = try await task.value
            require(f.memory.uploads == 1 && f.memory.replies == 0, "Shared media lock prevents duplicate upload and forum writes")
            print("PASS custom/file upload mutual exclusion, submit/discard guards and local draft saving")
        }

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let gate = CustomStickerGate(); f.memory.writeGate = gate
            let task = Task { @MainActor in try await f.call("reader.sendReply", ["url": f.topicURL.absoluteString]) }
            await gate.untilEntered()
            try await reject("writing") { _ = try await f.upload(group, item) }
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "A reserved forum write rejects before local picture/key/upload work")
            gate.release(); _ = try await task.value
            print("PASS active forum write rejects custom upload before credential or provider access")
        }

        for invalidation in ["account", "cancel", "dispose"] {
            let f = try CustomStickerFixture(); defer { f.close() }
            let group = try f.library.create("Pending import"), source = try f.source()
            let gate = CustomStickerGate()
            let task = Task { @MainActor in
                try await f.services.chooseStickerImages(f.args(["groupID": group.uuidString])) { await gate.wait(); return [source] }
            }
            await gate.untilEntered()
            if invalidation == "account" { f.changeAccount() }
            else if invalidation == "dispose" { f.services.dispose() }
            else { task.cancel() }
            gate.release()
            if invalidation == "account" { try await reject("stale_authorization") { _ = try await task.value } }
            else { try await cancelled { _ = try await task.value } }
            let afterInvalidation = try f.library.checkedGroups()
            require(afterInvalidation.first!.images.isEmpty, "Invalidated chooser cannot import late selected files")
            require(f.memory.keyReads == 0 && f.memory.uploads == 0, "Import invalidation cannot touch external services")
        }
        print("PASS account/task/disposal boundaries around OS selection prevent late local imports")

        for invalidation in ["account", "cancel", "dispose"] {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let gate = CustomStickerGate(); f.memory.uploadGate = gate
            let task = Task { @MainActor in try await f.upload(group, item) }
            await gate.untilEntered()
            if invalidation == "account" { f.changeAccount() }
            else if invalidation == "dispose" { f.services.dispose() }
            else { task.cancel() }
            gate.release()
            if invalidation == "account" { try await reject("stale_authorization") { _ = try await task.value } }
            else { try await cancelled { _ = try await task.value } }
            require(f.memory.uploadCancelled, "Invalidation must cancel the provider task even when its fake ignores cancellation")
            let afterInvalidation = try f.library.checkedGroups()
            require(afterInvalidation.first!.images == [item], "Cancelled upload preserves the local library")
        }
        print("PASS account/task/disposal boundaries reject late upload insertions and preserve local originals")

        for failure in [false, true] {
            for invalidation in ["account", "logout", "cancel", "dispose"] {
                let f = try CustomStickerFixture(); defer { f.close() }
                let (group, item) = try await f.seed()
                let gate = CustomStickerGate(); f.memory.keyGate = gate
                if failure {
                    f.memory.keyError = NSError(domain: "fixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-custom-key"])
                }
                let task = Task { @MainActor in try await f.upload(group, item) }
                await gate.untilEntered()
                let status = try await f.call("images.keyStatus")
                require(status["configured"] as? Bool == true && f.memory.uploads == 0,
                        "Status stays responsive while custom sticker waits for credentials")
                switch invalidation {
                case "account": f.changeAccount()
                case "logout": f.context.session.observeAccount(false)
                case "dispose": f.services.dispose()
                default: task.cancel()
                }
                gate.release()
                if invalidation == "account" || invalidation == "logout" {
                    try await reject("stale_authorization") { _ = try await task.value }
                } else {
                    try await cancelled { _ = try await task.value }
                }
                let groups = try f.library.checkedGroups()
                require(f.memory.keyReadCancelled && f.memory.uploads == 0 && groups.first!.images == [item],
                        "Obsolete custom key success/error receives cancellation without network or local mutation")
            }
        }
        print("PASS pending custom-key success/error across account/logout/cancel/dispose never starts network")

        for failure in [false, true] {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let old = CustomStickerGate(), current = CustomStickerGate()
            f.memory.keyGate = old
            if failure {
                f.memory.keyError = NSError(domain: "fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "DO-NOT-EXPOSE-old-custom-key"])
            }
            let first = Task { @MainActor in try await f.upload(group, item) }
            await old.untilEntered()
            f.changeAccount(); f.memory.keyGate = current; f.memory.keyError = nil
            let second = Task { @MainActor in try await f.upload(group, item) }
            await current.untilEntered()
            old.release()
            try await reject("stale_authorization") { _ = try await first.value }
            let busy = try await f.busy()
            require(busy && f.memory.keyReadCancelled && f.memory.uploads == 0,
                    "A stale custom key result cannot clear or start a newer account's upload")
            try await reject("uploading") { _ = try await f.upload(group, item) }
            current.release(); _ = try await second.value
            require(f.memory.uploads == 1 && !f.memory.keyReadCancelled,
                    "Only the current custom key read reaches the uploader without stale cancellation")
        }
        print("PASS late custom-key success/error cannot release or cancel a newer account's upload reservation")

        for invalidation in ["dispose", "cancelBeforeEntry"] {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            if invalidation == "dispose" {
                f.services.dispose()
                for method in ["stickers.custom.list", "stickers.custom.create", "stickers.custom.remove", "stickers.custom.thumbnail", "stickers.custom.upload"] {
                    try await cancelled {
                        _ = try await f.call(method, ["groupID": group.uuidString, "itemID": item,
                            "name": "Must not exist", "requestId": "sticker-fixture-disposed"])
                    }
                }
                try await cancelled {
                    _ = try await f.services.chooseStickerImages(f.args(["groupID": group.uuidString])) {
                        fatalError("Disposed service opened an import chooser")
                    }
                }
            } else {
                let task = Task { @MainActor in try await f.upload(group, item) }
                task.cancel()
                try await cancelled { _ = try await task.value }
            }
            require(f.memory.libraryReads == 0 && f.memory.keyReads == 0 && f.memory.uploads == 0,
                "Cancelled/disposed entry must not resolve the library, read credentials or upload")
        }
        print("PASS cancelled/disposed entry never starts library, chooser, credential or upload work")

        do {
            let f = try CustomStickerFixture(); defer { f.close() }
            let (group, item) = try await f.seed()
            let oldGate = CustomStickerGate(), currentGate = CustomStickerGate()
            f.memory.uploadGate = oldGate
            let old = Task { @MainActor in try await f.upload(group, item) }
            await oldGate.untilEntered()
            f.changeAccount(); f.memory.uploadGate = currentGate
            let current = Task { @MainActor in try await f.upload(group, item) }
            await currentGate.untilEntered()
            oldGate.release()
            try await reject("stale_authorization") { _ = try await old.value }
            let stillBusy = try await f.busy(); require(stillBusy, "Old upload finally cannot unlock the current account's upload")
            try await reject("uploading") { _ = try await f.upload(group, item) }
            currentGate.release(); _ = try await current.value
            let settled = try await f.busy(); require(!settled, "Current upload releases its own lock")
            print("PASS old account completion cannot release a newer custom upload reservation")
        }
    }
}
