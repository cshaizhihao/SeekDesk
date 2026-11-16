import SwiftUI
import WebKit

@MainActor
final class ForumAccountReader: ObservableObject {
    enum State {
        case loading, signedOut, verification, failure
        case profile(ForumProfile), notices([ForumNotice], floorsPerPage: Int), conversations([ForumConversation]), messages(peer: Int, [ForumMessage])
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var reading: Set<InboxReadTarget> = []
    @Published private(set) var acknowledged: Set<InboxReadTarget> = []
    @Published private(set) var readFlash: Set<InboxReadTarget> = []
    @Published private(set) var readFailures: Set<InboxReadTarget> = []
    private var context: (ForumWebPage, ForumIdentity)?
    private var contextAccess: Int?
    private var cache = InboxReadCache<State>()
    private var current: UUID?
    private var stateKey: InboxReadCache<State>.Key?
    private var markedAccount: Int?

    func load(_ route: String, peer: Int?, refresh: Int = 0, revision: Int = 0, session: ForumSession) async {
        guard !Task.isCancelled else { return }
        var access = session.accessRevision
        let request = UUID()
        current = request
        cache.prepare(access: access, refresh: refresh)
        if contextAccess != access {
            context = nil
            cache.removeAll()
        }
        let key = InboxReadCache<State>.Key(route: route, peer: peer)
        stateKey = key
        if let saved = cache.value(for: key, revision: revision) {
            state = saved
            return
        }
        state = .loading
        do {
            let page: ForumWebPage
            let identity: ForumIdentity
            if let context {
                (page, identity) = context
            } else {
                page = ForumWebPage(dataStore: session.dataStore)
                try await page.read(Forum.home)
                try Task.checkCancellation()
                if page.challenged { throw ForumPageError.verification }
                guard let actual = page.webView.url, Forum.contains(actual) else { throw ForumPageError.network }
                if actual.path == Forum.signIn.path { throw ForumPageError.signInRequired }
                let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.identity, arguments: [:],
                    in: nil, contentWorld: .page)
                guard let json = raw as? String,
                      let detected = try? JSONDecoder().decode(ForumIdentity.self, from: Data(json.utf8)) else {
                    throw ForumPageError.network
                }
                try Task.checkCancellation()
                guard detected.signedIn else { throw ForumPageError.signInRequired }
                guard current == request, access == session.accessRevision else { return }
                identity = detected
                session.observeIdentity(identity)
                access = session.accessRevision
                context = (page, identity)
                contextAccess = access
                cache.prepare(access: access, refresh: refresh)
                // Subsequent inbox reads use fetch in this settled document.
                page.webView.stopLoading()
            }
            guard let id = identity.id else { throw ForumPageError.changed }
            if markedAccount != id {
                markedAccount = id
                acknowledged.removeAll()
                reading.removeAll()
                readFailures.removeAll()
                readFlash.removeAll()
            }
            let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.read,
                arguments: ["route": route, "selfID": id, "peerID": peer ?? 0], in: nil, contentWorld: .defaultClient)
            guard current == request, !Task.isCancelled, access == session.accessRevision else { return }
            guard let json = raw as? String else { throw ForumPageError.network }
            let data = Data(json.utf8)
            let decoder = JSONDecoder()
            let meta = try decoder.decode(Meta.self, from: data)
            switch meta.kind {
            case "signedOut": throw ForumPageError.signInRequired
            case "verification": throw ForumPageError.verification
            case "ok": break
            default: throw ForumPageError.network
            }
            func value<T: Decodable>(_ type: T.Type) throws -> T {
                guard let result = try decoder.decode(Envelope<T>.self, from: data).data else { throw ForumPageError.changed }
                return result
            }
            switch route {
            case "profile":
                let profile = try value(ForumProfile.self)
                session.updateOwnProfile(profile)
                state = .profile(profile)
            case "mentions", "replies": state = .notices(try value([ForumNotice].self), floorsPerPage: identity.floorsPerPage ?? 10)
            case "messages":
                let conversations = try value([ForumConversation].self)
                session.rememberConversationContacts(conversations.map { ForumConversationContact(id: $0.id, name: $0.name) }, for: id)
                state = .conversations(conversations)
            case "conversation":
                guard let peer else { throw ForumPageError.changed }
                let messages = try value([ForumMessage].self)
                if !messages.isEmpty {
                    let name = messages.compactMap(\.peerName).first { !$0.isEmpty } ?? ""
                    session.rememberConversationContacts([ForumConversationContact(id: peer, name: name)], for: id)
                }
                state = .messages(peer: peer, messages)
            default: state = .failure
            }
            cache.insert(state, for: key, cost: data.count, revision: revision)
        } catch {
            guard current == request, !Task.isCancelled, access == session.accessRevision else { return }
            switch error as? ForumPageError {
            case .signInRequired:
                context = nil
                cache.removeAll()
                session.observeAccount(false)
                state = .signedOut
            case .verification:
                context = nil
                cache.removeAll()
                state = .verification
            default: state = .failure
            }
        }
    }

    func markRead(_ target: InboxReadTarget, session: ForumSession) async {
        guard let (page, identity) = context, let user = identity.id,
              !acknowledged.contains(target), reading.insert(target).inserted else { return }
        readFailures.remove(target)
        defer { reading.remove(target) }
        let access = session.accessRevision
        do {
            let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.markRead,
                arguments: ["route": target.category.rawValue, "itemID": target.id, "selfID": user],
                in: nil, contentWorld: .defaultClient)
            guard markedAccount == user, session.accessRevision == access else { return }
            guard let json = raw as? String else { readFailures.insert(target); return }
            let result = try JSONDecoder().decode(InboxReadResult.self, from: Data(json.utf8))
            guard result.kind == "read" else {
                if result.kind == "signedOut" { session.observeAccount(false) }
                readFailures.insert(target)
                return
            }
            if acknowledged.count >= 512 { acknowledged.removeAll(keepingCapacity: true) }
            readFlash.insert(target)
            acknowledged.insert(target)
            cache.updateValues { key, value in
                key.route == target.category.rawValue ? value.markingRead(target) : value
            }
            if stateKey?.route == target.category.rawValue { state = state.markingRead(target) }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(640))
                self?.readFlash.remove(target)
            }
            await session.acknowledgedRead(target.category, count: result.count ?? 0)
        } catch {
            if markedAccount == user && session.accessRevision == access { readFailures.insert(target) }
        }
    }

    func send(peer: Int, content: String, markdown: Bool) async -> MessageSendResult {
        guard case .messages(let currentPeer, _) = state, currentPeer == peer, let (page, _) = context else {
            return MessageSendResult(kind: "unavailable", message: nil)
        }
        do {
            let raw = try await page.webView.callAsyncJavaScript(ForumAccountScript.sendMessage,
                arguments: ["peerID": peer, "content": content, "markdown": markdown],
                in: nil, contentWorld: .defaultClient)
            guard let json = raw as? String else { return MessageSendResult(kind: "unknown", message: nil) }
            return try JSONDecoder().decode(MessageSendResult.self, from: Data(json.utf8))
        } catch { return MessageSendResult(kind: "unknown", message: nil) }
    }

    private struct Meta: Decodable { let kind: String }
    private struct Envelope<T: Decodable>: Decodable { let kind: String; let data: T? }
}

