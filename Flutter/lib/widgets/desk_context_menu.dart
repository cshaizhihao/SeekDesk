import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'glass_chrome.dart';
import 'desk_interaction.dart';

class DeskMenuEntry<T> {
  const DeskMenuEntry(this.value, this.label, this.icon);
  final T value;
  final String label;
  final IconData icon;
}

/// A bounded desktop menu. The optional validity signal retires only this
/// route, including when an account changes underneath a newer modal route.
Future<T?> showDeskContextMenu<T>(
  BuildContext context, {
  required Offset position,
  required List<DeskMenuEntry<T>> entries,
  double maximumHeight = double.infinity,
  Listenable? validityChanges,
  bool Function()? isValid,
}) async {
  if (entries.isEmpty || isValid?.call() == false) return null;
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  final local = overlay is RenderBox
      ? overlay.globalToLocal(position)
      : position;
  final route = RawDialogRoute<T>(
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: const Color(0x00000000),
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _DeskContextMenu<T>(
      position: local,
      entries: entries,
      maximumHeight: maximumHeight,
      validityChanges: validityChanges,
      isValid: isValid,
    ),
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

class _DeskContextMenu<T> extends StatefulWidget {
  const _DeskContextMenu({
    required this.position,
    required this.entries,
    required this.maximumHeight,
    required this.validityChanges,
    required this.isValid,
  });
  final Offset position;
  final List<DeskMenuEntry<T>> entries;
  final double maximumHeight;
  final Listenable? validityChanges;
  final bool Function()? isValid;

  @override
  State<_DeskContextMenu<T>> createState() => _DeskContextMenuState<T>();
}

class _DeskContextMenuState<T> extends State<_DeskContextMenu<T>> {
  late final _focus = List.generate(widget.entries.length, (_) => FocusNode());
  bool _retired = false, _finishing = false;

  @override
  void initState() {
    super.initState();
    widget.validityChanges?.addListener(_changed);
  }

  void _changed() {
    if (!mounted || _retired || widget.isValid?.call() != false) return;
    setState(() => _retired = true);
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route?.isActive == true) {
        route!.navigator?.removeRoute(route);
      }
    });
  }

  void _finish([T? value]) {
    if (_finishing ||
        _retired ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    if (widget.isValid?.call() == false) {
      _changed();
      return;
    }
    _finishing = true;
    Navigator.pop(context, value);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _finish();
      return KeyEventResult.handled;
    }
    final active = _focus.indexWhere((node) => node.hasFocus);
    final int next;
    if (key == LogicalKeyboardKey.arrowDown) {
      next = (active + 1) % _focus.length;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      next = (active - 1) % _focus.length;
    } else if (key == LogicalKeyboardKey.home) {
      next = 0;
    } else if (key == LogicalKeyboardKey.end) {
      next = _focus.length - 1;
    } else {
      return KeyEventResult.ignored;
    }
    _focus[next].requestFocus();
    final target = _focus[next].context;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.validityChanges?.removeListener(_changed);
    for (final focus in _focus) {
      focus.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_retired) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = math.min(260.0, math.max(0.0, bounds.maxWidth - 16));
        final rowHeight = math.max(
          38.0,
          MediaQuery.textScalerOf(context).scale(13) * 1.4 + 16,
        );
        final height = math.min(
          math.min(
            rowHeight * widget.entries.length + 12,
            widget.maximumHeight,
          ),
          math.max(0.0, bounds.maxHeight - 16),
        );
        return Stack(
          children: [
            Positioned(
              left: widget.position.dx.clamp(
                8.0,
                math.max(8.0, bounds.maxWidth - width - 8),
              ),
              top: widget.position.dy.clamp(
                8.0,
                math.max(8.0, bounds.maxHeight - height - 8),
              ),
              width: width,
              height: height,
              child: FocusScope(
                onKeyEvent: _key,
                child: DeskGlassPanel(
                  level: GlassLevel.overlay,
                  padding: const EdgeInsets.all(6),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < widget.entries.length;
                          index++
                        )
                          SizedBox(
                            height: rowHeight,
                            child: DeskInteraction(
                              color: DeskColors(context).accent,
                              child: CupertinoButton(
                                focusNode: _focus[index],
                                autofocus: index == 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                onPressed: () =>
                                    _finish(widget.entries[index].value),
                                child: Row(
                                  children: [
                                    Icon(
                                      widget.entries[index].icon,
                                      size: 15,
                                      color: DeskColors(context).secondary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        widget.entries[index].label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: DeskTypography.control.copyWith(
                                          fontSize: 13,
                                          color: DeskColors(context).ink,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
