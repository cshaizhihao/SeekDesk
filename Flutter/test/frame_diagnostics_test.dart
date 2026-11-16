import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/frame_diagnostics.dart';

FrameTiming timing(int rasterMicros) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: 1000,
  rasterStart: 1000,
  rasterFinish: 1000 + rasterMicros,
  rasterFinishWallTime: 1000 + rasterMicros,
);

FrameTiming timedFrame({
  required int number,
  required int vsyncMicros,
  required int wallMicros,
}) => FrameTiming(
  frameNumber: number,
  vsyncStart: vsyncMicros,
  buildStart: vsyncMicros + 500,
  buildFinish: vsyncMicros + 1500,
  rasterStart: vsyncMicros + 2000,
  rasterFinish: vsyncMicros + 5000,
  rasterFinishWallTime: wallMicros,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // Diagnostics are compiled out by default. Run this fixture explicitly with
  // --dart-define=SEEKDESK_PROFILE_FRAMES=true to exercise the real recorder.
  // Also enable SEEKDESK_PROFILE_RAW_FRAMES for raw frame/event/UI coverage; run
  // without that second flag separately to verify the raw-disabled path.
  group('opt-in frame diagnostics', () {
    setUp(() {
      binding.platformDispatcher.implicitView!.display.refreshRate = 180;
    });
    tearDown(() {
      FrameDiagnostics.stop();
      binding.platformDispatcher.implicitView!.display.resetRefreshRate();
    });

    test(
      'runtime metadata reads platform flags without enabling semantics',
      () {
        final dispatcher = binding.platformDispatcher;
        dispatcher.semanticsEnabledTestValue = false;
        dispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(
              accessibleNavigation: true,
              reduceMotion: true,
              boldText: true,
            );
        addTearDown(() {
          dispatcher.clearAccessibilityFeaturesTestValue();
          dispatcher.clearSemanticsEnabledTestValue();
        });
        final handles = binding.debugOutstandingSemanticsHandles;
        final semanticsCallback = dispatcher.onSemanticsEnabledChanged;
        final featuresCallback = dispatcher.onAccessibilityFeaturesChanged;
        final records = <Map<String, dynamic>>[];
        runZoned(
          () {
            final beforeStart = DateTime.now().microsecondsSinceEpoch;
            FrameDiagnostics.start();
            expect(records.single['runtimeState'], {
              'observedUnixMicros': inInclusiveRange(
                beforeStart,
                DateTime.now().microsecondsSinceEpoch,
              ),
              'frameworkSemanticsEnabled': 0,
              'platformSemanticsEnabled': 0,
              'accessibleNavigation': 1,
              'disableAnimations': 0,
              'reduceMotion': 1,
              'highContrast': 0,
              'boldText': 1,
            });
            expect(binding.debugOutstandingSemanticsHandles, handles);
            // A feature change is not itself a trace event. Snapshot metadata
            // belongs to the next report and must not install a platform hook.
            dispatcher.accessibilityFeaturesTestValue =
                const FakeAccessibilityFeatures(
                  disableAnimations: true,
                  highContrast: true,
                );
            FrameDiagnostics.report();
            expect(records, hasLength(1));
            binding.platformDispatcher.onReportTimings!([
              ...List.generate(10, (_) => timing(1000)),
            ]);
            final beforeReport = DateTime.now().microsecondsSinceEpoch;
            FrameDiagnostics.report();
            final expected = {
              'observedUnixMicros': inInclusiveRange(
                beforeReport,
                DateTime.now().microsecondsSinceEpoch,
              ),
              'frameworkSemanticsEnabled': 0,
              'platformSemanticsEnabled': 0,
              'accessibleNavigation': 0,
              'disableAnimations': 1,
              'reduceMotion': 0,
              'highContrast': 1,
              'boldText': 0,
            };
            expect(records.last['runtimeState'], expected);
            expect(
              records.singleWhere(
                (record) => record['seekdeskDiagnostics'] == 'startupFrames',
              )['runtimeState'],
              expected,
            );
            expect(binding.debugOutstandingSemanticsHandles, handles);
            expect(
              dispatcher.onSemanticsEnabledChanged,
              same(semanticsCallback),
            );
            expect(
              dispatcher.onAccessibilityFeaturesChanged,
              same(featuresCallback),
            );
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      },
    );

    test(
      'runtime metadata separates framework handles from platform requests',
      () {
        final dispatcher = binding.platformDispatcher;
        dispatcher.semanticsEnabledTestValue = false;
        addTearDown(dispatcher.clearSemanticsEnabledTestValue);
        final records = <Map<String, dynamic>>[];
        runZoned(
          () {
            final handle = binding.ensureSemantics();
            try {
              FrameDiagnostics.start();
              expect(
                records.single['runtimeState']['frameworkSemanticsEnabled'],
                1,
              );
              expect(
                records.single['runtimeState']['platformSemanticsEnabled'],
                0,
              );
            } finally {
              handle.dispose();
            }
            binding.platformDispatcher.onReportTimings!([timing(1000)]);
            FrameDiagnostics.report();
            expect(
              records.last['runtimeState']['frameworkSemanticsEnabled'],
              0,
            );
            expect(records.last['runtimeState']['platformSemanticsEnabled'], 0);
            dispatcher.semanticsEnabledTestValue = true;
            binding.platformDispatcher.onReportTimings!([timing(1000)]);
            FrameDiagnostics.report();
            expect(
              records.last['runtimeState']['frameworkSemanticsEnabled'],
              1,
            );
            expect(records.last['runtimeState']['platformSemanticsEnabled'], 1);
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      },
    );

    test(
      'uses 180 Hz budgets, separates startup, and emits no stale idle data',
      () {
        final records = <Map<String, dynamic>>[];
        runZoned(
          () {
            FrameDiagnostics.start();
            final renderer = records.single;
            expect(renderer['schemaVersion'], 3);
            expect(renderer['startedUnixMicros'], isA<int>());
            expect(renderer['rawFrameSamples'], FrameDiagnostics.rawFrames);
            binding.platformDispatcher.onReportTimings!([
              ...List.generate(10, (_) => timing(10000)),
              timing(4000),
              timing(6000),
            ]);
            FrameDiagnostics.report();

            final startup = records.singleWhere(
              (item) => item['seekdeskDiagnostics'] == 'startupFrames',
            );
            expect(startup['windowFrames'], 10);
            expect(startup['raster']['maxMs'], 10);
            final first = records.last;
            expect(first['scope'], 'interval');
            expect(first['windowFrames'], 12);
            expect(
              first['activeView']['frameBudgetMs'],
              closeTo(1000 / 180, .001),
            );
            expect(first['raster']['overRefreshBudget'], 11);
            final warm = first['intervalAfterFirst10Frames'];
            expect(warm['windowFrames'], 2);
            expect(warm['raster']['maxMs'], 6);
            expect(warm['raster']['overRefreshBudgetPercent'], 50);
            if (FrameDiagnostics.rawFrames) {
              final samples = first['samples'] as List<dynamic>;
              expect(
                samples.take(10).map((item) => item['startup']),
                everyElement(isTrue),
              );
              expect(
                samples.skip(10).map((item) => item['startup']),
                everyElement(isFalse),
              );
            }

            final countBeforeIdle = records.length;
            FrameDiagnostics.report();
            FrameDiagnostics.report();
            expect(records.length, countBeforeIdle);
            binding.platformDispatcher.onReportTimings!([timing(2000)]);
            FrameDiagnostics.report();
            expect(records.last['windowFrames'], 1);
            expect(records.last['raster']['maxMs'], 2);
            expect(records.last['rolling']['windowFrames'], 13);
            expect(records.last['totalFrames'], 13);
            if (!FrameDiagnostics.rawFrames) {
              expect(records.last.containsKey('samples'), isFalse);
              expect(records.last.containsKey('readerEvents'), isFalse);
            }
            expect(
              records.where(
                (item) => item['seekdeskDiagnostics'] == 'startupFrames',
              ),
              hasLength(1),
            );
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      },
    );

    test('bounds retained samples and resets counters when restarted', () {
      final records = <Map<String, dynamic>>[];
      runZoned(
        () {
          FrameDiagnostics.start();
          binding.platformDispatcher.onReportTimings!([
            ...List.generate(3605, (_) => timing(1000)),
          ]);
          FrameDiagnostics.report();
          expect(records.last['windowFrames'], 3600);
          expect(records.last['rolling']['windowFrames'], 3600);
          expect(records.last['intervalDroppedSamples'], 5);
          if (FrameDiagnostics.rawFrames) {
            expect(records.last['samples'], hasLength(3600));
            expect(records.last['readerEvents'], isEmpty);
            expect(records.last['intervalDroppedReaderEvents'], 0);
          }
          FrameDiagnostics.stop();

          binding.platformDispatcher.implicitView!.display.refreshRate = 0;
          FrameDiagnostics.start();
          binding.platformDispatcher.onReportTimings!([timing(6000)]);
          FrameDiagnostics.report();
          expect(records.last['totalFrames'], 1);
          expect(records.last['rolling']['windowFrames'], 1);
          expect(records.last['intervalDroppedSamples'], 0);
          expect(records.last['activeView']['frameBudgetMs'], isNull);
          expect(records.last['raster']['framesWithKnownBudget'], 0);
          expect(records.last['raster']['overRefreshBudgetPercent'], isNull);
          FrameDiagnostics.stop();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) =>
              records.add(jsonDecode(line) as Map<String, dynamic>),
        ),
      );
    });

    test(
      'quit flush exports the partial interval and awaits JSONL writes',
      () async {
        final records = <Map<String, dynamic>>[];
        await runZoned(
          () async {
            FrameDiagnostics.start();
            binding.platformDispatcher.onReportTimings!([timing(3250)]);
            await FrameDiagnostics.flush();
            expect(records.last['seekdeskDiagnostics'], 'frames');
            expect(records.last['windowFrames'], 1);
            expect(records.last['raster']['maxMs'], 3.25);
            if (FrameDiagnostics.output.isNotEmpty) {
              final lines = await File(FrameDiagnostics.output).readAsLines();
              final last = jsonDecode(lines.last) as Map<String, dynamic>;
              expect(last['seekdeskDiagnostics'], 'frames');
              expect(last['raster']['maxMs'], 3.25);
            }
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      },
    );

    test('raw-disabled recording ignores reader and UI work and exports no raw fields', () {
      final records = <Map<String, dynamic>>[];
      runZoned(
        () {
          FrameDiagnostics.start();
          FrameDiagnostics.recordReaderEvent(
            ReaderTimingEvent.wheel,
            sourceTime: const Duration(microseconds: 1234),
            dy: 40,
          );
          FrameDiagnostics.recordUiWork(
            UiWorkKind.glassShaderInstance,
            durationMicros: 200,
            frameNumber: 7,
          );
          FrameDiagnostics.report();
          expect(records, hasLength(1));
          binding.platformDispatcher.onReportTimings!([timing(1000)]);
          FrameDiagnostics.report();
          expect(records.last['windowFrames'], 1);
          expect(records.last.containsKey('samples'), isFalse);
          expect(records.last.containsKey('readerEvents'), isFalse);
          expect(records.last.containsKey('uiWorkSamples'), isFalse);
          expect(records.last.containsKey('totalUiWorkSamples'), isFalse);
          expect(records.last['runtimeState'], isA<Map<String, dynamic>>());
          expect(
            (records.last['runtimeState'] as Map<String, dynamic>).values,
            everyElement(isA<int>()),
          );
          FrameDiagnostics.stop();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) =>
              records.add(jsonDecode(line) as Map<String, dynamic>),
        ),
      );
    }, skip: !FrameDiagnostics.enabled || FrameDiagnostics.rawFrames);

    group('raw frame and reader event samples', () {
      test('startup observations retain zero and omit unknown positions', () {
        final records = <Map<String, dynamic>>[];
        runZoned(
          () {
            FrameDiagnostics.start();
            FrameDiagnostics.recordReaderEvent(
              ReaderTimingEvent.restoreEnd,
              readerInstance: 2,
              accessRevision: 0,
              positionEpoch: 0,
              restoreGeneration: 1,
              pixels: 0,
              savedPixels: 1194,
              localPixels: double.nan,
              observedPixels: 0,
              bodyAnchorDy: double.infinity,
              hasBodyAnchor: false,
              hasThread: true,
              hasOwner: false,
              restored: true,
            );
            FrameDiagnostics.report();
            final event =
                (records.last['readerEvents'] as List<dynamic>).single
                    as Map<String, dynamic>;
            expect(event['readerInstance'], 2);
            expect(event['accessRevision'], 0);
            expect(event['positionEpoch'], 0);
            expect(event['restoreGeneration'], 1);
            expect(event['pixels'], 0);
            expect(event['observedPixels'], 0);
            expect(event['savedPixels'], 1194);
            expect(event.containsKey('localPixels'), isFalse);
            expect(event.containsKey('bodyAnchorDy'), isFalse);
            expect(event['hasBodyAnchor'], isFalse);
            expect(event['hasThread'], isTrue);
            expect(event['hasOwner'], isFalse);
            expect(event['restored'], isTrue);
            expect(event.keys, isNot(contains('owner')));
            expect(event.keys, isNot(contains('url')));
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      });

      test('preserves frame clocks and numbers across late timing batches', () {
        final records = <Map<String, dynamic>>[];
        runZoned(
          () {
            final beforeStart = DateTime.now().microsecondsSinceEpoch;
            FrameDiagnostics.start();
            expect(
              records.single['startedUnixMicros'],
              inInclusiveRange(
                beforeStart,
                DateTime.now().microsecondsSinceEpoch,
              ),
            );
            const wall = 1700000000000000;
            binding.platformDispatcher.onReportTimings!([
              timedFrame(number: 501, vsyncMicros: 40000, wallMicros: wall),
              timedFrame(
                number: 502,
                vsyncMicros: 90000,
                wallMicros: wall + 50000,
              ),
            ]);
            // Recording a batch must not perform a separate output per frame.
            expect(records, hasLength(1));
            FrameDiagnostics.report();
            final samples = records.last['samples'] as List<dynamic>;
            expect(samples, hasLength(2));
            expect(samples.first, {
              'frameNumber': 501,
              'vsyncStartMicros': 40000,
              'rasterFinishMicros': 45000,
              'rasterFinishWallMicros': wall,
              'buildMicros': 1000,
              'rasterMicros': 3000,
              'totalSpanMicros': 5000,
              'vsyncOverheadMicros': 500,
              'budgetMs': 1000 / 180,
              'startup': true,
            });
            expect(samples.last['frameNumber'], 502);
            expect(samples.last['vsyncStartMicros'], 90000);
            expect(samples.last['rasterFinishWallMicros'], wall + 50000);
            expect(samples.last['buildMicros'], samples.first['buildMicros']);
            expect(samples.last['rasterMicros'], samples.first['rasterMicros']);

            FrameDiagnostics.recordReaderEvent(
              ReaderTimingEvent.wheel,
              sourceTime: const Duration(microseconds: 800000),
              dy: 72,
            );
            // Delivered after the input and previous report, but the frame's
            // timestamps precede that input. Never assign receipt time to it.
            binding.platformDispatcher.onReportTimings!([
              timedFrame(
                number: 500,
                vsyncMicros: 15000,
                wallMicros: wall - 25000,
              ),
            ]);
            FrameDiagnostics.report();
            final delayed = (records.last['samples'] as List<dynamic>).single;
            expect(delayed['frameNumber'], 500);
            expect(delayed['vsyncStartMicros'], 15000);
            expect(delayed['rasterFinishMicros'], 20000);
            expect(delayed['rasterFinishWallMicros'], wall - 25000);
            final event =
                (records.last['readerEvents'] as List<dynamic>).single;
            expect(event['sourceTimeMicros'], 800000);
            expect(event['receivedUnixMicros'], greaterThan(wall));
            expect(event['elapsedMicros'], greaterThanOrEqualTo(0));
            expect(records.last['windowFrames'], 1);
            expect(records.last['totalFrames'], 3);
            final reported = records.length;
            FrameDiagnostics.report();
            expect(records, hasLength(reported));
            FrameDiagnostics.stop();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) =>
                records.add(jsonDecode(line) as Map<String, dynamic>),
          ),
        );
      });

      test(
        'event-only reports retain zero input and distinguish correction',
        () {
          final records = <Map<String, dynamic>>[];
          runZoned(
            () {
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.wheel,
                dy: 1,
              );
              expect(records, isEmpty);
              FrameDiagnostics.start();
              binding.platformDispatcher.onReportTimings!([timing(1000)]);
              FrameDiagnostics.report();
              final beforeEvents = records.length;
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.wheel,
                sourceTime: Duration.zero,
                dx: 0,
                dy: 0,
                pixels: 0,
                minExtent: 0,
                maxExtent: 900,
                viewportDimension: 600,
                interaction: 7,
                correcting: false,
                restoring: false,
                pending: false,
                outOfRange: false,
              );
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.position,
                pixels: 37,
                interaction: 7,
                correcting: true,
                restoring: false,
                pending: true,
                outOfRange: false,
              );
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.capture,
                pixels: 37,
                interaction: 7,
                correcting: false,
                pending: false,
              );
              expect(records, hasLength(beforeEvents));
              FrameDiagnostics.report();
              final report = records.last;
              expect(report['windowFrames'], 0);
              expect(report['samples'], isEmpty);
              expect(report['rolling']['windowFrames'], 1);
              expect(report['totalReaderEvents'], 3);
              final events = report['readerEvents'] as List<dynamic>;
              expect(events, hasLength(3));
              final wheel = events.first as Map<String, dynamic>;
              expect(wheel['seq'], 1);
              expect(wheel['kind'], 'wheel');
              expect(wheel['sourceTimeMicros'], 0);
              expect(wheel['dx'], 0);
              expect(wheel['dy'], 0);
              expect(wheel['pixels'], 0);
              expect(wheel['minExtent'], 0);
              expect(wheel['maxExtent'], 900);
              expect(wheel['viewportDimension'], 600);
              expect(wheel['interaction'], 7);
              expect(wheel['correcting'], isFalse);
              expect(wheel['restoring'], isFalse);
              expect(wheel['pending'], isFalse);
              expect(wheel['outOfRange'], isFalse);
              expect(wheel['receivedUnixMicros'], isA<int>());
              expect(wheel['elapsedMicros'], isA<int>());
              expect(events[1]['seq'], 2);
              expect(events[1]['kind'], 'position');
              expect(events[1]['pixels'], 37);
              expect(events[1]['correcting'], isTrue);
              expect(events[1]['pending'], isTrue);
              expect(events[1].containsKey('sourceTimeMicros'), isFalse);
              expect(events[1].containsKey('dy'), isFalse);
              expect(events[2]['kind'], 'capture');
              expect(events[2]['correcting'], isFalse);
              expect(events[2]['pending'], isFalse);
              final count = records.length;
              FrameDiagnostics.report();
              FrameDiagnostics.report();
              expect(records, hasLength(count));
              FrameDiagnostics.stop();
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.wheel,
                dy: 20,
              );
              FrameDiagnostics.report();
              expect(records, hasLength(count));
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );

      test(
        'bounds event batches independently and resets counters on restart',
        () {
          final records = <Map<String, dynamic>>[];
          runZoned(
            () {
              FrameDiagnostics.start();
              for (var index = 0; index < 3605; index++) {
                FrameDiagnostics.recordReaderEvent(
                  ReaderTimingEvent.panUpdate,
                  pixels: index.toDouble(),
                );
              }
              expect(records, hasLength(1));
              FrameDiagnostics.report();
              final first = records.last;
              final events = first['readerEvents'] as List<dynamic>;
              expect(events, hasLength(3600));
              expect(events.first['seq'], 6);
              expect(events.first['pixels'], 5);
              expect(events.last['seq'], 3605);
              expect(first['totalReaderEvents'], 3605);
              expect(first['intervalDroppedReaderEvents'], 5);
              expect(first['totalDroppedReaderEvents'], 5);
              expect(first['intervalDroppedSamples'], 0);
              expect(first['windowFrames'], 0);
              for (var index = 0; index < 3602; index++) {
                FrameDiagnostics.recordReaderEvent(ReaderTimingEvent.panUpdate);
              }
              binding.platformDispatcher.onReportTimings!([timing(1000)]);
              FrameDiagnostics.report();
              expect(records.last['intervalDroppedReaderEvents'], 2);
              expect(records.last['totalDroppedReaderEvents'], 7);
              expect(records.last['totalReaderEvents'], 7207);
              expect(records.last['intervalDroppedSamples'], 0);
              expect(records.last['samples'], hasLength(1));
              FrameDiagnostics.recordReaderEvent(ReaderTimingEvent.panEnd);
              FrameDiagnostics.report();
              expect(records.last['intervalDroppedReaderEvents'], 0);
              expect(records.last['totalDroppedReaderEvents'], 7);
              expect(records.last['readerEvents'], hasLength(1));
              FrameDiagnostics.stop();

              FrameDiagnostics.start();
              FrameDiagnostics.recordReaderEvent(ReaderTimingEvent.panStart);
              FrameDiagnostics.report();
              expect(records.last['totalFrames'], 0);
              expect(records.last['samples'], isEmpty);
              expect(records.last['totalReaderEvents'], 1);
              expect(records.last['intervalDroppedReaderEvents'], 0);
              expect(records.last['totalDroppedReaderEvents'], 0);
              final fresh =
                  (records.last['readerEvents'] as List<dynamic>).single;
              expect(fresh['seq'], 1);
              expect(fresh['kind'], 'panStart');
              FrameDiagnostics.stop();
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );

      test(
        'flush includes input-only tails and excludes nonfinite numbers',
        () async {
          final records = <Map<String, dynamic>>[];
          await runZoned(
            () async {
              FrameDiagnostics.start();
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.dragStart,
                dx: double.nan,
                dy: double.infinity,
                pixels: 18,
                maxExtent: double.negativeInfinity,
                outOfRange: true,
              );
              expect(records, hasLength(1));
              await FrameDiagnostics.flush();
              expect(records.last['windowFrames'], 0);
              final event =
                  (records.last['readerEvents'] as List<dynamic>).single;
              expect(event['kind'], 'dragStart');
              expect(event['pixels'], 18);
              expect(event['outOfRange'], isTrue);
              expect(event.containsKey('dx'), isFalse);
              expect(event.containsKey('dy'), isFalse);
              expect(event.containsKey('maxExtent'), isFalse);
              if (FrameDiagnostics.output.isNotEmpty) {
                final lines = await File(FrameDiagnostics.output).readAsLines();
                final last = jsonDecode(lines.last) as Map<String, dynamic>;
                expect(last['readerEvents'], records.last['readerEvents']);
                expect(last['samples'], isEmpty);
              }
              FrameDiagnostics.stop();
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );
    }, skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames);

    group('raw UI work samples', () {
      test(
        'reports UI-only work with exact clocks, phases and zero values',
        () {
          final records = <Map<String, dynamic>>[];
          runZoned(
            () {
              FrameDiagnostics.recordUiWork(UiWorkKind.editorOpen);
              expect(records, isEmpty);
              FrameDiagnostics.start();
              final beforeWork = DateTime.now().microsecondsSinceEpoch;
              FrameDiagnostics.recordUiWork(
                UiWorkKind.editorOpen,
                startedUnixMicros: 1700000000123456,
                durationMicros: 0,
                width: 0,
                height: 340.5,
                count: 0,
                loading: false,
                frameNumber: 0,
              );
              for (final kind in UiWorkKind.values.skip(1)) {
                FrameDiagnostics.recordUiWork(kind);
              }
              final afterWork = DateTime.now().microsecondsSinceEpoch;
              // Even a full group of instrumented phases performs no output.
              expect(records, hasLength(1));
              FrameDiagnostics.report();
              final report = records.last;
              expect(report['schemaVersion'], 3);
              expect(report['windowFrames'], 0);
              expect(report['rolling']['windowFrames'], 0);
              expect(report['totalFrames'], 0);
              expect(report['samples'], isEmpty);
              expect(report['readerEvents'], isEmpty);
              expect(report['totalReaderEvents'], 0);
              expect(report['totalUiWorkSamples'], UiWorkKind.values.length);
              final samples = report['uiWorkSamples'] as List<dynamic>;
              expect(
                samples.map((sample) => sample['kind']),
                UiWorkKind.values.map((kind) => kind.name),
              );
              expect(
                samples.map((sample) => sample['seq']),
                List.generate(UiWorkKind.values.length, (index) => index + 1),
              );
              final first = samples.first as Map<String, dynamic>;
              expect(first, {
                'seq': 1,
                'kind': 'editorOpen',
                'receivedUnixMicros': inInclusiveRange(beforeWork, afterWork),
                'startedUnixMicros': 1700000000123456,
                'durationMicros': 0,
                'width': 0,
                'height': 340.5,
                'count': 0,
                'loading': false,
                'frameNumber': 0,
              });
              expect(samples.last, {
                'seq': UiWorkKind.values.length,
                'kind': 'glassShaderInstance',
                'receivedUnixMicros': inInclusiveRange(beforeWork, afterWork),
              });
              final reportCount = records.length;
              FrameDiagnostics.report();
              FrameDiagnostics.report();
              FrameDiagnostics.stop();
              FrameDiagnostics.recordUiWork(UiWorkKind.editorOpen);
              FrameDiagnostics.report();
              expect(records, hasLength(reportCount));
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );

      test(
        'bounds UI work independently and resets interval and session counts',
        () {
          final records = <Map<String, dynamic>>[];
          runZoned(
            () {
              FrameDiagnostics.start();
              for (var index = 0; index < 3605; index++) {
                FrameDiagnostics.recordUiWork(
                  UiWorkKind.glassGeometry,
                  count: index,
                  frameNumber: index + 500,
                );
              }
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.wheel,
                dy: 4,
              );
              binding.platformDispatcher.onReportTimings!([timing(1000)]);
              FrameDiagnostics.report();
              final first = records.last;
              final samples = first['uiWorkSamples'] as List<dynamic>;
              expect(samples, hasLength(3600));
              expect(samples.first['seq'], 6);
              expect(samples.first['count'], 5);
              expect(samples.first['frameNumber'], 505);
              expect(samples.last['seq'], 3605);
              expect(first['totalUiWorkSamples'], 3605);
              expect(first['intervalDroppedUiWorkSamples'], 5);
              expect(first['totalDroppedUiWorkSamples'], 5);
              expect(first['intervalDroppedSamples'], 0);
              expect(first['totalFrames'], 1);
              expect(first['samples'], hasLength(1));
              expect(first['readerEvents'], hasLength(1));
              expect(first['totalReaderEvents'], 1);
              expect(first['intervalDroppedReaderEvents'], 0);
              expect(first['totalDroppedReaderEvents'], 0);

              for (var index = 0; index < 3602; index++) {
                FrameDiagnostics.recordUiWork(UiWorkKind.glassShadow);
              }
              FrameDiagnostics.report();
              expect(records.last['intervalDroppedUiWorkSamples'], 2);
              expect(records.last['totalDroppedUiWorkSamples'], 7);
              expect(records.last['totalUiWorkSamples'], 7207);
              expect(records.last['samples'], isEmpty);
              expect(records.last['readerEvents'], isEmpty);
              expect(records.last['totalFrames'], 1);
              expect(records.last['totalReaderEvents'], 1);

              // Overflowing the reader and frame queues cannot evict UI work.
              FrameDiagnostics.recordUiWork(UiWorkKind.editorLayout);
              for (var index = 0; index < 3601; index++) {
                FrameDiagnostics.recordReaderEvent(ReaderTimingEvent.panUpdate);
              }
              binding.platformDispatcher.onReportTimings!([
                ...List.generate(3601, (_) => timing(1000)),
              ]);
              FrameDiagnostics.report();
              expect(records.last['uiWorkSamples'], hasLength(1));
              expect(records.last['uiWorkSamples'][0]['seq'], 7208);
              expect(records.last['intervalDroppedUiWorkSamples'], 0);
              expect(records.last['totalDroppedUiWorkSamples'], 7);
              expect(records.last['intervalDroppedSamples'], 1);
              expect(records.last['intervalDroppedReaderEvents'], 1);
              FrameDiagnostics.stop();

              FrameDiagnostics.start();
              FrameDiagnostics.recordUiWork(UiWorkKind.composerInit);
              FrameDiagnostics.report();
              expect(records.last['totalUiWorkSamples'], 1);
              expect(records.last['intervalDroppedUiWorkSamples'], 0);
              expect(records.last['totalDroppedUiWorkSamples'], 0);
              expect(records.last['totalFrames'], 0);
              expect(records.last['totalReaderEvents'], 0);
              expect(records.last['samples'], isEmpty);
              expect(records.last['readerEvents'], isEmpty);
              final fresh =
                  (records.last['uiWorkSamples'] as List<dynamic>).single;
              expect(fresh['seq'], 1);
              expect(fresh['kind'], 'composerInit');
              FrameDiagnostics.stop();
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );

      test(
        'flush and stop drain UI-only tails and omit nonfinite dimensions',
        () async {
          final records = <Map<String, dynamic>>[];
          await runZoned(
            () async {
              FrameDiagnostics.start();
              FrameDiagnostics.recordUiWork(
                UiWorkKind.glassShaderInstance,
                startedUnixMicros: 1700000000123456,
                durationMicros: 83,
                width: double.nan,
                height: double.infinity,
                count: 2,
                loading: true,
                frameNumber: 501,
              );
              await FrameDiagnostics.flush();
              expect(records.last['windowFrames'], 0);
              expect(records.last['samples'], isEmpty);
              expect(records.last['readerEvents'], isEmpty);
              final sample =
                  (records.last['uiWorkSamples'] as List<dynamic>).single;
              expect(sample['kind'], 'glassShaderInstance');
              expect(sample['startedUnixMicros'], 1700000000123456);
              expect(sample['durationMicros'], 83);
              expect(sample['count'], 2);
              expect(sample['loading'], isTrue);
              expect(sample['frameNumber'], 501);
              expect(sample.containsKey('width'), isFalse);
              expect(sample.containsKey('height'), isFalse);
              if (FrameDiagnostics.output.isNotEmpty) {
                final lines = await File(FrameDiagnostics.output).readAsLines();
                final last = jsonDecode(lines.last) as Map<String, dynamic>;
                expect(last['uiWorkSamples'], records.last['uiWorkSamples']);
              }
              FrameDiagnostics.recordUiWork(
                UiWorkKind.editorResize,
                width: double.negativeInfinity,
                height: 0,
              );
              final beforeStop = records.length;
              FrameDiagnostics.stop();
              expect(records, hasLength(beforeStop + 1));
              final tail =
                  (records.last['uiWorkSamples'] as List<dynamic>).single;
              expect(tail['seq'], 2);
              expect(tail['kind'], 'editorResize');
              expect(tail['height'], 0);
              expect(tail.containsKey('width'), isFalse);
              expect(tail.containsKey('frameNumber'), isFalse);
              final afterStop = records.length;
              FrameDiagnostics.recordUiWork(UiWorkKind.editorOpen);
              await FrameDiagnostics.flush();
              expect(records, hasLength(afterStop));
              FrameDiagnostics.start();
              FrameDiagnostics.report();
              expect(records, hasLength(afterStop + 1));
              expect(records.last['seekdeskDiagnostics'], 'renderer');
              FrameDiagnostics.stop();
            },
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) =>
                  records.add(jsonDecode(line) as Map<String, dynamic>),
            ),
          );
        },
      );
    }, skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames);
  }, skip: !FrameDiagnostics.enabled);

  test(
    'disabled diagnostics do not emit or enable runtime observation',
    () async {
      final records = <String>[];
      final dispatcher = binding.platformDispatcher;
      final handles = binding.debugOutstandingSemanticsHandles;
      final semantics = binding.semanticsEnabled;
      final semanticsCallback = dispatcher.onSemanticsEnabledChanged;
      final featuresCallback = dispatcher.onAccessibilityFeaturesChanged;
      final file = FrameDiagnostics.output.isEmpty
          ? null
          : File(FrameDiagnostics.output);
      final existed = file != null && await file.exists();
      final before = file != null && existed ? await file.readAsBytes() : null;
      await runZoned(
        () async {
          FrameDiagnostics.start();
          FrameDiagnostics.recordReaderEvent(ReaderTimingEvent.wheel, dy: 40);
          FrameDiagnostics.recordUiWork(
            UiWorkKind.glassShaderInstance,
            durationMicros: 200,
            frameNumber: 7,
          );
          FrameDiagnostics.report();
          await FrameDiagnostics.flush();
          FrameDiagnostics.stop();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => records.add(line),
        ),
      );
      expect(records, isEmpty);
      expect(binding.debugOutstandingSemanticsHandles, handles);
      expect(binding.semanticsEnabled, semantics);
      expect(dispatcher.onSemanticsEnabledChanged, same(semanticsCallback));
      expect(dispatcher.onAccessibilityFeaturesChanged, same(featuresCallback));
      if (file != null) {
        expect(await file.exists(), existed);
        if (existed) expect(await file.readAsBytes(), before);
      }
    },
    skip: FrameDiagnostics.enabled,
  );
}
