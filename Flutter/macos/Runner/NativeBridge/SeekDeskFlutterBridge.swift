import AppKit
import Combine
import CoreFoundation
import FlutterMacOS
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct NativeBridgeError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

enum NativeDTO {
    static func encode<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return NSNull() }
        return object
    }
    static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func url(_ args: [String: Any], key: String = "url", forumOnly: Bool = false) throws -> URL {
        guard let raw = args[key] as? String, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              !forumOnly || Forum.contains(url) else {
            throw NativeBridgeError(code: "invalid_url", message: "链接无效。")
        }
        return url
    }
    static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else {
            throw NativeBridgeError(code: "invalid_arguments", message: "缺少参数：\(key)")
        }
        return value
    }
    static func integer(_ args: [String: Any], _ key: String) throws -> Int {
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) < 9_007_199_254_740_991 else {
            throw NativeBridgeError(code: "invalid_arguments", message: "参数必须是整数：\(key)")
        }
        return number.intValue
    }
}

@MainActor
final class SeekDeskBridgeContext {
    let defaults: UserDefaults
    let workspace: Workspace
    let session: ForumSession
    let extensions: DeskExtensions
    let proxy: DeskProxyController
    var event: ((String, Any) -> Void)?
    var accessChanged: (() -> Void)?
    private var listingRecovery: NativeListingRecovery?
    private var shuttingDown = false

