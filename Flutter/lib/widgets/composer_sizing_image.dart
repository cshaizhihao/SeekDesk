import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import 'composer_image_sizing_controller.dart';
import 'glass_chrome.dart';

/// Only image leaves depend on this scope. Updating a selection must not rebuild
/// MarkdownDocument or parse the surrounding document again.
class ComposerImageSizingScope extends InheritedWidget {
  const ComposerImageSizingScope({
    required this.controller,
    required this.enabled,
    required this.accessRevision,
    required super.child,
    super.key,
  });

  final ComposerImageSizingController? controller;
  final bool enabled;
  final int accessRevision;

  static ComposerImageSizingScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerImageSizingScope>();

  @override
  bool updateShouldNotify(ComposerImageSizingScope oldWidget) =>
      controller != oldWidget.controller ||
      enabled != oldWidget.enabled ||
      accessRevision != oldWidget.accessRevision;
}

/// Native image metadata determines the source pixels; previewWidth is a saved
/// logical width, never the current window width or the screen's pixel ratio.
class ComposerImagePreviewGeometry {
  static Size size({
    required DraftImageSize selection,
    required double available,
    required Size decoded,
    Size? original,
  }) {
    final source = original != null && _valid(original) ? original : decoded;
    final basis = selection.previewWidth.isFinite && selection.previewWidth > 0
        ? selection.previewWidth.clamp(1.0, 1080.0)
        : available.clamp(1.0, 1080.0);
    final ratio = selection.ratio.isFinite
        ? selection.ratio.clamp(.1, 1.0)
        : 1.0;
    var width = math.max(
      1.0,
      (math.min(
                original != null && _valid(original) ? original.width : basis,
                basis,
              ) *
              ratio)
          .roundToDouble(),
    );
    // Match the native pixel budget when true original dimensions are known.
    if (original != null && _valid(original)) {
      width = math.min(
        width,
        original.width * math.sqrt(24000000 / original.width / original.height),
      );
    }
    width = math.min(width, math.max(0.0, available));
    return Size(
      width,
      _valid(source) ? width * source.height / source.width : 120,
    );
  }

  static bool _valid(Size size) =>
      size.width.isFinite && size.height.isFinite && !size.isEmpty;
}

/// The image builder remains owned by the forum renderer. This wrapper adds
/// controls only for canonical URLs accepted by the native Markdown scanner.
class ComposerSizingImage extends StatefulWidget {
  const ComposerSizingImage({
    required this.state,
    required this.url,
    required this.imageBuilder,
    this.label = '',
    this.isSticker = false,
    super.key,
  });

  final AppState state;
  final String url, label;

  /// Parsed from the original description, before Markdown flattens its alt.
  final bool isSticker;
  final Widget Function(String url, DraftImageSize? selection) imageBuilder;

  @override
  State<ComposerSizingImage> createState() => _ComposerSizingImageState();
}

