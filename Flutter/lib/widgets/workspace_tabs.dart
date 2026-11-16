// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip, TooltipTriggerMode;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';
import 'desk_context_menu.dart';

/// The tab label has 8 points of vertical padding inside a 4-point track inset.
/// Keep adjacent text actions aligned when accessibility text grows, without
/// changing the global desktop button metrics or the tab control's identity.
double workspaceToolbarHeight(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(13) * 1.25 + 12)
        .ceilToDouble()
        .clamp(34.0, double.infinity)
        .toDouble();

Color _tabTrackColor(BuildContext context) =>
    DeskColors(context).ink.withValues(alpha: .035);

/// Keep the package's interactive lens for selection; only the small handle
/// starts a reorder, so sliding the lens still selects tabs normally.
class WorkspaceTabs extends StatelessWidget {
  const WorkspaceTabs({
    required this.state,
    this.onSelect,
    this.canInteract,
    super.key,
  });
  final AppState state;
  final VoidCallback? onSelect;
  final bool Function()? canInteract;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final workspace = state.workspace;
      if (workspace.tabs.isEmpty) return const SizedBox.shrink();
      final tabs = workspace.tabs;
      final revision = state.accessRevision;
      final selectedIndex = tabs.indexWhere(
        (tab) => tab.id == workspace.selectedTab,
      );
      final height = workspaceToolbarHeight(context);
      return Row(
        children: [
          Expanded(
            child: _WorkspaceTabRail(
              key: ValueKey((revision, selectedIndex < 0)),
              canInteract: () =>
                  !state.changingTabs && canInteract?.call() != false,
              builder: (controller) => selectedIndex < 0
                  ? _unselectedTabs(context, tabs, revision, controller)
                  : GlassSegmentedControl.scrollable(
                      key: ValueKey('workspace-tabs-${state.accessRevision}'),
                      scrollController: controller,
                      segments: [
                        for (final tab in tabs)
                          GlassSegment(
                            id: tab.id,
                            semanticLabel: tab.title,
                            enabled: !state.changingTabs,
                            icon: _TabLabel(
                              state: state,
                              tab: tab,
                              canInteract: canInteract,
                              onReselect:
                                  !workspace.showReader &&
                                      tab.id == workspace.selectedTab
                                  ? () => _select(tab.id, revision)
                                  : null,
                            ),
                          ),
                      ],
                      selectedIndex: selectedIndex,
                      onSegmentSelected: (index) {
                        if (index < 0 || index >= tabs.length) return;
                        _select(tabs[index].id, revision);
                      },
                      height: height,
                      backgroundColor: _tabTrackColor(context),
                      selectedTextStyle: DeskTypography.control.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: DeskColors(context).ink,
                      ),
                      unselectedTextStyle: DeskTypography.control.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: DeskColors(context).secondary,
                      ),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 9),
                      regridDuration:
                          GlassAccessibilityData.of(context).reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      quality: GlassQuality.premium,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          GlassBackdropGroup(
            enabled: const bool.fromEnvironment(
              'SEEKDESK_SHARED_BACKDROP',
              defaultValue: true,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DeskIcon(
                  '关闭当前标签',
                  CupertinoIcons.xmark,
                  state.changingTabs || workspace.selected == null
                      ? null
                      : () {
                          if (canInteract?.call() == false) return;
                          final selected = state.workspace.selected;
                          if (selected != null) {
                            state.closeTopic(selected.id);
                          }
                        },
                  quiet: true,
                ),
                const SizedBox(width: 4),
                DeskIcon(
                  '关闭全部标签',
                  CupertinoIcons.rectangle_stack_badge_minus,
                  state.changingTabs
                      ? null
                      : () {
                          if (canInteract?.call() != false) {
                            state.closeAllTopics();
                          }
                        },
                  quiet: true,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  void _select(String id, int revision) {
    if (revision != state.accessRevision ||
        state.changingTabs ||
        canInteract?.call() == false) {
      return;
    }
    // Gestures can complete after the rail was rebuilt or the tab was closed.
    // Resolve its current page instead of retaining an obsolete TopicData.
    final tab = state.workspace.tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab == null) return;
    onSelect?.call();
    if (revision == state.accessRevision) state.selectTopic(tab);
  }

  Widget _unselectedTabs(
    BuildContext context,
    List<TopicData> tabs,
    int revision,
    ScrollController controller,
  ) {
    // The package requires a selected index. Background tabs can legitimately
    // have no native selection, so render the same labels in a neutral track
    // until the user selects one; never manufacture a selected first tab.
    return Container(
      key: const ValueKey('workspace-tabs-unselected'),
      height: workspaceToolbarHeight(context),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: _tabTrackColor(context),
        borderRadius: BorderRadius.circular(
          workspaceToolbarHeight(context) / 2,
        ),
      ),
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in tabs)
              Semantics(
                key: ValueKey('tab-neutral-${tab.id}'),
                selected: false,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  minimumSize: Size(0, workspaceToolbarHeight(context) - 4),
                  onPressed: state.changingTabs
                      ? null
                      : () => _select(tab.id, revision),
                  child: DefaultTextStyle(
                    style: DeskTypography.control.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: DeskColors(context).secondary,
                    ),
                    child: _TabLabel(
                      state: state,
                      tab: tab,
                      canInteract: canInteract,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Scope controller ownership to the actual viewport. Account changes and
// neutral/selected swaps replace that viewport, without sharing a controller
// between the outgoing and incoming scroll views during their lifecycle.
class _WorkspaceTabRail extends StatefulWidget {
  const _WorkspaceTabRail({
    required this.builder,
    required this.canInteract,
    super.key,
  });
  final Widget Function(ScrollController) builder;
  final bool Function() canInteract;

  @override
  State<_WorkspaceTabRail> createState() => _WorkspaceTabRailState();
}

class _WorkspaceTabRailState extends State<_WorkspaceTabRail> {
  final _scrollController = ScrollController();
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollTabs(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !_scrollController.hasClients ||
        !widget.canInteract()) {
      return;
    }
    // The inner horizontal Scrollable owns horizontal/Shift-wheel input.
    // Resolve vertical wheel input here, without handling an event twice.
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.position.pointerScroll(delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Listener(
      onPointerSignal: _scrollTabs,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: RawScrollbar(
          key: const ValueKey('workspace-tab-scrollbar'),
          controller: _scrollController,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          thickness: 6,
          crossAxisMargin: 2,
          mainAxisMargin: 2,
          radius: const Radius.circular(3),
          trackRadius: const Radius.circular(3),
          thumbColor: colors.secondary.withValues(alpha: .78),
          trackColor: colors.ink.withValues(alpha: .08),
          trackBorderColor: const Color(0x00000000),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: widget.builder(_scrollController),
          ),
        ),
      ),
    );
  }
}

class _TabDrag {
  const _TabDrag(this.id, this.accessRevision);
  final String id;
  final int accessRevision;
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.state,
    required this.tab,
    this.canInteract,
    this.onReselect,
  });
  final AppState state;
  final TopicData tab;
  final bool Function()? canInteract;
  final VoidCallback? onReselect;

  Future<void> _menu(
    BuildContext context,
    Offset position,
    int revision,
  ) async {
    if (!context.mounted ||
        revision != state.accessRevision ||
        state.changingTabs ||
        canInteract?.call() == false) {
      return;
    }
    final sourceRoute = ModalRoute.of(context);
    if (sourceRoute?.isCurrent == false) return;
    bool valid() {
      final extensions = state.domain('extensions');
      final office =
          jsonItems(
            extensions['items'],
          ).any((item) => item['id'] == 'office' && item['active'] == true) &&
          jsonMap(jsonMap(extensions['settings'])['office'])['presented'] ==
              true;
      return context.mounted &&
          !office &&
          revision == state.accessRevision &&
          !state.changingTabs &&
          state.workspace.tabs.any((item) => item.id == tab.id);
    }

    bool canShowFeedback() =>
        valid() &&
        (sourceRoute?.isCurrent ?? true) &&
        canInteract?.call() != false;

    final releasePopup = state.deferWatchPopup();
    String? choice;
    try {
      choice = await showDeskContextMenu<String>(
        context,
        position: position,
        validityChanges: state,
        isValid: valid,
        entries: [
          const DeskMenuEntry('copy', '复制帖子链接', CupertinoIcons.link),
          const DeskMenuEntry(
            'external',
            '在 NodeSeek 打开',
            CupertinoIcons.arrow_up_right_square,
          ),
          const DeskMenuEntry('close', '关闭此标签', CupertinoIcons.xmark),
          if (state.workspace.closedTabs.isNotEmpty)
            const DeskMenuEntry(
              'reopen',
              '恢复最近关闭的标签',
              CupertinoIcons.arrow_uturn_left,
            ),
        ],
      );
    } finally {
      releasePopup();
    }
    if (choice == null || !valid() || canInteract?.call() == false) return;
    final current = state.workspace.tabs
        .where((item) => item.id == tab.id)
        .first;
    switch (choice) {
      case 'copy':
        try {
          await Clipboard.setData(ClipboardData(text: current.url));
          if (canShowFeedback()) state.showMessage('帖子链接已复制');
        } catch (_) {
          if (canShowFeedback()) state.showMessage('复制失败，请重试。');
        }
      case 'external':
        await state.act('external.open', {'url': current.url});
      case 'close':
        await state.closeTopic(current.id);
      case 'reopen':
        if (state.workspace.closedTabs.isNotEmpty) await state.reopenTopic();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final revision = state.accessRevision;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Secondary clicks must not replace the segment's accessible tap with
      // this recognizer's empty primary-tap action.
      excludeFromSemantics: true,
      onSecondaryTapUp: (details) =>
          _menu(context, details.globalPosition, revision),
      child: DragTarget<_TabDrag>(
        onWillAcceptWithDetails: (details) =>
            !state.changingTabs &&
            canInteract?.call() != false &&
            details.data.accessRevision == state.accessRevision &&
            details.data.id != tab.id &&
            state.workspace.tabs.any((item) => item.id == details.data.id),
        onAcceptWithDetails: (details) {
          if (details.data.accessRevision != state.accessRevision ||
              canInteract?.call() == false) {
            return;
          }
          state.moveTopic(details.data.id, tab.id);
        },
        builder: (context, candidates, rejected) => AnimatedContainer(
          key: ValueKey('tab-target-${tab.id}'),
          duration: GlassAccessibilityData.of(context).reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: colors.accent.withValues(
              alpha: candidates.isEmpty ? 0 : .16,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Tooltip(
                  key: ValueKey(('tab-title', state.accessRevision, tab.id)),
                  message: tab.title,
                  waitDuration: const Duration(milliseconds: 450),
                  triggerMode: TooltipTriggerMode.manual,
                  excludeFromSemantics: true,
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: GestureDetector(
                    // The official control intentionally ignores selecting its
                    // current segment. In overview that tab still needs to open
                    // the retained reader; keep the lens for all other tabs.
                    behavior: HitTestBehavior.opaque,
                    onTap: onReselect,
                    child: Text(
                      tab.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: '关闭标签',
                child: CupertinoButton(
                  key: ValueKey('tab-close-${tab.id}'),
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(22, 22),
                  onPressed: state.changingTabs
                      ? null
                      : () {
                          if (revision != state.accessRevision ||
                              canInteract?.call() == false) {
                            return;
                          }
                          state.closeTopic(tab.id);
                        },
                  child: Semantics(
                    label: '关闭标签：${tab.title}',
                    child: Icon(
                      CupertinoIcons.xmark,
                      size: 11,
                      color: colors.secondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Tooltip(
                message: '拖动以排序',
                waitDuration: const Duration(milliseconds: 450),
                child: Draggable<_TabDrag>(
                  data: _TabDrag(tab.id, state.accessRevision),
                  maxSimultaneousDrags: state.changingTabs ? 0 : 1,
                  // The global office cover sits above the Navigator overlay.
                  // Keep drag titles below it even while the pointer is down.
                  rootOverlay: false,
                  feedback: _TabDragFeedback(
                    state: state,
                    id: tab.id,
                    accessRevision: state.accessRevision,
                    colors: colors,
                  ),
                  child: MouseRegion(
                    cursor: state.changingTabs
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.grab,
                    child: SizedBox(
                      key: ValueKey('tab-drag-${tab.id}'),
                      width: 22,
                      height: 22,
                      child: Icon(
                        CupertinoIcons.line_horizontal_3,
                        size: 11,
                        color: colors.secondary.withValues(alpha: .55),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A drag avatar outlives its source widget until the pointer is released.
/// Listen independently so an account change or close clears its old title.
class _TabDragFeedback extends StatelessWidget {
  const _TabDragFeedback({
    required this.state,
    required this.id,
    required this.accessRevision,
    required this.colors,
  });
  final AppState state;
  final String id;
  final int accessRevision;
  final DeskColors colors;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      if (accessRevision != state.accessRevision) {
        return const SizedBox.shrink();
      }
      final tab = state.workspace.tabs.where((tab) => tab.id == id).firstOrNull;
      if (tab == null) return const SizedBox.shrink();
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x20000000),
              blurRadius: 16,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Text(
              tab.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.ink,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// This entry also lives in the narrow overview, where there is no reader pane.
class ClosedTabsButton extends StatelessWidget {
  const ClosedTabsButton({required this.state, this.canInteract, super.key});
  final AppState state;
  final bool Function()? canInteract;

  Future<void> _show(BuildContext context) async {
    if (canInteract?.call() == false) return;
    final revision = state.accessRevision;
    var closing = false;
    void finish(BuildContext dialogContext, [String? selectedID]) {
      // The workspace route is covered by this dialog. Check this route rather
      // than its caller's canInteract, including for a pointer already down
      // when the office cover or a newer route appears.
      if (!dialogContext.mounted ||
          closing ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      final extensions = state.domain('extensions');
      final officeCovered =
          jsonItems(
            extensions['items'],
          ).any((item) => item['id'] == 'office' && item['active'] == true) &&
          jsonMap(jsonMap(extensions['settings'])['office'])['presented'] ==
              true;
      if (officeCovered ||
          selectedID != null &&
              (revision != state.accessRevision || state.changingTabs)) {
        return;
      }
      closing = true;
      Navigator.of(dialogContext).pop(selectedID);
    }

    final id = await showCupertinoDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: MediaQuery.sizeOf(context).height * .7,
            ),
            child: DeskGlassPanel(
              level: GlassLevel.overlay,
              padding: const EdgeInsets.all(16),
              child: ListenableBuilder(
                listenable: state,
                builder: (context, _) {
                  final closed = revision == state.accessRevision
                      ? state.workspace.closedTabs.reversed.toList()
                      : <TopicData>[];
                  final colors = DeskColors(context);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '最近关闭的标签',
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DeskIcon(
                            '关闭最近标签列表',
                            CupertinoIcons.xmark,
                            () => finish(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (closed.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '没有可恢复的标签',
                            style: TextStyle(color: colors.secondary),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: closed.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 3),
                            itemBuilder: (context, index) {
                              final tab = closed[index];
                              return HoverRow(
                                key: ValueKey('closed-tab-${tab.id}'),
                                onTap: () => finish(context, tab.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 11,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        CupertinoIcons.arrow_uturn_left,
                                        color: colors.accent,
                                        size: 15,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          tab.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: colors.ink,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      if (index == 0) ...[
                                        const SizedBox(width: 10),
                                        Text(
                                          '最近',
                                          style: TextStyle(
                                            color: colors.secondary,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (context.mounted &&
        id != null &&
        revision == state.accessRevision &&
        canInteract?.call() != false) {
      await state.reopenTopic(id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => state.workspace.closedTabs.isEmpty
        ? const SizedBox.shrink()
        : DeskButton(
            '最近关闭',
            icon: CupertinoIcons.arrow_uturn_left,
            width: 102,
            height: workspaceToolbarHeight(context),
            quiet: true,
            onTap: state.changingTabs ? null : () => _show(context),
          ),
  );
}
