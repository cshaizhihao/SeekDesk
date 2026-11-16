import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_wordmark.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _palettes = ['Cobalt', 'Teal', 'Fern', 'Iris', 'Amber', 'Coral'];
const _labels = ['钴蓝', '海松', '蕨绿', '鸢尾', '琥珀', '珊瑚'];
const _boundsKey = ValueKey('settings-local-bounds');

class _SettingsNative extends NativeClient {
  _SettingsNative()
    : super(methods: const MethodChannel('seekdesk.test.settings-controls'));

  JsonMap settings = {
    'appearance': 'system',
    'workspace.logoPalette': 'Cobalt',
    'workspace.readingDensity': 'comfortable',
    'workspace.replySendKey': 'commandReturn',
  };
  final writes = <JsonMap>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'settings.get') return {...settings};
    if (method == 'settings.update') {
      writes.add({...arguments});
      settings = {
        ...settings,
        stringValue(arguments['key']): arguments['value'],
      };
      return {...settings};
    }
    unexpected.add(method);
    throw StateError('Unexpected settings fixture operation: $method');
  }
}

Future<_SettingsNative> _mount(
  WidgetTester tester, {
  required double width,
  double textScale = 1,
  ValueNotifier<double>? liveWidth,
  ValueNotifier<double>? liveTextScale,
  TextDirection direction = TextDirection.ltr,
  Brightness brightness = Brightness.light,
  bool nativeTheme = false,
  bool bold = false,
  double? lineHeight,
  double? letterSpacing,
  double? wordSpacing,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1800));
  final native = _SettingsNative();
  final state = AppState(client: native)..connecting = false;
  final paneWidth = liveWidth ?? ValueNotifier(width);
  final paneScale = liveTextScale ?? ValueNotifier(textScale);
  state.domains['settings'] = {...native.settings};
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    if (liveWidth == null) paneWidth.dispose();
    if (liveTextScale == null) paneScale.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  final app = GlassAdaptiveScope(
    minQuality: GlassQuality.minimal,
    maxQuality: GlassQuality.minimal,
    child: CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      home: ValueListenableBuilder<double>(
        valueListenable: paneScale,
        builder: (context, currentScale, _) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(
                textScaler: TextScaler.linear(currentScale),
                disableAnimations: true,
                boldText: bold,
              )
              .applyTextStyleOverrides(
                lineHeightScaleFactorOverride: lineHeight,
                letterSpacingOverride: letterSpacing,
                wordSpacingOverride: wordSpacing,
                paragraphSpacingOverride: null,
              ),
          child: Directionality(
            textDirection: direction,
            child: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.topCenter,
                child: ValueListenableBuilder<double>(
                  valueListenable: paneWidth,
                  child: PreferencesScreen(state: state),
                  builder: (context, currentWidth, child) => SizedBox(
                    key: _boundsKey,
                    width: currentWidth,
                    height: 1600,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    nativeTheme
        ? GlassTheme(
            data: GlassThemeData.ios27(brightness: brightness),
            child: app,
          )
        : app,
  );
  await _frames(tester);
  return native;
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _tab(WidgetTester tester, String title) async {
  final tab = find.text(title);
  await tester.ensureVisible(tab);
  await tester.pump();
  await tester.tap(tab);
  await _frames(tester);
}

Finder _theme(String value) => find.byKey(ValueKey('appearance-$value'));

Finder _brand(String palette) =>
    find.byKey(ValueKey('preference-brand-$palette'));

Finder _choice(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.semanticLabel == label,
);

void _insideHorizontally(WidgetTester tester, Finder finder, Rect bounds) {
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
  expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
}

void _expectControlsInside(WidgetTester tester) {
  final bounds = tester.getRect(find.byKey(_boundsKey));
  final controls = find.byWidgetPredicate(
    (widget) =>
        widget is DeskButton ||
        widget is GlassSlider ||
        widget is GlassSwitch ||
        widget is GlassSegmentedControl,
  );
  for (var index = 0; index < controls.evaluate().length; index++) {
    _insideHorizontally(tester, controls.at(index), bounds);
  }
  expect(tester.takeException(), isNull);
}

void _expectCompleteSegmentLabels(WidgetTester tester) {
  final controls = find.byType(GlassSegmentedControl);
  for (var i = 0; i < controls.evaluate().length; i++) {
    final control = controls.at(i);
    final widget = tester.widget<GlassSegmentedControl>(control);
    final bounds = widget.padding
        .resolve(Directionality.of(tester.element(control)))
        .deflateRect(tester.getRect(control));
    final paintedLabels = <Rect>[];
    for (final segment in widget.segments) {
      final label = segment.label!;
      final text = find.descendant(of: control, matching: find.text(label));
      final paragraph = tester.renderObject<RenderParagraph>(text);
      expect(paragraph.didExceedMaxLines, isFalse, reason: '$label truncated');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: label.length),
      );
      expect(boxes, isNotEmpty);
      final painted = boxes
          .map((box) => box.toRect())
          .reduce((a, b) => a.expandToInclude(b))
          .shift(paragraph.localToGlobal(Offset.zero));
      for (final rect in [tester.getRect(text), painted]) {
        expect(
          rect.left,
          greaterThanOrEqualTo(bounds.left - .01),
          reason: label,
        );
        expect(
          rect.right,
          lessThanOrEqualTo(bounds.right + .01),
          reason: label,
        );
        expect(rect.top, greaterThanOrEqualTo(bounds.top - .01), reason: label);
        expect(
          rect.bottom,
          lessThanOrEqualTo(bounds.bottom + .01),
          reason: label,
        );
      }
      for (final other in paintedLabels) {
        expect(painted.overlaps(other), isFalse, reason: '$label overlaps');
      }
      paintedLabels.add(painted);
    }
  }
}

void _expectSelected(WidgetTester tester, String palette) {
  for (var index = 0; index < _palettes.length; index++) {
    final data = tester
        .getSemantics(_brand(_palettes[index]))
        .getSemanticsData();
    expect(data.label, _labels[index]);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
      data.flagsCollection.isSelected,
      _palettes[index] == palette ? Tristate.isTrue : Tristate.isFalse,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [360.0, 420.0, 760.0]) {
    testWidgets('large settings labels remain complete at local width $width', (
      tester,
    ) async {
      final native = await _mount(tester, width: width, textScale: 2);
      _expectCompleteSegmentLabels(tester);
      await _tab(tester, '外观');
      _expectControlsInside(tester);
      _expectCompleteSegmentLabels(tester);
      expect(native.writes, isEmpty);
    });
  }

  for (final width in [280.0, 420.0, 760.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('native large bold RTL labels fit at $width $brightness', (
        tester,
      ) async {
        final native = await _mount(
          tester,
          width: width,
          textScale: 2,
          direction: TextDirection.rtl,
          nativeTheme: true,
          brightness: brightness,
          bold: true,
        );
        _expectControlsInside(tester);
        _expectCompleteSegmentLabels(tester);
        await _tab(tester, '外观');
        _expectControlsInside(tester);
        _expectCompleteSegmentLabels(tester);
        expect(native.writes, isEmpty);
      });
    }
  }

  for (final direction in TextDirection.values) {
    testWidgets('settings sparse mouse drag changes sections in $direction', (
      tester,
    ) async {
      final native = await _mount(tester, width: 760, direction: direction);
      final pointer = await tester.startGesture(
        tester.getCenter(find.text('通用')),
        kind: PointerDeviceKind.mouse,
      );
      await pointer.moveTo(tester.getCenter(find.text('外观')));
      await pointer.up();
      await pointer.removePointer();
      await _frames(tester);
      expect(find.text('跟随系统'), findsOneWidget);
      expect(native.writes, isEmpty);
      _expectCompleteSegmentLabels(tester);
      expect(tester.takeException(), isNull);
    });

    for (final narrow in [false, true]) {
      testWidgets(
        'settings fast mouse landing stays on appearance in $direction narrow=$narrow',
        (tester) async {
          final native = await _mount(
            tester,
            width: narrow ? 280 : 760,
            textScale: narrow ? 2 : 1,
            direction: direction,
          );
          for (final from in ['通用', '阅读']) {
            await _tab(tester, from);
            final start = tester.getCenter(find.text(from));
            final end = tester.getCenter(find.text('外观'));
            final pointer = await tester.startGesture(
              start,
              kind: PointerDeviceKind.mouse,
            );
            for (var step = 1; step <= 8; step++) {
              await pointer.moveTo(
                Offset.lerp(start, end, step / 8)!,
                timeStamp: Duration(milliseconds: step * 8),
              );
              await tester.pump(const Duration(milliseconds: 8));
            }
            await pointer.up(timeStamp: const Duration(milliseconds: 65));
            await pointer.removePointer();
            await _frames(tester);
            expect(find.text('跟随系统'), findsOneWidget);
            expect(find.text('界面外观'), findsOneWidget);
            expect(
              tester
                  .widget<GlassSegmentedControl>(
                    find.byType(GlassSegmentedControl).first,
                  )
                  .selectedIndex,
              1,
            );
            _expectCompleteSegmentLabels(tester);
          }
          expect(native.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final width in [420.0, 760.0]) {
    testWidgets(
      'system text spacing keeps settings labels complete at $width',
      (tester) async {
        final native = await _mount(
          tester,
          width: width,
          textScale: 2,
          nativeTheme: true,
          lineHeight: 2,
          letterSpacing: 4,
          wordSpacing: 6,
        );
        _expectCompleteSegmentLabels(tester);
        await _tab(tester, '外观');
        _expectCompleteSegmentLabels(tester);
        for (var i = 0; i < _palettes.length; i++) {
          final card = _brand(_palettes[i]);
          final label = find.descendant(
            of: card,
            matching: find.text(_labels[i]),
          );
          final bounds = tester.getRect(card).deflate(9);
          final text = tester.getRect(label);
          expect(text.left, greaterThanOrEqualTo(bounds.left - .01));
          expect(text.right, lessThanOrEqualTo(bounds.right + .01));
          expect(text.top, greaterThanOrEqualTo(bounds.top - .01));
          expect(text.bottom, lessThanOrEqualTo(bounds.bottom + .01));
          expect(
            tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
            isFalse,
          );
        }
        expect(native.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'theme cards retain keyboard focus when stacked and when text resizes',
    (tester) async {
      final width = ValueNotifier(760.0), scale = ValueNotifier(2.0);
      addTearDown(width.dispose);
      addTearDown(scale.dispose);
      final native = await _mount(
        tester,
        width: 760,
        liveWidth: width,
        liveTextScale: scale,
      );
      await _tab(tester, '外观');
      final light = _theme('light'), dark = _theme('dark');
      final focus = Focus.of(tester.element(find.text('暖象牙')));
      focus.requestFocus();
      await _frames(tester);

      void retained() {
        expect(FocusManager.instance.primaryFocus, same(focus));
        _expectControlsInside(tester);
        final bounds = tester.getRect(find.byKey(_boundsKey));
        for (final card in [light, dark]) {
          _insideHorizontally(tester, card, bounds);
        }
      }

      expect(tester.getRect(light).top, tester.getRect(dark).top);
      for (final current in [420.0, 360.0, 760.0]) {
        width.value = current;
        await _frames(tester);
        retained();
        if (current == 760) {
          expect(tester.getRect(dark).top, tester.getRect(light).top);
        } else {
          expect(
            tester.getRect(dark).top,
            greaterThanOrEqualTo(tester.getRect(light).bottom),
          );
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(native.writes, [
        {'key': 'appearance', 'value': 'light'},
      ]);
      for (final current in [1.0, 1.3, 2.0]) {
        scale.value = current;
        await _frames(tester);
        retained();
      }
      width.value = 360;
      await _frames(tester);
      retained();
      await tester.tap(find.text('石墨蓝'));
      await _frames(tester);
      expect(native.writes, [
        {'key': 'appearance', 'value': 'light'},
        {'key': 'appearance', 'value': 'dark'},
      ]);
      expect(native.settings['appearance'], 'dark');
    },
  );

  testWidgets('held appearance tap invalidates when labels reflow vertically', (
    tester,
  ) async {
    final width = ValueNotifier(760.0);
    addTearDown(width.dispose);
    final native = await _mount(
      tester,
      width: 760,
      textScale: 2,
      liveWidth: width,
    );
    await _tab(tester, '外观');
    final pointer = await tester.startGesture(
      tester.getCenter(find.text('石墨蓝')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 150));
    width.value = 360;
    await _frames(tester);
    await pointer.up();
    await pointer.removePointer();
    await _frames(tester);
    expect(native.writes, isEmpty);
    _expectCompleteSegmentLabels(tester);
    await tester.tap(find.text('石墨蓝'));
    await _frames(tester);
    expect(native.writes, [
      {'key': 'appearance', 'value': 'dark'},
    ]);
  });

  for (final width in [360.0, 420.0, 760.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'settings controls stay within local width $width at text scale $scale',
        (tester) async {
          final native = await _mount(tester, width: width, textScale: scale);
          _expectControlsInside(tester);

          await _tab(tester, '外观');
          _expectControlsInside(tester);
          final bounds = tester.getRect(find.byKey(_boundsKey));
          final labelLeft = tester.getTopLeft(find.text('品牌配色')).dx;
          expect(
            labelLeft,
            closeTo(tester.getTopLeft(find.text('配色')).dx, .01),
          );
          expect(
            tester.getTopLeft(_brand('Cobalt')).dx,
            closeTo(labelLeft, .01),
          );
          final cards = <Rect>[];
          for (final palette in _palettes) {
            final card = _brand(palette);
            _insideHorizontally(tester, card, bounds);
            final artwork = find.descendant(
              of: card,
              matching: find.byType(DeskWordmark),
            );
            expect(artwork, findsOneWidget);
            expect(tester.widget<DeskWordmark>(artwork).palette, palette);
            final rect = tester.getRect(card);
            final image = tester.getRect(artwork);
            expect(image.left, greaterThanOrEqualTo(rect.left));
            expect(image.right, lessThanOrEqualTo(rect.right));
            expect(image.top, greaterThanOrEqualTo(rect.top));
            expect(image.bottom, lessThanOrEqualTo(rect.bottom));
            for (final previous in cards) {
              expect(rect.overlaps(previous), isFalse);
            }
            cards.add(rect);
          }
          for (final palette in _palettes) {
            final card = _brand(palette);
            await tester.ensureVisible(card);
            await tester.pump();
            expect(card.hitTestable(), findsOneWidget);
          }

          await _tab(tester, '阅读');
          _expectControlsInside(tester);
          for (final title in ['阅读密度', '发送回复快捷键']) {
            expect(
              tester.getTopLeft(find.text(title)).dx,
              closeTo(tester.getTopLeft(find.text('正文文字')).dx, .01),
            );
          }
          await _tab(tester, '关于');
          _expectControlsInside(tester);
          expect(native.writes, isEmpty);
        },
      );
    }
  }

  testWidgets(
    'brand pointer and accessibility selection write once and expose the selected option',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final native = await _mount(tester, width: 760);
        await _tab(tester, '外观');
        _expectSelected(tester, 'Cobalt');
        await tester.tap(_brand('Cobalt'));
        await _frames(tester);
        expect(native.writes, isEmpty);

        final labelBefore = tester.getRect(find.text('海松'));
        final cardBefore = tester.getRect(_brand('Teal'));
        await tester.tap(_brand('Teal'));
        await _frames(tester);
        expect(native.writes, [
          {'key': 'workspace.logoPalette', 'value': 'Teal'},
        ]);
        _expectSelected(tester, 'Teal');
        expect(tester.getRect(find.text('海松')), labelBefore);
        expect(tester.getRect(_brand('Teal')), cardBefore);
        await tester.tap(_brand('Teal'));
        await _frames(tester);
        expect(native.writes, hasLength(1));

        final node = tester.getSemantics(_brand('Fern'));
        tester
            .renderObject(_brand('Fern'))
            .owner!
            .semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        await _frames(tester);
        expect(native.writes, [
          {'key': 'workspace.logoPalette', 'value': 'Teal'},
          {'key': 'workspace.logoPalette', 'value': 'Fern'},
        ]);
        _expectSelected(tester, 'Fern');
        final selected = tester.getSemantics(_brand('Fern'));
        tester
            .renderObject(_brand('Fern'))
            .owner!
            .semanticsOwner!
            .performAction(selected.id, SemanticsAction.tap);
        await _frames(tester);
        expect(native.writes, hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'reading choices expose selection and ignore activation of the current value',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final native = await _mount(tester, width: 420, textScale: 1.3);
        await _tab(tester, '阅读');
        for (final (selected, other, key, value) in [
          ('舒适', '紧凑', 'workspace.readingDensity', 'compact'),
          ('⌘ Return', 'Return', 'workspace.replySendKey', 'returnKey'),
        ]) {
          await tester.ensureVisible(_choice(selected));
          await tester.pump();
          expect(
            tester
                .getSemantics(_choice(selected))
                .getSemanticsData()
                .flagsCollection
                .isSelected,
            Tristate.isTrue,
          );
          final count = native.writes.length;
          await tester.tap(_choice(selected));
          await _frames(tester);
          expect(native.writes, hasLength(count));
          await tester.ensureVisible(_choice(other));
          await tester.tap(_choice(other));
          await _frames(tester);
          expect(native.writes, hasLength(count + 1));
          expect(native.writes.last, {'key': key, 'value': value});
          expect(
            tester
                .getSemantics(_choice(other))
                .getSemanticsData()
                .flagsCollection
                .isSelected,
            Tristate.isTrue,
          );
          await tester.tap(_choice(other));
          await _frames(tester);
          expect(native.writes, hasLength(count + 1));
        }
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'slider reset retains its glass state and focus across wide and narrow headers',
    (tester) async {
      final width = ValueNotifier(760.0);
      addTearDown(width.dispose);
      final native = await _mount(
        tester,
        width: width.value,
        textScale: 1.3,
        liveWidth: width,
      );
      const preference = 'workspace.sidebarWidth';
      native.settings = {
        ...native.settings,
        preference: 250.0,
        'workspace.topicColumnWidth': 412.0,
      };
      final state = tester
          .widget<PreferencesScreen>(find.byType(PreferencesScreen))
          .state;
      await state.act('settings.get', {}, 'settings');
      await _tab(tester, '外观');
      final initialSettings = {...native.settings};
      final reset = find.byKey(
        const ValueKey('preference-reset-workspace.sidebarWidth'),
      );
      await tester.ensureVisible(reset);
      await _frames(tester);
      expect(tester.widget<DeskButton>(reset).onTap, isNotNull);
      final glass = find.descendant(
        of: reset,
        matching: find.byType(GlassButton),
      );
      final focusRegion = find.descendant(
        of: reset,
        matching: find.byType(FocusableActionDetector),
      );
      expect(glass, findsOneWidget);
      expect(focusRegion, findsOneWidget);
      final resetElement = tester.element(reset);
      final glassState = tester.state(glass);
      final focusState = tester.state(focusRegion);
      final focus = tester
          .widget<FocusableActionDetector>(focusRegion)
          .focusNode!;
      focus.requestFocus();
      await _frames(tester);
      final initialRect = tester.getRect(reset);
      final initialLabel = tester.getRect(find.text('侧边栏宽度'));
      expect(initialRect.top, lessThan(initialLabel.bottom));
      expect(initialRect.bottom, greaterThan(initialLabel.top));

      void expectRetained() {
        expect(tester.element(reset), same(resetElement));
        expect(tester.state(glass), same(glassState));
        expect(tester.state(focusRegion), same(focusState));
        expect(
          tester.widget<FocusableActionDetector>(focusRegion).focusNode,
          same(focus),
        );
        expect(FocusManager.instance.primaryFocus, same(focus));
        expect(reset.hitTestable(), findsOneWidget);
        expect(native.writes, isEmpty);
        _expectControlsInside(tester);
      }

      width.value = 420;
      await _frames(tester);
      expectRetained();
      final compactRect = tester.getRect(reset);
      final compactLabel = tester.getRect(find.text('侧边栏宽度'));
      expect(compactRect.top, greaterThanOrEqualTo(compactLabel.bottom));
      expect(
        tester.getRect(find.text('250 点')).left,
        closeTo(compactLabel.left, .01),
      );

      width.value = 760;
      await _frames(tester);
      expectRetained();
      expect(tester.getRect(reset), initialRect);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(native.writes, [
        {'key': preference, 'value': 228.0},
      ]);
      expect(native.settings, {...initialSettings, preference: 228.0});
      expect(state.domain('settings'), native.settings);
      expect(tester.widget<DeskButton>(reset).onTap, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('theme previews update with the reading background setting', (
    tester,
  ) async {
    final native = await _mount(tester, width: 760);
    await _tab(tester, '外观');

    List<String> previewImages() => [
      for (final value in ['light', 'dark'])
        ((tester
                            .widget<Image>(
                              find.descendant(
                                of: _theme(value),
                                matching: find.byType(Image),
                              ),
                            )
                            .image
                        as ResizeImage)
                    .imageProvider
                as AssetImage)
            .assetName,
    ];
    expect(previewImages(), [
      'assets/reader/reader-light.png',
      'assets/reader/reader-dark.png',
    ]);
    await tester.tap(find.text('石墨蓝'));
    await _frames(tester);
    expect(native.settings['appearance'], 'dark');
    await tester.tap(find.text('跟随系统'));
    await _frames(tester);
    expect(native.settings['appearance'], 'system');
    await tester.tap(find.text('山岚'));
    await _frames(tester);
    expect(native.settings['workspace.themeFamily'], 'mountain');
    expect(native.settings['appearance'], 'system');
    expect(previewImages(), [
      'assets/reader/mist-lake.jpg',
      'assets/reader/pine-dusk.jpg',
    ]);
    await tester.tap(find.text('海岸'));
    await _frames(tester);
    expect(native.settings['workspace.themeFamily'], 'coast');
    expect(previewImages(), [
      'assets/reader/sea-glass.jpg',
      'assets/reader/midnight-tide.jpg',
    ]);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassSwitch && widget.semanticLabel == '阅读背景',
      ),
    );
    await _frames(tester);
    for (final value in ['light', 'dark']) {
      expect(
        find.descendant(of: _theme(value), matching: find.byType(Image)),
        findsNothing,
      );
    }
    expect(native.settings['workspace.mistBackdrop'], false);
  });
}
