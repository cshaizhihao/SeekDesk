// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import '../state/rankings_controller.dart';
import 'glass_chrome.dart';

/// A height-flexible summary of the original first ten positions. All chrome
/// scrolls with the rows, so even a zero-height sidebar slot remains valid.
class SidebarRankings extends StatelessWidget {
  const SidebarRankings({
    required this.state,
    this.onOpenFull,
    this.onOpenTopic,
    super.key,
  });
  final AppState state;
  final VoidCallback? onOpenFull;
  final ValueChanged<TopicData>? onOpenTopic;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state.rankings,
    builder: (context, _) {
      final rankings = state.rankings;
      final rows = rankings.summaryPosts;
      final colors = DeskColors(context);
      final size = numberValue(
        state.domain('settings')['workspace.rankingTextSize'],
        12,
      ).clamp(11, 22).toDouble();
      return CustomScrollView(
        key: PageStorageKey('sidebar-rankings-${rankings.period.name}'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: RankingPeriodPicker(controller: rankings, compact: true),
            ),
          ),
          if (rankings.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  rankings.hasSnapshot ? '更新失败，保留上次榜单' : '热榜暂时无法加载',
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          if (rows.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
                child: rankings.loading
                    ? const Center(child: CupertinoActivityIndicator())
                    : Text(
                        rankings.hasSnapshot ? '这一榜暂无可显示帖子' : '等待加载热榜',
                        style: TextStyle(color: colors.secondary, fontSize: 12),
                      ),
              ),
            )
          else
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final post = rows[index];
                final position = intValue(post['position']);
                final title = stringValue(post['title']);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  child: Semantics(
                    label: '热榜第 $position 名，$title',
                    button: true,
                    child: HoverRow(
                      key: ValueKey(
                        'sidebar-ranking-${rankings.period.name}-${post['id']}',
                      ),
                      onTap: () {
                        final topic = TopicData(post);
                        if (onOpenTopic != null) {
                          onOpenTopic!(topic);
                        } else {
                          state.openTopic(topic);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 7,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 40,
                              child: RankingPositionBadge(position: position),
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Color.lerp(
                                    colors.ink,
                                    colors.secondary,
                                    .28,
                                  )!,
                                  fontSize: size,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (rankings.updatedAt != null)
                        Text(
                          rankingUpdatedLabel(rankings.updatedAt!),
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 10,
                          ),
                        ),
                      if (rankings.hasSnapshot)
                        Text(
                          '${rows.length} 篇',
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                  if (rankings.error != null) ...[
                    const SizedBox(height: 6),
                    DeskButton(
                      '重试',
                      width: 80,
                      height: 30,
                      busy: rankings.loading,
                      onTap: () => rankings.refresh(force: true),
                    ),
                  ],
                  if (onOpenFull != null) ...[
                    const SizedBox(height: 6),
                    DeskButton(
                      '完整热榜',
                      width: 118,
                      height: 30,
                      icon: CupertinoIcons.arrow_up_right,
                      onTap: onOpenFull,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class RankingPeriodPicker extends StatelessWidget {
  const RankingPeriodPicker({
    required this.controller,
    this.compact = false,
    super.key,
  });
  final RankingsController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => GlassSegmentedControl(
    segments: [
      for (final period in RankingPeriod.values)
        GlassSegment(label: period.label),
    ],
    selectedIndex: controller.period.index,
    onSegmentSelected: (index) =>
        controller.selectPeriod(RankingPeriod.values[index]),
    height: compact ? 30 : 37,
    labelPadding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
    selectedTextStyle: TextStyle(
      fontSize: compact ? 11 : 13,
      fontWeight: FontWeight.w600,
    ),
    unselectedTextStyle: TextStyle(fontSize: compact ? 11 : 13),
    quality: GlassQuality.premium,
  );
}

class RankingPositionBadge extends StatelessWidget {
  const RankingPositionBadge({
    required this.position,
    this.fontSize = 12,
    super.key,
  });
  final int position;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final topThree = position >= 1 && position <= 3;

    return Container(
      decoration: topThree
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: switch (position) {
                  1 => [
                    const Color(0xffeb6a4b)
                        .withValues(alpha: colors.dark ? 0.15 : 0.08),
                    const Color(0xffeb6a4b)
                        .withValues(alpha: colors.dark ? 0.08 : 0.04),
                  ],
                  2 => [
                    const Color(0xffc2974b)
                        .withValues(alpha: colors.dark ? 0.15 : 0.08),
                    const Color(0xffc2974b)
                        .withValues(alpha: colors.dark ? 0.08 : 0.04),
                  ],
                  3 => [
                    const Color(0xff9d83bf)
                        .withValues(alpha: colors.dark ? 0.15 : 0.08),
                    const Color(0xff9d83bf)
                        .withValues(alpha: colors.dark ? 0.08 : 0.04),
                  ],
                  _ => [],
                },
              ),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      padding: topThree
          ? const EdgeInsets.symmetric(horizontal: 2, vertical: 2)
          : null,
      child: Text(
        topThree ? '🔥 $position' : '$position',
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          color: switch (position) {
            1 => const Color(0xffeb6a4b),
            2 => const Color(0xffc2974b),
            3 => const Color(0xff9d83bf),
            _ => colors.secondary,
          },
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String rankingUpdatedLabel(DateTime date) {
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')} 更新';
}
