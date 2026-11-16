import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/official_stickers.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_sizing_image.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _source =
    r'"A & B" < > &quot; &#34; &#x1F525; &amp;quot; \&quot; &unknown;';
const _visible = '"A & B" < > " " 🔥 &quot; &quot; &unknown;';
const _hiddenImage = 'https://images.example.test/hidden.png';
const _visibleImage = 'https://images.example.test/visible.png';
const _destination = 'https://example.test/path?a=1&b=2&literal=&amp;';
const _sourceDestination =
    'https://example.test/path?a=1&amp;b=2&amp;literal=&amp;amp;';

OfficialStickerCatalog _catalog() => OfficialStickerCatalog.fromPacks([
  {
    'items': [
      {
        'id': 'ac01',
        'label': 'Hidden fixture',
        'url': _hiddenImage,
        'insertion': ':ac01:',
      },
      {
        'id': 'ac02',
        'label': 'Visible fixture',
        'url': _visibleImage,
        'insertion': ':ac02:',
      },
    ],
  },
]);

class _PreviewNative extends NativeClient {
  final calls = <(String, JsonMap)>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'external.open') return {};
    if (method == 'images.load') {
      return {
        'bytes': base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        'width': 1,
        'height': 1,
      };
    }
    throw StateError('Unexpected preview fixture request: $method');
  }
}

