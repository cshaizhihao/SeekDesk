import 'package:flutter/widgets.dart';

/// The effective environment of an ordinary single-line [Text] label.
///
/// Resolve where the label inherits its defaults. This is not a substitute for
/// measuring controls that install their own DefaultTextStyle or explicit
/// textScaler, locale, strut, or other paragraph configuration.
@immutable
class DeskLabelMetrics {
  const DeskLabelMetrics._({
    required this.style,
    required this.scaler,
    required this.direction,
    required this.locale,
    required this.textHeightBehavior,
    required this.textWidthBasis,
  });

  factory DeskLabelMetrics.of(
    BuildContext context, {
    required TextStyle style,
  }) {
    final defaults = DefaultTextStyle.of(context);
    var effective = style.inherit ? defaults.style.merge(style) : style;
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final height = MediaQuery.maybeLineHeightScaleFactorOverrideOf(context);
    final letterSpacing = MediaQuery.maybeLetterSpacingOverrideOf(context);
    final wordSpacing = MediaQuery.maybeWordSpacingOverrideOf(context);
    if (height != null || letterSpacing != null || wordSpacing != null) {
      effective = effective.merge(
        TextStyle(
          height: height,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
        ),
      );
    }
    return DeskLabelMetrics._(
      style: effective,
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      textHeightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
      textWidthBasis: defaults.textWidthBasis,
    );
  }

  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final Locale? locale;
  final TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;

  /// Paint-only changes can reuse geometry; layout-affecting changes cannot.
  bool hasSameLayout(DeskLabelMetrics other) =>
      style.compareTo(other.style) != RenderComparison.layout &&
      scaler == other.scaler &&
      direction == other.direction &&
      locale == other.locale &&
      textHeightBehavior == other.textHeightBehavior &&
      textWidthBasis == other.textWidthBasis;

  Size measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      locale: locale,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
      maxLines: 1,
    );
    try {
      painter.layout();
      return painter.size;
    } finally {
      painter.dispose();
    }
  }
}
