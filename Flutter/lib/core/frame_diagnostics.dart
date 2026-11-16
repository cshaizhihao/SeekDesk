import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

enum ReaderTimingEvent {
  wheel,
  wheelSmooth,
  wheelImmediate,
  panStart,
  panUpdate,
  panEnd,
  dragStart,
  position,
  capture,
  readerInit,
  readerAttach,
  readerDetach,
  readerSnapshot,
  restoreScheduled,
  restoreStart,
  restoreMediaWait,
  restoreEnd,
  positionSave,
  readerDispose,
  accessRevision,
  readerResult,
}

enum UiWorkKind {
  editorOpen,
  editorResize,
  composerInit,
  composerLoadStart,
  composerLoadReady,
  composerBinding,
  composerBuild,
  editorLayoutHeading,
  editorLayoutHeader,
  editorLayoutFooter,
  editorLayoutBody,
  editorLayout,
  editorControlsLayout,
  editorControlsPaint,
  editorFormatsLayout,
  editorFormatsPaint,
  editorMediaLayout,
  editorMediaPaint,
  editorControlsBuild,
  editorFormatsBuild,
  editorMediaBuild,
  editorBodyBuild,
  editorHeadingBuild,
  editorFooterBuild,
  editorToolBuild,
  editorToolGlassBuild,
  editorUndoBuild,
  editorRedoBuild,
  editorHelpBuild,
  editorStatusBuild,
  editorHostBuild,
  editorHostLayout,
  editorHostPaint,
  readerWorkspaceLayout,
  readerWorkspacePaint,
  readerViewportLayout,
  readerViewportPaint,
  readerRootLayout,
  readerRootPaint,
  readerActionsBuild,
  composerDispose,
  editorRemove,
  glassGeometry,
  glassShadow,
  glassShapeGeometry,
  glassGeometryPicture,
  glassGeometryImageHandle,
  glassShaderInstance,
}

/// Opt-in measurements only. No forum content, URLs or account data are logged.
/// Run profile/release with --dart-define=SEEKDESK_PROFILE_FRAMES=true and
/// capture stdout. Widget tests' minimal glass renderer is not performance proof.
class FrameDiagnostics {
  static const enabled = bool.fromEnvironment('SEEKDESK_PROFILE_FRAMES');
  static const rawFrames = bool.fromEnvironment('SEEKDESK_PROFILE_RAW_FRAMES');
  static const output = String.fromEnvironment('SEEKDESK_PROFILE_OUTPUT');
  static Future<void> _writing = Future<void>.value();
  static const _sampleLimit = 3600;
  static const _startupSampleCount = 10;
  static final Queue<_FrameSample> _frames = Queue<_FrameSample>();
  static final Queue<_FrameSample> _interval = Queue<_FrameSample>();
  static final Queue<Map<String, Object>> _readerEvents =
      Queue<Map<String, Object>>();
  static final Queue<Map<String, Object>> _uiWorkSamples =
      Queue<Map<String, Object>>();
  static final List<_FrameSample> _startup = <_FrameSample>[];
  static final Stopwatch _clock = Stopwatch();
  static Timer? _timer;
  static int _total = 0;
  static int _lastReportMicros = 0;
  static int _intervalDropped = 0;
  static int _readerEventSequence = 0;
  static int _intervalDroppedReaderEvents = 0;
  static int _totalDroppedReaderEvents = 0;
  static int _uiWorkSequence = 0;
  static int _intervalDroppedUiWorkSamples = 0;
  static int _totalDroppedUiWorkSamples = 0;
  static bool _startupReported = false;

