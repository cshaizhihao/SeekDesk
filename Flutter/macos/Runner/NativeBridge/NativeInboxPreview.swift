import CoreFoundation
import Foundation

/// Read-only notification detail. It owns no workspace reader, selected inbox
/// category, acknowledgement state, or retained WebView.
@MainActor
final class NativeInboxPreview {
    struct Document {
        let thread: ForumThread
        let url: URL
    }

    typealias Fetch = @MainActor (URL, String, ForumSession) async throws -> Document

    nonisolated static let fetch: Fetch = { url, floor, session in
        let (thread, page) = try await ForumReaderState.fetch(url, floor: floor, session: session)
        defer { page.webView.stopLoading() }
        try Task.checkCancellation()
        guard let actual = page.webView.url else { throw ForumPageError.changed }
        return Document(thread: thread, url: actual)
    }

    private struct Target {
        let url: URL
        let postID: Int
        let page: Int
        let floor: Int
        let authorID: Int?

        init(_ args: [String: Any]) throws {
            postID = try NativeDTO.integer(args, "postID")
            floor = try NativeDTO.integer(args, "floor")
            if let value = args["authorID"], !(value is NSNull) {
                authorID = try NativeDTO.integer(args, "authorID")
            } else { authorID = nil }
            guard postID > 0, floor >= 0, authorID.map({ $0 > 0 }) ?? true else {
                throw Self.invalid()
            }
            let source = try NativeDTO.url(args, forumOnly: true)
            let route = try Self.route(source, floor: floor)
            guard route.post == postID, floor != 0 || route.page == 1 else { throw Self.invalid() }
            page = route.page
            var canonical = URLComponents(url: Forum.home.appendingPathComponent("post-\(postID)-\(page)"), resolvingAgainstBaseURL: false)!
            canonical.fragment = String(floor)
            url = canonical.url!
        }

        var key: InboxReadCache<Cached>.Key { .init(route: url.absoluteString, peer: authorID) }

        func reply(in document: Document) throws -> ForumFloor {
            let route = try Self.route(document.url, floor: floor)
            guard route.post == postID, route.page == page, document.thread.page == page else {
                throw Self.unavailable()
            }
            let matching = ([document.thread.root].compactMap { $0 } + document.thread.replies)
                .filter { $0.id == String(floor) }
            let correctPlacement = floor == 0 ? document.thread.root?.id == "0" :
                document.thread.replies.contains(where: { $0.id == String(floor) })
            guard matching.count == 1, let reply = matching.first, !reply.blocks.isEmpty,
                  correctPlacement,
                  authorID == nil || reply.authorID == authorID else { throw Self.unavailable() }
            return reply
        }

        private static func route(_ url: URL, floor: Int) throws -> (post: Int, page: Int) {
            guard Forum.contains(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.query == nil, parts.percentEncodedPath == parts.path else { throw invalid() }
            let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
            let fields = path.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "/post",
                  let post = Int(fields[1]), let page = Int(fields[2]), post > 0, page > 0,
                  post < 9_007_199_254_740_991, page < 9_007_199_254_740_991,
                  String(post) == fields[1], String(page) == fields[2] else { throw invalid() }
            if let fragment = parts.fragment {
                let value = fragment.hasPrefix("comment-") ? String(fragment.dropFirst(8)) : fragment
                guard value == String(floor) else { throw invalid() }
            }
            return (post, page)
        }

        static func invalid() -> NativeBridgeError {
            NativeBridgeError(code: "invalid_preview_target", message: "通知指向的帖子或楼层无效。")
        }

        static func unavailable() -> NativeBridgeError {
            NativeBridgeError(code: "preview_unavailable", message: "暂时无法读取这层回复，内容可能已删除或当前账号无权查看。")
        }
    }

    private struct Cached {
        let reply: ForumFloor
        let updated: Date
        let writeRevision: UUID
    }

    private struct Active {
        let generation: UUID
        let requestID: String
        let revision: Int
        var task: Task<Document, Error>?
    }

    private let session: ForumSession
    private let fetchDocument: Fetch
    private let now: () -> Date
    private var cache = InboxReadCache<Cached>()
    private var active: Active?
    private var disposed = false

    init(session: ForumSession, fetch: @escaping Fetch = NativeInboxPreview.fetch,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        fetchDocument = fetch
        self.now = now
    }

