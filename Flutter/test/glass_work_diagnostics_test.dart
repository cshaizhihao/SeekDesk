import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/glass_work_diagnostics.dart';

typedef _Sample = ({
  GlassWorkKind kind,
  int startedUnixMicros,
  int durationMicros,
  int? width,
  int? height,
  int? count,
  int? frameNumber,
});

class _Observer {
  final samples = <_Sample>[];

  void record(
    GlassWorkKind kind, {
    required int startedUnixMicros,
    required int durationMicros,
    int? width,
    int? height,
    int? count,
    int? frameNumber,
  }) {
    samples.add((
      kind: kind,
      startedUnixMicros: startedUnixMicros,
      durationMicros: durationMicros,
      width: width,
      height: height,
      count: count,
      frameNumber: frameNumber,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Run normally and with each individual define to exercise the disabled
  // paths; both defines are required for the measured group below.
  setUp(() => GlassWorkDiagnostics.observer = null);
  tearDown(() => GlassWorkDiagnostics.observer = null);

  test('no observer creates no measurement in any build configuration', () {
    for (final kind in GlassWorkKind.values) {
      expect(GlassWorkDiagnostics.begin(kind), isNull);
    }
  });

  test(
    'either disabled compile flag prevents measurement despite an observer',
    () {
      final observer = _Observer();
      GlassWorkDiagnostics.observer = observer.record;
      for (final kind in GlassWorkKind.values) {
        expect(GlassWorkDiagnostics.begin(kind), isNull);
      }
      expect(observer.samples, isEmpty);
    },
    skip: GlassWorkDiagnostics.enabled,
  );

  group('explicitly enabled vendor work diagnostics', () {
    test('fixed categories carry only the declared numeric observations', () {
      expect(GlassWorkKind.values, const [
        GlassWorkKind.shapeGeometry,
        GlassWorkKind.geometryPicture,
        GlassWorkKind.geometryImageHandle,
        GlassWorkKind.shadowBake,
        GlassWorkKind.shaderInstance,
      ]);
      final observer = _Observer();
      GlassWorkDiagnostics.observer = observer.record;

      for (final kind in GlassWorkKind.values) {
        final expectedFrame =
            ui.PlatformDispatcher.instance.frameData.frameNumber;
        final before = DateTime.now().microsecondsSinceEpoch;
        final outerClock = Stopwatch()..start();
        final work = GlassWorkDiagnostics.begin(kind);
        expect(work, isNotNull);
        work!.finish(width: 96, height: 64, count: 3);
        outerClock.stop();
        final after = DateTime.now().microsecondsSinceEpoch;
        final sample = observer.samples.last;
        expect(sample.kind, kind);
        expect(sample.startedUnixMicros, inInclusiveRange(before, after));
        expect(
          sample.durationMicros,
          inInclusiveRange(0, outerClock.elapsedMicroseconds),
        );
        expect(sample.frameNumber, expectedFrame);
        expect(sample.width, 96);
        expect(sample.height, 64);
        expect(sample.count, 3);
      }
      expect(observer.samples, hasLength(GlassWorkKind.values.length));
    });

    test('finish emits once and retains the first completed measurements', () {
      final observer = _Observer();
      GlassWorkDiagnostics.observer = observer.record;
      final work = GlassWorkDiagnostics.begin(
        GlassWorkKind.geometryImageHandle,
      )!;
      work.finish(width: 96, height: 64, count: 2);
      final first = observer.samples.single;
      work.finish(width: 800, height: 600, count: 20);
      expect(observer.samples, [first]);
    });

    test('unsupplied optional observations remain absent', () {
      final observer = _Observer();
      GlassWorkDiagnostics.observer = observer.record;
      GlassWorkDiagnostics.begin(GlassWorkKind.shapeGeometry)!.finish();
      final sample = observer.samples.single;
      expect(sample.width, isNull);
      expect(sample.height, isNull);
      expect(sample.count, isNull);
      expect(sample.frameNumber, isA<int>());
    });

    test('a failing observer preserves both a render result and its error', () {
      final observerError = Object();
      final renderError = Object();
      var calls = 0;
      GlassWorkDiagnostics.observer =
          (
            GlassWorkKind kind, {
            required int startedUnixMicros,
            required int durationMicros,
            int? width,
            int? height,
            int? count,
            int? frameNumber,
          }) {
            calls++;
            throw observerError;
          };

      int render({required bool fail}) {
        final work = GlassWorkDiagnostics.begin(GlassWorkKind.shadowBake)!;
        try {
          if (fail) throw renderError;
          return 42;
        } finally {
          work.finish(width: 96, height: 64, count: 1);
          // An observer error must not leave this measurement open either.
          work.finish();
        }
      }

      expect(render(fail: false), 42);
      expect(calls, 1);
      expect(() => render(fail: true), throwsA(same(renderError)));
      expect(calls, 2);
    });

    test('clearing the observer prevents subsequent measurements', () {
      final observer = _Observer();
      GlassWorkDiagnostics.observer = observer.record;
      GlassWorkDiagnostics.begin(GlassWorkKind.shaderInstance)!
          .finish(count: 1);
      GlassWorkDiagnostics.observer = null;
      expect(GlassWorkDiagnostics.begin(GlassWorkKind.shaderInstance), isNull);
      expect(observer.samples, hasLength(1));
    });
  }, skip: !GlassWorkDiagnostics.enabled);
}
