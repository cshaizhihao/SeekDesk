import AppKit
import Combine
import CoreFoundation
import Darwin
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class NativeForumServices {
    let context: SeekDeskBridgeContext
    private var readers: [String: ForumReaderState] = [:]
    private var readerOrder: [String] = []
    private struct InlineEditState {
        let editor: ForumInlineEdit
        let authorization: ForumSession.Authorization
    }
    private var inlineEdits: [String: InlineEditState] = [:]
    private struct InboxKey: Hashable { let kind: String; let peer: Int? }
    private var accounts: [InboxKey: ForumAccountReader] = [:]
    private var accountOrder: [InboxKey] = []
    private var accountObservers: [InboxKey: AnyCancellable] = [:]
    private var profileAccount = ForumAccountReader()
    private var inboxLoads: [InboxKey: UUID] = [:]
    private var readerLoads: [String: UUID] = [:]
    private struct AuthorRead {
        let topicID: String
        let task: Task<Void, Never>
    }
    private var authorReads: [UUID: AuthorRead] = [:]
    private var inboxSelection = UUID()
    private var publisher = DiscussionPublisher()
    private let ranking = RankingState()
    private var inboxKind = "mentions"
    private var inboxPeer: Int?
    private var inboxRefresh = 0
    private var inboxRevisions = InboxCategoryRevisions()
    private var observedUnread = ForumUnreadCounts()
    private let inboxPreview: NativeInboxPreview
    private var subscriptions = Set<AnyCancellable>()
    private var uploading: Bool { uploadID != nil }
    private var uploadID: UUID?
    private var uploadTask: Task<URL, Error>?
    private var uploadKeyRead: (operation: UUID, task: Task<String?, Error>)?
    private var keyMutationID: UUID?
    private var keyMutationTask: Task<Void, Error>?
    var hasPendingImageKeyMutation: Bool { keyMutationID != nil }
    private let composerClipboard: NativeComposerClipboard
    let composerDrop = NativeComposerDropStore()
    private let imageEncoder: NativeImageEncoder
    private var clipboardUpload: (token: String, identity: NativeComposerClipboard.Identity, operation: UUID)?
    private var editorWriteID: UUID?
    private var profileLoad: UUID?
    private var optionsLoad: UUID?
    private var lastSubmissionMessage: String?
    private var writeTasks: [UUID: Task<Void, Never>] = [:]
    private var offsetStore: NativeReaderOffsetStore
    private var disposed = false
    struct Requests {
        var image: @Sendable (URL, ForumImageRequest.Kind) async throws -> ForumImageRequest.Bitmap = { url, kind in
            try await ForumImageRequest.fetchBitmap(url, kind: kind)
        }
        var reader: (Topic, ForumReaderState, ForumSession, Bool) async -> Bool = { topic, reader, session, force in
            await reader.load(topic, session: session, force: force)
        }
        var inbox: (ForumAccountReader, String, Int?, Int, Int, ForumSession) async -> Void = { account, kind, peer, refresh, revision, session in
            await account.load(kind, peer: peer, refresh: refresh, revision: revision, session: session)
        }
        var inboxState: @MainActor (ForumAccountReader) -> ForumAccountReader.State = { $0.state }
        var markRead: @MainActor (ForumAccountReader, InboxReadTarget, ForumSession) async -> Void = { account, target, session in
            await account.markRead(target, session: session)
        }
        var prepareMessage: @MainActor (DraftImageSizing, String, @escaping DraftImageSizing.Authorization) async throws -> String = {
            try await $0.prepare($1, authorized: $2)
        }
        var sendMessage: @MainActor (ForumAccountReader, Int, String, Bool) async -> MessageSendResult = {
            await $0.send(peer: $1, content: $2, markdown: $3)
        }
        var refreshMessageUnread: @MainActor (ForumSession) async -> Void = {
            await $0.refreshUnread(afterWrite: true)
        }
        var inboxPreview: NativeInboxPreview.Fetch = NativeInboxPreview.fetch
        var profile: (Int, ForumSession, Bool) async -> Void = { id, session, force in
            await session.loadProfile(id, includeReadme: true, force: force)
        }
        var readerAuthor: @MainActor (Int, ForumWebPage, ForumSession) async -> Void = { id, page, session in
            await session.loadProfile(id, using: page, includeReadme: false)
        }
        var options: (DiscussionPublisher, ForumSession, NewDiscussionDraft) async -> Void = { publisher, session, draft in
            await publisher.load(session, draft: draft)
        }
        var preparePage: @MainActor (Topic, ForumReaderState, ForumSession) async -> ForumWebPage? = { topic, reader, session in
            await reader.preparePage(topic, session: session)
        }
        var sendReply: @MainActor (Topic, ForumWebPage, ForumSession) -> Task<Void, Never>? = { topic, page, session in
            session.send(topic: topic, on: page)
        }
        var publish: @MainActor (DiscussionPublisher, NewDiscussionDraft, ForumSession, @escaping (URL?) -> Void) -> Task<Void, Never>? = {
            publisher, draft, session, accepted in publisher.publish(draft, session: session, accepted: accepted)
        }
        var saveEdit: @MainActor (ForumInlineEdit, ForumWebPage, @escaping () -> Bool) async -> Bool = { editor, page, authorized in
            await editor.save(on: page, authorized: authorized)
        }
        var makeEdit: @MainActor () -> ForumInlineEdit = { ForumInlineEdit() }
        var uploadImage: @MainActor (URL, String) async throws -> URL = { url, key in
            try Task.checkCancellation()
            let read = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let picture = try NodeImageUpload.Picture.file(url)
                try Task.checkCancellation()
                return picture
            }
            let picture = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            try Task.checkCancellation()
            return try await NodeImageUpload.upload(picture, key: key)
        }
        var uploadClipboardImage: @MainActor (NodeImageUpload.Picture, String) async throws -> URL = { picture, key in
            try await NodeImageUpload.upload(picture, key: key)
        }
    }
    private let requests: Requests

    struct KeyStore {
        var configured: @MainActor () async throws -> Bool = { try await NodeImageKey.configured() }
        var read: @MainActor () async throws -> String? = { try await NodeImageKey.readAsync() }
        var save: @MainActor (String) async throws -> Void = { try await NodeImageKey.saveAsync($0) }
        var remove: @MainActor () async throws -> Void = { try await NodeImageKey.removeAsync() }
    }
    private let keyStore: KeyStore
    // Resolving the production singleton is deliberately lazy. Official
    // metadata and unrelated bridge fixtures must not read the user's library.
    private let customStickerLibrary: @MainActor () -> StickerLibrary

    init(context: SeekDeskBridgeContext, requests: Requests = Requests(), keyStore: KeyStore = KeyStore(),
         clipboard: NativeComposerClipboard.Dependencies = .init(),
         imageCodec: NativeImageEncoder.Codec = .init(),
         customStickerLibrary: @escaping @MainActor () -> StickerLibrary = { StickerLibrary.shared }) {
        self.context = context
        self.requests = requests
        inboxPreview = NativeInboxPreview(session: context.session, fetch: requests.inboxPreview)
        self.keyStore = keyStore
        self.customStickerLibrary = customStickerLibrary
        composerClipboard = NativeComposerClipboard(dependencies: clipboard)
        imageEncoder = NativeImageEncoder(codec: imageCodec)
        offsetStore = NativeReaderOffsetStore(defaults: context.defaults)
        observedUnread = context.session.unread
        context.session.$unread.sink { [weak self] counts in
            self?.observeUnread(counts)
        }.store(in: &subscriptions)
        composerClipboard.onInvalidation = { [weak self] token, identity in
            self?.cancelClipboardUpload(token: token, identity: identity)
        }
    }

    func invalidate() {
        inboxPreview.invalidate()
        invalidateEditorOperations()
        closeAllReaders(preservingLoads: true)
        retireInlineEdits()
        accounts.removeAll()
        accountObservers.removeAll()
        accountOrder.removeAll()
        profileAccount = ForumAccountReader()
        publisher = DiscussionPublisher()
        lastSubmissionMessage = nil
        inboxRevisions = InboxCategoryRevisions()
        observedUnread = context.session.unread
        offsetStore.flush()
        context.emit(domain: "reader", data: ["url": "", "thread": NSNull(), "loading": false])
        context.emit(domain: "inbox", data: ["kind": inboxKind, "items": [], "loading": false])
        context.emit(domain: "discussion", data: discussionSnapshot())
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        inboxPreview.dispose()
        invalidateEditorOperations()
        subscriptions.removeAll()
        readerLoads.removeAll()
        inboxLoads.removeAll()
        accountObservers.removeAll()
        accounts.removeAll()
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()
        retireInlineEdits()
        closeAllReaders()
        offsetStore.flush()
    }

    private func retireInlineEdits() {
        for state in inlineEdits.values { state.editor.sizing.cancelPendingCredentialRead() }
        inlineEdits.removeAll()
    }

    /// The native quit boundary owns both checks: Flutter can finish flushing
    /// after a credential mutation starts, or after its caller is invalidated.
    func flushDrafts(using requestFlush: (@escaping (Bool) -> Void) -> Void,
                     completion: @escaping (Bool) -> Void) {
        guard !hasPendingImageKeyMutation else { completion(false); return }
        requestFlush { [weak self] saved in
            guard let self else { completion(false); return }
            completion(saved && !self.hasPendingImageKeyMutation)
        }
    }

    func closeReader(_ id: String) {
        cancelAuthorReads(id)
        readerLoads.removeValue(forKey: id)
        readers.removeValue(forKey: id)?.cancel()
        readerOrder.removeAll { $0 == id }
    }
    func closeAllReaders(preservingLoads: Bool = false) {
        cancelAuthorReads()
        if !preservingLoads { readerLoads.removeAll() }
        for reader in readers.values { reader.cancel() }
        readers.removeAll()
        readerOrder.removeAll()
    }

    private func cancelAuthorReads(_ topicID: String? = nil) {
        let ids = authorReads.compactMap { key, value in topicID == nil || value.topicID == topicID ? key : nil }
        for id in ids { authorReads.removeValue(forKey: id)?.task.cancel() }
    }

    private func topic(_ args: [String: Any]) throws -> Topic {
        if let raw = args["url"] as? String {
            let url = try NativeDTO.url(["url": raw], forumOnly: true)
            guard let id = Forum.topicID(url) else { throw NativeBridgeError(code: "invalid_topic", message: "帖子链接无效。") }
            return Topic(id: id, url: url, title: context.session.titles[id] ?? "")
        }
        let id = try NativeDTO.string(args, "topicID")
        guard let topic = context.workspace.session.topics.first(where: { $0.id == id }) else {
            throw NativeBridgeError(code: "closed_topic", message: "帖子已关闭，请重新打开。")
        }
        return topic
    }

    private func reader(_ topic: Topic) -> ForumReaderState {
        readerOrder.removeAll { $0 == topic.id }; readerOrder.append(topic.id)
        if let reader = readers[topic.id] { return reader }
        while readerOrder.count > 5 { closeReader(readerOrder[0]) }
        let reader = ForumReaderState(topic: topic, session: context.session)
        readers[topic.id] = reader
        return reader
    }

    private func readerSnapshot(_ topic: Topic, _ reader: ForumReaderState) -> [String: Any] {
        var result: [String: Any] = ["url": topic.url.absoluteString, "topicID": topic.id, "loading": reader.isLoading,
            "thread": NSNull(), "error": NSNull(), "errorCode": NSNull(), "refreshFailed": false,
            "authorProfilesSupported": true,
            "anchor": NativeDTO.optional(context.session.anchor(at: topic.url)),
            "scrollOffset": offsetStore.offset(at: topic.url, owner: context.session.memberID),
            "draft": context.session.drafts[topic.id, default: ""], "accessRevision": context.session.accessRevision]
        if let bodyAnchor = offsetStore.bodyAnchor(at: topic.url, owner: context.session.memberID) {
            result["bodyAnchor"] = bodyAnchor.dictionary
        }
        switch reader.phase {
        case .loading: break
        case .ready(let thread): result["thread"] = Self.normalizedThread(NativeDTO.encode(thread))
        case .failed(let error):
            result["error"] = error.localizedDescription
            result["errorCode"] = Self.readerErrorCode(error)
        }
        if let error = reader.refreshIssue {
            result["error"] = error.localizedDescription
            result["errorCode"] = Self.readerErrorCode(error)
            result["refreshFailed"] = true
        }
        return result
    }

    private static func readerErrorCode(_ error: ForumPageError) -> String {
        switch error {
        case .verification: "verification_required"
        case .signInRequired: "sign_in_required"
        case .missing: "unavailable"
        case .changed: "changed"
        case .timedOut: "timed_out"
        case .network: "network"
        }
    }

    /// A floor's author is read through its already loaded page. This path never
    /// prepares another WebKit page, fetches a readme, or uses profileLoad's
    /// single profile-screen selection. Session owns caching and concurrency.
    private func readerAuthor(_ args: [String: Any]) async throws -> [String: Any] {
        let session = context.session
        let authorization = try context.requireAuthorization(args, signedIn: false)
        let topic = try topic(args), id = try NativeDTO.integer(args, "id")
        let route = topic.url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard id > 0, route.count == 3, route[0] == "post",
              let pageNumber = Int(route[2]), pageNumber > 0 else {
            throw NativeBridgeError(code: "invalid_author", message: "作者或帖子页面无效。")
        }
        guard let reader = readers[topic.id], !reader.isLoading, reader.refreshIssue == nil,
              case .ready(let thread) = reader.phase, thread.page == pageNumber else {
            throw NativeBridgeError(code: "not_ready", message: "请等待这篇帖子的正文加载完成。")
        }
        guard thread.root?.authorID == id || thread.replies.contains(where: { $0.authorID == id }) else {
            throw NativeBridgeError(code: "invalid_author", message: "这位用户不在当前帖子的已加载楼层中。")
        }
        let page = reader.page
        func requireCurrent() throws {
            try checkActive()
            guard session.authorization == authorization else { throw staleAccess() }
            guard readers[topic.id] === reader, !reader.isLoading, reader.refreshIssue == nil,
                  reader.page === page, case .ready(let current) = reader.phase, current == thread else {
                throw CancellationError()
            }
        }
        try requireCurrent()
        if let page {
            let operation = UUID(), request = requests.readerAuthor
            let task = Task { @MainActor in
                do { try requireCurrent() } catch { return }
                await request(id, page, session)
            }
            authorReads[operation] = AuthorRead(topicID: topic.id, task: task)
            defer { authorReads[operation] = nil }
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            // A refresh may finish with the same payload; cancellation still
            // retires the previous reader request and prevents a late result.
            guard !task.isCancelled else { throw CancellationError() }
        }
        try requireCurrent()
        let authorName = thread.root?.authorID == id ? thread.root?.author : thread.replies.first { $0.authorID == id }?.author
        let profile = Self.readerAuthorProfile(session.profiles[id], authorID: id, authorName: authorName ?? "",
            ownSignature: id == session.memberID ? session.ownIntroduction?.signature : nil)
        return ["profile": NativeDTO.optional(profile), "accessRevision": authorization.revision]
    }

    static func readerAuthorProfile(_ profile: ForumUserProfile?, authorID: Int, authorName: String,
                                    ownSignature: String?) -> [String: Any]? {
        var result: [String: Any]?
        if let profile, profile.member_id == authorID {
            result = NativeDTO.encode(profile) as? [String: Any]
            // Exclude a readme cached by a separate profile-screen request.
            result?.removeValue(forKey: "readme")
        }
        if let ownSignature {
            // Presence is meaningful: an explicitly empty personal signature
            // must override a stale floor/profile signature. The floor already
            // supplies this identity even when richer metadata is unavailable.
            if result == nil { result = ["member_id": authorID, "member_name": authorName] }
            result?["ownSignature"] = ownSignature
        }
        return result
    }

    private func requirePreparedPage(_ page: ForumWebPage?, reader: ForumReaderState) throws -> ForumWebPage {
        if let page { return page }
        if reader.isLoading {
            throw NativeBridgeError(code: "not_ready", message: "帖子正在加载，请稍后重试。")
        }
        throw ForumPageError.signInRequired
    }

    /// SwiftUI parsed ANSI on presentation. Normalize at the DTO boundary so
    /// Flutter receives the same colored spans, including nested report tabs.
    static func normalizedThread(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(normalizedThread) }
        guard var map = value as? [String: Any] else { return value }
        if map["kind"] as? String == "terminal", !(map["terminal"] is [[Any]]),
           let text = map["text"] as? String {
            map["terminal"] = NativeDTO.encode(ForumTerminalANSI.lines(text))
        }
        for key in ["root", "replies", "blocks", "tabs", "items"] {
            if let child = map[key] { map[key] = normalizedThread(child) }
        }
        return map
    }

    /// Discovering a cookie's identity legitimately changes accessRevision. The
    /// production reader cancels its old context, so repeat this read using the
    /// new partition. Never attach an old payload to the new revision.
    private func loadReader(_ topic: Topic, force: Bool) async throws -> [String: Any] {
        cancelAuthorReads(topic.id)
        let operation = UUID()
        readerLoads[topic.id] = operation
        defer { if readerLoads[topic.id] == operation { readerLoads[topic.id] = nil } }
        for attempt in 0..<3 {
            try checkActive()
            let access = context.session.accessRevision
            let state = reader(topic)
            _ = await requests.reader(topic, state, context.session, force || attempt > 0)
            try checkActive()
            guard readerLoads[topic.id] == operation else { throw CancellationError() }
            if access != context.session.accessRevision { continue }
            guard readers[topic.id] === state else { throw CancellationError() }
            let snapshot = readerSnapshot(topic, state)
            context.emit(domain: "workspace", data: context.workspaceSnapshot())
            return snapshot
        }
        throw staleAccess()
    }

    private func accountReader(_ key: InboxKey) -> ForumAccountReader {
        accountOrder.removeAll { $0 == key }
        accountOrder.append(key)
        if let existing = accounts[key] { return existing }
        while accountOrder.count > 8 {
            let oldest = accountOrder.removeFirst()
            accounts[oldest] = nil
            accountObservers[oldest] = nil
            inboxLoads[oldest] = nil
        }
        let state = ForumAccountReader()
        accounts[key] = state
        accountObservers[key] = state.objectWillChange.sink { [weak self, weak state] in
            Task { @MainActor [weak self, weak state] in
                guard let self, let state, self.accounts[key] === state,
                      key == self.selectedInboxKey, !self.disposed else { return }
                self.emitInbox()
            }
        }
        return state
    }

    private var selectedInboxKey: InboxKey { InboxKey(kind: inboxKind, peer: inboxPeer) }

    private func loadInbox(_ key: InboxKey, force: Bool) async throws -> [String: Any] {
        let selection = UUID(), operation = UUID()
        inboxSelection = selection
        inboxKind = key.kind
        inboxPeer = key.peer
        inboxLoads[key] = operation
        defer { if inboxLoads[key] == operation { inboxLoads[key] = nil } }
        if force { inboxRefresh += 1 }
        for _ in 0..<3 {
            try checkActive()
            let access = context.session.accessRevision
            let state = accountReader(key)
            let revision = inboxRevision(for: key.kind)
            await requests.inbox(state, key.kind, key.peer, inboxRefresh, revision, context.session)
            try checkActive()
            guard inboxLoads[key] == operation, inboxSelection == selection else { throw CancellationError() }
            if access != context.session.accessRevision { continue }
            guard accounts[key] === state else { throw CancellationError() }
            let snapshot = inboxSnapshot(key: key, state: state)
            context.emit(domain: "inbox", data: snapshot)
            return snapshot
        }
        throw staleAccess()
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if disposed { throw CancellationError() }
    }

    private func loadProfile(_ args: [String: Any]) async throws -> [String: Any] {
        let request = UUID()
        profileLoad = request
        defer { if profileLoad == request { profileLoad = nil } }
        for _ in 0..<3 {
            try checkActive()
            let session = context.session, access = session.accessRevision
            if args["id"] != nil {
                let id = try NativeDTO.integer(args, "id")
                guard id > 0 else { throw ForumPageError.changed }
                await requests.profile(id, session, args["force"] as? Bool ?? false)
                try checkActive()
                guard profileLoad == request else { throw CancellationError() }
                if access != session.accessRevision { continue }
                var value = session.profiles[id].map { NativeDTO.encode($0) as? [String: Any] ?? [:] } ?? [:]
                value["accessRevision"] = session.accessRevision
                value["owner"] = NativeDTO.optional(session.memberID)
                return value
            }
            let state = profileAccount
            await requests.inbox(state, "profile", nil,
                args["force"] as? Bool == true ? Int(Date().timeIntervalSince1970) : 0, 0, session)
            try checkActive()
            guard profileLoad == request else { throw CancellationError() }
            if access != session.accessRevision { continue }
            guard profileAccount === state else { throw CancellationError() }
            return context.sessionSnapshot()
        }
        throw staleAccess()
    }

    private func staleAccess() -> NativeBridgeError {
        .init(code: "stale_authorization", message: "账号状态已变化，请重新加载。草稿已保留。")
    }

    func inboxRevision(for kind: String) -> Int {
        InboxCategory(rawValue: kind == "conversation" ? "messages" : kind)
            .map { inboxRevisions.value(for: $0) } ?? 0
    }

    func observeUnread(_ counts: ForumUnreadCounts) {
        inboxRevisions.incoming(from: observedUnread, to: counts)
        observedUnread = counts
    }

    func handle(_ method: String, _ args: [String: Any]) async throws -> Any? {
        let session = context.session
        try checkActive()
        switch method {
        case "reader.load":
            return try await loadReader(try topic(args), force: args["force"] as? Bool ?? false)
        case "reader.authorPage":
            // Scan a separate page without replacing the open reader or its
            // interaction context. Use the same authenticated forum loader.
            let authorization = try context.requireAuthorization(args, signedIn: false)
            let topic = try topic(args)
            let number = try NativeDTO.integer(args, "page")
            guard (1...10_000).contains(number) else {
                throw NativeBridgeError(code: "invalid_page", message: "帖子页码无效。")
            }
            let url = Forum.home.appendingPathComponent("post-\(topic.id)-\(number)")
            let thread: ForumThread
            if session.threadIsFresh(at: url), let cached = session.cachedThread(at: url) {
                thread = cached
            } else {
                (thread, _) = try await ForumReaderState.fetch(url, session: session)
            }
            try checkActive()
            guard session.authorization == authorization else { throw staleAccess() }
            guard thread.page == number else { throw ForumPageError.changed }
            return ["thread": Self.normalizedThread(NativeDTO.encode(thread)),
                    "accessRevision": authorization.revision]
        case "reader.author":
            return try await readerAuthor(args)
        case "reader.rememberPosition":
            let token = try context.requireAuthorization(args, signedIn: false)
            let topic = try topic(args)
            var validAnchor: String?
            if let raw = args["anchor"], !(raw is NSNull) {
                guard let anchor = raw as? String, ReadingProgress.valid(anchor) else {
                    throw NativeBridgeError(code: "invalid_anchor", message: "阅读位置标记无效。")
                }
                validAnchor = anchor
            }
            let validOffset = try args["offset"].flatMap { $0 is NSNull ? nil : try NativeReaderOffsetStore.validOffset($0) }
            let validBodyAnchor = try args["bodyAnchor"].flatMap { $0 is NSNull ? nil : try NativeReaderOffsetStore.validBodyAnchor($0) }
            guard validBodyAnchor == nil || validOffset != nil else {
                throw NativeBridgeError(code: "invalid_position", message: "正文阅读锚点必须同时提供滚动位置。")
            }
            if let offset = validOffset {
                try offsetStore.remember(offset, bodyAnchor: validBodyAnchor, at: topic.url, owner: token.owner)
            } else if args["anchor"] == nil || args["anchor"] is NSNull {
                throw NativeBridgeError(code: "invalid_position", message: "请提供阅读位置。")
            }
            if let anchor = validAnchor { session.rememberAnchor(anchor, at: topic.url, authorization: token) }
            return ["saved": true, "scrollOffset": offsetStore.offset(at: topic.url, owner: token.owner)]
        case "reader.replyDraft":
            _ = try context.requireAuthorization(args)
            return replyDraftSnapshot(try NativeDTO.string(args, "topicID"))
        case "reader.updateReplyDraft":
            _ = try context.requireAuthorization(args)
            let id = try NativeDTO.string(args, "topicID"), content = try NativeDTO.string(args, "content")
            session.edit(content, for: id)
            return replyDraftSnapshot(id)
        case "reader.setReplyImageSize":
            _ = try context.requireAuthorization(args)
            try requireEditorIdle()
            let id = try imageDraftTopicID(args)
            guard !session.sending.contains(id) else {
                throw NativeBridgeError(code: "writing", message: "回复正在提交，请完成后再调整图片大小。")
            }
            let change = try imageSizeChange(args, content: session.drafts[id, default: ""])
            session.imageSizing(for: .reply(id)).set(change.ratio, previewWidth: change.width, for: change.url)
            return replyDraftSnapshot(id)
        case "reader.discardReplyDraft":
            _ = try context.requireAuthorization(args)
            try requireEditorIdle()
            let id = try imageDraftTopicID(args)
            guard !session.sending.contains(id) else {
                throw NativeBridgeError(code: "writing", message: "回复正在提交，请等待发送结果后再放弃草稿。")
            }
            guard args["confirmed"] as? Bool == true else {
                throw NativeBridgeError(code: "confirmation_required", message: "请先确认放弃回复草稿。")
            }
            session.edit("", for: id)
            session.imageSizing(for: .reply(id)).reset()
            return replyDraftSnapshot(id)
        case "reader.sendReply":
            let token = try context.requireAuthorization(args)
            try requireEditorIdle()
            let topic = try topic(args)
            let reader = reader(topic)
            let preparedPage = await requests.preparePage(topic, reader, session)
            try checkActive()
            guard session.authorizes(token) else { throw staleAccess() }
            try requireEditorIdle()
            guard readers[topic.id] === reader else { throw CancellationError() }
            let page = try requirePreparedPage(preparedPage, reader: reader)
            let operation = try beginEditorWrite()
            defer { finishEditorWrite(operation) }
            guard let task = requests.sendReply(topic, page, session) else { throw NativeBridgeError(code: "not_ready", message: "请填写回复正文并等待上一条回复完成。") }
            await awaitWrite(task)
            try checkActive()
            guard session.authorizes(token) else { throw staleAccess() }
            let receipt = session.receipts[topic.id]
            var result = replyDraftSnapshot(topic.id)
            result["accepted"] = receipt?.accepted ?? false
            result["message"] = receipt?.message ?? "未收到发送结果。请刷新确认后再决定是否重发。"
            result["destination"] = NativeDTO.optional(receipt?.destination?.absoluteString)
            result["verify"] = receipt?.verify ?? false
            return result
        case "reader.react":
            let token = try context.requireAuthorization(args), topic = try topic(args)
            let rawKind = try NativeDTO.string(args, "kind")
            let normalizedKind = rawKind == "chicken" ? "like" : rawKind == "downvote" ? "dislike" : rawKind
            guard let post = Int(topic.id), let owner = token.owner,
                  let kind = ForumReactionKind(rawValue: normalizedKind) else { throw ForumPageError.changed }
            let approval = ForumReactionApproval(rawValue: args["approval"] as? String ?? (kind == .upvote ? "direct" : "quote")) ?? .quote
            let target = ForumReactionTarget(postID: post, floor: try NativeDTO.integer(args, "floor"), kind: kind)
            guard let page = await reader(topic).preparePage(topic, session: session), session.authorizes(token) else { throw ForumPageError.signInRequired }
            guard let result = await session.react(target, approval: approval, owner: owner, on: page) else { throw ForumPageError.network }
            guard session.authorizes(token) else { throw staleAccess() }
            return ["kind": result.kind.rawValue, "count": NativeDTO.optional(result.count), "coin": NativeDTO.optional(result.coin), "message": NativeDTO.optional(result.message)]
        case "reader.edit.begin", "reader.edit.update", "reader.edit.save", "reader.edit.cancel", "reader.edit.continueVerification", "reader.edit.setImageSize":
            return try await edit(method, args)
        case "inbox.load":
            let kind = try NativeDTO.string(args, "kind")
            guard ["mentions", "replies", "messages", "conversation"].contains(kind) else { throw ForumPageError.changed }
            let peer = kind == "conversation" ? try NativeDTO.integer(args, "peer") : nil
            if let peer, peer <= 0 { throw ForumPageError.changed }
            return try await loadInbox(InboxKey(kind: kind, peer: peer), force: args["force"] as? Bool == true)
        case "inbox.preview":
            return try await inboxPreview.load(args)
        case "inbox.cancelPreview":
            return try inboxPreview.cancel(args)
        case "inbox.markRead":
            let token = try context.requireAuthorization(args)
            guard let kind = InboxCategory(rawValue: try NativeDTO.string(args, "kind")) else { throw ForumPageError.changed }
            let key = InboxKey(kind: kind.rawValue, peer: nil)
            guard let state = accounts[key] else { throw NativeBridgeError(code: "not_ready", message: "请先加载这类通知。") }
            await requests.markRead(state, InboxReadTarget(category: kind, id: try NativeDTO.integer(args, "id"), stamp: args["stamp"] as? String ?? ""), session)
            guard session.authorizes(token) else { throw staleAccess() }
            guard accounts[key] === state else { throw CancellationError() }
            return inboxSnapshot(key: key, state: state)
        case "inbox.getDraft":
            _ = try context.requireAuthorization(args)
            return messageDraftSnapshot(try messagePeer(args))
        case "inbox.updateDraft":
            _ = try context.requireAuthorization(args)
            let peer = try messagePeer(args), content = try NativeDTO.string(args, "content")
            let markdown = try messageBoolean(args, "markdown")
            session.messageDrafts[peer] = content
            if let markdown { session.messageMarkdown[peer] = markdown }
            return messageDraftSnapshot(peer)
        case "inbox.setImageSize":
            _ = try context.requireAuthorization(args)
            let peer = try messagePeer(args)
            try requireEditorIdle()
            guard !session.sendingMessages.contains(peer) else {
                throw NativeBridgeError(code: "writing", message: "私信正在提交，请完成后再调整图片大小。")
            }
            let change = try imageSizeChange(args, content: session.messageDrafts[peer, default: ""])
            session.imageSizing(for: .message(peer)).set(change.ratio, previewWidth: change.width, for: change.url)
            return messageDraftSnapshot(peer)
        case "inbox.send":
            let token = try context.requireAuthorization(args), peer = try messagePeer(args)
            if args["expectedContent"] != nil {
                let expected = try NativeDTO.string(args, "expectedContent")
                guard session.messageDrafts[peer] == expected else {
                    throw staleMessageDraft()
                }
            }
            let storedMarkdown = session.messageMarkdown[peer, default: true]
            let markdown = try messageBoolean(args, "markdown") ?? storedMarkdown
            if let expected = try messageBoolean(args, "expectedMarkdown") {
                guard expected == storedMarkdown, markdown == expected else { throw staleMessageDraft() }
            }
            let key = InboxKey(kind: "conversation", peer: peer)
            guard let state = accounts[key], case .messages(let readyPeer, _) = requests.inboxState(state), readyPeer == peer else {
                throw NativeBridgeError(code: "not_ready", message: "请先加载当前私信对话。")
            }
            guard let original = session.messageDrafts[peer], !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !session.sendingMessages.contains(peer) else { throw NativeBridgeError(code: "empty_message", message: "请先填写私信。") }
            let draftRevision = session.messageDraftRevision(for: peer)
            let sizing = session.imageSizing(for: .message(peer))
            let imageSizes = sizing.sizes
            session.sendingMessages.insert(peer)
            defer { if token == session.authorization { session.sendingMessages.remove(peer) } }
            let isCurrent: DraftImageSizing.Authorization = { [self] in
                guard !disposed, session.authorizes(token), accounts[key] === state,
                      session.sendingMessages.contains(peer), session.ownsImageSizing(sizing, for: .message(peer)),
                      case .messages(let currentPeer, _) = requests.inboxState(state), currentPeer == peer else { return false }
                return true
            }
            let draftUnchanged: DraftImageSizing.Authorization = {
                session.messageDraftRevision(for: peer) == draftRevision &&
                session.messageDrafts[peer] == original &&
                session.messageMarkdown[peer, default: true] == storedMarkdown && sizing.sizes == imageSizes
            }
            let content: String
            do {
                content = markdown ? try await requests.prepareMessage(sizing, original, { isCurrent() && draftUnchanged() }) : original
            } catch {
                if isCurrent(), !draftUnchanged() { throw staleMessageDraft() }
                throw error
            }
            guard isCurrent() else { throw staleAccess() }
            guard draftUnchanged() else { throw staleMessageDraft() }
            try checkActive()
            let response = await requests.sendMessage(state, peer, content, markdown)
            guard session.authorizes(token) else { throw staleAccess() }
            if response.kind == "sent" {
                if session.ownsImageSizing(sizing, for: .message(peer)), draftUnchanged() {
                    session.messageDrafts[peer] = nil; sizing.reset()
                }
                inboxRevisions.invalidate(.messages)
                await requests.refreshMessageUnread(session)
                guard session.authorizes(token) else { throw staleAccess() }
            } else if response.kind == "signedOut" { session.observeAccount(false) }
            return NativeDTO.encode(response)
        case "profile.load":
            return try await loadProfile(args)
        case "profile.introduction":
            let token = try context.requireAuthorization(args)
            guard let owner = token.owner else { throw ForumPageError.signInRequired }
            let result = await session.introduction(for: owner)
            guard session.authorizes(token) else { throw staleAccess() }
            return NativeDTO.encode(result)
        case "profile.saveIntroduction":
            let token = try context.requireAuthorization(args)
            guard let owner = token.owner, let current = session.ownIntroduction,
                  let originalMap = args["original"] as? [String: Any], let draftMap = args["draft"] as? [String: Any] else { throw ForumPageError.changed }
            let original = ForumIntroduction(bio: current.bio, signature: originalMap["signature"] as? String ?? "", readme: originalMap["readme"] as? String ?? "")
            let draft = ForumIntroduction(bio: current.bio, signature: draftMap["signature"] as? String ?? "", readme: draftMap["readme"] as? String ?? "")
            let result = await session.introduction(for: owner, draft: draft, original: original)
            guard session.authorizes(token) else { throw staleAccess() }
            return NativeDTO.encode(result)
        case "discussion.getDraft":
            _ = try context.requireAuthorization(args)
            return discussionSnapshot()
        case "discussion.updateDraft":
            _ = try context.requireAuthorization(args)
            // Saving a newer edit during a pending publish is safe: the native
            // publisher only clears a draft that still equals its submitted copy.
            if let rank = args["rank"], !((rank as? Int).map { (0...30).contains($0) || $0 == 255 } ?? false) {
                throw NativeBridgeError(code: "invalid_rank", message: "阅读权限无效。")
            }
            for key in ["title", "content", "category"] {
                if let value = args[key], !(value is String) {
                    throw NativeBridgeError(code: "invalid_arguments", message: "草稿字段格式无效：\(key)")
                }
            }
            let draft = session.newDiscussion
            if let value = args["title"] as? String { draft.title = value }
            if let value = args["content"] as? String { draft.content = value }
            if let value = args["category"] as? String { draft.category = value }
            if let value = args["rank"] as? Int { draft.rank = value }
            return discussionSnapshot()
        case "discussion.setImageSize":
            _ = try context.requireAuthorization(args)
            try requireEditorIdle()
            guard !publisher.sending else {
                throw NativeBridgeError(code: "publishing", message: "帖子正在发布，请完成后再调整图片大小。")
            }
            let draft = session.newDiscussion
            let change = try imageSizeChange(args, content: draft.content)
            draft.imageSizing.set(change.ratio, previewWidth: change.width, for: change.url)
            return discussionSnapshot()
        case "discussion.loadOptions":
            // The caller must belong to the current revision, but discovering
            // the cookie's owner may legitimately change it during this read.
            _ = try context.requireAuthorization(args, signedIn: false)
            try requireEditorIdle()
            guard !publisher.sending else {
                throw NativeBridgeError(code: "publishing", message: "帖子正在发布，请等待发布结果后再刷新发帖权限。")
            }
            let request = UUID()
            optionsLoad = request
            defer { if optionsLoad == request { optionsLoad = nil } }
            for _ in 0..<3 {
                try checkActive()
                let access = session.accessRevision
                let current = publisher
                let draft = session.newDiscussion
                current.phase = .loading
                await requests.options(current, session, draft)
                try checkActive()
                guard optionsLoad == request else { throw CancellationError() }
                if access != session.accessRevision { continue }
                guard current === publisher, draft === session.newDiscussion else { throw CancellationError() }
                return discussionSnapshot()
            }
            throw staleAccess()
        case "discussion.discard":
            _ = try context.requireAuthorization(args, signedIn: false)
            try requireNoUpload()
            guard !publisher.sending else { throw NativeBridgeError(code: "publishing", message: "帖子正在发布，请等待发布结果后再放弃编辑。") }
            try requireEditorIdle()
            guard args["confirmed"] as? Bool == true else {
                throw NativeBridgeError(code: "confirmation_required", message: "请先确认放弃编辑。")
            }
            _ = DiscussionAbandonment.discard(session.newDiscussion, publishing: false, uploading: false)
            publisher.message = nil
            lastSubmissionMessage = nil
            return discussionSnapshot()
        case "discussion.publish":
            let token = try context.requireAuthorization(args)
            try requireNoUpload()
            guard !publisher.sending else { throw NativeBridgeError(code: "publishing", message: "帖子正在发布，请等待当前发布结果。") }
            try requireEditorIdle()
            guard session.newDiscussion.category != "inside" || args["feeAccepted"] as? Bool == true else {
                throw NativeBridgeError(code: "confirmation_required", message: "发内版需要确认消耗 5 鸡腿。")
            }
            let operation = try beginEditorWrite()
            defer { finishEditorWrite(operation) }
            var acceptedURL: URL?, accepted = false
            let current = publisher
            guard let task = requests.publish(current, session.newDiscussion, session, { url in accepted = true; acceptedURL = url }) else {
                throw NativeBridgeError(code: "not_ready", message: "请检查标题、正文、版块及发布权限。")
            }
            await awaitWrite(task)
            try checkActive()
            guard session.authorizes(token) else { throw staleAccess() }
            guard current === publisher else { throw CancellationError() }
            // Permission reloads clear publisher.message. Retain a submission
            // warning separately so an unknown result cannot look safe to retry.
            lastSubmissionMessage = accepted ? nil : current.message
            var result = discussionSnapshot()
            result["accepted"] = accepted; result["url"] = NativeDTO.optional(acceptedURL?.absoluteString)
            return result
        case "images.draftReferences":
            _ = try context.requireAuthorization(args, signedIn: false)
            let content = try NativeDTO.string(args, "content")
            return ["content": content, "imageURLs": MarkdownPreviewDocument.imageURLs(content).map(\.absoluteString),
                    "accessRevision": session.accessRevision]
        case "system.captureComposerPaste":
            let authorization = try context.requireAuthorization(args, signedIn: false)
            let identity = try NativeComposerClipboard.Identity(args, authorization: authorization)
            // Capture reserves only a snapshot, never the upload/key-store lock.
            // An already-running upload must not be superseded by another paste.
            try requireNoUpload()
            let result = try await composerClipboard.capture(identity) { [weak self] in
                guard let self else { return false }
                return !self.disposed && self.context.session.authorization == authorization
            }
            try checkActive()
            guard context.session.authorization == authorization else { throw staleAccess() }
            return result
        case "images.uploadClipboardSnapshot":
            return try await uploadClipboardSnapshot(args)
        case "system.captureComposerDrop":
            let authorization = try context.requireAuthorization(args, signedIn: false)
            let identity = try NativeComposerClipboard.Identity(args, authorization: authorization)
            try requireNoUpload()
            guard let token = args["dropToken"] as? String, UUID(uuidString: token) != nil else {
                throw NativeComposerDropStore.expired()
            }
            let file = try composerDrop.consume(token, identity: identity)
            let result = try await composerClipboard.captureFile(identity, file: file) { [weak self] in
                guard let self else { return false }
                return !self.disposed && self.context.session.authorization == authorization
            }
            try checkActive()
            guard context.session.authorization == authorization else { throw staleAccess() }
            return result
        case "system.releaseComposerDrop":
            guard let token = args["dropToken"] as? String, UUID(uuidString: token) != nil else {
                return ["released": false]
            }
            return ["released": composerDrop.release(token)]
        case "images.releaseClipboardSnapshot":
            let authorization = try context.requireAuthorization(args, signedIn: false)
            let identity = try NativeComposerClipboard.Identity(args, authorization: authorization)
            return ["released": composerClipboard.release(identity, token: try clipboardToken(args))]
        case "images.load":
            let authorization = session.authorization
            let url = try NativeDTO.url(args)
            let kind: ForumImageRequest.Kind = args["kind"] as? String == "avatar" ? .avatar : args["kind"] as? String == "original" ? .original : .post
            let bitmap = try await requests.image(url, kind)
            try checkActive()
            guard authorization == session.authorization else { throw staleAccess() }
            let image = bitmap.image
            let data: Data
            if let animation = bitmap.animation {
                data = animation.bytes
            } else {
                data = try await imageEncoder.encode(image, kind: kind, owner: authorization.owner, revision: authorization.revision)
            }
            try checkActive()
            guard authorization == session.authorization else { throw staleAccess() }
            let original = ForumImageRequest.originalSize(url)
            return ["bytes": FlutterStandardTypedData(bytes: data), "mime": bitmap.animation?.mime ?? "image/png", "width": image.width, "height": image.height,
                    "originalWidth": NativeDTO.optional(original.map { Double($0.width) }),
                    "originalHeight": NativeDTO.optional(original.map { Double($0.height) })]
        case "images.release": ForumImageRequest.releaseOriginal(try NativeDTO.url(args)); return ["released": true]
        case "images.keyStatus":
            return try await imageKeyStatus(args)
        case "images.setKey", "images.removeKey":
            return try await imageKeyOperation(method, args)
        case "stickers.list": return ["packs": ForumStickers.officialPacks.map { pack in
            ["id": pack.id, "title": pack.title, "items": pack.items.map { ["id": $0.id, "label": $0.label, "url": $0.url.absoluteString, "insertion": $0.insertion ?? ""] }] as [String: Any]
        }]
        case "stickers.custom.list", "stickers.custom.create", "stickers.custom.remove", "stickers.custom.thumbnail":
            return try await customStickerOperation(method, args)
        case "stickers.custom.upload":
            return try await uploadCustomSticker(args)
        case "rankings.load":
            guard let period = RankingPeriod(rawValue: args["period"] as? String ?? "hot") else { throw ForumPageError.changed }
            await ranking.refresh(period, ifDue: args["force"] as? Bool != true)
            return NativeDTO.rankingSnapshot(period: period, snapshot: ranking.snapshots[period], failed: ranking.failed.contains(period))
        case "rulings.load":
            let records = try await RulingClient.shared.lookup(try NativeDTO.string(args, "name"))
            return ["records": records.map { ["id": $0.id, "reason": $0.reason ?? "", "actions": $0.beijingActions ?? "", "kind": $0.kind.rawValue, "points": $0.points ?? 0, "url": NativeDTO.optional($0.postURL?.absoluteString)] }]
        case "attendance.perform":
            let token = try context.requireAuthorization(args)
            guard let owner = token.owner, let mode = ForumAttendanceMode(rawValue: args["mode"] as? String ?? "fixed") else { throw ForumPageError.changed }
            let result = await session.attend(member: owner, mode: mode, authorized: { session.authorizes(token) })
            guard session.authorizes(token) else { throw staleAccess() }
            return result.map(NativeDTO.encode) ?? NSNull()
        case "value.currencies":
            return ["items": (ValueCurrency.common + ValueCurrency.other).map { ["code": $0, "title": ValueCurrency.title($0)] }]
        case "value.rate":
            let base = try NativeDTO.string(args, "base"), quote = try NativeDTO.string(args, "quote")
            guard ValueCurrency.supported.contains(base), ValueCurrency.supported.contains(quote) else {
                throw NativeBridgeError(code: "invalid_currency", message: "币种无效。")
            }
            if base == quote { return ["rate": "1", "base": base, "quote": quote, "source": "同币种", "asOf": Date().timeIntervalSince1970 * 1000] }
            guard let value = await ValueExchangeRates.shared.latest(.init(base: base, quote: quote), force: args["force"] as? Bool == true) else {
                throw NativeBridgeError(code: "rate_unavailable", message: "暂时无法取得汇率，可以手动填写参考汇率。")
            }
            return try NativeValueRateWire.response(value, pair: .init(base: base, quote: quote))
        case "value.hint":
            guard let hint = RenewalTitleHint.extract(try NativeDTO.string(args, "title")) else { return ["available": false] }
            return ["available": true, "amount": hint.amount, "base": hint.currency, "cycle": hint.cycle.rawValue]
        case "value.calculate":
            // Milliseconds use a bounded civil-date range (0001-01-01 through
            // 9999-12-31). Reject Boolean NSNumber values before coercing them.
            func date(_ key: String, fallback: Date? = nil) throws -> Date {
                guard let raw = args[key] else {
                    if let fallback { return fallback }
                    throw NativeBridgeError(code: "invalid_value", message: "缺少日期：\(key)")
                }
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      (-62_135_596_800_000.0..<253_402_300_800_000.0).contains(number.doubleValue) else {
                    throw NativeBridgeError(code: "invalid_value", message: "日期无效，请使用公元 1 至 9999 年内的日期。")
                }
                return Date(timeIntervalSince1970: number.doubleValue / 1000)
            }
            func currency(_ key: String) throws -> String? {
                guard let raw = args[key] else { return nil }
                guard let code = raw as? String, ValueCurrency.supported.contains(code) else {
                    throw NativeBridgeError(code: "invalid_currency", message: "币种无效：\(key)")
                }
                return code
            }
            func number(_ raw: Any?, code: String, message: String) throws -> Decimal {
                guard let text = raw as? String, !text.isEmpty, text.count <= 32,
                      let value = ValueNumber.wire(text), !value.isNaN, value >= 0 else {
                    throw NativeBridgeError(code: code, message: message)
                }
                return value
            }
            let amount = try number(args["amount"], code: "invalid_value", message: "续费金额无效。")
            guard let cycle = RenewalCycle(rawValue: try NativeDTO.integer(args, "cycle")) else {
                throw NativeBridgeError(code: "invalid_value", message: "续费周期无效。")
            }
            let asOf = try date("asOf", fallback: Date()), expires = try date("expires")
            let base = try currency("base"), quote = try currency("quote")
            var rate: Decimal?, asking: Decimal?
            if let raw = args["rate"] {
                guard let parsed = NativeValueRateWire.parse(raw), quote != nil else {
                    throw NativeBridgeError(code: "invalid_rate", message: "请填写有效的正数汇率和折算币种。")
                }
                rate = parsed
            }
            if let raw = args["asking"], (raw as? String) != "" {
                asking = try number(raw, code: "invalid_value", message: "挂价无效。")
            }
            guard let estimate = RemainingValueEstimate.calculate(amount: amount, cycle: cycle, asOf: asOf, expires: expires),
                  !estimate.amount.isNaN else {
                throw NativeBridgeError(code: "invalid_value", message: "日期跨度或金额超出计算范围。")
            }
            var result: [String: Any] = ["days": estimate.days, "fullCycles": estimate.fullCycles,
                "partialDays": estimate.partialDays, "partialCycleDays": estimate.partialCycleDays,
                "amount": NSDecimalNumber(decimal: estimate.amount).stringValue,
                "asOf": asOf.timeIntervalSince1970 * 1000, "expires": expires.timeIntervalSince1970 * 1000]
            if let base {
                result["base"] = base
                result["originalFormatted"] = ValueCurrency.money(estimate.amount, base)
            }
            if let quote { result["quote"] = quote }
            if let rate, let quote {
                let converted = estimate.amount * rate
                guard !converted.isNaN else { throw NativeBridgeError(code: "invalid_value", message: "金额超出计算范围。") }
                let rounded = ValueCurrency.rounded(converted, quote)
                result["converted"] = NSDecimalNumber(decimal: rounded).stringValue
                result["formatted"] = ValueCurrency.money(converted, quote)
                if let asking {
                    // Match RemainingValueView: compare the displayed prices,
                    // not hidden fractions that can incorrectly report 低于 0.00.
                    let delta = ValueCurrency.rounded(asking, quote) - rounded
                    let difference: Decimal = delta == 0 ? 0 : delta
                    result["difference"] = NSDecimalNumber(decimal: difference).stringValue
                    result["differenceLabel"] = difference > 0 ? "高于剩余价值" : difference < 0 ? "低于剩余价值" : "与剩余价值一致"
                    result["differenceAmount"] = ValueCurrency.money(difference < 0 ? -difference : difference, quote)
                }
            }
            return result
        default: throw NativeBridgeError(code: "not_implemented", message: "此操作尚未接入：\(method)")
        }
    }

    private func stickerGroupID(_ args: [String: Any]) throws -> UUID {
        guard let raw = args["groupID"] as? String, let id = UUID(uuidString: raw) else {
            throw NativeBridgeError(code: "sticker_missing", message: "表情分组不存在，请重新选择。")
        }
        return id
    }

    private func stickerItemID(_ args: [String: Any]) throws -> String {
        guard let id = args["itemID"] as? String, Self.safeStickerID(id) else {
            throw NativeBridgeError(code: "sticker_invalid", message: "表情引用无效，请重新选择。")
        }
        return id
    }

    nonisolated private static func safeStickerID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 255 && id != "." && id != ".." &&
            !id.contains("/") && !id.contains("\\") &&
            id.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func stickerGroups(_ library: StickerLibrary) throws -> [[String: Any]] {
        try library.checkedGroups().map { group in
            ["id": group.id.uuidString, "name": group.name,
             "items": group.images.enumerated().compactMap { position, id -> [String: Any]? in
                 guard Self.safeStickerID(id) else { return nil }
                 return ["id": id, "label": "\(group.name) \(position + 1)"]
             }] as [String: Any]
        }
    }

    private func stickerLibraryError(_ error: Error) -> NativeBridgeError {
        guard let issue = error as? StickerLibrary.LibraryError else {
            return .init(code: "sticker_library", message: "暂时无法访问本地表情库，请稍后重试。")
        }
        switch issue {
        case .name: return .init(code: "sticker_name", message: "分组名需要 1 到 40 个字符。")
        case .duplicate: return .init(code: "sticker_duplicate", message: "已经有同名表情分组。")
        case .missingGroup, .missingItem, .missingFile:
            return .init(code: "sticker_missing", message: "表情已移除或无法找到，请重新选择。")
        case .unsafePath, .invalidImage:
            return .init(code: "sticker_invalid", message: "无法读取这张表情，请重新导入图片。")
        default: return .init(code: "sticker_library", message: "暂时无法访问本地表情库，请稍后重试。")
        }
    }

    private func checkStickerAccess(_ authorization: ForumSession.Authorization) throws {
        try checkActive()
        guard context.session.authorization == authorization else { throw staleAccess() }
    }

    private func customStickerOperation(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        let authorization = try context.requireAuthorization(args, signedIn: false)
        let group: UUID?
        if method == "stickers.custom.list" || method == "stickers.custom.create" { group = nil }
        else { group = try stickerGroupID(args) }
        let item: String?
        if method == "stickers.custom.remove" || method == "stickers.custom.thumbnail" { item = try stickerItemID(args) }
        else { item = nil }
        let name: String?
        if method == "stickers.custom.create" {
            guard let value = args["name"] as? String else {
                throw NativeBridgeError(code: "sticker_name", message: "请输入有效的表情分组名。")
            }
            name = value
        } else { name = nil }
        let library = customStickerLibrary()
        do {
            switch method {
            case "stickers.custom.create":
                let id = try library.create(name!)
                return ["groupID": id.uuidString, "groups": try stickerGroups(library)]
            case "stickers.custom.remove":
                try library.remove(itemID: item!, in: group!)
                return ["groups": try stickerGroups(library)]
            case "stickers.custom.thumbnail":
                let thumbnail = try await library.thumbnail(groupID: group!, itemID: item!)
                try checkStickerAccess(authorization)
                return ["bytes": FlutterStandardTypedData(bytes: thumbnail.bytes), "mime": thumbnail.mime]
            default: return ["groups": try stickerGroups(library)]
            }
        } catch {
            try checkStickerAccess(authorization)
            if error is CancellationError { throw CancellationError() }
            throw stickerLibraryError(error)
        }
    }

    /// The selected URLs originate in an OS chooser, never in a Dart path.
    /// Selection cancellation and invalidation cannot write into the library.
    func chooseStickerImages(_ args: [String: Any], select: () async -> [URL]?) async throws -> [String: Any] {
        try checkActive()
        let authorization = try context.requireAuthorization(args, signedIn: false)
        let group = try stickerGroupID(args)
        let library = customStickerLibrary()
        do {
            guard try library.checkedGroups().contains(where: { $0.id == group }) else {
                throw StickerLibrary.LibraryError.missingGroup
            }
            let selected = await select()
            try checkStickerAccess(authorization)
            guard let selected, !selected.isEmpty else {
                return ["cancelled": true, "importedCount": 0, "skippedCount": 0,
                        "groups": try stickerGroups(library)]
            }
            let result = try await library.importImages(selected, to: group) { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && !self.disposed && self.context.session.authorization == authorization
            }
            try checkStickerAccess(authorization)
            return ["cancelled": false, "importedCount": result.imported, "skippedCount": result.skipped,
                    "groups": try stickerGroups(library)]
        } catch {
            try checkStickerAccess(authorization)
            if error is CancellationError { throw CancellationError() }
            throw stickerLibraryError(error)
        }
    }

    private func uploadCustomSticker(_ args: [String: Any]) async throws -> [String: Any] {
        try checkActive()
        let authorization = try context.requireAuthorization(args)
        let group = try stickerGroupID(args), item = try stickerItemID(args)
        guard let requestID = args["requestId"] as? String, !requestID.isEmpty,
              requestID.utf8.count <= 512, requestID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NativeBridgeError(code: "sticker_invalid", message: "表情上传已失效，请重新选择。")
        }
        try requireEditorIdle()
        let operation = UUID()
        uploadID = operation
        defer { if uploadID == operation { uploadID = nil; uploadTask = nil } }
        func validate() throws {
            try checkActive()
            guard uploadID == operation, context.session.authorizes(authorization) else { throw staleAccess() }
        }
        let file: URL
        do { file = try customStickerLibrary().resolve(groupID: group, itemID: item) }
        catch { throw stickerLibraryError(error) }
        let read = Task.detached(priority: .utility) { try Self.stickerPicture(file) }
        let picture: NodeImageUpload.Picture
        do {
            picture = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        } catch {
            try validate()
            if error is CancellationError { throw CancellationError() }
            throw NativeBridgeError(code: "sticker_invalid", message: "无法读取这张表情，请重新导入图片。")
        }
        try validate()
        let key: String
        do {
            key = try await readUploadKey(operation, validate: validate)
        } catch NodeImageError.missingKey {
            throw NativeBridgeError(code: "image_key_missing", message: "请先配置 NodeImage 密钥，再使用自定义表情。")
        }
        try validate()
        let request = requests.uploadClipboardImage
        let task = Task { try Task.checkCancellation(); return try await request(picture, key) }
        uploadTask = task
        let uploaded: URL
        do {
            uploaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            try validate()
            if error is CancellationError { throw CancellationError() }
            if let issue = error as? NodeImageError, case .invalidKey = issue {
                throw NativeBridgeError(code: "image_key_invalid", message: "NodeImage 拒绝了密钥，请检查图床设置。")
            }
            throw NativeBridgeError(code: "sticker_upload_failed", message: "表情上传失败，正文已保留，请稍后重试。")
        }
        try validate()
        guard uploaded.scheme == "https", uploaded.host?.isEmpty == false,
              uploaded.user == nil, uploaded.password == nil,
              uploaded.absoluteString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !uploaded.absoluteString.contains("<"), !uploaded.absoluteString.contains(">") else {
            throw NativeBridgeError(code: "sticker_upload_failed", message: "图床没有返回有效图片链接，请稍后重试。")
        }
        return ["url": uploaded.absoluteString, "markdown": "![表情](<\(uploaded.absoluteString)>)"]
    }

    nonisolated private static func stickerPicture(_ url: URL) throws -> NodeImageUpload.Picture {
        try Task.checkCancellation()
        let directory = url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard directory >= 0 else { throw NodeImageError.invalidFile }
        defer { close(directory) }
        let descriptor = url.lastPathComponent.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NodeImageError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        let limit = StickerLibrary.imageSizeLimit
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size > 0, information.st_size <= Int64(limit),
              let bytes = try handle.read(upToCount: limit + 1), bytes.count == Int(information.st_size),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = info[kCGImagePropertyPixelWidth as String] as? Double,
              let height = info[kCGImagePropertyPixelHeight as String] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0,
              let format = CGImageSourceGetType(source),
              let type = UTType(format as String), type.conforms(to: .image), let mime = type.preferredMIMEType else {
            throw NodeImageError.invalidFile
        }
        try Task.checkCancellation()
        return .init(data: bytes, name: "sticker.\(type.preferredFilenameExtension ?? "img")", mime: mime)
    }

    private func imageKeyStatus(_ args: [String: Any]) async throws -> [String: Bool] {
        try checkActive()
        let authorization = try context.requireAuthorization(args, signedIn: false)
        let configured: Bool
        do {
            configured = try await keyStore.configured()
        } catch {
            try checkActive()
            guard context.session.authorization == authorization else { throw staleAccess() }
            if error is CancellationError { throw CancellationError() }
            throw imageKeyStoreError()
        }
        try checkActive()
        guard context.session.authorization == authorization else { throw staleAccess() }
        return ["configured": configured]
    }

    private func imageKeyOperation(_ method: String, _ args: [String: Any]) async throws -> [String: Bool] {
        // Local image credentials are available while signed out, but a stale
        // account window must not read state or mutate the current credential.
        try checkActive()
        let authorization = try context.requireAuthorization(args, signedIn: false)
        try requireEditorIdle()
        let mutation: @MainActor () async throws -> Void
        let configured: Bool
        switch method {
        case "images.setKey":
            let raw = try NativeDTO.string(args, "key")
            // Reject newline characters before trimming, including at either
            // edge, so pasted multi-line credentials cannot be silently changed.
            let invalid = NativeBridgeError(code: "invalid_image_key", message: "请输入不含换行的有效 NodeImage 密钥。")
            guard !raw.isEmpty, raw.rangeOfCharacter(from: .newlines) == nil else { throw invalid }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw invalid }
            let save = keyStore.save
            mutation = { try await save(key) }
            configured = true
        default:
            mutation = keyStore.remove
            configured = false
        }
        let operation = UUID()
        keyMutationID = operation
        let task = Task { try Task.checkCancellation(); try await mutation() }
        keyMutationTask = task
        // Cancellation can suppress a queued mutation, but a running Keychain
        // call must finish before another maintenance/upload/write can start.
        defer {
            if keyMutationID == operation { keyMutationID = nil; keyMutationTask = nil }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            try checkActive()
            guard context.session.authorization == authorization else { throw staleAccess() }
            if error is CancellationError { throw CancellationError() }
            throw imageKeyStoreError()
        }
        try checkActive()
        guard context.session.authorization == authorization else { throw staleAccess() }
        return ["configured": configured]
    }

    private func readUploadKey(_ operation: UUID, validate: () throws -> Void) async throws -> String {
        try validate()
        let read = keyStore.read
        let task = Task { try Task.checkCancellation(); return try await read() }
        uploadKeyRead = (operation, task)
        defer {
            if uploadKeyRead?.operation == operation { uploadKeyRead = nil }
        }
        let stored: String?
        do {
            stored = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            try validate()
            if error is CancellationError { throw CancellationError() }
            if let issue = error as? NodeImageError, case .missingKey = issue { throw issue }
            throw imageKeyStoreError()
        }
        try validate()
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NodeImageError.missingKey
        }
        return stored
    }

    private func imageKeyStoreError() -> NativeBridgeError {
        // Never forward a storage error's localizedDescription or userInfo: a
        // provider may include the supplied credential in its diagnostic text.
        .init(code: "image_key_store", message: "无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。")
    }

    private func clipboardToken(_ args: [String: Any]) throws -> String {
        guard let token = args["token"] as? String, UUID(uuidString: token) != nil else {
            throw NativeComposerClipboard.expired()
        }
        return token
    }

    private func cancelClipboardUpload(token: String, identity: NativeComposerClipboard.Identity) {
        guard let current = clipboardUpload, current.token == token, current.identity == identity else { return }
        clipboardUpload = nil
        if uploadID == current.operation {
            if uploadKeyRead?.operation == current.operation {
                uploadKeyRead?.task.cancel()
                uploadKeyRead = nil
            }
            uploadTask?.cancel()
            uploadTask = nil
            uploadID = nil
        }
    }

    private func uploadClipboardSnapshot(_ args: [String: Any]) async throws -> [String: Any] {
        try checkActive()
        let authorization = try context.requireAuthorization(args)
        let identity = try NativeComposerClipboard.Identity(args, authorization: authorization)
        let token = try clipboardToken(args)
        try composerClipboard.validate(identity, token: token)
        do { try requireEditorIdle() }
        catch {
            composerClipboard.release(identity, token: token)
            throw error
        }
        let bytes = try composerClipboard.consume(identity, token: token)
        let operation = UUID()
        uploadID = operation
        clipboardUpload = (token, identity, operation)
        defer {
            // Clear our upload before invalidating the token, so its callback
            // cannot cancel a newer file or clipboard upload.
            if uploadID == operation { uploadID = nil; uploadTask = nil }
            if clipboardUpload?.operation == operation { clipboardUpload = nil }
            composerClipboard.release(identity, token: token)
        }
        func validate() throws {
            try checkActive()
            guard uploadID == operation, context.session.authorizes(authorization) else { throw staleAccess() }
            try composerClipboard.validate(identity, token: token, ready: false)
        }
        let key: String
        do {
            key = try await readUploadKey(operation, validate: validate)
        } catch NodeImageError.missingKey {
            throw NativeBridgeError(code: "image_key_missing", message: "请先配置 NodeImage 密钥，再粘贴图片。")
        }
        try validate()
        let picture = NodeImageUpload.Picture(data: bytes, name: "clipboard.png", mime: "image/png")
        let request = requests.uploadClipboardImage
        let task = Task { try Task.checkCancellation(); return try await request(picture, key) }
        uploadTask = task
        let uploaded: URL
        do {
            uploaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            try checkActive()
            guard uploadID == operation, context.session.authorizes(authorization) else { throw staleAccess() }
            try composerClipboard.validate(identity, token: token, ready: false)
            if error is CancellationError { throw CancellationError() }
            if let imageError = error as? NodeImageError, case .invalidKey = imageError {
                throw NativeBridgeError(code: "image_key_invalid", message: "NodeImage 拒绝了密钥，请检查图床设置。")
            }
            // Provider errors may contain credentials in their descriptions.
            throw NativeBridgeError(code: "clipboard_upload_failed", message: "图片上传失败，正文已保留，请稍后重新粘贴。")
        }
        try checkActive()
        guard uploadID == operation, context.session.authorizes(authorization) else { throw staleAccess() }
        try composerClipboard.validate(identity, token: token, ready: false)
        guard uploaded.scheme == "https", uploaded.host?.isEmpty == false,
              uploaded.user == nil, uploaded.password == nil else {
            throw NativeBridgeError(code: "clipboard_upload_failed", message: "图床没有返回有效图片链接，请稍后重新粘贴。")
        }
        return ["url": uploaded.absoluteString, "markdown": "![image](\(uploaded.absoluteString))"]
    }

    /// Own selection and upload as one operation. An old picker/upload may finish
    /// after an account switch, but must neither return an insertion nor release
    /// the new account's operation.
    func chooseImage(_ args: [String: Any], select: () async -> URL?) async throws -> [String: Any] {
        try checkActive()
        let authorization = try context.requireAuthorization(args)
        try requireEditorIdle()
        let operation = UUID()
        uploadID = operation
        defer {
            if uploadID == operation { uploadID = nil; uploadTask = nil }
        }
        func validate() throws {
            try checkActive()
            guard uploadID == operation, context.session.authorizes(authorization) else { throw staleAccess() }
        }
        let selected = await select()
        try validate()
        guard let url = selected else { return ["cancelled": true] }
        let key = try await readUploadKey(operation, validate: validate)
        try validate()
        let request = requests.uploadImage
        let task = Task { try Task.checkCancellation(); return try await request(url, key) }
        uploadTask = task
        let uploaded: URL
        do {
            uploaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            try validate()
            throw error
        }
        try validate()
        return ["url": uploaded.absoluteString, "markdown": "![image](\(uploaded.absoluteString))"]
    }

    private func requireNoUpload() throws {
        guard !uploading else {
            throw NativeBridgeError(code: "uploading", message: "图片正在选择或上传，请完成后再提交或放弃编辑。")
        }
    }

    private func requireEditorIdle() throws {
        try requireNoUpload()
        guard keyMutationID == nil else {
            throw NativeBridgeError(code: "writing", message: "图床密钥正在更新，请等待完成后再上传图片或提交编辑。")
        }
        guard editorWriteID == nil else {
            throw NativeBridgeError(code: "writing", message: "内容正在提交，请等待完成后再上传图片或提交其他编辑。")
        }
        guard optionsLoad == nil else {
            throw NativeBridgeError(code: "discussion_options_loading", message: "正在读取发帖权限，请完成后再重试。")
        }
    }

    private func beginEditorWrite() throws -> UUID {
        try checkActive()
        try requireEditorIdle()
        let operation = UUID()
        editorWriteID = operation
        return operation
    }

    private func finishEditorWrite(_ operation: UUID) {
        if editorWriteID == operation { editorWriteID = nil }
    }

    private func invalidateEditorOperations() {
        context.session.cancelPendingDraftCredentialReads()
        composerDrop.invalidate()
        composerClipboard.invalidate()
        clipboardUpload = nil
        uploadKeyRead?.task.cancel()
        uploadKeyRead = nil
        uploadTask?.cancel()
        uploadTask = nil
        uploadID = nil
        editorWriteID = nil
        keyMutationTask?.cancel()
        // Retain the credential reservation until the storage task actually
        // returns, including after identity changes and service disposal.
        // Keep an options read reserved across identity discovery. Its old
        // publisher/draft are detached by invalidate(), and the same request
        // retries the new partition before releasing its reservation.
    }

    private func awaitWrite(_ task: Task<Void, Never>) async {
        let id = UUID()
        writeTasks[id] = task
        defer { writeTasks[id] = nil }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func imageDraftTopicID(_ args: [String: Any]) throws -> String {
        let id = try NativeDTO.string(args, "topicID")
        guard let value = Int(id), value > 0, String(value) == id else {
            throw NativeBridgeError(code: "invalid_topic", message: "帖子标识无效，请重新打开编辑器。")
        }
        return id
    }

    private func messagePeer(_ args: [String: Any]) throws -> Int {
        let peer = try NativeDTO.integer(args, "peer")
        guard peer > 0, peer != context.session.memberID else {
            throw NativeBridgeError(code: "invalid_peer", message: "请选择有效的私信联系人。")
        }
        return peer
    }

    private func messageBoolean(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw NativeBridgeError(code: "invalid_arguments", message: "参数必须是布尔值：\(key)")
        }
        return value.boolValue
    }

    private func staleMessageDraft() -> NativeBridgeError {
        .init(code: "stale_draft", message: "私信正文或 Markdown 模式已更新，请核对后重新发送。")
    }

    private func imageSizeChange(_ args: [String: Any], content: String) throws -> (url: URL, ratio: Double, width: Double) {
        let expected = try NativeDTO.string(args, "expectedContent")
        guard expected == content else {
            throw NativeBridgeError(code: "stale_image_draft", message: "正文已变化，请等待预览更新后再调整图片大小。")
        }
        let url = try NativeDTO.url(args)
        guard url.scheme == "https" else {
            throw NativeBridgeError(code: "invalid_url", message: "图片必须使用有效的 HTTPS 链接。")
        }
        func number(_ key: String, in range: ClosedRange<Double>) throws -> Double {
            guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, range.contains(value.doubleValue) else {
                throw NativeBridgeError(code: "invalid_image_size", message: "图片比例须为 10%–100%，预览宽度须为 1–1080。")
            }
            return value.doubleValue
        }
        let ratio = try number("ratio", in: 0.1...1)
        let width = try number("previewWidth", in: 1...Double(MarkdownImageScale.maximumWidth))
        guard !MarkdownPreviewDocument.imageReferences(content, selected: [url]).isEmpty else {
            throw NativeBridgeError(code: "unsupported_draft_image", message: "当前正文没有这张可调整大小的图片，请等待预览更新后重试。")
        }
        return (url, ratio, width)
    }

    private func imageSizingSnapshot(_ sizing: DraftImageSizing, content: String) -> [String: Any] {
        let selections: [[String: Any]] = sizing.sizes.keys.sorted { $0.absoluteString < $1.absoluteString }.compactMap { url in
            guard let size = sizing.sizes[url], size.ratio.isFinite, (0.1..<1).contains(size.ratio),
                  (1...MarkdownImageScale.maximumWidth).contains(size.previewWidth),
                  url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
            return ["url": url.absoluteString, "ratio": size.ratio, "previewWidth": size.previewWidth]
        }
        return ["imageSizing": selections, "imageURLs": MarkdownPreviewDocument.imageURLs(content).map(\.absoluteString)]
    }

    private func replyDraftSnapshot(_ topicID: String) -> [String: Any] {
        let session = context.session
        let content = session.drafts[topicID, default: ""]
        var result = imageSizingSnapshot(session.imageSizing(for: .reply(topicID)), content: content)
        result["topicID"] = topicID
        result["content"] = content
        result["accessRevision"] = session.accessRevision
        return result
    }

    private func messageDraftSnapshot(_ peer: Int) -> [String: Any] {
        let session = context.session
        let content = session.messageDrafts[peer, default: ""]
        var result = imageSizingSnapshot(session.imageSizing(for: .message(peer)), content: content)
        result["peer"] = peer
        result["content"] = content
        result["draft"] = content
        result["draftMarkdown"] = session.messageMarkdown[peer, default: true]
        result["accessRevision"] = session.accessRevision
        return result
    }

    private func discussionSnapshot() -> [String: Any] {
        let draft = context.session.newDiscussion
        let phase: String
        switch publisher.phase {
        case .loading: phase = "loading"
        case .ready: phase = "ready"
        case .signedOut: phase = "signedOut"
        case .verification: phase = "verification"
        case .unavailable: phase = "unavailable"
        }
        var result: [String: Any] = ["title": draft.title, "content": draft.content, "category": draft.category, "rank": draft.rank,
                "categories": publisher.categories.map { ["id": $0.id, "title": $0.title] }, "maxRank": publisher.maxRank,
                "phase": phase, "verificationURL": DiscussionScript.page.absoluteString,
                "ready": publisher.phase == .ready, "sending": publisher.sending, "uploading": uploading,
                "lastSubmissionMessage": NativeDTO.optional(lastSubmissionMessage),
                "message": NativeDTO.optional(publisher.message), "accessRevision": context.session.accessRevision]
        result.merge(imageSizingSnapshot(draft.imageSizing, content: draft.content)) { _, imageValue in imageValue }
        return result
    }

    private func emitInbox() { context.emit(domain: "inbox", data: inboxSnapshot()) }

    private func inboxSnapshot(key requested: InboxKey? = nil, state: ForumAccountReader? = nil) -> [String: Any] {
        let key = requested ?? selectedInboxKey
        var result: [String: Any] = ["kind": key.kind, "peer": NativeDTO.optional(key.peer), "items": [], "loading": false,
            "draft": key.peer.map { context.session.messageDrafts[$0, default: ""] } ?? "", "error": NSNull(), "accessRevision": context.session.accessRevision]
        if key.kind == "messages" { result["olderItems"] = [] as [[String: Any]] }
        if key.kind == "conversation", let peer = key.peer, peer > 0 {
            let draft = messageDraftSnapshot(peer)
            for name in ["draftMarkdown", "imageSizing", "imageURLs"] { result[name] = draft[name] }
        }
        guard let state = state ?? accounts[key] else { result["loading"] = true; return result }
        switch requests.inboxState(state) {
        case .loading: result["loading"] = true
        case .signedOut: result["error"] = "请先登录 NodeSeek。"
        case .verification: result["error"] = ForumPageError.verification.localizedDescription
        case .failure: result["error"] = "暂时无法读取通知，请重试。"
        case .profile(let profile): result["profile"] = NativeDTO.encode(profile)
        case .notices(let notices, let count): result["items"] = notices.map { notice in
            var row = NativeDTO.encode(notice) as? [String: Any] ?? [:]
            row["url"] = notice.destination(floorsPerPage: count).absoluteString
            row["avatar"] = notice.authorID.map { Forum.avatar($0).absoluteString } ?? ""
            return row
        }
        case .conversations(let conversations):
            func row(_ item: ForumConversation) -> [String: Any] {
                var value = NativeDTO.encode(item) as? [String: Any] ?? [:]
                value["avatar"] = Forum.avatar(item.id).absoluteString
                return value
            }
            result["items"] = conversations.map(row)
            var seen = Set(conversations.map(\.id))
            if let owner = context.session.memberID { seen.insert(owner) }
            result["olderItems"] = context.session.conversationContacts.compactMap { contact -> [String: Any]? in
                guard contact.id > 0, seen.insert(contact.id).inserted else { return nil }
                return row(contact.conversation)
            }
        case .messages(let peer, let messages): result["peer"] = peer; result["items"] = NativeDTO.encode(messages)
        }
        return result
    }

    private func edit(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        let session = context.session, token = try context.requireAuthorization(args)
        var topicArgs = args
        if method == "reader.edit.setImageSize" {
            // For this method `url` is the image URL. The existing editor token
            // binds topic/floor/owner, so no page load or separate topic URL is needed.
            let id = try imageDraftTopicID(args)
            topicArgs["url"] = Forum.home.appendingPathComponent("post-\(id)-1").absoluteString
        }
        let topic = try topic(topicArgs)
        try requireEditorIdle()
        guard let owner = token.owner, let postID = Int(topic.id),
              args["topicID"] as? String == topic.id,
              let floor = try? NativeDTO.integer(args, "floor"), floor >= 0 else { throw staleEditor() }
        let editor: ForumInlineEdit
        let target: ForumInlineEdit.Target
        if method == "reader.edit.begin" {
            editor = requests.makeEdit()
            target = .init(topicID: postID, floor: floor, owner: owner)
            editor.begin(target)
            // Reserve this exact instance before either page preparation or the
            // Markdown read suspends. An older begin cannot overwrite it later.
            inlineEdits[topic.id] = .init(editor: editor, authorization: token)
        } else {
            guard let current = inlineEdits[topic.id], current.authorization == token,
                  let existing = current.editor.target, existing.topicID == postID,
                  existing.floor == floor, existing.owner == owner,
                  let editToken = args["editToken"] as? String,
                  UUID(uuidString: editToken) == existing.id else { throw staleEditor() }
            editor = current.editor
            target = existing
        }
        func requireCurrent() throws {
            try checkActive()
            guard session.authorizes(token) else { throw staleAccess() }
            guard inlineEdits[topic.id]?.editor === editor,
                  inlineEdits[topic.id]?.authorization == token,
                  editor.target == target else { throw staleEditor() }
        }
        var accepted = false
        switch method {
        case "reader.edit.begin":
            let state = reader(topic)
            let preparedPage = await requests.preparePage(topic, state, session)
            try requireCurrent()
            guard readers[topic.id] === state else { throw staleEditor() }
            let page = try requirePreparedPage(preparedPage, reader: state)
            await editor.load(on: page)
            try requireCurrent()
        case "reader.edit.update":
            if let title = args["title"] as? String { editor.title = title }
            if let content = args["content"] as? String { editor.content = content }
        case "reader.edit.setImageSize":
            try requireCurrent()
            guard editor.ready, !editor.loading, !editor.saving else {
                throw NativeBridgeError(code: "not_ready", message: "请等待编辑内容载入或保存完成后再调整图片大小。")
            }
            let change = try imageSizeChange(args, content: editor.content)
            editor.sizing.set(change.ratio, previewWidth: change.width, for: change.url)
        case "reader.edit.save":
            let state = reader(topic)
            let preparedPage = await requests.preparePage(topic, state, session)
            try requireCurrent()
            try requireEditorIdle()
            guard readers[topic.id] === state else { throw staleEditor() }
            let page = try requirePreparedPage(preparedPage, reader: state)
            let operation = try beginEditorWrite()
            defer { finishEditorWrite(operation) }
            accepted = await requests.saveEdit(editor, page, {
                !self.disposed && self.editorWriteID == operation && session.authorizes(token) && !Task.isCancelled &&
                self.inlineEdits[topic.id]?.editor === editor && self.inlineEdits[topic.id]?.authorization == token &&
                editor.target == target
            })
            try requireCurrent()
            if accepted {
                if target.floor == 0 { session.rememberTitle(editor.title, for: topic.id, authorization: token) }
                session.invalidateThread(topic.id)
            }
        case "reader.edit.cancel":
            editor.clear(); inlineEdits[topic.id] = nil
        case "reader.edit.continueVerification":
            guard editor.ready else {
                throw NativeBridgeError(code: "not_ready", message: "编辑内容尚未载入，请稍后重试。")
            }
            // Opening a verification window is not proof of success. This only
            // lets the user explicitly retry saving the same preserved draft.
            editor.continueAfterVerification()
        default: break
        }
        guard session.authorizes(token) else { throw staleAccess() }
        var result: [String: Any] = ["title": editor.title, "content": editor.content, "ready": editor.ready, "saving": editor.saving,
                "canSave": editor.canSave, "message": NativeDTO.optional(editor.message), "needsVerification": editor.needsVerification,
                "accepted": accepted, "editToken": target.id.uuidString,
                "cancelled": method == "reader.edit.cancel",
                "topicID": topic.id, "floor": floor, "accessRevision": token.revision]
        result.merge(imageSizingSnapshot(editor.sizing, content: editor.content)) { _, imageValue in imageValue }
        if accepted, inlineEdits[topic.id]?.editor === editor,
           inlineEdits[topic.id]?.authorization == token, editor.target == target {
            // Build the receipt before retiring the completed lease. A new
            // begin must never inherit its body, image metadata, or write token.
            inlineEdits[topic.id] = nil
        }
        return result
    }

    private func staleEditor() -> NativeBridgeError {
        .init(code: "stale_editor", message: "编辑目标已变化，请重新打开对应楼层。当前窗口中的修改仍然保留。")
    }
}

