import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../core/native_client.dart';
import '../core/native_composer_drop.dart';
import 'composer_media_controller.dart';
import 'glass_chrome.dart';

/// Shares the document's upload/history lane without rebuilding its text field.
class ComposerDropScope extends StatefulWidget {
  const ComposerDropScope({
    required this.media,
    required this.bodyFocus,
    required this.enabled,
    required this.requestKey,
    required this.child,
    this.bridge,
    super.key,
  });

  final ComposerMediaController media;
  final FocusNode bodyFocus;
  final bool enabled;
  final Future<String?> Function() requestKey;
  final Widget child;
  final NativeComposerDrop? bridge;

  @override
  State<ComposerDropScope> createState() => _ComposerDropScopeState();
}

class _ComposerDropScopeState extends State<ComposerDropScope> {
  final _owner = Object();
  final _boundsKey = GlobalKey();
  final _hover = ValueNotifier(false);
  ModalRoute<dynamic>? _route;
  EditableTextState? _editable;
  bool _active = true, _clearHoverOnFrame = false;
  bool _routeCurrent = true, _visible = true, _documentAvailable = false;
  int _epoch = 0;
  NativeComposerDrop get _bridge =>
      widget.bridge ?? NativeComposerDrop.instance;

  bool get _availableDocument {
    if (!mounted ||
        !_active ||
        !widget.enabled ||
        !_visible ||
        widget.media.revision != widget.media.state.accessRevision ||
        !(_route?.isCurrent ?? true) ||
        !widget.media.canStart()) {
      return false;
    }
    final editable = _editable;
    if (editable == null ||
        !editable.mounted ||
        !identical(editable.widget.controller, widget.media.content) ||
        !identical(editable.widget.focusNode, widget.bodyFocus) ||
        editable.widget.readOnly ||
        !editable.widget.selectionEnabled) {
      return false;
    }
    final extensions = widget.media.state.domain('extensions');
    return !(jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] ==
            true);
  }

  bool get _canDrop {
    if (!_availableDocument || widget.media.busy) return false;
    final value = widget.media.content.value;
    return !(value.composing.isValid && !value.composing.isCollapsed);
  }

  Rect? get _bounds {
    final render = _boundsKey.currentContext?.findRenderObject();
    if (render is! RenderBox ||
        !render.attached ||
        !render.hasSize ||
        render.size.isEmpty) {
      return null;
    }
    final rect = MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
    if (!rect.isFinite || rect.isEmpty) return null;
    final view = View.of(context);
    return rect.intersect(
      Offset.zero & (view.physicalSize / view.devicePixelRatio),
    );
  }

  @override
  void initState() {
    super.initState();
    _listen(widget);
    WidgetsBinding.instance.addPostFrameCallback(_frame);
  }

  void _listen(ComposerDropScope target) {
    target.media.addListener(_changed);
    target.media.content.addListener(_changed);
    target.media.state.addListener(_changed);
    target.bodyFocus.addListener(_changed);
  }

  void _unlisten(ComposerDropScope target) {
    target.media.removeListener(_changed);
    target.media.content.removeListener(_changed);
    target.media.state.removeListener(_changed);
    target.bodyFocus.removeListener(_changed);
  }

  void _changed() {
    if (!mounted || !_active) return;
    final available = _availableDocument;
    if (available != _documentAvailable) {
      _documentAvailable = available;
      _epoch++;
    }
    // Normal typing only checks eligibility. It never rebuilds the body or
    // republishes an unchanged native target.
    if (!_canDrop) {
      _hover.value = false;
      _bridge.removeTarget(_owner);
    }
  }

  void _frame(Duration _) {
    if (!mounted) return;
    if (_active && _clearHoverOnFrame) {
      _clearHoverOnFrame = false;
      _hover.value = false;
    }
    // Resolve only after the widget tree has finished updating. A controller
    // notification can arrive while the old focused field is deactivated
    // during document rebinding; ancestor lookup in that interval is unsafe.
    final focusContext = widget.bodyFocus.context;
    _editable = _active && (focusContext?.mounted ?? false)
        ? focusContext!.findAncestorStateOfType<EditableTextState>()
        : null;
    _changed();
    final bounds = _canDrop ? _bounds : null;
    if (bounds != null && !bounds.isEmpty) {
      _bridge.updateTarget(
        owner: _owner,
        client: widget.media.state.client,
        documentID: widget.media.documentID,
        accessRevision: widget.media.revision,
        bounds: bounds,
        onDrag: _drag,
      );
    } else {
      _bridge.removeTarget(_owner);
    }
    // Observe frames that already exist (scroll/resize/route transitions).
    // This callback never schedules a frame or an idle polling timer.
    WidgetsBinding.instance.addPostFrameCallback(_frame);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final current = route?.isCurrent ?? true;
    final visible = TickerMode.valuesOf(context).enabled;
    if (!identical(route, _route) ||
        current != _routeCurrent ||
        visible != _visible) {
      _route = route;
      _routeCurrent = current;
      _visible = visible;
      _epoch++;
    }
    _changed();
  }

  @override
  void didUpdateWidget(ComposerDropScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media) ||
        !identical(oldWidget.bodyFocus, widget.bodyFocus) ||
        !identical(oldWidget.bridge, widget.bridge)) {
      (oldWidget.bridge ?? NativeComposerDrop.instance).removeTarget(_owner);
      _unlisten(oldWidget);
      _listen(widget);
      _editable = null;
      _epoch++;
    }
    if (oldWidget.enabled != widget.enabled) _epoch++;
    _changed();
  }

  @override
  void deactivate() {
    _active = false;
    _editable = null;
    _epoch++;
    _clearHoverOnFrame = true;
    _bridge.removeTarget(_owner);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  bool _hitBody(Offset position) {
    final bounds = _bounds;
    if (bounds == null || !bounds.contains(position)) return false;
    final hits = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hits,
      position,
      View.of(context).viewId,
    );
    final render = _boundsKey.currentContext?.findRenderObject();
    return hits.path.any((entry) => identical(entry.target, render));
  }

  bool _drag(ComposerDropEvent event) {
    if (event.phase == 'exit') {
      if (mounted && _active) _hover.value = false;
      return true;
    }
    if (!mounted || !_active) return false;
    if (!_canDrop || !_hitBody(event.position)) {
      _hover.value = false;
      return false;
    }
    if (event.phase != 'drop') {
      _hover.value = true;
      return true;
    }
    _hover.value = false;
    final token = event.dropToken;
    if (token == null) return false;
    final media = widget.media;
    final epoch = _epoch;
    final offset = _editable!.renderEditable.getPositionForPoint(
      event.position,
    );
    media.content.selection = TextSelection.collapsed(offset: offset.offset);
    widget.bodyFocus.requestFocus();
    bool acceptsCapture() =>
        mounted &&
        identical(media, widget.media) &&
        epoch == _epoch &&
        _availableDocument;
    unawaited(
      media.dropImage(
        dropToken: token,
        requestKey: widget.requestKey,
        canCaptureDrop: acceptsCapture,
      ),
    );
    return true;
  }

  @override
  void dispose() {
    _epoch++;
    _bridge.removeTarget(_owner);
    _unlisten(widget);
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    key: _boundsKey,
    fit: StackFit.passthrough,
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: ValueListenableBuilder(
              valueListenable: _hover,
              builder: (context, hovered, _) => !hovered
                  ? const SizedBox.shrink()
                  : Semantics(
                      liveRegion: true,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: DeskColors(context).accent
                              .withValues(alpha: .06),
                          border: Border.all(
                            color: DeskColors(context).accent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: DeskGlassPanel(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              level: GlassLevel.control,
                              child: Text(
                                '松开以上传图片',
                                style: DeskTypography.control.copyWith(
                                  color: DeskColors(context).ink,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    ],
  );
}
