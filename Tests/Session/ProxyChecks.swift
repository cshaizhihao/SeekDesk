import Foundation

func checkProxyNodes() throws {
    let uuid = "00000000-0000-4000-8000-000000000001"
    let vless = "vless://" + uuid + "@example.invalid:443"
    let key = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    func encoded(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    func vmess(_ extra: [String: Any] = [:]) throws -> String {
        let values: [String: Any] = ["v": "2", "ps": "VMess fixture", "add": "example.invalid", "port": 443,
            "id": uuid, "aid": 0, "net": "ws", "type": "none", "host": "edge.example.invalid",
            "path": "/socket", "tls": "tls", "sni": "example.invalid"]
        return "vmess://" + (try JSONSerialization.data(withJSONObject: values.merging(extra) { _, new in new })).base64EncodedString()
    }
    let fixtures = [
        vless + "?security=tls&type=ws&host=edge.example.invalid&path=%2Fws&alpn=h2%2Chttp%2F1.1#Test%20node",
        vless + "?security=reality&sni=example.invalid&pbk=" + key + "&sid=abcd&flow=xtls-rprx-vision&packetEncoding=xudp",
        vless + "?type=grpc&security=tls&serviceName=service&authority=edge.example.invalid&mode=multi",
        vless + "?type=xhttp&security=tls&path=%2F&mode=packet-up",
        vless + "?type=httpupgrade&security=tls&host=example.invalid&path=%2F",
        "trojan://fixture%40password@example.invalid:443?security=tls&sni=example.invalid#Trojan",
        "ss://" + encoded("aes-128-gcm:fixture-password") + "@example.invalid:8388#SIP002",
        "ss://" + encoded("aes-256-gcm:fixture-password@example.invalid:8388") + "#Legacy",
        "ss://chacha20-ietf-poly1305:fixture%40password@[::1]:8388/#IPv6",
        "ss://" + encoded("2022-blake3-aes-128-gcm:" + Data(repeating: 1, count: 16).base64EncodedString()) + "@example.invalid:8388",
        try vmess(), try vmess(["net": "tcp", "tls": "none", "path": "", "host": "", "sni": ""]),
        "vless://" + uuid + "@[2001:db8::1]:443?security=tls&sni=example.invalid",
        "hysteria2://fixture%3Apassword@example.invalid:443?sni=example.invalid#HY2",
        "hy2://fixture:password@example.invalid/?sni=example.invalid&obfs=salamander&obfs-password=fixture-obfs#HY2-obfs",
        "socks5://fixture:pass%40word@[2001:db8::1]:1080#SOCKS5",
        "socks://example.invalid:1080",
        "http://fixture:password@example.invalid:8080#HTTP",
        "https://fixture:password@example.invalid:8443?sni=example.invalid&alpn=http%2F1.1#HTTPS"
    ]
    let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Distribution/ProxyCore/xray")
    precondition(FileManager.default.isExecutableFile(atPath: core.path), "Bundled proxy core is required for schema checks.")
    for link in fixtures {
        let node = try DeskProxyNode.parse(link)
        let config = try node.configuration(port: 12345, username: "local-user", password: "local-password")
        let json = try JSONSerialization.jsonObject(with: config) as! [String: Any]
        let inbound = (json["inbounds"] as! [[String: Any]])[0]
        precondition(inbound["listen"] as? String == "127.0.0.1" && inbound["protocol"] as? String == "http")
        precondition((json["outbounds"] as! [[String: Any]]).count == 1 && json["routing"] == nil)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = core
        process.arguments = ["run", "-test", "-format", "json", "-c", "stdin:"]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: config); try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Xray rejected " + node.scheme + " fixture: " + String(decoding: result, as: UTF8.self))
    }
    let named = try DeskProxyNode.parse(" \n" + fixtures[0] + "\n")
    precondition(named.name == "Test node" && named.host == "example.invalid" && named.port == 443)
    let trojan = try DeskProxyNode.parse(fixtures[5])
    let outbound = try JSONSerialization.jsonObject(with: trojan.outbound) as! [String: Any]
    let servers = (outbound["settings"] as! [String: Any])["servers"] as! [[String: Any]]
    precondition(servers[0]["password"] as? String == "fixture@password")
    for password in ["p%40ss", "p#ss", "p?ss", "p@ss"] {
        let legacy = try DeskProxyNode.parse("ss://" + encoded("aes-128-gcm:" + password + "@example.invalid:8388"))
        let config = try JSONSerialization.jsonObject(with: legacy.outbound) as! [String: Any]
        let server = ((config["settings"] as! [String: Any])["servers"] as! [[String: Any]])[0]
        precondition(server["password"] as? String == password)
    }
    let reality = try DeskProxyNode.parse(fixtures[1])
    let realityJSON = try JSONSerialization.jsonObject(with: reality.outbound) as! [String: Any]
    precondition((realityJSON["settings"] as! [String: Any])["packetEncoding"] as? String == "xudp")
    let invalid = [
        "", "https://example.invalid/subscription", "vless://invalid@example.invalid:443",
        vless + "?unknown=value", vless + "?security=tls&security=none", vless + "?allowInsecure=1",
        vless + "?security=xtls", vless + "?encryption=other", vless + "?type=kcp",
        vless + "?security=reality&sni=example.invalid&pbk=bad",
        vless + "?security=reality&sni=example.invalid&pbk=" + key + "&sid=xyz",
        vless + "?security=reality&sni=example.invalid&pbk=" + key + "&type=ws",
        vless + "?flow=xtls-rprx-vision&type=ws&security=tls",
        vless + "?type=grpc&mode=invalid", vless + "?type=xhttp&mode=invalid",
        vless + "?security=tls&fp=unknown", vless + "/extra", vless + "\n" + vless,
        vless + "?type=ws&serviceName=unused", vless + "?security=none&sni=example.invalid",
        vless + "?type=grpc&security=tls&host=one.invalid&authority=two.invalid",
        "vless://" + uuid + "@example.invalid:0", "vless://" + uuid + "@example.invalid:65536",
        "trojan://@example.invalid:443", "trojan://password@example.invalid:443?flow=xtls-rprx-vision",
        "ss://" + encoded("rc4-md5:password") + "@example.invalid:8388",
        "ss://" + encoded("aes-128-gcm:password") + "@example.invalid:8388?plugin=obfs-local",
        "hy2://password@example.invalid?insecure=1", "hy2://password@example.invalid?obfs=unknown&obfs-password=x",
        "hy2://password@example.invalid?obfs=salamander", "hy2://password@example.invalid?mport=443-8443",
        "hy2://password@example.invalid?obfs-password=x", "hy2://@example.invalid:443",
        "socks5://user@example.invalid:1080", "socks5://example.invalid:1080?unknown=value",
        "http://example.invalid/path", "https://example.invalid?insecure=1", "tuic://test@example.invalid:443",
        "vmess://invalid-base64", try vmess(["aid": 64]), try vmess(["unknown": "value"]),
        try vmess(["allowInsecure": true]), try vmess(["insecure": "1"]), try vmess(["tls": "xtls"]),
        String(repeating: "x", count: 16_385)
    ]
    for link in invalid {
        do { _ = try DeskProxyNode.parse(link); preconditionFailure("An unsupported or malformed fixture was accepted.") }
        catch is DeskProxyError {}
    }
    try checkProxySubscriptions(fixtures: fixtures)
    print("Passed proxy share-link parsing, unsupported parameters, credentials, IPv6, TLS/Reality and " + String(fixtures.count) + " offline Xray configuration checks.")
}

