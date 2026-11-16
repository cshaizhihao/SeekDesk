import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ForumStickers.swift only needs this static URL for its unrelated official
// catalog. The checks never initialize a session, network client, or shared lib.
enum Forum { static let home = URL(string: "https://fixture.invalid/")! }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func fixtureBitmap(width: Int = 240, height: Int = 120) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return context.makeImage()!
}

private func fixtureImage(_ type: UTType = .png, frames: Int = 1, width: Int = 240) -> Data {
    let data = NSMutableData()
    let output = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(output, fixtureBitmap(width: width), nil) }
    require(CGImageDestinationFinalize(output), "Fixture image encoding failed")
    return data as Data
}

private func fileStat(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
    return value
}

private func restoreFileDates(_ url: URL, from value: stat) throws {
    let stamps = [value.st_atimespec, value.st_mtimespec]
    let result = stamps.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) }
    guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("seekdesk-sticker-library-" + UUID().uuidString, isDirectory: true)
    var directory: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var index: URL { directory.appendingPathComponent("groups.json") }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func source(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func local(_ name: String, data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    func seed(_ groups: [StickerLibrary.Group]) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(groups)
        try data.write(to: index)
        return data
    }

    func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}

@MainActor
private func reject(_ expected: StickerLibrary.LibraryError, _ operation: () throws -> Void) throws {
    do { try operation(); fatalError("Expected \(expected)") }
    catch let error as StickerLibrary.LibraryError { require(error == expected, "Expected \(expected), received \(error)") }
}

@MainActor
private func rejectAsync(_ expected: StickerLibrary.LibraryError, _ operation: () async throws -> Void) async throws {
    do { try await operation(); fatalError("Expected \(expected)") }
    catch let error as StickerLibrary.LibraryError { require(error == expected, "Expected \(expected), received \(error)") }
}

@MainActor
private func cancelled(_ operation: () async throws -> Void) async throws {
    do { try await operation(); fatalError("Expected cancellation") }
    catch is CancellationError {}
}

