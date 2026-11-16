import SwiftUI
import WebKit

@MainActor
enum DiscussionAbandonment {
    enum Decision { case blocked, close, confirm }

    static func decision(for draft: NewDiscussionDraft, publishing: Bool, uploading: Bool) -> Decision {
        guard !publishing, !uploading else { return .blocked }
        let hasEdits = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !draft.category.isEmpty || draft.rank != 0 || !draft.imageSizing.sizes.isEmpty
        return hasEdits ? .confirm : .close
    }

    @discardableResult
    static func discard(_ draft: NewDiscussionDraft, publishing: Bool, uploading: Bool) -> Bool {
        guard decision(for: draft, publishing: publishing, uploading: uploading) != .blocked else { return false }
        draft.clear()
        return true
    }
}

@MainActor
final class DiscussionPublisher: ObservableObject {
    enum Phase { case loading, ready, signedOut, verification, unavailable }

    @Published var phase: Phase = .loading
    @Published var categories: [DiscussionOptions.Category] = []
    @Published var maxRank = 0
    @Published var sending = false
    @Published var message: String?
    @Published var showFeeConfirmation = false
    @Published var reload = 0
    private var page: ForumWebPage?

    func load(_ session: ForumSession, draft: NewDiscussionDraft) async {
        phase = .loading
        page = nil
        message = nil
        let access = session.accessRevision
        let loader = ForumWebPage(dataStore: session.dataStore)
        var readIssue = DiscussionReadIssue.pageLoad
        do {
            try await loader.read(DiscussionScript.page)
            try Task.checkCancellation()
            guard access == session.accessRevision else { return }
            if loader.challenged { phase = .verification; return }
            if loader.webView.url?.path == Forum.signIn.path {
                session.observeAccount(false); phase = .signedOut; return
            }
            if let status = loader.status, status >= 400 {
                message = "NodeSeek 发帖页返回 HTTP \(status)，请稍后重试。"
                phase = .unavailable
                return
            }
            readIssue = .optionsRead
            let data = try await DiscussionScript.readOptions {
                guard access == session.accessRevision else { throw CancellationError() }
                let value = try await loader.webView.callAsyncJavaScript(DiscussionScript.options, arguments: [:], in: nil, contentWorld: .page)
                return try Self.decode(DiscussionOptions.self, value)
            }
            guard access == session.accessRevision else { return }
            if data.kind == "signedOut" {
                session.observeAccount(false); phase = .signedOut; return
            }
            guard data.kind == "ready", let available = data.categories, !available.isEmpty else {
                message = data.failureMessage
                phase = .unavailable; return
            }
            readIssue = .identityRead
            guard let identity = try await loader.identity(), identity.signedIn else { throw ForumPageError.signInRequired }
            guard access == session.accessRevision else { return }
            session.observeIdentity(identity)
            guard session.newDiscussion === draft else { return }
            categories = available
            maxRank = max(0, min(30, data.maxRank ?? 0))
            if !available.contains(where: { $0.id == draft.category }) { draft.category = "" }
            if draft.rank != 255 && draft.rank > maxRank { draft.rank = 0 }
            page = loader
            session.observeAccount(true)
            phase = .ready
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, access == session.accessRevision else { return }
            phase = loader.challenged || (error as? ForumPageError) == .verification ? .verification : .unavailable
            if phase == .unavailable {
                switch error as? ForumPageError {
                case .timedOut: message = "读取 NodeSeek 发帖页面超时，请稍后重试。"
                case .network: message = "NodeSeek 发帖页面连接未完成，请重试。"
                default: message = readIssue.message
                }
            }
        }
    }

