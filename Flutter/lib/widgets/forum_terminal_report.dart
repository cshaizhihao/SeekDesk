import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'forum_text_selection.dart';
import 'glass_chrome.dart';

/// Parsed terminal runs retain their CSS colors and natural report height.
/// Styling and text measurement survive parent rebuilds and scale changes.
class NativeTerminalReport extends StatefulWidget {
  const NativeTerminalReport({
    required this.state,
    required this.rows,
    this.text = '',
    super.key,
  });
  final AppState state;
  final List<List<JsonMap>> rows;
  final String text;
  @override
  State<NativeTerminalReport> createState() => _NativeTerminalReportState();
}

class _NativeTerminalReportState extends State<NativeTerminalReport> {
  late final AppState _owner;
  late final int _revision;
  bool _retired = false, _copying = false;
  int _copyGeneration = 0;
  CupertinoPageRoute<void>? _expandedRoute;
  ValueNotifier<bool>? _viewerAccess;
  List<List<JsonMap>> rows = const [];
  List<List<InlineSpan>> _styledRows = const [];
  TextSpan _styledText = const TextSpan();
  String plain = '';
  double naturalWidth = 500;
  static const lineHeight = 20.0;
  @override
  void initState() {
    super.initState();
    _owner = widget.state;
    _revision = _owner.accessRevision;
    _owner.addListener(_accessChanged);
    _prepare();
  }

  bool get _available =>
      mounted &&
      !_retired &&
      identical(widget.state, _owner) &&
      _revision == _owner.accessRevision;

  void _accessChanged() {
    if (_retired || _available) return;
    _retired = true;
    _copyGeneration++;
    _copying = false;
    rows = const [];
    _styledRows = const [];
    _styledText = const TextSpan();
    plain = '';
    _retireViewer();
    if (mounted) _rebuildTerminalSafely(this, () => setState(() {}));
  }

  void _retireViewer() {
    _viewerAccess?.value = false;
    final route = _expandedRoute;
    if (route != null) _removeTerminalRoute(route);
  }

