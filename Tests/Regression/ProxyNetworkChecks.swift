import AppKit
import WebKit

@main struct ProxyNetworkChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let port = UInt16(CommandLine.arguments[1])!
        // Use a hostname to exercise proxying; Apple bypasses literal loopback destinations.
        let origin = URL(string: "http://seekdesk-proxy-fixture.invalid/fixture")!
        let directOrigin = URL(string: "http://127.0.0.1:" + CommandLine.arguments[2] + "/fixture")!
        let network = DeskProxyNetwork.shared
        let endpoint = DeskProxyEndpoint(port: port, username: "fixture-user", password: "fixture-password")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.urlCache = nil
        let session = network.makeSession(configuration: config)
        defer { session.invalidateAndCancel(); network.setEndpoint(nil); DeskProxyWebKit.routeChanged() }
        network.setEndpoint(endpoint)
        precondition(network.requiresProxy && !endpoint.configuration.allowFailover)
        let request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, _) = try await session.data(for: request)
        precondition(String(decoding: data, as: UTF8.self).contains("via-proxy"))
        let (file, _) = try await session.download(for: request)
        let downloaded = try String(contentsOf: file, encoding: .utf8)
        precondition(downloaded.contains("via-proxy"))
        try FileManager.default.removeItem(at: file)
        var upload = request
        upload.httpMethod = "POST"
        let (uploaded, _) = try await session.upload(for: upload, from: Data("fixture".utf8))
        precondition(String(decoding: uploaded, as: UTF8.self).contains("via-proxy"))
        print("Passed native data, download and upload requests through authenticated app-only CONNECT proxy.")
        let store = WKWebsiteDataStore.nonPersistent()
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = store
        DeskProxyWebKit.configure(store)
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: webConfig)
        DeskProxyWebKit.register(web)
        let navigation = NavigationProbe()
        web.navigationDelegate = navigation
        try await navigation.load(web, request: request)
        let body = try await web.evaluateJavaScript("document.body.textContent") as? String
        precondition(body?.contains("via-proxy") == true)
        print("Passed WebKit requests through the same authenticated proxy.")
        network.setEndpoint(.blocked()); DeskProxyWebKit.routeChanged()
        do { _ = try await session.data(for: request); preconditionFailure("Proxy failure bypassed the route.") } catch {}
        do { try await navigation.load(web, request: request); preconditionFailure("WebKit proxy failure bypassed the route.") } catch {}
        print("Passed failed-proxy native and WebKit requests with failover disabled.")
        network.setEndpoint(nil); DeskProxyWebKit.routeChanged()
        let directRequest = URLRequest(url: directOrigin, cachePolicy: .reloadIgnoringLocalCacheData)
        let (direct, _) = try await session.data(for: directRequest)
        precondition(String(decoding: direct, as: UTF8.self).contains("direct-origin"))
        try await navigation.load(web, request: directRequest)
        let directBody = try await web.evaluateJavaScript("document.body.textContent") as? String
        precondition(directBody?.contains("direct-origin") == true)
        session.invalidateAndCancel()
        do { _ = try await session.data(for: request); preconditionFailure("Closed session was reused.") } catch {}
        print("Passed route refresh, explicit proxy disable and closed-session rejection.")
    }
}

@MainActor private final class NavigationProbe: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { pending = $0; web.load(request) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ error: Error?) {
        let waiter = pending; pending = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }
}
