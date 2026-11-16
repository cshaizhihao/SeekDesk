import SwiftUI

struct MarkdownPreview: View {
    let text: String
    let palette: DeskPalette
    let imageSizing: DraftImageSizing
    let onResize: () -> Void
    @StateObject private var snapshot = PreviewSnapshot()

    var body: some View {
        ScrollView {
            Group {
                if snapshot.blocks.isEmpty {
                    Text("输入内容后可预览").foregroundStyle(.secondary)
                } else {
                    MarkdownPreviewBlocks(blocks: snapshot.blocks, palette: palette).equatable()
                }
            }
            .font(.system(size: 15)).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown 预览")
        .environmentObject(imageSizing)
        .environment(\.markdownImageResized, onResize)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .task(id: text) {
            let revision = snapshot.beginRequest()
            if !snapshot.blocks.isEmpty {
                do { try await Task.sleep(for: .milliseconds(105)) } catch { return }
            }
            guard !Task.isCancelled, snapshot.isCurrent(revision) else { return }
            do {
                let blocks = try await MarkdownPreviewParsing.blocks(for: text)
                guard !Task.isCancelled, snapshot.isCurrent(revision) else { return }
                if snapshot.blocks != blocks { snapshot.blocks = blocks }
            } catch {
                // Parsing only throws on cancellation; keep the last completed preview.
                return
            }
        }
    }

    private final class PreviewSnapshot: ObservableObject {
        @Published var blocks: [MarkdownPreviewDocument.Block] = []
        private var requestRevision = 0

        func beginRequest() -> Int {
            requestRevision += 1
            return requestRevision
        }

        func isCurrent(_ revision: Int) -> Bool { revision == requestRevision }
    }
}

struct MarkdownPreviewBlocks: View, Equatable {
    let blocks: [MarkdownPreviewDocument.Block]
    let palette: DeskPalette
    var showsImageControls = true

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .line(let source, let kind):
                    line(source, kind: kind)
                case .code(let source):
                    ScrollView(.horizontal) {
                        Text(source).font(.system(size: showsImageControls ? 13 : 12, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(palette.list, in: RoundedRectangle(cornerRadius: 6))
                case .table(let columns, let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            cells(columns, header: true)
                            ForEach(rows.indices, id: \.self) { cells(rows[$0], header: false) }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.line).allowsHitTesting(false) }
                case .terminal(let lines):
                    ForumTerminalView(lines: lines, palette: palette)
                case .tabs(let tabs):
                    ForumTabPanel(labels: tabs.map(\.label), palette: palette) { tab in
                        MarkdownPreviewBlocks(blocks: tabs[tab].blocks, palette: palette, showsImageControls: showsImageControls).equatable()
                    }
                case .divider: Divider().padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ source: String, kind: MarkdownPreviewDocument.LineKind) -> some View {
        let parts = MarkdownPreviewDocument.inline(source)
        let heading = if case .heading(let level) = kind { level } else { 0 }
        let quote = kind == .quote
        HStack(alignment: .top, spacing: 6) {
            if quote {
                RoundedRectangle(cornerRadius: 1).fill(palette.accent.opacity(0.42)).frame(width: 2)
                    .frame(minHeight: 16, maxHeight: 28)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let value):
                        Text(formatted(value))
                            .font(.system(size: heading == 0 ? (showsImageControls ? 15 : 13) : CGFloat(max(14, 22 - heading * 2)),
                                          weight: heading == 0 ? .regular : .semibold))
                            .foregroundStyle(quote ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .image(let url, let label, let sticker):
                        if showsImageControls && !sticker { MarkdownPreviewImage(url: url, label: label, palette: palette) }
                        else { ForumImageView(url: url, label: label, sticker: sticker) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cells(_ cells: [String], header: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, value in
                tableText(value, header: header)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(header ? palette.list : .clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                    .overlay(alignment: .trailing) { Rectangle().fill(palette.line).frame(width: 1) }
            }
        }
    }

    @ViewBuilder private func tableText(_ value: String, header: Bool) -> some View {
        if showsImageControls {
            Text(formatted(value)).font(.system(size: 14, weight: header ? .semibold : .regular))
        } else {
            Text(formatted(value)).fontWeight(header ? .semibold : .regular)
        }
    }

    private func formatted(_ value: String) -> AttributedString {
        if !showsImageControls { return ForumMarkdownLink.format(value) }
        return DeskMarkdownText.inline(value)
    }

}

enum ForumMarkdownLink {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private final class Value: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = 256
        cache.totalCostLimit = 1024 * 1024
        return cache
    }()

    static func format(_ source: String) -> AttributedString {
        let key = source as NSString
        if let saved = cache.object(forKey: key) { return saved.text }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: source, options: options, baseURL: Forum.home)) ?? AttributedString(source)
        let plain = String(text.characters)
        for match in detector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = match.url, canOpen(url), let range = Range(match.range, in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text),
                  text[start..<end].runs.allSatisfy({ $0.link == nil }) else { continue }
            text[start..<end].link = url
        }
        let unsafe = text.runs.compactMap { run in run.link.map { canOpen($0) ? nil : run.range } ?? nil }
        for range in unsafe { text[range].link = nil }
        // A repeated author signature should not rerun Markdown and link detection on every
        // floor update. Keep the sanitized result only, bounded and entirely in memory.
        if source.utf8.count <= 16_384 {
            cache.setObject(Value(text), forKey: key, cost: max(64, source.utf8.count * 8))
        }
        return text
    }

