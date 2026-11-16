import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  #if SEEKDESK_PROFILE_FIXTURE
  // This host has no service context, defaults, proxy controller or web view.
  // The single channel only asks the in-memory Dart state to approve closing.
  private var fixtureLifecycle: FlutterMethodChannel?
  private var fixtureKeyboardDiagnostics: FixtureKeyboardDiagnostics?
  #else
  private var seekDeskBridge: SeekDeskFlutterBridge?
  private var windowChromeBridge: NativeWindowChromeBridge?
  #endif
  private var editMenuBridge: NativeEditMenuBridge?
  private var closePending = false
  private(set) var closeApproved = false
  private var flushCallbacks: [(Bool) -> Void] = []
  private var flushDeadline: DispatchWorkItem?
  private var flushID: UUID?
  override var toolbar: NSToolbar? {
    didSet {
      #if !SEEKDESK_PROFILE_FIXTURE
      windowChromeBridge?.windowToolbarDidChange()
      #endif
    }
  }
  override func awakeFromNib() {
    let flutterViewController = ReaderWheelFlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    #if SEEKDESK_PROFILE_FIXTURE
    fixtureLifecycle = FlutterMethodChannel(
      name: "cc.seekdesk/native.methods.v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fixtureLifecycle?.setMethodCallHandler { _, result in
      result(FlutterError(code: "fixture_only",
        message: "The local benchmark host has no native services.", details: nil))
    }
    title = "SeekDesk Benchmark · 本地性能夹具"
    #else
    seekDeskBridge = SeekDeskFlutterBridge(controller: flutterViewController)
    title = "SeekDesk · Flutter 测试版"
    #endif
    minSize = NSSize(width: 780, height: 540)
    setContentSize(NSSize(width: 1380, height: 880))
    center()
    delegate = self
    (NSApp.delegate as? FlutterHostDelegate)?.bindWorkspace(self)

    super.awakeFromNib()
    editMenuBridge = NativeEditMenuBridge(controller: flutterViewController, window: self)
    #if !SEEKDESK_PROFILE_FIXTURE
    windowChromeBridge = NativeWindowChromeBridge(controller: flutterViewController, window: self) { [weak self] in
      guard let self else { return false }
      return !self.closePending && !self.closeApproved && self.flushCallbacks.isEmpty
    }
    #endif
    #if SEEKDESK_PROFILE_FIXTURE
    if FixtureKeyboardDiagnostics.isEnabled {
      fixtureKeyboardDiagnostics = FixtureKeyboardDiagnostics(window: self)
      fixtureKeyboardDiagnostics?.start()
    }
    #endif
  }

  @MainActor func openKeywordTopic(_ url: URL) -> Bool {
    #if SEEKDESK_PROFILE_FIXTURE
    return false
    #else
    guard let bridge = seekDeskBridge,
          bridge.context.workspace.openTopicLink(url) else { return false }
    bridge.context.emit(domain: "workspace", data: bridge.context.workspaceSnapshot())
    return true
    #endif
  }

  @MainActor func navigate(_ destination: String) {
    #if !SEEKDESK_PROFILE_FIXTURE
    seekDeskBridge?.navigate(destination)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    #endif
  }

  @MainActor func flushDrafts(completion: @escaping (Bool) -> Void) {
    flushCallbacks.append(completion)
    guard flushCallbacks.count == 1 else { return }
    let id = UUID()
    flushID = id
    #if SEEKDESK_PROFILE_FIXTURE
    guard let channel = fixtureLifecycle else { finishFlush(false, id: id); return }
    #else
    guard let bridge = seekDeskBridge else { finishFlush(false, id: id); return }
    #endif
    let deadline = DispatchWorkItem { [weak self] in self?.finishFlush(false, id: id) }
    flushDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    #if SEEKDESK_PROFILE_FIXTURE
    channel.invokeMethod("lifecycle.flush", arguments: nil) { [weak self] value in
      self?.finishFlush((value as? [String: Any])?["saved"] as? Bool == true, id: id)
    }
    #else
    bridge.flushDrafts { [weak self] saved in self?.finishFlush(saved, id: id) }
    #endif
  }

  @MainActor private func finishFlush(_ saved: Bool, id: UUID) {
    guard flushID == id, !flushCallbacks.isEmpty else { return }
    flushID = nil
    flushDeadline?.cancel()
    flushDeadline = nil
    let callbacks = flushCallbacks
    flushCallbacks.removeAll()
    callbacks.forEach { $0(saved) }
  }

  @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeApproved { return true }
    guard !closePending else { return false }
    closePending = true
    flushDrafts { [weak self] saved in
      guard let self else { return }
      self.closePending = false
      if saved {
        self.closeApproved = true
        self.performClose(nil)
      } else {
        self.showUnsavedEdits()
      }
    }
    return false
  }

  @MainActor func showUnsavedEdits() {
    guard attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = "有尚未保存的编辑"
    alert.informativeText = "请先保存或放弃编辑后退出。若草稿保存失败，请稍后重试。"
    alert.addButton(withTitle: "继续编辑")
    alert.beginSheetModal(for: self)
  }
}

