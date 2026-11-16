import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum NativeWheelStatus { matched, unknown, ambiguous }

/// An immutable classification of the event currently being dispatched.
///
/// Read [NativeWheelInput.current] to inspect it; use
/// [NativeWheelInput.consume] to claim it once for the resolved scroll owner.
@immutable
class NativeWheelMatch {
  const NativeWheelMatch._(this.event, this.status, this._metadata);

  final PointerScrollEvent event;
  final NativeWheelStatus status;
  final _WheelMetadata? _metadata;

  bool get matched => status == NativeWheelStatus.matched;
  int? get sequence => _metadata?.sequence;
  bool? get precise => _metadata?.precise;
  int? get phase => _metadata?.phase;
  int? get momentumPhase => _metadata?.momentumPhase;
  int? get modifiers => _metadata?.modifiers;

  bool get eligible {
    final metadata = _metadata;
    return matched &&
        metadata != null &&
        event.kind == ui.PointerDeviceKind.mouse &&
        !metadata.precise &&
        metadata.phase == 0 &&
        metadata.momentumPhase == 0 &&
        metadata.modifiers == 0 &&
        metadata.signature.dx == 0 &&
        metadata.signature.dy != 0 &&
        event.scrollDelta.dx == 0 &&
        event.scrollDelta.dy != 0;
  }
}

/// Matches native wheel metadata without delaying or changing pointer events.
///
/// Positions and deltas on the wire use physical engine coordinates. Matching
/// reverses Flutter's conversion using the event's own view, never the implicit
/// view. View and timestamp are exact; physical values allow at most 0.000001
/// pixel of round-trip error, with multiple candidates rejected as ambiguous.
/// Unknown, expired, malformed or ambiguous input stays unclassified.
class NativeWheelInput {
  NativeWheelInput({
    BinaryMessenger? messenger,
    int Function()? clock,
    double? Function(int viewId)? devicePixelRatioForView,
  }) : _channel = BasicMessageChannel<Object?>(
         channelName,
         const StandardMessageCodec(),
         binaryMessenger: messenger,
       ),
       _clock = clock ?? _elapsedClock(),
       _devicePixelRatioForView =
           devicePixelRatioForView ?? _viewDevicePixelRatio;

  static final instance = NativeWheelInput();
  static const channelName = 'cc.seekdesk/native.wheel.v1';
  static const _capacity = 64;
  static const _maxAgeMicros = 100000;

  final BasicMessageChannel<Object?> _channel;
  final int Function() _clock;
  final double? Function(int) _devicePixelRatioForView;
  final _pending = Queue<_PendingWheel>();
  final _ambiguous = <_WheelSignature, int>{};
  final _dispatched = <_WheelSignature, int>{};
  final _lastDispatchTimestamp = <int, int>{};
  int _lastSequence = 0;
  int _generation = 0;
  bool _accepting = false;
  Future<void>? _starting;
  _DispatchScope? _scope;