private extension ForumAccountReader.State {
    func markingRead(_ target: InboxReadTarget) -> Self {
        switch self {
        case .notices(let notices, let floorsPerPage) where target.category != .messages:
            return .notices(notices.map { notice in
                guard notice.readTarget(target.category) == target else { return notice }
                return ForumNotice(id: notice.id, author: notice.author, authorID: notice.authorID,
                    title: notice.title, date: notice.date, unread: false, postID: notice.postID, floor: notice.floor)
            }, floorsPerPage: floorsPerPage)
        case .conversations(let conversations) where target.category == .messages:
            return .conversations(conversations.map { conversation in
                guard conversation.readTarget == target else { return conversation }
                return ForumConversation(id: conversation.id, name: conversation.name, preview: conversation.preview,
                    date: conversation.date, unread: false)
            })
        default: return self
        }
    }
}

struct ForumAccountSheet: View {
    enum Section { case profile, inbox }

    let section: Section
    @ObservedObject var session: ForumSession
    let palette: DeskPalette
    let openTopic: (URL) -> Bool
    @StateObject private var reader = ForumAccountReader()
    @StateObject private var detailReader = ForumAccountReader()
    @StateObject private var navigation = AccountNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inInbox: Bool { section == .inbox }
    private var rule: some View { Rectangle().fill(palette.line).frame(height: 1) }
    private var route: String { inInbox ? navigation.category.rawValue : "profile" }

