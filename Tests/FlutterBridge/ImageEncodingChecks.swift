import AppKit
import FlutterMacOS
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    fatalError("Image encoding fixture did not reach its lifecycle event")
}

private func bitmap(_ width: Int = 32, height: Int = 24) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return context.makeImage()!
}

/// Holds the actual synchronous codec entry on a background worker, allowing
/// tests to measure overlap and cancellation while ImageIO owns its bitmap.
private final class EncodingProbe: @unchecked Sendable {
    struct Snapshot {
        var started = 0
        var active = 0
        var peak = 0
        var activeOriginals = 0
        var peakOriginals = 0
        var mainThread = 0
        var widths: [Int] = []
    }
    enum FixtureError: Error { case requestedFailure }

    private let condition = NSCondition()
    private var state = Snapshot()
    private var held: Bool
    private var released = Set<Int>()
    private var failures: Int
    private let originalWidths: Set<Int>

    init(held: Bool = true, failures: Int = 0, originalWidths: Set<Int> = []) {
        self.held = held
        self.failures = failures
        self.originalWidths = originalWidths
    }

    var codec: NativeImageEncoder.Codec { .init(encode: { [self] in try run($0) }) }

    private func enter(_ image: CGImage) -> (original: Bool, failure: Bool) {
        condition.lock(); defer { condition.unlock() }
        let original = originalWidths.contains(image.width)
        state.started += 1
        let id = state.started
        state.widths.append(image.width)
        state.active += 1
        state.peak = max(state.peak, state.active)
        if original {
            state.activeOriginals += 1
            state.peakOriginals = max(state.peakOriginals, state.activeOriginals)
        }
        if Thread.isMainThread { state.mainThread += 1 }
        let failure = failures > 0
        if failure { failures -= 1 }
        while held && !released.contains(id) { condition.wait() }
        return (original, failure)
    }

    private func finish(original: Bool) {
        condition.lock(); defer { condition.unlock() }
        state.active -= 1
        if original { state.activeOriginals -= 1 }
    }

    private func run(_ image: CGImage) throws -> Data {
        let entry = enter(image)
        defer { finish(original: entry.original) }
        if entry.failure { throw FixtureError.requestedFailure }
        return try NativeImageEncoder.encodePNG(image)
    }

    func release(_ id: Int? = nil) {
        condition.lock(); defer { condition.unlock() }
        if let id { released.insert(id) } else { held = false }
        condition.broadcast()
    }

    func snapshot() -> Snapshot { condition.lock(); defer { condition.unlock() }; return state }
}

private actor FetchGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func hasEntered() -> Bool { entered }
    func release() { waiting?.resume(); waiting = nil }
}

private final class LifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var released = 0
    func release() { lock.lock(); released += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return released }
}

private final class BitmapOwner {
    let probe: LifetimeProbe
    init(_ probe: LifetimeProbe) { self.probe = probe }
    deinit { probe.release() }
}

private func ownedBitmap(_ probe: LifetimeProbe) -> CGImage {
    let count = 16 * 16 * 4
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4)
    pixels.initializeMemory(as: UInt8.self, repeating: 180, count: count)
    let owner = Unmanaged.passRetained(BitmapOwner(probe)).toOpaque()
    let provider = CGDataProvider(dataInfo: owner, data: pixels, size: count) { info, data, _ in
        UnsafeMutableRawPointer(mutating: data).deallocate()
        Unmanaged<BitmapOwner>.fromOpaque(info!).release()
    }!
    return CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@MainActor
private final class ImageBridgeFixture {
    let suite = "cc.seekdesk.qa.image-encoding." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices

