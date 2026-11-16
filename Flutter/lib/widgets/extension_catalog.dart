import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import 'glass_chrome.dart';
import 'desk_interaction.dart';

IconData extensionIcon(String id) => switch (id) {
  'proxy' => CupertinoIcons.globe,
  'hot' => CupertinoIcons.flame,
  'attendance' => CupertinoIcons.calendar,
  'office' => CupertinoIcons.table,
  'value' => CupertinoIcons.money_dollar_circle,
  'block' => CupertinoIcons.person_crop_circle_badge_xmark,
  'authorOnly' => CupertinoIcons.person,
  'keywords' => CupertinoIcons.bell,
  'rulings' => CupertinoIcons.shield,
  _ => CupertinoIcons.square_grid_2x2,
};

String extensionStatus(JsonMap item) => item['installed'] != true
    ? '尚未安装'
    : item['active'] == true
    ? '已启用'
    : '已停用';

/// A catalog card only navigates. Installation and switches live in the detail,
/// so one pointer/keyboard action cannot also toggle or install the extension.
class ExtensionCatalogGroup extends StatelessWidget {
  const ExtensionCatalogGroup({
    required this.title,
    required this.items,
    required this.onOpen,
    super.key,
  });
  final String title;
  final List<JsonMap> items;
  final ValueChanged<JsonMap> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: DeskTypography.control.copyWith(color: colors.secondary),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, bounds) {
              // A max-extent grid uses ceil(), which gave two undersized cards at
              // 453 local pixels. Derive columns from a real minimum instead.
              final columns = ((bounds.maxWidth + 16) / (230 + 16))
                  .floor()
                  .clamp(1, 4);
              final width = math.min(
                310.0,
                (bounds.maxWidth - 16 * (columns - 1)) / columns,
              );
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final item in items)
                    Semantics(
                      key: ValueKey('extension-card-${item['id']}'),
                      button: true,
                      label:
                          '${stringValue(item['title'])}，${extensionStatus(item)}，查看详情',
                      hint: stringValue(item['description']),
                      onTap: () => onOpen(item),
                      excludeSemantics: true,
                      child: DeskInteraction(
                        color: colors.accent,
                        child: GlassButton.custom(
                          width: width,
                          shape: const LiquidRoundedRectangle(borderRadius: 12),
                          quality: GlassQuality.premium,
                          settings: DeskMaterials.forLevel(
                            context,
                            GlassLevel.card,
                          ),
                          interactionScale: 1,
                          stretch: 0,
                          useOwnLayer: true,
                          onTap: () => onOpen(item),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 148),
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      extensionIcon(stringValue(item['id'])),
                                      size: 22,
                                      color: colors.accent,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        stringValue(item['title']),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: colors.ink,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      CupertinoIcons.chevron_right,
                                      size: 13,
                                      color: colors.secondary,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  stringValue(item['description']),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.secondary,
                                    fontSize: 12,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  extensionStatus(item),
                                  style: DeskTypography.metadata.copyWith(
                                    color: colors.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
