import AppKit
import ImageIO
import SwiftUI

struct ForumImageView: View {
    let url: URL
    let label: String
    let sticker: Bool
    var report = false
    var reportKind: ForumReportKind = .tq
    var thumbnail = false
    var previewSize: MarkdownImageScale? = nil
    var sourceSize: ForumImageDimensions? = nil
    @StateObject private var state = ImageState()
    @Environment(\.deskImageViewer) private var viewer

    private var bitmap: CGImage? { state.loadedURL == url ? state.bitmap : ForumImageRequest.cached(url) }
    private var knownSize: CGSize? {
        if let bitmap { return CGSize(width: bitmap.width, height: bitmap.height) }
        return ForumImageRequest.postSize(url) ?? sourceSize?.validatedSize.map(ForumImageRequest.projectedPostSize)
    }

    var body: some View {
        Group {
            if let knownSize {
                sizedPicture(bitmap, size: knownSize)
            } else if thumbnail {
                DeskIcon(state.failed ? "photo" : "face.smiling", size: 12).font(.caption).foregroundStyle(.tertiary)
            } else if state.failed {
                Link(destination: url) { DeskLabel("图片加载失败 · 打开图片", systemImage: "photo") }.font(.callout)
            } else {
                DeskLabel("正在加载图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
            }
        }
        .task(id: url) { await state.load(url) }
        .onChange(of: state.showingPreview) { _, visible in
            if !visible { state.previewBitmap = nil; ForumImageRequest.releaseOriginal(url) }
        }
        .sheet(isPresented: $state.showingPreview) {
            if let bitmap {
                let preview = state.previewBitmap ?? bitmap
                let original = ForumImageRequest.originalSize(url) ?? CGSize(width: bitmap.width, height: bitmap.height)
                VStack(spacing: 0) {
                    HStack {
                        Text(label).font(.headline).lineLimit(1)
                        Spacer()
                        Button { state.zoom = max(0.75, state.zoom - 0.25) } label: { DeskIcon("minus.magnifyingglass") }
                            .accessibilityLabel("缩小图片").disabled(state.zoom <= 0.75)
                        Text("\(Int(state.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 39)
                        Button { state.zoom = min(3, state.zoom + 0.25) } label: { DeskIcon("plus.magnifyingglass") }
                            .accessibilityLabel("放大图片").disabled(state.zoom >= 3)
                        Toggle("原尺寸", isOn: $state.fullSize).toggleStyle(.switch).controlSize(.small)
                        Button("关闭") { state.showingPreview = false }.keyboardShortcut(.cancelAction)
                    }
                    .buttonStyle(DeskButtonStyle())
                    .padding(13)
                    .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: Color(nsColor: .windowBackgroundColor))
                    .padding(10)
                    if state.loadingOriginal {
                        ProgressView("正在读取高清图片…").controlSize(.small).padding(8)
                    } else if state.previewFailed || CGFloat(preview.width) + 1 < original.width || CGFloat(preview.height) + 1 < original.height {
                        HStack {
                            Text(state.previewFailed ? "高清图片读取失败" : "超大图片已按内存限制优化显示")
                            Link("打开原图", destination: url)
                        }.font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    Divider()
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            image(preview)
                                .frame(width: (state.fullSize ? original.width : max(1, geometry.size.width - 24)) * state.zoom)
                                .padding(12)
                        }
                    }
                }
                .frame(minWidth: 520, idealWidth: 900, minHeight: 380, idealHeight: 650)
                .task(id: url) { await state.loadOriginal(url) }
            }
        }
    }

    private func image(_ bitmap: CGImage) -> some View {
        Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
    }

