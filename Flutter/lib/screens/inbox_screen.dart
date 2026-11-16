import 'dart:async';
import 'dart:math' as math;

// Flutter 3.50 still exports these APIs while package extraction is in progress.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/inbox_presentation.dart';
import '../core/native_client.dart';
import '../state/app_state.dart';
import '../state/inbox_navigation.dart';
import '../state/inbox_drafts.dart';
import '../widgets/forum_blocks.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/inbox_timeline.dart';
import '../widgets/inbox_notice_detail.dart';
import '../widgets/inbox_split_view.dart';
import '../widgets/inbox_composer.dart';
import '../widgets/inbox_peer_lookup.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    required this.state,
    this.initialPeer,
    this.peerName = '',
    this.peerAvatar = '',
    this.standalone = false,
    super.key,
  });
  final AppState state;
  final int? initialPeer;
  final String peerName, peerAvatar;
  final bool standalone;
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  static const kinds = ['mentions', 'replies', 'messages'];
  final Map<String, JsonMap> _cached = {};
  final _draft = TextEditingController();
  late final InboxNavigation _navigation;
  late final InboxDraftStore _drafts;
  final _listFocus = FocusScopeNode();
  final _composerGuard = InboxComposerNavigationGuard();
  int _navigationTicket = 0;
  int _loadTicket = 0;
  final Map<String, int> _reading = {};
  JsonMap? _observed;
  String _unreadSignature = '';
  Timer? _saveTimer;
  int _revision = 0;
  int _selected = 0;
  int? _peer;
  String _peerName = '';
  String _peerAvatar = '';
  String? _draftKey;
  bool _sending = false;
  bool _markdown = true;
  final Set<(String, int)> _markingRead = {};
  bool get _draftDirty =>
      _peer != null &&
      (_drafts.read(revision: _revision, peer: _peer!)?.dirty ?? false);
  String get _listKey => '${kinds[_selected]}:';
  bool get _detailOnly => widget.initialPeer != null && _peer != null;
  JsonMap get _listSnapshot => _cached[_listKey] ?? const {};
  JsonMap? get _noticeSelection => _navigation.notice;
  String? _feedback;
  bool _feedbackError = false;
  String get _kind => _peer == null ? kinds[_selected] : 'conversation';
  String get _key => '$_kind:${_peer ?? ''}';
  JsonMap get _snapshot => _cached[_key] ?? const {};

  @override
  void initState() {
    super.initState();
    _revision = widget.state.accessRevision;
    _drafts = widget.state.inboxDrafts;
    _drafts.addListener(_draftChanged);
    _navigation = !widget.standalone && widget.initialPeer == null
        ? widget.state.inboxNavigation
        : (InboxNavigation()..activate(_revision));
    _selected = _navigation.category;
    _peer = _navigation.peer;
    _peerName = _navigation.peerName;
    _peerAvatar = _navigation.peerAvatar;
    if (widget.initialPeer != null) {
      _selected = 2;
      _peer = widget.initialPeer;
      _peerName = widget.peerName;
      _peerAvatar = widget.peerAvatar;
    }
    _rememberLocation();
    widget.state.addListener(_changed);
    widget.state.registerDraftFlusher(this, _flushDraft);
    _changed(rebuild: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _changed({bool rebuild = true}) {
    if (!mounted) return;
    final accountChanged = _revision != widget.state.accessRevision;
    if (accountChanged) {
      _revision = widget.state.accessRevision;
      _navigationTicket++;
      _loadTicket++;
      _reading.clear();
      _navigation.activate(_revision);
      _selected = widget.initialPeer == null ? 0 : 2;
      _peer = widget.initialPeer;
      _peerName = '';
      _peerAvatar = '';
      _sending = false;
      _markingRead.clear();
      _saveTimer?.cancel();
      _cached.clear();
      _observed = null;
      _detachDraft();
      _feedback = null;
      // Explicit peer routes retain their shell, but require a fresh read before
      // accepting input. Workspace routes return to the new account's mentions.
      _rememberLocation();
      if (widget.initialPeer == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _peer == null && _selected == 0) _load();
        });
      }
    }
    final next = widget.state.domain('inbox');
    final unread = jsonMap(widget.state.domain('session')['unread']);
    final unreadSignature = kinds
        .map((kind) => intValue(unread[kind]))
        .join(':');
    final unreadChanged = _unreadSignature != unreadSignature;
    _unreadSignature = unreadSignature;
    if (identical(next, _observed)) {
      if (rebuild && (unreadChanged || accountChanged)) setState(() {});
      return;
    }
    _observed = next;
    if (next.isNotEmpty) {
      final key = '${next['kind']}:${next['peer'] ?? ''}';
      // Keep an already rendered list while its native cache is being checked.
      if (next['loading'] != true || !_cached.containsKey(key)) {
        _cached.remove(key);
        _cached[key] = next;
        while (_cached.length > 16) {
          _cached.remove(
            _cached.keys.firstWhere(
              (cachedKey) => cachedKey != _key && cachedKey != _listKey,
            ),
          );
        }
        if (key == _listKey &&
            next['loading'] != true &&
            stringValue(next['error']).isEmpty &&
            next['items'] is List) {
          _navigation.reconcileNotices(
            revision: _revision,
            category: _selected,
            items: jsonItems(next['items']),
          );
        }
      }
    }
    if (rebuild) setState(() {});
  }

  Future<void> _load({bool force = false, bool listOnly = false}) async {
    final ticket = ++_loadTicket, revision = _revision, key = _key;
    bool current() =>
        mounted &&
        ticket == _loadTicket &&
        revision == _revision &&
        revision == widget.state.accessRevision &&
        key == _key;
    Future<JsonMap?> read(String kind, {int? peer, bool force = false}) async {
      final target = '$kind:${peer ?? ''}';
      setState(() => _reading[target] = ticket);
      try {
        final result = await widget.state.loadInbox(
          kind,
          peer: peer,
          force: force,
          isCurrent: current,
        );
        // Cancelled/superseded reads cannot create an error for a newer route
        // or account. A current null result has no usable completion snapshot;
        // expose an explicit retry instead of retaining an endless spinner.
        if (!current()) return null;
        if (result == null) {
          setState(() {
            _cached[target] = {
              ...?_cached[target],
              'kind': kind,
              'peer': ?peer,
              'accessRevision': revision,
              'loading': false,
              'error': '此次读取未完成，请重试。',
            };
          });
        }
        return result;
      } finally {
        if (mounted && _reading[target] == ticket) {
          setState(() => _reading.remove(target));
        }
      }
    }

    // The native inbox currently has one active selection lane. On restoration
    // fill the left list first, then read the selected conversation; concurrent
    // reads would cancel one another.
    if (listOnly ||
        _peer != null && !_detailOnly && !_cached.containsKey(_listKey)) {
      await read(kinds[_selected], force: listOnly && force);
      if (!current()) return;
      // Retrying the left pane preserves an already usable conversation and
      // its editor. If its initial read was superseded, finish that read next
      // on the same native selection lane before enabling its draft.
      if (listOnly && (_peer == null || _draftKey == key)) return;
    }
    final result = await read(_kind, peer: _peer, force: !listOnly && force);
    // A remounted screen may see an old inbox snapshot before this read. Drafts
    // must come from the current request, never that stale snapshot. Once the
    // editor is enabled, later refreshes must not replace the user's input.
    if (current() &&
        result != null &&
        _peer != null &&
        _draftKey != key &&
        result['kind'] == 'conversation' &&
        result['peer'] == _peer &&
        result['loading'] != true &&
        stringValue(result['error']).isEmpty) {
      setState(() {
        _draftKey = key;
        final draft = _drafts.acquire(
          this,
          revision: revision,
          peer: _peer!,
          nativeContent: stringValue(result['draft']),
          nativeMarkdown: result['draftMarkdown'] != false,
        );
        _draft.text = draft?.content ?? '';
        _markdown = draft?.markdown ?? true;
        if (draft?.error != null) {
          _feedback = '这份私信草稿尚未保存，文字已恢复。请重试保存后再发送或关闭。';
          _feedbackError = true;
        }
      });
    }
  }

  void _rememberLocation() => _navigation.select(
    revision: _revision,
    category: _selected,
    peer: _peer,
    peerName: _peerName,
    peerAvatar: _peerAvatar,
  );

  int _beginNavigation() {
    final ticket = ++_navigationTicket;
    // Notify the inline lookup immediately, even while saving the old draft.
    // Its captured callback also checks this ticket before the next frame.
    setState(() {});
    return ticket;
  }

  Future<bool> _prepareNavigation(int ticket, int revision) async {
    do {
      if (!await _composerGuard.flush() ||
          !await _flushDraft() ||
          !mounted ||
          ticket != _navigationTicket ||
          revision != _revision) {
        return false;
      }
      // The editor remains responsive during local writes. Save any keystroke
      // arriving during the previous write before committing navigation.
    } while (_draftDirty);
    return true;
  }

  Future<void> _select(int value) async {
    if (_sending) return;
    final ticket = _beginNavigation(), revision = _revision;
    if (value == _selected && _peer == null) return;
    if (!await _prepareNavigation(ticket, revision)) return;
    setState(() {
      _detachDraft();
      _selected = value;
      _peer = null;
      _peerName = '';
      _peerAvatar = '';
      _feedback = null;
    });
    _rememberLocation();
    await _load();
  }

  Future<void> _open(JsonMap item) async {
    if (_sending) return;
    final category = _selected, revision = _revision;
    final peer = category == 2 ? intValue(item['id']) : null;
    if (category == 2 && peer! <= 0) return;
    final ticket = _beginNavigation();
    if (category == 2 && peer == _peer) return;
    if (!await _prepareNavigation(ticket, revision)) return;
    if (category != 2 &&
        !_navigation.chooseNotice(
          revision: revision,
          category: category,
          item: item,
        )) {
      return;
    }
    if (item['unread'] == true) unawaited(_markRead(item, category, revision));
    setState(() {
      if (category == 2) {
        _detachDraft();
        _peer = peer;
        _peerName = stringValue(item['name']);
        _peerAvatar = stringValue(item['avatar']);
        _rememberLocation();
      }
      _feedback = null;
    });
    if (category == 2) await _load();
  }

  Future<void> _markRead(JsonMap item, int category, int revision) async {
    final id = intValue(item['id']);
    if (id <= 0 ||
        category < 0 ||
        category >= kinds.length ||
        !mounted ||
        revision != _revision ||
        !widget.state.signedIn ||
        revision != widget.state.accessRevision) {
      return;
    }
    final operation = (kinds[category], id);
    if (!_markingRead.add(operation)) return;
    setState(() {});
    try {
      final result = await widget.state.act('inbox.markRead', {
        'kind': operation.$1,
        'id': id,
        if (category == 2) 'stamp': stringValue(item['date']),
      }, 'inbox');
      if (!mounted ||
          revision != _revision ||
          revision != widget.state.accessRevision) {
        return;
      }
      if (result != null &&
          jsonItems(
            result['items'],
          ).any((row) => intValue(row['id']) == id && row['unread'] == true)) {
        widget.state.showMessage('未能标为已读，请稍后重试。');
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _markingRead.remove(operation));
      }
    }
  }

  Future<bool> _openPeer(JsonMap peer, {required int generation}) async {
    final revision = _revision, id = intValue(peer['id']);
    if (_selected != 2 ||
        _sending ||
        id <= 0 ||
        generation != _navigationTicket) {
      return false;
    }
    final ticket = _peer == id ? generation : generation + 1;
    if (_peer == id) {
      if (_draftKey != _key) await _load();
    } else {
      await _open(peer);
    }
    final opened =
        mounted &&
        ticket == _navigationTicket &&
        revision == _revision &&
        revision == widget.state.accessRevision &&
        _selected == 2 &&
        _peer == id &&
        _draftKey == _key;
    if (!opened) return false;
    final list = _cached['messages:'];
    if (list != null &&
        intValue(list['accessRevision'], -1) == revision &&
        ![
          ...jsonItems(list['items']),
          ...jsonItems(list['olderItems']),
        ].any((item) => intValue(item['id']) == id)) {
      setState(
        () => _cached['messages:'] = {
          ...list,
          'olderItems': [
            {...peer, 'unread': false},
            ...jsonItems(list['olderItems']),
          ],
        },
      );
    }
    return true;
  }

  Future<void> _back() async {
    if (_sending) return;
    final ticket = _beginNavigation(), revision = _revision;
    if (!await _prepareNavigation(ticket, revision)) return;
    setState(() {
      _detachDraft();
      _peer = null;
      _peerName = '';
      _peerAvatar = '';
      _navigation.clearNotice(revision: revision, category: _selected);
      _rememberLocation();
      _feedback = null;
    });
    if (!_cached.containsKey(_listKey)) await _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ticket == _navigationTicket) _listFocus.requestFocus();
    });
  }

  void _detachDraft() {
    _saveTimer?.cancel();
    _drafts.release(this);
    _draftKey = null;
    _draft.clear();
    _markdown = true;
  }

  void _draftChanged() {
    if (!mounted ||
        _peer == null ||
        _draftKey != _key ||
        _revision != widget.state.accessRevision) {
      return;
    }
    final shared = _drafts.read(revision: _revision, peer: _peer!);
    if (shared == null) return;
    // Own edits already match. Only another view's actual edit replaces the
    // value, so normal typing never resets selection or IME composition.
    if (shared.content != _draft.text) {
      _draft.value = TextEditingValue(
        text: shared.content,
        selection: TextSelection.collapsed(offset: shared.content.length),
      );
    }
    if (_markdown != shared.markdown) {
      setState(() => _markdown = shared.markdown);
    }
  }

  void _editMarkdown(bool markdown) {
    if (_sending ||
        _draftKey != _key ||
        !_drafts.edit(this, _draft.text, markdown: markdown)) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _flushDraft);
  }

  void _editDraft(String text) {
    if (_draftKey != _key || !_drafts.edit(this, text)) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _flushDraft);
  }

  void _report(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _feedback = text;
      _feedbackError = error;
    });
  }

  Future<bool> _flushDraft() async {
    _saveTimer?.cancel();
    final peer = _peer, revision = _revision;
    if (peer == null || _draftKey == null) return true;
    final saved = await _drafts.flush(revision: revision, peer: peer);
    if (!saved &&
        mounted &&
        peer == _peer &&
        revision == _revision &&
        revision == widget.state.accessRevision) {
      _report('私信草稿保存失败，请重试保存后再发送或关闭。', error: true);
    }
    return saved;
  }

  Future<void> _send() async {
    if (_sending ||
        _peer == null ||
        _draftKey != _key ||
        !widget.state.signedIn ||
        _draft.text.trim().isEmpty ||
        (_draft.value.composing.isValid &&
            !_draft.value.composing.isCollapsed)) {
      return;
    }
    final content = _draft.text, revision = _revision, peer = _peer!;
    final markdown = _markdown;
    final version = _drafts.read(revision: revision, peer: peer)?.version;
    if (version == null) return;
    setState(() {
      _sending = true;
      _feedback = null;
    });
    try {
      if (!await _flushDraft() || !mounted || revision != _revision) return;
      final ready = _drafts.read(revision: revision, peer: peer);
      if (ready?.version != version ||
          ready?.content != content ||
          ready?.markdown != markdown) {
        _report('草稿已在其他窗口更新，请检查内容后再发送。', error: true);
        return;
      }
      final result = await widget.state.act('inbox.send', {
        'peer': peer,
        'markdown': markdown,
        'expectedContent': content,
        'expectedMarkdown': markdown,
      });
      if (revision == widget.state.accessRevision &&
          result?['kind'] == 'sent') {
        _drafts.confirmSent(revision: revision, peer: peer, version: version);
        await _drafts.flush(revision: revision, peer: peer);
      }
      if (!mounted || revision != _revision || peer != _peer) {
        return;
      }
      if (result == null) {
        _report('未确认发送成功，草稿已保留。请先刷新对话核对，再决定是否重试。', error: true);
        return;
      }
      if (result['kind'] == 'sent') {
        if (!await _flushDraft() || !mounted || revision != _revision) return;
        _report('私信已发送');
        await _load(force: true);
      } else {
        final message = stringValue(result['message']).trim();
        _report(
          message.isEmpty ? '未确认发送成功，草稿已保留。请先刷新对话核对，再决定是否重试。' : message,
          error: true,
        );
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _navigationTicket++;
    _loadTicket++;
    _flushDraft();
    _drafts.removeListener(_draftChanged);
    _drafts.release(this);
    _listFocus.dispose();
    widget.state.unregisterDraftFlusher(this);
    widget.state.removeListener(_changed);
    _saveTimer?.cancel();
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final lookupGeneration = _navigationTicket;
    final unread = jsonMap(widget.state.domain('session')['unread']);
    String label(int index) {
      final title = ['@我', '回复主题', '私信'][index];
      final count = intValue(unread[kinds[index]]);
      return count > 0 ? '$title ${count > 99 ? '99+' : count}' : title;
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(colors, _snapshot, [for (var i = 0; i < 3; i++) label(i)]),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: InboxSplitView(
              detailOnly: _detailOnly,
              hasDetail: _peer != null || _noticeSelection != null,
              list: FocusScope(
                node: _listFocus,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_selected == 2) ...[
                      InboxPeerLookup(
                        state: widget.state,
                        contacts: [
                          ...jsonItems(_listSnapshot['items']),
                          ...jsonItems(_listSnapshot['olderItems']),
                        ],
                        contactsRevision: intValue(
                          _listSnapshot['accessRevision'],
                          -1,
                        ),
                        enabled: !_sending,
                        navigationGeneration: lookupGeneration,
                        onOpen: (peer) =>
                            _openPeer(peer, generation: lookupGeneration),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: _timeline(
                        _listSnapshot,
                        colors,
                        conversation: false,
                      ),
                    ),
                  ],
                ),
              ),
              detailBuilder: (showBack) {
                if (_peer != null) {
                  return _conversation(colors, showBack: showBack);
                }
                final notice = _noticeSelection;
                if (notice != null) {
                  return InboxNoticeDetail(
                    state: widget.state,
                    notice: notice,
                    category: _selected,
                    revision: _revision,
                    onBack: _back,
                    showBack: showBack,
                  );
                }
                return _scrollEmpty(
                  DeskEmpty(
                    _selected == 2 ? '选择一段私信' : '选择一条通知',
                    detail: _selected == 2
                        ? '从左侧选择联系人，查看对话。'
                        : '从左侧选择通知，查看对应的回复。',
                    icon: CupertinoIcons.bubble_left_bubble_right,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
    return widget.standalone
        ? CupertinoPageScaffold(
            backgroundColor: colors.canvas,
            child: CustomPaint(
              painter: DeskBackdrop.themed(colors),
              child: SafeArea(child: body),
            ),
          )
        : body;
  }

  Widget _timeline(
    JsonMap value,
    DeskColors colors, {
    required bool conversation,
  }) {
    final recentItems = jsonItems(value['items']);
    final recentIDs = recentItems.map((item) => intValue(item['id'])).toSet();
    final olderItems = !conversation && _selected == 2
        ? jsonItems(value['olderItems']).where((item) {
            final id = intValue(item['id']);
            return id > 0 && recentIDs.add(id);
          }).toList()
        : const <JsonMap>[];
    final items = [...recentItems, ...olderItems];
    final rows = <({String? heading, JsonMap? item})>[
      if (olderItems.isNotEmpty && recentItems.isNotEmpty)
        (heading: '最近对话', item: null),
      for (final item in recentItems) (heading: null, item: item),
      if (olderItems.isNotEmpty) (heading: '较早的对话', item: null),
      for (final item in olderItems) (heading: null, item: item),
    ];
    final error = stringValue(value['error']);
    final location = conversation ? _key : _listKey;
    Widget retry() => DeskButton(
      widget.state.signedIn ? '重试' : '登录 NodeSeek',
      width: 130,
      busy: _reading.containsKey(location),
      onTap: _reading.containsKey(location)
          ? null
          : () {
              if (widget.state.signedIn) {
                _load(force: true, listOnly: !conversation);
              } else {
                widget.state.act('session.signIn', const {}, 'session');
              }
            },
    );
    final child = value.isEmpty || (value['loading'] == true && items.isEmpty)
        ? const Center(child: CupertinoActivityIndicator())
        : error.isNotEmpty && items.isEmpty
        ? _scrollEmpty(
            DeskEmpty(
              conversation ? '暂时无法读取对话' : '暂时无法读取通知',
              detail: error,
              icon: CupertinoIcons.envelope_badge,
              action: retry(),
            ),
            key: ValueKey('inbox-$location-recovery-scroll'),
          )
        : items.isEmpty
        ? _scrollEmpty(
            DeskEmpty(
              conversation
                  ? '还没有对话内容'
                  : ['暂无提到你的通知', '暂无帖子回复通知', '暂无私信'][_selected],
              detail: conversation ? '在下方输入内容，开始这次对话。' : '新的消息会在这里出现。',
              icon: CupertinoIcons.bubble_left_bubble_right,
            ),
          )
        : InboxTimeline(
            key: ValueKey((_revision, location)),
            navigation: _navigation,
            revision: _revision,
            location: location,
            conversation: conversation,
            tail: (items.last['id'], items.last['date'], items.last['text']),
            padding: conversation
                ? const EdgeInsets.all(14)
                : const EdgeInsets.symmetric(vertical: 4),
            itemCount: rows.length,
            separatorBuilder: (context, index) =>
                SizedBox(height: conversation ? 14 : 1),
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row.heading != null) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                  child: Semantics(
                    header: true,
                    child: Text(
                      row.heading!,
                      style: DeskTypography.metadata.copyWith(
                        color: colors.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              }
              return RepaintBoundary(
                child: conversation
                    ? _message(row.item!, colors)
                    : _notice(row.item!, colors),
              );
            },
          );
    final key = ValueKey(
      conversation ? 'inbox-conversation-surface' : 'inbox-category-surface',
    );
    return items.isNotEmpty
        ? DeskDocument(
            key: key,
            child: error.isEmpty
                ? child
                : LayoutBuilder(
                    builder: (context, bounds) => Column(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: math.min(120, bounds.maxHeight * .4),
                          ),
                          child: SingleChildScrollView(
                            primary: false,
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              children: [
                                Text(
                                  error,
                                  style: TextStyle(color: colors.secondary),
                                ),
                                const SizedBox(height: 6),
                                retry(),
                              ],
                            ),
                          ),
                        ),
                        Expanded(child: child),
                      ],
                    ),
                  ),
          )
        : SizedBox(key: key, child: child);
  }

  Widget _scrollEmpty(Widget child, {Key? key}) => LayoutBuilder(
    builder: (context, bounds) => SingleChildScrollView(
      key: key,
      primary: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: math.max(0, bounds.maxHeight)),
        child: child,
      ),
    ),
  );

  Widget _conversation(DeskColors colors, {required bool showBack}) => Padding(
    padding: EdgeInsets.only(left: showBack || _detailOnly ? 0 : 20),
    child: _readingAxis(
      child: LayoutBuilder(
        builder: (context, bounds) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
              child: Row(
                key: const ValueKey('inbox-contact-header'),
                children: [
                  if (showBack) ...[
                    DeskButton(
                      '返回私信列表',
                      icon: CupertinoIcons.chevron_left,
                      width: 132,
                      height: 32,
                      onTap: _sending ? null : _back,
                    ),
                    const SizedBox(width: 12),
                  ],
                  NativeAvatar(
                    state: widget.state,
                    name: _peerName,
                    url: _peerAvatar,
                    size: 30,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Tooltip(
                      message: _peerName.isEmpty ? 'NodeSeek 用户' : _peerName,
                      excludeFromSemantics: true,
                      child: Text(
                        _peerName.isEmpty ? 'NodeSeek 用户' : _peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, available) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_feedback != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(160, available.maxHeight * .5),
                        ),
                        child: SingleChildScrollView(
                          key: const ValueKey('inbox-feedback-scroll'),
                          primary: false,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Semantics(
                              liveRegion: true,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      (_feedbackError
                                              ? CupertinoColors.systemOrange
                                              : colors.accent)
                                          .withValues(alpha: .10),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _feedback!,
                                      style: TextStyle(
                                        color: colors.ink,
                                        fontSize: 13,
                                        height: 1.5,
                                      ),
                                    ),
                                    if (_drafts
                                            .read(
                                              revision: _revision,
                                              peer: _peer!,
                                            )
                                            ?.error !=
                                        null) ...[
                                      const SizedBox(height: 8),
                                      DeskButton(
                                        '重试保存',
                                        width: 102,
                                        height: 32,
                                        onTap: _sending
                                            ? null
                                            : () async {
                                                final peer = _peer,
                                                    revision = _revision;
                                                if (await _flushDraft() &&
                                                    mounted &&
                                                    peer == _peer &&
                                                    revision == _revision) {
                                                  _report('私信草稿已保存');
                                                }
                                              },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: _timeline(_snapshot, colors, conversation: true),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _composer(maxHeight: math.min(360, bounds.maxHeight * .52)),
          ],
        ),
      ),
    ),
  );

  Widget _readingAxis({required Widget child}) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );

  Widget _composer({required double maxHeight}) {
    final peer = _peer!, revision = _revision;
    bool current() =>
        mounted &&
        _revision == revision &&
        _peer == peer &&
        widget.state.accessRevision == revision &&
        _draftKey == 'conversation:$peer';
    return InboxComposer(
      key: const ValueKey('inbox-composer-row'),
      state: widget.state,
      controller: _draft,
      peer: peer,
      revision: revision,
      enabled: widget.state.signedIn && current(),
      sending: _sending,
      markdown: _markdown,
      onMarkdownChanged: _editMarkdown,
      onChanged: _editDraft,
      onSend: _send,
      flushDraft: _flushDraft,
      snapshot: _snapshot,
      navigationGuard: _composerGuard,
      isCurrent: current,
      maxHeight: maxHeight,
      synchronizeDraft: () async {
        if (!current()) return null;
        final result = await widget.state.client.call('inbox.getDraft', {
          'peer': peer,
        });
        return current() ? result : null;
      },
    );
  }

  Widget _header(
    DeskColors colors,
    JsonMap value,
    List<String> labels,
  ) => Padding(
    key: const ValueKey('inbox-header'),
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final scaler = MediaQuery.textScalerOf(context);
        double textWidth(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: DefaultTextStyle.of(context).style.merge(style),
            ),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        const titleStyle = TextStyle(fontSize: 19, fontWeight: FontWeight.w600);
        const segmentStyle = TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        );
        final segmentWidth = math.max(
          330.0,
          // Reserve the longest supported unread badge, so incoming counts
          // cannot reflow the header or recreate the glass indicator.
          ['@我 99+', '回复主题 99+', '私信 99+']
                      .map((label) => textWidth(label, segmentStyle))
                      .reduce((a, b) => math.max(a, b)) *
                  3 +
              72,
        );
        final actionsWidth = widget.standalone ? 72.0 : 32.0;
        final compact =
            bounds.maxWidth <
            textWidth('通知', titleStyle) + 20 + segmentWidth + 16 + actionsWidth;
        final title = Semantics(
          header: true,
          child: Text('通知', style: titleStyle.copyWith(color: colors.ink)),
        );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.standalone) ...[
              DeskIcon(
                '关闭私信',
                CupertinoIcons.xmark,
                _sending
                    ? null
                    : () async {
                        final ticket = _beginNavigation();
                        if (await _prepareNavigation(ticket, _revision) &&
                            context.mounted) {
                          Navigator.pop(context);
                        }
                      },
              ),
              const SizedBox(width: 8),
            ],
            DeskIcon(
              '刷新通知',
              CupertinoIcons.arrow_clockwise,
              _sending ? null : () => _load(force: true),
              busy: value['loading'] == true,
            ),
          ],
        );
        final segments = GlassSegmentedControl(
          key: const ValueKey('inbox-categories'),
          segments: [
            for (final label in labels)
              GlassSegment(label: label, enabled: !_sending),
          ],
          selectedIndex: _selected,
          onSegmentSelected: _sending ? (_) {} : _select,
          quality: GlassQuality.premium,
          height: math.max(34.0, scaler.scale(13) * 1.4 + 12),
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 16),
                  actions,
                ],
              ),
              const SizedBox(height: 10),
              // Preserve the user's text size even when all unread badges
              // cannot fit. The official glass control remains intact.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: SizedBox(
                  width: math.max(bounds.maxWidth - 24, segmentWidth),
                  child: segments,
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            title,
            const SizedBox(width: 20),
            SizedBox(width: segmentWidth, child: segments),
            const Spacer(),
            const SizedBox(width: 16),
            actions,
          ],
        );
      },
    ),
  );

  Widget _notice(JsonMap item, DeskColors colors) {
    final category = _selected, revision = _revision;
    bool current() =>
        mounted &&
        category == _selected &&
        revision == _revision &&
        revision == widget.state.accessRevision;
    final conversation = _selected == 2;
    final rawName = stringValue(item[conversation ? 'name' : 'author']);
    final name = rawName.isEmpty ? 'NodeSeek 用户' : rawName;
    final unread = item['unread'] == true;
    final date = inboxDateLabel(stringValue(item['date']));
    return _InboxNoticeRow(
      onTap: _sending
          ? null
          : () {
              if (current() && !_sending) unawaited(_open(item));
            },
      selected: conversation
          ? intValue(item['id']) == _peer
          : item['id'] == _navigation.noticeID,
      unread: unread,
      hint: conversation ? '打开私信对话' : '查看通知详情',
      action: unread
          ? DeskIcon(
              '标为已读',
              CupertinoIcons.checkmark_circle,
              _sending ||
                      _markingRead.contains((
                        kinds[_selected],
                        intValue(item['id']),
                      ))
                  ? null
                  : () {
                      if (current() && !_sending) {
                        unawaited(_markRead(item, category, revision));
                      }
                    },
              busy: _markingRead.contains((
                kinds[_selected],
                intValue(item['id']),
              )),
            )
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 10, unread ? 48 : 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NativeAvatar(
              state: widget.state,
              name: name,
              url: stringValue(item['avatar']),
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, bounds) => Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message: name,
                            excludeFromSemantics: true,
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 13,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: bounds.maxWidth * .42,
                          ),
                          child: _InboxDate(date: date, colors: colors),
                        ),
                        if (unread)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: colors.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    conversation
                        ? inboxSummary(stringValue(item['preview']))
                        : stringValue(item['title']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: conversation ? colors.secondary : colors.ink,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              CupertinoIcons.chevron_right,
              size: 12,
              color: colors.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(JsonMap item, DeskColors colors) {
    final mine = item['mine'] == true;
    final profile = widget.state.profile;
    final messagePeerName = stringValue(item['peerName']).trim();
    final rawName = mine
        ? stringValue(profile['name'], '我')
        : messagePeerName.isEmpty
        ? _peerName
        : messagePeerName;
    final name = rawName.isEmpty ? (mine ? '我' : 'NodeSeek 用户') : rawName;
    final date = inboxDateLabel(stringValue(item['date']));
    final avatar = NativeAvatar(
      state: widget.state,
      name: name,
      url: mine ? stringValue(profile['avatar']) : _peerAvatar,
      size: 30,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!mine) ...[avatar, const SizedBox(width: 10)],
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: name,
                        excludeFromSemantics: true,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DeskTypography.metadata.copyWith(
                            color: colors.secondary,
                          ),
                        ),
                      ),
                    ),
                    if (date.short.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: _InboxDate(date: date, colors: colors),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: mine
                        ? colors.accent.withValues(alpha: .10)
                        : colors.well,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: item['markdown'] == true
                      ? InlineMarkdown(
                          text: stringValue(item['text']),
                          state: widget.state,
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 14,
                            height: 1.65,
                          ),
                        )
                      : ForumTextSelection(
                          child: Text(
                            stringValue(item['text']),
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 14,
                              height: 1.65,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        if (mine) ...[const SizedBox(width: 10), avatar],
      ],
    );
  }
}