    init(image: CGImage, codec: NativeImageEncoder.Codec, fetchGate: FetchGate? = nil,
         animation: ForumImageAnimation? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        context.session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 10))
        var requests = NativeForumServices.Requests()
        requests.image = { _, _ in
            if let fetchGate { await fetchGate.wait() }
            return ForumImageRequest.Bitmap(image: image, animation: animation)
        }
        requests.uploadImage = { _, _ in fatalError("Image encoding must never upload") }
        requests.uploadClipboardImage = { _, _ in fatalError("Image encoding must never upload clipboard data") }
        requests.preparePage = { _, _, _ in fatalError("Image encoding must never prepare a forum write") }
        requests.publish = { _, _, _, _ in fatalError("Image encoding must never publish") }
        requests.sendReply = { _, _, _ in fatalError("Image encoding must never reply") }
        services = NativeForumServices(context: context, requests: requests,
            keyStore: .init(configured: { fatalError("Image encoding must never query Keychain status") },
                            read: { fatalError("Image encoding must never read Keychain") },
                            save: { _ in fatalError("Image encoding must never write Keychain") },
                            remove: { fatalError("Image encoding must never remove Keychain entries") }),
            imageCodec: codec,
            customStickerLibrary: { fatalError("Image encoding must never read the user's sticker library") })
        let services = services
        context.accessChanged = { services.invalidate() }
    }

    func load(_ kind: String = "post") async throws -> [String: Any] {
        try await services.handle("images.load", ["url": "https://fixture.invalid/image.png", "kind": kind,
                                                 "accessRevision": context.session.accessRevision]) as! [String: Any]
    }
    func changeAccount() { context.session.observeIdentity(.init(signedIn: true, id: 202, name: "Other", floorsPerPage: 10)) }
    func close() { services.dispose(); context.accessChanged = nil; defaults.removePersistentDomain(forName: suite) }
}

@main
struct ImageEncodingChecks {
    private static func cancelled<T>(_ task: Task<T, Error>) async throws {
        do { _ = try await task.value; fatalError("Expected cancelled image encoding") }
        catch is CancellationError {}
    }

    private static func stale<T>(_ task: Task<T, Error>) async throws {
        do { _ = try await task.value; fatalError("Expected stale image authorization") }
        catch let error as NativeBridgeError { require(error.code == "stale_authorization", "Wrong stale error") }
    }

    private static func verifyPNG(_ data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Invalid encoded PNG") }
        require(CGImageSourceGetType(source) as String? == UTType.png.identifier && CGImageSourceGetCount(source) == 1,
                "Encoder changed the PNG wire representation")
        require(image.width == width && image.height == height, "Encoder changed image dimensions")
    }

