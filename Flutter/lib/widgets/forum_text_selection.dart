// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

/// Ordinary forum text uses RenderParagraph, with one selection controller per
/// body. Nested blocks share that controller; standalone message text gets its
/// own. This avoids an EditableText and retained editing layer for every run.
class ForumTextSelection extends StatelessWidget {
  const ForumTextSelection({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) != null) return child;
    return _ForumSelectionRegion(child: child);
  }
}

class _ForumSelectionRegion extends StatefulWidget {
  const _ForumSelectionRegion({required this.child});
  final Widget child;

  @override
  State<_ForumSelectionRegion> createState() => _ForumSelectionRegionState();
}

class _ForumSelectionRegionState extends State<_ForumSelectionRegion>
    with AutomaticKeepAliveClientMixin {
  final _focusNode = FocusNode(debugLabel: 'Forum body selection');

  @override
  bool get wantKeepAlive => _focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(updateKeepAlive);
  }

  @override
  void dispose() {
    _focusNode.removeListener(updateKeepAlive);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // A region inside a lazy floor is invisible to SliverList's outer selection
    // keepalive. Preserve the focused body, as EditableText did previously, so
    // scrolling it out of the cache does not discard its selection or Cmd+C.
    return SelectableRegion(
      focusNode: _focusNode,
      selectionControls: cupertinoDesktopTextSelectionHandleControls,
      contextMenuBuilder: (context, region) {
        final items = region.contextMenuButtonItems;
        if (items.isEmpty) return const SizedBox.shrink();
        return CupertinoDesktopTextSelectionToolbar(
          anchor: region.contextMenuAnchors.primaryAnchor,
          children: [
            for (final item in items)
              CupertinoDesktopTextSelectionToolbarButton.buttonItem(
                buttonItem: item,
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
