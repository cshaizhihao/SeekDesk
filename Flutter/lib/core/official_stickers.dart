import 'package:markdown/markdown.dart' as md;

import 'native_client.dart';

const draftStickerTag = 'seekdesk-sticker';

// Keep source-only image semantics outside the Markdown attributes: alt/src,
// serialization and the ordinary img AST remain owned by package:markdown.
final _customImageStickers = Expando<bool>('draft image sticker semantics');

bool isDraftCustomStickerImage(md.Node node) =>
    node is md.Element &&
    node.tag == 'img' &&
    _customImageStickers[node] == true;

/// The native catalog owns the available codes and their image destinations.
/// Dart deliberately does not reconstruct official filenames or directories.
class OfficialSticker {
  const OfficialSticker({
    required this.code,
    required this.label,
    required this.url,
    required this.insertion,
  });

  final String code;
  final String label;
  final String url;
  final String insertion;

  @override
  bool operator ==(Object other) =>
      other is OfficialSticker &&
      code == other.code &&
      label == other.label &&
      url == other.url &&
      insertion == other.insertion;

  @override
  int get hashCode => Object.hash(code, label, url, insertion);
}

class OfficialStickerCatalog {
  const OfficialStickerCatalog._(this.byCode);

  static const empty = OfficialStickerCatalog._({});

  factory OfficialStickerCatalog.fromPacks(List<JsonMap> packs) {
    final result = <String, OfficialSticker>{};
    for (final pack in packs) {
      final items = pack['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final code = item['id'];
        final label = item['label'];
        final url = item['url'];
        final insertion = item['insertion'];
        if (code is! String ||
            _validCode.firstMatch(code)?.end != code.length ||
            label is! String ||
            label.trim().isEmpty ||
            url is! String ||
            !_isHTTPSImageURL(url) ||
            insertion is! String ||
            insertion.trim() != ':$code:') {
          continue;
        }
        // A malformed or repeated pack must not silently replace an earlier
        // valid destination for the same visible shortcode.
        result.putIfAbsent(
          code,
          () => OfficialSticker(
            code: code,
            label: label,
            url: url,
            insertion: insertion,
          ),
        );
      }
    }
    return result.isEmpty
        ? empty
        : OfficialStickerCatalog._(Map.unmodifiable(result));
  }

  final Map<String, OfficialSticker> byCode;
}

const _officialCodePattern =
    r'(?:ac[0-9]{2,4}|(?:yct|xhj)[0-9]{3}|emoji[0-9]{2})';
final _validCode = RegExp('^$_officialCodePattern\$');
final _stickerCandidate = RegExp(':$_officialCodePattern:');
final _invalidURLCharacters = RegExp(r'[\s\x00-\x1f\x7f\\]');

bool _isHTTPSImageURL(String value) {
  if (value.isEmpty ||
      value.length > 4096 ||
      _invalidURLCharacters.hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  try {
    return !uri.hasPort || (uri.port > 0 && uri.port <= 65535);
  } on FormatException {
    return false;
  }
}

/// This is only a cheap scheduling gate. The Markdown AST, not this scan,
/// determines whether a candidate is visible text, code, an image alt, etc.
bool hasDraftStickerCandidates(String text) => _stickerCandidate.hasMatch(text);

List<md.Node> parseDraftMarkdown(
  String text, {
  OfficialStickerCatalog stickers = OfficialStickerCatalog.empty,
}) {
  final enabled = stickers.byCode.isNotEmpty && hasDraftStickerCandidates(text);
  final nodes = md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet([
      for (final syntax in md.ExtensionSet.gitHubWeb.blockSyntaxes)
        if (syntax is md.FootnoteDefSyntax)
          const _DraftFootnoteDefSyntax()
        else
          syntax,
      if (enabled) _DraftHTMLBlockSyntax(),
    ], md.ExtensionSet.gitHubWeb.inlineSyntaxes),
    inlineSyntaxes: [
      _DraftImageSyntax(),
      if (enabled) ...[
        _DraftHTMLSyntax(),
        _DraftHTMLBoundarySyntax(),
        _OfficialStickerSyntax(stickers),
      ],
    ],
  ).parse(text);
  if (enabled) _HTMLCodeGuard().visit(nodes);
  return nodes;
}

class _DraftFootnoteDefSyntax extends md.FootnoteDefSyntax {
  const _DraftFootnoteDefSyntax();

