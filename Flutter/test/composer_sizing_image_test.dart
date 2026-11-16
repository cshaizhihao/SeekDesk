import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_image_sizing_controller.dart';
import 'package:seekdesk_flutter/widgets/composer_preview.dart';
import 'package:seekdesk_flutter/widgets/composer_sizing_image.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _url = 'https://www.nodeseek.com/assets/example.png';
const _other = 'https://images.example/unsupported.png';
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _ImageNative extends NativeClient {
  final calls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'images.load') {
      return {
        'bytes': _pixel,
        'width': 1000,
        'height': 500,
        'originalWidth': 4000,
        'originalHeight': 2000,
      };
    }
    if (method == 'images.draftReferences') {
      return {
        'content': arguments['content'],
        'imageURLs': [_url],
        'accessRevision': accessRevision,
      };
    }
    throw StateError('Image UI fixture cannot call $method');
  }
}

class _Fixture {
  _Fixture(String text) {
    content = TextEditingController(text: text);
    state = AppState(client: native);
    controller = ComposerImageSizingController(
      state: state,
      content: content,
      revision: 0,
      canChange: () => true,
      isCurrent: () => true,
      synchronize: (_) async => snapshot,
      saveSize: (url, ratio, width, expected) async {
        saves.add((url, ratio, width, expected));
        if (failSave) return null;
        saved = ratio == 1
            ? null
            : DraftImageSize(ratio: ratio, previewWidth: width);
        return snapshot;
      },
      onEdited: () => edits++,
    );
    controller.acceptSnapshot(snapshot);
  }

  final native = _ImageNative();
  late final AppState state;
  late final TextEditingController content;
  late final ComposerImageSizingController controller;
  final saves = <(String, double, double, String)>[];
  DraftImageSize? saved;
  int edits = 0;
  bool failSave = false;

  JsonMap get snapshot => {
    'content': content.text,
    'accessRevision': native.accessRevision,
    'imageURLs': [_url],
    'imageSizing': [
      if (saved != null)
        {
          'url': _url,
          'ratio': saved!.ratio,
          'previewWidth': saved!.previewWidth,
        },
    ],
  };

