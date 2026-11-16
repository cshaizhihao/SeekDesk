import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class ForumSession: ObservableObject {
    enum Account { case unconfirmed, signedOut, signedIn }

    enum AccountPanel { case profile, compose }

    struct Access: Identifiable {
        let id = UUID()
        let url: URL
        let verification: Bool
        let returnTo: AccountPanel?
    }

    enum Presentation: Identifiable {
        case access(Access), profile, compose, rulings(String), user(ForumUserReference)

        var id: String {
            switch self {
            case .access(let access): access.id.uuidString
            case .profile: "profile"
            case .compose: "compose"
            case .rulings(let name): "rulings-\(name)"
            case .user(let person): "user-\(person.id)"
            }
        }
    }

    struct Receipt: Equatable {
        let message: String
        var destination: URL? = nil
        var accepted = false
        var verify = false
    }

    @Published private(set) var account: Account = .unconfirmed
    @Published var presentation: Presentation?
    var access: Access? {
        if case .access(let request) = presentation { return request }
        return nil
    }
    @Published private(set) var accessRevision = 0
    @Published private(set) var memberID: Int?
    var accessDidChange: (() -> Void)?
    var canCompose: Bool { account == .signedIn && memberID != nil }
    struct Authorization: Equatable { let revision: Int; let owner: Int? }
    var authorization: Authorization { Authorization(revision: accessRevision, owner: memberID) }
    func authorizes(_ token: Authorization) -> Bool {
        canCompose && token == authorization
    }
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var receipts: [String: Receipt] = [:]
    @Published private(set) var reactionPending: ForumReactionTarget?
    @Published private(set) var reactionMarks: [ForumReactionTarget: ForumReactionResult] = [:]
    private var pendingReplyNavigation = Set<String>()
    @Published private(set) var titles: [String: String] = [:]
    /// Called after a valid title update or confirmed-owner restoration. It is
    /// not fired midway through access invalidation, before Workspace redacts.
    var titlesDidChange: (() -> Void)?
    var retainedTitleIDs: (() -> Set<String>)?
    private let titleStore: ForumTitleStore
    private var titleStorageClosed = false
    struct TitleRead {
        let authorization: Authorization
        let sequence: UInt64
    }
    private var titleSequence: UInt64 = 0
    private var publicTitleSequences: [String: UInt64] = [:]
    @Published private(set) var drafts: [String: String] = [:]
    @Published var messageDrafts: [Int: String] = [:] {
        didSet {
            changedMessageDrafts(Set(oldValue.keys).union(messageDrafts.keys).filter { oldValue[$0] != messageDrafts[$0] })
            persistDrafts()
        }
    }
    @Published var messageMarkdown: [Int: Bool] = [:] {
        didSet {
            changedMessageDrafts(Set(oldValue.keys).union(messageMarkdown.keys).filter {
                oldValue[$0, default: true] != messageMarkdown[$0, default: true]
            })
            persistDrafts()
        }
    }
    private var messageDraftRevisions: [Int: UInt64] = [:]
    @Published var messageStatus: [Int: String] = [:]
    @Published var sendingMessages: Set<Int> = []
    let profileStore = ForumProfileStore()
    var profiles: [Int: ForumUserProfile] { profileStore.profiles }
    @Published private(set) var ownProfile: ForumProfile?
    @Published private(set) var ownIntroduction: ForumIntroduction?
    @Published private(set) var conversationContacts: [ForumConversationContact] = []
    @Published private(set) var unread = ForumUnreadCounts()
    @Published var requestedPeer: ForumConversation?
    private var profileRequests: [Int: UUID] = [:]
    private var profileUpdated: [Int: Date] = [:]
    let profileRequestState = ForumProfileRequestState()
    var profileFailures: Set<Int> { profileRequestState.failures }
    var profileLoading: Set<Int> { profileRequestState.loading }
    private let profileLifetime: TimeInterval = 180
    private var savingIntroduction = false
    private var unreadPage: ForumWebPage?
    private var checkingUnread = false
    private var unreadRevision = 0
    private var queuedUnreadRefresh = false
    private var nextOwnProfileRefresh = Date.distantPast
    private var conversationContactOwner: Int?
    private var threadMemory: [URL: ForumThread] = [:]
    private var threadUpdated: [URL: Date] = [:]
    // Per-topic generations isolate background writes. Eviction also produces a
    // new generation on the next lookup, so an older in-flight read stays stale.
    private var threadWriteRevisions: [String: UUID] = [:]
    private var threadRevisionOrder: [String] = []
    private let threadLifetime: TimeInterval = 120
    private let threadNow: () -> Date
    private var recentPages: [URL] = []
    private var threadCosts: [URL: Int] = [:]
    private var threadCost = 0
    let readingProgress: ReadingProgress
    private var pendingEdits: [URL: ForumInlineEdit] = [:]
    enum DraftScope: Hashable {
        case reply(String), message(Int)
        var storageKey: String {
            switch self { case .reply(let id): "reply:" + id; case .message(let id): "message:\(id)" }
        }
        init?(storageKey: String) {
            if storageKey.hasPrefix("reply:") { self = .reply(String(storageKey.dropFirst(6))) }
            else if storageKey.hasPrefix("message:"), let id = Int(storageKey.dropFirst(8)) { self = .message(id) }
            else { return nil }
        }
    }
    private var draftImages: [DraftScope: DraftImageSizing] = [:]
    private var proxyObserver: AnyCancellable?
    let dataStore: WKWebsiteDataStore
    @Published private(set) var newDiscussion = NewDiscussionDraft()
    private let defaults: UserDefaults
    private let requests: Requests
    private let profileNow: () -> Date
    struct Requests {
        var reply: (ForumWebPage, Int, String) async throws -> String?
        var profile: (ForumWebPage, Int, Bool) async throws -> String?
        static var live: Self {
            Self(reply: { page, id, content in
                try await page.webView.callAsyncJavaScript(ForumPageScript.reply,
                    arguments: ["postId": id, "content": content], in: nil, contentWorld: .defaultClient) as? String
            }, profile: { page, id, readme in
                try await page.webView.callAsyncJavaScript(ForumAccountScript.userProfile,
                    arguments: ["member": id, "includeReadme": readme], in: nil, contentWorld: .defaultClient) as? String
            })
        }
    }
    private var restoringDrafts = false

    init(defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore? = nil, requests: Requests? = nil,
         profileNow: @escaping () -> Date = Date.init, threadNow: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        titleStore = ForumTitleStore(defaults: defaults)
        readingProgress = ReadingProgress(defaults: defaults)
        self.requests = requests ?? .live
        self.profileNow = profileNow
        self.threadNow = threadNow
        self.dataStore = dataStore ?? .default()
        DeskProxyWebKit.configure(self.dataStore)
        proxyObserver = NotificationCenter.default.publisher(for: .deskProxyRouteChanged).sink { [weak self] _ in
            guard let self else { return }
            self.persistDrafts()
            self.cancelPendingDraftCredentialReads()
            self.unreadRevision += 1
            self.unreadPage = nil
            self.clearThreadMemory()
            self.profileRequests.removeAll()
            self.profileRequestState.reset()
            self.sending.removeAll()
            self.sendingMessages.removeAll()
            self.reactionPending = nil
            self.savingIntroduction = false
            self.accessRevision += 1
            self.accessDidChange?()
        }
        newDiscussion.didChange = { [weak self] in self?.persistDrafts() }
        newDiscussion.imageSizing.didChange = { [weak self] in self?.persistDrafts() }
    }

    private func persistDrafts() {
        guard !restoringDrafts, let owner = memberID else { return }
        var images = Dictionary(uniqueKeysWithValues: draftImages.map { ($0.key.storageKey, $0.value.sizes) })
        images["discussion"] = newDiscussion.imageSizing.sizes
        let value = ForumDraftSnapshot(replies: drafts, messages: messageDrafts,
                                      discussion: newDiscussion.snapshot, images: images, messageMarkdown: messageMarkdown)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "forum.drafts.v1.\(owner)") }
    }

    private func restoreDrafts(for owner: Int?) {
        cancelPendingDraftCredentialReads()
        for sizing in draftImages.values { sizing.didChange = nil }
        newDiscussion.didChange = nil
        newDiscussion.imageSizing.didChange = nil
        restoringDrafts = true
        defer { restoringDrafts = false }
        let saved = owner.flatMap { defaults.data(forKey: "forum.drafts.v1.\($0)") }
            .flatMap { try? JSONDecoder().decode(ForumDraftSnapshot.self, from: $0) } ?? ForumDraftSnapshot()
        drafts = saved.replies
        messageDrafts = saved.messages
        messageMarkdown = saved.messageMarkdown
        messageDraftRevisions.removeAll()
        draftImages = [:]
        for (key, sizes) in saved.images {
            guard let scope = DraftScope(storageKey: key) else { continue }
            let sizing = DraftImageSizing()
            sizing.restore(sizes)
            sizing.didChange = { [weak self] in self?.persistDrafts() }
            draftImages[scope] = sizing
        }
        let discussion = NewDiscussionDraft()
        discussion.restore(saved.discussion)
        discussion.imageSizing.restore(saved.images["discussion"] ?? [:])
        discussion.didChange = { [weak self, weak discussion] in
            guard let self, self.newDiscussion === discussion else { return }
            self.persistDrafts()
        }
        discussion.imageSizing.didChange = discussion.didChange
        newDiscussion = discussion
    }

    func cancelPendingDraftCredentialReads() {
        for sizing in draftImages.values { sizing.cancelPendingCredentialRead() }
        newDiscussion.imageSizing.cancelPendingCredentialRead()
    }

    /// Invalidate every visible/request state derived from the current identity.
    /// The cookie store itself is kept so the official login can be rechecked.
    private func invalidateAccess() {
        persistDrafts()
        readingProgress.activate(nil)
        memberID = nil
        restoreDrafts(for: nil)
        ownProfile = nil
        ownIntroduction = nil
        requestedPeer = nil
        clearConversationContacts()
        unreadRevision += 1
        unread = ForumUnreadCounts()
        unreadPage = nil
        nextOwnProfileRefresh = .distantPast
        clearThreadMemory()
        pendingEdits.removeAll()
        titles.removeAll()
        publicTitleSequences.removeAll()
        receipts.removeAll()
        pendingReplyNavigation.removeAll()
        sending.removeAll()
        sendingMessages.removeAll()
        messageStatus.removeAll()
        reactionPending = nil
        savingIntroduction = false
        profileStore.removeAll()
        profileRequests.removeAll()
        profileRequestState.reset()
        profileUpdated.removeAll()
        accessRevision += 1
        accessDidChange?()
    }

    func observeIdentity(_ identity: ForumIdentity) {
        guard !titleStorageClosed else { return }
        observeAccount(identity.signedIn)
        if identity.signedIn, let id = identity.id { confirmOwner(id) }
    }

    private func confirmOwner(_ id: Int) {
        guard !titleStorageClosed, id > 0, account == .signedIn, memberID != id else { return }
        invalidateAccess()
        memberID = id
        readingProgress.activate(id)
        restoreDrafts(for: id)
        replaceTitles(titleStore.titles(for: id))
    }

    func signIn() { showAccess(Forum.signIn, verification: false) }
    func verify(_ url: URL) { showAccess(url, verification: true) }

    private func showAccess(_ url: URL, verification: Bool) {
        let panel: AccountPanel?
        switch presentation {
        case .profile: panel = .profile
        case .compose: panel = .compose
        default: panel = nil
        }
        presentation = .access(Access(url: url, verification: verification, returnTo: panel))
    }

    func observeAccount(_ signedIn: Bool) {
        if signedIn && titleStorageClosed { return }
        let state: Account = signedIn ? .signedIn : .signedOut
        guard account != state else { return }
        let previous = account
        account = state
        if !signedIn || previous == .signedOut { invalidateAccess() }
    }

    func cachedThread(at url: URL) -> ForumThread? {
        let page = Forum.pageURL(url)
        guard let thread = threadMemory[page] else { return nil }
        recentPages.removeAll { $0 == page }
        recentPages.append(page)
        return thread
    }

    func threadIsFresh(at url: URL) -> Bool {
        let page = Forum.pageURL(url)
        guard threadMemory[page] != nil else { return false }
        return threadIsFresh(since: threadUpdated[page])
    }

    var threadReadTime: Date { threadNow() }

    func threadIsFresh(since updated: Date?) -> Bool {
        guard let updated else { return false }
        let age = threadNow().timeIntervalSince(updated)
        return age >= 0 && age < threadLifetime
    }

    func threadRevision(_ id: String) -> UUID {
        let revision = threadWriteRevisions[id] ?? UUID()
        threadWriteRevisions[id] = revision
        threadRevisionOrder.removeAll { $0 == id }
        threadRevisionOrder.append(id)
        while threadRevisionOrder.count > 128 {
            threadWriteRevisions.removeValue(forKey: threadRevisionOrder.removeFirst())
        }
        return revision
    }

    func invalidateThread(_ id: String) {
        threadWriteRevisions[id] = UUID()
        _ = threadRevision(id)
        for page in recentPages.filter({ Forum.topicID($0) == id }) { removeCachedThread(at: page) }
    }

    func pendingEdit(at url: URL) -> ForumInlineEdit? { pendingEdits[Forum.pageURL(url)] }

    func rememberEdit(_ edit: ForumInlineEdit?, at url: URL) { pendingEdits[Forum.pageURL(url)] = edit }

    func cacheThread(_ thread: ForumThread, at url: URL) {
        let pageURL = Forum.pageURL(url)
        let cost = ForumThreadCacheCost.estimate(thread)
        removeCachedThread(at: pageURL)
        // Oversized reports remain readable in the active reader without
        // evicting every small parsed page or retaining extra WebKit instances.
        guard cost <= ForumThreadCacheCost.limit else { return }
        threadMemory[pageURL] = thread
        threadUpdated[pageURL] = threadNow()
        threadCosts[pageURL] = cost
        threadCost += cost
        recentPages.append(pageURL)
        while recentPages.count > 8 || threadCost > ForumThreadCacheCost.limit {
            guard let discarded = recentPages.first else { break }
            removeCachedThread(at: discarded)
        }
    }

    private func removeCachedThread(at page: URL) {
        threadMemory.removeValue(forKey: page)
        threadUpdated.removeValue(forKey: page)
        threadCost -= threadCosts.removeValue(forKey: page) ?? 0
        recentPages.removeAll { $0 == page }
    }

    func anchor(at url: URL) -> String? { readingProgress.anchor(at: url) }

    func rememberAnchor(_ anchor: String, at url: URL, authorization token: Authorization) {
        guard token == authorization else { return }
        readingProgress.remember(anchor, at: url)
    }

    private func clearThreadMemory() {
        DeskMarkdownText.removeAll()
        ForumMarkdownLink.removeAll()
        MarkdownPreviewParsing.removeAll()
        threadMemory.removeAll()
        threadUpdated.removeAll()
        threadWriteRevisions.removeAll()
        threadRevisionOrder.removeAll()
        recentPages.removeAll()
        threadCosts.removeAll()
        threadCost = 0
        reactionMarks.removeAll()
    }

    func react(_ target: ForumReactionTarget, approval: ForumReactionApproval, owner: Int, on page: ForumWebPage) async -> ForumReactionResult? {
        guard reactionPending == nil, reactionMarks[target] == nil, account == .signedIn, ownProfile?.id == owner else { return nil }
        let access = accessRevision
        reactionPending = target
        defer { if access == accessRevision { reactionPending = nil } }
        let value = try? await page.webView.callAsyncJavaScript(ForumReactionScript.request,
            arguments: ["postID": target.postID, "floor": target.floor, "kind": target.kind.rawValue,
                        "approval": approval.rawValue, "owner": owner], in: nil, contentWorld: .page)
        guard access == accessRevision, account == .signedIn, ownProfile?.id == owner else { return nil }
        let result = (value as? String).flatMap { try? JSONDecoder().decode(ForumReactionResult.self, from: Data($0.utf8)) }
            ?? ForumReactionResult(kind: approval == .quote ? .rejected : .unknown)
        switch result.kind {
        case .accepted, .already:
            if reactionMarks.count >= 256, let oldest = reactionMarks.keys.first { reactionMarks.removeValue(forKey: oldest) }
            reactionMarks[target] = result
            if result.kind == .accepted, target.kind != .upvote {
                if let coin = result.coin, var profile = ownProfile {
                    profile.coin = coin
                    ownProfile = profile
                }
                nextOwnProfileRefresh = .distantPast
                Task { await refreshUnread(afterWrite: true) }
            }
        case .signedOut: observeAccount(false)
        default: break
        }
        return result
    }

    func acknowledgedRead(_ category: InboxCategory, count: Int) async {
        unreadRevision += 1
        var counts = unread
        counts.markRead(category, count: count)
        if counts != unread { unread = counts }
        await refreshUnread(afterWrite: true)
    }

    func refreshUnread(afterWrite: Bool = false) async {
        guard !checkingUnread else {
            queuedUnreadRefresh = true
            return
        }
        checkingUnread = true
        let revision = unreadRevision
        let access = accessRevision
        defer {
            checkingUnread = false
            if queuedUnreadRefresh {
                queuedUnreadRefresh = false
                Task { await refreshUnread() }
            }
        }
        do {
            let page: ForumWebPage
            if let unreadPage {
                page = unreadPage
            } else {
                page = ForumWebPage(dataStore: dataStore)
                try await page.read(Forum.home)
                guard !page.challenged, let signedIn = try await page.signedIn() else { return }
                try Task.checkCancellation()
                guard access == accessRevision else { return }
                observeAccount(signedIn)
                guard signedIn else { return }
                unreadPage = page
            }
            let value = try await page.webView.callAsyncJavaScript(ForumAccountScript.unread,
                arguments: [:], in: nil, contentWorld: .defaultClient)
            try Task.checkCancellation()
            guard revision == unreadRevision else { return }
            if let json = value as? String {
                let counts = try JSONDecoder().decode(ForumUnreadCounts.self, from: Data(json.utf8))
                if counts != unread { unread = counts }
            } else {
                unreadPage = nil
            }
            if Date() >= nextOwnProfileRefresh { await refreshOwnProfile(using: page) }
        } catch {
            if !Task.isCancelled, access == accessRevision { unreadPage = nil }
        }
    }

    private func refreshOwnProfile(using page: ForumWebPage) async {
        let revision = accessRevision
        do {
            guard let identity = try await page.identity(), identity.signedIn, let id = identity.id,
                  !Task.isCancelled, revision == accessRevision, account == .signedIn else { return }
            observeIdentity(identity)
            let profileAccess = accessRevision
            let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.read,
                arguments: ["route": "profile", "selfID": id, "peerID": 0], in: nil, contentWorld: .defaultClient)
            guard !Task.isCancelled, profileAccess == accessRevision, account == .signedIn, let json = raw as? String else { return }
            struct Reply: Decodable { let kind: String; let data: ForumProfile? }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
            if reply.kind == "signedOut" { observeAccount(false) }
            if let profile = reply.data, profile.id == id { updateOwnProfile(profile) }
        } catch {}
    }

    func updateOwnProfile(_ profile: ForumProfile) {
        guard account == .signedIn else { return }
        confirmOwner(profile.id)
        if ownProfile != profile { ownProfile = profile }
        nextOwnProfileRefresh = Date().addingTimeInterval(180)
    }

    func introduction(for owner: Int, draft: ForumIntroduction? = nil, original: ForumIntroduction? = nil) async -> ForumIntroductionResult {
        guard account == .signedIn, ownProfile?.id == owner else { return .init(kind: .signedOut) }
        guard !savingIntroduction else { return .init(kind: .unavailable) }
        let access = accessRevision
        savingIntroduction = draft != nil
        defer { if access == accessRevision, draft != nil { savingIntroduction = false } }
        let page = ForumWebPage(dataStore: dataStore)
        do {
            try await page.read(Forum.home)
            if page.challenged { return .init(kind: .verification) }
            guard access == accessRevision, account == .signedIn, ownProfile?.id == owner else { return .init(kind: .signedOut) }
            let changes = draft.map { ["signature": $0.signature, "readme": $0.readme] as Any } ?? NSNull()
            let baseline = original.map { ["signature": $0.signature, "readme": $0.readme] as Any } ?? NSNull()
            let value = try await page.webView.callAsyncJavaScript(ForumIntroductionScript.request,
                arguments: ["owner": owner, "draft": changes, "original": baseline], in: nil, contentWorld: .page)
            guard access == accessRevision, account == .signedIn, ownProfile?.id == owner else { return .init(kind: .signedOut) }
            guard let json = value as? String else { return .init(kind: draft == nil ? .unavailable : .unknown) }
            let result = try JSONDecoder().decode(ForumIntroductionResult.self, from: Data(json.utf8))
            if (result.kind == .ready || result.kind == .saved), let data = result.data, !Task.isCancelled {
                ownIntroduction = data
                if var profile = profiles[owner] {
                    profile.readme = data.readme
                    profile.signature_markdown = data.signature
                    profileStore.update(profile)
                }
            }
            return result
        } catch { return .init(kind: draft == nil ? .unavailable : .unknown) }
    }

    func rememberConversationContacts(_ contacts: [ForumConversationContact], for member: Int) {
        guard account == .signedIn, ownProfile?.id == nil || ownProfile?.id == member else { return }
        let key = "forum.conversationContacts.\(member)"
        if conversationContactOwner != member {
            conversationContactOwner = member
            conversationContacts = defaults.data(forKey: key).flatMap {
                try? JSONDecoder().decode([ForumConversationContact].self, from: $0)
            } ?? []
        }
        let known = Dictionary(conversationContacts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        let updated = Array((contacts + conversationContacts).compactMap { contact -> ForumConversationContact? in
            guard contact.id != member, seen.insert(contact.id).inserted else { return nil }
            return ForumConversationContact(id: contact.id, name: contact.name.isEmpty ? known[contact.id] ?? "" : contact.name)
        }.prefix(500))
        guard updated != conversationContacts else { return }
        conversationContacts = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: key) }
    }

    private func clearConversationContacts() {
        conversationContactOwner = nil
        conversationContacts = []
    }

    func attend(member: Int, mode: ForumAttendanceMode, authorized: () -> Bool) async -> ForumAttendanceResult? {
        let revision = accessRevision
        let page = ForumWebPage(dataStore: dataStore)
        do {
            try await page.read(Forum.home)
            if page.challenged { return ForumAttendanceResult(kind: .verification) }
            guard let identity = try await page.identity() else {
                if page.webView.url?.path == Forum.signIn.path { return ForumAttendanceResult(kind: .signedOut) }
                return ForumAttendanceResult(kind: .failed)
            }
            guard !Task.isCancelled, revision == accessRevision, authorized() else { return nil }
            guard identity.signedIn else {
                observeAccount(false)
                return ForumAttendanceResult(kind: .signedOut)
            }
            guard identity.id == member, ownProfile?.id == member else {
                unreadPage = nil
                nextOwnProfileRefresh = .distantPast
                return nil
            }
            let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.attendance,
                arguments: ["randomMode": mode == .random], in: nil, contentWorld: .defaultClient)
            guard let json = raw as? String else { return ForumAttendanceResult(kind: .failed) }
            let result = try JSONDecoder().decode(ForumAttendanceResult.self, from: Data(json.utf8))
            if revision == accessRevision, result.done {
                if let current = result.current, var profile = ownProfile, profile.id == member, profile.coin != current {
                    profile.coin = current
                    ownProfile = profile
                }
                nextOwnProfileRefresh = .distantPast
                Task { await refreshUnread(afterWrite: true) }
            } else if revision == accessRevision, result.kind == .signedOut {
                observeAccount(false)
            }
            return result
        } catch {
            if Task.isCancelled { return nil }
            return ForumAttendanceResult(kind: (error as? ForumPageError) == .verification ? .verification : .failed)
        }
    }

    func loadProfile(_ id: Int, using existingPage: ForumWebPage? = nil, includeReadme: Bool = false,
                     force: Bool = false) async {
        let revision = accessRevision
        func loaded() -> Bool {
            guard let date = profileUpdated[id], profileNow().timeIntervalSince(date) < profileLifetime else { return false }
            return profiles[id].map { !includeReadme || $0.readme != nil } ?? false
        }
        guard force || !loaded() else { return }
        while profileRequests.count >= 3 || profileRequests[id] != nil {
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard revision == accessRevision else { return }
            if loaded() { return }
        }
        guard !Task.isCancelled, revision == accessRevision else { return }
        let request = UUID()
        profileRequests[id] = request
        profileRequestState.begin(id)
        defer {
            if profileRequests[id] == request {
                profileRequests[id] = nil
                profileRequestState.finish(id)
            }
        }
        do {
            let page: ForumWebPage
            if let existingPage { page = existingPage }
            else {
                page = ForumWebPage(dataStore: dataStore)
                try await page.read(Forum.home)
            }
            guard revision == accessRevision, !Task.isCancelled else { return }
            let value = try await requests.profile(page, id, includeReadme)
            try Task.checkCancellation()
            guard revision == accessRevision else { return }
            guard let json = value else { throw ForumPageError.network }
            var profile = try JSONDecoder().decode(ForumUserProfile.self, from: Data(json.utf8))
            guard profile.member_id == id else { throw ForumPageError.changed }
            if includeReadme && profile.readme == nil { profile.readme = "" }
            if !includeReadme, profile.readme == nil { profile.readme = profiles[id]?.readme }
            if id == ownProfile?.id, let ownIntroduction {
                profile.readme = ownIntroduction.readme
                profile.signature_markdown = ownIntroduction.signature
            }
            if profiles.count >= 240, profiles[id] == nil,
               let oldest = profileUpdated.min(by: { $0.value < $1.value })?.key {
                profileStore.remove(oldest)
                profileUpdated[oldest] = nil
            }
            profileStore.update(profile)
            profileUpdated[id] = profileNow()
        } catch {
            if !Task.isCancelled, revision == accessRevision { profileRequestState.fail(id) }
        }
    }

    func finishAccess(_ signedIn: Bool?) {
        if let signedIn { observeAccount(signedIn) }
        let returnTo = access?.returnTo
        invalidateAccess()
        switch returnTo {
        case .profile: presentation = .profile
        case .compose: presentation = .compose
        case nil: presentation = nil
        }
    }

    func edit(_ draft: String, for id: String) {
        guard canCompose, drafts[id, default: ""] != draft else { return }
        if draft.isEmpty { drafts.removeValue(forKey: id) }
        else { drafts[id] = draft }
        persistDrafts()
    }

    func rememberTitle(_ title: String, for id: String) {
        rememberTitle(title, for: id, authorization: authorization)
    }

    /// Allocate when the transport actually begins, never when its response
    /// arrives. The counter stays monotonic across identity revisions.
    func beginTitleRead() -> TitleRead {
        titleSequence += 1
        return TitleRead(authorization: authorization, sequence: titleSequence)
    }

    /// Synchronous confirmed writes (including a successful inline edit) are
    /// newer than every read begun before this acknowledgement.
    func rememberTitle(_ title: String, for id: String, authorization token: Authorization) {
        guard !titleStorageClosed, token == authorization else { return }
        rememberTitle(title, for: id, request: beginTitleRead())
    }

    func rememberCachedTitle(_ title: String, for id: String) {
        guard titles[id] == nil else { return }
        rememberTitle(title, for: id, request: TitleRead(authorization: authorization, sequence: 0))
    }

    func rememberTitle(_ title: String, for id: String, request: TitleRead) {
        let token = request.authorization
        guard !titleStorageClosed, token == authorization,
              let title = ForumTitleStore.validTitle(title, id: id) else { return }
        if canCompose, let owner = token.owner {
            titleStore.record([.init(id: id, title: title, source: .reader)], owner: owner,
                              sequence: request.sequence, preserving: retainedTitleIDs?() ?? [])
            replaceTitles(titleStore.titles(for: owner))
        } else {
            // A public read may still name its tab while signed out. These
            // labels stay in memory and never acquire a guessed account owner.
            guard request.sequence >= publicTitleSequences[id, default: 0] else { return }
            var current = titles
            if current[id] == nil, current.count >= ForumTitleStore.maximumTitles,
               let oldest = current.keys.sorted().first { current.removeValue(forKey: oldest) }
            current[id] = title
            publicTitleSequences[id] = request.sequence
            publicTitleSequences = publicTitleSequences.filter { current[$0.key] != nil }
            replaceTitles(current)
        }
    }

    func rememberListingTitles(_ posts: [FeedPost], request: TitleRead, feed: Bool = false) {
        let token = request.authorization
        guard !titleStorageClosed, authorizes(token), let owner = token.owner else { return }
        let entries = posts.compactMap { post -> ForumTitleStore.Entry? in
            guard Forum.topicID(post.url) == post.id else { return nil }
            return .init(id: post.id, title: post.title, source: feed ? .feed : .listing)
        }
        titleStore.record(entries, owner: owner, sequence: request.sequence, preserving: retainedTitleIDs?() ?? [])
        replaceTitles(titleStore.titles(for: owner))
    }

    private func replaceTitles(_ value: [String: String]) {
        guard titles != value else { return }
        titles = value
        titlesDidChange?()
    }

    /// The production shutdown path persists account data before revoking
    /// request tokens. Revocation only clears visible titles, not owner caches.
    func prepareForShutdown() {
        guard !titleStorageClosed else { return }
        titleStorageClosed = true
        titleStore.flush()
        let previous = authorization
        observeAccount(false)
        // Even an already signed-out session can own read-only requests.
        // Retire their revision as well; the operation remains idempotent.
        if authorization == previous { invalidateAccess() }
    }

    func clearReceipt(_ id: String) { receipts.removeValue(forKey: id) }

    func consumeReplyNavigation(_ id: String) -> Bool { pendingReplyNavigation.remove(id) != nil }

    func imageSizing(for scope: DraftScope) -> DraftImageSizing {
        if let sizing = draftImages[scope] { return sizing }
        let sizing = DraftImageSizing()
        sizing.didChange = { [weak self] in self?.persistDrafts() }
        draftImages[scope] = sizing
        return sizing
    }

    func ownsImageSizing(_ sizing: DraftImageSizing, for scope: DraftScope) -> Bool {
        draftImages[scope] === sizing
    }

    /// Changes, including A → B → A, retire an in-flight send's clear intent.
    /// Revisions are session-local; persisted content/mode remain per owner.
    func messageDraftRevision(for peer: Int) -> UInt64 { messageDraftRevisions[peer, default: 0] }

    private func changedMessageDrafts(_ peers: Set<Int>) {
        guard !restoringDrafts else { return }
        for peer in peers { messageDraftRevisions[peer, default: 0] &+= 1 }
    }

    @discardableResult
    func send(topic: Topic, on page: ForumWebPage) -> Task<Void, Never>? {
        guard let original = drafts[topic.id], !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let postID = Int(topic.id), canCompose, !sending.contains(topic.id) else { return nil }
        let sizing = imageSizing(for: .reply(topic.id))
        let originalSizes = sizing.sizes
        let token = authorization
        sending.insert(topic.id)
        clearReceipt(topic.id)
        return Task { [self, page] in
            defer { if token == authorization { sending.remove(topic.id) } }
            let isCurrent: DraftImageSizing.Authorization = { [self] in
                authorizes(token) && sending.contains(topic.id) && ownsImageSizing(sizing, for: .reply(topic.id))
            }
            let content: String
            do { content = try await sizing.prepare(original, authorized: isCurrent) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, isCurrent() else { return }
                receipts[topic.id] = Receipt(message: (error as? NodeImageError ?? .connection).localizedDescription + " 草稿已保留。")
                return
            }
            guard !Task.isCancelled, isCurrent() else { return }
            let result: ReplyEnvelope?
            do {
                let value = try await requests.reply(page, postID, content)
                result = value.flatMap { try? JSONDecoder().decode(ReplyEnvelope.self, from: Data($0.utf8)) }
            } catch { result = nil }
            guard authorizes(token) else { return }
            switch result?.kind {
            case "response" where result?.response != nil:
                guard let response = result?.response else { return }
                if response.success {
                    let destination: URL?
                    if response.redirect?.isEmpty != false, response.redirectHash != nil {
                        let floorsPerPage = (try? await page.identity())?.floorsPerPage ?? 10
                        destination = response.destination(from: topic.url, floorsPerPage: floorsPerPage)
                    } else {
                        destination = response.destination(from: topic.url)
                    }
                    guard authorizes(token) else { return }
                    if drafts[topic.id] == original, sizing.sizes == originalSizes {
                        edit("", for: topic.id)
                        sizing.reset()
                    }
                    invalidateThread(topic.id)
                    pendingReplyNavigation.insert(topic.id)
                    receipts[topic.id] = Receipt(message: "回复已发送", destination: destination, accepted: true)
                } else {
                    let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    receipts[topic.id] = Receipt(message: message.isEmpty ? "NodeSeek 没有接受这条回复，草稿已保留。" : message)
                }
            case "verification":
                receipts[topic.id] = Receipt(message: "请先完成 NodeSeek 站点验证。草稿已保留。", verify: true)
            case "signIn":
                observeAccount(false)
                receipts[topic.id] = Receipt(message: "登录已失效，请重新登录。草稿已保留。")
            case "forbidden":
                receipts[topic.id] = Receipt(message: "NodeSeek 拒绝了回复。请检查账号权限或登录状态，草稿已保留。")
            case "unavailable":
                receipts[topic.id] = Receipt(message: "帖子未就绪。请刷新后再回复，草稿已保留。")
            default:
                receipts[topic.id] = Receipt(message: "未收到发送结果。请刷新确认楼层是否出现，再决定是否重发。草稿已保留。")
            }
        }
    }
}

