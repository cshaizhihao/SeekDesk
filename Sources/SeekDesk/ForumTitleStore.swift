import Foundation

/// Small account-owned navigation labels, never a cache of forum bodies or
/// previews. Ownership is established by ForumSession, not a last-login hint.
@MainActor
final class ForumTitleStore {
    enum Source: String, Codable { case feed, listing, reader }
    struct Entry: Codable, Equatable {
        let id: String
        let title: String
        let source: Source
    }
    private struct Partition: Codable, Equatable {
        let owner: Int
        var entries: [Entry]
    }
    private struct Snapshot: Codable {
        let version: Int
        let partitions: [Partition]
    }

    static let storageKey = "forum.tabTitles.v1"
    static let maximumOwners = 4
    static let maximumTitles = 512
    static let maximumTitleBytes = 2048
    // Allow JSON escaping at the full per-title/owner bounds as well as the
    // metadata envelope; still reject an arbitrarily large persisted blob.
    static let maximumStoredBytes = 12 * 1024 * 1024
    private let defaults: UserDefaults
    private var partitions: [Partition] = []
    // Request order belongs to this process only. Restored entries start at 0;
    // retain no more order keys than the bounded owner/title cache itself.
    private var sequences: [Int: [String: UInt64]] = [:]
    private var dirty = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= Self.maximumStoredBytes,
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1 else { return }
        // Treat persisted input as untrusted. Keep the newest valid unique
        // owner/ID, while bounding decoding work and all in-memory snapshots.
        for partition in saved.partitions.suffix(Self.maximumOwners) where partition.owner > 0 {
            var entries: [Entry] = []
            for item in partition.entries.suffix(Self.maximumTitles) {
                guard let title = Self.validTitle(item.title, id: item.id) else { continue }
                entries.removeAll { $0.id == item.id }
                entries.append(.init(id: item.id, title: title, source: item.source))
            }
            partitions.removeAll { $0.owner == partition.owner }
            partitions.append(.init(owner: partition.owner, entries: entries))
        }
    }

    func titles(for owner: Int) -> [String: String] {
        guard owner > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: (partitions.first { $0.owner == owner }?.entries ?? [])
            .map { ($0.id, $0.title) })
    }

    /// All callers must first verify the request's account/revision. Forum
    /// lists and readers use request-start order; public RSS is fallback only.
    /// Reads and unchanged snapshots never write defaults or change recency.
    func record(_ incoming: [Entry], owner: Int, sequence: UInt64 = 0, preserving ids: Set<String> = []) {
        guard owner > 0 else { return }
        var entries = partitions.first { $0.owner == owner }?.entries ?? []
        var orders = sequences[owner] ?? [:]
        let previous = entries
        for item in incoming {
            guard let title = Self.validTitle(item.title, id: item.id) else { continue }
            if let old = entries.first(where: { $0.id == item.id }) {
                if old.source != .feed && item.source == .feed { continue }
                // An authoritative forum response can promote an RSS label
                // even if the fallback feed request happened to start later.
                if !(old.source == .feed && item.source != .feed),
                   sequence < orders[item.id, default: 0] { continue }
                orders[item.id] = sequence
                if old.title == title && old.source == item.source { continue }
            }
            orders[item.id] = sequence
            entries.removeAll { $0.id == item.id }
            entries.append(.init(id: item.id, title: title, source: item.source))
            while entries.count > Self.maximumTitles {
                entries.remove(at: entries.firstIndex { !ids.contains($0.id) } ?? 0)
            }
        }
        let retained = Set(entries.map(\.id))
        if !retained.isEmpty { sequences[owner] = orders.filter { retained.contains($0.key) } }
        guard entries != previous else { return }
        partitions.removeAll { $0.owner == owner }
        partitions.append(.init(owner: owner, entries: entries))
        if partitions.count > Self.maximumOwners { partitions.removeFirst(partitions.count - Self.maximumOwners) }
        let owners = Set(partitions.map(\.owner))
        sequences = sequences.filter { owners.contains($0.key) }
        dirty = true
        flush()
    }

    func flush() {
        guard dirty, let data = try? JSONEncoder().encode(Snapshot(version: 1, partitions: partitions)),
              data.count <= Self.maximumStoredBytes else { return }
        defaults.set(data, forKey: Self.storageKey)
        dirty = false
    }

    static func validTitle(_ input: String, id: String) -> String? {
        guard !id.isEmpty, id.utf8.count <= 19,
              id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(id), number > 0, String(number) == id,
              input.utf8.count <= maximumTitleBytes else { return nil }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "帖子 #\(id)", title != "未命名帖子",
              title.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return title
    }
}
