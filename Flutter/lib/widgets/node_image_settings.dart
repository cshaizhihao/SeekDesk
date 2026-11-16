import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

String? nodeImageKeyError(String value) {
  if (value.trim().isEmpty) return '请粘贴 NodeImage API 密钥。';
  if (RegExp('[\n\r\u000b\u000c\u0085\u2028\u2029]').hasMatch(value)) {
    return '密钥不能包含换行，请重新复制完整的一行。';
  }
  return null;
}

Future<void> showNodeImageSettings(BuildContext context, AppState state) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (_) => NodeImageSettings(state: state),
    );

/// Only configuration status crosses the bridge. The existing key is never
/// returned, displayed, placed in a controller, or included in an error message.
class NodeImageSettings extends StatefulWidget {
  const NodeImageSettings({required this.state, super.key});
  final AppState state;

  @override
  State<NodeImageSettings> createState() => _NodeImageSettingsState();
}

class _NodeImageSettingsState extends State<NodeImageSettings> {
  final input = TextEditingController();
  late final int revision;
  bool? configured;
  bool busy = false, invalidated = false, statusFailed = false;
  String? feedback;
  int operation = 0;
  String _observedText = '';
  bool _observedComposing = false;
  bool _initialStatusRequested = false;
  bool _closing = false;
  bool _readingStatus = false;

