import AppKit
import SwiftUI

@MainActor
final class MarkdownEditorState: ObservableObject {
    enum Mode: Hashable { case edit, split, preview }
    @Published var mode: Mode
    var preview: Bool { mode == .preview }
    @Published var expanded = false
    @Published var height: CGFloat?
    @Published var heightDrag: CGFloat = 0
    var dragStart: CGFloat?
    @Published var showingStickers = false
    @Published var confirmClear = false
    @Published var focused = false
    @Published var showingImageSettings = false
    @Published var uploading = false
    @Published var imageMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private(set) var selection = NSRange(location: 0, length: 0)
    weak var textView: NSTextView?
    private struct PendingInsertion {
        weak var view: NSTextView?
        let value: String
        let draft: Binding<String>
        let original: String
        let selection: NSRange?
        let atEnd: Bool
    }
    private var pendingInsertions: [PendingInsertion] = []

    init(initialMode: Mode = .edit) { mode = initialMode }

    func insert(_ value: String, into draft: Binding<String>, selection: NSRange? = nil) {
        insert(value, into: draft, selection: selection, atEnd: false)
    }

    private func insert(_ value: String, into draft: Binding<String>, selection: NSRange?, atEnd: Bool) {
        let original = draft.wrappedValue
        let source = original as NSString
        let end = NSRange(location: source.length, length: 0)
        // An upload may finish while the user is composing Chinese. Updating
        // only the binding then would be overwritten by the IME's final commit.
        if let textView, textView.isEditable, textView.hasMarkedText() {
            pendingInsertions.append(PendingInsertion(view: textView, value: value, draft: draft,
                                                      original: original, selection: selection, atEnd: atEnd))
            return
        }
        let view: NSTextView? = if let textView, textView.window != nil, textView.isEditable || preview,
                                  !textView.hasMarkedText(), textView.string == original { textView } else { nil }
        let proposed = atEnd ? end : selection ?? view?.selectedRange() ?? end
        let validRange = proposed.location >= 0 && proposed.location <= source.length &&
            proposed.length >= 0 && proposed.length <= source.length - proposed.location
        let range = validRange ? proposed : end
        if let view {
            // Preview keeps the same native document mounted. An already
            // authorized upload may complete here without losing its undo
            // history or bringing keyboard focus back to the hidden editor.
            let editable = view.isEditable
            if !editable { view.isEditable = true }
            defer { view.isEditable = editable }
            view.breakUndoCoalescing()
            view.insertText(value, replacementRange: range)
            view.breakUndoCoalescing()
            view.undoManager?.setActionName("插入内容")
            refreshEditingState()
            if view.string != original {
                if draft.wrappedValue != view.string { draft.wrappedValue = view.string }
                return
            }
        }
        draft.wrappedValue = source.replacingCharacters(in: range, with: value)
    }

    func flushPendingInsertions(from view: NSTextView) {
        guard !view.hasMarkedText() else { return }
        let pending = pendingInsertions
        pendingInsertions.removeAll()
        for item in pending where item.view === view && textView === view {
            let selection = item.draft.wrappedValue == item.original ? item.selection : nil
            insert(item.value, into: item.draft, selection: selection, atEnd: item.atEnd)
        }
    }

    func refreshEditingState() {
        let undo = textView?.undoManager?.canUndo ?? false
        let redo = textView?.undoManager?.canRedo ?? false
        let range = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
        if selection != range { selection = range }
    }

    func detach(_ view: NSTextView) {
        pendingInsertions.removeAll { $0.view === view || $0.view == nil }
        if textView === view { textView = nil; refreshEditingState() }
    }

    func restoreFocus() {
        guard !preview, let view = textView, view.isEditable else { return }
        view.window?.makeFirstResponder(view)
        view.scrollRangeToVisible(view.selectedRange())
    }

