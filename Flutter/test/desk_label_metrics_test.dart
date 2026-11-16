import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/desk_label_metrics.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _CurvedScaler extends TextScaler {
  const _CurvedScaler();

  @override
  double scale(double fontSize) => fontSize * (1 + 12 / (fontSize + 12));

  @override
  double get textScaleFactor => scale(14) / 14;
}

class _Environment {
  const _Environment({
    this.inherited = DeskTypography.base,
    this.role = DeskTypography.control,
    this.scaler = TextScaler.noScaling,
    this.bold = false,
    this.lineHeight,
    this.letterSpacing,
    this.wordSpacing,
    this.locale = const Locale('en'),
    this.direction = TextDirection.ltr,
    this.fallbackHeight = const TextHeightBehavior(),
    this.defaultHeight,
    this.widthBasis = TextWidthBasis.parent,
  });

  final TextStyle inherited, role;
  final TextScaler scaler;
  final bool bold;
  final double? lineHeight, letterSpacing, wordSpacing;
  final Locale locale;
  final TextDirection direction;
  final TextHeightBehavior fallbackHeight;
  final TextHeightBehavior? defaultHeight;
  final TextWidthBasis widthBasis;
}

Future<DeskLabelMetrics> _capture(
  WidgetTester tester,
  _Environment environment, {
  String label = '原尺寸 400% Label',
}) async {
  late DeskLabelMetrics metrics;
  const textKey = ValueKey('reference-text');
  await tester.pumpWidget(
    Localizations(
      locale: environment.locale,
      delegates: const [DefaultWidgetsLocalizations.delegate],
      child: MediaQuery(
        data:
            MediaQueryData(
              textScaler: environment.scaler,
              boldText: environment.bold,
            ).applyTextStyleOverrides(
              lineHeightScaleFactorOverride: environment.lineHeight,
              letterSpacingOverride: environment.letterSpacing,
              wordSpacingOverride: environment.wordSpacing,
              paragraphSpacingOverride: null,
            ),
        child: Directionality(
          textDirection: environment.direction,
          child: DefaultTextHeightBehavior(
            textHeightBehavior: environment.fallbackHeight,
            child: DefaultTextStyle(
              style: environment.inherited,
              textHeightBehavior: environment.defaultHeight,
              textWidthBasis: environment.widthBasis,
              child: Builder(
                builder: (context) {
                  metrics = DeskLabelMetrics.of(
                    context,
                    style: environment.role,
                  );
                  return UnconstrainedBox(
                    child: Text(
                      label,
                      key: textKey,
                      style: environment.role,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final paragraph = tester.renderObject<RenderParagraph>(find.byKey(textKey));
  final size = metrics.measure(label);
  // The oracle is SDK Text's actual paragraph, not a second copy of the
  // helper's default/role/accessibility merge algorithm.
  expect(size.width, closeTo(paragraph.size.width, .0001));
  expect(size.height, closeTo(paragraph.size.height, .0001));
  expect(metrics.style, (paragraph.text as TextSpan).style);
  expect(metrics.scaler, paragraph.textScaler);
  expect(metrics.direction, paragraph.textDirection);
  expect(metrics.locale, paragraph.locale);
  expect(metrics.textHeightBehavior, paragraph.textHeightBehavior);
  expect(metrics.textWidthBasis, paragraph.textWidthBasis);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(tester.takeException(), isNull);
  return metrics;
}

void main() {
  const cases = <String, _Environment>{
    'ordinary production text': _Environment(),
    'inherited family, fallback, spacing and font features': _Environment(
      inherited: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: ['serif'],
        fontSize: 19,
        letterSpacing: 3,
        wordSpacing: 5,
        fontFeatures: [FontFeature.tabularFigures()],
        fontVariations: [FontVariation('wght', 600)],
      ),
    ),
    'bold with system spacing and a replacement line height': _Environment(
      scaler: TextScaler.linear(2),
      bold: true,
      lineHeight: 2,
      letterSpacing: 4,
      wordSpacing: 6,
    ),
    'noninheriting role still receives accessibility overrides': _Environment(
      inherited: TextStyle(fontSize: 30, letterSpacing: 9, height: 3),
      role: TextStyle(inherit: false, fontSize: 13, height: 1.3),
      bold: true,
      lineHeight: 1.8,
      wordSpacing: 7,
    ),
    'nonlinear scaler': _Environment(scaler: _CurvedScaler()),
    'ambient locale and RTL': _Environment(
      locale: Locale('ar'),
      direction: TextDirection.rtl,
    ),
    'style locale is preserved separately from paragraph locale': _Environment(
      role: TextStyle(fontSize: 12, locale: Locale('ja')),
      locale: Locale('zh'),
    ),
    'height behavior falls back to its dedicated inherited widget':
        _Environment(
          fallbackHeight: TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
        ),
    'default style height behavior takes precedence': _Environment(
      defaultHeight: TextHeightBehavior(applyHeightToFirstAscent: false),
      fallbackHeight: TextHeightBehavior(applyHeightToLastDescent: false),
      widthBasis: TextWidthBasis.longestLine,
    ),
  };

  for (final entry in cases.entries) {
    testWidgets('label metrics match actual Text: ${entry.key}', (
      tester,
    ) async {
      await _capture(tester, entry.value);
    });
  }

  testWidgets('paint-only changes reuse layout but font changes do not', (
    tester,
  ) async {
    final original = await _capture(tester, const _Environment());
    final colored = await _capture(
      tester,
      _Environment(
        role: DeskTypography.control.copyWith(
          color: const Color(0xff224488),
          backgroundColor: const Color(0xffeeeeee),
          decoration: TextDecoration.underline,
        ),
      ),
    );
    expect(original.hasSameLayout(colored), isTrue);
    expect(colored.hasSameLayout(original), isTrue);
    for (final environment in cases.values.skip(1)) {
      final changed = await _capture(tester, environment);
      expect(original.hasSameLayout(changed), isFalse);
    }
  });

  testWidgets('full nonlinear scaler differs from its legacy factor', (
    tester,
  ) async {
    const curved = _CurvedScaler();
    final nonlinear = await _capture(
      tester,
      const _Environment(scaler: curved),
    );
    final linear = await _capture(
      tester,
      _Environment(scaler: TextScaler.linear(curved.textScaleFactor)),
    );
    // Intentionally exercise the legacy-equality collision in MediaQueryData.
    // ignore: deprecated_member_use
    expect(nonlinear.scaler.textScaleFactor, linear.scaler.textScaleFactor);
    expect(nonlinear.hasSameLayout(linear), isFalse);
    expect(nonlinear.measure('400%'), isNot(linear.measure('400%')));
  });
}
