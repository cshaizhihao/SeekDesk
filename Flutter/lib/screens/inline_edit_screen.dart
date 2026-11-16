import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/native_client.dart';
import '../core/document_history.dart';
import '../core/markdown_edit.dart';
import '../core/reader_editor_binding.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/desk_input_surface.dart';
import '../widgets/document_history_scope.dart';
import '../widgets/markdown_toolbar.dart';
import '../widgets/markdown_editor_controls.dart';
import '../widgets/composer_media.dart';
import '../widgets/composer_preview.dart';
import '../widgets/composer_media_controller.dart';
import '../widgets/node_image_settings.dart';
import '../widgets/composer_image_sizing_controller.dart';
import '../widgets/composer_paste_scope.dart';
import '../widgets/reader_markdown_workspace.dart';

class InlineEditScreen extends StatelessWidget {
  const InlineEditScreen({
    required this.state,
    required this.url,
    required this.topicID,
    required this.floor,
    this.binding,
    super.key,
  });
  final AppState state;
  final String url, topicID;
  final int floor;
  final ReaderEditorBinding? binding;

  @override
  Widget build(BuildContext context) => _InlineEditScreenDocument(
    key: ValueKey((state, topicID, url, floor, binding?.accessRevision)),
    state: state,
    topicID: topicID,
    url: url,
    floor: floor,
    binding: binding,
  );
}

// A target change creates a fresh owner. Pending media and draft completions
// remain bound to the old owner instead of following a reused route widget.
class _InlineEditScreenDocument extends StatefulWidget {
  const _InlineEditScreenDocument({
    required this.state,
    required this.url,
    required this.topicID,
    required this.floor,
    this.binding,
    super.key,
  });
  final AppState state;
  final String url, topicID;
  final int floor;
  final ReaderEditorBinding? binding;
  @override
  State<_InlineEditScreenDocument> createState() => _InlineEditScreenState();
}

