import 'dart:ui' show ImageFilter;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../state/app_state.dart';
import 'desk_interaction.dart';
import 'desk_theme.dart';

/// Enum to define glass layer hierarchy for visual depth
enum GlassLevel {
  background, // Deepest layer: window backdrop, canvas
  panel, // Mid layer: settings sections, grouped content
  card, // Elevated: list items, tiles
  control, // Buttons and interactive elements
  overlay, // Bounded menus and feedback over reading content
}

class DeskColors {
  DeskColors(BuildContext context)
    : this.forBrightness(
        CupertinoTheme.brightnessOf(context),
        highContrast: MediaQuery.highContrastOf(context),
        family: DeskThemeScope.of(context),
      );
  const DeskColors.forBrightness(
    Brightness brightness, {
    this.highContrast = false,
    this.family = DeskThemeFamily.classic,
  }) : dark = brightness == Brightness.dark;

  final bool dark, highContrast;
  final DeskThemeFamily family;
  Color get canvas => backdrop[1];
  Color get ink => dark ? const Color(0xffe9eef5) : const Color(0xff2c2925);
  Color get secondary => highContrast
      ? (dark ? const Color(0xffc7d3df) : const Color(0xff494039))
      : (dark ? const Color(0xffafbdcc) : const Color(0xff655d53));
  Color get accent => switch (family) {
    DeskThemeFamily.classic =>
      dark ? const Color(0xffabc8f3) : const Color(0xff4b627d),
    DeskThemeFamily.mountain =>
      dark ? const Color(0xffabd5ba) : const Color(0xff365b48),
    DeskThemeFamily.coast =>
      dark ? const Color(0xff94d8e2) : const Color(0xff285d66),
  };
  Color get selectionInk => family != DeskThemeFamily.classic || dark
      ? accent
      : const Color(0xff3e5570);
  Color get paper => switch (family) {
    DeskThemeFamily.classic =>
      dark ? const Color(0xfa25303d) : const Color(0xfafbf8f2),
    DeskThemeFamily.mountain =>
      dark ? const Color(0xfa243831) : const Color(0xfaf5f6ed),
    DeskThemeFamily.coast =>
      dark ? const Color(0xfa203442) : const Color(0xfaf1f8f6),
  };
  Color get line => highContrast
      ? (dark ? const Color(0x66ffffff) : const Color(0x662c2925))
      : (dark ? const Color(0x18ddeaff) : const Color(0x232c2925));
  Color get well => switch (family) {
    DeskThemeFamily.classic =>
      dark ? const Color(0xff1a2330) : const Color(0xffeee7db),
    DeskThemeFamily.mountain =>
      dark ? const Color(0xff182c25) : const Color(0xffe4ebdd),
    DeskThemeFamily.coast =>
      dark ? const Color(0xff142936) : const Color(0xffddeeea),
  };
  Color get hover => highContrast
      ? (dark ? const Color(0x24ffffff) : const Color(0x16000000))
      : (dark ? const Color(0x0dffffff) : const Color(0x07000000));
  Color get selection => family == DeskThemeFamily.classic
      ? (dark ? const Color(0x334c79b9) : const Color(0x20526986))
      : accent.withValues(alpha: dark ? .16 : .13);

  List<Color> get backdrop => switch (family) {
    DeskThemeFamily.classic =>
      dark
          ? const [Color(0xff303d4d), Color(0xff23303e), Color(0xff1c2430)]
          : const [Color(0xfff8f3eb), Color(0xffeee8df), Color(0xffe7ded1)],
    DeskThemeFamily.mountain =>
      dark
          ? const [Color(0xff2b4137), Color(0xff21352e), Color(0xff172720)]
          : const [Color(0xfff1f4e9), Color(0xffe5ecdf), Color(0xffd8e3d3)],
    DeskThemeFamily.coast =>
      dark
          ? const [Color(0xff274754), Color(0xff1b3441), Color(0xff122631)]
          : const [Color(0xffeff8f4), Color(0xffdfeee9), Color(0xffd1e6df)],
  };
}

