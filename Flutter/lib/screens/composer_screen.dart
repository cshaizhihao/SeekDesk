import 'dart:async';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/frame_diagnostics.dart';
import '../core/native_client.dart';
import '../core/document_history.dart';
import '../core/markdown_edit.dart';
import '../core/reader_editor_binding.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/desk_context_menu.dart';
import '../widgets/desk_input_surface.dart';
import '../widgets/document_history_scope.dart';
import '../widgets/markdown_toolbar.dart';
import '../widgets/markdown_editor_controls.dart';
import '../widgets/composer_media.dart';
import '../widgets/composer_preview.dart';
import '../widgets/composer_media_controller.dart';
import '../widgets/node_image_settings.dart';
import '../widgets/discussion_options_notice.dart';
import '../widgets/composer_image_sizing_controller.dart';
import '../widgets/composer_paste_scope.dart';
import '../widgets/editor_header_diagnostics.dart';
import '../widgets/reader_markdown_workspace.dart';

class ComposerScreen extends StatelessWidget {
  const ComposerScreen({
    required this.state,
    this.topicID,
    this.url,
    this.binding,
    super.key,
  });
  final AppState state;
  final String? topicID, url;
  final ReaderEditorBinding? binding;
  bool get reply => topicID != null;
  @override
  Widget build(BuildContext context) => _ComposerScreenDocument(
    key: ValueKey((state, topicID, url, binding)),
    state: state,
    topicID: topicID,
    url: url,
    binding: binding,
  );
}

// A target change creates a fresh owner. Pending media and draft completions
// remain bound to the old owner instead of following a reused route widget.
class _ComposerScreenDocument extends StatefulWidget {
  const _ComposerScreenDocument({
    required this.state,
    this.topicID,
    this.url,
    this.binding,
    super.key,
  });
  final AppState state;
  final String? topicID, url;
  final ReaderEditorBinding? binding;
  bool get reply => topicID != null;
  @override
  State<_ComposerScreenDocument> createState() => _ComposerScreenState();
}

