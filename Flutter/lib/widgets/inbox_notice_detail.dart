import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../core/inbox_presentation.dart';
import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import 'forum_blocks.dart';
import 'glass_chrome.dart';

/// Only the selected notification mounts this read-only preview. It never
/// opens a workspace reader or acknowledges a notification as a side effect.
class InboxNoticeDetail extends StatefulWidget {
  const InboxNoticeDetail({
    required this.state,
    required this.notice,
    required this.category,
    required this.revision,
    required this.onBack,
    required this.showBack,
    super.key,
  });

  final AppState state;
  final JsonMap notice;
  final int category, revision;
  final VoidCallback onBack;
  final bool showBack;

  @override
  State<InboxNoticeDetail> createState() => _InboxNoticeDetailState();
}

class _InboxNoticeDetailState extends State<InboxNoticeDetail> {
  static int _sequence = 0;
  final _scroll = ScrollController();
  String? _request;
  List<JsonMap>? _blocks;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(InboxNoticeDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.notice['id'] != widget.notice['id'] ||
        oldWidget.notice['url'] != widget.notice['url'] ||
        oldWidget.notice['postID'] != widget.notice['postID'] ||
        oldWidget.notice['floor'] != widget.notice['floor'] ||
        oldWidget.notice['authorID'] != widget.notice['authorID'] ||
        oldWidget.category != widget.category) {
      _cancel(oldWidget.revision);
      _blocks = null;
      _error = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _load();
    }
  }

  void _cancel(int revision) {
    final request = _request;
    _request = null;
    if (request == null || widget.state.accessRevision != revision) return;
    unawaited(
      widget.state.client
          .call('inbox.cancelPreview', {
            'requestID': request,
            'accessRevision': revision,
          })
          .catchError((Object _) => <String, dynamic>{}),
    );
  }

  Future<void> _load({bool force = false}) async {
    _cancel(widget.revision);
    final revision = widget.revision;
    final request =
        '$revision:${DateTime.now().microsecondsSinceEpoch}:${++_sequence}';
    _request = request;
    bool current() =>
        mounted &&
        _request == request &&
        revision == widget.state.accessRevision &&
        revision == widget.revision;
    try {
      final result = await widget.state.client.call('inbox.preview', {
        'requestID': request,
        'accessRevision': revision,
        'postID': widget.notice['postID'],
        'floor': widget.notice['floor'],
        'url': widget.notice['url'],
        if (widget.notice['authorID'] != null)
          'authorID': widget.notice['authorID'],
        'force': force,
      });
      if (!current()) return;
      if (result['requestID'] != request ||
          result['accessRevision'] != revision ||
          result['postID'] != widget.notice['postID'] ||
          result['floor'] != widget.notice['floor']) {
        throw const NativeFailure('stale', '通知内容已变化，请重新读取。');
      }
      final blocks = jsonItems(result['blocks']);
      if (blocks.isEmpty) {
        throw const NativeFailure('unavailable', '暂时无法显示这条回复，可进入帖子查看。');
      }
      setState(() {
        _blocks = blocks;
        _error = null;
      });
    } catch (error) {
      if (!current()) return;
      setState(
        () => _error = error is NativeFailure
            ? error.message
            : '暂时无法读取这条回复，请重试或进入帖子查看。',
      );
    }
  }

  @override
  void dispose() {
    _cancel(widget.revision);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context), notice = widget.notice;
    final rawName = stringValue(notice['author']);
    final name = rawName.isEmpty ? 'NodeSeek 用户' : rawName;
    final date = inboxDateLabel(stringValue(notice['date']));
    final floor = intValue(notice['floor']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: DeskButton(
                '返回通知列表',
                icon: CupertinoIcons.chevron_left,
                width: 132,
                height: 32,
                onTap: widget.onBack,
              ),
            ),
          ),
        Expanded(
          child: CupertinoScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              key: const ValueKey('inbox-notice-preview-scroll'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          NativeAvatar(
                            state: widget.state,
                            name: name,
                            url: stringValue(notice['avatar']),
                            size: 36,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(
                                    color: colors.ink,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.category == 0 ? '在帖子中提到了你' : '回复了你的主题',
                                  style: TextStyle(
                                    color: colors.secondary,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                if (date.full.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    date.full,
                                    style: TextStyle(
                                      color: colors.secondary,
                                      fontSize: 11,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      ForumTextSelection(
                        child: Text(
                          stringValue(notice['title']),
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 18,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '第 $floor 楼',
                        style: TextStyle(color: colors.secondary, fontSize: 12),
                      ),
                      const SizedBox(height: 18),
                      if (_error != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error!,
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 13,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 12),
                            DeskButton(
                              '重新读取',
                              icon: CupertinoIcons.arrow_clockwise,
                              width: 110,
                              onTap: () {
                                setState(() {
                                  _error = null;
                                  _blocks = null;
                                });
                                _load(force: true);
                              },
                            ),
                          ],
                        )
                      else if (_blocks == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: CupertinoActivityIndicator()),
                        )
                      else
                        ForumBlocks(
                          state: widget.state,
                          blocks: _blocks!,
                          fontSize: numberValue(
                            widget.state.domain(
                              'settings',
                            )['workspace.readerTextSize'],
                            15,
                          ).clamp(13, 24),
                        ),
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerRight,
                        child: DeskButton(
                          '进入帖子',
                          icon: CupertinoIcons.arrow_up_right,
                          width: 112,
                          onTap: () => widget.state.openTopic(
                            TopicData({...notice, 'id': '${notice['postID']}'}),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
