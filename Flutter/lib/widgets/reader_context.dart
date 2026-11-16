import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/native_client.dart';
import '../core/frame_diagnostics.dart';
import 'editor_header_diagnostics.dart';
import 'desk_material_scope.dart';
import '../models/snapshots.dart';
import '../screens/account_screen.dart';
import '../state/app_state.dart';
import 'forum_blocks.dart';
import 'glass_chrome.dart';

/// Both ends of the discussion use the same page set and navigation identity.
class ReaderPagination extends StatelessWidget {
  const ReaderPagination({
    required this.state,
    required this.topic,
    required this.thread,
    required this.position,
    super.key,
  });
  final AppState state;
  final TopicData topic;
  final ThreadData thread;
  final String position;

  @override
  Widget build(BuildContext context) {
    final current = thread.page > 0 ? thread.page : 1;
    final currentURL = AppState.webLink(topic.url);
    final route = currentURL == null
        ? null
        : RegExp(r'^/post-([1-9][0-9]*)-[1-9][0-9]*/?$')
              .firstMatch(currentURL.path);
    final pages = <int, String>{current: topic.url};
    for (final page in thread.pages) {
      final number = intValue(page['number']);
      final uri = AppState.webLink(stringValue(page['url']));
      // Page links must stay inside this topic, even if a malformed snapshot
      // contains links to another post or a non-forum destination.
      if (number > 0 &&
          uri != null &&
          route != null &&
          const ['nodeseek.com', 'www.nodeseek.com'].contains(uri.host) &&
          uri.path.replaceAll(RegExp(r'/$'), '') ==
              '/post-${route[1]}-$number') {
        pages[number] = uri.removeFragment().toString();
      }
    }
    if (pages.length <= 1) return const SizedBox.shrink();
    final numbers = pages.keys.toList()..sort();
    void open(int page) => state.openTopic(
      TopicData({'id': topic.id, 'url': pages[page], 'title': thread.title}),
    );
    return SingleChildScrollView(
      key: ValueKey('reader-pagination:$position'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          DeskButton(
            '上一页',
            width: 70,
            height: 30,
            onTap: pages.containsKey(current - 1)
                ? () => open(current - 1)
                : null,
          ),
          for (final page in numbers) ...[
            const SizedBox(width: 7),
            Semantics(
              selected: page == current,
              child: DeskButton(
                '$page',
                semanticLabel: page == current ? '第 $page 页，当前页' : '第 $page 页',
                width: 38,
                height: 30,
                selected: page == current,
                tint: page == current ? DeskColors(context).selectionInk : null,
                onTap: page == current ? null : () => open(page),
              ),
            ),
          ],
          const SizedBox(width: 7),
          DeskButton(
            '下一页',
            width: 70,
            height: 30,
            onTap: pages.containsKey(current + 1)
                ? () => open(current + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

/// Enrichment belongs to this mounted floor. Its body is passed through as a
/// stable child, with no loading placeholders that would move the document.
class ReaderFloorContext extends StatefulWidget {
  const ReaderFloorContext({
    required this.state,
    required this.topic,
    required this.floor,
    required this.root,
    required this.authorScale,
    required this.profilesSupported,
    required this.actions,
    required this.body,
    this.preserveAnchor,
    super.key,
  });
  final AppState state;
  final TopicData topic;
  final FloorData floor;
  final bool root, profilesSupported;
  final double authorScale;
  final List<Widget> actions;
  final Widget body;
  final VoidCallback Function()? preserveAnchor;
  @override
  State<ReaderFloorContext> createState() => _ReaderFloorContextState();
}

class _ReaderFloorContextState extends State<ReaderFloorContext> {
  // The actions move beside/below the author at narrow widths. Reparent the
  // mounted group so resizing does not discard button focus or press state.
  final _actionsKey = GlobalKey();
  Future<JsonMap?>? _profile;
  JsonMap _data = {};
  JsonMap? _pendingData;
  ScrollableState? _scrollable;
  ScrollPosition? _waitingPosition;
  VoidCallback? _cancelWait;
  int _waitGeneration = 0;
  int _revision = -1, _generation = 0;
  @override
  void initState() {
    super.initState();
    _load(seedCache: true);
  }

  @override
  void didUpdateWidget(ReaderFloorContext oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.floor.authorID != widget.floor.authorID ||
        oldWidget.topic.url != widget.topic.url ||
        _revision != widget.state.accessRevision) {
      _data = {};
      _pendingData = null;
      _profile = null;
      _generation++;
      _stopWait();
    }
    _load();
  }

  void _load({bool seedCache = false}) {
    _revision = widget.state.accessRevision;
    final id = widget.floor.authorID;
    if (!widget.profilesSupported || id == null) return;
    if (seedCache) {
      final cached = widget.state.cachedReaderAuthor(widget.topic.url, id);
      if (cached != null) _data = cached;
    }
    final future = widget.state.readerAuthor(widget.topic.url, id);
    if (identical(future, _profile)) return;
    _profile = future;
    _pendingData = null;
    _stopWait();
    final generation = ++_generation, access = _revision;
    unawaited(() async {
      final data = await future;
      if (data == null ||
          identical(data, _data) ||
          !mounted ||
          generation != _generation ||
          access != widget.state.accessRevision) {
        return;
      }
      _pendingData = data;
      // Reuse the active build's owner without looking up inherited widgets
      // from an async callback that may run after this floor is deactivated.
      final owner = _scrollable;
      if (owner != null && owner.position.isScrollingNotifier.value) {
        _waitForIdle(owner);
      } else {
        setState(() {});
      }
    }());
  }

  void _stopWait() {
    _waitGeneration++;
    _cancelWait?.call();
    _cancelWait = null;
    _waitingPosition = null;
  }

  void _waitForIdle(ScrollableState owner) {
    final position = owner.position;
    if (identical(position, _waitingPosition)) return;
    _stopWait();
    _waitingPosition = position;
    final generation = _waitGeneration;
    var queued = false;
    void changed() {
      if (position.isScrollingNotifier.value || queued) return;
      queued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _waitGeneration) return;
        queued = false;
        if (_revision != widget.state.accessRevision) {
          _pendingData = null;
          _stopWait();
          return;
        }
        if (identical(owner.position, position) &&
            position.isScrollingNotifier.value) {
          return;
        }
        setState(() {});
      });
      WidgetsBinding.instance.scheduleFrame();
    }

    position.isScrollingNotifier.addListener(changed);
    _cancelWait = () => position.isScrollingNotifier.removeListener(changed);
  }

  void _adoptPending(ScrollableState? owner) {
    if (_revision != widget.state.accessRevision) {
      _pendingData = null;
      _stopWait();
      return;
    }
    final pending = _pendingData;
    if (pending == null) return;
    if (owner != null && owner.position.isScrollingNotifier.value) {
      _waitForIdle(owner);
      return;
    }
    _stopWait();
    final restore = widget.preserveAnchor?.call();
    _data = pending;
    _pendingData = null;
    if (restore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => restore());
    }
  }

  @override
  void deactivate() {
    _scrollable = null;
    _stopWait();
    super.deactivate();
  }

  @override
  void dispose() {
    _generation++;
    _pendingData = null;
    _stopWait();
    super.dispose();
  }

  void _open() {
    if (widget.floor.authorID == null) return;
    Navigator.push(
      context,
      CupertinoPageRoute<void>(
        builder: (_) =>
            AccountScreen(state: widget.state, memberId: widget.floor.authorID),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _scrollable = Scrollable.maybeOf(context);
    _adoptPending(_scrollable);
    final profile = _revision == widget.state.accessRevision
        ? _data
        : const <String, dynamic>{};
    final floor = widget.floor;
    final colors = DeskColors(context);
    final scale = widget.authorScale.clamp(.75, 1.6);
    final rank = profile['rank'];
    final tags = <String>{
      ...floor.tags,
      for (final role in jsonItems(profile['roles']))
        if (stringValue(role['display_text']).trim().isNotEmpty)
          stringValue(role['display_text']).trim(),
      if (profile['tags'] is List)
        ...List.of(profile['tags'] as List).whereType<String>(),
      if (widget.root || floor.isAuthor) '楼主',
    };
    final own =
        floor.authorID != null &&
        floor.authorID == intValue(widget.state.domain('session')['owner'], -1);
    final signatureIsMarkdown =
        own && profile.containsKey('ownSignature') ||
        floor.signature.isNotEmpty ||
        profile['signature_markdown'] is String;
    final signature = own && profile.containsKey('ownSignature')
        ? stringValue(profile['ownSignature'])
        : floor.signature.isNotEmpty
        ? floor.signature
        : profile['signature_markdown'] is String
        ? profile['signature_markdown'] as String
        : stringValue(profile['bio']);
    Widget entry(Widget child, String label) => Semantics(
      button: floor.authorID != null,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: floor.authorID == null ? null : _open,
        child: MouseRegion(
          cursor: floor.authorID == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: child,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, bounds) {
            final avatarSize = (widget.root ? 35 : 28) * scale;
            final scaledNameSize = MediaQuery.textScalerOf(context)
                .scale(13 * scale);
            final effectiveScale = scaledNameSize / 13;
            final trailingLimit = bounds.maxWidth * .28;
            // Reserve a useful author column before placing metadata beside
            // it. A large system font must not let an unbounded floor number
            // squeeze names and dates down to a character per line.
            final availableIdentityWidth =
                bounds.maxWidth - avatarSize - 18 - trailingLimit;
            final compact =
                bounds.maxWidth < 420 ||
                effectiveScale > 1.25 && bounds.maxWidth < 520 ||
                availableIdentityWidth < scaledNameSize * 9;
            final floorNumber = Text(
              '#${floor.id}',
              textAlign: TextAlign.end,
              style: DeskTypography.metadata.copyWith(
                color: colors.secondary,
                fontSize: 11 * scale,
              ),
            );
            final actions = sampleEditorBuild(
              kind: UiWorkKind.readerActionsBuild,
              child: DeskMaterialScope(
                key: _actionsKey,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  runSpacing: 4,
                  children: widget.actions,
                ),
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    entry(
                      NativeAvatar(
                        state: widget.state,
                        name: floor.author,
                        url: floor.avatar,
                        size: avatarSize,
                      ),
                      '${floor.author} 的头像，查看资料',
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Share the identity line when there is room. Each
                          // item keeps its real text size and can wrap within
                          // this author column rather than truncating a name
                          // or reserving a permanent extra row for metadata.
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              entry(
                                Text(
                                  floor.author,
                                  style: TextStyle(
                                    color: colors.ink,
                                    fontSize: 13 * scale,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                  ),
                                ),
                                '${floor.author}，查看资料',
                              ),
                              if (rank is num)
                                _AuthorBadge(
                                  'Lv.${rank.toInt()}',
                                  scale: scale,
                                  color: _rankColor(rank.toInt(), colors),
                                ),
                              for (final tag in tags)
                                _roleBadge(tag, colors, scale),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            floor.date.isNotEmpty
                                ? floor.date
                                : floor.dateLabel,
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 11 * scale,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: trailingLimit),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            floorNumber,
                            if (widget.actions.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              actions,
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                if (compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: floorNumber),
                        if (widget.actions.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: bounds.maxWidth / 2,
                            ),
                            child: actions,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        widget.body,
        if (signature.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 12),
            child: signatureIsMarkdown
                ? InlineMarkdown(
                    text: signature,
                    state: widget.state,
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 11,
                      height: 1.6,
                    ),
                  )
                : ForumTextSelection(
                    child: Text(
                      signature,
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 11,
                        height: 1.6,
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}

Color _rankColor(int rank, DeskColors colors) {
  if (rank <= 0) return colors.secondary;
  const hues = [
    147.0,
    188.0,
    215.0,
    251.0,
    285.0,
    33.0,
    10.0,
    323.0,
    69.0,
    170.0,
  ];
  final cycle = (rank - 1) ~/ hues.length;
  final hue = (hues[(rank - 1) % hues.length] + cycle * 11) % 360;
  return HSLColor.fromAHSL(1, hue, .58, colors.dark ? .76 : .30).toColor();
}

Widget _roleBadge(String tag, DeskColors colors, double scale) {
  final normalized = tag.toLowerCase();
  final (icon, color) = switch (normalized) {
    '楼主' => (CupertinoIcons.person_crop_circle_fill, colors.accent),
    '管理' || '管理员' || '版主' || 'admin' || 'moderator' => (
      CupertinoIcons.shield_fill,
      colors.dark ? const Color(0xfff3c883) : const Color(0xff815210),
    ),
    'vip' || '赞助者' || '赞助' => (
      CupertinoIcons.star_fill,
      colors.dark ? const Color(0xffddc4fb) : const Color(0xff694396),
    ),
    _ => (CupertinoIcons.tag, colors.secondary),
  };
  return _AuthorBadge(tag, scale: scale, color: color, icon: icon);
}

class _AuthorBadge extends StatelessWidget {
  const _AuthorBadge(
    this.label, {
    required this.scale,
    required this.color,
    this.icon,
  });
  final String label;
  final double scale;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: colors.dark ? .17 : .11),
          colors.paper.withValues(alpha: .94),
        ),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final symbol?) ...[
              Icon(symbol, color: color, size: 9 * scale),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10 * scale,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
