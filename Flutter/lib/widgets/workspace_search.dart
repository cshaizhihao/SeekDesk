import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

/// A detached search draft. The workspace decides when to execute it.
final class WorkspaceSearchRequest {
  WorkspaceSearchRequest({
    required this.query,
    required Set<String> scope,
    required this.kind,
  }) : scope = Set<String>.unmodifiable(scope);

  final String query;
  final Set<String> scope;
  final String kind;
}

/// Opening and dismissing this route never changes the workspace destination,
/// reader, or applied search. Only explicit history deletion calls the service.
Future<WorkspaceSearchRequest?> showWorkspaceSearch(
  BuildContext context, {
  required AppState state,
}) async {
  final revision = state.accessRevision;
  final result = await showGeneralDialog<WorkspaceSearchRequest>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '取消搜索',
    barrierColor: CupertinoTheme.brightnessOf(context) == Brightness.dark
        ? const Color(0x2e000000)
        : const Color(0x14000000),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160),
    transitionBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, animation, secondary) =>
        _WorkspaceSearch(state: state, revision: revision),
  );
  return state.accessRevision == revision ? result : null;
}

const _kinds = ['all', 'posts', 'people'];
const _kindTitles = ['全部', '帖子', '用户'];

class _WorkspaceSearch extends StatefulWidget {
  const _WorkspaceSearch({required this.state, required this.revision});
  final AppState state;
  final int revision;

  @override
  State<_WorkspaceSearch> createState() => _WorkspaceSearchState();
}

class _WorkspaceSearchState extends State<_WorkspaceSearch> {
  late final TextEditingController _text;
  final _focus = FocusNode();
  late final List<JsonMap> _boards;
  late final Set<String> _searchable;
  late Set<String> _scope;
  late String _kind;
  List<JsonMap> _history = const [];
  Object? _workspace;
  bool _invalidated = false, _closing = false, _clearing = false;
  int _clearTicket = 0;
  String? _historyError;

