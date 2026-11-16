import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/image_viewer_geometry.dart';

Matrix4 transform(double scale, double dx, double dy) => Matrix4.identity()
  ..setEntry(0, 0, scale)
  ..setEntry(1, 1, scale)
  ..setEntry(0, 3, dx)
  ..setEntry(1, 3, dy);

Offset imagePointAtCenter(Matrix4 matrix, Rect rect, Size viewport) {
  final center = viewport.center(Offset.zero);
  final scale = ImageViewerGeometry.scaleOf(matrix);
  return Offset(
    ((center.dx - matrix.entry(0, 3)) / scale - rect.left) / rect.width,
    ((center.dy - matrix.entry(1, 3)) / scale - rect.top) / rect.height,
  );
}

void expectOffsetNear(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, .000001));
  expect(actual.dy, closeTo(expected.dy, .000001));
}

void main() {
  group('image size basis', () {
    test('source dimensions precede decoded original and thumbnail', () {
      expect(
        ImageViewerGeometry.naturalSize(
          original: const Size(12000, 8000),
          decodedOriginal: const Size(6000, 4000),
          thumbnail: const Size(900, 600),
        ),
        const Size(12000, 8000),
      );
      expect(
        ImageViewerGeometry.naturalSize(
          original: Size.zero,
          decodedOriginal: const Size(6000, 4000),
          thumbnail: const Size(900, 600),
        ),
        const Size(6000, 4000),
      );
      expect(
        ImageViewerGeometry.naturalSize(
          original: const Size(double.nan, 8000),
          decodedOriginal: const Size(6000, double.infinity),
          thumbnail: const Size(900, 600),
        ),
        const Size(900, 600),
      );
    });

    test('invalid candidates and fallback produce a finite safe basis', () {
      expect(
        ImageViewerGeometry.naturalSize(
          original: const Size(-1, 20),
          decodedOriginal: const Size(10, 0),
          thumbnail: const Size(double.infinity, 10),
          fallback: const Size(double.nan, 1),
        ),
        const Size(1, 1),
      );
      expect(
        ImageViewerGeometry.naturalSize(fallback: const Size(320, 240)),
        const Size(320, 240),
      );
    });

    test('fit preserves landscape, portrait and very long report ratios', () {
      const viewport = Size(800, 600);
      expect(
        ImageViewerGeometry.fitSize(const Size(1600, 900), viewport),
        const Size(800, 450),
      );
      expect(
        ImageViewerGeometry.fitSize(const Size(900, 1600), viewport),
        const Size(337.5, 600),
      );
      expect(
        ImageViewerGeometry.fitSize(const Size(600, 12000), viewport),
        const Size(30, 600),
      );
    });

    test('fit does not upscale small images or use device pixel density', () {
      expect(
        ImageViewerGeometry.fitSize(const Size(100, 80), const Size(800, 600)),
        const Size(100, 80),
      );
      expect(
        ImageViewerGeometry.centeredImageRect(
          const Size(1920, 1080),
          const Size(800, 600),
        ),
        const Rect.fromLTWH(-560, -240, 1920, 1080),
      );
    });

    test('missing or unbounded layout dimensions are inert', () {
      for (final invalid in [
        Size.zero,
        const Size(-1, 600),
        const Size(800, double.nan),
        const Size(double.infinity, 600),
      ]) {
        expect(
          ImageViewerGeometry.fitSize(const Size(800, 600), invalid),
          Size.zero,
        );
        expect(
          ImageViewerGeometry.fitSize(invalid, const Size(800, 600)),
          Size.zero,
        );
        expect(
          ImageViewerGeometry.centeredImageRect(invalid, const Size(800, 600)),
          Rect.zero,
        );
      }
    });
  });

  group('one uniform image transform', () {
    const viewport = Size(800, 600);
    const image = Rect.fromLTWH(0, 75, 800, 450);

    test('50 percent is not mistaken for the unchanged Z scale', () {
      expect(ImageViewerGeometry.scaleOf(transform(.5, 20, 30)), .5);
    });

    test('undersized axes stay centered despite drag translation', () {
      final matrix = ImageViewerGeometry.clampTransform(
        transform(.5, -800, 10000),
        imageRect: image,
        viewport: viewport,
      );
      expect(matrix.entry(0, 3), 200);
      expect(matrix.entry(1, 3), 150);
      expect(
        MatrixUtils.transformRect(matrix, image).center,
        viewport.center(Offset.zero),
      );
    });

    test('enlarged image can pan to each edge without exposing margins', () {
      final leading = ImageViewerGeometry.clampTransform(
        transform(2, 10000, 10000),
        imageRect: image,
        viewport: viewport,
      );
      final trailing = ImageViewerGeometry.clampTransform(
        transform(2, -10000, -10000),
        imageRect: image,
        viewport: viewport,
      );
      expect(MatrixUtils.transformRect(leading, image).topLeft, Offset.zero);
      expect(
        MatrixUtils.transformRect(trailing, image).bottomRight,
        const Offset(800, 600),
      );
    });

    test('zoom buttons preserve the visible center when panned', () {
      final before = transform(2, -600, -300);
      final after = ImageViewerGeometry.zoomAround(
        before,
        imageRect: image,
        viewport: viewport,
        targetScale: 2.25,
      );
      expect(ImageViewerGeometry.scaleOf(after), 2.25);
      expectOffsetNear(
        imagePointAtCenter(after, image, viewport),
        imagePointAtCenter(before, image, viewport),
      );
    });

    test(
      'double click zoom keeps the clicked image point under the pointer',
      () {
        const square = Rect.fromLTWH(100, 0, 600, 600);
        const pointer = Offset(200, 200);
        final matrix = ImageViewerGeometry.zoomAround(
          Matrix4.identity(),
          imageRect: square,
          viewport: viewport,
          targetScale: 2,
          anchor: pointer,
        );
        expectOffsetNear(MatrixUtils.transformPoint(matrix, pointer), pointer);
        expect(ImageViewerGeometry.scaleOf(matrix), 2);
      },
    );

    test('buttons and gesture correction share 50 to 400 percent bounds', () {
      for (final requested in [-1.0, .1, .5, 1.25, 4.0, 25.0]) {
        final matrix = ImageViewerGeometry.zoomAround(
          Matrix4.identity(),
          imageRect: image,
          viewport: viewport,
          targetScale: requested,
        );
        expect(ImageViewerGeometry.scaleOf(matrix), requested.clamp(.5, 4.0));
      }
      final matrix = ImageViewerGeometry.clampTransform(
        transform(25, -900, -900),
        imageRect: image,
        viewport: viewport,
      );
      expect(ImageViewerGeometry.scaleOf(matrix), 4);
    });

    test('invalid transform cannot introduce nonfinite scene coordinates', () {
      final matrix = ImageViewerGeometry.clampTransform(
        transform(double.nan, double.infinity, double.negativeInfinity),
        imageRect: image,
        viewport: viewport,
      );
      expect(matrix.storage.every((value) => value.isFinite), isTrue);
      expect(ImageViewerGeometry.scaleOf(matrix), 1);
      expect(MatrixUtils.transformRect(matrix, image), image);
      final zoom = ImageViewerGeometry.zoomAround(
        matrix,
        imageRect: image,
        viewport: viewport,
        targetScale: double.infinity,
        anchor: const Offset(double.nan, double.infinity),
      );
      expect(zoom.storage.every((value) => value.isFinite), isTrue);
      expect(ImageViewerGeometry.scaleOf(zoom), 1);
    });
  });

  group('viewport and basis changes', () {
    test('resize retains zoom and the image point at viewport center', () {
      const oldViewport = Size(800, 600);
      const oldImage = Rect.fromLTWH(0, 75, 800, 450);
      const newViewport = Size(1000, 700);
      final newImage = ImageViewerGeometry.centeredImageRect(
        ImageViewerGeometry.fitSize(const Size(1600, 900), newViewport),
        newViewport,
      );
      final before = transform(2, -600, -300);
      final after = ImageViewerGeometry.rebaseTransform(
        before,
        oldImageRect: oldImage,
        oldViewport: oldViewport,
        newImageRect: newImage,
        newViewport: newViewport,
      );
      expect(ImageViewerGeometry.scaleOf(after), 2);
      expectOffsetNear(
        imagePointAtCenter(after, newImage, newViewport),
        imagePointAtCenter(before, oldImage, oldViewport),
      );
    });

    test(
      'original basis update retains manual pan rather than resetting fit',
      () {
        const viewport = Size(800, 600);
        const oldImage = Rect.fromLTWH(-400, -150, 1600, 900);
        const newImage = Rect.fromLTWH(-1200, -600, 3200, 1800);
        final before = transform(1.5, -500, -300);
        final after = ImageViewerGeometry.rebaseTransform(
          before,
          oldImageRect: oldImage,
          oldViewport: viewport,
          newImageRect: newImage,
          newViewport: viewport,
        );
        expect(ImageViewerGeometry.scaleOf(after), 1.5);
        expectOffsetNear(
          imagePointAtCenter(after, newImage, viewport),
          imagePointAtCenter(before, oldImage, viewport),
        );
      },
    );

    test(
      'narrow resize recenters fitting axis and constrains remaining pan',
      () {
        final matrix = ImageViewerGeometry.rebaseTransform(
          transform(2, -700, -300),
          oldImageRect: const Rect.fromLTWH(0, 75, 800, 450),
          oldViewport: const Size(800, 600),
          newImageRect: const Rect.fromLTWH(0, 215.625, 300, 168.75),
          newViewport: const Size(300, 600),
        );
        final result = MatrixUtils.transformRect(
          matrix,
          const Rect.fromLTWH(0, 215.625, 300, 168.75),
        );
        expect(result.center.dy, 300);
        expect(result.left, lessThanOrEqualTo(0));
        expect(result.right, greaterThanOrEqualTo(300));
      },
    );

    test('unavailable previous geometry starts with a safe centered image', () {
      final matrix = ImageViewerGeometry.rebaseTransform(
        transform(double.nan, double.nan, double.nan),
        oldImageRect: Rect.zero,
        oldViewport: Size.zero,
        newImageRect: const Rect.fromLTWH(0, 75, 800, 450),
        newViewport: const Size(800, 600),
      );
      expect(matrix, Matrix4.identity());
    });
  });
}
