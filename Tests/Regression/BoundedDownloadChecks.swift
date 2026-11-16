import Foundation

@main
struct BoundedDownloadChecks {
    static func main() async throws {
        let base = URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])")!
        let limit = 256 * 1024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // This isolated route has no relationship to the user's live app proxy.
        let network = DeskProxyNetwork()
        let session = network.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let observer = URLSession(configuration: configuration)
        defer { observer.invalidateAndCancel() }

        func request(_ path: String) -> URLRequest {
            URLRequest(url: base.appendingPathComponent(path))
        }
        func fetch(_ path: String) async throws -> (URL, URLResponse) {
            try await session.download(for: request(path), maximumBytes: limit, allowedSchemes: ["http"])
        }
        func reject(_ path: String, code: URLError.Code, alternate: URLError.Code? = nil) async throws {
            do {
                let (file, _) = try await fetch(path)
                try? FileManager.default.removeItem(at: file)
                preconditionFailure("Unsafe download was accepted: \(path)")
            } catch let error as URLError {
                precondition(error.code == code || error.code == alternate,
                             "Unexpected download failure for \(path): \(error.code)")
            }
        }
        func records() async throws -> [String: [String: Int]] {
            let (data, _) = try await observer.data(for: request("stats"))
            return try JSONDecoder().decode([String: [String: Int]].self, from: data)
        }
        func waitUntilStarted(_ path: String) async throws {
            for _ in 0..<200 {
                if try await records()["/" + path]?["requests"] == 1 { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Download fixture did not start")
        }

        do {
            _ = try await session.download(for: request("default-reject"), maximumBytes: limit)
            preconditionFailure("Media policy must require HTTPS by default")
        } catch let error as URLError { precondition(error.code == .badURL) }
        for value in ["http://fixture:password@127.0.0.1:\(CommandLine.arguments[1])/credential-reject",
                      "file:///tmp/not-a-network-image"] {
            do {
                _ = try await session.download(for: URLRequest(url: URL(string: value)!), maximumBytes: limit,
                                               allowedSchemes: ["http"])
                preconditionFailure("Invalid initial URL was accepted")
            } catch let error as URLError { precondition(error.code == .badURL) }
        }
        print("PASS default HTTPS, unsupported scheme and embedded-credential rejection before transport")

        for path in ["small", "exact", "redirect", "cookie-set", "cookie-check", "cookie-redirect"] {
            let (file, response) = try await fetch(path)
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            precondition(data.count == (path == "exact" ? limit : 128))
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
        }
        print("PASS small and exact-limit transfers, allowed redirect and isolated cookies")

        for path in ["oversize-declared", "oversize-stream", "oversize-chunked"] {
            try await reject(path, code: .dataLengthExceedsMaximum)
        }
        try await reject("redirect-credentials", code: .badURL)
        // Foundation can reject a file redirect before invoking our policy.
        try await reject("redirect-file", code: .badURL, alternate: .noPermissionsToReadFile)
        let stats = try await records()
        for path in ["/oversize-declared", "/oversize-stream", "/oversize-chunked"] {
            let sent = stats[path]?["sent"] ?? Int.max
            // The delegate may observe a coalesced socket chunk past the cap;
            // it must abort well before the 8 MB body is completely received.
            precondition(sent < limit * 4, "Download limit was checked only after the full body: \(path)")
            print("PASS \(path): server sent \(sent) of \(limit * 32) bytes before client rejection")
        }
        precondition(stats["/credential-reject"] == nil && stats["/default-reject"] == nil && stats["/credential-target"] == nil)
        precondition(stats.values.allSatisfy { $0["cookie", default: 0] == 0 && $0["authorization", default: 0] == 0 })
        print("PASS declared, unknown-length and chunked overflow aborted during transfer; unsafe redirects never followed")

        // A rejected transfer cannot poison an independent request using the
        // same URLSession, or retain its per-task error on a later transfer.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reject("parallel-large", code: .dataLengthExceedsMaximum) }
            group.addTask {
                let (file, _) = try await fetch("parallel-small")
                defer { try? FileManager.default.removeItem(at: file) }
                let data = try Data(contentsOf: file)
                precondition(data.count == 128)
            }
            try await group.waitForAll()
        }
        let (file, _) = try await fetch("after-rejection")
        try FileManager.default.removeItem(at: file)
        print("PASS independent concurrent limits and successful transfer after rejection")

        let cancelled = Task { try await fetch("slow-cancel") }
        try await waitUntilStarted("slow-cancel")
        cancelled.cancel()
        let cancellationTime = Date()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled download succeeded") }
        catch is CancellationError {}
        precondition(Date().timeIntervalSince(cancellationTime) < 2)

        let rerouted = Task { try await fetch("slow-route") }
        try await waitUntilStarted("slow-route")
        network.setEndpoint(.blocked())
        do { _ = try await rerouted.value; preconditionFailure("Download crossed a route change") }
        catch let error as URLError { precondition(error.code == .cancelled) }
        network.setEndpoint(nil)
        let (last, _) = try await fetch("after-route")
        try FileManager.default.removeItem(at: last)
        print("PASS prompt cancellation, route invalidation and recovery")
        print("All bounded download checks passed against loopback only; no account, keychain or live proxy changed.")
    }
}
