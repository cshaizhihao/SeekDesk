import Foundation
import OSLog
import WebKit

/// Listing and directory failures use a small, stable vocabulary. Never expose
/// raw transport descriptions: they can include URLs or authentication data.
enum ForumListingIssue: String, Error {
    case verification, signInRequired, missing, changed, timedOut, network, rateLimited

    static func classify(_ error: Error) -> Self? {
        if error is CancellationError { return nil }
        if let issue = error as? Self { return issue }
        if let issue = error as? ForumPageError {
            switch issue {
            case .verification: return .verification
            case .signInRequired: return .signInRequired
            case .missing: return .missing
            case .changed: return .changed
            case .timedOut: return .timedOut
            case .network: return .network
            }
        }
        if error is DecodingError { return .changed }
        let underlying = error as NSError
        if underlying.domain == NSURLErrorDomain {
            if underlying.code == NSURLErrorCancelled { return nil }
            if underlying.code == NSURLErrorTimedOut { return .timedOut }
        }
        return .network
    }

    func message(people: Bool = false) -> String {
        let content = people ? "用户搜索结果" : "帖子列表或搜索结果"
        switch self {
        case .verification: return "请先完成 NodeSeek 站点验证，再重试读取\(content)。"
        case .signInRequired: return "请登录 NodeSeek 后读取\(content)。"
        case .missing: return "NodeSeek 未返回\(content)，当前页面可能不存在或无权访问。"
        case .changed: return "暂时无法解析\(content)，页面结构可能已变化。请重试或在浏览器中查看。"
        case .timedOut: return "读取\(content)超时，请检查网络后重试。"
        case .network: return "暂时无法读取\(content)，请检查网络后重试。"
        case .rateLimited: return "NodeSeek 请求过于频繁，请稍后重试读取\(content)。"
        }
    }
}

@MainActor
enum ForumListing {
    private static let logger = Logger(subsystem: "cc.seekdesk", category: "ListingRead")

