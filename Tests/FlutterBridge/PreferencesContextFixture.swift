import Foundation
import WebKit

struct NativeBridgeError: Error {
    let code: String
    let message: String
}

/// This fixture never opens the user's defaults, Keychain, network or proxy.
@MainActor
final class SeekDeskBridgeContext {
    let defaults: UserDefaults
    let session: ForumSession
    let workspace: Workspace
    let extensions: DeskExtensions
    let proxy: DeskProxyController
    private(set) var events: [(String, Any)] = []

    init(defaults: UserDefaults, proxy: DeskProxyController) {
        self.defaults = defaults
        self.session = ForumSession(defaults: defaults, dataStore: .nonPersistent())
        self.workspace = Workspace(defaults: defaults)
        self.extensions = DeskExtensions(defaults: defaults)
        self.proxy = proxy
    }

    func emit(domain: String, data: Any) { events.append((domain, data)) }
}
