import AppKit
import Darwin
import Foundation

enum DeskProxyNodeProbe {
    enum Failure: LocalizedError, Equatable {
        case missingCore, startup, unavailable, response, timeout
        var errorDescription: String? {
            switch self {
            case .missingCore: "缺少代理内核，无法检测节点。"
            case .startup: "检测连接未能启动。"
            case .unavailable: "节点暂时无法访问检测站点。"
            case .response: "检测站点未返回预期响应。"
            case .timeout: "节点检测超时。"
            }
        }
    }

    /// A fresh authenticated local proxy exercises the complete node protocol, including UDP transports.
    /// It never replaces the active app route or consults the shared proxy controller.
    static func measure(node: DeskProxyNode, coreURL: URL) async throws -> Int {
        try await measure(node: node, coreURL: coreURL, targetURL: URL(string: "https://www.gstatic.com/generate_204")!)
    }

    /// The target override is used only by local integration tests.
    static func measure(node: DeskProxyNode, coreURL: URL, targetURL: URL) async throws -> Int {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: coreURL.path) else { throw Failure.missingCore }
        guard ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""), targetURL.user == nil, targetURL.password == nil else {
            throw Failure.response
        }
        let resources = ProbeResources()
        do {
            let elapsed = try await withTaskCancellationHandler {
                let endpoint = DeskProxyEndpoint(port: try unusedPort(), username: UUID().uuidString, password: UUID().uuidString)
                let config = try node.configuration(port: endpoint.port, username: endpoint.username, password: endpoint.password)
                let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
                try resources.start(coreURL: coreURL, configuration: config)
                while !acceptsConnections(endpoint.port) {
                    try Task.checkCancellation()
                    guard resources.isRunning, DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.startup }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                guard resources.isRunning, DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.startup }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 8
                configuration.timeoutIntervalForResource = 10
                configuration.proxyConfigurations = [endpoint.configuration]
                let session = URLSession(configuration: configuration, delegate: ProbeRedirectDelegate(), delegateQueue: nil)
                try resources.setSession(session)
                var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.httpMethod = "GET"
                let began = DispatchTime.now().uptimeNanoseconds
                // The 204 endpoint has no body. Reject other responses immediately without buffering remote data.
                let (_, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 204,
                      http.url == targetURL, resources.isRunning else { throw Failure.response }
                return max(1, Int((DispatchTime.now().uptimeNanoseconds - began + 999_999) / 1_000_000))
            } onCancel: {
                resources.cancel(force: true)
            }
            await resources.finish()
            try Task.checkCancellation()
            return elapsed
        } catch {
            await resources.finish()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            if (error as? URLError)?.code == .timedOut { throw Failure.timeout }
            throw Failure.unavailable
        }
    }

    private static func address(_ port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        value.sin_port = port.bigEndian
        return value
    }

    private static func unusedPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Failure.startup }
        defer { Darwin.close(socket) }
        var value = address(0)
        let status = withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard status == 0 else { throw Failure.startup }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        guard result == 0 else { throw Failure.startup }
        return UInt16(bigEndian: value.sin_port)
    }

    private static func acceptsConnections(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        guard fcntl(socket, F_SETFL, O_NONBLOCK) >= 0 else { return false }
        var value = address(port)
        let connected = withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        // Give this same nonblocking socket time to complete its loopback handshake.
        guard Darwin.poll(&descriptor, 1, 10) > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    private final class ProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class ProbeResources: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var session: URLSession?
        private var cancelled = false
        private var terminationObserver: NSObjectProtocol?
        var isRunning: Bool { lock.withLock { process?.isRunning == true && !cancelled } }

        init() {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.cancel(force: true)
            }
        }

        func start(coreURL: URL, configuration: Data) throws {
            // Do not let cancellation slip between process creation and registering ownership.
            let pipe = Pipe()
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                let child = Process()
                child.executableURL = coreURL
                child.arguments = ["run", "-format", "json", "-c", "stdin:"]
                child.standardInput = pipe
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
                try child.run()
                process = child
            }
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            try pipe.fileHandleForWriting.write(contentsOf: configuration)
        }

        func setSession(_ value: URLSession) throws {
            let accepted = lock.withLock {
                guard !cancelled else { return false }
                session = value
                return true
            }
            if !accepted { value.invalidateAndCancel(); throw CancellationError() }
        }

        func cancel(force: Bool = false) {
            let owned = lock.withLock { () -> (Process?, URLSession?) in
                cancelled = true
                return (process, session)
            }
            owned.1?.invalidateAndCancel()
            if let child = owned.0, child.isRunning {
                if force { Darwin.kill(child.processIdentifier, SIGKILL) }
                else { child.terminate() }
            }
        }

        func finish() async {
            cancel()
            let child = lock.withLock { process }
            // Cleanup remains awaited even when the caller has been cancelled.
            await Task.detached(priority: .utility) {
                guard let child else { return }
                for _ in 0..<30 {
                    if !child.isRunning { return }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }.value
            lock.withLock { process = nil; session = nil }
        }

        deinit {
            cancel(force: true)
            if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        }
    }
}
