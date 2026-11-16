import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import '../widgets/extension_catalog.dart';
import '../widgets/extension_guide.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/desk_page_transition.dart';
import '../widgets/desk_input_surface.dart';
import 'proxy_screen.dart';
import 'tools_screen.dart';

class ExtensionsScreen extends StatefulWidget {
  const ExtensionsScreen({required this.state, this.onOpenRankings, super.key});
  final AppState state;
  final VoidCallback? onOpenRankings;
  @override
  State<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends State<ExtensionsScreen> {
  String? detail;
  int _catalog = 0;
  double _pageDistance = 12;
  bool _loading = true;
  String? _loadError;
  JsonMap? _observed, _session;
  int _revision = 0, _loadGeneration = 0;
  final Set<String> _changingInstallation = {};
  final Map<String, bool> _changingEnabled = {};
  final Map<String, String> _operationErrors = {};
  final _catalogScroll = ScrollController();
  final Map<String, GlobalKey> _settingsKeys = {};

  @override
  void initState() {
    super.initState();
    _observed = widget.state.domains['extensions'];
    _session = widget.state.domains['session'];
    _revision = widget.state.accessRevision;
    widget.state.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _changed() {
    if (!mounted) return;
    final next = widget.state.domains['extensions'];
    final session = widget.state.domains['session'];
    if (_revision != widget.state.accessRevision) {
      _revision = widget.state.accessRevision;
      _loadGeneration++;
      detail = null;
      _changingInstallation.clear();
      _changingEnabled.clear();
      _operationErrors.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    } else if (identical(next, _observed) && identical(session, _session)) {
      return;
    }
    _observed = next;
    _session = session;
    setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final revision = widget.state.accessRevision;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final result = await widget.state.act('extensions.list', {}, 'extensions');
    if (!mounted ||
        generation != _loadGeneration ||
        revision != widget.state.accessRevision) {
      return;
    }
    setState(() {
      _loading = false;
      if (result == null || result['items'] is! List) {
        _loadError = '未能读取扩展信息，请重试。';
      }
    });
  }

  void _openDetail(JsonMap item) {
    final id = stringValue(item['id']);
    if (detail == id) return;
    setState(() {
      _pageDistance = 12;
      detail = id;
    });
  }

  void _closeDetail() {
    if (detail == null) return;
    setState(() {
      _pageDistance = -12;
      detail = null;
    });
  }

  void _selectCatalog(int value) {
    if (_catalog == value) return;
    setState(() {
      _pageDistance = value > _catalog ? 12 : -12;
      _catalog = value;
    });
  }

  Future<void> _setEnabled(JsonMap item, bool value) async {
    final id = stringValue(item['id']);
    final current = jsonItems(widget.state.domain('extensions')['items'])
        .where((entry) => entry['id'] == id)
        .firstOrNull;
    if (current?['installed'] != true ||
        _changingInstallation.contains(id) ||
        _changingEnabled.containsKey(id) ||
        (current?['enabled'] == true) == value) {
      return;
    }
    final revision = widget.state.accessRevision;
    setState(() {
      _changingEnabled[id] = value;
      _operationErrors.remove(id);
    });
    try {
      final result = await widget.state.act('extensions.setEnabled', {
        'id': id,
        'enabled': value,
      }, 'extensions');
      if (mounted &&
          revision == widget.state.accessRevision &&
          result == null) {
        setState(() => _operationErrors[id] = '未能更改启用状态，请重试。');
      }
    } finally {
      if (mounted && revision == widget.state.accessRevision) {
        setState(() => _changingEnabled.remove(id));
      }
    }
  }

  Future<void> _changeInstallation(JsonMap item) async {
    final id = stringValue(item['id']);
    if (_changingInstallation.contains(id) ||
        _changingEnabled.containsKey(id)) {
      return;
    }
    final installed = item['installed'] == true;
    final revision = widget.state.accessRevision;
    setState(() {
      _changingInstallation.add(id);
      _operationErrors.remove(id);
    });
    try {
      if (installed &&
          !await confirmAction(
            context,
            title: '移除扩展',
            message: id == 'proxy'
                ? '确定移除“${item['title']}”？代理将停止连接，已保存的节点和订阅会保留。'
                : '确定从工作台移除“${item['title']}”？',
            accept: '移除',
            destructive: true,
          )) {
        return;
      }
      if (!mounted || revision != widget.state.accessRevision) return;
      final result = await widget.state.act(
        installed ? 'extensions.uninstall' : 'extensions.install',
        {'id': id},
        'extensions',
      );
      if (mounted &&
          revision == widget.state.accessRevision &&
          result == null) {
        setState(
          () => _operationErrors[id] = installed ? '移除未成功，请重试。' : '安装未成功，请重试。',
        );
      }
    } finally {
      if (mounted && revision == widget.state.accessRevision) {
        setState(() => _changingInstallation.remove(id));
      }
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    _catalogScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DeskPageTransition(
    identity: (detail, _catalog),
    distance: _pageDistance,
    child: _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final colors = DeskColors(context);
    final items = jsonItems(widget.state.domain('extensions')['items']);
    final selected = items.where((item) => item['id'] == detail).firstOrNull;
    if (selected != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DeskButton(
                '扩展中心',
                icon: CupertinoIcons.chevron_left,
                width: 112,
                quiet: true,
                onTap: _closeDetail,
              ),
            ),
          ),
          Expanded(child: _detail(selected)),
        ],
      );
    }
    final installed = items.where((item) => item['installed'] == true).toList();
    final available = items.where((item) => item['installed'] != true).toList();
    return SingleChildScrollView(
      key: const PageStorageKey('extension-catalog-scroll'),
      controller: _catalogScroll,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DeskPageHeader(
                title: '扩展中心',
                subtitle: '把常用工具，放进你的工作台。',
                trailing: DeskIcon(
                  '刷新扩展',
                  CupertinoIcons.arrow_clockwise,
                  _loading ? null : _load,
                  busy: _loading,
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth:
                        320 * MediaQuery.textScalerOf(context).scale(13) / 13,
                  ),
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final labels = [
                        '已安装 ${installed.length}',
                        '全部扩展 ${items.length}',
                      ];
                      var labelWidth = 0.0;
                      var controlHeight = 32.0;
                      for (final label in labels) {
                        final painter = TextPainter(
                          text: TextSpan(
                            text: label,
                            style: DefaultTextStyle.of(context).style.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          maxLines: 1,
                        )..layout();
                        labelWidth = painter.width.clamp(
                          labelWidth,
                          double.infinity,
                        );
                        controlHeight = (painter.height + 12).clamp(
                          controlHeight,
                          double.infinity,
                        );
                        painter.dispose();
                      }
                      // Keep complete labels and the same glass control when
                      // larger text no longer fits two horizontal segments.
                      final vertical =
                          bounds.maxWidth < (labelWidth + 16) * 2 + 4;
                      return GlassSegmentedControl(
                        segments: [
                          for (final label in labels)
                            GlassSegment(label: label),
                        ],
                        direction: vertical ? Axis.vertical : Axis.horizontal,
                        height: vertical ? bounds.maxWidth : controlHeight,
                        segmentExtent: vertical ? controlHeight : null,
                        borderRadius: vertical
                            ? 14
                            : GlassDefaults.capsuleRadius,
                        selectedIndex: _catalog,
                        onSegmentSelected: _selectCatalog,
                        quality: GlassQuality.premium,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 22),
              if (_loadError != null && items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _loadError!,
                    style: TextStyle(color: colors.secondary, fontSize: 13),
                  ),
                ),
              if (items.isEmpty)
                _loading
                    ? const DeskEmpty(
                        '正在读取扩展',
                        icon: CupertinoIcons.square_grid_2x2,
                      )
                    : DeskEmpty(
                        _loadError == null ? '暂无可用扩展' : '暂时无法读取扩展',
                        detail: _loadError,
                        action: DeskButton('重新加载', onTap: _load),
                      )
              else if (_catalog == 0 && installed.isEmpty)
                DeskEmpty(
                  '还没有已安装的扩展',
                  icon: CupertinoIcons.square_grid_2x2,
                  action: DeskButton(
                    '浏览全部扩展',
                    width: 140,
                    onTap: () => _selectCatalog(1),
                  ),
                )
              else ...[
                if (_catalog == 1 && available.isNotEmpty)
                  ExtensionCatalogGroup(
                    title: '未安装',
                    items: available,
                    onOpen: _openDetail,
                  ),
                if (installed.isNotEmpty)
                  ExtensionCatalogGroup(
                    title: '已安装',
                    items: installed,
                    onOpen: _openDetail,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _identity(JsonMap item) {
    final id = stringValue(item['id']);
    final installed = item['installed'] == true;
    final colors = DeskColors(context);
    final busy =
        _changingInstallation.contains(id) || _changingEnabled.containsKey(id);
    return DeskGlassPanel(
      quiet: true,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.hover,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(extensionIcon(id), size: 22, color: colors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stringValue(item['title']),
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      stringValue(item['description']),
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Text(
                extensionStatus(item),
                style: TextStyle(color: colors.secondary, fontSize: 12),
              ),
              if (installed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '启用扩展',
                      style: TextStyle(color: colors.ink, fontSize: 12),
                    ),
                    const SizedBox(width: 10),
                    Semantics(
                      enabled: !busy,
                      child: ExcludeFocus(
                        excluding: busy,
                        child: ExcludeSemantics(
                          excluding: busy,
                          child: IgnorePointer(
                            ignoring: busy,
                            child: GlassSwitch(
                              value:
                                  _changingEnabled[id] ??
                                  item['enabled'] == true,
                              semanticLabel:
                                  '启用${stringValue(item['title'])}扩展',
                              onChanged: (value) => _setEnabled(item, value),
                              quality: GlassQuality.premium,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: CupertinoActivityIndicator(radius: 6),
                      ),
                  ],
                )
              else
                DeskButton(
                  '添加扩展',
                  width: 115,
                  icon: CupertinoIcons.plus,
                  busy: busy,
                  onTap: busy ? null : () => _changeInstallation(item),
                ),
            ],
          ),
          if (_operationErrors[id] != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _operationErrors[id]!,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _removal(JsonMap item) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Text(
          '不再需要这个扩展？',
          style: DeskTypography.metadata.copyWith(
            color: DeskColors(context).secondary,
          ),
        ),
        DeskButton(
          '移除扩展',
          width: 110,
          icon: CupertinoIcons.trash,
          busy: _changingInstallation.contains(stringValue(item['id'])),
          onTap:
              _changingInstallation.contains(stringValue(item['id'])) ||
                  _changingEnabled.containsKey(stringValue(item['id']))
              ? null
              : () => _changeInstallation(item),
        ),
      ],
    ),
  );

  Widget _detail(JsonMap item) {
    final id = stringValue(item['id']);
    final installed = item['installed'] == true;
    if (id == 'proxy' && installed) {
      return ProxyScreen(
        state: widget.state,
        header: Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: _identity(item),
        ),
        footer: _removal(item),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        return SingleChildScrollView(
          key: PageStorageKey('extension-detail-$id'),
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _identity(item),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, local) {
                      final settings = KeyedSubtree(
                        key: _settingsKeys.putIfAbsent(id, GlobalKey.new),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (installed)
                              _ExtensionControls(
                                key: ValueKey((
                                  id,
                                  widget.state.accessRevision,
                                )),
                                state: widget.state,
                                id: id,
                                onOpenRankings: widget.onOpenRankings,
                              )
                            else
                              ExtensionGuide(id: id, preview: true),
                            ExtensionSources(id: id, state: widget.state),
                          ],
                        ),
                      );
                      if (!installed) return settings;
                      if (local.maxWidth >= 802) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: settings),
                            const SizedBox(width: 20),
                            SizedBox(width: 280, child: ExtensionGuide(id: id)),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          settings,
                          ExtensionGuide(id: id),
                        ],
                      );
                    },
                  ),
                  if (installed) _removal(item),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ExtensionControls extends StatefulWidget {
  const _ExtensionControls({
    required this.state,
    required this.id,
    this.onOpenRankings,
    super.key,
  });
  final AppState state;
  final String id;
  final VoidCallback? onOpenRankings;
  @override
  State<_ExtensionControls> createState() => _ExtensionControlsState();
}

class _ExtensionControlsState extends State<_ExtensionControls>
    with WidgetsBindingObserver {
  late final TextEditingController value, note, button, keyInput;
  bool _attendanceBusy = false;
  bool _permissionLoading = false;
  bool _openingNotifications = false;
  String? _notificationError;
  String? _attendanceResult, _attendanceKind, _actionError;
  bool _acknowledging = false;
  final Set<String> _saving = {};

  bool get _active =>
      jsonItems(widget.state.domain('extensions')['items'])
          .any((item) => item['id'] == widget.id && item['active'] == true);
  bool get _canAttend =>
      widget.state.signedIn &&
      widget.state.domain('session')['canCompose'] == true;

  Future<void> _configure(JsonMap changes) async {
    final config = jsonMap(
      jsonMap(widget.state.domain('extensions')['settings'])[widget.id],
    );
    if (changes.keys.any(_saving.contains) ||
        changes.entries.every((entry) => config[entry.key] == entry.value)) {
      return;
    }
    final revision = widget.state.accessRevision;
    setState(() {
      _saving.addAll(changes.keys);
      _actionError = null;
    });
    try {
      final result = await widget.state.act('extensions.configure', {
        'id': widget.id,
        'settings': changes,
      }, 'extensions');
      if (mounted &&
          revision == widget.state.accessRevision &&
          result == null) {
        setState(() => _actionError = '设置未保存，请重试。');
      }
    } finally {
      if (mounted && revision == widget.state.accessRevision) {
        setState(() => _saving.removeAll(changes.keys));
      }
    }
  }

  Future<void> _acknowledgeHits() async {
    if (_acknowledging ||
        intValue(widget.state.domain('extensions')['unread']) == 0) {
      return;
    }
    final revision = widget.state.accessRevision;
    setState(() {
      _acknowledging = true;
      _actionError = null;
    });
    try {
      final result = await widget.state.act(
        'extensions.acknowledgeHits',
        {},
        'extensions',
      );
      if (mounted &&
          revision == widget.state.accessRevision &&
          result == null) {
        setState(() => _actionError = '未能标记已读，请重试。');
      }
    } finally {
      if (mounted && revision == widget.state.accessRevision) {
        setState(() => _acknowledging = false);
      }
    }
  }

  Widget _label(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      title,
      style: DeskTypography.control.copyWith(color: DeskColors(context).ink),
    ),
  );

  Widget _error() => _actionError == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _actionError!,
              style: TextStyle(color: DeskColors(context).ink, fontSize: 12),
            ),
          ),
        );

  Future<void> _refreshNotificationAccess() async {
    if (_permissionLoading) return;
    setState(() {
      _permissionLoading = true;
      _notificationError = null;
    });
    final result = await widget.state.act('extensions.list', {}, 'extensions');
    if (!mounted) return;
    setState(() {
      _permissionLoading = false;
      if (result == null || result['settings'] is! Map) {
        _notificationError = '暂时无法刷新系统通知权限，请重试。';
      }
    });
  }

  Future<void> _openNotificationSettings() async {
    if (_openingNotifications) return;
    setState(() {
      _openingNotifications = true;
      _notificationError = null;
    });
    try {
      // Native owns the fixed destination; no caller-provided URL is accepted.
      final result = await widget.state.client.call(
        'settings.openNotifications',
      );
      if (result['opened'] != true) {
        throw const NativeFailure('settings_not_opened', '系统通知设置未能打开，请重试。');
      }
    } catch (error) {
      if (mounted) setState(() => _notificationError = error.toString());
    } finally {
      if (mounted) setState(() => _openingNotifications = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.id == 'keywords') {
      _refreshNotificationAccess();
    }
  }

  Widget _notificationAccess(JsonMap config, DeskColors colors) {
    final access = intValue(config['notificationAccess'], -1);
    final status = switch (access) {
      0 => '尚未请求系统权限',
      1 => '系统未允许通知',
      2 => '系统已允许通知',
      3 => '系统仅允许静默通知',
      4 => '系统已临时允许通知',
      _ => '系统通知权限暂不可用',
    };
    final description = switch (access) {
      0 => '开启上方开关后，macOS 会询问是否允许通知。',
      1 => '请在系统设置中允许 SeekDesk 发送通知。',
      2 when config['systemNotifications'] != true => '关键词系统通知当前已关闭。',
      2 => '关键词命中后可发送系统通知。',
      3 => '通知会静默送达，可在系统设置中调整提醒方式。',
      4 => '可在系统设置中查看通知权限。',
      _ => '刷新权限后重试，或在系统设置中检查。',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              status,
              style: TextStyle(
                color: colors.ink,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            description,
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              DeskButton(
                '系统通知设置',
                icon: CupertinoIcons.settings,
                width: 146,
                busy: _openingNotifications,
                onTap: _openingNotifications ? null : _openNotificationSettings,
              ),
              const SizedBox(width: 10),
              DeskIcon(
                '刷新通知权限',
                CupertinoIcons.arrow_clockwise,
                _permissionLoading ? null : _refreshNotificationAccess,
                busy: _permissionLoading,
              ),
            ],
          ),
          if (_notificationError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _notificationError!,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _performAttendance(JsonMap config) async {
    if (_attendanceBusy || !_canAttend || !_active) return;
    final account = widget.state.accessRevision;
    setState(() => _attendanceBusy = true);
    try {
      if (!await confirmAction(
            context,
            title: '每日签到',
            message: '使用当前账号进行今日签到？',
          ) ||
          !mounted ||
          account != widget.state.accessRevision ||
          !_canAttend ||
          !_active) {
        return;
      }
      final result = await widget.state.act('attendance.perform', {
        'mode': config['mode'] ?? 'fixed',
      });
      if (!mounted ||
          account != widget.state.accessRevision ||
          result == null) {
        return;
      }
      final current = result['current'];
      final balance = current is num ? ' · 当前 $current 个鸡腿' : '';
      final gain = result['gain'];
      final message = switch (result['kind']) {
        'completed' =>
          '${gain is num ? '今日已签到 · 获得 $gain 个鸡腿' : '今日签到成功'}$balance',
        'alreadyCompleted' => '今天已在 NodeSeek 签到$balance',
        'signedOut' => '请登录 NodeSeek 后继续签到',
        'verification' => '签到需要完成 NodeSeek 验证，请先完成验证后再试。',
        'failed' => '签到暂未成功，请稍后重试。',
        _ => '未确认签到结果，请刷新账号信息核对。',
      };
      setState(() {
        _attendanceResult = message;
        _attendanceKind = stringValue(result['kind']);
      });
      widget.state.showMessage(message);
    } finally {
      if (mounted) setState(() => _attendanceBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final config = jsonMap(
      jsonMap(widget.state.domain('extensions')['settings'])[widget.id],
    );
    value = TextEditingController(
      text: stringValue(config[widget.id == 'keywords' ? 'words' : 'title']),
    );
    note = TextEditingController(text: stringValue(config['note']));
    button = TextEditingController(text: stringValue(config['button']));
    keyInput = TextEditingController(text: stringValue(config['key'], '9'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    value.dispose();
    note.dispose();
    button.dispose();
    keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context),
        config = jsonMap(
          jsonMap(widget.state.domain('extensions')['settings'])[widget.id],
        );
    return switch (widget.id) {
      'keywords' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskSection(
            quiet: true,
            title: '监控关键词',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label('关键词规则'),
                DeskInputSurface(
                  child: CupertinoTextField(
                    controller: value,
                    decoration: const BoxDecoration(),
                    style: TextStyle(color: colors.ink),
                    placeholderStyle: TextStyle(color: colors.secondary),
                    placeholder: '关键词规则，例如 日本+VPS，测评',
                    minLines: 3,
                    maxLines: 6,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '逗号或换行分隔的规则满足任意一组即可；用 + 连接的词必须同时出现在同一帖子的标题或 RSS 摘要里。最多 25 组。',
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 14),
                _label('提示备注（可选）'),
                DeskInputSurface(
                  child: CupertinoTextField(
                    controller: note,
                    decoration: const BoxDecoration(),
                    style: TextStyle(color: colors.ink),
                    placeholderStyle: TextStyle(color: colors.secondary),
                    placeholder: '提示备注（可选）',
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _watchStatus(config),
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '系统通知',
                        style: TextStyle(color: colors.ink, fontSize: 13),
                      ),
                    ),
                    GlassSwitch(
                      value: config['systemNotifications'] == true,
                      semanticLabel: '关键词系统通知',
                      onChanged: (enabled) =>
                          _configure({'systemNotifications': enabled}),
                      quality: GlassQuality.premium,
                    ),
                  ],
                ),
                _notificationAccess(config, colors),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DeskButton(
                    '保存关键词',
                    width: 118,
                    busy: _saving.contains('words'),
                    onTap: _saving.contains('words')
                        ? null
                        : () => _configure({
                            'words': value.text,
                            'note': note.text,
                          }),
                  ),
                ),
                _error(),
              ],
            ),
          ),
          _keywordHits(colors),
        ],
      ),
      'office' => DeskSection(
        quiet: true,
        title: '办公视图与快捷键',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label('工作表标题'),
            DeskInputSurface(
              child: CupertinoTextField(
                controller: value,
                decoration: const BoxDecoration(),
                style: TextStyle(color: colors.ink),
                placeholderStyle: TextStyle(color: colors.secondary),
                placeholder: '伪装窗口标题',
                padding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 14),
            _label('工具栏按钮名称'),
            DeskInputSurface(
              child: CupertinoTextField(
                controller: button,
                decoration: const BoxDecoration(),
                style: TextStyle(color: colors.ink),
                placeholderStyle: TextStyle(color: colors.secondary),
                placeholder: '切换办公视图',
                padding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 14),
            _label('⌘⇧ 快捷键'),
            DeskInputSurface(
              child: CupertinoTextField(
                controller: keyInput,
                decoration: const BoxDecoration(),
                style: TextStyle(color: colors.ink),
                placeholderStyle: TextStyle(color: colors.secondary),
                placeholder: '快捷键字符（配合 ⌘⇧）',
                padding: const EdgeInsets.all(12),
                maxLength: 1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '同时按下 ⌘⇧ 和该字符即可切换工作表。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '建议使用 7、8、9 或 0，避开常用编辑快捷键。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DeskButton(
                  '保存设置',
                  width: 106,
                  busy: _saving.contains('title'),
                  onTap: _saving.contains('title')
                      ? null
                      : () => _configure({
                          'title': value.text,
                          'button': button.text,
                          'key': keyInput.text,
                        }),
                ),
                DeskButton(
                  '切换工作表',
                  width: 118,
                  onTap: !_active
                      ? null
                      : () => widget.state.act('extensions.office', {
                          'presented': true,
                        }, 'extensions'),
                ),
              ],
            ),
            _error(),
          ],
        ),
      ),
      'attendance' => DeskSection(
        quiet: true,
        title: '每日签到',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '自动签到',
                    style: TextStyle(color: colors.ink, fontSize: 13),
                  ),
                ),
                GlassSwitch(
                  value: config['automatic'] == true,
                  semanticLabel: '自动签到',
                  onChanged: (enabled) => _configure({'automatic': enabled}),
                  quality: GlassQuality.premium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            GlassSegmentedControl(
              segments: const [
                GlassSegment(label: '固定签到'),
                GlassSegment(label: '运气签到'),
              ],
              selectedIndex: config['mode'] == 'random' ? 1 : 0,
              onSegmentSelected: (mode) =>
                  _configure({'mode': mode == 0 ? 'fixed' : 'random'}),
              height: 34,
              quality: GlassQuality.premium,
            ),
            const SizedBox(height: 12),
            Text(
              '按北京时间每天 00:00 签到。电脑休眠或应用退出时，恢复运行后会补签当天。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _attendanceResult ??
                  (!widget.state.signedIn
                      ? '登录 NodeSeek 后即可签到。'
                      : !_canAttend
                      ? '账号暂不可执行签到，请刷新或完成站点验证。'
                      : '已登录；今日签到状态以论坛返回结果为准。'),
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DeskButton(
                  '立即签到',
                  width: 112,
                  icon: CupertinoIcons.checkmark,
                  busy: _attendanceBusy,
                  onTap: _attendanceBusy || !_active || !_canAttend
                      ? null
                      : () => _performAttendance(config),
                ),
                if (!widget.state.signedIn || _attendanceKind == 'signedOut')
                  DeskButton(
                    '登录 NodeSeek',
                    width: 140,
                    onTap: () => widget.state.act('session.signIn'),
                  ),
                if (_attendanceKind == 'verification' ||
                    widget.state.signedIn && !_canAttend)
                  DeskButton(
                    '打开 NodeSeek 验证',
                    width: 170,
                    onTap: () => widget.state.act('session.verify', {
                      'url': 'https://www.nodeseek.com/',
                    }),
                  ),
              ],
            ),
            _error(),
          ],
        ),
      ),
      'block' => DeskSection(
        quiet: true,
        title: '已屏蔽用户',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final author in jsonItems(
              widget.state.domain('extensions')['blocked'],
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.well,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.person_crop_circle,
                        size: 24,
                        color: colors.secondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          stringValue(author['name']),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.ink, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DeskButton(
                        '解除屏蔽',
                        width: 106,
                        onTap: () => widget.state.act('extensions.unblock', {
                          'memberId': author['memberId'],
                          'name': author['name'],
                        }, 'extensions'),
                      ),
                    ],
                  ),
                ),
              ),
            if (jsonItems(widget.state.domain('extensions')['blocked']).isEmpty)
              Column(
                children: [
                  Icon(
                    CupertinoIcons.person_crop_circle_badge_xmark,
                    size: 28,
                    color: colors.secondary,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '尚未屏蔽任何用户。',
                    style: TextStyle(color: colors.ink, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '从帖子作者旁添加，屏蔽名单会显示在这里。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      'hot' => DeskSection(
        quiet: true,
        title: '浏览热榜',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '发现社区里正在热议的帖子。',
              style: TextStyle(color: colors.secondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final (title, subtitle) in [
                  ('实时', '当下热议'),
                  ('日榜', '今天热门'),
                  ('周榜', '本周精选'),
                ])
                  Column(
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
                        subtitle,
                        style: DeskTypography.metadata.copyWith(
                          color: colors.secondary,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 18),
            DeskButton(
              '打开热榜',
              width: 116,
              icon: CupertinoIcons.flame,
              onTap: _active ? widget.onOpenRankings : null,
            ),
          ],
        ),
      ),
      'value' => DeskSection(
        quiet: true,
        title: '估价工具',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '启用后，打开任意帖子即可在顶部点「估价」。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 14),
            DeskButton(
              '试算',
              width: 100,
              icon: CupertinoIcons.money_dollar_circle,
              onTap: !_active
                  ? null
                  : () => Navigator.push(
                      context,
                      CupertinoPageRoute<void>(
                        builder: (_) => ValueScreen(state: widget.state),
                      ),
                    ),
            ),
          ],
        ),
      ),
      _ => DeskSection(
        quiet: true,
        title: widget.id == 'authorOnly' ? '阅读筛选' : '公开记录查询',
        child: Text(
          widget.id == 'authorOnly' ? '启用后，帖子内会提供「只看楼主」开关。每篇讨论可按需要切换。' : '在帖子作者旁点「管理记录」，即可查询社区公开记录。NS Seek 社区服务仅接收被查询的公开用户名。结果统一显示为北京时间。',
          style: TextStyle(color: colors.secondary, fontSize: 13, height: 1.7),
        ),
      ),
    };
  }

  String _watchStatus(JsonMap config) {
    final extensions = widget.state.domain('extensions');
    if (!_active) return '监控已关闭';
    if (extensions['watchFailed'] == true) return 'RSS 暂时无法连接，稍后自动重试';
    final terms = config['terms'];
    if (terms is List
        ? terms.isEmpty
        : stringValue(config['words']).trim().isEmpty) {
      return '添加关键词后开始监控';
    }
    final checked = extensions['lastCheck'];
    if (checked is num && checked.isFinite) {
      final time = DateTime.fromMillisecondsSinceEpoch(checked.toInt())
          .toLocal();
      return '最近检查 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    }
    return '正在检查新帖…';
  }

  Widget _keywordHits(DeskColors colors) {
    final domain = widget.state.domain('extensions');
    final hits = jsonItems(domain['hits']);
    final unread = intValue(domain['unread']);
    return DeskSection(
      quiet: true,
      title: '最近命中 ${hits.length} 条',
      subtitle: '保留本次运行期间最近的命中，最多 60 条。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Text(
                '未读 $unread 条',
                style: DeskTypography.metadata.copyWith(
                  color: colors.secondary,
                ),
              ),
              DeskButton(
                '全部标为已读',
                width: 132,
                busy: _acknowledging,
                onTap: _acknowledging || unread == 0 ? null : _acknowledgeHits,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (hits.isEmpty)
            Text(
              '还没有命中。保存规则后，SeekDesk 运行时会在后台检查新帖。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          for (final hit in hits)
            CupertinoButton(
              key: ValueKey('extension-hit-${jsonMap(hit['post'])['id']}'),
              padding: const EdgeInsets.symmetric(vertical: 10),
              onPressed: () =>
                  widget.state.openTopic(TopicData(jsonMap(hit['post']))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stringValue(jsonMap(hit['post'])['title']),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hit['words'] is List
                              ? (hit['words'] as List).join(' · ')
                              : stringValue(hit['words']),
                          style: DeskTypography.metadata.copyWith(
                            color: colors.accent,
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