    static func removeAll() { cache.removeAllObjects() }

    static func canOpen(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
}

@MainActor
final class DraftImageSizing: ObservableObject {
    typealias Authorization = @MainActor () -> Bool

    struct Requests {
        var readKey: @MainActor () async throws -> String? = { try await NodeImageKey.readAsync() }
        var resize: @MainActor (URL, MarkdownImageScale) async throws -> NodeImageUpload.Picture = { url, size in
            try await NodeImageUpload.resizedPicture(from: url, scale: size)
        }
        var upload: @MainActor (NodeImageUpload.Picture, String) async throws -> URL = { picture, key in
            try await NodeImageUpload.upload(picture, key: key)
        }
    }

    @Published private(set) var sizes: [URL: MarkdownImageScale] = [:]
    private var uploaded: [URL: (size: MarkdownImageScale, link: URL)] = [:]
    private let requests: Requests
    private var mutation: UInt64 = 0
    private var preparationID: UUID?
    private var credentialRead: (id: UUID, task: Task<String?, Error>)?
    var didChange: (() -> Void)?

    init(requests: Requests = Requests()) { self.requests = requests }

    func set(_ ratio: Double, previewWidth: Double, for url: URL) {
        let selection = ratio < 1 ? MarkdownImageScale(ratio: ratio, previewWidth: previewWidth) : nil
        guard sizes[url] != selection else { return }
        mutation &+= 1
        cancelPendingCredentialRead()
        sizes[url] = selection
        didChange?()
    }

    func reset() {
        mutation &+= 1
        cancelPendingCredentialRead()
        sizes.removeAll()
        uploaded.removeAll()
        didChange?()
    }

    func restore(_ saved: [URL: MarkdownImageScale]) {
        mutation &+= 1
        cancelPendingCredentialRead()
        sizes = saved
        uploaded.removeAll()
    }

    /// Retiring a draft must also remove its queued credential work, before
    /// that work can enter the Keychain backend and present an obsolete prompt.
    func cancelPendingCredentialRead() {
        credentialRead?.task.cancel()
    }

    private func readKey() async throws -> String? {
        try Task.checkCancellation()
        let id = UUID(), read = requests.readKey
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await read()
        }
        credentialRead = (id, task)
        defer { if credentialRead?.id == id { credentialRead = nil } }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        // Injected providers, like synchronous Security IPC, may finish even
        // after cancellation. Their results still belong to the retired read.
        guard !task.isCancelled else { throw CancellationError() }
        try Task.checkCancellation()
        return try result.get()
    }