  /// Installs the decoder before requesting native delivery. Buffered messages
  /// received before the ready reply are discarded, including during restart.
  /// A missing or incompatible host leaves ordinary pointer dispatch intact.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final generation = ++_generation;
    _accepting = false;
    _clear();
    _channel.setMessageHandler((message) {
      // Do not put an await before this store: the engine pointer event follows
      // this message and must see the classification synchronously.
      if (_accepting) acceptMetadata(message);
      return Future<Object?>.value(null);
    });
    try {
      // ChannelBuffers drains old platform messages through microtasks when a
      // handler is installed. Let that drain finish before enabling the host.
      await Future<void>.delayed(Duration.zero);
      if (generation != _generation) return;
      final reply = await _channel
          .send(const {'type': 'ready', 'version': 1})
          .timeout(const Duration(seconds: 1));
      if (generation != _generation) return;
      _clear();
      _accepting =
          reply is Map && reply['version'] is int && reply['version'] == 1;
    } catch (_) {
      if (generation != _generation) return;
      _accepting = false;
      _clear();
    }
  }

  /// Removes this instance's channel handler. Isolated tests use an injected
  /// messenger; they never register on the application's native channel.
  void dispose() {
    ++_generation;
    _accepting = false;
    _starting = null;
    _channel.setMessageHandler(null);
    _clear();
  }

  NativeWheelMatch? get current => _scope?.match;

  /// Claims the current classification once, while its dispatch is active.
  /// An optional event must be the identical original event, even when a hit
  /// test has produced a transformed event for a listener.
  NativeWheelMatch? consume([PointerScrollEvent? event]) {
    final scope = _scope;
    if (scope == null || scope.consumed) return null;
    if (event != null && !identical(_original(event), scope.match.event)) {
      return null;
    }
    scope.consumed = true;
    return scope.match;
  }

  /// Wraps the complete hit-test dispatch, including PointerSignalResolver.
  /// Nested dispatches temporarily hide the outer classification, and cleanup
  /// runs even when a callback throws. No state survives as a later hint for a
  /// direct or programmatic pointerScroll call.
  void dispatch(PointerEvent event, VoidCallback callback) {
    final previous = _scope;
    _scope = event is PointerScrollEvent
        ? _DispatchScope(_match(_original(event)))
        : null;
    try {
      callback();
    } finally {
      _scope = previous;
    }
  }

  /// Synchronous protocol entry point, also usable with an isolated instance
  /// in tests. It copies validated scalar fields and never retains the map.
  @visibleForTesting
  void acceptMetadata(Object? message) {
    final now = _clock();
    _expire(now);
    final metadata = _WheelMetadata.decode(message);
    if (metadata == null) {
      // A corrupt message cannot leave a preceding candidate eligible.
      _pending.clear();
      return;
    }
    final signature = metadata.signature;
    if (metadata.sequence <= _lastSequence) {
      final conflicts = _pending.where(
        (entry) =>
            entry.metadata.sequence == metadata.sequence ||
            entry.metadata.signature.matches(signature),
      );
      for (final entry in conflicts) {
        _remember(_ambiguous, entry.metadata.signature, now);
      }
      _pending.removeWhere(
        (entry) =>
            entry.metadata.sequence == metadata.sequence ||
            entry.metadata.signature.matches(signature),
      );
      _remember(_ambiguous, signature, now);
      return;
    }
    _lastSequence = metadata.sequence;
    final lastDispatched = _lastDispatchTimestamp[signature.fields.viewId];
    if (lastDispatched != null &&
        signature.fields.timestampMicros <= lastDispatched) {
      return;
    }
    if (_contains(_dispatched, signature) || _contains(_ambiguous, signature)) {
      return;
    }
    if (_pending.any((entry) => entry.metadata.signature.matches(signature))) {
      _pending.removeWhere(
        (entry) => entry.metadata.signature.matches(signature),
      );
      _remember(_ambiguous, signature, now);
      return;
    }
    _pending.add(_PendingWheel(metadata, now));
    while (_pending.length > _capacity) {
      _pending.removeFirst();
    }
  }

  NativeWheelMatch _match(PointerScrollEvent event) {
    final now = _clock();
    _expire(now);
    final previousTimestamp = _lastDispatchTimestamp.remove(event.viewId);
    final timestamp = event.timeStamp.inMicroseconds;
    _lastDispatchTimestamp[event.viewId] =
        previousTimestamp != null && previousTimestamp > timestamp
        ? previousTimestamp
        : timestamp;
    while (_lastDispatchTimestamp.length > _capacity) {
      _lastDispatchTimestamp.remove(_lastDispatchTimestamp.keys.first);
    }
    final ratio = _devicePixelRatioForView(event.viewId);
    if (ratio == null || !ratio.isFinite || ratio <= 0) {
      return NativeWheelMatch._(event, NativeWheelStatus.unknown, null);
    }
    final signature = _WheelSignature(
      event.viewId,
      event.timeStamp.inMicroseconds,
      event.position.dx * ratio,
      event.position.dy * ratio,
      event.scrollDelta.dx * ratio,
      event.scrollDelta.dy * ratio,
    );
    if (!signature.isFinite) {
      return NativeWheelMatch._(event, NativeWheelStatus.unknown, null);
    }
    final duplicate = _contains(_dispatched, signature);
    _remember(_dispatched, signature, now);
    if (_contains(_ambiguous, signature)) {
      return NativeWheelMatch._(event, NativeWheelStatus.ambiguous, null);
    }
    if (duplicate) {
      return NativeWheelMatch._(event, NativeWheelStatus.unknown, null);
    }
    _WheelMetadata? metadata;
    var matches = 0;
    _pending.removeWhere((entry) {
      if (!entry.metadata.signature.matches(signature)) return false;
      matches++;
      metadata = entry.metadata;
      return true;
    });
    if (matches > 1) {
      _remember(_ambiguous, signature, now);
      return NativeWheelMatch._(event, NativeWheelStatus.ambiguous, null);
    }
    return NativeWheelMatch._(
      event,
      metadata == null ? NativeWheelStatus.unknown : NativeWheelStatus.matched,
      metadata,
    );
  }

  void _expire(int now) {
    bool expired(int received) =>
        now < received || now - received >= _maxAgeMicros;
    _pending.removeWhere((entry) => expired(entry.received));
    _ambiguous.removeWhere((_, received) => expired(received));
    _dispatched.removeWhere((_, received) => expired(received));
  }

  void _remember(
    Map<_WheelSignature, int> entries,
    _WheelSignature signature,
    int now,
  ) {
    entries.removeWhere((key, _) => key.matches(signature));
    entries[signature] = now;
    while (entries.length > _capacity) {
      entries.remove(entries.keys.first);
    }
  }

  bool _contains(
    Map<_WheelSignature, int> entries,
    _WheelSignature signature,
  ) => entries.keys.any((key) => key.matches(signature));

  void _clear() {
    _pending.clear();
    _ambiguous.clear();
    _dispatched.clear();
    _lastDispatchTimestamp.clear();
    _lastSequence = 0;
  }

  static PointerScrollEvent _original(PointerScrollEvent event) =>
      (event.original ?? event) as PointerScrollEvent;

  static double? _viewDevicePixelRatio(int viewId) =>
      ui.PlatformDispatcher.instance.view(id: viewId)?.devicePixelRatio;

  static int Function() _elapsedClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsedMicroseconds;
  }
}