    init(defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore? = nil,
         sessionRequests: ForumSession.Requests? = nil,
         proxy: DeskProxyController? = nil,
         fetchFeed: @escaping () async throws -> [FeedPost] = ForumFeed.fetch,
         fetchPage: @escaping (URL) async throws -> ForumListingPage = ForumListing.fetch,
         fetchPeople: @escaping (String) async throws -> [ForumUserReference] = ForumDirectory.people) {
        self.defaults = defaults
        ForumReportSizing.migratePreferences(in: defaults)
        self.proxy = proxy ?? .shared
        let activeSession = ForumSession(defaults: defaults, dataStore: dataStore, requests: sessionRequests)
        session = activeSession
        workspace = Workspace(defaults: defaults, fetchFeed: { [weak activeSession] in
            let request = activeSession?.beginTitleRead()
            let posts = try await fetchFeed()
            try Task.checkCancellation()
            if let request { activeSession?.rememberListingTitles(posts, request: request, feed: true) }
            return posts
        }, fetchPage: { [weak activeSession] url in
            let request = activeSession?.beginTitleRead()
            let page = try await fetchPage(url)
            try Task.checkCancellation()
            if let request { activeSession?.rememberListingTitles(page.posts, request: request) }
            return page
        }, fetchPeople: fetchPeople)
        extensions = DeskExtensions(defaults: defaults)
        session.retainedTitleIDs = { [weak self] in
            guard let self else { return [] }
            return Set(self.workspace.session.topics.map(\.id) + self.workspace.session.closedTopics.map(\.id))
        }
        session.titlesDidChange = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            // Restoration must reach Flutter even in overview, where no reader
            // request will otherwise produce a new workspace event.
            self.emit(domain: "workspace", data: self.workspaceSnapshot())
        }
        session.accessDidChange = { [weak self] in
            guard let self else { return }
            self.workspace.invalidateForumAccess()
            self.accessChanged?()
            self.listingRecovery?.invalidate()
        }
    }

    /// The Flutter host has no WorkspaceView task keyed by accessRevision.
    /// Arm recovery before the initial listing can overlap a reader's identity
    /// discovery; subsequent unread/profile confirmation uses the same hook.
    func bootstrapListing() async {
        guard !Task.isCancelled else { return }
        if listingRecovery == nil {
            listingRecovery = NativeListingRecovery(workspace: workspace, session: session)
        }
        await workspace.refresh()
    }

    func stopListingRecovery() {
        listingRecovery?.dispose()
        listingRecovery = nil
    }

    /// Shared by the real bridge and memory-only startup/shutdown regressions.
    func prepareForShutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        stopListingRecovery()
        session.readingProgress.flush()
        session.prepareForShutdown()
    }

    func emit(domain: String, data: Any) { event?(domain, data) }

    func requireAuthorization(_ args: [String: Any], signedIn: Bool = true) throws -> ForumSession.Authorization {
        guard let revision = args["accessRevision"] as? Int, revision == session.accessRevision,
              !signedIn || session.canCompose else {
            throw NativeBridgeError(code: "stale_authorization", message: "账号状态已变化，请刷新后重试。草稿仍按账号保留。")
        }
        return session.authorization
    }

    func selectBoard(_ id: String) async throws -> [String: Any] {
        guard let board = ([Board.home, Board.award] + Board.sections).first(where: { $0.id == id }) else {
            throw NativeBridgeError(code: "invalid_board", message: "版块不存在。")
        }
        workspace.choose(board)
        await workspace.refresh()
        return workspaceSnapshot()
    }

    func search(query: String, scope: Set<String>, kind: Workspace.SearchKind) async -> [String: Any] {
        workspace.searchText = query
        workspace.searchScope = scope
        workspace.searchKind = kind
        let navigationRevision = workspace.readerNavigationRevision
        workspace.search()
        // The Flutter host does not run WorkspaceView's searchRevision task.
        // A topic URL only changes reader navigation and must not refresh the
        // search or board retained underneath the newly opened reader.
        if workspace.readerNavigationRevision == navigationRevision {
            if workspace.isSearchingForum || !workspace.hasForumPage {
                await workspace.refresh()
            }
        }
        return workspaceSnapshot()
    }

    func clearSearch() async -> [String: Any] {
        workspace.clearSearch()
        // Restore a cached listing immediately. A search can change the board
        // without loading its listing, so read only when that cache is absent.
        if !workspace.hasForumPage { await workspace.refresh() }
        return workspaceSnapshot()
    }

    func workspaceSnapshot() -> [String: Any] {
        let tabs = workspace.session.topics.map { topic in
            topicSnapshot(topic)
        }
        let posts = workspace.filteredPosts.filter { !extensions.blocks($0.authorID, name: $0.author) }.map { item -> [String: Any] in
            var result = NativeDTO.encode(item) as? [String: Any] ?? [:]
            result["avatar"] = NativeDTO.optional(item.avatarURL?.absoluteString)
            result["categoryLabel"] = Board.title(for: item.category)
            result["normalizedAuthor"] = ForumSearch.normalized(item.author)
            return result
        }
        return ["posts": posts, "tabs": tabs,
                "closedTabs": workspace.session.closedTopics.map { topicSnapshot($0.topic) },
                "selectedTab": NativeDTO.optional(workspace.session.selection),
                "showReader": workspace.showReader,
                "board": workspace.board.id, "boardURL": workspace.board.url.absoluteString,
                "boardCategoryID": NativeDTO.optional(workspace.board.categoryID),
                "boards": ([Board.home] + Board.sections).map {
                    ["id": $0.id, "title": $0.title, "icon": $0.icon,
                     "searchable": Board.searchableIDs.contains($0.id)] as [String: Any]
                },
                "loading": workspace.isLoading, "canLoadOlder": workspace.hasOlderPosts,
                "hasForumPage": workspace.hasForumPage,
                "failedToRefresh": workspace.failedToRefresh,
                "failedToLoadOlder": workspace.failedToLoadOlder,
                "error": NativeDTO.optional(workspace.listingIssue?.message()),
                "errorCode": NativeDTO.optional(workspace.listingIssue?.rawValue),
                "peopleLoading": workspace.peopleBusy,
                "peopleError": NativeDTO.optional(workspace.peopleError?.message(people: true)),
                "peopleErrorCode": NativeDTO.optional(workspace.peopleError?.rawValue),
                "showsPeopleResults": workspace.showsPeopleResults,
                "query": workspace.query, "feedOrder": workspace.feedOrder.rawValue,
                "appliedSearchScope": workspace.appliedSearchScope.sorted(),
                "appliedSearchKind": workspace.appliedSearchKind.rawValue,
                "lastRefresh": NativeDTO.optional(workspace.lastRefresh.map { $0.timeIntervalSince1970 * 1000 }),
                "people": workspace.searchPeople.map { ["id": $0.id, "name": $0.name, "avatar": NativeDTO.optional($0.avatar?.absoluteString)] },
                "searchHistory": workspace.searchHistory.map { ["query": $0.query, "scope": Array($0.scope), "kind": $0.kind.rawValue] }]
    }

    private func topicSnapshot(_ topic: Topic) -> [String: Any] {
        var value: [String: Any] = ["id": topic.id, "url": topic.url.absoluteString,
                                   "title": session.titles[topic.id] ?? topic.label]
        if let preview = topic.preview {
            value.merge(["author": preview.author, "authorID": NativeDTO.optional(preview.authorID),
                         "avatar": NativeDTO.optional(preview.avatarURL?.absoluteString),
                         "category": preview.category, "categoryLabel": Board.title(for: preview.category),
                         "featured": preview.featured == true, "readingRank": NativeDTO.optional(preview.readingRank),
                         "summary": preview.summary,
                         "published": NativeDTO.optional(preview.published.map { $0.timeIntervalSince1970 * 1000 })]) { _, new in new }
        }
        return value
    }

    func sessionSnapshot() -> [String: Any] {
        var profile = session.ownProfile.map { NativeDTO.encode($0) as? [String: Any] ?? [:] }
        if let id = session.memberID { profile?["avatar"] = Forum.avatar(id).absoluteString }
        let account: String
        switch session.account { case .unconfirmed: account = "unconfirmed"; case .signedOut: account = "signedOut"; case .signedIn: account = "signedIn" }
        return ["account": account, "profile": NativeDTO.optional(profile),
                "owner": NativeDTO.optional(session.memberID), "accessRevision": session.accessRevision,
                "canCompose": session.canCompose, "unread": NativeDTO.encode(session.unread),
                "sending": Array(session.sending)]
    }
}

