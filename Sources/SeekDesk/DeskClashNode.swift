import Foundation

enum DeskClashNode {
    static func parse(_ values: [String: Any]) throws -> DeskProxyNode {
        func string(_ key: String, _ fallback: String = "") -> String { values[key] as? String ?? fallback }
        let type = string("type").lowercased()
        let base: Set<String> = ["name", "type", "server", "port", "udp", "tfo", "fast-open"]
        let security: Set<String> = ["tls", "servername", "sni", "client-fingerprint", "alpn", "skip-cert-verify"]
        let transport: Set<String> = ["network", "ws-opts", "grpc-opts", "http-upgrade-opts", "xhttp-opts"]
        let specific: Set<String>
        switch type {
        case "ss": specific = ["cipher", "password"]
        case "hysteria2", "hy2": specific = ["password", "sni", "servername", "skip-cert-verify", "obfs", "obfs-password"]
        case "http", "socks5": specific = security.union(["username", "password"])
        case "vless": specific = security.union(transport).union(["uuid", "flow", "encryption", "packet-encoding", "reality-opts"])
        case "vmess": specific = security.union(transport).union(["uuid", "alterId", "cipher"])
        case "trojan": specific = security.union(transport).union(["password", "reality-opts"])
        default: specific = []
        }
        let allowed = base.union(specific)
        guard Set(values.keys).isSubset(of: allowed) else {
            throw DeskProxyError.invalid("节点含有当前不支持的 Clash 参数，已跳过以免改变连接行为。")
        }
        guard ["vless", "vmess", "ss", "trojan", "hysteria2", "hy2", "socks5", "http"].contains(type) else {
            throw DeskProxyError.invalid("当前支持 VLESS、VMess、SS、Trojan、Hysteria2、SOCKS5 和 HTTP/HTTPS；此协议暂不支持。")
        }
        let structured: Set<String> = ["alpn", "ws-opts", "grpc-opts", "http-upgrade-opts", "xhttp-opts", "reality-opts"]
        for (key, value) in values where !structured.contains(key) {
            guard value is String else { throw DeskProxyError.invalid("节点字段类型无效，不能使用空值、列表或对象代替文本。") }
        }
        if values["servername"] != nil, values["sni"] != nil, string("servername") != string("sni") {
            throw DeskProxyError.invalid("节点的 servername 与 sni 不一致。")
        }
        for key in ["tls", "skip-cert-verify", "udp", "tfo", "fast-open"] where values[key] != nil {
            guard ["true", "false", "0", "1"].contains(string(key).lowercased()) else { throw DeskProxyError.invalid("节点开关参数格式无效。") }
        }
        guard !["true", "1"].contains(string("skip-cert-verify").lowercased()) else { throw DeskProxyError.invalid("暂不支持跳过证书验证的节点。") }
        // UDP is unused by this HTTP app proxy; tfo/fast-open are optional socket optimizations.
        let host = string("server"), port = string("port")
        guard !host.isEmpty, let number = Int(port), (1...65535).contains(number) else { throw DeskProxyError.invalid("节点缺少有效服务器地址或端口。") }
        var c = URLComponents()
        c.host = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        c.port = number
        c.fragment = string("name")
        var q: [String: String] = [:]
        let tls = ["true", "1"].contains(string("tls").lowercased())
        let sni = string("servername", string("sni"))
        if !sni.isEmpty { q["sni"] = sni }
        if !string("client-fingerprint").isEmpty { q["fp"] = string("client-fingerprint") }
        if let list = values["alpn"] as? [String] { q["alpn"] = list.joined(separator: ",") }
        else if values["alpn"] != nil { throw DeskProxyError.invalid("ALPN 必须是列表。") }
        switch type {
        case "ss":
            guard ["network", "tls", "ws-opts", "grpc-opts", "reality-opts", "obfs"].allSatisfy({ values[$0] == nil }), q.isEmpty else {
                throw DeskProxyError.invalid("暂不支持带插件或额外传输的 SS 节点。")
            }
            c.scheme = "ss"
            c.user = Data((string("cipher") + ":" + string("password")).utf8).base64EncodedString()
        case "hysteria2", "hy2":
            guard ["network", "ws-opts", "grpc-opts", "reality-opts", "flow"].allSatisfy({ values[$0] == nil }), q["fp"] == nil, q["alpn"] == nil else {
                throw DeskProxyError.invalid("Hysteria2 含有不支持的传输参数。")
            }
            c.scheme = "hysteria2"; c.user = string("password")
            if !string("obfs").isEmpty { q["obfs"] = string("obfs") }
            if values["obfs-password"] != nil { q["obfs-password"] = string("obfs-password") }
        case "socks5", "http":
            guard ["network", "ws-opts", "grpc-opts", "reality-opts", "flow", "obfs"].allSatisfy({ values[$0] == nil }), type == "http" || !tls else {
                throw DeskProxyError.invalid("暂不支持此代理传输方式。")
            }
            c.scheme = type == "http" && tls ? "https" : type
            if values["username"] != nil || values["password"] != nil { c.user = string("username"); c.password = string("password") }
        default:
            c.scheme = type
            c.user = type == "trojan" ? string("password") : string("uuid")
            let network = string("network", "tcp")
            q["type"] = network
            q["security"] = tls || type == "trojan" ? "tls" : "none"
            if let reality = values["reality-opts"] as? [String: Any] {
                guard Set(reality.keys).isSubset(of: ["public-key", "short-id"]), reality.values.allSatisfy({ $0 is String }), let key = reality["public-key"] as? String else { throw DeskProxyError.invalid("Reality 参数不完整或字段类型无效。") }
                q["security"] = "reality"; q["pbk"] = key; q["sid"] = reality["short-id"] as? String ?? ""
            } else if values["reality-opts"] != nil { throw DeskProxyError.invalid("Reality 参数格式不正确。") }
            for (field, transport) in [("ws-opts", "ws"), ("grpc-opts", "grpc"), ("http-upgrade-opts", "httpupgrade"), ("xhttp-opts", "xhttp")] {
                guard let raw = values[field] else { continue }
                guard transport == network, let opts = raw as? [String: Any] else { throw DeskProxyError.invalid("传输参数与 network 不一致。") }
                if transport == "grpc" {
                    guard Set(opts.keys).isSubset(of: ["grpc-service-name"]), let service = opts["grpc-service-name"] as? String else { throw DeskProxyError.invalid("gRPC 参数不受支持。") }
                    q["serviceName"] = service
                } else {
                    let fields: Set<String> = transport == "xhttp" ? ["path", "host", "mode"] : transport == "ws" ? ["path", "headers"] : ["path", "host", "headers"]
                    guard Set(opts.keys).isSubset(of: fields), opts.allSatisfy({ $0.key == "headers" || $0.value is String }) else { throw DeskProxyError.invalid("传输含有不支持的参数或字段类型。") }
                    if let path = opts["path"] as? String { q["path"] = path }
                    if let host = opts["host"] as? String { q["host"] = host }
                    if let mode = opts["mode"] as? String { q["mode"] = mode }
                    if let headers = opts["headers"] as? [String: String] {
                        guard headers.keys.allSatisfy({ $0.lowercased() == "host" }), headers.count <= 1 else { throw DeskProxyError.invalid("当前仅支持传输中的 Host 请求头。") }
                        if let headerHost = headers.values.first {
                            guard q["host"] == nil || q["host"] == headerHost else { throw DeskProxyError.invalid("传输 host 与 Host 请求头不一致。") }
                            q["host"] = headerHost
                        }
                    } else if opts["headers"] != nil { throw DeskProxyError.invalid("传输请求头格式不正确。") }
                }
            }
            for (source, target) in [("flow", "flow"), ("encryption", "encryption"), ("packet-encoding", "packetEncoding")] where values[source] != nil { q[target] = string(source) }
            if type == "vmess" {
                guard q["mode"] == nil || q["mode"] == "auto" else { throw DeskProxyError.invalid("VMess 分享格式暂不支持指定 XHTTP mode，请使用默认模式。") }
                guard ["", "0"].contains(string("alterId")), values["flow"] == nil, values["reality-opts"] == nil, values["packet-encoding"] == nil, values["encryption"] == nil else { throw DeskProxyError.invalid("VMess 节点参数不受支持。") }
                let vm: [String: Any] = ["v": "2", "ps": string("name"), "add": host, "port": number, "id": string("uuid"), "aid": 0,
                    "scy": string("cipher", "auto"), "net": network, "type": "none", "tls": q["security"] ?? "none", "sni": sni,
                    "host": q["host"] ?? "", "path": network == "grpc" ? q["serviceName"] ?? "" : q["path"] ?? "/", "fp": q["fp"] ?? "", "alpn": q["alpn"] ?? ""]
                return try DeskProxyNode.parse("vmess://" + JSONSerialization.data(withJSONObject: vm, options: .sortedKeys).base64EncodedString())
            }
        }
        c.queryItems = q.isEmpty ? nil : q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let link = c.string else { throw DeskProxyError.invalid("节点链接无法生成。") }
        return try DeskProxyNode.parse(link)
    }
}