@main
struct StickerLibraryChecks {
    @MainActor
    static func main() async throws {
        do {
            let f = try Fixture()
            let library = StickerLibrary(directory: f.directory)
            let initial = try library.checkedGroups()
            require(initial.isEmpty, "Missing index must mean an empty library")
            require(!FileManager.default.fileExists(atPath: f.directory.path), "Read-only initialization created a directory")
            let id = try library.create("  My Stickers  ")
            require(library.groups.count == 1 && library.groups[0].name == "My Stickers", "Create must trim and persist name")
            let decoded = try JSONDecoder().decode([StickerLibrary.Group].self, from: Data(contentsOf: f.index))
            require(decoded == [.init(id: id, name: "My Stickers", images: [])], "Create changed the legacy schema")
            try reject(.duplicate) { _ = try library.create("my stickers") }
            try reject(.name) { _ = try library.create(" \n ") }
            try reject(.name) { _ = try library.create(String(repeating: "中", count: 41)) }
            print("Passed missing-library read-only initialization and compatible group creation.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let file = try f.local("Legacy custom name.png", data: fixtureImage())
            let groups = [StickerLibrary.Group(id: id, name: "Legacy", images: [file.lastPathComponent, "missing.png"])]
            let original = try f.seed(groups)
            let library = StickerLibrary(directory: f.directory)
            let loaded = try library.checkedGroups()
            let resolved = try library.resolve(groupID: id, itemID: file.lastPathComponent)
            require(loaded == groups && resolved.path == file.path, "Valid non-UUID legacy filenames must resolve unchanged")
            require(library.items(groups[0]).count == 2, "Missing images should remain visible as local failures")
            let unchanged = try Data(contentsOf: f.index)
            require(unchanged == original, "Reading a legal legacy index rewrote it")
            print("Passed old groups.json compatibility, non-UUID safe basenames and no read-time rewrite.")
        }

        do {
            let f = try Fixture()
            let broken = Data("{\"broken\": true".utf8)
            _ = try f.local("groups.json", data: broken)
            let library = StickerLibrary(directory: f.directory)
            try reject(.corruptIndex) { _ = try library.checkedGroups() }
            try reject(.corruptIndex) { _ = try library.create("Must not overwrite") }
            try await rejectAsync(.corruptIndex) {
                _ = try await library.importImages([], to: UUID(), authorized: { true })
            }
            let after = try Data(contentsOf: f.index)
            require(after == broken, "A bad index was overwritten")
            let repaired = [StickerLibrary.Group(id: UUID(), name: "Recovered", images: [])]
            _ = try f.seed(repaired)
            let recovered = try library.checkedGroups()
            require(recovered == repaired, "A repaired index should become readable without automatic repairs")
            try FileManager.default.removeItem(at: f.index)
            try reject(.unreadableIndex) { _ = try library.create("Index disappeared") }
            require(!FileManager.default.fileExists(atPath: f.index.path), "Missing previously loaded index was silently recreated")
            print("Passed corrupt and subsequently missing index write protection with explicit recovery.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let original = try f.seed([.init(id: id, name: "First", images: [])])
            let library = StickerLibrary(directory: f.directory)
            let initialStat = try fileStat(f.index)
            for _ in 0..<24 {
                let groups = try library.checkedGroups()
                require(groups[0].name == "First", "Unchanged index cache returned different groups")
            }
            let untouchedStat = try fileStat(f.index), untouched = try Data(contentsOf: f.index)
            require(untouched == original && untouchedStat.st_ino == initialStat.st_ino &&
                    untouchedStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec &&
                    untouchedStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec &&
                    untouchedStat.st_ctimespec.tv_sec == initialStat.st_ctimespec.tv_sec &&
                    untouchedStat.st_ctimespec.tv_nsec == initialStat.st_ctimespec.tv_nsec,
                    "Repeated cached reads changed the original index or its write metadata")

            // Rewrite the same inode with the same byte count and restore the
            // exact nanosecond modification date. Only ctime identifies this
            // change; size/mtime-only caches would keep returning First.
            let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "First", with: "Other").utf8)
            require(changed.count == original.count && changed != original, "Same-size fixture is not a rewrite")
            let handle = try FileHandle(forWritingTo: f.index)
            try handle.write(contentsOf: changed); try handle.close()
            try restoreFileDates(f.index, from: initialStat)
            let changedStat = try fileStat(f.index)
            require(changedStat.st_ino == initialStat.st_ino && changedStat.st_size == initialStat.st_size &&
                    changedStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec &&
                    changedStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec,
                    "Same-size fixture failed to preserve inode, size and exact modification date")
            require(changedStat.st_ctimespec.tv_sec != initialStat.st_ctimespec.tv_sec ||
                    changedStat.st_ctimespec.tv_nsec != initialStat.st_ctimespec.tv_nsec,
                    "Same-size fixture did not change ctime")
            let refreshed = try library.checkedGroups()
            require(refreshed[0].name == "Other", "Index fingerprint hid a same-size rewrite with restored mtime")
            let preserved = try Data(contentsOf: f.index)
            require(preserved == changed, "Cache invalidation rewrote an outside edit")
            print("Passed unchanged-index read-only caching and same-size external rewrite with restored nanosecond mtime.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let original = try f.seed([.init(id: id, name: "First", images: [])])
            let library = StickerLibrary(directory: f.directory)
            let initialStat = try fileStat(f.index)
            let replacement = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "First", with: "Third").utf8)
            try replacement.write(to: f.index, options: .atomic)
            try restoreFileDates(f.index, from: initialStat)
            let replacementStat = try fileStat(f.index)
            require(replacementStat.st_ino != initialStat.st_ino && replacementStat.st_size == initialStat.st_size,
                    "Atomic replacement fixture did not replace the inode at the same size")
            let replaced = try library.checkedGroups()
            require(replaced[0].name == "Third", "Index fingerprint hid an atomic replacement")

            let corrupt = Data(repeating: 0x78, count: replacement.count)
            try corrupt.write(to: f.index, options: .atomic)
            try reject(.corruptIndex) { _ = try library.checkedGroups() }
            try reject(.corruptIndex) { _ = try library.checkedGroups() }
            try reject(.corruptIndex) { _ = try library.create("Must not hide corruption") }
            let unrepaired = try Data(contentsOf: f.index)
            require(unrepaired == corrupt, "A cached index hid or repaired a corrupt replacement")
            try replacement.write(to: f.index, options: .atomic)
            let recovered = try library.checkedGroups()
            require(recovered[0].name == "Third", "A repaired replacement failed to recover the cache")
            try FileManager.default.removeItem(at: f.index)
            try reject(.unreadableIndex) { _ = try library.checkedGroups() }
            try reject(.unreadableIndex) { _ = try library.create("Must not hide deletion") }
            require(!FileManager.default.fileExists(atPath: f.index.path), "Cached groups recreated a deleted index")
            print("Passed atomic replacement, repeated corrupt-index rejection, explicit recovery and deletion cache invalidation.")
        }

