import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';

class ProxyScreen extends StatefulWidget {
  const ProxyScreen({required this.state, this.header, this.footer, super.key});
  final AppState state;
  final Widget? header, footer;
  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  final name = TextEditingController(), source = TextEditingController();
  final search = TextEditingController();
  final _editorFocus = FocusScopeNode(debugLabel: 'proxy-editor');
  final _sourceFocus = FocusNode(debugLabel: 'proxy-source');
  final _editorUpdates = ValueNotifier(0);
  final _editorRoutes = <RawDialogRoute<void>, NavigatorState>{};
  bool _disposing = false, _editorResourcesReleased = false;
  RawDialogRoute<void>? _editorRoute;
  NavigatorState? _editorNavigator;
  int mode = 0, generation = 0;
  late int _revision;
  int? _editorRevision, _previewRevision;
  bool importing = false, committing = false, removing = false;
  bool _editorOpen = false,
      _loading = true,
      _loaded = false,
      _connectionBusy = false;
  String? editingID, loadingEditorID, _formError, _loadError;
  JsonMap? preview, _observedProxy, _observedExtensions;

  void _refresh(VoidCallback change) {
    if (!mounted || _disposing) return;
    setState(change);
    _editorUpdates.value++;
  }

  bool get _hasSnapshot =>
      _loaded || jsonItems(widget.state.domain('proxy')['nodes']).isNotEmpty;

  // A fresh extension snapshot can revoke a cached proxy snapshot immediately.
  // A missing availability flag is incomplete data, never permission to mutate.
  // An entirely missing snapshot never becomes an enabled empty state.
  bool get _available {
    if (!_hasSnapshot) return false;
    final proxy = widget.state.domain('proxy');
    if (proxy['available'] != true) return false;
    final extensions = widget.state.domain('extensions');
    if (extensions['items'] is List) {
      final item = jsonItems(extensions['items'])
          .where((item) => item['id'] == 'proxy')
          .firstOrNull;
      if (item == null ||
          item['active'] == false ||
          item['installed'] == false ||
          item['enabled'] == false) {
        return false;
      }
      if (item['active'] != true &&
          !(item['installed'] == true && item['enabled'] == true)) {
        return false;
      }
    }
    return true;
  }

  bool get _canEdit =>
      _available &&
      !committing &&
      !removing &&
      !_editorOpen &&
      _editorRoutes.isEmpty;
  bool get _validEditor =>
      _editorOpen &&
      _editorRevision == widget.state.accessRevision &&
      _available;

