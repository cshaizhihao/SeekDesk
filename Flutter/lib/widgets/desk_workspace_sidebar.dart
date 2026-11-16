import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import 'desk_navigation_picker.dart';
import 'glass_chrome.dart';

enum DeskSidebarSection { boards, shortcuts, ranking }

/// The workspace navigation hierarchy. Routes and data loading belong to the
/// parent; folding a section only changes its visibility, not its scroll state.
class DeskWorkspaceSidebar extends StatefulWidget {
  const DeskWorkspaceSidebar({
    required this.boards,
    required this.shortcuts,
    required this.boardTextSize,
    required this.selectedBoard,
    required this.selectedShortcut,
    required this.selectedFooter,
    required this.section,
    required this.rankingEnabled,
    required this.extensionUnread,
    required this.ranking,
    required this.onSectionChanged,
    required this.onBoard,
    required this.onShortcut,
    required this.onFooter,
    required this.onCompose,
    this.onReselect,
    super.key,
  });

  final List<JsonMap> boards;
  final List<JsonMap> shortcuts;
  final double boardTextSize;
  final String? selectedBoard;
  final String? selectedShortcut;
  final String? selectedFooter;
  final DeskSidebarSection? section;
  final bool rankingEnabled;
  final int extensionUnread;
  final Widget ranking;
  final ValueChanged<DeskSidebarSection?> onSectionChanged;
  final ValueChanged<String> onBoard;
  final ValueChanged<String> onShortcut;
  final ValueChanged<String> onFooter;
  final VoidCallback onCompose;
  final VoidCallback? onReselect;

  @override
  State<DeskWorkspaceSidebar> createState() => _DeskWorkspaceSidebarState();
}

class _DeskWorkspaceSidebarState extends State<DeskWorkspaceSidebar> {
  final _sidebarScroll = ScrollController();
  final _boardsScroll = ScrollController();
  final _shortcutsScroll = ScrollController();

  static const _footer = [
    ('friends', '友情链接', CupertinoIcons.link),
    ('my', '我的', CupertinoIcons.person_crop_circle),
    ('extensions', '扩展中心', CupertinoIcons.square_grid_2x2),
    ('settings', '设置', CupertinoIcons.gear_alt),
  ];

  double get _fontSize => widget.boardTextSize.isFinite
      ? widget.boardTextSize.clamp(11, 24).toDouble()
      : 13;

  @override
  void dispose() {
    _sidebarScroll.dispose();
    _boardsScroll.dispose();
    _shortcutsScroll.dispose();
    super.dispose();
  }

