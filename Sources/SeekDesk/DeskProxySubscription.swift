import Foundation
import Yams
import CYaml

struct DeskProxySubscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    let url: String
    var updatedAt: Date?
}

struct DeskProxyImportResult {
    var nodes: [DeskProxyNode] = []
    var skipped: [String] = []
    var duplicates = 0
    var summary: String {
        "识别 \(nodes.count) 个节点" + (duplicates > 0 ? " · 重复 \(duplicates) 个" : "") + (skipped.isEmpty ? "" : " · 跳过 \(skipped.count) 个")
    }
}

/// Only the node list is imported. Subscription rules, remote providers and scripts are never executed.
enum DeskProxySubscriptionParser {
    static let byteLimit = 2 * 1024 * 1024
    static let nodeLimit = 1000

    static func parse(_ data: Data) throws -> DeskProxyImportResult {
        guard data.count <= byteLimit, var text = String(data: data, encoding: .utf8) else {
            throw DeskProxyError.invalid("订阅必须为 UTF-8 文本，且不超过 2 MB。")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        if !text.contains("://"), !text.contains("proxies:"), !text.hasPrefix("{") {
            let compact = text.filter { !$0.isWhitespace }
            if let decoded = DeskProxyNode.base64(compact), let value = String(data: decoded, encoding: .utf8) { text = value }
        }
        var result = DeskProxyImportResult()
        var seen = Set<Data>()
        func append(_ operation: () throws -> DeskProxyNode, index: Int) {
            do {
                let node = try operation()
                if seen.insert(node.identity).inserted { result.nodes.append(node) }
                else { result.duplicates += 1 }
            } catch {
                // Never include links, passwords, server-returned text, or parser excerpts in errors.
                let reason = (error as? DeskProxyError)?.localizedDescription ?? "节点格式不受支持。"
                result.skipped.append("第 \(index + 1) 项：" + reason)
            }
        }
        let firstLine = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) ?? ""
        if firstLine.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil {
            let entries = try yamlNodes(text)
            guard entries.count <= nodeLimit else { throw DeskProxyError.invalid("单个订阅最多导入 1000 个节点。") }
            for (index, entry) in entries.enumerated() { append({ try DeskClashNode.parse(entry) }, index: index) }
        } else {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard lines.count <= nodeLimit else { throw DeskProxyError.invalid("单次最多导入 1000 个节点。") }
            for (index, line) in lines.enumerated() { append({ try DeskProxyNode.parse(line) }, index: index) }
        }
        guard !result.nodes.isEmpty else {
            throw DeskProxyError.invalid("未找到可用节点。支持 Base64 / 明文节点列表及 Clash YAML / JSON 的 proxies 列表。" + (result.skipped.first.map { "\n" + $0 } ?? ""))
        }
        return result
    }

    private static func yamlNodes(_ text: String) throws -> [[String: Any]] {
        do {
            try validateYAML(text)
            guard let root = try Yams.compose(yaml: text), let list = root["proxies"]?.sequence else {
                throw DeskProxyError.invalid("订阅缺少 proxies 节点列表；不支持仅包含远程 proxy-providers 的配置。")
            }
            var budget = 60_000
            return try list.map { node in
                guard let object = try object(node, depth: 0, budget: &budget) as? [String: Any] else { return [:] }
                return object
            }
        } catch let error as DeskProxyError { throw error }
        catch { throw DeskProxyError.invalid("订阅 YAML / JSON 格式无效。请检查订阅是否返回了登录页面或错误页面。") }
    }