private struct ReplyEnvelope: Decodable {
    let kind: String
    let response: ForumReplyResponse?
}

@MainActor
final class ForumReaderState: ObservableObject {
    enum Phase {
        case loading, ready(ForumThread), failed(ForumPageError)
    }
    @Published private(set) var phase: Phase {
        didSet {
            floorIDs = Self.floorIDs(in: phase)
            if case .ready(let thread) = phase { preparesWholePage = ReaderLayoutPolicy.preparesWholePage(thread) }
            else { preparesWholePage = false }
        }
    }
    private(set) var floorIDs: Set<String>
    private(set) var preparesWholePage: Bool
    @Published private(set) var isLoading = true
    @Published private(set) var refreshIssue: ForumPageError?
    @Published private(set) var pageReady = false
    private(set) var page: ForumWebPage? {
        didSet { if pageReady != (page != nil) { pageReady = page != nil } }
    }
    struct ProfileTaskKey: Equatable { let authorID: Int?; let pageReady: Bool }
    func profileTaskKey(for id: Int?) -> ProfileTaskKey { ProfileTaskKey(authorID: id, pageReady: pageReady) }
    private var visibleURL: URL?
    private var latest: UUID?
    typealias Fetch = (URL, ForumSession) async throws -> (ForumThread, ForumWebPage)
    private var fetchTask: Task<(ForumThread, ForumWebPage, ForumSession.TitleRead), Error>?
    private var pageRevision: UUID?
    private var pageUpdated: Date?
    private var accessObserver: AnyCancellable?
    private let startedWithCachedThread: Bool

