// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import 'glass_chrome.dart';
import 'desk_theme.dart';

/// A static, theme-matched backdrop for the reader's bounded viewport.
///
/// Wrap the reader pane, not its slivers: the supplied child owns scrolling,
/// while the artwork stays fixed behind it.
class ReaderBackdrop extends StatelessWidget {
  const ReaderBackdrop({required this.child, this.enabled = true, super.key});

  static const darkAsset = 'assets/reader/reader-dark.png';
  static const lightAsset = 'assets/reader/reader-light.png';

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ReadingArtwork(
                colors: DeskColors(context),
                enabled: enabled,
              ),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

class ReadingArtwork extends StatelessWidget {
  const ReadingArtwork({
    required this.colors,
    required this.enabled,
    this.cacheWidth,
    super.key,
  });

  final DeskColors colors;
  final bool enabled;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final paper = colors.paper.withValues(alpha: 1);
    if (!enabled) return ColoredBox(color: paper);
    final brightness = colors.dark ? Brightness.dark : Brightness.light;
    final art = Image.asset(
      colors.family.readingAsset(brightness),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
    );
    if (colors.family == DeskThemeFamily.classic) return art;
    // Keep the center quiet for text. More of the landscape can show through
    // at the lower edge, without a blur layer or animation during scrolling.
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: paper),
        art,
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, .56, 1],
              colors: [
                paper.withValues(alpha: .80),
                paper.withValues(alpha: .70),
                paper.withValues(alpha: .47),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