    @discardableResult
    func publish(_ draft: NewDiscussionDraft, session: ForumSession, accepted: @escaping (URL?) -> Void) -> Task<Void, Never>? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, session.canCompose, !sending, let page, !title.isEmpty,
              !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              categories.contains(where: { $0.id == draft.category }) else { return nil }
        let original = draft.content
        let originalSizes = draft.imageSizing.sizes
        let category = draft.category
        let rank = draft.rank
        let token = session.authorization
        sending = true
        message = nil
        return Task {
            defer { if token == session.authorization { sending = false } }
            let isCurrent: DraftImageSizing.Authorization = {
                session.authorizes(token) && session.newDiscussion === draft && self.sending
            }
            let content: String
            do { content = try await draft.imageSizing.prepare(original, authorized: isCurrent) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, isCurrent() else { return }
                message = (error as? NodeImageError ?? .connection).localizedDescription + " 草稿已保留。"
                return
            }
            guard !Task.isCancelled, isCurrent() else { return }
            let arguments: [String: Any] = ["title":title, "content":content, "category":category, "rank":rank]
            let response: DiscussionResponse?
            do {
                let value = try await page.webView.callAsyncJavaScript(DiscussionScript.publish, arguments: arguments,
                    in: nil, contentWorld: .page)
                response = try Self.decode(DiscussionResponse.self, value)
            } catch { response = nil }
            guard session.authorizes(token) else { return }
            switch response?.kind {
            case "accepted":
                if draft.snapshot == ForumDraftSnapshot.Discussion(title: title, content: original, category: category, rank: rank),
                   draft.imageSizing.sizes == originalSizes {
                    draft.clear()
                }
                accepted(response?.topicURL)
            case "signedOut":
                session.observeAccount(false)
                phase = .signedOut
            case "verification": phase = .verification
            case "unavailable": phase = .unavailable
            case "rejected":
                let reason = response?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                message = reason.flatMap { $0.isEmpty ? nil : $0 } ?? "NodeSeek 未接受本次发布。草稿已保留。"
            default:
                message = "没有收到发布结果。请先检查帖子是否已经出现，再决定是否重发。草稿已保留。"
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        guard let json = value as? String else { throw ForumPageError.changed }
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

struct NewDiscussionView: View {
    @ObservedObject var session: ForumSession
    @ObservedObject var draft: NewDiscussionDraft
    let palette: DeskPalette
    let onPublished: (URL?) -> Void
    @StateObject private var publisher = DiscussionPublisher()
    @StateObject private var editor = MarkdownEditorState(initialMode: .split)
    @StateObject private var abandonment = AbandonmentState()
    @FocusState private var titleFocused: Bool

    private struct AbandonmentRequest {
        let authorization: ForumSession.Authorization
        let draft: ObjectIdentifier
    }

    @MainActor private final class AbandonmentState: ObservableObject {
        @Published var request: AbandonmentRequest?
    }

    private var canPublish: Bool {
        session.canCompose && publisher.phase == .ready && !publisher.sending && !editor.uploading && !draft.category.isEmpty &&
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { session.presentation = nil } label: {
                    DeskLabel("返回论坛", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 6).frame(height: 30)
                }
                .deskGlassButtonStyle()
                .disabled(publisher.sending)
                .keyboardShortcut(.cancelAction)
                Text("发布新主题").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 3)
            VStack(alignment: .leading, spacing: 10) {
                TextField("请输入帖子标题", text: $draft.title)
                    .font(.system(size: 21, weight: .semibold)).textFieldStyle(.plain)
                    .focused($titleFocused)
                    .padding(.horizontal, 13).frame(height: 47)
                    .background(palette.reader, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line).allowsHitTesting(false) }
                    .disabled(publisher.sending)
                HStack(spacing: 16) {
                    Picker("版块", selection: $draft.category) {
                        Text("选择版块").tag("")
                        ForEach(publisher.categories) { Text($0.title).tag($0.id) }
                    }.fixedSize()
                    Picker("阅读限制", selection: $draft.rank) {
                        Text("公开").tag(0)
                        if publisher.maxRank > 0 {
                            ForEach(1...publisher.maxRank, id: \.self) { Text("Lv\($0)").tag($0) }
                        }
                        Text("私有").tag(255)
                    }.fixedSize()
                    Spacer()
                }
                .controlSize(.regular).disabled(publisher.phase != .ready || publisher.sending)
            }
            .padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 11)
            MarkdownComposer(text: $draft.content, palette: palette, disabled: publisher.sending,
                editor: editor, imageSizing: draft.imageSizing, height: 320, allowsSplit: true,
                fillsAvailableSpace: true, placeholder: "写下你的帖子正文…", fieldLabel: "帖子正文")
            .padding(.horizontal, 20).padding(.bottom, 10)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    footerStatus.fixedSize()
                    Spacer(minLength: 12)
                    footerActions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    footerStatus
                    HStack {
                        Spacer(minLength: 0)
                        footerActions
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 9).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.list.opacity(0.45))
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1).allowsHitTesting(false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.readerWash)
        .defaultFocus($titleFocused, true)
        .task(id: "\(publisher.reload)|\(session.accessRevision)") { await publisher.load(session, draft: draft) }
        .confirmationDialog("发内版需消耗 5 鸡腿", isPresented: $publisher.showFeeConfirmation, titleVisibility: .visible) {
            Button("消耗 5 鸡腿并发布", action: publish)
            Button("取消", role: .cancel) {}
        }
        .alert("放弃编辑？", isPresented: Binding(get: { abandonment.request != nil }, set: { if !$0 { abandonment.request = nil } }),
               presenting: abandonment.request) { request in
            Button("放弃编辑", role: .destructive) { abandon(request) }
            Button("继续编辑", role: .cancel) {}
        } message: { _ in
            Text("将清空这篇帖子的标题、正文、版块和阅读权限设置。")
        }
        .onChange(of: session.accessRevision) { abandonment.request = nil }
    }

    private var footerStatus: some View {
        HStack(alignment: .top, spacing: 7) { status }
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            if publisher.sending { ProgressView().controlSize(.small) }
            Button("放弃编辑", role: .destructive, action: requestAbandonment)
                .buttonStyle(.bordered).disabled(publisher.sending || editor.uploading)
            Button {
                if draft.category == "inside" { publisher.showFeeConfirmation = true }
                else { publish() }
            } label: {
                DeskLabel("发布帖子", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent).tint(palette.publish).disabled(!canPublish)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var status: some View {
        switch publisher.phase {
        case .loading: Text("正在读取可用版块…").font(.caption).foregroundStyle(.secondary)
        case .ready:
            if let message = publisher.message {
                DeskLabel(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(publisher.sending ? "正在发布…" : "请遵守版规，并确认版块和阅读权限。").font(.caption).foregroundStyle(.secondary)
            }
        case .signedOut: Button("登录 NodeSeek", action: session.signIn)
        case .verification: Button("验证 NodeSeek") { session.verify(DiscussionScript.page) }
        case .unavailable:
            Text("暂时无法读取发帖权限").font(.caption).foregroundStyle(.secondary)
            Button("重试") { publisher.reload += 1 }
        }
    }

    private func publish() {
        guard canPublish else { return }
        publisher.publish(draft, session: session, accepted: onPublished)
    }

    private func requestAbandonment() {
        guard session.newDiscussion === draft else { return }
        let request = AbandonmentRequest(authorization: session.authorization, draft: ObjectIdentifier(draft))
        switch DiscussionAbandonment.decision(for: draft, publishing: publisher.sending, uploading: editor.uploading) {
        case .blocked: return
        case .close: abandon(request)
        case .confirm: abandonment.request = request
        }
    }

    private func abandon(_ request: AbandonmentRequest) {
        abandonment.request = nil
        guard session.authorization == request.authorization, session.newDiscussion === draft,
              request.draft == ObjectIdentifier(draft), !publisher.sending, !editor.uploading else { return }
        editor.finish()
        guard DiscussionAbandonment.discard(draft, publishing: publisher.sending, uploading: editor.uploading) else { return }
        publisher.showFeeConfirmation = false
        session.presentation = nil
    }
}