  Future<void> mount(
    WidgetTester tester, {
    double width = 520,
    bool enabled = true,
    bool attach = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 850,
                child: ComposerMarkdownPreview(
                  state: state,
                  controller: content,
                  active: true,
                  imageSizing: attach ? controller : null,
                  imagesEnabled: enabled,
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

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    content.dispose();
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
    await tester.binding.setSurfaceSize(null);
    expect(tester.takeException(), isNull);
  }
}

CupertinoSlider _slider(WidgetTester tester) =>
    tester.widget<CupertinoSlider>(find.byType(CupertinoSlider).first);

void _testMac(String description, WidgetTesterCallback callback) => testWidgets(
  description,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  test('saved baseline and original pixels define scaled preview independently of window size', () {
    const selection = DraftImageSize(ratio: .5, previewWidth: 640);
    Size geometry(double available, [Size original = const Size(4000, 2000)]) =>
        ComposerImagePreviewGeometry.size(
          selection: selection,
          available: available,
          decoded: const Size(1000, 500),
          original: original,
        );
    expect(geometry(900), const Size(320, 160));
    expect(geometry(500), const Size(320, 160));
    expect(geometry(220), const Size(220, 110));
    expect(geometry(900, const Size(200, 100)), const Size(100, 50));
  });

  _testMac(
    'canonical supported image controls cover paragraphs, inline spans and tables only',
    (tester) async {
      final f = _Fixture(
        '![standalone]($_url)\n\ninline ![inline](/assets/example.png) text\n\n'
        '| Picture | Text |\n| --- | --- |\n| ![table]($_url) | cell |\n\n'
        '![unsupported]($_other)\n\n![表情]($_url)',
      );
      await f.mount(tester);
      expect(find.byType(CupertinoSlider), findsNWidgets(3));
      expect(find.byType(NativeForumImage), findsNWidgets(4));
      expect(find.byType(DraftStickerImage), findsOneWidget);
      final sticker = tester.widget<DraftStickerImage>(
        find.byType(DraftStickerImage),
      );
      expect(sticker.url, _url);
      expect(sticker.size, 48);
      expect(
        find.ancestor(
          of: find.byType(DraftStickerImage),
          matching: find.byType(ComposerSizingImage),
        ),
        findsNothing,
      );
      expect(find.text('cell', findRichText: true), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(f.saves, isEmpty);
      expect(f.native.calls.every((call) => call == 'images.load'), isTrue);
      expect(tester.takeException(), isNull);
      await f.dispose(tester);
    },
  );

  _testMac(
    'drag previews shared URL without reparsing or saving until gesture end, reset restores original',
    (tester) async {
      final f = _Fixture('![one]($_url)\n\n![two]($_url)');
      await f.mount(tester);
      final document = tester.widget<MarkdownDocument>(
        find.byType(MarkdownDocument),
      );
      final element = tester.element(find.byType(MarkdownDocument));
      final beforeCalls = f.native.calls.length;
      _slider(tester).onChanged!(.5);
      await tester.pump();
      expect(f.saves, isEmpty);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(
        tester
            .widgetList<CupertinoSlider>(find.byType(CupertinoSlider))
            .map((slider) => slider.value),
        [.5, .5],
      );
      expect(
        tester.widget<MarkdownDocument>(find.byType(MarkdownDocument)),
        same(document),
      );
      expect(tester.element(find.byType(MarkdownDocument)), same(element));
      expect(f.native.calls.length, beforeCalls);
      _slider(tester).onChangeEnd!(.5);
      await tester.pump();
      await tester.pump();
      expect(f.saves, hasLength(1));
      expect(f.saves.single.$2, .5);
      expect(f.saves.single.$3, 488);
      expect(f.controller.hasPendingChanges, isFalse);
      final reset = tester.widget<CupertinoButton>(
        find.widgetWithText(CupertinoButton, '原图').first,
      );
      reset.onPressed!();
      await tester.pump();
      await tester.pump();
      expect(f.saves.last.$2, 1);
      expect(
        tester
            .widgetList<NativeForumImage>(find.byType(NativeForumImage))
            .every((image) => image.draftSize == null),
        isTrue,
      );
      await f.dispose(tester);
    },
  );

  _testMac(
    'resizing a narrow preview preserves saved width and image-only updates',
    (tester) async {
      final f = _Fixture(
        '![one]($_url)\n\n| Picture |\n| --- |\n| ![table]($_url) |',
      );
      f.saved = const DraftImageSize(ratio: .6, previewWidth: 700);
      f.controller.acceptSnapshot(f.snapshot);
      await f.mount(tester, width: 220);
      final document = tester.widget<MarkdownDocument>(
        find.byType(MarkdownDocument),
      );
      expect(tester.takeException(), isNull);
      await f.mount(tester, width: 180);
      expect(f.controller.sizeFor(_url).previewWidth, 700);
      expect(f.saves, isEmpty);
      expect(f.edits, 0);
      expect(
        tester.widget<MarkdownDocument>(find.byType(MarkdownDocument)),
        same(document),
      );
      expect(tester.takeException(), isNull);
      await f.dispose(tester);
    },
  );

  _testMac(
    'a failed size save exposes an explicit retry without another slider edit',
    (tester) async {
      final f = _Fixture('![example]($_url)')..failSave = true;
      await f.mount(tester);
      _slider(tester).onChanged!(.5);
      _slider(tester).onChangeEnd!(.5);
      await tester.pump();
      await tester.pump();
      expect(f.controller.hasPendingChanges, isTrue);
      expect(find.widgetWithText(CupertinoButton, '重试保存'), findsOneWidget);
      final edits = f.edits;
      f.failSave = false;
      tester
          .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '重试保存'))
          .onPressed!();
      await tester.pump();
      await tester.pump();
      expect(f.saves, hasLength(2));
      expect(f.saves.last.$2, .5);
      expect(f.edits, edits);
      expect(f.controller.hasPendingChanges, isFalse);
      expect(find.widgetWithText(CupertinoButton, '重试保存'), findsNothing);
      await f.dispose(tester);
    },
  );

  _testMac(
    'keyboard and accessibility expose actual percentages and persist one adjustment',
    (tester) async {
      final f = _Fixture('![example]($_url)');
      await f.mount(tester);
      Focus.of(tester.element(find.byType(CupertinoSlider))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump();
      expect(f.saves.single.$2, .99);
      final sliderSemantics = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.slider == true,
        ),
      );
      expect(sliderSemantics.properties.label, 'example发布大小');
      expect(sliderSemantics.properties.value, '99%');
      sliderSemantics.properties.onDecrease!();
      await tester.pump();
      await tester.pump();
      expect(f.saves.last.$2, .98);
      await f.dispose(tester);
    },
  );

  _testMac(
    'disabled or expired owner rejects captured callbacks and retains document text',
    (tester) async {
      final f = _Fixture('![example]($_url)');
      await f.mount(tester);
      final oldSlider = _slider(tester);
      await f.mount(tester, enabled: false);
      oldSlider.onChanged!(.4);
      oldSlider.onChangeEnd!(.4);
      await tester.pump();
      expect(f.edits, 0);
      expect(f.saves, isEmpty);
      await f.mount(tester);
      final expiredSlider = _slider(tester);
      f.native.accessRevision++;
      f.state.showMessage('Fixture account changed');
      expiredSlider.onChanged!(.4);
      expiredSlider.onChangeEnd!(.4);
      await tester.pump();
      expect(_slider(tester).onChanged, isNull);
      expect(f.edits, 0);
      expect(f.saves, isEmpty);
      expect(f.content.text, '![example]($_url)');
      await f.dispose(tester);
    },
  );

  _testMac(
    'previews without a sizing controller retain ordinary images and no sizing UI',
    (tester) async {
      final f = _Fixture('![example]($_url)');
      await f.mount(tester, attach: false);
      expect(find.byType(NativeForumImage), findsOneWidget);
      expect(find.byType(CupertinoSlider), findsNothing);
      expect(
        tester
            .widget<NativeForumImage>(find.byType(NativeForumImage))
            .draftSize,
        isNull,
      );
      await f.dispose(tester);
    },
  );
}
