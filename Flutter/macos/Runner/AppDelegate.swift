import Cocoa
import FlutterMacOS
import UserNotifications

@main
@MainActor
class FlutterHostDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NativeUpdateInstalling {
  private weak var workspaceWindow: MainFlutterWindow?
  private var pendingKeywordTopic: URL?
  private var terminationPending = false
  #if !SEEKDESK_PROFILE_FIXTURE
  private var updates: NativeAppUpdater?
  #endif

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    #if !SEEKDESK_PROFILE_FIXTURE
    // Register delivery only. Permission is requested by the explicit extension
    // preference, never just by launching this isolated preview application.
    UNUserNotificationCenter.current().delegate = self
    #endif
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Flutter's registrar observes the launch notification itself. The parent
    // does not implement this optional delegate method; a super call raises an
    // ObjC exception and skips our window/update-menu initialization.
    if let window = NSApp.windows.compactMap({ $0 as? MainFlutterWindow }).first {
      bindWorkspace(window)
    }
    #if !SEEKDESK_PROFILE_FIXTURE
    if Bundle.main.bundleIdentifier == "com.seekdesk.client" {
      updates = NativeAppUpdater { [weak self] completion in
        guard let window = self?.workspaceWindow else { completion(false); return }
        window.flushDrafts { saved in
          if !saved { window.showUnsavedEdits() }
          completion(saved)
        }
      }
    }
    let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
    updateItem.target = self
    applicationMenu?.insertItem(updateItem, at: 1)
    #endif
  }

  @IBAction func showSettings(_ sender: Any?) {
    workspaceWindow?.navigate("settings")
  }

  @objc private func checkForUpdates(_ sender: Any?) {
    #if !SEEKDESK_PROFILE_FIXTURE
    updates?.check()
    #endif
  }

  func installAvailableUpdate() async throws {
    #if SEEKDESK_PROFILE_FIXTURE
    throw NativeBridgeError(code: "update_unavailable", message: "此版本不支持应用内更新。")
    #else
    guard !DeskProxyNetwork.shared.requiresProxy else {
      throw NativeBridgeError(code: "update_proxy", message: "请先关闭 SeekDesk 专用代理，再重试应用内更新。")
    }
    guard let updates, let workspaceWindow, updates.canCheck else {
      throw NativeBridgeError(code: "update_unavailable", message: "更新程序暂时不可用，请稍后重试。")
    }
    let saved = await withCheckedContinuation { continuation in
      workspaceWindow.flushDrafts { continuation.resume(returning: $0) }
    }
    guard saved else {
      throw NativeBridgeError(code: "update_unsaved", message: "当前修改尚未保存。请先保存草稿，再重试更新。")
    }
    guard updates.canCheck, !DeskProxyNetwork.shared.requiresProxy else {
      throw NativeBridgeError(code: "update_unavailable", message: "更新程序暂时不可用，请稍后重试。")
    }
    updates.check(install: true)
    #endif
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    #if SEEKDESK_PROFILE_FIXTURE
    if menuItem.action == #selector(checkForUpdates(_:)) ||
       menuItem.action == #selector(showSettings(_:)) { return false }
    #else
    if menuItem.action == #selector(checkForUpdates(_:)) { return updates?.canCheck == true }
    if menuItem.action == #selector(showSettings(_:)) { return workspaceWindow != nil }
    #endif
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = workspaceWindow, !window.closeApproved else { return .terminateNow }
    if terminationPending { return .terminateLater }
    terminationPending = true
    window.flushDrafts { [weak self, weak window] saved in
      self?.terminationPending = false
      sender.reply(toApplicationShouldTerminate: saved)
      if !saved { window?.showUnsavedEdits() }
    }
    return .terminateLater
  }

  func bindWorkspace(_ window: MainFlutterWindow) {
    workspaceWindow = window
    if let topic = pendingKeywordTopic {
      pendingKeywordTopic = nil
      openKeywordTopic(topic)
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
    completion(notification.request.identifier.hasPrefix(KeywordNotification.identifierPrefix)
      ? [.banner, .list, .sound] : [])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
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

  @MainActor private func openKeywordTopic(_ url: URL) {
    guard let window = workspaceWindow else {
      pendingKeywordTopic = url
      return
    }
    guard window.openKeywordTopic(url) else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.deminiaturize(nil)
    window.makeKeyAndOrderFront(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
