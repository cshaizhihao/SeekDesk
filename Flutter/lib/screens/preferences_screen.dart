import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import '../widgets/appearance_picker.dart';
import '../widgets/desk_wordmark.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/desk_page_transition.dart';
import '../widgets/desk_theme.dart';
import '../widgets/node_image_settings.dart';
import '../widgets/preference_previews.dart';

class _PreferenceSegmentLayout {
  const _PreferenceSegmentLayout({
    required this.segments,
    required this.selectedStyle,
    required this.unselectedStyle,
    required this.horizontalWidth,
    required this.segmentHeight,
  });

  final List<GlassSegment> segments;
  final TextStyle selectedStyle, unselectedStyle;
  final double horizontalWidth, segmentHeight;

  factory _PreferenceSegmentLayout.measure(
    BuildContext context,
    List<GlassSegment> segments, {
    required double minHeight,
  }) {
    final theme = GlassTheme.maybeOf(context)?.data.style;
    final native = theme == GlassStyle.ios26 || theme == GlassStyle.ios27;
    const selected = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    final unselected = TextStyle(
      fontSize: 13,
      fontWeight: native ? FontWeight.w400 : FontWeight.w500,
    );
    final spacing = TextStyle(
      height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
      letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
      wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
    );
    var width = 0.0, height = minHeight;
    for (final segment in segments) {
      for (final style in [selected, unselected]) {
        final painter = TextPainter(
          text: TextSpan(
            text: segment.label,
            style:
                (MediaQuery.boldTextOf(context)
                        ? style.copyWith(fontWeight: FontWeight.bold)
                        : style)
                    .merge(spacing),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 1,
        )..layout();
        width = math.max(width, painter.width);
        height = math.max(height, painter.height + 12);
        painter.dispose();
      }
    }
    return _PreferenceSegmentLayout(
      segments: segments,
      selectedStyle: selected,
      unselectedStyle: unselected,
      horizontalWidth: (width + 16) * segments.length + 4,
      segmentHeight: height,
    );
  }
}

class _PreferenceSegments extends StatelessWidget {
  const _PreferenceSegments({
    required this.layout,
    required this.selectedIndex,
    required this.onSelected,
  });