  @override
  void didUpdateWidget(NativeTerminalReport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_available) {
      _accessChanged();
      return;
    }
    if (!_sameRows(oldWidget.rows, widget.rows) ||
        oldWidget.text != widget.text) {
      _retireViewer();
      _copyGeneration++;
      _copying = false;
      _prepare();
    }
  }

  @override
  void dispose() {
    _owner.removeListener(_accessChanged);
    _retired = true;
    _copyGeneration++;
    _retireViewer();
    super.dispose();
  }

  bool _sameRows(List<List<JsonMap>> left, List<List<JsonMap>> right) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var line = 0; line < left.length; line++) {
      if (left[line].length != right[line].length) return false;
      for (var run = 0; run < left[line].length; run++) {
        final a = left[line][run], b = right[line][run];
        for (final field in ['text', 'foreground', 'background', 'bold']) {
          if (a[field] != b[field]) return false;
        }
      }
    }
    return true;
  }

  void _prepare() {
    rows = widget.rows.isNotEmpty
        ? widget.rows
        : widget.text
              .split('\n')
              .map(
                (line) => <JsonMap>[
                  {'text': line},
                ],
              )
              .toList();
    _styledRows = rows
        .map(
          (row) => row.isEmpty
              ? <InlineSpan>[const TextSpan(text: ' ')]
              : row.map(_run).toList(growable: false),
        )
        .toList(growable: false);
    _styledText = TextSpan(
      children: [
        for (var index = 0; index < _styledRows.length; index++) ...[
          if (index != 0) const TextSpan(text: '\n'),
          ..._styledRows[index],
        ],
      ],
    );
    plain = rows
        .map((row) => row.map((run) => stringValue(run['text'])).join())
        .join('\n');
    naturalWidth = 500;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );
    for (final row in _styledRows) {
      textPainter.text = TextSpan(style: _terminalStyle, children: row);
      textPainter.layout();
      naturalWidth = math.max(
        naturalWidth,
        textPainter.width.ceilToDouble() + 26,
      );
    }
    textPainter.dispose();
  }

  TextStyle get _terminalStyle => const TextStyle(
    fontFamily: 'monospace',
    fontSize: 12.5,
    color: Color(0xffd6e0f0),
    height: 1.6,
  );

  static Color? parseColor(Object? value) {
    final text = stringValue(value).trim();
    if (text.startsWith('#')) {
      final hex = text.substring(1);
      if (hex.length == 3) {
        final expanded = hex.split('').map((part) => '$part$part').join();
        final number = int.tryParse(expanded, radix: 16);
        return number == null ? null : Color(0xff000000 | number);
      }
      final number = int.tryParse(hex, radix: 16);
      return number == null || ![6, 8].contains(hex.length)
          ? null
          : Color(
              hex.length == 6
                  ? number | 0xff000000
                  : (number & 0xff) << 24 | number >> 8,
            );
    }
    final components = RegExp(
      r'^rgba?\(\s*([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$',
    ).firstMatch(text);
    if (components == null) return null;
    final values = [
      for (var i = 1; i <= 3; i++) double.tryParse(components.group(i)!),
    ];
    if (values.any(
      (value) => value == null || !value.isFinite || value < 0 || value > 255,
    )) {
      return null;
    }
    final alpha = double.tryParse(components.group(4) ?? '1') ?? 1;
    return Color.fromARGB(
      (alpha.clamp(0.0, 1.0) * 255).round(),
      values[0]!.round(),
      values[1]!.round(),
      values[2]!.round(),
    );
  }

  TextSpan _run(JsonMap run) => TextSpan(
    text: stringValue(run['text']),
    style: TextStyle(
      color: parseColor(run['foreground']),
      backgroundColor: parseColor(run['background']),
      fontWeight: run['bold'] == true ? FontWeight.bold : FontWeight.normal,
    ),
  );

  Widget _inlineLines({
    required double factor,
    required double width,
    required double height,
  }) {
    return SizedBox(
      width: width,
      height: height,
      child: Padding(
        padding: EdgeInsets.all(12 * factor),
        child: SelectionContainer.disabled(
          child: ForumTextSelection(
            child: Text.rich(
              TextSpan(
                style: _terminalStyle.copyWith(fontSize: 12.5 * factor),
                children: [_styledText],
              ),
              strutStyle: StrutStyle(
                fontFamily: 'monospace',
                fontSize: 12.5 * factor,
                height: 1.6,
                forceStrutHeight: true,
              ),
              textScaler: TextScaler.noScaling,
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    final percent = numberValue(
      widget.state.domain('settings')['workspace.nqReportScale'],
      100,
    ).clamp(25.0, 200.0);
    return LayoutBuilder(
      builder: (context, bounds) {
        final available = bounds.maxWidth.isFinite
            ? math.max(1.0, bounds.maxWidth)
            : 640.0;
        final target = math.min(640.0, available) * percent / 100;
        final factor = target / naturalWidth;
        // The page owns vertical scrolling. A long report keeps its full height
        // so the mouse wheel never gets captured by a nested report viewport.
        final height = (math.max(1, rows.length) * lineHeight + 24) * factor;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 7,
              runSpacing: 7,
              children: [
                DeskIcon(
                  '缩小报告',
                  CupertinoIcons.minus,
                  () => _scale(percent - 10),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Text(
                    '${percent.round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      color: DeskColors(context).secondary,
                    ),
                  ),
                ),
                DeskIcon(
                  '放大报告',
                  CupertinoIcons.plus,
                  () => _scale(percent + 10),
                ),
                DeskButton(
                  '复制报告',
                  width: 100,
                  height: 32,
                  icon: CupertinoIcons.doc_on_doc,
                  busy: _copying,
                  onTap: _copying ? null : _copy,
                ),
                DeskButton(
                  '放大查看',
                  width: 100,
                  height: 32,
                  icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                  onTap: _expandedRoute == null ? _expand : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: math.min(target, available),
                height: height,
                decoration: BoxDecoration(
                  color: const Color(0xff172033),
                  borderRadius: BorderRadius.circular(9),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _inlineLines(
                    factor: factor,
                    width: target,
                    height: height,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _scale(double value) {
    if (!_available || ModalRoute.of(context)?.isCurrent == false) return;
    _owner.act('settings.update', {
      'key': 'workspace.nqReportScale',
      'value': value.clamp(25.0, 200.0),
    }, 'settings');
  }

  Future<void> _copy() async {
    if (!_available || _copying || ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final generation = _copyGeneration;
    final sourceRoute = ModalRoute.of(context);
    setState(() => _copying = true);
    bool ownsCopy() => _available && generation == _copyGeneration;
    try {
      await Clipboard.setData(ClipboardData(text: plain));
      if (ownsCopy() && sourceRoute?.isCurrent != false) {
        _owner.showMessage('报告已复制');
      }
    } catch (_) {
      if (ownsCopy() && sourceRoute?.isCurrent != false) {
        _owner.showMessage('报告复制失败，请重试。');
      }
    } finally {
      if (ownsCopy()) setState(() => _copying = false);
    }
  }

  Future<void> _expand() async {
    if (!_available ||
        _expandedRoute != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final access = ValueNotifier(true);
    late final CupertinoPageRoute<void> route;
    route = CupertinoPageRoute<void>(
      builder: (_) => _ExpandedTerminalReport(
        state: _owner,
        revision: _revision,
        access: access,
        route: route,
        styledRows: _styledRows,
        plain: plain,
        naturalWidth: naturalWidth,
        style: _terminalStyle,
      ),
    );
    setState(() {
      _expandedRoute = route;
      _viewerAccess = access;
    });
    try {
      await Navigator.of(context).push(route);
      // The source may be disposed while the route is still animating out.
      // Keep its invalidation signal alive until the route releases its child.
      await route.completed;
    } finally {
      access.dispose();
      if (identical(_expandedRoute, route)) {
        _expandedRoute = null;
        _viewerAccess = null;
        if (mounted) setState(() {});
      }
    }
  }
}

/// A viewer owns its route and account lease. It must never pop an unrelated
/// dialog that happens to be above it when the account changes.
class _ExpandedTerminalReport extends StatefulWidget {
  const _ExpandedTerminalReport({
    required this.state,
    required this.revision,
    required this.access,
    required this.route,
    required this.styledRows,
    required this.plain,
    required this.naturalWidth,
    required this.style,
  });

  final AppState state;
  final int revision;
  final ValueListenable<bool> access;
  final CupertinoPageRoute<void> route;
  final List<List<InlineSpan>> styledRows;
  final String plain;
  final double naturalWidth;
  final TextStyle style;

  @override
  State<_ExpandedTerminalReport> createState() =>
      _ExpandedTerminalReportState();
}

class _ExpandedTerminalReportState extends State<_ExpandedTerminalReport> {
  double _fontSize = 14;
  bool _retired = false, _closing = false, _copying = false;
  late List<List<InlineSpan>> _rows;
  late String _plain;

  bool get _available =>
      mounted &&
      !_retired &&
      !_closing &&
      widget.access.value &&
      widget.state.accessRevision == widget.revision;

  @override
  void initState() {
    super.initState();
    _rows = widget.styledRows;
    _plain = widget.plain;
    widget.state.addListener(_accessChanged);
    widget.access.addListener(_accessChanged);
    _accessChanged();
  }

  void _accessChanged() {
    if (_retired || _available) return;
    // Drop both selectable spans and copied text before scheduling any route
    // work, including when a transparent dialog currently covers this viewer.
    _retired = true;
    _rows = const [];
    _plain = '';
    _copying = false;
    _rebuildTerminalSafely(this, () => setState(() {}));
    _removeTerminalRoute(widget.route);
  }

  void _close() {
    if (!_available || !widget.route.isCurrent) return;
    _closing = true;
    widget.route.navigator?.pop();
  }

  Future<void> _copy() async {
    if (!_available || _copying || !widget.route.isCurrent) return;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: _plain));
      if (_available && widget.route.isCurrent) {
        widget.state.showMessage('报告已复制');
      }
    } catch (_) {
      if (_available && widget.route.isCurrent) {
        widget.state.showMessage('报告复制失败，请重试。');
      }
    } finally {
      if (_available) setState(() => _copying = false);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_accessChanged);
    widget.access.removeListener(_accessChanged);
    _retired = true;
    _rows = const [];
    _plain = '';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) {
      return const CupertinoPageScaffold(
        backgroundColor: Color(0xff172033),
        child: SizedBox.expand(),
      );
    }
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xff172033),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(15),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    '测评终端',
                    style: TextStyle(color: Color(0xffd6e0f0), fontSize: 17),
                  ),
                  DeskIcon(
                    '缩小报告字号',
                    CupertinoIcons.minus,
                    _fontSize <= 10
                        ? null
                        : () => setState(() => _fontSize -= 1),
                  ),
                  Text(
                    '${_fontSize.round()} 点',
                    style: const TextStyle(
                      color: Color(0xffd6e0f0),
                      fontSize: 12,
                    ),
                  ),
                  DeskIcon(
                    '放大报告字号',
                    CupertinoIcons.plus,
                    _fontSize >= 26
                        ? null
                        : () => setState(() => _fontSize += 1),
                  ),
                  DeskButton(
                    '复制报告',
                    width: 100,
                    busy: _copying,
                    onTap: _copying ? null : _copy,
                  ),
                  DeskButton('关闭', width: 72, onTap: _close),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: widget.naturalWidth * _fontSize / 12.5,
                  child: ListView.builder(
                    primary: false,
                    padding: const EdgeInsets.all(12),
                    itemCount: _rows.length,
                    itemExtent: _fontSize * 1.6,
                    itemBuilder: (context, index) =>
                        SelectionContainer.disabled(
                          child: ForumTextSelection(
                            child: Text.rich(
                              TextSpan(
                                style: widget.style.copyWith(
                                  fontSize: _fontSize,
                                ),
                                children: _rows[index],
                              ),
                              maxLines: 1,
                              textScaler: TextScaler.noScaling,
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _rebuildTerminalSafely(State<StatefulWidget> state, VoidCallback rebuild) {
  if (!state.mounted) return;
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.mounted) rebuild();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  } else {
    rebuild();
  }
}

void _removeTerminalRoute(CupertinoPageRoute<void> route) {
  // Invalidation can arrive while Navigator is finalizing another route or
  // while the source report is unmounting. Remove this exact route next frame.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final navigator = route.navigator;
    if (navigator != null && route.isActive) navigator.removeRoute(route);
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}
