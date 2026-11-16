import SwiftUI

/// Wrap whole labelled controls instead of shrinking their targets or hiding them offscreen.
struct MarkdownToolbarFlow: Layout {
    var spacing: CGFloat = 3
    var rowSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, position) in layout.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                 proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, positions: [CGPoint]) {
        let width = width.flatMap { $0.isFinite ? max(1, $0) : nil }
        let limit = width ?? .greatestFiniteMagnitude
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > limit {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: width ?? usedWidth, height: y + rowHeight), positions)
    }
}

struct MarkdownLinkDraft: Identifiable {
    let id = UUID()
    let image: Bool
    let source: String
    let selection: NSRange
    let label: String
}

struct MarkdownLinkForm: View {
    let draft: MarkdownLinkDraft
    let palette: DeskPalette
    let cancel: () -> Void
    let insert: (String, URL) -> Void
    @StateObject private var fields: Fields
    @FocusState private var addressFocused: Bool

    init(draft: MarkdownLinkDraft, palette: DeskPalette, cancel: @escaping () -> Void,
         insert: @escaping (String, URL) -> Void) {
        self.draft = draft
        self.palette = palette
        self.cancel = cancel
        self.insert = insert
        let selectedURL = Self.webURL(draft.label)
        _fields = StateObject(wrappedValue: Fields(label: selectedURL == nil ? draft.label : "",
                                                  address: selectedURL?.absoluteString ?? ""))
    }

    private var url: URL? { Self.webURL(fields.address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(draft.image ? "插入图片链接" : "插入链接", systemImage: draft.image ? "photo" : "link")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .deskGlass(in: RoundedRectangle(cornerRadius: 13), solid: palette.chrome)
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.image ? "图片地址" : "链接地址").font(.system(size: 12, weight: .medium))
                TextField("https://example.com", text: $fields.address)
                    .textFieldStyle(.roundedBorder).controlSize(.large).focused($addressFocused)
                    .accessibilityLabel(draft.image ? "图片地址" : "链接地址")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.image ? "图片说明（可选）" : "显示文字（可选）").font(.system(size: 12, weight: .medium))
                TextField(draft.image ? "描述这张图片" : "留空时使用链接地址", text: $fields.label)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityLabel(draft.image ? "图片说明" : "显示文字")
            }
            if !fields.address.isEmpty && url == nil {
                Text("请输入完整的 http 或 https 地址。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DeskGlassGroup {
                HStack {
                    Spacer()
                    Button("取消", action: cancel).deskGlassButtonStyle().keyboardShortcut(.cancelAction)
                    Button("插入") {
                        guard let url else { return }
                        let title = fields.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        insert(title.isEmpty ? (draft.image ? "图片" : url.absoluteString) : title, url)
                    }
                    .deskGlassButtonStyle(prominent: true).tint(palette.accent)
                    .keyboardShortcut(.defaultAction).disabled(url == nil)
                }
            }
        }
        .padding(20).frame(width: 400).background(palette.readerWash)
        .task(id: draft.id) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            addressFocused = true
        }
    }

    @MainActor private final class Fields: ObservableObject {
        @Published var label: String
        @Published var address: String
        init(label: String, address: String) { self.label = label; self.address = address }
    }

    private static func webURL(_ source: String) -> URL? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace), let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct MarkdownWritingHelp: View {
    let palette: DeskPalette
    private let examples = [
        ("加粗", "**文字**", "⌘B"), ("斜体", "*文字*", "⌘I"),
        ("链接", "[文字](地址)", "⌘K"), ("标题", "## 标题", ""),
        ("引用", "> 引用文字", ""), ("列表", "- 列表项", ""),
        ("行内代码", "`代码`", "")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Markdown 写作", systemImage: "textformat")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .deskGlass(in: RoundedRectangle(cornerRadius: 13), solid: palette.chrome)
            Text("选中文字后使用工具栏，也可以直接输入语法。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(examples.indices, id: \.self) { index in
                    GridRow {
                        Text(examples[index].0)
                        Text(examples[index].1).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Text(examples[index].2).foregroundStyle(.secondary)
                    }
                }
            }.font(.system(size: 12))
            Divider()
            Text("列表中回车继续下一项，空项再回车退出。Tab 缩进，⇧ Tab 取消缩进。若已设置 Return 发送，使用 ⇧ Return 换行。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("⌘Z 撤销　⇧⌘Z 重做")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 375).background(palette.readerWash)
    }
}