    func undo() {
        guard !preview, let view = textView, view.isEditable, !view.hasMarkedText(), view.undoManager?.canUndo == true else { return }
        view.breakUndoCoalescing()
        view.undoManager?.undo()
        restoreFocus()
        refreshEditingState()
    }
    func redo() {
        guard !preview, let view = textView, view.isEditable, !view.hasMarkedText(), view.undoManager?.canRedo == true else { return }
        view.undoManager?.redo()
        restoreFocus()
        refreshEditingState()
    }
    func clear() {
        guard !preview, let view = textView, view.isEditable, !view.hasMarkedText() else { return }
        view.breakUndoCoalescing()
        view.insertText("", replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        view.breakUndoCoalescing()
        view.undoManager?.setActionName("清空内容")
        refreshEditingState()
    }

    func apply(_ command: MarkdownCommand) {
        guard !preview, let textView, textView.isEditable, !textView.hasMarkedText(),
              let edit = command.edit(source: textView.string, selection: textView.selectedRange()) else { return }
        textView.window?.makeFirstResponder(textView)
        textView.breakUndoCoalescing()
        textView.insertText(edit.text, replacementRange: edit.replaced)
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName("Markdown 格式")
        if NSMaxRange(edit.selected) <= (textView.string as NSString).length {
            textView.setSelectedRange(edit.selected)
            textView.scrollRangeToVisible(edit.selected)
        }
        refreshEditingState()
    }

    func togglePreview() {
        mode = preview ? .edit : .preview
        if preview { releaseFocus() }
    }

    func append(_ content: String, to draft: Binding<String>) {
        if preview { mode = .edit }
        insert(content, into: draft, selection: nil, atEnd: true)
        Task { @MainActor [weak self] in
            guard let self, !self.preview, let view = self.textView, view.isEditable, !view.hasMarkedText() else { return }
            view.window?.makeFirstResponder(view)
            let end = NSRange(location: (view.string as NSString).length, length: 0)
            view.setSelectedRange(end)
            view.scrollRangeToVisible(end)
        }
    }

    func finish() {
        if preview { mode = .edit }
        releaseFocus()
    }

    func releaseFocus() {
        if let textView, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
}

struct MarkdownTextInput: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let editor: MarkdownEditorState
    let fieldLabel: String
    let onKeyDown: ((NSEvent) -> Bool)?
    var onInsertLink: (() -> Void)? = nil
    var onFormat: (() -> Void)? = nil
    let onImage: (NodeImageUpload.Picture) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = MarkdownTextView(frame: scroll.contentView.bounds)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes[.paragraphStyle] = paragraph
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.drawsBackground = false
        view.setAccessibilityLabel(fieldLabel)
        view.string = text
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        editor.textView = view
        context.coordinator.observeUndo(in: view)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = view.documentView as? NSTextView else { return }
        if input.string != text, !input.hasMarkedText() {
            let selected = input.selectedRange()
            input.string = text
            // External draft replacement starts a new document history. Never
            // let undo restore a previous thread's or account's draft.
            input.undoManager?.removeAllActions()
            let length = (text as NSString).length
            let location = min(selected.location, length)
            input.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
        }
        input.setAccessibilityLabel(fieldLabel)
        input.isEditable = enabled
        context.coordinator.scheduleEditingStateRefresh()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        guard let input = view.documentView as? NSTextView else { return }
        input.delegate = nil
        coordinator.parent.editor.detach(input)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextInput
        private var refreshScheduled = false
        private weak var observedUndo: UndoManager?
        init(_ parent: MarkdownTextInput) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func observeUndo(in view: NSTextView) {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                         .NSUndoManagerDidCloseUndoGroup] {
                // NSTextView also registers its delegate with NotificationCenter.
                // Removing every observation here would silently detach normal
                // textDidChange/textDidBeginEditing delegate notifications.
                NotificationCenter.default.removeObserver(self, name: name, object: observedUndo)
                if let manager = view.undoManager {
                    NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: name, object: manager)
                }
            }
            observedUndo = view.undoManager
        }
        @objc private func historyChanged(_ notification: Notification) {
            // UndoManager can restore NSTextStorage without sending the normal
            // NSTextView textDidChange delegate callback. Keep the draft binding
            // in sync for toolbar and native menu/keyboard undo alike.
            if notification.name == .NSUndoManagerDidUndoChange || notification.name == .NSUndoManagerDidRedoChange,
               let view = parent.editor.textView, !view.hasMarkedText() {
                parent.text = view.string
            }
            scheduleEditingStateRefresh()
        }
        func scheduleEditingStateRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.parent.editor.refreshEditingState()
            }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.editor.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.editor.focused = false }
        func textViewDidChangeSelection(_ notification: Notification) { scheduleEditingStateRefresh() }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView, !view.hasMarkedText() {
                parent.text = view.string
                parent.editor.flushPendingInsertions(from: view)
            }
            scheduleEditingStateRefresh()
        }
    }
}