/// Pixel offsets and body-relative anchors preserve the Flutter reader's position. Native
/// partitions and budgets prevent account mixing and unbounded UI persistence.
@MainActor
final class NativeReaderOffsetStore {
    struct BodyAnchor: Codable, Equatable {
        let floor: String
        let dy: Double
        var dictionary: [String: Any] { ["floor": floor, "dy": dy] }

        init(floor: String, dy: Double) throws {
            guard !floor.isEmpty, floor.utf8.count <= 12,
                  floor.utf8.allSatisfy({ (48...57).contains($0) }),
                  dy.isFinite, (-100_000_000...100_000_000).contains(dy) else {
                throw NativeBridgeError(code: "invalid_position", message: "正文阅读锚点无效。")
            }
            self.floor = floor
            self.dy = dy
        }

        private enum CodingKeys: String, CodingKey { case floor, dy }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(floor: values.decode(String.self, forKey: .floor), dy: values.decode(Double.self, forKey: .dy))
        }
    }

    private struct Entry: Codable {
        let page: String
        let offset: Double
        let updated: Date
        let bodyAnchor: BodyAnchor?

        init(page: String, offset: Double, updated: Date, bodyAnchor: BodyAnchor?) {
            self.page = page
            self.offset = offset
            self.updated = updated
            self.bodyAnchor = bodyAnchor
        }

        private enum CodingKeys: String, CodingKey { case page, offset, updated, bodyAnchor }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            page = try values.decode(String.self, forKey: .page)
            offset = try values.decode(Double.self, forKey: .offset)
            updated = try values.decode(Date.self, forKey: .updated)
            // Older v1 records have no bodyAnchor. A damaged optional anchor
            // must not discard its usable pixel fallback or sibling records.
            bodyAnchor = try? values.decodeIfPresent(BodyAnchor.self, forKey: .bodyAnchor)
        }
    }
    private let defaults: UserDefaults
    private var partitions: [String: [String: Entry]] = [:]
    private var partitionOrder: [String] = []
    private var dirty = Set<String>()
    private var pending: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private let now: () -> Date
    static let maximumEntries = 500
    static let maximumOffset = 100_000_000.0

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                self?.flush()
            }.store(in: &observers)
        }
    }

    static func validOffset(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...maximumOffset).contains(number.doubleValue) else {
            throw NativeBridgeError(code: "invalid_position", message: "阅读位置数值无效。")
        }
        return number.doubleValue
    }

    static func validBodyAnchor(_ value: Any) throws -> BodyAnchor {
        guard let values = value as? [String: Any], let floor = values["floor"] as? String,
              let number = values["dy"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw NativeBridgeError(code: "invalid_position", message: "正文阅读锚点无效。")
        }
        return try BodyAnchor(floor: floor, dy: number.doubleValue)
    }

    func offset(at url: URL, owner: Int?) -> Double {
        guard let page = canonicalPage(url) else { return 0 }
        let key = partition(owner)
        load(key)
        return partitions[key]?[page]?.offset ?? 0
    }

    func bodyAnchor(at url: URL, owner: Int?) -> BodyAnchor? {
        guard let page = canonicalPage(url) else { return nil }
        let key = partition(owner)
        load(key)
        return partitions[key]?[page]?.bodyAnchor
    }

    func remember(_ offset: Double, bodyAnchor: BodyAnchor? = nil, at url: URL, owner: Int?) throws {
        _ = try Self.validOffset(offset)
        guard let page = canonicalPage(url) else {
            throw NativeBridgeError(code: "invalid_topic", message: "阅读位置必须属于 NodeSeek 帖子。")
        }
        let key = partition(owner)
        load(key)
        partitions[key, default: [:]][page] = Entry(page: page, offset: offset, updated: now(), bodyAnchor: bodyAnchor)
        if let entries = partitions[key], entries.count > Self.maximumEntries,
           let oldest = entries.values.min(by: { $0.updated < $1.updated }) {
            partitions[key]?[oldest.page] = nil
        }
        dirty.insert(key)
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pending?.cancel()
        pending = nil
        for key in dirty {
            guard let entries = partitions[key], let data = try? JSONEncoder().encode(Array(entries.values)) else { continue }
            defaults.set(data, forKey: key)
        }
        dirty.removeAll()
    }

    private func load(_ key: String) {
        partitionOrder.removeAll { $0 == key }
        partitionOrder.append(key)
        guard partitions[key] == nil else { return }
        if partitionOrder.count > 4 {
            flush()
            partitions[partitionOrder.removeFirst()] = nil
        }
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        var entries: [String: Entry] = [:]
        for entry in saved.sorted(by: { $0.updated > $1.updated }).prefix(Self.maximumEntries) {
            guard let url = URL(string: entry.page), let page = canonicalPage(url),
                  (try? Self.validOffset(entry.offset)) != nil, entries[page] == nil else { continue }
            entries[page] = entry
        }
        partitions[key] = entries
    }

    private func partition(_ owner: Int?) -> String {
        "flutter.readerOffsets.v1." + (owner.map(String.init) ?? "guest")
    }

    private func canonicalPage(_ url: URL) -> String? {
        guard Forum.topicID(url) != nil,
              url.lastPathComponent.range(of: #"^post-[1-9][0-9]*-[1-9][0-9]*$"#, options: .regularExpression) != nil else { return nil }
        return Forum.home.appendingPathComponent(url.lastPathComponent).absoluteString
    }
}
