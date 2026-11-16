// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/markdown_edit.dart';
import '../core/frame_diagnostics.dart';
import 'desk_material_scope.dart';
import 'editor_header_diagnostics.dart';
import 'glass_chrome.dart';

/// All formatting commands stay on the tool shelf. Grouping provides a stable
/// reading order without hiding commands in a horizontal scroller or menu.
class MarkdownToolbar extends StatefulWidget {
  const MarkdownToolbar({
    required this.onCommand,
    this.enabled = true,
    this.trailing,
    super.key,
  });

  final ValueChanged<MarkdownCommand> onCommand;
  final bool enabled;
  final Widget? trailing;

  @override
  State<MarkdownToolbar> createState() => _MarkdownToolbarState();
}

class _MarkdownToolbarState extends State<MarkdownToolbar> {
  static const groups = [
    [
      MarkdownCommand.bold,
      MarkdownCommand.italic,
      MarkdownCommand.strike,
      MarkdownCommand.heading,
    ],
    [MarkdownCommand.quote, MarkdownCommand.bullets, MarkdownCommand.numbers],
    [
      MarkdownCommand.link,
      MarkdownCommand.image,
      MarkdownCommand.table,
      MarkdownCommand.divider,
    ],
    [MarkdownCommand.code, MarkdownCommand.codeBlock],
  ];

  // These groups depend only on availability. Command dispatch reads the
  // current widget at activation time, while the group surface resolves its
  // own inherited theme. Parent text/status and media updates can therefore
  // reuse the format widgets without retaining callbacks or theme snapshots.
  late List<Widget> _commandGroups;

  @override
  void initState() {
    super.initState();
    _commandGroups = _buildCommandGroups();
  }

  @override
  void didUpdateWidget(covariant MarkdownToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _commandGroups = _buildCommandGroups();
    }
  }

  List<Widget> _buildCommandGroups() => [
    for (final group in groups)
      Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: _MarkdownGroupSurface()),
          ),
          Padding(
            padding: const EdgeInsets.all(2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final command in group)
                  MarkdownToolButton(
                    key: ValueKey(command),
                    command: command,
                    onTap: widget.enabled ? () => _run(command) : null,
                  ),
              ],
            ),
          ),
        ],
      ),
  ];

  void _run(MarkdownCommand command) {
    if (!mounted ||
        !widget.enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    widget.onCommand(command);
  }

  @override
  Widget build(BuildContext context) => DeskMaterialScope(
    child: TextFieldTapRegion(
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ..._commandGroups,
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    ),
  );
}

class _MarkdownGroupSurface extends StatelessWidget {
  const _MarkdownGroupSurface();

  @override
  Widget build(BuildContext context) => GlassContainer(
    shape: const LiquidRoundedSuperellipse(borderRadius: 9),
    padding: EdgeInsets.zero,
    quality: GlassQuality.standard,
    settings: DeskMaterials.control(context, quiet: true),
    useOwnLayer: true,
    child: const SizedBox.expand(),
  );
}

/// Compact format glyphs share one quiet group surface. The official transparent
/// glass button retains hover, press and keyboard focus without thirteen pills.
class MarkdownToolButton extends StatelessWidget {
  const MarkdownToolButton({
    required this.command,
    required this.onTap,
    super.key,
  });
  final MarkdownCommand command;
  final VoidCallback? onTap;
  String get label => _describe(command).label;

  @override
  Widget build(BuildContext context) {
    final item = _describe(command);
    final shortcut = switch (command) {
      MarkdownCommand.bold => '⌘B',
      MarkdownCommand.italic => '⌘I',
      MarkdownCommand.link => '⌘K',
      _ => '',
    };
    final symbol = switch (command) {
      MarkdownCommand.heading => 'H₂',
      MarkdownCommand.code => '<>',
      MarkdownCommand.codeBlock => '{ }',
      _ => null,
    };
    final colors = DeskColors(context);
    return sampleEditorBuild(
      kind: UiWorkKind.editorToolBuild,
      child: Tooltip(
        message:
            '${item.label}${shortcut.isEmpty ? '' : '  $shortcut'}\n${item.help}',
        excludeFromSemantics: true,
        waitDuration: const Duration(milliseconds: 350),
        child: Semantics(
          button: true,
          label: '${item.label}，${item.help}',
          enabled: onTap != null,
          onTap: onTap,
          excludeSemantics: true,
          child: IgnorePointer(
            ignoring: onTap == null,
            child: sampleEditorBuild(
              kind: UiWorkKind.editorToolGlassBuild,
              child: GlassButton.custom(
                width: 32,
                height: 32,
                shape: const LiquidRoundedSuperellipse(borderRadius: 7),
                style: GlassButtonStyle.transparent,
                quality: GlassQuality.premium,
                stretch: .15,
                enabled: onTap != null,
                onTap: onTap ?? () {},
                child: symbol == null
                    ? Icon(item.icon, size: 17, color: colors.ink)
                    : Text(
                        symbol,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.ink,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

({String label, String help, IconData icon}) _describe(
  MarkdownCommand command,
) => switch (command) {
  MarkdownCommand.bold => (
    label: '粗体',
    help: '将选中文字加粗',
    icon: CupertinoIcons.bold,
  ),
  MarkdownCommand.italic => (
    label: '斜体',
    help: '将选中文字设为斜体',
    icon: CupertinoIcons.italic,
  ),
  MarkdownCommand.strike => (
    label: '删除线',
    help: '为选中文字添加删除线',
    icon: CupertinoIcons.strikethrough,
  ),
  MarkdownCommand.heading => (
    label: '标题',
    help: '将当前行或选中行设为二级标题',
    icon: CupertinoIcons.textformat_size,
  ),
  MarkdownCommand.quote => (
    label: '引用',
    help: '将当前行或选中行设为引用',
    icon: CupertinoIcons.quote_bubble,
  ),
  MarkdownCommand.bullets => (
    label: '列表',
    help: '将当前行或选中行设为无序列表',
    icon: CupertinoIcons.list_bullet,
  ),
  MarkdownCommand.numbers => (
    label: '有序列表',
    help: '为当前行或选中行添加编号',
    icon: CupertinoIcons.number,
  ),
  MarkdownCommand.code => (
    label: '代码',
    help: '将选中文字设为行内代码',
    icon: CupertinoIcons.chevron_left_slash_chevron_right,
  ),
  MarkdownCommand.link => (
    label: '链接',
    help: '插入链接并填写网址',
    icon: CupertinoIcons.link,
  ),
  MarkdownCommand.image => (
    label: '图片链接',
    help: '插入图片链接，不上传文件',
    icon: CupertinoIcons.photo,
  ),
  MarkdownCommand.codeBlock => (
    label: '代码块',
    help: '插入多行代码块',
    icon: CupertinoIcons.chevron_left_slash_chevron_right,
  ),
  MarkdownCommand.table => (
    label: '表格',
    help: '插入 Markdown 表格',
    icon: CupertinoIcons.table,
  ),
  MarkdownCommand.divider => (
    label: '分割线',
    help: '插入段落分割线',
    icon: CupertinoIcons.minus,
  ),
};
