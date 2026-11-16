import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:markdown/markdown.dart' as md;

import '../core/official_stickers.dart';
import '../state/app_state.dart';
import 'composer_sizing_image.dart';
import 'draft_sticker_image.dart';
import 'forum_code_block.dart';
import 'forum_hanging_list.dart';
import 'forum_images.dart';
import 'forum_text_selection.dart';
import 'glass_chrome.dart';

/// Full block Markdown for draft previews; forum content uses the native parsed blocks.
class MarkdownDocument extends StatefulWidget {
  const MarkdownDocument({
    required this.state,
    required this.text,
    this.fontSize = 15,
    this.stickers = OfficialStickerCatalog.empty,
    this.opensLinks = true,
    super.key,
  });
  final AppState state;
  final String text;
  final double fontSize;
  final OfficialStickerCatalog stickers;

  /// Editor previews retain text selection without navigating the workspace.
  final bool opensLinks;
  @override
  State<MarkdownDocument> createState() => _MarkdownDocumentState();

  Widget _node(BuildContext context, md.Node node, {md.Node? omitted}) {
    final colors = DeskColors(context),
        style = DeskTypography.reading(size: fontSize, color: colors.ink);
    if (node is md.Text) return Text(node.text, style: style);
    if (node is! md.Element) return const SizedBox.shrink();
    final children = [
      for (final child in node.children ?? <md.Node>[])
        if (!identical(child, omitted)) child,
    ];
    if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
      final headingStyle = style.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: fontSize + 8 - int.parse(node.tag.substring(1)),
      );
      return InlineNodeText(
        state: state,
        nodes: children,
        style: headingStyle,
        opensLinks: opensLinks,
      );
    }
    switch (node.tag) {
      case 'pre':
        final code = children
            .whereType<md.Element>()
            .where((node) => node.tag == 'code')
            .firstOrNull;
        return ForumCodeBlock(
          state: state,
          text: node.textContent,
          language: code?.attributes['class'] ?? '',
        );
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: colors.accent, width: 3)),
          ),
          child: _flow(context, children, style, omitted: omitted),
        );
      case 'ul':
      case 'ol':
        return _list(context, node, style);
      case 'li':
      case 'div':
      case 'section':
        return _flow(context, children, style, omitted: omitted);
      case 'hr':
        return Container(height: 1, color: colors.line);
      case 'table':
        return _markdownTable(context, node, style);
      case 'img':
        if (isDraftCustomStickerImage(node)) {
          return Align(
            alignment: Alignment.centerLeft,
            child: DraftStickerImage(
              state: state,
              url: node.attributes['src'] ?? '',
              label: '表情',
              code: '',
            ),
          );
        }
        return ComposerSizingImage(
          state: state,
          url: node.attributes['src'] ?? '',
          label: node.attributes['alt'] ?? '',
          isSticker: isDraftCustomStickerImage(node),
          imageBuilder: (url, selection) => NativeForumImage(
            state: state,
            url: url,
            draftSize: selection,
            label: node.attributes['alt'] ?? '',
          ),
        );
      case draftStickerTag:
        return Align(
          alignment: Alignment.centerLeft,
          child: DraftStickerImage(
            state: state,
            url: node.attributes['src'] ?? '',
            label: node.attributes['alt'] ?? '',
            code: node.attributes['code'] ?? '',
          ),
        );
      default:
        return InlineNodeText(
          state: state,
          nodes: children,
          style: style,
          opensLinks: opensLinks,
        );
    }
  }

  static const _blockTags = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'pre',
    'blockquote',
    'ul',
    'ol',
    'li',
    'hr',
    'table',
    'div',
    'section',
  };

  static bool _isBlock(md.Node? node) =>
      node is md.Element && _blockTags.contains(node.tag);

  Widget _flow(
    BuildContext context,
    List<md.Node> nodes,
    TextStyle style, {
    md.Node? omitted,
    bool skipTightSeparators = false,
  }) {
    final blocks = <Widget>[];
    var inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      blocks.add(
        InlineNodeText(
          state: state,
          nodes: inline,
          style: style,
          opensLinks: opensLinks,
        ),
      );
      inline = [];
    }

    md.Node? previous;
    for (final node in nodes) {
      final skipSeparator =
          skipTightSeparators &&
          _isBlock(previous) &&
          node is md.Text &&
          node.text == '\n';
      previous = node;
      if (identical(node, omitted) || skipSeparator) continue;
      if (_isBlock(node)) {
        flush();
        blocks.add(_node(context, node, omitted: omitted));
      } else {
        inline.add(node);
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Padding(
            padding: EdgeInsets.only(bottom: index < blocks.length - 1 ? 8 : 0),
            child: blocks[index],
          ),
      ],
    );
  }

  md.Element? _taskCheckbox(md.Element item) {
    if (!(item.attributes['class'] ?? '')
        .split(' ')
        .contains('task-list-item')) {
      return null;
    }
    var first = item.children?.firstOrNull;
    if (first is md.Element && first.tag == 'p') {
      first = first.children?.firstOrNull;
    }
    return first is md.Element &&
            first.tag == 'input' &&
            first.attributes['type'] == 'checkbox'
        ? first
        : null;
  }

  Widget _list(BuildContext context, md.Element node, TextStyle style) {
    final items = (node.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((child) => child.tag == 'li')
        .toList();
    final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final ordered = node.tag == 'ol';
    final checkboxes = items.map(_taskCheckbox).toList();
    final markers = [
      for (var index = 0; index < items.length; index++)
        if (checkboxes[index] case final checkbox?)
          '${ordered ? '${start + index}. ' : ''}'
              '${checkbox.attributes.containsKey('checked') ? '☑' : '☐'}'
        else
          ordered ? '${start + index}.' : '•',
    ];
    return ForumHangingList(
      style: style,
      markers: markers,
      markerBuilder: (index, marker) {
        final checkbox = checkboxes[index];
        if (checkbox == null) return marker;
        final checked = checkbox.attributes.containsKey('checked');
        return Semantics(
          checked: checked,
          readOnly: true,
          label:
              '${ordered ? '${start + index}. ' : ''}'
              '${checked ? '已完成' : '未完成'}',
          excludeSemantics: true,
          child: marker,
        );
      },
      children: [
        for (var index = 0; index < items.length; index++)
          _flow(
            context,
            items[index].children ?? const <md.Node>[],
            style,
            omitted: checkboxes[index],
            skipTightSeparators:
                checkboxes[index] == null &&
                !(items[index].children ?? const <md.Node>[]).any(
                  (child) => child is md.Element && child.tag == 'p',
                ),
          ),
      ],
    );
  }

  /// Preserve inline semantics in every draft table. Flattening to text and
  /// reparsing would turn code literals into links and lose the preview policy.
  /// Native forum tables keep their established renderer.
  Widget _markdownTable(
    BuildContext context,
    md.Element element,
    TextStyle style,
  ) {
    final rows = <List<md.Element>>[];
    void walk(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'tr') {
        rows.add((node.children ?? []).whereType<md.Element>().toList());
      } else {
        for (final child in node.children ?? <md.Node>[]) {
          walk(child);
        }
      }
    }

    walk(element);
    final columns = rows.fold<int>(
      0,
      (count, row) => math.max(count, row.length),
    );
    if (columns == 0) return const SizedBox.shrink();
    final colors = DeskColors(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final available = bounds.maxWidth.isFinite ? bounds.maxWidth : 640.0;
        final tableWidth = math.max(available, columns * 160.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: SizedBox(
            width: tableWidth,
            child: Table(
              defaultColumnWidth: FixedColumnWidth(tableWidth / columns),
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              border: TableBorder.all(color: colors.line),
              children: [
                for (final row in rows)
                  TableRow(
                    children: [
                      for (var index = 0; index < columns; index++)
                        if (index >= row.length)
                          const SizedBox.shrink()
                        else
                          Container(
                            color: row[index].tag == 'th' ? colors.well : null,
                            padding: const EdgeInsets.all(10),
                            child: InlineNodeText(
                              state: state,
                              nodes: row[index].children ?? const <md.Node>[],
                              opensLinks: opensLinks,
                              style: row[index].tag == 'th'
                                  ? style.copyWith(fontWeight: FontWeight.w600)
                                  : style,
                            ),
                          ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Parsing is local to the current preview. Status, focus and theme changes
/// reuse its tree; new text or a new sticker catalog invalidates it immediately.
class _MarkdownDocumentState extends State<MarkdownDocument> {
  late List<md.Node> _nodes;

  void _parse() =>
      _nodes = parseDraftMarkdown(widget.text, stickers: widget.stickers);

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        !identical(oldWidget.stickers, widget.stickers)) {
      _parse();
    }
  }

  @override
  Widget build(BuildContext context) => ForumTextSelection(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final node in _nodes)
          Padding(
            padding: const EdgeInsets.only(bottom: 13),
            child: widget._node(context, node),
          ),
      ],
    ),
  );
}

class InlineNodeText extends StatefulWidget {
  const InlineNodeText({
    required this.state,
    required this.nodes,
    required this.style,
    this.opensLinks = true,
    super.key,
  });
  final AppState state;
  final List<md.Node> nodes;
  final TextStyle style;
  final bool opensLinks;
  @override
  State<InlineNodeText> createState() => _InlineNodeTextState();
}

class _InlineNodeTextState extends State<InlineNodeText> {
  final links = <TapGestureRecognizer>[];
  void clear() {
    for (final item in links) {
      item.dispose();
    }
    links.clear();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    clear();
    final colors = DeskColors(context);
    InlineSpan span(md.Node node, [TapGestureRecognizer? inheritedLink]) {
      if (node is md.Text) {
        return TextSpan(text: node.text, recognizer: inheritedLink);
      }
      if (node is! md.Element) return const TextSpan();
      final tag = node.tag;
      final href = node.attributes['href'];
      var recognizer = inheritedLink;
      if (widget.opensLinks &&
          tag == 'a' &&
          href != null &&
          AppState.webLink(href) != null) {
        recognizer = TapGestureRecognizer()
          ..onTap = () => widget.state.openLink(href);
        links.add(recognizer);
      }
      if (tag == 'img') {
        if (isDraftCustomStickerImage(node)) {
          return WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SelectionContainer.disabled(
              child: DraftStickerImage(
                state: widget.state,
                url: node.attributes['src'] ?? '',
                label: '表情',
                code: '',
                onTap: recognizer?.onTap,
              ),
            ),
          );
        }
        return WidgetSpan(
          child: SelectionContainer.disabled(
            child: ComposerSizingImage(
              state: widget.state,
              url: node.attributes['src'] ?? '',
              label: node.attributes['alt'] ?? '',
              isSticker: isDraftCustomStickerImage(node),
              imageBuilder: (url, selection) => NativeForumImage(
                state: widget.state,
                url: url,
                draftSize: selection,
                label: node.attributes['alt'] ?? '',
              ),
            ),
          ),
        );
      }
      if (tag == draftStickerTag) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SelectionContainer.disabled(
            child: DraftStickerImage(
              state: widget.state,
              url: node.attributes['src'] ?? '',
              label: node.attributes['alt'] ?? '',
              code: node.attributes['code'] ?? '',
              onTap: recognizer?.onTap,
            ),
          ),
        );
      }
      if (tag == 'input' && node.attributes['type'] == 'checkbox') {
        final checked = node.attributes.containsKey('checked');
        return TextSpan(
          text: checked ? '☑ ' : '☐ ',
          semanticsLabel: checked ? '已完成 ' : '未完成 ',
        );
      }
      return TextSpan(
        text: tag == 'br' ? '\n' : null,
        recognizer: recognizer,
        style: TextStyle(
          fontWeight: tag == 'strong' ? FontWeight.w600 : null,
          fontStyle: tag == 'em' ? FontStyle.italic : null,
          color: tag == 'a' ? colors.accent : null,
          fontFamily: tag == 'code' ? 'monospace' : null,
          backgroundColor: tag == 'code' ? colors.well : null,
          decoration: tag == 'del' ? TextDecoration.lineThrough : null,
        ),
        children: (node.children ?? [])
            .map((child) => span(child, recognizer))
            .toList(),
      );
    }

    return ForumTextSelection(
      child: Text.rich(
        TextSpan(
          style: widget.style,
          children: widget.nodes.map(span).toList(),
        ),
      ),
    );
  }
}
