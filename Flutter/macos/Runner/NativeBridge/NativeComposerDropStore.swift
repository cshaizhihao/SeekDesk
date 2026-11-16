import AppKit
import CoreFoundation
import Darwin

/// A single file chosen by an actual drag, never a path supplied by Dart.
/// Unconsumed offers expire; consuming binds conversion to the editor's existing
/// clipboard identity and hands resource ownership to its bounded worker.
@MainActor
final class NativeComposerDropStore {
    struct Target: Equatable {
        let documentID: String
        let authorization: ForumSession.Authorization
        let revision: Int64
        let rect: CGRect

        func event(_ phase: String, point: CGPoint, token: String? = nil) -> [String: Any] {
            var result: [String: Any] = ["phase": phase, "documentID": documentID,
                "accessRevision": authorization.revision, "targetRevision": revision,
                "x": Double(point.x), "y": Double(point.y)]
            if let token { result["dropToken"] = token }
            return result
        }
    }

    final class File: @unchecked Sendable {
        private let url: URL
        private let scoped: Bool
        fileprivate init(_ url: URL) {
            self.url = url
            scoped = url.startAccessingSecurityScopedResource()
        }
        deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

        func read() throws -> Data {
            try Task.checkCancellation()
            // Open nonblocking, then inspect this exact descriptor. This rejects
            // a directory/FIFO/device even if the path changed after the drop.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw NativeComposerDropStore.invalidFile() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else { throw NativeComposerDropStore.invalidFile() }
            guard metadata.st_size > 0, metadata.st_size <= NodeImageUpload.sizeLimit else {
                throw NativeBridgeError(code: "clipboard_image_size", message: "图片为空或超过 100 MB，请换一张图片。")
            }
            var data = Data()
            while true {
                try Task.checkCancellation()
                // Count actual bytes too: the file can grow after fstat.
                let next = min(1024 * 1024, NodeImageUpload.sizeLimit + 1 - data.count)
                guard next > 0 else {
                    throw NativeBridgeError(code: "clipboard_image_size", message: "图片超过 100 MB，请换一张图片。")
                }
                guard let chunk = try handle.read(upToCount: next), !chunk.isEmpty else { break }
                data.append(chunk)
                try NativeComposerClipboard.validateByteCount(data.count)
            }
            try NativeComposerClipboard.validateByteCount(data.count)
            return data
        }
    }

    private struct Offer {
        let token: String
        let documentID: String
        let authorization: ForumSession.Authorization
        let expires: Date
        let file: File
    }

    private(set) var target: Target?
    private(set) var targetRevision: Int64 = -1
    private var pending: Offer?
    private var expiration: Task<Void, Never>?
    private let now: @MainActor () -> Date
    private let lifetime: TimeInterval

    init(now: @escaping @MainActor () -> Date = Date.init, lifetime: TimeInterval = 120) {
        self.now = now
        self.lifetime = min(300, max(1, lifetime))
    }

    @discardableResult
    func update(_ args: [String: Any], authorization: ForumSession.Authorization) -> Bool {
        guard let revision = Self.integer(args["targetRevision"]), revision >= targetRevision,
              let enabled = args["enabled"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID() else { return false }
        if !enabled.boolValue {
            targetRevision = revision
            target = nil
            return true
        }
        guard let document = args["documentID"] as? String, !document.isEmpty, document.utf8.count <= 256,
              let accessRevision = Self.integer(args["accessRevision"]), accessRevision == authorization.revision,
              let left = Self.number(args["left"]), let top = Self.number(args["top"]),
              let width = Self.number(args["width"]), let height = Self.number(args["height"]),
              abs(left) <= 100_000, abs(top) <= 100_000,
              width > 0, height > 0, width <= 100_000, height <= 100_000 else { return false }
        targetRevision = revision
        target = Target(documentID: document, authorization: authorization, revision: revision,
                        rect: CGRect(x: left, y: top, width: width, height: height))
        return true
    }

    func target(at point: CGPoint, authorization: ForumSession.Authorization) -> Target? {
        guard point.x.isFinite, point.y.isFinite, let target,
              target.authorization == authorization, target.rect.contains(point) else { return nil }
        return target
    }

    /// Called only by NSDraggingDestination after checking its current target.
    /// Unit checks may inject a generated temporary file at the same boundary.
    func offer(_ url: URL, target: Target, authorization: ForumSession.Authorization) throws -> String {
        guard self.target == target, target.authorization == authorization,
              url.isFileURL, url.user == nil, url.password == nil else { throw Self.expired() }
        releasePending()
        let token = UUID().uuidString
        pending = Offer(token: token, documentID: target.documentID, authorization: authorization,
                        expires: now().addingTimeInterval(lifetime), file: File(url))
        let lifetime = lifetime
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            guard !Task.isCancelled, self?.pending?.token == token else { return }
            self?.releasePending()
        }
        return token
    }

    func consume(_ token: String, identity: NativeComposerClipboard.Identity) throws -> File {
        if let pending, pending.expires <= now() { releasePending() }
        guard let pending, pending.token == token, pending.documentID == identity.documentID,
              pending.authorization == identity.authorization else { throw Self.expired() }
        let file = pending.file
        releasePending()
        return file
    }

    @discardableResult
    func release(_ token: String) -> Bool {
        guard pending?.token == token else { return false }
        releasePending()
        return true
    }

    func invalidate() {
        target = nil
        releasePending()
    }

    private func releasePending() {
        pending = nil
        expiration?.cancel()
        expiration = nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: value.objCType)),
              let result = Int64(value.stringValue), result >= 0 else { return nil }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    nonisolated static func expired() -> NativeBridgeError {
        .init(code: "composer_drop_expired", message: "拖入的图片已取消或过期，请重新拖入。")
    }
    nonisolated static func invalidFile() -> NativeBridgeError {
        .init(code: "clipboard_image_invalid", message: "无法读取图片，请选择单张 PNG、JPEG、TIFF 或 WebP 图片。")
    }
}
