import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Mounted leaf blocks, indexed by floor. No scroll listener, polling, or
/// per-frame document walk is installed by this controller.
class ReaderContentLayoutController {
  ReaderContentLayoutController({
    required this.preserveAnchor,
    this.onGeometryResolved,
    this.readScrollPosition,
  });

  final VoidCallback Function() preserveAnchor;
  final VoidCallback? onGeometryResolved;
  final ScrollPosition? Function()? readScrollPosition;
  final _floors = <String, Set<_RenderContentBlock>>{};
  final _unresolvedGeometry = <String, Set<Object>>{};
  bool _disposed = false;

  ScrollPosition? get scrollPosition =>
      _disposed ? null : readScrollPosition?.call();

  bool hasUnresolvedGeometry(String floorID) =>
      !_disposed && (_unresolvedGeometry[floorID]?.isNotEmpty ?? false);

  void _setUnresolvedGeometry(String floorID, Object token, bool unresolved) {
    if (_disposed) return;
    if (unresolved) {
      (_unresolvedGeometry[floorID] ??= Set<Object>.identity()).add(token);
      return;
    }
    final tokens = _unresolvedGeometry[floorID];
    if (tokens == null || !tokens.remove(token) || tokens.isNotEmpty) return;
    _unresolvedGeometry.remove(floorID);
    // The owner decides whether to resume a parked restore after layout.
    // Registration itself never schedules frames, timers, or document scans.
    onGeometryResolved?.call();
  }

  void _register(_RenderContentBlock block) {
    if (!_disposed) {
      (_floors[block.floorID] ??= <_RenderContentBlock>{}).add(block);
    }
  }

  void _unregister(_RenderContentBlock block) {
    final blocks = _floors[block.floorID];
    blocks?.remove(block);
    if (blocks?.isEmpty == true) _floors.remove(block.floorID);
  }

  bool hasVariableMedia(String floorID) =>
      !_disposed &&
      (_floors[floorID]?.any((block) => block.attached && block.variableSize) ??
          false);

  /// [top] and [bottom] are the viewport's global vertical coordinates.
  /// Call before changing content, while the old layout is still available.
  /// Only this floor's mounted markers are inspected.
  ReaderContentPoint? capture({
    required String floorID,
    required double top,
    required double bottom,
  }) {
    if (_disposed || !top.isFinite || !bottom.isFinite || bottom <= top) {
      return null;
    }
    _RenderContentBlock? first;
    Rect? firstRect;
    for (final block in _floors[floorID] ?? const <_RenderContentBlock>{}) {
      final rect = _paintedRect(block);
      if (rect == null || rect.bottom <= top || rect.top >= bottom) continue;
      if (firstRect == null || rect.top < firstRect.top) {
        first = block;
        firstRect = rect;
      }
    }
    if (first == null || firstRect == null) return null;
    return ReaderContentPoint._capture(first, firstRect, top);
  }

  void dispose() {
    _disposed = true;
    _floors.clear();
    _unresolvedGeometry.clear();
  }
}

class ReaderContentLayoutScope extends InheritedWidget {
  const ReaderContentLayoutScope({
    required this.controller,
    required this.viewportHeight,
    required super.child,
    super.key,
  });

  final ReaderContentLayoutController controller;
  final double viewportHeight;

  /// Capture synchronously, before the caller's setState/content mutation.
  /// The mutation supplies the frame; this helper never requests extra frames.
  /// Do not gate the restore on the source block remaining mounted: removing
  /// that block is itself a valid change, and the reader owns fallback/cancel.
  static void prepareChange(BuildContext context) {
    if (!context.mounted) return;
    final scope = context
        .getInheritedWidgetOfExactType<ReaderContentLayoutScope>();
    final controller = scope?.controller;
    if (controller == null || controller._disposed) return;
    final restore = controller.preserveAnchor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller._disposed) restore();
    });
  }

  static double? maybeViewportHeightOf(BuildContext context) {
    final height = context
        .dependOnInheritedWidgetOfExactType<ReaderContentLayoutScope>()
        ?.viewportHeight;
    return height != null && height.isFinite && height > 0 ? height : null;
  }

  @override
  bool updateShouldNotify(ReaderContentLayoutScope oldWidget) =>
      !identical(controller, oldWidget.controller) ||
      viewportHeight != oldWidget.viewportHeight;
}

class ReaderContentFloor extends InheritedWidget {
  const ReaderContentFloor({
    required this.floorID,
    required super.child,
    super.key,
  });

  final String floorID;

  @override
  bool updateShouldNotify(ReaderContentFloor oldWidget) =>
      floorID != oldWidget.floorID;
}

/// Registers unknown media dimensions without adding a render object.
/// A failed request remains unresolved until its caller has valid dimensions;
/// a loading/error placeholder is not evidence that the geometry is known.
class ReaderContentGeometry extends StatefulWidget {
  const ReaderContentGeometry({
    required this.unresolved,
    required this.child,
    super.key,
  });

  final bool unresolved;
  final Widget child;

  @override
  State<ReaderContentGeometry> createState() => _ReaderContentGeometryState();
}