  int? _selectedIndex(List<JsonMap> items, String? selected) {
    if (selected == null) return null;
    final index = items.indexWhere(
      (item) => stringValue(item['id']) == selected,
    );
    return index < 0 ? null : index;
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(34.0, scaler.scale(_fontSize) + 17);
    final headerHeight = math.max(34.0, scaler.scale(_fontSize) + 19);
    final sectionCount = widget.rankingEnabled ? 3 : 2;
    // Keep room for real destinations, not just the section headers. Below
    // this height the entire sidebar scrolls, including the fixed footer.
    final minimumRollHeight =
        sectionCount * headerHeight +
        8 * (sectionCount - 1) +
        rowHeight * 2 +
        4;
    const verticalPadding = 24.0, composeHeight = 35.0;
    const fixedSpacing = 5.0 + 9 + 8 + 1 + 8;
    final minimumHeight =
        verticalPadding +
        composeHeight +
        fixedSpacing +
        rowHeight * (1 + _footer.length) +
        minimumRollHeight;
    final boards = widget.boards
        .where((item) => stringValue(item['id']).isNotEmpty)
        .toList(growable: false);
    final footerIndex = _footer.indexWhere(
      (item) => item.$1 == widget.selectedFooter,
    );

    return LayoutBuilder(
      builder: (context, bounds) => SingleChildScrollView(
        key: const ValueKey('sidebar-overflow'),
        controller: _sidebarScroll,
        primary: false,
        // This wrapper is always mounted. A resize changes constraints without
        // replacing the navigation pickers, focus nodes or section controllers.
        child: SizedBox(
          height: math.max(bounds.maxHeight, minimumHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 12, 11, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, bounds) => DeskButton(
                    '发布新帖',
                    key: const ValueKey('sidebar-compose'),
                    icon: CupertinoIcons.plus,
                    width: bounds.maxWidth,
                    onTap: widget.onCompose,
                  ),
                ),
                const SizedBox(height: 5),
                DeskNavigationPicker(
                  key: const ValueKey('sidebar-home'),
                  segments: [
                    _segment('', '最新帖子', CupertinoIcons.list_bullet, _fontSize),
                  ],
                  selectedIndex: widget.selectedBoard == '' ? 0 : null,
                  onSelected: (_) => widget.onBoard(''),
                  onReselect: widget.onReselect,
                  extent: rowHeight,
                ),
                const SizedBox(height: 9),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bounds) => _roll(
                      boards,
                      rowHeight: rowHeight,
                      headerHeight: headerHeight,
                      availableHeight: bounds.maxHeight,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: SizedBox(
                    height: 1,
                    child: ColoredBox(color: colors.line),
                  ),
                ),
                const SizedBox(height: 8),
                DeskNavigationPicker(
                  key: const ValueKey('sidebar-footer'),
                  segments: [
                    for (final item in _footer)
                      _segment(
                        item.$1,
                        item.$2,
                        item.$3,
                        _fontSize,
                        unread: item.$1 == 'extensions'
                            ? widget.extensionUnread
                            : 0,
                      ),
                  ],
                  selectedIndex: footerIndex < 0 ? null : footerIndex,
                  onSelected: (index) => widget.onFooter(_footer[index].$1),
                  onReselect: widget.onReselect,
                  extent: rowHeight,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roll(
    List<JsonMap> boards, {
    required double rowHeight,
    required double headerHeight,
    required double availableHeight,
  }) {
    final count = widget.rankingEnabled ? 3 : 2;
    final bodyHeight = math.max(
      0.0,
      availableHeight - headerHeight * count - 8 * (count - 1),
    );

    // Each body keeps its own controller. The stable outer sidebar viewport
    // handles short windows while this roll retains its existing element tree.
    return SingleChildScrollView(
      key: const ValueKey('sidebar-roll'),
      primary: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _group(
            section: DeskSidebarSection.boards,
            title: '论坛版块',
            icon: CupertinoIcons.square_grid_2x2,
            headerHeight: headerHeight,
            bodyHeight: math.min(bodyHeight, boards.length * rowHeight + 4),
            child: _destinations(
              boards,
              section: DeskSidebarSection.boards,
              selected: widget.selectedBoard,
              controller: _boardsScroll,
              extent: rowHeight,
              onSelected: widget.onBoard,
            ),
          ),
          const SizedBox(height: 8),
          _group(
            section: DeskSidebarSection.shortcuts,
            title: '快捷功能区',
            icon: CupertinoIcons.bolt,
            headerHeight: headerHeight,
            bodyHeight: math.min(
              bodyHeight,
              widget.shortcuts.length * rowHeight + 4,
            ),
            child: _destinations(
              widget.shortcuts,
              section: DeskSidebarSection.shortcuts,
              selected: widget.selectedShortcut,
              controller: _shortcutsScroll,
              extent: rowHeight,
              onSelected: widget.onShortcut,
            ),
          ),
          if (widget.rankingEnabled) ...[
            const SizedBox(height: 8),
            _group(
              section: DeskSidebarSection.ranking,
              title: '热榜',
              icon: CupertinoIcons.flame,
              headerHeight: headerHeight,
              bodyHeight: bodyHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: PrimaryScrollController.none(child: widget.ranking),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _group({
    required DeskSidebarSection section,
    required String title,
    required IconData icon,
    required double headerHeight,
    required double bodyHeight,
    required Widget child,
  }) {
    final open = widget.section == section;
    final colors = DeskColors(context);
    final reduceMotion = GlassAccessibilityData.of(context).reduceMotion;
    return Column(
      key: ValueKey('sidebar-group-${section.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MergeSemantics(
          child: Semantics(
            label: title,
            value: open ? '已展开' : '已收起',
            button: true,
            child: CupertinoButton(
              key: ValueKey('sidebar-header-${section.name}'),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              pressedOpacity: 1,
              onPressed: () => widget.onSectionChanged(open ? null : section),
              child: ExcludeSemantics(
                child: SizedBox(
                  height: headerHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: Icon(
                            icon,
                            size: 14,
                            color: open ? colors.accent : colors.secondary,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: (_fontSize - 1)
                                  .clamp(11, 23)
                                  .toDouble(),
                              fontWeight: FontWeight.w400,
                              color: colors.secondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: open ? .5 : 0,
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            CupertinoIcons.chevron_down,
                            size: 10,
                            color: colors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Offstage(
          offstage: !open,
          child: TickerMode(
            enabled: open,
            child: ClipRect(
              child: SizedBox(
                key: ValueKey('sidebar-body-${section.name}'),
                height: bodyHeight,
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _destinations(
    List<JsonMap> items, {
    required DeskSidebarSection section,
    required String? selected,
    required ScrollController controller,
    required double extent,
    required ValueChanged<String> onSelected,
  }) => SingleChildScrollView(
    key: ValueKey('sidebar-scroll-${section.name}'),
    controller: controller,
    primary: false,
    padding: const EdgeInsets.only(top: 4),
    child: items.isEmpty
        ? const SizedBox.shrink()
        : DeskNavigationPicker(
            key: ValueKey('sidebar-picker-${section.name}'),
            segments: [
              for (final item in items)
                _segment(
                  stringValue(item['id']),
                  stringValue(item['title'], stringValue(item['id'])),
                  _icon(stringValue(item['id'])),
                  _fontSize,
                ),
            ],
            selectedIndex: _selectedIndex(items, selected),
            onSelected: (index) => onSelected(stringValue(items[index]['id'])),
            onReselect: widget.onReselect,
            extent: extent,
          ),
  );

  GlassSegment _segment(
    String id,
    String title,
    IconData icon,
    double size, {
    int unread = 0,
  }) {
    final colors = DeskColors(context);
    return GlassSegment(
      id: id,
      semanticLabel: unread > 0 ? '$title，$unread 条未读' : title,
      tooltip: title,
      icon: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            SizedBox(width: 18, child: Icon(icon, size: 15)),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: size),
              ),
            ),
            if (unread > 0) ...[
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 36),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: colors.accent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Cupertino's bundled font has no cup, megaphone, leaf or puzzle glyph.
  // Use its closest built-in symbols instead of relying on an absent glyph.
  IconData _icon(String id) => switch (id) {
    'daily' => CupertinoIcons.chat_bubble_2,
    'tech' => CupertinoIcons.chevron_left_slash_chevron_right,
    'info' => CupertinoIcons.antenna_radiowaves_left_right,
    'review' => CupertinoIcons.chart_bar,
    'trade' => CupertinoIcons.tag,
    'carpool' => CupertinoIcons.person_2,
    'dev' => CupertinoIcons.hammer,
    'photo-share' => CupertinoIcons.photo_on_rectangle,
    'expose' => CupertinoIcons.exclamationmark_bubble,
    'promotion' => CupertinoIcons.speaker_2,
    'life' => CupertinoIcons.leaf_arrow_circlepath,
    'inside' => CupertinoIcons.lock_shield,
    'sandbox' => CupertinoIcons.cube_box,
    'award' => CupertinoIcons.rhombus,
    'ruling' => CupertinoIcons.shield,
    'lucky' => CupertinoIcons.gift,
    'invite' => CupertinoIcons.person_badge_plus,
    _ => CupertinoIcons.square_grid_2x2,
  };
}
