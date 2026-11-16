import '../core/native_client.dart';

class TopicData {
  TopicData(JsonMap value)
    : id = stringValue(value['id']),
      url = stringValue(value['url']),
      title = stringValue(value['title'], '未命名帖子'),
      author = stringValue(value['author']),
      authorID = value['authorID'] == null ? null : intValue(value['authorID']),
      avatar = stringValue(value['avatar'] ?? value['listedAvatarURL']),
      category = stringValue(value['category']),
      categoryLabel = stringValue(value['categoryLabel'] ?? value['category']),
      normalizedAuthor = stringValue(
        value['normalizedAuthor'],
        stringValue(value['author']).toLowerCase(),
      ),
      featured = value['featured'] == true,
      readingRank = value['readingRank'] == null
          ? null
          : intValue(value['readingRank']),
      published = _publishedLabel(value['dateLabel'] ?? value['published']),
      summary = stringValue(value['summary']);
  final String id,
      url,
      title,
      author,
      avatar,
      category,
      categoryLabel,
      normalizedAuthor,
      published,
      summary;
  final int? authorID, readingRank;
  final bool featured;

  static String _publishedLabel(Object? value) {
    if (value is! num) return stringValue(value);
    final date = DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal();
    final now = DateTime.now();
    final elapsed = now.difference(date);
    if (elapsed.inMinutes >= 0 && elapsed.inMinutes < 1) return '刚刚';
    if (elapsed.inMinutes >= 1 && elapsed.inMinutes < 60) {
      return '${elapsed.inMinutes} 分钟前';
    }
    if (elapsed.inHours >= 1 && elapsed.inHours < 24) {
      return '${elapsed.inHours} 小时前';
    }
    return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class WorkspaceData {
  WorkspaceData(JsonMap value)
    : posts = jsonItems(value['posts']).map(TopicData.new).toList(),
      tabs = jsonItems(value['tabs']).map(TopicData.new).toList(),
      closedTabs = jsonItems(value['closedTabs']).map(TopicData.new).toList(),
      boards = jsonItems(value['boards']),
      selectedTab = stringValue(value['selectedTab']),
      board = stringValue(value['board']),
      showReader = value['showReader'] != false,
      loading = value['loading'] == true,
      canLoadOlder = value['canLoadOlder'] == true,
      error = stringValue(value['error']);
  final List<TopicData> posts, tabs, closedTabs;
  final List<JsonMap> boards;
  final String selectedTab, board, error;
  final bool loading, canLoadOlder, showReader;

  TopicData? get selected {
    for (final topic in tabs) {
      if (topic.id == selectedTab) return topic;
    }
    return null;
  }
}

class ThreadData {
  ThreadData(JsonMap value)
    : title = stringValue(value['title']),
      category = stringValue(value['category']),
      root = value['root'] is Map ? FloorData(jsonMap(value['root'])) : null,
      replies = jsonItems(value['replies']).map(FloorData.new).toList(),
      pages = jsonItems(value['pages']),
      page = intValue(value['page'], 1),
      replyRestriction = stringValue(value['replyRestriction']);
  final String title, category, replyRestriction;
  final FloorData? root;
  final List<FloorData> replies;
  final List<JsonMap> pages;
  final int page;
}

class FloorData {
  FloorData(JsonMap value)
    : id = stringValue(value['id']),
      author = stringValue(value['author']),
      authorID = value['authorID'] == null ? null : intValue(value['authorID']),
      avatar = stringValue(value['avatar']),
      isAuthor = value['isAuthor'] == true,
      date = stringValue(value['date']),
      dateLabel = stringValue(value['dateLabel'] ?? value['date']),
      tags = (value['tags'] is List ? value['tags'] as List : const [])
          .whereType<String>()
          .where((tag) => tag.trim().isNotEmpty)
          .toList(),
      blocks = jsonItems(value['blocks']),
      signature = stringValue(value['signature']),
      likes = intValue(value['likes']),
      chicken = intValue(value['chicken']),
      dislikes = intValue(value['dislikes']),
      upvoted = value['upvoted'] == true,
      downvoted = value['downvoted'] == true,
      gaveChicken = value['gaveChicken'] == true;
  final String id, author, avatar, date, dateLabel, signature;
  final List<String> tags;
  final int? authorID;
  final List<JsonMap> blocks;
  final int likes, chicken, dislikes;
  final bool isAuthor, upvoted, downvoted, gaveChicken;
}
