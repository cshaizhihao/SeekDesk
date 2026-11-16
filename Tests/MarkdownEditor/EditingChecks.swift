import AppKit
import SwiftUI

// Only unrelated forum/image data types are stubbed; all edit algorithms,
// NSTextView behavior, state, delegation and undo handling are production code.
struct ForumFloor { let id: String; let author: String; let blocks: [ForumBlock] }
struct ForumBlock { let kind: String; let text: String; let tabs: [ForumBlockTab]?; var items: [ForumListItem]? = nil }
struct ForumBlockTab { let blocks: [ForumBlock] }
struct ForumListItem { let marker: String; let blocks: [ForumBlock] }
enum Forum { static func topicID(_ url: URL) -> String? { "fixture" } }
enum NodeImageUpload {
    struct Picture { let data: Data; let name: String; let mime: String }
}

@main
struct MarkdownEditingChecks {
    static func rendered(_ source: String, _ edit: MarkdownCommand.Edit?) -> (String, NSRange) {
        guard let edit else { preconditionFailure("Missing edit for \(source.debugDescription)") }
        return ((source as NSString).replacingCharacters(in: edit.replaced, with: edit.text), edit.selected)
    }

    static func commandChecks() {
        for command in [MarkdownCommand.bold, .italic, .strike, .code, .codeBlock, .heading, .quote, .bullets, .numbers] {
            let original = "中文🎉"
            let first = rendered(original, command.edit(source: original, selection: NSRange(location: 0, length: original.utf16.count)))
            let second = rendered(first.0, command.edit(source: first.0, selection: first.1))
            precondition(second.0 == original, "Second \(command) must remove its own formatting: \(second.0)")
        }
        for original in ["`中文", "中文`", " `中文` ", " 中文 "] {
            let first = rendered(original, MarkdownCommand.code.edit(source: original, selection: NSRange(location: 0, length: original.utf16.count)))
            let second = rendered(first.0, MarkdownCommand.code.edit(source: first.0, selection: first.1))
            precondition(second.0 == original, "Inline code padding must preserve the selected source")
        }
        let bold = "**中文**"
        let italic = rendered(bold, MarkdownCommand.italic.edit(source: bold, selection: NSRange(location: 2, length: 2)))
        precondition(italic.0 == "***中文***")
        let removed = rendered(italic.0, MarkdownCommand.italic.edit(source: italic.0, selection: italic.1))
        precondition(removed.0 == bold, "Italic toggle must preserve bold")
        let selectedMarkers = rendered("**中文**", MarkdownCommand.bold.edit(source: "**中文**", selection: NSRange(location: 0, length: 6)))
        precondition(selectedMarkers.0 == "中文")
        let selectedLines = "甲\n乙\n丙"
        let partialList = rendered(selectedLines, MarkdownCommand.numbers.edit(source: selectedLines, selection: NSRange(location: 0, length: 3)))
        precondition(partialList.0 == "1. 甲\n2. 乙\n丙", "The final selected character must include its line")
        let list = rendered(selectedLines, MarkdownCommand.bullets.edit(source: selectedLines, selection: NSRange(location: 0, length: 4)))
        precondition(list.0 == "- 甲\n- 乙\n丙", "A selection ending at the next line must not change that line")
        let converted = rendered("  - 甲\n  - 乙", MarkdownCommand.numbers.edit(source: "  - 甲\n  - 乙", selection: NSRange(location: 0, length: 11)))
        precondition(converted.0 == "  1. 甲\n  2. 乙", "Changing list type must preserve indentation")
        for bad in [NSRange(location: NSNotFound, length: 0), NSRange(location: 9, length: 0), NSRange(location: 0, length: 9)] {
            precondition(MarkdownCommand.bold.edit(source: "短文", selection: bad) == nil)
        }
        print("Passed formatting toggles, combined emphasis, list conversion, boundary selections and UTF-16 offsets.")
    }

