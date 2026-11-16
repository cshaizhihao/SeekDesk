import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../state/app_state.dart';
import '../state/value_tool_memory.dart';
import '../widgets/desk_label_metrics.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/forum_blocks.dart';
import '../widgets/sidebar_rankings.dart';

class RankingsScreen extends StatelessWidget {
  const RankingsScreen({required this.state, super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state.rankings,
    builder: (context, _) {
      final rankings = state.rankings;
      final colors = DeskColors(context);
      final posts = rankings.posts;
      final textSize = numberValue(
        state.domain('settings')['workspace.rankingTextSize'],
        12,
      ).clamp(11, 22).toDouble();
      final badgeWidth = math.max(
        49.0,
        _measure(
              context,
              '🔥 3',
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ).width +
            12,
      );
      return _ToolWidth(
        maxWidth: 810,
        child: CustomScrollView(
          key: PageStorageKey('full-rankings-${rankings.period.name}'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 18),
                child: DeskPageHeader(
                  title: 'NodeSeek 热榜',
                  trailing: DeskIcon(
                    '刷新热榜',
                    CupertinoIcons.arrow_clockwise,
                    () => rankings.refresh(force: true),
                    busy: rankings.loading,
                    quiet: true,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: RankingPeriodPicker(controller: rankings),
                ),
              ),
            ),
            if (rankings.error != null && rankings.hasSnapshot)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '更新失败，保留上次榜单。可点击刷新重试。',
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                ),
              ),
            if (rankings.updatedAt != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    rankingUpdatedLabel(rankings.updatedAt!),
                    style: DeskTypography.metadata.copyWith(
                      color: colors.secondary,
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
            if (posts.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: rankings.loading
                    ? const Center(child: CupertinoActivityIndicator())
                    : DeskEmpty(
                        rankings.hasSnapshot
                            ? '这一榜暂无可显示帖子'
                            : rankings.error != null
                            ? '热榜暂时无法加载'
                            : '等待加载热榜',
                        detail: rankings.error,
                        action: rankings.error == null
                            ? null
                            : _ToolButton(
                                '重试',
                                onTap: () => rankings.refresh(force: true),
                              ),
                      ),
              )
            else
              SliverList.builder(
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final post = posts[index];
                  final position = intValue(post['position']);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Semantics(
                      label: '热榜第 $position 名，${stringValue(post['title'])}',
                      button: true,
                      child: HoverRow(
                        key: ValueKey(
                          'full-ranking-${rankings.period.name}-${post['id']}',
                        ),
                        onTap: () => state.openTopic(TopicData(post)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: badgeWidth,
                                child: RankingPositionBadge(
                                  position: position,
                                  fontSize: 14,
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      stringValue(post['title']),
                                      style: TextStyle(
                                        color: colors.ink,
                                        fontSize: textSize,
                                        fontWeight: FontWeight.w500,
                                        height: 1.4,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 5,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        if (TopicData(post)
                                            .categoryLabel
                                            .isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colors.accent.withValues(
                                                alpha: .08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                            ),
                                            child: Text(
                                              TopicData(post).categoryLabel,
                                              style: DeskTypography.metadata
                                                  .copyWith(
                                                    color: colors.accent,
                                                  ),
                                            ),
                                          ),
                                        Text(
                                          '${stringValue(post['author'])} · ${intValue(post['replies'])} 回复 · ${intValue(post['views'])} 浏览',
                                          style: DeskTypography.metadata
                                              .copyWith(
                                                color: colors.secondary,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      );
    },
  );
}

class ValueScreen extends StatefulWidget {
  const ValueScreen({
    required this.state,
    this.topicKey,
    this.topicTitle,
    this.embedded = false,
    super.key,
  });
  final AppState state;
  final String? topicKey, topicTitle;
  final bool embedded;
  @override
  State<ValueScreen> createState() => _ValueScreenState();
}

class _ValueScreenState extends State<ValueScreen> {
  final amount = TextEditingController(), expires = TextEditingController();
  final manualRate = TextEditingController(), asking = TextEditingController();
  final asOf = TextEditingController();
  final _formScroll = ScrollController();
  ValueToolDraft? _draft;
  bool _restoring = false;
  Object? _identity;
  Object? _textProjection;
  Object get _inputTexts =>
      (amount.text, expires.text, asOf.text, manualRate.text, asking.text);
  int _hintGeneration = 0;
  JsonMap? _hint;
  String? _hintError, _copyText, _copyStatus;
  bool _hintLoading = false;
  final _rateControlKey = GlobalKey();
  final _cycleControlKey = GlobalKey();
  final _rateRequests =
      <(NativeClient, int, String, String), Future<JsonMap>>{};
  int cycle = 1, mode = 0, rateGeneration = 0, inputGeneration = 0;
  int revision = 0, optionsGeneration = 0;
  int _calculationGeneration = 0;
  String base = 'USD', quote = 'CNY';
  List<JsonMap> currencies = [];
  JsonMap? result, rate;
  String? rateError, calculationError, optionsError;
  bool loading = false, rateLoading = false, optionsLoading = false;

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    _restoreDraft();
    widget.state.addListener(_identityChanged);
    for (final field in [amount, expires, asOf, manualRate, asking]) {
      field.addListener(_edited);
    }
    _options();
    _rate();
    _loadHint();
  }

  @override
  void didUpdateWidget(ValueScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_identityChanged);
      widget.state.addListener(_identityChanged);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.topicKey != widget.topicKey) {
      _resetRequests();
    } else if (oldWidget.topicTitle != widget.topicTitle) {
      _loadHint();
    }
  }

  Object get _currentIdentity => (
    widget.state,
    widget.state.accessRevision,
    intValue(widget.state.domain('session')['owner']),
    widget.state.signedIn,
  );

  void _identityChanged() {
    if (mounted && _identity != _currentIdentity) _resetRequests();
  }

  void _restoreDraft() {
    _identity = _currentIdentity;
    _draft = widget.state.valueTools.forTopic(
      widget.topicKey == null ? 'standalone' : 'topic:${widget.topicKey}',
    );
    final draft = _draft ?? ValueToolDraft();
    _restoring = true;
    amount.text = draft.amount;
    expires.text = draft.expires;
    asOf.text = draft.asOf ?? _dateLabel(DateTime.now());
    manualRate.text = draft.manualRate;
    asking.text = draft.asking;
    base = draft.base;
    quote = draft.quote;
    cycle = draft.cycle;
    mode = draft.mode;
    _restoring = false;
    _textProjection = _inputTexts;
  }

  void _remember() {
    if (_restoring || _identity != _currentIdentity) return;
    _draft
      ?..amount = amount.text
      ..expires = expires.text
      ..asOf = asOf.text
      ..manualRate = manualRate.text
      ..asking = asking.text
      ..base = base
      ..quote = quote
      ..cycle = cycle
      ..mode = mode;
  }

  void _resetRequests() {
    revision = widget.state.accessRevision;
    optionsGeneration++;
    _calculationGeneration++;
    _restoreDraft();
    setState(() {
      optionsLoading = false;
      currencies = [];
      loading = false;
      _invalidate();
    });
    _options();
    _rate();
    _loadHint();
  }

  void _invalidate() {
    _textProjection = _inputTexts;
    inputGeneration++;
    result = null;
    _copyText = _copyStatus = null;
    calculationError = null;
    _remember();
  }

  void _edited() {
    // Selection and IME bookkeeping also notify a TextEditingController. They
    // do not change the calculation inputs and must not erase a valid ticket.
    if (mounted && !_restoring && _textProjection != _inputTexts) {
      setState(_invalidate);
    }
  }

  Future<void> _loadHint() async {
    final generation = ++_hintGeneration;
    final identity = _currentIdentity;
    final title = widget.topicTitle?.trim() ?? '';
    setState(() {
      _hint = null;
      _hintError = null;
      _hintLoading = title.isNotEmpty;
    });
    if (title.isEmpty) return;
    try {
      final hint = await widget.state.client.call('value.hint', {
        'title': title,
      });
      if (!mounted ||
          identity != _currentIdentity ||
          generation != _hintGeneration) {
        return;
      }
      setState(() {
        _hintLoading = false;
        if (hint['available'] == true) _hint = hint;
      });
    } catch (_) {
      if (!mounted ||
          identity != _currentIdentity ||
          generation != _hintGeneration) {
        return;
      }
      setState(() {
        _hintLoading = false;
        _hintError = '标题识别暂时不可用';
      });
    }
  }

  bool get _composing => [amount, expires, asOf, manualRate, asking].any(
    (field) =>
        field.value.composing.isValid && !field.value.composing.isCollapsed,
  );

  void _applyHint() {
    final hint = _hint;
    if (hint == null || _composing || _identity != _currentIdentity) return;
    final hintedAmount = _number(stringValue(hint['amount']));
    final hintedBase = stringValue(hint['base']);
    final hintedCycle = intValue(hint['cycle']);
    if (hintedAmount == null ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(hintedBase) ||
        !const [1, 3, 6, 12, 24, 36].contains(hintedCycle)) {
      return;
    }
    setState(() {
      _restoring = true;
      amount.text = hintedAmount;
      manualRate.clear();
      base = hintedBase;
      cycle = hintedCycle;
      _restoring = false;
      _invalidate();
    });
    _rate();
  }

  Future<void> _copyResult() async {
    final text = _copyText,
        identity = _currentIdentity,
        generation = inputGeneration;
    if (text == null || _composing) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted &&
          identity == _currentIdentity &&
          generation == inputGeneration) {
        setState(() => _copyStatus = '已复制');
      }
    } catch (_) {
      if (mounted &&
          identity == _currentIdentity &&
          generation == inputGeneration) {
        setState(() => _copyStatus = '复制失败，请重试');
      }
    }
  }

  Future<void> _options() async {
    if (optionsLoading) return;
    final generation = ++optionsGeneration;
    final owner = widget.state, access = revision;
    setState(() {
      optionsLoading = true;
      optionsError = null;
    });
    try {
      final data = await owner.client.call('value.currencies');
      if (!mounted ||
          generation != optionsGeneration ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        currencies = jsonItems(data['items']);
        optionsLoading = false;
        if (currencies.isEmpty) optionsError = '暂时无法读取币种，请重试。';
      });
    } catch (failure) {
      if (!mounted ||
          generation != optionsGeneration ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        optionsLoading = false;
        optionsError = failure.toString();
      });
    }
  }

  Future<JsonMap> _sharedRate({required bool force}) {
    final client = widget.state.client;
    final key = (client, revision, base, quote);
    final pending = _rateRequests[key];
    if (pending != null) return pending;
    // Share the actual response across automatic → manual → automatic. A second
    // AppState.act call would otherwise return null while the first is pending.
    late final Future<JsonMap> request;
    request = () async {
      try {
        return await client.call('value.rate', {
          'base': key.$3,
          'quote': key.$4,
          'force': force,
        });
      } finally {
        if (identical(_rateRequests[key], request)) _rateRequests.remove(key);
      }
    }();
    _rateRequests[key] = request;
    return request;
  }

  Future<void> _rate({bool force = false}) async {
    final generation = ++rateGeneration;
    final owner = widget.state, access = revision;
    setState(() {
      _invalidate();
      rateError = null;
      rate = base == quote ? {'rate': '1', 'source': '同币种'} : null;
      rateLoading = base != quote && mode == 0;
    });
    if (!rateLoading) return;
    try {
      final data = await _sharedRate(force: force);
      if (!mounted ||
          generation != rateGeneration ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      if (_automaticRate(stringValue(data['rate'])) == null ||
          (data.containsKey('base') && data['base'] != base) ||
          (data.containsKey('quote') && data['quote'] != quote)) {
        throw const NativeFailure('invalid_rate', '未取得有效汇率，请刷新或手动填写。');
      }
      setState(() {
        _invalidate();
        rate = data;
        rateLoading = false;
      });
    } catch (failure) {
      if (!mounted ||
          generation != rateGeneration ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        rateError = failure.toString();
        rateLoading = false;
      });
    }
  }

  Future<void> _currency(bool original) async {
    if (_composing) return;
    final identity = _currentIdentity, topic = widget.topicKey;
    if (currencies.isEmpty) await _options();
    if (!mounted ||
        currencies.isEmpty ||
        identity != _currentIdentity ||
        topic != widget.topicKey) {
      return;
    }
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(original ? '续费币种' : '折算币种'),
        actions: [
          for (final currency in currencies)
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.pop(context, stringValue(currency['code'])),
              child: Text(stringValue(currency['title'])),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
    );
    if (!mounted ||
        identity != _currentIdentity ||
        topic != widget.topicKey ||
        choice == null ||
        choice == (original ? base : quote) ||
        _composing) {
      return;
    }
    setState(() {
      if (original) {
        base = choice;
      } else {
        quote = choice;
        asking.clear();
      }
      manualRate.clear();
      _invalidate();
    });
    _rate();
  }

  // Validate the bridge's decimal wire format without converting user amounts
  // to binary floating point. Native Decimal remains the source of arithmetic.
  String? _number(String raw, {bool positive = false}) {
    final text = raw.trim();
    if (text.length > 32 ||
        !RegExp(r'^(?:[0-9]+(?:\.[0-9]{0,12})?|\.[0-9]{1,12})$')
            .hasMatch(text)) {
      return null;
    }
    if (positive && !RegExp('[1-9]').hasMatch(text)) return null;
    return text;
  }

  // Native reciprocal/cross rates retain Decimal precision. They have a wider
  // plain-decimal wire contract than human-entered amounts and manual rates.
  String? _automaticRate(String raw) {
    final text = raw.trim();
    if (text.length > 256 ||
        !RegExp(r'^(?:[0-9]+(?:\.[0-9]{0,128})?|\.[0-9]{1,128})$')
            .hasMatch(text) ||
        !RegExp('[1-9]').hasMatch(text)) {
      return null;
    }
    return text;
  }

  Future<void> calculate() async {
    if (loading || _composing) return;
    final renewal = _number(amount.text);
    final text = expires.text.trim();
    final date = _validDate(text),
        calculationDate = _validDate(asOf.text.trim());
    final askingText = asking.text.trim();
    final activeRate = base == quote
        ? '1'
        : mode == 1
        ? _number(manualRate.text, positive: true)
        : _automaticRate(stringValue(rate?['rate']));
    final error = renewal == null
        ? '请输入有效的续费金额，使用小数点，不含千位分隔符。'
        : date == null
        ? '请输入有效的到期日期，例如 2027-01-01。'
        : calculationDate == null
        ? '请输入有效的计算日期，例如 2027-01-01。'
        : mode == 1 && base != quote && activeRate == null
        ? '请输入大于 0 的手动汇率。'
        : askingText.isNotEmpty && _number(askingText) == null
        ? '请输入有效的挂价，使用小数点，不含千位分隔符。'
        : null;
    if (error != null) {
      setState(() {
        calculationError = error;
        result = null;
        _copyText = _copyStatus = null;
      });
      return;
    }
    final generation = inputGeneration, owner = widget.state, access = revision;
    final identity = _currentIdentity, request = ++_calculationGeneration;
    final calculationTitle = widget.topicTitle;
    final requestBase = base, requestQuote = quote;
    final rateSource = mode == 1 ? '手动汇率' : stringValue(rate?['source']);
    final rateDate = rate?['asOf'];
    final input = <String, dynamic>{
      'amount': renewal, 'cycle': cycle,
      'expires': date!.millisecondsSinceEpoch.toDouble(),
      'asOf': calculationDate!.millisecondsSinceEpoch.toDouble(),
      'base': base, 'quote': quote,
      // Keep the original-currency estimate available if the rate service fails.
      'rate': ?activeRate,
      if (activeRate != null && askingText.isNotEmpty) 'asking': askingText,
    };
    setState(() {
      loading = true;
      calculationError = null;
    });
    try {
      final data = await owner.client.call('value.calculate', input);
      if (!mounted ||
          request != _calculationGeneration ||
          identity != _currentIdentity ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        if (generation == inputGeneration) {
          result = data;
          _copyText = [
            'SeekDesk 剩余价值估算',
            if (calculationTitle?.isNotEmpty == true) calculationTitle!,
            '计算日期：${_dateLabel(calculationDate)} · 到期日期：${_dateLabel(date)}',
            '续费：$renewal $requestBase / ${input['cycle']} 个月',
            '剩余 ${data['days']} 天 · 原币剩余价值：${stringValue(data['originalFormatted']).isNotEmpty ? data['originalFormatted'] : '${data['amount']} $requestBase'}',
            if (stringValue(data['formatted']).isNotEmpty)
              '折算剩余价值：${data['formatted']}',
            if (activeRate != null)
              '汇率：1 $requestBase = $activeRate $requestQuote${rateSource.isEmpty ? '' : ' · $rateSource'}${rateDate is num && mode == 0 ? ' · ${_dateTimeLabel(rateDate)}' : ''}',
            if (input.containsKey('asking')) '挂价：$askingText $requestQuote',
            if (data['differenceLabel'] != null)
              '挂价${data['differenceLabel']} ${data['differenceAmount']}',
          ].join('\n');
        }
        loading = false;
      });
      if (widget.embedded && generation == inputGeneration && result != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              generation != inputGeneration ||
              !_formScroll.hasClients) {
            return;
          }
          if (MediaQuery.disableAnimationsOf(context) ||
              GlassAccessibilityData.of(context).reduceMotion) {
            _formScroll.jumpTo(0);
          } else {
            _formScroll.animateTo(
              0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (failure) {
      if (!mounted ||
          request != _calculationGeneration ||
          identity != _currentIdentity ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        if (generation == inputGeneration) {
          calculationError = failure.toString();
        }
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    amount.dispose();
    expires.dispose();
    asOf.dispose();
    _formScroll.dispose();
    manualRate.dispose();
    asking.dispose();
    super.dispose();
  }

  Widget _currencyButton(bool original) => _ToolButton(
    original ? base : quote,
    semanticLabel: original ? '续费币种 $base' : '折算币种 $quote',
    icon: CupertinoIcons.chevron_down,
    busy: optionsLoading,
    onTap: () => _currency(original),
  );

  Widget _renewalFields(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final currencyWidth = math.max(
        104.0,
        math.max(
          _measure(
            context,
            '续费币种',
            const TextStyle(fontSize: 13, height: 1.4),
          ).width,
          _measure(context, base, DeskTypography.control).width + 50,
        ),
      );
      final amountMinimum = math.max(
        220.0,
        _measure(
              context,
              '每期续费金额',
              const TextStyle(fontSize: 13, height: 1.4),
            ).width +
            24,
      );
      final horizontal = bounds.maxWidth >= amountMinimum + 14 + currencyWidth;
      // Keep both fields at the same element paths when the window changes.
      // In particular, the amount's editor and its focus survive the reflow.
      return Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: horizontal
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: horizontal
                ? bounds.maxWidth - currencyWidth - 14
                : bounds.maxWidth,
            child: _ToolField(
              label: '每期续费金额',
              child: _ToolInput(
                controller: amount,
                label: '每期续费金额',
                placeholder: '例如 35.99',
              ),
            ),
          ),
          SizedBox(width: horizontal ? 14 : 0, height: horizontal ? 0 : 14),
          SizedBox(
            width: horizontal ? currencyWidth : bounds.maxWidth,
            child: _ToolField(
              label: '续费币种',
              child: Align(
                alignment: Alignment.centerLeft,
                child: _currencyButton(true),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _cycleSelector(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const options = <int, String>{
        1: '月付',
        3: '季付',
        6: '半年付',
        12: '年付',
        24: '两年付',
        36: '三年付',
      };
      final colors = DeskColors(context);
      final style = DeskTypography.control.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      );
      final labelSize = _measureSegment(context, '三年付', style);
      final minimumWidth = (labelSize.width + 24) * options.length + 4;
      final height = math.max(36.0, labelSize.height + 16);
      final vertical = bounds.maxWidth < minimumWidth;
      return GlassSegmentedControl(
        key: _cycleControlKey,
        segments: [
          for (final option in options.entries)
            GlassSegment(
              id: '${option.key}',
              label: option.value,
              semanticLabel: option.value,
            ),
        ],
        selectedIndex: options.keys.toList().indexOf(cycle),
        direction: vertical ? Axis.vertical : Axis.horizontal,
        height: vertical ? bounds.maxWidth : height,
        segmentExtent: vertical ? height : null,
        borderRadius: vertical ? 14 : GlassDefaults.capsuleRadius,
        backgroundColor: colors.ink.withValues(alpha: .035),
        selectedTextStyle: style.copyWith(color: colors.ink),
        unselectedTextStyle: style.copyWith(
          fontWeight: FontWeight.w400,
          color: colors.secondary,
        ),
        quality: GlassQuality.premium,
        onSegmentSelected: (index) {
          final selected = options.keys.elementAt(index);
          if (cycle == selected) return;
          setState(() {
            cycle = selected;
            _invalidate();
          });
        },
      );
    },
  );

  Widget _rateSelector(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const labels = ['自动汇率', '手动汇率'];
      const style = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
      final size = _measureSegment(context, labels.first, style);
      final controlWidth = (size.width + 32) * 2 + 4;
      final controlHeight = math.max(36.0, size.height + 16);
      final vertical = bounds.maxWidth < controlWidth;
      final selector = SizedBox(
        width: math.min(bounds.maxWidth, controlWidth),
        child: GlassSegmentedControl(
          key: _rateControlKey,
          segments: [for (final label in labels) GlassSegment(label: label)],
          selectedIndex: mode,
          direction: vertical ? Axis.vertical : Axis.horizontal,
          height: vertical ? bounds.maxWidth : controlHeight,
          segmentExtent: vertical ? controlHeight : null,
          borderRadius: vertical ? 14 : GlassDefaults.capsuleRadius,
          selectedTextStyle: style,
          unselectedTextStyle: style.copyWith(fontWeight: FontWeight.w400),
          quality: GlassQuality.premium,
          onSegmentSelected: (index) {
            if (mode == index) return;
            setState(() {
              mode = index;
            });
            _rate();
          },
        ),
      );
      final currency = _ToolField(
        label: '折算币种',
        child: Align(
          alignment: Alignment.centerLeft,
          child: _currencyButton(false),
        ),
      );
      final currencyWidth = math.max(
        104.0,
        math.max(
          _measure(
            context,
            '折算币种',
            const TextStyle(fontSize: 13, height: 1.4),
          ).width,
          _measure(context, quote, DeskTypography.control).width + 50,
        ),
      );
      if (bounds.maxWidth < currencyWidth + 16 + controlWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [currency, const SizedBox(height: 14), selector],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(width: currencyWidth, child: currency),
          const SizedBox(width: 16),
          selector,
        ],
      );
    },
  );

  Widget _result(BuildContext context) {
    final value = result!, colors = DeskColors(context);
    final converted = stringValue(value['formatted']);
    final original = stringValue(value['originalFormatted']).isNotEmpty
        ? stringValue(value['originalFormatted'])
        : '${value['amount']} $base';
    final days = intValue(value['days']);
    return _section(
      title: '估算结果',
      quiet: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            converted.isEmpty ? '原币剩余价值' : '折算剩余价值',
            style: TextStyle(color: colors.secondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ForumTextSelection(
            child: Text(
              converted.isEmpty ? original : converted,
              style: TextStyle(
                color: colors.ink,
                fontSize: 30,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (converted.isNotEmpty && base != quote)
            Text(
              '原币 $original',
              style: TextStyle(color: colors.secondary, fontSize: 13),
            ),
          if (converted.isEmpty && base != quote)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '尚未取得 $base → $quote 汇率；当前显示原币估值，折算与挂价对比待计算。',
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          Text('剩余 $days 天', style: TextStyle(color: colors.ink, fontSize: 14)),
          const SizedBox(height: 6),
          Text(
            days == 0
                ? '到期日不晚于计算日期，剩余价值为 0。'
                : '续费金额 ×（${value['fullCycles']} 个完整周期 + ${value['partialDays']} / ${value['partialCycleDays']} 个周期）',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          if (value['differenceLabel'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '挂价${value['differenceLabel']} ${value['differenceAmount']}',
                style: TextStyle(color: colors.ink, fontSize: 14),
              ),
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ToolButton(
                '复制结果',
                icon: CupertinoIcons.doc_on_doc,
                onTap: _copyResult,
              ),
              if (_copyStatus != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _copyStatus!,
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required Widget child,
    String? subtitle,
    bool quiet = true,
  }) {
    if (!widget.embedded) {
      return DeskSection(
        key: ValueKey('value-section-$title'),
        title: title,
        subtitle: subtitle,
        quiet: quiet,
        child: child,
      );
    }
    final colors = DeskColors(context);
    return Padding(
      key: ValueKey('value-section-$title'),
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: DeskTypography.section.copyWith(color: colors.ink),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: colors.secondary),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  void _close() {
    if (_composing) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == true) Navigator.maybePop(context);
  }

  Widget _header(BuildContext context) => DeskPageHeader(
    title: '剩余价值计算器',
    trailing: DeskIcon('关闭估价', CupertinoIcons.xmark, _close, quiet: true),
  );

  Widget _contextCard(BuildContext context) {
    final colors = DeskColors(context);
    final hint = _hint, generation = _hintGeneration;
    return Padding(
      key: const ValueKey('value-topic-context'),
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.topicTitle ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.secondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (_hint != null || _hintLoading || _hintError != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_hint != null)
                  _ToolButton(
                    '从标题带入',
                    icon: CupertinoIcons.text_badge_plus,
                    onTap: () {
                      if (generation == _hintGeneration &&
                          identical(hint, _hint)) {
                        _applyHint();
                      }
                    },
                  ),
                if (_hint != null)
                  Text(
                    '${_hint!['amount']} ${_hint!['base']} / ${_hint!['cycle']} 个月',
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                if (_hintLoading)
                  const Text('正在识别标题…', style: TextStyle(fontSize: 12)),
                if (_hintError != null) _ToolButton('重试标题识别', onTap: _loadHint),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _calculateButton() => _ToolButton(
    '计算剩余价值',
    icon: CupertinoIcons.equal,
    quiet: false,
    busy: loading,
    onTap: calculate,
  );

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    final form = <Widget>[
      if ((widget.topicTitle?.trim() ?? '').isNotEmpty) _contextCard(context),
      if (widget.embedded && result != null) _result(context),
      _section(
        title: '续费与到期',
        quiet: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _renewalFields(context),
            const SizedBox(height: 14),
            _ToolField(label: '续费周期', child: _cycleSelector(context)),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, bounds) {
                final horizontal = bounds.maxWidth >= 400;
                final fieldWidth = horizontal
                    ? math.min(250.0, (bounds.maxWidth - 14) / 2)
                    : bounds.maxWidth;
                return Flex(
                  direction: horizontal ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: _ToolField(
                        label: '到期日期',
                        child: _ToolInput(
                          controller: expires,
                          label: '到期日期',
                          placeholder: 'YYYY-MM-DD',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: horizontal ? 14 : 0,
                      height: horizontal ? 0 : 14,
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: _ToolField(
                        label: '计算日期',
                        child: _ToolInput(
                          controller: asOf,
                          label: '计算日期',
                          placeholder: '计算基准日 YYYY-MM-DD',
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      _section(
        title: '币种与参考汇率',
        quiet: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _rateSelector(context),
            const SizedBox(height: 16),
            if (mode == 1 && base != quote)
              _ToolField(
                label: '手动汇率',
                child: _ToolInput(
                  controller: manualRate,
                  label: '手动汇率',
                  placeholder: '1 $base 等于多少 $quote',
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        rateLoading
                            ? '正在读取参考汇率…'
                            : rate == null
                            ? '尚未取得汇率，可先计算原币估值。'
                            : '1 $base = ${rate!['rate']} $quote',
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (base != quote) ...[
                      const SizedBox(width: 12),
                      DeskIcon(
                        '刷新汇率',
                        CupertinoIcons.arrow_clockwise,
                        () => _rate(force: true),
                        busy: rateLoading,
                        quiet: true,
                      ),
                    ],
                  ],
                ),
              ),
            if (rateError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _ToolError(rateError!),
              ),
            if (mode == 0 && rate?['source'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  [
                    stringValue(rate!['source']),
                    stringValue(rate!['caption']),
                    if (rate!['asOf'] is num)
                      '更新于 ${_dateTimeLabel(rate!['asOf'])}',
                  ].where((part) => part.isNotEmpty).join(' · '),
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
      if (optionsError != null)
        Padding(
          key: const ValueKey('value-options-error'),
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ToolError(optionsError!),
              const SizedBox(height: 10),
              _ToolButton('重试币种', onTap: _options, busy: optionsLoading),
            ],
          ),
        ),
      _section(
        title: '挂价对比',
        quiet: true,
        subtitle: '选填；使用折算后的币种。',
        child: _ToolField(
          label: '卖家挂价（$quote）',
          child: _ToolInput(
            controller: asking,
            label: '卖家挂价（$quote）',
            placeholder: '例如 180',
          ),
        ),
      ),

      if (!widget.embedded && calculationError != null)
        Padding(
          key: const ValueKey('value-calculation-error'),
          padding: const EdgeInsets.only(bottom: 14),
          child: _ToolError(calculationError!),
        ),
      if (!widget.embedded && result != null) _result(context),
    ];
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 16, 14),
            child: _header(context),
          ),
          Expanded(
            child: ListView(
              controller: _formScroll,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              children: form,
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (calculationError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ToolError(calculationError!),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _calculateButton(),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return CupertinoPageScaffold(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: DeskBackdrop.themed(colors)),
          ),
          SafeArea(
            child: _ToolWidth(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 24, bottom: 20),
                    child: _header(context),
                  ),
                  Expanded(
                    child: ListView(
                      controller: _formScroll,
                      padding: const EdgeInsets.only(bottom: 6),
                      children: form,
                    ),
                  ),
                  // Keep the primary action outside the scroll viewport: its
                  // trailing edge must not sit under the desktop scrollbar.
                  Container(
                    padding: const EdgeInsets.only(top: 12, bottom: 24),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: colors.line)),
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _calculateButton(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RulingsScreen extends StatefulWidget {
  const RulingsScreen({
    required this.state,
    required this.name,
    this.embedded = false,
    super.key,
  });
  final AppState state;
  final String name;
  final bool embedded;
  @override
  State<RulingsScreen> createState() => _RulingsScreenState();
}

class _RulingsScreenState extends State<RulingsScreen> {
  JsonMap? result;
  bool loading = false;
  String? error;
  int generation = 0, revision = 0;
  String? _openingURL, _openFailureURL;

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    widget.state.addListener(_identityChanged);
    _load();
  }

  @override
  void didUpdateWidget(RulingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_identityChanged);
      widget.state.addListener(_identityChanged);
    }
    if (oldWidget.state != widget.state || oldWidget.name != widget.name) {
      _reset();
    }
  }

  void _identityChanged() {
    if (mounted && revision != widget.state.accessRevision) _reset();
  }

  void _reset() {
    revision = widget.state.accessRevision;
    generation++;
    setState(() {
      result = null;
      loading = false;
      error = null;
      _openingURL = _openFailureURL = null;
    });
    _load();
  }

  Future<void> _load() async {
    if (loading) return;
    final token = ++generation, owner = widget.state, access = revision;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      // Local read state preserves the native failure (including rate-limit
      // timing), instead of replacing it with AppState.act's nullable response.
      final data = await owner.client.call('rulings.load', {
        'name': widget.name,
      });
      if (!mounted ||
          token != generation ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        result = data;
        loading = false;
      });
    } catch (failure) {
      if (!mounted ||
          token != generation ||
          owner != widget.state ||
          access != widget.state.accessRevision) {
        return;
      }
      setState(() {
        error = failure.toString();
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    super.dispose();
  }

  Future<void> _openRecord(String url) async {
    final route = ModalRoute.of(context), owner = widget.state;
    final access = revision, token = generation;
    if (_openingURL != null ||
        route?.isCurrent != true ||
        access != owner.accessRevision) {
      return;
    }
    setState(() {
      _openingURL = url;
      _openFailureURL = null;
    });
    bool opened;
    try {
      opened = await owner.tryOpenTopic(TopicData({'url': url}));
    } catch (_) {
      opened = false;
    }
    if (!mounted ||
        owner != widget.state ||
        access != owner.accessRevision ||
        token != generation) {
      return;
    }
    setState(() {
      _openingURL = null;
      _openFailureURL = opened ? null : url;
    });
    if (opened && route?.isCurrent == true) Navigator.maybePop(context);
  }

  Widget _record(JsonMap record, {required bool last}) {
    final colors = DeskColors(context);
    final token = generation, owner = widget.state;
    final (title, icon) = switch (stringValue(record['kind'])) {
      'punish' => ('处罚', CupertinoIcons.exclamationmark_shield),
      'reward' => ('奖励', CupertinoIcons.gift),
      _ => ('管理', CupertinoIcons.shield),
    };
    final reason = stringValue(record['reason']);
    final actions = stringValue(record['actions']);
    return Container(
      key: ValueKey('ruling-${record['id']}'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, size: 17, color: colors.secondary),
              Text(
                title,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '#${record['id']}',
                style: DeskTypography.metadata.copyWith(
                  color: colors.secondary,
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 9),
              child: ForumTextSelection(
                child: Text(
                  reason,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ForumTextSelection(
                child: Text(
                  actions,
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          if (stringValue(record['url']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _ToolButton(
                '查看帖子',
                icon: CupertinoIcons.arrow_up_right,
                busy: _openingURL == record['url'],
                onTap: _openingURL != null
                    ? null
                    : () {
                        if (token == generation && owner == widget.state) {
                          _openRecord(stringValue(record['url']));
                        }
                      },
              ),
            ),
          if (_openFailureURL == record['url'])
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _ToolError('未打开帖子，可重试或关闭管理记录。'),
            ),
        ],
      ),
    );
  }

  void _close() {
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.maybePop(context);
  }

  Widget _status(DeskColors colors) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: loading
                ? const CupertinoActivityIndicator(radius: 10)
                : Icon(
                    error == null
                        ? CupertinoIcons.doc_text
                        : CupertinoIcons.exclamationmark_circle,
                    size: 22,
                    color: colors.secondary,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  loading
                      ? '正在查询管理记录…'
                      : error != null
                      ? '暂时无法查询'
                      : '没有查到管理记录',
                  style: DeskTypography.section.copyWith(color: colors.ink),
                ),
                if (error != null) ...[
                  const SizedBox(height: 9),
                  _ToolError(error!),
                  const SizedBox(height: 14),
                  _ToolButton('重试', onTap: _load),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context), records = jsonItems(result?['records']);
    final statusOnly = loading || error != null || records.isEmpty;
    final header = DeskPageHeader(
      title: '管理记录',
      trailing: DeskIcon('关闭', CupertinoIcons.xmark, _close, quiet: true),
    );
    final content = CustomScrollView(
      key: const ValueKey('rulings-content'),
      primary: false,
      // Short feedback has only a few slivers. Records retain the regular
      // lazy viewport instead of measuring every row to size the tool.
      shrinkWrap: statusOnly,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            // Keep the complete query identity available, but let long names
            // scroll rather than push the fixed close action out of a short
            // window when the user increases text size.
            child: Text(
              widget.name,
              style: TextStyle(
                color: colors.secondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ),
        if (statusOnly)
          SliverToBoxAdapter(child: _status(colors))
        else ...[
          SliverToBoxAdapter(
            child: Text(
              records.length >= 200
                  ? '显示最近 ${records.length} 条记录'
                  : '共 ${records.length} 条记录',
              style: TextStyle(color: colors.secondary, fontSize: 12),
            ),
          ),
          SliverList.builder(
            itemCount: records.length,
            itemBuilder: (_, index) =>
                _record(records[index], last: index == records.length - 1),
          ),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!statusOnly) ...[
                  Text(
                    '时间以北京时间显示',
                    style: DeskTypography.metadata.copyWith(
                      color: colors.secondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: () => widget.state.act('external.open', {
                    'url': 'https://github.com/theslugger/ns-seek',
                  }),
                  child: Text(
                    '数据来源：NS Seek 社区查询服务',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    final panel = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: widget.embedded
              ? const EdgeInsets.fromLTRB(22, 18, 16, 6)
              : const EdgeInsets.only(top: 20, bottom: 6),
          child: header,
        ),
        Flexible(
          fit: FlexFit.loose,
          child: Padding(
            padding: widget.embedded
                ? const EdgeInsets.symmetric(horizontal: 22)
                : EdgeInsets.zero,
            child: content,
          ),
        ),
      ],
    );
    if (widget.embedded) return panel;
    return CupertinoPageScaffold(
      backgroundColor: colors.canvas,
      child: SafeArea(
        child: _ToolWidth(
          maxWidth: 760,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: DeskGlassPanel(
              quiet: true,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolWidth extends StatelessWidget {
  const _ToolWidth({required this.maxWidth, required this.child});
  final double maxWidth;
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: child,
      ),
    ),
  );
}

Size _measure(BuildContext context, String label, TextStyle style) =>
    DeskLabelMetrics.of(context, style: style).measure(label);

// The package replaces DefaultTextStyle inside segmented labels. Preserve the
// existing selector sizing until that distinct inheritance path is verified.
Size _measureSegment(BuildContext context, String label, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: label,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final size = painter.size;
  painter.dispose();
  return size;
}

class _ToolButton extends StatelessWidget {
  const _ToolButton(
    this.label, {
    required this.onTap,
    this.icon,
    this.busy = false,
    this.quiet = true,
    this.semanticLabel,
  });
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool busy, quiet;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final size = _measure(context, label, DeskTypography.control);
    return DeskButton(
      label,
      onTap: onTap,
      icon: icon,
      busy: busy,
      quiet: quiet,
      semanticLabel: semanticLabel,
      width: math.max(92.0, size.width + 28 + (icon != null || busy ? 22 : 0)),
      height: math.max(35.0, size.height + 14),
    );
  }
}

class _ToolField extends StatelessWidget {
  const _ToolField({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: TextStyle(
          color: DeskColors(context).secondary,
          fontSize: 13,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 7),
      child,
    ],
  );
}

class _ToolInput extends StatelessWidget {
  const _ToolInput({
    required this.controller,
    required this.label,
    required this.placeholder,
  });
  final TextEditingController controller;
  final String label, placeholder;
  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context);
    return MergeSemantics(
      child: Semantics(
        label: label,
        child: CupertinoTextField(
          controller: controller,
          placeholder: placeholder,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          style: TextStyle(color: colors.ink, fontSize: 14, height: 1.4),
          placeholderStyle: TextStyle(
            color: colors.secondary,
            fontSize: 14,
            height: 1.4,
          ),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.line),
          ),
        ),
      ),
    );
  }
}

class _ToolError extends StatelessWidget {
  const _ToolError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(
        color: DeskColors(context).ink,
        fontSize: 13,
        height: 1.5,
      ),
    ),
  );
}

String _dateTimeLabel(Object? milliseconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(intValue(milliseconds))
      .toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
}

String _dateLabel(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime? _validDate(String text) {
  if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(text)) return null;
  final date = DateTime.tryParse(text);
  return date != null && date.year > 0 && _dateLabel(date) == text
      ? date
      : null;
}