/// Desktop text roles share the system font, without overriding the reader's
/// user-selected sizes or scaling an already rasterized block of text.
abstract final class DeskTypography {
  static const family = '.AppleSystemUIFont';
  static const fallbacks = ['PingFang SC', 'Helvetica Neue'];
  static const base = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallbacks,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
    letterSpacing: 0,
  );
  static const control = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.25,
  );
  static const metadata = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const section = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const page = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  // Explicit system typography for rich text too; no painted shadows or
  // scaled cached glyphs to simulate antialiasing.
  static TextStyle reading({required double size, required Color color}) =>
      base.copyWith(fontSize: size, color: color, height: 1.75);
}

/// Broad glass surfaces use a thinner optical body than small interactive
/// controls. Retain the pinned engine, lighting and accessibility fallback.
abstract final class DeskMaterials {
  static const _lightOpacityLift = .04;
  static const _darkOpacityLift = .03;

  static LiquidGlassSettings forLevel(BuildContext context, GlassLevel level) =>
      switch (level) {
        GlassLevel.background => background(context),
        GlassLevel.panel => panel(context),
        GlassLevel.card => card(context),
        GlassLevel.control => control(context),
        GlassLevel.overlay => overlay(context),
      };

  static Color _surfaceTint(Color color, {required bool dark}) =>
      color.withValues(
        alpha: (color.a + (dark ? _darkOpacityLift : _lightOpacityLift)).clamp(
          0,
          1,
        ),
      );