class _ReaderContentGeometryState extends State<ReaderContentGeometry> {
  final Object _token = Object();
  ReaderContentLayoutController? _controller;
  String? _floor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRegistration();
  }

  @override
  void didUpdateWidget(ReaderContentGeometry oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistration();
  }

  void _syncRegistration() {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ReaderContentLayoutScope>();
    final floor = context
        .dependOnInheritedWidgetOfExactType<ReaderContentFloor>();
    final next = scope != null && floor != null && !scope.controller._disposed
        ? scope.controller
        : null;
    final nextFloor = next == null ? null : floor!.floorID;
    final previous = _controller, previousFloor = _floor;
    _controller = next;
    _floor = nextFloor;
    // Register the new owner first, so resolving the old floor cannot expose
    // a transient gap for this token's new floor/controller.
    if (next != null && nextFloor != null) {
      next._setUnresolvedGeometry(nextFloor, _token, widget.unresolved);
    }
    if (previous != null &&
        previousFloor != null &&
        (!identical(previous, next) || previousFloor != nextFloor)) {
      previous._setUnresolvedGeometry(previousFloor, _token, false);
    }
  }

  @override
  void dispose() {
    final controller = _controller, floor = _floor;
    _controller = null;
    _floor = null;
    if (controller != null && floor != null) {
      controller._setUnresolvedGeometry(floor, _token, false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wrap leaf content only, not disclosure/tab containers around other markers.
/// Outside a reader this is just [child], with no added render object.
class ReaderContentBlock extends StatelessWidget {
  const ReaderContentBlock({
    required this.child,
    this.variableSize = false,
    super.key,
  });

  final Widget child;
  final bool variableSize;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ReaderContentLayoutScope>();
    final floor = context
        .dependOnInheritedWidgetOfExactType<ReaderContentFloor>();
    if (scope == null || floor == null || scope.controller._disposed) {
      return child;
    }
    return _ContentMarker(
      controller: scope.controller,
      floorID: floor.floorID,
      variableSize: variableSize,
      child: child,
    );
  }
}

/// A short-lived position inside one mounted leaf. It is not persistent data.
/// Resolve after layout; a retired/reassigned leaf returns null so the reader
/// can fall back to its floor anchor. The block-relative fraction preserves a
/// location inside long images/reports, without reading text layout that may
/// already be dirty when a LayoutBuilder starts a geometry transaction.
class ReaderContentPoint {
  ReaderContentPoint._(_RenderContentBlock block, double fraction)
    : _block = block,
      _epoch = block.epoch,
      _fraction = fraction;

  final _RenderContentBlock _block;
  final int _epoch;
  final double _fraction;

  static ReaderContentPoint? _capture(
    _RenderContentBlock block,
    Rect rect,
    double top,
  ) {
    final y = math.max(top, rect.top);
    final local = block.globalToLocal(Offset(rect.center.dx, y));
    final layoutSize = block.layoutSize;
    if (layoutSize == null || layoutSize.height <= 0 || !local.dy.isFinite) {
      return null;
    }
    final fraction = (local.dy / layoutSize.height).clamp(0.0, 1.0);
    return ReaderContentPoint._(block, fraction);
  }

  ({RenderBox box, double localDy})? resolve() {
    if (_block.epoch != _epoch ||
        _block.controller._disposed ||
        !_hasPaintedLayout(_block)) {
      return null;
    }
    // Resolution is local, including during a sliver's layout correction.
    // A global transform could read an outer FractionalTranslation's size
    // outside its layout scope, even though this block's dimensions are cached.
    return (box: _block, localDy: _block.layoutSize!.height * _fraction);
  }
}

class _ContentMarker extends SingleChildRenderObjectWidget {
  const _ContentMarker({
    required this.controller,
    required this.floorID,
    required this.variableSize,
    required super.child,
  });

  final ReaderContentLayoutController controller;
  final String floorID;
  final bool variableSize;

  @override
  _RenderContentBlock createRenderObject(BuildContext context) =>
      _RenderContentBlock(controller, floorID, variableSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderContentBlock renderObject,
  ) {
    renderObject.rebind(controller, floorID, variableSize);
  }
}

class _RenderContentBlock extends RenderProxyBox {
  _RenderContentBlock(this.controller, this.floorID, this.variableSize);

  ReaderContentLayoutController controller;
  String floorID;
  bool variableSize;
  int epoch = 0;
  Size? layoutSize;

  void rebind(
    ReaderContentLayoutController next,
    String nextFloor,
    bool nextVariableSize,
  ) {
    variableSize = nextVariableSize;
    if (identical(next, controller) && nextFloor == floorID) return;
    if (attached) controller._unregister(this);
    epoch++;
    controller = next;
    floorID = nextFloor;
    if (attached) controller._register(this);
  }

  @override
  void performLayout() {
    super.performLayout();
    // Sliver correction may resolve a descendant point while the ancestor is
    // laying out. RenderBox.size cannot be read across that layout boundary.
    // Copy dimensions here, where this box owns the legal size read, and use
    // the last completed layout throughout capture/resolve in every build mode.
    final laidOut = size;
    layoutSize = Size(laidOut.width, laidOut.height);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    epoch++;
    controller._register(this);
  }

  @override
  void detach() {
    controller._unregister(this);
    epoch++;
    super.detach();
  }
}

bool _hasPaintedLayout(_RenderContentBlock box) {
  final layoutSize = box.layoutSize;
  if (!box.attached || layoutSize == null || layoutSize.isEmpty) return false;
  if (!layoutSize.width.isFinite || !layoutSize.height.isFinite) return false;
  RenderObject child = box;
  for (var parent = child.parent; parent != null; parent = child.parent) {
    if (!parent.paintsChild(child)) return false;
    child = parent;
  }
  return true;
}

Rect? _paintedRect(_RenderContentBlock box) {
  if (!_hasPaintedLayout(box)) return null;
  final rect = MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.layoutSize!,
  );
  return rect.isFinite && !rect.isEmpty ? rect : null;
}
