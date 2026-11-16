// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../models/snapshots.dart';
import '../state/app_state.dart';
import 'forum_blocks.dart';
import 'forum_post_list.dart';
import 'glass_chrome.dart';
import 'reader_context.dart';
import 'sidebar_rankings.dart';

const _previewTitle = '分享一次晚高峰的三网线路实测';
const _previewBody = '这是晚高峰的实测记录。电信和联通的延迟比较稳定，移动偶尔出现波动。';

final _previewTopic = TopicData({
  'id': 'preference-preview',
  'url': '',
  'title': _previewTitle,
  'author': '示例用户',
  'avatar': '',
  'dateLabel': '刚刚',
  'categoryLabel': '测评',
});

final _previewFloor = FloorData({
  'id': '0',
  'author': '示例用户',
  'avatar': '',
  'dateLabel': '刚刚',
  'tags': ['管理'],
});

/// Uses the reader's actual author and text layout with local, inert content.
/// [authorScale] is the preference's percentage, rather than a scale factor.
class PreferenceReaderPreview extends StatelessWidget {
  const PreferenceReaderPreview({
    required this.state,
    required this.bodySize,
    required this.authorScale,
    super.key,
  });

  final AppState state;
  final double bodySize, authorScale;

  @override
  Widget build(BuildContext context) => _PreferencePreview(
    description: '阅读预览，正文 ${bodySize.round()} 点，作者栏 ${authorScale.round()}%',
    child: ReaderFloorContext(
      state: state,
      topic: _previewTopic,
      floor: _previewFloor,
      root: true,
      authorScale: authorScale / 100,
      profilesSupported: false,
      actions: const [],
      body: ForumBlocks(
        state: state,
        fontSize: bodySize,
        blocks: const [
          {'kind': 'text', 'text': _previewBody},
        ],
      ),
    ),
  );
}

class PreferenceListPreview extends StatelessWidget {
  const PreferenceListPreview({
    required this.state,
    required this.titleSize,
    this.compact = false,
    super.key,
  });

  final AppState state;
  final double titleSize;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PreferencePreview(
    description: '帖子列表预览，标题 ${titleSize.round()} 点，${compact ? '紧凑' : '舒适'}布局',
    child: ForumPostRow(
      state: state,
      post: _previewTopic,
      titleSize: titleSize,
      compact: compact,
      onTap: () {},
    ),
  );
}

class PreferenceSidebarPreview extends StatelessWidget {
  const PreferenceSidebarPreview({
    required this.boardSize,
    required this.rankingSize,
    super.key,
  });

  final double boardSize, rankingSize;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return _PreferencePreview(
      description: '侧栏预览，版块 ${boardSize.round()} 点，热榜 ${rankingSize.round()} 点',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                child: Icon(
                  CupertinoIcons.chevron_left_slash_chevron_right,
                  size: boardSize.clamp(13, 18).toDouble(),
                  color: colors.secondary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '技术交流',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: boardSize,
                    color: colors.ink,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RankingPositionBadge(position: 1),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _previewTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: rankingSize,
                    color: Color.lerp(colors.ink, colors.secondary, .28),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single descriptive semantics node, with no example links, selection,
/// keyboard stops or pointer actions inherited from the real display widgets.
class _PreferencePreview extends StatelessWidget {
  const _PreferencePreview({required this.description, required this.child});

  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Semantics(
      container: true,
      label: description,
      excludeSemantics: true,
      child: IgnorePointer(
        child: ExcludeFocus(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.well,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '预览',
                  style: DeskTypography.metadata.copyWith(
                    color: colors.secondary,
                  ),
                ),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
