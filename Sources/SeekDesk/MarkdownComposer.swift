import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReplySendKey: String, CaseIterable, Identifiable {
    static let preference = "workspace.replySendKey"
    case commandReturn, returnKey, buttonOnly

    var id: Self { self }
    var title: String {
        switch self {
        case .commandReturn: "⌘ Return"
        case .returnKey: "Return"
        case .buttonOnly: "仅按钮"
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        guard self != .buttonOnly, event.keyCode == 36 || event.keyCode == 76 else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        return modifiers == (self == .commandReturn ? .command : [])
    }
}

struct MarkdownComposer: View {
    @Binding var text: String
    let palette: DeskPalette
    let disabled: Bool
    @ObservedObject var editor: MarkdownEditorState
    let imageSizing: DraftImageSizing
    let height: CGFloat
    var maxHeight: CGFloat = 420
    var resizeFromBottom = false
    var allowsSplit = true
    var fillsAvailableSpace = false
    var compactControls = false
    var placeholder = "写下你的回复…"
    var fieldLabel = "回复正文"
    var onFormat: () -> Void = {}
    var onKeyDown: ((NSEvent) -> Bool)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dialogs = Dialogs()

    private let minHeight: CGFloat = 80
    private var range: ClosedRange<CGFloat> { minHeight...max(minHeight, maxHeight) }
    private var baseHeight: CGFloat {
        clamp(editor.height ?? (editor.expanded ? range.upperBound : editor.mode == .split ? max(260, height) : height))
    }
    private var locked: Bool { disabled || editor.preview }

    var body: some View {
        VStack(spacing: 0) {
            if !fillsAvailableSpace && !resizeFromBottom { resizeGrip }
            Group {
                toolbar
                    .deskGlass(in: RoundedRectangle(cornerRadius: 12), solid: palette.list)
            }
            .padding(6)
            GeometryReader { geometry in
                let sideBySide = editor.mode == .split && geometry.size.width >= DeskComposerLayout.sideBySideWidth
                let comparisonAllowed = DeskComposerLayout.allowsComparison(width: geometry.size.width, height: geometry.size.height)
                // Keep the native editor mounted when previewing, preserving selection and undo.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            editorPane.opacity(editor.preview ? 0 : 1)
                                .allowsHitTesting(!editor.preview).accessibilityHidden(editor.preview)
                            if editor.preview { previewPane }
                        }
                        if editor.mode == .split && !sideBySide {
                            rule
                            previewPane
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if sideBySide {
                        Rectangle().fill(palette.line).frame(width: 1)
                        previewPane
                    }
                }
                .onChange(of: comparisonAllowed, initial: true) { _, allowed in
                    dialogs.comparisonAllowed = allowed
                    if !allowed && editor.mode == .split { editor.mode = .edit }
                }
            }
            .frame(height: fillsAvailableSpace ? nil : clamp(baseHeight + editor.heightDrag))
            .frame(maxHeight: fillsAvailableSpace ? .infinity : nil)
            if !compactControls {
                rule
                statusBar
            }
            if !fillsAvailableSpace && resizeFromBottom { resizeGrip }
            if editor.uploading || editor.imageMessage != nil {
                HStack(alignment: .top, spacing: 7) {
                    if editor.uploading { ProgressView().controlSize(.small) }
                    Text(editor.uploading ? "正在上传图片…" : editor.imageMessage ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !editor.uploading {
                        Button { editor.imageMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭上传提示")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).background(palette.list)
            }
        }
        .frame(maxHeight: fillsAvailableSpace ? .infinity : nil)
        .background(palette.reader, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(editor.focused && !editor.preview ? palette.accent.opacity(0.7) : palette.line)
                .allowsHitTesting(false).animation(reduceMotion ? nil : DeskMotion.feedback, value: editor.focused)
        }
        .sheet(isPresented: $editor.showingImageSettings) {
            NodeImageSettingsView() { editor.showingImageSettings = false }
        }
        .sheet(item: $dialogs.insertion, onDismiss: { editor.restoreFocus() }) { draft in
            MarkdownLinkForm(draft: draft, palette: palette, cancel: { dialogs.insertion = nil }) { label, url in
                guard !locked else { dialogs.insertion = nil; return }
                let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    .replacingOccurrences(of: "\n", with: " ")
                let markdown = "\(draft.image ? "!" : "")[\(escaped)](<\(url.absoluteString)>)"
                editor.insert(markdown, into: $text, selection: text == draft.source ? draft.selection : nil)
                onFormat()
                dialogs.insertion = nil
            }
        }
        .confirmationDialog("清空当前编辑内容？", isPresented: $editor.confirmClear) {
            Button("清空", role: .destructive) { editor.clear() }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: editor.mode) { _, mode in
            if mode == .preview { dialogs.insertion = nil; editor.releaseFocus() }
        }
        .onChange(of: disabled) { _, disabled in if disabled { dialogs.insertion = nil } }
    }

    @MainActor private final class Dialogs: ObservableObject {
        @Published var insertion: MarkdownLinkDraft?
        @Published var showingHelp = false
        @Published var comparisonAllowed = true
    }

    private var rule: some View { Rectangle().fill(palette.line).frame(height: 1) }

    @ViewBuilder private var toolbar: some View {
        if compactControls {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    modePicker
                    Menu {
                        ForEach([MarkdownCommand.bold, .italic, .heading, .quote, .bullets, .numbers, .strike, .code, .codeBlock, .table, .divider], id: \.self) { command in
                            Button { apply(command) } label: { Label(command.title, systemImage: command.icon) }
                        }
                        Divider()
                        Button("插入链接…") { beginLink(image: false) }
                        Button("清空内容…", role: .destructive) { editor.confirmClear = true }.disabled(text.isEmpty)
                    } label: { toolbarLabel("格式", icon: "textformat", menu: true) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(locked)
                    .help("Markdown 格式与插入链接").accessibilityLabel("Markdown 格式")
                    imageMenu
                    stickers
                    historyTools
                }
                .padding(.horizontal, 9)
            }
            .scrollIndicators(.hidden).frame(height: 28).padding(.vertical, 1)
        } else {
            regularToolbar
        }
    }

    private var modePicker: some View {
        DeskGlassPicker(values: allowsSplit && dialogs.comparisonAllowed ? [.edit, .split, .preview] : [.edit, .preview],
                        selection: $editor.mode, tint: palette.accent,
                        solid: palette.selection, compact: true) { mode, _ in
            Text(mode == .edit ? "编辑" : mode == .split ? "对照" : "预览")
                .font(.system(size: 12, weight: .medium))
        }
        .frame(width: allowsSplit && dialogs.comparisonAllowed ? 186 : 132).disabled(disabled)
        .accessibilityLabel("编辑器视图")
        .help(dialogs.comparisonAllowed ? "切换编辑、对照与预览" : "扩大编辑区后可使用对照视图")
    }

    private var historyTools: some View {
        Group {
            tool("撤销", icon: "arrow.uturn.backward", labelled: false, hint: "撤销 · ⌘Z") { editor.undo() }
                .disabled(locked || !editor.canUndo)
            tool("重做", icon: "arrow.uturn.forward", labelled: false, hint: "重做 · ⇧⌘Z") { editor.redo() }
                .disabled(locked || !editor.canRedo)
        }
    }

    private var regularToolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                modePicker
                Spacer(minLength: 4)
                historyTools
                if !fillsAvailableSpace {
                    tool(editor.expanded ? "收起编辑区" : "展开编辑区",
                         icon: editor.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", labelled: false) {
                        withAnimation(reduceMotion ? nil : DeskMotion.pane) {
                            editor.expanded.toggle()
                            editor.height = nil
                        }
                    }
                }
            }
            MarkdownToolbarFlow(spacing: 3, rowSpacing: 3) {
                commandButton(.bold, hint: "加粗 · ⌘B")
                commandButton(.italic, hint: "斜体 · ⌘I")
                commandButton(.heading, hint: "插入二级标题")
                commandButton(.quote, hint: "引用文字")
                Menu {
                    Button("无序列表") { apply(.bullets) }
                    Button("有序列表") { apply(.numbers) }
                } label: { toolbarLabel("列表", icon: "list.bullet", menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 32).disabled(locked)
                .help("插入列表，回车继续下一项").accessibilityLabel("列表")
                tool("链接", icon: "link", hint: "插入链接 · ⌘K") { beginLink(image: false) }.disabled(locked)
                imageMenu
                stickers
                Menu {
                    ForEach([MarkdownCommand.strike, .code, .codeBlock, .table, .divider], id: \.self) { command in
                        Button { apply(command) } label: { Label(command.title, systemImage: command.icon) }
                    }
                    Divider()
                    Button("清空内容…", role: .destructive) { editor.confirmClear = true }.disabled(text.isEmpty)
                } label: { toolbarLabel("更多", icon: "ellipsis", menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 32).disabled(locked)
                .help("代码、表格、删除线与分割线").accessibilityLabel("更多格式")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .foregroundStyle(.primary)
    }

    private func commandButton(_ command: MarkdownCommand, hint: String) -> some View {
        tool(command.title, icon: command.icon, hint: hint) { apply(command) }.disabled(locked)
    }

    private func toolbarLabel(_ label: String, icon: String, labelled: Bool = true, menu: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(width: 17)
            if labelled { Text(label).font(.system(size: 13, weight: .medium)) }
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, labelled ? 7 : 6).frame(minWidth: 32, minHeight: 32)
        .contentShape(RoundedRectangle(cornerRadius: 6)).fixedSize()
    }

    private func tool(_ label: String, icon: String, labelled: Bool = true, hint: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { toolbarLabel(label, icon: icon, labelled: labelled) }
            .buttonStyle(DeskButtonStyle()).help(hint ?? label).accessibilityLabel(label)
    }

    private var imageMenu: some View {
        Menu {
            Button("上传本机图片…") { chooseImage() }
            Button("插入图片链接…") { beginLink(image: true) }
            Divider()
            Button("图床设置…") { editor.showingImageSettings = true }
        } label: { toolbarLabel("图片", icon: "photo", menu: true) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 32)
        .accessibilityLabel("插入图片").help("上传图片或插入图片链接，也可直接粘贴图片")
        .disabled(locked || editor.uploading)
    }

    private var stickers: some View {
        tool("表情", icon: "face.smiling") { editor.showingStickers.toggle() }
            .disabled(locked || editor.uploading)
            .popover(isPresented: $editor.showingStickers, arrowEdge: .bottom) {
                StickerPicker(palette: palette) { item in
                    if let insertion = item.insertion {
                        editor.insert(insertion, into: $text)
                        onFormat()
                    } else {
                        do { upload(try NodeImageUpload.Picture.file(item.url), label: "表情") }
                        catch { editor.imageMessage = error.localizedDescription }
                    }
                    editor.showingStickers = false
                    if item.insertion != nil { Task { @MainActor in editor.restoreFocus() } }
                }
            }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if editor.mode == .split { columnLabel("正文", icon: "pencil.line") }
            input
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if editor.mode == .split { columnLabel("实时预览", icon: "eye") }
            MarkdownPreview(text: text, palette: palette, imageSizing: imageSizing, onResize: onFormat)
                .disabled(disabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func columnLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
            Spacer()
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 13).frame(height: 26).background(palette.list.opacity(0.55))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button { dialogs.showingHelp.toggle() } label: {
                Label("语法与快捷键", systemImage: "questionmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("查看 Markdown 语法和编辑快捷键")
            .popover(isPresented: $dialogs.showingHelp, arrowEdge: .bottom) { MarkdownWritingHelp(palette: palette) }
            Spacer(minLength: 4)
            Text("\(text.count) 字符").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 27).background(palette.list.opacity(0.6))
    }

    private var input: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MarkdownTextInput(text: $text, enabled: !locked, editor: editor, fieldLabel: fieldLabel,
                                  onKeyDown: onKeyDown, onInsertLink: { beginLink(image: false) },
                                  onFormat: onFormat) { upload($0) }
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 15)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            if editor.mode == .edit { MarkdownDraftStickers(text: text, palette: palette) }
        }
    }

    private func beginLink(image: Bool) {
        guard !locked, let view = editor.textView, !view.hasMarkedText() else { return }
        let selection = view.selectedRange()
        let source = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return }
        dialogs.insertion = MarkdownLinkDraft(image: image, source: text, selection: selection,
                                      label: source.substring(with: selection))
    }

    private var resizeGrip: some View {
        ZStack {
            palette.list
            Capsule().fill(palette.accent.opacity(editor.heightDrag == 0 ? 0.26 : 0.72)).frame(width: 30, height: 2)
                .allowsHitTesting(false)
            DeskResizeHandle(vertical: true, change: { delta in
                if editor.dragStart == nil { editor.dragStart = baseHeight }
                editor.heightDrag = (resizeFromBottom ? -1 : 1) * delta
            }, finish: { delta in
                let start = editor.dragStart ?? baseHeight
                editor.height = clamp(start + (resizeFromBottom ? -1 : 1) * delta)
                editor.dragStart = nil
                editor.heightDrag = 0
            }, reset: {
                editor.height = nil
                editor.expanded = false
                editor.dragStart = nil
                editor.heightDrag = 0
            })
            .accessibilityHidden(true)
        }
        .frame(height: 11)
        .help("拖动调整编辑框高度，双击恢复")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("编辑框高度")
        .accessibilityValue("\(Int(clamp(baseHeight + editor.heightDrag))) 点")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: editor.height = clamp(baseHeight + 24)
            case .decrement: editor.height = clamp(baseHeight - 24)
            @unknown default: break
            }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(range.upperBound, max(range.lowerBound, value)) }
    private func apply(_ command: MarkdownCommand) {
        editor.apply(command)
        onFormat()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "上传"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { upload(try NodeImageUpload.Picture.file(url)) }
            catch { editor.imageMessage = NodeImageError.invalidFile.localizedDescription }
        }
    }

    private func upload(_ picture: NodeImageUpload.Picture, label: String = "图片") {
        guard !disabled, !editor.uploading, !editor.preview else { return }
        do {
            guard let key = try NodeImageKey.read(), !key.isEmpty else {
                editor.showingImageSettings = true
                return
            }
            let draft = $text
            let original = draft.wrappedValue
            let selection = editor.textView?.selectedRange()
            editor.uploading = true
            editor.imageMessage = nil
            Task {
                defer { editor.uploading = false }
                do {
                    let url = try await NodeImageUpload.upload(picture, key: key)
                    let markdown = "![\(label)](<\(url.absoluteString)>)"
                    let insertion = draft.wrappedValue == original ? selection : editor.textView?.selectedRange()
                    let range = insertion.map { NSRange(location: NSMaxRange($0), length: 0) }
                    editor.insert(markdown, into: draft, selection: range)
                    onFormat()
                    editor.imageMessage = "\(label)已插入。"
                } catch {
                    editor.imageMessage = (error as? NodeImageError)?.localizedDescription ?? NodeImageError.connection.localizedDescription
                }
            }
        } catch { editor.imageMessage = error.localizedDescription }
    }

}

private extension MarkdownCommand {
    var icon: String {
        switch self {
        case .bold: "bold"; case .italic: "italic"; case .strike: "strikethrough"; case .quote: "text.quote"
        case .bullets: "list.bullet"; case .numbers: "list.number"
        case .code: "chevron.left.chevron.right"
        case .codeBlock: "curlybraces.square"
        case .heading: "textformat.size"; case .table: "tablecells"; case .divider: "minus"
        case .link: "link"; case .image: "photo"
        }
    }
    var title: String {
        switch self {
        case .bold: "加粗"; case .italic: "斜体"; case .strike: "删除线"; case .quote: "引用"
        case .bullets: "无序列表"; case .numbers: "有序列表"; case .code: "行内代码"
        case .codeBlock: "代码块"; case .heading: "标题"; case .table: "表格"; case .divider: "分割线"
        case .link: "链接"; case .image: "图片链接"
        }
    }
}
