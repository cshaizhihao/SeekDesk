import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/document_history.dart';
import '../core/markdown_edit.dart';
import '../core/native_client.dart';
import '../state/app_state.dart';
import 'composer_image_sizing_controller.dart';
import 'composer_media.dart';
import 'composer_media_controller.dart';
import 'composer_paste_scope.dart';
import 'composer_preview.dart';
import 'document_history_scope.dart';
import 'glass_chrome.dart';
import 'forum_blocks.dart';
import 'markdown_editor_controls.dart';
import 'markdown_toolbar.dart';
import 'node_image_settings.dart';
import 'reader_markdown_workspace.dart';

/// A parent-owned navigation gate for the currently mounted private document.
///
/// Call [flush] before changing recipient/category or detaching the draft. An
/// unmounted, not-yet-acquired or retired document has nothing it can write.
/// A current document with unfinished work returns false, so the parent can
/// keep its current conversation visible.
class InboxComposerNavigationGuard {
  Object? _owner, _lease;
  Future<bool> Function()? _flushDocument;

  void _bind(Object owner, Future<bool> Function() flush) {
    _owner = owner;
    _lease = Object();
    _flushDocument = flush;
  }

  void _unbind(Object owner) {
    // A replacement document can mount before the old element is disposed.
    // The old document must never clear its successor's navigation gate.
    if (!identical(_owner, owner)) return;
    _owner = _lease = null;
    _flushDocument = null;
  }

  Future<bool> flush() async {
    final flush = _flushDocument, lease = _lease;
    if (flush == null) return true;
    try {
      final saved = await flush();
      return saved && identical(lease, _lease);
    } catch (_) {
      // The document/parent retains its error feedback and draft. Navigation
      // must not convert an unsuccessful save into a successful departure.
      return false;
    }
  }
}

/// The parent owns the shared private draft and the actual send operation.
/// This widget owns only its mounted document's history, focus and media work.
/// Changing account, recipient or controller retires that entire document.
class InboxComposer extends StatelessWidget {
  const InboxComposer({
    required this.state,
    required this.controller,
    required this.peer,
    required this.revision,
    required this.enabled,
    required this.sending,
    required this.markdown,
    required this.onMarkdownChanged,
    required this.onChanged,
    required this.onSend,
    required this.flushDraft,
    this.snapshot = const {},
    this.synchronizeDraft,
    this.isCurrent,
    this.navigationGuard,
    this.maxHeight = 360,
    super.key,
  });

  final AppState state;
  final TextEditingController controller;
  final int peer, revision;
  final bool enabled, sending, markdown;
  final ValueChanged<bool> onMarkdownChanged;

  /// Actual local edits only, including history and media. External controller
  /// synchronization is not echoed back as another edit.
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final Future<bool> Function() flushDraft;
  final JsonMap snapshot;

  /// Optional authoritative read after flushing, used to confirm image sizes.
  /// It must return this peer's draft (content/draft, imageSizing, imageURLs).
  /// No controller text is assigned from the result.
  final Future<JsonMap?> Function()? synchronizeDraft;

  /// Parent ownership check, including navigation before the next rebuild.
  final bool Function()? isCurrent;
  final InboxComposerNavigationGuard? navigationGuard;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => _InboxDocument(
    key: ValueKey((state, controller, peer, revision)),
    configuration: this,
  );
}

class _InboxDocument extends StatefulWidget {
  const _InboxDocument({required this.configuration, super.key});
  final InboxComposer configuration;

  @override
  State<_InboxDocument> createState() => _InboxDocumentState();
}

class _InboxDocumentState extends State<_InboxDocument> {
  InboxComposer get config => widget.configuration;
  final focus = FocusNode();
  late final _InboxHistory history;
  late ComposerMediaController media;
  late ComposerImageSizingController sizing;
  late String observedText, reportedText;
  int mode = 0, textGeneration = 0, pasteOwnerGeneration = 0;
  bool preparingSend = false, observedComposition = false;
  late bool acquiredDocument;
  String? feedback;

  bool get current =>
      mounted &&
      config.peer > 0 &&
      config.revision == config.state.accessRevision &&
      (config.isCurrent?.call() ?? true);
  bool get routeCurrent => ModalRoute.of(context)?.isCurrent ?? true;
  bool get writable =>
      current && config.enabled && !config.sending && !preparingSend;
  bool get canEdit => writable && mode != 2 && routeCurrent;
  bool get canCommand =>
      canEdit && !media.busy && !sizing.busy && !history.isComposing;
  bool get canFormat => canCommand && config.markdown;

