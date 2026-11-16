import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Geometry for a viewport-sized scene containing one centered image.
///
/// The image rect is expressed in scene coordinates. Returned matrices contain
/// only a uniform XY scale and translation; pixel density is deliberately not
/// involved, matching the desktop viewer's natural-size convention.
abstract final class ImageViewerGeometry {
  static const minScale = .5;
  static const maxScale = 4.0;

  static bool validSize(Size? size) =>
      size != null &&
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  /// Prefer source metadata over the possibly downsampled decoded original.
  static Size naturalSize({
    Size? original,
    Size? decodedOriginal,
    Size? thumbnail,
    Size fallback = const Size(1, 1),
  }) {
    for (final candidate in [original, decodedOriginal, thumbnail, fallback]) {
      if (validSize(candidate)) return candidate!;
    }
    return const Size(1, 1);
  }

  /// Fit without enlarging a small image. Empty/unbounded viewports are inert.
  static Size fitSize(Size natural, Size viewport) {
    if (!validSize(natural) || !validSize(viewport)) return Size.zero;
    final factor = math.min(
      1.0,
      math.min(
        viewport.width / natural.width,
        viewport.height / natural.height,
      ),
    );
    return Size(natural.width * factor, natural.height * factor);
  }

  static Rect centeredImageRect(Size imageSize, Size viewport) {
    if (!validSize(imageSize) || !validSize(viewport)) return Rect.zero;
    return Rect.fromCenter(
      center: viewport.center(Offset.zero),
      width: imageSize.width,
      height: imageSize.height,
    );
  }

  /// Do not use getMaxScaleOnAxis: its unchanged Z axis hides XY zoom below 1.
  static double scaleOf(Matrix4 matrix) {
    final scale = matrix.entry(0, 0);
    return scale.isFinite && scale > 0 ? scale : 1.0;
  }

  static Matrix4 clampTransform(
    Matrix4 matrix, {
    required Rect imageRect,
    required Size viewport,
    double min = minScale,
    double max = maxScale,
  }) {
    if (!_validRect(imageRect) || !validSize(viewport)) {
      return Matrix4.identity();
    }
    final limits = _limits(min, max);
    final scale = scaleOf(matrix).clamp(limits.$1, limits.$2);
    final dx = _finite(matrix.entry(0, 3));
    final dy = _finite(matrix.entry(1, 3));
    return _matrix(
      scale,
      _clampAxis(dx, imageRect.left, imageRect.right, viewport.width, scale),
      _clampAxis(dy, imageRect.top, imageRect.bottom, viewport.height, scale),
    );
  }

  /// Preserve the image point under [anchor], then constrain empty margins.
  /// The default anchor is the viewport center, used by toolbar zoom buttons.
  static Matrix4 zoomAround(
    Matrix4 matrix, {
    required Rect imageRect,
    required Size viewport,
    required double targetScale,
    Offset? anchor,
    double min = minScale,
    double max = maxScale,
  }) {
    if (!_validRect(imageRect) || !validSize(viewport)) {
      return Matrix4.identity();
    }
    final limits = _limits(min, max);
    final oldScale = scaleOf(matrix);
    final scale = (targetScale.isFinite ? targetScale : oldScale).clamp(
      limits.$1,
      limits.$2,
    );
    final point = anchor != null && anchor.dx.isFinite && anchor.dy.isFinite
        ? anchor
        : viewport.center(Offset.zero);
    final ratio = scale / oldScale;
    return clampTransform(
      _matrix(
        scale,
        point.dx - (point.dx - _finite(matrix.entry(0, 3))) * ratio,
        point.dy - (point.dy - _finite(matrix.entry(1, 3))) * ratio,
      ),
      imageRect: imageRect,
      viewport: viewport,
      min: limits.$1,
      max: limits.$2,
    );
  }

  /// Keep the same normalized image point at the new viewport center.
  ///
  /// Use for viewport resizing or new dimensions arriving after a manual pan.
  /// Zoom remains unchanged unless [targetScale] is supplied. A caller that is
  /// still in untouched fit mode should instead use an identity transform.
  static Matrix4 rebaseTransform(
    Matrix4 matrix, {
    required Rect oldImageRect,
    required Size oldViewport,
    required Rect newImageRect,
    required Size newViewport,
    double? targetScale,
    double min = minScale,
    double max = maxScale,
  }) {
    if (!_validRect(oldImageRect) || !validSize(oldViewport)) {
      return clampTransform(
        Matrix4.identity(),
        imageRect: newImageRect,
        viewport: newViewport,
        min: min,
        max: max,
      );
    }
    final oldScale = scaleOf(matrix);
    final oldCenter = oldViewport.center(Offset.zero);
    final normalized = Offset(
      ((oldCenter.dx - _finite(matrix.entry(0, 3))) / oldScale -
              oldImageRect.left) /
          oldImageRect.width,
      ((oldCenter.dy - _finite(matrix.entry(1, 3))) / oldScale -
              oldImageRect.top) /
          oldImageRect.height,
    );
    final limits = _limits(min, max);
    final scale =
        (targetScale != null && targetScale.isFinite ? targetScale : oldScale)
            .clamp(limits.$1, limits.$2);
    final center = newViewport.center(Offset.zero);
    return clampTransform(
      _matrix(
        scale,
        center.dx -
            (newImageRect.left + newImageRect.width * normalized.dx) * scale,
        center.dy -
            (newImageRect.top + newImageRect.height * normalized.dy) * scale,
      ),
      imageRect: newImageRect,
      viewport: newViewport,
      min: limits.$1,
      max: limits.$2,
    );
  }

  static bool _validRect(Rect rect) =>
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.right.isFinite &&
      rect.bottom.isFinite &&
      validSize(rect.size);

  static double _finite(double value) => value.isFinite ? value : 0.0;

  static (double, double) _limits(double min, double max) {
    final lower = min.isFinite && min > 0 ? min : minScale;
    final upper = max.isFinite && max >= lower
        ? max
        : math.max(lower, maxScale);
    return (lower, upper);
  }

  static double _clampAxis(
    double translation,
    double leading,
    double trailing,
    double viewport,
    double scale,
  ) {
    if ((trailing - leading) * scale <= viewport) {
      return (viewport - (leading + trailing) * scale) / 2;
    }
    return translation.clamp(viewport - trailing * scale, -leading * scale);
  }

  static Matrix4 _matrix(double scale, double dx, double dy) =>
      Matrix4.identity()
        ..setEntry(0, 0, scale)
        ..setEntry(1, 1, scale)
        ..setEntry(0, 3, dx)
        ..setEntry(1, 3, dy);
}