#if SEEKDESK_PROFILE_FIXTURE
// Deliberately absent from production builds and off even in the fixture unless
// the explicit local flag exists. This observes AppKit routing without replacing
// menu actions, consuming keys, changing focus, or examining text/clipboard data.
private final class FixtureKeyboardDiagnostics {
  static var isEnabled: Bool {
    FileManager.default.fileExists(atPath: "/tmp/seekdesk-fixture-keyboard-enabled")
  }

  private static let logPath = "/tmp/seekdesk-fixture-keyboard.log"
  private static let menuActions: Set<String> = ["selectAll:", "copy:", "paste:", "cut:"]
  private weak var window: NSWindow?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var records: [[String: Any]] = []
  private var sequence = 0

  init(window: NSWindow) { self.window = window }

  func start() {
    record(stage: "start")
    _ = dump()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak self] event in
      if let self, let window = self.window,
         event.window === window || (event.window == nil && NSApp.keyWindow === window) {
        self.recordKey(event, stage: "localMonitor")
      }
      return event
    }
    let center = NotificationCenter.default
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) {
        [weak self] notification in
        guard let self else { return }
        self.record(stage: notification.name == NSApplication.didBecomeActiveNotification
          ? "app.becameActive" : "app.resignedActive")
        if notification.name == NSApplication.didResignActiveNotification { _ = self.dump() }
      })
    }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                 NSWindow.willCloseNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) {
        [weak self] notification in
        guard let self else { return }
        let stage = notification.name == NSWindow.didBecomeKeyNotification ? "window.becameKey"
          : notification.name == NSWindow.didResignKeyNotification ? "window.resignedKey" : "window.willClose"
        self.record(stage: stage)
        if notification.name != NSWindow.didBecomeKeyNotification { _ = self.dump() }
      })
    }
    for name in [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] notification in self?.recordMenu(notification)
      })
    }
  }

  private func recordKey(_ event: NSEvent, stage: String) {
    let knownKeys: [UInt16: String] = [0: "A", 8: "C", 9: "V", 7: "X"]
    var fields: [String: Any] = [
      "eventType": event.type == .keyDown ? "keyDown" : event.type == .keyUp ? "keyUp" : "flagsChanged",
      "key": knownKeys[event.keyCode] ?? "other",
      "flags": event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
      "meta": event.modifierFlags.contains(.command),
    ]
    // Arbitrary key codes could reconstruct typed content, so only these four
    // diagnostic command keys retain their numeric code. Never inspect characters.
    if knownKeys[event.keyCode] != nil { fields["keyCode"] = event.keyCode }
    record(stage: stage, fields: fields)
  }

  private func recordMenu(_ notification: Notification) {
    guard let window, NSApp.keyWindow === window || NSApp.mainWindow === window else { return }
    let item = notification.userInfo?.values.compactMap { $0 as? NSMenuItem }.first
      ?? (notification.object as? NSMenu)?.highlightedItem
    guard let item, let action = item.action else { return }
    let selector = NSStringFromSelector(action)
    guard Self.menuActions.contains(selector) else { return }
    // This is the responder-chain lookup at notification time, not an assertion
    // that a particular action implementation actually ran.
    let target = NSApp.target(forAction: action, to: item.target, from: item)
    record(stage: notification.name == NSMenu.willSendActionNotification ? "menu.willSend" : "menu.didSend",
      fields: ["selector": selector, "targetLookupClass": className(target as AnyObject?)])
  }

  private func className(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(describing: type(of: object))
  }

  private func record(stage: String, fields: [String: Any] = [:]) {
    sequence += 1
    var entry = fields
    entry["sequence"] = sequence
    entry["timestampMs"] = Int64(Date().timeIntervalSince1970 * 1000)
    entry["stage"] = stage
    entry["isActive"] = NSApp.isActive
    entry["isKeyWindow"] = window?.isKeyWindow == true
    entry["firstResponderClass"] = className(window?.firstResponder)
    records.append(entry)
    if records.count > 512 { records.removeFirst(records.count - 512) }
  }

  private func dump() -> Bool {
    do {
      var data = Data()
      for record in records {
        data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        data.append(0x0a)
      }
      try data.write(to: URL(fileURLWithPath: Self.logPath), options: [.atomic])
      return true
    } catch {
      return false
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }
}
#endif
