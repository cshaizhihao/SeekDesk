import Foundation

enum DeskProxyError: LocalizedError {
    case invalid(String), keychain, missingCore, startup, interrupted
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .keychain: "无法访问代理节点钥匙串。请检查 macOS 的授权提示。"
        case .missingCore: "安装包中缺少代理内核，请重新安装完整的 SeekDesk。"
        case .startup: "代理内核未能启动。请检查节点参数后重试；SeekDesk 未回退直连。"
        case .interrupted: "代理已中断。请重新连接或主动关闭代理；SeekDesk 未回退直连。"
        }
    }
}

/// Credentials and original links are persisted only in Keychain, never in defaults or logs.
struct DeskProxyNode: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    let scheme: String
    let host: String
    let port: Int
    let link: String
    let outbound: Data
    var subscriptionID: UUID?

    var identity: Data { outbound }
    var protocolName: String {
        switch scheme {
        case "ss": "SS"
        case "hysteria2": "HY2"
        default: scheme.uppercased()
        }
    }

    static func parse(_ input: String) throws -> Self {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16_384, !raw.contains(where: { $0.isWhitespace }) else {
            throw DeskProxyError.invalid("请每次粘贴一个完整的节点链接。")
        }
        if raw.lowercased().hasPrefix("vmess://") { return try vmess(raw) }
        if raw.lowercased().hasPrefix("ss://") { return try shadowsocks(raw) }
        if ["hysteria2://", "hy2://"].contains(where: { raw.lowercased().hasPrefix($0) }) { return try hysteria2(raw) }
        if ["socks://", "socks5://", "http://", "https://"].contains(where: { raw.lowercased().hasPrefix($0) }) { return try standardProxy(raw) }
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              ["vless", "trojan"].contains(scheme) else {
            throw DeskProxyError.invalid("支持 VLESS、VMess、SS、Trojan、Hysteria2、SOCKS5 和 HTTP/HTTPS；TUIC、SSR 暂不受当前内核支持。")
        }
        let (host, port) = try endpoint(c.host, c.port)
        guard let user = c.user, !user.isEmpty, c.password == nil, ["", "/"].contains(c.path) else {
            throw DeskProxyError.invalid("节点缺少有效的 UUID 或密码。")
        }
        let q = try query(c)
        try validateKeys(q, allowed: ["type", "security", "sni", "peer", "fp", "alpn", "pbk", "sid", "spx", "flow", "encryption", "host", "path", "serviceName", "mode", "authority", "headerType", "allowInsecure", "insecure", "packetEncoding"])
        if let value = q["encryption"], value != "none" {
            throw DeskProxyError.invalid("此版本仅支持 encryption=none 的 VLESS 链接。")
        }
        if let value = q["packetEncoding"], !["xudp", "none"].contains(value) {
            throw DeskProxyError.invalid("暂不支持此 packetEncoding 参数。")
        }
        if scheme == "trojan", ["flow", "encryption", "packetEncoding"].contains(where: { q[$0] != nil }) {
            throw DeskProxyError.invalid("Trojan 链接不能包含 VLESS 专用参数。")
        }
        let stream = try transport(q, defaultSecurity: scheme == "trojan" ? "tls" : "none")
        var account: [String: Any]
        if scheme == "vless" {
            guard UUID(uuidString: user) != nil else { throw DeskProxyError.invalid("VLESS UUID 格式不正确。") }
            account = ["id": user, "encryption": "none"]
            if let flow = q["flow"], !flow.isEmpty {
                guard flow == "xtls-rprx-vision", ["tcp", "raw"].contains(q["type"] ?? "tcp"),
                      ["tls", "reality"].contains(q["security"] ?? "none") else {
                    throw DeskProxyError.invalid("Vision 需要 TCP 配合 TLS 或 Reality。")
                }
                account["flow"] = flow
            }
        } else { account = ["password": user] }
        let settings: [String: Any] = scheme == "vless"
            ? ["vnext": [["address": host, "port": port, "users": [account]]]]
            : ["servers": [["address": host, "port": port, "password": user]]]
        var outbound: [String: Any] = ["protocol": scheme, "settings": settings, "streamSettings": stream]
        if let encoding = q["packetEncoding"] { outbound["settings"] = settings.merging(["packetEncoding": encoding]) { _, new in new } }
        return try node(raw, name: c.fragment, scheme: scheme, host: host, port: port, outbound: outbound)
    }

    private static func standardProxy(_ raw: String) throws -> Self {
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), ["", "/"].contains(c.path) else {
            throw DeskProxyError.invalid("代理服务器链接格式不正确；订阅地址请在“订阅链接”中导入。")
        }
        let (host, port) = try endpoint(c.host, c.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 1080))
        let q = try query(c)
        try validateKeys(q, allowed: scheme == "https" ? ["sni", "peer", "fp", "alpn"] : [])
        var server: [String: Any] = ["address": host, "port": port]
        if let user = c.user {
            guard !user.isEmpty, let password = c.password, !password.isEmpty else { throw DeskProxyError.invalid("代理鉴权需要同时填写用户名和密码。") }
            server["users"] = [["user": user, "pass": password]]
        } else if c.password != nil { throw DeskProxyError.invalid("代理缺少用户名。") }
        let socks = ["socks", "socks5"].contains(scheme)
        var outbound: [String: Any] = ["protocol": socks ? "socks" : "http", "settings": ["servers": [server]]]
        if scheme == "https" { outbound["streamSettings"] = try transport(q, defaultSecurity: "tls") }
        return try node(raw, name: c.fragment, scheme: socks ? "socks5" : scheme, host: host, port: port, outbound: outbound)
    }

    private static func hysteria2(_ raw: String) throws -> Self {
        guard let c = URLComponents(string: raw), let user = c.user, !user.isEmpty, ["", "/"].contains(c.path) else {
            throw DeskProxyError.invalid("Hysteria2 链接缺少有效鉴权信息。")
        }
        let (host, port) = try endpoint(c.host, c.port ?? 443)
        let q = try query(c)
        try validateKeys(q, allowed: ["sni", "insecure", "allowInsecure", "obfs", "obfs-password"])
        let auth = user + (c.password.map { ":" + $0 } ?? "")
        var stream = try transport(q, defaultSecurity: "tls")
        stream["network"] = "hysteria"
        stream["hysteriaSettings"] = ["version": 2, "auth": auth]
        if let obfs = q["obfs"], !obfs.isEmpty {
            guard obfs == "salamander", let password = q["obfs-password"], !password.isEmpty else {
                throw DeskProxyError.invalid("Hysteria2 混淆需要 salamander 及有效混淆密码。")
            }
            stream["finalmask"] = ["udp": [["type": "salamander", "settings": ["password": password]]]]
        } else if q["obfs-password"] != nil { throw DeskProxyError.invalid("混淆密码必须配合 salamander 使用。") }
        return try node(raw, name: c.fragment, scheme: "hysteria2", host: host, port: port, outbound: [
            "protocol": "hysteria", "settings": ["version": 2, "address": host, "port": port], "streamSettings": stream])
    }

    private static func vmess(_ raw: String) throws -> Self {
        let payload = String(raw.dropFirst(8)).components(separatedBy: "#")[0]
        guard let bytes = base64(payload), let q = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DeskProxyError.invalid("VMess 链接必须包含有效的 Base64 JSON。")
        }
        let allowed: Set<String> = ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "alpn", "fp", "allowInsecure", "insecure"]
        guard Set(q.keys).isSubset(of: allowed), q.values.allSatisfy({ $0 is String || $0 is NSNumber }) else {
            throw DeskProxyError.invalid("VMess 链接含有不支持的参数或格式。")
        }
        func string(_ key: String, _ fallback: String = "") -> String {
            if let value = q[key] as? String { return value }
            if let value = q[key] as? NSNumber { return value.stringValue }
            return fallback
        }
        let (host, port) = try endpoint(string("add"), Int(string("port")))
        guard ["", "2"].contains(string("v")) else { throw DeskProxyError.invalid("仅支持标准 VMess v2 分享格式。") }
        let id = string("id")
        guard UUID(uuidString: id) != nil, ["", "0"].contains(string("aid")) else {
            throw DeskProxyError.invalid("VMess 需要有效 UUID，且仅支持 alterId=0。")
        }
        guard ["", "none"].contains(string("type")), ["", "tls", "none"].contains(string("tls")) else {
            throw DeskProxyError.invalid("暂不支持此 VMess 伪装或安全类型。")
        }
        let cipher = string("scy", "auto")
        guard ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"].contains(cipher) else {
            throw DeskProxyError.invalid("不支持此 VMess 加密方式。")
        }
        let network = string("net", "tcp")
        var parameters = ["type": network, "security": string("tls").isEmpty ? "none" : string("tls"),
            "sni": string("sni"), "host": string("host"), "path": string("path", "/"),
            "alpn": string("alpn"), "fp": string("fp"),
            "allowInsecure": string("allowInsecure", "false"), "insecure": string("insecure", "false")]
        if network == "grpc" { parameters["serviceName"] = parameters.removeValue(forKey: "path") }
        let stream = try transport(parameters, defaultSecurity: "none")
        return try node(raw, name: string("ps"), scheme: "vmess", host: host, port: port, outbound: [
            "protocol": "vmess", "settings": ["vnext": [["address": host, "port": port,
                "users": [["id": id, "alterId": 0, "security": cipher]]]]], "streamSettings": stream])
    }

    private static func shadowsocks(_ raw: String) throws -> Self {
        var normalized = raw
        let body = String(raw.dropFirst(5)).components(separatedBy: "#")[0]
        if !body.contains("@") {
            guard let data = base64(body), let decoded = String(data: data, encoding: .utf8) else {
                throw DeskProxyError.invalid("Shadowsocks Base64 内容无效。")
            }
            guard let at = decoded.lastIndex(of: "@") else { throw DeskProxyError.invalid("Shadowsocks 缺少服务器地址。") }
            // The legacy payload is plain credentials, not percent-encoded URL userinfo.
            let credential = Data(decoded[..<at].utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            normalized = "ss://" + credential + "@" + decoded[decoded.index(after: at)...] + (raw.contains("#") ? "#" + raw.components(separatedBy: "#").dropFirst().joined(separator: "#") : "")
        }
        guard let c = URLComponents(string: normalized), let user = c.user, ["", "/"].contains(c.path) else {
            throw DeskProxyError.invalid("Shadowsocks 链接不完整。")
        }
        let (host, port) = try endpoint(c.host, c.port)
        let q = try query(c)
        guard q.isEmpty else { throw DeskProxyError.invalid("暂不支持带 SIP003 插件或额外参数的 Shadowsocks 链接。") }
        let credential: String
        if let password = c.password { credential = user + ":" + password }
        else {
            guard let bytes = base64(user), let text = String(data: bytes, encoding: .utf8) else {
                throw DeskProxyError.invalid("Shadowsocks 用户信息无效。")
            }
            credential = text
        }
        guard let colon = credential.firstIndex(of: ":") else { throw DeskProxyError.invalid("Shadowsocks 缺少加密方式或密码。") }
        let method = String(credential[..<colon]), password = String(credential[credential.index(after: colon)...])
        let methods = ["aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]
        guard methods.contains(method), !password.isEmpty else { throw DeskProxyError.invalid("不支持此 Shadowsocks 加密方式，或密码为空。") }
        return try node(raw, name: c.fragment, scheme: "ss", host: host, port: port, outbound: ["protocol": "shadowsocks",
            "settings": ["servers": [["address": host, "port": port, "method": method, "password": password]]]])
    }

    private static func node(_ raw: String, name: String?, scheme: String, host: String, port: Int, outbound: [String: Any]) throws -> Self {
        let label = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(name: String((label.isEmpty ? scheme.uppercased() + " · " + host : label).prefix(100)),
            scheme: scheme, host: host, port: port, link: raw, outbound: try JSONSerialization.data(withJSONObject: outbound, options: [.sortedKeys]))
    }

    private static func endpoint(_ host: String?, _ port: Int?) throws -> (String, Int) {
        guard let raw = host, !raw.isEmpty, let port, (1...65535).contains(port) else {
            throw DeskProxyError.invalid("节点需要有效服务器地址和 1–65535 的端口。")
        }
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        guard host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/") else { throw DeskProxyError.invalid("服务器地址格式不正确。") }
        return (host, port)
    }

    static func base64(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
    private static func query(_ c: URLComponents) throws -> [String: String] {
        var values: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard values[item.name] == nil else { throw DeskProxyError.invalid("节点含有重复参数，请检查链接。") }
            values[item.name] = item.value ?? ""
        }
        return values
    }
    private static func validateKeys(_ q: [String: String], allowed: Set<String>) throws {
        guard Set(q.keys).isSubset(of: allowed) else { throw DeskProxyError.invalid("节点含有当前版本不支持的参数。") }
    }

    private static func transport(_ q: [String: String], defaultSecurity: String) throws -> [String: Any] {
        guard ["", "none"].contains(q["headerType"] ?? ""),
              ["0", "false", ""].contains(q["allowInsecure"] ?? ""),
              ["0", "false", ""].contains(q["insecure"] ?? "") else {
            throw DeskProxyError.invalid("暂不支持此伪装参数或跳过证书验证的节点。")
        }
        let type = q["type"] ?? "tcp"
        let security = q["security"] ?? defaultSecurity
        func present(_ key: String) -> Bool { !(q[key] ?? "").isEmpty }
        if present("sni"), present("peer"), q["sni"] != q["peer"] { throw DeskProxyError.invalid("sni 与 peer 参数不一致。") }
        if type != "grpc", ["serviceName", "authority"].contains(where: present) { throw DeskProxyError.invalid("serviceName / authority 仅适用于 gRPC。") }
        if ["tcp", "raw"].contains(type), present("host") || (present("path") && q["path"] != "/") { throw DeskProxyError.invalid("普通 TCP 节点不能包含 Host 或路径伪装参数。") }
        if type == "grpc", present("path") && q["path"] != "/" { throw DeskProxyError.invalid("gRPC 请使用 serviceName 参数。") }
        if ["", "none"].contains(security), ["sni", "peer", "fp", "alpn", "pbk", "sid", "spx"].contains(where: present) { throw DeskProxyError.invalid("未开启 TLS / Reality 的节点不能包含安全层参数。") }
        if security != "reality", ["pbk", "sid", "spx"].contains(where: present) { throw DeskProxyError.invalid("pbk / sid / spx 仅适用于 Reality。") }
        if security == "reality", present("alpn") { throw DeskProxyError.invalid("Reality 链接不支持自定义 ALPN。") }
        if let mode = q["mode"], !mode.isEmpty {
            guard type == "xhttp" || (type == "grpc" && ["gun", "multi"].contains(mode)) else {
                throw DeskProxyError.invalid("此传输方式不支持链接中的 mode 参数。")
            }
        }
        var stream: [String: Any] = ["network": type]
        switch type {
        case "tcp", "raw": break
        case "ws":
            var ws: [String: Any] = ["path": q["path"] ?? "/"]
            if let host = q["host"], !host.isEmpty { ws["host"] = host }
            stream["wsSettings"] = ws
        case "grpc":
            if present("host"), present("authority"), q["host"] != q["authority"] { throw DeskProxyError.invalid("gRPC host 与 authority 不一致。") }
            stream["grpcSettings"] = ["serviceName": q["serviceName"] ?? "", "authority": q["authority"] ?? q["host"] ?? "",
                "multiMode": q["mode"] == "multi"]
        case "httpupgrade": stream["httpupgradeSettings"] = ["host": q["host"] ?? "", "path": q["path"] ?? "/"]
        case "xhttp":
            let mode = q["mode"] ?? "auto"
            guard ["auto", "packet-up", "stream-up", "stream-one"].contains(mode) else { throw DeskProxyError.invalid("不支持此 XHTTP 模式。") }
            stream["xhttpSettings"] = ["host": q["host"] ?? "", "path": q["path"] ?? "/", "mode": mode]
        default: throw DeskProxyError.invalid("暂不支持此传输方式，支持 TCP、WS、gRPC、HTTPUpgrade 和 XHTTP。")
        }
        stream["security"] = security
        let serverName = q["sni"] ?? q["peer"] ?? ""
        let fingerprint = q["fp"] ?? ""
        guard ["", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"].contains(fingerprint) else {
            throw DeskProxyError.invalid("暂不支持此 TLS 指纹。")
        }
        switch security {
        case "", "none": stream["security"] = "none"
        case "tls":
            var tls: [String: Any] = ["allowInsecure": false]
            if !serverName.isEmpty { tls["serverName"] = serverName }
            if !fingerprint.isEmpty { tls["fingerprint"] = fingerprint }
            if let alpn = q["alpn"], !alpn.isEmpty { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            stream["tlsSettings"] = tls
        case "reality":
            guard ["tcp", "raw", "grpc", "xhttp"].contains(type) else {
                throw DeskProxyError.invalid("Reality 不支持此传输方式。")
            }
            guard let key = q["pbk"], base64(key)?.count == 32, !serverName.isEmpty else {
                throw DeskProxyError.invalid("Reality 需要有效的公钥 pbk 和服务器名称 sni。")
            }
            let sid = q["sid"] ?? ""
            guard sid.count <= 16, sid.count.isMultiple(of: 2), sid.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw DeskProxyError.invalid("Reality shortId 必须为不超过 16 位的偶数长度十六进制。")
            }
            stream["realitySettings"] = ["serverName": serverName, "publicKey": key, "shortId": sid,
                "fingerprint": fingerprint.isEmpty ? "chrome" : fingerprint, "spiderX": q["spx"] ?? "/"]
        default: throw DeskProxyError.invalid("仅支持 none、TLS 和 Reality 安全类型。")
        }
        return stream
    }

    func configuration(port: UInt16, username: String, password: String) throws -> Data {
        var outbound = try JSONSerialization.jsonObject(with: self.outbound) as! [String: Any]
        outbound["tag"] = "node"
        return try JSONSerialization.data(withJSONObject: ["log": ["loglevel": "none"],
            "inbounds": [["tag": "seekdesk", "listen": "127.0.0.1", "port": Int(port), "protocol": "http",
                "settings": ["accounts": [["user": username, "pass": password]], "allowTransparent": false]]],
            "outbounds": [outbound]], options: [.sortedKeys])
    }
}
