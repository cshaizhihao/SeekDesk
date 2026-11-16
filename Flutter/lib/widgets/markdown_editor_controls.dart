// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/document_history.dart';
import '../core/frame_diagnostics.dart';
import '../core/markdown_edit.dart';
import 'editor_header_diagnostics.dart';
import 'desk_material_scope.dart';
import 'glass_chrome.dart';

class MarkdownStatus extends StatelessWidget {
  const MarkdownStatus(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => sampleEditorBuild(
    kind: UiWorkKind.editorStatusBuild,
    child: DeskMaterialScope(
      child: Tooltip(
        message: text,
        excludeFromSemantics: true,
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: DeskColors(context).secondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
    ),
  );
}

/// Auxiliary controls may scroll in short windows; the document keeps a useful
/// editing area instead of being reduced to its padding by a verification notice.
class MarkdownWorkspace extends StatelessWidget {
  const MarkdownWorkspace({
    required this.header,
    required this.editor,
    required this.footer,
    super.key,
  });

  final List<Widget> header;
  final Widget editor, footer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (constraints.maxHeight - 211).clamp(
              0.0,
              constraints.maxHeight,
            ),
          ),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: header,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          key: const ValueKey('markdown-workspace-editor'),
          child: editor,
        ),
        const SizedBox(height: 16),
        footer,
      ],
    ),
  );
}

MarkdownCommand? markdownShortcut(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (event is! KeyDownEvent ||
      !keyboard.isMetaPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isShiftPressed) {
    return null;
  }
  return switch (event.logicalKey) {
    LogicalKeyboardKey.keyB => MarkdownCommand.bold,
    LogicalKeyboardKey.keyI => MarkdownCommand.italic,
    LogicalKeyboardKey.keyK => MarkdownCommand.link,
    _ => null,
  };
}

MarkdownTypingCommand? markdownTypingShortcut(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (event is! KeyDownEvent && event is! KeyRepeatEvent ||
      keyboard.isMetaPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed) {
    return null;
  }
  if (event.logicalKey == LogicalKeyboardKey.tab) {
    return keyboard.isShiftPressed
        ? MarkdownTypingCommand.outdent
        : MarkdownTypingCommand.indent;
  }
  if (!keyboard.isShiftPressed &&
      (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
    return MarkdownTypingCommand.newline;
  }
  return null;
}

/// Composition keys must reach the platform IME without first triggering an
/// ancestor's focus traversal. This is deliberately narrower than all keys:
/// modifiers used by system shortcuts keep their existing routing.
bool markdownCompositionKey(DocumentHistory history, KeyEvent event) =>
    history.isComposing && markdownTypingShortcut(event) != null;

/// Call only for the active body editor, after its send-shortcut policy. A
/// non-applicable newline stays unhandled so platform text input inserts it.
bool applyMarkdownTypingKey(
  DocumentHistory history,
  KeyEvent event, {
  required FocusNode focusNode,
  required bool Function() isCurrent,
}) {
  final command = markdownTypingShortcut(event);
  if (command == null || history.isComposing) return false;
  final before = history.controller.value;
  final next = applyMarkdownTypingCommand(history.controller.value, command);
  if (next == null) return false;
  if (next == before) return true;
  if (!history.apply(next)) return false;
  revealMarkdownCaret(history, focusNode: focusNode, isCurrent: isCurrent);
  return true;
}

/// Programmatic history edits bypass EditableText's native caret scheduling.
/// Normally requires a focused, current body. Explicit history controls can
/// reveal without moving keyboard focus away from their toolbar button.
void revealMarkdownCaret(
  DocumentHistory history, {
  required FocusNode focusNode,
  required bool Function() isCurrent,
  bool allowUnfocused = false,
}) {
  if (history.isDisposed ||
      history.isComposing ||
      !isCurrent() ||
      !allowUnfocused && !focusNode.hasFocus) {
    return;
  }
  final editable = focusNode.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (editable != null &&
      identical(editable.widget.controller, history.controller)) {
    final applied = history.controller.value;
    if (!applied.selection.isValid ||
        applied.selection.end > applied.text.length) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (history.isDisposed ||
          !isCurrent() ||
          !editable.mounted ||
          !allowUnfocused && !focusNode.hasFocus ||
          history.controller.value != applied ||
          !(ModalRoute.of(editable.context)?.isCurrent ?? true) ||
          !identical(
            focusNode.context?.findAncestorStateOfType<EditableTextState>(),
            editable,
          )) {
        return;
      }
      editable.bringIntoView(applied.selection.extent);
    });
  }
}

