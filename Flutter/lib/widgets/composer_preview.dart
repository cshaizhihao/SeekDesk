import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/official_stickers.dart';
import '../state/app_state.dart';
import 'composer_image_sizing_controller.dart';
import 'composer_sizing_image.dart';
import 'draft_sticker_image.dart';
import 'forum_blocks.dart';
import 'glass_chrome.dart';

/// A stable document widget avoids reparsing on selection and toolbar changes.
class ComposerMarkdownPreview extends StatelessWidget {
  const ComposerMarkdownPreview({
    required this.state,
    required this.controller,
    required this.active,
    this.imageSizing,
    this.imagesEnabled = true,
    super.key,
  });

  final AppState state;
  final TextEditingController controller;
  final bool active;
  final ComposerImageSizingController? imageSizing;
  final bool imagesEnabled;

  @override
  Widget build(BuildContext context) => _ComposerDraftView(
    state: state,
    controller: controller,
    active: active,
    strip: false,
    accessRevision: imageSizing?.revision,
    imageSizing: imageSizing,
    imagesEnabled: imagesEnabled,
  );
}

/// Split and preview modes already display inline stickers. The edit-only
/// strip sits outside the input field, preserving its focus and history.
class ComposerEditorWithStickers extends StatelessWidget {
  const ComposerEditorWithStickers({
    required this.state,
    required this.controller,
    required this.accessRevision,
    required this.active,
    required this.child,
    super.key,
  });

  final AppState state;
  final TextEditingController controller;
  final int accessRevision;
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(child: child),
      ComposerDraftStickerStrip(
        state: state,
        controller: controller,
        accessRevision: accessRevision,
        active: active,
      ),
    ],
  );
}

class ComposerDraftStickerStrip extends StatelessWidget {
  const ComposerDraftStickerStrip({
    required this.state,
    required this.controller,
    required this.accessRevision,
    required this.active,
    super.key,
  });

  final AppState state;
  final TextEditingController controller;
  final int accessRevision;
  final bool active;

  @override
  Widget build(BuildContext context) => _ComposerDraftView(
    state: state,
    controller: controller,
    active: active,
    strip: true,
    accessRevision: accessRevision,
  );
}

class _ComposerDraftView extends StatefulWidget {
  const _ComposerDraftView({
    required this.state,
    required this.controller,
    required this.active,
    required this.strip,
    this.accessRevision,
    this.imageSizing,
    this.imagesEnabled = true,
  });

  final AppState state;
  final TextEditingController controller;
  final bool active, strip, imagesEnabled;
  final int? accessRevision;
  final ComposerImageSizingController? imageSizing;

  @override
  State<_ComposerDraftView> createState() => _ComposerDraftViewState();
}

class _ComposerDraftViewState extends State<_ComposerDraftView> {
  final scroll = ScrollController();
  Timer? debounce;
  late String observedText;
  late int ownerRevision, observedRevision;
  int requestGeneration = 0;
  bool catalogReady = false, catalogLoading = false, catalogFailed = false;
  OfficialStickerCatalog catalog = OfficialStickerCatalog.empty;
  String? renderedText;
  OfficialStickerCatalog? renderedCatalog;
  AppState? renderedState;
  Widget? document;
  List<OfficialSticker> occurrences = const [];

  bool get current => ownerRevision == widget.state.accessRevision;
  bool get active => widget.active && current;

  @override
  void initState() {
    super.initState();
    ownerRevision = widget.accessRevision ?? widget.state.accessRevision;
    observedRevision = widget.state.accessRevision;
    observedText = widget.controller.text;
    widget.controller.addListener(_changed);
    widget.state.addListener(_accessChanged);
    if (active) _updateDocument();
  }

