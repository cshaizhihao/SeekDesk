import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/official_stickers.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_image_sizing_controller.dart';
import 'package:seekdesk_flutter/widgets/composer_sizing_image.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _ac = 'https://www.nodeseek.com/static/image/sticker/ac/01.png';
const _yct = 'https://www.nodeseek.com/static/image/sticker/yct/001.gif';
const _xhj = 'https://www.nodeseek.com/static/image/sticker/xhj/001.png';
const _emoji = 'https://www.nodeseek.com/static/image/sticker/emoji/00.png';
const _normal = 'https://www.nodeseek.com/assets/photo.png';
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
JsonMap get _image => {'bytes': _pixel, 'width': 64, 'height': 64};

OfficialStickerCatalog get _catalog => OfficialStickerCatalog.fromPacks([
  {
    'id': 'ac',
    'title': 'AC 娘',
    'items': [
      {'id': 'ac01', 'label': 'AC 娘 01', 'url': _ac, 'insertion': ' :ac01: '},
    ],
  },
  {
    'id': 'yct',
    'title': '洋葱头',
    'items': [
      {
        'id': 'yct001',
        'label': '洋葱头 001',
        'url': _yct,
        'insertion': ' :yct001: ',
      },
    ],
  },
]);

class _StickerNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final failures = <String>{};
  final gates = <String, Completer<JsonMap>>{};
  final images = <String, JsonMap>{};

  int loads(String url) => calls
      .where((call) => call.$1 == 'images.load' && call.$2['url'] == url)
      .length;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'images.load') {
      final url = arguments['url'] as String;
      if (failures.contains(url)) {
        throw const NativeFailure('fixture', 'Image unavailable');
      }
      return await gates[url]?.future ?? images[url] ?? _image;
    }
    if (method == 'images.draftReferences') {
      return {
        'content': arguments['content'],
        'imageURLs': [_normal],
        'accessRevision': accessRevision,
      };
    }
    if (method == 'external.open') return {};
    // No fallback to a real image, forum, clipboard or upload service.
    throw NativeFailure('fixture_only', 'Unexpected sticker fixture request');
  }
}

Widget _app(Widget child) => CupertinoApp(
  home: GlassAdaptiveScope(
    minQuality: GlassQuality.minimal,
    maxQuality: GlassQuality.minimal,
    child: CupertinoPageScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: child,
      ),
    ),
  ),
);

List<WidgetSpan> _stickerSpans(InlineSpan span) {
  if (span is WidgetSpan) {
    final child = span.child;
    return child is SelectionContainer && child.child is DraftStickerImage
        ? [span]
        : [];
  }
  return span is TextSpan
      ? [
          for (final child in span.children ?? <InlineSpan>[])
            ..._stickerSpans(child),
        ]
      : [];
}