    var body: some View {
        VStack(spacing: 0) {
            DeskGlassGroup {
                HStack(spacing: 10) {
                    DeskIcon(inInbox ? "tray.full" : "person.crop.circle", size: 17)
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(palette.accent)
                    Text(inInbox ? "通知" : "个人资料")
                        .font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { navigation.reload += 1 } label: {
                        DeskLabel("刷新", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 7).frame(height: 28)
                    }
                    .deskGlassButtonStyle().help("刷新")
                    if !inInbox {
                        Button("关闭") { session.presentation = nil }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(palette.readerWash)
            rule
            if inInbox {
                tabs
                rule
                if reader.readFailures.contains(where: { $0.category == navigation.category }) {
                    DeskLabel("没能标为已读。可以再点一次红点。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 7).background(palette.list)
                }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: inInbox ? nil : 525, height: inInbox ? nil : 440)
        .background(palette.reader)
        .onChange(of: session.unread, initial: true) { _, unread in
            guard inInbox, !navigation.selectedCategory, session.requestedPeer == nil else { return }
            if let first = InboxCategory.allCases.first(where: { unread.count($0) > 0 }) {
                navigation.category = first
                navigation.selectedCategory = true
            }
        }
        .onChange(of: session.requestedPeer?.id, initial: true) { _, _ in
            guard inInbox, let peer = session.requestedPeer else { return }
            navigation.selectedCategory = true
            navigation.category = .messages
            navigation.peer = peer
            session.requestedPeer = nil
        }
        .onChange(of: session.unread) { old, new in
            guard inInbox else { return }
            navigation.revisions.incoming(from: old, to: new)
        }
        .task(id: navigation.reload) {
            if inInbox { await session.refreshUnread() }
        }
        .task(id: Key(route: route, peer: nil, reload: navigation.reload, access: session.accessRevision,
                      revision: navigation.revisions.value(for: navigation.category))) {
            await reader.load(route, peer: nil, refresh: navigation.reload,
                              revision: navigation.revisions.value(for: navigation.category), session: session)
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            DeskGlassPicker(values: InboxCategory.allCases, selection: Binding(
                    get: { navigation.category }, set: { category in
                        navigation.selectedCategory = true
                        navigation.category = category
                        navigation.notice = nil
                        navigation.peer = nil
                    }), tint: palette.accent, solid: palette.selection) { category, selected in
                        HStack(spacing: 5) {
                            Text(category.title).font(.system(size: 12, weight: .semibold))
                            InboxCategoryCount(count: session.unread.count(category), palette: palette)
                        }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch reader.state {
        case .loading:
            VStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在读取 NodeSeek…").font(.callout).foregroundStyle(.secondary) }
        case .signedOut:
            empty("登录后查看\(inInbox ? "通知" : "资料")", icon: "person.crop.circle") {
                Button("登录 NodeSeek", action: session.signIn).deskGlassButtonStyle(prominent: true)
            }
        case .verification:
            empty("请先完成 NodeSeek 站点验证", icon: "checkmark.shield") {
                Button("打开验证窗口") { session.verify(Forum.home) }.deskGlassButtonStyle(prominent: true)
            }
        case .failure:
            empty("暂时无法读取，检查网络后重试", icon: "exclamationmark.circle") {
                Button("重试") { navigation.reload += 1 }
            }
        case .profile(let profile): profileView(profile)
        case .notices(let items, let floorsPerPage):
            if items.isEmpty { empty(navigation.category.emptyTitle, icon: "tray") { EmptyView() } }
            else {
                split {
                    rows(items) { notice in
                        notificationRow(name: notice.author, personID: notice.authorID, summary: notice.title, date: notice.date,
                            unread: notice.unread, target: notice.readTarget(navigation.category), selected: navigation.notice == notice.id) {
                            navigation.notice = notice.id
                        }
                    }
                } detail: {
                    if let notice = items.first(where: { $0.id == navigation.notice }) {
                        noticeDetail(notice, floorsPerPage: floorsPerPage).id(notice.id).modifier(DeskArrival())
                    } else {
                        empty("选择一条通知", icon: "text.bubble") { EmptyView() }
                    }
                }
            }
        case .conversations(let results):
            let recentIDs = Set(results.map(\.id))
            let known = session.conversationContacts.filter { !recentIDs.contains($0.id) }.map(\.conversation)
            let older = known.contains(where: { $0.id == navigation.peer?.id }) || results.contains(where: { $0.id == navigation.peer?.id })
                ? known : [navigation.peer].compactMap { $0 } + known
            split {
                conversationList(recent: results, older: older)
            } detail: {
                if let peer = (results + older).first(where: { $0.id == navigation.peer?.id }) {
                    conversationDetail(peer)
                } else {
                    empty("选择一段私信", icon: "bubble.left.and.bubble.right") { EmptyView() }
                }
            }
        case .messages:
            EmptyView()
        }
    }

    private func conversationList(recent: [ForumConversation], older: [ForumConversation]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("UID 或个人主页链接", text: $navigation.peerLookup)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("查找旧私信")
                    .onSubmit { openOlderConversation(in: recent + older) }
                Button("打开") { openOlderConversation(in: recent + older) }
                    .buttonStyle(.borderless)
                    .disabled(navigation.peerLookup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(9)
            .deskGlass(in: RoundedRectangle(cornerRadius: 12), solid: palette.list)
            .padding(8)
            if let issue = navigation.peerLookupIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            rule
            if recent.isEmpty && older.isEmpty {
                empty("暂无私信", icon: "bubble.left.and.bubble.right") { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        conversationSection("最近对话", items: recent)
                        conversationSection("较早的对话", items: older)
                    }
                    .padding(7)
                }
            }
        }
    }

    @ViewBuilder private func conversationSection(_ title: String, items: [ForumConversation]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.top, 6).accessibilityAddTraits(.isHeader)
            ForEach(items) { peer in
                notificationRow(name: peer.name, personID: peer.id, summary: peer.preview, date: peer.date,
                    unread: peer.unread, target: peer.readTarget, selected: navigation.peer?.id == peer.id) {
                    navigation.peer = peer
                }
            }
        }
    }

    private func openOlderConversation(in conversations: [ForumConversation]) {
        guard let id = Forum.memberID(from: navigation.peerLookup), id != session.ownProfile?.id else {
            navigation.peerLookupIssue = "请输入对方的 NodeSeek 数字 UID 或个人主页链接。"
            return
        }
        navigation.peerLookup = ""
        navigation.peerLookupIssue = nil
        navigation.peer = conversations.first { $0.id == id } ?? ForumConversationContact(id: id, name: "").conversation
    }

    private func split<List: View, Detail: View>(@ViewBuilder list: () -> List, @ViewBuilder detail: () -> Detail) -> some View {
        let listView = list()
        let detailView = detail()
        return GeometryReader { geometry in
            let columns = DeskMessageLayout.usesColumns(width: geometry.size.width)
            let hasDetail = navigation.category == .messages ? navigation.peer != nil : navigation.notice != nil
            let showList = columns || !hasDetail
            let listWidth = columns ? max(224, min(340, geometry.size.width * 0.37)) : showList ? geometry.size.width : 0
            VStack(spacing: 0) {
                if !columns && hasDetail {
                    HStack {
                        Button {
                            if navigation.category == .messages { navigation.peer = nil }
                            else { navigation.notice = nil }
                        } label: { DeskLabel(navigation.category == .messages ? "返回私信列表" : "返回通知列表", systemImage: "chevron.left") }
                        .buttonStyle(DeskButtonStyle()).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    rule
                }
                HStack(spacing: 0) {
                    listView.frame(width: listWidth).clipped().background(palette.list)
                        .allowsHitTesting(showList).accessibilityHidden(!showList)
                    Rectangle().fill(palette.line).frame(width: columns ? 1 : 0)
                    detailView.frame(width: columns ? max(0, geometry.size.width - listWidth - 1) : geometry.size.width)
                        .frame(width: columns || hasDetail ? nil : 0, alignment: .leading)
                        .frame(maxHeight: .infinity).clipped()
                        .allowsHitTesting(columns || hasDetail).accessibilityHidden(!columns && !hasDetail)
                        .background { ReaderBackdrop(palette: palette) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func noticeDetail(_ notice: ForumNotice, floorsPerPage: Int) -> some View {
        let target = notice.destination(floorsPerPage: floorsPerPage)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        noticeIdentity(notice)
                        Spacer(minLength: 8)
                        Text(dateLabel(notice.date)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        noticeIdentity(notice)
                        Text(dateLabel(notice.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: palette.chrome)
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "text.bubble").foregroundStyle(palette.accent).padding(.top, 2)
                        Text(notice.title).font(.system(size: 17, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    NoticeReplyPreview(notice: notice, target: target, session: session, palette: palette,
                                       cache: navigation.previews, refresh: navigation.reload, openTopic: openTopic)
                }
                .padding(22)
                rule
                HStack {
                    Text("第 \(notice.floor) 楼").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button { _ = openTopic(target) } label: {
                        DeskLabel("进入帖子", systemImage: "arrow.up.right").padding(.horizontal, 5).frame(height: 26)
                    }
                    .deskGlassButtonStyle(prominent: true)
                    .accessibilityLabel("打开第 \(notice.floor) 楼")
                }.padding(16)
            }
            .background(palette.list, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(palette.line).allowsHitTesting(false) }
            .frame(maxWidth: 760, alignment: .leading).padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func noticeIdentity(_ notice: ForumNotice) -> some View {
        HStack(spacing: 12) {
            avatar(notice.authorID, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.author.isEmpty ? "NodeSeek 用户" : notice.author)
                    .font(.system(size: 14, weight: .semibold))
                Text(navigation.category == .mentions ? "在帖子中提到了你" : "回复了你的主题")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func conversationDetail(_ peer: ForumConversation) -> some View {
        GeometryReader { geometry in
        let layout = DeskMessageLayout(height: geometry.size.height, hasStatus: session.messageStatus[peer.id] != nil)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                avatar(peer.id, size: layout.compact ? 24 : 30)
                Text(peer.name.isEmpty ? "NodeSeek 用户" : peer.name).font(.headline).lineLimit(1)
                    .help(peer.name.isEmpty ? "NodeSeek 用户" : peer.name)
                Spacer()
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity)
            .frame(height: layout.headerHeight - (layout.compact ? 12 : 20))
            .deskGlass(in: RoundedRectangle(cornerRadius: 14), solid: palette.list)
            .padding(layout.compact ? 6 : 10)
            Group {
                switch detailReader.state {
                case .messages(let id, let items) where id == peer.id && !items.isEmpty: messageHistory(items, peerID: peer.id).id(peer.id)
                case .messages(let id, _) where id == peer.id: empty("这段对话暂无消息", icon: "bubble.left") { EmptyView() }
                case .loading, .messages: ProgressView("正在读取对话…").controlSize(.small)
                case .signedOut: empty("请重新登录后查看私信", icon: "person.crop.circle") {
                    Button("登录 NodeSeek", action: session.signIn)
                }
                case .verification: empty("请先完成 NodeSeek 站点验证", icon: "checkmark.shield") {
                    Button("打开验证窗口") { session.verify(Forum.home) }
                }
                default: empty("暂时无法读取对话", icon: "exclamationmark.circle") {
                    Button("重试") { navigation.reload += 1 }
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .messages(let id, _) = detailReader.state, id == peer.id {
                rule
                messageComposer(peer, viewportHeight: layout.editorHeight,
                                compact: layout.compact || geometry.size.width < 520)
            }
        }
        }
        .task(id: Key(route: "conversation", peer: peer.id, reload: navigation.reload, access: session.accessRevision,
                      revision: navigation.revisions.value(for: .messages))) {
            await detailReader.load("conversation", peer: peer.id, refresh: navigation.reload,
                                    revision: navigation.revisions.value(for: .messages), session: session)
        }
    }

    private func messageComposer(_ peer: ForumConversation, viewportHeight: CGFloat, compact: Bool) -> some View {
        let sending = session.sendingMessages.contains(peer.id)
        let token = session.authorization
        let draft = Binding(get: { session.authorizes(token) ? session.messageDrafts[peer.id, default: ""] : "" },
                            set: { if session.authorizes(token) { session.messageDrafts[peer.id] = $0 } })
        let text = draft.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            DirectMessageComposer(text: draft, palette: palette, disabled: sending, peer: peer.name,
                viewportHeight: viewportHeight, compact: compact, imageSizing: session.imageSizing(for: .message(peer.id)),
                markdown: $navigation.messageMarkdown, sending: sending,
                signedIn: session.canCompose) {
                    sendMessage(peer: peer.id, text: text, markdown: navigation.messageMarkdown)
                }
                .id(peer.id)
            if let status = session.messageStatus[peer.id] {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(2).help(status).fixedSize(horizontal: false, vertical: true)
            }
            if session.account == .signedOut {
                Button("重新登录", action: session.signIn).deskGlassButtonStyle()
            }
        }
        .padding(compact ? 8 : 12).background(palette.list)
    }

    private func sendMessage(peer: Int, text: String, markdown: Bool) {
        guard session.canCompose, session.sendingMessages.insert(peer).inserted else { return }
        let sizing = session.imageSizing(for: .message(peer))
        let originalSizes = sizing.sizes
        let token = session.authorization
        let reader = detailReader
        session.messageStatus[peer] = nil
        Task {
            defer { if token == session.authorization { session.sendingMessages.remove(peer) } }
            let isCurrent: DraftImageSizing.Authorization = {
                guard session.authorizes(token), session.sendingMessages.contains(peer),
                      session.ownsImageSizing(sizing, for: .message(peer)),
                      case .messages(let currentPeer, _) = reader.state, currentPeer == peer else { return false }
                return true
            }
            let content: String
            do { content = markdown ? try await sizing.prepare(text, authorized: isCurrent) : text }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, isCurrent() else { return }
                session.messageStatus[peer] = (error as? NodeImageError ?? .connection).localizedDescription + " 草稿已保留。"
                return
            }
            guard !Task.isCancelled, isCurrent() else { return }
            let result = await reader.send(peer: peer, content: content, markdown: markdown)
            guard session.authorizes(token) else { return }
            if result.kind == "sent" {
                if session.messageDrafts[peer] == text, sizing.sizes == originalSizes {
                    session.messageDrafts[peer] = nil
                    sizing.reset()
                }
                session.messageStatus[peer] = "已发送"
                navigation.revisions.invalidate(.messages)
            } else {
                switch result.kind {
                case "signedOut":
                    session.observeAccount(false)
                    session.messageStatus[peer] = "登录已失效。重新登录后再发送。"
                case "verification":
                    session.messageStatus[peer] = "NodeSeek 需要站点验证。完成验证后再发送。"
                case "unavailable":
                    session.messageStatus[peer] = "请刷新当前对话后再发送。"
                case "rejected":
                    session.messageStatus[peer] = result.message ?? "NodeSeek 拒绝了此消息。"
                default:
                    session.messageStatus[peer] = "发送结果不明。刷新确认后再重试。"
                }
            }
        }
    }

    private func profileView(_ profile: ForumProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 13) {
                    avatar(profile.id, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(profile.name).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                            if let rank = profile.rank {
                                Text("Lv.\(rank)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(palette.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(palette.selection, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text("用户 #\(profile.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: palette.list)
                rule
                HStack(spacing: 8) {
                    stat("主题", profile.topics); stat("回复", profile.replies); stat("关注", profile.following)
                    stat("粉丝", profile.followers); stat("鸡腿", profile.coin)
                }
                if let joined = profile.joined, !joined.isEmpty {
                    DeskLabel("加入于 \(joined)", systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                }
                if let bio = profile.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("个人简介").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(bio).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.map { String($0) } ?? "—").font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .deskGlass(in: RoundedRectangle(cornerRadius: 6), solid: palette.list)
        .accessibilityElement(children: .combine)
    }

    private func empty<Actions: View>(_ title: String, icon: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            DeskIcon(icon, size: 23).font(.system(size: 23)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.callout).foregroundStyle(.secondary)
            actions().deskGlassButtonStyle()
        }
        .padding(20)
    }

    private func rows<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in row(item); rule.padding(.leading, 48) }
            }
            .padding(.horizontal, 15).padding(.vertical, 7)
        }
    }

    private func notificationRow(name: String, personID: Int?, summary: String, date: String, unread: Bool,
                                 target: InboxReadTarget?, selected: Bool, open: @escaping () -> Void) -> some View {
        let isUnread = unread && (target.map { !reader.acknowledged.contains($0) } ?? true)
        let flash = target.map { reader.readFlash.contains($0) } ?? false
        return HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 8) {
                    avatar(personID, size: 29)
                    VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? "NodeSeek 用户" : name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(summary).font(.callout).lineLimit(1)
                    }
                    Spacer(minLength: 5)
                    Text(dateLabel(date)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: 89, alignment: .trailing)
                }
                .padding(.leading, 8).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(isUnread ? "未读" : "已读")
            ZStack {
                if isUnread, let target {
                    let working = reader.reading.contains(target)
                    Button {
                        Task { await reader.markRead(target, session: session) }
                    } label: {
                        ZStack {
                            Circle().fill(palette.unread.opacity(0.17)).frame(width: 17, height: 17)
                            Circle().fill(palette.unread).frame(width: 8, height: 8)
                                .scaleEffect(working && !reduceMotion ? 0.68 : 1)
                        }
                        .frame(width: 26, height: 29).contentShape(Rectangle())
                        .animation(reduceMotion ? nil : DeskMotion.feedback, value: working)
                    }
                    .buttonStyle(DeskButtonStyle(compresses: true)).disabled(working)
                    .help(target.category == .messages ? "将此会话标为已读" : "标为已读")
                    .accessibilityLabel(target.category == .messages ? "将此会话标为已读" : "标为已读")
                    .accessibilityHint(name)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.55).combined(with: .opacity))
                } else if flash {
                    DeskIcon("checkmark.circle.fill", size: 13).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.categoryInk("review")).accessibilityHidden(true)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
                } else if isUnread {
                    Circle().fill(palette.unread).frame(width: 8, height: 8).accessibilityHidden(true)
                }
            }
            .frame(width: 26, height: 29)
            .animation(reduceMotion ? nil : DeskMotion.selection, value: isUnread)
            .animation(reduceMotion ? nil : DeskMotion.selection, value: flash)
            .padding(.trailing, 3)
        }
        .background(selected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .animation(reduceMotion ? nil : DeskMotion.selection, value: selected)
    }

    private func messageHistory(_ items: [ForumMessage], peerID: Int) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { message in
                    HStack(alignment: .top, spacing: 9) {
                        if !message.mine {
                            avatar(peerID, size: 32).padding(.top, 2)
                        }
                        VStack(alignment: message.mine ? .trailing : .leading, spacing: 4) {
                            Text(message.markdown ? DeskMarkdownText.inline(message.text) : AttributedString(message.text))
                                .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .background(message.mine ? palette.selection : palette.list, in: RoundedRectangle(cornerRadius: 14))
                            Text(dateLabel(message.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 580, alignment: message.mine ? .trailing : .leading)
                        if message.mine {
                            avatar(session.memberID, size: 32).padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: 621, alignment: message.mine ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
                }
            }
            .frame(maxWidth: 820).padding(20).frame(maxWidth: .infinity)
        }
        .modifier(MessageHistoryAlignment())
        .environment(\.openURL, OpenURLAction { url in
            guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return .discarded }
            if Forum.topicID(url) != nil { _ = openTopic(url); return .handled }
            return .systemAction
        })
    }

    private func avatar(_ id: Int?, size: CGFloat) -> some View {
        ForumAvatar(url: id.map { Forum.avatar($0) }, size: size, palette: palette)
    }

    private func dateLabel(_ date: String) -> String {
        guard !date.isEmpty else { return "" }
        let formats: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], .withInternetDateTime]
        let formatter = ISO8601DateFormatter()
        for format in formats {
            formatter.formatOptions = format
            if let parsed = formatter.date(from: date) { return parsed.formatted(date: .abbreviated, time: .shortened) }
        }
        return String(date.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    private struct Key: Equatable { let route: String; let peer: Int?; let reload: Int; let access: Int; let revision: Int }
}

private struct InboxCategoryCount: View {
    let count: Int
    let palette: DeskPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if count > 0 {
                Text(String(count)).font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 4).background(palette.surface, in: Capsule())
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : DeskMotion.selection, value: count)
    }
}

private struct NoticeReplyPreview: View {
    let notice: ForumNotice
    let target: URL
    let session: ForumSession
    let palette: DeskPalette
    let cache: NoticePreviewCache
    let refresh: Int
    let openTopic: (URL) -> Bool
    @StateObject private var state = State()

    private enum Preview { case loading, ready([ForumBlock]), unavailable }
    @MainActor private final class State: ObservableObject {
        @Published var result: Preview = .loading
        @Published var retry = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DeskLabel("回复正文", systemImage: "text.quote")
                .font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
            switch state.result {
            case .loading:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取第 \(notice.floor) 楼…").font(.callout).foregroundStyle(.secondary)
                }
            case .ready(let blocks):
                ForumBlocksView(blocks: blocks, palette: palette).equatable()
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if openTopic(url) { return .handled }
                        return url.scheme == "https" && url.user == nil && url.password == nil ? .systemAction : .discarded
                    })
            case .unavailable:
                HStack {
                    Text("暂时无法读取这层回复。").font(.callout).foregroundStyle(.secondary)
                    Button("重试") { state.retry += 1 }.buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: state.retry) {
            state.result = .loading
            cache.values.prepare(access: session.accessRevision, refresh: refresh)
            let key = InboxReadCache<[ForumBlock]>.Key(route: target.absoluteString, peer: notice.authorID)
            if state.retry == 0, let saved = cache.values.value(for: key) {
                state.result = .ready(saved)
                return
            }
            if let cached = session.cachedThread(at: target), let floor = notice.reply(in: cached), !floor.blocks.isEmpty {
                state.result = .ready(floor.blocks)
                return
            }
            do {
                let (thread, _) = try await ForumReaderState.fetch(target, floor: String(notice.floor), session: session)
                try Task.checkCancellation()
                if let floor = notice.reply(in: thread), !floor.blocks.isEmpty {
                    cache.values.insert(floor.blocks, for: key, cost: ForumThreadCacheCost.estimate(thread))
                    state.result = .ready(floor.blocks)
                }
                else { state.result = .unavailable }
            } catch {
                if !Task.isCancelled { state.result = .unavailable }
            }
        }
    }
}

@MainActor private final class NoticePreviewCache {
    var values = InboxReadCache<[ForumBlock]>()
}

@MainActor private final class AccountNavigation: ObservableObject {
    let previews = NoticePreviewCache()
    @Published var category: InboxCategory = .mentions
    var selectedCategory = false
    @Published var peer: ForumConversation?
    @Published var peerLookup = ""
    @Published var peerLookupIssue: String?
    @Published var notice: String?
    @Published var messageMarkdown = true
    @Published var reload = 0
    @Published var revisions = InboxCategoryRevisions()
}


struct MessageSendResult: Codable {
    let kind: String
    let message: String?
}


private struct DirectMessageComposer: View {
    @Binding var text: String
    let palette: DeskPalette
    let disabled: Bool
    let peer: String
    let viewportHeight: CGFloat
    let compact: Bool
    let imageSizing: DraftImageSizing
    @Binding var markdown: Bool
    let sending: Bool
    let signedIn: Bool
    let send: () -> Void
    @StateObject private var editor = MarkdownEditorState()

    var body: some View {
        VStack(spacing: 0) {
            // One native editor viewport. Its text scrolls internally; no second
            // expanding ScrollView can push the Send row away from the field.
            MarkdownComposer(text: $text, palette: palette, disabled: disabled, editor: editor,
                imageSizing: imageSizing, height: 100, maxHeight: 260, fillsAvailableSpace: true, compactControls: compact,
                placeholder: "写给 \(peer)…", fieldLabel: "私信正文", onFormat: { markdown = true })
            .frame(height: viewportHeight)
            .accessibilityIdentifier("message-composer")
            DeskGlassGroup {
                HStack {
                    Toggle("Markdown", isOn: $markdown).toggleStyle(.checkbox).controlSize(.small).disabled(sending)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button(action: send) { DeskLabel("发送私信", systemImage: "paperplane") }
                        .deskGlassButtonStyle(prominent: true)
                        .disabled(sending || editor.uploading || !signedIn || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(minHeight: 28)
                .padding(.horizontal, 12).padding(.vertical, compact ? 4 : 10)
            }
        }
        .background(palette.reader, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(palette.line).allowsHitTesting(false) }
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
    }
}

private struct MessageHistoryAlignment: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment)
        } else {
            content.defaultScrollAnchor(.top)
        }
    }
}
