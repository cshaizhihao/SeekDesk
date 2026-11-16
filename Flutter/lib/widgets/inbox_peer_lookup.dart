import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/inbox_peer.dart';
import '../core/native_client.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

/// Compact lookup above the recent/older conversation timeline. The owner must
/// return true only after its existing draft-safe navigation has succeeded.
/// This widget never changes the inbox selection, marks read, or saves a draft.
class InboxPeerLookup extends StatefulWidget {
  const InboxPeerLookup({
    required this.state,
    required this.onOpen,
    this.contacts = const [],
    this.contactsRevision,
    this.navigationGeneration = 0,
    this.enabled = true,
    super.key,
  });

  final AppState state;
  final Future<bool> Function(JsonMap peer) onOpen;
  final Iterable<JsonMap> contacts;

  /// Stamp the contacts with the account revision of their messages snapshot.
  /// When omitted, contacts are trusted only in the account of initial mount.
  final int? contactsRevision;

  /// Changes synchronously when the parent starts another navigation. The
  /// callback supplied with this generation must reject a superseded lease.
  final int navigationGeneration;
  final bool enabled;

  @override
  State<InboxPeerLookup> createState() => _InboxPeerLookupState();
}

class _InboxPeerLookupState extends State<InboxPeerLookup> {
  final _input = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Inbox peer lookup');
  late int _revision, _initialContactsRevision;
  late int _owner;
  late bool _signedIn;
  int _operation = 0;
  bool _busy = false, _opening = false;
  String? _feedback;

  bool get _available => widget.enabled && widget.state.signedIn;

  @override
  void initState() {
    super.initState();
    _revision = widget.state.accessRevision;
    _initialContactsRevision = _revision;
    _owner = intValue(widget.state.domain('session')['owner']);
    _signedIn = widget.state.signedIn;
    widget.state.addListener(_accountChanged);
  }

