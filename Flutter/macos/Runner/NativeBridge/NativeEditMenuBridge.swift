import AppKit
import CoreFoundation
import Foundation
#if canImport(FlutterMacOS)
import FlutterMacOS
#endif

/// The native Edit menu must invoke Flutter Actions, not the hidden NSTextView
/// used by Flutter's IME. Keyboard delivery remains entirely owned by Flutter.
@MainActor
final class NativeEditMenuBridge: NSObject, NSMenuItemValidation {
    nonisolated static let commands: Set<String> = [
        "selectAll", "copy", "cut", "paste", "pasteAsPlainText", "undo", "redo", "delete"
    ]

    struct Capabilities {
        let focusToken: Int64
        let commands: Set<String>

        init?(_ value: Any?) {
            guard let value = value as? [String: Any],
                  let number = value["focusToken"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < 9_007_199_254_740_991,
                  number.doubleValue.rounded() == number.doubleValue,
                  let names = value["commands"] as? [String] else { return nil }
            focusToken = number.int64Value
            commands = Set(names).intersection(NativeEditMenuBridge.commands)
        }
    }

    typealias InvokeDart = (String, Any?, @escaping (Any?) -> Void) -> Void
    typealias ResolveOriginal = (Selector, AnyObject?, NSMenuItem) -> AnyObject?
    typealias DispatchOriginal = (Selector, AnyObject, NSMenuItem) -> Bool

    private final class OriginalItem {
        weak var item: NSMenuItem?
        weak var target: AnyObject?
        let action: Selector
        let command: String

        init(item: NSMenuItem, action: Selector, command: String) {
            self.item = item
            target = item.target
            self.action = action
            self.command = command
        }
    }

    private let invokeDart: InvokeDart
    private let routesToFlutter: () -> Bool
    private let resolveOriginal: ResolveOriginal
    private let dispatchOriginal: DispatchOriginal
    private var originals: [ObjectIdentifier: OriginalItem] = [:]
    private weak var editMenu: NSMenu?
    private var capabilities: Capabilities?
    private var generation = 0
    private var stopped = false
    private var observations: [NSObjectProtocol] = []
    #if canImport(FlutterMacOS)
    private var channel: FlutterMethodChannel?
    #endif

    /// Injectable routing keeps the native fallback testable without starting
    /// NSApplication, opening a window, or reading the system clipboard.
    init(menu: NSMenu, invokeDart: @escaping InvokeDart,
         routesToFlutter: @escaping () -> Bool,
         resolveOriginal: @escaping ResolveOriginal,
         dispatchOriginal: @escaping DispatchOriginal) {
        self.invokeDart = invokeDart
        self.routesToFlutter = routesToFlutter
        self.resolveOriginal = resolveOriginal
        self.dispatchOriginal = dispatchOriginal
        super.init()
        install(in: menu)
    }

