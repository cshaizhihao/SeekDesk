import AppKit

/// Lightweight reading positions survive eviction of parsed posts and WebKit pages.
/// Only navigation anchors are stored; the account's post contents are never persisted here.
@MainActor
final class ReadingProgress: NSObject {
    private struct Entry: Codable { let page: URL; let anchor: String; let updated: Date }
    private let defaults: UserDefaults
    private var owner: Int?
    private var entries: [URL: Entry] = [:]
    private var pending: Task<Void, Never>?
    private var dirty = false
    private var key: String { "reading.positions.v1." + (owner.map(String.init) ?? "guest") }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        restore()
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(flush), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func activate(_ owner: Int?) {
        guard self.owner != owner else { return }
        flush()
        self.owner = owner
        restore()
    }

    func anchor(at url: URL) -> String? { Self.page(url).flatMap { entries[$0]?.anchor } }

    func remember(_ anchor: String, at url: URL) {
        guard let page = Self.page(url), Self.valid(anchor), entries[page]?.anchor != anchor else { return }
        entries[page] = Entry(page: page, anchor: anchor, updated: Date())
        if entries.count > 500, let oldest = entries.values.min(by: { $0.updated < $1.updated }) {
            entries.removeValue(forKey: oldest.page)
        }
        dirty = true
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    @objc func flush() {
        pending?.cancel()
        pending = nil
        guard dirty else { return }
        if let data = try? JSONEncoder().encode(Array(entries.values)) { defaults.set(data, forKey: key) }
        dirty = false
    }

    private func restore() {
        entries = [:]
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        for entry in saved.sorted(by: { $0.updated > $1.updated }).prefix(500) {
            guard let page = Self.page(entry.page), Self.valid(entry.anchor), entries[page] == nil else { continue }
            entries[page] = Entry(page: page, anchor: entry.anchor, updated: entry.updated)
        }
    }

    private static func page(_ url: URL) -> URL? {
        guard Forum.topicID(url) != nil else { return nil }
        return Forum.home.appendingPathComponent(url.lastPathComponent)
    }

    static func valid(_ anchor: String) -> Bool {
        if ["thread-title", "thread-discussion"].contains(anchor) { return true }
        guard anchor.hasPrefix("floor-") else { return false }
        let floor = anchor.dropFirst(6)
        return !floor.isEmpty && floor.count <= 12 && floor.utf8.allSatisfy { (48...57).contains($0) }
    }
}