@MainActor
final class SeekDeskFlutterBridge: NSObject, @preconcurrency FlutterStreamHandler, NSWindowDelegate {
    let context = SeekDeskBridgeContext()
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var observers = Set<AnyCancellable>()
    private var pendingDomains = Set<String>()
    private var requests: [String: Task<Void, Never>] = [:]
    private var bootstrapTask: Task<Void, Never>?
    private var unreadTask: Task<Void, Never>?
    private var attendanceTask: Task<Void, Never>?
    private var attendanceMember: Int?
    private lazy var attendance = AttendanceState(defaults: context.defaults)
    private var accessWindow: NSWindow?
    private var accessID: UUID?
    private var shortcutWindow: NSWindow?
    private var disposed = false
    private lazy var preferences = NativePreferencesServices(context: context)
    private lazy var forum = NativeForumServices(context: context)
    private lazy var directory = NativeDirectoryServices(context: context)
    private var composerDropBridge: NativeComposerDropBridge?

    func navigate(_ destination: String) {
        guard ["settings", "extensions", "inbox", "forum"].contains(destination) else { return }
        context.emit(domain: "navigation", data: ["destination": destination, "id": UUID().uuidString])
    }

    func flushDrafts(completion: @escaping (Bool) -> Void) {
        forum.flushDrafts(using: { reply in
            guard !disposed else { reply(true); return }
            methods.invokeMethod("lifecycle.flush", arguments: nil) { value in
                reply((value as? [String: Any])?["saved"] as? Bool == true)
            }
        }, completion: completion)
    }

