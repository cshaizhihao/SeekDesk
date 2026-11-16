import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var workspace: Workspace?
    weak var workspaceWindow: NSWindow?
    private var keyboardMonitor: Any?
    private var pendingKeywordTopic: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let workspace = self?.workspace,
                  !workspace.showingSearch, !workspace.presentingOfficeCover,
                  let window = event.window, window === NSApp.keyWindow, window === self?.workspaceWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if let dismiss = workspace.dismissImage {
                if (event.charactersIgnoringModifiers == "\u{1b}" && modifiers.isEmpty) ||
                    (event.charactersIgnoringModifiers == "w" && modifiers == .command) {
                    if !event.isARepeat { dismiss() }
                    return nil
                }
                return event
            }
            guard !workspace.presentingContentOverlay else { return event }
            switch (event.charactersIgnoringModifiers, modifiers) {
            case ("w", .command):
                if event.isARepeat { return nil }
                return workspace.closeCurrentTab() ? nil : event
            case ("\t", .control):
                return workspace.selectAdjacentTab(.next) ? nil : event
            case ("\t", [.control, .shift]), ("\u{19}", [.control, .shift]):
                return workspace.selectAdjacentTab(.previous) ? nil : event
            case ("\u{1b}", []) where !event.isARepeat && !(window.firstResponder is NSTextView):
                if !workspace.inForum { workspace.returnToForum() }
                else if workspace.showReader { workspace.showList() }
                else { return event }
            default: return event
            }
            return nil
        }
    }

    func bindWorkspace(_ workspace: Workspace, window: NSWindow?) {
        self.workspace = workspace
        workspaceWindow = window
        if #available(macOS 26.0, *), let window {
            // Let the system sample scroll content behind the window toolbar.
            window.styleMask.insert(.fullSizeContentView)
        }
        if window != nil, let pendingKeywordTopic {
            self.pendingKeywordTopic = nil
            openKeywordTopic(pendingKeywordTopic)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion(notification.request.identifier.hasPrefix(KeywordNotification.identifierPrefix) ? [.banner, .list, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let request = response.notification.request
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           request.identifier.hasPrefix(KeywordNotification.identifierPrefix),
           let raw = request.content.userInfo[KeywordNotification.topicKey] as? String,
           let url = URL(string: raw), Forum.topicID(url) != nil {
            Task { @MainActor [weak self] in self?.openKeywordTopic(url) }
        }
        completion()
    }

    private func openKeywordTopic(_ url: URL) {
        if let workspace, let workspaceWindow {
            _ = workspace.openTopicLink(url)
            NSApp.activate(ignoringOtherApps: true)
            workspaceWindow.makeKeyAndOrderFront(nil)
        } else {
            pendingKeywordTopic = url
        }
    }

}

private struct WorkspaceWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.onWindowChange = onWindowChange
    }

    final class WindowView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            controller = nil
            return
        }
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = updater
        updater.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func check() { guard !DeskProxyNetwork.shared.requiresProxy else { return }; controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle owns its downloader process and cannot share an app-only WebKit/URLSession route.
        // Suspend update checks in proxy mode rather than silently using another route.
        if DeskProxyNetwork.shared.requiresProxy {
            throw NSError(domain: "SeekDesk.Proxy", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "专用代理开启时暂停自动更新检查。请关闭代理后检查，或使用浏览器下载更新。"])
        }
    }
}

#if !SEEKDESK_FLUTTER
@main
struct SeekDeskApp: App {
    init() { ForumReportSizing.migratePreferences(); _ = DeskProxyController.shared }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace(fetchPage: ForumListing.fetch, fetchPeople: ForumDirectory.people)
    @StateObject private var updates = Updates()
    @StateObject private var extensions = DeskExtensions()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(DeskLogo.preference) private var selectedLogo = DeskLogo.cobalt

    var body: some Scene {
        Window("SeekDesk", id: "workspace") {
            WorkspaceView(workspace: workspace, updates: updates, extensions: extensions)
                .onAppear { extensions.startKeywordMonitoring() }
                .onChange(of: selectedLogo, initial: true) { _, logo in
                    NSApplication.shared.applicationIconImage = logo.dockImage
                }
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .background {
                    WorkspaceWindowReader { window in
                        appDelegate.bindWorkspace(workspace, window: window)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1300, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…", action: workspace.showSettings).keyboardShortcut(",")
                    .disabled(workspace.presentingContentOverlay)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updates.check).disabled(!updates.canCheck)
            }
            CommandMenu("浏览") {
                Button("搜索或打开帖子链接…", action: workspace.beginSearch).keyboardShortcut("k")
                    .disabled(workspace.presentingContentOverlay)
                Button("刷新帖子列表") { Task { await workspace.refresh() } }.keyboardShortcut("r")
                    .disabled(workspace.presentingContentOverlay)
                Button("在浏览器打开", action: workspace.openCurrentInBrowser)
                    .disabled(!workspace.inForum || workspace.presentingContentOverlay)
                Divider()
                Button("恢复关闭的帖子") { workspace.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(workspace.session.closedTopics.isEmpty || workspace.showingSearch || workspace.presentingOfficeCover || workspace.presentingContentOverlay)
                Menu("最近关闭") {
                    ForEach(workspace.session.closedTopics.reversed()) { entry in
                        Button(entry.topic.label) { workspace.reopenClosedTab(entry.id) }
                    }
                }.disabled(workspace.session.closedTopics.isEmpty || workspace.showingSearch || workspace.presentingOfficeCover || workspace.presentingContentOverlay)
                Divider()
                Button("切换版块导航") { workspace.showingSidebar.toggle() }
                    .disabled(workspace.presentingContentOverlay)
                Button("返回帖子列表", action: workspace.showList)
                    .disabled(!workspace.showReader || !workspace.inForum || workspace.presentingContentOverlay)
            }
        }
    }
}
#endif