  @override
  md.Node? parse(md.BlockParser parser) {
    final node = super.parse(parser);
    if (node is md.Element) {
      final children = node.children;
      final last = children?.lastOrNull;
      if (last is md.Element && last.tag != 'p') {
        children!.add(md.Element('p', <md.Node>[]));
      }
    }
    return node;
  }
}

/// Native MarkdownPreviewDocument.assets compares the unescaped source label,
/// not CommonMark's flattened alt text. Strong/code/entity labels that render
/// as "表情" must remain ordinary images with their native sizing controls.
class _DraftImageSyntax extends md.ImageSyntax {
  static final _escapedPunctuation = RegExp(
    r'''\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_\x60{|}~])''',
  );

  @override
  Iterable<md.Node>? close(
    md.InlineParser parser,
    covariant md.SimpleDelimiter opener,
    md.Delimiter? closer, {
    String? tag,
    required List<md.Node> Function() getChildren,
  }) {
    final sourceLabel = parser.source.substring(opener.endPos, parser.pos);
    final result = super.close(
      parser,
      opener,
      closer,
      tag: tag,
      getChildren: getChildren,
    );
    if (result == null) return null;
    final label = sourceLabel.replaceAllMapped(
      _escapedPunctuation,
      (match) => match[1]!,
    );
    for (final node in result) {
      if (node is md.Element && node.tag == 'img') {
        _customImageStickers[node] = label == '表情';
      }
    }
    return result;
  }
}

/// Collect only nodes created from catalog entries in the final visible AST.
/// ImageSyntax consumes its inline children to form alt text, so collecting
/// during InlineSyntax.onMatch would incorrectly load image-alt shortcodes.
List<OfficialSticker> draftStickerOccurrences(List<md.Node> nodes) {
  final result = <OfficialSticker>[];
  void visit(Iterable<md.Node> children) {
    for (final node in children) {
      if (node is _OfficialStickerNode) {
        result.add(node.sticker);
      } else if (node is md.Element &&
          node.tag != 'code' &&
          node.tag != 'pre' &&
          node.tag != 'img') {
        visit(node.children ?? const []);
      }
    }
  }

  visit(nodes);
  return List.unmodifiable(result);
}

class _OfficialStickerNode extends md.Element {
  _OfficialStickerNode(this.sticker)
    : super.text(draftStickerTag, ':${sticker.code}:') {
    attributes.addAll({
      'src': sticker.url,
      'alt': sticker.label,
      'code': sticker.code,
    });
  }

  final OfficialSticker sticker;
}

class _OfficialStickerSyntax extends md.InlineSyntax {
  _OfficialStickerSyntax(this.catalog)
    : super(
        ':(${catalog.byCode.keys.map(RegExp.escape).join('|')}):',
        startCharacter: 0x3a,
      );

  final OfficialStickerCatalog catalog;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final sticker = catalog.byCode[match[1]!];
    parser.addNode(
      sticker == null ? md.Text(match[0]!) : _OfficialStickerNode(sticker),
    );
    // Only catalog codes match, leaving standard emoji to GFM. Consume even a
    // defensive lookup miss: returning false without advancing would make
    // markdown's InlineParser retry this position forever.
    return true;
  }
}

// Keep complete HTML tokens opaque before attempting shortcodes. The upstream
// inline comment expression excludes some otherwise valid comments containing
// angle brackets, which would allow their hidden contents into the sticker AST.
const _htmlTokenPattern =
    r'<!--[\s\S]*?(?:-->|(?![\s\S]))'
    r'|<!\[CDATA\[[\s\S]*?(?:\]\]>|(?![\s\S]))'
    r'|<\?[\s\S]*?(?:\?>|(?![\s\S]))'
    r'|<![a-z][^>]*>'
    r'|<[a-z][a-z0-9-]*'
    r'(?:\s+[a-z_:][a-z0-9._:-]*'
    r'''(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*'''
    r'\s*/?>'
    r'|</[a-z][a-z0-9-]*\s*>';

final _htmlTokens = RegExp(_htmlTokenPattern, caseSensitive: false);
final _htmlTagName = RegExp(r'^<(\/?)([a-z][a-z0-9-]*)', caseSensitive: false);

class _DraftHTMLSyntax extends md.InlineSyntax {
  _DraftHTMLSyntax()
    : super(_htmlTokenPattern, startCharacter: 0x3c, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_DraftHTMLNode(match[0]!));
    return true;
  }
}

class _DraftHTMLBlockSyntax extends md.HtmlBlockSyntax {
  @override
  md.Node parse(md.BlockParser parser) =>
      _DraftHTMLNode(super.parse(parser).textContent);
}

