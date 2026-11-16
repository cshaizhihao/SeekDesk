import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import '../state/profile_space_memory.dart';
import '../models/snapshots.dart';
import '../widgets/profile_introduction_editor.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/forum_blocks.dart';
import 'inbox_screen.dart';
import 'activity_screen.dart';

enum _ProfileRecovery { retry, verification, login }

enum _IntroductionStatus { loading, ready, failure, verification, signedOut }

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    required this.state,
    this.memberId,
    this.onClose,
    super.key,
  });
  final AppState state;
  final int? memberId;

  /// A workspace destination returns through its owner instead of popping it.
  final VoidCallback? onClose;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late ProfileSpaceMemory memory;
  late final ScrollController overviewScroll;
  final editorController = ProfileIntroductionEditorController();
  JsonMap? editingOriginal;
  AppState? editingSource;
  ProfileSpaceMemory? editingMemory;
  Object? editingKey;
  int? editingRevision;
  int _owner = 0;
  bool _signedIn = false, _restoringOverview = false;
  String section = 'overview';
  JsonMap profile = {};
  JsonMap introduction = {};
  bool loading = true;
  String? error;
  _ProfileRecovery recovery = _ProfileRecovery.retry;
  _IntroductionStatus introductionStatus = _IntroductionStatus.loading;
  int generation = 0, revision = 0;
  bool _inFlight = false, _reloadRequested = false, _reloadForce = false;
  bool _reloadIntroductionOnly = false;
  bool get own =>
      widget.memberId == null ||
      widget.memberId == intValue(widget.state.domain('session')['owner']);

  int get member =>
      widget.memberId ?? intValue(widget.state.domain('session')['owner']);
  bool get privateSpace =>
      own &&
      widget.state.signedIn &&
      intValue(profile['id']) ==
          intValue(widget.state.domain('session')['owner']) &&
      intValue(profile['id']) > 0;
  List<String> get sections => [
    'overview',
    'discussions',
    'comments',
    if (privateSpace) ...['follow', 'fans'],
  ];
  static const sectionLabels = {
    'overview': '概况',
    'discussions': '主题',
    'comments': '回复',
    'follow': '关注',
    'fans': '粉丝',
  };

  void _bindMemory() {
    memory = widget.state.profileSpaces.forMember(member);
    section = memory.section;
    profile = memory.profile;
    introduction = memory.introduction;
    if (profile.isNotEmpty) {
      loading = false;
      introductionStatus = _IntroductionStatus.ready;
    }
  }

  void _rememberOverview() {
    if (!_restoringOverview &&
        overviewScroll.hasClients &&
        revision == widget.state.accessRevision) {
      memory.overviewOffset = math.max(0, overviewScroll.offset);
    }
  }

  void _restoreOverview() {
    _restoringOverview = true;
    final targetMemory = memory;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(memory, targetMemory)) return;
      // A changed identity may still be loading. Consume the restoration only
      // after its overview has attached; otherwise this controller's original
      // offset could leak into the new account's page.
      if (!overviewScroll.hasClients) return;
      overviewScroll.jumpTo(
        memory.overviewOffset.clamp(
          0.0,
          overviewScroll.position.maxScrollExtent,
        ),
      );
      _restoringOverview = false;
    });
  }

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    _owner = intValue(widget.state.domain('session')['owner']);
    _signedIn = widget.state.signedIn;
    _bindMemory();
    overviewScroll = ScrollController(
      initialScrollOffset: memory.overviewOffset,
      keepScrollOffset: false,
    )..addListener(_rememberOverview);
    widget.state.addListener(_identityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_inFlight && profile.isEmpty) _load();
    });
  }

  @override
  void didUpdateWidget(AccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_identityChanged);
      oldWidget.state.unregisterWorkspaceLeaveGuard(this);
      if (editingOriginal != null) {
        widget.state.registerWorkspaceLeaveGuard(this, _prepareLeave);
      }
      widget.state.addListener(_identityChanged);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.memberId != widget.memberId) {
      _resetIdentity();
    }
  }

  void _identityChanged() {
    if (!mounted ||
        revision == widget.state.accessRevision &&
            _owner == intValue(widget.state.domain('session')['owner']) &&
            _signedIn == widget.state.signedIn) {
      return;
    }
    _resetIdentity();
  }

  void _resetIdentity() {
    revision = widget.state.accessRevision;
    _owner = intValue(widget.state.domain('session')['owner']);
    _signedIn = widget.state.signedIn;
    generation++;
    setState(() {
      profile = {};
      introduction = {};
      introductionStatus = _IntroductionStatus.loading;
      loading = true;
      error = null;
      _bindMemory();
    });
    _restoreOverview();
    // Finish the old transport slot before reading the new identity. Captured
    // state/member/revision below also prevent its result from appearing here.
    _load();
  }

  Future<void> _load({
    bool force = false,
    bool introductionOnly = false,
  }) async {
    if (_inFlight) {
      _reloadIntroductionOnly = _reloadRequested
          ? _reloadIntroductionOnly && introductionOnly
          : introductionOnly;
      _reloadRequested = true;
      _reloadForce = _reloadForce || force;
      return;
    }
    _inFlight = true;
    final source = widget.state;
    final member = widget.memberId;
    final access = source.accessRevision;
    final token = ++generation;
    final requestOwner = intValue(source.domain('session')['owner']);
    final requestSignedIn = source.signedIn;
    final isOwn =
        member == null || member == intValue(source.domain('session')['owner']);
    bool current() =>
        mounted &&
        token == generation &&
        identical(widget.state, source) &&
        widget.memberId == member &&
        access == source.accessRevision &&
        requestOwner == intValue(source.domain('session')['owner']) &&
        requestSignedIn == source.signedIn;
    setState(() {
      loading = true;
      error = null;
      introductionStatus = _IntroductionStatus.loading;
    });
    try {
      var account = stringValue(
        source.domain('session')['account'],
        'unconfirmed',
      );
      if (!introductionOnly || !isOwn || profile.isEmpty) {
        final result = await source.act('profile.load', {
          'id': ?member,
          'force': force,
        });
        if (!current()) return;
        final raw = member == null
            ? jsonMap(result?['profile'])
            : jsonMap(result?['profile'] ?? result);
        account = stringValue(result?['account'] ?? account, 'unconfirmed');
        var loaded = _profile(raw);
        if (loaded.isEmpty && isOwn && account == 'signedIn') {
          loaded = _profile(source.profile);
        }
        if (member != null && loaded['id'] != member) loaded = {};
        setState(() {
          profile = loaded;
          introduction = {
            if (raw['signature_markdown'] is String)
              'signature': raw['signature_markdown'],
            if (raw['readme'] is String) 'readme': raw['readme'],
          };
          if (!isOwn) {
            introductionStatus = raw['readme'] is String
                ? _IntroductionStatus.ready
                : _IntroductionStatus.failure;
          }
        });
      }
      if (isOwn) {
        if (account == 'signedIn' && source.signedIn) {
          final detail = await source.act('profile.introduction');
          if (!current()) return;
          introductionStatus = switch (detail?['kind']) {
            'ready' => _IntroductionStatus.ready,
            'verification' => _IntroductionStatus.verification,
            'signedOut' => _IntroductionStatus.signedOut,
            _ => _IntroductionStatus.failure,
          };
          if (introductionStatus == _IntroductionStatus.ready) {
            // An empty ready payload is still an editable, empty introduction.
            introduction = jsonMap(detail?['data']);
          }
          if (introductionStatus == _IntroductionStatus.signedOut) {
            account = 'signedOut';
          }
        } else {
          introductionStatus = switch (account) {
            'signedOut' => _IntroductionStatus.signedOut,
            'unconfirmed' => _IntroductionStatus.verification,
            _ => _IntroductionStatus.failure,
          };
        }
      }
      if (!current()) return;
      setState(() {
        loading = false;
        if (profile.isEmpty) {
          if (isOwn && account == 'signedOut') {
            recovery = _ProfileRecovery.login;
            error = '当前尚未登录 NodeSeek，登录后即可查看自己的账号资料。';
          } else if (introductionStatus == _IntroductionStatus.verification ||
              isOwn && account == 'unconfirmed') {
            recovery = _ProfileRecovery.verification;
            error = account == 'unconfirmed'
                ? '尚未确认 NodeSeek 的访问状态。可打开站点确认访问，再重新加载资料。'
                : '请在 NodeSeek 窗口中完成站点验证，然后重新加载资料。';
          } else {
            recovery = _ProfileRecovery.retry;
            error = isOwn ? '暂时无法读取账号资料，请检查网络后重试。' : '暂时无法读取这位用户的资料，请稍后重试。';
          }
        }
      });
      if (profile.isNotEmpty &&
          introductionStatus == _IntroductionStatus.ready) {
        memory.profile = Map<String, dynamic>.unmodifiable(profile);
        memory.introduction = Map<String, dynamic>.unmodifiable(introduction);
      }
    } finally {
      _inFlight = false;
      if (mounted && _reloadRequested) {
        final forced = _reloadForce, onlyIntroduction = _reloadIntroductionOnly;
        _reloadRequested = false;
        _reloadForce = false;
        _reloadIntroductionOnly = false;
        _load(force: forced, introductionOnly: onlyIntroduction);
      }
    }
  }

  void _verify() =>
      widget.state.act('session.verify', {'url': 'https://www.nodeseek.com/'});

  void _recover() {
    switch (recovery) {
      case _ProfileRecovery.retry:
        _load(force: true);
      case _ProfileRecovery.verification:
        _verify();
      case _ProfileRecovery.login:
        widget.state.act('session.signIn');
    }
  }

  JsonMap _profile(JsonMap raw) {
    final id = intValue(raw['id'] ?? raw['member_id']);
    if (id <= 0) return {};
    return {
      ...raw,
      'id': id,
      'name': raw['name'] ?? raw['member_name'],
      'joined': raw['joined'] ?? raw['created_at_str'],
      'topics': raw['topics'] ?? raw['nPost'],
      'replies': raw['replies'] ?? raw['nComment'],
      'following': raw['following'] ?? raw['follows'],
      'followers': raw['followers'] ?? raw['fans'],
    };
  }

  void _editIntroduction() {
    if (!privateSpace ||
        introductionStatus != _IntroductionStatus.ready ||
        editingOriginal != null) {
      return;
    }
    setState(() {
      editingOriginal = Map<String, dynamic>.unmodifiable(introduction);
      editingSource = widget.state;
      editingMemory = memory;
      editingRevision = revision;
      editingKey = Object();
    });
    widget.state.registerWorkspaceLeaveGuard(this, _prepareLeave);
  }

  Future<bool> _prepareLeave() async {
    if (editingOriginal == null) return true;
    if (!editorController.isAttached) return false;
    return editorController.requestClose();
  }

  void _editorClosed(bool saved) {
    if (!mounted) return;
    final current =
        identical(editingSource, widget.state) &&
        identical(editingMemory, memory) &&
        editingRevision == widget.state.accessRevision;
    widget.state.unregisterWorkspaceLeaveGuard(this);
    setState(() {
      editingOriginal = null;
      editingSource = null;
      editingMemory = null;
      editingRevision = null;
      editingKey = null;
      if (saved && current) section = memory.section = 'overview';
    });
    if (saved && current) {
      memory.profile = memory.introduction = const {};
      unawaited(_load(force: true));
    }
  }

  Future<void> _selectSection(String next) async {
    if (next == section || !sections.contains(next)) return;
    final source = widget.state, currentMemory = memory;
    if (editingOriginal != null && !await _prepareLeave()) {
      return;
    }
    if (!mounted ||
        !identical(source, widget.state) ||
        !identical(currentMemory, memory) ||
        !sections.contains(next)) {
      return;
    }
    setState(() => section = memory.section = next);
  }

  Future<void> _close() async {
    final source = widget.state, currentMemory = memory;
    if (editingOriginal != null && !await _prepareLeave()) {
      return;
    }
    // Inline close updates PopScope on the next frame before a route can pop.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !identical(source, widget.state) ||
        !identical(currentMemory, memory)) {
      return;
    }
    if (widget.onClose case final close?) {
      close();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _refresh() async {
    final source = widget.state, currentMemory = memory;
    if (editingOriginal != null && !await _prepareLeave()) {
      return;
    }
    if (mounted &&
        identical(source, widget.state) &&
        identical(currentMemory, memory)) {
      await _load(force: true);
    }
  }

  Future<void> _openTopic(TopicData topic) async {
    final source = widget.state;
    final access = source.accessRevision;
    await source.openTopic(topic);
    if (!mounted ||
        access != source.accessRevision ||
        !identical(source, widget.state) ||
        widget.onClose != null) {
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(_identityChanged);
    widget.state.unregisterWorkspaceLeaveGuard(this);
    overviewScroll.dispose();
    super.dispose();
  }

  Widget _axis(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );

  Widget _tabs() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: _axis(
      LayoutBuilder(
        builder: (context, bounds) {
          final scale = MediaQuery.textScalerOf(context);
          final minimumWidth =
              sections.length * math.max(64.0, scale.scale(13) * 2 + 28);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SizedBox(
              width: math.max(bounds.maxWidth - 24, minimumWidth).toDouble(),
              child: GlassSegmentedControl(
                key: const ValueKey('profile-space-sections'),
                segments: [
                  for (final route in sections)
                    GlassSegment(label: sectionLabels[route]!),
                ],
                selectedIndex: math.max(0, sections.indexOf(section)),
                onSegmentSelected: (index) =>
                    unawaited(_selectSection(sections[index])),
                quality: GlassQuality.premium,
                height: math.max(34.0, scale.scale(13) * 1.4 + 12),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _overview(DeskColors colors) => SingleChildScrollView(
    key: const ValueKey('profile-overview-scroll'),
    controller: overviewScroll,
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
    child: _axis(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _identity(colors),
          const SizedBox(height: 16),
          _statistics(colors),
          if (stringValue(introduction['signature']).trim().isNotEmpty)
            DeskSection(
              quiet: true,
              title: '论坛签名',
              child: MarkdownDocument(
                state: widget.state,
                text: stringValue(introduction['signature']),
              ),
            ),
          _introduction(colors),
        ],
      ),
    ),
  );

  Widget _content(DeskColors colors) {
    if (_restoringOverview && profile.isNotEmpty) _restoreOverview();
    if (loading && profile.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (profile.isEmpty) {
      return DeskEmpty(
        switch (recovery) {
          _ProfileRecovery.retry => '暂时无法读取资料',
          _ProfileRecovery.verification => '确认 NodeSeek 访问',
          _ProfileRecovery.login => '登录后查看账号',
        },
        detail: error,
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            DeskButton(
              switch (recovery) {
                _ProfileRecovery.retry => '重试加载',
                _ProfileRecovery.verification => '验证访问',
                _ProfileRecovery.login => '登录 NodeSeek',
              },
              width: 140,
              onTap: _recover,
            ),
            if (recovery == _ProfileRecovery.verification)
              DeskButton('重试加载', width: 112, onTap: () => _load(force: true)),
          ],
        ),
      );
    }
    final routes = sections;
    return IndexedStack(
      index: math.max(0, routes.indexOf(section)),
      sizing: StackFit.expand,
      children: [
        _overview(colors),
        for (final route in routes.skip(1))
          Padding(
            key: ValueKey((revision, member, route)),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: _axis(
              ActivityPane(
                state: widget.state,
                memberId: intValue(profile['id']),
                route: route,
                active: editingOriginal == null && section == route,
                memory: memory.activity(route),
                onOpenTopic: (topic) => unawaited(_openTopic(topic)),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return PopScope(
      canPop: editingOriginal == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && editingOriginal != null) {
          unawaited(_prepareLeave());
        }
      },
      child: CupertinoPageScaffold(
        backgroundColor: widget.onClose == null
            ? colors.canvas
            : CupertinoColors.transparent,
        child: Stack(
          children: [
            if (widget.onClose == null)
              Positioned.fill(
                child: CustomPaint(painter: DeskBackdrop.themed(colors)),
              ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                    child: _axis(
                      DeskPageHeader(
                        title: own ? '我的账号' : '个人主页',
                        subtitle: section == 'overview' || profile.isEmpty
                            ? null
                            : '${stringValue(profile['name'])} · #${profile['id']}',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DeskIcon(
                              '刷新资料',
                              CupertinoIcons.arrow_clockwise,
                              loading ? null : () => unawaited(_refresh()),
                              busy: loading,
                              quiet: true,
                            ),
                            const SizedBox(width: 8),
                            DeskIcon(
                              '关闭账号',
                              CupertinoIcons.xmark,
                              () => unawaited(_close()),
                              quiet: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (profile.isNotEmpty) _tabs(),
                  Expanded(
                    child: IndexedStack(
                      index: editingOriginal == null ? 0 : 1,
                      sizing: StackFit.expand,
                      children: [
                        _content(colors),
                        if (editingOriginal != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                            child: _axis(
                              ProfileIntroductionEditor(
                                key: ValueKey(editingKey),
                                state: widget.state,
                                original: editingOriginal!,
                                controller: editorController,
                                onClose: _editorClosed,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _identity(DeskColors colors) {
    final id = intValue(profile['id']);
    final tags = <String>{
      for (final role in jsonItems(profile['roles']))
        if (stringValue(role['display_text']).trim().isNotEmpty)
          stringValue(role['display_text']).trim(),
      if (profile['tags'] is List)
        ...List.of(profile['tags'] as List)
            .whereType<String>()
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty),
    };
    final bio = stringValue(profile['bio']).trim();
    final joined = stringValue(profile['joined']).trim();
    return DeskGlassPanel(
      key: const ValueKey('account-identity'),
      quiet: true,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NativeAvatar(
                state: widget.state,
                name: stringValue(profile['name']),
                url: stringValue(
                  profile['avatar'],
                  'https://www.nodeseek.com/avatar/$id.png',
                ),
                size: 62,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        stringValue(profile['name']),
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'NodeSeek · #$id',
                      style: DeskTypography.metadata.copyWith(
                        color: colors.secondary,
                      ),
                    ),
                    if (profile['rank'] != null || tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (profile['rank'] != null)
                            _badge('等级 Lv.${profile['rank']}', colors),
                          for (final tag in tags) _badge(tag, colors),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (bio.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              bio,
              style: TextStyle(color: colors.ink, fontSize: 14, height: 1.5),
            ),
          ],
          if (joined.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '加入于 $joined',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (privateSpace &&
                  introductionStatus == _IntroductionStatus.ready)
                DeskButton(
                  '编辑签名与简介',
                  width: 160,
                  icon: CupertinoIcons.square_pencil,
                  onTap: _editIntroduction,
                ),
              if (own)
                DeskButton(
                  '切换账号',
                  width: 110,
                  icon: CupertinoIcons.person_crop_circle,
                  quiet: true,
                  onTap: () => widget.state.act('session.signIn'),
                ),
              DeskButton(
                '网页主页',
                width: 110,
                icon: CupertinoIcons.globe,
                quiet: true,
                onTap: () => widget.state.act('external.open', {
                  'url': 'https://www.nodeseek.com/space/$id',
                }),
              ),
              if (!own && widget.state.signedIn)
                DeskButton(
                  '发私信',
                  width: 110,
                  icon: CupertinoIcons.bubble_left,
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute<void>(
                      builder: (context) => InboxScreen(
                        state: widget.state,
                        initialPeer: id,
                        peerName: stringValue(profile['name']),
                        peerAvatar: stringValue(
                          profile['avatar'],
                          'https://www.nodeseek.com/avatar/$id.png',
                        ),
                        standalone: true,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, DeskColors colors) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: colors.selection,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: DeskTypography.metadata.copyWith(color: colors.accent),
    ),
  );

  Widget _statistics(DeskColors colors) {
    final fields = const {
      'topics': '主题',
      'replies': '回复',
      'following': '关注',
      'followers': '粉丝',
      'coin': '鸡腿',
    }.entries.where((field) => profile[field.key] != null).toList();
    if (fields.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DeskGlassPanel(
        key: const ValueKey('account-statistics'),
        quiet: true,
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final minimum = math.max(
              104.0,
              MediaQuery.textScalerOf(context).scale(20) * 4,
            );
            final columns = ((bounds.maxWidth + 12) / (minimum + 12))
                .floor()
                .clamp(1, fields.length);
            final width = (bounds.maxWidth - 12 * (columns - 1)) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final field in fields)
                  SizedBox(
                    width: width,
                    child: _metric(field.key, field.value, colors),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _metric(String field, String label, DeskColors colors) {
    final route = const {
      'topics': 'discussions',
      'replies': 'comments',
      'following': 'follow',
      'followers': 'fans',
    }[field];
    final value = '${profile[field]}';
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 22,
              color: colors.ink,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colors.secondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
    if (route == null ||
        !privateSpace && field != 'topics' && field != 'replies') {
      return Semantics(
        label: '$label，$value',
        excludeSemantics: true,
        child: content,
      );
    }
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: () => unawaited(_selectSection(route)),
      child: content,
    );
  }

  Widget _introduction(DeskColors colors) {
    final readme = stringValue(introduction['readme']);
    return DeskSection(
      quiet: true,
      title: '个人简介',
      subtitle: 'README',
      child: introductionStatus == _IntroductionStatus.ready
          ? readme.trim().isEmpty
                ? Text(
                    '还没有填写 README。',
                    style: TextStyle(color: colors.secondary, fontSize: 13),
                  )
                : MarkdownDocument(state: widget.state, text: readme)
          : introductionStatus == _IntroductionStatus.loading
          ? Row(
              children: [
                const CupertinoActivityIndicator(radius: 7),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在读取个人简介…',
                    style: TextStyle(color: colors.secondary, fontSize: 13),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    switch (introductionStatus) {
                      _IntroductionStatus.verification =>
                        '请先完成 NodeSeek 站点验证，再重新读取个人简介。',
                      _IntroductionStatus.signedOut => '登录已失效，请重新登录后读取个人简介。',
                      _ => '暂时无法读取个人简介。已读取的账号资料仍然保留。',
                    },
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (introductionStatus == _IntroductionStatus.verification)
                      DeskButton('验证访问', width: 112, onTap: _verify),
                    if (introductionStatus == _IntroductionStatus.signedOut)
                      DeskButton(
                        '登录 NodeSeek',
                        width: 140,
                        onTap: () => widget.state.act('session.signIn'),
                      ),
                    DeskButton(
                      '重新读取简介',
                      width: 128,
                      onTap: () => _load(force: true, introductionOnly: own),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