  /// Compute elevation shadow for floating elements
  static List<BoxShadow> elevationShadow(
    BuildContext context, {
    required double elevation,
  }) {
    if (elevation <= 0) return const [];
    final colors = DeskColors(context);
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return const [];
    }
    // Subtle depth shadow scaled by elevation, no harsh borders
    return [
      BoxShadow(
        color: (colors.dark ? CupertinoColors.black : const Color(0xff252832))
            .withValues(alpha: colors.dark ? 0.28 : 0.18),
        blurRadius: elevation * 3,
        spreadRadius: -elevation * 0.5,
        offset: Offset(0, elevation * 0.8),
      ),
    ];
  }

  /// Background glass: deepest layer, minimal frost
  static LiquidGlassSettings background(BuildContext context) {
    final colors = DeskColors(context);
    final base = _quiet(context);
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return base;
    }
    return base.copyWith(
      glassColor: _surfaceTint(
        CupertinoColors.white.withValues(alpha: colors.dark ? .002 : .08),
        dark: colors.dark,
      ),
      thickness: 18,
      // This broad plane sits over the static window gradient. Re-blurring it
      // on every reader scroll adds a full-size GPU pass with no visible gain.
      // Optical edges/tint remain; interactive controls keep their own blur.
      blur: 0,
      frost: 6,
      rimShade: colors.dark ? .15 : .20,
      rimLight: colors.dark ? .55 : .45,
    );
  }

  /// Panel glass: mid-layer for grouped sections
  static LiquidGlassSettings panel(BuildContext context) {
    final colors = DeskColors(context);
    final base = _quiet(context);
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return base;
    }
    return base.copyWith(
      glassColor: _surfaceTint(
        CupertinoColors.white.withValues(alpha: colors.dark ? .008 : .12),
        dark: colors.dark,
      ),
      thickness: 20,
      blur: 0,
      frost: 8,
      rimShade: colors.dark ? .18 : .23,
      rimLight: colors.dark ? .60 : .50,
    );
  }

  /// Menus and feedback need to remain readable over arbitrary post content.
  /// Keep this opt-in and locally bounded; broad panes retain their clear body.
  static LiquidGlassSettings overlay(BuildContext context) {
    final colors = DeskColors(context);
    return _quiet(context).copyWith(
      bodyMode: GlassBodyMode.clear,
      glassColor: colors.paper.withValues(alpha: colors.dark ? .12 : .18),
      // The panel blurs the backdrop once, beneath the optical glass edge.
      blur: 0,
      frost: 0,
      saturation: 1,
    );
  }

  /// Card glass: elevated list items and tiles
  static LiquidGlassSettings card(
    BuildContext context, {
    double elevation = 1,
  }) {
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return tile(context);
    }
    final colors = DeskColors(context);
    return tile(context).copyWith(
      thickness: 20 + elevation.clamp(0, 8),
      rimLight: (colors.dark ? .55 : .45) + elevation * .02,
    );
  }

  static GlassThemeData theme(Brightness brightness) {
    final base = GlassThemeData.ios27(brightness: brightness);
    GlassThemeVariant tune(GlassThemeVariant variant, {required bool dark}) {
      final settings = variant.settings!;
      return variant.copyWith(
        settings: settings.copyWith(
          glassColor: _surfaceTint(settings.glassColor!, dark: dark),
        ),
      );
    }

    return base.copyWith(
      light: tune(base.light, dark: false),
      dark: tune(base.dark, dark: true),
    );
  }

  static LiquidGlassSettings content(BuildContext context) => _quiet(context);
  static LiquidGlassSettings tile(BuildContext context) {
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return _quiet(context);
    }
    final colors = DeskColors(context);
    return _quiet(context).copyWith(
      glassColor: _surfaceTint(
        CupertinoColors.white.withValues(alpha: colors.dark ? .035 : .19),
        dark: colors.dark,
      ),
      thickness: 18,
      rimLight: colors.dark ? .55 : .45,
    );
  }

  /// A resting action sits above the content without a permanent heavy bevel.
  /// GlassButton still owns its premium interactive lens and spring response.
  static LiquidGlassSettings control(
    BuildContext context, {
    bool quiet = false,
    bool selected = false,
  }) {
    final colors = DeskColors(context);
    final fill = selected
        ? colors.accent.withValues(alpha: colors.dark ? .16 : .08)
        : CupertinoColors.white.withValues(
            alpha: colors.dark ? (quiet ? .005 : .035) : (quiet ? .10 : .22),
          );
    final preset = LiquidGlassSettings.ios27(context);
    final base =
        GlassThemeData.of(context).settingsFor(context)?.applyTo(preset) ??
        preset;
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return base.copyWith(
        glassColor: selected
            ? Color.alphaBlend(fill, colors.paper.withValues(alpha: 1))
            : colors.paper.withValues(alpha: 1),
        shadow: const [],
      );
    }
    return base.copyWith(
      bodyMode: GlassBodyMode.clear,
      glassColor: selected ? fill : _surfaceTint(fill, dark: colors.dark),
      thickness: quiet ? 20 : 24,
      frost: 8,
      rimShade: quiet ? .20 : .30,
      rimLight: quiet ? .50 : .80,
      bodyShade: colors.dark ? .06 : 0,
      edgeAbsorption: .015,
      shadow: const [],
    );
  }

  static LiquidGlassSettings _quiet(BuildContext context) {
    final colors = DeskColors(context);
    final preset = LiquidGlassSettings.ios27(context);
    final base =
        GlassThemeData.of(context).settingsFor(context)?.applyTo(preset) ??
        preset;
    if (GlassAccessibilityData.of(context).reduceTransparency) {
      return base.copyWith(
        glassColor: colors.paper.withValues(alpha: 1),
        shadow: const [],
      );
    }
    return base.copyWith(
      bodyMode: GlassBodyMode.clear,
      glassColor: _surfaceTint(
        CupertinoColors.white.withValues(alpha: colors.dark ? .005 : .10),
        dark: colors.dark,
      ),
      thickness: 20,
      blur: .6,
      frost: 8,
      frostOpacity: colors.dark ? .62 : .55,
      frostWeight: 1,
      blurWeight: 1,
      rimShade: colors.dark ? .20 : .25,
      rimLight: colors.dark ? .65 : .55,
      bodyShade: colors.dark ? .08 : 0,
      edgeAbsorption: .015,
      saturation: colors.dark ? 1.05 : 1.15,
      shadow: const [],
    );
  }
}

class DeskPageHeader extends StatelessWidget {
  const DeskPageHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: DeskTypography.page.copyWith(color: colors.ink),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ],
    );
  }
}