    static func typingChecks() {
        let cases: [(String, String)] = [
            ("- 中文", "- 中文\n- "), ("  * 中文", "  * 中文\n  * "),
            ("9. 九", "9. 九\n10. "), ("9) 九", "9) 九\n10) "),
            ("- [x] 已完成", "- [x] 已完成\n- [ ] "), ("- [ ] 待做", "- [ ] 待做\n- [ ] "),
            ("- ", ""), ("  2.   ", ""), ("- [x] ", "")
        ]
        for (source, expected) in cases {
            let edited = rendered(source, MarkdownTypingCommand.newline.edit(source: source, selection: NSRange(location: source.utf16.count, length: 0)))
            precondition(edited.0 == expected, "List continuation mismatch: \(source)")
            precondition(edited.1 == NSRange(location: expected.utf16.count, length: 0))
        }
        for source in ["普通文字", "```text\n- 内容", "~~~\n- 内容"] {
            precondition(MarkdownTypingCommand.newline.edit(source: source, selection: NSRange(location: source.utf16.count, length: 0)) == nil)
        }
        let closedFence = "```\n代码\n```\n- 内容"
        precondition(MarkdownTypingCommand.newline.edit(source: closedFence, selection: NSRange(location: closedFence.utf16.count, length: 0)) != nil)
        let multiline = "甲🎉\n乙\n丙"
        let range = NSRange(location: 1, length: 5)
        let indented = rendered(multiline, MarkdownTypingCommand.indent.edit(source: multiline, selection: range))
        precondition(indented.0 == "    甲🎉\n    乙\n丙")
        let outdented = rendered(indented.0, MarkdownTypingCommand.outdent.edit(source: indented.0, selection: indented.1))
        precondition(outdented.0 == multiline && outdented.1 == range, "Indentation must preserve selection, including emoji")
        let plain = rendered("正文", MarkdownTypingCommand.indent.edit(source: "正文", selection: NSRange(location: 1, length: 0)))
        precondition(plain.0 == "正    文" && plain.1.location == 5)
        let nested = rendered("- 列表", MarkdownTypingCommand.indent.edit(source: "- 列表", selection: NSRange(location: 4, length: 0)))
        precondition(nested.0 == "    - 列表" && nested.1.location == 8)
        precondition(MarkdownTypingCommand.outdent.edit(source: "正文", selection: NSRange(location: 1, length: 0)) == nil)
        for length in [3, 4] {
            let source = "甲\n乙\n丙"
            let edit = rendered(source, MarkdownTypingCommand.indent.edit(source: source, selection: NSRange(location: 0, length: length)))
            precondition(edit.0 == "    甲\n    乙\n丙", "Both selected lines must indent; the following unselected line stays put")
        }
        print("Passed Return continuation/empty exit/tasks/fences and Tab/Shift-Tab selection preservation.")
    }

    @MainActor
    final class Fixture {
        var draft: String
        let editor = MarkdownEditorState()
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        var coordinator: MarkdownTextInput.Coordinator!
        var binding: Binding<String> { Binding(get: { self.draft }, set: { self.draft = $0 }) }

        init(_ text: String, onKeyDown: ((NSEvent) -> Bool)? = nil, onLink: (() -> Void)? = nil, onFormat: (() -> Void)? = nil) {
            draft = text
            window.contentView = view
            view.isRichText = false
            view.allowsUndo = true
            view.string = text
            view.isEditable = true
            editor.textView = view
            coordinator = MarkdownTextInput.Coordinator(MarkdownTextInput(text: binding, enabled: true, editor: editor,
                fieldLabel: "测试", onKeyDown: onKeyDown, onInsertLink: onLink, onFormat: onFormat, onImage: { _ in }))
            view.delegate = coordinator
            coordinator.observeUndo(in: view)
            window.makeFirstResponder(view)
        }

