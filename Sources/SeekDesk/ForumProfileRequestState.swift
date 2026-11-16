import SwiftUI

/// A mounted author observes only this member's value, never the entire cache.
@MainActor
final class ForumProfileEntry: ObservableObject {
    @Published private(set) var profile: ForumUserProfile?

    fileprivate init(_ profile: ForumUserProfile?) { self.profile = profile }

    fileprivate func replace(_ profile: ForumUserProfile?) {
        guard self.profile != profile else { return }
        self.profile = profile
    }
}

/// Values follow ForumSession's bounded cache policy. Weak cells stay stable
/// while a view observes them without retaining every previously seen author.
@MainActor
final class ForumProfileStore {
    private struct WeakEntry { weak var value: ForumProfileEntry? }
    private var entries: [Int: WeakEntry] = [:]
    private let anonymous = ForumProfileEntry(nil)
    private(set) var profiles: [Int: ForumUserProfile] = [:]

    func entry(for id: Int?) -> ForumProfileEntry {
        guard let id else { return anonymous }
        if let entry = entries[id]?.value { return entry }
        if entries.count >= 256 { entries = entries.filter { $0.value.value != nil } }
        let entry = ForumProfileEntry(profiles[id])
        entries[id] = WeakEntry(value: entry)
        return entry
    }

    func update(_ profile: ForumUserProfile) {
        guard profiles[profile.member_id] != profile else { return }
        profiles[profile.member_id] = profile
        entries[profile.member_id]?.value?.replace(profile)
    }

    func remove(_ id: Int) {
        profiles.removeValue(forKey: id)
        entries[id]?.value?.replace(nil)
    }

    func removeAll() {
        profiles.removeAll()
        for entry in entries.values { entry.value?.replace(nil) }
        entries = entries.filter { $0.value.value != nil }
    }
}

struct ForumProfileObserver<Content: View>: View {
    @ObservedObject private var entry: ForumProfileEntry
    private let content: (ForumUserProfile?) -> Content

    init(store: ForumProfileStore, id: Int?, @ViewBuilder content: @escaping (ForumUserProfile?) -> Content) {
        _entry = ObservedObject(wrappedValue: store.entry(for: id))
        self.content = content
    }

    var body: some View { content(entry.profile) }
}

/// Request feedback is observed by profile UI, independently of reader content.
@MainActor
final class ForumProfileRequestState: ObservableObject {
    @Published private(set) var loading: Set<Int> = []
    @Published private(set) var failures: Set<Int> = []

    func begin(_ id: Int) {
        if !loading.contains(id) { loading.insert(id) }
        if failures.contains(id) { failures.remove(id) }
    }

    func finish(_ id: Int) {
        if loading.contains(id) { loading.remove(id) }
    }

    func fail(_ id: Int) {
        if !failures.contains(id) { failures.insert(id) }
    }

    func reset() {
        if !loading.isEmpty { loading.removeAll() }
        if !failures.isEmpty { failures.removeAll() }
    }
}

/// Keeps request-only updates inside profile surfaces without forwarding them to ForumSession.
struct ForumProfileRequestObserver<Content: View>: View {
    @ObservedObject var state: ForumProfileRequestState
    @ViewBuilder let content: (ForumProfileRequestState) -> Content

    var body: some View { content(state) }
}