class DeskButton extends StatelessWidget {
  const DeskButton(
    this.label, {
    required this.onTap,
    this.icon,
    this.width = 104,
    this.height = 35,
    this.busy = false,
    this.tint,
    this.quiet = false,
    this.selected = false,
    this.semanticLabel,
    super.key,
  });
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final double width, height;
  final bool busy;
  final Color? tint;

  /// Secondary chrome keeps the same interactive lens and hit target, with a
  /// lighter resting tint so it does not compete with the current selection.
  final bool quiet;
  final bool selected;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final enabled = onTap != null && !busy;
    final shape = label.isEmpty
        ? LiquidRoundedRectangle(borderRadius: height / 2)
        : const LiquidRoundedSuperellipse(borderRadius: 12);
    final button = GlassButton.custom(
      width: width,
      height: height,
      shape: shape,
      quality: GlassQuality.premium,
      useOwnLayer: true,
      // Lens thickness/glow animate, while labels remain at native resolution.
      interactionScale: 1,
      stretch: 0,
      settings: DeskMaterials.control(
        context,
        quiet: quiet,
        selected: selected,
      ),
      enabled: enabled,
      onTap: enabled ? onTap! : () {},
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy)
            const CupertinoActivityIndicator(radius: 7)
          else if (icon != null)
            Icon(icon, size: 15, color: tint ?? colors.secondary),
          if (label.isNotEmpty) ...[
            if (icon != null || busy) const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DeskTypography.control.copyWith(
                  color: tint ?? colors.ink,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      value: busy ? '处理中' : null,
      selected: selected ? true : null,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: IgnorePointer(
        ignoring: !enabled,
        // The package dims disabled controls itself. An outer Opacity, even at
        // 1, would opt active controls out of shared backdrop sampling.
        child: DeskInteraction(
          color: colors.accent,
          enabled: enabled,
          radius: label.isEmpty ? height / 2 : 12,
          shape: shape,
          child: button,
        ),
      ),
    );
  }
}

