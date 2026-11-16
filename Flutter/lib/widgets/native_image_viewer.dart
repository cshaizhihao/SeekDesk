import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../core/image_viewer_geometry.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';
import 'image_viewer_toolbar.dart';

/// The route owns modal deferral until its reverse transition has finished.
Future<void> showNativeImageViewer(
  BuildContext context, {
  required AppState state,
  required String url,
  required Uint8List thumbnail,
  String label = '',
  Object? heroTag,
  bool Function()? canReturnToSource,
}) async {
  final reducedMotion =
      MediaQuery.disableAnimationsOf(context) ||
      GlassAccessibilityData.of(context).reduceMotion;
  final route = PageRouteBuilder<void>(
    opaque: false,
    allowSnapshotting: false,
    requestFocus: true,
    barrierDismissible: false,
    barrierLabel: '图片预览',
    transitionDuration: Duration(milliseconds: reducedMotion ? 100 : 220),
    reverseTransitionDuration: Duration(
      milliseconds: reducedMotion ? 100 : 180,
    ),
    pageBuilder: (context, animation, secondary) => NativeImageViewer(
      state: state,
      url: url,
      thumbnail: thumbnail,
      label: label,
      heroTag: heroTag,
      canReturnToSource: canReturnToSource,
    ),
    transitionsBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  final release = state.deferWatchPopup();
  try {
    Navigator.of(context).push(route);
    await route.completed;
  } finally {
    release();
  }
}

class NativeImageViewer extends StatefulWidget {
  const NativeImageViewer({
    required this.state,
    required this.url,
    required this.thumbnail,
    this.heroTag,
    this.label = '',
    this.canReturnToSource,
    super.key,
  });
  final AppState state;
  final String url;
  final Uint8List thumbnail;
  final Object? heroTag;
  final String label;
  final bool Function()? canReturnToSource;
  @override
  State<NativeImageViewer> createState() => _NativeImageViewerState();
}

/// One viewer source owns one reference to the shared original. Retiring a
/// source must capture its own state/URL/future before a widget adopts another.
class _OriginalImageLease {
  _OriginalImageLease(this.state, this.url) : revision = state.accessRevision {
    final viewers = _viewers[state] ??= {};
    viewers[key] = (viewers[key] ?? 0) + 1;
    future = state.image(url, kind: 'original');
  }

  static final Expando<Map<String, int>> _viewers = Expando();
  final AppState state;
  final String url;
  final int revision;
  late Future<Uint8List> future;
  bool _retired = false;
  String get key => '$revision:$url';
  bool get current => !_retired && state.accessRevision == revision;
  bool get _canRelease =>
      state.accessRevision == revision && (_viewers[state]?[key] ?? 0) == 0;

  void retire() {
    if (_retired) return;
    _retired = true;
    final viewers = _viewers[state]!;
    final count = (viewers[key] ?? 1) - 1;
    if (count == 0) {
      viewers.remove(key);
    } else {
      viewers[key] = count;
    }
    if (_canRelease) state.releaseImage(url, kind: 'original');
    future.then(
      (bytes) {
        if (_canRelease) {
          MemoryImage(bytes).evict();
          state.releaseImage(url, kind: 'original');
        }
      },
      onError: (Object _) {
        // Native decoding can retain an original before lifetime validation.
        if (_canRelease) state.releaseImage(url, kind: 'original');
      },
    );
  }
}

class _NativeImageViewerState extends State<NativeImageViewer>
    with SingleTickerProviderStateMixin {
  late _OriginalImageLease _lease;
  final _transform = TransformationController();
  // Keep exact image geometry independent from the toolbar's visible state.
  final _toolbarPresentation = ValueNotifier(
    ImageViewerToolbar.scalePresentation(1),
  );
  final _focus = FocusNode(debugLabel: 'Image viewer');
  late final AnimationController _motion;
  Matrix4Tween? _motionTween;
  Matrix4? _pendingMatrix;
  Matrix4 _gestureStart = Matrix4.identity();
  bool _gestureActive = false;
  double _gestureScaleBase = 1, _lastGestureScale = 1;
  Offset _lastGestureFocal = Offset.zero;
  Offset _gestureAnchor = Offset.zero, _doubleTapPosition = Offset.zero;
  Size _viewport = Size.zero, _natural = const Size(640, 480);
  Size? _thumbnailSize, _decodedOriginal, _knownNatural;
  int _naturalRank = 0;
  Rect _imageRect = Rect.zero;
  ImageStream? _dimensionStream;
  ImageStreamListener? _dimensionListener;
  ImageStream? _originalDimensionStream;
  ImageStreamListener? _originalDimensionListener;
  Future<Uint8List>? _decodeFailed;
  bool _invalidated = false, _closing = false, _originalSize = false;
  bool _manual = false, _heroAllowed = true;

  bool get _officeCovered {
    final extensions = widget.state.domain('extensions');
    return jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] == true;
  }

  bool get _ownRoute => mounted && ModalRoute.of(context)?.isCurrent == true;
  bool get _canAct =>
      _ownRoute && !_closing && !_officeCovered && _lease.current;
  Matrix4 get _effectiveMatrix => _pendingMatrix ?? _transform.value;
  double get _scale => ImageViewerGeometry.scaleOf(_effectiveMatrix);
  double get _buttonScale => _motion.isAnimating && _motionTween?.end != null
      ? ImageViewerGeometry.scaleOf(_motionTween!.end!)
      : _scale;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_updateToolbarPresentation);
    _motion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 160),
        )..addListener(() {
          final tween = _motionTween;
          if (tween != null) {
            _transform.value = tween.transform(
              Curves.easeOutCubic.transform(_motion.value),
            );
          }
        });
    _attach();
  }

  void _updateToolbarPresentation() {
    _toolbarPresentation.value = ImageViewerToolbar.scalePresentation(
      ImageViewerGeometry.scaleOf(_transform.value),
    );
  }

  void _attach() {
    _lease = _OriginalImageLease(widget.state, widget.url);
    _invalidated = false;
    _closing = false;
    _originalSize = false;
    _manual = false;
    _heroAllowed = true;
    _gestureActive = false;
    _decodeFailed = null;
    _thumbnailSize = null;
    _decodedOriginal = null;
    _knownNatural = null;
    _naturalRank = 0;
    _natural = const Size(640, 480);
    _viewport = Size.zero;
    _imageRect = Rect.zero;
    _pendingMatrix = null;
    _motion.stop();
    _transform.value = Matrix4.identity();
    widget.state.addListener(_accessChanged);
    _trackOriginalDimensions(_lease, _lease.future);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_dimensionStream == null && _thumbnailSize == null && _lease.current) {
      _readThumbnailDimensions();
    }
  }

  void _stopOriginalDimensionRead() {
    final listener = _originalDimensionListener;
    if (listener != null) _originalDimensionStream?.removeListener(listener);
    _originalDimensionStream = null;
    _originalDimensionListener = null;
  }

  void _trackOriginalDimensions(
    _OriginalImageLease owner,
    Future<Uint8List> request,
  ) {
    request.then((bytes) {
      if (!mounted ||
          !identical(owner, _lease) ||
          !owner.current ||
          !identical(owner.future, request)) {
        return;
      }
      final metadata = owner.state.imageDimensions(owner.url, kind: 'original');
      final thumb = owner.state.imageDimensions(owner.url);
      // Cache may be evicted between this completion and the next build.
      _naturalSize(metadata, thumb);
      if (ImageViewerGeometry.validSize(_size(metadata, 'width', 'height')) ||
          ImageViewerGeometry.validSize(
            _size(thumb, 'originalWidth', 'originalHeight'),
          )) {
        return;
      }
      _stopOriginalDimensionRead();
      final stream = MemoryImage(bytes).resolve(ImageConfiguration.empty);
      _originalDimensionStream = stream;
      final listener = ImageStreamListener(
        (info, synchronous) {
          final size = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          info.dispose();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                !identical(owner, _lease) ||
                !owner.current ||
                !identical(owner.future, request)) {
              return;
            }
            setState(() => _decodedOriginal = size);
            if (identical(_originalDimensionStream, stream)) {
              _stopOriginalDimensionRead();
            }
          });
        },
        onError: (Object error, StackTrace? stack) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (identical(_originalDimensionStream, stream)) {
              _stopOriginalDimensionRead();
            }
          });
        },
      );
      _originalDimensionListener = listener;
      stream.addListener(listener);
    }, onError: (Object error) {});
  }

  Size _naturalSize(JsonMap original, JsonMap thumbnail) {
    final candidates = <(Size?, int)>[
      (_size(original, 'originalWidth', 'originalHeight'), 5),
      (_size(thumbnail, 'originalWidth', 'originalHeight'), 4),
      (_size(original, 'width', 'height'), 3),
      (_decodedOriginal, 3),
      (_size(thumbnail, 'width', 'height'), 2),
      (_thumbnailSize, 1),
    ];
    for (final (size, rank) in candidates) {
      if (ImageViewerGeometry.validSize(size)) {
        if (rank >= _naturalRank) {
          _knownNatural = size;
          _naturalRank = rank;
        }
        break;
      }
    }
    return _knownNatural ?? const Size(640, 480);
  }

  void _stopDimensionRead() {
    final listener = _dimensionListener;
    if (listener != null) _dimensionStream?.removeListener(listener);
    _dimensionListener = null;
    _dimensionStream = null;
  }

  void _readThumbnailDimensions() {
    _stopDimensionRead();
    final owner = _lease;
    final stream = MemoryImage(widget.thumbnail)
        .resolve(ImageConfiguration.empty);
    _dimensionStream = stream;
    final listener = ImageStreamListener(
      (info, synchronous) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
        // Even a cached codec can complete synchronously during a build. Its
        // dimensions join the next frame without rebuilding an unrelated route.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(_lease, owner) || !owner.current) return;
          if (_thumbnailSize != size) setState(() => _thumbnailSize = size);
          if (identical(_dimensionStream, stream)) _stopDimensionRead();
        });
      },
      onError: (Object error, StackTrace? stack) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (identical(_dimensionStream, stream)) _stopDimensionRead();
        });
      },
    );
    _dimensionListener = listener;
    stream.addListener(listener);
  }

  void _accessChanged() {
    if (!mounted || _invalidated || _lease.current) return;
    _motion.stop();
    _stopDimensionRead();
    _stopOriginalDimensionRead();
    _lease.retire();
    setState(() => _invalidated = true);
  }

  @override
  void didUpdateWidget(NativeImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        oldWidget.url != widget.url) {
      oldWidget.state.removeListener(_accessChanged);
      _stopDimensionRead();
      _stopOriginalDimensionRead();
      _lease.retire();
      _attach();
      _readThumbnailDimensions();
    } else {
      _accessChanged();
    }
  }

  void _retry(_OriginalImageLease owner, Future<Uint8List> expected) {
    if (!_canAct ||
        !identical(owner, _lease) ||
        !identical(owner.future, expected)) {
      return;
    }
    owner.state.evictImageFuture(
      owner.url,
      expected,
      revision: owner.revision,
      kind: 'original',
    );
    final next = owner.state.image(owner.url, kind: 'original');
    setState(() {
      _decodeFailed = null;
      owner.future = next;
    });
    _trackOriginalDimensions(owner, next);
  }

  void _dismiss() {
    if (!_ownRoute ||
        _closing ||
        _officeCovered ||
        !Navigator.of(context).canPop()) {
      return;
    }
    _motion.stop();
    setState(() {
      _closing = true;
      if (widget.canReturnToSource?.call() == false) _heroAllowed = false;
    });
    // HeroController must see the rebuilt HeroMode before collecting a pop
    // flight. Keep the lease alive until route disposal, including that flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_ownRoute || _officeCovered || !Navigator.of(context).canPop()) {
        setState(() => _closing = false);
        return;
      }
      Navigator.of(context).pop();
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_ownRoute || _officeCovered) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final plain =
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    final command =
        keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    if ((event.logicalKey == LogicalKeyboardKey.escape && plain) ||
        (event.logicalKey == LogicalKeyboardKey.keyW && command)) {
      if (!Navigator.of(context).canPop()) return KeyEventResult.ignored;
      _dismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Size _size(JsonMap metadata, String width, String height) =>
      Size(numberValue(metadata[width]), numberValue(metadata[height]));

  void _layoutImage(Size viewport, Size natural) {
    final rect = ImageViewerGeometry.centeredImageRect(
      _originalSize ? natural : ImageViewerGeometry.fitSize(natural, viewport),
      viewport,
    );
    _natural = natural;
    if (_viewport == viewport && _imageRect == rect) return;
    _motion.stop();
    if (_viewport != Size.zero && _viewport != viewport) _heroAllowed = false;
    final next = !_manual && !_originalSize
        ? ImageViewerGeometry.clampTransform(
            Matrix4.identity(),
            imageRect: rect,
            viewport: viewport,
          )
        : ImageViewerGeometry.rebaseTransform(
            _effectiveMatrix,
            oldImageRect: _imageRect,
            oldViewport: _viewport,
            newImageRect: rect,
            newViewport: viewport,
          );
    if (_gestureActive) {
      _gestureStart = next.clone();
      _gestureAnchor = _lastGestureFocal;
      _gestureScaleBase = _lastGestureScale;
    }
    _viewport = viewport;
    _imageRect = rect;
    // Paint the rebased geometry immediately; notify the sibling toolbar only
    // after layout. This avoids both a stale-size frame and setState in layout.
    _pendingMatrix = next;
    final owner = _lease;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(owner, _lease) ||
          !identical(_pendingMatrix, next)) {
        return;
      }
      _pendingMatrix = null;
      _transform.value = next;
    });
  }

  void _moveTo(Matrix4 value, {bool animate = false}) {
    _motion.stop();
    final begin = _effectiveMatrix.clone();
    _pendingMatrix = null;
    if (animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        !GlassAccessibilityData.of(context).reduceMotion) {
      _motionTween = Matrix4Tween(begin: begin, end: value);
      _motion.forward(from: 0);
    } else {
      _transform.value = value;
    }
  }

  void _zoom(double value, {Offset? anchor}) {
    if (!_canAct) return;
    _manual = true;
    _moveTo(
      ImageViewerGeometry.zoomAround(
        _effectiveMatrix,
        imageRect: _imageRect,
        viewport: _viewport,
        targetScale: value,
        anchor: anchor,
      ),
      animate: true,
    );
  }

  void _fit() {
    if (!_canAct) return;
    _motion.stop();
    _manual = false;
    setState(() => _originalSize = false);
    final rect = ImageViewerGeometry.centeredImageRect(
      ImageViewerGeometry.fitSize(_natural, _viewport),
      _viewport,
    );
    _imageRect = rect;
    _moveTo(Matrix4.identity());
  }

  void _toggleOriginal() {
    if (!_canAct) return;
    if (_originalSize) {
      _fit();
      return;
    }
    _motion.stop();
    _manual = true;
    final rect = ImageViewerGeometry.centeredImageRect(_natural, _viewport);
    final next = ImageViewerGeometry.rebaseTransform(
      _effectiveMatrix,
      oldImageRect: _imageRect,
      oldViewport: _viewport,
      newImageRect: rect,
      newViewport: _viewport,
      targetScale: 1,
    );
    _imageRect = rect;
    setState(() => _originalSize = true);
    _moveTo(next);
  }

  bool _insideImage(Offset point) => _imageRect.contains(
    MatrixUtils.transformPoint(Matrix4.inverted(_effectiveMatrix), point),
  );

  void _scroll(PointerSignalEvent event) {
    if (!_canAct || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      if (!_canAct) return;
      _motion.stop();
      _manual = true;
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed || keyboard.isMetaPressed) {
        _moveTo(
          ImageViewerGeometry.zoomAround(
            _effectiveMatrix,
            imageRect: _imageRect,
            viewport: _viewport,
            targetScale: _scale * math.exp(-event.scrollDelta.dy / 200),
            anchor: event.localPosition,
          ),
        );
      } else {
        final delta = keyboard.isShiftPressed
            ? Offset(event.scrollDelta.dy, event.scrollDelta.dx)
            : event.scrollDelta;
        final next = _effectiveMatrix.clone()
          ..setEntry(0, 3, _effectiveMatrix.entry(0, 3) - delta.dx)
          ..setEntry(1, 3, _effectiveMatrix.entry(1, 3) - delta.dy);
        _moveTo(
          ImageViewerGeometry.clampTransform(
            next,
            imageRect: _imageRect,
            viewport: _viewport,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _stopDimensionRead();
    _stopOriginalDimensionRead();
    _motion.dispose();
    _transform.removeListener(_updateToolbarPresentation);
    _transform.dispose();
    _toolbarPresentation.dispose();
    _focus.dispose();
    _lease.state.removeListener(_accessChanged);
    _lease.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _lease, request = _lease.future;
    final glass = GlassThemeData.of(context)
        .copyWith(brightness: Brightness.dark);
    return CupertinoTheme(
      data: CupertinoTheme.of(context).copyWith(brightness: Brightness.dark),
      child: GlassTheme(
        data: glass,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: '图片预览',
            child: ColoredBox(
              color: GlassAccessibilityData.of(context).reduceTransparency
                  ? const Color(0xff000000)
                  : const Color(0xe8000000),
              child: SafeArea(
                child: FutureBuilder<Uint8List>(
                  key: ObjectKey(request),
                  future: request,
                  builder: (context, value) {
                    final valid = !_invalidated && owner.current;
                    final failed =
                        value.hasError || identical(_decodeFailed, request);
                    final original = owner.state.imageDimensions(
                      owner.url,
                      kind: 'original',
                    );
                    final thumb = owner.state.imageDimensions(owner.url);
                    final natural = _naturalSize(original, thumb);
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 860),
                              child: ValueListenableBuilder(
                                valueListenable: _toolbarPresentation,
                                builder: (context, presentation, child) =>
                                    ImageViewerToolbar(
                                      label: widget.label,
                                      scale: _scale,
                                      originalSize: _originalSize,
                                      enabled: valid && !_closing,
                                      onZoomOut: () =>
                                          _zoom(_buttonScale - .25),
                                      onZoomIn: () => _zoom(_buttonScale + .25),
                                      onFit: _fit,
                                      onOriginalSize: _toggleOriginal,
                                      onClose: _dismiss,
                                    ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: valid
                                ? LayoutBuilder(
                                    builder: (context, bounds) {
                                      _layoutImage(bounds.biggest, natural);
                                      final picture = Positioned.fromRect(
                                        rect: _imageRect,
                                        child: _image(
                                          value.data,
                                          owner,
                                          request,
                                          failed: failed,
                                        ),
                                      );
                                      return Listener(
                                        onPointerSignal: _scroll,
                                        child: GestureDetector(
                                          key: const ValueKey(
                                            'image-viewer-viewport',
                                          ),
                                          behavior: HitTestBehavior.opaque,
                                          onTapUp: (details) {
                                            if (!_insideImage(
                                              details.localPosition,
                                            )) {
                                              _dismiss();
                                            }
                                          },
                                          onDoubleTapDown: (details) =>
                                              _doubleTapPosition =
                                                  details.localPosition,
                                          onDoubleTap: () {
                                            if (!_insideImage(
                                              _doubleTapPosition,
                                            )) {
                                              _dismiss();
                                              return;
                                            }
                                            if (_originalSize ||
                                                _scale > 1.01) {
                                              _fit();
                                            } else {
                                              _zoom(
                                                2,
                                                anchor: _doubleTapPosition,
                                              );
                                            }
                                          },
                                          onScaleStart: (details) {
                                            if (!_canAct) return;
                                            _motion.stop();
                                            _manual = true;
                                            _gestureActive = true;
                                            _gestureScaleBase =
                                                _lastGestureScale = 1;
                                            _gestureStart = _effectiveMatrix
                                                .clone();
                                            _gestureAnchor = _lastGestureFocal =
                                                details.localFocalPoint;
                                          },
                                          onScaleEnd: (_) =>
                                              _gestureActive = false,
                                          onScaleUpdate: (details) {
                                            if (!_canAct || !_gestureActive) {
                                              return;
                                            }
                                            _lastGestureScale = details.scale;
                                            _lastGestureFocal =
                                                details.localFocalPoint;
                                            final scale =
                                                (ImageViewerGeometry.scaleOf(
                                                          _gestureStart,
                                                        ) *
                                                        details.scale /
                                                        _gestureScaleBase)
                                                    .clamp(.5, 4.0);
                                            final scene =
                                                MatrixUtils.transformPoint(
                                                  Matrix4.inverted(
                                                    _gestureStart,
                                                  ),
                                                  _gestureAnchor,
                                                );
                                            final next = Matrix4.identity()
                                              ..setEntry(0, 0, scale)
                                              ..setEntry(1, 1, scale)
                                              ..setEntry(
                                                0,
                                                3,
                                                details.localFocalPoint.dx -
                                                    scene.dx * scale,
                                              )
                                              ..setEntry(
                                                1,
                                                3,
                                                details.localFocalPoint.dy -
                                                    scene.dy * scale,
                                              );
                                            _moveTo(
                                              ImageViewerGeometry.clampTransform(
                                                next,
                                                imageRect: _imageRect,
                                                viewport: _viewport,
                                              ),
                                            );
                                          },
                                          child: ClipRect(
                                            child: AnimatedBuilder(
                                              animation: _transform,
                                              builder: (context, child) =>
                                                  Transform(
                                                    transform:
                                                        _pendingMatrix ??
                                                        _transform.value,
                                                    child: child,
                                                  ),
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                fit: StackFit.expand,
                                                children: [picture],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  )
                                : const Center(
                                    child: Text(
                                      '账号已变更，请关闭图片后重新打开。',
                                      style: TextStyle(
                                        color: Color(0xffeceef3),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          child: SizedBox(
                            height: 36,
                            child: Center(
                              child: !valid
                                  ? const SizedBox.shrink()
                                  : failed
                                  ? DeskButton(
                                      '重新加载原图',
                                      width: 144,
                                      icon: CupertinoIcons.arrow_clockwise,
                                      onTap: () => _retry(owner, request),
                                    )
                                  : Text(
                                      value.hasData
                                          ? '滚动查看 · 双击缩放 · Esc 关闭'
                                          : '正在读取高清图片…',
                                      style: DeskTypography.metadata.copyWith(
                                        color: const Color(0xffa8adb8),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail([Uint8List? bytes]) => Image.memory(
    bytes ?? widget.thumbnail,
    fit: BoxFit.contain,
    gaplessPlayback: false,
    errorBuilder: (_, error, stack) =>
        const Icon(CupertinoIcons.photo, color: Color(0xffa8adb8), size: 40),
  );

  Widget _image(
    Uint8List? bytes,
    _OriginalImageLease owner,
    Future<Uint8List> request, {
    required bool failed,
  }) {
    final image = bytes == null || failed
        ? _thumbnail()
        : Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: false,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, error, stack) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    identical(owner, _lease) &&
                    owner.current &&
                    identical(owner.future, request) &&
                    !identical(_decodeFailed, request)) {
                  setState(() {
                    _decodeFailed = request;
                  });
                }
              });
              return _thumbnail();
            },
          );
    final picture = SizedBox.expand(
      key: const ValueKey('image-viewer-picture'),
      child: image,
    );
    if (widget.heroTag == null) return picture;
    final thumbnail = widget.thumbnail;
    return HeroMode(
      enabled:
          _heroAllowed &&
          !MediaQuery.disableAnimationsOf(context) &&
          !GlassAccessibilityData.of(context).reduceMotion,
      child: Hero(
        tag: widget.heroTag!,
        transitionOnUserGestures: true,
        flightShuttleBuilder: (_, animation, direction, from, to) =>
            ListenableBuilder(
              listenable: owner.state,
              builder: (context, child) =>
                  owner.current ? child! : const SizedBox.shrink(),
              child: _thumbnail(thumbnail),
            ),
        child: picture,
      ),
    );
  }
}