private func checkProxySubscriptions(fixtures: [String]) throws {
    let plain = fixtures.joined(separator: "\n") + "\n" + fixtures[0] + "\ntuic://secret@example.invalid:443\n"
    let imported = try DeskProxySubscriptionParser.parse(Data(plain.utf8))
    precondition(imported.nodes.count == fixtures.count && imported.duplicates == 1 && imported.skipped.count == 1)
    precondition(!imported.skipped[0].contains("secret"))
    let encoded = Data(plain.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let base64 = try DeskProxySubscriptionParser.parse(Data(("\n" + encoded + "\n").utf8))
    precondition(base64.nodes.map(\.identity) == imported.nodes.map(\.identity))
    let yaml = """
    mixed-port: 7890
    rules: [MATCH,DIRECT]
    defaults: &base {server: example.invalid, port: 443}
    proxies:
      - {<<: *base, name: '香港 #1', type: vless, uuid: 00000000-0000-4000-8000-000000000001, tls: true, network: ws, ws-opts: {path: /ws, headers: {Host: edge.example.invalid}}}
      - name: HY2
        type: hysteria2
        server: example.invalid
        port: 443
        password: '123456'
        sni: example.invalid
        obfs: salamander
        obfs-password: 'fixture-password'
      - {name: HTTPS, type: http, server: example.invalid, port: 443, tls: true, username: fixture, password: password}
      - {name: VMess, type: vmess, server: example.invalid, port: 443, uuid: 00000000-0000-4000-8000-000000000001, alterId: 0, cipher: auto, tls: true, network: grpc, grpc-opts: {grpc-service-name: service}}
      - {name: SS, type: ss, server: example.invalid, port: 8388, cipher: aes-128-gcm, password: fixture}
      - {name: SOCKS, type: socks5, server: '2001:db8::1', port: 1080}
      - {name: Trojan, type: trojan, server: example.invalid, port: 443, password: 'a@b:c'}
      - {name: TUIC, type: tuic, server: example.invalid, port: 443, password: secret}
      - {name: unsupported, type: ss, server: example.invalid, port: 8388, cipher: aes-128-gcm, password: secret, plugin: obfs}
    """
    let clash = try DeskProxySubscriptionParser.parse(Data(yaml.utf8))
    precondition(clash.nodes.map(\.name) == ["香港 #1", "HY2", "HTTPS", "VMess", "SS", "SOCKS", "Trojan"] &&
                 clash.skipped.count == 2,
                 "Unexpected Clash fixtures: accepted \(clash.nodes.map(\.name)), skipped \(clash.skipped)")
    let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Distribution/ProxyCore/xray")
    for node in clash.nodes {
        let process = Process(), pipe = Pipe()
        process.executableURL = core
        process.arguments = ["run", "-test", "-format", "json", "-c", "stdin:"]
        process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: node.configuration(port: 12345, username: "local", password: "local"))
        try pipe.fileHandleForWriting.close(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Clash translation rejected: " + node.scheme)
    }
    let invalid = [Data("<html>login</html>".utf8), Data("proxies: [invalid]".utf8), Data("proxies: [{type: ss, password: secret, password: other}]".utf8),
                   Data("proxies: [{type: http, server: example.invalid, port: 443, username: fixture, password: null}]".utf8),
                   Data("proxies: [{type: ss, server: example.invalid, port: 443, cipher: aes-128-gcm, password: fixture, xhttp-opts: {path: /test}}]".utf8),
                   Data("proxies: [{type: vless, uuid: 00000000-0000-4000-8000-000000000001, server: example.invalid, port: 443, network: ws, ws-opts: {path: [/test]}}]".utf8),
                   Data("proxies: [{type: vmess, uuid: 00000000-0000-4000-8000-000000000001, server: example.invalid, port: 443, network: xhttp, xhttp-opts: {mode: stream-one}}]".utf8),
                   Data(("proxies: " + String(repeating: "[", count: 40) + "x" + String(repeating: "]", count: 40)).utf8),
                   Data(repeating: 65, count: DeskProxySubscriptionParser.byteLimit + 1)]
    for data in invalid {
        do { _ = try DeskProxySubscriptionParser.parse(data); preconditionFailure("Malformed subscription was accepted.") }
        catch let error as DeskProxyError { precondition(!error.localizedDescription.contains("secret")) }
    }
    let literal = try DeskProxySubscriptionParser.parse(Data("proxies: [{type: http, server: example.invalid, port: 443, username: fixture, password: 'null'}]".utf8))
    precondition(literal.nodes.count == 1 && literal.nodes[0].link.contains("null"))
    for prefix in ["external-ui-url: https://example.invalid/ui.zip\nproxies:", "proxies :", "'proxies':"] {
        let parsed = try DeskProxySubscriptionParser.parse(Data((prefix + " [{type: socks5, server: example.invalid, port: 1080}]").utf8))
        precondition(parsed.nodes.count == 1)
    }
    let upgrade = try DeskProxySubscriptionParser.parse(Data("proxies: [{type: vless, uuid: 00000000-0000-4000-8000-000000000001, server: example.invalid, port: 443, network: httpupgrade, http-upgrade-opts: {host: desired.example.invalid, headers: {}}}]".utf8))
    let upgradeJSON = try JSONSerialization.jsonObject(with: upgrade.nodes[0].outbound) as! [String: Any]
    precondition(((upgradeJSON["streamSettings"] as! [String: Any])["httpupgradeSettings"] as! [String: Any])["host"] as? String == "desired.example.invalid")
    for url in ["file:///tmp/nodes", "https://user:password@example.invalid/sub", "https://example.invalid:70000/sub", "not a URL"] {
        do { _ = try DeskProxySubscriptionFetch.validatedURL(url); preconditionFailure("Invalid subscription URL accepted.") }
        catch is DeskProxyError { }
    }
    let legacy = try JSONEncoder().encode(Array(imported.nodes.prefix(1)))
    let decoded = try JSONDecoder().decode([DeskProxyNode].self, from: legacy)
    precondition(decoded[0].subscriptionID == nil)
    print("Passed subscription plain/Base64/Clash imports, aliases, credentials, deduplication, malformed input, size/depth limits and protocol configuration checks.")
}
