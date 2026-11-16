import Foundation
import Network
import WebKit

struct DeskProxyEndpoint: Equatable, Sendable {
    let port: UInt16
    let username: String
    let password: String

    var configuration: ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.allowFailover = false
        proxy.applyCredential(username: username, password: password)
        return proxy
    }

    /// Port 9 has no proxy service. Failover is disabled, so startup failures cannot become direct requests.
    static func blocked() -> Self {
        Self(port: 9, username: UUID().uuidString, password: UUID().uuidString)
    }
}

/// The lock serializes route changes with URLSession creation. No process-wide or system proxy is changed.
final class DeskProxyNetwork: @unchecked Sendable {
    static let shared = DeskProxyNetwork()
    private let lock = NSRecursiveLock()
    private var endpoint: DeskProxyEndpoint?
    private var generation = 0
    private let sessions = NSHashTable<DeskProxySession>.weakObjects()

    var requiresProxy: Bool { lock.withLock { endpoint != nil } }
    var revision: Int { lock.withLock { generation } }
    var configurations: [ProxyConfiguration] { lock.withLock { endpoint.map { [$0.configuration] } ?? [] } }

    func setEndpoint(_ value: DeskProxyEndpoint?) {
        lock.withLock {
            guard endpoint != value else { return }
            endpoint = value
            generation += 1
            // Existing connections must not outlive a node change or the enable/disable switch.
            for session in sessions.allObjects { session.reset() }
        }
    }

    func makeSession(configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil,
                     delegateQueue: OperationQueue? = nil) -> DeskProxySession {
        lock.withLock {
            let session = DeskProxySession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue, network: self)
            sessions.add(session)
            return session
        }
    }

    fileprivate func withRoute<T>(_ action: (Int, [ProxyConfiguration]) throws -> T) rethrows -> T {
        try lock.withLock { try action(generation, endpoint.map { [$0.configuration] } ?? []) }
    }
}

/// Preserves each caller's cookie, redirect, timeout and cache policies while refreshing proxy settings.
final class DeskProxySession: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let delegate: URLSessionDelegate?
    private let delegateQueue: OperationQueue?
    private let network: DeskProxyNetwork
    private let lock = NSLock()
    private var current: URLSession?
    private var currentRevision = -1
    private var closed = false

    fileprivate init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?,
                     delegateQueue: OperationQueue?, network: DeskProxyNetwork) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.delegate = delegate
        self.delegateQueue = delegateQueue
        self.network = network
    }

    deinit { current?.invalidateAndCancel() }

    private func session() throws -> (URLSession, Int) {
        try network.withRoute { revision, proxies in
            try lock.withLock {
                guard !closed else { throw URLError(.cancelled) }
                if current == nil || currentRevision != revision {
                    current?.invalidateAndCancel()
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.proxyConfigurations = proxies
                    current = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
                    currentRevision = revision
                }
                return (current!, revision)
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (session, revision) = try session()
        let result = try await session.data(for: request)
        guard revision == network.revision else { throw URLError(.cancelled) }
        return result
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let (session, revision) = try session()
        let result = try await session.bytes(for: request)
        guard revision == network.revision else { throw URLError(.cancelled) }
        return result
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (session, revision) = try session()
        let result = try await session.download(for: request)
        guard revision == network.revision else {
            try? FileManager.default.removeItem(at: result.0)
            throw URLError(.cancelled)
        }
        return result
    }

    /// Media limits must apply while receiving bytes, not only after an
    /// untrusted server has filled URLSession's temporary download file.
    /// The scheme override is used by loopback integration checks only.
    func download(for request: URLRequest, maximumBytes: Int,
                  allowedSchemes: Set<String> = ["https"]) async throws -> (URL, URLResponse) {
        precondition(maximumBytes > 0)
        try Task.checkCancellation()
        let policy = BoundedDownloadDelegate(maximumBytes: maximumBytes, allowedSchemes: allowedSchemes)
        guard policy.accepts(request.url) else { throw URLError(.badURL) }
        let (session, revision) = try session()
        do {
            let result = try await policy.download(request, session: session)
            var accepted = false
            defer { if !accepted { try? FileManager.default.removeItem(at: result.0) } }
            try Task.checkCancellation()
            guard revision == network.revision else { throw URLError(.cancelled) }
            if let failure = policy.failure { throw URLError(failure) }
            guard policy.accepts(result.1.url) else { throw URLError(.badURL) }
            // Retain a final check as well: callbacks may be coalesced, and
            // Content-Length is only a hint supplied by the remote server.
            let size = try result.0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            accepted = true
            return result
        } catch {
            try Task.checkCancellation()
            guard revision == network.revision else { throw URLError(.cancelled) }
            if let failure = policy.failure { throw URLError(failure) }
            throw error
        }
    }

    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        let (session, revision) = try session()
        let result = try await session.upload(for: request, from: data)
        guard revision == network.revision else { throw URLError(.cancelled) }
        return result
    }

    fileprivate func reset() {
        lock.withLock { current?.invalidateAndCancel(); current = nil; currentRevision = -1 }
    }

    func finishTasksAndInvalidate() {
        lock.withLock { closed = true; current?.finishTasksAndInvalidate(); current = nil }
    }

    func invalidateAndCancel() {
        lock.withLock { closed = true; current?.invalidateAndCancel(); current = nil }
    }
}

