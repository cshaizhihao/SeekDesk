import AppKit
import CoreFoundation
import FlutterMacOS
import ImageIO

/// The toolbar has no service or navigation authority. This small, testable
/// protocol state only describes presentation and the current Flutter lease.
struct NativeWindowChromeState {
    enum Action: String, CaseIterable {
        case sidebar, home, search, back, office, notifications, account
    }

    struct Snapshot {
        let enabledActions: Set<Action>
        let compact: Bool
        let sidebarOpen: Bool
        let showBack: Bool
        let showOffice: Bool
        let officeLabel: String
        let officeCovered: Bool
        let accountLabel: String
        let accountName: String
        let unreadCount: Int
        let connecting: Bool
        let dark: Bool
        let appearance: String
        let palette: String
        let avatarBytes: Data?

        init?(_ value: Any?) {
            guard let data = value as? [String: Any],
                  let names = data["enabledActions"] as? [String],
                  names.count <= Action.allCases.count,
                  Set(names).count == names.count,
                  names.allSatisfy({ Action(rawValue: $0) != nil }),
                  let compact = NativeWindowChromeState.boolean(data["compact"]),
                  let sidebarOpen = NativeWindowChromeState.boolean(data["sidebarOpen"]),
                  let showBack = NativeWindowChromeState.boolean(data["showBack"]),
                  let showOffice = NativeWindowChromeState.boolean(data["showOffice"]),
                  let officeLabel = Self.text(data["officeLabel"], limit: 256),
                  let officeCovered = NativeWindowChromeState.boolean(data["officeCovered"]),
                  let accountLabel = Self.text(data["accountLabel"], limit: 256),
                  let accountName = Self.text(data["accountName"], limit: 160),
                  let unread = NativeWindowChromeState.integer(data["unreadCount"]),
                  let connecting = NativeWindowChromeState.boolean(data["connecting"]),
                  let dark = NativeWindowChromeState.boolean(data["dark"]),
                  let appearance = data["appearance"] as? String,
                  ["system", "light", "dark"].contains(appearance),
                  let palette = data["palette"] as? String,
                  ["Cobalt", "Teal", "Fern", "Iris", "Amber", "Coral"].contains(palette) else { return nil }
            let avatar: Data?
            if data["avatarBytes"] == nil || data["avatarBytes"] is NSNull {
                avatar = nil
            } else if let bytes = data["avatarBytes"] as? FlutterStandardTypedData,
                      bytes.elementSize == 1 {
                // Avatar decoding is optional presentation work. Oversized or
                // empty images must not take the navigation toolbar offline.
                avatar = !bytes.data.isEmpty && bytes.data.count <= 2 * 1024 * 1024 ? bytes.data : nil
            } else {
                return nil
            }
            self.compact = compact
            self.sidebarOpen = sidebarOpen
            self.dark = dark
            self.appearance = appearance
            self.palette = palette
            self.officeCovered = officeCovered
            // A stale or inconsistent Dart snapshot must never expose account
            // information or clickable forum controls through the office cover.
            self.enabledActions = officeCovered ? [] : Set(names.compactMap(Action.init(rawValue:)))
            self.showBack = !officeCovered && showBack
            self.showOffice = !officeCovered && showOffice
            self.officeLabel = officeCovered ? "" : officeLabel
            self.accountLabel = officeCovered ? "" : accountLabel
            self.accountName = officeCovered ? "" : accountName
            self.unreadCount = officeCovered ? 0 : Int(unread)
            self.connecting = !officeCovered && connecting
            self.avatarBytes = officeCovered ? nil : avatar
        }

        func allows(_ action: Action) -> Bool {
            guard !officeCovered, enabledActions.contains(action) else { return false }
            if action == .back && !showBack { return false }
            if action == .office && !showOffice { return false }
            return true
        }

