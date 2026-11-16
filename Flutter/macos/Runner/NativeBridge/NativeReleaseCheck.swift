import Foundation

@MainActor
protocol NativeUpdateInstalling: AnyObject {
    func installAvailableUpdate() async throws
}

enum NativeReleaseCheck {
    private static let api = URL(string: "https://api.github.com/repos/cshaizhihao/SeekDesk/releases/latest")!
    private static let repository = URL(string: "https://github.com/cshaizhihao/SeekDesk")!
    private static let session: DeskProxySession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        return DeskProxyNetwork.shared.makeSession(configuration: configuration)
    }()

    static func check(installed: String) async throws -> [String: String] {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SeekDesk", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request, maximumBytes: 512 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.url == api else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429,
               http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
               http.value(forHTTPHeaderField: "Retry-After") != nil {
                return ["status": "rateLimited"]
            }
            throw URLError(.badServerResponse)
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return try result(for: Data(contentsOf: file), installed: installed, build: build)
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    static func result(for data: Data, installed: String, build: String) throws -> [String: String] {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let published = Version(release.tag_name), !published.prerelease else {
            throw URLError(.cannotParseResponse)
        }
        let releases = repository.appendingPathComponent("releases")
        let releaseURL = releases.appendingPathComponent("tag").appendingPathComponent(release.tag_name)
        var result = ["version": published.text, "releaseURL": releaseURL.absoluteString]
        if let local = Version(installed), Int(build) != nil {
            if local < published {
                let hasFeed = release.assets.contains { $0.name == "appcast.xml" && $0.state == "uploaded" }
                result["status"] = hasFeed ? "available" : "awaitingPackage"
            }
            else if published < local { result["status"] = "ahead" }
            else { result["status"] = "current" }
        } else {
            result["status"] = "unknownInstalled"
        }
        return result
    }

    private struct Version: Comparable {
        let text: String
        let numbers: [Int]
        let prerelease: Bool

        init?(_ input: String) {
            let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.range(of: #"^[vV]?[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(?:-[0-9A-Za-z.\-]+)?(?:\+[0-9A-Za-z.\-]+)?$"#,
                            options: .regularExpression) != nil else { return nil }
            let version = raw.lowercased().hasPrefix("v") ? raw.dropFirst() : raw[...]
            let withoutMetadata = version.prefix { $0 != "+" }
            text = String(withoutMetadata.prefix { $0 != "-" })
            prerelease = withoutMetadata.contains("-")
            numbers = text.split(separator: ".").compactMap { Int($0) }
        }

        static func == (lhs: Version, rhs: Version) -> Bool {
            lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
            return lhs.prerelease && !rhs.prerelease
        }
    }
}