/// Called inside runAsync so the engine decodes real bytes, rather than leaving
/// an Image.memory request stranded in the widget test's FakeAsync zone.
Future<bool> _waitForImageDecode(WidgetTester tester) async {
  final image = tester.widget<Image>(find.byType(Image));
  final stream = image.image.resolve(ImageConfiguration.empty);
  final completed = Completer<bool>();
  final listener = ImageStreamListener(
    (info, synchronous) {
      info.dispose();
      if (!completed.isCompleted) completed.complete(true);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completed.isCompleted) completed.complete(false);
    },
  );
  stream.addListener(listener);
  try {
    return await completed.future.timeout(const Duration(seconds: 5));
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(_app(child));
    await tester.pump();
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'custom sticker images stay compact in paragraphs and tables without changing ordinary images',
    (tester) async {
      final native = _StickerNative();
      final state = AppState(client: native);
      await mount(
        tester,
        MarkdownDocument(
          state: state,
          text:
              '''前 ![表情]($_ac) 后

[![表情]($_yct)](https://example.test/sticker-link)

| 收藏 |
| --- |
| ![表情]($_xhj) |

![表情说明]($_normal)

`![表情]($_emoji)`
''',
        ),
      );
      expect(find.byType(DraftStickerImage), findsNWidgets(3));
      expect(find.byType(NativeForumImage), findsOneWidget);
      expect(find.byType(ComposerSizingImage), findsOneWidget);
      for (final image in tester.widgetList<DraftStickerImage>(
        find.byType(DraftStickerImage),
      )) {
        expect(image.size, 48);
        expect(image.code, isEmpty);
        expect(image.label, '表情');
      }
      final linked = find.byWidgetPredicate(
        (widget) => widget is DraftStickerImage && widget.url == _yct,
      );
      await tester.tap(linked);
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'external.open').single.$2,
        {'url': 'https://example.test/sticker-link'},
      );
      expect(native.loads(_emoji), 0);
      expect(find.byType(NativeImageViewer), findsNothing);
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'default Markdown and native reader text keep official codes literal',
    (tester) async {
      final native = _StickerNative();
      final state = AppState(client: native);
      await mount(
        tester,
        Column(
          children: [
            MarkdownDocument(state: state, text: 'default :ac01: :smile:'),
            ForumBlocks(
              state: state,
              blocks: const [
                {'kind': 'paragraph', 'text': 'reader :ac01:'},
              ],
            ),
          ],
        ),
      );
      expect(find.byType(DraftStickerImage), findsNothing);
      expect(find.textContaining(':ac01:', findRichText: true), findsWidgets);
      expect(
        find.textContaining('😄', findRichText: true),
        findsOneWidget,
        reason: 'The existing gitHubWeb emoji behavior must remain intact.',
      );
      expect(native.calls, isEmpty);
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'explicit catalog renders bounded heading, inline, table and linked stickers with shared loads',
    (tester) async {
      final native = _StickerNative();
      final state = AppState(client: native);
      await mount(
        tester,
        DraftStickerImageScope(
          accessRevision: 0,
          active: true,
          child: MarkdownDocument(
            state: state,
            stickers: _catalog,
            text:
                '# Head :ac01:\n\nBefore :ac01: after :smile:\n\n'
                '| Sticker | Text |\n| --- | --- |\n| :yct001: | cell |\n\n'
                '[:ac01:](https://example.invalid/sticker-link)',
          ),
        ),
      );
      expect(find.byType(DraftStickerImage), findsNWidgets(4));
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('cell', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('😄', findRichText: true),
        findsOneWidget,
        reason:
            'Adding official stickers must not swallow standard emoji syntax.',
      );
      expect(find.byType(ComposerSizingImage), findsNothing);
      expect(find.byType(NativeForumImage), findsNothing);
      expect(native.loads(_ac), 1);
      expect(native.loads(_yct), 1);
      for (final leaf in find.byType(DraftStickerImage).evaluate()) {
        expect(tester.getSize(find.byWidget(leaf.widget)), const Size(48, 48));
      }
      final spans = tester
          .widgetList<RichText>(find.byType(RichText))
          .expand((text) => _stickerSpans(text.text))
          .toList();
      expect(spans, hasLength(4));
      expect(
        spans.every((span) => span.alignment == PlaceholderAlignment.middle),
        true,
      );
      final linked = find.byWidgetPredicate(
        (widget) => widget is DraftStickerImage && widget.onTap != null,
      );
      expect(linked, findsOneWidget);
      await tester.tap(linked);
      await tester.pump();
      expect(
        native.calls
            .where((call) => call.$1 == 'external.open')
            .single
            .$2['url'],
        'https://example.invalid/sticker-link',
      );
      expect(find.byType(NativeImageViewer), findsNothing);
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'official stickers do not take normal image sizing controls or geometry',
    (tester) async {
      final native = _StickerNative();
      final state = AppState(client: native);
      final content = TextEditingController(text: ':ac01: ![photo]($_normal)');
      final sizing = ComposerImageSizingController(
        state: state,
        content: content,
        revision: 0,
        canChange: () => true,
        isCurrent: () => true,
        synchronize: (_) async => {},
        saveSize: (_, _, _, _) async => {},
        onEdited: () {},
      );
      sizing.acceptSnapshot({
        'content': content.text,
        'imageURLs': [_normal],
        'imageSizing': <JsonMap>[],
        'accessRevision': 0,
      });
      await mount(
        tester,
        DraftStickerImageScope(
          accessRevision: 0,
          active: true,
          child: ComposerImageSizingScope(
            controller: sizing,
            enabled: true,
            accessRevision: 0,
            child: MarkdownDocument(
              state: state,
              text: content.text,
              stickers: _catalog,
            ),
          ),
        ),
      );
      expect(find.byType(DraftStickerImage), findsOneWidget);
      expect(find.byType(ComposerSizingImage), findsOneWidget);
      expect(find.byType(NativeForumImage), findsOneWidget);
      expect(find.byType(CupertinoSlider), findsOneWidget);
      expect(
        tester.widget<NativeForumImage>(find.byType(NativeForumImage)).url,
        _normal,
      );
      expect(sizing.stage(_normal, .5, 320), true);
      await tester.pump();
      expect(
        tester
            .widget<NativeForumImage>(find.byType(NativeForumImage))
            .draftSize
            ?.ratio,
        .5,
      );
      expect(
        tester.getSize(find.byType(DraftStickerImage)),
        const Size(48, 48),
      );
      expect(native.loads(_ac), 1);
      expect(native.loads(_normal), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      sizing.dispose();
      content.dispose();
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'leaf guards hidden requests, results, retry, stale owners and unscoped fallback',
    (tester) async {
      final native = _StickerNative();
      final state = AppState(client: native);
      final visible = ValueNotifier((active: false, url: _ac));
      var links = 0;
      final first = Completer<JsonMap>();
      native.gates[_ac] = first;
      await mount(
        tester,
        ValueListenableBuilder(
          valueListenable: visible,
          builder: (context, value, _) => DraftStickerImageScope(
            accessRevision: 0,
            active: value.active,
            child: Align(
              alignment: Alignment.topLeft,
              child: DraftStickerImage(
                state: state,
                url: value.url,
                label: 'Fixture sticker',
                code: 'ac01',
                onTap: () => links++,
              ),
            ),
          ),
        ),
      );
      expect(native.loads(_ac), 0);
      visible.value = (active: true, url: _ac);
      await tester.pump();
      expect(native.loads(_ac), 1);
      visible.value = (active: false, url: _ac);
      await tester.pump();
      first.complete(_image);
      await tester.pump();
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'Hidden results are not adopted by the leaf.',
      );
      visible.value = (active: true, url: _ac);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(
        native.loads(_ac),
        1,
        reason: 'Reactivation reuses the bounded AppState cache.',
      );
      visible.value = (active: false, url: _ac);
      await tester.pump();
      await tester.tap(find.byType(DraftStickerImage));
      expect(links, 0);
      expect(
        find.byType(Image),
        findsOneWidget,
        reason: 'Already accepted success stays cached while hidden.',
      );

      native.failures.add(_yct);
      visible.value = (active: true, url: _yct);
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsOneWidget);
      expect(native.loads(_yct), 1);
      visible.value = (active: false, url: _yct);
      await tester.pump();
      await tester.tap(find.byType(DraftStickerImage));
      expect(native.loads(_yct), 1);
      native.failures.remove(_yct);
      visible.value = (active: true, url: _yct);
      await tester.pump();
      expect(
        native.loads(_yct),
        1,
        reason: 'Returning to preview does not loop failed requests.',
      );
      await tester.tap(find.byType(DraftStickerImage));
      await tester.pump();
      await tester.pump();
      expect(native.loads(_yct), 2);
      expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsNothing);
      await tester.tap(find.byType(DraftStickerImage));
      expect(links, 1);

      final stale = Completer<JsonMap>();
      native.gates[_xhj] = stale;
      visible.value = (active: true, url: _xhj);
      await tester.pump();
      expect(native.loads(_xhj), 1);
      native.accessRevision++;
      visible.value = (active: false, url: _xhj);
      await tester.pump();
      stale.complete(_image);
      await tester.pump();
      visible.value = (active: true, url: _xhj);
      await tester.pump();
      await tester.tap(find.byType(DraftStickerImage));
      expect(native.loads(_xhj), 1);
      expect(find.byType(Image), findsNothing);
      expect(links, 1);

      // Without a scope, the leaf keeps its first revision instead of following
      // later account changes when its parent rebuilds.
      Widget standalone() => Align(
        alignment: Alignment.topLeft,
        child: DraftStickerImage(
          key: const ValueKey('unscoped'),
          state: state,
          url: _emoji,
          label: 'Fallback',
          code: 'emoji00',
        ),
      );
      await tester.pumpWidget(_app(standalone()));
      await tester.pump();
      expect(native.loads(_emoji), 1);
      native.accessRevision++;
      await tester.pumpWidget(_app(standalone()));
      await tester.pump();
      expect(native.loads(_emoji), 1);
      expect(find.byType(Image), findsNothing);

      final disposed = Completer<JsonMap>();
      native.gates[_normal] = disposed;
      await tester.pumpWidget(
        _app(
          DraftStickerImageScope(
            accessRevision: 2,
            active: true,
            child: DraftStickerImage(
              key: const ValueKey('disposing'),
              state: state,
              url: _normal,
              label: 'Disposed fixture',
              code: 'ac01',
            ),
          ),
        ),
      );
      expect(native.loads(_normal), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      disposed.complete(_image);
      await tester.pump();
      visible.dispose();
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'real decode failure retries corrupt bytes without evicting a newer image Future',
    (tester) async {
      await tester.runAsync(() async {
        final native = _StickerNative();
        final state = AppState(client: native);
        final recovered = Uint8List.fromList(_pixel);
        native.images[_ac] = {
          'bytes': Uint8List.fromList([0x53, 0x44, 0, 1, 2]),
          'width': 64,
          'height': 64,
        };
        Widget sticker(String url) => DraftStickerImageScope(
          accessRevision: 0,
          active: true,
          child: Align(
            alignment: Alignment.topLeft,
            child: DraftStickerImage(
              state: state,
              url: url,
              label: 'Decode fixture',
              code: 'ac01',
            ),
          ),
        );
        await mount(tester, sticker(_ac));
        expect(await _waitForImageDecode(tester), false);
        await tester.pump();
        expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsOneWidget);
        expect(native.loads(_ac), 1);
        expect(
          native.failures,
          isEmpty,
          reason: 'The error must come from decoding actual corrupt bytes.',
        );

        native.images[_ac] = {'bytes': recovered, 'width': 64, 'height': 64};
        await tester.tap(find.byType(DraftStickerImage));
        await tester.pump();
        await tester.pump();
        expect(native.loads(_ac), 2);
        expect(await _waitForImageDecode(tester), true);
        await tester.pump();
        expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsNothing);
        expect(
          tester.getSize(find.byType(DraftStickerImage)),
          const Size(48, 48),
        );

        // Switch URLs on the same leaf, then replace its failed cache entry
        // externally before clicking its old retry button. That stale button
        // must reuse the replacement Future, not evict it and start load #3.
        native.images[_yct] = {
          'bytes': Uint8List.fromList([0x53, 0x44, 0, 3, 4]),
          'width': 64,
          'height': 64,
        };
        await tester.pumpWidget(_app(sticker(_yct)));
        await tester.pump();
        await tester.pump();
        expect(await _waitForImageDecode(tester), false);
        await tester.pump();
        expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsOneWidget);
        final failedFuture = state.image(_yct);
        expect(native.loads(_yct), 1);
        expect(state.evictImageFuture(_yct, failedFuture, revision: 0), true);
        native.images[_yct] = {'bytes': recovered, 'width': 91, 'height': 73};
        final replacement = state.image(_yct);
        await replacement;
        expect(native.loads(_yct), 2);
        expect(state.imageDimensions(_yct)['width'], 91);
        await tester.tap(find.byType(DraftStickerImage));
        await tester.pump();
        await tester.pump();
        expect(native.loads(_yct), 2);
        expect(identical(state.image(_yct), replacement), true);
        expect(state.imageDimensions(_yct)['width'], 91);
        expect(state.imageDimensions(_yct)['height'], 73);
        expect(await _waitForImageDecode(tester), true);
        await tester.pump();
        expect(find.byIcon(CupertinoIcons.arrow_clockwise), findsNothing);
        expect(native.calls.every((call) => call.$1 == 'images.load'), true);
        await cleanup(tester, state);
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
