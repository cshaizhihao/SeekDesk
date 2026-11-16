// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import 'desk_interaction.dart';
import 'glass_chrome.dart';
import 'desk_theme.dart';
import 'reader_backdrop.dart';

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({
    required this.value,
    required this.family,
    required this.showReadingBackground,
    required this.onChanged,
    required this.onFamilyChanged,
    super.key,
  });

  final String value;
  final DeskThemeFamily family;
  final bool showReadingBackground;
  final ValueChanged<String> onChanged;
  final ValueChanged<DeskThemeFamily> onFamilyChanged;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final followsSystem = value != 'light' && value != 'dark';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('配色', style: TextStyle(color: colors.ink, fontSize: 13)),
              MergeSemantics(
                child: Semantics(
                  selected: followsSystem,
                  child: DeskButton(
                    '跟随系统',
                    icon: CupertinoIcons.device_laptop,
                    width: MediaQuery.textScalerOf(context).scale(53) + 56,
                    height: MediaQuery.textScalerOf(context).scale(14) + 18,
                    quiet: true,
                    selected: followsSystem,
                    onTap: () => onChanged('system'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final option in DeskThemeFamily.values)
                MergeSemantics(
                  child: Semantics(
                    selected: option == family,
                    child: DeskButton(
                      option.title,
                      width: MediaQuery.textScalerOf(context).scale(28) + 34,
                      height: MediaQuery.textScalerOf(context).scale(13) + 16,
                      quiet: true,
                      selected: option == family,
                      onTap: () => onFamilyChanged(option),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, bounds) {
              const gap = 12.0;
              final width = bounds.maxWidth >= 456
                  ? (bounds.maxWidth - gap) / 2
                  : bounds.maxWidth;
              // Keep the same two card elements when the window reflows.
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final mode in [Brightness.light, Brightness.dark])
                    SizedBox(
                      width: width,
                      child: _AppearanceCard(
                        key: ValueKey('appearance-${mode.name}'),
                        family: family,
                        brightness: mode,
                        selected: value == mode.name,
                        showReadingBackground: showReadingBackground,
                        onTap: () => onChanged(mode.name),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({
    required this.family,
    required this.brightness,
    required this.selected,
    required this.showReadingBackground,
    required this.onTap,
    super.key,
  });

  final Brightness brightness;
  final DeskThemeFamily family;
  final bool selected, showReadingBackground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final dark = brightness == Brightness.dark;
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        child: DeskInteraction(
          color: colors.accent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          child: CupertinoButton(
            color: selected ? colors.selection : colors.hover,
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(12),
            focusColor: colors.accent.withValues(alpha: .55),
            pressedOpacity: .78,
            onPressed: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? colors.accent : colors.line,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: _AppearancePreview(
                        family: family,
                        brightness: brightness,
                        showReadingBackground: showReadingBackground,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 3),
                      child: Row(
                        children: [
                          Icon(
                            dark ? CupertinoIcons.moon : CupertinoIcons.sun_max,
                            color: colors.secondary,
                            size: 15,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              dark ? family.darkTitle : family.lightTitle,
                              style: DeskTypography.control.copyWith(
                                color: colors.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            selected
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.circle,
                            size: 16,
                            color: selected ? colors.accent : colors.secondary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({
    required this.family,
    required this.brightness,
    required this.showReadingBackground,
  });

  final Brightness brightness;
  final DeskThemeFamily family;
  final bool showReadingBackground;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors.forBrightness(brightness, family: family);
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        height: 104,
        child: CustomPaint(
          foregroundPainter: _PreviewChrome(brightness, family),
          child: ReadingArtwork(
            colors: colors,
            enabled: showReadingBackground,
            cacheWidth: 480,
          ),
        ),
      ),
    );
  }
}

/// A miniature of the three-column workspace, painted with the live UI colors.
class _PreviewChrome extends CustomPainter {
  const _PreviewChrome(this.brightness, this.family);
  final Brightness brightness;
  final DeskThemeFamily family;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = DeskColors.forBrightness(brightness, family: family);
    final w = size.width, h = size.height;
    final paint = Paint();
    void fill(
      double x,
      double y,
      double width,
      double height,
      Color color, [
      double radius = 0,
    ]) {
      paint.color = color;
      canvas.drawRRect(
        RRect.fromLTRBR(x, y, x + width, y + height, Radius.circular(radius)),
        paint,
      );
    }

    fill(0, 0, w * .21, h, colors.canvas);
    fill(w * .21, 0, w * .27, h, colors.paper.withValues(alpha: 1));
    fill(0, 0, w, 15, colors.backdrop.first);
    fill(0, 15, w, 1, colors.line);
    fill(w * .21, 16, 1, h - 16, colors.line);
    fill(w * .48, 16, 1, h - 16, colors.line);
    for (var index = 0; index < 3; index++) {
      fill(7 + index * 6, 6, 3, 3, colors.secondary.withValues(alpha: .48), 2);
    }
    fill(w * .77, 5, w * .19, 5, colors.line, 2.5);
    fill(w * .025, 24, w * .16, 12, colors.selection, 4);
    for (var index = 0; index < 4; index++) {
      final y = 28.0 + index * 17;
      fill(
        w * .045,
        y,
        w * .105,
        3,
        colors.secondary.withValues(alpha: .58),
        1.5,
      );
      if (index == 0) fill(w * .225, y - 4, w * .24, 14, colors.selection, 3);
      fill(w * .24, y, 6, 6, colors.accent.withValues(alpha: .55), 3);
      fill(
        w * .24 + 10,
        y,
        w * (.13 - index * .01),
        2.5,
        colors.ink.withValues(alpha: .62),
        1.25,
      );
      fill(
        w * .24 + 10,
        y + 5,
        w * .095,
        2,
        colors.secondary.withValues(alpha: .42),
        1,
      );
    }
    fill(w * .53, 25, w * .34, 5, colors.ink.withValues(alpha: .87), 2.5);
    fill(w * .53, 36, w * .16, 2.5, colors.accent.withValues(alpha: .8), 1.25);
    for (final (index, length) in [.37, .32, .40, .24].indexed) {
      fill(
        w * .53,
        48 + index * 7,
        w * length,
        2.5,
        colors.ink.withValues(alpha: .42),
        1.25,
      );
    }
    fill(w * .53, 83, w * .39, 11, colors.well.withValues(alpha: .72), 3);
    fill(w * .56, 87, w * .22, 2.5, colors.accent.withValues(alpha: .7), 1.25);
  }

  @override
  bool shouldRepaint(_PreviewChrome oldDelegate) =>
      oldDelegate.brightness != brightness || oldDelegate.family != family;
}
