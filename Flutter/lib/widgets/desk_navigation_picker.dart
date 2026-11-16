// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/theme/glass_theme_helpers.dart';

import 'glass_chrome.dart';

/// Sidebar destinations sharing a single glass selection, without a track.
///
/// A destination outside this group is represented by [selectedIndex] == null.
/// The rows stay mounted and focusable when the selection disappears.
class DeskNavigationPicker extends StatefulWidget {
  const DeskNavigationPicker({
    required this.segments,
    required this.selectedIndex,
    required this.onSelected,
    this.onReselect,
    this.extent = 43,
    this.quality = GlassQuality.premium,
    super.key,
  }) : assert(segments.length > 0),
       assert(extent > 0 && extent < double.infinity),
       assert(
         selectedIndex == null ||
             (selectedIndex >= 0 && selectedIndex < segments.length),
       );

  final List<GlassSegment> segments;
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback? onReselect;
  final double extent;
  final GlassQuality quality;

  @override
  State<DeskNavigationPicker> createState() => _DeskNavigationPickerState();
}

class _DeskNavigationPickerState extends State<DeskNavigationPicker>
    with TickerProviderStateMixin {
  // These are the same public controllers and springs used by the package's
  // VelocitySpringBuilder / SpringBuilder. Owning them lets a null selection
  // or a live Reduce Motion change stop BOTH springs without remounting rows.
  late final SingleSpringController _position;
  late final SingleSpringController _thickness;
  late final Listenable _motion;
  final Set<int> _pressedPointers = {};
  bool _reduceMotion = false;
  double _thicknessTarget = 0;

  double get _target {
    final selected = widget.selectedIndex;
    if (selected == null || widget.segments.length == 1) return 0;
    return -1 + 2 * selected / (widget.segments.length - 1);
  }

  @override
  void initState() {
    super.initState();
    _position = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 350)),
      initialValue: _target,
    );
    _thickness = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 300)),
    );
    _motion = Listenable.merge([_position, _thickness]);
    _position.addListener(_updateThickness);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = GlassAccessibilityData.of(context).reduceMotion;
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      if (reduceMotion) _snap();
    }
  }

  @override
  void didUpdateWidget(DeskNavigationPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex == null ||
        oldWidget.selectedIndex == null ||
        widget.segments.length != oldWidget.segments.length ||
        _reduceMotion) {
      _snap();
    } else if (widget.selectedIndex != oldWidget.selectedIndex) {
      _position.animateTo(_target);
      _updateThickness();
    }
  }

  void _snap() {
    _pressedPointers.clear();
    _position.setValue(_target);
    _thicknessTarget = 0;
    _thickness.setValue(0);
  }

  void _updateThickness() {
    final moving = (_position.value - _target).abs() > 0.05;
    final target =
        !_reduceMotion &&
            widget.selectedIndex != null &&
            (_pressedPointers.isNotEmpty || moving)
        ? 1.0
        : 0.0;
    if (target == _thicknessTarget) return;
    _thicknessTarget = target;
    if (_reduceMotion || widget.selectedIndex == null) {
      _thickness.setValue(target);
    } else {
      _thickness.animateTo(target);
    }
  }

  void _releasePointer(PointerEvent event) {
    if (_pressedPointers.remove(event.pointer)) _updateThickness();
  }

  void _select(int index) {
    if (!widget.segments[index].enabled) return;
    if (index == widget.selectedIndex) {
      widget.onReselect?.call();
      return;
    }
    widget.onSelected(index);
  }

  @override
  void dispose() {
    _position.removeListener(_updateThickness);
    _position.dispose();
    _thickness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quality = GlassThemeHelpers.resolveQuality(
      context,
      widgetQuality: widget.quality,
    );
    final premium = quality == GlassQuality.premium;
    final dark = GlassTheme.brightnessOf(context) == Brightness.dark;
    final indicatorColor = dark
        ? const Color(0x304F6FA5)
        : CupertinoColors.white;
    final foreground = CupertinoDynamicColor.resolve(
      CupertinoColors.label,
      context,
    );

    final rows = Column(
      key: const ValueKey('navigation-rows'),
      children: [
        for (var index = 0; index < widget.segments.length; index++)
          SizedBox(
            key: ValueKey(widget.segments[index].id ?? index),
            height: widget.extent,
            width: double.infinity,
            child: _row(index, foreground),
          ),
      ],
    );

    return SizedBox(
      height: widget.extent * widget.segments.length,
      child: ListenableBuilder(
        listenable: _motion,
        child: rows,
        builder: (context, child) {
          Widget indicator({required bool background}) {
            if (widget.selectedIndex == null || (!background && !premium)) {
              return const SizedBox.shrink();
            }
            return ExcludeSemantics(
              child: IgnorePointer(
                // The official indicator returns Positioned.fill itself. Give
                // it a Stack parent below our hit-testing/semantics wrappers.
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedGlassIndicator(
                      velocity: _position.velocity,
                      itemCount: widget.segments.length,
                      alignment: Alignment(0, _position.value),
                      direction: Axis.vertical,
                      thickness: _thickness.value,
                      quality: quality,
                      indicatorColor: indicatorColor,
                      isBackgroundIndicator: false,
                      borderRadius: 12,
                      paintBackground: background,
                      paintGlass: !background || !premium,
                      pinchStrength: 0.4,
                      expansion: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 4,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // Match the package's premium painting order: solid pill, unchanged
          // labels, then the refractive glass lens. Keep all three slots stable.
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: indicator(background: true)),
              child!,
              Positioned.fill(child: indicator(background: false)),
            ],
          );
        },
      ),
    );
  }

  Widget _row(int index, Color foreground) {
    final segment = widget.segments[index];
    final selected = widget.selectedIndex == index;
    final color = segment.enabled
        ? foreground
        : foreground.withValues(alpha: 0.38);
    Widget content;
    if (segment.icon != null && segment.label != null) {
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          segment.icon!,
          const SizedBox(width: 8),
          Flexible(
            child: Text(segment.label!, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    } else {
      content =
          segment.icon ??
          Text(segment.label!, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    // Keep the name/selection and CupertinoButton's focus/tap semantics on one
    // node. CupertinoButton may otherwise introduce a separate action node.
    Widget row = MergeSemantics(
      child: Semantics(
        container: true,
        label: segment.semanticLabel ?? segment.label,
        button: true,
        enabled: segment.enabled,
        selected: selected,
        // CupertinoButton's gesture semantics may retain a tap action when
        // disabled. Keep only our named, disabled node in that state.
        child: ExcludeSemantics(
          excluding: !segment.enabled,
          child: Listener(
            onPointerDown: segment.enabled
                ? (event) {
                    _pressedPointers.add(event.pointer);
                    _updateThickness();
                  }
                : null,
            onPointerUp: _releasePointer,
            onPointerCancel: _releasePointer,
            child: _NavigationHover(
              enabled: segment.enabled,
              selected: selected,
              reduceMotion: _reduceMotion,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                borderRadius: BorderRadius.circular(12),
                pressedOpacity: 1,
                foregroundColor: color,
                onPressed: segment.enabled ? () => _select(index) : null,
                child: ExcludeSemantics(
                  child: DefaultTextStyle(
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                    child: IconTheme(
                      data: IconThemeData(color: color, size: 17),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (segment.tooltip != null) {
      row = Tooltip(
        message: segment.tooltip!,
        excludeFromSemantics: true,
        child: row,
      );
    }
    return row;
  }
}

/// Hover stays local to a row so crossing destinations does not rebuild the
/// shared glass lens or drive its position/press springs.
class _NavigationHover extends StatefulWidget {
  const _NavigationHover({
    required this.enabled,
    required this.selected,
    required this.reduceMotion,
    required this.child,
  });

  final bool enabled, selected, reduceMotion;
  final Widget child;

  @override
  State<_NavigationHover> createState() => _NavigationHoverState();
}

class _NavigationHoverState extends State<_NavigationHover> {
  bool _hovered = false;

  @override
  void didUpdateWidget(_NavigationHover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _hovered = false;
  }

  void _hover(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.enabled && !widget.selected && _hovered;
    return MouseRegion(
      onEnter: widget.enabled ? (_) => _hover(true) : null,
      onExit: (_) => _hover(false),
      child: AnimatedContainer(
        // The selected row belongs entirely to the official glass indicator;
        // remove this tint immediately when selection takes over.
        duration: widget.reduceMotion || widget.selected || !widget.enabled
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: highlighted
              ? DeskColors(context).hover
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(12),
        ),
        child: widget.child,
      ),
    );
  }
}
