import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Uses the real production fetch/decoder with only the network transport replaced.
final class ImageRequestProbe: @unchecked Sendable {
    struct Snapshot {
        var downloads = 0
        var decodes = 0
        var mainThreadDecodes = 0
        var active = 0
        var peak = 0
        var activeOriginals = 0
        var peakOriginals = 0
        var cancellations = 0
        var paths: [String: Int] = [:]
        var referersValid = true
    }
    struct Download {
        let source: URL
        let fail: Bool
        let original: Bool
    }
    static let shared = ImageRequestProbe()
    private let lock = NSLock()
    private var state = Snapshot()
    private var source: URL?
    private var failures: [String: Int] = [:]

    func configure(_ source: URL) {
        lock.lock(); defer { lock.unlock() }
        precondition(state.active == 0)
        self.source = source
        state = Snapshot()
        failures = [:]
    }

    func failOnce(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        failures[path] = 1
    }

    func begin(_ request: URLRequest) -> Download {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        let original = path.contains("original")
        state.downloads += 1
        state.paths[path, default: 0] += 1
        state.active += 1
        if original { state.activeOriginals += 1 }
        state.peak = max(state.peak, state.active)
        state.peakOriginals = max(state.peakOriginals, state.activeOriginals)
        state.referersValid = state.referersValid && request.value(forHTTPHeaderField: "Referer") == Forum.home.absoluteString && request.value(forHTTPHeaderField: "Accept") == "image/*"
        let fail = failures[path, default: 0] > 0
        if fail { failures[path, default: 0] -= 1 }
        return Download(source: source!, fail: fail, original: original)
    }

    func finish(_ download: Download, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.active -= 1
        if download.original { state.activeOriginals -= 1 }
        if cancelled { state.cancellations += 1 }
    }

    func decoding() {
        lock.lock(); defer { lock.unlock() }
        state.decodes += 1
        if Thread.isMainThread { state.mainThreadDecodes += 1 }
    }

    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return state }
}

/// Holds actual production decoder entry points open, making overlap observable
/// instead of inferring a decode limit from instantaneous tiny PNG decoding.
final class DecodeRequestProbe: @unchecked Sendable {
    struct Snapshot { var entered = 0; var active = 0; var peak = 0; var held = false }
    static let shared = DecodeRequestProbe()
    private let condition = NSCondition()
    private var state = Snapshot()

    func hold() {
        condition.lock(); defer { condition.unlock() }
        precondition(state.active == 0)
        state = Snapshot(held: true)
    }

    func begin(_ file: URL) {
        condition.lock(); defer { condition.unlock() }
        precondition(FileManager.default.fileExists(atPath: file.path), "Decoder input file must exist at entry")
        state.entered += 1
        state.active += 1
        state.peak = max(state.peak, state.active)
        while state.held { condition.wait() }
        precondition(FileManager.default.fileExists(atPath: file.path), "Cancelled synchronous decoder must retain its input file until it exits")
    }

    func finish() { condition.lock(); state.active -= 1; condition.broadcast(); condition.unlock() }
    func release() { condition.lock(); state.held = false; condition.broadcast(); condition.unlock() }
    func snapshot() -> Snapshot { condition.lock(); defer { condition.unlock() }; return state }
}

enum Forum {
    static let home = URL(string: "https://fixture.invalid")!
    static func contains(_ url: URL) -> Bool { url.host == home.host }
}

struct DeskProxySession {
    func download(for request: URLRequest, maximumBytes: Int) async throws -> (URL, URLResponse) {
        precondition(maximumBytes == 4 * 1024 * 1024 || maximumBytes == 25 * 1024 * 1024,
                     "Production image requests must bound avatar and post transfer bytes")
        let download = ImageRequestProbe.shared.begin(request)
        var cancelled = false
        defer { ImageRequestProbe.shared.finish(download, cancelled: cancelled) }
        do {
            // Enough time for all concurrent subscribers to join the same request.
            try await Task.sleep(for: .milliseconds(120))
            try Task.checkCancellation()
            if download.fail { throw URLError(.timedOut) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try FileManager.default.copyItem(at: download.source, to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                         headerFields: ["Content-Type": "image/png"])!)
        } catch {
            cancelled = Task.isCancelled || error is CancellationError
            throw error
        }
    }
}

struct DeskProxyNetwork {
    static let shared = Self()
    func makeSession(configuration: URLSessionConfiguration) -> DeskProxySession {
        precondition(configuration.urlCache == nil && configuration.httpCookieStorage == nil)
        return .init()
    }
}

func imageFixture() -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    let pixels = Data(repeating: 150, count: 32 * 32)
    let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 32,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                        provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return file
}
