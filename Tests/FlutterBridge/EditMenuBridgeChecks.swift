import AppKit
import Foundation

@MainActor
private final class OriginalEditTarget: NSObject, NSMenuItemValidation {
    var enabled = true
    var validatedActions: [String] = []
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validatedActions.append(menuItem.action.map(NSStringFromSelector) ?? "nil")
        return enabled
    }
}

@main
struct EditMenuBridgeChecks {
    @MainActor
    static func main() {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }

        let menu = NSMenu(title: "Fixture")
        let edit = NSMenu(title: "Fixture edit")
        let container = NSMenuItem(title: "Fixture edit", action: nil, keyEquivalent: "")
        container.submenu = edit
        menu.addItem(container)
        let originalTarget = OriginalEditTarget()
        var items: [String: NSMenuItem] = [:]
        for command in NativeEditMenuBridge.commands.sorted() {
            let item = NSMenuItem(title: command, action: NSSelectorFromString(command + ":"), keyEquivalent: "")
            item.target = originalTarget
            edit.addItem(item)
            items[command] = item
        }
        let unknown = NSMenuItem(title: "Unknown", action: NSSelectorFromString("unknown:"), keyEquivalent: "")
        unknown.target = originalTarget
        edit.addItem(unknown)
        // The production XIB uses a nil target (First Responder), while some
        // native clients provide an explicit target. Exercise both forms.
        items["paste"]?.target = nil

        var flutter = true
        var requests: [(String, Any?, (Any?) -> Void)] = []
        var resolved: [(String, AnyObject?)] = []
        var sent: [(String, AnyObject)] = []
        var resolvedTarget: AnyObject? = originalTarget
        let bridge = NativeEditMenuBridge(menu: menu, invokeDart: { method, arguments, completion in
            requests.append((method, arguments, completion))
        }, routesToFlutter: { flutter }, resolveOriginal: { action, target, _ in
            resolved.append((NSStringFromSelector(action), target))
            return resolvedTarget
        }, dispatchOriginal: { action, target, _ in
            sent.append((NSStringFromSelector(action), target))
            return true
        })

        for (command, item) in items {
            require(item.target === bridge, "Only supported Edit items must be retargeted")
            require(item.action == NSSelectorFromString(command + ":"), "Standard selector must remain intact")
            require(!bridge.validateMenuItem(item), "No capabilities means disabled")
        }
        require(unknown.target === originalTarget, "Unknown action must retain its original target")
        require(!bridge.validateMenuItem(unknown), "Unknown commands are disabled in the bridge")
        require(NativeEditMenuBridge.command(for: NSSelectorFromString("copy")) == nil, "Missing colon rejected")
        print("PASS allowed Edit items only, unchanged selectors and unknown/initial disabled states")

        bridge.refreshCapabilities()
        require(requests.count == 1 && requests[0].0 == "capabilities" && requests[0].1 == nil, "Capabilities query")
        requests[0].2(["focusToken": 4, "commands": ["selectAll", "copy", "unknown"]])
        require(bridge.validateMenuItem(items["copy"]!), "Enabled copy capability")
        require(!bridge.validateMenuItem(items["paste"]!), "Absent paste capability disabled")
        bridge.copy(items["copy"]!)
        require(requests.count == 2 && requests[1].0 == "perform", "Menu uses perform rather than keyboard synthesis")
        let arguments = requests[1].1 as? [String: Any]
        require(arguments?["command"] as? String == "copy" && arguments?["focusToken"] as? Int64 == 4,
                "Command carries the cached focus token")
        bridge.paste(items["paste"]!)
        require(requests.count == 2, "Unavailable operation must not dispatch")
        requests[1].2(true)
        require(!bridge.validateMenuItem(items["copy"]!), "Perform completion invalidates capabilities")
        require(requests.count == 3 && requests[2].0 == "capabilities", "Perform completion refreshes capabilities")
        print("PASS command dispatch with focus token and fresh capability validation")

        let staleQuery = requests[2].2
        bridge.capabilitiesDidChange()
        require(requests.count == 4, "Changed starts fresh capability query")
        requests[3].2(["focusToken": 8, "commands": ["paste"]])
        staleQuery(["focusToken": 4, "commands": ["copy"]])
        require(bridge.validateMenuItem(items["paste"]!) && !bridge.validateMenuItem(items["copy"]!),
                "Older asynchronous result must not overwrite newer focus state")
        bridge.paste(items["paste"]!)
        require((requests.last!.1 as? [String: Any])?["focusToken"] as? Int64 == 8, "New focus token retained")
        print("PASS stale asynchronous capability replies cannot restore old focus permissions")

        let invalidTokens: [Any] = [true, -1, 0.5, Double.infinity, "1", NSNull(), 9_007_199_254_740_991]
        for token in invalidTokens {
            require(NativeEditMenuBridge.Capabilities(["focusToken": token, "commands": ["copy"]]) == nil,
                    "Malformed focus token rejected")
        }
        require(NativeEditMenuBridge.Capabilities(["focusToken": 0, "commands": ["copy"]]) != nil,
                "Zero token is valid")
        require(NativeEditMenuBridge.Capabilities(["focusToken": 1, "commands": ["unknown"]])?.commands.isEmpty == true,
                "Unknown capabilities are filtered")
        require(NativeEditMenuBridge.Capabilities(["focusToken": 1, "commands": "copy"]) == nil,
                "Malformed capability list rejected")
        print("PASS capability payload types, integer boundaries and command allowlist")

        flutter = false
        originalTarget.enabled = false
        require(!bridge.validateMenuItem(items["copy"]!), "Native validation must control native editor availability")
        originalTarget.enabled = true
        require(bridge.validateMenuItem(items["copy"]!), "Native responder can enable action independently of Dart cache")
        let dartCount = requests.count
        bridge.copy(items["copy"]!)
        require(requests.count == dartCount && sent.count == 1, "Native sheet/window routes only through original action")
        require(sent[0].0 == "copy:" && sent[0].1 === originalTarget, "Original selector and target forwarded")
        require(resolved.last?.1 === originalTarget && originalTarget.validatedActions.last == "copy:",
                "Original explicit target and standard selector used for validation")
        bridge.paste(items["paste"]!)
        require(resolved.last?.0 == "paste:" && resolved.last?.1 == nil,
                "A First Responder item must retain nil target for native responder-chain lookup")
        require(sent.count == 2 && sent[1].0 == "paste:" && requests.count == dartCount,
                "First Responder fallback uses original selector without sending Dart commands")
        resolvedTarget = bridge
        require(!bridge.validateMenuItem(items["copy"]!), "Resolver returning the bridge is rejected")
        bridge.copy(items["copy"]!)
        require(sent.count == 2, "Fallback must never recurse through the bridge")
        resolvedTarget = nil
        require(!bridge.validateMenuItem(items["copy"]!), "Missing original responder disables menu item")
        print("PASS native fallback validation/dispatch, original selector and recursion guard")

        bridge.stop()
        for (command, item) in items {
            require(command == "paste" ? item.target == nil : item.target === originalTarget,
                    "Stop restores original target, including First Responder")
        }
        staleQuery(["focusToken": 4, "commands": ["copy"]])
        require(!bridge.validateMenuItem(items["copy"]!), "Closed bridge ignores outstanding callbacks")
        print("PASS teardown restores original targets and rejects late callbacks")
    }
}
