// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/frame_diagnostics.dart';
import '../core/native_client.dart';
import '../core/composer_sticker_selection.dart';
import '../state/app_state.dart';
import 'composer_media_controller.dart';
import 'composer_sticker_picker.dart';
import 'desk_label_metrics.dart';
import 'editor_header_diagnostics.dart';
import 'glass_chrome.dart';
import 'desk_input_surface.dart';
import 'node_image_settings.dart';

export '../core/composer_sticker_selection.dart';

Size _toolSize(DeskLabelMetrics metrics, String label, double minimum) {
  final text = metrics.measure(label);
  return Size(
    (text.width + 46).ceilToDouble().clamp(minimum, double.infinity),
    (text.height + 12).ceilToDouble().clamp(32.0, double.infinity),
  );
}

class ComposerMediaTools extends StatelessWidget {
  const ComposerMediaTools({
    required this.controller,
    required this.onUpload,
    required this.onStickers,
    this.enabled = true,
    super.key,
  });
  final ComposerMediaController controller;
  final VoidCallback onUpload, onStickers;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final metrics = DeskLabelMetrics.of(
        context,
        style: DeskTypography.control,
      );
      final uploadSize = _toolSize(metrics, '上传图片', 108);
      final stickerSize = _toolSize(metrics, '表情', 82);
      return sampleEditorHeader(
        buildKind: UiWorkKind.editorMediaBuild,
        layoutKind: UiWorkKind.editorMediaLayout,
        paintKind: UiWorkKind.editorMediaPaint,
        child: Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            DeskButton(
              '上传图片',
              icon: CupertinoIcons.photo,
              width: uploadSize.width,
              height: uploadSize.height,
              quiet: true,
              busy:
                  controller.busy &&
                  controller.phase != ComposerMediaPhase.choosingSticker &&
                  controller.phase != ComposerMediaPhase.managingSettings,
              onTap: enabled && !controller.busy ? onUpload : null,
            ),
            DeskButton(
              '表情',
              icon: CupertinoIcons.smiley,
              width: stickerSize.width,
              height: stickerSize.height,
              quiet: true,
              busy: controller.phase == ComposerMediaPhase.choosingSticker,
              onTap: enabled && !controller.busy ? onStickers : null,
            ),
          ],
        ),
      );
    },
  );
}

/// Separate from formatting tools so settings stay reachable in preview mode.
class ComposerImageSettingsButton extends StatelessWidget {
  const ComposerImageSettingsButton({
    required this.controller,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final ComposerMediaController controller;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final size = _toolSize(
        DeskLabelMetrics.of(context, style: DeskTypography.control),
        '图床设置',
        112,
      );
      return DeskButton(
        '图床设置',
        icon: CupertinoIcons.gear,
        width: size.width,
        height: size.height,
        quiet: true,
        onTap: enabled && !controller.busy ? onTap : null,
      );
    },
  );
}

/// Call with the editor's context so toolbar removal cannot orphan the dialog.
Future<String?> showComposerUploadKey(BuildContext context) =>
    showCupertinoDialog<String>(
      context: context,
      builder: (_) => const _ComposerUploadKeyDialog(),
    );

class _ComposerUploadKeyDialog extends StatefulWidget {
  const _ComposerUploadKeyDialog();

  @override
  State<_ComposerUploadKeyDialog> createState() =>
      _ComposerUploadKeyDialogState();
}

class _ComposerUploadKeyDialogState extends State<_ComposerUploadKeyDialog> {
  final input = TextEditingController();
  String? error;