    init(controller: FlutterViewController) {
        let messenger = controller.engine.binaryMessenger
        methods = FlutterMethodChannel(name: "cc.seekdesk/native.methods.v1", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "cc.seekdesk/native.events.v1", binaryMessenger: messenger)
        super.init()
        context.event = { [weak self] domain, data in self?.send(domain, data) }
        methods.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self, !self.disposed else {
                    result(FlutterError(code: "disposed", message: "本机服务已关闭。", details: nil))
                    return
                }
                self.receive(call, result: result)
            }
        }
        events.setStreamHandler(self)
        context.workspace.objectWillChange.sink { [weak self] in self?.schedule("workspace") }.store(in: &observers)
        context.session.objectWillChange.sink { [weak self] in self?.schedule("session") }.store(in: &observers)
        context.extensions.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.reconcileAttendance() }
        }.store(in: &observers)
        // accessDidChange runs after the revision mutation. A @Published sink
        // runs in willSet and a queued invalidation can erase a new, valid read.
        context.accessChanged = { [weak self] in
            guard let self, !self.disposed else { return }
            self.send("session", self.context.sessionSnapshot())
            self.forum.invalidate()
            self.schedule("workspace")
        }
        composerDropBridge = NativeComposerDropBridge(controller: controller, store: forum.composerDrop,
            authorization: { [weak self] in self?.context.session.authorization },
            available: { [weak self] in
                guard let self else { return false }
                return !self.disposed && !self.context.extensions.officePresented
            })
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.dispose()
        }.store(in: &observers)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        bootstrapTask?.cancel()
        context.stopListingRecovery()
        unreadTask?.cancel()
        attendanceTask?.cancel()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        context.accessChanged = nil
        context.event = nil
        observers.removeAll()
        pendingDomains.removeAll()
        composerDropBridge?.dispose()
        composerDropBridge = nil
        forum.dispose()
        // Persist drafts and revoke write tokens before releasing hidden pages.
        // This does not clear or modify the website cookie store.
        context.prepareForShutdown()
        accessWindow?.delegate = nil
        accessWindow?.close()
        accessWindow = nil
        shortcutWindow?.delegate = nil
        shortcutWindow?.close()
        shortcutWindow = nil
        methods.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
        eventSink = nil
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard !disposed else { return FlutterError(code: "disposed", message: "本机服务已关闭。", details: nil) }
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func receive(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "request.cancel" {
            if let id = args["requestId"] as? String { requests[id]?.cancel() }
            result(nil)
            return
        }
        let id = args["requestId"] as? String ?? UUID().uuidString
        guard requests[id] == nil else { result(FlutterError(code: "duplicate_request", message: "请求仍在进行中。", details: nil)); return }
        requests[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.requests[id] = nil }
            do {
                let value = try await self.handle(call.method, args)
                try Task.checkCancellation()
                result(value)
            } catch is CancellationError {
                result(FlutterError(code: "cancelled", message: "请求已取消。", details: nil))
            } catch let error as NativeBridgeError {
                result(FlutterError(code: error.code, message: error.message, details: nil))
            } catch {
                result(FlutterError(code: "native_error", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func handle(_ method: String, _ args: [String: Any]) async throws -> Any? {
        try Task.checkCancellation()
        guard !disposed else { throw CancellationError() }
        let workspace = context.workspace
        switch method {
        case "bootstrap":
            let snapshot: [String: Any] = ["workspace": context.workspaceSnapshot(), "session": context.sessionSnapshot(),
                "settings": preferences.settingsSnapshot(), "extensions": preferences.extensionsSnapshot(), "proxy": preferences.proxySnapshot(),
                "shortcuts": shortcutsSnapshot(),
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
            if bootstrapTask == nil {
                bootstrapTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled, !self.disposed else { return }
                    await self.context.bootstrapListing()
                    guard !Task.isCancelled, !self.disposed else { return }
                    await self.context.session.refreshUnread()
                    guard !Task.isCancelled, !self.disposed else { return }
                    self.context.extensions.startKeywordMonitoring()
                }
                unreadTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        guard let self else { return }
                        if !self.context.extensions.officePresented { await self.context.session.refreshUnread() }
                        if self.context.defaults.object(forKey: "workspace.autoRefresh") as? Bool ?? true,
                           self.context.workspace.board == .home, self.context.workspace.query.isEmpty,
                           !self.context.workspace.isBrowsingHistory, NSApp.isActive {
                            await self.context.workspace.refresh()
                        }
                    }
                }
            }
            return snapshot
        case "session.get": return context.sessionSnapshot()
        case "session.signIn": context.session.signIn(); showAccess(); return context.sessionSnapshot()
        case "session.verify":
            context.session.verify(try NativeDTO.url(args, forumOnly: true)); showAccess(); return context.sessionSnapshot()
        case "session.refresh": await context.session.refreshUnread(afterWrite: true); return context.sessionSnapshot()
        case "listing.get": return context.workspaceSnapshot()
        case "shortcuts.list": return shortcutsSnapshot()
        case "shortcuts.open":
            guard let shortcut = ForumShortcut(rawValue: try NativeDTO.string(args, "id")) else { throw NativeBridgeError(code: "invalid_shortcut", message: "快捷页面不存在。") }
            openShortcut(shortcut)
            return ["opened": true]
        case "listing.selectBoard":
            return try await context.selectBoard(NativeDTO.string(args, "id"))
        case "listing.refresh": await workspace.refresh(); return context.workspaceSnapshot()
        case "listing.older": await workspace.loadOlder(); return context.workspaceSnapshot()
        case "listing.order":
            guard let order = ForumFeedOrder(rawValue: try NativeDTO.string(args, "order")) else { throw NativeBridgeError(code: "invalid_order", message: "排序方式无效。") }
            workspace.chooseFeedOrder(order); await workspace.refresh(); return context.workspaceSnapshot()
        case "listing.search":
            return await context.search(query: try NativeDTO.string(args, "query"),
                scope: Set(args["scope"] as? [String] ?? []),
                kind: Workspace.SearchKind(rawValue: args["kind"] as? String ?? "all") ?? .all)
        case "listing.clearSearch": return await context.clearSearch()
        case "listing.clearHistory": workspace.clearSearchHistory(); return context.workspaceSnapshot()
        case "reader.open":
            let url = try NativeDTO.url(args, forumOnly: true)
            if let background = args["background"], !(background is Bool) {
                throw NativeBridgeError(code: "invalid_argument", message: "后台打开选项必须为布尔值。")
            }
            let opened = args["background"] as? Bool == true
                ? workspace.openTopicInBackground(url) : workspace.openTopicLink(url)
            guard opened else { throw NativeBridgeError(code: "invalid_topic", message: "请输入 NodeSeek 帖子链接。") }
            return context.workspaceSnapshot()
        case "reader.select": workspace.select(try NativeDTO.string(args, "id")); return context.workspaceSnapshot()
        case "reader.close":
            let id = try NativeDTO.string(args, "id"); workspace.close(id); forum.closeReader(id); return context.workspaceSnapshot()
        case "reader.closeAll": workspace.closeAllTabs(); forum.closeAllReaders(); return context.workspaceSnapshot()
        case "reader.reopen": _ = workspace.reopenClosedTab(args["id"] as? String); return context.workspaceSnapshot()
        case "reader.move": _ = workspace.moveTab(try NativeDTO.string(args, "id"), to: try NativeDTO.string(args, "to")); return context.workspaceSnapshot()
        case "reader.overview": workspace.showList(); return context.workspaceSnapshot()
        case "updates.check":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            return try await NativeReleaseCheck.check(installed: version)
        case "updates.install":
            guard let delegate = NSApp.delegate as? any NativeUpdateInstalling else {
                throw NativeBridgeError(code: "update_unavailable", message: "更新程序暂时不可用。")
            }
            try await delegate.installAvailableUpdate()
            return ["started": true]
        case "external.open":
            let url = try NativeDTO.url(args)
            guard NSWorkspace.shared.open(url) else { throw NativeBridgeError(code: "open_failed", message: "无法打开链接。") }
            return true
        case "clipboard.copy":
            NSPasteboard.general.clearContents()
            return ["copied": NSPasteboard.general.setString(try NativeDTO.string(args, "text"), forType: .string)]
        case "system.chooseImage":
            return try await forum.chooseImage(args) {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
                guard await panel.begin() == .OK else { return nil }
                return panel.url
            }
        case "system.importStickers":
            return try await forum.chooseStickerImages(args) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.prompt = "导入表情"
                let response = await withTaskCancellationHandler { await panel.begin() } onCancel: {
                    Task { @MainActor in panel.cancel(nil) }
                }
                guard response == .OK else { return nil }
                return panel.urls
            }
        default:
            if ["settings.", "extensions.", "proxy."].contains(where: { method.hasPrefix($0) }) { return try await preferences.handle(method, args) }
            if method.hasPrefix("space.") { return try await directory.handle(method, args) }
            return try await forum.handle(method, args)
        }
    }

    private func schedule(_ domain: String) {
        guard !disposed else { return }
        guard pendingDomains.insert(domain).inserted else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.disposed else { return }
            self.pendingDomains.remove(domain)
            self.send(domain, domain == "workspace" ? self.context.workspaceSnapshot() : self.context.sessionSnapshot())
            if domain == "session" { self.showAccess(); self.reconcileAttendance() }
        }
    }

    private func reconcileAttendance() {
        guard !disposed else { return }
        let enabled = context.extensions.active(.attendance) && context.extensions.autoAttendance && context.session.account == .signedIn
        let member = enabled ? context.session.ownProfile?.id : nil
        guard member != attendanceMember else { return }
        attendanceTask?.cancel()
        attendanceMember = member
        guard let member else { attendanceTask = nil; return }
        let service = attendance, session = context.session, extensions = context.extensions
        attendanceTask = Task { @MainActor in
            await service.run(member: member, session: session, extensions: extensions)
        }
    }

    private func send(_ domain: String, _ data: Any) {
        guard !disposed else { return }
        eventSink?(["domain": domain, "data": data, "accessRevision": context.session.accessRevision])
    }

    private func shortcutsSnapshot() -> [String: Any] {
        ["items": ForumShortcut.allCases.map { ["id": $0.id, "title": $0.title, "icon": $0.icon, "url": $0.url.absoluteString] }]
    }

    private func openShortcut(_ shortcut: ForumShortcut) {
        shortcutWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(shortcut.title) · NodeSeek 官方页面"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 480)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NativeShortcutContent(shortcut: shortcut, context: context) { [weak self, weak window] url in
            guard let self, self.context.workspace.openTopicLink(url) else { return false }
            self.context.emit(domain: "workspace", data: self.context.workspaceSnapshot())
            self.navigate("forum")
            window?.close()
            return true
        })
        shortcutWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    private func showAccess() {
        guard let request = context.session.access else {
            accessWindow?.orderOut(nil); accessWindow = nil; accessID = nil; return
        }
        if accessID == request.id { return }
        accessWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = request.verification ? "验证 NodeSeek 访问" : "登录 NodeSeek"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ForumAccessSheet(request: request, session: context.session))
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        accessWindow = window; accessID = request.id
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === accessWindow { context.session.finishAccess(nil) }
        if let window = notification.object as? NSWindow, window === shortcutWindow { shortcutWindow = nil }
    }
}

private struct NativeShortcutContent: View {
    let shortcut: ForumShortcut
    let context: SeekDeskBridgeContext
    let openTopic: (URL) -> Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ForumShortcutPane(shortcut: shortcut, session: context.session,
                          palette: DeskPalette(dark: colorScheme == .dark), openTopic: openTopic)
    }
}
