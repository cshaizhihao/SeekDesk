// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../state/app_state.dart';
import 'glass_chrome.dart';

/// Feedback has its own subscription: showing or expiring a message must not
/// rebuild the whole workspace and its reader. The caller bounds its viewport.
class WorkspaceMessage extends StatefulWidget {
  const WorkspaceMessage({required this.state, super.key});
  final AppState state;

  @override
  State<WorkspaceMessage> createState() => _WorkspaceMessageState();
}

class _WorkspaceMessageState extends State<WorkspaceMessage> {
  String? _message;

  @override
  void initState() {
    super.initState();
    _message = widget.state.message;
    widget.state.addListener(_changed);
  }

  void _changed() {
    if (mounted && _message != widget.state.message) {
      setState(() => _message = widget.state.message);
    }
  }

  @override
  void didUpdateWidget(WorkspaceMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      _message = widget.state.message;
      widget.state.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    if (message == null || message.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.sizeOf(context).height * .3,
        ),
        child: Semantics(
          container: true,
          liveRegion: true,
          child: DeskGlassPanel(
            level: GlassLevel.overlay,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: SingleChildScrollView(
              primary: false,
              child: Text(
                message,
                style: DeskTypography.base.copyWith(
                  color: DeskColors(context).ink,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