        do {
            let f = try Fixture(), first = UUID(), second = UUID()
            let file = try f.local("valid.png", data: fixtureImage())
            _ = try f.seed([.init(id: first, name: "First", images: [file.lastPathComponent]),
                            .init(id: second, name: "Second", images: [])])
            let library = StickerLibrary(directory: f.directory)
            try reject(.missingGroup) { _ = try library.resolve(groupID: UUID(), itemID: "valid.png") }
            try reject(.missingItem) { _ = try library.resolve(groupID: second, itemID: "valid.png") }
            for invalid in ["", "../valid.png", "sub/valid.png", "/valid.png", "a\\b.png", "a:b.png", ".hidden.png", "groups.json", "a\u{0000}.png"] {
                try reject(.unsafePath) { _ = try library.resolve(groupID: first, itemID: invalid) }
                try reject(.unsafePath) { try library.remove(itemID: invalid, in: first) }
            }
            let unchanged = try library.checkedGroups()
            require(unchanged[0].images == ["valid.png"], "Rejected ID changed its group")
            print("Passed exact group membership and path/ID rejection.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let hostile = try f.seed([.init(id: id, name: "Unsafe", images: ["../escape.png"])])
            let library = StickerLibrary(directory: f.directory)
            try reject(.corruptIndex) { _ = try library.checkedGroups() }
            try reject(.corruptIndex) { _ = try library.create("No repair") }
            let after = try Data(contentsOf: f.index)
            require(after == hostile, "Unsafe index was rewritten")
            _ = try f.seed([.init(id: id, name: "One", images: []), .init(id: id, name: "Two", images: [])])
            try reject(.corruptIndex) { _ = try library.checkedGroups() }
            print("Passed malicious persisted paths and duplicate group IDs without repair writes.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let original = try f.source("outside.png", data: fixtureImage())
            _ = try f.seed([.init(id: id, name: "Links", images: ["linked.png"])])
            let linked = f.directory.appendingPathComponent("linked.png")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
            let library = StickerLibrary(directory: f.directory)
            try reject(.unsafePath) { _ = try library.resolve(groupID: id, itemID: "linked.png") }
            try reject(.unsafePath) { try library.remove(itemID: "linked.png", in: id) }
            try await rejectAsync(.unsafePath) { _ = try await library.thumbnail(groupID: id, itemID: "linked.png") }
            require(FileManager.default.fileExists(atPath: original.path), "A rejected link touched its destination")

            let libraryLink = f.root.appendingPathComponent("LibraryLink", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: libraryLink, withDestinationURL: f.directory)
            let linkedLibrary = StickerLibrary(directory: libraryLink)
            try reject(.unsafePath) { _ = try linkedLibrary.checkedGroups() }
            try reject(.unsafePath) { _ = try linkedLibrary.create("Must fail") }

            try FileManager.default.moveItem(at: f.index, to: f.root.appendingPathComponent("outside-index.json"))
            try FileManager.default.createSymbolicLink(at: f.index, withDestinationURL: f.root.appendingPathComponent("outside-index.json"))
            let linkedIndex = StickerLibrary(directory: f.directory)
            try reject(.unsafePath) { _ = try linkedIndex.checkedGroups() }
            try reject(.unsafePath) { _ = try linkedIndex.create("Must also fail") }
            print("Passed file, library-directory and groups.json symlink protection.")
        }

        do {
            let f = try Fixture(), id = UUID()
            _ = try f.local("good.png", data: fixtureImage())
            _ = try f.seed([.init(id: id, name: "Mixed", images: ["missing.png", "good.png"])])
            let library = StickerLibrary(directory: f.directory)
            let before = try library.checkedGroups()
            require(before[0].images.count == 2, "Missing file should not invalidate or repair the index")
            try reject(.missingFile) { _ = try library.resolve(groupID: id, itemID: "missing.png") }
            try await rejectAsync(.missingFile) { _ = try await library.thumbnail(groupID: id, itemID: "missing.png") }
            _ = try library.resolve(groupID: id, itemID: "good.png")
            try library.remove(itemID: "missing.png", in: id)
            require(library.groups[0].images == ["good.png"], "Users must be able to remove a missing file's entry")
            print("Passed missing-file local failure and explicit removal without affecting valid entries.")
        }

        do {
            let f = try Fixture(), first = UUID(), second = UUID()
            let file = try f.local("shared.png", data: fixtureImage())
            _ = try f.seed([.init(id: first, name: "One", images: ["shared.png"]),
                            .init(id: second, name: "Two", images: ["shared.png"])])
            let library = StickerLibrary(directory: f.directory)
            try library.remove(itemID: "shared.png", in: first)
            require(FileManager.default.fileExists(atPath: file.path), "Removing one reference deleted another group's image")
            _ = try library.resolve(groupID: second, itemID: "shared.png")
            try library.remove(itemID: "shared.png", in: second)
            require(!FileManager.default.fileExists(atPath: file.path), "Last-reference removal retained its image")
            print("Passed shared-file reference preservation and final-reference removal.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let file = try f.local("keep.png", data: fixtureImage())
            let before = try f.seed([.init(id: id, name: "Keep", images: ["keep.png"])])
            let library = StickerLibrary(directory: f.directory, writeIndex: { _, _ in throw CocoaError(.fileWriteUnknown) })
            try reject(.writeFailed) { try library.remove(itemID: "keep.png", in: id) }
            let after = try Data(contentsOf: f.index)
            require(before == after && FileManager.default.fileExists(atPath: file.path), "Failed index write deleted an existing image")
            require(library.groups[0].images == ["keep.png"], "Failed index write mutated published state")
            print("Passed remove transaction rollback on injected index-write failure.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Import")
            let firstBytes = fixtureImage(), secondBytes = fixtureImage(width: 320)
            let first = try f.source("first/same.png", data: firstBytes)
            let second = try f.source("second/same.png", data: secondBytes)
            let empty = try f.source("empty.png", data: Data())
            let invalid = try f.source("invalid.png", data: Data("not an image".utf8))
            let oversized = try f.source("too-big.png", data: Data())
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(StickerLibrary.imageSizeLimit + 1)); try handle.close()
            let link = f.root.appendingPathComponent("source-link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            let result = try await library.importImages([
                first, second, empty, invalid, oversized, f.root.appendingPathComponent("absent.png"), f.root, link,
                URL(string: "https://fixture.invalid/no-download.png")!
            ], to: group, authorized: { true })
            require(result == .init(imported: 2, skipped: 7), "Partial import counts are incorrect")
            let files = library.groups[0].images
            require(files.count == 2 && Set(files).count == 2 && !files.contains("same.png"), "Same-named input images collided")
            let copyA = try Data(contentsOf: library.resolve(groupID: group, itemID: files[0]))
            let copyB = try Data(contentsOf: library.resolve(groupID: group, itemID: files[1]))
            require(copyA == firstBytes && copyB == secondBytes, "Import transformed or failed to copy source bytes")
            try FileManager.default.removeItem(at: first)
            _ = try library.resolve(groupID: group, itemID: files[0])
            let reloaded = try StickerLibrary(directory: f.directory).checkedGroups()
            require(reloaded[0].images == files, "Partial success was not persisted")
            print("Passed safe copied import, partial success, unique names and original-byte preservation.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Exact size")
            var data = fixtureImage()
            data.append(Data(count: StickerLibrary.imageSizeLimit - data.count))
            let source = try f.source("at-limit.png", data: data)
            let result = try await library.importImages([source], to: group, authorized: { true })
            require(result.imported == 1 && result.skipped == 0, "15 MiB inclusive import limit rejected a valid PNG")
            let copied = try Data(contentsOf: library.resolve(groupID: group, itemID: library.groups[0].images[0]))
            require(copied.count == StickerLibrary.imageSizeLimit && copied == data, "Inclusive boundary changed bytes")
            print("Passed 15 MiB inclusive boundary using a local PNG fixture.")
        }

        do {
            let f = try Fixture(), id = UUID()
            let before = try f.seed([.init(id: id, name: "Rollback", images: [])])
            let library = StickerLibrary(directory: f.directory, writeIndex: { _, _ in throw CocoaError(.fileWriteUnknown) })
            let source = try f.source("source.png", data: fixtureImage())
            try await rejectAsync(.writeFailed) {
                _ = try await library.importImages([source], to: id, authorized: { true })
            }
            let after = try Data(contentsOf: f.index), names = try f.names()
            require(before == after && names == ["groups.json"], "Commit failure did not roll back staged copies")
            require(library.groups[0].images.isEmpty, "Commit failure published imported images")
            print("Passed imported-file rollback on deterministic index-write failure.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Cancel")
            let source = try f.source("source.png", data: fixtureImage())
            let before = try Data(contentsOf: f.index)
            try await cancelled { _ = try await library.importImages([source], to: group, authorized: { false }) }
            var authorizations = 0
            try await cancelled {
                _ = try await library.importImages([source], to: group, authorized: {
                    authorizations += 1
                    return authorizations == 1
                })
            }
            require(authorizations == 2, "Invalidation fixture did not reach post-copy authorization")
            let after = try Data(contentsOf: f.index), names = try f.names()
            require(before == after && names == ["groups.json"], "Late authorization change retained staged files or changed index")
            print("Passed preflight denial and post-copy authorization rollback.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Task cancellation")
            let source = try f.source("source.png", data: fixtureImage())
            var authorizations = 0
            let task = Task { @MainActor in
                try await library.importImages([source], to: group, authorized: {
                    authorizations += 1
                    if authorizations == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                })
            }
            try await cancelled { _ = try await task.value }
            let names = try f.names()
            require(authorizations == 2 && names == ["groups.json"], "Task cancellation at commit did not roll back copies")
            require(library.groups[0].images.isEmpty, "Cancelled task committed its index")
            print("Passed task cancellation after background copy with complete rollback.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Concurrent")
            let source = try f.source("source.png", data: fixtureImage())
            async let first = library.importImages([source], to: group, authorized: { true })
            async let second = library.importImages([source], to: group, authorized: { true })
            let results = try await [first, second]
            require(results.allSatisfy { $0.imported == 1 && $0.skipped == 0 }, "Concurrent import failed")
            require(library.groups[0].images.count == 2 && Set(library.groups[0].images).count == 2, "Concurrent commit lost another import")
            print("Passed concurrent imports merging into the current index.")
        }

        do {
            let f = try Fixture(), library = StickerLibrary(directory: f.directory)
            let group = try library.create("Animated")
            let original = fixtureImage(.gif, frames: 2)
            let source = try f.source("animated.gif", data: original)
            let result = try await library.importImages([source], to: group, authorized: { true })
            require(result.imported == 1, "GIF import failed")
            let item = library.groups[0].images[0]
            let copied = try Data(contentsOf: library.resolve(groupID: group, itemID: item))
            require(copied == original, "GIF was transcoded during import")
            let thumbnail = try await library.thumbnail(groupID: group, itemID: item)
            require(thumbnail.mime == "image/gif" && thumbnail.bytes == original, "Preview must retain the GIF and its timing")
            let decoded = CGImageSourceCreateWithData(thumbnail.bytes as CFData, nil)!
            require(CGImageSourceGetCount(decoded) == 2, "Preview lost an animation frame")
            let many = try await withThrowingTaskGroup(of: StickerLibrary.Thumbnail.self) { tasks in
                for _ in 0..<12 { tasks.addTask { try await library.thumbnail(groupID: group, itemID: item) } }
                var values: [StickerLibrary.Thumbnail] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            require(many.count == 12 && many.allSatisfy { $0 == thumbnail }, "Concurrent subscribers received inconsistent thumbnails")
            print("Passed original GIF preservation, animated preview and concurrent subscribers.")
        }

        print("All StickerLibrary checks passed using temporary directories and generated image fixtures only.")
    }
}
