import 'dart:async';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;

import '../state/app_state.dart';
import 'glass_chrome.dart';

/// A preview owns one account revision for its lifetime. Its parent observes
/// account changes; individual sticker leaves do not subscribe to AppState.
class DraftStickerImageScope extends InheritedWidget {
  const DraftStickerImageScope({
    required this.accessRevision,
    required this.active,
    required super.child,
    super.key,
  });

  final int accessRevision;
  final bool active;

  static DraftStickerImageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DraftStickerImageScope>();

  @override
  bool updateShouldNotify(DraftStickerImageScope oldWidget) =>
      accessRevision != oldWidget.accessRevision || active != oldWidget.active;
}

/// A compact draft-only image. It never adds resizing controls or opens the
/// image viewer; an explicit onTap may preserve a surrounding Markdown link.
class DraftStickerImage extends StatefulWidget {
  const DraftStickerImage({
    required this.state,
    required this.url,
    required this.label,
    required this.code,
    this.size = 48,
    this.onTap,
    super.key,
  }) : assert(size > 0 && size < double.infinity);

  final AppState state;
  final String url, label, code;
  final double size;
  final VoidCallback? onTap;

  @override
  State<DraftStickerImage> createState() => _DraftStickerImageState();
}

class _DraftStickerImageState extends State<DraftStickerImage> {
  DraftStickerImageScope? _scope;
  late final int _fallbackRevision;
  late AppState _sourceState;
  late String _sourceURL;
  late int _ownerRevision;
  int _request = 0;
  bool _loading = false, _failed = false;
  Uint8List? _bytes;
  Future<Uint8List>? _imageFuture;

  bool get _active => _scope?.active ?? true;
  bool get _authorized =>
      mounted &&
      identical(_sourceState, widget.state) &&
      _sourceURL == widget.url &&
      _ownerRevision == widget.state.accessRevision;

  @override
  void initState() {
    super.initState();
    _fallbackRevision = widget.state.accessRevision;
    _ownerRevision = _fallbackRevision;
    _sourceState = widget.state;
    _sourceURL = widget.url;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = DraftStickerImageScope.maybeOf(context);
    _synchronize();
  }

  @override
  void didUpdateWidget(DraftStickerImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An inherited scope and this leaf may update in the same frame. Read the
    // new scope before considering a URL change, not its previous active flag.
    _scope = DraftStickerImageScope.maybeOf(context);
    _synchronize();
  }

  void _synchronize() {
    final owner = _scope?.accessRevision ?? _fallbackRevision;
    if (!identical(_sourceState, widget.state) ||
        _sourceURL != widget.url ||
        _ownerRevision != owner) {
      _request++;
      _sourceState = widget.state;
      _sourceURL = widget.url;
      _ownerRevision = owner;
      _bytes = null;
      _imageFuture = null;
      _loading = false;
      _failed = false;
    }
    if (!_authorized) {
      _request++;
      _bytes = null;
      _imageFuture = null;
      _loading = false;
      _failed = false;
      return;
    }
    _loadIfNeeded();
  }

  void _loadIfNeeded() {
    if (!_authorized || !_active || _loading || _failed || _bytes != null) {
      return;
    }
    _loading = true;
    final request = ++_request;
    final state = _sourceState, url = _sourceURL, owner = _ownerRevision;
    bool sameRequest() =>
        mounted &&
        request == _request &&
        identical(state, _sourceState) &&
        url == _sourceURL &&
        owner == _ownerRevision;
    unawaited(() async {
      try {
        // Keep the exact cache entry, not an async wrapper around it. A decode
        // retry may only evict the Future whose bytes this leaf displayed.
        final imageFuture = state.image(url);
        _imageFuture = imageFuture;
        final bytes = await imageFuture;
        if (!sameRequest()) return;
        _loading = false;
        // Hidden results may remain in AppState's bounded cache, but are not
        // adopted here. Reactivation can reuse that cached Future.
        if (!_authorized || !_active) return;
        setState(() => _bytes = bytes);
      } catch (_) {
        if (!sameRequest()) return;
        _loading = false;
        if (!_authorized || !_active) return;
        setState(() => _failed = true);
      }
    }());
  }

  void _retry() {
    if (!_authorized || !_active || _loading) return;
    final expected = _imageFuture;
    if (_bytes != null && expected != null) {
      // Native transport succeeded but Image.memory could not decode its
      // bytes. Another leaf may already have replaced this cache entry; the
      // identity/revision guard leaves that newer Future and metadata intact.
      _sourceState.evictImageFuture(
        _sourceURL,
        expected,
        revision: _ownerRevision,
      );
    }
    setState(() {
      _failed = false;
      _bytes = null;
      _imageFuture = null;
      _loadIfNeeded();
    });
  }

  void _openLink() {
    if (_authorized && _active) widget.onTap?.call();
  }

  String get _description {
    final label = widget.label.trim();
    final code = widget.code.trim();
    if (label.isEmpty) return code.isEmpty ? '表情' : ':$code:';
    return code.isEmpty ? label : '$label · :$code:';
  }

  Widget _placeholder(BuildContext context, {required bool error}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: DeskColors(context).well,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Center(
          child: Icon(
            error ? CupertinoIcons.arrow_clockwise : CupertinoIcons.smiley,
            size: widget.size.clamp(12.0, 48.0).toDouble() * .4,
            color: DeskColors(context).secondary,
          ),
        ),
      );

  Widget _frame(
    BuildContext context, {
    required Widget child,
    required bool error,
  }) {
    final action = !_authorized || !_active
        ? null
        : error
        ? _retry
        : widget.onTap == null
        ? null
        : _openLink;
    final description = error ? '$_description，加载失败，点按重试' : _description;
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: Semantics(
        image: true,
        button: action != null,
        label: description,
        onTap: action,
        child: ExcludeSemantics(
          child: MouseRegion(
            cursor: action == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: action,
              child: SizedBox.square(dimension: widget.size, child: child),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _authorized ? _bytes : null;
    if (bytes == null) {
      final error = _authorized && _failed;
      return _frame(
        context,
        error: error,
        child: _placeholder(context, error: error),
      );
    }
    return Image.memory(
      bytes,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
      // Keep every frame, including decode failure, within the same tiny box.
      frameBuilder: (context, child, frame, synchronous) =>
          _frame(context, error: false, child: child),
      errorBuilder: (context, error, stack) => _frame(
        context,
        error: true,
        child: _placeholder(context, error: true),
      ),
    );
  }

  @override
  void dispose() {
    _request++;
    _imageFuture = null;
    super.dispose();
  }
}
