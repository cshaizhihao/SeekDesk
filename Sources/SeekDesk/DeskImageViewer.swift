import AppKit
import SwiftUI

/// Measure in window coordinates only when opening an image, rather than on every scroll.
struct DeskImageCoordinateSpace: NSViewRepresentable {
    func makeNSView(context: Context) -> Space { Space() }
    func updateNSView(_ view: Space, context: Context) {}

    final class Space: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct DeskImageSourceAnchor: NSViewRepresentable {
    let register: (Anchor) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { register(view) }

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var sourceRect: CGRect {
            guard let content = window?.contentView,
                  let space = Self.space(in: content) else { return .zero }
            return convert(bounds, to: space)
        }

        private static func space(in view: NSView) -> DeskImageCoordinateSpace.Space? {
            if let space = view as? DeskImageCoordinateSpace.Space { return space }
            for child in view.subviews { if let space = space(in: child) { return space } }
            return nil
        }
    }
}

@MainActor
final class DeskImageViewer: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let label: String
        let bitmap: CGImage
        let source: CGRect
    }
    @Published var item: Item?
    @Published private(set) var closeRequest = UUID()
    func requestDismiss() { closeRequest = UUID() }
    func open(_ url: URL, label: String, bitmap: CGImage, source: CGRect) {
        item = Item(url: url, label: label, bitmap: bitmap, source: source)
    }
}

private struct DeskImageViewerKey: EnvironmentKey { static let defaultValue: DeskImageViewer? = nil }
extension EnvironmentValues {
    var deskImageViewer: DeskImageViewer? {
        get { self[DeskImageViewerKey.self] }
        set { self[DeskImageViewerKey.self] = newValue }
    }
}

struct DeskImageOverlay: View {
    let item: DeskImageViewer.Item
    @ObservedObject var viewer: DeskImageViewer
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var state = ViewerState()
    @AccessibilityFocusState private var closeFocused: Bool

    private var bitmap: CGImage { state.original ?? item.bitmap }
    private var magnified: Bool { state.fullSize || state.zoom > 1 }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let source = item.source.intersects(bounds) && item.source.width > 1 && item.source.height > 1
                ? item.source : CGRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80)
            let target = DeskImageGeometry.fit(naturalSize, in: bounds.insetBy(dx: 24, dy: min(82, bounds.height / 4)))
            let smallTarget = DeskImageGeometry.scaled(target, by: min(1, state.zoom))
            let frame = state.expanded || reduceMotion || !state.returnToSource ? smallTarget : source
            ZStack(alignment: .top) {
                Color.black.opacity(reduceTransparency ? 1 : 0.91)
                    .opacity(state.expanded ? 1 : 0)
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                if magnified && !state.closing {
                    ScrollView([.horizontal, .vertical]) {
                        let width = (state.fullSize ? naturalSize.width : target.width) * state.zoom
                        picture.frame(width: width, height: width * naturalSize.height / max(1, naturalSize.width))
                            .padding(24)
                            .frame(minWidth: bounds.width, minHeight: max(1, bounds.height - 132))
                    }
                    .padding(.top, 64).padding(.bottom, 52)
                } else {
                    picture
                        .frame(width: max(1, frame.width), height: max(1, frame.height))
                        .clipShape(RoundedRectangle(cornerRadius: state.expanded ? 10 : 6))
                        .position(x: frame.midX, y: frame.midY)
                        .opacity((reduceMotion || !state.returnToSource) && !state.expanded ? 0 : 1)
                }
                toolbar.opacity(state.expanded ? 1 : 0).padding(16)
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if state.loading { ProgressView().controlSize(.small).tint(.white); Text("正在读取高清图片…") }
                        else if state.failed { Text("高清图片读取失败"); Link("打开原图", destination: item.url) }
                        else { Text("滚动查看 · 双击切换缩放 · Esc 关闭") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .deskGlass(in: Capsule(), solid: .black)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }.opacity(state.expanded ? 1 : 0).allowsHitTesting(state.failed)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                state.windowSize = geometry.size
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DeskMotion.image) { state.expanded = true }
                closeFocused = true
            }
            .onChange(of: geometry.size) { _, size in
                if state.windowSize != size { state.returnToSource = false; state.windowSize = size }
            }
        }
        .task(id: item.id) {
            defer { state.loading = false }
            do {
                let image = try await ForumImageRequest.fetch(item.url, kind: .original)
                guard !Task.isCancelled else { return }
                state.original = image
            } catch { if !Task.isCancelled { state.failed = true } }
        }
        .onExitCommand(perform: dismiss)
        .onChange(of: viewer.closeRequest) { dismiss() }
        .onDisappear {
            state.dismissTask?.cancel()
            state.original = nil
            ForumImageRequest.releaseOriginal(item.url)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片查看器")
    }

    private var naturalSize: CGSize {
        ForumImageRequest.originalSize(item.url) ?? CGSize(width: item.bitmap.width, height: item.bitmap.height)
    }

    private var picture: some View {
        Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
            .accessibilityLabel(item.label.isEmpty ? "帖子图片" : item.label)
            .onTapGesture(count: 2) {
                guard !state.closing else { return }
                state.zoom = state.zoom == 1 ? 2 : 1
                state.fullSize = false
            }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(item.label.isEmpty || item.label == "image" ? "图片预览" : item.label)
                .font(.headline).lineLimit(1).frame(maxWidth: 240, alignment: .leading)
            Spacer(minLength: 8)
            Button { state.zoom = max(0.5, state.zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(state.zoom <= 0.5).accessibilityLabel("缩小图片")
            Button { state.zoom = 1; state.fullSize = false } label: { Text("\(Int(state.zoom * 100))%").monospacedDigit().frame(width: 44) }
                .help("恢复适合窗口")
            Button { state.zoom = min(4, state.zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(state.zoom >= 4).accessibilityLabel("放大图片")
            Toggle("原尺寸", isOn: $state.fullSize).toggleStyle(.button)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                .keyboardShortcut("w", modifiers: .command).accessibilityLabel("关闭图片").accessibilityFocused($closeFocused)
        }
        .buttonStyle(.borderless).foregroundStyle(.primary)
        .padding(.horizontal, 16).frame(height: 42)
        .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: .black)
        .environment(\.colorScheme, .dark)
        .disabled(state.closing)
    }

    private func dismiss() {
        guard !state.closing else { return }
        state.closing = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DeskMotion.image) {
            state.fullSize = false
            state.zoom = 1
            state.expanded = false
        }
        state.dismissTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 130 : 240)) } catch { return }
            close()
        }
    }
}

@MainActor private final class ViewerState: ObservableObject {
    var dismissTask: Task<Void, Never>?
    var windowSize: CGSize = .zero
    var returnToSource = true
    @Published var expanded = false
    @Published var closing = false
    @Published var zoom = 1.0
    @Published var fullSize = false
    @Published var original: CGImage?
    @Published var loading = true
    @Published var failed = false
}

enum DeskImageGeometry {
    static func fit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let width = max(1, size.width), height = max(1, size.height)
        let scale = min(max(1, bounds.width) / width, max(1, bounds.height) / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
    static func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        let width = rect.width * scale, height = rect.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