/// Keeps classification alive through the resolver callback at the end of
/// GestureBinding.dispatchEvent, rather than staging it in a widget listener.
mixin NativeWheelDispatchBinding on GestureBinding {
  @protected
  NativeWheelInput get nativeWheelInput => NativeWheelInput.instance;

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    nativeWheelInput.dispatch(
      event,
      () => super.dispatchEvent(event, hitTestResult),
    );
  }
}

class SeekDeskFlutterBinding extends WidgetsFlutterBinding
    with NativeWheelDispatchBinding {}

class _DispatchScope {
  _DispatchScope(this.match);
  final NativeWheelMatch match;
  bool consumed = false;
}

class _PendingWheel {
  const _PendingWheel(this.metadata, this.received);
  final _WheelMetadata metadata;
  final int received;
}

typedef _WheelSignatureFields = ({
  int viewId,
  int timestampMicros,
  double x,
  double y,
  double dx,
  double dy,
});

@immutable
class _WheelSignature {
  const _WheelSignature(
    int viewId,
    int timestampMicros,
    double x,
    double y,
    double dx,
    double dy,
  ) : fields = (
        viewId: viewId,
        timestampMicros: timestampMicros,
        x: x,
        y: y,
        dx: dx,
        dy: dy,
      );

  final _WheelSignatureFields fields;
  double get dx => fields.dx;
  double get dy => fields.dy;
  bool get isFinite =>
      fields.x.isFinite && fields.y.isFinite && dx.isFinite && dy.isFinite;

  bool matches(_WheelSignature other) =>
      fields.viewId == other.fields.viewId &&
      fields.timestampMicros == other.fields.timestampMicros &&
      (fields.x - other.fields.x).abs() <= 0.000001 &&
      (fields.y - other.fields.y).abs() <= 0.000001 &&
      (dx - other.dx).abs() <= 0.000001 &&
      (dy - other.dy).abs() <= 0.000001;

  @override
  bool operator ==(Object other) =>
      other is _WheelSignature && fields == other.fields;

  @override
  int get hashCode => fields.hashCode;
}

@immutable
class _WheelMetadata {
  const _WheelMetadata({
    required this.sequence,
    required this.signature,
    required this.precise,
    required this.phase,
    required this.momentumPhase,
    required this.modifiers,
  });

  final int sequence;
  final _WheelSignature signature;
  final bool precise;
  final int phase;
  final int momentumPhase;
  final int modifiers;

  static _WheelMetadata? decode(Object? message) {
    if (message is! Map ||
        message['version'] is! int ||
        message['version'] != 1) {
      return null;
    }
    final sequence = message['sequence'];
    final viewId = message['viewId'];
    final timestamp = message['timestampMicros'];
    final precise = message['precise'];
    final phase = message['phase'];
    final momentum = message['momentumPhase'];
    final modifiers = message['modifiers'];
    final x = message['x'];
    final y = message['y'];
    final dx = message['dx'];
    final dy = message['dy'];
    if (sequence is! int ||
        sequence <= 0 ||
        viewId is! int ||
        viewId < 0 ||
        timestamp is! int ||
        timestamp < 0 ||
        precise is! bool ||
        phase is! int ||
        phase < 0 ||
        momentum is! int ||
        momentum < 0 ||
        modifiers is! int ||
        modifiers < 0 ||
        x is! double ||
        y is! double ||
        dx is! double ||
        dy is! double) {
      return null;
    }
    final signature = _WheelSignature(viewId, timestamp, x, y, dx, dy);
    if (!signature.isFinite) return null;
    return _WheelMetadata(
      sequence: sequence,
      signature: signature,
      precise: precise,
      phase: phase,
      momentumPhase: momentum,
      modifiers: modifiers,
    );
  }
}
