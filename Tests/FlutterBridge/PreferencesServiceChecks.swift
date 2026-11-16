import Foundation

@main
struct PreferencesServiceChecks {
    @MainActor
    static func main() async throws {
        let suite = "cc.seekdesk.qa.preferences-bridge." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        // Preinstall proxy in the isolated defaults. Calling install(proxy) would
        // intentionally notify the production shared controller, so do not do it.
        defaults.set(["proxy", "hot"], forKey: "extensions.installed")
        defaults.set(["proxy", "hot"], forKey: "extensions.enabled")
        var vault = DeskProxyVault.State(nodes: [], subscriptions: [])
        let proxy = DeskProxyController(defaults: defaults, readVault: { vault }, saveVault: { nodes, sources in
            vault = .init(nodes: nodes, subscriptions: sources)
        }, fetchSubscription: { _ in throw DeskProxyError.invalid("Fixture fetch disabled") },
           measureNode: { _ in 42 })
        let context = SeekDeskBridgeContext(defaults: defaults, proxy: proxy)
        var openedSettingsURLs: [URL] = []
        var settingsCanOpen = true
        let service = NativePreferencesServices(context: context, openSystemSettings: { url in
            openedSettingsURLs.append(url)
            return settingsCanOpen
        })

        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { fatalError(label) }
        }
        func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
        func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
        func failure(_ method: String, _ args: [String: Any], code: String) async throws {
            do {
                _ = try await service.handle(method, args)
                fatalError("Expected \(code): \(method)")
            } catch let issue as NativeBridgeError { require(issue.code == code, "Wrong error: \(issue.code)") }
        }

        let initial = service.settingsSnapshot()
        require(initial["workspace.readerTextSize"] as? Double == 15, "Reader default")
        require(initial["workspace.autoRefresh"] as? Bool == true, "Boolean default")
        require(initial["workspace.sidebarSection"] as? String == "ranking", "Missing sidebar section defaults to ranking")
        for section in ["boards", "shortcuts", "ranking", "none"] {
            let updated = map(try await service.handle("settings.update", ["key": "workspace.sidebarSection", "value": section]))
            require(defaults.string(forKey: "workspace.sidebarSection") == section, "Sidebar section persists immediately")
            require(updated["workspace.sidebarSection"] as? String == section &&
                    service.settingsSnapshot()["workspace.sidebarSection"] as? String == section,
                    "Sidebar snapshot must round-trip every supported value")
        }
        let invalidSections: [Any] = ["", "review", "Boards", 1, true, ["boards"], NSNull()]
        for section in invalidSections {
            try await failure("settings.update", ["key": "workspace.sidebarSection", "value": section], code: "invalid_arguments")
            require(defaults.string(forKey: "workspace.sidebarSection") == "none", "Rejected sidebar writes must retain the saved choice")
        }
        let malformedStoredSections: [Any] = ["invalid", 42, true, ["boards"]]
        for section in malformedStoredSections {
            defaults.set(section, forKey: "workspace.sidebarSection")
            require(service.settingsSnapshot()["workspace.sidebarSection"] as? String == "ranking",
                    "Malformed legacy sidebar preferences must have a safe snapshot fallback")
        }
        defaults.removeObject(forKey: "workspace.sidebarSection")
        print("PASS sidebar section default, valid persistence, invalid write rejection and legacy fallback")
        _ = try await service.handle("settings.update", ["key": "workspace.readerTextSize", "value": 20])
        require(defaults.double(forKey: "workspace.readerTextSize") == 20, "Existing key retained")
        try await failure("settings.update", ["key": "forum.drafts.v1.1", "value": "leak"], code: "invalid_arguments")
        try await failure("settings.update", ["key": "workspace.readerTextSize", "value": true], code: "invalid_arguments")
        try await failure("settings.update", ["key": "workspace.readerTextSize", "value": 99], code: "invalid_arguments")
        try await failure("settings.update", ["key": "workspace.autoRefresh", "value": 1], code: "invalid_arguments")
        require(defaults.object(forKey: "forum.drafts.v1.1") == nil, "Arbitrary defaults blocked")
        print("PASS settings whitelist, type checks, ranges and defaults")

