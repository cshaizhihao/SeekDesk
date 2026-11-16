import AppKit
import CoreFoundation
import ImageIO
import UniformTypeIdentifiers

/// One bounded, memory-only paste snapshot. Only an explicit capture reads the
/// pasteboard; readiness checks, credentials and token cleanup never read it.
@MainActor
final class NativeComposerClipboard {
    struct Identity: Equatable {
        let documentID: String
        let operationID: Int
        let authorization: ForumSession.Authorization

        init(_ args: [String: Any], authorization: ForumSession.Authorization) throws {
            guard let document = args["documentID"] as? String,
                  !document.isEmpty, document.utf8.count <= 256,
                  let number = args["operationID"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  let operation = Int(number.stringValue), operation > 0 else {
                throw NativeBridgeError(code: "invalid_clipboard_operation", message: "粘贴操作已失效，请重新粘贴。")
            }
            documentID = document
            operationID = operation
            self.authorization = authorization
        }
    }

    enum Representation: Sendable, Equatable { case png, tiff, file }
    struct Metadata: Sendable {
        let width: Double
        let height: Double
        let frames: Int
    }
    struct Pasteboard {
        var changeCount: @MainActor () -> Int = { NSPasteboard.general.changeCount }
        var text: @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) }
        var png: @MainActor () -> Data? = { NSPasteboard.general.data(forType: .png) }
        var tiff: @MainActor () -> Data? = { NSPasteboard.general.data(forType: .tiff) }
    }
    struct Codec: Sendable {
        var metadata: @Sendable (Data, Representation) throws -> Metadata = { data, representation in
            let source = try NativeComposerClipboard.imageSource(data, representation)
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
                throw NativeComposerClipboard.invalidImage()
            }
            return Metadata(width: width.doubleValue, height: height.doubleValue, frames: CGImageSourceGetCount(source))
        }
        var encodePNG: @Sendable (Data, Representation) throws -> Data = { data, representation in
            let source = try NativeComposerClipboard.imageSource(data, representation)
            // Metadata and the pixel budget have already been checked before
            // this first bitmap allocation, including for PNG passthrough.
            guard let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw NativeComposerClipboard.invalidImage()
            }
            if representation == .png { return data }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw NativeComposerClipboard.invalidImage()
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            CGImageDestinationAddImage(destination, bitmap, properties)
            guard CGImageDestinationFinalize(destination) else { throw NativeComposerClipboard.invalidImage() }
            return output as Data
        }

        nonisolated func prepare(_ data: Data, _ representation: Representation) throws -> Data {
            try Task.checkCancellation()
            try NativeComposerClipboard.validateByteCount(data.count)
            let info = try metadata(data, representation)
            try NativeComposerClipboard.validateMetadata(info)
            try Task.checkCancellation()
            let png = try encodePNG(data, representation)
            try Task.checkCancellation()
            try NativeComposerClipboard.validateByteCount(png.count)
            return png
        }
    }
    struct Dependencies {
        var pasteboard = Pasteboard()
        var codec = Codec()
        var now: @MainActor () -> Date = { Date() }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var lifetime: TimeInterval = 120
    }
    private struct Snapshot {
        let token: String
        let identity: Identity
        let expires: Date
        var bytes: Data?
        var consumed = false
    }

    private let dependencies: Dependencies
    private var pending: Snapshot?
    private var conversion: Task<Data, Error>?
    private var expiration: Task<Void, Never>?
    private var generation = UUID()
    var onInvalidation: ((String, Identity) -> Void)?

    init(dependencies: Dependencies = Dependencies()) { self.dependencies = dependencies }

    func capture(_ identity: Identity, isCurrent: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        invalidate()
        let board = dependencies.pasteboard
        let before = board.changeCount()
        if let text = board.text(), !text.isEmpty {
            guard board.changeCount() == before else { throw Self.changed() }
            return ["kind": "text", "text": text]
        }
        let representation: Representation
        let bytes: Data
        if let png = board.png() {
            representation = .png; bytes = png
        } else if let tiff = board.tiff() {
            representation = .tiff; bytes = tiff
        } else {
            guard board.changeCount() == before else { throw Self.changed() }
            return ["kind": "empty"]
        }
        guard board.changeCount() == before else { throw Self.changed() }
        try Self.validateByteCount(bytes.count)
        let codec = dependencies.codec
        return try await captureImage(identity, isCurrent: isCurrent) {
            try codec.prepare(bytes, representation)
        }
    }

    /// A file can enter only through an OS drag token. Reuse the same bounded
    /// conversion, one-shot upload token and document/account ownership as a
    /// paste, without reading or replacing NSPasteboard.general.
    func captureFile(_ identity: Identity, file: NativeComposerDropStore.File,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        invalidate()
        let codec = dependencies.codec
        return try await captureImage(identity, isCurrent: isCurrent) {
            try codec.prepare(file.read(), .file)
        }
    }

    private func captureImage(_ identity: Identity,
                              isCurrent: @escaping @MainActor () -> Bool,
                              prepare: @escaping @Sendable () throws -> Data) async throws -> [String: Any] {
        let currentGeneration = generation
        let token = UUID().uuidString
        let lifetime = min(300, max(1, dependencies.lifetime))
        pending = Snapshot(token: token, identity: identity, expires: dependencies.now().addingTimeInterval(lifetime))
        let sleep = dependencies.sleep
        expiration = Task { [weak self] in
            do { try await sleep(.seconds(lifetime)) } catch { return }
            guard !Task.isCancelled, let self, self.pending?.token == token else { return }
            self.invalidate()
        }
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try prepare() }
        }
        conversion = task
        do {
            let png = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard isCurrent(), currentGeneration == generation,
                  pending?.token == token, pending?.identity == identity else { throw CancellationError() }
            guard pending!.expires > dependencies.now() else {
                invalidate(); throw Self.expired()
            }
            pending?.bytes = png
            conversion = nil
            return ["kind": "image", "token": token, "byteCount": png.count, "mime": "image/png"]
        } catch {
            if pending?.token == token { invalidate() }
            if error is CancellationError || Task.isCancelled || !isCurrent() { throw CancellationError() }
            if let error = error as? NativeBridgeError { throw error }
            throw Self.invalidImage()
        }
    }

    func validate(_ identity: Identity, token: String, ready: Bool = true) throws {
        if let snapshot = pending, snapshot.expires <= dependencies.now() { invalidate() }
        guard let snapshot = pending, snapshot.identity == identity, snapshot.token == token,
              !ready || (!snapshot.consumed && snapshot.bytes != nil) else { throw Self.expired() }
    }

    func consume(_ identity: Identity, token: String) throws -> Data {
        try validate(identity, token: token)
        let bytes = pending!.bytes!
        pending?.bytes = nil
        pending?.consumed = true
        return bytes
    }

    @discardableResult
    func release(_ identity: Identity, token: String) -> Bool {
        guard pending?.identity == identity, pending?.token == token else { return false }
        invalidate()
        return true
    }

    func invalidate() {
        let previous = pending
        pending = nil
        generation = UUID()
        conversion?.cancel(); conversion = nil
        expiration?.cancel(); expiration = nil
        if let previous { onInvalidation?(previous.token, previous.identity) }
    }

    nonisolated static func validateByteCount(_ count: Int) throws {
        guard count > 0, count <= NodeImageUpload.sizeLimit else {
            throw NativeBridgeError(code: "clipboard_image_size", message: "剪贴板图片为空或超过 100 MB，请换一张图片。")
        }
    }

    nonisolated static func validateMetadata(_ value: Metadata) throws {
        guard value.frames == 1 else {
            throw NativeBridgeError(code: "clipboard_image_frames", message: "暂不支持粘贴多帧或多页图片，请使用单张静态图片。")
        }
        guard value.width.isFinite, value.height.isFinite,
              value.width >= 1, value.height >= 1,
              value.width.rounded(.down) == value.width, value.height.rounded(.down) == value.height else { throw invalidImage() }
        guard value.width <= 24_000_000 / value.height else {
            throw NativeBridgeError(code: "clipboard_image_pixels", message: "剪贴板图片超过 2400 万像素，请先缩小图片。")
        }
    }

    nonisolated private static func imageSource(_ data: Data, _ representation: Representation) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String? else { throw invalidImage() }
        let accepted: Bool
        switch representation {
        case .png: accepted = type == UTType.png.identifier
        case .tiff: accepted = type == UTType.tiff.identifier
        case .file:
            accepted = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier,
                        UTType.webP.identifier].contains(type)
        }
        guard accepted else { throw invalidImage() }
        return source
    }
    nonisolated private static func invalidImage() -> NativeBridgeError {
        .init(code: "clipboard_image_invalid", message: "无法读取剪贴板图片，请重新复制一张 PNG 或 TIFF 图片。")
    }
    nonisolated private static func changed() -> NativeBridgeError {
        .init(code: "clipboard_changed", message: "读取时剪贴板已变化，请重新粘贴。")
    }
    nonisolated static func expired() -> NativeBridgeError {
        .init(code: "clipboard_snapshot_expired", message: "图片粘贴已取消或过期，请重新粘贴。")
    }
}