  @override
  void didUpdateWidget(covariant _ComposerDraftView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = oldWidget.controller != widget.controller;
    final stateChanged = oldWidget.state != widget.state;
    final ownerChanged =
        controllerChanged ||
        stateChanged ||
        oldWidget.accessRevision != widget.accessRevision;
    if (controllerChanged) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      observedText = widget.controller.text;
    }
    if (stateChanged) {
      oldWidget.state.removeListener(_accessChanged);
      widget.state.addListener(_accessChanged);
    }
    if (ownerChanged) {
      requestGeneration++;
      ownerRevision = widget.accessRevision ?? widget.state.accessRevision;
      observedRevision = widget.state.accessRevision;
      catalog = OfficialStickerCatalog.empty;
      catalogReady = catalogLoading = catalogFailed = false;
      renderedText = null;
      renderedCatalog = null;
      document = null;
      occurrences = const [];
    }
    if (!active) {
      debounce?.cancel();
      debounce = null;
    } else if (!oldWidget.active ||
        ownerChanged ||
        oldWidget.strip != widget.strip) {
      debounce?.cancel();
      debounce = null;
      _updateDocument();
    }
  }

  void _accessChanged() {
    final revision = widget.state.accessRevision;
    if (revision == observedRevision) return;
    observedRevision = revision;
    requestGeneration++;
    debounce?.cancel();
    debounce = null;
    if (!mounted) return;
    setState(() {
      catalogLoading = catalogFailed = false;
      // Never adopt a new account's image permission for an expired document.
    });
  }

  void _changed() {
    final text = widget.controller.text;
    if (observedText == text) return;
    observedText = text;
    debounce?.cancel();
    debounce = null;
    if (!active) return;
    debounce = Timer(const Duration(milliseconds: 120), () {
      debounce = null;
      if (mounted && active) setState(_updateDocument);
    });
  }

  void _ensureCatalog({bool retry = false}) {
    if (!active ||
        catalogReady ||
        catalogLoading ||
        catalogFailed && !retry ||
        !hasDraftStickerCandidates(widget.controller.text)) {
      return;
    }
    catalogLoading = true;
    final generation = ++requestGeneration;
    final state = widget.state;
    final controller = widget.controller;
    bool accepts() =>
        mounted &&
        current &&
        generation == requestGeneration &&
        identical(state, widget.state) &&
        identical(controller, widget.controller);
    unawaited(() async {
      try {
        final result = await state.loadOfficialStickers();
        if (!accepts()) return;
        catalog = result;
        catalogReady = true;
        catalogLoading = false;
        catalogFailed = false;
        if (active) setState(_updateDocument);
      } catch (_) {
        if (!accepts()) return;
        catalogLoading = false;
        catalogFailed = true;
        if (active) setState(() {});
      }
    }());
  }

  void _updateDocument() {
    final text = widget.controller.text;
    observedText = text;
    _ensureCatalog();
    if (renderedText == text &&
        identical(renderedState, widget.state) &&
        identical(renderedCatalog, catalog)) {
      return;
    }
    renderedText = text;
    renderedState = widget.state;
    renderedCatalog = catalog;
    if (widget.strip) {
      occurrences = catalogReady && hasDraftStickerCandidates(text)
          ? draftStickerOccurrences(parseDraftMarkdown(text, stickers: catalog))
          : const [];
    } else {
      document = MarkdownDocument(
        state: widget.state,
        text: text,
        stickers: catalog,
      );
    }
  }

  void _retry() {
    if (!active || catalogLoading) return;
    setState(() {
      _ensureCatalog(retry: true);
    });
  }

  Widget _error(BuildContext context) => TextFieldTapRegion(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '表情预览暂不可用',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DeskColors(context).secondary,
                fontSize: 12,
              ),
            ),
          ),
          DeskButton(
            '重试',
            width: 56,
            height: 28,
            busy: catalogLoading,
            onTap: active ? _retry : null,
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    requestGeneration++;
    debounce?.cancel();
    widget.controller.removeListener(_changed);
    widget.state.removeListener(_accessChanged);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showError = catalogFailed && hasDraftStickerCandidates(observedText);
    final Widget child;
    if (widget.strip) {
      if (!active || occurrences.isEmpty && !showError) {
        return const SizedBox.shrink();
      }
      final colors = DeskColors(context);
      child = showError
          ? _error(context)
          : TextFieldTapRegion(
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.line)),
                ),
                child: Row(
                  children: [
                    Text(
                      '表情预览',
                      style: TextStyle(color: colors.secondary, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListView.separated(
                        controller: scroll,
                        scrollDirection: Axis.horizontal,
                        itemCount: occurrences.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 5),
                        itemBuilder: (context, index) {
                          final item = occurrences[index];
                          return Center(
                            child: DraftStickerImage(
                              state: widget.state,
                              url: item.url,
                              label: item.label,
                              code: item.code,
                              size: 28,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
    } else {
      child = SingleChildScrollView(
        controller: scroll,
        primary: false,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
        padding: const EdgeInsets.all(16),
        child: ComposerImageSizingScope(
          controller: widget.imageSizing,
          enabled: widget.imagesEnabled && active,
          accessRevision: ownerRevision,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showError) _error(context),
              document ?? const SizedBox.shrink(),
            ],
          ),
        ),
      );
    }
    return DraftStickerImageScope(
      accessRevision: ownerRevision,
      active: active,
      child: child,
    );
  }
}