final class MarkdownTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    private var continuesList = true
    override var undoManager: UndoManager? { documentUndoManager }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, historyShortcut(event) || formattingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isEditable, !hasMarkedText(),
           let coordinator = delegate as? MarkdownTextInput.Coordinator,
           coordinator.parent.onKeyDown?(event) == true { return }
        if historyShortcut(event) { return }
        if formattingShortcut(event) { return }
        continuesList = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        defer { continuesList = true }
        super.keyDown(with: event)
    }

    private var historyEditor: MarkdownEditorState? {
        guard window?.firstResponder === self, isEditable, !hasMarkedText(),
              let coordinator = delegate as? MarkdownTextInput.Coordinator,
              !coordinator.parent.editor.preview else { return nil }
        return coordinator.parent.editor
    }

    // NSTextView's separate UndoManager does not by itself make the standard
    // responder-chain undo:/redo: actions target it. Expose and validate those
    // actions here, so the Edit menu and shortcuts use this document's history.
    @objc func undo(_ sender: Any?) { historyEditor?.undo() }
    @objc func redo(_ sender: Any?) { historyEditor?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return historyEditor != nil && documentUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return historyEditor != nil && documentUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            menuItem.title = documentUndoManager.undoMenuItemTitle
            return historyEditor != nil && documentUndoManager.canUndo
        }
        if menuItem.action == #selector(redo(_:)) {
            menuItem.title = documentUndoManager.redoMenuItemTitle
            return historyEditor != nil && documentUndoManager.canRedo
        }
        return super.validateMenuItem(menuItem)
    }

    private func historyShortcut(_ event: NSEvent) -> Bool {
        guard historyEditor != nil, event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command { undo(nil); return true }
        if modifiers == [.command, .shift] { redo(nil); return true }
        return false
    }

    private func formattingShortcut(_ event: NSEvent) -> Bool {
        guard isEditable, !hasMarkedText(),
              event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
              let coordinator = delegate as? MarkdownTextInput.Coordinator,
              !coordinator.parent.editor.preview else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": coordinator.parent.editor.apply(.bold)
        case "i": coordinator.parent.editor.apply(.italic)
        case "k":
            if let action = coordinator.parent.onInsertLink { action(); return true }
            coordinator.parent.editor.apply(.link)
        default: return false
        }
        coordinator.parent.onFormat?()
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if continuesList, applyTyping(.newline, name: "列表换行") { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if applyTyping(.indent, name: "缩进") { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if isEditable, !hasMarkedText() {
            _ = applyTyping(.outdent, name: "减少缩进")
            return
        }
        super.insertBacktab(sender)
    }

    private func applyTyping(_ command: MarkdownTypingCommand, name: String) -> Bool {
        guard isEditable, !hasMarkedText(),
              let edit = command.edit(source: string, selection: selectedRange()) else { return false }
        breakUndoCoalescing()
        insertText(edit.text, replacementRange: edit.replaced)
        breakUndoCoalescing()
        undoManager?.setActionName(name)
        setSelectedRange(edit.selected)
        scrollRangeToVisible(edit.selected)
        if let coordinator = delegate as? MarkdownTextInput.Coordinator {
            coordinator.parent.onFormat?()
            coordinator.parent.editor.refreshEditingState()
        }
        return true
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if isEditable, let delegate = delegate as? MarkdownTextInput.Coordinator,
           pasteboard.string(forType: .string)?.isEmpty != false,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap({
               NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
           }) {
            delegate.parent.onImage(NodeImageUpload.Picture(data: data, name: "clipboard.png", mime: "image/png"))
            return
        }
        super.paste(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let didFocus = super.becomeFirstResponder()
        if didFocus, let delegate = delegate as? MarkdownTextInput.Coordinator {
            Task { @MainActor in delegate.parent.editor.focused = true }
        }
        return didFocus
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, let delegate = delegate as? MarkdownTextInput.Coordinator {
            Task { @MainActor in delegate.parent.editor.focused = false }
        }
        return didResign
    }
}

