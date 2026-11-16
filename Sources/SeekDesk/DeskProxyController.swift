import AppKit
import Combine
import Darwin

extension Notification.Name { static let deskProxyRouteChanged = Notification.Name("SeekDesk.proxy.routeChanged") }

enum DeskProxyLatency: Equatable {
    case measuring, success(Int), failed
}

@MainActor
final class DeskProxyController: NSObject, ObservableObject {
    static let shared = DeskProxyController()
    @Published private(set) var nodes: [DeskProxyNode] = []
    @Published private(set) var subscriptions: [DeskProxySubscription] = []
    @Published private(set) var updatingSubscriptions: Set<UUID> = []
    @Published private(set) var importMessage: String?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var enabled = false
    @Published private(set) var status = "代理已关闭"
    @Published private(set) var issue: String?
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var checking = false
    @Published private(set) var checkResult: String?
    @Published private(set) var nodeLatencies: [UUID: DeskProxyLatency] = [:]
    @Published var startWithApp: Bool { didSet { defaults.set(startWithApp, forKey: "proxy.startWithApp") } }
    private let defaults: UserDefaults
    private let readVault: () throws -> DeskProxyVault.State
    private let saveVault: ([DeskProxyNode], [DeskProxySubscription]) throws -> Void
    private let fetchSubscription: (String) async throws -> DeskProxyImportResult
    private let measureNode: (DeskProxyNode) async throws -> Int
    private var nodeMeasurements: [UUID: Task<Void, Never>] = [:]
    private var measurementTokens: [UUID: UUID] = [:]
    private var sourceRevisions: [UUID: UUID] = [:]
    private var loaded = false
    private var child: Process?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var checkToken = UUID()
    var selected: DeskProxyNode? { nodes.first { $0.id == selectedID } }
    var coreURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xray") }

    override convenience init() {
        self.init(defaults: .standard, readVault: DeskProxyVault.read,
                  saveVault: { try DeskProxyVault.save($0, subscriptions: $1) }, fetchSubscription: DeskProxySubscriptionFetch.fetch)
    }

    init(defaults: UserDefaults, readVault: @escaping () throws -> DeskProxyVault.State,
         saveVault: @escaping ([DeskProxyNode], [DeskProxySubscription]) throws -> Void,
         fetchSubscription: @escaping (String) async throws -> DeskProxyImportResult,
         measureNode: @escaping (DeskProxyNode) async throws -> Int = {
             try await DeskProxyNodeProbe.measure(node: $0, coreURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xray"))
         }) {
        self.defaults = defaults
        self.readVault = readVault
        self.saveVault = saveVault
        self.fetchSubscription = fetchSubscription
        self.measureNode = measureNode
        selectedID = defaults.string(forKey: "proxy.selected").flatMap(UUID.init(uuidString:))
        startWithApp = defaults.bool(forKey: "proxy.startWithApp")
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(shutdown), name: NSApplication.willTerminateNotification, object: nil)
        let installed = defaults.stringArray(forKey: "extensions.installed") ?? []
        let active = defaults.stringArray(forKey: "extensions.enabled") ?? []
        if installed.contains("proxy"), active.contains("proxy"), startWithApp, defaults.bool(forKey: "proxy.requested") {
            enabled = true
            route(.blocked())
            reconnect()
        }
    }

