// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import 'glass_chrome.dart';

/// Resize changes the panes' geometry, never their position in the element
/// tree. In particular, an active editor retains its selection and IME state.
class InboxSplitView extends StatelessWidget {
  const InboxSplitView({
    required this.hasDetail,
    required this.list,
    required this.detailBuilder,
    this.detailOnly = false,
    super.key,
  });

  final bool hasDetail, detailOnly;
  final Widget list;
  final Widget Function(bool showBack) detailBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final breakpoint = (341 + 390 * scale).clamp(760.0, double.infinity);
      final columns = !detailOnly && bounds.maxWidth >= breakpoint;
      final listWidth = columns
          ? (bounds.maxWidth * .37).clamp(224.0, 340.0)
          : bounds.maxWidth;
      final detailLeft = columns ? listWidth + 1 : 0.0;
      final showList = !detailOnly && (columns || !hasDetail);
      final showDetail = detailOnly || columns || hasDetail;
      Widget pane({required bool visible, required Widget child}) => Offstage(
        offstage: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: IgnorePointer(
              ignoring: !visible,
              child: TickerMode(enabled: visible, child: child),
            ),
          ),
        ),
      );
      return Stack(
        children: [
          Positioned(
            key: const ValueKey('inbox-list-pane'),
            left: 0,
            top: 0,
            bottom: 0,
            width: listWidth,
            child: pane(visible: showList, child: list),
          ),
          if (columns)
            Positioned(
              key: const ValueKey('inbox-pane-divider'),
              left: listWidth,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: DeskColors(context).line),
            ),
          Positioned(
            key: const ValueKey('inbox-detail-pane'),
            left: detailLeft,
            top: 0,
            bottom: 0,
            width: bounds.maxWidth - detailLeft,
            child: pane(
              visible: showDetail,
              child: detailBuilder(!columns && !detailOnly),
            ),
          ),
        ],
      );
    },
  );
}