  @override
  void initState() {
    super.initState();
    acquiredDocument = current;
    observedText = reportedText = config.controller.text;
    history = _InboxHistory(
      controller: config.controller,
      canApply: () => canEdit && !history.isComposing,
      canNavigate: () => canCommand,
      onEdited: _reportEdit,
    );
    media = _createMedia();
    sizing = _createSizing();
    config.controller.addListener(_contentChanged);
    focus.addListener(_focusChanged);
    config.state.addListener(_accessChanged);
    config.state.registerDraftFlusher(this, _flush);
    config.navigationGuard?._bind(this, _flush);
  }

  ComposerImageSizingController _createSizing() {
    final controller = ComposerImageSizingController(
      state: config.state,
      content: config.controller,
      revision: config.revision,
      isCurrent: () => current,
      canChange: () =>
          writable && config.markdown && !media.busy && !history.isComposing,
      synchronize: _synchronize,
      saveSize: (url, ratio, width, expectedContent) async {
        if (!current || config.controller.text != expectedContent) return null;
        final result = await config.state.client.call('inbox.setImageSize', {
          'peer': config.peer,
          'expectedContent': expectedContent,
          'url': url,
          'ratio': ratio,
          'previewWidth': width,
        });
        return current ? _normalizeSnapshot(result) : null;
      },
      validateSnapshot: (value) => value['peer'] == config.peer,
      onEdited: () {},
    );
    final initial = _normalizeSnapshot(config.snapshot);
    if (initial != null) controller.acceptSnapshot(initial);
    return controller..addListener(_refresh);
  }

  void _acquireDocumentIfReady() {
    if (acquiredDocument || !current) return;
    acquiredDocument = true;
    // The loading shell may have exhausted its initial reference-read timer
    // before a draft existed. No local size edits were possible in that shell.
    // Start a fresh read and accept the now-authoritative draft snapshot.
    sizing.removeListener(_refresh);
    sizing.dispose();
    sizing = _createSizing();
  }

  ComposerMediaController _createMedia() => ComposerMediaController(
    state: config.state,
    content: config.controller,
    revision: config.revision,
    documentIdentity: (
      config.state,
      config.controller,
      config.peer,
      config.revision,
    ),
    canStart: () =>
        writable && routeCurrent && !sizing.busy && !history.isComposing,
    applyEdit: (value) {
      if (!current) {
        media.invalidate();
        return false;
      }
      final applied = history.apply(value);
      if (applied) {
        revealMarkdownCaret(
          history,
          focusNode: focus,
          isCurrent: () => canEdit,
        );
      }
      return applied;
    },
  )..addListener(_refresh);

  JsonMap? _normalizeSnapshot(JsonMap value) {
    if (value['peer'] != config.peer ||
        value['accessRevision'] != config.revision) {
      return null;
    }
    final text = value['content'] ?? value['draft'];
    if (text is! String) return null;
    return {...value, 'content': text};
  }

  Future<JsonMap?> _synchronize(String expectedContent) async {
    if (!current ||
        !await config.flushDraft() ||
        !current ||
        config.controller.text != expectedContent) {
      return null;
    }
    final value = config.synchronizeDraft == null
        ? config.snapshot
        : await config.synchronizeDraft!();
    if (!current ||
        value == null ||
        config.controller.text != expectedContent) {
      return null;
    }
    final normalized = _normalizeSnapshot(value);
    return normalized?['content'] == expectedContent ? normalized : null;
  }