class _ComposerScreenState extends State<_ComposerScreenDocument> {
  final title = TextEditingController(), content = TextEditingController();
  final contentFocus = FocusNode();
  late final ComposerMediaController media;
  late final DocumentHistory history;
  late final ComposerImageSizingController imageSizing;
  (bool, bool, String?)? imageSizingStatus;
  String lastTitle = '', lastContent = '';
  int mode = 0, rank = 0;
  String category = '';
  bool sending = false, discarding = false;
  bool loading = true, saving = false, changed = false;
  bool draftLoaded = false, draftReadActive = false;
  bool closing = false, optionsLoading = false, openingAccess = false;
  bool _finished = false;
  bool _metadataMenuOpen = false;
  String optionsPhase = 'loading';
  String? optionsMessage, submissionMessage;
  bool localSubmissionUncertain = false;
  String verificationURL = 'https://www.nodeseek.com/new-discussion';
  int optionsGeneration = 0;
  Future<void>? optionsTask;
  String? loadError;
  Future<JsonMap?>? draftWrite;
  Timer? debounce;
  int revision = 0;
  JsonMap draft = {};
  List<JsonMap> categories = [];
  bool _comparisonAllowed = true;
  (bool, bool) _lastComposition = (false, false);
  @override
  void initState() {
    super.initState();
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      FrameDiagnostics.recordUiWork(
        UiWorkKind.composerInit,
        count: 1,
        loading: loading,
      );
    }
    revision = widget.binding?.accessRevision ?? widget.state.accessRevision;
    history = DocumentHistory(controller: content);
    imageSizing = ComposerImageSizingController(
      state: widget.state,
      content: content,
      revision: revision,
      isCurrent: () => current,
      canChange: () =>
          current &&
          active &&
          !sending &&
          !closing &&
          !loading &&
          !media.busy &&
          !imageSizing.busy &&
          !optionsBusy &&
          loadError == null &&
          !history.isComposing,
      synchronize: _synchronizeImageSizing,
      saveSize: (url, ratio, previewWidth, expectedContent) async {
        if (!current) return null;
        final result = await widget.state.act(
          widget.reply ? 'reader.setReplyImageSize' : 'discussion.setImageSize',
          {
            if (widget.reply) 'topicID': widget.topicID,
            'url': url,
            'ratio': ratio,
            'previewWidth': previewWidth,
            'expectedContent': expectedContent,
          },
        );
        if (!current) return null;
        return result;
      },
      onEdited: () {},
    )..addListener(_imageSizingChanged);
    media = ComposerMediaController(
      state: widget.state,
      content: content,
      applyEdit: _applyMediaEdit,
      revision: revision,
      documentIdentity: (widget.state, widget.topicID, widget.url),
      canStart: () =>
          mounted &&
          active &&
          !sending &&
          !closing &&
          !loading &&
          !optionsLoading &&
          !openingAccess &&
          !imageSizing.busy &&
          loadError == null,
    )..addListener(_mediaChanged);
    title.addListener(_edited);
    content.addListener(_edited);
    widget.state.registerDraftFlusher(this, () async {
      if (sending ||
          closing ||
          _composing ||
          media.busy ||
          optionsLoading ||
          openingAccess ||
          imageSizing.busy) {
        return false;
      }
      if (loading || loadError != null) return true;
      return _flush();
    });
    widget.binding
      ?..requestClose = _requestClose
      ..prepareForTabClose = _prepareForTabClose
      ..operationBusy = _isOperationBusy
      ..addListener(_bindingChanged);
    if (embedded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    } else {
      _load();
    }
  }

  bool get embedded => widget.binding != null;
  bool get active => widget.binding?.active ?? true;
  bool get _composing =>
      history.isComposing ||
      title.value.composing.isValid && !title.value.composing.isCollapsed;
  bool get operationBusy =>
      sending ||
      closing ||
      loading ||
      _composing ||
      media.busy ||
      optionsBusy ||
      imageSizing.busy;
  bool _isOperationBusy() => operationBusy;

  void _bindingChanged() {
    if (!mounted) return;
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      FrameDiagnostics.recordUiWork(
        UiWorkKind.composerBinding,
        count: 1,
        loading: loading,
      );
    }
    if (!active) contentFocus.unfocus();
    setState(() {
      // An expired preview must still expose its retained source for copying.
      if (!current) mode = 0;
    });
    _consumeReplyAppend();
  }

  void _consumeReplyAppend() {
    final binding = widget.binding;
    if (!mounted || binding == null || !binding.hasReplyAppend) return;
    // A newly opened editor reads its own draft before applying the command.
    // All other busy states reject it rather than replaying it later.
    if (loading && current && active) return;
    final request = binding.takeReplyAppend();
    if (request == null) return;
    if (!widget.reply ||
        !current ||
        !active ||
        !draftLoaded ||
        loadError != null ||
        operationBusy ||
        !_replyAllowed ||
        request.navigation != binding.navigationIdentity()) {
      request.complete(false);
      return;
    }
    final accepted = history.execute((value) {
      final text = value.text + request.insertion(value.text);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
    request.complete(accepted);
    if (!accepted) return;
    setState(() => mode = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current &&
          active &&
          !operationBusy &&
          mode == 0 &&
          request.navigation == binding.navigationIdentity()) {
        contentFocus.requestFocus();
        revealMarkdownCaret(
          history,
          focusNode: contentFocus,
          isCurrent: () =>
              current &&
              active &&
              mode == 0 &&
              request.navigation == binding.navigationIdentity(),
        );
      }
    });
  }

  Future<bool> _prepareForTabClose() async {
    if (!current || operationBusy || loadError != null) return false;
    setState(() => closing = true);
    try {
      if (!await _flush() || !current || _composing || changed) return false;
      widget.binding?.close();
      return true;
    } finally {
      if (mounted) setState(() => closing = false);
    }
  }

  void _finish({ModalRoute<dynamic>? ownerRoute}) {
    if (!mounted || _finished) return;
    final binding = widget.binding;
    if (binding != null) {
      _finished = true;
      binding.close();
    } else {
      final route = ownerRoute ?? ModalRoute.of(context);
      final navigator = route?.navigator;
      if (route == null ||
          navigator == null ||
          !navigator.mounted ||
          !route.isActive) {
        return;
      }
      _finished = true;
      // A successful save may finish after another page covers this editor.
      // Complete only the route that owns the document, never the new top page.
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
  }

  Future<void> _load() async {
    if (!mounted || draftLoaded || draftReadActive) return;
    if (!current) {
      setState(() {
        loading = false;
        loadError = '账号已变更，请重新打开编辑器。';
      });
      _consumeReplyAppend();
      return;
    }
    draftReadActive = true;
    try {
      setState(() {
        loading = true;
        loadError = null;
      });
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        FrameDiagnostics.recordUiWork(
          UiWorkKind.composerLoadStart,
          count: 1,
          loading: loading,
        );
      }
      final value = await widget.state.act(
        widget.reply ? 'reader.replyDraft' : 'discussion.getDraft',
        widget.reply ? {'topicID': widget.topicID} : {},
        widget.reply ? null : 'discussion',
      );
      if (!mounted) return;
      if (value == null || revision != widget.state.accessRevision) {
        setState(() {
          loading = false;
          loadError = revision != widget.state.accessRevision
              ? '账号已变更，请重新打开编辑器。'
              : '无法读取草稿，请重试。';
        });
        _consumeReplyAppend();
        return;
      }
      draft = {...value};
      title.text = stringValue(draft['title']);
      content.text = stringValue(draft['content']);
      imageSizing.acceptSnapshot(value);
      history.reset();
      category = stringValue(draft['category']);
      rank = intValue(draft['rank']);
      if (!widget.reply) _acceptOptions(value);
      lastTitle = title.text;
      lastContent = content.text;
      _lastComposition = (history.isComposing, _composing);
      draftLoaded = true;
      setState(() => loading = false);
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        FrameDiagnostics.recordUiWork(
          UiWorkKind.composerLoadReady,
          count: 1,
          loading: loading,
        );
      }
      _consumeReplyAppend();
      if (!widget.reply) unawaited(_reloadOptions());
    } finally {
      draftReadActive = false;
    }
  }

  bool get current => mounted && revision == widget.state.accessRevision;
  static const expiredMessage =
      '账号已变更，当前窗口的未保存修改无法写回原账号。请复制需要保留的内容，关闭后重新打开编辑器。';
  bool get optionsBusy => optionsLoading || openingAccess;
  bool get canLoadOptions =>
      current &&
      active &&
      !widget.reply &&
      !loading &&
      loadError == null &&
      !sending &&
      !closing &&
      !media.busy &&
      !imageSizing.busy &&
      !imageSizing.hasPendingChanges &&
      !optionsBusy;
  bool get canChooseMetadata => canLoadOptions && optionsPhase == 'ready';
  bool get validMetadata =>
      optionsPhase == 'ready' &&
      title.text.trim().isNotEmpty &&
      categories.any(
        (item) => stringValue(item['id']) == category && category.isNotEmpty,
      ) &&
      (rank == 255 ||
          rank >= 0 && rank <= intValue(draft['maxRank']).clamp(0, 30));
  bool get _replyAllowed {
    if (!widget.reply) return true;
    if (widget.state.domain('session')['canCompose'] == false) return false;
    final url = widget.url;
    if (url == null) return true;
    final thread = widget.state.readerFor(url)['thread'];
    return thread is! Map || stringValue(thread['replyRestriction']).isEmpty;
  }

  bool get canSubmit =>
      current &&
      active &&
      !sending &&
      !closing &&
      !loading &&
      !_composing &&
      !media.busy &&
      !imageSizing.busy &&
      !optionsBusy &&
      loadError == null &&
      _replyAllowed &&
      content.text.trim().isNotEmpty &&
      (widget.reply || validMetadata);

  void _acceptOptions(JsonMap snapshot) {
    // Never copy text, selection, history or image sizing from an options reply.
    const phases = {
      'loading',
      'ready',
      'signedOut',
      'verification',
      'unavailable',
    };
    if (snapshot.containsKey('phase')) {
      final phase = stringValue(snapshot['phase']);
      optionsPhase = phases.contains(phase) ? phase : 'unavailable';
    } else if (snapshot.containsKey('ready')) {
      optionsPhase = snapshot['ready'] == true ? 'ready' : 'unavailable';
    }
    for (final key in ['categories', 'maxRank', 'category', 'rank']) {
      if (snapshot.containsKey(key)) draft[key] = snapshot[key];
    }
    if (snapshot.containsKey('categories')) {
      categories = jsonItems(snapshot['categories']);
    }
    if (snapshot.containsKey('category')) {
      category = stringValue(snapshot['category']);
    }
    if (snapshot.containsKey('rank')) rank = intValue(snapshot['rank']);
    final address = Uri.tryParse(stringValue(snapshot['verificationURL']));
    if (address != null &&
        address.scheme == 'https' &&
        const {'www.nodeseek.com', 'nodeseek.com'}.contains(address.host) &&
        address.path == '/new-discussion' &&
        address.userInfo.isEmpty) {
      verificationURL = address.toString();
    }
    final message = stringValue(snapshot['message']).trim();
    optionsMessage = message.isEmpty ? null : message;
    if (snapshot.containsKey('lastSubmissionMessage')) {
      final message = stringValue(snapshot['lastSubmissionMessage']).trim();
      if (message.isNotEmpty) {
        submissionMessage = message;
      } else if (!localSubmissionUncertain) {
        submissionMessage = null;
      }
    }
  }

  Future<void> _reloadOptions() async {
    if (!canLoadOptions) return;
    final generation = ++optionsGeneration;
    debounce?.cancel();
    setState(() {
      optionsLoading = true;
      optionsMessage = null;
    });
    final operation = _readOptions(generation);
    optionsTask = operation;
    try {
      await operation;
    } finally {
      if (identical(optionsTask, operation)) optionsTask = null;
      if (mounted && generation == optionsGeneration) {
        setState(() => optionsLoading = false);
        // Edits made while metadata was loading are saved only after accepting
        // the native category/rank correction, never with the old metadata.
        if (current && changed) unawaited(_save());
      }
    }
  }

  Future<void> _readOptions(int generation) async {
    bool valid() => current && generation == optionsGeneration;
    while (saving) {
      await draftWrite;
      if (!valid()) return;
    }
    if (!valid()) return;
    if (!await _save(allowDuringOptions: true)) {
      if (valid()) {
        setState(() {
          optionsPhase = 'unavailable';
          optionsMessage = '草稿暂时无法保存，尚未重新读取发布权限。当前文字已保留，请重试。';
        });
      }
      return;
    }
    if (!valid()) return;
    final result = await widget.state.act(
      'discussion.loadOptions',
      {},
      'discussion',
    );
    if (!valid()) return;
    setState(() {
      if (result == null) {
        optionsPhase = 'unavailable';
        optionsMessage = '未能读取发布选项。当前文字已保留，请重试。';
      } else {
        _acceptOptions(result);
        if (optionsPhase == 'loading') {
          optionsPhase = 'unavailable';
          optionsMessage ??= '发布选项尚未就绪，请重试。';
        }
      }
    });
  }

  Future<void> _openOptionsAccess() async {
    if (!canLoadOptions ||
        history.isComposing ||
        !const {'verification', 'signedOut'}.contains(optionsPhase)) {
      return;
    }
    final generation = optionsGeneration;
    final signIn = optionsPhase == 'signedOut';
    setState(() => openingAccess = true);
    try {
      final result = await widget.state.act(
        signIn ? 'session.signIn' : 'session.verify',
        signIn ? {} : {'url': verificationURL},
      );
      if (!current || generation != optionsGeneration) return;
      setState(
        () => optionsMessage = result == null
            ? '窗口未能打开，当前文字已保留，请重试。'
            : signIn
            ? '登录窗口已打开。完成后返回这里，点击「登录后重试」。'
            : '验证窗口已打开。完成后返回这里，点击「验证后重试」。',
      );
      // Opening a window does not prove login/verification and never publishes.
    } finally {
      if (mounted) setState(() => openingAccess = false);
    }
  }

  void _edited({bool metadataChanged = false}) {
    if (loading || !mounted) return;
    // Formatting depends on body composition; saving/submitting also depends
    // on the title. Observe both so a body commit still refreshes formatting
    // while the title retains an unfinished composition.
    final composition = (history.isComposing, _composing);
    final compositionChanged = _lastComposition != composition;
    _lastComposition = composition;
    if (!metadataChanged &&
        lastTitle == title.text &&
        lastContent == content.text) {
      if (compositionChanged) setState(() {});
      return;
    }
    lastTitle = title.text;
    lastContent = content.text;
    // An IME commit may arrive while a save/close is awaiting native work.
    // Retain it as dirty without starting a competing background write.
    changed = true;
    debounce?.cancel();
    if (!sending && !closing && !optionsLoading && !imageSizing.busy) {
      debounce = Timer(const Duration(milliseconds: 400), _save);
    }
    if (mounted) setState(() {});
  }

  Future<bool> _save({
    bool allowDuringOptions = false,
    bool allowDuringSizing = false,
  }) async {
    if (revision != widget.state.accessRevision ||
        loadError != null ||
        optionsLoading && !allowDuringOptions ||
        imageSizing.busy && !allowDuringSizing) {
      return false;
    }
    if (!changed) return true;
    if (saving) {
      debounce?.cancel();
      if (mounted && !sending && !closing && !optionsLoading) {
        debounce = Timer(const Duration(milliseconds: 180), _save);
      }
      return false;
    }
    saving = true;
    changed = false;
    final operation = widget.state.act(
      widget.reply ? 'reader.updateReplyDraft' : 'discussion.updateDraft',
      widget.reply
          ? {'topicID': widget.topicID, 'content': content.text}
          : {
              'title': title.text,
              'content': content.text,
              // A failed options reply may have hidden a native correction.
              // While metadata is unavailable, save text without overwriting it.
              if (optionsPhase == 'ready') 'category': category,
              if (optionsPhase == 'ready') 'rank': rank,
            },
      widget.reply ? null : 'discussion',
    );
    draftWrite = operation;
    widget.state.trackDraftSave(operation.then((result) => result != null));
    final result = await operation;
    saving = false;
    draftWrite = null;
    if (result == null) changed = true;
    if (result != null && current) {
      imageSizing.acceptSnapshot(result);
    }
    return result != null && revision == widget.state.accessRevision;
  }

  Future<JsonMap?> _synchronizeImageSizing(String expectedContent) async {
    debounce?.cancel();
    while (saving) {
      await draftWrite;
      if (!current) return null;
    }
    if (!current || optionsBusy || content.text != expectedContent) return null;
    if (!await _save(allowDuringSizing: true) ||
        !current ||
        content.text != expectedContent) {
      return null;
    }
    // A setter may have succeeded even if its reply was lost. Read canonical
    // local metadata rather than confirming a retry with a cached snapshot.
    final snapshot = await widget.state.act(
      widget.reply ? 'reader.replyDraft' : 'discussion.getDraft',
      widget.reply ? {'topicID': widget.topicID} : {},
    );
    if (!current || content.text != expectedContent) return null;
    return snapshot;
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
    if (!imageSizing.busy &&
        changed &&
        !sending &&
        !closing &&
        !optionsBusy &&
        current) {
      unawaited(_save());
    }
  }

  Future<void> _send() async {
    if (!canSubmit) return;
    final binding = widget.binding;
    final navigation = binding?.navigationIdentity();
    setState(() => sending = true);
    try {
      if (!await _flush() ||
          !mounted ||
          !current ||
          _composing ||
          changed ||
          !active ||
          !_replyAllowed ||
          binding != null && binding.navigationIdentity() != navigation) {
        return;
      }
      final confirmed = await confirmAction(
        context,
        title: widget.reply ? '发送回复' : '发布新帖',
        message: widget.reply
            ? '将以当前 NodeSeek 账号发送这条回复。'
            : '将以当前 NodeSeek 账号发布这篇帖子，并接受社区规定的发帖费用。',
        accept: widget.reply ? '发送' : '发布',
      );
      if (!confirmed ||
          !current ||
          _composing ||
          changed ||
          !active ||
          !_replyAllowed ||
          binding != null && binding.navigationIdentity() != navigation) {
        return;
      }
      // Only another explicit, confirmed submission starts a new attempt.
      localSubmissionUncertain = false;
      final result = await widget.state.act(
        widget.reply ? 'reader.sendReply' : 'discussion.publish',
        widget.reply
            ? {'topicID': widget.topicID, 'url': widget.url}
            : {'feeAccepted': true},
        widget.reply ? null : 'discussion',
      );
      if (!mounted) return;
      if (revision != widget.state.accessRevision) return;
      if (result == null) {
        if (!widget.reply) {
          setState(() {
            localSubmissionUncertain = true;
            submissionMessage = '未收到发布结果。请先检查帖子是否已经出现，再决定是否重发。当前文字已保留。';
          });
        }
        return;
      }
      final accepted =
          result['accepted'] == true ||
          result['kind'] == 'posted' ||
          result['kind'] == 'published';
      if (accepted) {
        changed = false;
        final destination = stringValue(result['destination'] ?? result['url']);
        if (binding != null) {
          binding.submitted(
            navigation!,
            destination: destination.isEmpty ? null : destination,
          );
        } else {
          _finish();
          if (destination.isNotEmpty) {
            widget.state.openLink(destination);
          } else if (widget.url != null) {
            widget.state.loadReader(widget.url!, force: true);
          }
        }
      } else {
        if (!widget.reply) {
          setState(() {
            _acceptOptions(result);
            submissionMessage ??= stringValue(
              result['message'],
              '请检查发布结果，确认后再重试。',
            );
          });
        }
        widget.state.showMessage(
          stringValue(result['message'], '请检查发布结果，确认后再重试。'),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<bool> _flush() async {
    if (_composing || media.busy || optionsBusy) return false;
    debounce?.cancel();
    while (saving) {
      await draftWrite;
      if (!current || _composing || media.busy || optionsBusy) return false;
    }
    if (!current || _composing) return false;
    await _save();
    if (changed || !current || _composing || media.busy || optionsBusy) {
      return false;
    }
    if (!await imageSizing.flush() ||
        !current ||
        _composing ||
        media.busy ||
        optionsBusy) {
      return false;
    }
    await _save();
    return current &&
        !_composing &&
        !changed &&
        !imageSizing.hasPendingChanges &&
        !media.busy &&
        !optionsBusy;
  }

  Future<bool> _close() async {
    if (sending ||
        closing ||
        loading ||
        _composing ||
        media.busy ||
        (optionsBusy || imageSizing.busy) && current) {
      return false;
    }
    if (loadError != null) return true;
    setState(() => closing = true);
    try {
      if (revision != widget.state.accessRevision) {
        final confirmed = await confirmAction(
          context,
          title: '关闭旧账号的编辑器',
          message: '账号已变更，当前窗口的未保存修改无法写回原账号。请先复制需要保留的内容，再关闭此窗口。',
          accept: '关闭此编辑器',
          destructive: true,
        );
        if (!mounted || !confirmed || _composing) return false;
        discarding = true;
        return true;
      }
      return await _flush();
    } finally {
      if (mounted) setState(() => closing = false);
    }
  }

  Future<void> _discard() async {
    if (!mounted ||
        _finished ||
        !embedded && ModalRoute.of(context)?.isCurrent != true ||
        !active ||
        sending ||
        closing ||
        loading ||
        _composing ||
        media.busy ||
        (optionsBusy || imageSizing.busy) && current) {
      return;
    }
    if (revision != widget.state.accessRevision) {
      await _requestClose();
      return;
    }
    setState(() => closing = true);
    try {
      if (!await confirmAction(
            context,
            title: '放弃编辑',
            message: '将清空当前草稿，此操作无法撤销。',
            accept: '放弃编辑',
            destructive: true,
          ) ||
          !mounted ||
          _composing ||
          revision != widget.state.accessRevision) {
        return;
      }
      debounce?.cancel();
      while (saving) {
        await draftWrite;
        if (!current || _composing) return;
      }
      if (!current || _composing) return;
      final result = await widget.state.act(
        widget.reply ? 'reader.discardReplyDraft' : 'discussion.discard',
        widget.reply
            ? {'topicID': widget.topicID, 'confirmed': true}
            : {'confirmed': true},
        widget.reply ? null : 'discussion',
      );
      if (result != null && mounted) {
        changed = false;
        discarding = true;
        _finish();
      }
    } finally {
      if (mounted) setState(() => closing = false);
    }
  }

  bool get canFormat =>
      mounted &&
      active &&
      !sending &&
      !closing &&
      !loading &&
      !media.busy &&
      loadError == null &&
      revision == widget.state.accessRevision &&
      mode != 2 &&
      !history.isComposing;

  bool _applyMediaEdit(TextEditingValue value) {
    if (!current) return false;
    if (!history.apply(value)) return false;
    revealMarkdownCaret(
      history,
      focusNode: contentFocus,
      // The media operation still owns busy while committing this edit.
      isCurrent: () =>
          current &&
          active &&
          !sending &&
          !closing &&
          !loading &&
          !optionsBusy &&
          !imageSizing.busy &&
          loadError == null &&
          mode != 2,
    );
    return true;
  }

  void _format(MarkdownCommand command) {
    if (!canFormat) return;
    final applied = history.execute((value) {
      // A freshly loaded draft has no selection until its first focus.
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

  Future<T?> _chooseMetadata<T>(
    BuildContext anchor,
    List<DeskMenuEntry<T>> entries,
  ) async {
    if (!canChooseMetadata || _metadataMenuOpen || !anchor.mounted) return null;
    final sourceRoute = ModalRoute.of(context);
    if (sourceRoute?.isCurrent == false) return null;
    final render = anchor.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    final generation = optionsGeneration;
    bool valid() {
      if (!canChooseMetadata || generation != optionsGeneration) return false;
      final extensions = widget.state.domain('extensions');
      return !(jsonItems(
            extensions['items'],
          ).any((item) => item['id'] == 'office' && item['active'] == true) &&
          jsonMap(jsonMap(extensions['settings'])['office'])['presented'] ==
              true);
    }

    _metadataMenuOpen = true;
    final releasePopup = widget.state.deferWatchPopup();
    try {
      final selected = await showDeskContextMenu<T>(
        context,
        position: render.localToGlobal(Offset(0, render.size.height + 6)),
        entries: entries,
        maximumHeight: 420,
        validityChanges: widget.state,
        isValid: valid,
      );
      return valid() && (sourceRoute?.isCurrent ?? true) ? selected : null;
    } finally {
      _metadataMenuOpen = false;
      releasePopup();
    }
  }

  Future<void> _chooseCategory(BuildContext anchor) async {
    final selected = await _chooseMetadata<String>(anchor, [
      for (final item in categories)
        DeskMenuEntry(
          stringValue(item['id']),
          stringValue(item['title']),
          item['id'] == category
              ? CupertinoIcons.check_mark
              : CupertinoIcons.square_grid_2x2,
        ),
    ]);
    if (!mounted ||
        selected == null ||
        !canChooseMetadata ||
        !categories.any((item) => item['id'] == selected)) {
      return;
    }
    setState(() => category = selected);
    _edited(metadataChanged: true);
  }

  Future<void> _chooseRank(BuildContext anchor) async {
    if (!canChooseMetadata) return;
    final maximum = intValue(draft['maxRank']).clamp(0, 30);
    final selected = await _chooseMetadata<int>(anchor, [
      for (final value in [0, for (var i = 1; i <= maximum; i++) i, 255])
        DeskMenuEntry(
          value,
          value == 0
              ? '公开'
              : value == 255
              ? '私有（仅自己）'
              : 'Lv.$value 及以上',
          value == rank
              ? CupertinoIcons.check_mark
              : value == 255
              ? CupertinoIcons.lock
              : CupertinoIcons.eye,
        ),
    ]);
    if (!mounted || selected == null || !canChooseMetadata) {
      return;
    }
    setState(() => rank = selected);
    _edited(metadataChanged: true);
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  void _changeMode(int next) {
    if (!active || !current || sending || closing) return;
    if (mode == next) return;
    if (embedded && next == 1 && !_comparisonAllowed) {
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
        if (current && active && mode != 2) contentFocus.requestFocus();
      });
    }
  }

  Future<void> _requestClose() async {
    if (!mounted || _finished) return;
    final route = embedded ? null : ModalRoute.of(context);
    if (!embedded && route?.isCurrent != true) return;
    if (await _close() && mounted && !_composing && (discarding || !changed)) {
      _finish(ownerRoute: route);
    }
  }

  @override
  void dispose() {
    final measured = FrameDiagnostics.enabled && FrameDiagnostics.rawFrames;
    final started = measured
        ? DateTime.now().toUtc().microsecondsSinceEpoch
        : 0;
    final frameNumber = measured
        ? ui.PlatformDispatcher.instance.frameData.frameNumber
        : null;
    final timer = measured ? (Stopwatch()..start()) : null;
    try {
      final binding = widget.binding;
      binding?.removeListener(_bindingChanged);
      if (binding?.requestClose == _requestClose) binding?.requestClose = null;
      if (binding?.prepareForTabClose == _prepareForTabClose) {
        binding?.prepareForTabClose = null;
      }
      if (binding?.operationBusy == _isOperationBusy) {
        binding?.operationBusy = null;
      }
      widget.state.unregisterDraftFlusher(this);
      optionsGeneration++;
      final pendingOptions = optionsTask;
      imageSizing.dispose();
      media.dispose();
      history.dispose();
      debounce?.cancel();
      if (changed && !discarding && revision == widget.state.accessRevision) {
        final state = widget.state, pending = draftWrite;
        final method = widget.reply
            ? 'reader.updateReplyDraft'
            : 'discussion.updateDraft';
        final JsonMap values = widget.reply
            ? {'topicID': widget.topicID, 'content': content.text}
            : {
                'title': title.text,
                'content': content.text,
                if (optionsPhase == 'ready') 'category': category,
                if (optionsPhase == 'ready') 'rank': rank,
              };
        final queued = () async {
          try {
            await pending;
            await pendingOptions;
            if (revision != state.accessRevision) return false;
            if (!widget.reply && pendingOptions != null) {
              final canonical = await state.client.call('discussion.getDraft');
              if (revision != state.accessRevision) return false;
              values['category'] = stringValue(canonical['category']);
              values['rank'] = intValue(canonical['rank']);
            }
            await state.client.call(method, values);
            return revision == state.accessRevision;
          } catch (_) {
            return false;
          }
        }();
        state.trackDraftSave(queued);
      }
      title.dispose();
      content.dispose();
      contentFocus.dispose();
      super.dispose();
    } finally {
      if (timer != null) {
        timer.stop();
        FrameDiagnostics.recordUiWork(
          UiWorkKind.composerDispose,
          startedUnixMicros: started,
          durationMicros: timer.elapsedMicroseconds,
          count: 1,
          frameNumber: frameNumber,
        );
      }
    }
  }

  KeyEventResult _sendKey(FocusNode node, KeyEvent event) {
    if (!active ||
        !contentFocus.hasFocus ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return KeyEventResult.ignored;
    }
    if (markdownCompositionKey(history, event)) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (!canFormat) return KeyEventResult.ignored;
    final formatCommand = markdownShortcut(event);
    if (formatCommand != null) {
      _format(formatCommand);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final preference = stringValue(
      widget.state.domain('settings')['workspace.replySendKey'],
      'commandReturn',
    );
    final plain =
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    final command =
        keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter &&
        (preference == 'returnKey' && plain ||
            preference == 'commandReturn' && command)) {
      // Holding a send shortcut must neither resubmit nor become a structural
      // newline when the first key press cannot currently submit.
      if (event is KeyDownEvent) unawaited(_send());
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

  Widget _discardButton() => DeskButton(
    '放弃编辑',
    width: 105,
    onTap:
        !active ||
            sending ||
            closing ||
            loading ||
            _composing ||
            media.busy ||
            (optionsBusy || imageSizing.busy) && current
        ? null
        : _discard,
  );

  Widget _footer() {
    final status = MarkdownStatus(
      !current
          ? expiredMessage
          : media.feedback ??
                imageSizing.feedback ??
                submissionMessage ??
                (optionsLoading ? '正在读取发布选项，正文仍可编辑' : optionsMessage) ??
                '${content.text.characters.length} 字符 · 草稿自动保存在本机',
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _discardButton(),
        const SizedBox(width: 10),
        DeskButton(
          widget.reply ? '发送回复' : '发布帖子',
          icon: CupertinoIcons.paperplane,
          width: 122,
          tint: CupertinoColors.systemGreen,
          busy: sending,
          onTap: canSubmit ? _send : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        // Keep the two document actions together; a narrow footer gives the
        // status its own bounded line instead of squeezing either button.
        if (bounds.maxWidth < 520) {
          final boundedActions = embedded && bounds.maxWidth < 237
              ? SingleChildScrollView(
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  child: actions,
                )
              : actions;
          return sampleEditorBuild(
            kind: UiWorkKind.editorFooterBuild,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: boundedActions),
              ],
            ),
          );
        }
        return sampleEditorBuild(
          kind: UiWorkKind.editorFooterBuild,
          child: Row(
            children: [
              Expanded(child: status),
              const SizedBox(width: 12),
              actions,
            ],
          ),
        );
      },
    );
  }

  Widget _controlRow(
    Widget child, {
    required UiWorkKind layoutKind,
    required UiWorkKind paintKind,
  }) => sampleEditorHeader(
    layoutKind: layoutKind,
    paintKind: paintKind,
    buildKind: layoutKind == UiWorkKind.editorControlsLayout
        ? UiWorkKind.editorControlsBuild
        : UiWorkKind.editorFormatsBuild,
    // Include width constraints and descendant layout. The control row's
    // LimitedBox does not defer mounting, so prior build work is outside this
    // local timer and must be assessed using the full frame's framework time.
    child: embedded ? ReaderMarkdownControlRow(child: child) : child,
  );

  Widget _heading(DeskColors colors) => Row(
    children: [
      Expanded(
        child: Text(
          widget.reply ? '写回复' : '发布新帖',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.ink,
            fontSize: embedded ? 16 : 23,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(width: 8),
      DeskButton(
        '保存并关闭',
        width: 112,
        icon: CupertinoIcons.xmark,
        onTap:
            sending ||
                closing ||
                loading ||
                media.busy ||
                (optionsBusy || imageSizing.busy) && current
            ? null
            : _requestClose,
      ),
    ],
  );

  Widget _editor(DeskColors colors) => LayoutBuilder(
    builder: (context, bounds) {
      _comparisonAllowed =
          !embedded || bounds.maxHeight >= (bounds.maxWidth >= 760 ? 110 : 234);
      final visibleMode = mode == 1 && !_comparisonAllowed ? 0 : mode;
      if (visibleMode != mode && !history.isComposing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              mode == 1 &&
              !_comparisonAllowed &&
              !history.isComposing) {
            setState(() => mode = 0);
          }
        });
      }
      return ComposerContentViewport(
        editing: visibleMode != 2,
        split: visibleMode == 1,
        editor: ComposerEditorWithStickers(
          state: widget.state,
          controller: content,
          accessRevision: revision,
          active:
              visibleMode == 0 &&
              current &&
              active &&
              !loading &&
              loadError == null,
          child: DocumentHistoryScope(
            history: history,
            onHistoryApplied: _revealHistoryCaret,
            enabled: current && active && !sending && !closing && !media.busy,
            child: ComposerPasteScope(
              media: media,
              bodyFocus: contentFocus,
              enabled:
                  current &&
                  active &&
                  !sending &&
                  !closing &&
                  !loading &&
                  !optionsBusy &&
                  !imageSizing.busy &&
                  loadError == null &&
                  visibleMode != 2,
              requestKey: () => showComposerUploadKey(context),
              child: Focus(
                onKeyEvent: _sendKey,
                child: CupertinoTextField(
                  controller: content,
                  focusNode: contentFocus,
                  contextMenuBuilder: ComposerPasteScope.contextMenuBuilder,
                  selectAllOnFocus: false,
                  enabled: !sending && !closing,
                  readOnly: embedded && (!current || !active),
                  placeholder: widget.reply ? '写下你的回复…' : '分享你的想法…',
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  padding: const EdgeInsets.all(16),
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
          active:
              visibleMode != 0 &&
              current &&
              active &&
              !loading &&
              loadError == null,
          imageSizing: imageSizing,
          imagesEnabled:
              current &&
              active &&
              !sending &&
              !closing &&
              !media.busy &&
              !imageSizing.busy &&
              !optionsBusy,
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      FrameDiagnostics.recordUiWork(
        UiWorkKind.composerBuild,
        count: 1,
        loading: loading,
      );
    }
    final colors = DeskColors(context);
    final header = [
      if (!widget.reply) ...[
        DeskInputSurface(
          child: CupertinoTextField(
            controller: title,
            enabled: !sending && !closing,
            readOnly: embedded && (!current || !active),
            decoration: const BoxDecoration(),
            placeholder: '帖子标题',
            placeholderStyle: TextStyle(color: colors.secondary),
            padding: const EdgeInsets.all(13),
            style: TextStyle(
              color: colors.ink,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Builder(
              builder: (anchor) => DeskButton(
                categories
                        .where((item) => item['id'] == category)
                        .firstOrNull?['title']
                        ?.toString() ??
                    '选择版块',
                width: 140,
                icon: CupertinoIcons.square_grid_2x2,
                onTap: canChooseMetadata && categories.isNotEmpty
                    ? () => _chooseCategory(anchor)
                    : null,
              ),
            ),
            Builder(
              builder: (anchor) => DeskButton(
                rank == 0
                    ? '阅读权限：公开'
                    : rank == 255
                    ? '阅读权限：私有'
                    : '阅读权限：Lv.$rank+',
                width: 170,
                icon: rank == 255 ? CupertinoIcons.lock : CupertinoIcons.eye,
                onTap: canChooseMetadata ? () => _chooseRank(anchor) : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!current ||
            optionsLoading ||
            optionsPhase != 'ready' ||
            optionsMessage != null) ...[
          DiscussionOptionsNotice(
            phase: !current
                ? 'expired'
                : optionsLoading
                ? 'loading'
                : optionsPhase,
            busy: current && (optionsBusy || sending || closing || media.busy),
            message: !current
                ? expiredMessage
                : optionsLoading
                ? null
                : optionsMessage,
            onRetry: canLoadOptions ? _reloadOptions : null,
            onOpenVerification: canLoadOptions && !history.isComposing
                ? _openOptionsAccess
                : null,
          ),
          const SizedBox(height: 12),
        ],
      ],
      _controlRow(
        MarkdownEditorControls(
          mode: mode,
          onModeChanged: _changeMode,
          history: history,
          onHistoryApplied: _revealHistoryCaret,
          enabled: active && !sending && !closing && !media.busy && current,
          trailing: ComposerImageSettingsButton(
            controller: media,
            enabled: current && active && !sending && !closing && !optionsBusy,
            onTap: () => media.manageSettings(
              presentSettings: () =>
                  showNodeImageSettings(context, widget.state),
            ),
          ),
        ),
        layoutKind: UiWorkKind.editorControlsLayout,
        paintKind: UiWorkKind.editorControlsPaint,
      ),
      SizedBox(height: embedded ? 6 : 10),
      Offstage(
        offstage: mode == 2,
        child: _controlRow(
          MarkdownToolbar(
            enabled: active && canFormat,
            onCommand: _format,
            trailing: ComposerMediaTools(
              controller: media,
              enabled:
                  current && active && !sending && !closing && !optionsBusy,
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
          layoutKind: UiWorkKind.editorFormatsLayout,
          paintKind: UiWorkKind.editorFormatsPaint,
        ),
      ),
    ];
    final unavailable = loading || loadError != null;
    final editor = loading
        ? const Center(child: CupertinoActivityIndicator())
        : loadError != null
        ? embedded
              ? SingleChildScrollView(
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('无法打开草稿', style: TextStyle(color: colors.ink)),
                      const SizedBox(height: 6),
                      Text(
                        loadError!,
                        style: TextStyle(color: colors.secondary, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      DeskButton('重试', onTap: current && active ? _load : null),
                    ],
                  ),
                )
              : DeskEmpty(
                  '无法打开草稿',
                  detail: loadError,
                  action: DeskButton('重试', onTap: _load),
                )
        : _editor(colors);
    if (embedded) {
      return ReaderMarkdownWorkspace(
        heading: sampleEditorBuild(
          kind: UiWorkKind.editorHeadingBuild,
          child: _heading(colors),
        ),
        header: unavailable ? const [] : header,
        editor: editor,
        footer: _footer(),
      );
    }
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: CupertinoPageScaffold(
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: DeskBackdrop.themed(colors)),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _heading(colors),
                    const SizedBox(height: 12),
                    Expanded(
                      child: unavailable
                          ? editor
                          : DeskDocument(
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: MarkdownWorkspace(
                                  header: header,
                                  editor: editor,
                                  footer: _footer(),
                                ),
                              ),
                            ),
                    ),
                    if (unavailable) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _discardButton(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