    static func fetch(_ url: URL) async throws -> ForumListingPage {
        let page = ForumWebPage(dataStore: .default())
        let started = Date()
        let kind = url.path.hasPrefix("/search") ? "search" : "listing"
        var stage = "read"
        do {
            try await page.read(url)
            stage = "response"
            try validateResponse(status: page.status, challenged: page.challenged, actual: page.webView.url, requested: url)
            stage = "extract"
            let result = try await page.webView.callAsyncJavaScript(extract, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard let json = result as? String else { throw ForumPageError.changed }
            stage = "decode"
            let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            let standard = ISO8601DateFormatter()
            var seen = Set<String>()
            let posts: [FeedPost] = payload.rows.compactMap { row in
                guard let id = Forum.topicID(row.url), !row.title.isEmpty, seen.insert(id).inserted else { return nil }
                let avatar = row.avatar.flatMap { Forum.contains($0) && $0.path.hasPrefix("/avatar/") ? $0 : nil }
                return FeedPost(id: id, url: row.url, title: row.title, author: row.author, category: row.category,
                    published: fractional.date(from: row.date) ?? standard.date(from: row.date), summary: "", authorID: row.authorID,
                    readingRank: row.readingRank, featured: row.featured, listedAvatarURL: avatar)
            }
            guard payload.rows.isEmpty || !posts.isEmpty else { throw ForumPageError.changed }
            return ForumListingPage(posts: posts, next: payload.next)
        } catch {
            if !Task.isCancelled, let issue = ForumListingIssue.classify(error) {
                let elapsed = Int(max(0, Date().timeIntervalSince(started)) * 1_000)
                // Whitelist only bounded diagnostic fields; never interpolate
                // URL/query, headers, response content or raw Error values.
                logger.error("kind=\(kind, privacy: .public) stage=\(stage, privacy: .public) status=\(page.status ?? 0) code=\(issue.rawValue, privacy: .public) elapsedMs=\(elapsed)")
            }
            throw error
        }
    }

    /// Validate the top-level document before a parser can mistake an HTTP
    /// failure page for empty search results. Kept pure for local fixtures.
    static func validateResponse(status: Int?, challenged: Bool, actual: URL?, requested: URL) throws {
        if challenged { throw ForumListingIssue.verification }
        if actual?.path == Forum.signIn.path || status == 401 { throw ForumListingIssue.signInRequired }
        guard let status else { throw ForumListingIssue.network }
        if status == 429 { throw ForumListingIssue.rateLimited }
        if status == 404 || status == 410 { throw ForumListingIssue.missing }
        guard (200..<300).contains(status) else { throw ForumListingIssue.network }
        guard let actual, Forum.contains(actual),
              actual.path == requested.path ||
                (requested.path.hasPrefix("/search") && actual.path.hasPrefix("/search")) else {
            throw ForumListingIssue.network
        }
    }

    private struct Payload: Decodable {
        struct Row: Decodable {
            let url: URL
            let title: String
            let author: String
            let authorID: Int?
            let avatar: URL?
            let category: String
            let date: String
            let readingRank: Int?
            let featured: Bool
        }
        let rows: [Row]
        let next: URL?
    }

    private static let extract = #"""
    const main = document.querySelector('#nsk-body-left') || document.querySelector('#nsk-frame');
    if (!main) return null;
    const isSearch = /^\/search(?:\/|$)/.test(location.pathname);
    const isAward = /^\/award(?:\/|$)/.test(location.pathname);
    const lists = [...main.querySelectorAll(':scope > ul.post-list')];
    if (!lists.length && (isAward || isSearch)) lists.push(...main.querySelectorAll('ul.post-list'));
    if (!lists.length && !isSearch) return null;
    const text = element => element?.textContent.trim() ?? '';
    let results = (isAward && lists.length ? lists : [lists[0] || main])
        .flatMap(list => [...list.querySelectorAll('.post-list-item, .search-result-item')]);
    if (isSearch && !results.length) {
        results = [...main.querySelectorAll('.post-title, h2, h3')].map(title => title.closest('li') || title.parentElement);
    }
    const rows = results.flatMap(row => {
        const link = row.querySelector('.post-title a[href^="/post-"], a[href^="/post-"]');
        if (!link) return [];
        const category = row.querySelector('.post-category, a[href^="/categories/"]')?.getAttribute('href')?.split('/').pop() ?? '';
        const author = row.querySelector('.info-author a') || row.querySelector('a[href^="/space/"]');
        const authorID = Number(author?.getAttribute('href')?.match(/^\/space\/(\d+)$/)?.[1]) || null;
        const photo = row.querySelector('img.avatar-normal') || author?.querySelector('img');
        const avatar = photo?.getAttribute('data-src') || photo?.getAttribute('src');
        const title = link.closest('.post-title, h2, h3') || row.querySelector('.post-title');
        const lock = title?.querySelector('use[href="#lock"]')?.closest('span');
        const restriction = text(lock);
        const level = Number(/^[1-9]\d{0,2}$/.test(restriction) ? restriction : 0);
        const readingRank = restriction === '私有' ? 255 : (level > 0 && level <= 255 ? level : null);
        const featured = Boolean(title?.querySelector('a[href="/award"] use[href="#diamonds"]'));
        return [{url:link.href, title:text(link), author:text(author) || photo?.alt || '', authorID,
            avatar: avatar && /^\/avatar\//.test(avatar) ? new URL(avatar, location.origin).href : null,
            category, date:row.querySelector('time[datetime]')?.getAttribute('datetime') ?? '', readingRank, featured}];
    });
    let next = main.querySelector('[aria-label="pagination"] a[rel="next"], a.pager-next[href], .pagination a[rel="next"]');
    if (!next && isAward) {
        const current = Number(location.pathname.match(/\/page-(\d+)$/)?.[1] ?? 1);
        const nextPath = '/award/page-' + (current + 1);
        next = [...main.querySelectorAll('.pagination a[href]')].find(link => link.pathname === nextPath);
    }
    return JSON.stringify({rows, next:next?.href ?? null});
    """#
}
