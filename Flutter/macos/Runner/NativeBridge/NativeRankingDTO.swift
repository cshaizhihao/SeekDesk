import Foundation

extension NativeDTO {
    // Keep raw positions and timestamps even when a failed refresh leaves a
    // previous snapshot. Flutter applies blocklist filtering after this map.
    static func rankingSnapshot(period: RankingPeriod, snapshot: RankingSnapshot?, failed: Bool) -> [String: Any] {
        ["period": period.rawValue,
         "updatedAt": optional(snapshot?.updatedAt.timeIntervalSince1970),
         "posts": snapshot?.posts.enumerated().map { index, item in
             ["id": String(item.id), "url": item.url.absoluteString, "title": item.post.title,
              "author": item.post.author, "authorID": optional(item.post.author_id),
              "normalizedAuthor": ForumSearch.normalized(item.post.author), "position": index + 1,
              "category": item.post.category ?? "", "views": item.post.views ?? 0,
              "replies": item.post.comments ?? 0] as [String: Any]
         } ?? [],
         "error": failed ? "热榜暂时无法加载。" : NSNull()]
    }
}
