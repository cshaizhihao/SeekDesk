import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/composer_sticker_selection.dart';
import '../core/native_client.dart';
import '../core/official_stickers.dart';
import '../state/app_state.dart';
import 'draft_sticker_image.dart';
import 'glass_chrome.dart';
import 'desk_input_surface.dart';

/// One modal owns its local library requests and thumbnail cache. The editor
/// receives only a selection; importing or removing never changes its text.
class ComposerStickerPicker extends StatefulWidget {
  const ComposerStickerPicker({
    required this.state,
    required this.packs,
    super.key,
  });

  final AppState state;
  final List<JsonMap> packs;

  @override
  State<ComposerStickerPicker> createState() => _ComposerStickerPickerState();
}

class _ComposerStickerPickerState extends State<ComposerStickerPicker> {
  final _name = TextEditingController();
  late final int _revision;
  late final _PickerRequests _requests;
  late final _ThumbnailCache _thumbnails;
  late final List<_StickerGroup> _official;
  List<_StickerGroup> _custom = const [];
  String? _selected, _feedback;
  bool _loading = true, _loadFailed = false, _busy = false;
  bool _naming = false, _invalidated = false;
  int _generation = 0;

  bool get _current =>
      mounted && !_invalidated && _revision == widget.state.accessRevision;
  bool get _enabled => _current && !_busy;
  _StickerGroup? get _group {
    for (final group in [..._official, ..._custom]) {
      if (group.key == _selected) return group;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _revision = widget.state.accessRevision;
    _requests = _PickerRequests(widget.state.client, _revision);
    _thumbnails = _ThumbnailCache(_requests);
    _official = _officialGroups(widget.packs);
    _selected = _official.firstOrNull?.key;
    widget.state.addListener(_accessChanged);
    unawaited(_load());
  }

  void _accessChanged() {
    if (!mounted || _invalidated || _revision == widget.state.accessRevision) {
      return;
    }
    _requests.dispose();
    _thumbnails.dispose();
    _name.clear();
    setState(() {
      _invalidated = true;
      _generation++;
      _busy = false;
      _loading = false;
      _naming = false;
      _custom = const [];
      _feedback = '账号已变更，请关闭后重新打开表情。';
    });
  }

  bool _valid(int generation) {
    if (!_current) {
      _accessChanged();
      return false;
    }
    return generation == _generation;
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final result = await _requests.call('stickers.custom.list');
      if (!_valid(generation)) return;
      final groups = _customGroups(result);
      setState(() => _acceptGroups(groups));
    } catch (_) {
      if (_valid(generation)) setState(() => _loadFailed = true);
    } finally {
      if (_valid(generation)) setState(() => _loading = false);
    }
  }

  void _acceptGroups(List<_StickerGroup> groups, {String? select}) {
    _custom = groups;
    _thumbnails.retain(groups);
    if (select != null) _selected = 'custom:$select';
    if (_group == null) {
      _selected = _official.firstOrNull?.key ?? _custom.firstOrNull?.key;
    }
  }

