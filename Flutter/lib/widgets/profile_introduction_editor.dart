import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'forum_blocks.dart';
import 'glass_chrome.dart';

/// Lets the containing page use the editor's own discard confirmation before
/// switching sections or leaving. A successful request also invokes onClose.
/// Concurrent requests share the same confirmation; saving or IME composition
/// blocks departure. No bound editor means there is nothing to close.
class ProfileIntroductionEditorController {
  Object? _owner, _lease;
  Future<bool> Function()? _close;

  /// False between the parent's edit intent and the editor's first mount.
  /// A parent with a pending editor should defer navigation until attached.
  bool get isAttached => _close != null;

  void _bind(Object owner, Future<bool> Function() close) {
    _owner = owner;
    _lease = Object();
    _close = close;
  }

  void _unbind(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = _lease = null;
    _close = null;
  }

  Future<bool> requestClose() async {
    final close = _close, lease = _lease;
    if (close == null) return true;
    final closed = await close();
    // onClose may intentionally unmount the editor. It must not approve a
    // replacement editor that bound this controller during the old operation.
    return closed && (_lease == null || identical(lease, _lease));
  }
}

/// An inline editor; it never pushes or pops its containing page.
///
/// The original snapshot and account revision are captured on mount, so parent
/// refreshes cannot replace an unsaved draft or weaken conflict detection.
/// Give a new editing session a new key. Place this widget in a bounded height,
/// normally Expanded under the account page header. The parent removes it in
/// onClose and reloads the profile only when saved is true.
class ProfileIntroductionEditor extends StatefulWidget {
  const ProfileIntroductionEditor({
    required this.state,
    required this.original,
    required this.onClose,
    this.controller,
    this.embedded = true,
    super.key,
  });

  final AppState state;
  final JsonMap original;
  final ValueChanged<bool> onClose;
  final ProfileIntroductionEditorController? controller;
  final bool embedded;

  @override
  State<ProfileIntroductionEditor> createState() =>
      _ProfileIntroductionEditorState();
}

class _ProfileIntroductionEditorState extends State<ProfileIntroductionEditor> {
  late final AppState source;
  late final JsonMap original;
  late final int revision, owner;
  late final bool signedIn;
  late final TextEditingController signature, readme;
  final signatureFocus = FocusNode(), readmeFocus = FocusNode();
  int mode = 0;
  bool saving = false, closing = false, exiting = false;
  late bool observedCover;
  late int observedRevision;
  Future<bool>? closeOperation;
  String? error, issueKind;