  bool get current =>
      mounted &&
      !_closing &&
      !invalidated &&
      revision == widget.state.accessRevision;
  bool get _routeCurrent =>
      mounted && !_closing && ModalRoute.of(context)?.isCurrent == true;
  bool get _canAct => current && _routeCurrent;
  bool get _protectingMutation => busy && !_readingStatus;
  bool get composing =>
      input.value.composing.isValid && !input.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    input.addListener(_inputChanged);
    widget.state.addListener(_accessChanged);
    widget.state.registerDraftFlusher(this, () async => !_protectingMutation);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialStatusRequested || !_routeCurrent) return;
    _initialStatusRequested = true;
    unawaited(_refresh());
  }

  void _inputChanged() {
    final textChanged = input.text != _observedText;
    final nextComposing = composing;
    if (!textChanged && nextComposing == _observedComposing) return;
    _observedText = input.text;
    _observedComposing = nextComposing;
    if (mounted) {
      setState(() {
        if (textChanged) feedback = null;
      });
    }
  }

  void _accessChanged() {
    if (!mounted || invalidated || revision == widget.state.accessRevision) {
      return;
    }
    input.clear();
    setState(() {
      invalidated = true;
      feedback = '账号已变更，请关闭后重新打开图床设置。';
    });
  }

  bool _valid(int token) => current && token == operation;

  int _start({bool readingStatus = false}) {
    final token = ++operation;
    setState(() {
      busy = true;
      _readingStatus = readingStatus;
      feedback = null;
    });
    return token;
  }

  void _finish(int token) {
    if (!mounted || _closing || token != operation) return;
    setState(() {
      busy = false;
      _readingStatus = false;
    });
    _accessChanged();
  }

  Future<void> _refresh() async {
    if (!_canAct || busy) return;
    final token = _start(readingStatus: true);
    try {
      final result = await widget.state.client.call('images.keyStatus');
      if (!_valid(token)) return;
      if (result['configured'] is! bool) {
        throw const NativeFailure('invalid_status', 'Invalid status');
      }
      setState(() {
        configured = result['configured'] as bool;
        statusFailed = false;
      });
    } catch (_) {
      if (!_valid(token)) return;
      setState(() {
        configured = null;
        statusFailed = true;
        feedback = '暂时无法读取本机密钥状态，请重试。';
      });
    } finally {
      _finish(token);
    }
  }

  Future<void> _save() async {
    if (!_canAct || busy || configured == null || composing) return;
    final validation = nodeImageKeyError(input.text);
    if (validation != null) {
      setState(() => feedback = validation);
      return;
    }
    final key = input.text.trim();
    final token = _start();
    try {
      final result = await widget.state.client.call('images.setKey', {
        'key': key,
      });
      if (!_valid(token)) return;
      if (result['configured'] != true) {
        throw const NativeFailure('invalid_status', 'Invalid status');
      }
      input.clear();
      setState(() {
        configured = true;
        feedback = '上传密钥已保存。';
      });
    } catch (_) {
      if (!_valid(token)) return;
      setState(() => feedback = '密钥未能保存，请重试。');
    } finally {
      _finish(token);
    }
  }

  Future<void> _remove() async {
    if (!_canAct || busy || configured != true) return;
    final token = _start();
    try {
      final confirmed = await confirmAction(
        context,
        title: '移除上传密钥',
        message: '移除后，需要重新配置密钥才能上传图片。已上传的图片不受影响。',
        accept: '移除密钥',
        destructive: true,
      );
      if (!confirmed || !_valid(token) || !_routeCurrent) return;
      final result = await widget.state.client.call('images.removeKey');
      if (!_valid(token)) return;
      if (result['configured'] != false) {
        throw const NativeFailure('invalid_status', 'Invalid status');
      }
      input.clear();
      setState(() {
        configured = false;
        feedback = '本机上传密钥已移除。';
      });
    } catch (_) {
      if (!_valid(token)) return;
      setState(() => feedback = '密钥未能移除，请重试。');
    } finally {
      _finish(token);
    }
  }

  void _openWebsite() {
    if (!_canAct || busy) return;
    unawaited(
      widget.state.act('external.open', {'url': 'https://www.nodeimage.com/'}),
    );
  }

  void _close() {
    if (_protectingMutation || !_routeCurrent) return;
    _retire();
    Navigator.pop(context);
  }

  void _retire() {
    if (!mounted || _closing) return;
    setState(() => _closing = true);
  }

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent ||
        event.synthesized ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        !_routeCurrent ||
        composing) {
      return KeyEventResult.ignored;
    }
    _close();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    operation++;
    widget.state.unregisterDraftFlusher(this);
    widget.state.removeListener(_accessChanged);
    input.removeListener(_inputChanged);
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final enabled = _canAct && !busy;
    final status = invalidated
        ? '设置已暂停'
        : statusFailed
        ? '无法读取密钥状态'
        : configured == null
        ? '正在读取密钥状态…'
        : configured!
        ? '已配置上传密钥'
        : '尚未配置上传密钥';
    final panel = PopScope<void>(
      canPop: !_protectingMutation,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _retire();
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'NodeImage 图床设置',
        child: SafeArea(
          minimum: const EdgeInsets.all(24),
          child: Center(
            child: SingleChildScrollView(
              child: SizedBox(
                width: 460,
                child: DeskGlassPanel(
                  level: GlassLevel.overlay,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(CupertinoIcons.photo, color: colors.accent),
                          const SizedBox(width: 10),
                          Text(
                            'NodeImage 图床',
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '使用你的 NodeImage API 密钥上传图片。密钥保存在此 Mac 的钥匙串中。',
                        style: TextStyle(color: colors.secondary, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DeskButton(
                          '打开 NodeImage 网站',
                          icon: CupertinoIcons.arrow_up_right_square,
                          width: 190,
                          height: 32,
                          quiet: true,
                          onTap: enabled ? _openWebsite : null,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          if (busy) ...[
                            const CupertinoActivityIndicator(radius: 7),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              status,
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (statusFailed)
                            DeskButton(
                              '重试',
                              width: 70,
                              onTap: enabled ? _refresh : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      CupertinoTextField(
                        controller: input,
                        enabled: enabled && configured != null,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        placeholder: configured == true
                            ? '粘贴新密钥以更换'
                            : '粘贴 NodeImage API 密钥',
                        padding: const EdgeInsets.all(13),
                        style: TextStyle(color: colors.ink, fontSize: 14),
                        decoration: BoxDecoration(
                          color: colors.well,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: colors.line),
                        ),
                        // Keep preedit intact until the input method commits
                        // it; EditableText's default completion would clear
                        // composing before our write guard can inspect it.
                        onEditingComplete: () {},
                        onSubmitted: (_) => unawaited(_save()),
                      ),
                      if (feedback != null) ...[
                        const SizedBox(height: 10),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            feedback!,
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          DeskButton(
                            '移除密钥',
                            width: 100,
                            tint: CupertinoColors.systemRed,
                            onTap: enabled && configured == true
                                ? _remove
                                : null,
                          ),
                          const Spacer(),
                          DeskButton(
                            '关闭',
                            width: 74,
                            onTap: !_protectingMutation && _routeCurrent
                                ? _close
                                : null,
                          ),
                          const SizedBox(width: 8),
                          DeskButton(
                            configured == true ? '更换密钥' : '保存密钥',
                            width: 106,
                            tint: CupertinoColors.systemGreen,
                            onTap:
                                enabled &&
                                    configured != null &&
                                    !composing &&
                                    input.text.trim().isNotEmpty
                                ? _save
                                : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: _keyEvent,
      child: panel,
    );
  }
}
