import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/native_wheel_input.dart';

/// Interpolates only native-classified wheel signals won by this scrollable.
/// The standard pointer-signal resolver still owns nested scrolling and bounds.
class ReaderWheelScrollController extends ScrollController {
  ReaderWheelScrollController({
    required this.onUserWheel,
    this.onWheel,
    NativeWheelInput? input,
    super.initialScrollOffset,
    super.keepScrollOffset = false,
    super.onAttach,
    super.onDetach,
  }) : input = input ?? NativeWheelInput.instance;

  final NativeWheelInput input;
  final VoidCallback onUserWheel;
  final void Function(PointerScrollEvent event, bool smooth)? onWheel;
  bool _motionEnabled = true;
  int _wheelDispatchDepth = 0;

  bool get dispatchingWheel => _wheelDispatchDepth != 0;
  bool get motionEnabled => _motionEnabled;

  set motionEnabled(bool value) {
    if (_motionEnabled == value) return;
    _motionEnabled = value;
    if (!value) cancelWheel();
  }

  void cancelWheel() {
    for (final position in positions.toList(growable: false)) {
      if (position is ReaderWheelScrollPosition) position.cancelWheel();
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => ReaderWheelScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
  );

  @override
  void detach(ScrollPosition position) {
    if (position is ReaderWheelScrollPosition) position.cancelWheel();
    super.detach(position);
  }

  @override
  void dispose() {
    cancelWheel();
    super.dispose();
  }
}

class ReaderWheelScrollPosition extends ScrollPositionWithSingleContext {
  ReaderWheelScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
  });

  final ReaderWheelScrollController controller;

  void cancelWheel() {
    final current = activity;
    if (current is! _ReaderWheelActivity) return;
    if (context.notificationContext == null) {
      // Scrollable.dispose detaches its controller after removing this context.
      // Halt now; ScrollPosition.dispose will release the activity without
      // attempting to dispatch ScrollEndNotification through a removed element.
      current.retire();
    } else {
      goIdle();
    }
  }

  @override
  void absorb(ScrollPosition other) {
    super.absorb(other);
    // A retained offset can transfer to a replacement position; an input tail
    // must not retain the previous ScrollContext's ticker/ownership.
    cancelWheel();
  }

  @override
  void pointerScroll(double delta) {
    final match = controller.input.consume();
    if (!delta.isFinite || !hasContentDimensions || !hasPixels) {
      cancelWheel();
      return;
    }
    if (delta == 0) {
      cancelWheel();
      super.pointerScroll(delta);
      return;
    }
    final target = (pixels + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    final smooth =
        controller.motionEnabled &&
        match?.eligible == true &&
        axisDirection == AxisDirection.down &&
        match!.event.scrollDelta.dy == delta &&
        !outOfRange;
    controller._wheelDispatchDepth++;
    try {
      // Every accepted original signal takes ownership before its first pixel,
      // including repeated same-direction signals during a pending floor seek.
      controller.onUserWheel();
      if (match != null) controller.onWheel?.call(match.event, smooth);
      if (!smooth) {
        cancelWheel();
        super.pointerScroll(delta);
        return;
      }
      updateUserScrollDirection(
        delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
      );
      final current = activity;
      if (current is _ReaderWheelActivity && !current.retired) {
        current.add(delta);
      } else {
        final next = _ReaderWheelActivity(this, context.vsync);
        beginActivity(next);
        next.add(delta);
      }
    } finally {
      controller._wheelDispatchDepth--;
    }
  }
}

/// A single activity retains the destination of a wheel burst. A new direction
/// discards the old, unconsumed tail, so reversal never coasts the wrong way.
/// Same-direction input conserves distance up to the document's actual bounds.
class _ReaderWheelActivity extends ScrollActivity {
  _ReaderWheelActivity(
    ReaderWheelScrollPosition super.position,
    TickerProvider vsync,
  ) : _target = position.pixels {
    _ticker = vsync.createTicker(_tick);
  }

  static const _tail = Duration(milliseconds: 140);
  static const _responseSeconds = .028;
  late final Ticker _ticker;
  double _target;
  double _direction = 0;
  Duration _elapsed = Duration.zero;
  Duration _lastInput = Duration.zero;
  bool _disposed = false;
  bool retired = false;

  void retire() {
    if (_disposed || retired) return;
    retired = true;
    _ticker.stop();
  }

  ReaderWheelScrollPosition get position =>
      delegate as ReaderWheelScrollPosition;

  void add(double delta) {
    if (_disposed || retired) return;
    final nextDirection = delta.sign;
    if (_direction != 0 && nextDirection != _direction) {
      _target = position.pixels;
    }
    _direction = nextDirection;
    _target = (_target + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _lastInput = _elapsed;
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration elapsed) {
    if (_disposed || retired) return;
    if (!position.controller.motionEnabled) {
      delegate.goIdle();
      return;
    }
    final seconds = (elapsed - _elapsed).inMicroseconds / 1000000;
    _elapsed = elapsed;
    if (seconds <= 0) return;
    _target = _target.clamp(position.minScrollExtent, position.maxScrollExtent);
    final before = position.pixels;
    final finish =
        elapsed - _lastInput >= _tail || (_target - before).abs() < .05;
    final next = finish
        ? _target
        : _target + (before - _target) * math.exp(-seconds / _responseSeconds);
    final overscroll = delegate.setPixels(next);
    // A position listener may replace this activity synchronously.
    if (_disposed || retired) return;
    if (finish || overscroll != 0) delegate.goIdle();
  }

  @override
  void applyNewDimensions() {
    if (position.outOfRange) {
      delegate.goBallistic(0);
    } else {
      _target = _target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    }
  }

  @override
  void resetActivity() => delegate.goIdle();

  @override
  bool get isScrolling => true;
  @override
  bool get shouldIgnorePointer => false;
  @override
  // This visual wheel tail must not become carried fling momentum when the
  // user switches to a touch/trackpad drag through ScrollPosition.hold.
  double get velocity => 0;

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    super.dispose();
  }
}
