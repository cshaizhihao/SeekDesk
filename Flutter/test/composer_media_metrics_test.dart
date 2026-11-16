import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// These are local fixture responses. No key, chooser, upload, draft, or forum
/// operation may fall through to NativeClient's platform transport.
class _MediaNative extends NativeClient {
  _MediaNative()
    : super(methods: const MethodChannel('seekdesk.test.media-metrics'));

  final calls = <String>[];
  final unexpected = <String>[];
  final imageChoice = Completer<JsonMap>();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'images.keyStatus':
        return {'configured': true};
      case 'system.chooseImage':
        return imageChoice.future;
      default:
        unexpected.add(method);
        throw StateError('Unexpected media metrics fixture operation: $method');
    }
  }
}

class _Fixture {
  _Fixture() {
    state = AppState(client: native)..connecting = false;
    media = ComposerMediaController(
      state: state,
      content: content,
      revision: state.accessRevision,
      documentIdentity: this,
      canStart: () => enabled.value,
    );
  }

  final native = _MediaNative();
  late final AppState state;
  late final ComposerMediaController media;
  final content = TextEditingController.fromValue(
    const TextEditingValue(
      text: 'Existing draft',
      selection: TextSelection(baseOffset: 1, extentOffset: 4),
    ),
  );
  final width = ValueNotifier(800.0);
  final enabled = ValueNotifier(true);
  int uploads = 0, stickers = 0, settings = 0;

  void upload() {
    uploads++;
    unawaited(
      media.upload(
        requestKey: () async =>
            throw StateError('Fixture must not request or save a key'),
      ),
    );
  }
}