/// One delegate per download keeps concurrent image policies and errors
/// independent. It cannot change the session's proxy, cookie or TLS policy.
private final class BoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let allowedSchemes: Set<String>
    private let lock = NSLock()
    private var rejected: URLError.Code?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var received: (URL, URLResponse)?
    private var cancelled = false

    init(maximumBytes: Int, allowedSchemes: Set<String>) {
        self.maximumBytes = Int64(maximumBytes)
        self.allowedSchemes = allowedSchemes
    }

    var failure: URLError.Code? { lock.withLock { rejected } }

    func download(_ request: URLRequest, session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let pending: URLSessionDownloadTask? = lock.withLock {
                    guard !cancelled else { return nil }
                    self.continuation = continuation
                    // The async convenience download API suppresses progress
                    // callbacks. A delegate-owned task enforces the cap before
                    // completing the file, without per-byte async overhead.
                    let task = session.downloadTask(with: request)
                    task.delegate = self
                    self.task = task
                    return task
                }
                if let pending { pending.resume() }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func accepts(_ url: URL?) -> Bool {
        guard let url, allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || (1...65535).contains(url.port!) else { return false }
        return true
    }

    private func reject(_ code: URLError.Code) {
        lock.withLock { if rejected == nil { rejected = code } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard accepts(request.url),
              !(response.url?.scheme?.lowercased() == "https" && request.url?.scheme?.lowercased() != "https") else {
            reject(.badURL)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            reject(.dataLengthExceedsMaximum)
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard failure == nil else { return }
        guard let response = downloadTask.response, accepts(response.url) else { reject(.badURL); return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { reject(.dataLengthExceedsMaximum); return }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("SeekDeskMedia-" + UUID().uuidString)
            // URLSession removes its temporary file when this delegate
            // returns. Move it now; exactly one successful caller owns it.
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { received = (destination, response) }
        } catch {
            reject(.cannotWriteToFile)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let completed = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?,
                                               (URL, URLResponse)?, Error?) in
            let failure: Error? = cancelled ? CancellationError() : rejected.map { URLError($0) } ?? error
            let result = (continuation, received, failure)
            continuation = nil
            received = nil
            self.task = nil
            return result
        }
        if completed.2 == nil, let value = completed.1, let continuation = completed.0 {
            continuation.resume(returning: value)
        } else {
            if let file = completed.1?.0 { try? FileManager.default.removeItem(at: file) }
            completed.0?.resume(throwing: completed.2 ?? URLError(.cannotDecodeContentData))
        }
    }
}

@MainActor
enum DeskProxyWebKit {
    private static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    private static let views = NSHashTable<WKWebView>.weakObjects()

    static func configure(_ store: WKWebsiteDataStore) {
        // Reassigning a shared store's proxy configuration can interrupt other tabs.
        // Existing stores are updated only by routeChanged(), once per route change.
        guard !stores.contains(store) else { return }
        stores.add(store)
        store.proxyConfigurations = DeskProxyNetwork.shared.configurations
    }

    static func register(_ view: WKWebView) {
        views.add(view)
        configure(view.configuration.websiteDataStore)
    }

    static func routeChanged() {
        for view in views.allObjects { view.stopLoading() }
        let proxies = DeskProxyNetwork.shared.configurations
        for store in stores.allObjects { store.proxyConfigurations = proxies }
    }
}
