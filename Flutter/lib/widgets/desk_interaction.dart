import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Pointer-following edge light, press response and keyboard focus. Paint only;
/// the wrapped button owns activation, semantics and its unchanged text layout.
class DeskInteraction extends StatefulWidget {
  const DeskInteraction({
    required this.child,
    required this.color,
    this.enabled = true,
    this.radius = 12,
    this.shape,
    super.key,
  });
  final Widget child;
  final Color color;
  final bool enabled;
  final double radius;

  /// Match the actual optical silhouette, including continuous corners.
  /// Callers without a glass shape retain their rounded-rectangle outline.
  final OutlinedBorder? shape;

  @override
  State<DeskInteraction> createState() => _DeskInteractionState();
}

class _DeskInteractionState extends State<DeskInteraction>
    with SingleTickerProviderStateMixin {
  late final _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    reverseDuration: const Duration(milliseconds: 220),
  );
  final _point = ValueNotifier<Offset?>(null);
  late final _paint = Listenable.merge([_light, _point]);
  bool _hovered = false, _focused = false, _pressed = false;
  bool _reduceMotion = false;

  void _update() {
    final target = !widget.enabled
        ? 0.0
        : _pressed
        ? 1.0
        : (_hovered || _focused)
        ? .65
        : 0.0;
    if (_reduceMotion) {
      _light.value = target;
    } else {
      _light.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        GlassAccessibilityData.of(context).reduceMotion;
    _update();
  }

  @override
  void didUpdateWidget(DeskInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _pressed = false;
      _update();
    }
  }

  @override
  void dispose() {
    _light.dispose();
    _point.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (value) {
      _focused = value;
      _update();
    },
    child: MouseRegion(
      onEnter: (event) {
        _hovered = true;
        _point.value = event.localPosition;
        _update();
      },
      onHover: (event) {
        if (widget.enabled && !_reduceMotion) {
          _point.value = event.localPosition;
        }
      },
      onExit: (_) {
        _hovered = false;
        _pressed = false;
        _point.value = null;
        _update();
      },
      child: Listener(
        onPointerDown: (_) {
          _pressed = true;
          _update();
        },
        onPointerUp: (_) {
          _pressed = false;
          _update();
        },
        onPointerCancel: (_) {
          _pressed = false;
          _update();
        },
        child: Stack(
          // Preserve the button's original tight constraints and hit area,
          // notably the full-width pagination retry control in a list footer.
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _EdgeLight(
                      repaint: _paint,
                      strength: _light,
                      point: _point,
                      color: widget.color,
                      radius: widget.radius,
                      shape: widget.shape,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EdgeLight extends CustomPainter {
  _EdgeLight({
    required Listenable repaint,
    required this.strength,
    required this.point,
    required this.color,
    required this.radius,
    required this.shape,
  }) : super(repaint: repaint);
  final Animation<double> strength;
  final ValueListenable<Offset?> point;
  final Color color;
  final double radius;
  final OutlinedBorder? shape;
  Size? _outlineSize;
  Path? _outline;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength.value == 0 || size.isEmpty) return;
    final bounds = (Offset.zero & size).deflate(1);
    if (_outlineSize != size) {
      _outlineSize = size;
      _outline =
          shape?.getOuterPath(bounds) ??
          (Path()..addRRect(
            RRect.fromRectAndRadius(bounds, Radius.circular(radius)),
          ));
    }
    final outline = _outline!;
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: strength.value * .55),
    );
    final center = point.value ?? Offset(size.width / 2, 0);
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = RadialGradient(
          colors: [
            const Color(0xffffffff).withValues(alpha: strength.value),
            const Color(0x00ffffff),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: 100)),
    );
  }

  @override
  bool shouldRepaint(_EdgeLight old) =>
      old.color != color ||
      old.radius != radius ||
      old.shape != shape ||
      old.strength != strength ||
      old.point != point;
}
