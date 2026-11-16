import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/frame_diagnostics.dart';
import 'editor_header_diagnostics.dart';
import '../screens/composer_screen.dart';
import '../screens/inline_edit_screen.dart';
import '../state/reader_editors.dart';
import 'glass_chrome.dart';

/// The target belongs to the reader, while documents stay mounted in the host
/// above every destination. LayerLink keeps their position tied to the pane.
class ReaderEditorAnchor extends StatelessWidget {
  const ReaderEditorAnchor({
    required this.editors,
    required this.session,
    required this.height,
    super.key,
  });
  final ReaderEditors editors;
  final ReaderEditorSession session;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: LayoutBuilder(
      builder: (context, bounds) {
        final size = Size(bounds.maxWidth, bounds.maxHeight);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) editors.updateSize(session, size);
        });
        return CompositedTransformTarget(
          link: session.link,
          child: const SizedBox.expand(),
        );
      },
    ),
  );
}

class ReaderEditorHost extends StatelessWidget {
  const ReaderEditorHost({
    required this.editors,
    required this.child,
    super.key,
  });
  final ReaderEditors editors;
  final Widget child;

  Future<void> _choose(BuildContext context) async {
    final sessions = editors.sessions;
    if (sessions.length == 1) {
      await editors.reveal(sessions.single);
      return;
    }
    final selected = await showCupertinoModalPopup<ReaderEditorSession>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('保留的编辑'),
        actions: [
          for (final session in sessions)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, session),
              child: Text(
                '${session.revision != editors.state.accessRevision ? '旧账号 · ' : ''}'
                '${session.reply ? '回复' : '编辑第 ${session.floor} 楼'} · ${session.topic.title}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
    );
    if (context.mounted && selected != null) await editors.reveal(selected);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editors,
    builder: (context, _) => sampleEditorHeader(
      layoutKind: UiWorkKind.editorHostLayout,
      paintKind: UiWorkKind.editorHostPaint,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final recovery = editors.recovery;
          final presented = editors.presented;
          final hidden = editors.sessions
              .where((session) => !identical(session, presented))
              .length;
          final colors = DeskColors(context);
          return sampleEditorBuild(
            kind: UiWorkKind.editorHostBuild,
            child: Stack(
              children: [
                ExcludeFocus(
                  excluding: recovery != null,
                  child: ExcludeSemantics(
                    excluding: recovery != null,
                    child: IgnorePointer(
                      ignoring: recovery != null,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: hidden > 0 ? 44 : 0),
                        child: child,
                      ),
                    ),
                  ),
                ),
                if (recovery != null) ...[
                  Positioned.fill(
                    child: ModalBarrier(
                      color: const Color(0x66000000),
                      dismissible: false,
                    ),
                  ),
                  Center(
                    child: SizedBox(
                      width: math.min(760, bounds.maxWidth - 32),
                      child: DeskGlassPanel(
                        level: GlassLevel.overlay,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    recovery.revision !=
                                            editors.state.accessRevision
                                        ? '旧账号保留的编辑 · 仅供复制后关闭'
                                        : '保留的编辑 · ${recovery.topic.title}',
                                    style: TextStyle(color: colors.ink),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                DeskButton(
                                  '返回工作区',
                                  width: 110,
                                  onTap: editors.hideRecovery,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ReaderEditorAnchor(
                              editors: editors,
                              session: recovery,
                              height: math.min(
                                480,
                                math.max(160, bounds.maxHeight - 140),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                for (final session in editors.sessions)
                  Positioned.fill(
                    key: ValueKey(('retained-reader-editor', session.id)),
                    child: CompositedTransformFollower(
                      link: session.link,
                      showWhenUnlinked: false,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: session.size.width,
                          height: session.size.height,
                          child: Offstage(
                            offstage: !identical(presented, session),
                            child: ExcludeFocus(
                              excluding: !session.binding.active,
                              child: ExcludeSemantics(
                                excluding: !session.binding.active,
                                child: IgnorePointer(
                                  ignoring: !session.binding.active,
                                  child: TickerMode(
                                    enabled: session.binding.active,
                                    child: RepaintBoundary(
                                      child: ClipRRect(
                                        borderRadius:
                                            const BorderRadius.vertical(
                                              bottom: Radius.circular(16),
                                            ),
                                        child: ColoredBox(
                                          color: colors.paper,
                                          child: session.reply
                                              ? ComposerScreen(
                                                  key: ValueKey(session.id),
                                                  state: editors.state,
                                                  topicID: session.topic.id,
                                                  url: session.topic.url,
                                                  binding: session.binding,
                                                )
                                              : InlineEditScreen(
                                                  key: ValueKey(session.id),
                                                  state: editors.state,
                                                  topicID: session.topic.id,
                                                  url: session.topic.url,
                                                  floor: session.floor!,
                                                  binding: session.binding,
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
                      ),
                    ),
                  ),
                if (hidden > 0 && recovery == null)
                  Positioned(
                    right: 16,
                    bottom: 4,
                    child: DeskButton(
                      '继续编辑 · $hidden',
                      icon: CupertinoIcons.square_pencil,
                      width: 160,
                      onTap: () => _choose(context),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
