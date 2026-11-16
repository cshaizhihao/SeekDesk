import Foundation

@main struct ProxySubscriptionFetchChecks {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!
        let base = "http://127.0.0.1:\(port)"
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.proxyConfigurations = []
        config.timeoutIntervalForRequest = 2
        let observer = URLSession(configuration: config)
        defer { observer.invalidateAndCancel() }
        func records() async throws -> [[String: String]] {
            let (data, _) = try await observer.data(from: URL(string: base + "/stats")!)
            return try JSONDecoder().decode([[String: String]].self, from: data)
        }
        let plain = try await DeskProxySubscriptionFetch.fetch(base + "/plain")
        precondition(plain.nodes.count == 2)
        for path in ["/base64", "/yaml", "/redirect", "/cookie-set", "/cookie-check", "/cookie-redirect"] {
            let result = try await DeskProxySubscriptionFetch.fetch(base + path)
            precondition(result.nodes.map(\.identity) == plain.nodes.map(\.identity), "Unexpected parsed nodes from \(path)")
        }
        let requests = try await records()
        precondition(requests.allSatisfy { $0["cookie"] == "" && $0["authorization"] == "" })
        precondition(requests.allSatisfy { $0["agent"]?.contains("SeekDesk") == true })
        print("Passed local HTTP subscription plain/Base64/Clash YAML fetches, redirects, user agent and cookie isolation.")

        for path in ["/http-error", "/html-error", "/redirect-credentials", "/oversize-length", "/oversize-stream"] {
            do {
                _ = try await DeskProxySubscriptionFetch.fetch(base + path + "?token=fixture-url-token")
                preconditionFailure("Invalid subscription HTTP fixture accepted: \(path)")
            } catch let error as DeskProxyError {
                let message = error.localizedDescription
                precondition(!message.contains("fixture-sensitive-response-never-display"))
                precondition(!message.contains("fixture-url-token") && !message.contains("fixture-password"))
                if path.hasPrefix("/oversize") { precondition(message.contains("2 MB"), "Body limit must reject before parsing at \(path): \(message)") }
            }
        }
        print("Passed unsuccessful HTTP/HTML responses, credential redirects and declared/streamed 2 MB limits with sanitized errors.")

        let pending = Task { try await DeskProxySubscriptionFetch.fetch(base + "/slow") }
        var started = false
        for _ in 0..<200 {
            if try await records().contains(where: { $0["path"] == "/slow" }) { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(started, "Cancellation fixture did not start")
        let cancelledAt = Date()
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled fetch returned usable nodes") }
        catch { precondition(Date().timeIntervalSince(cancelledAt) < 5) }
        print("Passed cancellation of an active streaming subscription without returning usable nodes.")
        print("Passed subscription fetch integration checks against loopback only; no external service contacted.")
    }
}