class _DraftHTMLNode implements md.Node {
  _DraftHTMLNode(this.textContent);

  @override
  final String textContent;

  @override
  void accept(md.NodeVisitor visitor) =>
      visitor.visitText(md.Text(textContent));
}

class _DraftHTMLBoundary implements md.Node {
  _DraftHTMLBoundary(this.closes);

  final String closes;

  @override
  String get textContent => '>';

  @override
  void accept(md.NodeVisitor visitor) =>
      visitor.visitText(md.Text(textContent));
}

class _DraftHTMLBoundarySyntax extends md.InlineSyntax {
  _DraftHTMLBoundarySyntax() : super('>', startCharacter: 0x3e);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    for (final close in ['-->', ']]>', '?>']) {
      final start = match.end - close.length;
      if (start < 0 || !parser.source.startsWith(close, start)) continue;
      var escapes = 0;
      for (
        var index = start - 1;
        index >= 0 && parser.source.codeUnitAt(index) == 0x5c;
        index--
      ) {
        escapes++;
      }
      if (escapes.isOdd) continue;
      parser.addNode(_DraftHTMLBoundary(close));
      return true;
    }
    parser.addNode(md.Text('>'));
    return true;
  }
}

class _HTMLCodeGuard {
  static const _protectedTags = {
    'code',
    'pre',
    'kbd',
    'samp',
    'script',
    'style',
    'textarea',
    'xmp',
    'plaintext',
  };
  static const _rawTextTags = {
    'script',
    'style',
    'textarea',
    'xmp',
    'plaintext',
  };
  static final _rawTextEnds = {
    for (final tag in _rawTextTags)
      tag: RegExp('</$tag\\s*>', caseSensitive: false),
  };

  final _tags = <String>[];
  String? _opaqueEnd;

  bool get _protected => _tags.isNotEmpty || _opaqueEnd != null;

  void visit(List<md.Node> nodes) {
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      if (node is _OfficialStickerNode) {
        if (_protected) nodes[index] = md.Text(node.textContent);
      } else if (node is _DraftHTMLNode) {
        _readHTML(node.textContent);
        nodes[index] = md.Text(node.textContent);
      } else if (node is _DraftHTMLBoundary) {
        if (_opaqueEnd == node.closes) _opaqueEnd = null;
        nodes[index] = md.Text(node.textContent);
      } else if (node is md.Element &&
          node.tag != 'code' &&
          node.tag != 'pre' &&
          node.tag != 'img') {
        visit(node.children ?? const []);
      }
    }
  }

  void _readHTML(String text) {
    var offset = 0;
    while (offset < text.length) {
      final opaqueEnd = _opaqueEnd;
      if (opaqueEnd != null) {
        final close = text.indexOf(opaqueEnd, offset);
        if (close < 0) return;
        offset = close + opaqueEnd.length;
        _opaqueEnd = null;
        continue;
      }
      final rawTag = _tags.isNotEmpty && _rawTextTags.contains(_tags.last)
          ? _tags.last
          : null;
      if (rawTag != null) {
        if (rawTag == 'plaintext') return;
        final closes = _rawTextEnds[rawTag]!.allMatches(text, offset).iterator;
        if (!closes.moveNext()) return;
        offset = closes.current.end;
        _tags.removeLast();
        continue;
      }
      final matches = _htmlTokens.allMatches(text, offset).iterator;
      if (!matches.moveNext()) return;
      final match = matches.current;
      final token = match[0]!;
      offset = match.end;
      if (token.startsWith('<!--')) {
        if (!token.endsWith('-->')) _opaqueEnd = '-->';
        continue;
      }
      if (token.toUpperCase().startsWith('<![CDATA[')) {
        if (!token.endsWith(']]>')) _opaqueEnd = ']]>';
        continue;
      }
      if (token.startsWith('<?')) {
        if (!token.endsWith('?>')) _opaqueEnd = '?>';
        continue;
      }
      final tagMatch = _htmlTagName.firstMatch(token);
      if (tagMatch == null) continue;
      final tag = tagMatch[2]!.toLowerCase();
      if (!_protectedTags.contains(tag)) continue;
      if (tagMatch[1] == '/') {
        final index = _tags.lastIndexOf(tag);
        if (index >= 0) _tags.removeRange(index, _tags.length);
      } else if (!token.endsWith('/>')) {
        _tags.add(tag);
      }
    }
  }
}
