import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_preview.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _url = 'https://www.nodeseek.com/static/image/sticker/ac/01.png';
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
final _catalog = <String, dynamic>{
  'packs': [
    {
      'id': 'ac',
      'title': 'AC',
      'items': [
        {'id': 'ac01', 'label': 'AC 01', 'url': _url, 'insertion': ' :ac01: '},
      ],
    },
  ],
};

class _Native extends NativeClient {
  final calls = <String>[];
  Completer<JsonMap>? catalog;
  bool failCatalog = false;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'stickers.list':
        if (failCatalog) {
          throw const NativeFailure('fixture', 'private provider details');
        }
        return catalog?.future ?? Future.value(_catalog);
      case 'images.load':
        return {'bytes': _pixel, 'width': 1, 'height': 1};
      case 'fixture.account':
        return {
          'session': {'accessRevision': 1, 'account': 'signedIn'},
        };
      default:
        throw StateError('Unexpected service: $method');
    }
  }
}

Widget _app(Widget child) => CupertinoApp(
  home: GlassAdaptiveScope(
    minQuality: GlassQuality.minimal,
    maxQuality: GlassQuality.minimal,
    child: Center(child: SizedBox(width: 500, height: 300, child: child)),
  ),
);

Future<void> _clean(
  WidgetTester tester,
  AppState state,
  TextEditingController content,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  content.dispose();
  state.dispose();
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'late local catalog updates the same draft and selection never reloads metadata',
    (tester) async {
      final native = _Native()..catalog = Completer<JsonMap>();
      final state = AppState(client: native);
      final content = TextEditingController(text: 'One :ac01:');
      await tester.pumpWidget(
        _app(
          ComposerMarkdownPreview(
            state: state,
            controller: content,
            active: true,
          ),
        ),
      );
      expect(find.byType(DraftStickerImage), findsNothing);
      content.text = 'Latest :ac01: :ac01:';
      await tester.pump(const Duration(milliseconds: 120));
      native.catalog!.complete(_catalog);
      await tester.pumpAndSettle();
      expect(find.byType(DraftStickerImage), findsNWidgets(2));
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(1));
      expect(native.calls.where((m) => m == 'images.load'), hasLength(1));
      final document = tester.widget<MarkdownDocument>(
        find.byType(MarkdownDocument),
      );
      content.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<MarkdownDocument>(find.byType(MarkdownDocument)),
        same(document),
      );
      expect(content.text, 'Latest :ac01: :ac01:');
      await _clean(tester, state, content);
    },
  );

  testWidgets(
    'hidden preview defers requests and a hidden catalog completion cannot start images',
    (tester) async {
      final native = _Native()..catalog = Completer<JsonMap>();
      final state = AppState(client: native);
      final content = TextEditingController(text: ':ac01:');
      final active = ValueNotifier(false);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => ComposerMarkdownPreview(
              state: state,
              controller: content,
              active: value,
            ),
          ),
        ),
      );
      expect(native.calls, isEmpty);
      active.value = true;
      await tester.pump();
      expect(native.calls, ['stickers.list']);
      active.value = false;
      await tester.pump();
      native.catalog!.complete(_catalog);
      await tester.pumpAndSettle();
      expect(native.calls, ['stickers.list']);
      content.text = 'Latest :ac01:';
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(DraftStickerImage), findsOneWidget);
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(1));
      await _clean(tester, state, content);
      active.dispose();
    },
  );

  testWidgets(
    'edit strip is compact, preserves repeats, ignores code and vanishes in split mode',
    (tester) async {
      final native = _Native();
      final state = AppState(client: native);
      final content = TextEditingController(text: ':ac01: `:ac01:` :ac01:');
      final original = content.value;
      final active = ValueNotifier(true);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => Column(
              children: [
                ComposerDraftStickerStrip(
                  state: state,
                  controller: content,
                  accessRevision: 0,
                  active: value,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('表情预览'), findsOneWidget);
      expect(find.byType(DraftStickerImage), findsNWidgets(2));
      expect(tester.getSize(find.byType(ComposerDraftStickerStrip)).height, 36);
      expect(content.value, original);
      active.value = false;
      await tester.pumpAndSettle();
      expect(find.text('表情预览'), findsNothing);
      expect(tester.getSize(find.byType(ComposerDraftStickerStrip)).height, 0);
      active.value = true;
      content.text = 'Only ordinary text';
      await tester.pumpAndSettle();
      expect(find.text('表情预览'), findsNothing);
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(1));
      await _clean(tester, state, content);
      active.dispose();
    },
  );

  testWidgets(
    'catalog failure is local, retry uses latest body, and successful retry keeps draft intact',
    (tester) async {
      final native = _Native()..failCatalog = true;
      final state = AppState(client: native);
      final content = TextEditingController(text: ':ac01:');
      await tester.pumpWidget(
        _app(
          ComposerMarkdownPreview(
            state: state,
            controller: content,
            active: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('表情预览暂不可用'), findsOneWidget);
      expect(state.message, isNull);
      expect(find.textContaining('private provider'), findsNothing);
      content.text = 'Changed :ac01:';
      await tester.pump(const Duration(milliseconds: 120));
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(1));
      native.failCatalog = false;
      await tester.tap(
        find.byWidgetPredicate((w) => w is DeskButton && w.label == '重试'),
      );
      await tester.pumpAndSettle();
      expect(find.text('表情预览暂不可用'), findsNothing);
      expect(find.byType(DraftStickerImage), findsOneWidget);
      expect(content.text, 'Changed :ac01:');
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(2));
      await _clean(tester, state, content);
    },
  );

  testWidgets(
    'expired draft refuses late catalog and never adopts new account image access',
    (tester) async {
      final native = _Native()..catalog = Completer<JsonMap>();
      final state = AppState(client: native);
      final content = TextEditingController(text: ':ac01:');
      await tester.pumpWidget(
        _app(
          ComposerMarkdownPreview(
            state: state,
            controller: content,
            active: true,
          ),
        ),
      );
      await state.act('fixture.account');
      await tester.pump();
      native.catalog!.complete(_catalog);
      await tester.pumpAndSettle();
      content.text = ':ac01: :ac01:';
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DraftStickerImage), findsNothing);
      expect(native.calls.where((m) => m == 'images.load'), isEmpty);
      expect(native.calls.where((m) => m == 'stickers.list'), hasLength(1));
      expect(state.message, isNull);
      await _clean(tester, state, content);
    },
  );

  testWidgets(
    'changing or disposing document while catalog waits does not revive old image widgets',
    (tester) async {
      final native = _Native()..catalog = Completer<JsonMap>();
      final state = AppState(client: native);
      final first = TextEditingController(text: ':ac01:');
      final second = TextEditingController(text: 'No sticker in this document');
      final controller = ValueNotifier(first);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<TextEditingController>(
            valueListenable: controller,
            builder: (_, value, _) => ComposerMarkdownPreview(
              state: state,
              controller: value,
              active: true,
            ),
          ),
        ),
      );
      controller.value = second;
      await tester.pump();
      native.catalog!.complete(_catalog);
      await tester.pumpAndSettle();
      expect(find.byType(DraftStickerImage), findsNothing);
      expect(native.calls.where((m) => m == 'images.load'), isEmpty);
      expect(
        tester.widget<MarkdownDocument>(find.byType(MarkdownDocument)).text,
        second.text,
      );
      await _clean(tester, state, second);
      first.dispose();
      controller.dispose();
    },
  );
}
