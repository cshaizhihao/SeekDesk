import Foundation

struct DiscussionOptions: Codable {
    struct Category: Codable, Identifiable {
        let id: String
        let title: String
    }
    let kind: String
    let categories: [Category]?
    let maxRank: Int?
    var reason: String? = nil

    var failureMessage: String {
        (reason.flatMap(DiscussionReadIssue.init(rawValue:)) ?? .unavailable).message
    }
}

/// Fixed diagnostics only: neither page HTML, script exceptions nor account
/// metadata may be presented as a failure reason.
enum DiscussionReadIssue: String {
    case unexpectedOrigin, unexpectedPage, configurationMissing, editorMissing
    case categoryMissing, categoriesUnavailable, pageLoad, optionsRead, identityRead, unavailable

    var message: String {
        switch self {
        case .unexpectedOrigin: "发帖页跳转到了不支持的地址，请重新打开 NodeSeek 后重试。"
        case .unexpectedPage: "未能进入 NodeSeek 发帖页面，请重试。"
        case .configurationMissing: "NodeSeek 发帖配置尚未就绪，请稍后重试。"
        case .editorMissing: "NodeSeek 发帖编辑器尚未就绪，请稍后重试。"
        case .categoryMissing: "NodeSeek 发帖页尚未提供板块选择，请稍后重试。"
        case .categoriesUnavailable: "NodeSeek 发帖页未提供可用板块，请确认账号发帖权限后重试。"
        case .pageLoad: "未能加载 NodeSeek 发帖页面，请重试。"
        case .optionsRead: "未能解析 NodeSeek 发帖选项，请重试。"
        case .identityRead: "未能确认发帖页的登录状态，请重新打开登录窗口后重试。"
        case .unavailable: "暂时无法读取 NodeSeek 发帖选项，请重试。"
        }
    }
}

struct DiscussionResponse: Codable {
    let kind: String
    let redirect: String?
    let message: String?

    var topicURL: URL? {
        guard kind == "accepted", let redirect, let url = URL(string: redirect, relativeTo: Forum.home)?.absoluteURL,
              Forum.topicID(url) != nil else { return nil }
        return Forum.pageURL(url)
    }
}

enum DiscussionScript {
    static let page = Forum.home.appendingPathComponent("new-discussion")

    // A hidden WKWebView throttles JavaScript timers. Poll from Swift so a
    // delayed editor gets regular checks and cancellation can stop the wait.
    @MainActor
    static func readOptions(timeout: Duration = .seconds(12),
                            read: () async throws -> DiscussionOptions) async throws -> DiscussionOptions {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            try Task.checkCancellation()
            let options = try await read()
            try Task.checkCancellation()
            guard options.kind == "unavailable",
                  let issue = options.reason.flatMap(DiscussionReadIssue.init(rawValue:)),
                  [.configurationMissing, .editorMissing, .categoryMissing, .categoriesUnavailable].contains(issue),
                  clock.now < deadline else { return options }
            try await clock.sleep(until: min(deadline, clock.now + .milliseconds(250)))
        }
    }

    private static let categorySelect = "document.querySelector('select#category') || document.querySelector('select[name=category]')"

    static let options = #"""
    const unavailable = reason => JSON.stringify({kind:'unavailable', reason});
    if (location.protocol !== 'https:' || !['www.nodeseek.com','nodeseek.com'].includes(location.host)) {
        return unavailable('unexpectedOrigin');
    }
    if (location.pathname === '/signIn.html') return JSON.stringify({kind:'signedOut'});
    if (location.pathname !== '/new-discussion') {
        const config = window.__config__;
        if (config && Object.prototype.hasOwnProperty.call(config, 'user') && !config.user) {
            return JSON.stringify({kind:'signedOut'});
        }
        return unavailable('unexpectedPage');
    }
    const config = window.__config__;
    if (!config || !Object.prototype.hasOwnProperty.call(config, 'user')) return unavailable('configurationMissing');
    if (!config.user) return JSON.stringify({kind:'signedOut'});
    if (!document.querySelector('#editor')) return unavailable('editorMissing');
    const select = \#(categorySelect);
    if (!select) return unavailable('categoryMissing');
    const categories = [...select.options]
        .filter(option => !option.disabled && !option.closest('optgroup:disabled') &&
            /^[a-z][a-z0-9-]{0,63}$/.test(option.value))
        .map(option => ({id:option.value, title:option.textContent.trim()}));
    if (!categories.length) return unavailable('categoriesUnavailable');
    return JSON.stringify({kind:'ready', categories, maxRank:Number(config.user.rank) || 0});
    """#

    static let publish = #"""
    if (location.protocol !== 'https:' || !['www.nodeseek.com','nodeseek.com'].includes(location.host) ||
        location.pathname !== '/new-discussion' || !document.querySelector('#editor')) {
        return JSON.stringify({kind:'unavailable'});
    }
    if (!window.__config__?.user) return JSON.stringify({kind:'signedOut'});
    const select = \#(categorySelect);
    const categoryOption = [...(select?.options || [])]
        .find(option => option.value === category && !option.disabled && !option.closest('optgroup:disabled'));
    if (!categoryOption || !Number.isInteger(rank) || rank < 0 ||
        (rank !== 255 && rank > Number(window.__config__.user.rank || 0))) {
        return JSON.stringify({kind:'rejected',message:'请重新选择可发帖的版块和阅读权限。'});
    }
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const token = Array.from(crypto.getRandomValues(new Uint8Array(16)), n => alphabet[n % alphabet.length]).join('');
    try {
        const result = await fetch('/api/content/new-discussion', {
            method:'POST', credentials:'same-origin', redirect:'error', signal:AbortSignal.timeout(22000),
            headers:{'Content-Type':'application/json','csrf-token':token},
            body:JSON.stringify({mode:'new-discussion',title,content,category,rank})
        });
        if (result.headers.get('cf-mitigated') === 'challenge') return JSON.stringify({kind:'verification'});
        if (result.status === 401) return JSON.stringify({kind:'signedOut'});
        const body = await result.json().catch(() => null);
        if (result.ok && body?.success === true) {
            return JSON.stringify({kind:'accepted',redirect:typeof body.redirect === 'string' ? body.redirect : null});
        }
        if (body?.success === false || result.status === 403 || result.status === 429) {
            return JSON.stringify({kind:'rejected',message:typeof body?.message === 'string' ? body.message : null});
        }
        return JSON.stringify({kind:'unknown'});
    } catch {
        return JSON.stringify({kind:'unknown'});
    }
    """#
}
