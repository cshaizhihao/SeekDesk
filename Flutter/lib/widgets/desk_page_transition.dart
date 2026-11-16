import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// A single live page: no outgoing editor, duplicated semantics or opacity
/// layer around refractive controls. Translation lands on physical pixels.
class DeskPageTransition extends StatefulWidget {
  const DeskPageTransition({
    required this.identity,
    required this.child,
    this.distance = 12,
    super.key,
  });

  final Object identity;
  final Widget child;

  /// Positive enters from the reading direction; negative returns to a prior
  /// section. Only the new page moves, so outgoing editors never remain live.
  final double distance;

  @override
  State<DeskPageTransition> createState() => _DeskPageTransitionState();
}

class _DeskPageTransitionState extends State<DeskPageTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        GlassAccessibilityData.of(context).reduceMotion;
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(DeskPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final remaining =
              1 - Curves.easeOutCubic.transform(_controller.value);
          final dx =
              (widget.distance * direction * remaining * ratio).round() / ratio;
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
      ),
    );
  }
}