  final _PreferenceSegmentLayout layout;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final vertical = bounds.maxWidth < layout.horizontalWidth;
      return GlassSegmentedControl(
        segments: layout.segments,
        selectedIndex: selectedIndex,
        onSegmentSelected: onSelected,
        direction: vertical ? Axis.vertical : Axis.horizontal,
        height: vertical ? bounds.maxWidth : layout.segmentHeight,
        segmentExtent: vertical ? layout.segmentHeight : null,
        borderRadius: vertical ? 14 : GlassDefaults.capsuleRadius,
        selectedTextStyle: layout.selectedStyle,
        unselectedTextStyle: layout.unselectedStyle,
        quality: GlassQuality.premium,
      );
    },
  );
}

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({required this.state, super.key});
  final AppState state;
  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  int tab = 0;
  double _pageDistance = 12;
  bool managingImages = false;
  bool _checkingUpdates = false;
  bool _installingUpdate = false;
  String? _updateError;
  JsonMap? _releaseCheck;
  Object? _settingsSnapshot;
  (String?, String?) _bundleMetadataSnapshot = (null, null);
  @override
  void initState() {
    super.initState();
    _settingsSnapshot = widget.state.domains['settings'];
    _bundleMetadataSnapshot = (
      widget.state.bundleVersion,
      widget.state.bundleBuild,
    );
    widget.state.addListener(_settingsChanged);
    // act() synchronously notifies the workspace before awaiting the host.
    // Start after mounting so that notification cannot rebuild an ancestor
    // while this settings page is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.act('settings.get', {}, 'settings'));
    });
  }

  final Map<String, double> _dragValues = {};
  final Map<String, Object> _sliderOperations = {};
  final Map<String, FocusNode> _sliderFocus = {};
  final Map<String, GlobalKey> _rowControlKeys = {};
  final Map<String, (String, Object)> _pendingChoices = {};

  void _settingsChanged() {
    final next = widget.state.domains['settings'];
    final metadata = (widget.state.bundleVersion, widget.state.bundleBuild);
    if (mounted &&
        (!identical(_settingsSnapshot, next) ||
            _bundleMetadataSnapshot != metadata)) {
      setState(() {
        _settingsSnapshot = next;
        _bundleMetadataSnapshot = metadata;
      });
    }
  }

  String get _versionDescription {
    final version = widget.state.bundleVersion;
    final build = widget.state.bundleBuild;
    final label = version == null ? '版本信息不可用' : 'V$version';
    return build == null ? label : '$label（构建 $build）';
  }

  @override
  void dispose() {
    widget.state.removeListener(_settingsChanged);
    for (final node in _sliderFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _sliderKey(
    FocusNode node,
    KeyEvent event,
    String key,
    double min,
    double max,
    double fallback, {
    required bool rtl,
  }) {
    if (!node.hasPrimaryFocus ||
        event is! KeyDownEvent && event is! KeyRepeatEvent ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final stored = numberValue(widget.state.domain('settings')[key], fallback);
    final current = (_dragValues[key] ?? (stored.isFinite ? stored : fallback))
        .clamp(min, max);
    final double target;
    if (event.logicalKey == LogicalKeyboardKey.home) {
      target = min;
    } else if (event.logicalKey == LogicalKeyboardKey.end) {
      target = max;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey ==
            (rtl
                ? LogicalKeyboardKey.arrowLeft
                : LogicalKeyboardKey.arrowRight)) {
      target = (current + 1).clamp(min, max);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey ==
            (rtl
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowLeft)) {
      target = (current - 1).clamp(min, max);
    } else {
      return KeyEventResult.ignored;
    }
    if (target != current) unawaited(_commitSlider(key, target));
    return KeyEventResult.handled;
  }

  Future<void> _commitSlider(String key, double value) async {
    final operation = Object();
    _sliderOperations[key] = operation;
    setState(() => _dragValues[key] = value);
    try {
      await update(key, value);
    } finally {
      if (mounted && identical(_sliderOperations[key], operation)) {
        setState(() {
          _sliderOperations.remove(key);
          _dragValues.remove(key);
        });
      }
    }
  }

  double _sliderValue(
    String key,
    JsonMap settings,
    double min,
    double max,
    double fallback,
  ) {
    final stored = numberValue(settings[key], fallback);
    return (_dragValues[key] ?? (stored.isFinite ? stored : fallback)).clamp(
      min,
      max,
    );
  }

  Future<void> update(String key, Object value) async {
    await widget.state.act('settings.update', {
      'key': key,
      'value': value,
    }, 'settings');
  }

  Future<void> openImageSettings() async {
    if (managingImages) return;
    setState(() => managingImages = true);
    try {
      await showNodeImageSettings(context, widget.state);
    } finally {
      if (mounted) setState(() => managingImages = false);
    }
  }

  void _selectTab(int value) {
    if (tab == value) return;
    setState(() {
      _pageDistance = value > tab ? 12 : -12;
      tab = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context),
        settings = widget.state.domain('settings');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DeskPageHeader(
                title: '偏好设置',
                subtitle: '让 SeekDesk 更合你的习惯',
              ),
              const SizedBox(height: 24),
              _PreferenceSegments(
                layout: _PreferenceSegmentLayout.measure(context, const [
                  GlassSegment(label: '通用'),
                  GlassSegment(label: '外观'),
                  GlassSegment(label: '阅读'),
                  GlassSegment(label: '关于'),
                ], minHeight: 38),
                selectedIndex: tab,
                onSelected: _selectTab,
              ),
              const SizedBox(height: 24),
              DeskPageTransition(
                identity: tab,
                distance: _pageDistance,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (tab == 0) ...[
                      DeskSection(
                        quiet: true,
                        title: '通用功能',
                        child: Column(
                          children: [
                            _toggle(
                              '自动刷新列表',
                              'workspace.autoRefresh',
                              settings,
                              true,
                            ),
                            _row(
                              'NodeImage 图片上传',
                              DeskButton(
                                '图床设置',
                                icon: CupertinoIcons.gear,
                                width: 112,
                                onTap: managingImages
                                    ? null
                                    : openImageSettings,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (tab == 1) ...[
                      DeskSection(
                        quiet: true,
                        title: '界面外观',
                        child: Column(
                          children: [
                            AppearancePicker(
                              family: DeskThemeFamily.fromSetting(
                                settings[DeskThemeFamily.preference],
                              ),
                              value: stringValue(
                                settings['appearance'],
                                'system',
                              ),
                              showReadingBackground:
                                  settings['workspace.mistBackdrop'] != false,
                              onChanged: (value) =>
                                  _selectChoice('appearance', value, 'system'),
                              onFamilyChanged: (family) => _selectChoice(
                                DeskThemeFamily.preference,
                                family.name,
                                DeskThemeFamily.classic.name,
                              ),
                            ),
                            _toggle(
                              '阅读背景',
                              'workspace.mistBackdrop',
                              settings,
                              true,
                            ),
                            _brandChoice(settings),
                          ],
                        ),
                      ),
                      DeskSection(
                        quiet: true,
                        title: '窗口布局',
                        child: Column(
                          children: [
                            _slider(
                              '侧边栏宽度',
                              'workspace.sidebarWidth',
                              settings,
                              184,
                              360,
                              228,
                            ),
                            _slider(
                              '帖子列表宽度',
                              'workspace.topicColumnWidth',
                              settings,
                              240,
                              620,
                              340,
                            ),
                          ],
                        ),
                      ),
                    ] else if (tab == 2) ...[
                      DeskSection(
                        quiet: true,
                        title: '阅读体验',
                        child: Column(
                          children: [
                            _slider(
                              '正文文字',
                              'workspace.readerTextSize',
                              settings,
                              13,
                              24,
                              15,
                            ),
                            _slider(
                              '作者栏大小',
                              'workspace.floorAuthorScale',
                              settings,
                              80,
                              160,
                              100,
                              suffix: '%',
                            ),
                            PreferenceReaderPreview(
                              state: widget.state,
                              bodySize: _sliderValue(
                                'workspace.readerTextSize',
                                settings,
                                13,
                                24,
                                15,
                              ),
                              authorScale: _sliderValue(
                                'workspace.floorAuthorScale',
                                settings,
                                80,
                                160,
                                100,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _slider(
                              '帖子列表文字',
                              'workspace.listTextSize',
                              settings,
                              12,
                              24,
                              15,
                            ),
                            PreferenceListPreview(
                              state: widget.state,
                              titleSize: _sliderValue(
                                'workspace.listTextSize',
                                settings,
                                12,
                                24,
                                15,
                              ),
                              compact:
                                  settings['workspace.readingDensity'] ==
                                  'compact',
                            ),
                            const SizedBox(height: 12),
                            _slider(
                              '论坛版块文字',
                              'workspace.boardTextSize',
                              settings,
                              11,
                              22,
                              13,
                            ),
                            _slider(
                              '侧栏热榜文字',
                              'workspace.rankingTextSize',
                              settings,
                              11,
                              22,
                              12,
                            ),
                            PreferenceSidebarPreview(
                              boardSize: _sliderValue(
                                'workspace.boardTextSize',
                                settings,
                                11,
                                22,
                                13,
                              ),
                              rankingSize: _sliderValue(
                                'workspace.rankingTextSize',
                                settings,
                                11,
                                22,
                                12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _choice(
                              '阅读密度',
                              'workspace.readingDensity',
                              settings,
                              const ['compact', 'comfortable'],
                              const ['紧凑', '舒适'],
                              'comfortable',
                            ),
                            _choice(
                              '发送回复快捷键',
                              'workspace.replySendKey',
                              settings,
                              const [
                                'commandReturn',
                                'returnKey',
                                'buttonOnly',
                              ],
                              const ['⌘ Return', 'Return', '仅按钮'],
                              'commandReturn',
                            ),
                            _toggle(
                              '阅读时收起帖子列表',
                              'workspace.hideListWhileReading',
                              settings,
                              false,
                            ),
                            _toggle(
                              '自动加载更早的帖子',
                              'workspace.autoLoadOlder',
                              settings,
                              false,
                            ),
                          ],
                        ),
                      ),
                      DeskSection(
                        quiet: true,
                        title: '测速报告',
                        subtitle: '按图片原始宽高比显示，长图保持宽度并自然展开。',
                        child: Column(
                          children: [
                            _slider(
                              'NQ 显示比例',
                              'workspace.nqReportScale',
                              settings,
                              25,
                              200,
                              100,
                              suffix: '%',
                            ),
                            _slider(
                              'TQ 显示比例',
                              'workspace.tqReportScale',
                              settings,
                              50,
                              200,
                              100,
                              suffix: '%',
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      DeskSection(
                        quiet: true,
                        title: 'SeekDesk',
                        subtitle: '$_versionDescription · www.seekdesk.cc',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '开发者 @cshaizhihao',
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'SeekDesk 是独立开发的第三方客户端，与 NodeSeek 官方没有隶属关系。帖子内容、账号权限和社区规则均以 NodeSeek 为准。',
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 14,
                                height: 1.75,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 9,
                              runSpacing: 9,
                              children: [
                                DeskButton(
                                  'NodeSeek',
                                  icon: CupertinoIcons.globe,
                                  width: 114,
                                  onTap: () => widget.state.act(
                                    'external.open',
                                    {'url': 'https://www.nodeseek.com/'},
                                  ),
                                ),
                                DeskButton(
                                  '官方网站',
                                  icon: CupertinoIcons.link,
                                  width: 114,
                                  onTap: () => widget.state.act(
                                    'external.open',
                                    {'url': 'https://www.seekdesk.cc/'},
                                  ),
                                ),
                                _aboutLink(
                                  '项目源码',
                                  'https://github.com/cshaizhihao/SeekDesk',
                                  CupertinoIcons
                                      .chevron_left_slash_chevron_right,
                                ),
                                _aboutLink(
                                  '查看发布版本',
                                  'https://github.com/cshaizhihao/SeekDesk/releases',
                                  CupertinoIcons.arrow_up_right,
                                  width: 142,
                                ),
                                _aboutLink(
                                  '问题反馈',
                                  'https://github.com/cshaizhihao/SeekDesk/issues',
                                  CupertinoIcons.bubble_left,
                                ),
                                _aboutLink(
                                  'GNU GPLv3.0',
                                  'https://github.com/cshaizhihao/SeekDesk/blob/main/LICENSE',
                                  CupertinoIcons.doc_text,
                                  width: 142,
                                ),
                                _aboutLink(
                                  '致谢与许可证',
                                  'https://github.com/cshaizhihao/SeekDesk/blob/main/THIRD_PARTY_NOTICES.md',
                                  CupertinoIcons.heart,
                                  width: 142,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      _aboutUpdates(colors),
                      DeskSection(
                        quiet: true,
                        title: '开源组件',
                        child: Text(
                          'Liquid Glass Widgets 1.17.3 · MIT\nFlutter · BSD\nSparkle · MIT\nYams · MIT\n\n完整许可证随应用源码与安装包提供。',
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 13,
                            height: 1.7,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _aboutLink(
    String title,
    String url,
    IconData icon, {
    double width = 114,
  }) => DeskButton(
    title,
    icon: icon,
    width: width,
    quiet: true,
    onTap: () => widget.state.act('external.open', {'url': url}),
  );

  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() {
      _checkingUpdates = true;
      _releaseCheck = null;
      _updateError = null;
    });
    JsonMap response;
    try {
      response = await widget.state.client.call('updates.check');
    } catch (_) {
      response = const {'status': 'failed'};
    }
    if (!mounted) return;
    setState(() {
      _checkingUpdates = false;
      _releaseCheck = response;
    });
  }

  Future<void> _installUpdate() async {
    if (_installingUpdate || _checkingUpdates) return;
    setState(() {
      _installingUpdate = true;
      _updateError = null;
    });
    try {
      await widget.state.client.call('updates.install');
    } on NativeFailure catch (error) {
      if (mounted) setState(() => _updateError = error.message);
    } catch (_) {
      if (mounted) setState(() => _updateError = '暂时无法启动更新，请稍后重试。');
    } finally {
      if (mounted) setState(() => _installingUpdate = false);
    }
  }

  Widget _aboutUpdates(DeskColors colors) {
    final result = _releaseCheck;
    final version = stringValue(result?['version']);
    final release = stringValue(result?['releaseURL']);
    final status = result?['status'];
    final message = _checkingUpdates
        ? '正在检查 GitHub 发布版本…'
        : _updateError ??
              switch (status) {
                'current' => '已是最新版本（V$version）。',
                'ahead' => '本机版本高于 GitHub 上的正式版 V$version。',
                'available' => '发现新版本 V$version，可以在应用内更新。',
                'awaitingPackage' => '发现新版本 V$version，应用内更新包尚未发布。',
                'unknownInstalled' => 'GitHub 最新版本为 V$version。当前版本无法自动比对。',
                'rateLimited' => 'GitHub 暂时限制了请求次数，请稍后再试。',
                null => '从 GitHub 获取最新正式版本。',
                _ => '暂时无法检查更新，请稍后重试。',
              };
    return DeskSection(
      quiet: true,
      title: '软件更新',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: TextStyle(
                color: colors.secondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              DeskButton(
                '检查更新',
                width: 114,
                icon: CupertinoIcons.arrow_clockwise,
                busy: _checkingUpdates,
                onTap: _installingUpdate ? null : _checkUpdates,
              ),
              if (status == 'available')
                DeskButton(
                  '更新并重启',
                  icon: CupertinoIcons.arrow_down_circle,
                  width: 126,
                  busy: _installingUpdate,
                  onTap: _installUpdate,
                ),
              if (release.isNotEmpty && status != 'current')
                _aboutLink('发布说明', release, CupertinoIcons.doc_text),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String title, Widget control, {double? controlWidth}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: LayoutBuilder(
      builder: (context, bounds) {
        // Responsive reflow moves the control between Row and Column parents.
        // Preserve its focus, hover and spring state through that move.
        final retainedControl = KeyedSubtree(
          key: _rowControlKeys.putIfAbsent(title, GlobalKey.new),
          child: control,
        );
        final label = Text(
          title,
          style: TextStyle(color: DeskColors(context).ink, fontSize: 13),
        );
        final labelWidth =
            120 * MediaQuery.textScalerOf(context).scale(13) / 13;
        if (controlWidth != null &&
            bounds.maxWidth < controlWidth + labelWidth + 12) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: bounds.maxWidth),
                  child: retainedControl,
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 12),
            retainedControl,
          ],
        );
      },
    ),
  );

  Widget _toggle(String title, String key, JsonMap settings, bool fallback) =>
      _row(
        title,
        GlassSwitch(
          value: settings[key] is bool ? settings[key] as bool : fallback,
          onChanged: (value) => update(key, value),
          quality: GlassQuality.premium,
          semanticLabel: title,
        ),
      );

  Widget _choice(
    String title,
    String key,
    JsonMap settings,
    List<String> values,
    List<String> labels,
    String fallback,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: DeskColors(context).ink, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (var index = 0; index < values.length; index++)
                MergeSemantics(
                  child: Semantics(
                    selected:
                        stringValue(settings[key], fallback) == values[index],
                    child: DeskButton(
                      '${stringValue(settings[key], fallback) == values[index] ? '✓ ' : ''}${labels[index]}',
                      semanticLabel: labels[index],
                      selected:
                          stringValue(settings[key], fallback) == values[index],
                      tint:
                          stringValue(settings[key], fallback) == values[index]
                          ? DeskColors(context).selectionInk
                          : null,
                      width: key == 'workspace.replySendKey' ? 116 : 88,
                      onTap: () => _selectChoice(key, values[index], fallback),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  void _selectChoice(String key, String value, String fallback) {
    // A glass segment can report pointer-down and activation in the same turn.
    // Also retain a later different choice while settings writes are serialized.
    final current =
        _pendingChoices[key]?.$1 ??
        stringValue(widget.state.domain('settings')[key], fallback);
    if (current == value) return;
    final token = Object();
    _pendingChoices[key] = (value, token);
    unawaited(() async {
      try {
        await update(key, value);
      } finally {
        if (identical(_pendingChoices[key]?.$2, token)) {
          _pendingChoices.remove(key);
        }
      }
    }());
  }

  Widget _brandChoice(JsonMap settings) {
    const palettes = ['Cobalt', 'Teal', 'Fern', 'Iris', 'Amber', 'Coral'];
    const labels = ['钴蓝', '海松', '蕨绿', '鸢尾', '琥珀', '珊瑚'];
    const preference = 'workspace.logoPalette';
    final colors = DeskColors(context);
    final stored = stringValue(settings[preference], 'Cobalt');
    final current = palettes.contains(stored) ? stored : 'Cobalt';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('品牌配色', style: TextStyle(color: colors.ink, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              '用于顶栏 Logo 与 Dock 图标',
              style: DeskTypography.metadata.copyWith(color: colors.secondary),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 550),
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final columns = ((bounds.maxWidth + 10) / 150).floor().clamp(
                    1,
                    3,
                  );
                  final width =
                      (bounds.maxWidth - 10 * (columns - 1)) / columns;
                  final labelHeight =
                      MediaQuery.textScalerOf(context).scale(13) *
                      math.max(
                        1.45,
                        MediaQuery.maybeLineHeightScaleFactorOverrideOf(
                              context,
                            ) ??
                            1.45,
                      );
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var index = 0; index < palettes.length; index++)
                        Semantics(
                          key: ValueKey('preference-brand-${palettes[index]}'),
                          button: true,
                          selected: current == palettes[index],
                          label: labels[index],
                          onTap: () => _selectChoice(
                            preference,
                            palettes[index],
                            'Cobalt',
                          ),
                          excludeSemantics: true,
                          child: GlassButton.custom(
                            width: width,
                            // Include the two border pixels as well as padding.
                            height: 34 + 4 + labelHeight.ceilToDouble() + 18,
                            shape: const LiquidRoundedRectangle(
                              borderRadius: 9,
                            ),
                            quality: GlassQuality.premium,
                            settings: DeskMaterials.tile(context),
                            useOwnLayer: true,
                            onTap: () => _selectChoice(
                              preference,
                              palettes[index],
                              'Cobalt',
                            ),
                            child: Container(
                              width: double.infinity,
                              height: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: current == palettes[index]
                                    ? colors.selection
                                    : const Color(0x00000000),
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: current == palettes[index]
                                      ? colors.accent.withValues(alpha: .55)
                                      : const Color(0x00000000),
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  DeskWordmark(
                                    palette: palettes[index],
                                    height: 34,
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: Icon(
                                          current == palettes[index]
                                              ? CupertinoIcons
                                                    .check_mark_circled_solid
                                              : CupertinoIcons.circle,
                                          size: 15,
                                          color: current == palettes[index]
                                              ? colors.accent
                                              : colors.secondary,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      Flexible(
                                        child: Text(
                                          labels[index],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: colors.ink,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            height: 1.45,
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
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String title,
    String key,
    JsonMap settings,
    double min,
    double max,
    double fallback, {
    String suffix = ' 点',
  }) {
    final colors = DeskColors(context);
    final value = _sliderValue(key, settings, min, max, fallback);
    String describe(double amount) => '${amount.round()}$suffix';
    final increased = (value + 1).clamp(min, max);
    final decreased = (value - 1).clamp(min, max);
    // Use the package's own FocusableActionDetector node. A surrounding Focus
    // would add a second Tab stop and separate keyboard and glass focus rings.
    final focus = _sliderFocus.putIfAbsent(
      key,
      () => FocusNode(debugLabel: 'preference-slider-$key'),
    );
    focus.onKeyEvent = (node, event) => _sliderKey(
      node,
      event,
      key,
      min,
      max,
      fallback,
      rtl: Directionality.of(context) == TextDirection.rtl,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, bounds) {
              final label = Text(
                title,
                style: TextStyle(color: colors.ink, fontSize: 13),
              );
              final textScaler = MediaQuery.textScalerOf(context);
              final actions = KeyedSubtree(
                key: _rowControlKeys.putIfAbsent(
                  'slider-actions-$key',
                  GlobalKey.new,
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      describe(value),
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    DeskButton(
                      '恢复默认',
                      key: ValueKey('preference-reset-$key'),
                      semanticLabel: '$title，恢复默认',
                      width: (textScaler.scale(12) * 4 + 24).clamp(
                        82,
                        double.infinity,
                      ),
                      height: (textScaler.scale(12) * 1.25 + 12).clamp(
                        28,
                        double.infinity,
                      ),
                      quiet: true,
                      onTap: value == fallback
                          ? null
                          : () => _commitSlider(key, fallback),
                    ),
                  ],
                ),
              );
              if (bounds.maxWidth < 330 * textScaler.scale(13) / 13) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, const SizedBox(height: 6), actions],
                );
              }
              return Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 12),
                  actions,
                ],
              );
            },
          ),
          Semantics(
            key: ValueKey('preference-slider-$key'),
            container: true,
            slider: true,
            enabled: true,
            label: title,
            value: describe(value),
            increasedValue: value < max ? describe(increased) : null,
            decreasedValue: value > min ? describe(decreased) : null,
            onIncrease: value < max
                ? () => _commitSlider(key, increased)
                : null,
            onDecrease: value > min
                ? () => _commitSlider(key, decreased)
                : null,
            // The pinned package announces a normalized range percentage.
            // Expose the actual point/scale value once, including persistence
            // for VoiceOver adjustments which do not trigger onChangeEnd.
            excludeSemantics: true,
            child: GlassSlider(
              activeColor: colors.accent,
              focusNode: focus,
              label: title,
              value: value,
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: (value) => setState(() {
                // A completed older write must not erase a newer live drag,
                // including a drag that returns to the same numeric value.
                _sliderOperations.remove(key);
                _dragValues[key] = value;
              }),
              onChangeEnd: (value) => _commitSlider(key, value),
              quality: GlassQuality.premium,
            ),
          ),
        ],
      ),
    );
  }
}
