// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';

import '../state/inbox_navigation.dart';

/// A single mounted list owns its controller; account-scoped memory holds only
/// finite offsets. Category switches never attach one controller to two lists.
class InboxTimeline extends StatefulWidget {
  const InboxTimeline({
    required this.navigation,
    required this.revision,
    required this.location,
    required this.conversation,
    required this.tail,
    required this.padding,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    super.key,
  });

  final InboxNavigation navigation;
  final int revision;
  final String location;
  final bool conversation;
  final Object tail;
  final EdgeInsets padding;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder, separatorBuilder;

  @override
  State<InboxTimeline> createState() => _InboxTimelineState();
}

class _InboxTimelineState extends State<InboxTimeline> {
  late final ScrollController _scroll;
  bool _settling = false;
  bool _revealed = true;
  int _settleTicket = 0;

  @override
  void initState() {
    super.initState();
    final saved = widget.navigation.offset(
      widget.location,
      revision: widget.revision,
    );
    _scroll = ScrollController(
      initialScrollOffset: saved ?? 0,
      keepScrollOffset: false,
    )..addListener(_remember);
    if (widget.conversation && saved == null) {
      _revealed = false;
      _settleAtEnd();
    }
  }

  void _remember() {
    if (!_scroll.hasClients || _settling) return;
    widget.navigation.remember(
      widget.location,
      _scroll.offset,
      revision: widget.revision,
    );
  }

  @override
  void didUpdateWidget(InboxTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation &&
        _scroll.hasClients &&
        (widget.itemCount != oldWidget.itemCount ||
            widget.tail != oldWidget.tail) &&
        _scroll.position.extentAfter <= 24) {
      _settleAtEnd();
    }
  }

  void _settleAtEnd() {
    final ticket = ++_settleTicket;
    _settling = true;
    var frames = 0, stable = 0;
    double? previousEnd;
    void step(Duration _) {
      if (!mounted || ticket != _settleTicket) return;
      if (!_scroll.hasClients) {
        _finishSettling();
        return;
      }
      final position = _scroll.position;
      final end = position.maxScrollExtent;
      if ((position.pixels - end).abs() > .5) _scroll.jumpTo(end);
      stable = previousEnd != null && (end - previousEnd!).abs() <= .5
          ? stable + 1
          : 0;
      previousEnd = end;
      // Lazy variable-height rows refine maxScrollExtent after a jump. Let
      // layout converge before revealing first entry; short chats remain top.
      if (end == 0 || stable >= 2 || ++frames >= 12) {
        _finishSettling();
      } else {
        WidgetsBinding.instance.addPostFrameCallback(step);
        WidgetsBinding.instance.scheduleFrame();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(step);
    WidgetsBinding.instance.scheduleFrame();
  }

  void _finishSettling() {
    _settling = false;
    _remember();
    if (!_revealed) setState(() => _revealed = true);
  }

  void _userScroll() {
    if (!_settling) return;
    _settleTicket++;
    _finishSettling();
  }

  @override
  void dispose() {
    _settleTicket++;
    _remember();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is PointerScrollEvent) _userScroll();
    },
    onPointerPanZoomStart: (_) => _userScroll(),
    child: NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null && _settling) {
          _userScroll();
        }
        return false;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_revealed,
              child: Opacity(
                opacity: _revealed ? 1 : 0,
                child: CupertinoScrollbar(
                  controller: _scroll,
                  child: ListView.separated(
                    key: ValueKey(widget.location),
                    controller: _scroll,
                    padding: widget.padding,
                    itemCount: widget.itemCount,
                    itemBuilder: widget.itemBuilder,
                    separatorBuilder: widget.separatorBuilder,
                  ),
                ),
              ),
            ),
          ),
          if (!_revealed) const Center(child: CupertinoActivityIndicator()),
        ],
      ),
    ),
  );
}
