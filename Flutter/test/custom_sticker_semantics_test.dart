import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/official_stickers.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_image_sizing_controller.dart';
import 'package:seekdesk_flutter/widgets/composer_sizing_image.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _url = 'https://images.example/label-semantics.png';
const _labels = <(String, bool)>[
  ('表情', true),
  (' 表情 ', false),
  ('**表情**', false),
  ('`表情`', false),
  ('&#x8868;&#x60c5;', false),
  (r'\*表情\*', false),
  (r'\表情', false),
];

Iterable<md.Element> _images(Iterable<md.Node> nodes) sync* {
  for (final node in nodes) {
    if (node is md.Element) {
      if (node.tag == 'img') yield node;
      yield* _images(node.children ?? const []);
    }
  }
}

class _SemanticNative extends NativeClient {
  final calls = <String>[];
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'images.load') {
      return {
        'bytes': base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        'width': 1,
        'height': 1,
      };
    }
    if (method == 'images.draftReferences') {
      // The native scanner includes this URL because the same document also
      // contains ordinary images. Sticker semantics belong to each occurrence.
      return {
        'content': arguments['content'],
        'imageURLs': [_url],
        'accessRevision': accessRevision,
      };
    }
    throw StateError('Unexpected native operation: $method');
  }
}

void main() {
  for (final (label, sticker) in _labels) {
    test(
      'source label $label preserves Markdown alt and native sticker semantics',
      () {
        final source = '![$label](<$_url> "label fixture")';
        final parsed = parseDraftMarkdown(source);
        final upstream = md.Document(
          extensionSet: md.ExtensionSet.gitHubWeb,
          encodeHtml: false,
        ).parse(source);
        final image = _images(parsed).single;
        expect(isDraftCustomStickerImage(image), sticker);
        expect(image.attributes, _images(upstream).single.attributes);
        expect(md.renderToHtml(parsed), md.renderToHtml(upstream));
        if (label == '**表情**' || label == '`表情`' || label.startsWith('&#')) {
          expect(image.attributes['alt'], '表情');
          expect(
            isDraftCustomStickerImage(image),
            isFalse,
            reason: 'Flattened alt must not replace the original native label.',
          );
        }
      },
    );
  }

  test(
    'link, inline and table contexts retain per-occurrence source semantics',
    () {
      const source =
          '''前 ![表情]($_url) ![**表情**]($_url) 后

[![表情]($_url)](https://example.test/exact)
[![`表情`]($_url)](https://example.test/code)

| Images |
| --- |
| ![表情]($_url) |
| ![&#x8868;&#x60c5;]($_url) |

![表情][reference]

[reference]: $_url "reference title"
''';
      final parsed = parseDraftMarkdown(source);
      final upstream = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(source);
      expect(_images(parsed).map(isDraftCustomStickerImage), [
        true,
        false,
        true,
        false,
        true,
        false,
        true,
      ]);
      expect(md.renderToHtml(parsed), md.renderToHtml(upstream));
    },
  );

  test('code, escaped images and malformed destinations preserve normal Markdown parsing', () {
    const source = r'''`![表情](https://images.example/a.png)`

\![表情](https://images.example/escaped.png)

![表情](<broken destination

![outer ![表情](https://images.example/inner.png)](https://images.example/outer.png)
''';
    final parsed = parseDraftMarkdown(source);
    final upstream = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    ).parse(source);
    expect(md.renderToHtml(parsed), md.renderToHtml(upstream));
    expect(
      _images(parsed).map(isDraftCustomStickerImage),
      everyElement(isFalse),
    );
  });

  for (final context in ['paragraph', 'inline', 'link', 'table']) {
    testWidgets(
      '$context keeps formatted/space/entity labels adjustable beside exact stickers',
      (tester) async {
        final descriptions = _labels
            .take(5)
            .map((entry) => '![${entry.$1}]($_url)')
            .toList();
        final source = switch (context) {
          'inline' => '正文 ${descriptions.join(' 后 ')}',
          'link' =>
            descriptions
                .map((image) => '[$image](https://example.test/destination)')
                .join('\n\n'),
          'table' =>
            '| Image |\n| --- |\n${descriptions.map((image) => '| $image |').join('\n')}',
          _ => descriptions.join('\n\n'),
        };
        final native = _SemanticNative();
        final state = AppState(client: native);
        final content = TextEditingController(text: source);
        final controller = ComposerImageSizingController(
          state: state,
          content: content,
          revision: 0,
          canChange: () => true,
          isCurrent: () => true,
          synchronize: (_) async => null,
          saveSize: (_, _, _, _) async => throw StateError('Read-only fixture'),
          onEdited: () {},
        );
        controller.acceptSnapshot({
          'content': source,
          'accessRevision': 0,
          'imageURLs': [_url],
          'imageSizing': <JsonMap>[],
        });
        await tester.binding.setSurfaceSize(const Size(900, 900));
        await tester.pumpWidget(
          CupertinoApp(
            home: GlassAdaptiveScope(
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: CupertinoPageScaffold(
                child: SingleChildScrollView(
                  child: ComposerImageSizingScope(
                    controller: controller,
                    enabled: true,
                    accessRevision: 0,
                    child: MarkdownDocument(state: state, text: source),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byType(DraftStickerImage), findsOneWidget);
        expect(
          tester.widget<DraftStickerImage>(find.byType(DraftStickerImage)).size,
          48,
        );
        expect(find.byType(NativeForumImage), findsNWidgets(4));
        expect(find.byType(ComposerSizingImage), findsNWidgets(4));
        expect(find.byType(CupertinoSlider), findsNWidgets(4));
        expect(
          tester
              .widgetList<ComposerSizingImage>(find.byType(ComposerSizingImage))
              .map((image) => image.isSticker),
          everyElement(isFalse),
        );
        expect(
          find.ancestor(
            of: find.byType(DraftStickerImage),
            matching: find.byType(ComposerSizingImage),
          ),
          findsNothing,
        );
        expect(
          native.calls.every(
            (method) =>
                method == 'images.load' || method == 'images.draftReferences',
          ),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        content.dispose();
        state.dispose();
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
