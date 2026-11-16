import AppKit
import Combine
import Foundation
import CoreFoundation

/// The Flutter UI shares the production preferences, extension state and app-only
/// proxy controller. Node credentials and generated outbound JSON stay native.
@MainActor
final class NativePreferencesServices {
    let context: SeekDeskBridgeContext
    private let openSystemSettings: (URL) -> Bool
    private var observations = Set<AnyCancellable>()
    private var pendingEvents = Set<String>()
    private var eventTask: Task<Void, Never>?
    private struct ImportPreview {
        var result: DeskProxyImportResult
        var subscription: DeskProxySubscription?
        let created: Date
    }
    private var previews: [UUID: ImportPreview] = [:]

    init(context: SeekDeskBridgeContext,
         openSystemSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.context = context
        self.openSystemSettings = openSystemSettings
        // Do not synchronously touch the proxy Keychain while bootstrapping.
        // SecItemCopyMatching can wait for a macOS authorization sheet; doing
        // that from the main actor used to block Flutter's first frame. Proxy
        // state is loaded on the explicit proxy settings/read path below.
        context.proxy.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleEvent("proxy") }
        }.store(in: &observations)
        context.extensions.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleEvent("extensions") }
        }.store(in: &observations)
    }

    func handle(_ method: String, _ args: [String: Any]) async throws -> Any? {
        switch method {
        case "settings.get": return settingsSnapshot()
        case "settings.openNotifications":
            guard args.keys.allSatisfy({ $0 == "accessRevision" }) else {
                throw invalid("打开通知设置不接受业务参数。")
            }
            if let revision = args["accessRevision"] {
                guard let number = revision as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 0, number.doubleValue < 9_007_199_254_740_991 else {
                    throw invalid("账号状态版本必须为非负整数。")
                }
            }
            let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            guard openSystemSettings(url) else { throw unavailable("无法打开系统通知设置，请在系统设置中打开通知。") }
            return ["opened": true]
        case "settings.update":
            let key = try string(args, "key", maximum: 100)
            guard let value = args["value"] else { throw invalid("缺少设置值。") }
            let checked = try settingValue(value, key: key)
            context.defaults.set(checked, forKey: key)
            if key == "appearance", let mode = checked as? String {
                NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) :
                    mode == "light" ? NSAppearance(named: .aqua) : nil
            }
            if key == DeskLogo.preference, let raw = checked as? String, let logo = DeskLogo(rawValue: raw) {
                NSApp.applicationIconImage = logo.dockImage
            }
            let snapshot = settingsSnapshot()
            context.emit(domain: "settings", data: snapshot)
            return snapshot
        case "extensions.list", "extensions.get":
            await context.extensions.refreshWatchNotificationAccess()
            return extensionsSnapshot()
        case "extensions.install":
            context.extensions.install(try extensionID(args))
            return extensionsSnapshot()
        case "extensions.uninstall", "extensions.remove":
            context.extensions.remove(try extensionID(args))
            return extensionsSnapshot()
        case "extensions.setEnabled":
            let item = try extensionID(args)
            guard context.extensions.installed.contains(item) else { throw unavailable("请先安装这个扩展。") }
            context.extensions.setEnabled(item, try boolean(args, "enabled"))
            return extensionsSnapshot()
        case "extensions.configure":
            try configureExtension(args)
            return extensionsSnapshot()
        case "extensions.block":
            guard context.extensions.active(.block) else { throw unavailable("请先启用屏蔽用户扩展。") }
            let name = try string(args, "name", maximum: 120)
            let member = try optionalMemberID(args["memberId"] ?? args["memberID"])
            context.extensions.confirmBlock(.init(memberID: member, name: name))
            return extensionsSnapshot()
        case "extensions.unblock":
            let name = try optionalString(args, "name", maximum: 120) ?? ""
            let member = try optionalMemberID(args["memberId"] ?? args["memberID"])
            guard member != nil || !name.isEmpty else { throw invalid("请选择要解除屏蔽的用户。") }
            context.extensions.unblock(member, name: name)
            return extensionsSnapshot()
        case "extensions.acknowledgeHits":
            context.extensions.acknowledgeHits()
            return extensionsSnapshot()
        case "extensions.dismissWatchPopup":
            context.extensions.dismissWatchPopup()
            return extensionsSnapshot()
        case "extensions.office":
            guard context.extensions.active(.office) else { throw unavailable("请先启用老板键扩展。") }
            context.extensions.officePresented = try boolean(args, "presented")
            return extensionsSnapshot()
        case "proxy.get":
            context.proxy.loadNodes()
            return proxySnapshot()
        case "proxy.import", "proxy.subscribe":
            try requireProxyAvailable()
            return try await importProxy(args, subscription: method == "proxy.subscribe")
        case "proxy.select":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try nodeID(args)
            context.proxy.select(id)
            return proxySnapshot()
        case "proxy.start":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            guard context.proxy.selected != nil else { throw unavailable("请先添加并选择代理节点。") }
            context.proxy.setEnabled(true)
            return proxySnapshot()
        case "proxy.stop":
            context.proxy.setEnabled(false)
            return proxySnapshot()
        case "proxy.reconnect":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            guard context.proxy.enabled else { throw unavailable("请先开启代理。") }
            context.proxy.reconnect()
            return proxySnapshot()
        case "proxy.check":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            guard context.proxy.enabled, context.proxy.running else { throw unavailable("请先连接代理节点。") }
            await context.proxy.checkConnection()
            return proxySnapshot()
        case "proxy.probe":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try nodeID(args)
            if context.proxy.nodeLatencies[id] != .measuring && !context.proxy.canMeasureMoreNodes {
                throw NativeBridgeError(code: "busy", message: "最多同时检测 4 个节点，请稍后再试。")
            }
            context.proxy.measureLatency(id)
            return proxySnapshot()
        case "proxy.cancelProbes":
            context.proxy.cancelNodeMeasurements()
            return proxySnapshot()
        case "proxy.remove":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try nodeID(args)
            context.proxy.remove(id)
            if context.proxy.nodes.contains(where: { $0.id == id }) {
                throw NativeBridgeError(code: "proxy_storage", message: context.proxy.issue ?? "无法删除节点，请重试。")
            }
            return proxySnapshot()
        case "proxy.updateSubscription":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try subscriptionID(args)
            await context.proxy.refreshSubscription(id)
            return proxySnapshot()
        case "proxy.removeSubscription":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try subscriptionID(args)
            context.proxy.removeSubscription(id)
            if context.proxy.subscriptions.contains(where: { $0.id == id }) {
                throw NativeBridgeError(code: "proxy_storage", message: context.proxy.issue ?? "无法删除订阅，请重试。")
            }
            return proxySnapshot()
        case "proxy.configure":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            context.proxy.startWithApp = try boolean(args, "startWithApp")
            return proxySnapshot()
        case "proxy.editNode":
            try requireProxyAvailable()
            context.proxy.loadNodes()
            let id = try nodeID(args)
            let node = context.proxy.nodes.first { $0.id == id }!
            // Only this dedicated, user-invoked editor method returns a link.
            return ["id": id.uuidString, "name": node.name, "link": node.link]
        case "proxy.discardImport":
            let id = try uuid(args, "importToken")
            previews.removeValue(forKey: id)
            return ["discarded": true]
        default: return nil
        }
    }

    func settingsSnapshot() -> [String: Any] {
        let defaults = context.defaults
        let savedSidebarSection = defaults.string(forKey: "workspace.sidebarSection") ?? ""
        var result: [String: Any] = [
            "appearance": defaults.string(forKey: "appearance") ?? "system",
            "workspace.themeFamily": defaults.string(forKey: "workspace.themeFamily") ?? "classic",
            DeskLogo.preference: defaults.string(forKey: DeskLogo.preference) ?? DeskLogo.cobalt.rawValue,
            "workspace.replySendKey": defaults.string(forKey: "workspace.replySendKey") ?? ReplySendKey.commandReturn.rawValue,
            "workspace.sidebarSection": Self.sidebarSections.contains(savedSidebarSection)
                ? savedSidebarSection : "ranking",
            DeskReadingDensity.preference: defaults.string(forKey: DeskReadingDensity.preference) ?? DeskReadingDensity.comfortable.rawValue
        ]
        for (key, fallback) in Self.boolSettings {
            result[key] = defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        for (key, rule) in Self.numberSettings {
            let value = defaults.object(forKey: key) == nil ? rule.standard : defaults.double(forKey: key)
            result[key] = value.isFinite ? min(rule.range.upperBound, max(rule.range.lowerBound, value)) : rule.standard
        }
        return result
    }

    func extensionsSnapshot() -> [String: Any] {
        let service = context.extensions
        // The Flutter reader now exposes this filter directly in its toolbar.
        let catalog = DeskExtension.allCases.filter { $0 != .authorOnly }
        return [
            "items": catalog.map { item -> [String: Any] in
                ["id": item.rawValue, "title": item.title, "description": item.description,
                 "icon": item.icon, "installed": service.installed.contains(item),
                 "enabled": service.enabled.contains(item), "active": service.active(item)]
            },
            "installed": catalog.filter { service.installed.contains($0) }.map(\.rawValue).sorted(),
            "enabled": catalog.filter { service.enabled.contains($0) }.map(\.rawValue).sorted(),
            "blocked": service.blocked.map { author -> [String: Any] in
                ["id": author.id, "memberId": author.memberID as Any? ?? NSNull(), "name": author.name,
                 "normalizedName": ForumSearch.normalized(author.name)]
            },
            "settings": [
                "office": ["title": service.officeTitle, "button": service.officeButton,
                           "key": service.officeKey, "presented": service.officePresented] as [String: Any],
                "keywords": ["words": service.watchWords, "note": service.watchNote,
                             "systemNotifications": service.watchSystemNotifications,
                             "notificationAccess": service.watchNotificationAccess.rawValue,
                             "terms": service.watchTerms] as [String: Any],
                "attendance": ["mode": service.attendanceMode.rawValue,
                               "automatic": service.autoAttendance] as [String: Any]
            ],
            "hits": service.hits.map(hitMap), "unread": service.unread,
            "lastCheck": milliseconds(service.lastCheck), "watchFailed": service.watchFailed,
            "watchPopup": service.watchPopup.map { popup -> [String: Any] in
                ["id": popup.id.uuidString, "hits": popup.hits.map(hitMap)]
            } as Any? ?? NSNull()
        ]
    }

    func proxySnapshot() -> [String: Any] {
        let proxy = context.proxy
        return [
            "available": context.extensions.active(.proxy),
            "nodes": proxy.nodes.map { nodeMap($0, latency: proxy.nodeLatencies[$0.id]) },
            "subscriptions": proxy.subscriptions.map { source -> [String: Any] in
                ["id": source.id.uuidString, "name": source.name, "updatedAt": milliseconds(source.updatedAt),
                 "updating": proxy.updatingSubscriptions.contains(source.id),
                 "nodeCount": proxy.nodes.filter { $0.subscriptionID == source.id }.count]
            },
            "selectedId": proxy.selectedID?.uuidString as Any? ?? NSNull(),
            "enabled": proxy.enabled, "running": proxy.running, "starting": proxy.starting,
            "checking": proxy.checking, "status": proxy.status,
            "issue": proxy.issue as Any? ?? NSNull(),
            "checkResult": proxy.checkResult as Any? ?? NSNull(),
            "importMessage": proxy.importMessage as Any? ?? NSNull(),
            "startWithApp": proxy.startWithApp, "canMeasureMoreNodes": proxy.canMeasureMoreNodes,
            "supportedProtocols": ["vless", "vmess", "ss", "trojan", "hysteria2", "socks5", "http", "https"]
        ]
    }

    private func importProxy(_ args: [String: Any], subscription: Bool) async throws -> [String: Any] {
        removeExpiredPreviews()
        if args["importToken"] != nil {
            let token = try uuid(args, "importToken")
            guard var saved = previews[token] else { throw invalid("导入预览已过期，请重新识别节点。") }
            let name = try optionalString(args, "name", maximum: 100) ?? ""
            if let source = saved.subscription {
                if !name.isEmpty { saved.subscription = .init(id: source.id, name: name, url: source.url, updatedAt: source.updatedAt) }
            } else if saved.result.nodes.count == 1, !name.isEmpty {
                saved.result.nodes[0].name = name
            }
            do { try context.proxy.importNodes(saved.result, subscription: saved.subscription) }
            catch { throw proxyError(error) }
            previews.removeValue(forKey: token)
            return proxySnapshot()
        }
        let name = try optionalString(args, "name", maximum: 100) ?? ""
        if args["replacingId"] != nil {
            guard !subscription else { throw invalid("订阅节点请通过更新订阅进行替换。") }
            let id = try uuid(args, "replacingId")
            context.proxy.loadNodes()
            guard context.proxy.nodes.contains(where: { $0.id == id }) else { throw invalid("节点已不存在。") }
            let text = try input(args, subscription: false)
            do { try context.proxy.save(link: text, name: name, replacing: id) }
            catch { throw proxyError(error) }
            return proxySnapshot()
        }
        let text = try input(args, subscription: subscription)
        let result: DeskProxyImportResult
        let source: DeskProxySubscription?
        do {
            if subscription {
                let url = try DeskProxySubscriptionFetch.validatedURL(text)
                result = try await DeskProxySubscriptionFetch.fetch(url.absoluteString)
                source = .init(name: name.isEmpty ? String((url.host ?? "我的订阅").prefix(100)) : name,
                               url: url.absoluteString, updatedAt: Date())
            } else {
                result = try await Task.detached(priority: .userInitiated) {
                    try DeskProxySubscriptionParser.parse(Data(text.utf8))
                }.value
                source = nil
            }
        } catch { throw proxyError(error) }
        try Task.checkCancellation()
        // Extension state can change while a subscription is downloading.
        try requireProxyAvailable()
        var preview = ImportPreview(result: result, subscription: source, created: Date())
        if !subscription, preview.result.nodes.count == 1, !name.isEmpty { preview.result.nodes[0].name = name }
        let onlyPreview = try optionalBoolean(args, "preview") ?? false
        if onlyPreview {
            if previews.count >= 4, let oldest = previews.min(by: { $0.value.created < $1.value.created })?.key {
                previews.removeValue(forKey: oldest)
            }
            let token = UUID()
            previews[token] = preview
            return ["importToken": token.uuidString, "summary": result.summary,
                    "nodes": preview.result.nodes.map { nodeMap($0, latency: nil) },
                    "skipped": result.skipped, "duplicates": result.duplicates,
                    "subscription": source != nil]
        }
        do { try context.proxy.importNodes(preview.result, subscription: preview.subscription) }
        catch { throw proxyError(error) }
        return proxySnapshot()
    }

    private func configureExtension(_ args: [String: Any]) throws {
        let item = try extensionID(args)
        guard context.extensions.installed.contains(item) else { throw unavailable("请先安装这个扩展。") }
        guard let values = args["settings"] as? [String: Any], !values.isEmpty else { throw invalid("请提供扩展设置。") }
        let allowed: Set<String>
        switch item {
        case .office: allowed = ["title", "button", "key"]
        case .keywords: allowed = ["words", "note", "systemNotifications"]
        case .attendance: allowed = ["mode", "automatic"]
        case .proxy: allowed = ["startWithApp"]
        default: throw invalid("这个扩展没有可修改的配置。")
        }
        guard Set(values.keys).isSubset(of: allowed) else { throw invalid("包含不支持的扩展设置。") }
        // Validate the whole update before mutating production state.
        var checked: [String: Any] = [:]
        for (key, value) in values {
            if ["automatic", "systemNotifications", "startWithApp"].contains(key) {
                checked[key] = try boolean([key: value], key)
            } else {
                let maximum = key == "words" || key == "note" ? 8000 : key == "key" ? 8 : 120
                let text = try string([key: value], key, maximum: maximum, allowEmpty: key == "words" || key == "note")
                if key == "mode", ForumAttendanceMode(rawValue: text) == nil { throw invalid("签到方式不正确。") }
                if key == "key", text.count != 1 { throw invalid("老板键需要填写一个按键字符。") }
                checked[key] = text
            }
        }
        let service = context.extensions
        switch item {
        case .office:
            if let value = checked["title"] as? String { service.officeTitle = value }
            if let value = checked["button"] as? String { service.officeButton = value }
            if let value = checked["key"] as? String { service.officeKey = value }
        case .keywords:
            if let value = checked["words"] as? String { service.watchWords = value }
            if let value = checked["note"] as? String { service.watchNote = value }
            if let value = checked["systemNotifications"] as? Bool { service.setWatchSystemNotifications(value) }
        case .attendance:
            if let value = checked["mode"] as? String, let mode = ForumAttendanceMode(rawValue: value) { service.attendanceMode = mode }
            if let value = checked["automatic"] as? Bool { service.autoAttendance = value }
        case .proxy:
            if let value = checked["startWithApp"] as? Bool { context.proxy.startWithApp = value }
        default: break
        }
    }

    private struct NumberSetting { let standard: Double; let range: ClosedRange<Double> }
    private static let sidebarSections: Set<String> = ["boards", "shortcuts", "ranking", "none"]
    private static let boolSettings: [String: Bool] = [
        "workspace.mistBackdrop": true, "workspace.autoLoadOlder": false,
        "workspace.autoRefresh": true, "workspace.hideListWhileReading": false
    ]
    private static let numberSettings: [String: NumberSetting] = [
        DeskTextSize.listKey: .init(standard: DeskTextSize.listDefault, range: DeskTextSize.listRange),
        DeskTextSize.bodyKey: .init(standard: DeskTextSize.bodyDefault, range: DeskTextSize.bodyRange),
        DeskTextSize.authorScaleKey: .init(standard: DeskTextSize.authorScaleDefault, range: DeskTextSize.authorScaleRange),
        DeskTextSize.boardKey: .init(standard: DeskTextSize.boardDefault, range: DeskTextSize.sidebarRange),
        DeskTextSize.rankingKey: .init(standard: DeskTextSize.rankingDefault, range: DeskTextSize.sidebarRange),
        "workspace.nqReportScale": .init(standard: 100, range: ForumReportKind.nq.range),
        "workspace.tqReportScale": .init(standard: 100, range: ForumReportKind.tq.range),
        "workspace.sidebarWidth": .init(standard: DeskSidebarSizing.standard, range: 184...360),
        "workspace.topicColumnWidth": .init(standard: 340, range: 240...620)
    ]

    private func settingValue(_ value: Any, key: String) throws -> Any {
        if Self.boolSettings[key] != nil { return try boolean([key: value], key) }
        if let rule = Self.numberSettings[key] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, rule.range.contains(number.doubleValue) else {
                throw invalid("设置值超出了允许范围。")
            }
            return number.doubleValue
        }
        let allowed: [String: Set<String>] = [
            "appearance": ["system", "light", "dark"],
            "workspace.themeFamily": ["classic", "mountain", "coast"],
            "workspace.sidebarSection": Self.sidebarSections,
            DeskLogo.preference: Set(DeskLogo.allCases.map(\.rawValue)),
            ReplySendKey.preference: Set(ReplySendKey.allCases.map(\.rawValue)),
            DeskReadingDensity.preference: Set(DeskReadingDensity.allCases.map(\.rawValue))
        ]
        guard let values = allowed[key], let text = value as? String, values.contains(text) else {
            throw invalid("不支持的设置或设置值。")
        }
        return text
    }

    private func nodeMap(_ node: DeskProxyNode, latency: DeskProxyLatency?) -> [String: Any] {
        var measurement: [String: Any] = ["state": "idle"]
        switch latency {
        case .measuring: measurement = ["state": "measuring"]
        case .success(let value): measurement = ["state": "success", "milliseconds": value]
        case .failed: measurement = ["state": "failed"]
        case nil: break
        }
        return ["id": node.id.uuidString, "name": node.name, "scheme": node.scheme,
                "protocolName": node.protocolName, "host": node.host, "port": node.port,
                "subscriptionId": node.subscriptionID?.uuidString as Any? ?? NSNull(), "latency": measurement]
    }

    private func hitMap(_ hit: DeskExtensions.Hit) -> [String: Any] {
        let post = hit.post
        return ["id": hit.id, "words": hit.words, "post": [
            "id": post.id, "url": post.url.absoluteString, "title": post.title,
            "author": post.author, "category": post.category, "summary": post.summary,
            "published": milliseconds(post.published), "authorId": post.authorID as Any? ?? NSNull(),
            "avatarUrl": post.avatarURL?.absoluteString as Any? ?? NSNull(),
            "readingRank": post.readingRank as Any? ?? NSNull(), "featured": post.featured as Any? ?? NSNull()
        ]]
    }

    private func scheduleEvent(_ domain: String) {
        pendingEvents.insert(domain)
        guard eventTask == nil else { return }
        eventTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            let domains = self.pendingEvents
            self.pendingEvents.removeAll()
            self.eventTask = nil
            for domain in domains.sorted() {
                self.context.emit(domain: domain, data: domain == "proxy" ? self.proxySnapshot() : self.extensionsSnapshot())
            }
        }
    }

    private func removeExpiredPreviews() {
        previews = previews.filter { Date().timeIntervalSince($0.value.created) < 600 }
    }

    private func requireProxyAvailable() throws {
        guard context.extensions.active(.proxy) else { throw unavailable("请先安装并启用 SeekDesk 专用代理扩展。") }
    }
    private func extensionID(_ args: [String: Any]) throws -> DeskExtension {
        let raw = try string(args, "id", maximum: 40)
        guard let item = DeskExtension(rawValue: raw) else { throw invalid("未找到这个扩展。") }
        return item
    }
    private func nodeID(_ args: [String: Any]) throws -> UUID {
        let id = try uuid(args, "id")
        guard context.proxy.nodes.contains(where: { $0.id == id }) else { throw invalid("节点已不存在。") }
        return id
    }
    private func subscriptionID(_ args: [String: Any]) throws -> UUID {
        let id = try uuid(args, "id")
        guard context.proxy.subscriptions.contains(where: { $0.id == id }) else { throw invalid("订阅已不存在。") }
        return id
    }
    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let raw = args[key] as? String, let id = UUID(uuidString: raw) else { throw invalid("标识符不正确。") }
        return id
    }
    private func input(_ args: [String: Any], subscription: Bool) throws -> String {
        let key = subscription ? "url" : args["text"] != nil ? "text" : "link"
        return try string(args, key, maximum: subscription ? 16384 : DeskProxySubscriptionParser.byteLimit)
    }
    private func string(_ args: [String: Any], _ key: String, maximum: Int, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, value.utf8.count <= maximum else { throw invalid("文本无效或超过长度限制。") }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !text.isEmpty else { throw invalid("请填写必要的内容。") }
        return text
    }
    private func optionalString(_ args: [String: Any], _ key: String, maximum: Int) throws -> String? {
        guard args[key] != nil, !(args[key] is NSNull) else { return nil }
        return try string(args, key, maximum: maximum, allowEmpty: true)
    }
    private func boolean(_ args: [String: Any], _ key: String) throws -> Bool {
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid("开关值必须为 true 或 false。")
        }
        return number.boolValue
    }
    private func optionalBoolean(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard args[key] != nil, !(args[key] is NSNull) else { return nil }
        return try boolean(args, key)
    }
    private func optionalMemberID(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue > 0, number.doubleValue < 9_007_199_254_740_991 else { throw invalid("用户编号不正确。") }
        return number.intValue
    }
    private func milliseconds(_ date: Date?) -> Any {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } as Any? ?? NSNull()
    }
    private func invalid(_ message: String) -> NativeBridgeError { .init(code: "invalid_arguments", message: message) }
    private func unavailable(_ message: String) -> NativeBridgeError { .init(code: "unavailable", message: message) }
    private func proxyError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        return NativeBridgeError(code: "proxy", message: (error as? DeskProxyError)?.localizedDescription ?? "无法导入代理配置，请检查输入后重试。")
    }
}
