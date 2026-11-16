import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'forum_code_block.dart';
import 'forum_hanging_list.dart';
import 'forum_images.dart';
import 'forum_terminal_report.dart';
import 'forum_text_selection.dart';
import 'glass_chrome.dart';
import 'reader_content_layout.dart';

// Compatibility exports keep callers independent of renderer organization.
export 'forum_images.dart';
export 'forum_terminal_report.dart';
export 'forum_text_selection.dart';
export 'markdown_document.dart';
export 'native_image_viewer.dart';

class ForumBlocks extends StatelessWidget {
  const ForumBlocks({
    required this.state,
    required this.blocks,
    this.fontSize = 15,
    this.reportKind,
    this.blockSpacing = 13,
    this.trailingSpacing = true,
    super.key,
  });
  final AppState state;
  final List<JsonMap> blocks;
  final double fontSize;
  final String? reportKind;
  final double blockSpacing;
  final bool trailingSpacing;
  @override
  Widget build(BuildContext context) => ForumTextSelection(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Padding(
            padding: EdgeInsets.only(
              bottom: trailingSpacing || index < blocks.length - 1
                  ? blockSpacing
                  : 0,
            ),
            child: _markedBlock(context, blocks[index], index),
          ),
      ],
    ),
  );

  Widget _markedBlock(BuildContext context, JsonMap block, int index) {
    final child = _block(context, block, index);
    // Nested ForumBlocks register their own leaves. Marking their containers
    // as well would select the whole report instead of the visible passage.
    return switch (stringValue(block['kind'])) {
      'tabs' || 'disclosure' || 'list' => child,
      'image' ||
      'sticker' ||
      'terminal' => ReaderContentBlock(variableSize: true, child: child),
      _ => ReaderContentBlock(child: child),
    };
  }

  Widget _block(BuildContext context, JsonMap block, int index) {
    final colors = DeskColors(context),
        kind = stringValue(block['kind']),
        text = stringValue(block['text']);
    final size = DeskTypography.reading(size: fontSize, color: colors.ink);
    switch (kind) {
      case 'list':
        final items = jsonItems(block['items']);
        return ForumHangingList(
          style: size,
          markers: [for (final item in items) stringValue(item['marker'])],
          markerBuilder: (index, marker) =>
              jsonItems(items[index]['blocks']).isEmpty
              ? ReaderContentBlock(child: marker)
              : marker,
          children: [
            for (final item in items)
              ForumBlocks(
                state: state,
                blocks: jsonItems(item['blocks']),
                fontSize: fontSize,
                reportKind: reportKind,
                blockSpacing: 8,
                trailingSpacing: false,
              ),
          ],
        );
      case 'image':
      case 'sticker':
        return SelectionContainer.disabled(
          child: NativeForumImage(
            key: ValueKey('$index:${block['url']}'),
            state: state,
            url: stringValue(block['url']),
            label: text,
            size: jsonMap(block['imageSize']),
            sticker: kind == 'sticker',
            reportKind: reportKind,
          ),
        );
      case 'rule':
        return Container(
          height: 1,
          color: colors.line,
          margin: const EdgeInsets.symmetric(vertical: 10),
        );
      case 'heading':
        return InlineMarkdown(
          text: text,
          state: state,
          style: size.copyWith(
            fontSize: fontSize + 6,
            fontWeight: FontWeight.w600,
          ),
        );
      case 'quote':
      case 'notice':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: .05),
            border: Border(
              left: BorderSide(
                color: colors.accent.withValues(alpha: .45),
                width: 3,
              ),
            ),
          ),
          child: kind == 'notice'
              ? Text(text, style: size)
              : InlineMarkdown(text: text, state: state, style: size),
        );
      case 'code':
        return ForumCodeBlock(
          state: state,
          text: text,
          language: stringValue(block['language']),
        );
      case 'terminal':
        return SelectionContainer.disabled(
          child: NativeTerminalReport(
            state: state,
            rows: jsonItemsInRows(block['terminal']),
            text: text,
          ),
        );
      case 'terminalUnavailable':
        return Text(
          text.isEmpty ? '终端内容暂时无法显示' : text,
          style: size.copyWith(color: colors.secondary),
        );
      case 'table':
        final rows = (block['rows'] is List ? block['rows'] as List : const [])
            .whereType<List>()
            .map((row) => row.map(stringValue).toList(growable: false))
            .toList(growable: false);
        if (rows.isEmpty) return const SizedBox.shrink();
        final columns = rows.fold<int>(
          0,
          (value, row) => math.max(value, row.length),
        );
        if (columns == 0) return const SizedBox.shrink();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: colors.line),
            children: [
              for (var row = 0; row < rows.length; row++)
                TableRow(
                  decoration: BoxDecoration(
                    color: row == 0 ? colors.well : const Color(0x00000000),
                  ),
                  children: [
                    for (var column = 0; column < columns; column++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 9,
                        ),
                        child: Text(
                          column < rows[row].length ? rows[row][column] : '',
                          style: size.copyWith(
                            fontSize: 13,
                            fontWeight: row == 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      case 'tabs':
        return BlockTabs(
          state: state,
          tabs: jsonItems(block['tabs']),
          fontSize: fontSize,
          reportKind: reportKind,
        );
      case 'disclosure':
        return BlockDisclosure(
          state: state,
          block: block,
          fontSize: fontSize,
          reportKind: reportKind,
        );
      default:
        return InlineMarkdown(text: text, state: state, style: size);
    }
  }

  static List<List<JsonMap>> jsonItemsInRows(Object? raw) => raw is List
      ? raw
            .whereType<List>()
            .map((row) => row.map(jsonMap).toList(growable: false))
            .toList(growable: false)
      : const [];
}

bool _blocksHaveTerminal(
  List<JsonMap> blocks, {
  bool includeUnavailable = true,
}) => blocks.any(
  (block) =>
      block['kind'] == 'terminal' ||
      (includeUnavailable && block['kind'] == 'terminalUnavailable') ||
      [...jsonItems(block['items']), ...jsonItems(block['tabs'])].any(
        (item) => _blocksHaveTerminal(
          jsonItems(item['blocks']),
          includeUnavailable: includeUnavailable,
        ),
      ),
);

class InlineMarkdown extends StatefulWidget {
  const InlineMarkdown({
    required this.text,
    required this.state,
    required this.style,
    super.key,
  });
  final String text;
  final AppState state;
  final TextStyle style;
  @override
  State<InlineMarkdown> createState() => _InlineMarkdownState();
}

class _InlineMarkdownState extends State<InlineMarkdown> {
  final List<TapGestureRecognizer> _links = [];
  List<InlineSpan>? _cached;
  void _clear() {
    for (final recognizer in _links) {
      recognizer.dispose();
    }
    _links.clear();
    _cached = null;
  }

  @override
  void didUpdateWidget(InlineMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  InlineSpan _span(md.Node node, [TapGestureRecognizer? inheritedLink]) {
    if (node is md.Text) {
      return TextSpan(text: node.text, recognizer: inheritedLink);
    }
    if (node is! md.Element) return const TextSpan();
    final colors = DeskColors(context);
    if (node.tag == 'br') return const TextSpan(text: '\n');
    if (node.tag == 'img') {
      return TextSpan(
        text: node.attributes['alt'] ?? '图片',
        recognizer: inheritedLink,
      );
    }
    TextStyle? style;
    TapGestureRecognizer? tap = inheritedLink;
    switch (node.tag) {
      case 'strong':
        style = const TextStyle(fontWeight: FontWeight.w600);
        break;
      case 'em':
        style = const TextStyle(fontStyle: FontStyle.italic);
        break;
      case 'del':
        style = const TextStyle(decoration: TextDecoration.lineThrough);
        break;
      case 'code':
        style = TextStyle(
          fontFamily: 'monospace',
          fontSize: widget.style.fontSize! * .9,
          backgroundColor: colors.well,
        );
        break;
      case 'a':
        final href = node.attributes['href'] ?? '';
        if (AppState.webLink(href) == null) break;
        style = TextStyle(
          color: colors.accent,
          decoration: TextDecoration.underline,
          decorationColor: colors.accent.withValues(alpha: .3),
        );
        tap = TapGestureRecognizer()..onTap = () => widget.state.openLink(href);
        _links.add(tap);
        break;
    }
    return TextSpan(
      style: style,
      // TextSpan recognizers do not bubble from a parent to its children. Put
      // the link on each text leaf, including nested emphasis, for both pointer
      // hit testing and the virtual accessibility link nodes.
      children: (node.children ?? [])
          .map((child) => _span(child, tap))
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _cached ??= md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    ).parseInline(widget.text).map(_span).toList();
    return ForumTextSelection(
      child: Text.rich(TextSpan(style: widget.style, children: _cached)),
    );
  }
}

class BlockTabs extends StatefulWidget {
  const BlockTabs({
    required this.state,
    required this.tabs,
    required this.fontSize,
    this.reportKind,
    super.key,
  });
  final AppState state;
  final List<JsonMap> tabs;
  final String? reportKind;
  final double fontSize;
  @override
  State<BlockTabs> createState() => _BlockTabsState();
}

class _BlockTabsState extends State<BlockTabs> {
  int selected = 0;
  @override
  Widget build(BuildContext context) {
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    selected = selected.clamp(0, widget.tabs.length - 1);
    final hasTerminal = widget.tabs.any(
      (tab) => _blocksHaveTerminal(jsonItems(tab['blocks'])),
    );
    final labels = widget.tabs
        .map((tab) => stringValue(tab['label']))
        .join(' ');
    final reportKind =
        widget.reportKind ??
        (hasTerminal ||
                RegExp(
                  r'基本信息|IP质量|网络质量|回程路由|NodeQuality|\bNQ\b',
                  caseSensitive: false,
                ).hasMatch(labels)
            ? 'nq'
            : RegExp(
                r'回程|路由|测速|互联|质量|IPv[46]|TCP|UDP',
                caseSensitive: false,
              ).hasMatch(labels)
            ? 'tq'
            : null);
    final scale = reportKind == null
        ? 100.0
        : numberValue(
            widget.state.domain(
              'settings',
            )['workspace.${reportKind}ReportScale'],
            100,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.tabs.length > 1)
          SelectionContainer.disabled(
            child: GlassSegmentedControl.scrollable(
              segments: [
                for (final tab in widget.tabs)
                  GlassSegment(label: stringValue(tab['label'])),
              ],
              selectedIndex: selected,
              onSegmentSelected: (value) {
                if (value == selected ||
                    value < 0 ||
                    value >= widget.tabs.length) {
                  return;
                }
                ReaderContentLayoutScope.prepareChange(context);
                setState(() => selected = value);
              },
              height: 35,
              quality: GlassQuality.premium,
            ),
          ),
        if (reportKind != null &&
            !_blocksHaveTerminal(
              jsonItems(widget.tabs[selected]['blocks']),
              includeUnavailable: false,
            ))
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DeskIcon(
                    '缩小报告',
                    CupertinoIcons.minus,
                    () => _scale(reportKind, scale - 10),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '${scale.round()}%',
                      style: TextStyle(
                        color: DeskColors(context).secondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  DeskIcon(
                    '放大报告',
                    CupertinoIcons.plus,
                    () => _scale(reportKind, scale + 10),
                  ),
                  const SizedBox(width: 6),
                  DeskButton(
                    '重置',
                    width: 64,
                    height: 31,
                    onTap: () => _scale(reportKind, 100),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        ForumBlocks(
          key: ValueKey('tab:$selected:${widget.tabs[selected]['label']}'),
          state: widget.state,
          blocks: jsonItems(widget.tabs[selected]['blocks']),
          fontSize: widget.fontSize,
          reportKind: reportKind,
        ),
      ],
    );
  }

  void _scale(String kind, double value) {
    widget.state.act('settings.update', {
      'key': 'workspace.${kind}ReportScale',
      'value': value.clamp(kind == 'nq' ? 25 : 50, 200),
    }, 'settings');
  }
}

class BlockDisclosure extends StatefulWidget {
  const BlockDisclosure({
    required this.state,
    required this.block,
    required this.fontSize,
    this.reportKind,
    super.key,
  });
  final AppState state;
  final JsonMap block;
  final double fontSize;
  final String? reportKind;
  @override
  State<BlockDisclosure> createState() => _BlockDisclosureState();
}

class _BlockDisclosureState extends State<BlockDisclosure> {
  bool open = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SelectionContainer.disabled(
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 6),
          alignment: Alignment.centerLeft,
          onPressed: () {
            ReaderContentLayoutScope.prepareChange(context);
            setState(() => open = !open);
          },
          child: Row(
            children: [
              Icon(
                open
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_right,
                size: 13,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stringValue(widget.block['text'], '展开内容'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
      if (open)
        ForumBlocks(
          state: widget.state,
          blocks: jsonItems(
            widget.block['blocks'] ??
                (jsonItems(widget.block['tabs']).firstOrNull ??
                    const <String, dynamic>{})['blocks'],
          ),
          fontSize: widget.fontSize,
          reportKind: widget.reportKind,
        ),
    ],
  );
}