    @MainActor
    static func main() async throws {
        do {
            let image = bitmap()
            let bytes = NSMutableData()
            let writer = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 2, nil)!
            for delay in [0.12, 0.28] {
                CGImageDestinationAddImage(writer, image, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
                ] as CFDictionary)
            }
            require(CGImageDestinationFinalize(writer), "Could not make the GIF fixture")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
            defer { try? FileManager.default.removeItem(at: file) }
            try (bytes as Data).write(to: file)
            let decoded = try ForumImageRequest.decode(file)
            let fixture = ImageBridgeFixture(image: decoded.image,
                codec: .init(encode: { _ in fatalError("Animation went through the PNG codec") }),
                animation: decoded.animation)
            defer { fixture.close() }
            let result = try await fixture.load()
            let returned = result["bytes"] as? FlutterStandardTypedData
            require(result["mime"] as? String == "image/gif" && returned?.data == bytes as Data,
                    "GIF animation bytes and timing must reach Flutter unchanged")
            print("Passed animated GIF decode and bridge delivery with original frame timing.")
        }

        do {
            let image = bitmap(), probe = EncodingProbe(), encoder = NativeImageEncoder(codec: probe.codec)
            let tasks = (0..<8).map { _ in Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 1) } }
            try await eventually { probe.snapshot().started == 1 }
            try await Task.sleep(for: .milliseconds(30))
            require(probe.snapshot().started == 1, "Identical bitmap subscribers encoded independently")
            probe.release()
            var outputs: [Data] = []
            for task in tasks { outputs.append(try await task.value) }
            require(outputs.count == 8 && outputs.allSatisfy { $0 == outputs[0] }, "Shared PNG results differ")
            verifyPNG(outputs[0], width: 32, height: 24)
            require(probe.snapshot().mainThread == 0, "PNG codec ran on the main thread")
            _ = try await encoder.encode(image, kind: .post, owner: 101, revision: 1)
            require(probe.snapshot().started == 2, "Completed PNG was retained in an additional native cache")
            print("Passed 8 same-bitmap subscribers -> 1 real PNG encode, off-main execution, correct dimensions and no completed byte cache.")
        }

        do {
            let image = bitmap(), other = bitmap(), probe = EncodingProbe(), encoder = NativeImageEncoder(codec: probe.codec)
            let tasks = [
                Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 1) },
                Task { try await encoder.encode(image, kind: .avatar, owner: 101, revision: 1) },
                Task { try await encoder.encode(image, kind: .original, owner: 101, revision: 1) },
                Task { try await encoder.encode(image, kind: .post, owner: 202, revision: 1) },
                Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 2) },
                Task { try await encoder.encode(other, kind: .post, owner: 101, revision: 1) }
            ]
            try await eventually { probe.snapshot().started == 2 }
            probe.release()
            for task in tasks { _ = try await task.value }
            require(probe.snapshot().started == 6, "Bitmap identity, kind, owner or revision was omitted from the encoder key")
            print("Passed bitmap identity, post/avatar/original kind, account owner and revision separation.")
        }

        do {
            let probe = EncodingProbe(originalWidths: [211, 212, 213]), encoder = NativeImageEncoder(codec: probe.codec)
            let originals = [211, 212, 213].map { width in
                Task { try await encoder.encode(bitmap(width), kind: .original, owner: 101, revision: 1) }
            }
            try await eventually { probe.snapshot().started == 1 }
            let posts = [41, 42, 43, 44].map { width in
                Task { try await encoder.encode(bitmap(width), kind: .post, owner: 101, revision: 1) }
            }
            try await eventually { probe.snapshot().started == 2 }
            try await Task.sleep(for: .milliseconds(30))
            let held = probe.snapshot()
            require(held.started == 2 && held.active == 2 && held.activeOriginals == 1,
                    "Encoder exceeded 2 total / 1 original slots or blocked ordinary images behind originals")
            probe.release()
            for task in originals + posts { _ = try await task.value }
            let finished = probe.snapshot()
            require(finished.started == 7 && finished.peak == 2 && finished.peakOriginals == 1 && finished.mainThread == 0,
                    "Measured encoder overlap exceeded its limits")
            print("Passed measured encoder concurrency: total 2, original 1, ordinary images bypass queued originals.")
        }

        do {
            let image = bitmap(), probe = EncodingProbe(), encoder = NativeImageEncoder(codec: probe.codec)
            let leaving = Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 1) }
            try await eventually { probe.snapshot().started == 1 }
            let staying = Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 1) }
            try await Task.sleep(for: .milliseconds(30))
            leaving.cancel()
            try await cancelled(leaving)
            require(probe.snapshot().active == 1, "One subscriber cancelled the shared synchronous codec")
            probe.release()
            verifyPNG(try await staying.value, width: 32, height: 24)
            require(probe.snapshot().started == 1, "Remaining subscriber lost its shared conversion")
            print("Passed individual cancellation without interrupting another subscriber.")
        }

        do {
            let firstImage = bitmap(51), secondImage = bitmap(52)
            let probe = EncodingProbe(), encoder = NativeImageEncoder(codec: probe.codec)
            let first = Task { try await encoder.encode(firstImage, kind: .post, owner: 101, revision: 1) }
            try await eventually { probe.snapshot().started == 1 }
            let second = Task { try await encoder.encode(secondImage, kind: .post, owner: 101, revision: 1) }
            try await eventually { probe.snapshot().started == 2 }
            first.cancel(); second.cancel()
            try await cancelled(first); try await cancelled(second)
            let replacement = Task { try await encoder.encode(firstImage, kind: .post, owner: 101, revision: 1) }
            let queued = Task { try await encoder.encode(bitmap(53), kind: .post, owner: 101, revision: 1) }
            try await Task.sleep(for: .milliseconds(30))
            require(probe.snapshot().started == 2 && probe.snapshot().active == 2,
                    "Cancelled synchronous codecs released their slots before exiting")
            queued.cancel(); try await cancelled(queued)
            probe.release(1)
            try await eventually { probe.snapshot().started == 3 }
            require(probe.snapshot().active == 2, "Replacement failed to enter the single released slot")
            probe.release()
            verifyPNG(try await replacement.value, width: 51, height: 24)
            try await eventually { probe.snapshot().active == 0 }
            require(probe.snapshot().started == 3 && probe.snapshot().peak == 2,
                    "Cancelled queued conversion ran or an abandoned generation corrupted its successor")
            print("Passed final-subscriber cancellation, retained synchronous slots, cancelled queue and same-bitmap replacement.")
        }

        do {
            let image = bitmap(), probe = EncodingProbe(failures: 1), encoder = NativeImageEncoder(codec: probe.codec)
            let tasks = (0..<4).map { _ in Task { try await encoder.encode(image, kind: .post, owner: 101, revision: 1) } }
            try await eventually { probe.snapshot().started == 1 }
            try await Task.sleep(for: .milliseconds(30))
            probe.release()
            for task in tasks {
                do { _ = try await task.value; fatalError("Expected shared encoding failure") }
                catch is EncodingProbe.FixtureError {}
            }
            require(probe.snapshot().started == 1, "Encoding failure did not reach all shared subscribers")
            verifyPNG(try await encoder.encode(image, kind: .post, owner: 101, revision: 1), width: 32, height: 24)
            require(probe.snapshot().started == 2, "Failed conversion poisoned retry")
            let preCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await encoder.encode(image, kind: .post, owner: 101, revision: 1)
            }
            try await cancelled(preCancelled)
            require(probe.snapshot().started == 2, "Already-cancelled conversion entered ImageIO")
            print("Passed shared failure, clean retry and already-cancelled request rejection.")
        }

        do {
            let probe = LifetimeProbe(), encoder = NativeImageEncoder()
            func transient() async throws -> Data {
                try await encoder.encode(ownedBitmap(probe), kind: .post, owner: 101, revision: 1)
            }
            let bytes = try await transient()
            verifyPNG(bytes, width: 16, height: 16)
            try await eventually { probe.count == 1 }
            // Keep both the encoder and returned bytes alive while verifying
            // the input provider is freed: neither is a hidden bitmap cache.
            withExtendedLifetime((encoder, bytes)) {}
            print("Passed bitmap/provider release after completion while encoded bytes and encoder remain alive.")
        }

        do {
            let image = bitmap(63), probe = EncodingProbe()
            let first = ImageBridgeFixture(image: image, codec: probe.codec)
            let second = ImageBridgeFixture(image: image, codec: probe.codec)
            defer { first.close(); second.close() }
            let firstTask = Task { try await first.load() }, secondTask = Task { try await second.load() }
            try await eventually { probe.snapshot().started == 2 }
            probe.release()
            for value in [try await firstTask.value, try await secondTask.value] {
                guard let bytes = value["bytes"] as? FlutterStandardTypedData else { fatalError("Bridge omitted PNG bytes") }
                require(value["mime"] as? String == "image/png" && value["width"] as? Int == 63 && value["height"] as? Int == 24,
                        "Bridge changed its image DTO")
                verifyPNG(bytes.data, width: 63, height: 24)
            }
            require(probe.snapshot().started == 2, "Separate service instances shared an encoder")
            print("Passed independent service encoder ownership and real PNG bridge DTO compatibility.")
        }

        for action in ["account", "dispose", "cancel"] {
            let probe = EncodingProbe(held: false), gate = FetchGate()
            let fixture = ImageBridgeFixture(image: bitmap(), codec: probe.codec, fetchGate: gate)
            defer { fixture.close() }
            let load = Task { try await fixture.load() }
            try await eventually { await gate.hasEntered() }
            switch action {
            case "account": fixture.changeAccount()
            case "dispose": fixture.services.dispose()
            default: load.cancel()
            }
            await gate.release()
            if action == "account" { try await stale(load) } else { try await cancelled(load) }
            require(probe.snapshot().started == 0, "Invalid request entered encoding after image fetch")
        }
        print("Passed account change, service disposal and cancellation after fetch without starting PNG work.")

        for action in ["account", "dispose", "cancel"] {
            let probe = EncodingProbe(), fixture = ImageBridgeFixture(image: bitmap(), codec: probe.codec)
            defer { fixture.close() }
            let load = Task { try await fixture.load() }
            try await eventually { probe.snapshot().started == 1 }
            switch action {
            case "account": fixture.changeAccount()
            case "dispose": fixture.services.dispose()
            default: load.cancel()
            }
            if action == "cancel" { try await cancelled(load) }
            probe.release()
            if action == "account" { try await stale(load) }
            else if action == "dispose" { try await cancelled(load) }
            try await eventually { probe.snapshot().active == 0 }
        }
        print("Passed final account/disposal checks and prompt subscriber cancellation during synchronous PNG work.")
        print("All native image encoding checks passed with generated bitmaps, controlled codecs and stub fetches only.")
    }
}
