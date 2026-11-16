import Foundation
import WebKit

@MainActor
private final class DirectoryGate {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct DirectoryServiceChecks {
    @MainActor
    static func main() async throws {
        let suite = "cc.seekdesk.qa.directory." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        let context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        let session = context.session
        session.observeIdentity(.init(signedIn: true, id: 101, name: "Fixture", floorsPerPage: 20))
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        func map(_ raw: Any) -> [String: Any] { raw as? [String: Any] ?? [:] }
        func args(_ route: String, member: Int = 101, page: Any = 1) -> [String: Any] {
            ["route": route, "memberId": member, "page": page, "accessRevision": session.accessRevision]
        }
        var activityReads = 0, memberReads = 0
        let gate = DirectoryGate()
        var block = false
        var requests = NativeDirectoryServices.Requests()
        requests.activity = { route, member, page, store in
            require(store === session.dataStore && !store.isPersistent, "Directory must use the injected account store")
            activityReads += 1
            require(route == .comments && member == 202 && page == 2, "Correct activity request")
            return .init(items: [.init(post_id: 77, title: "Fixture", floor_id: 31, text: "Reply"),
                                 .init(post_id: 77, title: "Duplicate", floor_id: 31, text: "Reply"),
                                 .init(post_id: -1, title: "Invalid", floor_id: nil, text: nil)],
                         floorsPerPage: 20, publicationDates: [77: Date(timeIntervalSince1970: 12345)])
        }
        requests.members = { route, store in
            require(store === session.dataStore && !store.isPersistent, "Member list must use injected store")
            require(route == .fans || route == .follow, "Private list route")
            memberReads += 1
            if block { await gate.wait() }
            return [.init(id: 202, name: "Member", avatar: nil, tags: []),
                    .init(id: 202, name: "Duplicate", avatar: nil, tags: [])]
        }
        let service = NativeDirectoryServices(context: context, requests: requests)
        func fails(_ method: String, _ arguments: [String: Any], _ code: String) async throws {
            do { _ = try await service.handle(method, arguments); fatalError("Expected failure \(code)") }
            catch let error as NativeBridgeError { require(error.code == code, "Wrong error \(error.code), expected \(code)") }
        }

        let activity = map(try await service.handle("space.activity", args("comments", member: 202, page: 2)))
        let items = activity["items"] as! [[String: Any]]
        require(items.count == 1, "Duplicate/invalid rows removed")
        require(items[0]["url"] as? String == "https://www.nodeseek.com/post-77-2#31", "Comment URL preserves page size and floor")
        require(items[0]["publishedMillis"] as? Double == 12_345_000, "Publication time is milliseconds")
        require(activity["accessRevision"] as? Int == session.accessRevision, "Bound response revision")
        print("PASS activity uses account WebKit, deduplicates rows and preserves floor/page destination")

        try await fails("space.activity", args("fans"), "invalid_directory")
        try await fails("space.activity", args("comments", page: 1.5), "invalid_arguments")
        try await fails("space.activity", args("comments", page: true), "invalid_arguments")
        try await fails("space.activity", args("comments", page: 0), "invalid_directory")
        try await fails("space.activity", args("comments", page: 10001), "invalid_directory")
        try await fails("space.members", args("fans", member: 202), "private_directory")
        require(activityReads == 1 && memberReads == 0, "Invalid/private requests must not reach network")
        print("PASS route/page/ID validation and private directory ownership before any read")

        let members = map(try await service.handle("space.members", args("follow")))
        let people = members["items"] as! [[String: Any]]
        require(people.count == 1 && people[0]["avatar"] as? String == "https://www.nodeseek.com/avatar/202.png", "Safe deduplicated member avatar")
        require(members["hasNext"] as? Bool == false, "Private API is not falsely paginated")
        print("PASS current-owner member list and native avatar fallback")

        block = true
        let pending = Task { @MainActor in try await service.handle("space.members", args("fans")) }
        while !gate.entered { await Task.yield() }
        session.observeIdentity(.init(signedIn: true, id: 303, name: "Other", floorsPerPage: 20))
        gate.release()
        do { _ = try await pending.value; fatalError("Old account result leaked") }
        catch let error as NativeBridgeError { require(error.code == "stale_authorization", "Old owner response rejected") }
        try await fails("space.members", args("fans", member: 101), "private_directory")
        print("PASS account switch rejects a late private response and old-owner request")
    }
}
