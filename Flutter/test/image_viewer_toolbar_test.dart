import 'dart:math' as math;
import 'dart:ui' show SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/image_viewer_toolbar.dart';

final _metricStyle = DeskTypography.base.merge(DeskTypography.control);
const _metricTexts = ['400%', '原尺寸'];

/// Observe the SDK's real temporary measurement objects, without installing a
/// production callback or counting visible RenderParagraph layout. These exact
/// fixed-label painters are constructed, laid out once and disposed by the
/// toolbar's measurement; visible labels instead configure an ellipsis.
class _MetricAllocations {
  final created =
      <({String text, TextDirection? direction, TextScaler scaler})>[];
  final disposed = <String>[];
  final _live = <TextPainter, String>{};

  void observe(ObjectEvent event) {
    final object = event.object;
    if (event is ObjectCreated &&
        event.library == 'package:flutter/painting.dart' &&
        event.className == 'TextPainter' &&
        object is TextPainter) {
      final span = object.text;
      if (span is! TextSpan ||
          !_metricTexts.contains(span.text) ||
          object.maxLines != 1 ||
          object.ellipsis != null) {
        return;
      }
      final text = span.text!;
      _live[object] = text;
      created.add((
        text: text,
        direction: object.textDirection,
        scaler: object.textScaler,
      ));
    } else if (event is ObjectDisposed && object is TextPainter) {
      final text = _live.remove(object);
      if (text != null) disposed.add(text);
    }
  }

  void expectDisposed() {
    expect(_live, isEmpty);
    expect(disposed, orderedEquals(created.map((item) => item.text)));
  }
}

_MetricAllocations _observeMetrics() {
  expect(kFlutterMemoryAllocationsEnabled, isTrue);
  final metrics = _MetricAllocations();
  FlutterMemoryAllocations.instance.addListener(metrics.observe);
  addTearDown(() {
    FlutterMemoryAllocations.instance.removeListener(metrics.observe);
    metrics.expectDisposed();
  });
  return metrics;
}

/// Preserve the production theme's control widths and minimum heights while
/// allowing the measured line height plus its existing vertical allowance.
/// Call before observing allocations so these independent measurements cannot
/// satisfy production allocation assertions.
({double fit, double original, double height}) _expectedMetrics(
  TextScaler scaler,
  TextDirection direction,
) {
  Size measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _metricStyle),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    try {
      return painter.size;
    } finally {
      painter.dispose();
    }
  }

  final fit = measure('400%');
  final original = measure('原尺寸');
  return (
    fit: math.max(62.0, fit.width + 22),
    original: math.max(92.0, original.width + 46),
    height: math.max(
      math.max(34.0, scaler.scale(12) * 1.25 + 16),
      math.max(fit.height, original.height) + 16,
    ),
  );
}

class _CurvedTextScaler extends TextScaler {
  const _CurvedTextScaler();

  @override
  double scale(double fontSize) => fontSize * (1 + 12 / (fontSize + 12));

  @override
  double get textScaleFactor => scale(14) / 14;
}

DeskButton _originalButton(WidgetTester tester) =>
    tester.widget<DeskButton>(find.byKey(ImageViewerToolbar.originalSizeKey));

