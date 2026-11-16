import Foundation

/// Session-only values for switching inbox categories and conversations. Reads
/// expire on explicit revisions, not a timer; private content never goes to disk.
struct InboxReadCache<Value> {
    struct Key: Hashable { let route: String; let peer: Int? }
    private struct Entry { var value: Value; let revision: Int; let cost: Int }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var access: Int?
    private var refresh: Int?
    private let maximumCost = 2 * 1024 * 1024
    private let maximumEntries = 8

    mutating func prepare(access: Int, refresh: Int) {
        if self.access != access || self.refresh != refresh { removeAll() }
        self.access = access
        self.refresh = refresh
    }

    mutating func value(for key: Key, revision: Int = 0) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard entry.revision == revision else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int, revision: Int = 0) {
        entries[key] = nil
        order.removeAll { $0 == key }
        guard cost >= 0, cost <= maximumCost else { return }
        entries[key] = Entry(value: value, revision: revision, cost: max(64, cost))
        order.append(key)
        while order.count > maximumEntries || entries.values.reduce(0, { $0 + $1.cost }) > maximumCost {
            guard let first = order.first else { break }
            order.removeFirst()
            entries[first] = nil
        }
    }

    /// Use only for in-place metadata changes (such as a confirmed read flag),
    /// which do not increase the retained payload or disturb LRU order.
    mutating func updateValues(_ transform: (Key, Value) -> Value) {
        for key in order {
            guard var entry = entries[key] else { continue }
            entry.value = transform(key, entry.value)
            entries[key] = entry
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

/// Each notification category changes independently. Comparing the individual
/// counts also catches an incoming reply masked by another category being read.
struct InboxCategoryRevisions {
    private var values: [InboxCategory: Int] = [:]

    func value(for category: InboxCategory) -> Int { values[category, default: 0] }

    mutating func incoming(from old: ForumUnreadCounts, to new: ForumUnreadCounts) {
        for category in InboxCategory.allCases where new.count(category) > old.count(category) {
            invalidate(category)
        }
    }

    mutating func invalidate(_ category: InboxCategory) {
        values[category, default: 0] += 1
    }
}