class _InlineEditScreenState extends State<_InlineEditScreenDocument> {
  final title = TextEditingController(), content = TextEditingController();
  final contentFocus = FocusNode();
  late final ComposerMediaController media;
  late final DocumentHistory history;
  late final ComposerImageSizingController imageSizing;
  (bool, bool, String?)? imageSizingStatus;
  String lastTitle = '', lastContent = '';
  bool _lastComposing = false;
  bool _comparisonAllowed = true;
  JsonMap data = {};
  bool loading = false, saving = false, dirty = false;
  bool closing = false, openingVerification = false, continuing = false;
  bool editorLoaded = false, needsVerification = false, invalidSession = false;
  bool _beginAttempted = false, _documentClosed = false;
  String? editToken, statusMessage;
  int mode = 0, revision = 0;
  bool get busy =>
      saving ||
      closing ||
      openingVerification ||
      continuing ||
      imageSizing.busy;
  bool get current => mounted && revision == widget.state.accessRevision;
  bool get active => widget.binding?.active ?? true;
  bool get validSession =>
      current && !_documentClosed && !invalidSession && editToken != null;
  JsonMap get args => {
    'topicID': widget.topicID,
    'url': widget.url,
    'floor': widget.floor,
  };
  JsonMap tokenArgs(String token) => {...args, 'editToken': token};
  @override
  void initState() {
    super.initState();
    revision = widget.binding?.accessRevision ?? widget.state.accessRevision;
    history = DocumentHistory(controller: content);
    imageSizing = ComposerImageSizingController(
      state: widget.state,
      content: content,
      revision: revision,
      isCurrent: () => validSession,
      canChange: () =>
          active &&
          validSession &&
          editorLoaded &&
          !loading &&
          !busy &&
          !media.busy &&
          !history.isComposing,
      synchronize: _synchronizeImageSizing,
      saveSize: (url, ratio, previewWidth, expectedContent) async {
        final token = editToken;
        if (token == null || !sameOperation(token)) return null;
        final result = await widget.state.act('reader.edit.setImageSize', {
          ...tokenArgs(token),
          'url': url,
          'ratio': ratio,
          'previewWidth': previewWidth,
          'expectedContent': expectedContent,
        });
        if (!sameOperation(token)) return null;
        if (result != null && !acceptSnapshot(result, token)) return null;
        return result;
      },
      validateSnapshot: (snapshot) =>
          editToken != null && tokenFrom(snapshot) == editToken,
      onEdited: () {
        if (mounted) setState(() => dirty = true);
      },
    )..addListener(_imageSizingChanged);
    media = ComposerMediaController(
      state: widget.state,
      content: content,
      applyEdit: _applyMediaEdit,
      revision: revision,
      documentIdentity: (
        widget.state,
        widget.topicID,
        widget.url,
        widget.floor,
      ),
      canStart: () =>
          active && validSession && editorLoaded && !loading && !busy,
    )..addListener(_mediaChanged);
    widget.state.registerDraftFlusher(
      this,
      () async => !dirty && !_operationBusy(),
    );
    _bind(widget.binding);
    if (widget.binding == null) {
      load();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(load());
      });
    }
  }

  void _bind(ReaderEditorBinding? binding) {
    if (binding == null) return;
    binding.requestClose = close;
    binding.prepareForTabClose = _prepareForTabClose;
    binding.operationBusy = _operationBusy;
    binding.addListener(_bindingChanged);
  }

  void _unbind(ReaderEditorBinding? binding) {
    if (binding == null) return;
    binding.removeListener(_bindingChanged);
    if (binding.requestClose == close) binding.requestClose = null;
    if (binding.prepareForTabClose == _prepareForTabClose) {
      binding.prepareForTabClose = null;
    }
    if (binding.operationBusy == _operationBusy) binding.operationBusy = null;
  }

  bool get _isComposing =>
      history.isComposing ||
      (title.value.composing.isValid && !title.value.composing.isCollapsed);

  bool _operationBusy() => busy || loading || media.busy || _isComposing;

  Future<bool> _prepareForTabClose() async {
    // Tab closure must not silently discard a retained document or open a
    // discard dialog for an editor which is currently hidden in another tab.
    if (dirty || _operationBusy()) return false;
    return _closeDocument(confirmDiscard: false);
  }

  void _bindingChanged() {
    if (!mounted) return;
    setState(() {});
    if (active && !_beginAttempted && !_documentClosed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && active && !_beginAttempted) unawaited(load());
      });
    }
  }

  @override
  void didUpdateWidget(covariant _InlineEditScreenDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      _unbind(oldWidget.binding);
      _bind(widget.binding);
      _bindingChanged();
    }
  }

  String? tokenFrom(JsonMap snapshot) {
    final token = snapshot['editToken'];
    if (token is! String ||
        token.trim().isEmpty ||
        snapshot['topicID'] != widget.topicID ||
        snapshot['floor'] is! int ||
        snapshot['floor'] != widget.floor ||
        snapshot['accessRevision'] is! int ||
        snapshot['accessRevision'] != revision) {
      return null;
    }
    return token;
  }

  bool sameOperation(String token) => validSession && editToken == token;

  bool acceptSnapshot(JsonMap snapshot, String token) {
    if (!sameOperation(token)) return false;
    if (tokenFrom(snapshot) != token) {
      setState(() {
        invalidSession = true;
        editToken = null;
        statusMessage = '编辑会话已失效。当前修改仍保留，请复制内容后重新打开编辑器。';
      });
      return false;
    }
    return true;
  }

  Future<void> load() async {
    // A loaded document is never re-begun during verification recovery.
    if (!current ||
        !active ||
        _documentClosed ||
        loading ||
        busy ||
        editorLoaded) {
      return;
    }
    _beginAttempted = true;
    title.removeListener(edit);
    content.removeListener(edit);
    setState(() => loading = true);
    final result = await widget.state.act('reader.edit.begin', args);
    if (!mounted) return;
    if (!current) {
      setState(() {
        loading = false;
        data = {'message': '账号已变更，请重新打开编辑器。'};
      });
      return;
    }
    final token = result == null ? null : tokenFrom(result);
    setState(() {
      data = result ?? {'message': '无法读取原始内容，请重试。'};
      loading = false;
      editToken = token;
      invalidSession = false;
      if (result != null && token == null) {
        data = {'message': '未取得有效的编辑会话，请重试。'};
      }
      editorLoaded = token != null && data['ready'] == true;
      if (editorLoaded) {
        title.text = stringValue(data['title']);
        content.text = stringValue(data['content']);
        imageSizing.acceptSnapshot(data);
        history.reset();
        lastTitle = title.text;
        lastContent = content.text;
        _lastComposing = _isComposing;
        needsVerification = data['needsVerification'] == true;
        statusMessage = needsVerification ? stringValue(data['message']) : null;
        dirty = false;
      }
    });
    title.addListener(edit);
    content.addListener(edit);
  }

  void edit() {
    final textChanged = lastTitle != title.text || lastContent != content.text;
    final composing = _isComposing;
    if (!textChanged && _lastComposing == composing) return;
    lastTitle = title.text;
    lastContent = content.text;
    _lastComposing = composing;
    // IME may commit without changing text. Refresh action availability while
    // keeping composition-only transitions separate from document changes.
    if (mounted) {
      setState(() {
        if (textChanged) dirty = true;
      });
    }
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  void _imageSizingChanged() {
    if (!mounted) return;
    final status = (
      imageSizing.busy,
      imageSizing.hasPendingChanges,
      imageSizing.feedback,
    );
    if (status == imageSizingStatus) return;
    imageSizingStatus = status;
    setState(() {});
  }

  Future<JsonMap?> _synchronizeImageSizing(String expectedContent) async {
    final token = editToken;
    if (token == null ||
        !sameOperation(token) ||
        content.text != expectedContent) {
      return null;
    }
    final result = await widget.state.act('reader.edit.update', {
      ...tokenArgs(token),
      'title': title.text,
      'content': expectedContent,
    });
    if (!sameOperation(token) || content.text != expectedContent) return null;
    if (result != null && !acceptSnapshot(result, token)) return null;
    return result;
  }

  void _changeMode(int next) {
    if (!active || busy || mode == next) return;
    // A retired document may return from preview to its read-only source so
    // that the user can copy the retained text before explicitly closing it.
    if (!validSession && next != 0) return;
    if (widget.binding != null && next == 1 && !_comparisonAllowed) {
      widget.state.showMessage('请扩大编辑区后使用对照预览。');
      return;
    }
    if (content.value.composing.isValid &&
        !content.value.composing.isCollapsed) {
      widget.state.showMessage('请先完成当前输入，再切换预览。');
      return;
    }
    history.commitTyping();
    if (next == 2) contentFocus.unfocus();
    setState(() => mode = next);
    if (next != 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && active && mode != 2) {
          contentFocus.requestFocus();
        }
      });
    }
  }

  bool get canFormat =>
      active &&
      validSession &&
      editorLoaded &&
      !loading &&
      !busy &&
      !media.busy &&
      mode != 2 &&
      !_isComposing;

  bool _applyMediaEdit(TextEditingValue value) {
    // A previously started upload may finish while hidden. It still belongs
    // to this document, but must never mutate a retired account/editor token.
    if (!validSession || !editorLoaded || loading || busy) return false;
    if (!history.apply(value)) return false;
    revealMarkdownCaret(
      history,
      focusNode: contentFocus,
      // busy here covers saving/closing/sizing, independently of media.busy.
      isCurrent: () =>
          active &&
          validSession &&
          editorLoaded &&
          !loading &&
          !busy &&
          mode != 2,
    );
    return true;
  }

  void _format(MarkdownCommand command) {
    if (!canFormat) return;
    final applied = history.execute((value) {
      final source =
          value.selection.baseOffset == -1 && value.selection.extentOffset == -1
          ? value.copyWith(
              selection: TextSelection.collapsed(offset: value.text.length),
            )
          : value;
      return applyMarkdownCommand(source, command) ?? value;
    });
    if (!applied) return;
    contentFocus.requestFocus();
    revealMarkdownCaret(
      history,
      focusNode: contentFocus,
      isCurrent: () => canFormat,
    );
  }

  void _revealHistoryCaret() => revealMarkdownCaret(
    history,
    focusNode: contentFocus,
    isCurrent: () => canFormat,
    allowUnfocused: true,
  );

  KeyEventResult _formatKey(FocusNode node, KeyEvent event) {
    if (!active ||
        !contentFocus.hasFocus ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return KeyEventResult.ignored;
    }
    if (markdownCompositionKey(history, event)) {
      return KeyEventResult.skipRemainingHandlers;
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
          focusNode: contentFocus,
          isCurrent: () => canFormat,
        )
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  Future<void> save() async {
    if (!active || _operationBusy() || !validSession || needsVerification) {
      return;
    }
    final token = editToken!;
    final binding = widget.binding;
    final navigation = binding?.navigationIdentity();
    setState(() {
      saving = true;
      statusMessage = null;
    });
    try {
      if (!await imageSizing.flush() || !sameOperation(token)) return;
      final updated = await widget.state.act('reader.edit.update', {
        ...tokenArgs(token),
        'title': title.text,
        'content': content.text,
      });
      if (!sameOperation(token)) return;
      if (updated == null) {
        setState(() => statusMessage = '未能准备保存，当前修改已保留，请重试。');
        return;
      }
      if (!acceptSnapshot(updated, token)) return;
      if (updated['ready'] != true) {
        setState(() => statusMessage = '编辑会话暂时无法保存，当前修改已保留，请重试。');
        return;
      }
      if (updated['needsVerification'] == true) {
        setState(() {
          needsVerification = true;
          statusMessage = stringValue(
            updated['message'],
            '请先完成 NodeSeek 站点验证。',
          );
        });
        return;
      }
      final result = await widget.state.act(
        'reader.edit.save',
        tokenArgs(token),
      );
      if (!mounted || !sameOperation(token)) return;
      if (result == null) {
        setState(() => statusMessage = '未收到保存结果，当前修改已保留，请确认站点状态后重试。');
        return;
      }
      if (!acceptSnapshot(result, token)) return;
      if (result['accepted'] == true) {
        dirty = false;
        _documentClosed = true;
        if (binding != null) {
          binding.submitted(navigation!);
        } else {
          _finishStandaloneRoute();
          widget.state.loadReader(widget.url, force: true);
        }
      } else {
        setState(() {
          data = result;
          needsVerification = result['needsVerification'] == true;
          final message = stringValue(result['message']);
          statusMessage = message.isEmpty ? '修改尚未保存，当前内容已保留，请检查后重试。' : message;
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> openVerification() async {
    if (!active ||
        busy ||
        loading ||
        media.busy ||
        !validSession ||
        !needsVerification) {
      return;
    }
    final token = editToken!;
    setState(() => openingVerification = true);
    try {
      final result = await widget.state.act('session.verify', {
        'url': widget.url,
      });
      if (!sameOperation(token)) return;
      setState(
        () => statusMessage = result == null
            ? '验证窗口未能打开，当前修改已保留，请重试。'
            : '验证窗口已打开。完成后返回这里，点击「验证后继续」。',
      );
      // Opening a window is not proof of verification and never resumes a save.
    } finally {
      if (mounted) setState(() => openingVerification = false);
    }
  }

  Future<void> continueVerification() async {
    if (!active ||
        busy ||
        loading ||
        media.busy ||
        !validSession ||
        !needsVerification) {
      return;
    }
    final token = editToken!;
    setState(() => continuing = true);
    try {
      final result = await widget.state.act(
        'reader.edit.continueVerification',
        tokenArgs(token),
      );
      if (!sameOperation(token)) return;
      if (result == null) {
        setState(() => statusMessage = '暂时无法恢复保存入口，当前修改已保留，请重试。');
        return;
      }
      if (!acceptSnapshot(result, token)) return;
      setState(() {
        data = result;
        needsVerification =
            result['ready'] != true || result['needsVerification'] != false;
        statusMessage = needsVerification
            ? stringValue(result['message'], '请完成站点验证后再继续。')
            : '当前修改已保留，请点击「保存修改」再次提交。';
      });
      // Never copy native title/content over edits made while the window was open.
      // The next explicit save sends the latest local fields through edit.update.
    } finally {
      if (mounted) setState(() => continuing = false);
    }
  }

  Future<void> close() async {
    if (!mounted || _documentClosed) return;
    final route = widget.binding == null ? ModalRoute.of(context) : null;
    if (widget.binding == null && route?.isCurrent != true) return;
    await _closeDocument(ownerRoute: route);
  }

  void _finishStandaloneRoute([ModalRoute<dynamic>? ownerRoute]) {
    if (!mounted) return;
    final route = ownerRoute ?? ModalRoute.of(context);
    final navigator = route?.navigator;
    if (route == null ||
        navigator == null ||
        !navigator.mounted ||
        !route.isActive) {
      return;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // Cancellation/save already succeeded for this document. Retire its
      // own route while leaving any later covering route and its focus alone.
      navigator.removeRoute(route);
    }
  }

  Future<bool> _closeDocument({
    bool confirmDiscard = true,
    ModalRoute<dynamic>? ownerRoute,
  }) async {
    if (_documentClosed) return true;
    if (!mounted || _operationBusy()) return false;
    if (dirty && !confirmDiscard) return false;
    setState(() => closing = true);
    try {
      if (dirty &&
          !await confirmAction(
            context,
            title: '放弃这次修改',
            message: '已编辑的内容尚未保存到 NodeSeek。',
            accept: '放弃修改',
            destructive: true,
          )) {
        return false;
      }
      if (!mounted) return false;
      final token = editToken;
      if (validSession && token != null) {
        try {
          // Keep the native error code here: an old editor can be dismissed
          // locally after confirmation without cancelling its replacement.
          final result = await widget.state.client.call(
            'reader.edit.cancel',
            tokenArgs(token),
          );
          if (!sameOperation(token)) return false;
          if (!acceptSnapshot(result, token)) return false;
        } on NativeFailure catch (error) {
          if (!mounted) return false;
          if (error.code != 'stale_editor') {
            setState(() => statusMessage = '暂时无法结束编辑，当前修改已保留，请重试。');
            return false;
          }
        } catch (_) {
          if (mounted) {
            setState(() => statusMessage = '暂时无法结束编辑，当前修改已保留，请重试。');
          }
          return false;
        }
      }
      if (!mounted) return false;
      _documentClosed = true;
      dirty = false;
      final binding = widget.binding;
      if (binding != null) {
        binding.close();
      } else {
        _finishStandaloneRoute(ownerRoute);
      }
      return true;
    } finally {
      if (mounted) setState(() => closing = false);
    }
  }

  @override
  void dispose() {
    _unbind(widget.binding);
    widget.state.unregisterDraftFlusher(this);
    imageSizing.dispose();
    media.dispose();
    history.dispose();
    title.dispose();
    content.dispose();
    contentFocus.dispose();
    super.dispose();
  }

  Widget verificationNotice(DeskColors colors) => TextFieldTapRegion(
    child: DeskGlassPanel(
      quiet: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '需要完成站点验证',
            style: TextStyle(
              color: colors.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            statusMessage?.trim().isNotEmpty == true
                ? statusMessage!
                : '当前修改已保留。请打开验证窗口，完成后返回这里继续。',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DeskButton(
                '打开验证窗口',
                width: 142,
                icon: CupertinoIcons.arrow_up_right_square,
                busy: openingVerification,
                onTap: active && !busy && !media.busy && validSession
                    ? openVerification
                    : null,
              ),
              DeskButton(
                '验证后继续',
                width: 130,
                icon: CupertinoIcons.arrow_clockwise,
                busy: continuing,
                onTap: active && !busy && !media.busy && validSession
                    ? continueVerification
                    : null,
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _heading(DeskColors colors, {required bool embedded}) => Row(
    children: [
      Expanded(
        child: Text(
          widget.floor == 0 ? '编辑主题' : '编辑第 ${widget.floor} 楼',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.ink,
            fontSize: embedded ? 17 : 23,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      DeskButton(
        '取消编辑',
        width: embedded ? 100 : 108,
        onTap: _operationBusy() ? null : close,
      ),
    ],
  );

  Widget _controlRow(Widget child, {required bool embedded}) =>
      embedded ? ReaderMarkdownControlRow(child: child) : child;

  Widget _documentSurface(
    DeskColors colors,
    String? footerMessage, {
    required bool embedded,
  }) {
    final heading = _heading(colors, embedded: embedded);
    if (loading || !editorLoaded) {
      final placeholder = loading
          ? const Center(child: CupertinoActivityIndicator())
          : DeskEmpty(
              '暂时无法编辑',
              detail: !current
                  ? '账号已变更，请重新打开编辑器。'
                  : stringValue(data['message']),
              action: DeskButton('重试', onTap: active && current ? load : null),
            );
      if (!embedded) return placeholder;
      return ReaderMarkdownWorkspace(
        heading: heading,
        header: const [],
        editor: loading
            ? placeholder
            : SingleChildScrollView(primary: false, child: placeholder),
        footer: const SizedBox.shrink(),
      );
    }
    final interactive = active && validSession && !loading;
    final editingEnabled = interactive && !_operationBusy();
    final header = <Widget>[
      if (widget.floor == 0) ...[
        DeskInputSurface(
          child: CupertinoTextField(
            controller: title,
            enabled: !saving && !closing,
            readOnly: !interactive || saving || closing,
            decoration: const BoxDecoration(),
            placeholder: '帖子标题',
            style: TextStyle(color: colors.ink),
            placeholderStyle: TextStyle(color: colors.secondary),
            padding: EdgeInsets.all(embedded ? 8 : 12),
          ),
        ),
        SizedBox(height: embedded ? 6 : 14),
      ],
      _controlRow(
        MarkdownEditorControls(
          mode: mode,
          onModeChanged: _changeMode,
          history: history,
          onHistoryApplied: _revealHistoryCaret,
          enabled: editingEnabled,
          trailing: ComposerImageSettingsButton(
            controller: media,
            enabled: interactive && !busy,
            onTap: () => media.manageSettings(
              presentSettings: () =>
                  showNodeImageSettings(context, widget.state),
            ),
          ),
        ),
        embedded: embedded,
      ),
      SizedBox(height: embedded ? 4 : 10),
      Offstage(
        offstage: mode == 2,
        child: _controlRow(
          MarkdownToolbar(
            enabled: canFormat,
            onCommand: _format,
            trailing: ComposerMediaTools(
              controller: media,
              enabled: interactive && !busy,
              onUpload: () => media.upload(
                requestKey: () => showComposerUploadKey(context),
              ),
              onStickers: () => media.chooseSticker(
                requestKey: () => showComposerUploadKey(context),
                presentPicker: (packs) => showComposerStickerPicker(
                  context: context,
                  state: widget.state,
                  packs: packs,
                ),
              ),
            ),
          ),
          embedded: embedded,
        ),
      ),
      SizedBox(height: embedded ? 4 : 10),
      if (needsVerification) ...[
        verificationNotice(colors),
        SizedBox(height: embedded ? 6 : 14),
      ],
    ];
    final editor = LayoutBuilder(
      builder: (context, bounds) {
        _comparisonAllowed =
            !embedded ||
            bounds.maxHeight >= (bounds.maxWidth >= 760 ? 110 : 234);
        final visibleMode = mode == 1 && !_comparisonAllowed ? 0 : mode;
        if (visibleMode != mode && !_isComposing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && mode == 1 && !_comparisonAllowed && !_isComposing) {
              setState(() => mode = 0);
            }
          });
        }
        // Keep one viewport tree through resizing and mode changes, retaining
        // its pane keys, text controller, selection, history and focus node.
        return ComposerContentViewport(
          editing: visibleMode != 2,
          split: visibleMode == 1,
          editor: ComposerEditorWithStickers(
            state: widget.state,
            controller: content,
            accessRevision: revision,
            active: visibleMode == 0 && interactive && editorLoaded,
            child: DocumentHistoryScope(
              history: history,
              onHistoryApplied: _revealHistoryCaret,
              enabled: editingEnabled,
              child: ComposerPasteScope(
                media: media,
                bodyFocus: contentFocus,
                enabled:
                    interactive && editorLoaded && !busy && visibleMode != 2,
                requestKey: () => showComposerUploadKey(context),
                child: Focus(
                  onKeyEvent: _formatKey,
                  child: CupertinoTextField(
                    controller: content,
                    focusNode: contentFocus,
                    contextMenuBuilder: ComposerPasteScope.contextMenuBuilder,
                    selectAllOnFocus: false,
                    enabled: !saving && !closing,
                    // A retired account/session keeps its text selectable. Only
                    // mutations are blocked; users may copy it before closing.
                    readOnly: !interactive || saving || closing,
                    minLines: null,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    padding: EdgeInsets.all(embedded ? 10 : 16),
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 15,
                      height: 1.7,
                    ),
                    decoration: BoxDecoration(
                      color: colors.well,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
          preview: ComposerMarkdownPreview(
            state: widget.state,
            controller: content,
            active: visibleMode != 0 && interactive && editorLoaded,
            imageSizing: imageSizing,
            imagesEnabled: editingEnabled,
          ),
        );
      },
    );
    final status = MarkdownStatus(
      !current
          ? '账号已变更，修改已保留，可复制内容后关闭'
          : footerMessage ?? '${content.text.characters.length} 字符 · 修改尚未提交',
    );
    final saveButton = DeskButton(
      '保存修改',
      width: 116,
      tint: CupertinoColors.systemGreen,
      icon: CupertinoIcons.checkmark,
      busy: saving,
      onTap: dirty && editingEnabled && !needsVerification ? save : null,
    );
    final footer = LayoutBuilder(
      builder: (context, bounds) => embedded && bounds.maxWidth < 520
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: saveButton),
              ],
            )
          : Row(
              children: [
                Expanded(child: status),
                const SizedBox(width: 12),
                saveButton,
              ],
            ),
    );
    if (embedded) {
      return ReaderMarkdownWorkspace(
        heading: heading,
        header: header,
        editor: editor,
        footer: footer,
      );
    }
    return DeskDocument(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: MarkdownWorkspace(
          header: header,
          editor: editor,
          footer: footer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final footerMessage =
        media.feedback ??
        imageSizing.feedback ??
        (needsVerification ? '需要完成站点验证，当前修改已保留' : statusMessage);
    if (widget.binding != null) {
      // The reader owns its route and backdrop. No PopScope or page scaffold is
      // installed here, so closing this document cannot pop the reader itself.
      return _documentSurface(colors, footerMessage, embedded: true);
    }
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(close());
      },
      child: CupertinoPageScaffold(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _heading(colors, embedded: false),
                const SizedBox(height: 12),
                Expanded(
                  child: _documentSurface(
                    colors,
                    footerMessage,
                    embedded: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
