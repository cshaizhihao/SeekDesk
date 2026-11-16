import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:markdown/markdown.dart' as md;

const _summaryInputLimit = 4096;
const _summaryStructureLimit = 128;
const _summaryCharacterLimit = 240;
final _summaryWhitespace = RegExp(r'\s+');
final _summaryControls = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u200B\u202A-\u202E\u2066-\u2069\uFEFF]',
);
final _summaryCutLink = RegExp(r'(!?)\[([^\]\n]{0,256})\]\([^\)\n]*$');

/// Plain text for a two-line inbox row, independent of message-body rendering.
/// Only a bounded prefix enters Markdown parsing; a separate structural budget
/// also bounds nesting/delimiter work. No input or result is retained globally.
/// No image resolver, platform service, renderer or HTML execution is involved.
String inboxSummary(String raw) {
  var end = 0, structures = 0;
  while (end < raw.length && end < _summaryInputLimit) {
    final unit = raw.codeUnitAt(end);
    if (unit == 10 ||
        unit == 40 ||
        unit == 42 ||
        unit == 60 ||
        unit == 62 ||
        unit == 91 ||
        unit == 95 ||
        unit == 96) {
      if (++structures > _summaryStructureLimit) break;
    }
    end++;
  }
  // Do not give the parser half of a supplementary Unicode scalar.
  if (end > 0 &&
      end < raw.length &&
      raw.codeUnitAt(end - 1) >= 0xd800 &&
      raw.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  final clipped = end < raw.length;
  final source = raw.substring(0, end);
  final document = md.Document(
    encodeHtml: false,
    withDefaultBlockSyntaxes: false,
    extensionSet: md.ExtensionSet.none,
    blockSyntaxes: const [
      md.FencedCodeBlockSyntax(),
      md.EmptyBlockSyntax(),
      md.SetextHeaderSyntax(),
      md.HeaderSyntax(),
      md.CodeBlockSyntax(),
      md.BlockquoteSyntax(),
      md.HorizontalRuleSyntax(),
      md.UnorderedListWithCheckboxSyntax(),
      md.OrderedListWithCheckboxSyntax(),
      md.LinkReferenceDefinitionSyntax(),
      md.TableSyntax(),
      md.ParagraphSyntax(),
    ],
    inlineSyntaxes: [
      _SummaryHTMLSyntax(),
      _SummaryStickerSyntax(),
      md.StrikethroughSyntax(),
      md.EmojiSyntax(),
    ],
  );
  var text = _summaryText(document.parse(source));
  // A clipped destination may no longer be a valid Markdown link. Keep its
  // label rather than exposing the now-unclosed destination in the summary.
  if (clipped) {
    text = text.replaceAllMapped(_summaryCutLink, (match) {
      final label = match[2]!.trim();
      return match[1]!.isNotEmpty
          ? (label.isEmpty ? '[图片]' : '[图片：$label]')
          : (label.isEmpty ? '[链接]' : label);
    });
  }
  text = text
      .replaceAll(_summaryControls, '')
      .replaceAll(_summaryWhitespace, ' ')
      .trim();
  final characters = text.characters;
  final truncated = characters.length > _summaryCharacterLimit;
  return '${characters.take(_summaryCharacterLimit)}${clipped || truncated ? '…' : ''}';
}

const _summaryBlocks = {
  'p',
  'pre',
  'blockquote',
  'li',
  'ul',
  'ol',
  'table',
  'tr',
  'td',
  'th',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'br',
  'hr',
};
const _summaryHiddenHTML = {
  'script',
  'style',
  'iframe',
  'object',
  'template',
  'comment',
};

String _summaryText(List<md.Node> nodes) {
  final output = StringBuffer();
  final stack = <md.Node>[...nodes.reversed];
  String? hiddenHTML;
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is _SummaryHTML) {
      if (hiddenHTML != null) {
        if (node.closing && node.name == hiddenHTML) hiddenHTML = null;
      } else if (!node.closing && _summaryHiddenHTML.contains(node.name)) {
        hiddenHTML = node.name;
      } else if (node.name == 'img' && !node.closing) {
        output.write('[图片]');
      } else if (const {
        'br',
        'hr',
        'p',
        'div',
        'li',
        'tr',
      }.contains(node.name)) {
        output.write(' ');
      }
      continue;
    }
    if (node is md.Text) {
      if (hiddenHTML == null) output.write(node.text);
      continue;
    }
    if (node is! md.Element) continue;
    if (node.tag == 'img') {
      if (hiddenHTML != null) continue;
      final alt = (node.attributes['alt'] ?? '').trim();
      output.write(
        alt == '表情'
            ? '[表情]'
            : alt.isEmpty
            ? '[图片]'
            : '[图片：$alt]',
      );
      continue;
    }
    if (node.tag == 'input') continue;
    final children = node.children ?? const <md.Node>[];
    if (hiddenHTML == null && node.tag == 'a' && children.isEmpty) {
      output.write('[链接]');
    }
    if (_summaryBlocks.contains(node.tag) && hiddenHTML == null) {
      output.write(' ');
      stack.add(md.Text(' '));
    }
    stack.addAll(children.reversed);
  }
  return output.toString();
}

