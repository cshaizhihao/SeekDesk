import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import 'desk_label_metrics.dart';
import 'glass_chrome.dart';

/// A compact control surface above the image, outside its transform layer.
/// The viewer supplies the dark Cupertino/Glass theme used by its backdrop.
class ImageViewerToolbar extends StatefulWidget {
  const ImageViewerToolbar({
    required this.label,
    required this.scale,
    required this.originalSize,
    required this.enabled,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
    required this.onOriginalSize,
    required this.onClose,
    super.key,
  });

  final String label;
  final double scale;
  final bool originalSize;
  final bool enabled;
  final VoidCallback onZoomOut, onZoomIn, onFit, onOriginalSize, onClose;

  static const zoomOutKey = ValueKey('image-viewer-zoom-out');
  static const zoomInKey = ValueKey('image-viewer-zoom-in');
  static const fitKey = ValueKey('image-viewer-fit');
  static const originalSizeKey = ValueKey('image-viewer-original');
  static const closeKey = ValueKey('image-viewer-close');

  static ({int percentage, bool canZoomOut, bool canZoomIn}) scalePresentation(
    double scale,
  ) {
    final currentScale = scale.isFinite ? scale.clamp(.5, 4.0) : 1.0;
    return (
      percentage: (currentScale * 100).round(),
      canZoomOut: currentScale > .50001,
      canZoomIn: currentScale < 3.99999,
    );
  }

  String get _title {
    final title = label.trim().replaceAll(RegExp(r'\s+'), ' ');
    return title.isEmpty || title.toLowerCase() == 'image' ? '图片预览' : title;
  }

  @override
  State<ImageViewerToolbar> createState() => _ImageViewerToolbarState();
}

class _ImageViewerToolbarState extends State<ImageViewerToolbar> {
  DeskLabelMetrics? _labelMetrics;
  ({Size fit, Size original})? _fixedMetrics;
  int? _systemFontsCallbackId;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(
      _scheduleFontMetricsRefresh,
    );
  }

  void _scheduleFontMetricsRefresh() {
    if (_systemFontsCallbackId != null) return;
    // Font notifications can arrive during build or layout. Coalesce them into
    // a transient callback, before the next frame's widget build.
    _systemFontsCallbackId = WidgetsBinding.instance.scheduleFrameCallback((_) {
      _systemFontsCallbackId = null;
      if (!mounted) return;
      setState(() => _fixedMetrics = null);
    });
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(
      _scheduleFontMetricsRefresh,
    );
    final callbackId = _systemFontsCallbackId;
    if (callbackId != null) {
      WidgetsBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final metrics = DeskLabelMetrics.of(context, style: DeskTypography.control);
    // Check on widget updates too: this SDK's MediaQuery equality compares the
    // legacy scale factor, which can hide changes in a nonlinear TextScaler.
    if (_labelMetrics == null || !_labelMetrics!.hasSameLayout(metrics)) {
      _fixedMetrics = null;
    }
    _labelMetrics = metrics;
    final presentation = ImageViewerToolbar.scalePresentation(widget.scale);
    final percentage = '${presentation.percentage}%';
    final basis = widget.originalSize ? '原尺寸' : '适合窗口';
    final measured = _fixedMetrics ??= (
      fit: metrics.measure('400%'),
      original: metrics.measure('原尺寸'),
    );
    final height = math.max(
      math.max(34.0, metrics.scaler.scale(12) * 1.25 + 16),
      math.max(measured.fit.height, measured.original.height) + 16,
    );
    final fitWidth = math.max(62.0, measured.fit.width + 22);
    final originalWidth = math.max(92.0, measured.original.width + 46);
    final zoomWidth = 64 + 8 + fitWidth;
    final zoomOut = DeskIcon(
      '缩小图片',
      CupertinoIcons.minus,
      widget.enabled && presentation.canZoomOut ? widget.onZoomOut : null,
      key: ImageViewerToolbar.zoomOutKey,
    );
    final fit = DeskButton(
      percentage,
      key: ImageViewerToolbar.fitKey,
      width: fitWidth,
      height: height,
      semanticLabel: '当前为$basis基准的 $percentage，点按适合窗口',
      onTap: widget.enabled ? widget.onFit : null,
    );
    final zoomIn = DeskIcon(
      '放大图片',
      CupertinoIcons.plus,
      widget.enabled && presentation.canZoomIn ? widget.onZoomIn : null,
      key: ImageViewerToolbar.zoomInKey,
    );
    final original = DeskButton(
      '原尺寸',
      key: ImageViewerToolbar.originalSizeKey,
      width: originalWidth,
      height: height,
      selected: widget.originalSize,
      icon: widget.originalSize
          ? CupertinoIcons.check_mark
          : CupertinoIcons.arrow_up_left_arrow_down_right,
      tint: widget.originalSize ? colors.selectionInk : null,
      semanticLabel: widget.originalSize ? '原尺寸，已选中' : '查看原尺寸',
      onTap: widget.enabled ? widget.onOriginalSize : null,
    );
    final close = DeskIcon(
      '关闭图片',
      CupertinoIcons.xmark,
      widget.onClose,
      key: ImageViewerToolbar.closeKey,
    );
    final title = Text(
      widget._title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DeskTypography.base.copyWith(
        color: colors.ink,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
    );

    return DeskGlassPanel(
      level: GlassLevel.overlay,
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(
        builder: (context, bounds) {
          // At large text sizes even the zoom group can exceed a narrow
          // viewport. Keep the percentage readable above its two controls.
          final zoom = zoomWidth <= bounds.maxWidth
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    zoomOut,
                    const SizedBox(width: 4),
                    fit,
                    const SizedBox(width: 4),
                    zoomIn,
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    fit,
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [zoomOut, const SizedBox(width: 4), zoomIn],
                    ),
                  ],
                );
          // Keep a meaningful title and reachable close action before switching
          // to a second row. Controls retain their readable size at large text.
          final wide = bounds.maxWidth >= zoomWidth + originalWidth + 32 + 160;
          if (wide) {
            return Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 16),
                zoom,
                const SizedBox(width: 10),
                original,
                const SizedBox(width: 10),
                close,
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 10),
                  close,
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [zoom, original],
              ),
            ],
          );
        },
      ),
    );
  }
}