    // Loading and loaded images share every width/report constraint. Only the
    // pixels change when a cached image has to be downloaded again.
    @ViewBuilder private func sizedPicture(_ bitmap: CGImage?, size: CGSize) -> some View {
        if sticker {
            picture(bitmap, size: size)
                .frame(maxWidth: thumbnail ? 68 : 60, maxHeight: thumbnail ? 68 : 54)
                .accessibilityLabel(label)
        } else if report {
            ForumReportPanel(naturalSize: size, minimumWidth: 390, kind: reportKind) {
                HStack(spacing: 8) {
                    Text("测评报告").font(.caption.weight(.semibold))
                    Spacer()
                    ForumReportScaleControls(kind: reportKind)
                    Button { if let bitmap { openPreview(bitmap) } } label: {
                        DeskLabel("查看大图", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.caption).buttonStyle(.borderless).disabled(bitmap == nil)
                }
                .padding(.horizontal, 10).frame(height: 35)
                .deskGlass(in: UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7),
                           solid: Color(nsColor: .windowBackgroundColor))
            } content: { _ in
                pictureButton(bitmap, size: size)
            }
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.15)).allowsHitTesting(false) }
        } else if let previewSize {
            PreviewImageWidth(maxWidth: CGFloat(previewSize.width(for: Int(size.width)))) {
                pictureButton(bitmap, size: size)
            }
        } else {
            pictureButton(bitmap, size: size)
                .frame(maxWidth: min(CGFloat(MarkdownImageScale.maximumWidth), size.width), alignment: .leading)
        }
    }

    @ViewBuilder private func picture(_ bitmap: CGImage?, size: CGSize) -> some View {
        if let bitmap {
            image(bitmap)
        } else {
            Rectangle().fill(.secondary.opacity(0.04))
                .aspectRatio(size, contentMode: .fit)
                .overlay {
                    if thumbnail || sticker {
                        DeskIcon("photo", size: 12).foregroundStyle(.tertiary)
                    } else if state.failed {
                        Link(destination: url) { DeskLabel("图片加载失败 · 打开图片", systemImage: "photo") }
                            .font(.callout)
                    } else {
                        DeskLabel("正在加载图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    }
                }
        }
    }

    @ViewBuilder private func pictureButton(_ bitmap: CGImage?, size: CGSize) -> some View {
        if let bitmap {
            Button { openPreview(bitmap) } label: {
                picture(bitmap, size: size).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label).help("点开看大图")
            .background(DeskImageSourceAnchor { state.sourceView = $0 })
        } else {
            picture(nil, size: size).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func openPreview(_ bitmap: CGImage) {
        if let viewer { viewer.open(url, label: label, bitmap: bitmap, source: state.sourceView?.sourceRect ?? .zero) }
        else { state.zoom = 1; state.fullSize = false; state.showingPreview = true }
    }

    @MainActor private final class ImageState: ObservableObject {
        @Published var bitmap: CGImage?
        @Published var previewBitmap: CGImage?
        @Published var loadingOriginal = false
        @Published var previewFailed = false
        private(set) var loadedURL: URL?
        @Published var failed = false
        @Published var showingPreview = false
        @Published var fullSize = false
        @Published var zoom = 1.0
        weak var sourceView: DeskImageSourceAnchor.Anchor?

        func load(_ url: URL) async {
            if loadedURL == url, bitmap != nil { return }
            loadedURL = url
            previewBitmap = nil
            bitmap = ForumImageRequest.cached(url)
            failed = false
            guard bitmap == nil else { return }
            do {
                let result = try await ForumImageRequest.fetch(url)
                try Task.checkCancellation()
                guard loadedURL == url else { return }
                bitmap = result
            } catch {
                if !Task.isCancelled, loadedURL == url { failed = true }
            }
        }

        func loadOriginal(_ url: URL) async {
            loadingOriginal = true
            previewFailed = false
            defer { if loadedURL == url { loadingOriginal = false } }
            do {
                let result = try await ForumImageRequest.fetch(url, kind: .original)
                try Task.checkCancellation()
                guard loadedURL == url else { return }
                previewBitmap = result
            } catch {
                if !Task.isCancelled, loadedURL == url { previewFailed = true }
            }
        }
    }
}

private struct PreviewImageWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(maxWidth, proposal.width ?? maxWidth)
        return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

enum ForumImageRequest {
    enum Kind: Hashable, Sendable { case post, avatar, original }
    private struct Key: Hashable, Sendable { let url: URL; let kind: Kind }
    private static let requests = ImageRequestCoordinator<Key, Bitmap>()
    final class Bitmap: Sendable {
        let image: CGImage
        let originalSize: CGSize?
        let animation: ForumImageAnimation?

        init(image: CGImage, originalSize: CGSize? = nil, animation: ForumImageAnimation? = nil) {
            self.image = image
            self.originalSize = originalSize
            self.animation = animation
        }
    }
    private static let decoding = ImageRequestCoordinator<Key, Bitmap>(maximumConcurrent: 2)
    private final class TemporaryImageFile: Sendable {
        let url: URL
        init(_ url: URL) { self.url = url }
        deinit { try? FileManager.default.removeItem(at: url) }
    }
    private static let dimensions: NSCache<NSURL, NSValue> = {
        let cache = NSCache<NSURL, NSValue>()
        cache.countLimit = 512
        return cache
    }()
    private static let postDimensions: NSCache<NSURL, NSValue> = {
        let cache = NSCache<NSURL, NSValue>()
        cache.countLimit = 512
        return cache
    }()
    private static let originalCache = cache(megabytes: 96, count: 2)
    static func originalSize(_ url: URL) -> CGSize? { dimensions.object(forKey: url as NSURL)?.sizeValue }
    static func postSize(_ url: URL) -> CGSize? {
        if let size = postDimensions.object(forKey: url as NSURL)?.sizeValue { return size }
        guard let original = originalSize(url) else { return nil }
        return projectedPostSize(original)
    }

    static func projectedPostSize(_ original: CGSize) -> CGSize {
        // If only the original metadata survived, reproduce the decoder's size
        // limit instead of treating the full-resolution width as the post width.
        // First-load DOM metadata uses this same projection.
        let edge = thumbnailEdge(original, kind: .post)
        let factor = min(1, CGFloat(edge) / max(original.width, original.height))
        return CGSize(width: max(1, (original.width * factor).rounded()),
                      height: max(1, (original.height * factor).rounded()))
    }
    static func releaseOriginal(_ url: URL) { originalCache.removeObject(forKey: url as NSURL) }
    private static func memory(for kind: Kind) -> NSCache<NSURL, Bitmap> {
        switch kind { case .post: postCache; case .avatar: avatarCache; case .original: originalCache }
    }

    private static let postCache = cache(megabytes: 28, count: 32)
    private static let avatarCache = cache(megabytes: 16, count: 256)

    private static func cache(megabytes: Int, count: Int) -> NSCache<NSURL, Bitmap> {
        let cache = NSCache<NSURL, Bitmap>()
        cache.totalCostLimit = megabytes * 1024 * 1024
        cache.countLimit = count
        return cache
    }
    private static let session: DeskProxySession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 20
        return DeskProxyNetwork.shared.makeSession(configuration: config)
    }()

    static func cached(_ url: URL, kind: Kind = .post) -> CGImage? {
        memory(for: kind).object(forKey: url as NSURL)?.image
    }

    static func fetch(_ url: URL, kind: Kind = .post) async throws -> CGImage {
        try await fetchBitmap(url, kind: kind).image
    }

    static func fetchBitmap(_ url: URL, kind: Kind) async throws -> Bitmap {
        try Task.checkCancellation()
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw URLError(.badURL) }
        if let bitmap = memory(for: kind).object(forKey: url as NSURL) { return bitmap }
        return try await requests.value(for: Key(url: url, kind: kind), large: kind == .original) {
            // A queued request can have become warm while waiting for a slot.
            if let bitmap = memory(for: kind).object(forKey: url as NSURL) { return bitmap }
            return try await download(url, kind: kind)
        }
    }

    private static func download(_ url: URL, kind: Kind) async throws -> Bitmap {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        // Match the origin referrer used for embedded images on the forum.
        request.setValue(Forum.home.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let byteLimit = (kind == .avatar ? 4 : 25) * 1024 * 1024
        let (file, response) = try await session.download(for: request, maximumBytes: byteLimit)
        let temporary = TemporaryImageFile(file)
        try Task.checkCancellation()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let sourceURL = http.url, sourceURL.scheme == "https",
              size > 0, size <= byteLimit
        else { throw URLError(.cannotDecodeContentData) }
        let svgAvatar = kind == .avatar && http.mimeType == "image/svg+xml" && size <= 256 * 1024 &&
            Forum.contains(url) && url.path.hasPrefix("/avatar/") && Forum.contains(sourceURL)
        let bitmap = try await decoding.value(for: Key(url: url, kind: kind), large: kind == .original) {
            try await decodeBitmap(temporary, kind: kind, svgAvatar: svgAvatar)
        }
        try Task.checkCancellation()
        if let originalSize = bitmap.originalSize {
            dimensions.setObject(NSValue(size: originalSize), forKey: url as NSURL)
            if kind == .post {
                postDimensions.setObject(NSValue(size: CGSize(width: bitmap.image.width, height: bitmap.image.height)), forKey: url as NSURL)
            }
        }
        let memory = memory(for: kind)
        let cost = bitmap.image.bytesPerRow * bitmap.image.height + (bitmap.animation?.bytes.count ?? 0)
        if cost <= memory.totalCostLimit { memory.setObject(bitmap, forKey: url as NSURL, cost: cost) }
        return bitmap
    }

    private static func decodeBitmap(_ temporary: TemporaryImageFile, kind: Kind, svgAvatar: Bool) async throws -> Bitmap {
        // A synchronous decoder can finish after its last subscriber cancelled.
        // Keep its file alive until that worker exits, including queued cancellation.
        defer { withExtendedLifetime(temporary) {} }
        let file = temporary.url
        try Task.checkCancellation()
        if svgAvatar {
            // NodeSeek generates default avatars as SVG, even at URLs ending in .png.
            let data = try Data(contentsOf: file)
            let image: CGImage? = try await MainActor.run {
                try Task.checkCancellation()
                guard let avatar = NSImage(data: data), avatar.size.width > 0, avatar.size.height > 0,
                      avatar.size.width <= 1024, avatar.size.height <= 1024 else { return nil }
                return avatar.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            guard let image else { throw URLError(.cannotDecodeContentData) }
            try Task.checkCancellation()
            return Bitmap(image: image, originalSize: nil)
        } else {
            let decoded = try decode(file, kind: kind)
            try Task.checkCancellation()
            return Bitmap(image: decoded.image, originalSize: decoded.originalSize, animation: decoded.animation)
        }
    }
    struct Decoded {
        let image: CGImage
        let originalSize: CGSize
        let animation: ForumImageAnimation?
    }

    static func decode(_ file: URL, kind: Kind = .post) throws -> Decoded {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = info[kCGImagePropertyPixelWidth as String] as? Double,
              let h = info[kCGImagePropertyPixelHeight as String] as? Double,
              w > 0, h > 0, w.isFinite, h.isFinite else { throw URLError(.cannotDecodeContentData) }
        let rotated = (5...8).contains(info[kCGImagePropertyOrientation as String] as? Int ?? 1)
        let width = rotated ? h : w, height = rotated ? w : h
        let edge = thumbnailEdge(CGSize(width: width, height: height), kind: kind)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let animation: ForumImageAnimation?
        if kind != .avatar,
           let mime = ForumImageAnimation.format(of: source, maxEdge: 1024),
           let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           bytes <= 4 * 1024 * 1024 {
            animation = ForumImageAnimation(bytes: try Data(contentsOf: file), mime: mime)
        } else {
            animation = nil
        }
        return Decoded(image: image, originalSize: CGSize(width: width, height: height), animation: animation)
    }

    private static func thumbnailEdge(_ size: CGSize, kind: Kind) -> Int {
        // Long reports retain a readable width instead of shrinking their width
        // whenever height grows. A pixel budget bounds decoded memory (~96 MB).
        let width = size.width, height = size.height
        let readingScale = kind == .avatar ? min(1, 256 / max(width, height)) :
            (kind == .original ? 1 : min(1, 2160 / width))
        let pixelBudget = kind == .avatar ? 256.0 * 256 : 24_000_000
        let factor = min(readingScale, sqrt(pixelBudget / width / height))
        return max(1, Int((max(width, height) * factor).rounded(.down)))
    }

}
