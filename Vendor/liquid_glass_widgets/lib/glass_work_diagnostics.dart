import 'dart:ui' as ui;

/// Fixed, content-free synchronous work categories for local diagnostics.
/// Durations are inclusive within each category and must not be added across
/// nested work. Image-handle creation does not measure completed GPU work.
enum GlassWorkKind {
  shapeGeometry,
  geometryPicture,
  geometryImageHandle,
  shadowBake,
  shaderInstance,
}

/// An optional observer of UI-thread work. Width and height are physical image
/// pixels when supplied; count is the number of shapes, shadows, or instances.
typedef GlassWorkObserver = void Function(
  GlassWorkKind kind, {
  required int startedUnixMicros,
  required int durationMicros,
  int? width,
  int? height,
  int? count,
  int? frameNumber,
});

/// Explicitly imported by a local diagnostic host; no observer is installed by
/// the library. Disabled builds allocate no measurement objects or clocks.
class GlassWorkDiagnostics {
  GlassWorkDiagnostics._();

  static const enabled =
      bool.fromEnvironment('SEEKDESK_PROFILE_FRAMES') &&
      bool.fromEnvironment('SEEKDESK_PROFILE_RAW_FRAMES');

  static GlassWorkObserver? observer;

  static GlassWorkMeasurement? begin(GlassWorkKind kind) {
    if (!enabled) return null;
    final callback = observer;
    if (callback == null) return null;
    return GlassWorkMeasurement._(kind, callback);
  }
}

/// A single synchronous measurement. Call [finish] from finally so an original
/// rendering exception propagates unchanged even when an observer fails.
class GlassWorkMeasurement {
  GlassWorkMeasurement._(this._kind, this._observer)
    : _startedUnixMicros = DateTime.now().microsecondsSinceEpoch,
      _frameNumber = ui.PlatformDispatcher.instance.frameData.frameNumber,
      _clock = Stopwatch()..start();

  final GlassWorkKind _kind;
  final GlassWorkObserver _observer;
  final int _startedUnixMicros;
  final int _frameNumber;
  final Stopwatch _clock;
  bool _finished = false;

  void finish({int? width, int? height, int? count}) {
    if (_finished) return;
    _finished = true;
    _clock.stop();
    try {
      _observer(
        _kind,
        startedUnixMicros: _startedUnixMicros,
        durationMicros: _clock.elapsedMicroseconds,
        width: width,
        height: height,
        count: count,
        frameNumber: _frameNumber,
      );
    } on Object {
      // Optional diagnostics must never fail a render or replace its error.
    }
  }
}