    init(topic: Topic, session: ForumSession) {
        visibleURL = Forum.pageURL(topic.url)
        let cached = session.cachedThread(at: topic.url)
        startedWithCachedThread = cached != nil
        phase = cached.map(Phase.ready) ?? .loading
        floorIDs = Self.floorIDs(in: cached.map(Phase.ready) ?? .loading)
        preparesWholePage = cached.map(ReaderLayoutPolicy.preparesWholePage) ?? false
        isLoading = cached == nil
        accessObserver = session.$accessRevision.dropFirst().sink { [weak self] _ in
            self?.fetchTask?.cancel()
            self?.fetchTask = nil
            self?.latest = nil
            self?.phase = .loading
            self?.page = nil
            self?.refreshIssue = nil
            self?.isLoading = false
        }
    }

    private static func floorIDs(in phase: Phase) -> Set<String> {
        guard case .ready(let thread) = phase else { return [] }
        return Set(thread.replies.map(\.readerID) + (thread.root == nil ? [] : ["floor-0"]))
    }

    func initialRefreshDelay(returningToPosition: Bool) -> Duration {
        startedWithCachedThread && returningToPosition ? .milliseconds(350) : .milliseconds(100)
    }

    static func canPresentFromTop(_ cached: ForumThread?, at url: URL, anchor: String?) -> Bool {
        cached?.page == 1 && url.fragment == nil && (anchor == nil || anchor == "thread-title")
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        latest = nil
        page?.webView.stopLoading()
        page = nil
        isLoading = false
    }