class MarkdownEditorControls extends StatelessWidget {
  const MarkdownEditorControls({
    required this.mode,
    required this.onModeChanged,
    required this.history,
    required this.enabled,
    required this.trailing,
    this.onHistoryApplied,
    super.key,
  });

  final int mode;
  final ValueChanged<int> onModeChanged;
  final DocumentHistory history;
  final bool enabled;
  final Widget trailing;

  /// Called only after a user undo/redo succeeds, not for ordinary edits.
  final VoidCallback? onHistoryApplied;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: Wrap(
      spacing: 14,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 252,
          child: GlassSegmentedControl(
            segments: const [
              GlassSegment(label: '编辑'),
              GlassSegment(label: '对照'),
              GlassSegment(label: '预览'),
            ],
            selectedIndex: mode,
            onSegmentSelected: onModeChanged,
            height: (MediaQuery.textScalerOf(context).scale(13) * 1.25 + 12)
                .ceilToDouble()
                .clamp(34.0, double.infinity),
            selectedTextStyle: const TextStyle(
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
            unselectedTextStyle: const TextStyle(
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w500,
            ),
            quality: GlassQuality.premium,
          ),
        ),
        ListenableBuilder(
          listenable: history,
          builder: (context, _) => DeskMaterialScope(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                sampleEditorBuild(
                  kind: UiWorkKind.editorUndoBuild,
                  child: DeskIcon(
                    '撤销 ⌘Z',
                    CupertinoIcons.arrow_uturn_left,
                    enabled && mode != 2 && history.canUndo
                        ? () {
                            if (history.undo()) onHistoryApplied?.call();
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                sampleEditorBuild(
                  kind: UiWorkKind.editorRedoBuild,
                  child: DeskIcon(
                    '重做 ⇧⌘Z',
                    CupertinoIcons.arrow_uturn_right,
                    enabled && mode != 2 && history.canRedo
                        ? () {
                            if (history.redo()) onHistoryApplied?.call();
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                sampleEditorBuild(
                  kind: UiWorkKind.editorHelpBuild,
                  child: DeskIcon(
                    'Markdown 帮助',
                    CupertinoIcons.question_circle,
                    enabled && !history.isComposing
                        ? () {
                            if (ModalRoute.of(context)?.isCurrent ?? true) {
                              _showHelp(context);
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        trailing,
      ],
    ),
  );
}

Future<void> _showHelp(BuildContext context) => showCupertinoDialog<void>(
  context: context,
  builder: (context) => DeskDialog(
    title: 'Markdown 快速帮助',
    icon: CupertinoIcons.question_circle,
    content: const Text(
      '选中文字后点击格式按钮；再次点击可移除格式。标题、引用和列表作用于整行。\n\n'
      '**粗体**  ·  *斜体*  ·  ~~删除线~~\n'
      '## 标题\n> 引用\n- 列表\n1. 有序列表\n'
      '[文字](网址)\n![描述](图片网址)\n`行内代码`\n\n'
      '⌘B 粗体  ·  ⌘I 斜体  ·  ⌘K 链接\n'
      '⌘Z 撤销  ·  ⇧⌘Z 重做\n\n'
      '列表中按回车可续行，空条目再次回车可退出。\n'
      'Tab 缩进  ·  ⇧Tab 减少缩进；可作用于选中的多行。\n'
      '回车优先遵循设置中的发送快捷键。\n\n'
      '对照模式可边写边看效果，预览仅供检查，不会发布内容。',
    ),
    actions: [
      DeskDialogAction(
        '知道了',
        isDefaultAction: true,
        onPressed: () => Navigator.pop(context),
      ),
    ],
  ),
);