class DeskIcon extends StatelessWidget {
  const DeskIcon(
    this.label,
    this.icon,
    this.onTap, {
    this.busy = false,
    this.quiet = false,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy, quiet;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    waitDuration: const Duration(milliseconds: 450),
    showDuration: const Duration(seconds: 3),
    child: DeskButton(
      '',
      semanticLabel: label,
      onTap: onTap,
      icon: icon,
      width: 32,
      height: 32,
      busy: busy,
      quiet: quiet,
    ),
  );
}

class DeskDocument extends StatelessWidget {
  const DeskDocument({
    required this.child,
    this.radius = 16,
    this.glassLevel,
    super.key,
  });
  final Widget child;
  final double radius;
  final GlassLevel? glassLevel;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    if (glassLevel != null) {
      return DeskGlassPanel(
        level: glassLevel!,
        radius: radius,
        padding: EdgeInsets.zero,
        child: child,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: colors.paper,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// The surface and controls are siblings: GlassContainer deliberately disables
/// descendant refraction, so wrapping a control inside it would flatten its lens.
class DeskGlassPanel extends StatelessWidget {
  const DeskGlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.interactive = false,
    this.quiet = false,
    this.level = GlassLevel.panel,
    this.radius = 12,
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool interactive;
  final GlassLevel level;
  final double radius;

  /// Settings groups recede behind their controls without reducing text opacity
  /// or changing the independently sampled interactive lenses above them.
  final bool quiet;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final shape = LiquidRoundedSuperellipse(borderRadius: radius);
    final overlay = level == GlassLevel.overlay;
    final opaqueOverlay =
        overlay &&
        (colors.highContrast ||
            GlassAccessibilityData.of(context).reduceTransparency);
    final panel = Stack(
      clipBehavior: Clip.none,
      children: [
        if (level != GlassLevel.background)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _OutsideGlassShadow(
                  DeskMaterials.elevationShadow(
                    context,
                    elevation: quiet ? .6 : 1.2,
                  ),
                  shape,
                ),
              ),
            ),
          ),
        if (overlay)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: opaqueOverlay
                    ? ColoredBox(color: colors.paper.withValues(alpha: 1))
                    : BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 13, sigmaY: 13),
                        child: ColoredBox(
                          color: colors.paper.withValues(
                            alpha: colors.dark ? .34 : .48,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        if (!opaqueOverlay)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: GlassContainer.card(
                  shape: shape,
                  quality: GlassQuality.standard,
                  useOwnLayer: true,
                  settings: DeskMaterials.forLevel(context, level),
                  padding: EdgeInsets.zero,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape.copyWith(
                  side: BorderSide(
                    color: colors.highContrast
                        ? colors.line
                        : CupertinoColors.white.withValues(
                            alpha: colors.dark ? .09 : .55,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(padding: padding, child: child),
      ],
    );
    // Paint the moving edge independently. Crossing a panel must not rebuild
    // its controls, recreate its glass settings or relayout its text.
    return interactive
        ? DeskInteraction(color: colors.accent, shape: shape, child: panel)
        : panel;
  }
}

/// A translucent material must not receive a filled shadow inside its body.
class _OutsideGlassShadow extends CustomPainter {
  const _OutsideGlassShadow(this.shadows, this.shape);
  final List<BoxShadow> shadows;
  final LiquidRoundedSuperellipse shape;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || shadows.isEmpty) return;
    final bounds = Offset.zero & size;
    final body = shape.getOuterPath(bounds);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds.inflate(24))
      ..addPath(body, Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final shadow in shadows) {
      canvas.drawPath(
        shape.getOuterPath(
          bounds.shift(shadow.offset).inflate(shadow.spreadRadius),
        ),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OutsideGlassShadow old) =>
      old.shape != shape || !listEquals(old.shadows, shadows);
}

class DeskSection extends StatelessWidget {
  const DeskSection({
    required this.title,
    required this.child,
    this.subtitle,
    this.quiet = true,
    super.key,
  });
  final String title;
  final String? subtitle;
  final bool quiet;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: DeskGlassPanel(
        quiet: quiet,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: DeskTypography.section.copyWith(color: colors.ink),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                style: TextStyle(color: colors.secondary, fontSize: 12),
              ),
            ],
            SizedBox(height: quiet ? 8 : 16),
            child,
          ],
        ),
      ),
    );
  }
}

class DeskEmpty extends StatelessWidget {
  const DeskEmpty(
    this.title, {
    this.detail,
    this.action,
    this.icon = CupertinoIcons.doc_text,
    super.key,
  });
  final String title;
  final String? detail;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: colors.secondary, size: 35),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 9),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class NativeAvatar extends StatefulWidget {
  const NativeAvatar({
    required this.state,
    required this.name,
    required this.url,
    this.size = 30,
    super.key,
  });
  final AppState state;
  final String name, url;
  final double size;
  @override
  State<NativeAvatar> createState() => _NativeAvatarState();
}

class _NativeAvatarState extends State<NativeAvatar> {
  late Future<Uint8List>? image;
  int _revision = -1;
  @override
  void initState() {
    super.initState();
    _update();
  }

  void _update() {
    _revision = widget.state.accessRevision;
    image = widget.url.isEmpty
        ? null
        : widget.state.image(widget.url, kind: 'avatar');
  }