        private static func text(_ value: Any?, limit: Int) -> String? {
            guard let value = value as? String else { return nil }
            // These are display labels, not authorization. Older preferences
            // permit long or multiline office button names; normalize only the
            // presentation instead of invalidating navigation or saving edits.
            var scalars = String.UnicodeScalarView()
            for scalar in value.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    scalars.append(" ")
                } else if scalar.properties.generalCategory != .control {
                    scalars.append(scalar)
                }
            }
            let singleLine = String(scalars).split(separator: " ").joined(separator: " ")
            guard singleLine.utf8.count > limit else { return singleLine }
            var truncated = ""
            var byteCount = 0
            for character in singleLine {
                let size = String(character).utf8.count
                guard byteCount + size <= limit - 3 else { break }
                truncated.append(character)
                byteCount += size
            }
            return truncated.trimmingCharacters(in: .whitespaces) + "…"
        }
    }

    private(set) var attachment: String?
    private(set) var generation: Int64 = -1
    private(set) var snapshot: Snapshot?

    mutating func attach(_ value: Any?) -> [String: Any]? {
        guard let data = value as? [String: Any],
              Set(data.keys) == ["protocol"], Self.integer(data["protocol"]) == 1 else { return nil }
        let id = UUID().uuidString
        attachment = id
        generation = -1
        snapshot = nil
        return ["installed": true, "attachment": id]
    }

    mutating func update(_ value: Any?) -> Bool {
        guard let data = value as? [String: Any],
              Set(data.keys) == ["attachment", "generation", "snapshot"],
              let id = data["attachment"] as? String, id == attachment,
              let next = Self.integer(data["generation"]), next > generation,
              let snapshot = Snapshot(data["snapshot"]) else { return false }
        generation = next
        self.snapshot = snapshot
        return true
    }

    mutating func detach(_ value: Any?) -> Bool {
        guard let data = value as? [String: Any], Set(data.keys) == ["attachment"],
              let id = data["attachment"] as? String, id == attachment else { return false }
        reset()
        return true
    }

    mutating func reset() {
        attachment = nil
        generation = -1
        snapshot = nil
    }

    func performArguments(for action: Action) -> [String: Any]? {
        guard let attachment, generation >= 0, snapshot?.allows(action) == true else { return nil }
        return ["attachment": attachment, "generation": generation, "action": action.rawValue]
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let integer = Int64(number.stringValue), integer >= 0,
              integer <= 9_007_199_254_740_991 else { return nil }
        return integer
    }
}

