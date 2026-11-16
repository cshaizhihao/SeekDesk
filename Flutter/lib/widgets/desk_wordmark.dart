// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

/// The production wordmark artwork, with the native layout's 3.1-wide frame.
/// The enclosing navigation button owns its label and accessibility action.
class DeskWordmark extends StatelessWidget {
  const DeskWordmark({this.palette = 'Cobalt', this.height = 30, super.key})
    : assert(height > 0 && height < double.infinity);

  final String palette;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final selected = switch (palette) {
      'Teal' || 'Fern' || 'Iris' || 'Amber' || 'Coral' => palette,
      _ => 'Cobalt',
    };
    final name = selected == 'Cobalt'
        ? (dark ? 'Wordmark-Dark' : 'Wordmark')
        : 'Wordmark-$selected-${dark ? 'Dark' : 'Light'}';
    // All original assets are 2172 x 724 (3:1). Decode only the physical size
    // needed for this display, preserving that ratio and never upscaling them.
    final decodeHeight = (height * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 724)
        .toInt();
    return SizedBox(
      width: height * 3.1,
      height: height,
      child: Image.asset(
        'assets/brand/$name.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        cacheWidth: decodeHeight * 3,
        cacheHeight: decodeHeight,
        excludeFromSemantics: true,
      ),
    );
  }
}