  void save() {
    final validation = nodeImageKeyError(input.text);
    if (validation != null) {
      setState(() => error = validation);
      return;
    }
    Navigator.pop(context, input.text.trim());
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DeskDialog(
    title: '设置 NodeImage 上传密钥',
    icon: CupertinoIcons.lock,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeskInputSurface(
          radius: 8,
          child: CupertinoTextField(
            controller: input,
            decoration: const BoxDecoration(),
            style: TextStyle(color: DeskColors(context).ink),
            placeholderStyle: TextStyle(color: DeskColors(context).secondary),
            placeholder: 'NodeImage API Key',
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => error = null),
            onSubmitted: (_) => save(),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Semantics(liveRegion: true, child: Text(error!)),
        ],
      ],
    ),
    actions: [
      DeskDialogAction('取消', onPressed: () => Navigator.pop(context)),
      DeskDialogAction('保存', isDefaultAction: true, onPressed: save),
    ],
  );
}

Future<ComposerStickerSelection?> showComposerStickerPicker({
  required BuildContext context,
  required AppState state,
  required List<JsonMap> packs,
}) => showCupertinoDialog<ComposerStickerSelection>(
  context: context,
  builder: (_) => ComposerStickerPicker(state: state, packs: packs),
);

/// One stable slot per pane preserves field state, history and scroll positions.
/// Preview is mounted only on its first appearance, then retained offstage.
class ComposerContentViewport extends StatefulWidget {
  const ComposerContentViewport({
    required this.editing,
    required this.editor,
    required this.preview,
    this.split = false,
    super.key,
  });
  final bool editing, split;
  final Widget editor, preview;

  @override
  State<ComposerContentViewport> createState() =>
      _ComposerContentViewportState();
}

class _ComposerContentViewportState extends State<ComposerContentViewport> {
  bool previewMounted = false;
  Size? editorSize, previewSize;

  Widget pane(String name, Rect bounds, bool visible, Widget child) =>
      Positioned(
        key: ValueKey(name),
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(
            enabled: visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: IgnorePointer(
                ignoring: !visible,
                child: Focus(
                  canRequestFocus: false,
                  descendantsAreFocusable: visible,
                  child: ClipRect(child: child),
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.hasBoundedWidth ? constraints.maxWidth : 760.0;
      final height = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : 420.0;
      final full = Offset.zero & Size(width, height);
      final editorVisible = widget.editing || widget.split;
      final previewVisible = !widget.editing || widget.split;
      previewMounted = previewMounted || previewVisible;
      Rect editorBounds = full, previewBounds = full;
      Rect? separator;
      if (widget.split) {
        final horizontal = width >= 760;
        final extent = horizontal ? width : height;
        final gap = extent.clamp(0.0, 14.0);
        final half = (extent - gap) / 2;
        if (horizontal) {
          editorBounds = Rect.fromLTWH(0, 0, half, height);
          previewBounds = Rect.fromLTWH(half + gap, 0, half, height);
          if (gap >= 1) separator = Rect.fromLTWH(half + gap / 2, 0, 1, height);
        } else {
          editorBounds = Rect.fromLTWH(0, 0, width, half);
          previewBounds = Rect.fromLTWH(0, half + gap, width, half);
          if (gap >= 1) separator = Rect.fromLTWH(0, half + gap / 2, width, 1);
        }
      }
      if (editorVisible) editorSize = editorBounds.size;
      if (previewVisible) previewSize = previewBounds.size;
      // Keep a hidden pane's last dimensions: expanding it offstage can clamp
      // its scroll offset before the user returns to the previous mode.
      if (!editorVisible) {
        editorBounds = Offset.zero & (editorSize ?? full.size);
      }
      if (!previewVisible) {
        previewBounds = Offset.zero & (previewSize ?? full.size);
      }
      return sampleEditorBuild(
        kind: UiWorkKind.editorBodyBuild,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              pane(
                'composer-editor-pane',
                editorBounds,
                editorVisible,
                widget.editor,
              ),
              pane(
                'composer-preview-pane',
                previewBounds,
                previewVisible,
                previewMounted ? widget.preview : const SizedBox.shrink(),
              ),
              if (separator != null)
                Positioned.fromRect(
                  rect: separator,
                  child: IgnorePointer(
                    child: ColoredBox(color: DeskColors(context).line),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