/// AppKit supplies the actual toolbar/titlebar material and button behavior.
/// Flutter still owns route guards, input focus, account state and all actions.
@MainActor
final class NativeWindowChromeBridge: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    private typealias Action = NativeWindowChromeState.Action
    // Avoid NSObject.perform(_:): an unqualified #selector(perform(_:))
    // resolves to performSelector:, which interprets the button as a selector.
    nonisolated static var toolbarActionSelector: Selector { #selector(performToolbarAction(_:)) }
    private struct OriginalChrome {
        let toolbar: NSToolbar?
        let style: NSWindow.ToolbarStyle
        let title: String
        let titleVisibility: NSWindow.TitleVisibility
        let transparentTitlebar: Bool
        let appearance: NSAppearance?
    }

    private weak var window: NSWindow?
    private let channel: FlutterMethodChannel
    private let allowsWindowActions: () -> Bool
    private var state = NativeWindowChromeState()
    private var original: OriginalChrome?
    private var toolbar: NSToolbar?
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var accountWidth: NSLayoutConstraint?
    private var avatarBytes: Data?
    private var avatarImage: NSImage?
    private var logoKey: String?
    private var visibilityObservation: NSKeyValueObservation?
    private var connectionAnimating = false
    private var observations: [NSObjectProtocol] = []
    private var stopped = false
    private static let connectionID = NSToolbarItem.Identifier("connecting")

    init(controller: FlutterViewController, window: NSWindow, allowsWindowActions: @escaping () -> Bool) {
        self.window = window
        self.allowsWindowActions = allowsWindowActions
        channel = FlutterMethodChannel(name: "cc.seekdesk/window-chrome.v1",
                                       binaryMessenger: controller.engine.binaryMessenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self, !self.stopped else {
                result(FlutterError(code: "disposed", message: "The window is closed.", details: nil))
                return
            }
            self.receive(call, result: result)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            observations.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.validateItems() }
            })
        }
        observations.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        })
    }

    private func receive(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "attach":
            guard let window, window.styleMask.contains(.titled),
                  let reply = state.attach(call.arguments) else {
                result(FlutterError(code: "invalid_arguments", message: "Unsupported window chrome attachment.", details: nil))
                return
            }
            if original == nil {
                original = OriginalChrome(toolbar: window.toolbar, style: window.toolbarStyle,
                                          title: window.title, titleVisibility: window.titleVisibility,
                                          transparentTitlebar: window.titlebarAppearsTransparent,
                                          appearance: window.appearance)
            }
            installToolbar(on: window)
            render()
            result(reply)
        case "update":
            guard state.update(call.arguments) else { result(false); return }
            render()
            result(true)
        case "detach":
            guard state.detach(call.arguments) else { result(false); return }
            restoreChrome()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func installToolbar(on window: NSWindow) {
        if toolbar == nil {
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cc.seekdesk.window." + UUID().uuidString))
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
            self.toolbar = toolbar
        }
        guard let toolbar else { return }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        // Keep system material and content-layout geometry. No full-size
        // content overlay, manual vibrancy view or first-responder changes.
        window.titlebarAppearsTransparent = false
        window.toolbar = toolbar
        toolbar.isVisible = true
        // NSToolbar.h explicitly documents visibility KVO on macOS 14+,
        // which is the Flutter host's minimum supported macOS version.
        visibilityObservation?.invalidate()
        visibilityObservation = toolbar.observe(\.isVisible, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.toolbar === observed, !observed.isVisible else { return }
                self.revokeHiddenChrome()
            }
        }
    }

    private var canPerform: Bool {
        guard !stopped, let window, window.toolbar === toolbar,
              toolbar?.isVisible == true, NSApp.keyWindow === window,
              window.attachedSheet == nil, !window.isMiniaturized,
              allowsWindowActions() else { return false }
        return true
    }

    private func isEnabled(_ action: Action) -> Bool {
        canPerform && state.performArguments(for: action) != nil
    }

    private var desiredItems: [NSToolbarItem.Identifier] {
        guard state.snapshot?.officeCovered != true else { return [] }
        var result = [identifier(.sidebar), identifier(.home), .flexibleSpace]
        if state.snapshot?.showBack == true { result.append(identifier(.back)) }
        result.append(identifier(.search))
        if state.snapshot?.connecting == true { result.append(Self.connectionID) }
        if state.snapshot?.showOffice == true { result.append(identifier(.office)) }
        result += [identifier(.notifications), identifier(.account)]
        return result
    }

    private func render() {
        guard let window, let toolbar else { return }
        let snapshot = state.snapshot
        let covered = snapshot?.officeCovered == true
        let title = covered ? "工作计划" : (original?.title ?? "SeekDesk")
        if window.title != title { window.title = title }
        window.titleVisibility = covered ? .visible : .hidden
        if let snapshot {
            // Clearing the override is essential in system mode; otherwise
            // effectiveAppearance and Flutter brightness can become pinned.
            if snapshot.appearance == "system" {
                if window.appearance != nil { window.appearance = nil }
            } else {
                let appearance: NSAppearance.Name = snapshot.dark ? .darkAqua : .aqua
                if window.appearance?.name != appearance { window.appearance = NSAppearance(named: appearance) }
            }
        }
        let desired = desiredItems
        if toolbar.items.map(\.itemIdentifier) != desired {
            // Reconcile in place on macOS 14 too; ordinary state updates must
            // not reconstruct controls or restart AppKit material transitions.
            for (index, id) in desired.enumerated() {
                if toolbar.items.indices.contains(index), toolbar.items[index].itemIdentifier == id { continue }
                if let previous = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
                    toolbar.removeItem(at: previous)
                }
                toolbar.insertItem(withItemIdentifier: id, at: index)
            }
            while toolbar.items.count > desired.count { toolbar.removeItem(at: toolbar.items.count - 1) }
        }
        if covered {
            // Clear detached custom views as well as the visible titlebar, so
            // overflow menus and later attachments cannot retain account data.
            setConnectionAnimating(false)
            items.removeAll()
            accountWidth = nil
            avatarBytes = nil
            avatarImage = nil
            logoKey = nil
            return
        }
        setConnectionAnimating(snapshot?.connecting == true)
        configureItems(snapshot)
        validateItems()
    }

    private func configureItems(_ snapshot: NativeWindowChromeState.Snapshot?) {
        let sidebar = item(.sidebar)
        let sidebarTitle: String
        if snapshot?.compact == true {
            sidebarTitle = snapshot?.sidebarOpen == true ? "关闭导航" : "打开导航"
        } else {
            sidebarTitle = snapshot?.sidebarOpen == true ? "收起侧栏" : "展开侧栏"
        }
        describe(sidebar, title: sidebarTitle)
        let home = item(.home)
        if let button = home.view as? NSButton {
            let logo = DeskLogo(rawValue: snapshot?.palette ?? "Cobalt") ?? .cobalt
            let dark = snapshot?.dark ?? false
            let key = "\(logo.rawValue):\(dark)"
            if logoKey != key {
                logoKey = key
                button.image = (logo.image(dark: dark) ?? DeskLogo.cobalt.image(dark: dark))?.copy() as? NSImage
                button.image?.size = NSSize(width: 87, height: 28)
                button.title = button.image == nil ? "SeekDesk" : ""
            }
        }
        if let search = item(.search).view as? NSButton {
            let title = snapshot?.compact == true ? "搜索" : "搜索帖子"
            if search.title != title { search.title = title }
        }
        describe(item(.office), title: snapshot?.officeLabel.isEmpty == false ? snapshot!.officeLabel : "切换办公视图")
        let unread = snapshot?.unreadCount ?? 0
        let notifications = item(.notifications)
        describe(notifications, title: unread == 0 ? "消息" : "消息，\(unread) 条未读")
        if #available(macOS 26.0, *) {
            notifications.badge = unread == 0 ? nil : (unread > 99 ? .text("99+") : .count(unread))
        } else {
            // Older systems have no native item badges. An explicit native
            // button title keeps the count visible without a custom overlay.
            if let button = notifications.view as? NSButton {
                button.title = unread == 0 ? "" : (unread > 99 ? "99+" : String(unread))
                button.imagePosition = unread == 0 ? .imageOnly : .imageLeading
            }
        }
        let account = item(.account)
        let label = snapshot?.accountLabel.isEmpty == false ? snapshot!.accountLabel : "账号"
        describe(account, title: label)
        if let button = account.view as? NSButton {
            if avatarBytes != snapshot?.avatarBytes {
                avatarBytes = snapshot?.avatarBytes
                avatarImage = avatarBytes.flatMap(Self.avatar)
            }
            button.image = avatarImage ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            let compact = snapshot?.compact == true
            let name = compact ? "" : (snapshot?.accountName.isEmpty == false ? snapshot!.accountName : "账号")
            if button.title != name { button.title = name }
            button.imagePosition = name.isEmpty ? .imageOnly : .imageLeading
            let width: CGFloat = compact ? 36 : 144
            if accountWidth?.constant != width { accountWidth?.constant = width }
        }
    }

    private func item(_ action: Action) -> NSToolbarItem {
        let id = identifier(action)
        if let item = items[id] { return item }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.action = Self.toolbarActionSelector
        item.isBordered = true
        item.autovalidates = true
        item.isEnabled = false
        let symbol: String
        let label: String
        switch action {
        case .sidebar: symbol = "sidebar.left"; label = "侧栏"
        case .home: symbol = "house"; label = "SeekDesk 首页"
        case .search: symbol = "magnifyingglass"; label = "搜索帖子或打开链接"
        case .back: symbol = "chevron.left"; label = "返回论坛"
        case .office: symbol = "tablecells"; label = "切换办公视图"
        case .notifications: symbol = "bell"; label = "消息"
        case .account: symbol = "person.crop.circle"; label = "账号"
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.visibilityPriority = action == .home ? .low : .high
        if action == .home || action == .account {
            let button = makeButton(action, symbol: symbol)
            item.view = button
            let width = button.widthAnchor.constraint(equalToConstant: action == .home ? 99 : 144)
            width.isActive = true
            if action == .account { accountWidth = width }
            if action == .home { button.isBordered = false }
        } else if action == .search || action == .back {
            let button = makeButton(action, symbol: symbol)
            button.title = action == .search ? "搜索帖子" : "返回论坛"
            button.imagePosition = .imageLeading
            item.view = button
        } else if action == .notifications {
            if #available(macOS 26.0, *) {
                // The standard item draws its badge and material itself.
            } else {
                item.view = makeButton(action, symbol: symbol)
            }
        }
        describe(item, title: label)
        items[id] = item
        return item
    }

    private func makeButton(_ action: Action, symbol: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: Self.toolbarActionSelector)
        button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        button.bezelStyle = .toolbar
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.lineBreakMode = .byTruncatingTail
        button.isEnabled = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func describe(_ item: NSToolbarItem, title: String) {
        Self.bindMenuRepresentation(of: item, title: title, target: self)
        guard item.label != title else { return }
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.view?.setAccessibilityLabel(title)
    }

    static func bindMenuRepresentation(of item: NSToolbarItem, title: String, target: AnyObject) {
        // AppKit may supply a default overflow item without our action identity.
        // Bind both generated and existing items, including unchanged labels.
        let menu = item.menuFormRepresentation ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if menu.title != title { menu.title = title }
        menu.target = target
        menu.action = toolbarActionSelector
        menu.representedObject = item.itemIdentifier.rawValue
        if item.menuFormRepresentation !== menu { item.menuFormRepresentation = menu }
    }

    private func identifier(_ action: Action) -> NSToolbarItem.Identifier { .init(action.rawValue) }

    private func action(from sender: Any?) -> Action? {
        let raw = (sender as? NSToolbarItem)?.itemIdentifier.rawValue
            ?? (sender as? NSView)?.identifier?.rawValue
            ?? ((sender as? NSMenuItem)?.representedObject as? String)
        return raw.flatMap(Action.init(rawValue:))
    }

    @objc private func performToolbarAction(_ sender: Any?) {
        guard canPerform, let action = action(from: sender),
              let args = state.performArguments(for: action) else { return }
        // Never activate a window, move first responder, or dispatch a backend
        // operation here. Dart revalidates this lease against its current route.
        channel.invokeMethod("perform", arguments: args) { [weak self] _ in
            self?.validateItems()
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = Action(rawValue: item.itemIdentifier.rawValue) else { return false }
        return isEnabled(action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = action(from: menuItem) else { return false }
        return isEnabled(action)
    }

    private func validateItems() {
        for action in Action.allCases {
            guard let item = items[identifier(action)] else { continue }
            let enabled = isEnabled(action)
            item.isEnabled = enabled
            (item.view as? NSControl)?.isEnabled = enabled
            item.menuFormRepresentation?.isEnabled = enabled
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Action.allCases.map(identifier) + [.flexibleSpace, Self.connectionID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { desiredItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let action = Action(rawValue: itemIdentifier.rawValue) { return item(action) }
        guard itemIdentifier == Self.connectionID else { return nil }
        if let item = items[itemIdentifier] { return item }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        indicator.setAccessibilityLabel("正在连接")
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "正在连接"
        item.toolTip = "正在连接"
        item.view = indicator
        items[itemIdentifier] = item
        return item
    }

    private static func avatar(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = metadata[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 4096, height.doubleValue <= 4096,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.addEllipse(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        context.clip()
        let scale = max(64 / CGFloat(thumbnail.width), 64 / CGFloat(thumbnail.height))
        let size = CGSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
        context.draw(thumbnail, in: CGRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2,
                                          width: size.width, height: size.height))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 22, height: 22))
    }

    private func setConnectionAnimating(_ active: Bool) {
        guard connectionAnimating != active,
              let indicator = items[Self.connectionID]?.view as? NSProgressIndicator else { return }
        connectionAnimating = active
        if active { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
    }

    /// NSWindow does not document toolbar KVO. MainFlutterWindow instead calls
    /// this from its toolbar property observer, avoiding an unsupported observer.
    func windowToolbarDidChange() {
        guard let toolbar, window?.toolbar !== toolbar else { return }
        revokeHiddenChrome(replaceToolbar: false)
    }

    private func revokeHiddenChrome(replaceToolbar: Bool = true) {
        guard !stopped, let attachment = state.attachment else { return }
        state.reset()
        restoreChrome(replaceToolbar: replaceToolbar)
        channel.invokeMethod("detached", arguments: ["attachment": attachment])
    }

    private func restoreChrome(replaceToolbar: Bool = true) {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        setConnectionAnimating(false)
        // Clear our reference before setting NSWindow.toolbar: its observer
        // must not mistake intentional restoration for an external removal.
        let ownedToolbar = toolbar
        toolbar = nil
        if let window, let original {
            if replaceToolbar { window.toolbar = original.toolbar }
            window.toolbarStyle = original.style
            window.title = original.title
            window.titleVisibility = original.titleVisibility
            window.titlebarAppearsTransparent = original.transparentTitlebar
            window.appearance = original.appearance
        }
        ownedToolbar?.delegate = nil
        original = nil
        items.removeAll()
        accountWidth = nil
        avatarBytes = nil
        avatarImage = nil
        logoKey = nil
        connectionAnimating = false
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        state.reset()
        channel.setMethodCallHandler(nil)
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        restoreChrome()
    }

    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
}