        let notifications = map(try await service.handle("settings.openNotifications", ["accessRevision": 7]))
        require(notifications["opened"] as? Bool == true, "Notification settings success result")
        require(openedSettingsURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ], "Notification settings must use the fixed system URL")
        try await failure("settings.openNotifications", ["accessRevision": 7, "url": "https://example.invalid"], code: "invalid_arguments")
        try await failure("settings.openNotifications", ["unexpected": NSNull()], code: "invalid_arguments")
        let invalidRevisions: [Any] = [true, -1, 1.5, "7", NSNull(), Double.infinity]
        for revision in invalidRevisions {
            try await failure("settings.openNotifications", ["accessRevision": revision], code: "invalid_arguments")
        }
        require(openedSettingsURLs.count == 1, "Arguments must be rejected before opening settings")
        let withoutRevision = map(try await service.handle("settings.openNotifications", [:]))
        require(withoutRevision["opened"] as? Bool == true, "Transport revision is optional")
        let zeroRevision = map(try await service.handle("settings.openNotifications", ["accessRevision": 0]))
        require(zeroRevision["opened"] as? Bool == true, "Zero transport revision is valid")
        settingsCanOpen = false
        try await failure("settings.openNotifications", ["accessRevision": 7], code: "unavailable")
        require(openedSettingsURLs.count == 4 && openedSettingsURLs.allSatisfy { $0 == openedSettingsURLs[0] },
                "A failed open must still use only the fixed system URL")
        print("PASS notification settings fixed URL, transport-only arguments and unavailable result")

        _ = try await service.handle("extensions.install", ["id": "office"])
        let originalTitle = context.extensions.officeTitle
        try await failure("extensions.configure", ["id": "office", "settings": ["title": "Changed", "key": "too long"]], code: "invalid_arguments")
        require(context.extensions.officeTitle == originalTitle, "Invalid configure must not partially mutate")
        _ = try await service.handle("extensions.configure", ["id": "office", "settings": ["title": "Test title", "key": "8"]])
        require(context.extensions.officeTitle == "Test title" && context.extensions.officeKey == "8", "Office configure")
        _ = try await service.handle("extensions.install", ["id": "block"])
        _ = try await service.handle("extensions.block", ["memberId": 123, "name": "Test Author"])
        require(context.extensions.blocks(123, name: "Renamed"), "ID-based block")
        _ = try await service.handle("extensions.unblock", ["memberId": 123])
        require(context.extensions.blocked.isEmpty, "ID unblock")
        print("PASS extensions install, atomic configure and block/unblock")

        let link = "socks5://fixture-user:fixture-password@127.0.0.1:18881#Fixture"
        let preview = map(try await service.handle("proxy.import", ["text": link, "preview": true]))
        require(vault.nodes.isEmpty, "Preview must not write vault")
        guard let token = preview["importToken"] as? String else { fatalError("Missing preview token") }
        let safePreview = rows(preview["nodes"])
        require(safePreview.count == 1 && safePreview[0]["link"] == nil && safePreview[0]["outbound"] == nil, "Preview secrets")
        let committed = map(try await service.handle("proxy.import", ["importToken": token, "name": "Renamed"] ))
        require(vault.nodes.count == 1 && vault.nodes[0].name == "Renamed", "Preview commit")
        let safeNodes = rows(committed["nodes"])
        require(safeNodes.count == 1 && safeNodes[0]["link"] == nil && safeNodes[0]["outbound"] == nil, "Snapshot secrets")
        let json = String(data: try JSONSerialization.data(withJSONObject: committed), encoding: .utf8)!
        require(!json.contains("fixture-password") && !json.contains("fixture-user"), "Credentials must not enter snapshots")
        let id = vault.nodes[0].id.uuidString
        let editor = map(try await service.handle("proxy.editNode", ["id": id]))
        require(editor["link"] as? String == link, "Explicit editor link")
        try await failure("proxy.import", ["importToken": token], code: "invalid_arguments")
        try await failure("proxy.select", ["id": UUID().uuidString], code: "invalid_arguments")
        print("PASS native import preview/commit, one-shot token and safe snapshots")

        _ = try await service.handle("proxy.probe", ["id": id])
        for _ in 0..<40 { await Task.yield() }
        require(proxy.nodeLatencies[vault.nodes[0].id] == .success(42), "Probe real controller result")
        require(context.events.contains { $0.0 == "proxy" }, "Async proxy event")
        _ = try await service.handle("proxy.remove", ["id": id])
        require(vault.nodes.isEmpty, "Remove writes fake vault")
        try await failure("proxy.start", [:], code: "unavailable")
        require(!proxy.enabled, "No accidental core startup")
        require(JSONSerialization.isValidJSONObject(service.settingsSnapshot()), "Settings codec safe")
        require(JSONSerialization.isValidJSONObject(service.extensionsSnapshot()), "Extensions codec safe")
        require(JSONSerialization.isValidJSONObject(service.proxySnapshot()), "Proxy codec safe")
        let unknown = try await service.handle("not.handled", [:])
        require(unknown == nil, "Unknown method passthrough")
        print("PASS asynchronous probe events, delete and channel serialization")
    }
}