/// Recognize NodeSeek's official text codes without obtaining a sticker pack.
/// Markdown's code parser consumes code spans first, preserving literal codes.
class _SummaryStickerSyntax extends md.InlineSyntax {
  _SummaryStickerSyntax()
    : super(
        r':(?:ac[0-9]{2,4}|(?:yct|xhj)[0-9]{3}|emoji[0-9]{2}):',
        startCharacter: 58,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Text('[表情]'));
    return true;
  }
}

class _SummaryHTML extends md.Element {
  _SummaryHTML(this.name, this.closing) : super.empty('inbox-summary-html');
  final String name;
  final bool closing;
}

/// A linear tag scan, not an HTML renderer. Tags remain distinct AST nodes, so
/// escaped/entity-written tags and code retain their literal text. Suppressed
/// HTML bodies are discarded by the text visitor, including across paragraphs.
class _SummaryHTMLSyntax extends md.InlineSyntax {
  _SummaryHTMLSyntax() : super('<', startCharacter: 60);

  static bool _letter(int value) =>
      (value >= 65 && value <= 90) || (value >= 97 && value <= 122);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final source = parser.source, start = startMatchPos ?? parser.pos;
    if (source.codeUnitAt(start) != 60) return false;
    if (source.startsWith('<!--', start)) {
      final close = source.indexOf('-->', start + 4);
      parser.writeText();
      parser.addNode(_SummaryHTML(close < 0 ? 'comment' : 'ignored', false));
      parser.consume((close < 0 ? source.length : close + 3) - start);
      return true;
    }
    var cursor = start + 1;
    final closing = cursor < source.length && source.codeUnitAt(cursor) == 47;
    if (closing) cursor++;
    final nameStart = cursor;
    while (cursor < source.length) {
      final unit = source.codeUnitAt(cursor);
      if (!_letter(unit) && !(unit >= 48 && unit <= 57) && unit != 45) break;
      cursor++;
    }
    if (cursor == nameStart || !_letter(source.codeUnitAt(nameStart))) {
      return false;
    }
    if (cursor < source.length &&
        !const [9, 10, 13, 32, 47, 62].contains(source.codeUnitAt(cursor))) {
      return false; // Includes autolinks such as <https://example.com>.
    }
    final name = source.substring(nameStart, cursor).toLowerCase();
    int? quote;
    while (cursor < source.length) {
      final unit = source.codeUnitAt(cursor++);
      if (quote != null) {
        if (unit == quote) quote = null;
      } else if (unit == 34 || unit == 39) {
        quote = unit;
      } else if (unit == 62) {
        break;
      } else if (unit == 60) {
        return false;
      }
    }
    parser.writeText();
    parser.addNode(_SummaryHTML(name, closing));
    parser.consume(cursor - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

/// A short list label and an unabridged, local-time accessibility/hover label.
/// Unknown server strings remain readable without claiming a parsed date.
class InboxDateLabel {
  const InboxDateLabel({required this.short, required this.full});

  final String short;
  final String full;
}

InboxDateLabel inboxDateLabel(String raw, {DateTime? now}) {
  final text = raw.trim();
  if (text.isEmpty) return const InboxDateLabel(short: '', full: '');
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    final runes = text.runes;
    return InboxDateLabel(
      short: runes.length <= 16
          ? text
          : '${String.fromCharCodes(runes.take(16))}…',
      full: text,
    );
  }
  final local = parsed.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final today = DateTime(current.year, current.month, current.day);
  final yesterday = DateTime(current.year, current.month, current.day - 1);
  final day = DateTime(local.year, local.month, local.day);
  final short = day == today
      ? clock
      : day == yesterday
      ? '昨天 $clock'
      : local.year == current.year
      ? '${local.month}月${local.day}日'
      : '${local.year}/${two(local.month)}/${two(local.day)}';
  return InboxDateLabel(
    short: short,
    full:
        '${local.year}年${local.month}月${local.day}日 '
        '$clock:${two(local.second)}（本地时间）',
  );
}