class _ComposerSizingImageState extends State<ComposerSizingImage> {
  ComposerImageSizingScope? scope;
  bool focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    scope = ComposerImageSizingScope.maybeOf(context);
  }

  String? _supportedURL(ComposerImageSizingController controller) {
    if (widget.isSticker) return null;
    final raw = Uri.tryParse(widget.url);
    if (raw == null) return null;
    final canonical = Uri.parse('https://www.nodeseek.com/').resolveUri(raw);
    if (canonical.scheme != 'https' ||
        canonical.host.isEmpty ||
        canonical.userInfo.isNotEmpty) {
      return null;
    }
    final url = canonical.toString();
    return controller.imageURLs.contains(url) ? url : null;
  }

  bool _canAdjust(ComposerImageSizingController controller, String url) =>
      mounted &&
      identical(scope?.controller, controller) &&
      scope!.enabled &&
      scope!.accessRevision == widget.state.accessRevision &&
      !controller.busy &&
      _supportedURL(controller) == url;

  void _stage(
    ComposerImageSizingController controller,
    String url,
    double ratio,
    double width, {
    bool commit = false,
  }) {
    if (!_canAdjust(controller, url)) return;
    if (!controller.stage(url, ratio, width.clamp(1.0, 1080.0))) return;
    if (commit) unawaited(controller.flush());
  }

  @override
  Widget build(BuildContext context) {
    final controller = scope?.controller;
    if (controller == null) return widget.imageBuilder(widget.url, null);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, widget.state]),
      builder: (context, _) {
        final url = _supportedURL(controller);
        if (url == null) return widget.imageBuilder(widget.url, null);
        final selection = controller.sizeFor(url);
        final enabled = _canAdjust(controller, url);
        return LayoutBuilder(
          builder: (context, bounds) {
            final available = bounds.maxWidth.isFinite
                ? math.max(0.0, bounds.maxWidth)
                : 640.0;
            return SizedBox(
              width: available,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  widget.imageBuilder(
                    url,
                    selection.ratio < 1 ? selection : null,
                  ),
                  if (available > 0) ...[
                    const SizedBox(height: 5),
                    _controls(
                      context,
                      controller,
                      url,
                      selection,
                      available,
                      enabled,
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _controls(
    BuildContext context,
    ComposerImageSizingController controller,
    String url,
    DraftImageSize selection,
    double available,
    bool enabled,
  ) {
    final colors = DeskColors(context);
    final ratio = selection.ratio.clamp(.1, 1.0);
    final percent = (ratio * 100).round();
    final label = widget.label.trim().isEmpty
        ? '图片发布大小'
        : '${widget.label}发布大小';
    final barWidth = math.min(360.0, available);
    final innerWidth = math.max(0.0, barWidth - 16);
    final increased = math.min(1.0, (percent + 1) / 100);
    final decreased = math.max(.1, (percent - 1) / 100);
    void commit(double value) =>
        _stage(controller, url, value, available, commit: true);

    return TextFieldTapRegion(
      child: SizedBox(
        width: barWidth,
        child: DeskGlassPanel(
          padding: EdgeInsets.symmetric(
            horizontal: math.min(8.0, barWidth / 2),
            vertical: 3,
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: math.min(63.0, innerWidth),
                child: Text(
                  '发布大小',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
              ),
              SizedBox(
                width: math.min(146.0, innerWidth),
                child: Focus(
                  // A short persistence request must not take keyboard focus
                  // away. Disabled controls leave traversal but retain focus.
                  skipTraversal: !enabled,
                  descendantsAreFocusable: false,
                  onFocusChange: (value) {
                    if (mounted) setState(() => focused = value);
                  },
                  onKeyEvent: (_, event) {
                    if (!enabled ||
                        event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final value = switch (event.logicalKey) {
                      LogicalKeyboardKey.arrowLeft ||
                      LogicalKeyboardKey.arrowDown => decreased,
                      LogicalKeyboardKey.arrowRight ||
                      LogicalKeyboardKey.arrowUp => increased,
                      LogicalKeyboardKey.home => .1,
                      LogicalKeyboardKey.end => 1.0,
                      _ => null,
                    };
                    if (value == null) return KeyEventResult.ignored;
                    commit(value);
                    return KeyEventResult.handled;
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: focused && enabled
                            ? colors.accent
                            : const Color(0x00000000),
                      ),
                    ),
                    child: Semantics(
                      container: true,
                      slider: true,
                      enabled: enabled,
                      label: label,
                      value: '$percent%',
                      increasedValue: enabled && percent < 100
                          ? '${percent + 1}%'
                          : null,
                      decreasedValue: enabled && percent > 10
                          ? '${percent - 1}%'
                          : null,
                      onIncrease: enabled && percent < 100
                          ? () => commit(increased)
                          : null,
                      onDecrease: enabled && percent > 10
                          ? () => commit(decreased)
                          : null,
                      excludeSemantics: true,
                      child: CupertinoSlider(
                        value: ratio,
                        min: .1,
                        max: 1,
                        divisions: 90,
                        activeColor: colors.accent,
                        onChanged: enabled
                            ? (value) =>
                                  _stage(controller, url, value, available)
                            : null,
                        onChangeEnd: enabled
                            ? (_) {
                                if (_canAdjust(controller, url)) {
                                  unawaited(controller.flush());
                                }
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: math.min(35.0, innerWidth),
                child: Text(
                  '$percent%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.ink, fontSize: 12),
                ),
              ),
              SizedBox(
                width: math.min(58.0, innerWidth),
                child: Semantics(
                  label: '恢复原图，100%',
                  button: true,
                  enabled: enabled && percent < 100,
                  onTap: enabled && percent < 100 ? () => commit(1) : null,
                  excludeSemantics: true,
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 28),
                    onPressed: enabled && percent < 100
                        ? () => commit(1)
                        : null,
                    child: Text(
                      '原图',
                      style: TextStyle(
                        fontSize: 12,
                        color: enabled && percent < 100
                            ? colors.accent
                            : colors.secondary,
                      ),
                    ),
                  ),
                ),
              ),
              if (controller.busy) const CupertinoActivityIndicator(radius: 6),
              if (controller.hasPendingChanges && controller.feedback != null)
                SizedBox(
                  width: math.min(80.0, innerWidth),
                  child: Semantics(
                    hint: controller.feedback,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 28),
                      onPressed: enabled
                          ? () {
                              if (_canAdjust(controller, url)) {
                                unawaited(controller.flush());
                              }
                            }
                          : null,
                      child: Text(
                        '重试保存',
                        style: TextStyle(
                          fontSize: 12,
                          color: enabled ? colors.accent : colors.secondary,
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
}