  bool get _currentIdentity =>
      !_invalidated && widget.state.accessRevision == widget.revision;
  bool get _officeCovered {
    final extensions = widget.state.domain('extensions');
    return jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] == true;
  }

  bool get _ownRoute => mounted && ModalRoute.of(context)?.isCurrent == true;
  bool get _canAct =>
      _ownRoute && !_closing && !_officeCovered && _currentIdentity;
  bool get _composing =>
      _text.value.composing.isValid && !_text.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    final workspace = widget.state.domain('workspace');
    _workspace = workspace;
    _boards = jsonItems(workspace['boards'])
        .where((board) {
          final id = stringValue(board['id']);
          if (id.isEmpty) return false;
          return board['searchable'] is bool
              ? board['searchable'] == true
              : id != 'home' && id != 'award';
        })
        .toList(growable: false);
    _searchable = {for (final board in _boards) stringValue(board['id'])};
    final query = stringValue(workspace['query']);
    _text = TextEditingController(text: query)..addListener(_edited);
    if (query.isEmpty) {
      _kind = 'all';
      final category = stringValue(
        workspace['boardCategoryID'] ?? workspace['board'],
      );
      _scope = _searchable.contains(category) ? {category} : {};
    } else {
      _kind = _validKind(workspace['appliedSearchKind']);
      _scope = _validScope(workspace['appliedSearchScope']);
    }
    _readHistory(workspace);
    widget.state.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canAct) return;
      _text.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _text.text.length,
      );
      _focus.requestFocus();
    });
  }

  String _validKind(Object? value) =>
      _kinds.contains(value) ? value! as String : 'all';
  Set<String> _validScope(Object? value) => value is List
      ? value.map((item) => item.toString()).where(_searchable.contains).toSet()
      : <String>{};

  void _readHistory(JsonMap workspace) {
    _history = jsonItems(workspace['searchHistory'])
        .take(5)
        .where((entry) => stringValue(entry['query']).trim().isNotEmpty)
        .toList(growable: false);
  }

  void _edited() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    if (widget.state.accessRevision != widget.revision) {
      if (_invalidated) return;
      _clearTicket++;
      _focus.unfocus();
      setState(() {
        _invalidated = true;
        _history = const [];
        _historyError = null;
      });
      return;
    }
    final workspace = widget.state.domains['workspace'];
    if (_currentIdentity && !identical(workspace, _workspace)) {
      _workspace = workspace;
      setState(() => _readHistory(workspace ?? const {}));
    }
  }

  void _finish([WorkspaceSearchRequest? request]) {
    // Never pop a newer dialog, editor, or image route above this search.
    if (!_ownRoute || _closing || _officeCovered) return;
    if (request != null && !_currentIdentity) return;
    _closing = true;
    Navigator.of(context).pop(request);
  }

  void _submit() {
    if (!_canAct || _composing || _text.text.trim().isEmpty) return;
    _finish(
      WorkspaceSearchRequest(
        query: _text.text.trim(),
        scope: _kind == 'people' ? {} : _scope,
        kind: _kind,
      ),
    );
  }

  void _repeat(JsonMap entry) {
    if (!_canAct || _composing) return;
    final kind = _validKind(entry['kind']);
    final query = stringValue(entry['query']).trim();
    if (query.isEmpty) return;
    _finish(
      WorkspaceSearchRequest(
        query: query,
        scope: kind == 'people' ? {} : _validScope(entry['scope']),
        kind: kind,
      ),
    );
  }

  Future<void> _clearHistory() async {
    if (!_canAct || _clearing) return;
    final ticket = ++_clearTicket;
    setState(() {
      _clearing = true;
      _historyError = null;
    });
    final result = await widget.state.act(
      'listing.clearHistory',
      {},
      'workspace',
    );
    if (!mounted || !_currentIdentity || ticket != _clearTicket) return;
    setState(() {
      _clearing = false;
      if (result == null) {
        _historyError = '清空记录失败，请重试。';
      } else if (result['searchHistory'] is List) {
        _readHistory(result);
      }
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_ownRoute || _officeCovered || _closing || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final escape = event.logicalKey == LogicalKeyboardKey.escape;
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!escape && !enter) return KeyEventResult.ignored;
    if (_currentIdentity && _composing) {
      // Leave the event unhandled for the platform IME, while preventing a
      // parent route's Escape shortcut or default submit action from firing.
      return KeyEventResult.skipRemainingHandlers;
    }
    if (event is KeyDownEvent) {
      if (escape) {
        _finish();
      } else {
        _submit();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _clearTicket++;
    widget.state.removeListener(_changed);
    _text.removeListener(_edited);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final scale = MediaQuery.textScalerOf(context);
    final glassTheme = GlassThemeData.of(context);
    return GlassTheme(
      data: glassTheme.copyWith(
        interaction: glassTheme.interaction.copyWith(
          interactionScale: 1,
          stretch: 0,
          anchorStretch: false,
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _key,
        child: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: Padding(
            padding: MediaQuery.viewInsetsOf(context),
            child: LayoutBuilder(
              builder: (context, bounds) => Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 560,
                    maxHeight: bounds.maxHeight,
                  ),
                  child: SizedBox(
                    width: math.min(560.0, bounds.maxWidth),
                    child: Semantics(
                      scopesRoute: true,
                      namesRoute: true,
                      explicitChildNodes: true,
                      label: '搜索或打开帖子',
                      child: DeskGlassPanel(
                        key: const ValueKey('workspace-search-panel'),
                        level: GlassLevel.overlay,
                        padding: EdgeInsets.zero,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: !_currentIdentity
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '账号已变更',
                                      style: TextStyle(
                                        color: colors.ink,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '请关闭搜索后重新打开。',
                                      style: TextStyle(
                                        color: colors.secondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    DeskButton('关闭搜索', onTap: _finish),
                                  ],
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '搜索 NodeSeek',
                                      style: TextStyle(
                                        color: colors.ink,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    GlassTextField.search(
                                      key: const ValueKey(
                                        'workspace-search-input',
                                      ),
                                      controller: _text,
                                      focusNode: _focus,
                                      placeholder: '搜索帖子、用户名，或粘贴帖子链接',
                                      height: math.max(
                                        36.0,
                                        scale.scale(14) + 20,
                                      ),
                                      textStyle: TextStyle(
                                        color: colors.ink,
                                        fontSize: 14,
                                      ),
                                      placeholderStyle: TextStyle(
                                        color: colors.secondary,
                                        fontSize: 14,
                                      ),
                                      prefixIcon: Icon(
                                        CupertinoIcons.search,
                                        size: 16,
                                        color: colors.secondary,
                                      ),
                                      suffixIcon: _text.text.isEmpty
                                          ? null
                                          : Icon(
                                              CupertinoIcons
                                                  .clear_circled_solid,
                                              size: 18,
                                              color: colors.secondary,
                                            ),
                                      suffixSemanticLabel: '清除搜索文字',
                                      onSuffixTap: () {
                                        if (_canAct) {
                                          _text.clear();
                                          _focus.requestFocus();
                                        }
                                      },
                                      onSubmitted: (_) => _submit(),
                                      pressScale: 1,
                                      surfaceStyle: GlassSurfaceStyle.solid,
                                      color: colors.well.withValues(
                                        alpha:
                                            colors.highContrast ||
                                                GlassAccessibilityData.of(
                                                  context,
                                                ).reduceTransparency
                                            ? 1
                                            : .56,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    GlassSegmentedControl(
                                      segments: [
                                        for (final title in _kindTitles)
                                          GlassSegment(label: title),
                                      ],
                                      selectedIndex: _kinds.indexOf(_kind),
                                      onSegmentSelected: (index) {
                                        if (_canAct) {
                                          setState(() => _kind = _kinds[index]);
                                        }
                                      },
                                      height: math.max(
                                        32.0,
                                        scale.scale(12) + 18,
                                      ),
                                      selectedTextStyle: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      unselectedTextStyle: const TextStyle(
                                        fontSize: 12,
                                      ),
                                      quality: GlassQuality.premium,
                                    ),
                                    if (_kind != 'people') ...[
                                      const SizedBox(height: 14),
                                      Wrap(
                                        alignment: WrapAlignment.spaceBetween,
                                        spacing: 12,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            '搜索版块',
                                            style: TextStyle(
                                              color: colors.ink,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            _scope.isEmpty
                                                ? '搜索所有版块'
                                                : '已选 ${_scope.length} 个版块',
                                            style: TextStyle(
                                              color: colors.secondary,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      LayoutBuilder(
                                        builder: (context, constraints) {
                                          final columns =
                                              (constraints.maxWidth /
                                                      math.max(
                                                        95.0,
                                                        scale.scale(84),
                                                      ))
                                                  .floor()
                                                  .clamp(1, 5)
                                                  .toInt();
                                          final width = math.max(
                                            0.0,
                                            (constraints.maxWidth -
                                                    (columns - 1) * 6) /
                                                columns,
                                          );
                                          return Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            children: [
                                              _chip(
                                                '',
                                                '全部版块',
                                                width,
                                                _scope.isEmpty,
                                              ),
                                              for (final board in _boards)
                                                _chip(
                                                  stringValue(board['id']),
                                                  stringValue(board['title']),
                                                  width,
                                                  _scope.contains(
                                                    stringValue(board['id']),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                    if (_history.isNotEmpty ||
                                        _clearing ||
                                        _historyError != null) ...[
                                      const SizedBox(height: 14),
                                      Wrap(
                                        alignment: WrapAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 12,
                                        runSpacing: 6,
                                        children: [
                                          Text(
                                            '最近搜索',
                                            style: TextStyle(
                                              color: colors.secondary,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          DeskButton(
                                            '清空记录',
                                            semanticLabel: '清空最近搜索记录',
                                            width: 100,
                                            height: math.max(
                                              30.0,
                                              scale.scale(12) + 12,
                                            ),
                                            busy: _clearing,
                                            onTap: _clearHistory,
                                          ),
                                        ],
                                      ),
                                      for (
                                        var index = 0;
                                        index < _history.length;
                                        index++
                                      )
                                        _historyRow(_history[index], index),
                                      if (_historyError != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 6,
                                          ),
                                          child: Text(
                                            _historyError!,
                                            style: TextStyle(
                                              color: colors.secondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                    const SizedBox(height: 16),
                                    Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 12,
                                      runSpacing: 10,
                                      children: [
                                        Text(
                                          _kind == 'people'
                                              ? '按用户名查找论坛成员。'
                                              : '版块筛选只作用于帖子。',
                                          style: TextStyle(
                                            color: colors.secondary,
                                            fontSize: 11,
                                          ),
                                        ),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            DeskButton(
                                              '取消',
                                              width: 84,
                                              height: math.max(
                                                34.0,
                                                scale.scale(12) + 14,
                                              ),
                                              onTap: _finish,
                                            ),
                                            DeskButton(
                                              '搜索',
                                              width: 84,
                                              height: math.max(
                                                34.0,
                                                scale.scale(12) + 14,
                                              ),
                                              tint: colors.accent,
                                              onTap:
                                                  _text.text.trim().isEmpty ||
                                                      _composing
                                                  ? null
                                                  : _submit,
                                            ),
                                          ],
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
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String id, String title, double width, bool selected) {
    final colors = DeskColors(context);
    return Semantics(
      key: ValueKey('workspace-search-scope-$id'),
      selected: selected,
      child: DeskButton(
        title,
        icon: selected
            ? CupertinoIcons.checkmark_circle_fill
            : CupertinoIcons.circle,
        width: width,
        height: math.max(30.0, MediaQuery.textScalerOf(context).scale(12) + 14),
        selected: selected,
        tint: selected ? colors.selectionInk : colors.secondary,
        onTap: () {
          if (!_canAct) return;
          setState(() {
            if (id.isEmpty) {
              _scope.clear();
            } else if (!_scope.remove(id)) {
              _scope.add(id);
            }
          });
        },
      ),
    );
  }

  Widget _historyRow(JsonMap entry, int index) {
    final kind = _validKind(entry['kind']);
    final scope = _validScope(entry['scope']);
    final scopeTitle = scope.isEmpty
        ? '全部版块'
        : _boards
              .where((board) => scope.contains(stringValue(board['id'])))
              .map((board) => stringValue(board['title']))
              .join('、');
    final description = kind == 'people'
        ? '用户'
        : '${_kindTitles[_kinds.indexOf(kind)]} · $scopeTitle';
    final colors = DeskColors(context);
    return HoverRow(
      key: ValueKey('workspace-search-history-$index'),
      onTap: () => _repeat(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            Icon(CupertinoIcons.clock, color: colors.secondary, size: 14),
            const SizedBox(width: 7),
            Expanded(
              flex: 3,
              child: Text(
                stringValue(entry['query']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.ink, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              flex: 2,
              child: Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(color: colors.secondary, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