const _labels = ['上传图片', '表情', '图床设置'];
const _paneKey = ValueKey('media-metrics-pane');

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<_Fixture> _mount(WidgetTester tester, {required bool accessible}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 700));
  final fixture = _Fixture();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.media.dispose();
    if (!fixture.native.imageChoice.isCompleted) {
      fixture.native.imageChoice.complete({});
    }
    await _frames(tester);
    fixture.content.dispose();
    fixture.state.dispose();
    fixture.width.dispose();
    fixture.enabled.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(fixture.native.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        theme: const CupertinoThemeData(
          textTheme: CupertinoTextThemeData(textStyle: DeskTypography.base),
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(accessible ? 2 : 1),
                  boldText: accessible,
                )
                .applyTextStyleOverrides(
                  lineHeightScaleFactorOverride: accessible ? 2 : null,
                  letterSpacingOverride: accessible ? 4 : null,
                  wordSpacingOverride: accessible ? 6 : null,
                  paragraphSpacingOverride: null,
                ),
            child: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.topLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: fixture.width,
                  builder: (context, width, _) => SizedBox(
                    key: _paneKey,
                    width: width,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: fixture.enabled,
                      builder: (context, enabled, _) => Wrap(
                        spacing: 14,
                        runSpacing: 10,
                        children: [
                          ComposerMediaTools(
                            controller: fixture.media,
                            enabled: enabled,
                            onUpload: fixture.upload,
                            onStickers: () => fixture.stickers++,
                          ),
                          ComposerImageSettingsButton(
                            controller: fixture.media,
                            enabled: enabled,
                            onTap: () => fixture.settings++,
                          ),
                        ],
                      ),
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
  await _frames(tester);
  return fixture;
}

void _expectCompleteLabels(WidgetTester tester) {
  final pane = tester.getRect(find.byKey(_paneKey)).inflate(.01);
  final controls = <Rect>[];
  for (final label in _labels) {
    final button = _button(label);
    final text = find.descendant(of: button, matching: find.text(label));
    expect(text, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.text.toPlainText(), label);
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$label is truncated');
    expect(
      paragraph.textSize.height,
      lessThanOrEqualTo(paragraph.size.height + .01),
      reason: '$label has a clipped line box',
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    expect(boxes, isNotEmpty);
    final painted = boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b))
        .shift(paragraph.localToGlobal(Offset.zero));
    final bounds = tester.getRect(button);
    for (final rect in [tester.getRect(text), painted]) {
      expect(
        bounds.inflate(.01).contains(rect.topLeft),
        isTrue,
        reason: '$label starts outside its control',
      );
      expect(
        bounds.inflate(.01).contains(rect.bottomRight),
        isTrue,
        reason: '$label ends outside its control',
      );
    }
    expect(pane.contains(bounds.topLeft), isTrue, reason: label);
    expect(pane.contains(bounds.bottomRight), isTrue, reason: label);
    for (final other in controls) {
      expect(bounds.overlaps(other), isFalse, reason: '$label overlaps a peer');
    }
    controls.add(bounds);
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final accessible in [false, true]) {
    testWidgets(
      'media controls preserve complete ${accessible ? 'large spaced bold' : 'desktop default'} labels across wrap and busy states',
      (tester) async {
        final fixture = await _mount(tester, accessible: accessible);
        final originalValue = fixture.content.value;
        final elements = {
          for (final label in _labels) label: tester.element(_button(label)),
        };
        final glassStates = {
          for (final label in _labels)
            label: tester.state(
              find.descendant(
                of: _button(label),
                matching: find.byType(GlassButton),
              ),
            ),
        };
        void expectRetained() {
          for (final label in _labels) {
            expect(tester.element(_button(label)), same(elements[label]));
            expect(
              tester.state(
                find.descendant(
                  of: _button(label),
                  matching: find.byType(GlassButton),
                ),
              ),
              same(glassStates[label]),
            );
          }
          expect(fixture.content.value, originalValue);
        }

        for (final width in [800.0, 280.0, 800.0]) {
          fixture.width.value = width;
          await _frames(tester);
          _expectCompleteLabels(tester);
          expectRetained();
          final upload = tester.getRect(_button('上传图片'));
          final settings = tester.getRect(_button('图床设置'));
          if (width == 280) {
            expect(settings.top, greaterThanOrEqualTo(upload.bottom));
          } else {
            expect(settings.top, closeTo(upload.top, .01));
          }
        }
        await tester.tap(_button('表情'));
        await tester.tap(_button('图床设置'));
        await _frames(tester);
        expect(fixture.stickers, 1);
        expect(fixture.settings, 1);
        expect(fixture.native.calls, isEmpty);

        fixture.enabled.value = false;
        fixture.width.value = 280;
        await _frames(tester);
        _expectCompleteLabels(tester);
        for (final label in _labels) {
          expect(tester.widget<DeskButton>(_button(label)).onTap, isNull);
          await tester.tap(_button(label), warnIfMissed: false);
        }
        expect(fixture.uploads, 0);
        expect(fixture.stickers, 1);
        expect(fixture.settings, 1);
        expectRetained();

        fixture.enabled.value = true;
        await _frames(tester);
        await tester.tap(_button('上传图片'));
        await _frames(tester);
        expect(
          fixture.media.phase,
          ComposerMediaPhase.selectingOrUploadingImage,
        );
        expect(fixture.uploads, 1);
        expect(fixture.native.calls, [
          'images.keyStatus',
          'system.chooseImage',
        ]);
        expect(tester.widget<DeskButton>(_button('上传图片')).busy, isTrue);
        for (final width in [280.0, 800.0]) {
          fixture.width.value = width;
          await _frames(tester);
          _expectCompleteLabels(tester);
          expectRetained();
          for (final label in _labels) {
            expect(tester.widget<DeskButton>(_button(label)).onTap, isNull);
            await tester.tap(_button(label), warnIfMissed: false);
          }
        }
        expect(fixture.uploads, 1);
        expect(fixture.stickers, 1);
        expect(fixture.settings, 1);
        fixture.native.imageChoice.complete({});
        await _frames(tester);
        expect(fixture.media.busy, isFalse);
        for (final label in _labels) {
          expect(tester.widget<DeskButton>(_button(label)).onTap, isNotNull);
        }
        _expectCompleteLabels(tester);
        expectRetained();
        expect(fixture.native.calls, [
          'images.keyStatus',
          'system.chooseImage',
        ]);
      },
    );
  }
}