    func load(_ args: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !disposed else { throw CancellationError() }
        let revision = try NativeDTO.integer(args, "accessRevision")
        guard revision == session.accessRevision else { throw staleAccess() }
        let requestID = try Self.requestID(args)
        let target = try Target(args)
        if let force = args["force"] {
            guard let number = force as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw NativeBridgeError(code: "invalid_arguments", message: "刷新参数无效。")
            }
        }
        let force = args["force"] as? Bool ?? false
        let generation = UUID(), writeRevision = session.threadRevision(String(target.postID))
        active?.task?.cancel()
        active = Active(generation: generation, requestID: requestID, revision: revision)
        defer { if active?.generation == generation { active = nil } }
        cache.prepare(access: revision, refresh: 0)

        func requireCurrent() throws {
            try Task.checkCancellation()
            guard !disposed, active?.generation == generation else { throw CancellationError() }
            guard revision == session.accessRevision else { throw staleAccess() }
            guard writeRevision == session.threadRevision(String(target.postID)) else { throw CancellationError() }
        }

        if !force, let saved = cache.value(for: target.key), saved.writeRevision == writeRevision {
            let age = now().timeIntervalSince(saved.updated)
            if age >= 0 && age < 120 {
                try requireCurrent()
                return payload(saved.reply, target: target, requestID: requestID, revision: revision)
            }
        }
        if !force, session.threadIsFresh(at: target.url), let thread = session.cachedThread(at: target.url),
           let reply = try? target.reply(in: Document(thread: thread, url: target.url)) {
            try requireCurrent()
            // Do not give a nearly-expired reader entry another full lifetime.
            return payload(reply, target: target, requestID: requestID, revision: revision)
        }

        let task = Task { @MainActor [fetchDocument, session] in
            try await fetchDocument(target.url, String(target.floor), session)
        }
        active?.task = task
        let document: Document
        do {
            document = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch {
            // A superseded transport may fail instead of acknowledging its
            // cancellation. Do not surface that stale failure to the new pane.
            try requireCurrent()
            guard !task.isCancelled else { throw CancellationError() }
            throw error
        }
        try requireCurrent()
        guard !task.isCancelled else { throw CancellationError() }
        let reply = try target.reply(in: document)
        try requireCurrent()
        remember(reply, target: target, writeRevision: writeRevision)
        return payload(reply, target: target, requestID: requestID, revision: revision)
    }

    func cancel(_ args: [String: Any]) throws -> [String: Any] {
        guard !disposed else { throw CancellationError() }
        let revision = try NativeDTO.integer(args, "accessRevision")
        guard revision == session.accessRevision else { throw staleAccess() }
        let requestID = try Self.requestID(args)
        let cancelled = active?.requestID == requestID && active?.revision == revision
        if cancelled {
            active?.task?.cancel()
            active = nil
        }
        return ["requestID": requestID, "cancelled": cancelled, "accessRevision": revision]
    }

    func invalidate() {
        active?.task?.cancel()
        active = nil
        cache.removeAll()
    }

    func dispose() {
        disposed = true
        invalidate()
    }

    private func remember(_ reply: ForumFloor, target: Target, writeRevision: UUID) {
        let thread = ForumThread(title: "", category: "", root: target.floor == 0 ? reply : nil,
            replies: target.floor == 0 ? [] : [reply], pages: [], page: target.page, replyRestriction: nil)
        cache.insert(Cached(reply: reply, updated: now(), writeRevision: writeRevision), for: target.key,
            cost: ForumThreadCacheCost.estimate(thread))
    }

    private func payload(_ reply: ForumFloor, target: Target, requestID: String, revision: Int) -> [String: Any] {
        ["requestID": requestID, "accessRevision": revision, "url": target.url.absoluteString,
         "postID": target.postID, "page": target.page, "floor": target.floor,
         "blocks": NativeForumServices.normalizedThread(NativeDTO.encode(reply.blocks))]
    }

    private static func requestID(_ args: [String: Any]) throws -> String {
        let value = try NativeDTO.string(args, "requestID")
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeBridgeError(code: "invalid_arguments", message: "通知预览请求标识无效。")
        }
        return value
    }

    private func staleAccess() -> NativeBridgeError {
        NativeBridgeError(code: "stale_authorization", message: "账号状态已变化，请重新选择通知。")
    }
}
