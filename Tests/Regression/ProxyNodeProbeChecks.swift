import AppKit
import Foundation

@main struct ProxyNodeProbeChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let core = URL(fileURLWithPath: CommandLine.arguments[1])
        let vlessPort = CommandLine.arguments[2], hy2Port = CommandLine.arguments[3], originPort = CommandLine.arguments[4]
        let cert = try String(contentsOfFile: CommandLine.arguments[5], encoding: .utf8)
        let closedPort = CommandLine.arguments[6]
        let target = URL(string: "http://seekdesk-node-probe.invalid/generate_204")!
        let good = try DeskProxyNode.parse("vless://00000000-0000-4000-8000-000000000001@127.0.0.1:\(vlessPort)")
        let bad = try DeskProxyNode.parse("vless://00000000-0000-4000-8000-000000000002@127.0.0.1:\(vlessPort)")
        let unavailable = try DeskProxyNode.parse("vless://00000000-0000-4000-8000-000000000001@127.0.0.1:\(closedPort)")
        let observer = URLSession(configuration: .ephemeral)
        defer { observer.invalidateAndCancel() }
        func records() async throws -> [[String: String]] {
            let (data, _) = try await observer.data(from: URL(string: "http://127.0.0.1:\(originPort)/stats")!)
            return try JSONDecoder().decode([[String: String]].self, from: data)
        }
        // The process-local shared route is deliberately blocked; the probe must use only its own temporary route.
        DeskProxyNetwork.shared.setEndpoint(.blocked())
        let revision = DeskProxyNetwork.shared.revision
        defer { DeskProxyNetwork.shared.setEndpoint(nil) }
        let result = try await DeskProxyNodeProbe.measure(node: good, coreURL: core, targetURL: target)
        precondition(result > 0 && result <= 10_000)
        precondition(DeskProxyNetwork.shared.revision == revision && DeskProxyNetwork.shared.requiresProxy)
        try checkNoHelpers()
        print("Passed actual VLESS handshake and HTTP 204 request through an isolated Xray, without altering the active app route.")

        // Trust only the test fixture's temporary certificate inside this test node; no system trust changes.
        let parsedHY2 = try DeskProxyNode.parse("hy2://fixture-hysteria-auth@127.0.0.1:\(hy2Port)?sni=localhost")
        let hy2 = try withFixtureCertificate(parsedHY2, certificate: cert)
        let hy2Result = try await DeskProxyNodeProbe.measure(node: hy2, coreURL: core, targetURL: target)
        precondition(hy2Result > 0 && hy2Result <= 10_000)
        try checkNoHelpers()
        print("Passed Hysteria2 UDP/QUIC and verified TLS handshake against a local Xray server and HTTP 204 origin.")

        let beforeFailures = try await records().count
        for node in [bad, unavailable] {
            do { _ = try await DeskProxyNodeProbe.measure(node: node, coreURL: core, targetURL: target); preconditionFailure("Invalid node was usable") }
            catch let error as DeskProxyNodeProbe.Failure {
                precondition(!error.localizedDescription.contains("00000000") && !error.localizedDescription.contains("127.0.0.1"))
            }
            try checkNoHelpers()
        }
        let afterFailures = try await records().count
        precondition(afterFailures == beforeFailures, "Failed nodes reached origin by direct fallback")
        print("Passed rejected VLESS credentials and unavailable nodes without direct fallback or leaked helper processes.")

        for path in ["wrong", "redirect"] {
            do {
                _ = try await DeskProxyNodeProbe.measure(node: good, coreURL: core, targetURL: URL(string: "http://seekdesk-node-probe.invalid/\(path)")!)
                preconditionFailure("Non-204 response accepted")
            } catch let error as DeskProxyNodeProbe.Failure { precondition(error == .response) }
        }
        let afterRedirect = try await records()
        precondition(!afterRedirect.contains(where: { $0["path"] == "/redirect-target" }))
        print("Passed strict 204 validation and disabled redirects.")

        let pending = Task { try await DeskProxyNodeProbe.measure(node: good, coreURL: core, targetURL: URL(string: "http://seekdesk-node-probe.invalid/slow")!) }
        var began = false
        for _ in 0..<200 {
            if try await records().contains(where: { $0["path"] == "/slow" }) { began = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(began)
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled node probe returned latency") }
        catch is CancellationError {}
        try checkNoHelpers()
        precondition(DeskProxyNetwork.shared.revision == revision)
        print("Passed cancellation during an active proxied request with temporary Xray fully terminated.")
        print("Passed real-protocol node probe integration checks using only local TCP/UDP fixtures.")
    }

    static func withFixtureCertificate(_ node: DeskProxyNode, certificate: String) throws -> DeskProxyNode {
        var outbound = try JSONSerialization.jsonObject(with: node.outbound) as! [String: Any]
        var stream = outbound["streamSettings"] as! [String: Any]
        var tls = stream["tlsSettings"] as! [String: Any]
        tls["certificates"] = [["usage": "verify", "certificate": certificate.components(separatedBy: .newlines).filter { !$0.isEmpty }]]
        stream["tlsSettings"] = tls
        outbound["streamSettings"] = stream
        return DeskProxyNode(id: node.id, name: node.name, scheme: node.scheme, host: node.host, port: node.port,
                             link: node.link, outbound: try JSONSerialization.data(withJSONObject: outbound), subscriptionID: nil)
    }

    static func checkNoHelpers() throws {
        let children = try helperChildren()
        precondition(children.isEmpty, "Temporary Xray process survived completion")
    }

    static func helperChildren() throws -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let parent = String(ProcessInfo.processInfo.processIdentifier)
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter {
            let fields = $0.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            return fields.count == 3 && fields[1] == parent && fields[2].hasSuffix("/xray")
        }
    }
}