  @override
  void didUpdateWidget(NativeAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !identical(oldWidget.state, widget.state) ||
        _revision != widget.state.accessRevision) {
      _update();
    }
  }

  void _retry(Future<Uint8List> expected) {
    if (!mounted ||
        !identical(image, expected) ||
        _revision != widget.state.accessRevision) {
      return;
    }
    widget.state.evictImageFuture(
      widget.url,
      expected,
      revision: _revision,
      kind: 'avatar',
    );
    setState(_update);
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final fallback = Container(
      color: colors.accent.withValues(alpha: .12),
      alignment: Alignment.center,
      child: Text(
        widget.name.isEmpty ? '·' : widget.name.characters.first,
        style: TextStyle(
          color: colors.accent,
          fontSize: widget.size * .4,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final request = image;
    Widget retry() => Semantics(
      label: '重试头像',
      button: true,
      excludeSemantics: true,
      onTap: () => _retry(request!),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        pressedOpacity: 1,
        onPressed: () => _retry(request!),
        child: fallback,
      ),
    );
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipOval(
        child: request == null
            ? fallback
            : FutureBuilder<Uint8List>(
                key: ObjectKey(request),
                future: request,
                builder: (context, value) => value.hasData
                    ? Image.memory(
                        value.data!,
                        width: widget.size,
                        height: widget.size,
                        fit: BoxFit.cover,
                        gaplessPlayback: false,
                        errorBuilder: (_, error, stack) => retry(),
                      )
                    : value.hasError
                    ? retry()
                    : fallback,
              ),
      ),
    );
  }
}

