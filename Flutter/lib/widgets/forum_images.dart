import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/native_client.dart';
import '../core/image_viewer_geometry.dart';
import '../state/app_state.dart';
import 'composer_image_sizing_controller.dart';
import 'composer_sizing_image.dart';
import 'glass_chrome.dart';
import 'native_image_viewer.dart';
import 'reader_content_layout.dart';

class NativeForumImage extends StatefulWidget {
  const NativeForumImage({
    required this.state,
    required this.url,
    this.size = const {},
    this.sticker = false,
    this.reportKind,
    this.draftSize,
    this.label = '',
    super.key,
  });
  final AppState state;
  final String url;
  final JsonMap size;
  final bool sticker;
  final String? reportKind;
  final DraftImageSize? draftSize;
  final String label;
  @override
  State<NativeForumImage> createState() => _NativeForumImageState();
}

class _NativeForumImageState extends State<NativeForumImage> {
  late Future<Uint8List> future;
  late int revision;
  Object _heroTag = Object();
  final _sourceKey = GlobalKey();
  bool _viewerOpen = false;
  Size? _renderedSize;
  ({Size size, Size original})? _sourceGeometry, _adoptedGeometry;
  bool _sourceHasMetadata = false;
  ReaderContentLayoutController? _geometryOwner;
  ScrollPosition? _geometryPosition;
  VoidCallback? _cancelGeometryWait;
  int _geometryGeneration = 0;

  void _stopGeometryWait() {
    _geometryGeneration++;
    _cancelGeometryWait?.call();
    _cancelGeometryWait = null;
    _geometryOwner = null;
    _geometryPosition = null;
  }

  void _waitForGeometry(
    ReaderContentLayoutController owner,
    ScrollPosition position,
  ) {
    if (identical(_geometryOwner, owner) &&
        identical(_geometryPosition, position)) {
      return;
    }
    _stopGeometryWait();
    _geometryOwner = owner;
    _geometryPosition = position;
    final generation = _geometryGeneration;
    final request = future;
    var queued = false;
    void changed() {
      if (position.isScrollingNotifier.value || queued) return;
      queued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _geometryGeneration) return;
        queued = false;
        if (!identical(request, future) ||
            revision != widget.state.accessRevision ||
            !identical(owner.scrollPosition, position)) {
          _stopGeometryWait();
          return;
        }
        if (position.isScrollingNotifier.value) return;
        setState(() {});
      });
      WidgetsBinding.instance.scheduleFrame();
    }

    position.isScrollingNotifier.addListener(changed);
    _cancelGeometryWait = () =>
        position.isScrollingNotifier.removeListener(changed);
  }

  ({Size size, Size original}) _geometry(
    BuildContext context,
    JsonMap natural,
  ) {
    final candidate = (
      size: Size(
        numberValue(natural['width'] ?? widget.size['width']),
        numberValue(natural['height'] ?? widget.size['height']),
      ),
      original: Size(
        numberValue(natural['originalWidth']),
        numberValue(natural['originalHeight']),
      ),
    );
    final hasMetadata = ImageViewerGeometry.validSize(
      Size(numberValue(natural['width']), numberValue(natural['height'])),
    );
    if (hasMetadata ||
        !_sourceHasMetadata && ImageViewerGeometry.validSize(candidate.size) ||
        _sourceGeometry == null) {
      _sourceGeometry = candidate;
    }
    _sourceHasMetadata = _sourceHasMetadata || hasMetadata;
    final next = _sourceGeometry!;
    final owner = context
        .dependOnInheritedWidgetOfExactType<ReaderContentLayoutScope>()
        ?.controller;
    final position = owner?.scrollPosition;
    if (_adoptedGeometry != null &&
        _adoptedGeometry != next &&
        position != null &&
        position.isScrollingNotifier.value) {
      _waitForGeometry(owner!, position);
      return _adoptedGeometry!;
    }
    _stopGeometryWait();
    return _adoptedGeometry = next;
  }

  Rect? get _sourceRect {
    final render = _sourceKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  Future<void> _open(Uint8List thumbnail) async {
    if (_viewerOpen || revision != widget.state.accessRevision) return;
    _viewerOpen = true;
    final tag = _heroTag, source = _sourceRect;
    try {
      await showNativeImageViewer(
        context,
        state: widget.state,
        url: widget.url,
        thumbnail: thumbnail,
        label: widget.label,
        heroTag: tag,
        canReturnToSource: () =>
            mounted &&
            identical(tag, _heroTag) &&
            revision == widget.state.accessRevision &&
            source != null &&
            _sourceRect == source,
      );
    } finally {
      _viewerOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    future = widget.state.image(widget.url);
  }

  @override
  void didUpdateWidget(NativeForumImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.state != widget.state ||
        revision != widget.state.accessRevision) {
      _stopGeometryWait();
      revision = widget.state.accessRevision;
      _heroTag = Object();
      _renderedSize = null;
      _sourceGeometry = null;
      _adoptedGeometry = null;
      _sourceHasMetadata = false;
      future = widget.state.image(widget.url);
    }
  }

  void _retry(Future<Uint8List> expected) {
    if (!mounted ||
        !identical(future, expected) ||
        revision != widget.state.accessRevision) {
      return;
    }
    _stopGeometryWait();
    widget.state.evictImageFuture(widget.url, expected, revision: revision);
    final next = widget.state.image(widget.url);
    setState(() {
      future = next;
    });
  }

  Widget _failure(DeskColors colors, Future<Uint8List> expected) =>
      GestureDetector(
        onTap: () => _retry(expected),
        child: ColoredBox(
          color: colors.well,
          child: Center(
            child: Text(
              '图片加载失败，点按重试',
              style: TextStyle(color: colors.secondary, fontSize: 12),
            ),
          ),
        ),
      );

  @override
  void deactivate() {
    _stopGeometryWait();
    super.deactivate();
  }

  @override
  void dispose() {
    _stopGeometryWait();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final available = bounds.maxWidth.isFinite ? bounds.maxWidth : 640.0;
        final request = future;
        return FutureBuilder<Uint8List>(
          key: ObjectKey(request),
          future: request,
          builder: (context, result) {
            final natural = widget.state.imageDimensions(widget.url);
            final geometry = _geometry(context, natural);
            final width = geometry.size.width, height = geometry.size.height;
            final validSize =
                width.isFinite && height.isFinite && width > 0 && height > 0;
            final scale = widget.reportKind == null
                ? 100.0
                : numberValue(
                    widget.state.domain(
                      'settings',
                    )['workspace.${widget.reportKind}ReportScale'],
                    100,
                  );
            final rendered = widget.draftSize != null
                ? ComposerImagePreviewGeometry.size(
                    selection: widget.draftSize!,
                    available: available,
                    decoded: Size(width, height),
                    original: geometry.original,
                  )
                : validSize
                ? ReportImageGeometry.size(
                    Size(width, height),
                    available: available,
                    kind: widget.reportKind,
                    percentage: scale,
                    sticker: widget.sticker,
                    viewportHeight:
                        ReaderContentLayoutScope.maybeViewportHeightOf(
                          context,
                        ) ??
                        MediaQuery.sizeOf(context).height,
                  )
                : Size(
                    math.min(available, widget.sticker ? 90 : 640),
                    widget.sticker ? 64 : 120,
                  );
            if (_renderedSize != null && _renderedSize != rendered) {
              // The old image box is still laid out here. Capture before this
              // leaf replaces its placeholder or adopts changed dimensions.
              ReaderContentLayoutScope.prepareChange(context);
            }
            _renderedSize = rendered;
            Widget content;
            if (result.hasError) {
              content = _failure(colors, request);
            } else if (!result.hasData) {
              content = ColoredBox(
                color: colors.well,
                child: const Center(child: CupertinoActivityIndicator()),
              );
            } else {
              content = GestureDetector(
                onTap: () => _open(result.data!),
                child: Hero(
                  key: _sourceKey,
                  tag: _heroTag,
                  transitionOnUserGestures: true,
                  child: Image.memory(
                    result.data!,
                    width: rendered.width,
                    height: rendered.height,
                    fit: BoxFit.contain,
                    gaplessPlayback: false,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, error, stack) =>
                        _failure(colors, request),
                  ),
                ),
              );
            }
            final sized = SizedBox(
              width: rendered.width,
              height: rendered.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.sticker ? 0 : 9),
                child: content,
              ),
            );
            return ReaderContentGeometry(
              unresolved: !validSize || _adoptedGeometry != _sourceGeometry,
              child: Align(
                alignment: Alignment.centerLeft,
                child: rendered.width > available
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: sized,
                      )
                    : sized,
              ),
            );
          },
        );
      },
    );
  }
}