  @override
  void didUpdateWidget(InboxPeerLookup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.state, oldWidget.state)) {
      oldWidget.state.removeListener(_accountChanged);
      widget.state.addListener(_accountChanged);
      _resetIdentity();
    } else {
      _accountChanged();
    }
    if (!widget.enabled && oldWidget.enabled) _cancel();
    if (widget.navigationGeneration != oldWidget.navigationGeneration) {
      _cancel();
    }
  }

  void _accountChanged() {
    if (!mounted) return;
    if (_revision != widget.state.accessRevision ||
        _owner != intValue(widget.state.domain('session')['owner']) ||
        _signedIn != widget.state.signedIn) {
      _resetIdentity();
    }
  }

  void _resetIdentity() {
    _operation++;
    _initialContactsRevision = -1;
    _revision = widget.state.accessRevision;
    _owner = intValue(widget.state.domain('session')['owner']);
    _signedIn = widget.state.signedIn;
    _input.clear();
    setState(() {
      _busy = false;
      _opening = false;
      _feedback = '账号已变更，请重新输入要查找的联系人。';
    });
  }

  void _cancel() {
    // The parent owns the already-started draft-safe navigation. Only a read
    // may be cancelled here; account changes always invalidate either phase.
    if (!_busy || _opening) return;
    _operation++;
    setState(() {
      _busy = false;
      _feedback = null;
    });
  }

  JsonMap _peer(int id, JsonMap source) {
    final rawName = source['name'] ?? source['member_name'];
    final name = rawName is String ? rawName.trim() : '';
    return {
      'id': id,
      'name': name.isEmpty ? '用户 $id' : name,
      'avatar': 'https://www.nodeseek.com/avatar/$id.png',
    };
  }

  Future<void> _submit() async {
    if (!_available || _busy) return;
    final source = widget.state;
    final revision = source.accessRevision;
    final owner = intValue(source.domain('session')['owner']);
    final navigation = widget.navigationGeneration;
    // Capture the callback from the request's original parent generation. A
    // newer build's callback must not grant an old profile result a new lease.
    final open = widget.onOpen;
    final validation = inboxPeerLookupError(_input.text, owner: owner);
    if (validation != null) {
      setState(() => _feedback = validation);
      return;
    }
    final id = parseInboxPeerID(_input.text)!;
    final token = ++_operation;
    bool current({bool opening = false}) =>
        mounted &&
        token == _operation &&
        identical(source, widget.state) &&
        widget.enabled &&
        (opening || navigation == widget.navigationGeneration) &&
        source.signedIn &&
        revision == source.accessRevision &&
        owner == intValue(source.domain('session')['owner']);
    setState(() {
      _busy = true;
      _opening = false;
      _feedback = null;
    });
    try {
      JsonMap? peer;
      if ((widget.contactsRevision ?? _initialContactsRevision) == revision) {
        for (final contact in widget.contacts) {
          if (contact['id'] == id) {
            peer = _peer(id, contact);
            break;
          }
        }
      }
      if (peer == null) {
        // AppState coalesces profile reads. Do not use inbox.load here: the
        // native inbox has one active selection lane shared by all categories.
        final result = await source.act('profile.load', {'id': id});
        if (!current()) return;
        final profile = jsonMap(result?['profile'] ?? result);
        final loadedID = profile['id'] ?? profile['member_id'];
        if (result == null ||
            result['accessRevision'] != revision ||
            loadedID != id ||
            result['owner'] != null && result['owner'] != owner) {
          setState(() {
            _feedback = '暂时无法读取这位用户的资料，请检查 UID 后重试。';
          });
          return;
        }
        peer = _peer(id, profile);
      }
      if (!current()) return;
      setState(() => _opening = true);
      final opened = await open(peer);
      if (!current(opening: true)) return;
      if (opened) {
        _input.clear();
        _focus.unfocus();
      } else {
        setState(() => _feedback = '未能打开对话，输入已保留。请重试。');
      }
    } catch (_) {
      if (current(opening: _opening)) {
        setState(() => _feedback = '未能打开对话，输入已保留。请重试。');
      }
    } finally {
      if (mounted && token == _operation) {
        setState(() {
          _busy = false;
          _opening = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _operation++;
    widget.state.removeListener(_accountChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final scaler = MediaQuery.textScalerOf(context);
    final buttonWidth = math.max(62.0, scaler.scale(12) * 2 + 24);
    final controlHeight = math.max(35.0, scaler.scale(14) * 1.25 + 18);
    final field = CupertinoTextField(
      key: const ValueKey('inbox-peer-lookup-input'),
      controller: _input,
      focusNode: _focus,
      enabled: _available,
      readOnly: _busy,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      placeholder: 'UID 或个人主页链接',
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      style: DeskTypography.base.copyWith(color: colors.ink),
      placeholderStyle: DeskTypography.base.copyWith(color: colors.secondary),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.line),
      ),
      onChanged: (_) => setState(() => _feedback = null),
      onSubmitted: (_) => unawaited(_submit()),
    );
    final open = DeskButton(
      '打开',
      key: const ValueKey('inbox-peer-lookup-open'),
      width: buttonWidth,
      height: controlHeight,
      busy: _busy,
      onTap: _available && !_busy && _input.text.trim().isNotEmpty
          ? _submit
          : null,
    );
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _busy &&
            !_opening) {
          _cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, bounds) =>
                bounds.maxWidth < 140 + 8 + buttonWidth
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field,
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerRight, child: open),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: field),
                      const SizedBox(width: 8),
                      open,
                    ],
                  ),
          ),
          if (_busy || _feedback != null || !_signedIn)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        !_signedIn
                            ? '登录 NodeSeek 后可以查找私信。'
                            : _feedback ?? (_opening ? '正在打开对话…' : '正在查找联系人…'),
                        style: DeskTypography.metadata.copyWith(
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ),
                  if (_busy && !_opening)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      onPressed: _cancel,
                      child: Text(
                        '取消',
                        style: DeskTypography.metadata.copyWith(
                          color: colors.accent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