void _expectFullVisibleLabels(WidgetTester tester) {
  final labels = [
    (key: ImageViewerToolbar.fitKey, text: '400%'),
    (key: ImageViewerToolbar.originalSizeKey, text: '原尺寸'),
  ];
  final reports =
      <
        ({
          String text,
          RenderParagraph visible,
          Rect buttonBounds,
          Size naturalSize,
          Rect naturalGlyphBounds,
          List<Rect> visibleGlyphs,
          List<Rect> finalGlyphs,
        })
      >[];
  for (final label in labels) {
    final button = find.byKey(label.key);
    final text = find.descendant(
      of: button,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText() == label.text,
      ),
    );
    expect(text, findsOneWidget);
    final visible = tester.renderObject<RenderParagraph>(text);
    // Start from the paragraph actually produced by SDK Text, after inherited
    // styles/accessibility overrides. An unconstrained renderer reveals text
    // hidden by ellipsis; no toolbar sizing or style-resolution formula is
    // reproduced here.
    final natural = RenderParagraph(
      visible.text,
      textAlign: visible.textAlign,
      textDirection: visible.textDirection,
      textScaler: visible.textScaler,
      locale: visible.locale,
      strutStyle: visible.strutStyle,
      textWidthBasis: visible.textWidthBasis,
      textHeightBehavior: visible.textHeightBehavior,
      hyphens: visible.hyphens,
      softWrap: false,
      overflow: TextOverflow.visible,
      maxLines: 1,
    );
    try {
      natural.layout(const BoxConstraints());
      final selection = TextSelection(
        baseOffset: 0,
        extentOffset: label.text.length,
      );
      final naturalBoxes = natural.getBoxesForSelection(selection);
      expect(natural.didExceedMaxLines, isFalse);
      expect(naturalBoxes, isNotEmpty);
      List<Rect> globalBoxes(TextSelection range) => visible
          .getBoxesForSelection(range)
          .map(
            (box) => MatrixUtils.transformRect(
              visible.getTransformTo(null),
              box.toRect(),
            ),
          )
          .toList();
      reports.add((
        text: label.text,
        visible: visible,
        buttonBounds: tester.getRect(button),
        naturalSize: natural.size,
        naturalGlyphBounds: naturalBoxes
            .map((box) => box.toRect())
            .reduce((a, b) => a.expandToInclude(b)),
        visibleGlyphs: globalBoxes(selection),
        finalGlyphs: globalBoxes(
          TextSelection(
            baseOffset: label.text.length - 1,
            extentOffset: label.text.length,
          ),
        ),
      ));
    } finally {
      natural.dispose();
    }
  }
  // Report both labels before the first assertion so a baseline width failure
  // cannot conceal the original-size label's independent height evidence.
  // ignore: avoid_print
  print(
    'toolbarVisibleLabelMetrics=${[
      for (final report in reports) {'text': report.text, 'visible': report.visible.size.toString(), 'natural': report.naturalSize.toString(), 'naturalGlyphs': report.naturalGlyphBounds.toString(), 'ellipsized': report.visible.didExceedMaxLines},
    ]}',
  );
  for (final report in reports) {
    final reason = '${report.text} must remain fully readable';
    expect(report.visible.didExceedMaxLines, isFalse, reason: reason);
    expect(
      report.naturalSize.width,
      lessThanOrEqualTo(report.visible.size.width + .01),
      reason: '$reason: natural advance exceeds the visible paragraph',
    );
    expect(
      report.naturalGlyphBounds.width,
      lessThanOrEqualTo(report.visible.size.width + .01),
      reason: '$reason: natural glyph bounds exceed the visible paragraph',
    );
    expect(
      report.naturalSize.height,
      lessThanOrEqualTo(report.visible.size.height + .01),
      reason: '$reason: natural line height is clipped',
    );
    expect(report.visibleGlyphs, isNotEmpty, reason: reason);
    expect(report.finalGlyphs, isNotEmpty, reason: '$reason: last character');
    // Natural glyph boxes can extend by half the letter spacing past a loose
    // paragraph's advance without overflow clipping. The visible button must
    // contain those boxes; the natural advance/height checks above cover the
    // paragraph's allocation independently.
    for (final glyph in [...report.visibleGlyphs, ...report.finalGlyphs]) {
      expect(
        glyph.left,
        greaterThanOrEqualTo(report.buttonBounds.left - .01),
        reason: reason,
      );
      expect(
        glyph.right,
        lessThanOrEqualTo(report.buttonBounds.right + .01),
        reason: reason,
      );
      expect(
        glyph.top,
        greaterThanOrEqualTo(report.buttonBounds.top - .01),
        reason: reason,
      );
      expect(
        glyph.bottom,
        lessThanOrEqualTo(report.buttonBounds.bottom + .01),
        reason: reason,
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(
    WidgetTester tester, {
    String label = '',
    double width = 800,
    double textScale = 1,
    TextScaler? textScaler,
    TextDirection direction = TextDirection.ltr,
    Brightness brightness = Brightness.dark,
    bool reduceMotion = false,
    Key? toolbarKey,
    double scale = 1,
    bool originalSize = false,
    bool enabled = true,
    List<String>? actions,
  }) => tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        theme: CupertinoThemeData(
          brightness: brightness,
          textTheme: CupertinoTextThemeData(
            textStyle: DeskTypography.base.copyWith(
              color: brightness == Brightness.dark
                  ? const Color(0xffeceef3)
                  : const Color(0xff252832),
            ),
          ),
        ),
        home: CupertinoPageScaffold(
          backgroundColor: const Color(0xff101114),
          child: MediaQuery(
            data: MediaQueryData(
              textScaler: textScaler ?? TextScaler.linear(textScale),
              disableAnimations: reduceMotion,
            ),
            child: Directionality(
              textDirection: direction,
              child: Center(
                child: SizedBox(
                  width: width,
                  child: ImageViewerToolbar(
                    key: toolbarKey,
                    label: label,
                    scale: scale,
                    originalSize: originalSize,
                    enabled: enabled,
                    onZoomOut: () => actions?.add('out'),
                    onZoomIn: () => actions?.add('in'),
                    onFit: () => actions?.add('fit'),
                    onOriginalSize: () => actions?.add('original'),
                    onClose: () => actions?.add('close'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('fit and original size expose the percentage basis', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final actions = <String>[];
    await mount(tester, scale: 1.75, actions: actions);
    expect(find.text('图片预览'), findsOneWidget);
    expect(find.text('175%'), findsOneWidget);
    expect(find.bySemanticsLabel('当前为适合窗口基准的 175%，点按适合窗口'), findsOneWidget);
    await tester.tap(find.byKey(ImageViewerToolbar.fitKey));
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    expect(actions, ['fit', 'original']);

    await mount(tester, originalSize: true);
    expect(find.bySemanticsLabel('当前为原尺寸基准的 100%，点按适合窗口'), findsOneWidget);
    final original = tester
        .getSemantics(find.byKey(ImageViewerToolbar.originalSizeKey))
        .getSemanticsData();
    expect(original.flagsCollection.isSelected, Tristate.isTrue);
    expect(original.label, '原尺寸，已选中');
    semantics.dispose();
  });

  testWidgets('zoom boundaries disable only the exhausted direction', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final actions = <String>[];
    for (final scale in [.5, 4.0]) {
      await mount(tester, scale: scale, actions: actions);
      final disabled = scale == .5
          ? ImageViewerToolbar.zoomOutKey
          : ImageViewerToolbar.zoomInKey;
      final active = scale == .5
          ? ImageViewerToolbar.zoomInKey
          : ImageViewerToolbar.zoomOutKey;
      expect(
        tester
            .getSemantics(find.byKey(disabled))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        false,
      );
      await tester.tap(find.byKey(disabled), warnIfMissed: false);
      await tester.tap(find.byKey(active));
    }
    expect(actions, ['in', 'out']);
    semantics.dispose();
  });

  testWidgets('invalid source disables image tools but keeps close usable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final actions = <String>[];
    await mount(tester, enabled: false, actions: actions);
    for (final key in [
      ImageViewerToolbar.zoomOutKey,
      ImageViewerToolbar.zoomInKey,
      ImageViewerToolbar.fitKey,
      ImageViewerToolbar.originalSizeKey,
    ]) {
      expect(
        tester
            .getSemantics(find.byKey(key))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        false,
      );
    }
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    expect(actions, ['close']);
    semantics.dispose();
  });

  testWidgets('narrow toolbar and large type retain all controls', (
    tester,
  ) async {
    final actions = <String>[];
    for (final textScale in [1.0, 2.5]) {
      await mount(
        tester,
        label: '很长的图片标题 LongUnbrokenImageDescription',
        width: 220,
        textScale: textScale,
        actions: actions,
      );
      expect(tester.takeException(), isNull);
      for (final key in [
        ImageViewerToolbar.zoomOutKey,
        ImageViewerToolbar.fitKey,
        ImageViewerToolbar.zoomInKey,
        ImageViewerToolbar.originalSizeKey,
        ImageViewerToolbar.closeKey,
      ]) {
        final rect = tester.getRect(find.byKey(key));
        final toolbar = tester.getRect(find.byType(ImageViewerToolbar));
        expect(rect.left, greaterThanOrEqualTo(toolbar.left));
        expect(rect.right, lessThanOrEqualTo(toolbar.right));
        await tester.tap(find.byKey(key));
      }
      final buttons = tester.widgetList<DeskButton>(find.byType(DeskButton));
      expect(buttons.where((button) => button.label == '原尺寸'), hasLength(1));
    }
    expect(actions, [
      'out',
      'fit',
      'in',
      'original',
      'close',
      'out',
      'fit',
      'in',
      'original',
      'close',
    ]);
  });

  testWidgets('generic alt text falls back and non-finite scale stays safe', (
    tester,
  ) async {
    await mount(tester, label: ' IMAGE ', scale: double.nan);
    expect(find.text('图片预览'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('warm zoom updates reuse both fixed text measurements', (
    tester,
  ) async {
    final metrics = _observeMetrics();
    await mount(tester);
    await tester.pumpAndSettle();
    final toolbar = tester.element(find.byType(ImageViewerToolbar));
    expect(metrics.created.map((item) => item.text), _metricTexts);
    metrics.expectDisposed();
    final fitWidth = tester
        .widget<DeskButton>(find.byKey(ImageViewerToolbar.fitKey))
        .width;
    final originalWidth = _originalButton(tester).width;
    final perUpdate = <int>[];
    for (final scale in [1.02, 1.17, 1.25, 1.43, 1.75, 2.5, 3.2, 4.0, .5]) {
      final before = metrics.created.length;
      await mount(tester, scale: scale);
      await tester.pumpAndSettle();
      perUpdate.add(metrics.created.length - before);
      expect(tester.element(find.byType(ImageViewerToolbar)), same(toolbar));
      expect(find.text('${(scale * 100).round()}%'), findsOneWidget);
      expect(
        tester.widget<DeskButton>(find.byKey(ImageViewerToolbar.fitKey)).width,
        fitWidth,
      );
      expect(_originalButton(tester).width, originalWidth);
      metrics.expectDisposed();
      expect(tester.takeException(), isNull);
    }
    // These are paired SDK allocation/disposal counts for one-shot measuring
    // painters; they are not native paragraph-layout timings or FPS evidence.
    // ignore: avoid_print
    print('toolbarFixedTextPaintersPerZoomUpdate=$perUpdate');
    expect(perUpdate, everyElement(0));
  });

  testWidgets(
    'non-metric toolbar changes preserve measurement cache and actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final metrics = _observeMetrics();
        final oldActions = <String>[], currentActions = <String>[];
        await mount(tester, actions: oldActions);
        await tester.pumpAndSettle();
        final toolbar = tester.element(find.byType(ImageViewerToolbar));
        final before = metrics.created.length;
        await mount(
          tester,
          label: 'New image title',
          width: 220,
          brightness: Brightness.light,
          reduceMotion: true,
          originalSize: true,
          actions: currentActions,
        );
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(ImageViewerToolbar)), same(toolbar));
        expect(find.text('New image title'), findsOneWidget);
        expect(find.bySemanticsLabel('当前为原尺寸基准的 100%，点按适合窗口'), findsOneWidget);
        for (final key in [
          ImageViewerToolbar.zoomOutKey,
          ImageViewerToolbar.fitKey,
          ImageViewerToolbar.zoomInKey,
          ImageViewerToolbar.originalSizeKey,
          ImageViewerToolbar.closeKey,
        ]) {
          await tester.tap(find.byKey(key));
        }
        expect(currentActions, ['out', 'fit', 'in', 'original', 'close']);
        expect(oldActions, isEmpty);
        await mount(tester, enabled: false, actions: currentActions);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.byKey(ImageViewerToolbar.fitKey))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
        expect(currentActions.last, 'close');
        expect(metrics.created.length - before, 0);
        metrics.expectDisposed();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'fixed metrics refresh for direction and nonlinear text scaling',
    (tester) async {
      const curved = _CurvedTextScaler();
      // The legacy scale factor is identical, but scaling at the control's
      // actual font size differs. The full TextScaler must invalidate metrics.
      final linearizedCurved = TextScaler.linear(curved.textScaleFactor);
      final environments = [
        (scaler: TextScaler.noScaling, direction: TextDirection.ltr),
        (scaler: const TextScaler.linear(2.5), direction: TextDirection.ltr),
        (scaler: const TextScaler.linear(2.5), direction: TextDirection.rtl),
        (scaler: linearizedCurved, direction: TextDirection.rtl),
        (scaler: curved, direction: TextDirection.rtl),
        (scaler: TextScaler.noScaling, direction: TextDirection.ltr),
      ];
      final expected = [
        for (final environment in environments)
          _expectedMetrics(environment.scaler, environment.direction),
      ];
      final metrics = _observeMetrics();
      Element? toolbar;
      for (var index = 0; index < environments.length; index++) {
        final environment = environments[index];
        final before = metrics.created.length;
        await mount(
          tester,
          width: 220,
          textScaler: environment.scaler,
          direction: environment.direction,
        );
        await tester.pumpAndSettle();
        toolbar ??= tester.element(find.byType(ImageViewerToolbar));
        expect(tester.element(find.byType(ImageViewerToolbar)), same(toolbar));
        final measured = metrics.created.skip(before).toList();
        expect(measured.map((item) => item.text), _metricTexts);
        expect(
          measured.map((item) => item.direction),
          everyElement(environment.direction),
        );
        expect(
          measured.map((item) => item.scaler),
          everyElement(environment.scaler),
        );
        final fit = tester.widget<DeskButton>(
          find.byKey(ImageViewerToolbar.fitKey),
        );
        expect(fit.width, closeTo(expected[index].fit, .001));
        expect(fit.height, closeTo(expected[index].height, .001));
        expect(
          _originalButton(tester).width,
          closeTo(expected[index].original, .001),
        );
        final bounds = tester.getRect(find.byType(ImageViewerToolbar));
        for (final key in [
          ImageViewerToolbar.zoomOutKey,
          ImageViewerToolbar.fitKey,
          ImageViewerToolbar.zoomInKey,
          ImageViewerToolbar.originalSizeKey,
          ImageViewerToolbar.closeKey,
        ]) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
        }
        metrics.expectDisposed();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('inherited metric changes refresh an identical toolbar child', (
    tester,
  ) async {
    final environments = [
      (scaler: TextScaler.noScaling, direction: TextDirection.ltr),
      (scaler: const _CurvedTextScaler(), direction: TextDirection.ltr),
      (scaler: const _CurvedTextScaler(), direction: TextDirection.rtl),
      (scaler: TextScaler.noScaling, direction: TextDirection.rtl),
    ];
    final expected = [
      for (final environment in environments)
        _expectedMetrics(environment.scaler, environment.direction),
    ];
    final environment = ValueNotifier(environments.first);
    addTearDown(environment.dispose);
    final child = ImageViewerToolbar(
      label: 'Inherited metrics',
      scale: 1,
      originalSize: false,
      enabled: true,
      onZoomOut: () {},
      onZoomIn: () {},
      onFit: () {},
      onOriginalSize: () {},
      onClose: () {},
    );
    final metrics = _observeMetrics();
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          theme: CupertinoThemeData(
            brightness: Brightness.dark,
            textTheme: CupertinoTextThemeData(
              textStyle: DeskTypography.base.copyWith(
                color: const Color(0xffeceef3),
              ),
            ),
          ),
          home: ValueListenableBuilder(
            valueListenable: environment,
            child: Center(child: SizedBox(width: 220, child: child)),
            builder: (context, value, child) => MediaQuery(
              data: MediaQueryData(textScaler: value.scaler),
              child: Directionality(
                textDirection: value.direction,
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    final element = tester.element(find.byType(ImageViewerToolbar));
    for (var index = 0; index < environments.length; index++) {
      final before = index == 0 ? 0 : metrics.created.length;
      environment.value = environments[index];
      await tester.pumpAndSettle();
      expect(tester.widget(find.byType(ImageViewerToolbar)), same(child));
      expect(tester.element(find.byType(ImageViewerToolbar)), same(element));
      final measured = metrics.created.skip(before).toList();
      expect(measured.map((item) => item.text), _metricTexts);
      expect(
        measured.map((item) => item.scaler),
        everyElement(environments[index].scaler),
      );
      expect(
        measured.map((item) => item.direction),
        everyElement(environments[index].direction),
      );
      final fit = tester.widget<DeskButton>(
        find.byKey(ImageViewerToolbar.fitKey),
      );
      expect(fit.width, closeTo(expected[index].fit, .001));
      expect(fit.height, closeTo(expected[index].height, .001));
      expect(
        _originalButton(tester).width,
        closeTo(expected[index].original, .001),
      );
      metrics.expectDisposed();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'system fonts invalidate mounted metrics and retire with toolbar',
    (tester) async {
      final metrics = _observeMetrics();
      await mount(tester, toolbarKey: const ValueKey('first-toolbar'));
      await tester.pumpAndSettle();
      final first = tester.element(find.byType(ImageViewerToolbar));
      final initial = metrics.created.length;
      // Use the SDK system-font channel handler, not a toolbar-specific hook.
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pump();
      await tester.pumpAndSettle();
      final refreshed = metrics.created.length - initial;
      // ignore: avoid_print
      print('toolbarFixedTextPaintersAfterFontsChange=$refreshed');
      expect(refreshed, 2);
      expect(tester.element(find.byType(ImageViewerToolbar)), same(first));
      metrics.expectDisposed();

      // Replacing the toolbar must retire its listener and register the new one.
      // pumpWidget runs transient callbacks before the old child is disposed.
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await mount(tester, toolbarKey: const ValueKey('replacement-toolbar'));
      await tester.pumpAndSettle();
      final replacement = tester.element(find.byType(ImageViewerToolbar));
      expect(replacement, isNot(same(first)));
      final beforeReplacementRefresh = metrics.created.length;
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pump();
      await tester.pumpAndSettle();
      expect(metrics.created.length - beforeReplacementRefresh, 2);
      metrics.expectDisposed();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final retired = metrics.created.length;
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pump();
      await tester.pumpAndSettle();
      expect(metrics.created.length, retired);
      metrics.expectDisposed();
      expect(tester.takeException(), isNull);
    },
  );

  final visibleTextEnvironments = [
    (
      name: 'ordinary production theme',
      scale: 1.0,
      bold: false,
      lineHeight: null,
      letterSpacing: null,
      inherited: const TextStyle(),
    ),
    (
      name: 'realistic accessibility with inherited font',
      scale: 2.5,
      bold: true,
      lineHeight: 1.5,
      letterSpacing: 1.5,
      inherited: const TextStyle(fontFamily: 'monospace'),
    ),
    (
      name: 'line-height stress',
      scale: 2.5,
      bold: true,
      lineHeight: 2.0,
      letterSpacing: null,
      inherited: const TextStyle(),
    ),
    (
      name: 'system letter-spacing stress',
      scale: 2.5,
      bold: false,
      lineHeight: null,
      letterSpacing: 8.0,
      inherited: const TextStyle(),
    ),
    (
      name: 'inherited letter-spacing stress',
      scale: 2.5,
      bold: false,
      lineHeight: null,
      letterSpacing: null,
      inherited: const TextStyle(fontFamily: 'monospace', letterSpacing: 8),
    ),
  ];
  for (final environment in visibleTextEnvironments) {
    for (final width in [800.0, 220.0]) {
      testWidgets(
        'visible toolbar labels fit ${environment.name} at width $width',
        (tester) async {
          await tester.pumpWidget(
            GlassAdaptiveScope(
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: CupertinoApp(
                theme: CupertinoThemeData(
                  brightness: Brightness.dark,
                  textTheme: CupertinoTextThemeData(
                    textStyle: DeskTypography.base.copyWith(
                      color: const Color(0xffeceef3),
                    ),
                  ),
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(environment.scale),
                    boldText: environment.bold,
                    lineHeightScaleFactorOverride: environment.lineHeight,
                    letterSpacingOverride: environment.letterSpacing,
                  ),
                  child: DefaultTextStyle.merge(
                    style: environment.inherited,
                    child: Center(
                      child: SizedBox(
                        width: width,
                        child: ImageViewerToolbar(
                          label: '图片预览',
                          scale: 4,
                          originalSize: false,
                          enabled: true,
                          onZoomOut: () {},
                          onZoomIn: () {},
                          onFit: () {},
                          onOriginalSize: () {},
                          onClose: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          _expectFullVisibleLabels(tester);
          final bounds = tester.getRect(find.byType(ImageViewerToolbar));
          for (final key in [
            ImageViewerToolbar.zoomOutKey,
            ImageViewerToolbar.fitKey,
            ImageViewerToolbar.zoomInKey,
            ImageViewerToolbar.originalSizeKey,
            ImageViewerToolbar.closeKey,
          ]) {
            final rect = tester.getRect(find.byKey(key));
            expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
            expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
          }
        },
      );
    }
  }
}