  Future<void> _mutate(
    String method,
    JsonMap arguments, {
    bool create = false,
    bool importing = false,
  }) async {
    if (!_enabled || _loading || _loadFailed) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _feedback = importing ? '正在导入图片…' : null;
    });
    try {
      final result = await _requests.call(method, arguments);
      if (!_valid(generation)) return;
      if (result['cancelled'] == true) {
        setState(() => _feedback = null);
        return;
      }
      final groups = _customGroups(result);
      final createdID = create ? result['groupID'] : null;
      if (create && (createdID is! String || createdID.isEmpty)) {
        throw const FormatException('Missing group identity');
      }
      setState(() {
        _acceptGroups(groups, select: createdID as String?);
        if (create) {
          _name.clear();
          _naming = false;
        }
        if (importing) {
          final imported = intValue(result['importedCount']);
          final skipped = intValue(result['skippedCount']);
          _feedback = skipped > 0
              ? '已导入 $imported 张，跳过 $skipped 张无法读取或过大的图片。'
              : '已导入 $imported 张图片。';
        }
      });
    } catch (error) {
      if (!_valid(generation)) return;
      setState(() => _feedback = _failureMessage(error));
    } finally {
      if (_valid(generation)) setState(() => _busy = false);
    }
  }

  void _create() {
    if (!_enabled) return;
    final name = _name.text.trim();
    if (name.isEmpty || name.characters.length > 40) {
      setState(() => _feedback = '分组名需要 1 到 40 个字符。');
      return;
    }
    if (_custom.any(
      (group) => group.name.toLowerCase() == name.toLowerCase(),
    )) {
      setState(() => _feedback = '已经有同名分组。');
      return;
    }
    unawaited(_mutate('stickers.custom.create', {'name': name}, create: true));
  }

  void _select(_StickerGroup group) {
    if (!_enabled) return;
    setState(() {
      _selected = group.key;
      _feedback = null;
    });
  }

  void _pick(_StickerGroup group, _StickerItem item) {
    if (!_enabled || _group?.key != group.key) return;
    Navigator.pop<ComposerStickerSelection>(
      context,
      group.official
          ? OfficialStickerSelection(item.insertion!)
          : CustomStickerSelection(groupID: group.id, itemID: item.id),
    );
  }

  void _close() {
    if (!_busy && mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.state.removeListener(_accessChanged);
    _requests.dispose();
    _thumbnails.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final group = _group;
    return PopScope(
      canPop: !_busy,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: LayoutBuilder(
              builder: (context, bounds) => Center(
                child: SizedBox(
                  key: const ValueKey('composer-sticker-panel'),
                  width: math.min(540, bounds.maxWidth),
                  height: math.min(580, bounds.maxHeight),
                  child: DeskGlassPanel(
                    level: GlassLevel.overlay,
                    padding: const EdgeInsets.all(12),
                    child: DefaultTextStyle(
                      style: TextStyle(color: colors.ink, fontSize: 12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '表情',
                                  style: TextStyle(
                                    color: colors.ink,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              DeskButton(
                                '新建分组',
                                icon: CupertinoIcons.folder_badge_plus,
                                width: 106,
                                height: 32,
                                onTap: _enabled && !_loading && !_loadFailed
                                    ? () => setState(() {
                                        _naming = !_naming;
                                        _feedback = null;
                                      })
                                    : null,
                              ),
                              const SizedBox(width: 6),
                              DeskIcon(
                                '关闭表情',
                                CupertinoIcons.xmark,
                                _busy ? null : _close,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: CustomScrollView(
                              key: const ValueKey('composer-sticker-scroll'),
                              slivers: [
                                SliverToBoxAdapter(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_official.isNotEmpty ||
                                          _custom.isNotEmpty)
                                        _groupStrip([..._official, ..._custom]),
                                      if (_loading)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: 10,
                                          ),
                                          child: Row(
                                            children: [
                                              CupertinoActivityIndicator(
                                                radius: 7,
                                              ),
                                              SizedBox(width: 8),
                                              Text('正在读取自定义表情…'),
                                            ],
                                          ),
                                        ),
                                      if (_loadFailed && !_invalidated)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              const Expanded(
                                                child: Text('自定义表情暂不可用。'),
                                              ),
                                              DeskButton(
                                                '重试',
                                                width: 60,
                                                height: 30,
                                                onTap: _enabled ? _load : null,
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (_naming) ...[
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: DeskInputSurface(
                                                radius: 8,
                                                child: CupertinoTextField(
                                                  key: const ValueKey(
                                                    'sticker-group-name',
                                                  ),
                                                  controller: _name,
                                                  decoration:
                                                      const BoxDecoration(),
                                                  placeholder: '分组名称',
                                                  placeholderStyle: TextStyle(
                                                    color: colors.secondary,
                                                  ),
                                                  enabled: _enabled,
                                                  maxLength: 40,
                                                  style: TextStyle(
                                                    color: colors.ink,
                                                    fontSize: 13,
                                                  ),
                                                  onSubmitted: (_) => _create(),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            DeskButton(
                                              '创建',
                                              width: 62,
                                              height: 32,
                                              onTap: _enabled ? _create : null,
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (group != null && !group.official) ...[
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 6,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            DeskButton(
                                              '导入图片…',
                                              icon: CupertinoIcons
                                                  .photo_on_rectangle,
                                              width: 112,
                                              height: 32,
                                              busy: _busy,
                                              onTap: _enabled
                                                  ? () => _mutate(
                                                      'system.importStickers',
                                                      {'groupID': group.id},
                                                      importing: true,
                                                    )
                                                  : null,
                                            ),
                                            Text(
                                              '插入时上传到 NodeImage',
                                              style: TextStyle(
                                                color: colors.secondary,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (_feedback != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: Semantics(
                                            liveRegion: true,
                                            child: Text(
                                              _feedback!,
                                              style: TextStyle(
                                                color: colors.secondary,
                                                height: 1.4,
                                              ),
                                            ),
                                          ),
                                        ),
                                      const SizedBox(height: 12),
                                      if (group == null || group.items.isEmpty)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 24,
                                          ),
                                          child: Text(
                                            group != null && !group.official
                                                ? '还没有表情，导入几张喜欢的图片吧。'
                                                : '选择一个表情分组。',
                                            style: TextStyle(
                                              color: colors.secondary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (group != null)
                                  SliverGrid.builder(
                                    key: ValueKey(group.key),
                                    gridDelegate:
                                        SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 78,
                                          mainAxisExtent: group.official
                                              ? 68
                                              : 94,
                                          crossAxisSpacing: 6,
                                          mainAxisSpacing: 6,
                                        ),
                                    itemCount: group.items.length,
                                    itemBuilder: (context, index) =>
                                        _tile(group, group.items[index]),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupStrip(List<_StickerGroup> groups) {
    final index = groups.indexWhere((group) => group.key == _selected);
    return IgnorePointer(
      ignoring: !_enabled,
      child: ExcludeFocus(
        excluding: !_enabled,
        child: GlassSegmentedControl.scrollable(
          segments: [
            for (final group in groups) GlassSegment(label: group.name),
          ],
          selectedIndex: index < 0 ? 0 : index,
          onSegmentSelected: (index) => _select(groups[index]),
          height: 32,
          quality: GlassQuality.premium,
          selectedTextStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          unselectedTextStyle: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _tile(_StickerGroup group, _StickerItem item) {
    final colors = DeskColors(context);
    return Column(
      children: [
        Expanded(
          child: Tooltip(
            message: item.label,
            child: CupertinoButton(
              key: ValueKey(
                group.official
                    ? 'official-sticker-${item.id}'
                    : 'custom-sticker-${group.id}-${item.id}',
              ),
              padding: const EdgeInsets.all(5),
              onPressed: _enabled ? () => _pick(group, item) : null,
              child: Semantics(
                label: item.label,
                button: true,
                child: group.official
                    ? IgnorePointer(
                        child: DraftStickerImageScope(
                          accessRevision: _revision,
                          active: _current,
                          child: DraftStickerImage(
                            state: widget.state,
                            url: item.url!,
                            label: item.label,
                            code: item.id,
                            size: 48,
                          ),
                        ),
                      )
                    : _LocalThumbnail(
                        key: ValueKey((group.id, item.id)),
                        cache: _thumbnails,
                        groupID: group.id,
                        itemID: item.id,
                        enabled: _enabled,
                      ),
              ),
            ),
          ),
        ),
        if (!group.official)
          SizedBox(
            height: 26,
            child: CupertinoButton(
              key: ValueKey('remove-sticker-${group.id}-${item.id}'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(40, 26),
              onPressed: _enabled
                  ? () => _mutate('stickers.custom.remove', {
                      'groupID': group.id,
                      'itemID': item.id,
                    })
                  : null,
              child: Text(
                '移除',
                style: TextStyle(color: colors.secondary, fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }
}

String _failureMessage(Object error) =>
    switch (error is NativeFailure ? error.code : null) {
      'sticker_name' => '分组名需要 1 到 40 个字符。',
      'sticker_duplicate' => '已经有同名分组。',
      'sticker_missing' => '表情或分组已移除，请关闭后重新打开。',
      'sticker_invalid' => '无法读取这张表情，请重新导入图片。',
      _ => '操作未完成，请重试。',
    };

class _StickerGroup {
  const _StickerGroup(this.id, this.name, this.items, {this.official = false});
  final String id, name;
  final List<_StickerItem> items;
  final bool official;
  String get key => '${official ? 'official' : 'custom'}:$id';
}

class _StickerItem {
  const _StickerItem(this.id, this.label, {this.url, this.insertion});
  final String id, label;
  final String? url, insertion;
}

List<_StickerGroup> _officialGroups(List<JsonMap> packs) {
  final catalog = OfficialStickerCatalog.fromPacks(packs);
  final seen = <String>{};
  return [
    for (final pack in packs)
      if (pack['id'] is String && seen.add(pack['id'] as String))
        _StickerGroup(pack['id'] as String, stringValue(pack['title']), [
          for (final item in jsonItems(pack['items']))
            if (catalog.byCode[item['id']] case final sticker?)
              _StickerItem(
                sticker.code,
                sticker.label,
                url: sticker.url,
                insertion: sticker.insertion,
              ),
        ], official: true),
  ];
}

List<_StickerGroup> _customGroups(JsonMap value) {
  if (value['groups'] is! List) throw const FormatException('Missing groups');
  final seen = <String>{};
  return [
    for (final group in jsonItems(value['groups']))
      if (group['id'] is String &&
          (group['id'] as String).isNotEmpty &&
          group['name'] is String &&
          seen.add(group['id'] as String))
        _StickerGroup(
          group['id'] as String,
          group['name'] as String,
          _customItems(group),
        ),
  ];
}

List<_StickerItem> _customItems(JsonMap group) {
  final seen = <String>{};
  return [
    for (final item in jsonItems(group['items']))
      if (item['id'] is String &&
          (item['id'] as String).isNotEmpty &&
          item['label'] is String &&
          seen.add(item['id'] as String))
        _StickerItem(item['id'] as String, item['label'] as String),
  ];
}

class _PickerRequests {
  _PickerRequests(this.client, this.revision);
  final NativeClient client;
  final int revision;
  static int _serial = 0;
  static final String _session = DateTime.now().microsecondsSinceEpoch
      .toRadixString(36);
  final Set<String> _active = {};
  bool _disposed = false;

  bool get current => !_disposed && client.accessRevision == revision;
  String nextID() => 'sticker-$_session-${++_serial}';

  Future<JsonMap> call(
    String method, [
    JsonMap args = const {},
    String? requestID,
  ]) async {
    if (!current) throw const NativeFailure('stale', '表情面板已关闭。');
    final id = requestID ?? nextID();
    _active.add(id);
    try {
      final result = await client.call(method, {...args, 'requestId': id});
      if (!current || !_active.contains(id)) {
        throw const NativeFailure('stale', '表情面板已关闭。');
      }
      return result;
    } finally {
      _active.remove(id);
    }
  }

  void cancel(String id) {
    if (!_active.remove(id)) return;
    unawaited(() async {
      try {
        await client.call('request.cancel', {'requestId': id});
      } catch (_) {
        // Local resource cleanup never produces late UI feedback.
      }
    }());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final id in _active.toList()) {
      cancel(id);
    }
  }
}

class _ThumbnailRequest {
  _ThumbnailRequest(this.id);
  final String id;
  final Completer<Uint8List> result = Completer<Uint8List>();
  int size = 0;
}

/// The modal retains at most 48 thumbnail requests and 4 MB of completed PNGs.
/// Eviction cancels only its own operation; late replies cannot replace a retry.
class _ThumbnailCache {
  _ThumbnailCache(this.requests);
  final _PickerRequests requests;
  final _entries = <(String, String), _ThumbnailRequest>{};

  Future<Uint8List> image(String groupID, String itemID) {
    final key = (groupID, itemID);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing.result.future;
    }
    final request = _ThumbnailRequest(requests.nextID());
    _entries[key] = request;
    while (_entries.length > 48) {
      _drop(_entries.keys.first);
    }
    unawaited(_load(key, request));
    return request.result.future;
  }

  Future<void> _load((String, String) key, _ThumbnailRequest request) async {
    try {
      final value = await requests.call('stickers.custom.thumbnail', {
        'groupID': key.$1,
        'itemID': key.$2,
      }, request.id);
      final raw = value['bytes'];
      final bytes = raw is Uint8List
          ? raw
          : raw is List
          ? Uint8List.fromList(raw.cast<int>())
          : null;
      if (bytes == null || bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('Invalid thumbnail');
      }
      if (identical(_entries[key], request)) {
        request.size = bytes.length;
        while (_entries.values.fold<int>(0, (sum, entry) => sum + entry.size) >
            4 * 1024 * 1024) {
          _drop(_entries.keys.first);
        }
      }
      request.result.complete(bytes);
    } catch (error, stack) {
      if (identical(_entries[key], request)) _entries.remove(key);
      request.result.completeError(error, stack);
    }
  }

  void retry(String groupID, String itemID, Future<Uint8List> expected) {
    final key = (groupID, itemID);
    if (identical(_entries[key]?.result.future, expected)) _drop(key);
  }

  void retain(List<_StickerGroup> groups) {
    final keys = {
      for (final group in groups)
        for (final item in group.items) (group.id, item.id),
    };
    for (final key in _entries.keys.toList()) {
      if (!keys.contains(key)) _drop(key);
    }
  }

  void _drop((String, String) key) {
    final request = _entries.remove(key);
    if (request != null) requests.cancel(request.id);
  }

  void dispose() {
    for (final key in _entries.keys.toList()) {
      _drop(key);
    }
  }
}

class _LocalThumbnail extends StatefulWidget {
  const _LocalThumbnail({
    required this.cache,
    required this.groupID,
    required this.itemID,
    required this.enabled,
    super.key,
  });
  final _ThumbnailCache cache;
  final String groupID, itemID;
  final bool enabled;
  @override
  State<_LocalThumbnail> createState() => _LocalThumbnailState();
}

class _LocalThumbnailState extends State<_LocalThumbnail> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.cache.image(widget.groupID, widget.itemID);
  }

  void _retry() {
    if (!widget.enabled) return;
    widget.cache.retry(widget.groupID, widget.itemID, _future);
    final next = widget.cache.image(widget.groupID, widget.itemID);
    setState(() {
      _future = next;
    });
  }

  Widget _failure() => CupertinoButton(
    padding: EdgeInsets.zero,
    onPressed: widget.enabled ? _retry : null,
    child: Semantics(
      label: '重试表情缩略图',
      button: true,
      child: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
    ),
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _failure();
        final bytes = snapshot.data;
        if (bytes == null) return const CupertinoActivityIndicator(radius: 8);
        return Image.memory(
          bytes,
          width: 48,
          height: 48,
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) => _failure(),
        );
      },
    ),
  );
}
