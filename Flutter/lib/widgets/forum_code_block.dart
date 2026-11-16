import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/code_highlight.dart';
import '../state/app_state.dart';
import 'desk_label_metrics.dart';
import 'forum_text_selection.dart';
import 'glass_chrome.dart';

/// Stable text geometry and one horizontal viewport. The code remains literal,
/// selectable and copyable, including when highlighting falls back to plain.
class ForumCodeBlock extends StatefulWidget {
  const ForumCodeBlock({
    required this.state,
    required this.text,
    this.language = '',
    super.key,
  });
  final AppState state;
  final String text, language;

  @override
  State<ForumCodeBlock> createState() => _ForumCodeBlockState();
}

class _ForumCodeBlockState extends State<ForumCodeBlock> {
  late final AppState _owner;
  late final int _revision;
  late List<CodeToken> _tokens;
  Timer? _feedback;
  bool _copied = false, _copying = false, _retired = false;
  int _generation = 0;

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
    _generation++;
    _feedback?.cancel();
    _tokens = const [];
    _copying = false;
    _copied = false;
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      setState(() {});
    }
  }

  void _prepare() {
    _generation++;
    _tokens = CodeHighlight.tokenize(widget.text, language: widget.language);
    _feedback?.cancel();
    _copied = false;
    _copying = false;
  }

  @override
  void didUpdateWidget(ForumCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_available) {
      _accessChanged();
      return;
    }
    if (oldWidget.text != widget.text ||
        oldWidget.language != widget.language) {
      _prepare();
    }
  }

  Future<void> _copy() async {
    if (!_available || _copying) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == false) return;
    final source = widget.text, generation = _generation;
    bool ownsCopy() => _available && generation == _generation;
    bool canShowFeedback() => ownsCopy() && (route?.isCurrent ?? true);
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: source));
      if (!canShowFeedback()) return;
      _feedback?.cancel();
      setState(() => _copied = true);
      _feedback = Timer(const Duration(seconds: 2), () {
        if (ownsCopy()) setState(() => _copied = false);
      });
    } catch (_) {
      if (canShowFeedback()) {
        _owner.showMessage('复制失败，请选中代码后按 ⌘C。');
      }
    } finally {
      if (ownsCopy()) setState(() => _copying = false);
    }
  }

  @override
  void dispose() {
    _owner.removeListener(_accessChanged);
    _retired = true;
    _generation++;
    _feedback?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    final colors = DeskColors(context);
    final copyLabel = DeskLabelMetrics.of(
      context,
      style: DeskTypography.control,
    ).measure('已复制');
    Color? ink(CodeTokenKind kind) => switch (kind) {
      CodeTokenKind.plain => null,
      CodeTokenKind.comment => colors.secondary,
      CodeTokenKind.string =>
        colors.dark ? const Color(0xffb6d8a8) : const Color(0xff316540),
      CodeTokenKind.number =>
        colors.dark ? const Color(0xffe5bd89) : const Color(0xff80511c),
      CodeTokenKind.keyword =>
        colors.dark ? const Color(0xffc4b8ef) : const Color(0xff6541a0),
    };
    final language = CodeHighlight.language(widget.language);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 7, 7, 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      language.isEmpty ? '代码' : language,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DeskTypography.metadata.copyWith(
                        color: colors.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    liveRegion: true,
                    child: DeskButton(
                      _copied ? '已复制' : '复制',
                      semanticLabel: _copied ? '代码已复制' : '复制代码',
                      icon: _copied
                          ? CupertinoIcons.check_mark
                          : CupertinoIcons.doc_on_doc,
                      width: math.max(80, copyLabel.width.ceilToDouble() + 46),
                      height: math.max(
                        30,
                        copyLabel.height.ceilToDouble() + 12,
                      ),
                      quiet: true,
                      busy: _copying,
                      onTap: _copy,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 4, 15, 15),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              primary: false,
              child: SelectionContainer.disabled(
                child: ForumTextSelection(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        for (final token in _tokens)
                          TextSpan(
                            text: token.text,
                            style: TextStyle(color: ink(token.kind)),
                          ),
                      ],
                    ),
                    style: DeskTypography.base.copyWith(
                      color: colors.ink,
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.6,
                    ),
                    textDirection: TextDirection.ltr,
                    softWrap: false,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
