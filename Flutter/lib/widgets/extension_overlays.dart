// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

/// Lives above the Navigator, so the office cover also covers compose/settings
/// routes. The native extension remains the single source of truth.
class ExtensionOverlays extends StatefulWidget {
  const ExtensionOverlays({
    required this.state,
    required this.child,
    super.key,
  });
  final AppState state;
  final Widget child;
  @override
  State<ExtensionOverlays> createState() => _ExtensionOverlaysState();
}

class _ExtensionOverlaysState extends State<ExtensionOverlays> {
  JsonMap data = {};
  JsonMap get office => jsonMap(jsonMap(data['settings'])['office']);
  bool get officeEnabled =>
      jsonItems(data['items'])
          .any((item) => item['id'] == 'office' && item['active'] == true);
  bool get covered => officeEnabled && office['presented'] == true;

  @override
  void initState() {
    super.initState();
    data = widget.state.domain('extensions');
    widget.state.addListener(_changed);
    widget.state.watchPopupDeferred.addListener(_popupDeferralChanged);
    HardwareKeyboard.instance.addHandler(_shortcut);
  }

  @override
  void didUpdateWidget(ExtensionOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.state, widget.state)) return;
    oldWidget.state.removeListener(_changed);
    oldWidget.state.watchPopupDeferred.removeListener(_popupDeferralChanged);
    data = widget.state.domain('extensions');
    widget.state.addListener(_changed);
    widget.state.watchPopupDeferred.addListener(_popupDeferralChanged);
  }

  void _popupDeferralChanged() {
    if (mounted) setState(() {});
  }

  bool _canActOnPopup(JsonMap popup, int revision) =>
      mounted &&
      !covered &&
      !widget.state.watchPopupDeferred.value &&
      revision == widget.state.accessRevision &&
      popup['id'] == jsonMap(data['watchPopup'])['id'];

  void _changed() {
    final next = widget.state.domain('extensions');
    if (!identical(next, data) && mounted) setState(() => data = next);
  }

  bool _shortcut(KeyEvent event) {
    if (event is! KeyDownEvent || !officeEnabled) return false;
    final keyboard = HardwareKeyboard.instance;
    final key = stringValue(office['key'], '9').toLowerCase();
    // Shift changes event.character on number keys, so use the physical key's
    // logical label rather than its typed character.
    if (keyboard.isMetaPressed &&
        keyboard.isShiftPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        event.logicalKey.keyLabel.toLowerCase() == key) {
      widget.state.act('extensions.office', {
        'presented': !covered,
      }, 'extensions');
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_shortcut);
    widget.state.removeListener(_changed);
    widget.state.watchPopupDeferred.removeListener(_popupDeferralChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final popup = jsonMap(data['watchPopup']);
    final revision = widget.state.accessRevision;
    final colors = DeskColors(context);
    // This layer intentionally sits above the Navigator. Give its controls an
    // overlay host too, so their tooltips never depend on the covered route.
    return Overlay.wrap(
      child: Stack(
        children: [
          ExcludeFocus(
            excluding: covered,
            child: ExcludeSemantics(
              excluding: covered,
              child: IgnorePointer(ignoring: covered, child: widget.child),
            ),
          ),
          if (covered)
            Positioned.fill(
              child: _OfficeCover(
                title: stringValue(office['title'], '工作计划'),
                button: '恢复窗口',
                restore: () => widget.state.act('extensions.office', {
                  'presented': false,
                }, 'extensions'),
              ),
            ),
          if (!covered &&
              !widget.state.watchPopupDeferred.value &&
              popup.isNotEmpty)
            Positioned(
              top: 75,
              right: 24,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 350,
                  maxHeight: 420,
                ),
                child: DeskGlassPanel(
                  level: GlassLevel.overlay,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.bell,
                            color: colors.accent,
                            size: 17,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              '发现关注的关键词',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: colors.ink,
                              ),
                            ),
                          ),
                          DeskIcon('关闭关键词提示', CupertinoIcons.xmark, () {
                            if (!_canActOnPopup(popup, revision)) return;
                            widget.state.act(
                              'extensions.dismissWatchPopup',
                              const {},
                              'extensions',
                            );
                          }),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final hit in jsonItems(popup['hits']).take(8))
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: HoverRow(
                                  onTap: () async {
                                    if (!_canActOnPopup(popup, revision)) {
                                      return;
                                    }
                                    await widget.state.openTopic(
                                      TopicData(jsonMap(hit['post'])),
                                    );
                                    if (!_canActOnPopup(popup, revision)) {
                                      return;
                                    }
                                    await widget.state.act(
                                      'extensions.dismissWatchPopup',
                                      const {},
                                      'extensions',
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          stringValue(
                                            jsonMap(hit['post'])['title'],
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: colors.ink,
                                            fontSize: 13,
                                            height: 1.5,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          hit['words'] is List
                                              ? (hit['words'] as List).join(
                                                  ' · ',
                                                )
                                              : stringValue(hit['words']),
                                          style: TextStyle(
                                            color: colors.accent,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
        ],
      ),
    );
  }
}

class _OfficeCover extends StatelessWidget {
  const _OfficeCover({
    required this.title,
    required this.button,
    required this.restore,
  });
  final String title, button;
  final VoidCallback restore;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return FocusScope(
      autofocus: true,
      child: ColoredBox(
        color: colors.paper.withValues(alpha: 1),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 18,
                ),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.table,
                      color: CupertinoColors.systemGreen,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title.isEmpty ? '工作计划' : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: colors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    DeskButton(
                      button.isEmpty ? '恢复窗口' : button,
                      width: 150,
                      onTap: restore,
                      icon: CupertinoIcons.arrow_uturn_left,
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: colors.line),
              Expanded(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Table(
                      defaultColumnWidth: const FixedColumnWidth(148),
                      columnWidths: const {0: FixedColumnWidth(44)},
                      border: TableBorder.all(color: colors.line),
                      children: [
                        for (var row = 0; row <= 30; row++)
                          TableRow(
                            children: [
                              for (var column = 0; column <= 6; column++)
                                Container(
                                  height: 30,
                                  alignment: column == 0 || row == 0
                                      ? Alignment.center
                                      : Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  color: row == 0 || column == 0
                                      ? colors.well
                                      : colors.paper,
                                  child: Text(
                                    row == 0
                                        ? (column == 0
                                              ? ''
                                              : String.fromCharCode(
                                                  64 + column,
                                                ))
                                        : column == 0
                                        ? '$row'
                                        : row == 1
                                        ? [
                                            '事项',
                                            '负责人',
                                            '开始日期',
                                            '截止日期',
                                            '状态',
                                            '备注',
                                          ][column - 1]
                                        : '',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.ink,
                                      fontWeight: row <= 1
                                          ? FontWeight.w500
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                      ],
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