  static void start() {
    if (!enabled || _timer != null) return;
    _total = 0;
    _lastReportMicros = 0;
    _intervalDropped = 0;
    _readerEventSequence = 0;
    _intervalDroppedReaderEvents = 0;
    _totalDroppedReaderEvents = 0;
    _uiWorkSequence = 0;
    _intervalDroppedUiWorkSamples = 0;
    _totalDroppedUiWorkSamples = 0;
    _uiWorkSamples.clear();
    _startupReported = false;
    final startedUnixMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
    _clock
      ..reset()
      ..start();
    final displays = WidgetsBinding.instance.platformDispatcher.displays
        .map(
          (display) => {
            'id': display.id,
            'refreshRateHz': display.refreshRate,
            'pixelRatio': display.devicePixelRatio,
          },
        )
        .toList();
    _emit(
      jsonEncode({
        'seekdeskDiagnostics': 'renderer',
        'schemaVersion': 3,
        'startedUnixMicros': startedUnixMicros,
        'rawFrameSamples': rawFrames,
        'localSyntheticFixture': const bool.fromEnvironment(
          'SEEKDESK_PROFILE_FIXTURE',
        ),
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
        'shaderFilterSupported': ui.ImageFilter.isShaderFilterSupported,
        'sharedBackdropEnabled': const bool.fromEnvironment(
          'SEEKDESK_SHARED_BACKDROP',
          defaultValue: true,
        ),
        'displays': displays,
        'activeView': _activeView(),
        'runtimeState': _runtimeState(),
        'timingScope':
            'Frames delivered after FrameDiagnostics.start; '
            'initialization before start is not measured. '
            'totalSpan includes scheduling and queue time. '
            'Refresh budget is sampled when each timing batch is delivered; '
            'runtimeState describes report time, not individual frame time. '
            'idle periods do not indicate dropped frames.',
      }),
    );
    SchedulerBinding.instance.addTimingsCallback(_record);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => report());
  }

  static void _record(List<FrameTiming> batch) {
    if (!enabled || !_clock.isRunning) return;
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final refreshRate = view?.display.refreshRate;
    final budget =
        refreshRate != null && refreshRate.isFinite && refreshRate > 0
        ? 1000 / refreshRate
        : null;
    for (final frame in batch) {
      final sample = _FrameSample(
        frame,
        budget,
        _total++ < _startupSampleCount,
      );
      _frames.add(sample);
      _interval.add(sample);
      if (sample.startup) _startup.add(sample);
      if (_frames.length > _sampleLimit) _frames.removeFirst();
      if (_interval.length > _sampleLimit) {
        _interval.removeFirst();
        _intervalDropped++;
      }
    }
  }

  /// Numeric observations only. Receiving an input does not prove that the
  /// reader moved, and neither event nor frame samples imply presented FPS.
  /// Engine/source timestamps retain their original time base; Unix reception
  /// time and elapsed time are separate fields, never silently substituted.
  static void recordReaderEvent(
    ReaderTimingEvent kind, {
    Duration? sourceTime,
    double? dx,
    double? dy,
    double? pixels,
    double? minExtent,
    double? maxExtent,
    double? viewportDimension,
    int? interaction,
    bool? correcting,
    bool? restoring,
    bool? pending,
    bool? outOfRange,
    int? readerInstance,
    int? accessRevision,
    int? positionEpoch,
    int? restoreGeneration,
    double? savedPixels,
    double? localPixels,
    double? observedPixels,
    double? bodyAnchorDy,
    bool? hasBodyAnchor,
    bool? hasThread,
    bool? hasOwner,
    bool? restored,
    bool? nativeMatched,
    bool? nativePrecise,
    int? nativeModifiers,
    int? nativePhase,
    int? nativeMomentumPhase,
    bool? wheelMotionEnabled,
  }) {
    if (!enabled || !rawFrames || !_clock.isRunning) return;
    _readerEvents.add({
      'seq': ++_readerEventSequence,
      'kind': kind.name,
      'receivedUnixMicros': DateTime.now().toUtc().microsecondsSinceEpoch,
      'elapsedMicros': _clock.elapsedMicroseconds,
      if (sourceTime != null) 'sourceTimeMicros': sourceTime.inMicroseconds,
      if (dx != null && dx.isFinite) 'dx': dx,
      if (dy != null && dy.isFinite) 'dy': dy,
      if (pixels != null && pixels.isFinite) 'pixels': pixels,
      if (minExtent != null && minExtent.isFinite) 'minExtent': minExtent,
      if (maxExtent != null && maxExtent.isFinite) 'maxExtent': maxExtent,
      if (viewportDimension != null && viewportDimension.isFinite)
        'viewportDimension': viewportDimension,
      'interaction': ?interaction,
      'correcting': ?correcting,
      'restoring': ?restoring,
      'pending': ?pending,
      'outOfRange': ?outOfRange,
      'readerInstance': ?readerInstance,
      'accessRevision': ?accessRevision,
      'positionEpoch': ?positionEpoch,
      'restoreGeneration': ?restoreGeneration,
      if (savedPixels != null && savedPixels.isFinite)
        'savedPixels': savedPixels,
      if (localPixels != null && localPixels.isFinite)
        'localPixels': localPixels,
      if (observedPixels != null && observedPixels.isFinite)
        'observedPixels': observedPixels,
      if (bodyAnchorDy != null && bodyAnchorDy.isFinite)
        'bodyAnchorDy': bodyAnchorDy,
      'hasBodyAnchor': ?hasBodyAnchor,
      'hasThread': ?hasThread,
      'hasOwner': ?hasOwner,
      'restored': ?restored,
      'nativeMatched': ?nativeMatched,
      'nativePrecise': ?nativePrecise,
      'nativeModifiers': ?nativeModifiers,
      'nativePhase': ?nativePhase,
      'nativeMomentumPhase': ?nativeMomentumPhase,
      'wheelMotionEnabled': ?wheelMotionEnabled,
    });
    if (_readerEvents.length > _sampleLimit) {
      _readerEvents.removeFirst();
      _intervalDroppedReaderEvents++;
      _totalDroppedReaderEvents++;
    }
  }

  /// Fixed phase names and numeric observations only. Supplied wall-clock and
  /// frame identifiers retain their original values for later correlation.
  /// Buffer independently from input and frame samples; encoding and output
  /// happen only at report boundaries, never in an instrumented UI operation.
  static void recordUiWork(
    UiWorkKind kind, {
    int? startedUnixMicros,
    int? durationMicros,
    double? width,
    double? height,
    int? count,
    bool? loading,
    int? frameNumber,
  }) {
    if (!enabled || !rawFrames || !_clock.isRunning) return;
    _uiWorkSamples.add({
      'seq': ++_uiWorkSequence,
      'kind': kind.name,
      'receivedUnixMicros': DateTime.now().toUtc().microsecondsSinceEpoch,
      'startedUnixMicros': ?startedUnixMicros,
      'durationMicros': ?durationMicros,
      if (width != null && width.isFinite) 'width': width,
      if (height != null && height.isFinite) 'height': height,
      'count': ?count,
      'loading': ?loading,
      'frameNumber': ?frameNumber,
    });
    if (_uiWorkSamples.length > _sampleLimit) {
      _uiWorkSamples.removeFirst();
      _intervalDroppedUiWorkSamples++;
      _totalDroppedUiWorkSamples++;
    }
  }

  static Map<String, Object?> _activeView() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final refreshRate = view?.display.refreshRate;
    return {
      'viewId': view?.viewId,
      'displayId': view?.display.id,
      'refreshRateHz': refreshRate,
      'frameBudgetMs':
          refreshRate != null && refreshRate.isFinite && refreshRate > 0
          ? 1000 / refreshRate
          : null,
      'pixelRatio': view?.devicePixelRatio,
      'physicalWidth': view?.physicalSize.width,
      'physicalHeight': view?.physicalSize.height,
    };
  }

  /// Read-only environment snapshot. Framework semantics may also be requested
  /// by tests or accessibility clients, so neither switch identifies VoiceOver.
  /// The timestamp marks observation time; it is not assigned to older frames.
  static Map<String, int> _runtimeState() {
    final binding = WidgetsBinding.instance;
    final dispatcher = binding.platformDispatcher;
    final features = dispatcher.accessibilityFeatures;
    return {
      'observedUnixMicros': DateTime.now().toUtc().microsecondsSinceEpoch,
      'frameworkSemanticsEnabled': binding.semanticsEnabled ? 1 : 0,
      'platformSemanticsEnabled': dispatcher.semanticsEnabled ? 1 : 0,
      'accessibleNavigation': features.accessibleNavigation ? 1 : 0,
      'disableAnimations': features.disableAnimations ? 1 : 0,
      'reduceMotion': features.reduceMotion ? 1 : 0,
      'highContrast': features.highContrast ? 1 : 0,
      'boldText': features.boldText ? 1 : 0,
    };
  }

  static Map<String, Object?> _distribution(
    List<_FrameSample> samples,
    Duration Function(FrameTiming) duration,
  ) {
    final values = <double>[];
    var budgeted = 0;
    var overBudget = 0;
    for (final sample in samples) {
      final value = duration(sample.frame).inMicroseconds / 1000;
      values.add(value);
      if (sample.budgetMs case final double budget) {
        budgeted++;
        if (value > budget) overBudget++;
      }
    }
    values.sort();
    double percentile(double rank) =>
        values.isEmpty ? 0 : values[((values.length - 1) * rank).round()];
    return {
      'count': values.length,
      'p50ms': percentile(.5),
      'p95ms': percentile(.95),
      'maxMs': values.isEmpty ? 0 : values.last,
      'over16_7ms': values.where((value) => value > 16.7).length,
      'over8_3ms': values.where((value) => value > 8.3).length,
      'framesWithKnownBudget': budgeted,
      'overRefreshBudget': overBudget,
      'overRefreshBudgetPercent': budgeted == 0
          ? null
          : overBudget * 100 / budgeted,
    };
  }

  static Map<String, Object?> _summary(List<_FrameSample> samples) => {
    'windowFrames': samples.length,
    'sampledFrameBudgetsMs':
        samples
            .map((sample) => sample.budgetMs)
            .whereType<double>()
            .toSet()
            .toList()
          ..sort(),
    'build': _distribution(samples, (frame) => frame.buildDuration),
    'raster': _distribution(samples, (frame) => frame.rasterDuration),
    'totalSpan': _distribution(samples, (frame) => frame.totalSpan),
  };

  static void report() {
    if (!enabled || !_clock.isRunning) return;
    final now = _clock.elapsedMicroseconds;
    final intervalStart = _lastReportMicros;
    _lastReportMicros = now;
    // Do not repeatedly label old samples as fresh measurements while idle.
    if (_interval.isEmpty && _readerEvents.isEmpty && _uiWorkSamples.isEmpty) {
      return;
    }
    final snapshot = _interval.toList(growable: false);
    final readerEvents = _readerEvents.toList(growable: false);
    final uiWorkSamples = _uiWorkSamples.toList(growable: false);
    _interval.clear();
    _readerEvents.clear();
    _uiWorkSamples.clear();
    final runtimeState = _runtimeState();
    if (!_startupReported && _startup.length == _startupSampleCount) {
      _startupReported = true;
      _emit(
        jsonEncode({
          'seekdeskDiagnostics': 'startupFrames',
          'schemaVersion': 3,
          'scope': 'first $_startupSampleCount delivered frames',
          'runtimeState': runtimeState,
          ..._summary(_startup),
        }),
      );
    }
    _emit(
      jsonEncode({
        'seekdeskDiagnostics': 'frames',
        'schemaVersion': 3,
        'scope': 'interval',
        'elapsedSeconds': now / Duration.microsecondsPerSecond,
        'intervalStartSeconds': intervalStart / Duration.microsecondsPerSecond,
        'intervalDurationSeconds':
            (now - intervalStart) / Duration.microsecondsPerSecond,
        'totalFrames': _total,
        'intervalDroppedSamples': _intervalDropped,
        'activeView': _activeView(),
        'runtimeState': runtimeState,
        ..._summary(snapshot),
        'intervalAfterFirst10Frames': _summary(
          snapshot.where((sample) => !sample.startup).toList(growable: false),
        ),
        'rolling': _summary(_frames.toList(growable: false)),
        if (rawFrames) ...{
          'samples': snapshot.map((sample) => sample.toJson()).toList(),
          'readerEvents': readerEvents,
          'totalReaderEvents': _readerEventSequence,
          'intervalDroppedReaderEvents': _intervalDroppedReaderEvents,
          'totalDroppedReaderEvents': _totalDroppedReaderEvents,
          'uiWorkSamples': uiWorkSamples,
          'totalUiWorkSamples': _uiWorkSequence,
          'intervalDroppedUiWorkSamples': _intervalDroppedUiWorkSamples,
          'totalDroppedUiWorkSamples': _totalDroppedUiWorkSamples,
        },
      }),
    );
    _intervalDropped = 0;
    _intervalDroppedReaderEvents = 0;
    _intervalDroppedUiWorkSamples = 0;
  }

  static void stop() {
    if (!enabled || _timer == null) return;
    report();
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _clock.stop();
    _frames.clear();
    _interval.clear();
    _readerEvents.clear();
    _uiWorkSamples.clear();
    _startup.clear();
  }

  /// Drain delivered samples and queued writes. Callers must not spend a real
  /// draft-save deadline waiting for optional diagnostic output.
  static Future<void> flush() async {
    report();
    await _writing;
  }

  static void _emit(String line) {
    debugPrintSynchronously(line);
    if (output.isEmpty) return;
    _writing = _writing
        .then((_) async {
          final file = File(output);
          await file.parent.create(recursive: true);
          await file.writeAsString(
            '$line\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((Object error) {
          debugPrintSynchronously(
            'SeekDesk frame diagnostics file is unavailable.',
          );
        });
  }
}

class _FrameSample {
  const _FrameSample(this.frame, this.budgetMs, this.startup);

  final FrameTiming frame;
  final double? budgetMs;
  final bool startup;

  Map<String, Object?> toJson() => {
    'frameNumber': frame.frameNumber,
    'vsyncStartMicros': frame.timestampInMicroseconds(ui.FramePhase.vsyncStart),
    'rasterFinishMicros': frame.timestampInMicroseconds(
      ui.FramePhase.rasterFinish,
    ),
    'rasterFinishWallMicros': frame.timestampInMicroseconds(
      ui.FramePhase.rasterFinishWallTime,
    ),
    'buildMicros': frame.buildDuration.inMicroseconds,
    'rasterMicros': frame.rasterDuration.inMicroseconds,
    'totalSpanMicros': frame.totalSpan.inMicroseconds,
    'vsyncOverheadMicros': frame.vsyncOverhead.inMicroseconds,
    'budgetMs': budgetMs,
    'startup': startup,
  };
}
