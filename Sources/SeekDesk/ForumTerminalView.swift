import AppKit
import SwiftUI

struct ForumTerminalView: View {
    let lines: [[ForumTerminalSpan]]
    let palette: DeskPalette
    @StateObject private var state = Controls()
    private let ink = Color(red: 0.12, green: 0.15, blue: 0.20)

    var body: some View {
        let content = state.renderCache.content(for: lines)
        let naturalSize = content.naturalSize
        ForumReportPanel(naturalSize: naturalSize, minimumWidth: 500, kind: .nq) {
            HStack(spacing: 8) {
                DeskIcon("terminal").foregroundStyle(palette.accent)
                Text("测评终端").font(.system(size: 12, weight: .semibold))
                Spacer()
                ForumReportScaleControls(kind: .nq)
                Button { state.showingReport = true } label: { DeskLabel("放大报告", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .font(.caption).buttonStyle(.borderless)
                Button {
                    let text = lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    state.didCopy = true
                } label: {
                    DeskLabel(state.didCopy ? "已复制" : "复制报告", systemImage: state.didCopy ? "checkmark" : "doc.on.doc")
                }
                .font(.caption).buttonStyle(.borderless)
            }
            .padding(.horizontal, 11).frame(height: 35)
            .deskGlass(in: Rectangle(), solid: palette.chrome)
        } content: { scale in
                terminalText(content, size: 12.5)
                    .frame(width: naturalSize.width, height: naturalSize.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: naturalSize.width * scale, height: naturalSize.height * scale, alignment: .topLeading)
                    .background(ink)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line).allowsHitTesting(false) }
        .sheet(isPresented: $state.showingReport) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    DeskLabel("测评终端", systemImage: "terminal").font(.headline)
                    Spacer()
                    Button { state.reportSize = max(10, state.reportSize - 1) } label: { DeskIcon("minus.magnifyingglass") }
                        .accessibilityLabel("缩小报告字号").disabled(state.reportSize <= 10)
                    Text("\(Int(state.reportSize)) 点").font(.caption.monospacedDigit()).frame(width: 42)
                    Button { state.reportSize = min(26, state.reportSize + 1) } label: { DeskIcon("plus.magnifyingglass") }
                        .accessibilityLabel("放大报告字号").disabled(state.reportSize >= 26)
                    Button("关闭") { state.showingReport = false }.keyboardShortcut(.cancelAction)
                }
                .buttonStyle(DeskButtonStyle()).controlSize(.regular)
                .padding(14)
                .deskGlass(in: RoundedRectangle(cornerRadius: 16), solid: palette.chrome)
                .padding(10)
                ScrollView([.horizontal, .vertical]) { terminalText(content, size: state.reportSize) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(ink)
            }
            .frame(minWidth: 560, idealWidth: 900, minHeight: 360, idealHeight: 620)
        }
    }

    private func terminalText(_ content: ForumTerminalContent, size: Double) -> some View {
        Group {
            if content.lines.count > 250 {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(content.lines.indices, id: \.self) { index in
                        Text(content.styledLine(at: index)).fixedSize(horizontal: true, vertical: true)
                    }
                }
            } else { Text(content.styledText).lineSpacing(1).fixedSize(horizontal: true, vertical: true) }
        }
        .font(.system(size: size, design: .monospaced)).textSelection(.enabled).padding(12)
    }

    @MainActor private final class Controls: ObservableObject {
        let renderCache = ForumTerminalRenderCache()
        @Published var showingReport = false
        @Published var didCopy = false
        @Published var reportSize = 14.0
    }
}

/// One content snapshot per mounted report, without publishing cache mutations.
/// Replacing the source releases the previous formatted lines and measurement.
final class ForumTerminalRenderCache {
    private var current: ForumTerminalContent?

    func content(for lines: [[ForumTerminalSpan]]) -> ForumTerminalContent {
        if let current, current.lines == lines { return current }
        let content = ForumTerminalContent(lines: lines)
        current = content
        return content
    }
}

final class ForumTerminalContent {
    let lines: [[ForumTerminalSpan]]
    let naturalSize: CGSize
    private static let maximumCachedBytes = 256 * 1024
    private static let maximumCachedLines = 128
    private var cachedText: AttributedString?
    private var cachedLines: [Int: (text: AttributedString, bytes: Int)] = [:]
    private var cachedLineOrder: [Int] = []
    private var cachedLineBytes = 0

    init(lines: [[ForumTerminalSpan]]) {
        self.lines = lines
        naturalSize = Self.measure(lines)
    }

    private static func measure(_ lines: [[ForumTerminalSpan]]) -> CGSize {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
        let width = lines.map { spans in
            spans.reduce(CGFloat.zero) { width, span in
                let runFont = span.bold ? boldFont : font
                return width + (span.text as NSString).size(withAttributes: [.font: runFont]).width
            }
        }.max() ?? 1
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(width: ceil(width) + 24, height: ceil(CGFloat(max(1, lines.count)) * (lineHeight + 1)) + 24)
    }

    var styledText: AttributedString {
        if let cachedText { return cachedText }
        var result = AttributedString()
        var bytes = 0
        for (index, spans) in lines.enumerated() {
            if index != 0 { result.append(AttributedString("\n")) }
            result.append(Self.styled(spans))
            bytes += spans.reduce(0) { $0 + $1.text.utf8.count } + 1
        }
        // Long reports use styledLine instead; do not retain an unbounded
        // attributed copy of an unusually large short report either.
        if lines.count <= 250, bytes <= Self.maximumCachedBytes { cachedText = result }
        return result
    }

    func styledLine(at index: Int) -> AttributedString {
        if let cached = cachedLines[index] { return cached.text }
        let spans = lines[index]
        let result = Self.styled(spans)
        let bytes = max(1, spans.reduce(0) { $0 + $1.text.utf8.count })
        guard bytes <= Self.maximumCachedBytes else { return result }
        while cachedLines.count >= Self.maximumCachedLines || cachedLineBytes + bytes > Self.maximumCachedBytes {
            let oldest = cachedLineOrder.removeFirst()
            if let removed = cachedLines.removeValue(forKey: oldest) { cachedLineBytes -= removed.bytes }
        }
        cachedLines[index] = (result, bytes)
        cachedLineOrder.append(index)
        cachedLineBytes += bytes
        return result
    }

    private static func styled(_ spans: [ForumTerminalSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            run.foregroundColor = color(span.foreground) ?? Color(red: 0.84, green: 0.88, blue: 0.94)
            if let background = color(span.background) { run.backgroundColor = background }
            if span.bold { run.inlinePresentationIntent = .stronglyEmphasized }
            result.append(run)
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }

    private static func color(_ value: String?) -> Color? {
        guard let value else { return nil }
        let values = value.split { !$0.isNumber }.compactMap { Double($0) }
        guard values.count >= 3, values.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        return Color(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255)
    }

}