  @override
  void initState() {
    super.initState();
    _revision = widget.state.accessRevision;
    _observedProxy = widget.state.domains['proxy'];
    _observedExtensions = widget.state.domains['extensions'];
    widget.state.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  void _changed() {
    if (!mounted) return;
    final nextProxy = widget.state.domains['proxy'];
    final nextExtensions = widget.state.domains['extensions'];
    final revision = widget.state.accessRevision;
    final revisionChanged = revision != _revision;
    if (revisionChanged) {
      _revision = revision;
      if (_editorOpen) {
        _closeEditor(completed: true, clearImmediately: true);
      } else {
        _resetForm();
      }
    } else if (!_available && (_editorOpen || _editorRoutes.isNotEmpty)) {
      // Editing exposes the decrypted link. Revoking the extension closes and
      // clears that view even if no preview/import request is currently active.
      _closeEditor(completed: true, clearImmediately: true);
    }
    if (revisionChanged ||
        !identical(nextProxy, _observedProxy) ||
        !identical(nextExtensions, _observedExtensions) ||
        _editorRevision != null && _editorRevision != revision) {
      _observedProxy = nextProxy;
      _observedExtensions = nextExtensions;
      _refresh(() {});
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    _refresh(() {
      _loading = true;
      _loadError = null;
    });
    final result = await widget.state.act('proxy.get', {}, 'proxy');
    if (!mounted) return;
    _refresh(() {
      _loading = false;
      if (result?['nodes'] is List) _loaded = true;
      if (result == null || result['nodes'] is! List && !_hasSnapshot) {
        _loadError = '未能读取代理信息，请重试。';
      }
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    _disposing = true;
    for (final entry in _editorRoutes.entries.toList()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (entry.value.mounted && entry.key.isActive) {
          entry.value.removeRoute(entry.key);
        }
      });
    }
    // Popped routes may still be reversing. They retain the controllers until
    // their overlay entries are actually removed, not merely until pop returns.
    if (_editorRoutes.isEmpty) _releaseEditorResources();
    generation++;
    unawaited(_discard(preview));
    search.dispose();
    super.dispose();
  }

  void _releaseEditorResources() {
    if (_editorResourcesReleased) return;
    _editorResourcesReleased = true;
    _editorUpdates.dispose();
    name.dispose();
    source.dispose();
    _sourceFocus.dispose();
    _editorFocus.dispose();
  }

  Future<void> _discard(JsonMap? value) async {
    final token = stringValue(value?['importToken']);
    if (token.isEmpty) return;
    try {
      await widget.state.client.call('proxy.discardImport', {
        'importToken': token,
      });
    } catch (_) {
      // Native previews also expire. Cleanup remains safe after route disposal.
    }
  }

  void _invalidate() {
    generation++;
    final previous = preview;
    preview = null;
    _previewRevision = null;
    importing = false;
    loadingEditorID = null;
    _formError = null;
    unawaited(_discard(previous));
  }

  void _inputChanged(String _) => _refresh(_invalidate);

  void _resetForm({int? selectedMode}) {
    _invalidate();
    if (selectedMode != null) mode = selectedMode;
    editingID = null;
    name.clear();
    source.clear();
  }

  void _openEditor() {
    if (!_canEdit) return;
    _refresh(() {
      _resetForm(selectedMode: 0);
      _editorRevision = widget.state.accessRevision;
      _editorOpen = true;
    });
    _presentEditor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editorOpen) _sourceFocus.requestFocus();
    });
  }

  void _presentEditor() {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = RawDialogRoute<void>(
      barrierDismissible: false,
      barrierColor: const Color(0x55000000),
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      pageBuilder: (routeContext, animation, secondaryAnimation) =>
          ValueListenableBuilder<int>(
            valueListenable: _editorUpdates,
            builder: (context, _, child) {
              if (!mounted || _disposing) return const SizedBox.shrink();
              return PopScope(
                canPop: !committing,
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, bounds) => Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: committing ? null : _closeEditor,
                            child: const SizedBox.expand(),
                          ),
                        ),
                        _editor(context, bounds),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
    );
    _editorRoute = route;
    _editorNavigator = navigator;
    _editorRoutes[route] = navigator;
    // Keyword notifications live above the Navigator. Defer their presentation
    // until this route has actually left the overlay, without consuming hits.
    final releaseWatchPopup = widget.state.deferWatchPopup();
    unawaited(
      route.completed.then((_) {
        releaseWatchPopup();
        _editorRoutes.remove(route);
        if (_disposing && _editorRoutes.isEmpty) {
          _releaseEditorResources();
        } else if (mounted && !_disposing) {
          _refresh(() {
            if (_editorRoutes.isEmpty && !_editorOpen) _resetForm();
          });
        }
      }),
    );
    unawaited(
      navigator.push(route).then((_) {
        if (!mounted || !identical(_editorRoute, route)) return;
        _editorRoute = null;
        _editorNavigator = null;
        _retireEditor();
      }),
    );
  }

  void _retireEditor({bool clearImmediately = false}) {
    _refresh(() {
      generation++;
      _editorOpen = false;
      _editorRevision = null;
      _previewRevision = null;
      if (clearImmediately) _resetForm();
    });
  }

  void _closeEditor({bool completed = false, bool clearImmediately = false}) {
    if (committing && !completed) return;
    _sourceFocus.unfocus();
    final route = _editorRoute, navigator = _editorNavigator;
    _editorRoute = null;
    _editorNavigator = null;
    _retireEditor(clearImmediately: clearImmediately);
    if (route != null &&
        navigator != null &&
        navigator.mounted &&
        route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
  }

  Future<void> edit(JsonMap node) async {
    if (!_canEdit) return;
    _openEditor();
    final request = generation, revision = widget.state.accessRevision;
    final id = stringValue(node['id']);
    _refresh(() {
      editingID = id;
      loadingEditorID = id;
    });
    try {
      final result = await widget.state.client.call('proxy.editNode', {
        'id': id,
      });
      if (!mounted ||
          request != generation ||
          revision != widget.state.accessRevision ||
          !_validEditor) {
        return;
      }
      _refresh(() {
        name.text = stringValue(result['name']);
        source.text = stringValue(result['link']);
      });
    } catch (error) {
      if (mounted &&
          request == generation &&
          revision == widget.state.accessRevision) {
        _refresh(() => _formError = error.toString());
      }
    } finally {
      if (mounted && request == generation) {
        _refresh(() => loadingEditorID = null);
      }
    }
  }

  Future<void> identify() async {
    if (!_validEditor ||
        importing ||
        committing ||
        source.text.trim().isEmpty) {
      return;
    }
    _refresh(() {
      _invalidate();
      importing = true;
    });
    final request = generation, revision = widget.state.accessRevision;
    try {
      final result = await widget.state.client.call(
        mode == 0 ? 'proxy.import' : 'proxy.subscribe',
        {
          'name': name.text,
          if (mode == 0) 'text': source.text,
          if (mode == 1) 'url': source.text.trim(),
          'preview': true,
        },
      );
      if (!mounted ||
          request != generation ||
          revision != widget.state.accessRevision ||
          !_validEditor) {
        await _discard(result);
        return;
      }
      _refresh(() {
        preview = result;
        _previewRevision = revision;
      });
    } catch (error) {
      if (mounted &&
          request == generation &&
          revision == widget.state.accessRevision) {
        _refresh(() => _formError = error.toString());
      }
    } finally {
      if (mounted && request == generation) _refresh(() => importing = false);
    }
  }

  Future<void> commit() async {
    if (!_validEditor ||
        committing ||
        preview == null ||
        _previewRevision != widget.state.accessRevision) {
      return;
    }
    _refresh(() {
      committing = true;
      _formError = null;
    });
    try {
      final result = await widget.state.act(
        preview!['subscription'] == true ? 'proxy.subscribe' : 'proxy.import',
        {'importToken': preview!['importToken'], 'name': name.text},
        'proxy',
      );
      if (!mounted) return;
      if (result != null) {
        _closeEditor(completed: true);
      } else {
        _refresh(() => _formError = '导入未完成，请检查节点或订阅后重试。');
      }
    } finally {
      if (mounted) _refresh(() => committing = false);
    }
  }

  Future<void> saveEdit() async {
    if (!_validEditor ||
        committing ||
        editingID == null ||
        loadingEditorID != null ||
        source.text.trim().isEmpty) {
      return;
    }
    _refresh(() {
      committing = true;
      _formError = null;
    });
    try {
      final result = await widget.state.act('proxy.import', {
        'replacingId': editingID,
        'name': name.text,
        'text': source.text,
      }, 'proxy');
      if (!mounted) return;
      if (result != null) {
        _closeEditor(completed: true);
      } else {
        _refresh(() => _formError = '节点未保存，请检查链接后重试。');
      }
    } finally {
      if (mounted) _refresh(() => committing = false);
    }
  }

  Future<void> remove(JsonMap item, {bool subscription = false}) async {
    final id = stringValue(item['id']);
    if (!mounted || !_canEdit || id.isEmpty) return;
    final revision = widget.state.accessRevision;
    _refresh(() => removing = true);
    try {
      final confirmed = await confirmAction(
        context,
        title: subscription ? '删除订阅' : '删除节点',
        message: subscription
            ? '将同时删除该订阅下的节点，其他节点和订阅会保留。'
            : '确定删除“${item['name']}”？',
        accept: '删除',
        destructive: true,
      );
      if (!confirmed ||
          !mounted ||
          !_available ||
          revision != widget.state.accessRevision) {
        return;
      }
      await widget.state.act(
        subscription ? 'proxy.removeSubscription' : 'proxy.remove',
        {'id': id},
        'proxy',
      );
    } finally {
      if (mounted) _refresh(() => removing = false);
    }
  }

  Future<void> _act(String method, [JsonMap args = const {}]) async {
    if (!mounted || !_available && method != 'proxy.stop') return;
    await widget.state.act(method, args, 'proxy');
  }

  Future<void> _connect(bool enabled) async {
    if (!_available && enabled || _connectionBusy) return;
    _refresh(() => _connectionBusy = true);
    try {
      await _act(enabled ? 'proxy.start' : 'proxy.stop');
    } finally {
      if (mounted) _refresh(() => _connectionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proxy = widget.state.domain('proxy');
    final nodes = jsonItems(proxy['nodes']);
    final subscriptions = jsonItems(proxy['subscriptions']);
    final query = search.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? nodes
        : nodes
              .where(
                (node) =>
                    '${node['name']} ${node['host']} ${node['protocolName']}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
    return LayoutBuilder(
      builder: (context, bounds) {
        const leftInset = 24.0;
        final rightInset = math.max(24.0, bounds.maxWidth - leftInset - 960);
        return Stack(
          children: [
            ExcludeFocus(
              excluding: _editorOpen,
              child: ExcludeSemantics(
                excluding: _editorOpen,
                child: CustomScrollView(
                  key: const PageStorageKey('proxy-scroll'),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        leftInset,
                        widget.header == null ? 20 : 8,
                        rightInset,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.header != null) widget.header!,
                            if (_loadError != null) _loadFailure(),
                            _connection(proxy, nodes),
                            if (subscriptions.isNotEmpty)
                              _subscriptions(subscriptions),
                            if (stringValue(proxy['importMessage']).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: _detail(
                                  stringValue(proxy['importMessage']),
                                ),
                              ),
                            _nodeHeader(nodes.length),
                            if (!_hasSnapshot)
                              _empty(_loading ? '正在读取节点…' : '节点信息暂不可用')
                            else if (nodes.isEmpty)
                              _empty('还没有节点', detail: '添加订阅，或粘贴节点分享链接。')
                            else if (filtered.isEmpty)
                              _empty('没有匹配的节点', detail: '试试其他名称、服务器或协议。'),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.only(
                        left: leftInset,
                        right: rightInset,
                      ),
                      sliver: SliverList.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) =>
                            _node(filtered[index], proxy, subscriptions),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        leftInset,
                        18,
                        rightInset,
                        24,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _preferences(proxy),
                            _coreInfo(proxy),
                            if (widget.footer != null) ...[
                              const SizedBox(height: 20),
                              widget.footer!,
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _loadFailure() => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(child: _detail(_loadError!)),
        const SizedBox(width: 10),
        DeskButton(
          '重新读取',
          width: 96,
          busy: _loading,
          onTap: _loading ? null : _load,
        ),
      ],
    ),
  );

  Widget _detail(String text, {bool error = false, BuildContext? owner}) =>
      Text(
        text,
        style: TextStyle(
          color: error
              ? CupertinoColors.systemRed
              : DeskColors(owner ?? context).secondary,
          fontSize: 12,
          height: 1.5,
        ),
      );

  Widget _empty(String title, {String? detail}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: DeskColors(context).ink, fontSize: 14),
        ),
        if (detail != null) ...[const SizedBox(height: 6), _detail(detail)],
      ],
    ),
  );

  Widget _connection(JsonMap proxy, List<JsonMap> nodes) {
    final colors = DeskColors(context), enabled = proxy['enabled'] == true;
    final starting = proxy['starting'] == true,
        running = proxy['running'] == true;
    final selected = nodes
        .where((node) => node['id'] == proxy['selectedId'])
        .firstOrNull;
    final title = !_hasSnapshot
        ? (_loading ? '正在读取代理状态' : '代理状态暂不可用')
        : !_available
        ? '扩展已停用'
        : !enabled
        ? '代理未开启'
        : starting
        ? '正在连接'
        : running
        ? '代理已就绪'
        : '连接未建立';
    return DeskSection(
      title: '连接状态',
      quiet: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colors.selection,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: starting && _available
                    ? const CupertinoActivityIndicator(radius: 9)
                    : Icon(
                        running && _available
                            ? CupertinoIcons.checkmark_shield
                            : CupertinoIcons.globe,
                        color: colors.accent,
                        size: 22,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _detail(
                      !_hasSnapshot
                          ? '正在读取已保存的节点与连接状态。'
                          : !_available
                          ? '启用扩展后，可以连接和管理节点。'
                          : '仅用于 SeekDesk 的网络请求。',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _ProxySwitch(
                label: '开启专用代理',
                value: enabled,
                onChanged:
                    !_connectionBusy &&
                        (enabled || _available && nodes.isNotEmpty)
                    ? _connect
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.hover,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detail('当前节点'),
                const SizedBox(height: 4),
                Text(
                  selected == null ? '尚未选择节点' : stringValue(selected['name']),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (enabled &&
              !running &&
              !starting &&
              stringValue(proxy['status']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _detail(stringValue(proxy['status'])),
            ),
          if (stringValue(proxy['issue']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _detail(stringValue(proxy['issue']), error: true),
            ),
          if (enabled) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DeskButton(
                  '检测连接',
                  icon: CupertinoIcons.checkmark_shield,
                  width: 114,
                  busy: proxy['checking'] == true,
                  onTap: _available && running && proxy['checking'] != true
                      ? () => _act('proxy.check')
                      : null,
                ),
                DeskButton(
                  '重新连接',
                  icon: CupertinoIcons.arrow_clockwise,
                  width: 114,
                  onTap: _available && !starting && !_connectionBusy
                      ? () => _act('proxy.reconnect')
                      : null,
                ),
              ],
            ),
          ],
          if (stringValue(proxy['checkResult']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _detail(stringValue(proxy['checkResult'])),
            ),
        ],
      ),
    );
  }

  Widget _nodeHeader(int count) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
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
              '我的节点${_hasSnapshot ? ' · $count' : ''}',
              style: DeskTypography.section.copyWith(
                color: DeskColors(context).ink,
              ),
            ),
            DeskButton(
              '添加节点 / 订阅',
              icon: CupertinoIcons.add,
              width: 148,
              onTap: _canEdit ? _openEditor : null,
            ),
          ],
        ),
        if (count > 8 || search.text.isNotEmpty) ...[
          const SizedBox(height: 12),
          CupertinoSearchTextField(
            controller: search,
            placeholder: '搜索名称、服务器或协议',
            onChanged: (_) => _refresh(() {}),
            style: TextStyle(color: DeskColors(context).ink, fontSize: 13),
          ),
        ],
      ],
    ),
  );

  Widget _subscriptions(List<JsonMap> items) => DeskSection(
    title: '我的订阅 · ${items.length}',
    quiet: true,
    child: Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stringValue(item['name']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: DeskColors(context).ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _detail(
                        '${intValue(item['nodeCount'])} 个节点 · ${_updatedAt(item['updatedAt'])}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DeskIcon(
                  '更新订阅',
                  CupertinoIcons.arrow_clockwise,
                  _available && item['updating'] != true
                      ? () =>
                            _act('proxy.updateSubscription', {'id': item['id']})
                      : null,
                  busy: item['updating'] == true,
                ),
                const SizedBox(width: 6),
                DeskIcon(
                  '删除订阅',
                  CupertinoIcons.trash,
                  _canEdit ? () => remove(item, subscription: true) : null,
                ),
              ],
            ),
          ),
      ],
    ),
  );

  String _updatedAt(Object? value) {
    final milliseconds = intValue(value);
    if (milliseconds <= 0) return '尚未更新';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '更新于 ${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Widget _node(JsonMap node, JsonMap proxy, List<JsonMap> subscriptions) {
    final colors = DeskColors(context), latency = jsonMap(node['latency']);
    final selected = node['id'] == proxy['selectedId'];
    final id = stringValue(node['id']);
    final subscriptionID = stringValue(node['subscriptionId']);
    final subscription = subscriptions
        .where((item) => item['id'] == subscriptionID)
        .firstOrNull;
    final origin = subscriptionID.isEmpty
        ? '手动添加'
        : stringValue(subscription?['name'], '订阅节点');
    final host = '${node['host']}:${node['port']}';
    final latencyLabel = switch (latency['state']) {
      'success' => '${numberValue(latency['milliseconds']).round()} ms',
      'failed' => '无法连接',
      'measuring' => '检测中',
      _ => '未检测',
    };
    return Padding(
      key: ValueKey('proxy-node-$id'),
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? colors.selection : colors.hover,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.accent.withValues(alpha: .3) : colors.line,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  key: ValueKey('proxy-select-$id'),
                  button: true,
                  selected: selected,
                  enabled: _available,
                  label:
                      '${stringValue(node['name'])}，${node['protocolName']}，$host，$origin',
                  onTap: _available ? () => _select(node) : null,
                  excludeSemantics: true,
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    onPressed: _available ? () => _select(node) : null,
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          color: selected ? colors.accent : colors.secondary,
                          size: 18,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                stringValue(node['name']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colors.hover,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      stringValue(node['protocolName']),
                                      style: TextStyle(
                                        color: colors.secondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    origin,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colors.secondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.secondary,
                                  fontSize: 11,
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
              const SizedBox(width: 5),
              SizedBox(
                width: 68,
                child: Column(
                  children: [
                    DeskIcon(
                      '检测节点延迟',
                      CupertinoIcons.bolt_fill,
                      _available &&
                              latency['state'] != 'measuring' &&
                              proxy['canMeasureMoreNodes'] != false
                          ? () => _act('proxy.probe', {'id': id})
                          : null,
                      busy: latency['state'] == 'measuring',
                    ),
                    const SizedBox(height: 3),
                    Text(
                      latencyLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: latency['state'] == 'failed'
                            ? CupertinoColors.systemRed
                            : colors.secondary,
                        fontSize: 10,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              GlassMenu(
                key: ValueKey('proxy-node-menu-$id'),
                menuSemanticLabel: '${stringValue(node['name'])}的操作',
                quality: GlassQuality.premium,
                autoAdjustToScreen: true,
                menuWidth: 190,
                menuBorderRadius: 14,
                itemBorderRadius: 9,
                triggerBuilder: (context, toggle) => DeskIcon(
                  '节点更多操作',
                  CupertinoIcons.ellipsis,
                  _canEdit ? toggle : null,
                ),
                items: [
                  GlassMenuItem(
                    title: '编辑节点',
                    icon: const Icon(CupertinoIcons.pencil, size: 16),
                    enabled: _canEdit,
                    onTap: () => edit(node),
                  ),
                  GlassMenuItem(
                    title: '删除节点',
                    icon: const Icon(CupertinoIcons.trash, size: 16),
                    enabled: _canEdit,
                    isDestructive: true,
                    onTap: () => remove(node),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _select(JsonMap node) {
    if (!_available ||
        node['id'] == widget.state.domain('proxy')['selectedId']) {
      return;
    }
    unawaited(_act('proxy.select', {'id': node['id']}));
  }

  Widget _preferences(JsonMap proxy) => DeskSection(
    title: '连接偏好',
    quiet: true,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '启动时自动连接',
                style: TextStyle(color: DeskColors(context).ink, fontSize: 13),
              ),
              const SizedBox(height: 4),
              _detail('打开 SeekDesk 时使用已选择的节点。'),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _ProxySwitch(
          label: '启动时自动连接代理',
          value: proxy['startWithApp'] == true,
          onChanged: _available
              ? (value) => _act('proxy.configure', {'startWithApp': value})
              : null,
        ),
      ],
    ),
  );

  Widget _coreInfo(JsonMap proxy) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            _detail('Xray-core 26.11.9 · MPL-2.0'),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => widget.state.act('external.open', {
                'url': 'https://github.com/XTLS/Xray-core/tree/v26.11.9',
              }),
              child: Text(
                '内核与源代码',
                style: TextStyle(
                  color: DeskColors(context).accent,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        if (proxy['supportedProtocols'] is List)
          _detail(
            (proxy['supportedProtocols'] as List).join(' · ').toUpperCase(),
          ),
      ],
    ),
  );

  Widget _editor(BuildContext routeContext, BoxConstraints bounds) {
    final colors = DeskColors(routeContext);
    final textScale = math.max(
      1.0,
      MediaQuery.textScalerOf(routeContext).scale(14) / 14,
    );
    final preferredHeight =
        (preview != null
                ? 610.0
                : editingID == null
                ? 390.0
                : 350.0) *
            textScale +
        (_formError == null ? 0 : 64);
    final fieldDecoration = BoxDecoration(
      color: colors.well.withValues(alpha: .8),
      border: Border.all(color: colors.line),
      borderRadius: BorderRadius.circular(10),
    );
    Widget detail(String text, {bool error = false}) =>
        _detail(text, error: error, owner: routeContext);
    final editable = _validEditor && !committing && loadingEditorID == null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: SizedBox(
          width: math.min(640.0, math.max(0.0, bounds.maxWidth - 32)),
          height: math.min(
            preferredHeight,
            math.max(0.0, bounds.maxHeight - 32),
          ),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              label: editingID == null ? '添加节点或订阅' : '编辑节点',
              explicitChildNodes: true,
              child: FocusScope(
                node: _editorFocus,
                autofocus: true,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape &&
                      !(source.value.composing.isValid &&
                          !source.value.composing.isCollapsed) &&
                      !(name.value.composing.isValid &&
                          !name.value.composing.isCollapsed)) {
                    if (!committing) _closeEditor();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: DeskGlassPanel(
                  level: GlassLevel.overlay,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              editingID == null ? '添加节点 / 订阅' : '编辑节点',
                              style: DeskTypography.section.copyWith(
                                color: colors.ink,
                              ),
                            ),
                          ),
                          DeskIcon(
                            '关闭节点编辑器',
                            CupertinoIcons.xmark,
                            committing ? null : _closeEditor,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!_available) ...[
                                detail('扩展已停用。重新启用后可继续编辑。'),
                                const SizedBox(height: 12),
                              ],
                              if (loadingEditorID != null) ...[
                                const Row(
                                  children: [
                                    CupertinoActivityIndicator(radius: 8),
                                    SizedBox(width: 8),
                                    Text('正在读取节点…'),
                                  ],
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (editingID == null) ...[
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: 220,
                                    height: 34,
                                    child: _DisabledControls(
                                      disabled: !editable,
                                      child: GlassSegmentedControl(
                                        segments: const [
                                          GlassSegment(label: '节点链接'),
                                          GlassSegment(label: '订阅链接'),
                                        ],
                                        selectedIndex: mode,
                                        quality: GlassQuality.premium,
                                        onSegmentSelected: (value) {
                                          if (editable && value != mode) {
                                            _refresh(
                                              () => _resetForm(
                                                selectedMode: value,
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              Text(
                                mode == 0 ? '节点分享链接' : '订阅地址',
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 7),
                              CupertinoTextField(
                                key: const ValueKey('proxy-source'),
                                controller: source,
                                focusNode: _sourceFocus,
                                decoration: fieldDecoration,
                                enabled: editable,
                                onChanged: _inputChanged,
                                placeholder: mode == 0
                                    ? 'vless://、vmess://、ss:// 等，可批量粘贴'
                                    : 'https://…',
                                placeholderStyle: TextStyle(
                                  color: colors.secondary,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                                minLines: 2,
                                maxLines: 3,
                                obscureText: false,
                                autocorrect: false,
                                enableSuggestions: false,
                                smartDashesType: SmartDashesType.disabled,
                                smartQuotesType: SmartQuotesType.disabled,
                                padding: const EdgeInsets.all(10),
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                '名称（可选）',
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 7),
                              CupertinoTextField(
                                key: const ValueKey('proxy-name'),
                                controller: name,
                                decoration: fieldDecoration,
                                enabled: editable,
                                onChanged: _inputChanged,
                                placeholder: mode == 0
                                    ? '为节点起一个容易辨认的名字'
                                    : '订阅名称',
                                placeholderStyle: TextStyle(
                                  color: colors.secondary,
                                  fontSize: 13,
                                ),
                                maxLength: 100,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 9,
                                ),
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 13,
                                ),
                              ),
                              if (_formError != null) ...[
                                const SizedBox(height: 12),
                                detail(_formError!, error: true),
                              ],
                              if (preview != null) ...[
                                const SizedBox(height: 16),
                                _preview(routeContext),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          DeskButton(
                            editingID == null ? '取消' : '取消编辑',
                            width: 90,
                            onTap: committing ? null : _closeEditor,
                          ),
                          DeskButton(
                            preview != null
                                ? '确认导入'
                                : editingID == null
                                ? '识别并预览'
                                : '保存节点',
                            icon: preview != null || editingID != null
                                ? CupertinoIcons.checkmark
                                : CupertinoIcons.arrow_down_doc,
                            width: 128,
                            busy: importing || committing,
                            onTap: !editable || source.text.trim().isEmpty
                                ? null
                                : preview != null
                                ? commit
                                : editingID == null
                                ? identify
                                : saveEdit,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext routeContext) {
    Widget detail(String text) => _detail(text, owner: routeContext);
    final nodes = jsonItems(preview!['nodes']);
    final skipped = preview!['skipped'] is List
        ? preview!['skipped'] as List
        : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stringValue(preview!['summary'], '识别 ${nodes.length} 个节点'),
          style: TextStyle(
            color: DeskColors(routeContext).ink,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        for (final node in nodes.take(4))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: detail('${node['name']} · ${node['protocolName']}'),
          ),
        if (nodes.length > 4) detail('另有 ${nodes.length - 4} 个节点'),
        if (intValue(preview!['duplicates']) > 0)
          detail('已合并 ${intValue(preview!['duplicates'])} 个重复节点'),
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 8),
          detail('跳过 ${skipped.length} 项'),
          for (final reason in skipped.take(4)) detail('$reason'),
          if (skipped.length > 4) detail('另有 ${skipped.length - 4} 项未能识别'),
        ],
      ],
    );
  }
}

/// GlassSwitch requires a callback even when disabled. Own its public semantics
/// and block keyboard focus as well as pointer input; stale callbacks are guarded
/// again by the screen before invoking the native bridge.
class _ProxySwitch extends StatelessWidget {
  const _ProxySwitch({
    required this.label,
    required this.value,
    this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    toggled: value,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    excludeSemantics: true,
    child: _DisabledControls(
      disabled: onChanged == null,
      child: GlassSwitch(
        value: value,
        onChanged: (value) => onChanged?.call(value),
        quality: GlassQuality.premium,
        useOwnLayer: true,
        semanticLabel: label,
      ),
    ),
  );
}

class _DisabledControls extends StatelessWidget {
  const _DisabledControls({required this.disabled, required this.child});
  final bool disabled;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final content = ExcludeFocus(
      excluding: disabled,
      child: IgnorePointer(
        ignoring: disabled,
        child: ExcludeSemantics(excluding: disabled, child: child),
      ),
    );
    // Opacity is only introduced on disabled controls: active glass continues
    // sampling its actual backdrop rather than an intermediate opacity layer.
    return disabled ? Opacity(opacity: .45, child: content) : content;
  }
}