Iterable<md.Element> _elements(Iterable<md.Node> nodes, String tag) sync* {
  for (final node in nodes) {
    if (node is md.Element) {
      if (node.tag == tag) yield node;
      yield* _elements(node.children ?? const [], tag);
    }
  }
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    expect(tester.takeException(), isNull);
  }

  Finder paragraph(String text) => find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == text,
  );

  Offset point(WidgetTester tester, String text) {
    final render = tester.renderObject<RenderParagraph>(paragraph(text));
    final box = render
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first;
    return render.localToGlobal(box.toRect().center);
  }

  for (final (kind, source) in [
    ('paragraph', _source),
    ('heading', '# $_source'),
    ('list', '- $_source'),
    ('quote', '> $_source'),
    ('table', '| Value |\n| --- |\n| $_source |'),
  ]) {
    testWidgets('$kind preview displays native characters decoded once', (
      tester,
    ) async {
      final native = _PreviewNative();
      final state = AppState(client: native);
      await mount(tester, MarkdownDocument(state: state, text: source));
      expect(paragraph(_visible), findsOneWidget);
      expect(native.calls, isEmpty);
      await cleanup(tester, state);
    });
  }

  testWidgets('inline and block code preserve entities and punctuation', (
    tester,
  ) async {
    const code = r'&quot; " <code> &amp; \path :ac01:';
    final native = _PreviewNative();
    final state = AppState(client: native);
    await mount(
      tester,
      MarkdownDocument(
        state: state,
        stickers: _catalog(),
        text: 'Inline `$code`\n\n```text\n$code\n```\n\n    $code',
      ),
    );
    expect(paragraph('Inline $code'), findsOneWidget);
    expect(paragraph('$code\n'), findsNWidgets(2));
    expect(
      _spans(tester.widget<RichText>(paragraph('Inline $code')).text)
          .where((span) => span.style?.fontFamily == 'monospace')
          .map((span) => span.toPlainText()),
      [code],
    );
    expect(
      tester
          .widgetList<RichText>(paragraph('$code\n'))
          .map((text) => (text.text as TextSpan).style?.fontFamily),
      everyElement('monospace'),
    );
    expect(find.byType(SelectableRegion), findsNWidgets(3));
    final nodes = parseDraftMarkdown('Inline `$code`', stickers: _catalog());
    final inline = _elements(nodes, 'code').single;
    expect(inline.textContent, code);
    expect(find.byType(DraftStickerImage), findsNothing);
    expect(native.calls, isEmpty);
    await cleanup(tester, state);
  });

  testWidgets('preview Cmd+A/C copies the displayed text once', (tester) async {
    final native = _PreviewNative();
    final state = AppState(client: native);
    var clipboard = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = stringValue(jsonMap(call.arguments)['text']);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await mount(tester, MarkdownDocument(state: state, text: _source));
    expect(paragraph(_visible), findsOneWidget);
    await tester.tapAt(point(tester, _visible));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, _visible);
    expect(native.calls, isEmpty);
    await cleanup(tester, state);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final (kind, source, visible, destination) in [
    (
      'inline',
      '[**&quot;Reference &amp; more&quot;**]($_sourceDestination)',
      '"Reference & more"',
      _destination,
    ),
    (
      'reference',
      '[**&quot;Reference &amp; more&quot;**][ref]\n\n[ref]: $_sourceDestination',
      '"Reference & more"',
      _destination,
    ),
    (
      'autolink',
      '<https://example.test/raw?a=1&b=2>',
      'https://example.test/raw?a=1&b=2',
      'https://example.test/raw?a=1&b=2',
    ),
  ]) {
    testWidgets('$kind preview link preserves label and exact target', (
      tester,
    ) async {
      final native = _PreviewNative();
      final state = AppState(client: native);
      await mount(tester, MarkdownDocument(state: state, text: source));
      expect(paragraph(visible), findsOneWidget);
      await tester.tapAt(point(tester, visible));
      await tester.pump();
      expect(native.calls, hasLength(1));
      expect(native.calls.single.$1, 'external.open');
      expect(native.calls.single.$2, {'url': destination});
      await cleanup(tester, state);
    });
  }

  testWidgets('preview navigation policy and unsafe-link filtering remain', (
    tester,
  ) async {
    final native = _PreviewNative();
    final state = AppState(client: native);
    await mount(
      tester,
      Column(
        children: [
          MarkdownDocument(
            state: state,
            opensLinks: false,
            text: '[&quot;Preview only&quot;]($_sourceDestination)',
          ),
          MarkdownDocument(
            state: state,
            text: '[&quot;Unsafe&quot;](javascript:alert%281%29)',
          ),
        ],
      ),
    );
    for (final text in ['"Preview only"', '"Unsafe"']) {
      expect(paragraph(text), findsOneWidget);
      await tester.tapAt(point(tester, text));
    }
    await tester.pump();
    expect(native.calls, isEmpty);
    await cleanup(tester, state);
  });

  test('image attributes decode once while exact source labels keep identity', () {
    final source =
        '![&quot;A &amp; B&quot; &amp;quot;]($_sourceDestination "A &amp; B") '
        '![表情]($_sourceDestination) ![&#x8868;&#x60c5;]($_sourceDestination) '
        '![**表情**]($_sourceDestination) ![`表情`]($_sourceDestination) :ac02:';
    final nodes = parseDraftMarkdown(source, stickers: _catalog());
    final images = _elements(nodes, 'img').toList();
    expect(images, hasLength(5));
    expect(images.first.attributes, {
      'alt': '"A & B" &quot;',
      'src': _destination,
      'title': 'A &amp; B',
    });
    expect(images.map(isDraftCustomStickerImage), [
      false,
      true,
      false,
      false,
      false,
    ]);
    expect(
      images.skip(1).map((image) => image.attributes['alt']),
      everyElement('表情'),
    );
    expect(draftStickerOccurrences(nodes).map((item) => item.code), ['ac02']);
  });

  testWidgets('native preview image receives the visible alt and exact URL', (
    tester,
  ) async {
    final native = _PreviewNative();
    final state = AppState(client: native);
    await mount(
      tester,
      MarkdownDocument(
        state: state,
        text: '![&quot;A &amp; B&quot; &amp;quot;]($_sourceDestination)',
      ),
    );
    final sizing = tester.widget<ComposerSizingImage>(
      find.byType(ComposerSizingImage),
    );
    final image = tester.widget<NativeForumImage>(
      find.byType(NativeForumImage),
    );
    expect(sizing.url, _destination);
    expect(image.url, _destination);
    expect(sizing.label, '"A & B" &quot;');
    expect(image.label, '"A & B" &quot;');
    expect(find.byType(DraftStickerImage), findsNothing);
    expect(native.calls.map((call) => (call.$1, call.$2['url'])), [
      ('images.load', _destination),
    ]);
    await cleanup(tester, state);
  });

  testWidgets(
    'catalog hydration keeps text and only loads genuinely visible stickers',
    (tester) async {
      final native = _PreviewNative();
      final state = AppState(client: native);
      final catalog = ValueNotifier(OfficialStickerCatalog.empty);
      final text = ValueNotifier(
        '$_source\n\n前 <code>:ac01: &lt;/code&gt; :ac01:</code> :ac02:',
      );
      await mount(
        tester,
        ValueListenableBuilder(
          valueListenable: catalog,
          builder: (context, value, _) => ValueListenableBuilder(
            valueListenable: text,
            builder: (context, source, _) => DraftStickerImageScope(
              accessRevision: 0,
              active: true,
              child: MarkdownDocument(
                state: state,
                text: source,
                stickers: value,
              ),
            ),
          ),
        ),
      );
      expect(paragraph(_visible), findsOneWidget);
      expect(find.byType(DraftStickerImage), findsNothing);
      expect(native.calls, isEmpty);
      catalog.value = _catalog();
      await tester.pump();
      await tester.pump();
      expect(paragraph(_visible), findsOneWidget);
      expect(find.byType(DraftStickerImage), findsOneWidget);
      expect(native.calls.map((call) => (call.$1, call.$2['url'])), [
        ('images.load', _visibleImage),
      ]);
      text.value = '前 <code> :ac01:';
      await tester.pump();
      expect(find.byType(DraftStickerImage), findsNothing);
      text.value = r'前 \<code> &lt;code&gt; :ac01:';
      await tester.pump();
      await tester.pump();
      expect(find.byType(DraftStickerImage), findsOneWidget);
      expect(native.calls.map((call) => (call.$1, call.$2['url'])), [
        ('images.load', _visibleImage),
        ('images.load', _hiddenImage),
      ]);
      await cleanup(tester, state);
      catalog.dispose();
      text.dispose();
    },
  );
}
