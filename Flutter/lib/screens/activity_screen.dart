import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/activity_memory.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';
import 'account_screen.dart';

const _activityTitles = {
  'discussions': '主题帖',
  'comments': '评论',
  'fans': '粉丝',
  'follow': '关注',
};

/// Legacy routed destination. The same content can now live in a profile's
/// IndexedStack without introducing another navigation bar or background.
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({
    required this.state,
    required this.memberId,
    required this.route,
    super.key,
  });

  final AppState state;
  final int memberId;
  final String route;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return CupertinoPageScaffold(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: DeskBackdrop.themed(colors)),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(22),
                  child: Row(
                    children: [
                      DeskIcon(
                        '返回个人主页',
                        CupertinoIcons.chevron_left,
                        () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _activityTitles[route] ?? '个人空间',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DeskTypography.section.copyWith(
                                color: colors.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'NodeSeek · #$memberId',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DeskTypography.metadata.copyWith(
                                color: colors.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                    child: ActivityPane(
                      state: state,
                      memberId: memberId,
                      route: route,
                      onOpenTopic: (topic) {
                        unawaited(state.openTopic(topic));
                        Navigator.of(context)
                            .popUntil((route) => route.isFirst);
                      },
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

/// One retained profile tab. Set [active] only for the selected tab: unseen
/// tabs do not read, and returning to a loaded tab does not force a refresh.
///
/// An optional [memory] restores the last successful page after the entire
/// profile is unmounted. It must belong to this account/member/route; identity
/// checks also clear it defensively. Callbacks let the profile own navigation.
class ActivityPane extends StatefulWidget {
  const ActivityPane({
    required this.state,
    required this.memberId,
    required this.route,
    this.active = true,
    this.memory,
    this.onOpenMember,
    this.onOpenTopic,
    super.key,
  });

  final AppState state;
  final int memberId;
  final String route;
  final bool active;
  final ActivityPaneMemory? memory;
  final ValueChanged<int>? onOpenMember;
  final ValueChanged<TopicData>? onOpenTopic;

  @override
  State<ActivityPane> createState() => _ActivityPaneState();
}

class _ActivityPaneState extends State<ActivityPane> {
  late ActivityPaneMemory _memory;
  late final ScrollController _scroll;
  int _generation = 0, _identity = 0, _revision = 0, _owner = 0;
  int _scrollRestoreGeneration = 0;
  bool _signedIn = false, _attempted = false, _loading = false;
  bool _restoringScroll = false;
  int? _failedPage;
  String? _error;

  bool get _members => widget.route == 'fans' || widget.route == 'follow';
  String get _title => _activityTitles[widget.route] ?? '个人空间';

  @override
  void initState() {
    super.initState();
    _memory = widget.memory ?? ActivityPaneMemory();
    _captureIdentity();
    _activateMemory();
    _scroll = ScrollController(
      initialScrollOffset: _memory.offsetFor(_memory.page),
    );
    _scroll.addListener(_rememberScroll);
    widget.state.addListener(_identityChanged);
    _activate();
  }

  void _captureIdentity() {
    _revision = widget.state.accessRevision;
    _owner = intValue(widget.state.domain('session')['owner']);
    _signedIn = widget.state.signedIn;
  }

  void _activateMemory() => _memory.activate(
    revision: _revision,
    memberId: widget.memberId,
    route: widget.route,
    owner: _owner,
    signedIn: _signedIn,
  );

  @override
  void didUpdateWidget(ActivityPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = !identical(oldWidget.state, widget.state);
    if (sourceChanged) {
      oldWidget.state.removeListener(_identityChanged);
      widget.state.addListener(_identityChanged);
    }
    if (sourceChanged ||
        oldWidget.memberId != widget.memberId ||
        oldWidget.route != widget.route ||
        !identical(oldWidget.memory, widget.memory)) {
      _rememberScroll();
      if (!identical(oldWidget.memory, widget.memory)) {
        _memory = widget.memory ?? ActivityPaneMemory();
      }
      _resetIdentity();
    } else if (_revision != widget.state.accessRevision ||
        _owner != intValue(widget.state.domain('session')['owner']) ||
        _signedIn != widget.state.signedIn) {
      _resetIdentity();
    } else if (widget.active && !oldWidget.active) {
      _activate();
    }
  }

  void _identityChanged() {
    if (!mounted) return;
    if (_revision != widget.state.accessRevision ||
        _owner != intValue(widget.state.domain('session')['owner']) ||
        _signedIn != widget.state.signedIn) {
      _resetIdentity();
    }
  }

  void _resetIdentity() {
    _generation++;
    _identity++;
    _captureIdentity();
    _activateMemory();
    setState(() {
      _loading = false;
      _attempted = false;
      _failedPage = null;
      _error = null;
    });
    _restoreScroll();
    _activate();
  }

  String? get _accessProblem {
    if (!_activityTitles.containsKey(widget.route) || widget.memberId <= 0) {
      return '个人空间栏目或用户编号无效。';
    }
    if (_members && (!_signedIn || _owner != widget.memberId)) {
      return '只能读取当前账号的粉丝和关注列表。';
    }
    return null;
  }

  void _activate() {
    if (!widget.active || _attempted || _memory.loaded) return;
    unawaited(_load(_memory.page));
  }

  void _rememberScroll() {
    if (!_restoringScroll && _scroll.hasClients && _memory.loaded) {
      _memory.rememberOffset(_memory.page, _scroll.offset);
    }
  }

  void _restoreScroll() {
    _restoringScroll = true;
    final identity = _identity, restore = ++_scrollRestoreGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          identity != _identity ||
          restore != _scrollRestoreGeneration) {
        return;
      }
      if (_scroll.hasClients) {
        final offset = _memory
            .offsetFor(_memory.page)
            .clamp(0.0, _scroll.position.maxScrollExtent);
        _scroll.jumpTo(offset.toDouble());
      }
      _restoringScroll = false;
      _rememberScroll();
    });
  }

  Future<void> _load(int target) async {
    if (!mounted ||
        !widget.active ||
        _loading ||
        target < 1 ||
        target > 10000) {
      return;
    }
    final problem = _accessProblem;
    if (problem != null) {
      setState(() {
        _attempted = true;
        _error = problem;
      });
      return;
    }
    _rememberScroll();
    final source = widget.state, member = widget.memberId, route = widget.route;
    final access = _revision, owner = _owner, signedIn = _signedIn;
    final memory = _memory, token = ++_generation;
    bool current() =>
        mounted &&
        token == _generation &&
        identical(source, widget.state) &&
        identical(memory, _memory) &&
        member == widget.memberId &&
        route == widget.route &&
        access == source.accessRevision &&
        owner == intValue(source.domain('session')['owner']) &&
        signedIn == source.signedIn;
    setState(() {
      _attempted = true;
      _loading = true;
      if (!_memory.loaded) _error = null;
    });
    try {
      // The dedicated native result keeps independent profile tabs isolated.
      final result = await source.client.call(
        _members ? 'space.members' : 'space.activity',
        {'memberId': member, 'route': route, if (!_members) 'page': target},
      );
      if (!current()) return;
      if (intValue(result['accessRevision'], access) != access ||
          result['memberId'] != null && result['memberId'] != member ||
          result['route'] != null && result['route'] != route ||
          result['page'] != null && result['page'] != target ||
          result['items'] is! List) {
        throw const NativeFailure('stale_activity', '读取结果已过期，请重新读取。');
      }
      _rememberScroll();
      setState(() {
        memory.acceptPage(
          page: target,
          items: jsonItems(result['items']),
          hasNext: !_members && result['hasNext'] == true,
        );
        _failedPage = null;
        _error = null;
        _loading = false;
      });
      _restoreScroll();
    } catch (failure) {
      if (!current()) return;
      setState(() {
        _failedPage = target;
        _error = failure.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _rememberScroll();
    _generation++;
    widget.state.removeListener(_identityChanged);
    _scroll.removeListener(_rememberScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final writable = widget.active && !_loading && _accessProblem == null;
    final error = _accessProblem ?? _error;
    final scale = MediaQuery.textScalerOf(context);
    final buttonHeight = math.max(32.0, scale.scale(12) * 1.3 + 14);
    Widget retry() => DeskButton(
      '重新读取',
      height: buttonHeight,
      width: math.max(104.0, scale.scale(12) * 4 + 28),
      onTap: writable
          ? () => unawaited(_load(_failedPage ?? _memory.page))
          : null,
    );
    Widget empty(Widget child, {Key? key}) => LayoutBuilder(
      builder: (context, bounds) => SingleChildScrollView(
        key: key,
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, bounds.maxHeight)),
          child: child,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(120, bounds.maxHeight * .35),
            ),
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!_members) ...[
                    DeskButton(
                      '上一页',
                      quiet: true,
                      width: math.max(86.0, scale.scale(12) * 3 + 26),
                      height: buttonHeight,
                      onTap: writable && _memory.page > 1
                          ? () => unawaited(_load(_memory.page - 1))
                          : null,
                    ),
                    Text(
                      '第 ${_memory.page} 页',
                      style: DeskTypography.control.copyWith(
                        color: colors.secondary,
                      ),
                    ),
                    DeskButton(
                      '下一页',
                      quiet: true,
                      width: math.max(86.0, scale.scale(12) * 3 + 26),
                      height: buttonHeight,
                      onTap: writable && _memory.hasNext
                          ? () => unawaited(_load(_memory.page + 1))
                          : null,
                    ),
                  ] else if (_memory.loaded)
                    Text(
                      '${_memory.items.length} 位用户',
                      style: DeskTypography.control.copyWith(
                        color: colors.secondary,
                      ),
                    ),
                  DeskIcon(
                    '刷新$_title',
                    CupertinoIcons.arrow_clockwise,
                    writable ? () => unawaited(_load(_memory.page)) : null,
                    busy: _loading,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: DeskDocument(
              child: LayoutBuilder(
                builder: (context, bodyBounds) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null && _memory.loaded)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(160, bodyBounds.maxHeight * .4),
                        ),
                        child: SingleChildScrollView(
                          key: ValueKey('activity-${widget.route}-feedback'),
                          primary: false,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  error,
                                  style: DeskTypography.control.copyWith(
                                    color: colors.secondary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              retry(),
                            ],
                          ),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                    Expanded(
                      key: ValueKey('activity-${widget.route}-body'),
                      child: !_memory.loaded
                          ? _loading
                                ? const Center(
                                    child: CupertinoActivityIndicator(),
                                  )
                                : error != null
                                ? empty(
                                    DeskEmpty(
                                      '暂时无法读取$_title',
                                      detail: error,
                                      action: _accessProblem == null
                                          ? retry()
                                          : null,
                                    ),
                                    key: ValueKey(
                                      'activity-${widget.route}-recovery',
                                    ),
                                  )
                                : const SizedBox.shrink()
                          : _memory.items.isEmpty
                          ? empty(
                              DeskEmpty(
                                '暂无$_title',
                                detail: _members
                                    ? '这里会显示当前账号的$_title列表。'
                                    : '这一页还没有内容。',
                              ),
                            )
                          : ListView.separated(
                              key: ValueKey('activity-${widget.route}-list'),
                              controller: _scroll,
                              padding: const EdgeInsets.all(12),
                              itemCount: _memory.items.length,
                              separatorBuilder: (context, index) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                child: Container(height: 1, color: colors.line),
                              ),
                              itemBuilder: (context, index) => _members
                                  ? _member(_memory.items[index], colors)
                                  : _activity(_memory.items[index], colors),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _member(JsonMap item, DeskColors colors) {
    final identity = _identity, id = intValue(item['id']);
    final name = stringValue(item['name']);
    return HoverRow(
      enabled: widget.active && id > 0,
      onTap: () {
        if (!mounted ||
            identity != _identity ||
            !widget.active ||
            _accessProblem != null ||
            id <= 0) {
          return;
        }
        if (widget.onOpenMember != null) {
          widget.onOpenMember!(id);
        } else {
          Navigator.push(
            context,
            CupertinoPageRoute<void>(
              builder: (context) =>
                  AccountScreen(state: widget.state, memberId: id),
            ),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            NativeAvatar(
              state: widget.state,
              name: name,
              url: stringValue(item['avatar']),
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DeskTypography.base.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '#$id',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DeskTypography.metadata.copyWith(
                  color: colors.secondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              CupertinoIcons.chevron_right,
              color: colors.secondary,
              size: 12,
            ),
          ],
        ),
      ),
    );
  }

  Widget _activity(JsonMap item, DeskColors colors) {
    final identity = _identity;
    final millis = numberValue(item['publishedMillis']);
    final published = millis > 0 && millis <= 8640000000000000
        ? DateTime.fromMillisecondsSinceEpoch(millis.round()).toLocal()
        : null;
    return HoverRow(
      enabled: widget.active,
      onTap: () {
        if (!mounted ||
            identity != _identity ||
            !widget.active ||
            _accessProblem != null) {
          return;
        }
        final topic = TopicData({...item, 'id': '${item['postId']}'});
        if (widget.onOpenTopic != null) {
          widget.onOpenTopic!(topic);
        } else {
          unawaited(widget.state.openTopic(topic));
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              stringValue(item['title']),
              textAlign: TextAlign.start,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: DeskTypography.base.copyWith(
                color: colors.ink,
                fontSize: numberValue(
                  widget.state.domain('settings')['workspace.listTextSize'],
                  15,
                ),
                fontWeight: FontWeight.w500,
              ),
            ),
            if (stringValue(item['text']).isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '#${item['floor']}  ${item['text']}',
                textAlign: TextAlign.start,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: DeskTypography.base.copyWith(
                  color: colors.secondary,
                  fontSize: 13,
                ),
              ),
            ],
            if (published != null) ...[
              const SizedBox(height: 8),
              Text(
                '${published.year}-${published.month.toString().padLeft(2, '0')}-${published.day.toString().padLeft(2, '0')}',
                textAlign: TextAlign.start,
                style: DeskTypography.metadata.copyWith(
                  color: colors.secondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
