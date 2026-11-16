import 'dart:async';
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
import 'package:seekdesk_flutter/widgets/forum_code_block.dart';

class _ListPreviewNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final image = Completer<JsonMap>();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'external.open' || method == 'images.release') return {};
    if (method == 'images.load') return image.future;
    throw StateError('Unexpected list preview request: $method');
  }
}

Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

Offset _point(WidgetTester tester, String text) {
  final render = tester.renderObject<RenderParagraph>(_paragraph(text));
  final box = render
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .first;
  return render.localToGlobal(box.toRect().center);
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
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

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  String text, {
  double width = 760,
  double fontSize = 15,
  double scale = 1,
  bool opensLinks = true,
  OfficialStickerCatalog stickers = OfficialStickerCatalog.empty,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(fontFamily: 'monospace'),
                    child: MarkdownDocument(
                      state: state,
                      text: text,
                      fontSize: fontSize,
                      opensLinks: opensLinks,
                      stickers: stickers,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

void main() {
  for (final start in [0, 3, 9, 999999999]) {
    testWidgets('ordered preview starts at $start and follows AST sequence', (
      tester,
    ) async {
      final native = _ListPreviewNative();
      final state = AppState(client: native);
      await _mount(tester, state, '$start. First\n2. Next');
      expect(_paragraph('$start. '), findsOneWidget);
      expect(_paragraph('${start + 1}. '), findsOneWidget);
      expect(
        tester.getTopLeft(_paragraph('First')).dx,
        tester.getTopLeft(_paragraph('Next')).dx,
      );
      expect(
        tester.getTopLeft(_paragraph('$start. ')).dy,
        tester.getTopLeft(_paragraph('First')).dy,
      );
      expect(native.calls, isEmpty);
      await _cleanup(tester, state);
    });
  }

  testWidgets('nested blocks return to parent indentation and copy in order', (
    tester,
  ) async {
    final native = _ListPreviewNative();
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mount(
      tester,
      state,
      '- Parent\n\n  3. Inner first\n     - Deep child\n  4. Inner second'
      '\n\n  Parent continuation\n- Sibling',
    );
    double x(String text) => tester.getTopLeft(_paragraph(text)).dx;
    expect(x('Inner first'), greaterThan(x('Parent')));
    expect(x('Deep child'), greaterThan(x('Inner first')));
    expect(x('Parent continuation'), x('Parent'));
    expect(x('Sibling'), x('Parent'));
    expect(find.byType(SelectableRegion), findsOneWidget);
    await tester.tapAt(_point(tester, 'Parent'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, contains('• Parent'));
    expect(clipboard, contains('3. Inner first'));
    expect(clipboard, contains('• Deep child'));
    expect(clipboard, contains('4. Inner second'));
    final ordered = [
      'Parent',
      'Inner first',
      'Deep child',
      'Inner second',
      'Parent continuation',
      'Sibling',
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(
        clipboard.indexOf(ordered[i]),
        greaterThan(clipboard.indexOf(ordered[i - 1])),
      );
    }
    expect(native.calls, isEmpty);
    await _cleanup(tester, state);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('loose paragraphs remain separate without repeated tail gaps', (
    tester,
  ) async {
    final state = AppState(client: _ListPreviewNative());
    await _mount(tester, state, '- Alpha\n\n  Beta\n\n- Gamma');
    final alpha = tester.getRect(_paragraph('Alpha'));
    final beta = tester.getRect(_paragraph('Beta'));
    final gamma = tester.getRect(_paragraph('Gamma'));
    expect(beta.left, alpha.left);
    expect(gamma.left, alpha.left);
    expect(beta.top - alpha.bottom, closeTo(8, .01));
    expect(gamma.top - beta.bottom, closeTo(8, .01));
    await _cleanup(tester, state);
  });

  for (final (source, visible) in [
    ('- ## Heading\n  Continuation', 'Continuation'),
    ('- ## Heading\n  First\n  Second', 'First\nSecond'),
    ('- ## Heading\n  &#10;**Continuation**', '\nContinuation'),
    ('- [x] ## Heading\n  &#10;**Continuation**', '\nContinuation'),
    ('- ## Heading\n  \\\n  Continuation', '\nContinuation'),
  ]) {
    testWidgets('block separator preserves source breaks: $source', (
      tester,
    ) async {
      final state = AppState(client: _ListPreviewNative());
      await _mount(tester, state, source);
      expect(_paragraph('Heading'), findsOneWidget);
      expect(_paragraph(visible), findsOneWidget);
      expect(
        tester.getTopLeft(_paragraph(visible)).dy -
            tester.getBottomLeft(_paragraph('Heading')).dy,
        closeTo(8, .01),
      );
      await _cleanup(tester, state);
    });
  }

  testWidgets('empty items and changed list delimiters keep separate starts', (
    tester,
  ) async {
    final state = AppState(client: _ListPreviewNative());
    await _mount(
      tester,
      state,
      '-\n\n3.\n\nBreak\n\n7. Period\n9) Parenthesis',
    );
    for (final marker in ['• ', '3. ', '7. ', '9. ']) {
      expect(_paragraph(marker), findsOneWidget);
      expect(tester.getSize(_paragraph(marker)).height, greaterThan(0));
    }
    expect(_paragraph('Period'), findsOneWidget);
    expect(_paragraph('Parenthesis'), findsOneWidget);
    await _cleanup(tester, state);
  });

  testWidgets('task copy contains state once and code remains independent', (
    tester,
  ) async {
    final native = _ListPreviewNative();
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mount(
      tester,
      state,
      '7. [x] Done\n8. [ ] Todo\n   - [X] Nested\n\n'
      '9. [ ] ```text\n   independent code\n   ```',
    );
    expect(_paragraph('9. ☐ '), findsOneWidget);
    expect(
      tester.getTopLeft(_paragraph('9. ☐ ')).dy,
      tester.getTopLeft(find.byType(ForumCodeBlock)).dy,
    );
    expect(find.byType(SelectableRegion), findsNWidgets(2));
    await tester.tapAt(_point(tester, 'Done'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, contains('7. ☑ Done'));
    expect(clipboard, contains('8. ☐ Todo'));
    expect(clipboard, contains('☑ Nested'));
    expect(clipboard.split('☑'), hasLength(3));
    expect(clipboard, isNot(contains('independent code')));
    expect(clipboard, isNot(contains('\uFFFC')));
    expect(native.calls, isEmpty);
    await _cleanup(tester, state);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('narrow scaled lists remeasure markers and preserve content', (
    tester,
  ) async {
    final state = AppState(client: _ListPreviewNative());
    const source = '999999999. Wide first marker\n1. Following item';
    await _mount(tester, state, source);
    final originalX = tester.getTopLeft(_paragraph('Following item')).dx;
    await _mount(tester, state, source, width: 260, fontSize: 20, scale: 1.6);
    final first = tester.getRect(_paragraph('Wide first marker'));
    final next = tester.getRect(_paragraph('Following item'));
    expect(first.left, next.left);
    expect(next.left, isNot(originalX));
    expect(first.right, lessThanOrEqualTo(260));
    expect(first.left, lessThanOrEqualTo(104));
    final marker = tester.renderObject<RenderParagraph>(
      _paragraph('1000000000. '),
    );
    expect(
      marker.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 12),
      ),
      hasLength(1),
    );
    expect(marker.didExceedMaxLines, isFalse);
    await _cleanup(tester, state);
  });

  testWidgets('tasks retain state, numbers and readonly semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final native = _ListPreviewNative();
    final state = AppState(client: native);
    const source =
        '- [ ] Todo\n- [x] Done\n- Plain\n'
        '\n7. [X] Numbered done\n8. [ ] Numbered todo';
    await _mount(tester, state, source);
    for (final marker in ['☐ ', '☑ ', '• ', '7. ☑ ', '8. ☐ ']) {
      expect(_paragraph(marker), findsOneWidget);
    }
    final checked = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.checked != null,
    );
    expect(checked, findsNWidgets(4));
    expect(
      tester.widgetList<Semantics>(checked).map((w) => w.properties.checked),
      [false, true, true, false],
    );
    for (final widget in tester.widgetList<Semantics>(checked)) {
      expect(widget.properties.onTap, isNull);
    }
    await tester.tapAt(_point(tester, '☐ '));
    await tester.pump();
    expect(_paragraph('☐ '), findsOneWidget);
    expect(
      tester.widget<MarkdownDocument>(find.byType(MarkdownDocument)).text,
      source,
    );
    expect(native.calls, isEmpty);
    await _cleanup(tester, state);
    semantics.dispose();
  });

  testWidgets('loose nested and empty tasks extract only their own marker', (
    tester,
  ) async {
    final state = AppState(client: _ListPreviewNative());
    await _mount(
      tester,
      state,
      '- Parent\n\n  - [x] Nested\n\n    Detail\n'
      '\n- [ ] \n- [ ]\n- `[x]` literal\n- [x] # Heading',
    );
    expect(_paragraph('☑ '), findsNWidgets(2));
    expect(_paragraph('☐ '), findsOneWidget);
    expect(_paragraph('• '), findsNWidgets(3));
    expect(_paragraph('[ ]'), findsOneWidget);
    expect(_paragraph('[x] literal'), findsOneWidget);
    expect(_paragraph('Nested'), findsOneWidget);
    expect(_paragraph('Detail'), findsOneWidget);
    expect(
      tester.getTopLeft(_paragraph('Detail')).dx,
      tester.getTopLeft(_paragraph('Nested')).dx,
    );
    expect(
      tester.getTopLeft(_paragraph('☑ ').last).dy,
      tester.getTopLeft(_paragraph('Heading')).dy,
    );
    await _cleanup(tester, state);
  });

  for (final opensLinks in [false, true]) {
    testWidgets('nested inline semantics retain link policy $opensLinks', (
      tester,
    ) async {
      final native = _ListPreviewNative();
      final state = AppState(client: native);
      await _mount(
        tester,
        state,
        '- Parent\n  - [**Reference**](https://example.test/?a=1&amp;b=2) '
        '&amp;quot; `[fake](https://wrong.test/)`',
        opensLinks: opensLinks,
      );
      const visible = 'Reference &quot; [fake](https://wrong.test/)';
      final paragraph = tester.widget<RichText>(_paragraph(visible));
      expect(
        _spans(paragraph.text)
            .where((span) => span.style?.fontWeight == FontWeight.w600)
            .map((span) => span.toPlainText()),
        ['Reference'],
      );
      expect(
        _spans(paragraph.text)
            .where(
              (span) =>
                  span.style?.fontFamily == 'monospace' &&
                  span.style?.backgroundColor != null,
            )
            .map((span) => span.toPlainText()),
        ['[fake](https://wrong.test/)'],
      );
      await tester.tapAt(_point(tester, visible));
      await tester.pump();
      expect(native.calls, hasLength(opensLinks ? 1 : 0));
      if (opensLinks) {
        expect(native.calls.single.$1, 'external.open');
        expect(native.calls.single.$2, {
          'url': 'https://example.test/?a=1&b=2',
        });
      }
      await _cleanup(tester, state);
    });
  }

  testWidgets(
    'list block children retain code quote table and heading layout',
    (tester) async {
      final native = _ListPreviewNative();
      final state = AppState(client: native);
      await _mount(
        tester,
        state,
        '- ```text\n  [code](https://wrong.test/) &quot;\n  ```'
        '\n\n  > Quote\n  >\n  > Continuation\n'
        '\n  ## Heading\n\n  | Cell |\n  | --- |\n  | Value |\n'
        '\n- Next',
        opensLinks: false,
      );
      for (final text in [
        '[code](https://wrong.test/) &quot;\n',
        'Quote',
        'Continuation',
        'Heading',
        'Cell',
        'Value',
        'Next',
      ]) {
        expect(_paragraph(text), findsOneWidget);
      }
      expect(find.byType(Table), findsOneWidget);
      expect(find.byType(SelectableRegion), findsNWidgets(2));
      expect(
        tester.getTopLeft(_paragraph('Continuation')).dy,
        greaterThan(tester.getBottomLeft(_paragraph('Quote')).dy),
      );
      expect(native.calls, isEmpty);
      await _cleanup(tester, state);
    },
  );

  testWidgets('alerts and footnotes recursively retain list structure', (
    tester,
  ) async {
    final state = AppState(client: _ListPreviewNative());
    await _mount(
      tester,
      state,
      '> [!NOTE]\n> 3. Alert first\n> 4. Alert next\n'
      '\nReference[^1]\n\n[^1]: Footnote first\n'
      '\n    - Footnote child',
      opensLinks: false,
    );
    for (final text in [
      'Alert first',
      'Alert next',
      'Footnote first',
      '3. ',
      '4. ',
      '1. ',
    ]) {
      expect(_paragraph(text), findsOneWidget);
    }
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().startsWith('Footnote child'),
      ),
      findsOneWidget,
    );
    await _cleanup(tester, state);
  });

  for (final (kind, definition, visible) in [
    ('list', '- Child', 'Child'),
    ('code', '```text\n    literal &quot;\n    ```', 'literal &quot;\n'),
    ('quote', '> Quoted', 'Quoted'),
    ('heading', '## Titled', 'Titled'),
    ('table', '| Header |\n    | --- |\n    | Value |', 'Value'),
    ('rule', '---', null),
  ]) {
    testWidgets(
      'footnote ending with $kind retains content and both backrefs',
      (tester) async {
        final native = _ListPreviewNative();
        final state = AppState(client: native);
        final source = 'First[^a] second[^a]\n\n[^a]: $definition';
        final nodes = parseDraftMarkdown(source);
        final links = _elements(
          nodes,
          'a',
        ).where((node) => node.attributes['class'] == 'footnote-backref');
        expect(links.map((node) => node.attributes['href']), [
          '#fnref-a',
          '#fnref-a-2',
        ]);
        await _mount(tester, state, source, opensLinks: false);
        expect(_paragraph(' ↩ ↩2'), findsOneWidget);
        if (visible != null) expect(_paragraph(visible), findsOneWidget);
        if (kind == 'code') {
          expect(_elements(nodes, 'code').single.textContent, visible);
          expect(find.byType(SelectableRegion), findsNWidgets(2));
        }
        if (kind == 'list') {
          expect(_paragraph('• '), findsOneWidget);
          expect(_paragraph('1. '), findsOneWidget);
        }
        await tester.tapAt(_point(tester, ' ↩ ↩2'));
        await tester.pump();
        expect(native.calls, isEmpty);
        await _cleanup(tester, state);
      },
    );
  }

  testWidgets('nested images keep source-only sticker identity while loading', (
    tester,
  ) async {
    final native = _ListPreviewNative();
    final state = AppState(client: native);
    final catalog = OfficialStickerCatalog.fromPacks([
      {
        'items': [
          {
            'id': 'ac01',
            'label': 'Official',
            'url': 'https://images.example.test/official.png',
            'insertion': ':ac01:',
          },
        ],
      },
    ]);
    await _mount(
      tester,
      state,
      '- Parent\n\n  - ![表情](https://images.example.test/custom.png)'
      '\n  - ![&#x8868;&#x60c5;](https://images.example.test/photo.png)'
      '\n  - :ac01:\n\n    Caption\n- Sibling',
      stickers: catalog,
      opensLinks: false,
    );
    expect(find.byType(DraftStickerImage), findsNWidgets(2));
    expect(find.byType(ComposerSizingImage), findsOneWidget);
    expect(find.byType(NativeForumImage), findsOneWidget);
    final image = tester.widget<ComposerSizingImage>(
      find.byType(ComposerSizingImage),
    );
    expect(image.url, 'https://images.example.test/photo.png');
    expect(image.isSticker, isFalse);
    expect(_paragraph('Caption'), findsOneWidget);
    expect(_paragraph('Sibling'), findsOneWidget);
    final before = tester.getTopLeft(_paragraph('Sibling')).dy;
    native.image.complete({
      'bytes': base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      'width': 1,
      'height': 1,
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pump();
    await tester.pump();
    expect(_paragraph('Sibling'), findsOneWidget);
    expect(tester.getTopLeft(_paragraph('Sibling')).dy, isNot(before));
    expect(find.byType(DraftStickerImage), findsNWidgets(2));
    expect(find.byType(ComposerSizingImage), findsOneWidget);
    expect(
      native.calls.where((call) => call.$1 == 'images.load'),
      hasLength(3),
    );
    await _cleanup(tester, state);
  });
}
