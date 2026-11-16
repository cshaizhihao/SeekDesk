// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_chrome.dart';

/// A legible inset field within the surrounding glass surface. Only the border
/// animates; text, focus ownership and the child's input state stay untouched.
/// The child supplies its own padding and an empty BoxDecoration so Cupertino
/// does not insert a rectangular default background while the field is disabled.
class DeskInputSurface extends StatefulWidget {
  const DeskInputSurface({
    required this.child,
    this.radius = 10,
    super.key,
  });

  final Widget child;
  final double radius;

  @override
  State<DeskInputSurface> createState() => _DeskInputSurfaceState();
}

class _DeskInputSurfaceState extends State<DeskInputSurface> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final edge = _focused ? colors.accent : colors.line;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(begin: edge, end: edge),
        duration: GlassAccessibilityData.of(context).reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 130),
        child: widget.child,
        builder: (context, border, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: border ?? edge),
          ),
          child: child,
        ),
      ),
    );
  }
}