    func prepare(_ markdown: String, authorized: @escaping Authorization) async throws -> String {
        try Task.checkCancellation()
        guard authorized(), preparationID == nil else { throw CancellationError() }
        let operation = UUID(), revision = mutation
        preparationID = operation
        defer { if preparationID == operation { preparationID = nil } }

        func check() throws {
            try Task.checkCancellation()
            guard authorized(), mutation == revision, preparationID == operation else { throw CancellationError() }
        }

        let selections = sizes
        let references = MarkdownPreviewDocument.imageReferences(markdown, selected: Set(selections.keys))
        do {
            // Even an empty document or an entirely cached preparation belongs
            // to an authorized, live draft and must not bypass cancellation.
            try check()
            guard !references.isEmpty else { return markdown }
            var replacements: [URL: URL] = [:]
            for reference in references {
                try check()
                let url = reference.url
                guard replacements[url] == nil, let size = selections[url] else { continue }
                if let previous = uploaded[url], previous.size == size {
                    replacements[url] = previous.link
                    continue
                }
                let key = try await readKey()
                try check()
                guard let key, !key.isEmpty else { throw NodeImageError.missingKey }
                let picture = try await requests.resize(url, size)
                try check()
                let link = try await requests.upload(picture, key)
                try check()
                // A reset/restore or a different size selected while awaiting
                // must never repopulate the cache with this stale completion.
                uploaded[url] = (size, link)
                replacements[url] = link
            }
            let prepared = MarkdownPreviewDocument.replacingImages(markdown, references: references, with: replacements)
            try check()
            return prepared
        } catch {
            // Authorization/cancellation wins over a late transport error.
            // Completed, authorized images remain cached for a valid retry.
            try check()
            throw error
        }
    }
}

private struct MarkdownImageResizedKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
    var markdownImageResized: () -> Void {
        get { self[MarkdownImageResizedKey.self] }
        set { self[MarkdownImageResizedKey.self] = newValue }
    }
}

private struct MarkdownPreviewImage: View {
    let url: URL
    let label: String
    let palette: DeskPalette
    @EnvironmentObject private var sizing: DraftImageSizing
    @Environment(\.markdownImageResized) private var onResize
    @StateObject private var geometry = PreviewGeometry()

    private var ratio: Binding<Double> {
        Binding(get: { sizing.sizes[url]?.ratio ?? 1 }, set: {
            sizing.set($0, previewWidth: geometry.width, for: url)
            onResize()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DeskIcon("minus.magnifyingglass", size: 12).accessibilityHidden(true)
                Text("发布大小")
                Slider(value: ratio, in: 0.1...1, step: 0.01) { Text("\(label)发布大小") }
                    .labelsHidden().frame(minWidth: 55, maxWidth: 125).tint(palette.accent)
                    .accessibilityValue("\(percent)%")
                Text("\(percent)%").monospacedDigit().frame(width: 34, alignment: .trailing).accessibilityHidden(true)
            }
            .font(.caption).foregroundStyle(.secondary).controlSize(.small)
            .padding(.horizontal, 8).frame(height: 25)
            .deskGlass(in: RoundedRectangle(cornerRadius: 6), solid: palette.list)
            .help("小于 100% 时，发布或发送前会将缩小后的图片上传到 NodeImage。")
            ForumImageView(url: url, label: label, sticker: false, previewSize: sizing.sizes[url])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
            if width.isFinite, width > 0 { geometry.width = width }
        }
    }

    private var percent: Int { Int((ratio.wrappedValue * 100).rounded()) }

    private final class PreviewGeometry: ObservableObject {
        var width = Double(MarkdownImageScale.maximumWidth)
    }
}

struct MarkdownDraftStickers: View {
    let text: String
    let palette: DeskPalette
    @StateObject private var snapshot = Snapshot()

    var body: some View {
        VStack(spacing: 0) {
            if !snapshot.items.isEmpty {
                HStack(spacing: 8) {
                    Text("表情预览").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 5) {
                            ForEach(snapshot.items.indices, id: \.self) { index in
                                if case .image(let url, let label, _) = snapshot.items[index] {
                                    ForumImageView(url: url, label: label, sticker: true, thumbnail: true)
                                        .frame(width: 31, height: 28)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(palette.list)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
            }
        }
        .task(id: text) {
            do { try await Task.sleep(for: .milliseconds(105)) } catch { return }
            let items = MarkdownDraftStickerScan.items(in: text)
            if snapshot.items != items { snapshot.items = items }
        }
    }

    private final class Snapshot: ObservableObject {
        @Published var items: [MarkdownPreviewDocument.Inline] = []
    }
}

enum MarkdownDraftStickerScan {
    private static let token = try! NSRegularExpression(pattern: #":((?:ac|yct|xhj|emoji)[0-9]+):"#)

    static func items(in text: String) -> [MarkdownPreviewDocument.Inline] {
        // Keep every image opener as a candidate. The full parser determines
        // sticker labels and excludes ordinary images, code spans and escapes.
        var candidate = text.contains("![")
        if !candidate {
            let source = text as NSString
            token.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if let match, ForumStickers.byCode[source.substring(with: match.range(at: 1))] != nil {
                    candidate = true
                    stop.pointee = true
                }
            }
        }
        return candidate ? MarkdownPreviewDocument.stickerImages(text) : []
    }
}
