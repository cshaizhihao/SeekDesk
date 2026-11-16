import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../screens/tools_screen.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

/// The desktop list owns keyboard selection, independently of the reader tab.
class ForumPostList extends StatefulWidget {
  const ForumPostList({
    required this.state,
    required this.controller,
    required this.canInteract,
    required this.onOpen,
    this.selectedURL,
    this.footer,
    super.key,
  });
  final AppState state;
  final ScrollController controller;
  final bool Function() canInteract;
  final void Function(TopicData) onOpen;
  final String? selectedURL;
  final Widget? footer;
  @override
  State<ForumPostList> createState() => _ForumPostListState();
}

class _ForumPostListState extends State<ForumPostList> {
  final focus = FocusNode(debugLabel: 'Forum post list');
  final rows = <String, GlobalKey>{};
  String? focusedURL;
  int revealSequence = 0;

  @override
  void dispose() {
    revealSequence++;
    focus.dispose();
    super.dispose();
  }

  bool get allowed => mounted && widget.canInteract();
  bool active(String id) =>
      jsonItems(widget.state.domain('extensions')['items'])
          .any((item) => item['id'] == id && item['active'] == true);
  bool blocked(TopicData post) =>
      active('block') &&
      jsonItems(widget.state.domain('extensions')['blocked']).any(
        (user) =>
            (post.authorID != null && user['memberId'] == post.authorID) ||
            stringValue(user['name']).trim().toLowerCase() ==
                post.normalizedAuthor,
      );

  void open(TopicData post, {required bool background}) {
    if (!allowed) return;
    focus.requestFocus();
    setState(() => focusedURL = post.url);
    if (background) {
      unawaited(widget.state.openTopicInBackground(post));
    } else {
      widget.onOpen(post);
    }
  }