    @discardableResult
    func load(_ topic: Topic, session: ForumSession, force: Bool = false,
              fetch: Fetch? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        let url = Forum.pageURL(topic.url)
        // A delayed ordinary appearance must not cancel a page being prepared
        // for an explicit interaction, nor turn its busy feedback off.
        if !force, session.threadIsFresh(at: url), let cached = session.cachedThread(at: url) {
            if visibleURL == url, isLoading { return false }
            if visibleURL != url { cancel(); visibleURL = url }
            if case .ready(let existing) = phase, existing == cached {} else { phase = .ready(cached) }
            isLoading = false
            refreshIssue = nil
            session.rememberCachedTitle(cached.title, for: topic.id)
            return true
        }
        fetchTask?.cancel()
        fetchTask = nil
        let request = UUID()
        latest = request
        if visibleURL != url {
            phase = session.cachedThread(at: url).map(Phase.ready) ?? .loading
            visibleURL = url
            page = nil
        } else if case .failed = phase { phase = .loading }
        isLoading = true
        refreshIssue = nil
        defer {
            if latest == request {
                isLoading = false
                fetchTask = nil
            }
        }
        let access = session.accessRevision
        let revision = session.threadRevision(topic.id)
        let operation = Task { @MainActor in
            let titleRead = session.beginTitleRead()
            let result: (ForumThread, ForumWebPage)
            if let fetch { result = try await fetch(url, session) }
            else { result = try await Self.fetch(url, session: session) }
            return (result.0, result.1, titleRead)
        }
        fetchTask = operation
        do {
            let (thread, loader, titleRead) = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard latest == request, !Task.isCancelled, !operation.isCancelled,
                  access == session.accessRevision else { return false }
            guard revision == session.threadRevision(topic.id) else {
                settleInvalidatedRead()
                return false
            }
            page = loader
            pageRevision = revision
            pageUpdated = session.threadReadTime
            session.cacheThread(thread, at: url)
            session.rememberTitle(thread.title, for: topic.id, request: titleRead)
            if case .ready(let existing) = phase, existing == thread { return true }
            phase = .ready(thread)
            return true
        } catch {
            guard !Task.isCancelled, !operation.isCancelled, latest == request,
                  access == session.accessRevision else { return false }
            guard revision == session.threadRevision(topic.id) else {
                settleInvalidatedRead()
                return false
            }
            let issue = error as? ForumPageError ?? .network
            pageUpdated = nil
            if case .ready = phase, issue == .network || issue == .timedOut || issue == .changed { refreshIssue = issue }
            else {
                if issue == .missing || issue == .signInRequired || issue == .verification { session.invalidateThread(topic.id) }
                page = nil
                phase = .failed(issue)
            }
            return false
        }
    }