        func settle() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
            editor.refreshEditingState()
        }
    }

    @MainActor
    static func event(_ text: String, code: UInt16 = 11, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    @MainActor
    static func nativeChecks() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let fixture = Fixture("中文🎉")
        precondition(fixture.coordinator.responds(to: #selector(NSTextViewDelegate.textDidChange(_:))))
        fixture.view.setSelectedRange(NSRange(location: 0, length: 4))
        fixture.editor.apply(.bold)
        fixture.settle()
        precondition(fixture.draft == "**中文🎉**" && fixture.editor.canUndo,
                     "native result=\(fixture.view.string.debugDescription), binding=\(fixture.draft.debugDescription), undo=\(fixture.editor.canUndo), marked=\(fixture.view.hasMarkedText()), delegate=\(fixture.view.delegate === fixture.coordinator), focus=\(fixture.window.firstResponder === fixture.view)")
        precondition(fixture.view.selectedRange() == NSRange(location: 2, length: 4))
        fixture.editor.undo()
        fixture.settle()
        precondition(fixture.draft == "中文🎉" && fixture.editor.canRedo,
                     "undo result=\(fixture.view.string.debugDescription), binding=\(fixture.draft.debugDescription), redo=\(fixture.editor.canRedo)")
        fixture.editor.redo()
        fixture.settle()
        precondition(fixture.draft == "**中文🎉**")
        let originalInput = fixture.editor.textView
        fixture.editor.mode = .preview
        fixture.view.isEditable = false
        fixture.window.makeFirstResponder(nil)
        fixture.editor.insert("图片", into: fixture.binding, selection: NSRange(location: fixture.draft.utf16.count, length: 0))
        fixture.settle()
        precondition(fixture.draft == "**中文🎉**图片" && fixture.view.string == fixture.draft)
        precondition(!fixture.view.isEditable && fixture.window.firstResponder !== fixture.view && fixture.editor.textView === originalInput)
        fixture.editor.mode = .split
        fixture.view.isEditable = true
        fixture.editor.undo()
        fixture.settle()
        precondition(fixture.draft == "**中文🎉**", "An upload completing in preview must preserve the document's undo history")
        let second = Fixture("另一篇")
        precondition(!second.editor.canUndo && second.view.undoManager !== fixture.view.undoManager)

        var linkCalls = 0
        var formatted = 0
        let shortcuts = Fixture("文字", onLink: { linkCalls += 1 }, onFormat: { formatted += 1 })
        shortcuts.view.setSelectedRange(NSRange(location: 0, length: 2))
        precondition(shortcuts.view.performKeyEquivalent(with: event("b")))
        precondition(shortcuts.draft == "**文字**" && formatted == 1)
        precondition(shortcuts.view.performKeyEquivalent(with: event("i", code: 34)))
        precondition(shortcuts.draft == "***文字***" && formatted == 2)
        precondition(shortcuts.view.performKeyEquivalent(with: event("k", code: 40)) && linkCalls == 1)
        shortcuts.window.makeFirstResponder(nil)
        _ = shortcuts.view.performKeyEquivalent(with: event("k", code: 40))
        precondition(linkCalls == 1, "An unfocused editor must not consume the global Cmd-K shortcut")
        shortcuts.window.makeFirstResponder(shortcuts.view)
        shortcuts.editor.mode = .preview
        _ = shortcuts.view.performKeyEquivalent(with: event("k", code: 40))
        precondition(linkCalls == 1, "Hidden preview input must not consume Cmd-K")

        var sends = 0
        let sending = Fixture("- 列表", onKeyDown: { event in
            if event.keyCode == 36 && event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
                sends += 1; return true
            }
            return false
        })
        sending.view.setSelectedRange(NSRange(location: 4, length: 0))
        sending.view.keyDown(with: event("\r", code: 36, modifiers: []))
        precondition(sends == 1 && sending.draft == "- 列表", "Configured Return-send takes precedence")
        sending.view.keyDown(with: event("\r", code: 36, modifiers: .shift))
        precondition(sending.draft == "- 列表\n", "Shift-Return bypasses list continuation")

        let ime = Fixture("正文")
        ime.view.setSelectedRange(NSRange(location: 2, length: 0))
        ime.view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(ime.view.hasMarkedText())
        ime.editor.insert("[图片]", into: ime.binding)
        ime.editor.apply(.bold)
        precondition(ime.draft == "正文" && ime.view.string == "正文拼", "Composition and pending upload must not corrupt each other")
        ime.view.insertText("拼音", replacementRange: ime.view.markedRange())
        ime.settle()
        precondition(!ime.view.hasMarkedText() && ime.draft == "正文拼音[图片]", "An insertion completing during IME must survive commit")
        precondition(ime.view.string == ime.draft)
        print("Passed native undo/redo/isolation, keyboard focus, preview, send priority and marked-text insertion.")
    }

    @MainActor
    static func historyRoutingChecks() {
        let fixture = Fixture("正文")
        fixture.view.setSelectedRange(NSRange(location: 2, length: 0))
        fixture.editor.insert("[链接](https://example.com)", into: fixture.binding)
        fixture.settle()
        let inserted = fixture.draft
        let undo = NSMenuItem(title: "Undo", action: #selector(MarkdownTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(MarkdownTextView.redo(_:)), keyEquivalent: "Z")
        precondition(fixture.view.validateMenuItem(undo) && fixture.view.validateUserInterfaceItem(undo))
        precondition(!fixture.view.validateMenuItem(redo))
        precondition(fixture.view.performKeyEquivalent(with: event("z", code: 6)))
        fixture.settle()
        precondition(fixture.draft == "正文", "Cmd-Z must use the editor's document UndoManager")
        precondition(!fixture.view.validateMenuItem(undo) && fixture.view.validateMenuItem(redo))
        precondition(fixture.view.performKeyEquivalent(with: event("z", code: 6, modifiers: [.command, .shift])))
        fixture.settle()
        precondition(fixture.draft == inserted, "Shift-Cmd-Z must redo the same document edit")
        fixture.view.keyDown(with: event("z", code: 6))
        fixture.settle()
        precondition(fixture.draft == "正文", "The keyDown fallback must route Cmd-Z too")
        fixture.view.keyDown(with: event("z", code: 6, modifiers: [.command, .shift]))
        fixture.settle()
        precondition(fixture.draft == inserted)
        precondition(NSApp.sendAction(#selector(MarkdownTextView.undo(_:)), to: fixture.view, from: undo))
        fixture.settle()
        precondition(fixture.draft == "正文", "The native undo: menu action must synchronize the draft")
        precondition(NSApp.sendAction(#selector(MarkdownTextView.redo(_:)), to: fixture.view, from: redo))
        fixture.settle()
        precondition(fixture.draft == inserted)

        fixture.window.makeFirstResponder(nil)
        precondition(!fixture.view.validateMenuItem(undo))
        fixture.view.undo(nil)
        precondition(fixture.draft == inserted, "Unfocused editors must not intercept menu history")
        fixture.window.makeFirstResponder(fixture.view)
        fixture.editor.mode = .preview
        precondition(!fixture.view.validateMenuItem(undo))
        fixture.view.undo(nil)
        precondition(fixture.draft == inserted, "Preview must not accept native editing actions")
        fixture.editor.mode = .edit
        fixture.view.setSelectedRange(NSRange(location: inserted.utf16.count, length: 0))
        fixture.view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = fixture.view.string
        precondition(!fixture.view.validateMenuItem(undo) && !fixture.view.validateMenuItem(redo))
        fixture.view.undo(nil)
        precondition(fixture.view.hasMarkedText() && fixture.view.string == composing)
        fixture.view.unmarkText()
        print("Passed Cmd-Z/Shift-Cmd-Z key-equivalent/keyDown routing, native menu actions/validation and focus/preview/IME guards.")
    }

    @MainActor
    static func main() {
        commandChecks()
        typingChecks()
        nativeChecks()
        historyRoutingChecks()
        print("All Markdown editor checks passed without showing or activating a window.")
    }
}