/// Placeholder and decoded content share exactly the same aspect-ratio policy.
class ReportImageGeometry {
  static Size size(
    Size natural, {
    required double available,
    String? kind,
    double percentage = 100,
    bool sticker = false,
    double viewportHeight = 720,
  }) {
    if (!natural.width.isFinite ||
        !natural.height.isFinite ||
        natural.isEmpty) {
      return Size.zero;
    }
    final width = available.isFinite ? math.max(1.0, available) : 640.0;
    final percent = percentage.isFinite
        ? percentage.clamp(kind == 'nq' ? 25.0 : 50.0, 200.0) / 100
        : 1.0;
    double factor;
    if (sticker) {
      factor = math.min(
        1.0,
        math.min(math.min(90.0, width) / natural.width, 90 / natural.height),
      );
    } else if (kind == 'nq') {
      factor = math.min(640.0, width) / natural.width * percent;
    } else if (kind == 'tq') {
      final viewport = viewportHeight.isFinite && viewportHeight > 0
          ? viewportHeight
          : 720.0;
      final budget = (viewport * .55).clamp(160.0, 440.0);
      final fit = math.min(
        1.0,
        math.min(width / natural.width, budget / natural.height),
      );
      // Keep the accepted 1.75 baseline while making its 100% fit usable in
      // short reading panes. Explicit user zoom scales that fitted baseline.
      factor =
          math.min(
            fit * 1.75,
            math.min(width / natural.width, viewport / natural.height),
          ) *
          percent;
    } else {
      factor = math.min(1.0, math.min(900.0, width) / natural.width);
    }
    return Size(natural.width * factor, natural.height * factor);
  }
}
