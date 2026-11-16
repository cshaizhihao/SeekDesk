import Foundation
import WebKit

/// Directory reads use the same native WebKit account/proxy partition as the
/// reader. This service retains no private list cache between requests.
@MainActor
final class NativeDirectoryServices {
    struct ActivityPage {
        let items: [ForumActivity]
        let floorsPerPage: Int
        let publicationDates: [Int: Date]
    }

    struct Requests {
        var activity: (ForumDirectory.Route, Int, Int, WKWebsiteDataStore) async throws -> ActivityPage = { route, member, page, store in
            let result = try await ForumDirectory.activity(route, member: member, page: page, dataStore: store)
            try Task.checkCancellation()
            let dates = route == .discussions
                ? await ForumDirectory.publicationDates(for: result.items.map(\.post_id), using: result.site)
                : [:]
            try Task.checkCancellation()
            return ActivityPage(items: result.items, floorsPerPage: result.floorsPerPage, publicationDates: dates)
        }
        var members: (ForumDirectory.Route, WKWebsiteDataStore) async throws -> [ForumUserReference] = { route, store in
            try await ForumDirectory.members(route, dataStore: store)
        }
    }

    private let context: SeekDeskBridgeContext
    private let requests: Requests

    init(context: SeekDeskBridgeContext, requests: Requests = Requests()) {
        self.context = context
        self.requests = requests
    }

    func handle(_ method: String, _ args: [String: Any]) async throws -> Any {
        try Task.checkCancellation()
        guard let route = ForumDirectory.Route(rawValue: try NativeDTO.string(args, "route")) else {
            throw invalid("个人空间栏目无效。")
        }
        let member = try NativeDTO.integer(args, "memberId")
        guard member > 0 else { throw invalid("用户编号无效。") }
        switch method {
        case "space.activity":
            guard route == .discussions || route == .comments else { throw invalid("请选择主题帖或评论。") }
            let page = args["page"] == nil ? 1 : try NativeDTO.integer(args, "page")
            guard (1...10_000).contains(page) else { throw invalid("页码超出可读取范围。") }
            let token = try context.requireAuthorization(args, signedIn: false)
            let result = try await requests.activity(route, member, page, context.session.dataStore)
            try requireCurrent(token)
            var seen = Set<String>()
            let items = result.items.filter { $0.post_id > 0 && ($0.floor_id ?? 0) >= 0 && seen.insert($0.id).inserted }
            return [
                "route": route.rawValue, "memberId": member, "page": page,
                "accessRevision": token.revision,
                "hasNext": result.items.count >= 15,
                "items": items.map { item -> [String: Any] in
                    ["id": item.id, "postId": item.post_id, "title": item.title ?? "帖子 #\(item.post_id)",
                     "floor": item.floor_id ?? 0, "text": item.text ?? "",
                     "url": item.destination(floorsPerPage: max(1, result.floorsPerPage)).absoluteString,
                     "publishedMillis": NativeDTO.optional(result.publicationDates[item.post_id].map { $0.timeIntervalSince1970 * 1000 })]
                }
            ]
        case "space.members":
            guard route == .fans || route == .follow else { throw invalid("请选择粉丝或关注。") }
            let token = try context.requireAuthorization(args)
            guard token.owner == member else {
                throw NativeBridgeError(code: "private_directory", message: "只能读取当前账号的粉丝和关注列表。")
            }
            let result = try await requests.members(route, context.session.dataStore)
            try requireCurrent(token)
            var seen = Set<Int>()
            return [
                "route": route.rawValue, "memberId": member, "page": 1,
                "accessRevision": token.revision, "hasNext": false,
                "items": result.filter { $0.id > 0 && seen.insert($0.id).inserted }.map {
                    ["id": $0.id, "name": $0.name,
                     "avatar": ($0.avatar ?? Forum.avatar($0.id)).absoluteString] as [String: Any]
                }
            ]
        default:
            throw NativeBridgeError(code: "not_implemented", message: "个人空间操作不存在。")
        }
    }

    private func requireCurrent(_ token: ForumSession.Authorization) throws {
        try Task.checkCancellation()
        guard context.session.accessRevision == token.revision,
              context.session.memberID == token.owner else {
            throw NativeBridgeError(code: "stale_authorization", message: "账号状态已变化，请重新读取个人空间。")
        }
    }

    private func invalid(_ message: String) -> NativeBridgeError {
        NativeBridgeError(code: "invalid_directory", message: message)
    }
}