  Future<void> reveal(String url, int direction) async {
    final sequence = ++revealSequence;
    // A lazy list may not have built the next row (especially at large text
    // sizes). Advance by a viewport until its context exists, then align it.
    while (allowed &&
        sequence == revealSequence &&
        focusedURL == url &&
        widget.controller.hasClients) {
      final rowContext = rows[url]?.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignmentPolicy: direction > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return;
      }
      final position = widget.controller.position;
      final target =
          (position.pixels + direction * position.viewportDimension * .7).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
      if (target == position.pixels) return;
      widget.controller.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  KeyEventResult key(FocusNode _, KeyEvent event) {
    if (!allowed || event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final posts = widget.state.workspace.posts;
    if (posts.isEmpty ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if ((down || up) && !keyboard.isMetaPressed) {
      final index = posts.indexWhere((post) => post.url == focusedURL);
      final next = index < 0
          ? (down ? 0 : posts.length - 1)
          : (index + (down ? 1 : -1)).clamp(0, posts.length - 1);
      setState(() => focusedURL = posts[next].url);
      unawaited(reveal(posts[next].url, down ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final post = posts.where((post) => post.url == focusedURL).firstOrNull;
      if (post == null) return KeyEventResult.ignored;
      open(post, background: keyboard.isMetaPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> menu(TopicData post, Offset position) async {
    if (!allowed) return;
    final revision = widget.state.accessRevision;
    final origin = widget.state.domain('workspace');
    final board = origin['board'],
        query = origin['query'],
        order = origin['feedOrder'];
    bool current() {
      final workspace = widget.state.domain('workspace');
      return allowed &&
          revision == widget.state.accessRevision &&
          workspace['board'] == board &&
          workspace['query'] == query &&
          workspace['feedOrder'] == order &&
          widget.state.workspace.posts.any((item) => item.url == post.url);
    }

    final isBlocked = blocked(post);
    final entries = <(String, String)>[
      ('background', '在后台打开'),
      ('external', '在 NodeSeek 打开'),
      if (post.author.isNotEmpty && active('rulings')) ('rulings', '管理记录查询'),
      if (post.author.isNotEmpty &&
          active('block') &&
          post.authorID !=
              intValue(widget.state.domain('session')['owner'], -1))
        ('block', isBlocked ? '解除屏蔽' : '屏蔽此用户'),
    ];
    final choice = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭帖子菜单',
      barrierColor: const Color(0x00000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => LayoutBuilder(
        builder: (context, bounds) {
          final width = math.min(204.0, bounds.maxWidth - 16);
          // CupertinoButton retains its 44-point desktop hit target. Include
          // both document borders when keeping this menu inside the window.
          final height = entries.length * 44.0 + 14;
          return Stack(
            children: [
              Positioned(
                left: position.dx.clamp(
                  8.0,
                  math.max(8.0, bounds.maxWidth - width - 8),
                ),
                top: position.dy.clamp(
                  8.0,
                  math.max(8.0, bounds.maxHeight - height - 8),
                ),
                width: width,
                child: DeskDocument(
                  radius: 12,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final entry in entries)
                          HoverRow(
                            onTap: () => Navigator.pop(context, entry.$1),
                            child: SizedBox(
                              height: 38,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  child: Text(
                                    entry.$2,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: DeskColors(context).ink,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || choice == null || !current()) return;
    switch (choice) {
      case 'background':
        open(post, background: true);
      case 'external':
        await widget.state.act('external.open', {'url': post.url});
      case 'rulings':
        if (active('rulings')) {
          await Navigator.push(
            context,
            CupertinoPageRoute<void>(
              builder: (_) =>
                  RulingsScreen(state: widget.state, name: post.author),
            ),
          );
        }
      case 'block':
        if (!active('block') || blocked(post) != isBlocked) return;
        if (!isBlocked &&
            !await confirmAction(
              context,
              title: '屏蔽作者',
              message: '将折叠 ${post.author} 的帖子正文和回复。',
              accept: '屏蔽',
            )) {
          return;
        }
        if (!current() || !active('block') || blocked(post) != isBlocked) {
          return;
        }
        await widget.state.act(
          isBlocked ? 'extensions.unblock' : 'extensions.block',
          {
            'name': post.author,
            if (post.authorID != null) 'memberId': post.authorID,
          },
          'extensions',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final posts = widget.state.workspace.posts;
    final urls = posts.map((post) => post.url).toSet();
    rows.removeWhere((url, _) => !urls.contains(url));
    final settings = widget.state.domain('settings');
    final size = numberValue(
      settings['workspace.listTextSize'],
      15,
    ).clamp(12, 24).toDouble();
    return Focus(
      focusNode: focus,
      onKeyEvent: key,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: ListView.builder(
        controller: widget.controller,
        padding: const EdgeInsets.all(8),
        scrollCacheExtent: const ScrollCacheExtent.viewport(.5),
        addAutomaticKeepAlives: true,
        itemCount: posts.length + (widget.footer == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == posts.length) return widget.footer!;
          final post = posts[index];
          return Padding(
            key: rows.putIfAbsent(post.url, GlobalKey.new),
            padding: EdgeInsets.only(
              bottom: settings['workspace.readingDensity'] == 'compact' ? 4 : 8,
            ),
            child: GestureDetector(
              onSecondaryTapDown: (details) =>
                  menu(post, details.globalPosition),
              child: ExcludeFocus(
                child: ForumPostRow(
                  state: widget.state,
                  post: post,
                  titleSize: size,
                  compact: settings['workspace.readingDensity'] == 'compact',
                  selected: widget.selectedURL == post.url,
                  focused: focus.hasFocus && focusedURL == post.url,
                  blocked: blocked(post),
                  onTap: () => open(
                    post,
                    background: HardwareKeyboard.instance.isMetaPressed,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ForumPostRow extends StatelessWidget {
  const ForumPostRow({
    required this.state,
    required this.post,
    required this.onTap,
    this.titleSize = 15,
    this.compact = false,
    this.selected = false,
    this.focused = false,
    this.blocked = false,
    super.key,
  });
  final AppState state;
  final TopicData post;
  final VoidCallback onTap;
  final double titleSize;
  final bool compact, selected, focused, blocked;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final metadataSize = (titleSize * .74)
        .roundToDouble()
        .clamp(11.0, 14.0)
        .toDouble();
    final categorySize = (titleSize * .67)
        .roundToDouble()
        .clamp(10.0, 12.0)
        .toDouble();
    final badge = post.categoryLabel.isEmpty
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.secondary.withValues(
                alpha: colors.dark ? .10 : .07,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              post.categoryLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeskTypography.metadata.copyWith(
                fontSize: categorySize,
                color: colors.secondary,
              ),
            ),
          );
    // RepaintBoundary isolates list item repaints
    return RepaintBoundary(
      child: Semantics(
        selected: selected,
        value: focused ? '键盘选中' : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colors.accent.withValues(alpha: focused ? .48 : 0),
            ),
          ),
          child: HoverRow(
            selected: selected,
            onTap: onTap,
            child: Stack(
              children: [
                if (selected)
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: math
                        .max(compact ? 8 : 10, titleSize * .48)
                        .roundToDouble(),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: NativeAvatar(
                          state: state,
                          name: post.author,
                          url: post.avatar,
                          size: (titleSize + 14).clamp(30, 34).toDouble(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    post.title,
                                    maxLines: compact ? 2 : 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colors.ink,
                                      fontSize: titleSize,
                                      height: 1.35,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (post.featured)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 6,
                                      top: 3,
                                    ),
                                    child: Icon(
                                      CupertinoIcons.suit_diamond,
                                      semanticLabel: '精品帖',
                                      size: metadataSize + 3,
                                      color: colors.accent,
                                    ),
                                  ),
                                if (post.readingRank != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 6,
                                      top: 2,
                                    ),
                                    child: Semantics(
                                      label: post.readingRank == 255
                                          ? '私有帖子'
                                          : '阅读需要 Lv${post.readingRank}',
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            CupertinoIcons.lock,
                                            size: metadataSize,
                                            color: colors.secondary,
                                          ),
                                          Text(
                                            post.readingRank == 255
                                                ? '私有'
                                                : '${post.readingRank}',
                                            style: TextStyle(
                                              fontSize: metadataSize,
                                              color: colors.secondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            SizedBox(
                              height: (titleSize * .32)
                                  .roundToDouble()
                                  .clamp(5.0, 6.0)
                                  .toDouble(),
                            ),
                            LayoutBuilder(
                              builder: (context, bounds) {
                                final metadata = Text(
                                  [
                                        post.author,
                                        if (blocked) '已屏蔽',
                                        post.published,
                                      ]
                                      .where((value) => value.isNotEmpty)
                                      .join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DeskTypography.metadata.copyWith(
                                    fontSize: metadataSize,
                                    color: colors.secondary,
                                  ),
                                );
                                if (bounds.maxWidth < 210) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      metadata,
                                      if (badge != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 5,
                                          ),
                                          child: badge,
                                        ),
                                    ],
                                  );
                                }
                                return Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Flexible(child: metadata),
                                    if (badge != null) ...[
                                      const SizedBox(width: 8),
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: bounds.maxWidth * .34,
                                        ),
                                        child: badge,
                                      ),
                                    ],
                                  ],
                                );
                              },
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
        ),
      ),
    );
  }
}