  @override
  void didUpdateWidget(covariant _InboxDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    _acquireDocumentIfReady();
    final old = oldWidget.configuration;
    if (!identical(old.navigationGuard, config.navigationGuard)) {
      old.navigationGuard?._unbind(this);
      config.navigationGuard?._bind(this, _flush);
    }
    // These transient locks cancel unfinished media, while keeping history and
    // the external controller. Re-enabling starts a fresh media operation lane.
    if ((old.enabled && !config.enabled) ||
        (!old.sending && config.sending) ||
        old.markdown != config.markdown) {
      pasteOwnerGeneration++;
      media.removeListener(_refresh);
      media.dispose();
      media = _createMedia();
    }
    if (old.markdown != config.markdown && !config.markdown) mode = 0;
    if (!identical(old.snapshot, config.snapshot)) {
      final incoming = _normalizeSnapshot(config.snapshot);
      if (incoming != null) sizing.acceptSnapshot(incoming);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _focusChanged() => pasteOwnerGeneration++;

  void _pastePlain() {
    if (!canCommand || !focus.hasFocus) return;
    final owner = media, generation = pasteOwnerGeneration;
    unawaited(
      owner.pasteTextOnly(
        requestText: () async =>
            (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        canPasteText: () =>
            canEdit &&
            !config.markdown &&
            focus.hasFocus &&
            generation == pasteOwnerGeneration &&
            identical(owner, media),
      ),
    );
  }

  void _accessChanged() {
    _acquireDocumentIfReady();
    if (!current) {
      // A first-load shell does not own a draft yet. AppState's ordinary
      // loading notifications must not permanently retire its media lane.
      if (acquiredDocument || config.revision != config.state.accessRevision) {
        media.invalidate();
      }
      focus.unfocus();
    }
    _refresh();
  }

  void _contentChanged() {
    final text = config.controller.text;
    final composing = history.isComposing;
    if (text != observedText) {
      final generation = ++textGeneration;
      observedText = text;
      // TextField.onChanged runs after controller listeners. At the microtask
      // boundary both platform edits and explicit history transactions have
      // reported their value. Other changes came from the shared draft owner.
      scheduleMicrotask(() {
        if (!mounted || generation != textGeneration) return;
        if (reportedText != config.controller.text) {
          reportedText = config.controller.text;
          history.reset();
        }
      });
      _refresh();
    } else if (composing != observedComposition) {
      _refresh();
    }
    observedComposition = composing;
  }

  void _reportEdit() {
    final text = config.controller.text;
    reportedText = text;
    if (current && config.enabled && !config.sending) config.onChanged(text);
  }

  void _format(MarkdownCommand command) {
    if (!canFormat) return;
    final applied = history.execute((value) {
      final source =
          value.selection == const TextSelection.collapsed(offset: -1)
          ? value.copyWith(
              selection: TextSelection.collapsed(offset: value.text.length),
            )
          : value;
      return applyMarkdownCommand(source, command) ?? value;
    });
    if (!applied) return;
    focus.requestFocus();
    revealMarkdownCaret(history, focusNode: focus, isCurrent: () => canFormat);
  }

  void _revealHistoryCaret() => revealMarkdownCaret(
    history,
    focusNode: focus,
    isCurrent: () => canCommand,
    allowUnfocused: true,
  );

  void _changeMode(int next) {
    if (!writable ||
        !routeCurrent ||
        media.busy ||
        sizing.busy ||
        history.isComposing ||
        next == mode) {
      return;
    }
    history.commitTyping();
    pasteOwnerGeneration++;
    if (next == 2) focus.unfocus();
    setState(() => mode = next);
  }

  void _changeMarkdown() {
    if (!writable ||
        !routeCurrent ||
        media.busy ||
        sizing.busy ||
        history.isComposing) {
      return;
    }
    history.commitTyping();
    config.onMarkdownChanged(!config.markdown);
  }

  Future<bool> _flush() async {
    // A loading/failed conversation has not acquired a shared draft yet. An
    // expired account likewise no longer owns a writable draft. Neither shell
    // should trap the user on this page. This is only an entry-time exemption:
    // an operation that starts current must remain current after every await.
    if (!current) return true;
    bool available() =>
        current &&
        !history.isComposing &&
        !media.busy &&
        !config.sending &&
        !preparingSend;
    while (available() && !sizing.busy) {
      final generation = textGeneration, markdown = config.markdown;
      if (!await sizing.flush() ||
          !available() ||
          sizing.busy ||
          sizing.hasPendingChanges ||
          !await config.flushDraft() ||
          !available() ||
          sizing.busy ||
          sizing.hasPendingChanges) {
        return false;
      }
      // The shared owner can drain edits typed during a pending save. Confirm
      // its latest state instead of rejecting a successful navigation. Owners
      // that save one snapshot at a time also get a chance to save the new text.
      if (generation == textGeneration && markdown == config.markdown) {
        return true;
      }
    }
    return false;
  }

  Future<void> _send() async {
    if (!writable ||
        !routeCurrent ||
        media.busy ||
        sizing.busy ||
        history.isComposing ||
        config.controller.text.trim().isEmpty) {
      return;
    }
    final text = config.controller.text, markdown = config.markdown;
    setState(() {
      preparingSend = true;
      feedback = null;
    });
    try {
      if (!await sizing.flush() ||
          !current ||
          !await config.flushDraft() ||
          !current) {
        return;
      }
      if (config.controller.text != text || config.markdown != markdown) {
        feedback = '草稿已在其他窗口更新，请检查内容后再发送。';
        return;
      }
      if (!config.enabled ||
          config.sending ||
          !routeCurrent ||
          history.isComposing) {
        return;
      }
      config.onSend();
    } catch (_) {
      if (current) feedback = '草稿尚未同步，内容已保留，请稍后重试。';
    } finally {
      // Keep same-turn stale button/keyboard callbacks locked until the parent
      // has had a frame to publish its own sending state.
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => preparingSend = false);
        });
        setState(() {});
      }
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!current || !focus.hasFocus || !routeCurrent) {
      return KeyEventResult.ignored;
    }
    if (markdownCompositionKey(history, event)) {
      return KeyEventResult.skipRemainingHandlers;
    }
    final keyboard = HardwareKeyboard.instance;
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter &&
        keyboard.isMetaPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isControlPressed) {
      if (event is KeyDownEvent) unawaited(_send());
      return KeyEventResult.handled;
    }
    if (!canFormat) return KeyEventResult.ignored;
    final command = markdownShortcut(event);
    if (command != null) {
      _format(command);
      return KeyEventResult.handled;
    }
    return applyMarkdownTypingKey(
          history,
          event,
          focusNode: focus,
          isCurrent: () => canFormat,
        )
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  Widget _editor(DeskColors colors) => ComposerContentViewport(
    editing: mode != 2,
    split: mode == 1,
    editor: ComposerEditorWithStickers(
      state: config.state,
      controller: config.controller,
      accessRevision: config.revision,
      active: current && config.markdown && mode == 0,
      child: DocumentHistoryScope(
        history: history,
        onHistoryApplied: _revealHistoryCaret,
        enabled: canCommand,
        child: ComposerPasteScope(
          media: media,
          bodyFocus: focus,
          enabled: canEdit,
          imageDropEnabled: config.markdown,
          requestKey: () => showComposerUploadKey(context),
          child: Actions(
            actions: {
              if (!config.markdown)
                PasteTextIntent: CallbackAction<PasteTextIntent>(
                  onInvoke: (_) {
                    _pastePlain();
                    return null;
                  },
                ),
            },
            child: Focus(
              onKeyEvent: _key,
              child: CupertinoTextField(
                key: const ValueKey('inbox-composer-body'),
                controller: config.controller,
                focusNode: focus,
                onChanged: (_) => _reportEdit(),
                // Plain mode uses the normal text-only paste path. It never
                // starts a surprise image upload from a Markdown-disabled field.
                contextMenuBuilder: config.markdown
                    ? ComposerPasteScope.contextMenuBuilder
                    : (context, editable) =>
                          CupertinoAdaptiveTextSelectionToolbar.editableText(
                            editableTextState: editable,
                          ),
                selectAllOnFocus: false,
                readOnly: !writable,
                placeholder: '写私信…',
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                padding: const EdgeInsets.all(12),
                style: TextStyle(color: colors.ink, fontSize: 14, height: 1.55),
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    preview: config.markdown
        ? ComposerMarkdownPreview(
            state: config.state,
            controller: config.controller,
            active: current && mode != 0,
            imageSizing: sizing,
            imagesEnabled: writable && !media.busy && !sizing.busy,
          )
        : ValueListenableBuilder<TextEditingValue>(
            valueListenable: config.controller,
            builder: (context, value, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: ForumTextSelection(
                child: Text(
                  value.text,
                  style: TextStyle(color: colors.ink, fontSize: 14),
                ),
              ),
            ),
          ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final available = writable && !media.busy && !sizing.busy;
    final message = feedback ?? sizing.feedback ?? media.feedback;
    return LayoutBuilder(
      builder: (context, bounds) {
        final preferred = math.min(
          config.maxHeight,
          MediaQuery.sizeOf(context).height * .42,
        );
        final height = bounds.hasBoundedHeight
            ? math.min(bounds.maxHeight, preferred)
            : preferred;
        return SizedBox(
          key: const ValueKey('inbox-composer-panel'),
          height: math.max(0.0, height),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.paper,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ReaderMarkdownWorkspace(
                    minimumEditorHeight: mode == 1 ? 220 : 108,
                    heading: const SizedBox.shrink(),
                    header: [
                      ReaderMarkdownControlRow(
                        child: MarkdownEditorControls(
                          mode: mode,
                          onModeChanged: _changeMode,
                          history: history,
                          onHistoryApplied: _revealHistoryCaret,
                          enabled: available,
                          trailing: ComposerImageSettingsButton(
                            controller: media,
                            enabled: available && config.markdown,
                            onTap: () {
                              if (!writable ||
                                  !routeCurrent ||
                                  media.busy ||
                                  sizing.busy ||
                                  history.isComposing ||
                                  !config.markdown) {
                                return;
                              }
                              unawaited(
                                media.manageSettings(
                                  presentSettings: () => showNodeImageSettings(
                                    context,
                                    config.state,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ReaderMarkdownControlRow(
                        child: MarkdownToolbar(
                          enabled: canFormat,
                          onCommand: _format,
                          trailing: ComposerMediaTools(
                            controller: media,
                            enabled: canFormat,
                            onUpload: () {
                              if (canFormat) {
                                unawaited(
                                  media.upload(
                                    requestKey: () =>
                                        showComposerUploadKey(context),
                                  ),
                                );
                              }
                            },
                            onStickers: () {
                              if (!canFormat) return;
                              unawaited(
                                media.chooseSticker(
                                  requestKey: () =>
                                      showComposerUploadKey(context),
                                  presentPicker: (packs) =>
                                      showComposerStickerPicker(
                                        context: context,
                                        state: config.state,
                                        packs: packs,
                                      ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                    editor: _editor(colors),
                    footer: const SizedBox.shrink(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message != null) ...[
                        ConstrainedBox(
                          key: const ValueKey('inbox-composer-status'),
                          constraints: BoxConstraints(
                            maxHeight: math.max(0.0, height * .25),
                          ),
                          child: SingleChildScrollView(
                            primary: false,
                            child: Text(
                              message,
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.end,
                        children: [
                          DeskButton(
                            config.markdown ? 'Markdown 开启' : '纯文本',
                            key: const ValueKey('inbox-composer-markdown'),
                            width: 140,
                            quiet: true,
                            icon: config.markdown
                                ? CupertinoIcons.check_mark_circled
                                : CupertinoIcons.textformat,
                            onTap: available && !history.isComposing
                                ? _changeMarkdown
                                : null,
                          ),
                          if (bounds.maxWidth >= 420)
                            Text(
                              '⌘↩ 发送',
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 11,
                              ),
                            ),
                          DeskButton(
                            '发送',
                            key: const ValueKey('inbox-composer-send'),
                            icon: CupertinoIcons.paperplane,
                            tint: CupertinoColors.systemGreen,
                            busy: config.sending || preparingSend,
                            onTap:
                                available &&
                                    !history.isComposing &&
                                    config.controller.text.trim().isNotEmpty
                                ? () => unawaited(_send())
                                : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    config.navigationGuard?._unbind(this);
    config.state.unregisterDraftFlusher(this);
    config.state.removeListener(_accessChanged);
    config.controller.removeListener(_contentChanged);
    media.removeListener(_refresh);
    media.dispose();
    sizing.removeListener(_refresh);
    sizing.dispose();
    history.dispose();
    focus.removeListener(_focusChanged);
    focus.dispose();
    super.dispose();
  }
}

/// Report only explicit history transactions. The external controller can also
/// receive a shared draft refresh, which must never be replayed as a local edit.
class _InboxHistory extends DocumentHistory {
  _InboxHistory({
    required super.controller,
    required this.canApply,
    required this.canNavigate,
    required this.onEdited,
  });
  final bool Function() canApply, canNavigate;
  final VoidCallback onEdited;

  bool _record(bool Function() edit) {
    final before = controller.text;
    final result = edit();
    if (result && before != controller.text) onEdited();
    return result;
  }

  @override
  bool runAtomic(VoidCallback edit) =>
      canApply() && _record(() => super.runAtomic(edit));
  @override
  bool undo() => canNavigate() && _record(super.undo);
  @override
  bool redo() => canNavigate() && _record(super.redo);
}