    /// Cache-only revisits do not retain WebKit. Prepare one page only when an
    /// actual interaction needs its authenticated script context.
    func preparePage(_ topic: Topic, session: ForumSession, force: Bool = false, fetch: Fetch? = nil) async -> ForumWebPage? {
        guard !Task.isCancelled, !isLoading else { return nil }
        if !force, let page, visibleURL == Forum.pageURL(topic.url),
           refreshIssue == nil, pageRevision == session.threadRevision(topic.id),
           session.threadIsFresh(since: pageUpdated) { return page }
        let access = session.accessRevision
        let loaded = await load(topic, session: session, force: true, fetch: fetch)
        guard loaded, !Task.isCancelled, access == session.accessRevision, !isLoading,
              refreshIssue == nil, pageRevision == session.threadRevision(topic.id),
              session.threadIsFresh(since: pageUpdated) else { return nil }
        return page
    }

    private func settleInvalidatedRead() {
        page = nil
        pageUpdated = nil
        if case .ready = phase { refreshIssue = .changed }
        else { phase = .failed(.changed) }
    }

    static func fetch(_ url: URL, floor: String? = nil, session: ForumSession) async throws -> (ForumThread, ForumWebPage) {
        let revision = session.accessRevision
        let loader = ForumWebPage(dataStore: session.dataStore, captureTerminals: true)
        guard let id = Forum.topicID(url) else { throw ForumPageError.missing }
        try await loader.read(Forum.pageURL(url))
        // A challenge can complete with a new navigation after its initial HTML finishes.
        var signedIn = try await loader.signedIn()
        if loader.challenged && signedIn == nil {
            for _ in 0..<3 {
                try await Task.sleep(for: .seconds(1))
                signedIn = try await loader.signedIn()
                if signedIn != nil { break }
            }
        }
        try Task.checkCancellation()
        guard revision == session.accessRevision else { throw CancellationError() }
        if let identity = try await loader.identity() {
            guard revision == session.accessRevision else { throw CancellationError() }
            session.observeIdentity(identity)
        } else if let signedIn { session.observeAccount(signedIn) }
        if loader.challenged && signedIn == nil { throw ForumPageError.verification }
        if let status = loader.status, status == 404 || status == 410 { throw ForumPageError.missing }
        guard let actual = loader.webView.url, Forum.topicID(actual) == id else {
            if signedIn == false || loader.webView.url?.path == Forum.signIn.path { throw ForumPageError.signInRequired }
            throw ForumPageError.missing
        }
        if loader.status == 401 { throw ForumPageError.signInRequired }
        if loader.status == 403 { throw signedIn == false ? ForumPageError.signInRequired : ForumPageError.missing }
        try Task.checkCancellation()
        guard revision == session.accessRevision else { throw CancellationError() }
        let sourceURL = Forum.pageURL(actual)
        // NodeSeek keeps the complete ANSI fences in its own page-world config
        // even when an inactive xterm viewport has never painted. Read only a
        // bounded terminal DTO; keep account data out of the reader world.
        let terminalSources = (try? await loader.webView.callAsyncJavaScript(ForumPageScript.terminalMarkdown,
            arguments: ["expectedURL": sourceURL.absoluteString, "onlyFloor": floor ?? ""],
            in: nil, contentWorld: .page)) as? String ?? ""
        try Task.checkCancellation()
        guard revision == session.accessRevision else { throw CancellationError() }
        guard loader.webView.url.map(Forum.pageURL) == sourceURL else { throw ForumPageError.changed }
        let result = try await loader.webView.callAsyncJavaScript(ForumPageScript.extract,
            arguments: ["onlyFloor": floor ?? "", "terminalSources": terminalSources], in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard revision == session.accessRevision else { throw CancellationError() }
        guard loader.webView.url.map(Forum.pageURL) == sourceURL else { throw ForumPageError.changed }
        guard let json = result as? String else { throw ForumPageError.changed }
        let thread: ForumThread
        do { thread = try await ForumThreadDecoding.decode(json) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if json == #"{"error":"missing"}"# {
                throw signedIn == false ? ForumPageError.signInRequired : ForumPageError.missing
            }
            throw ForumPageError.changed
        }
        try Task.checkCancellation()
        guard revision == session.accessRevision else { throw CancellationError() }
        guard loader.webView.url.map(Forum.pageURL) == sourceURL else { throw ForumPageError.changed }
        // The native reader already has the document; stop hidden subresource loads.
        loader.webView.stopLoading()
        return (thread, loader)
    }
}