  bool get dirty =>
      signature.text != stringValue(original['signature']) ||
      readme.text != stringValue(original['readme']);
  bool get composing => [signature, readme].any(
    (controller) =>
        controller.value.composing.isValid &&
        !controller.value.composing.isCollapsed,
  );
  bool get current =>
      mounted &&
      identical(source, widget.state) &&
      revision == source.accessRevision &&
      owner == intValue(source.domain('session')['owner']) &&
      signedIn == source.signedIn;
  bool get officeCovered {
    final extensions = widget.state.domain('extensions');
    return jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] == true;
  }

  bool get routeCurrent => ModalRoute.of(context)?.isCurrent ?? true;
  bool get ownsBinding =>
      widget.controller == null || identical(widget.controller!._owner, this);
  bool get locked => saving || closing || exiting;
  bool get canAct =>
      mounted &&
      ownsBinding &&
      !locked &&
      !composing &&
      !officeCovered &&
      routeCurrent;

  @override
  void initState() {
    super.initState();
    source = widget.state;
    original = Map<String, dynamic>.unmodifiable(widget.original);
    revision = observedRevision = source.accessRevision;
    owner = intValue(source.domain('session')['owner']);
    signedIn = source.signedIn;
    signature = TextEditingController(text: stringValue(original['signature']));
    readme = TextEditingController(text: stringValue(original['readme']));
    signature.addListener(_edited);
    readme.addListener(_edited);
    observedCover = officeCovered;
    source.addListener(_sourceChanged);
    source.registerDraftFlusher(this, _canTerminate);
    widget.controller?._bind(this, _requestClose);
  }

  @override
  void didUpdateWidget(covariant ProfileIntroductionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      if (!identical(oldWidget.state, source)) {
        oldWidget.state.unregisterDraftFlusher(this);
        oldWidget.state.removeListener(_sourceChanged);
      }
      // The retained old-account draft still blocks quitting the live app.
      // Keep the captured source guarded too, until this editor is disposed.
      widget.state.registerDraftFlusher(this, _canTerminate);
      if (!identical(widget.state, source)) {
        widget.state.addListener(_sourceChanged);
      }
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._unbind(this);
      widget.controller?._bind(this, _requestClose);
    }
  }

  Future<bool> _canTerminate() async =>
      exiting || !dirty && !saving && !closing && !composing;

  void _edited() {
    if (mounted) setState(() {});
  }

  void _sourceChanged() {
    final covered = officeCovered, access = source.accessRevision;
    if (covered == observedCover && access == observedRevision) return;
    observedCover = covered;
    observedRevision = access;
    if (covered) {
      signatureFocus.unfocus();
      readmeFocus.unfocus();
    }
    if (mounted) setState(() {});
  }

  Future<bool> _requestClose() {
    if (closeOperation case final running?) return running;
    if (exiting) return Future.value(true);
    if (!canAct) return Future.value(false);
    final completion = Completer<bool>();
    closeOperation = completion.future;
    setState(() => closing = true);
    unawaited(() async {
      var closed = false;
      try {
        if (dirty &&
            !await confirmAction(
              context,
              title: '放弃个人资料编辑？',
              message: '未保存的签名和个人简介将被丢弃。',
              accept: '放弃编辑',
              destructive: true,
            )) {
          return;
        }
        if (!mounted ||
            !ownsBinding ||
            composing ||
            officeCovered ||
            !routeCurrent) {
          return;
        }
        closed = _finish(false);
      } finally {
        closeOperation = null;
        if (mounted) setState(() => closing = false);
        completion.complete(closed);
      }
    }());
    return completion.future;
  }

  bool _finish(bool saved) {
    if (!mounted || exiting) return false;
    setState(() => exiting = true);
    signatureFocus.unfocus();
    readmeFocus.unfocus();
    widget.onClose(saved);
    return true;
  }

  Future<void> _save() async {
    if (!canAct || !dirty) return;
    if (!current || !ownsBinding) {
      setState(() {
        issueKind = null;
        error = '账号已经变化，请关闭后重新打开当前账号资料。';
      });
      return;
    }
    final submittedSignature = signature.text, submittedReadme = readme.text;
    setState(() {
      saving = true;
      error = issueKind = null;
    });
    final result = await source.act('profile.saveIntroduction', {
      'original': original,
      'draft': {'signature': submittedSignature, 'readme': submittedReadme},
    });
    if (!mounted) return;
    setState(() => saving = false);
    if (!current || !ownsBinding) {
      setState(() => error = '账号已经变化，本次返回结果不会应用到当前账号。输入已保留。');
      return;
    }
    if (signature.text != submittedSignature ||
        readme.text != submittedReadme) {
      setState(() => error = '保存期间输入发生变化，当前内容已保留，请检查后再保存。');
      return;
    }
    if (result?['kind'] == 'saved') {
      _finish(true);
      return;
    }
    setState(() {
      issueKind = stringValue(result?['kind']);
      error = switch (issueKind) {
        'conflict' => '资料已在其他地方被修改。请先复制保留本次编辑，再重新读取资料。',
        'verification' => '请先完成 NodeSeek 站点验证，当前输入已保留。',
        'signedOut' => '登录已失效。请重新登录后再操作，当前输入已保留。',
        'rejected' =>
          stringValue(result?['message']).trim().isEmpty
              ? 'NodeSeek 拒绝了这次更新，当前输入已保留。'
              : stringValue(result?['message']),
        'unavailable' => '暂时无法保存个人资料，请稍后重试。当前输入已保留。',
        _ => stringValue(result?['message'], '没有确认保存成功，请保留内容并重新检查账号资料。'),
      };
    });
  }

  void _changeMode(int next) {
    if (!canAct || next == mode) return;
    if (next == 1) {
      signatureFocus.unfocus();
      readmeFocus.unfocus();
    }
    setState(() => mode = next);
  }

  void _recover() {
    if (!canAct || !current) return;
    if (issueKind == 'verification') {
      unawaited(
        source.act('session.verify', {
          'url': 'https://www.nodeseek.com/setting',
        }),
      );
    } else if (issueKind == 'signedOut') {
      unawaited(source.act('session.signIn'));
    }
  }

  Widget _actions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      DeskButton(
        '放弃编辑',
        key: const ValueKey('profile-introduction-discard'),
        quiet: true,
        onTap: canAct ? () => unawaited(_requestClose()) : null,
      ),
      DeskButton(
        '保存资料',
        key: const ValueKey('profile-introduction-save'),
        tint: CupertinoColors.systemGreen,
        busy: saving,
        onTap: canAct && dirty ? () => unawaited(_save()) : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return PopScope(
      canPop: exiting || !dirty && !saving && !closing && !composing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestClose());
      },
      child: Padding(
        padding: EdgeInsets.all(widget.embedded ? 0 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '编辑个人资料',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: widget.embedded ? 17 : 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              key: const ValueKey('profile-introduction-controls'),
              spacing: 16,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: GlassSegmentedControl(
                    segments: const [
                      GlassSegment(label: '编辑'),
                      GlassSegment(label: '预览'),
                    ],
                    selectedIndex: mode,
                    onSegmentSelected: _changeMode,
                    quality: GlassQuality.premium,
                    height: math.max(
                      38.0,
                      MediaQuery.textScalerOf(context).scale(13) + 12,
                    ),
                  ),
                ),
                _actions(),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                key: const ValueKey('profile-introduction-content'),
                primary: false,
                children: [
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: CupertinoColors.systemRed.resolveFrom(
                                  context,
                                ),
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ),
                          if (issueKind == 'verification' ||
                              issueKind == 'signedOut') ...[
                            const SizedBox(height: 8),
                            DeskButton(
                              issueKind == 'verification'
                                  ? '验证访问'
                                  : '登录 NodeSeek',
                              width: 140,
                              onTap: canAct && current ? _recover : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  _field(
                    '论坛签名',
                    '显示在帖子下方。',
                    signature,
                    signatureFocus,
                    key: const ValueKey('profile-introduction-signature'),
                    minLines: 3,
                    maxLines: 6,
                    colors: colors,
                  ),
                  _field(
                    '个人简介',
                    '支持 Markdown。',
                    readme,
                    readmeFocus,
                    key: const ValueKey('profile-introduction-readme'),
                    minLines: 7,
                    maxLines: 16,
                    colors: colors,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String title,
    String subtitle,
    TextEditingController controller,
    FocusNode focus, {
    required Key key,
    required int minLines,
    required int maxLines,
    required DeskColors colors,
  }) => DeskSection(
    quiet: true,
    title: title,
    subtitle: subtitle,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Offstage(
          offstage: mode != 0,
          child: ExcludeFocus(
            excluding: mode != 0,
            child: MergeSemantics(
              child: Semantics(
                label: title,
                child: CupertinoTextField(
                  key: key,
                  controller: controller,
                  focusNode: focus,
                  selectAllOnFocus: false,
                  readOnly: locked || officeCovered || mode != 0,
                  minLines: minLines,
                  maxLines: maxLines,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.well,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.line),
                  ),
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (mode == 1)
          controller.text.trim().isEmpty
              ? Text(
                  '暂无内容',
                  style: TextStyle(color: colors.secondary, fontSize: 13),
                )
              : MarkdownDocument(
                  state: source,
                  text: controller.text,
                  opensLinks: false,
                ),
      ],
    ),
  );

  @override
  void dispose() {
    widget.controller?._unbind(this);
    source.unregisterDraftFlusher(this);
    if (!identical(source, widget.state)) {
      widget.state.unregisterDraftFlusher(this);
      widget.state.removeListener(_sourceChanged);
    }
    source.removeListener(_sourceChanged);
    signature.removeListener(_edited);
    readme.removeListener(_edited);
    signature.dispose();
    readme.dispose();
    signatureFocus.dispose();
    readmeFocus.dispose();
    super.dispose();
  }
}