class HoverRow extends StatefulWidget {
  const HoverRow({
    required this.child,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.focusColor,
    super.key,
  });
  final Widget child;
  final VoidCallback onTap;
  final bool selected, enabled;
  final Color? focusColor;
  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return MouseRegion(
      cursor: !widget.enabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: DeskInteraction(
        color: colors.accent,
        enabled: widget.enabled,
        child: CupertinoButton(
          pressedOpacity: 1,
          padding: EdgeInsets.zero,
          focusColor: widget.focusColor,
          onPressed: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration:
                MediaQuery.disableAnimationsOf(context) ||
                    GlassAccessibilityData.of(context).reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.selection
                  : hover && widget.enabled
                  ? colors.hover
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class DeskBackdrop extends CustomPainter {
  const DeskBackdrop({
    required this.dark,
    this.family = DeskThemeFamily.classic,
  });
  DeskBackdrop.themed(DeskColors colors)
    : dark = colors.dark,
      family = colors.family;
  final bool dark;
  final DeskThemeFamily family;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    // A static, restrained light falloff gives the window chrome a material
    // context. The opaque document surfaces and user's reader images retain
    // their own colors; no ticking, texture or additional backdrop sampling.
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, .46, 1],
          colors: DeskColors.forBrightness(
            dark ? Brightness.dark : Brightness.light,
            family: family,
          ).backdrop,
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(DeskBackdrop oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.family != family;
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String accept = '确定',
  bool destructive = false,
}) async =>
    await showCupertinoDialog<bool>(
      context: context,
      barrierColor: DeskColors(context).dark
          ? const Color(0x50000000)
          : const Color(0x28000000),
      builder: (_) => _DeskConfirmationDialog(
        title: title,
        message: message,
        accept: accept,
        destructive: destructive,
      ),
    ) ??
    false;

class DeskDialog extends StatelessWidget {
  const DeskDialog({
    required this.title,
    required this.content,
    required this.actions,
    this.icon,
    this.destructive = false,
    super.key,
  });

  final String title;
  final Widget content;
  final List<DeskDialogAction> actions;
  final IconData? icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final tone = destructive ? _dialogDanger(colors) : colors.accent;
    final insets = MediaQuery.viewInsetsOf(context);
    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Padding(
        padding: insets,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              child: DeskGlassPanel(
                level: GlassLevel.overlay,
                radius: 18,
                padding: EdgeInsets.zero,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (icon case final symbol?) ...[
                            ExcludeSemantics(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: tone.withValues(alpha: .13),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(symbol, color: tone, size: 17),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Semantics(
                              namesRoute: true,
                              header: true,
                              child: Text(
                                title,
                                style: DeskTypography.section.copyWith(
                                  color: colors.ink,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DefaultTextStyle(
                        style: DeskTypography.base.copyWith(
                          color: colors.secondary,
                          fontSize: 13,
                          height: 1.55,
                        ),
                        child: content,
                      ),
                      const SizedBox(height: 22),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 10,
                        runSpacing: 8,
                        children: actions,
                      ),
                    ],
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

Color _dialogDanger(DeskColors colors) =>
    colors.dark ? const Color(0xffffa5a0) : const Color(0xffa82a32);

class DeskDialogAction extends StatefulWidget {
  const DeskDialogAction(
    this.label, {
    required this.onPressed,
    this.isDefaultAction = false,
    this.isDestructiveAction = false,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isDefaultAction, isDestructiveAction, autofocus;
  final FocusNode? focusNode;

  @override
  State<DeskDialogAction> createState() => _DeskDialogActionState();
}

class _DeskDialogActionState extends State<DeskDialogAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final foreground = widget.isDestructiveAction
        ? _dialogDanger(colors)
        : widget.isDefaultAction
        ? colors.selectionInk
        : colors.ink;
    final emphasis = widget.isDestructiveAction || widget.isDefaultAction;
    final fill = foreground.withValues(
      alpha: _focused
          ? (colors.highContrast ? .38 : .26)
          : (emphasis ? .13 : .06),
    );
    return CupertinoButton(
      minimumSize: const Size(82, 36),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      borderRadius: BorderRadius.circular(9),
      color: fill,
      foregroundColor: foreground,
      focusColor: const Color(0x00000000),
      mouseCursor: SystemMouseCursors.click,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        if (mounted && focused != _focused) {
          setState(() => _focused = focused);
        }
      },
      onPressed: widget.onPressed,
      child: Text(
        widget.label,
        textAlign: TextAlign.center,
        style: DeskTypography.control.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: emphasis ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _DeskConfirmationDialog extends StatefulWidget {
  const _DeskConfirmationDialog({
    required this.title,
    required this.message,
    required this.accept,
    required this.destructive,
  });

  final String title, message, accept;
  final bool destructive;

  @override
  State<_DeskConfirmationDialog> createState() =>
      _DeskConfirmationDialogState();
}

class _DeskConfirmationDialogState extends State<_DeskConfirmationDialog> {
  final _cancelFocus = FocusNode(debugLabel: 'Confirmation cancel');
  final _acceptFocus = FocusNode(debugLabel: 'Confirmation accept');
  bool _finished = false;

  void _finish(bool accepted) {
    if (!mounted || _finished || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _finished = true;
    Navigator.of(context).pop(accepted);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final tab = key == LogicalKeyboardKey.tab;
    final escape = key == LogicalKeyboardKey.escape;
    final activate =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space;
    if (!tab && (!escape && !activate || keyboard.isShiftPressed)) {
      return KeyEventResult.ignored;
    }
    // A held opening/activation key must not confirm, traverse repeatedly, or
    // fall through to the covered editor. Only a fresh press performs an action.
    if (event is! KeyDownEvent || event.synthesized || _finished) {
      return KeyEventResult.handled;
    }
    if (tab) {
      // This dialog has exactly two actions; forward and backward traversal
      // both wrap to the other action without escaping the modal route.
      (_cancelFocus.hasFocus ? _acceptFocus : _cancelFocus).requestFocus();
    } else if (escape) {
      _finish(false);
    } else if (_cancelFocus.hasFocus || _acceptFocus.hasFocus) {
      _finish(_acceptFocus.hasFocus);
    }
    return KeyEventResult.handled;
  }

  DeskDialogAction _action({required bool accept}) {
    final isDefault = accept != widget.destructive;
    return DeskDialogAction(
      accept ? widget.accept : '取消',
      key: ValueKey(accept ? 'confirmation-accept' : 'confirmation-cancel'),
      focusNode: accept ? _acceptFocus : _cancelFocus,
      autofocus: isDefault,
      isDefaultAction: isDefault,
      isDestructiveAction: accept && widget.destructive,
      onPressed: () => _finish(accept),
    );
  }

  @override
  Widget build(BuildContext context) => Focus(
    skipTraversal: true,
    onKeyEvent: _key,
    child: DeskDialog(
      title: widget.title,
      content: Text(widget.message),
      icon: widget.destructive ? CupertinoIcons.exclamationmark_triangle : null,
      destructive: widget.destructive,
      actions: [_action(accept: false), _action(accept: true)],
    ),
  );

  @override
  void dispose() {
    _cancelFocus.dispose();
    _acceptFocus.dispose();
    super.dispose();
  }
}