/// A deterministic retention budget for parsed value types, not a process-RSS
/// measurement. Include string storage and per-element overhead; stop counting
/// once the cache budget is exceeded rather than traversing an oversized report.
enum ForumThreadCacheCost {
    static let limit = 16 * 1024 * 1024

    static func estimate(_ thread: ForumThread) -> Int {
        var remaining = limit + 1
        func add(_ value: Int) { remaining -= min(remaining, value) }
        func text(_ value: String?) {
            guard let value, remaining > 0 else { return }
            add(64)
            add(min(limit + 1, value.utf8.count) * 2)
        }
        func blocks(_ items: [ForumBlock]) {
            for block in items {
                guard remaining > 0 else { return }
                add(192)
                text(block.kind); text(block.text); text(block.url?.absoluteString); text(block.language)
                for row in block.rows ?? [] {
                    add(32)
                    for cell in row {
                        text(cell)
                        if remaining == 0 { return }
                    }
                    if remaining == 0 { return }
                }
                for line in block.terminal ?? [] {
                    add(32)
                    for span in line {
                        add(96)
                        text(span.text); text(span.foreground); text(span.background)
                        if remaining == 0 { return }
                    }
                }
                for tab in block.tabs ?? [] {
                    add(64); text(tab.label); blocks(tab.blocks)
                    if remaining == 0 { return }
                }
                for item in block.items ?? [] {
                    add(64); text(item.marker); blocks(item.blocks)
                    if remaining == 0 { return }
                }
            }
        }
        func floor(_ item: ForumFloor) {
            add(256)
            text(item.id); text(item.author); text(item.avatar?.absoluteString)
            text(item.date); text(item.dateLabel); text(item.signature)
            for tag in item.tags ?? [] { text(tag) }
            blocks(item.blocks)
        }
        add(256)
        text(thread.title); text(thread.category); text(thread.replyRestriction)
        if let root = thread.root { floor(root) }
        for reply in thread.replies {
            guard remaining > 0 else { break }
            floor(reply)
        }
        for page in thread.pages {
            guard remaining > 0 else { break }
            add(32); text(page.url.absoluteString)
        }
        return limit + 1 - remaining
    }
}

