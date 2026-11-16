// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import '../models/friend_links.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';

class FriendLinksScreen extends StatelessWidget {
  const FriendLinksScreen({
    required this.state,
    required this.onReturn,
    super.key,
  });

  final AppState state;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DeskButton(
                '返回论坛',
                icon: CupertinoIcons.chevron_left,
                quiet: true,
                onTap: onReturn,
              ),
              Text(
                '友情链接',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 990),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '感谢以下伙伴对本项目的支持，排名不分先后。',
                      style: TextStyle(color: colors.secondary, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, bounds) {
                        final columns = ((bounds.maxWidth + 16) / 258)
                            .floor()
                            .clamp(1, 3);
                        final width =
                            (bounds.maxWidth - 16 * (columns - 1)) / columns;
                        return Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            for (final partner in seekDeskPartners)
                              SizedBox(
                                width: width,
                                child: _card(context, partner),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, Map<String, String> partner) {
    final colors = DeskColors(context);
    return DeskGlassPanel(
      quiet: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  partner['asset']!,
                  width: 56,
                  height: 56,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                  excludeFromSemantics: true,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  partner['name']!,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            partner['description']!,
            style: TextStyle(
              color: colors.secondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (partner['website'] != null)
                DeskButton(
                  '官网',
                  width: 82,
                  icon: CupertinoIcons.arrow_up_right,
                  semanticLabel: '${partner['name']} 官网',
                  onTap: () =>
                      state.act('external.open', {'url': partner['website']}),
                ),
              if (partner['telegram'] != null)
                DeskButton(
                  'Telegram 群组',
                  width: 140,
                  icon: CupertinoIcons.paperplane,
                  semanticLabel: '${partner['name']} Telegram 群组',
                  onTap: () =>
                      state.act('external.open', {'url': partner['telegram']}),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
