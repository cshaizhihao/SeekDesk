import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

class ForumHangingList extends StatelessWidget {
  const ForumHangingList({
    required this.markers,
    required this.children,
    required this.style,
    this.markerBuilder,
    super.key,
  }) : assert(markers.length == children.length);

  final List<String> markers;
  final List<Widget> children;
  final TextStyle style;
  final Widget Function(int index, Widget marker)? markerBuilder;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    var markerWidth = scaler.scale(effectiveStyle.fontSize ?? 15) * 1.25;
    for (final marker in markers.toSet()) {
      final painter = TextPainter(
        text: TextSpan(text: '$marker ', style: effectiveStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      markerWidth = math.max(markerWidth, painter.width);
      painter.dispose();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 640.0;
        final gap = math.min(6.0, available * .1);
        final width = math.min(markerWidth, available * .4 - gap);
        return SizedBox(
          width: available,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index < children.length - 1 ? 8 : 0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: width,
                        child: _marker(index, effectiveStyle, scaler),
                      ),
                      SizedBox(width: gap),
                      Expanded(child: children[index]),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _marker(int index, TextStyle effectiveStyle, TextScaler scaler) {
    final marker = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.topEnd,
      child: Text(
        '${markers[index]} ',
        style: effectiveStyle,
        textScaler: scaler,
        maxLines: 1,
        softWrap: false,
      ),
    );
    return markerBuilder?.call(index, marker) ?? marker;
  }
}
