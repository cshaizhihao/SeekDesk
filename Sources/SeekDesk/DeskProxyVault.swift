import Foundation
import Security

enum DeskProxyVault {
    private static let service = Bundle.main.bundleIdentifier == "com.seekdesk.flutter-preview"
        ? "com.seekdesk.flutter-preview.proxy" : "com.seekdesk.client.proxy"
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "nodes-v1"
    ]

    struct State: Codable {
        var nodes: [DeskProxyNode]
        var subscriptions: [DeskProxySubscription]
    }

    static func read() throws -> State {
        var options = query
        options[kSecReturnData as String] = true
        options[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(options as CFDictionary, &result)
        if status == errSecItemNotFound { return State(nodes: [], subscriptions: []) }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DeskProxyError.keychain
        }
        let decoder = JSONDecoder()
        let state: State
        if let current = try? decoder.decode(State.self, from: data) { state = current }
        else if let old = try? decoder.decode([DeskProxyNode].self, from: data) { state = State(nodes: old, subscriptions: []) }
        else { throw DeskProxyError.keychain }
        guard state.nodes.count <= 1000, state.subscriptions.count <= 30,
              Set(state.subscriptions.map(\.id)).count == state.subscriptions.count else { throw DeskProxyError.keychain }
        for subscription in state.subscriptions { _ = try DeskProxySubscriptionFetch.validatedURL(subscription.url) }
        var seen = Set<UUID>()
        let nodes = try state.nodes.map { entry in
            guard seen.insert(entry.id).inserted else { throw DeskProxyError.keychain }
            // Never trust a persisted JSON outbound as executable configuration; reparse the original URL.
            var parsed = try DeskProxyNode.parse(entry.link)
            parsed.id = entry.id
            parsed.name = String(entry.name.prefix(100))
            parsed.subscriptionID = entry.subscriptionID
            guard entry.subscriptionID == nil || state.subscriptions.contains(where: { $0.id == entry.subscriptionID }) else { throw DeskProxyError.keychain }
            return parsed
        }
        return State(nodes: nodes, subscriptions: state.subscriptions)
    }

    static func save(_ nodes: [DeskProxyNode], subscriptions: [DeskProxySubscription]) throws {
        guard nodes.count <= 1000, subscriptions.count <= 30 else { throw DeskProxyError.invalid("最多保存 1000 个节点和 30 个订阅。") }
        let bytes = try JSONEncoder().encode(State(nodes: nodes, subscriptions: subscriptions))
        let update = [kSecValueData as String: bytes] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DeskProxyError.keychain }
        var attributes = query
        attributes[kSecValueData as String] = bytes
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw DeskProxyError.keychain }
    }
}