class _InboxDate extends StatelessWidget {
  const _InboxDate({required this.date, required this.colors});

  final InboxDateLabel date;
  final DeskColors colors;

  @override
  Widget build(BuildContext context) => date.short.isEmpty
      ? const SizedBox.shrink()
      : Tooltip(
          message: date.full,
          excludeFromSemantics: true,
          child: Text(
            date.short,
            semanticsLabel: date.full,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DeskTypography.metadata.copyWith(color: colors.secondary),
          ),
        );
}

/// Keep hover and keyboard feedback local to the row. CupertinoButton inside
/// HoverRow owns row activation; NativeAvatar retains its separate image retry.
class _InboxNoticeRow extends StatefulWidget {
  const _InboxNoticeRow({
    required this.onTap,
    required this.unread,
    required this.selected,
    required this.hint,
    required this.child,
    this.action,
  });

  final VoidCallback? onTap;
  final bool unread, selected;
  final String hint;
  final Widget child;
  final Widget? action;

  @override
  State<_InboxNoticeRow> createState() => _InboxNoticeRowState();
}

class _InboxNoticeRowState extends State<_InboxNoticeRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Semantics(
      value: widget.unread ? '未读' : '已读',
      selected: widget.selected,
      hint: widget.hint,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        child: Stack(
          children: [
            HoverRow(
              onTap: widget.onTap ?? () {},
              enabled: widget.onTap != null,
              focusColor: const Color(0x00000000),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.selected
                      ? colors.accent.withValues(alpha: .10)
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: widget.child,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _focused ? colors.accent : const Color(0x00000000),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.action != null)
              Positioned(top: 8, right: 8, child: widget.action!),
          ],
        ),
      ),
    );
  }
}