    #if canImport(FlutterMacOS)
    convenience init(controller: FlutterViewController, window: NSWindow) {
        let channel = FlutterMethodChannel(name: "cc.seekdesk/edit-menu.v1",
                                          binaryMessenger: controller.engine.binaryMessenger)
        self.init(menu: NSApp.mainMenu ?? NSMenu(),
                  invokeDart: { method, arguments, completion in
                      channel.invokeMethod(method, arguments: arguments, result: completion)
                  },
                  routesToFlutter: { [weak controller, weak window] in
                      guard let window, let controller, NSApp.keyWindow === window,
                            window.attachedSheet == nil,
                            let responder = window.firstResponder as? NSView else { return false }
                      return responder === controller.view || responder.isDescendant(of: controller.view)
                  },
                  resolveOriginal: { action, target, item in
                      NSApp.target(forAction: action, to: target, from: item) as AnyObject?
                  },
                  dispatchOriginal: { action, target, item in
                      NSApp.sendAction(action, to: target, from: item)
                  })
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "changed" else { result(FlutterMethodNotImplemented); return }
            guard call.arguments == nil || call.arguments is NSNull else {
                result(FlutterError(code: "invalid_arguments", message: "changed takes no arguments", details: nil))
                return
            }
            self?.capabilitiesDidChange()
            result(nil)
        }
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCapabilities() }
        })
        observations.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.capabilitiesDidChange() }
        })
        observations.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                                object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidateCapabilities() }
        })
        observations.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                                object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        })
        // Main-menu outlets and the Dart handler can become available after the
        // window's awakeFromNib. Retry installation once without rebuilding it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if self.editMenu == nil, let menu = NSApp.mainMenu { self.install(in: menu) }
            self.refreshCapabilities()
        }
    }
    #endif

    private func install(in menu: NSMenu) {
        guard editMenu == nil, let edit = Self.findEditMenu(in: menu) else { return }
        editMenu = edit
        for item in edit.items {
            guard let action = item.action, let command = Self.command(for: action) else { continue }
            originals[ObjectIdentifier(item)] = OriginalItem(item: item, action: action, command: command)
            // Keep titles, key equivalents, selectors and the menu's delegate.
            item.target = self
        }
    }

    private static func findEditMenu(in menu: NSMenu) -> NSMenu? {
        let actions = Set(menu.items.compactMap { $0.action.map(NSStringFromSelector) })
        if Set(["selectAll:", "copy:", "cut:", "paste:"]).isSubset(of: actions) { return menu }
        return menu.items.compactMap(\.submenu).compactMap { findEditMenu(in: $0) }.first
    }

    static func command(for selector: Selector) -> String? {
        let name = NSStringFromSelector(selector)
        guard name.hasSuffix(":"), commands.contains(String(name.dropLast())) else { return nil }
        return String(name.dropLast())
    }

    func capabilitiesDidChange() {
        invalidateCapabilities()
        refreshCapabilities()
    }

    private func invalidateCapabilities() {
        generation += 1
        capabilities = nil
    }

    func refreshCapabilities() {
        guard !stopped, routesToFlutter() else { return }
        generation += 1
        let request = generation
        invokeDart("capabilities", nil) { [weak self] value in
            guard let self, !self.stopped, request == self.generation else { return }
            self.capabilities = Capabilities(value)
            self.editMenu?.update()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !stopped, let original = originals[ObjectIdentifier(menuItem)] else { return false }
        if routesToFlutter() { return capabilities?.commands.contains(original.command) == true }
        guard let target = originalTarget(original, item: menuItem) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(menuItem) }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(menuItem)
        }
        return true
    }

    private func originalTarget(_ original: OriginalItem, item: NSMenuItem) -> AnyObject? {
        guard let target = resolveOriginal(original.action, original.target, item), target !== self else { return nil }
        return target
    }

    private func perform(_ sender: Any?) {
        guard !stopped, let item = sender as? NSMenuItem,
              let original = originals[ObjectIdentifier(item)] else { return }
        guard routesToFlutter() else {
            if let target = originalTarget(original, item: item) {
                _ = dispatchOriginal(original.action, target, item)
            }
            return
        }
        guard let capabilities, capabilities.commands.contains(original.command) else { return }
        invokeDart("perform", ["command": original.command, "focusToken": capabilities.focusToken]) { [weak self] _ in
            self?.capabilitiesDidChange()
        }
    }

    @objc func selectAll(_ sender: Any?) { perform(sender) }
    @objc func copy(_ sender: Any?) { perform(sender) }
    @objc func cut(_ sender: Any?) { perform(sender) }
    @objc func paste(_ sender: Any?) { perform(sender) }
    @objc func pasteAsPlainText(_ sender: Any?) { perform(sender) }
    @objc func undo(_ sender: Any?) { perform(sender) }
    @objc func redo(_ sender: Any?) { perform(sender) }
    @objc func delete(_ sender: Any?) { perform(sender) }

    func stop() {
        guard !stopped else { return }
        stopped = true
        invalidateCapabilities()
        for original in originals.values {
            if let item = original.item, item.target === self { item.target = original.target }
        }
        originals.removeAll()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        #if canImport(FlutterMacOS)
        channel?.setMethodCallHandler(nil)
        #endif
    }

    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
}