    func loadNodes() {
        guard !loaded else { return }
        do {
            let saved = try readVault()
            nodes = saved.nodes
            subscriptions = saved.subscriptions
            loaded = true
            if !nodes.contains(where: { $0.id == selectedID }) { selectedID = nodes.first?.id; persistSelection() }
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func save(link: String, name: String, replacing id: UUID?) throws {
        loadNodes()
        guard loaded else { throw DeskProxyError.keychain }
        var node = try DeskProxyNode.parse(link)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { node.name = String(name.prefix(100)) }
        var updated = nodes
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
            node.id = id
            node.subscriptionID = updated[index].subscriptionID
            updated[index] = node
        } else {
            guard !nodes.contains(where: { $0.link == node.link }) else { throw DeskProxyError.invalid("这个节点已经添加。") }
            updated.append(node)
        }
        try saveVault(updated, subscriptions)
        invalidateMeasurements(for: updated)
        nodes = updated
        if let source = node.subscriptionID { sourceRevisions[source] = UUID() }
        if selectedID == nil { selectedID = node.id; persistSelection() }
        issue = nil
        if enabled, selectedID == node.id { reconnect() }
    }

    func remove(_ id: UUID) {
        guard loaded else { return }
        let source = nodes.first(where: { $0.id == id })?.subscriptionID
        let updated = nodes.filter { $0.id != id }
        do {
            try saveVault(updated, subscriptions)
            invalidateMeasurements(for: updated)
            nodes = updated
            if let source { sourceRevisions[source] = UUID() }
            issue = nil
            if selectedID == id {
                selectedID = updated.first?.id
                persistSelection()
                if enabled { reconnect() }
            }
        } catch { issue = error.localizedDescription }
    }

    func importNodes(_ result: DeskProxyImportResult, subscription: DeskProxySubscription?) throws {
        loadNodes()
        guard loaded else { throw DeskProxyError.keychain }
        let oldSelected = selected
        let sourceID = subscription?.id
        var updated = nodes
        var sources = subscriptions
        if let subscription {
            if let index = sources.firstIndex(where: { $0.id == subscription.id }) { sources[index] = subscription }
            else {
                guard !sources.contains(where: { $0.url == subscription.url }) else { throw DeskProxyError.invalid("此订阅已添加，请使用更新按钮刷新。") }
                sources.append(subscription)
            }
            let incoming = Self.mergedSubscriptionNodes(old: nodes.filter { $0.subscriptionID == sourceID }, imported: result.nodes, sourceID: subscription.id)
            let position = updated.firstIndex(where: { $0.subscriptionID == sourceID }) ?? updated.count
            updated.removeAll { $0.subscriptionID == sourceID }
            updated.insert(contentsOf: incoming, at: min(position, updated.count))
        } else {
            var identities = Set(updated.map(\.identity))
            let additions = result.nodes.filter { identities.insert($0.identity).inserted }
            guard !additions.isEmpty else { throw DeskProxyError.invalid("这些节点已经添加，无需重复导入。") }
            updated.append(contentsOf: additions)
        }
        try saveVault(updated, sources)
        invalidateMeasurements(for: updated)
        nodes = updated
        subscriptions = sources
        if let sourceID { sourceRevisions[sourceID] = UUID() }
        if !nodes.contains(where: { $0.id == selectedID }) {
            selectedID = (sourceID.flatMap { id in nodes.first { $0.subscriptionID == id } } ?? nodes.first)?.id
            persistSelection()
        }
        importMessage = result.summary + (result.skipped.isEmpty ? "" : "\n" + result.skipped.prefix(3).joined(separator: "\n"))
        issue = nil
        if enabled, selectedID != oldSelected?.id || selected?.identity != oldSelected?.identity { reconnect() }
    }

    func refreshSubscription(_ id: UUID) async {
        guard let source = subscriptions.first(where: { $0.id == id }), !updatingSubscriptions.contains(id) else { return }
        updatingSubscriptions.insert(id)
        let revision = sourceRevisions[id]
        defer { updatingSubscriptions.remove(id) }
        do {
            let result = try await fetchSubscription(source.url)
            guard subscriptions.contains(where: { $0.id == id }), !Task.isCancelled else { return }
            guard sourceRevisions[id] == revision else {
                importMessage = "订阅更新期间节点有修改，已保留你的修改。可以再次更新订阅。"
                return
            }
            var updated = source
            updated.updatedAt = Date()
            try importNodes(result, subscription: updated)
        } catch is CancellationError { }
        catch { if subscriptions.contains(where: { $0.id == id }) { importMessage = "订阅更新失败，保留原有节点。\n" + error.localizedDescription } }
    }

    func removeSubscription(_ id: UUID) {
        guard loaded else { return }
        let updated = nodes.filter { $0.subscriptionID != id }
        let sources = subscriptions.filter { $0.id != id }
        do {
            try saveVault(updated, sources)
            let removedSelection = !updated.contains { $0.id == selectedID }
            invalidateMeasurements(for: updated)
            nodes = updated; subscriptions = sources; issue = nil
            sourceRevisions.removeValue(forKey: id)
            if removedSelection {
                selectedID = updated.first?.id; persistSelection()
                if enabled { reconnect() }
            }
        } catch { issue = error.localizedDescription }
    }

    static func mergedSubscriptionNodes(old: [DeskProxyNode], imported: [DeskProxyNode], sourceID: UUID) -> [DeskProxyNode] {
        var remaining = old
        var matched = Set<Int>()
        var incoming = imported.map { node -> DeskProxyNode in var node = node; node.subscriptionID = sourceID; return node }
        // Reserve unchanged endpoints first so name fallback cannot steal their selected IDs.
        for index in incoming.indices {
            if let previous = remaining.firstIndex(where: { $0.identity == incoming[index].identity }) {
                incoming[index].id = remaining.remove(at: previous).id
                matched.insert(index)
            }
        }
        for index in incoming.indices where !matched.contains(index) {
            let candidates = remaining.indices.filter { remaining[$0].name == incoming[index].name && remaining[$0].scheme == incoming[index].scheme }
            let uniqueIncoming = incoming.indices.filter { !matched.contains($0) && incoming[$0].name == incoming[index].name && incoming[$0].scheme == incoming[index].scheme }.count == 1
            if candidates.count == 1, uniqueIncoming, let previous = candidates.first { incoming[index].id = remaining.remove(at: previous).id }
        }
        return incoming
    }

    func select(_ id: UUID) {
        guard nodes.contains(where: { $0.id == id }), selectedID != id else { return }
        selectedID = id
        persistSelection()
        checkResult = nil
        if enabled { reconnect() }
    }

    var canMeasureMoreNodes: Bool { nodeMeasurements.count < 4 }

    func measureLatency(_ id: UUID) {
        guard nodeMeasurements[id] == nil, canMeasureMoreNodes,
              let node = nodes.first(where: { $0.id == id }) else { return }
        let request = UUID()
        measurementTokens[id] = request
        nodeLatencies[id] = .measuring
        let measure = measureNode
        nodeMeasurements[id] = Task { [weak self] in
            let result: DeskProxyLatency?
            do { result = .success(try await measure(node)) }
            catch is CancellationError { result = nil }
            catch { result = Task.isCancelled ? nil : .failed }
            guard let self, self.measurementTokens[id] == request else { return }
            self.nodeMeasurements.removeValue(forKey: id)
            self.measurementTokens.removeValue(forKey: id)
            guard !Task.isCancelled, self.nodes.contains(where: { $0.id == id && $0.identity == node.identity }) else {
                self.nodeLatencies.removeValue(forKey: id)
                return
            }
            self.nodeLatencies[id] = result
        }
    }

    func cancelNodeMeasurements() {
        measurementTokens.removeAll()
        for task in nodeMeasurements.values { task.cancel() }
        nodeMeasurements.removeAll()
        nodeLatencies = nodeLatencies.filter { $0.value != .measuring }
    }

    private func invalidateMeasurements(for updated: [DeskProxyNode]) {
        let identities = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0.identity) })
        for old in nodes where identities[old.id] != old.identity {
            measurementTokens.removeValue(forKey: old.id)
            nodeMeasurements.removeValue(forKey: old.id)?.cancel()
            nodeLatencies.removeValue(forKey: old.id)
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: "proxy.requested")
        if value { reconnect() }
        else {
            cancelConnection()
            route(nil)
            issue = nil
            status = "代理已关闭"
        }
    }

    func setAvailable(_ value: Bool) {
        if !value { cancelNodeMeasurements(); setEnabled(false) }
    }

    func reconnect() {
        guard enabled else { return }
        cancelConnection()
        route(.blocked())
        loadNodes()
        guard let node = selected else {
            status = "代理未连接"
            issue = loaded ? "请先添加并选择节点；代理模式下不会回退直连。" : DeskProxyError.keychain.localizedDescription
            return
        }
        let request = UUID()
        token = request
        starting = true
        status = "正在启动代理…"
        issue = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard FileManager.default.isExecutableFile(atPath: coreURL.path) else { throw DeskProxyError.missingCore }
                let port = try Self.freePort()
                let endpoint = DeskProxyEndpoint(port: port, username: UUID().uuidString, password: UUID().uuidString)
                let config = try node.configuration(port: port, username: endpoint.username, password: endpoint.password)
                let process = Process(), pipe = Pipe()
                process.executableURL = coreURL
                process.arguments = ["run", "-format", "json", "-c", "stdin:"]
                process.standardInput = pipe
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == request, self.enabled else { return }
                        self.child = nil
                        self.running = false
                        self.starting = false
                        self.route(.blocked())
                        self.status = "代理已中断"
                        self.issue = DeskProxyError.interrupted.localizedDescription
                    }
                }
                try process.run()
                child = process
                try pipe.fileHandleForWriting.write(contentsOf: config)
                try pipe.fileHandleForWriting.close()
                for _ in 0..<50 {
                    try await Task.sleep(for: .milliseconds(100))
                    guard token == request, enabled else { throw CancellationError() }
                    guard process.isRunning else { throw DeskProxyError.startup }
                    if Self.acceptsConnections(port) {
                        route(endpoint)
                        running = true
                        starting = false
                        status = "内核已就绪 · 尚未检测节点连通性"
                        return
                    }
                }
                throw DeskProxyError.startup
            } catch {
                guard token == request, enabled, !Task.isCancelled else { return }
                stopChild()
                starting = false
                running = false
                status = "代理未连接"
                issue = (error as? DeskProxyError)?.localizedDescription ?? DeskProxyError.startup.localizedDescription
            }
        }
    }

    func checkConnection() async {
        guard enabled, running, !checking else { return }
        let requestID = UUID(), connection = token
        checkToken = requestID
        checking = true
        checkResult = nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        let session = DeskProxyNetwork.shared.makeSession(configuration: config)
        defer {
            session.finishTasksAndInvalidate()
            if checkToken == requestID { checking = false }
        }
        do {
            var request = URLRequest(url: URL(string: "https://www.nodeseek.com/")!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "HEAD"
            let start = Date()
            let (_, response) = try await session.data(for: request)
            guard token == connection, enabled, checkToken == requestID else { return }
            guard let http = response as? HTTPURLResponse, Forum.contains(http.url ?? request.url!) else { throw URLError(.badServerResponse) }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            checkResult = (200...399).contains(http.statusCode)
                ? "NodeSeek 已响应 · " + String(elapsed) + " ms"
                : "已收到 NodeSeek 响应（HTTP " + String(http.statusCode) + "），可能需要在页面完成站点验证。"
        } catch {
            guard token == connection, enabled, checkToken == requestID else { return }
            checkResult = "检测失败，请检查节点或稍后重试。代理模式仍保持开启。"
        }
    }

    private func persistSelection() { defaults.set(selectedID?.uuidString, forKey: "proxy.selected") }
    private func route(_ endpoint: DeskProxyEndpoint?) {
        DeskProxyNetwork.shared.setEndpoint(endpoint)
        DeskProxyWebKit.routeChanged()
        NotificationCenter.default.post(name: .deskProxyRouteChanged, object: nil)
    }
    private func cancelConnection() {
        token = UUID()
        checkToken = UUID()
        task?.cancel()
        task = nil
        checking = false
        checkResult = nil
        stopChild()
        running = false
        starting = false
    }
    private func stopChild() {
        guard let old = child else { return }
        child = nil
        old.terminationHandler = nil
        if old.isRunning {
            old.terminate()
            Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                if old.isRunning { Darwin.kill(old.processIdentifier, SIGKILL) }
            }
        }
    }
    @objc private func shutdown() {
        cancelNodeMeasurements()
        token = UUID()
        task?.cancel()
        guard let old = child, old.isRunning else { return }
        old.terminationHandler = nil
        old.terminate()
        for _ in 0..<30 { if !old.isRunning { return }; Thread.sleep(forTimeInterval: 0.01) }
        if old.isRunning { Darwin.kill(old.processIdentifier, SIGKILL) }
    }

    private static func address(_ port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return value
    }
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeskProxyError.startup }
        defer { Darwin.close(fd) }
        var address = address(0)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw DeskProxyError.startup }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard found == 0 else { throw DeskProxyError.startup }
        return UInt16(bigEndian: address.sin_port)
    }
    private static func acceptsConnections(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = address(port)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}
