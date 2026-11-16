import Combine
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The SwiftUI and Flutter pickers share the original on-disk schema. A bridge
/// item identifier is a validated basename from its group, never a caller URL.
@MainActor
final class StickerLibrary: ObservableObject {
    struct Group: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        var name: String
        var images: [String]
    }

    struct ImportResult: Equatable, Sendable {
        let imported: Int
        let skipped: Int
    }

    struct Thumbnail: Equatable, Sendable {
        let bytes: Data
        let mime: String
    }

    nonisolated static let imageSizeLimit = 15 * 1024 * 1024
    nonisolated static let thumbnailEdge = 112
    private nonisolated static let indexSizeLimit = 16 * 1024 * 1024

    static let shared = StickerLibrary(directory:
        URL.applicationSupportDirectory.appendingPathComponent("SeekDesk/Stickers", isDirectory: true))

    @Published private(set) var groups: [Group] = []
    private let directory: URL
    private let writeIndex: (Data, URL) throws -> Void
    private let thumbnails = ImageRequestCoordinator<String, Thumbnail>(maximumConcurrent: 2)
    private var storedData: Data?
    private var storedFingerprint: IndexFingerprint?
    private var indexWasPresent = false
    private var index: URL { directory.appendingPathComponent("groups.json") }

    /// Thumbnail membership checks still inspect the file and directory, but
    /// avoid reading/decoding the unchanged index for every visible tile.
    /// ctime catches same-size rewrites whose modification date is restored;
    /// device/inode also detect an atomic replacement of the index.
    private struct IndexFingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    /// Initialization only reads; a missing directory is created by a later
    /// authorized mutation. Tests must supply a temporary directory.
    init(directory: URL, writeIndex: @escaping (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) {
        // Resolve trusted parent aliases such as macOS /var -> /private/var,
        // while retaining the final component so a symlink library is rejected.
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        self.directory = parent.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        self.writeIndex = writeIndex
        _ = try? checkedGroups()
    }

    /// Bad/unreadable indexes remain errors, not an empty library that a later
    /// create/import could overwrite. Reading never repairs or rewrites files.
    func checkedGroups() throws -> [Group] {
        try Self.checkDirectory(directory, allowMissing: true)
        guard let attributes = try Self.attributes(index) else {
            guard !indexWasPresent else { throw LibraryError.unreadableIndex }
            return groups
        }
        indexWasPresent = true
        guard Self.isRegular(attributes), !Self.isSymlink(attributes) else {
            throw LibraryError.unsafePath
        }
        let fingerprint = IndexFingerprint(attributes)
        if storedFingerprint == fingerprint { return groups }
        // A failed read/validation must never turn into a cache hit on a later
        // request. Only fingerprints for validated bytes are remembered.
        storedFingerprint = nil
        let data: Data
        do { data = try Self.readFile(index, limit: Self.indexSizeLimit, allowEmpty: true) }
        catch LibraryError.unsafePath { throw LibraryError.unsafePath }
        catch { throw LibraryError.unreadableIndex }
        if storedData == data {
            storedFingerprint = fingerprint
            return groups
        }
        let decoded: [Group]
        do { decoded = try JSONDecoder().decode([Group].self, from: data) }
        catch { throw LibraryError.corruptIndex }
        guard Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ group in
                  !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  group.name.count <= 40 && group.images.allSatisfy(Self.safeBasename)
              }) else { throw LibraryError.corruptIndex }
        storedData = data
        storedFingerprint = fingerprint
        if groups != decoded { groups = decoded }
        return groups
    }

    func create(_ name: String) throws -> UUID {
        _ = try checkedGroups()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw LibraryError.name }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw LibraryError.duplicate
        }
        let group = Group(id: UUID(), name: name, images: [])
        try store(groups + [group])
        return group.id
    }

    func resolve(groupID: UUID, itemID: String) throws -> URL {
        guard Self.safeBasename(itemID) else { throw LibraryError.unsafePath }
        let current = try checkedGroups()
        guard let group = current.first(where: { $0.id == groupID }) else { throw LibraryError.missingGroup }
        guard group.images.contains(itemID) else { throw LibraryError.missingItem }
        let url = try Self.itemURL(itemID, directory: directory)
        guard let attributes = try Self.attributes(url) else { throw LibraryError.missingFile }
        guard Self.isRegular(attributes), !Self.isSymlink(attributes) else { throw LibraryError.unsafePath }
        return url
    }

    /// Compatibility for the old SwiftUI picker. Missing entries stay in the
    /// index and fail locally; unsafe entries are never offered as file URLs.
    func items(_ group: Group) -> [ForumSticker] {
        guard let current = groups.first(where: { $0.id == group.id }) else { return [] }
        return current.images.enumerated().compactMap { offset, item in
            guard let url = try? Self.itemURL(item, directory: directory) else { return nil }
            if let attributes = try? Self.attributes(url), Self.isSymlink(attributes) || !Self.isRegular(attributes) {
                return nil
            }
            return ForumSticker(id: item, label: "\(current.name) \(offset + 1)", url: url, insertion: nil)
        }
    }

    func remove(itemID: String, in groupID: UUID) throws {
        guard Self.safeBasename(itemID) else { throw LibraryError.unsafePath }
        var next = try checkedGroups()
        guard let offset = next.firstIndex(where: { $0.id == groupID }) else { throw LibraryError.missingGroup }
        guard next[offset].images.contains(itemID) else { throw LibraryError.missingItem }
        let url = try Self.itemURL(itemID, directory: directory)
        if let attributes = try Self.attributes(url), !Self.isRegular(attributes) || Self.isSymlink(attributes) {
            throw LibraryError.unsafePath
        }
        next[offset].images.removeAll { $0 == itemID }
        try store(next)
        // An older/imported index can reference one file from several groups.
        // The file is expendable only after its final persisted reference ends.
        if !next.contains(where: { $0.images.contains(itemID) }) {
            Self.removeOwnedFiles([url], directory: directory)
        }
    }

    func remove(_ sticker: ForumSticker, in group: UUID) throws {
        try remove(itemID: sticker.id, in: group)
    }

    func importImages(_ urls: [URL], to group: UUID,
                      authorized: @escaping @MainActor () -> Bool) async throws -> ImportResult {
        try Task.checkCancellation()
        guard authorized() else { throw CancellationError() }
        try Task.checkCancellation()
        guard try checkedGroups().contains(where: { $0.id == group }) else { throw LibraryError.missingGroup }
        let directory = directory
        let worker = Task.detached(priority: .userInitiated) {
            try Self.stageImport(urls, directory: directory)
        }
        let staged = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        do {
            try Task.checkCancellation()
            guard authorized() else { throw CancellationError() }
            try Task.checkCancellation()
            // Other groups/imports may have changed while validation ran. Merge
            // into the current index, never the pre-worker snapshot.
            var next = try checkedGroups()
            guard let offset = next.firstIndex(where: { $0.id == group }) else { throw LibraryError.missingGroup }
            if !staged.files.isEmpty {
                next[offset].images.append(contentsOf: staged.files.map(\.lastPathComponent))
                try store(next)
            }
            return ImportResult(imported: staged.files.count, skipped: staged.skipped)
        } catch {
            await Task.detached(priority: .utility) {
                Self.removeOwnedFiles(staged.files, directory: directory)
            }.value
            throw error
        }
    }

    func thumbnail(groupID: UUID, itemID: String) async throws -> Thumbnail {
        try Task.checkCancellation()
        let url = try resolve(groupID: groupID, itemID: itemID)
        let directory = directory
        let data = try await thumbnails.value(for: "\(groupID.uuidString):\(itemID)") {
            try autoreleasepool {
                try Self.checkDirectory(directory, allowMissing: false)
                let data = try Self.readFile(url, limit: Self.imageSizeLimit)
                let source = try Self.imageSource(data)
                try Task.checkCancellation()
                if data.count <= 2 * 1024 * 1024,
                   let mime = ForumImageAnimation.format(of: source, maxEdge: 512) {
                    return Thumbnail(bytes: data, mime: mime)
                }
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailEdge,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary), image.width > 0, image.height > 0,
                      image.width <= Self.thumbnailEdge, image.height <= Self.thumbnailEdge else {
                    throw LibraryError.invalidImage
                }
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                    throw LibraryError.invalidImage
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalidImage }
                try Task.checkCancellation()
                return Thumbnail(bytes: output as Data, mime: "image/png")
            }
        }
        try Task.checkCancellation()
        _ = try resolve(groupID: groupID, itemID: itemID)
        return data
    }

    private func store(_ next: [Group]) throws {
        try Self.ensureDirectory(directory)
        if let attributes = try Self.attributes(index), !Self.isRegular(attributes) || Self.isSymlink(attributes) {
            throw LibraryError.unsafePath
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(next)
            guard data.count <= Self.indexSizeLimit else { throw LibraryError.writeFailed }
            try writeIndex(data, index)
        } catch { throw LibraryError.writeFailed }
        storedData = data
        // The next read establishes the identity of the persisted bytes. Do
        // not pair our encoded data with metadata from a possible outside
        // replacement that happened immediately after the write.
        storedFingerprint = nil
        indexWasPresent = true
        groups = next
    }

    private struct StagedImport: Sendable {
        let files: [URL]
        let skipped: Int
    }

    private nonisolated static func stageImport(_ urls: [URL], directory: URL) throws -> StagedImport {
        var files: [URL] = []
        var skipped = 0
        var finished = false
        defer { if !finished { removeOwnedFiles(files, directory: directory) } }
        for url in urls {
            try Task.checkCancellation()
            let picture: (Data, String)? = try autoreleasepool {
                guard url.isFileURL else { return nil }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try readFile(url, limit: imageSizeLimit)
                    let source = try imageSource(data)
                    guard let identifier = CGImageSourceGetType(source) as String?,
                          let type = UTType(identifier), type.conforms(to: .image),
                          let ext = type.preferredFilenameExtension,
                          safeBasename("image.\(ext)") else { return nil }
                    return (data, ext)
                } catch is CancellationError { throw CancellationError() }
                catch { return nil }
            }
            guard let (data, ext) = picture else { skipped += 1; continue }
            try Task.checkCancellation()
            try ensureDirectory(directory)
            let target = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try writeNewFile(data, to: target)
            files.append(target)
        }
        try Task.checkCancellation()
        finished = true
        return StagedImport(files: files, skipped: skipped)
    }

    private nonisolated static func imageSource(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = info[kCGImagePropertyPixelWidth as String] as? Double,
              let height = info[kCGImagePropertyPixelHeight as String] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else { throw LibraryError.invalidImage }
        return source
    }

    private nonisolated static func safeBasename(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("."),
              value.caseInsensitiveCompare("groups.json") != .orderedSame,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              value == (value as NSString).lastPathComponent else { return false }
        return true
    }

    private nonisolated static func itemURL(_ item: String, directory: URL) throws -> URL {
        guard safeBasename(item) else { throw LibraryError.unsafePath }
        try checkDirectory(directory, allowMissing: true)
        let url = directory.appendingPathComponent(item)
        guard url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else { throw LibraryError.unsafePath }
        return url
    }

    private nonisolated static func checkDirectory(_ directory: URL, allowMissing: Bool) throws {
        guard directory.isFileURL, directory.path != "/",
              directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw LibraryError.unsafePath
        }
        guard let attributes = try attributes(directory) else {
            if allowMissing { return }
            throw LibraryError.missingFile
        }
        guard (attributes.st_mode & S_IFMT) == S_IFDIR else { throw LibraryError.unsafePath }
    }

    private nonisolated static func ensureDirectory(_ directory: URL) throws {
        try checkDirectory(directory, allowMissing: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw LibraryError.importFailed }
        try checkDirectory(directory, allowMissing: false)
    }

    private nonisolated static func attributes(_ url: URL) throws -> stat? {
        guard url.isFileURL else { throw LibraryError.unsafePath }
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw LibraryError.unreadableIndex
    }

    private nonisolated static func isRegular(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFREG }
    private nonisolated static func isSymlink(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFLNK }

    /// O_NOFOLLOW plus a bounded copy prevents following a substituted final
    /// symlink or accepting a file that grows after its initial size check.
    private nonisolated static func readFile(_ url: URL, limit: Int, allowEmpty: Bool = false) throws -> Data {
        guard url.isFileURL else { throw LibraryError.unsafePath }
        guard let initial = try attributes(url) else { throw LibraryError.missingFile }
        guard isRegular(initial), !isSymlink(initial) else { throw LibraryError.unsafePath }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw LibraryError.unsafePath }
            throw LibraryError.missingFile
        }
        defer { close(descriptor) }
        var current = stat()
        guard fstat(descriptor, &current) == 0, isRegular(current),
              current.st_size >= 0, current.st_size <= Int64(limit) else { throw LibraryError.invalidImage }
        var data = Data()
        data.reserveCapacity(Int(current.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, min($0.count, limit - data.count + 1)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw LibraryError.invalidImage
            }
            if count == 0 { break }
            guard count <= limit - data.count else { throw LibraryError.invalidImage }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard allowEmpty || !data.isEmpty else { throw LibraryError.invalidImage }
        return data
    }

    private nonisolated static func writeNewFile(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.importFailed }
        var finished = false
        defer {
            close(descriptor)
            if !finished { _ = unlink(url.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LibraryError.importFailed }
                offset += count
            }
        }
        finished = true
    }

    private nonisolated static func removeOwnedFiles(_ urls: [URL], directory: URL) {
        guard (try? checkDirectory(directory, allowMissing: false)) != nil else { return }
        for url in urls {
            guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                  let info = try? attributes(url), isRegular(info), !isSymlink(info) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum LibraryError: LocalizedError, Equatable, Sendable {
        case name, duplicate, skipped(Int)
        case unreadableIndex, corruptIndex, writeFailed, unsafePath
        case missingGroup, missingItem, missingFile, invalidImage, importFailed

        var errorDescription: String? {
            switch self {
            case .name: "分组名需要 1 到 40 个字符。"
            case .duplicate: "已经有同名分组。"
            case .skipped(let count): "已跳过 \(count) 张无法读取或大于 15 MB 的图片。"
            case .unreadableIndex: "无法读取本机表情库，请检查文件权限后重试。"
            case .corruptIndex: "本机表情库索引损坏，原文件已保留，请恢复索引后重试。"
            case .writeFailed: "无法保存本机表情库，原有分组已保留。"
            case .unsafePath: "本机表情文件路径无效，操作已停止。"
            case .missingGroup: "表情分组已不存在，请刷新后重试。"
            case .missingItem: "此表情已不在选定分组中，请刷新后重试。"
            case .missingFile: "本机表情文件已不存在，可从分组移除后重新导入。"
            case .invalidImage: "无法读取此表情图片，请使用不超过 15 MB 的有效图片。"
            case .importFailed: "表情导入未完成，请检查本机存储后重试。"
            }
        }
    }
}
