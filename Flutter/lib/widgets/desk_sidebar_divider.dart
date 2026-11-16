// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';

/// A desktop sidebar resize handle. The parent owns and persists [width].
///
/// Drag updates are previews; only [onChangeEnd] commits a completed adjustment.
/// Cancelling delegates restoration to [onCancel], so the parent can restore a
/// newer pending save instead of a stale drag-start value.
class DeskSidebarDivider extends StatefulWidget {
  const DeskSidebarDivider({
    required this.width,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onCancel,
    required this.onReset,
    this.minimum = 184,
    this.maximum = 360,
    this.label = '侧边栏宽度',
    this.adjustmentStep = 8,
    super.key,
  }) : assert(width >= 0 && width < double.infinity),
       assert(minimum >= 0 && minimum < double.infinity),
       assert(maximum >= minimum && maximum < double.infinity),
       assert(adjustmentStep > 0 && adjustmentStep < double.infinity);

  final double width;
  final double minimum;
  final double maximum;
  final String label;
  final double adjustmentStep;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  @override
  State<DeskSidebarDivider> createState() => _DeskSidebarDividerState();
}

class _DeskSidebarDividerState extends State<DeskSidebarDivider> {
  double get _step => widget.adjustmentStep;
  late final _focus = FocusNode(debugLabel: widget.label);
  final Set<LogicalKeyboardKey> _adjustmentKeys = {};
  bool _hovered = false;
  bool _focused = false;
  bool _keyboardChanged = false;
  bool _disposing = false;
  double? _keyboardValue;
  double? _dragStartWidth;
  double? _dragStartX;
  double? _dragValue;

  double _clamp(double value) =>
      value.clamp(widget.minimum, widget.maximum).toDouble();
  double get _value => _clamp(widget.width);
  bool get _adjustable => widget.minimum < widget.maximum;

  @override
  void didUpdateWidget(DeskSidebarDivider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label) _focus.debugLabel = widget.label;
  }

  void _dragStart(DragStartDetails details) {
    final start = _keyboardValue ?? _value;
    _finishKeyboard();
    _focus.requestFocus();
    setState(() {
      _dragStartWidth = start;
      _dragStartX = details.globalPosition.dx;
      _dragValue = start;
    });
  }

  void _dragUpdate(DragUpdateDetails details) {
    final start = _dragStartWidth;
    final origin = _dragStartX;
    if (start == null || origin == null) return;
    // The divider itself moves when the parent relayouts. Local deltas would
    // feed that movement back into the resize, so measure from global origin.
    final value = _clamp(start + details.globalPosition.dx - origin);
    if (value == _dragValue) return;
    _dragValue = value;
    widget.onChanged(value);
  }

  void _dragEnd(DragEndDetails details) {
    final value = _dragValue;
    if (_disposing || !mounted || value == null) return;
    _clearDrag();
    widget.onChangeEnd(_clamp(value));
  }

  void _dragCancel() {
    if (_disposing || !mounted || _dragStartWidth == null) return;
    _clearDrag();
    widget.onCancel();
  }

  void _clearDrag() {
    setState(() {
      _dragStartWidth = null;
      _dragStartX = null;
      _dragValue = null;
    });
  }

  bool _isAdjustmentKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.home ||
      key == LogicalKeyboardKey.end;

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (!_adjustable || !_isAdjustmentKey(key) || _dragStartWidth != null) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (!_adjustmentKeys.remove(key)) return KeyEventResult.ignored;
      if (_adjustmentKeys.isEmpty) _finishKeyboard();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    _adjustmentKeys.add(key);
    final current = _keyboardValue ?? _value;
    final requested = key == LogicalKeyboardKey.home
        ? widget.minimum
        : key == LogicalKeyboardKey.end
        ? widget.maximum
        : current + (key == LogicalKeyboardKey.arrowRight ? _step : -_step);
    final next = _clamp(requested);
    _keyboardValue = next;
    if (next != current) {
      _keyboardChanged = true;
      widget.onChanged(next);
    }
    return KeyEventResult.handled;
  }

  void _finishKeyboard() {
    final value = _keyboardValue;
    final changed = _keyboardChanged;
    _adjustmentKeys.clear();
    _keyboardValue = null;
    _keyboardChanged = false;
    if (!_disposing && mounted && changed && value != null) {
      widget.onChangeEnd(_clamp(value));
    }
  }

  void _semanticAdjustment(double delta) {
    if (_dragStartWidth != null) return;
    _finishKeyboard();
    final next = _clamp(_value + delta);
    if (next == _value) return;
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  void _reset() {
    // A double click is its own action; do not also persist an intermediate
    // keyboard value or dispatch a synthetic drag completion.
    _adjustmentKeys.clear();
    _keyboardValue = null;
    _keyboardChanged = false;
    widget.onReset();
  }

  @override
  void dispose() {
    _disposing = true;
    _adjustmentKeys.clear();
    _keyboardValue = null;
    _keyboardChanged = false;
    _dragStartWidth = null;
    _dragStartX = null;
    _dragValue = null;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final emphasized = _hovered || _dragStartWidth != null;
    final color = _focused
        ? CupertinoDynamicColor.resolve(
            CupertinoColors.activeBlue,
            context,
          ).withValues(alpha: 0.5)
        : CupertinoDynamicColor.resolve(
            CupertinoColors.label,
            context,
          ).withValues(alpha: emphasized ? 0.25 : 0.10);
    String description(double size) => '${size.round()} 点';

    return Semantics(
      container: true,
      label: widget.label,
      value: description(value),
      increasedValue: value < widget.maximum
          ? description(_clamp(value + _step))
          : null,
      decreasedValue: value > widget.minimum
          ? description(_clamp(value - _step))
          : null,
      slider: true,
      enabled: _adjustable,
      focusable: _adjustable,
      focused: _focused,
      onIncrease: value < widget.maximum
          ? () => _semanticAdjustment(_step)
          : null,
      onDecrease: value > widget.minimum
          ? () => _semanticAdjustment(-_step)
          : null,
      child: Focus(
        focusNode: _focus,
        includeSemantics: false,
        canRequestFocus: _adjustable,
        onFocusChange: (focused) {
          if (_disposing || !mounted) return;
          if (!focused) _finishKeyboard();
          setState(() => _focused = focused);
        },
        onKeyEvent: _keyEvent,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Listener(
            onPointerDown: (_) => _focus.requestFocus(),
            // Flutter's accepted drag recognizer routes PointerCancelEvent to
            // onEnd. Clear the drag before gesture routing can commit it.
            onPointerCancel: (_) => _dragCancel(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: _adjustable ? _dragStart : null,
              onHorizontalDragUpdate: _adjustable ? _dragUpdate : null,
              onHorizontalDragEnd: _adjustable ? _dragEnd : null,
              onHorizontalDragCancel: _adjustable ? _dragCancel : null,
              onDoubleTap: _reset,
              child: SizedBox(
                width: 9,
                child: Center(
                  child: SizedBox(
                    width: 1,
                    height: double.infinity,
                    child: ColoredBox(color: color),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
