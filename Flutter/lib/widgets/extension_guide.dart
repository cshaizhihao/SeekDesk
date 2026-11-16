// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../state/app_state.dart';
import 'glass_chrome.dart';

const _guides = <String, List<(IconData, String, String)>>{
  'hot': [
    (CupertinoIcons.list_bullet, '侧栏随时查看', '展开侧栏热榜，直接打开感兴趣的帖子。'),
    (CupertinoIcons.clock, '切换时间范围', '实时、日榜和周榜分别查看近期与持续热门的讨论。'),
  ],
  'attendance': [
    (CupertinoIcons.calendar, '北京时间零点', 'SeekDesk 运行时自动执行当天签到。'),
    (CupertinoIcons.moon, '恢复后补签', '电脑休眠或应用退出后，重新运行会补签当天。'),
  ],
  'office': [
    (CupertinoIcons.keyboard, '快捷切换', '按设定的 ⌘⇧ 快捷键进入或退出办公视图。'),
    (CupertinoIcons.doc_text, '保留阅读状态', '恢复窗口后继续浏览之前的帖子。'),
  ],
  'value': [
    (CupertinoIcons.money_dollar_circle, '帖子右上角', '打开交易帖子，点击「估价」填写价格与到期时间。'),
    (CupertinoIcons.arrow_left_right, '对比交易价格', '按剩余时间估值，也可以换算币种。'),
  ],
  'block': [
    (CupertinoIcons.person, '从作者旁屏蔽', '在帖主或楼层作者旁选择屏蔽用户。'),
    (CupertinoIcons.eye, '随时恢复', '可在原楼层临时展开，也可在这里解除屏蔽。'),
  ],
  'authorOnly': [
    (CupertinoIcons.person, '聚焦楼主更新', '在帖子楼层标题旁开启「只看楼主」。'),
    (CupertinoIcons.bubble_left, '返回完整讨论', '关闭开关，即可继续查看其他人的回复。'),
  ],
  'keywords': [
    (CupertinoIcons.search, '组合关键词', '日本+VPS 表示两个词都出现；用逗号或换行添加另一组规则。'),
    (CupertinoIcons.bell, '应用内与系统通知', '命中后显示应用内提示，也可开启 macOS 通知。'),
  ],
  'rulings': [
    (CupertinoIcons.shield, '从作者旁查询', '点击「管理记录」查看公开社区记录。'),
    (CupertinoIcons.clock, '北京时间', '查询结果统一显示为北京时间。'),
  ],
  'proxy': [
    (CupertinoIcons.link, '导入节点或订阅', '粘贴分享链接或订阅地址，选择自己的节点。'),
    (CupertinoIcons.globe, '仅代理 SeekDesk', '开启后只影响本应用的连接，其他 App 保持原有网络。'),
  ],
};

class ExtensionGuide extends StatelessWidget {
  const ExtensionGuide({required this.id, this.preview = false, super.key});
  final String id;
  final bool preview;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final entries = _guides[id] ?? const <(IconData, String, String)>[];
    return _ExtensionInfoPanel(
      title: preview ? '功能预览' : '使用方式',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, (icon, title, detail)) in entries.indexed)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 16, color: colors.secondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: DeskTypography.control.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          detail,
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (preview) ...[
            const SizedBox(height: 14),
            Text(
              '安装后可在这里管理扩展。',
              style: DeskTypography.metadata.copyWith(color: colors.secondary),
            ),
          ],
        ],
      ),
    );
  }
}

class ExtensionSources extends StatelessWidget {
  const ExtensionSources({required this.id, required this.state, super.key});
  final String id;
  final AppState state;
  @override
  Widget build(BuildContext context) {
    final links = switch (id) {
      'hot' => const [
        ('原作者 @小号', 'NodeSeek 社区', 'https://www.nodeseek.com/space/10539'),
        ('原热榜项目', 'Greasy Fork', 'https://greasyfork.org/scripts/560065'),
      ],
      'rulings' => const [
        (
          '原脚本 · @slugger',
          'sluggerbox · Greasy Fork',
          'https://greasyfork.org/scripts/567915',
        ),
        (
          'NS Seek 后端',
          '@slugger · GitHub',
          'https://github.com/theslugger/ns-seek',
        ),
        (
          '北京时间修正',
          '@sss1231 · NodeSeek',
          'https://www.nodeseek.com/post-870735-1',
        ),
      ],
      _ => const <(String, String, String)>[],
    };
    if (links.isEmpty) return const SizedBox.shrink();
    final colors = DeskColors(context);
    return _ExtensionInfoPanel(
      title: '来源与致谢',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (title, subtitle, url) in links)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              onPressed: () => state.act('external.open', {'url': url}),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(color: colors.accent, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: DeskTypography.metadata.copyWith(
                            color: colors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    CupertinoIcons.arrow_up_right,
                    size: 13,
                    color: colors.secondary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Supporting details use a smaller heading than the extension's controls.
class _ExtensionInfoPanel extends StatelessWidget {
  const _ExtensionInfoPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: DeskGlassPanel(
      quiet: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                color: DeskColors(context).secondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}