    private static func object(_ node: Yams.Node, depth: Int, budget: inout Int) throws -> Any {
        budget -= 1
        guard budget >= 0, depth <= 24 else { throw DeskProxyError.invalid("订阅嵌套过深或别名展开过多。") }
        switch node {
        case .scalar(let value): return node.tag == Yams.Tag(.null) ? NSNull() : value.string as Any
        case .sequence(let values): return try values.map { try object($0, depth: depth + 1, budget: &budget) }
        case .mapping(let values):
            var result: [String: Any] = [:]
            var merged: [String: Any] = [:]
            for (key, value) in values {
                guard let name = key.scalar?.string, result[name] == nil else { throw DeskProxyError.invalid("订阅节点含有重复或无效字段。") }
                let parsed = try object(value, depth: depth + 1, budget: &budget)
                if name == "<<" {
                    for map in (parsed as? [[String: Any]]) ?? [(parsed as? [String: Any]) ?? [:]] {
                        merged.merge(map) { old, _ in old }
                    }
                } else { result[name] = parsed }
            }
            return merged.merging(result) { _, new in new }
        case .alias: throw DeskProxyError.invalid("订阅包含无法解析的 YAML 别名。")
        }
    }

    /// Validate depth/events before invoking the recursive YAML composer, including unused config sections.
    private static func validateYAML(_ text: String) throws {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else { throw DeskProxyError.invalid("无法解析订阅。") }
        defer { yaml_parser_delete(&parser) }
        try Array(text.utf8).withUnsafeBufferPointer { buffer in
            yaml_parser_set_input_string(&parser, buffer.baseAddress, buffer.count)
            var depth = 0, count = 0, aliases = 0
            while true {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else { throw DeskProxyError.invalid("订阅 YAML / JSON 格式无效。") }
                let type = event.type
                yaml_event_delete(&event)
                count += 1
                if type == YAML_MAPPING_START_EVENT || type == YAML_SEQUENCE_START_EVENT { depth += 1 }
                if type == YAML_MAPPING_END_EVENT || type == YAML_SEQUENCE_END_EVENT { depth -= 1 }
                if type == YAML_ALIAS_EVENT { aliases += 1 }
                guard depth <= 32, count <= 100_000, aliases <= 2000 else { throw DeskProxyError.invalid("订阅过于复杂，请使用节点列表格式。") }
                if type == YAML_STREAM_END_EVENT { return }
            }
        }
    }
}

enum DeskProxySubscriptionFetch {
    static func validatedURL(_ text: String) throws -> URL {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16_384, !raw.contains(where: { $0.isWhitespace }),
              let c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.port == nil || (1...65535).contains(c.port!), let url = c.url else {
            throw DeskProxyError.invalid("请填写有效的 HTTP 或 HTTPS 订阅地址。")
        }
        return url
    }

    static func fetch(_ text: String) async throws -> DeskProxyImportResult {
        let url = try validatedURL(text)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = DeskProxyNetwork.shared.makeSession(configuration: config, delegate: SubscriptionRedirectDelegate())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("v2rayN/7.0 SeekDesk", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/yaml, application/json, */*", forHTTPHeaderField: "Accept")
        do {
            let revision = DeskProxyNetwork.shared.revision
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw DeskProxyError.invalid("订阅服务器未返回成功响应，请检查地址是否有效或已过期。")
            }
            guard response.expectedContentLength <= DeskProxySubscriptionParser.byteLimit else { throw DeskProxyError.invalid("订阅超过 2 MB 限制。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < DeskProxySubscriptionParser.byteLimit else { throw DeskProxyError.invalid("订阅超过 2 MB 限制。") }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard revision == DeskProxyNetwork.shared.revision else { throw CancellationError() }
            let result = try await Task.detached(priority: .userInitiated) { try DeskProxySubscriptionParser.parse(data) }.value
            try Task.checkCancellation()
            guard revision == DeskProxyNetwork.shared.revision else { throw CancellationError() }
            return result
        } catch let error as DeskProxyError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw DeskProxyError.invalid("无法获取订阅。请检查网络和订阅地址；代理开启时会通过当前节点获取，必要时先关闭代理再导入。") }
    }
}

private final class SubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? DeskProxySubscriptionFetch.validatedURL(url.absoluteString)) != nil,
              !(response.url?.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
}