enum ForumThreadDecoding {
    static func decode(_ json: String) async throws -> ForumThread {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let thread = try JSONDecoder().decode(ForumThread.self, from: Data(json.utf8))
            try Task.checkCancellation()
            return thread
        }
        return try await withTaskCancellationHandler {
            let thread = try await work.value
            try Task.checkCancellation()
            return thread
        } onCancel: {
            work.cancel()
        }
    }
}

@MainActor
final class ForumWebPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var documentProbe: Task<Void, Never>?
    private var expected: WKNavigation?
    private var readID: UUID?
    private(set) var status: Int?
    private(set) var challenged = false
    var didSettle: (() -> Void)?
    var didClose: (() -> Void)?
    var openTopic: ((URL) -> Bool)?

    init(dataStore: WKWebsiteDataStore, captureTerminals: Bool = false) {
        let configuration = WKWebViewConfiguration()
        DeskProxyWebKit.configure(dataStore)
        configuration.websiteDataStore = dataStore
        if captureTerminals {
            configuration.userContentController.addUserScript(WKUserScript(source: ForumPageScript.captureTerminals,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 940, height: 700), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        DeskProxyWebKit.register(webView)
    }

    func read(_ url: URL) async throws {
        guard Forum.contains(url) else { throw ForumPageError.missing }
        if continuation != nil { finish(.failure(CancellationError())); webView.stopLoading() }
        let requestID = UUID()
        readID = requestID
        status = nil
        challenged = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { waiter.resume(throwing: CancellationError()); return }
                continuation = waiter
                expected = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(26))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ForumPageError.timedOut))
                    self?.webView.stopLoading()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.readID == requestID else { return }
                self?.finish(.failure(CancellationError()))
                self?.webView.stopLoading()
            }
        }
    }

    func signedIn() async throws -> Bool? {
        guard let url = webView.url, Forum.contains(url) else { return nil }
        let result = try await webView.callAsyncJavaScript(#"""
            if (window.__config__ && document.querySelector('#nsk-head')) return Boolean(window.__config__.user);
            if (location.pathname === '/signIn.html' && document.querySelector('input[type=password]')) return false;
            return null;
            """#, arguments: [:], in: nil, contentWorld: .page)
        return result as? Bool
    }

    func identity() async throws -> ForumIdentity? {
        guard let url = webView.url, Forum.contains(url) else { return nil }
        let raw = try await webView.callAsyncJavaScript(ForumAccountScript.identity, arguments: [:], in: nil, contentWorld: .page)
        guard let json = raw as? String else { return nil }
        return try JSONDecoder().decode(ForumIdentity.self, from: Data(json.utf8))
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        documentProbe?.cancel()
        documentProbe = nil
        expected = nil
        readID = nil
        let waiter = continuation
        continuation = nil
        waiter?.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        guard let url = action.request.url, Forum.contains(url) else { decisionHandler(.cancel); return }
        if (action.navigationType == .linkActivated || action.targetFrame == nil),
           Forum.topicID(url) != nil, openTopic?(url) == true { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            if didSettle != nil { webView.load(action.request) }
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
            status = http.statusCode
            challenged = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
        }
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard continuation != nil, !challenged else { return }
        documentProbe?.cancel()
        documentProbe = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.continuation != nil, let url = self.webView.url, Forum.contains(url) else { return }
                let ready = try? await self.webView.callAsyncJavaScript(
                    "return document.readyState !== 'loading' && Boolean(document.querySelector('#nsk-head'));",
                    arguments: [:], in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled else { return }
                if (ready as? Bool) == true { self.finish(.success(())); return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if continuation != nil, navigation === expected { finish(.success(())) }
        didSettle?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation, error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(ForumPageError.network)) }
    func webViewDidClose(_ webView: WKWebView) { didClose?() }

    private func fail(_ navigation: WKNavigation?, _ error: Error) {
        guard navigation === expected, continuation != nil else { return }
        if challenged { finish(.failure(ForumPageError.verification)) }
        else if (error as NSError).code == NSURLErrorTimedOut { finish(.failure(ForumPageError.timedOut)) }
        else { finish(.failure(ForumPageError.network)) }
    }
}

struct ForumAccessSheet: View {
    let request: ForumSession.Access
    @ObservedObject var session: ForumSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                DeskIcon(request.verification ? "checkmark.shield" : "person.crop.circle.badge.checkmark")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.verification ? "验证 NodeSeek 访问" : "登录 NodeSeek").font(.headline)
                    Text("www.nodeseek.com · 官方页面").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { session.finishAccess(nil) }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DeskButtonStyle())
            }
            .padding(15)
            .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: Color(nsColor: .windowBackgroundColor))
            .padding(10)
            ForumAccessWebView(request: request, session: session)
        }
        .frame(idealWidth: 710, idealHeight: 590)
        .frame(width: 710, height: 590)
    }
}

private struct ForumAccessWebView: NSViewRepresentable {
    let request: ForumSession.Access
    let session: ForumSession

    @MainActor final class Coordinator {
        var page: ForumWebPage?
        var monitor: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let page = ForumWebPage(dataStore: session.dataStore)
        let coordinator = context.coordinator
        coordinator.page = page
        let accessID = request.id
        let forVerification = request.verification
        let target = request.url
        let session = self.session
        page.didClose = { [weak page] in
            guard let page else { return }
            page.webView.load(URLRequest(url: Forum.home, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        let check = { @MainActor [weak session, weak page] in
            guard let page, let session, session.access?.id == accessID,
                  let actual = page.webView.url, Forum.contains(actual),
                  let signedIn = try? await page.signedIn(), session.access?.id == accessID else { return }
            if signedIn || (forVerification && (Forum.topicID(actual) == Forum.topicID(target) || actual.path == Forum.signIn.path)) {
                session.finishAccess(signedIn)
            }
        }
        page.didSettle = { Task { await check() } }
        coordinator.monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, session.access?.id == accessID else { break }
                if !page.webView.isLoading { await check() }
            }
        }
        page.webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
        return page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.monitor?.cancel()
        webView.stopLoading()
        coordinator.page = nil
    }
}
