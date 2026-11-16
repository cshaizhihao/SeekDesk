import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_focus_region.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

class _Request {
  _Request(this.args);
  final JsonMap args;
  final done = Completer<JsonMap>();
}

class _Native extends NativeClient {
  _Native() : super(methods: const MethodChannel('seekdesk.test.tools'));
  final calls = <(String, JsonMap)>[];
  final rates = <_Request>[],
      calculations = <_Request>[],
      rulings = <_Request>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) {
    calls.add((method, {...args}));
    switch (method) {
      case 'value.currencies':
        return Future.value({
          'items': [
            {'code': 'USD', 'title': 'USD 美元'},
            {'code': 'CNY', 'title': 'CNY 人民币'},
            {'code': 'JPY', 'title': 'JPY 日元 Japanese Yen — 完整币种名称'},
          ],
        });
      case 'value.rate':
        final request = _Request({...args});
        rates.add(request);
        return request.done.future;
      case 'value.calculate':
        final request = _Request({...args});
        calculations.add(request);
        return request.done.future;
      case 'rulings.load':
        final request = _Request({...args, 'revision': accessRevision});
        rulings.add(request);
        return request.done.future;
      case 'rankings.load':
        return Future.value({
          'period': args['period'],
          'updatedAt': 1700000000,
          'posts': [
            for (var rank = 1; rank <= 3; rank++)
              {
                'id': '$rank',
                'url': 'https://www.nodeseek.com/post-$rank-1',
                'position': rank,
                'title': '窄窗下也完整显示的热榜标题 $rank',
                'author': 'Fixture',
                'replies': 3,
                'views': 100,
              },
          ],
        });
    }
    unexpected.add(method);
    throw StateError('Unexpected tools fixture request: $method');
  }

  void finishPending() {
    for (final request in [...rates, ...calculations, ...rulings]) {
      if (!request.done.isCompleted) request.done.complete({});
    }
  }
}

class _State extends AppState {
  _State(_Native native) : super(client: native);
  void changeIdentity() {
    client.accessRevision++;
    notifyListeners();
  }
}

enum _Screen { value, rulings, rankings }

class _Fixture {
  _Fixture(this.native, this.state, this.width, this.name);
  final _Native native;
  final _State state;
  final ValueNotifier<double> width;
  final ValueNotifier<String> name;
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  _Screen screen = _Screen.value,
  double width = 760,
  double scale = 1,
  String name = 'Fixture',
  Size surfaceSize = const Size(1400, 1200),
  bool desktopTypography = false,
  bool bold = false,
  double? lineHeight,
  double? letterSpacing,
  double? wordSpacing,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  final native = _Native();
  // Each test owns its transport and every pending request.
  final app = _State(native)..connecting = false;
  final pane = ValueNotifier(width), user = ValueNotifier(name);
  final fixture = _Fixture(native, app, pane, user);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    native.finishPending();
    await _frames(tester);
    app.dispose();
    pane.dispose();
    user.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        theme: desktopTypography
            ? const CupertinoThemeData(
                textTheme: CupertinoTextThemeData(
                  textStyle: DeskTypography.base,
                ),
              )
            : null,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
                boldText: bold,
              )
              .applyTextStyleOverrides(
                lineHeightScaleFactorOverride: lineHeight,
                letterSpacingOverride: letterSpacing,
                wordSpacingOverride: wordSpacing,
                paragraphSpacingOverride: null,
              ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: pane,
                builder: (_, width, _) => SizedBox(
                  key: const ValueKey('tools-local-pane'),
                  width: width,
                  height: 1100,
                  child: ValueListenableBuilder<String>(
                    valueListenable: user,
                    builder: (_, name, _) => switch (screen) {
                      _Screen.value => ValueScreen(state: app),
                      _Screen.rulings => RulingsScreen(state: app, name: name),
                      _Screen.rankings => RankingsScreen(state: app),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return fixture;
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 3; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder _field(String placeholder) => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.placeholder == placeholder,
);

Finder _selector(String firstLabel) => find.byWidgetPredicate(
  (widget) =>
      widget is GlassSegmentedControl &&
      widget.segments.first.label == firstLabel,
);

void _expectCompleteButtonLabel(WidgetTester tester, String label) {
  final button = _button(label);
  final text = find.descendant(of: button, matching: find.text(label));
  expect(text, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.text.toPlainText(), label);
  expect(paragraph.didExceedMaxLines, isFalse, reason: '$label is truncated');
  expect(
    paragraph.textSize.height,
    lessThanOrEqualTo(paragraph.size.height + .01),
    reason: '$label has a clipped line box',
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: label.length),
  );
  expect(boxes, isNotEmpty);
  final painted = boxes
      .map((box) => box.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .shift(paragraph.localToGlobal(Offset.zero));
  final bounds = tester.getRect(button).inflate(.01);
  for (final rect in [tester.getRect(text), painted]) {
    expect(
      bounds.contains(rect.topLeft),
      isTrue,
      reason: '$label starts outside',
    );
    expect(
      bounds.contains(rect.bottomRight),
      isTrue,
      reason: '$label ends outside',
    );
  }
  final pane = tester.getRect(find.byKey(const ValueKey('tools-local-pane')));
  expect(bounds.left, greaterThanOrEqualTo(pane.left - .02));
  expect(bounds.right, lessThanOrEqualTo(pane.right + .02));
  expect(bounds.top, greaterThanOrEqualTo(pane.top - .02));
  expect(bounds.bottom, lessThanOrEqualTo(pane.bottom + .02));
}

Future<void> _fill(WidgetTester tester, String placeholder, String text) async {
  final field = _field(placeholder);
  await _reveal(tester, field);
  await tester.enterText(field, text);
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = _button(label);
  await _reveal(tester, button);
  await tester.tap(button);
  await _frames(tester);
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(0);
    await _frames(tester);
    // This helper discovers lazy layout; a drag from the viewport's center can
    // instead activate the vertical cycle selector after large-text reflow.
    for (var step = 0; target.evaluate().isEmpty && step < 50; step++) {
      final next = (position.pixels + 220).clamp(0.0, position.maxScrollExtent);
      if (next <= position.pixels) break;
      position.jumpTo(next);
      await _frames(tester);
    }
    expect(
      target,
      findsOneWidget,
      reason: 'Target must be built within the form scroll range',
    );
  }
  await tester.ensureVisible(target);
  await _frames(tester);
}

void _mode(WidgetTester tester, int mode) => tester
    .widget<GlassSegmentedControl>(_selector('自动汇率'))
    .onSegmentSelected(mode);

const _rate = {
  'rate': '7.2',
  'source': 'Fixture rate',
  'caption': '参考汇率',
  'asOf': 1794747600000,
};
const _estimate = {
  'amount': '10',
  'days': 15,
  'fullCycles': 0,
  'partialDays': 15,
  'partialCycleDays': 30,
};

void main() {
  for (final accessible in [false, true]) {
    testWidgets(
      'value action labels remain complete with ${accessible ? 'large spaced bold' : 'desktop default'} text',
      (tester) async {
        final fixture = await _mount(
          tester,
          width: 800,
          desktopTypography: true,
          scale: accessible ? 2 : 1,
          bold: accessible,
          lineHeight: accessible ? 2 : null,
          letterSpacing: accessible ? 4 : null,
          wordSpacing: accessible ? 6 : null,
        );
        fixture.native.rates.single.done.complete(_rate);
        await _frames(tester);
        await _fill(tester, '例如 35.99', '20');
        final amount = tester
            .widget<CupertinoTextField>(_field('例如 35.99'))
            .controller!;
        await _fill(tester, 'YYYY-MM-DD', '2027-01-01');
        final calculate = _button('计算剩余价值');
        final retainedAction = tester.element(calculate);
        final retainedGlass = tester.state(
          find.descendant(of: calculate, matching: find.byType(GlassButton)),
        );
        for (final width in [800.0, 420.0, 800.0]) {
          fixture.width.value = width;
          await _frames(tester);
          for (final label in ['USD', 'CNY', '计算剩余价值']) {
            await _reveal(tester, _button(label));
            _expectCompleteButtonLabel(tester, label);
          }
          expect(tester.element(calculate), same(retainedAction));
          expect(
            tester.state(
              find.descendant(
                of: calculate,
                matching: find.byType(GlassButton),
              ),
            ),
            same(retainedGlass),
          );
          expect(tester.takeException(), isNull);
        }
        await _tap(tester, '计算剩余价值');
        expect(fixture.native.calculations, hasLength(1));
        expect(tester.widget<DeskButton>(calculate).busy, isTrue);
        _expectCompleteButtonLabel(tester, '计算剩余价值');
        await tester.tap(calculate, warnIfMissed: false);
        await _frames(tester);
        expect(fixture.native.calculations, hasLength(1));
        fixture.native.calculations.single.done.complete({
          ..._estimate,
          'formatted': '72.00 CNY',
        });
        await _frames(tester);
        expect(tester.widget<DeskButton>(calculate).busy, isFalse);
        _expectCompleteButtonLabel(tester, '计算剩余价值');
        expect(amount.text, '20');
        expect(fixture.native.rates, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('automatic manual automatic shares the pending rate response', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    expect(fixture.native.rates, hasLength(1));
    _mode(tester, 1);
    await _frames(tester);
    _mode(tester, 0);
    await _frames(tester);
    expect(fixture.native.rates, hasLength(1));
    fixture.native.rates.single.done.complete(_rate);
    await _frames(tester);
    expect(find.text('1 USD = 7.2 CNY'), findsOneWidget);
    expect(find.textContaining('Fixture rate · 参考汇率 · 更新于'), findsOneWidget);
    expect(find.text('正在读取参考汇率…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'calculate prevents duplicates and a rate refresh invalidates its response',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      await _fill(tester, '例如 35.99', '20');
      await _fill(tester, 'YYYY-MM-DD', '2027-01-01');
      final calculate = tester.widget<DeskButton>(_button('计算剩余价值')).onTap!;
      calculate();
      calculate();
      await _frames(tester);
      expect(fixture.native.calculations, hasLength(1));
      tester
          .widget<DeskIcon>(
            find.byWidgetPredicate(
              (widget) => widget is DeskIcon && widget.label == '刷新汇率',
            ),
          )
          .onTap!();
      await _frames(tester);
      expect(fixture.native.rates, hasLength(2));
      fixture.native.calculations.single.done.complete({
        ..._estimate,
        'formatted': '72.00 CNY',
      });
      await _frames(tester);
      expect(find.text('估算结果'), findsNothing);
      fixture.native.rates.last.done.complete({..._rate, 'rate': '7.3'});
      await _frames(tester);
      expect(find.text('1 USD = 7.3 CNY'), findsOneWidget);
      expect(tester.widget<DeskButton>(_button('计算剩余价值')).busy, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable exchange still calculates original value and retains inputs',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.native.rates.single.done.completeError(
        const NativeFailure('rate_unavailable', '汇率服务暂时不可用，请稍后重试。'),
      );
      await _frames(tester);
      await _fill(tester, '例如 35.99', '20.5');
      await _fill(tester, 'YYYY-MM-DD', '2027-01-01');
      await _fill(tester, '例如 180', '180');
      await _tap(tester, '计算剩余价值');
      final calculation = fixture.native.calculations.single;
      expect(calculation.args['amount'], '20.5');
      expect(calculation.args.containsKey('rate'), isFalse);
      expect(calculation.args.containsKey('asking'), isFalse);
      calculation.done.complete(_estimate);
      await _frames(tester);
      expect(find.text('原币剩余价值'), findsOneWidget);
      expect(find.text('10 USD'), findsOneWidget);
      expect(find.textContaining('当前显示原币估值'), findsOneWidget);
      expect(find.textContaining('15 / 30 个周期'), findsOneWidget);
      expect(
        tester.widget<CupertinoTextField>(_field('例如 35.99')).controller!.text,
        '20.5',
      );
      expect(
        tester.widget<CupertinoTextField>(_field('例如 180')).controller!.text,
        '180',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid normalized dates and manual rates stay local and preserve text',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      await _fill(tester, '例如 35.99', '20');
      await _fill(tester, 'YYYY-MM-DD', '2027-02-30');
      await _tap(tester, '计算剩余价值');
      expect(find.text('请输入有效的到期日期，例如 2027-01-01。'), findsOneWidget);
      expect(fixture.native.calculations, isEmpty);
      expect(
        tester
            .widget<CupertinoTextField>(_field('YYYY-MM-DD'))
            .controller!
            .text,
        '2027-02-30',
      );
      await _fill(tester, 'YYYY-MM-DD', '2027-02-28');
      _mode(tester, 1);
      await _frames(tester);
      await _fill(tester, '1 USD 等于多少 CNY', '0');
      await _tap(tester, '计算剩余价值');
      expect(find.text('请输入大于 0 的手动汇率。'), findsOneWidget);
      expect(fixture.native.calculations, isEmpty);
      await _fill(tester, '1 USD 等于多少 CNY', '7');
      await _tap(tester, '计算剩余价值');
      fixture.native.calculations.single.done.completeError(
        const NativeFailure('fixture', '计算服务暂时不可用，输入已保留。'),
      );
      await _frames(tester);
      expect(find.text('计算服务暂时不可用，输入已保留。'), findsOneWidget);
      expect(
        tester.widget<CupertinoTextField>(_field('例如 35.99')).controller!.text,
        '20',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'management retry shows loading, shares one request and preserves native errors',
    (tester) async {
      final fixture = await _mount(tester, screen: _Screen.rulings);
      fixture.native.rulings.single.done.completeError(
        const NativeFailure('rate_limited', '查询太频繁，请等待 30 秒后重试。'),
      );
      await _frames(tester);
      expect(find.text('查询太频繁，请等待 30 秒后重试。'), findsOneWidget);
      final retry = tester.widget<DeskButton>(_button('重试')).onTap!;
      retry();
      retry();
      await _frames(tester);
      expect(fixture.native.rulings, hasLength(2));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(_button('重试'), findsNothing);
      fixture.native.rulings.last.done.complete({
        'records': [
          {
            'id': 12,
            'kind': 'punish',
            'reason': '原因可选择复制',
            'actions': '2026-11-15 12:30:00（北京时间）',
          },
          {'id': 13, 'kind': 'reward', 'reason': '社区奖励', 'actions': ''},
          {'id': 14, 'kind': 'management', 'reason': '管理操作', 'actions': ''},
        ],
      });
      await _frames(tester);
      expect(find.text('处罚'), findsOneWidget);
      expect(find.text('奖励'), findsOneWidget);
      expect(find.text('管理'), findsOneWidget);
      expect(find.text('#12'), findsOneWidget);
      expect(find.text('共 3 条记录'), findsOneWidget);
      expect(find.text('2026-11-15 12:30:00（北京时间）'), findsOneWidget);
      expect(find.text('数据来源：NS Seek 社区查询服务'), findsOneWidget);
      expect(find.byType(ForumTextSelection), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'management identity and name changes reject previous responses',
    (tester) async {
      final fixture = await _mount(tester, screen: _Screen.rulings);
      fixture.state.changeIdentity();
      await _frames(tester);
      expect(fixture.native.rulings, hasLength(2));
      fixture.native.rulings.first.done.complete({
        'records': [
          {'id': 1, 'kind': 'punish', 'reason': 'Old identity record'},
        ],
      });
      await _frames(tester);
      expect(find.text('Old identity record'), findsNothing);
      fixture.name.value = 'New member';
      await _frames(tester);
      expect(fixture.native.rulings, hasLength(3));
      expect(fixture.native.rulings.last.args['name'], 'New member');
      fixture.native.rulings[1].done.complete({
        'records': [
          {'id': 2, 'kind': 'punish', 'reason': 'Old member record'},
        ],
      });
      fixture.native.rulings.last.done.complete({
        'records': [
          {'id': 3, 'kind': 'reward', 'reason': 'Current member record'},
        ],
      });
      await _frames(tester);
      expect(find.text('Old member record'), findsNothing);
      expect(find.text('Current member record'), findsOneWidget);
      expect(find.text('New member'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resizing keeps the same glass selector state and current input',
    (tester) async {
      final fixture = await _mount(tester, width: 1000, scale: 2);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      _mode(tester, 1);
      await _frames(tester);
      await _fill(tester, '1 USD 等于多少 CNY', '7.25');
      final control = _selector('自动汇率');
      final before = tester.state(control);
      fixture.width.value = 360;
      await _frames(tester);
      expect(tester.state(control), same(before));
      expect(
        tester.widget<GlassSegmentedControl>(control).direction,
        Axis.vertical,
      );
      expect(
        tester
            .widget<CupertinoTextField>(_field('1 USD 等于多少 CNY'))
            .controller!
            .text,
        '7.25',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide estimate groups renewal fields and keeps date and rate actions compact',
    (tester) async {
      final fixture = await _mount(tester, width: 1000);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      final amount = tester.getRect(_field('例如 35.99'));
      final currency = tester.getRect(_button('USD'));
      expect(currency.left - amount.right, closeTo(14, .1));
      expect(currency.bottom, closeTo(amount.bottom, .1));
      expect(amount.width, greaterThan(currency.width));
      final date = tester.getRect(_field('YYYY-MM-DD'));
      expect(date.width, inInclusiveRange(220, 260));
      expect(date.left, closeTo(amount.left, .1));
      final cycles = tester.widget<GlassSegmentedControl>(_selector('月付'));
      expect(cycles.direction, Axis.horizontal);
      expect(cycles.segments.map((segment) => segment.label), [
        '月付',
        '季付',
        '半年付',
        '年付',
        '两年付',
        '三年付',
      ]);
      final refresh = find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '刷新汇率',
      );
      final rate = tester.getRect(find.text('1 USD = 7.2 CNY'));
      expect(tester.getRect(refresh).left - rate.right, closeTo(12, .1));
      final source = tester.getRect(
        find.textContaining('Fixture rate · 参考汇率 · 更新于'),
      );
      expect(source.top, greaterThan(rate.bottom));
      expect(source.left, closeTo(rate.left, .1));
      expect(_button('计算剩余价值').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'renewal reflow preserves focused editor, selection and the cycle control',
    (tester) async {
      final fixture = await _mount(tester, width: 1000);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      await _fill(tester, '例如 35.99', '123.45');
      final field = _field('例如 35.99');
      final originalElement = tester.element(field);
      final editor = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final focus = tester.widget<EditableText>(editor).focusNode;
      final controller = tester.widget<CupertinoTextField>(field).controller!;
      controller.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 4,
      );
      final cycleControl = tester.state(_selector('月付'));
      expect(focus.hasFocus, isTrue);
      fixture.width.value = 360;
      await _frames(tester);
      expect(tester.element(field), same(originalElement));
      expect(
        tester.widget<CupertinoTextField>(field).controller,
        same(controller),
      );
      expect(controller.text, '123.45');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(tester.widget<EditableText>(editor).focusNode, same(focus));
      expect(focus.hasFocus, isTrue);
      expect(tester.state(_selector('月付')), same(cycleControl));
      expect(
        tester.widget<GlassSegmentedControl>(_selector('月付')).direction,
        Axis.vertical,
      );
      expect(
        tester.getRect(_button('USD')).top,
        greaterThan(tester.getRect(field).bottom),
      );
      fixture.width.value = 1000;
      await _frames(tester);
      expect(tester.element(field), same(originalElement));
      expect(tester.state(_selector('月付')), same(cycleControl));
      expect(focus.hasFocus, isTrue);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(fixture.native.rates, hasLength(1));
      expect(fixture.native.calculations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all six shared cycle choices keep their native month values', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final fixture = await _mount(tester);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      await _fill(tester, '例如 35.99', '35.99');
      await _fill(tester, 'YYYY-MM-DD', '2027-01-01');
      for (final option in const {
        '月付': 1,
        '季付': 3,
        '半年付': 6,
        '年付': 12,
        '两年付': 24,
        '三年付': 36,
      }.entries) {
        await _reveal(tester, _selector('月付'));
        final actionable = find.semantics
            .byLabel(option.key)
            .evaluate()
            .where(
              (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
            );
        expect(actionable, hasLength(1));
        final node = actionable.single;
        tester
            .renderObject(_selector('月付'))
            .owner!
            .semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        await _frames(tester);
        expect(
          find.semantics
              .byLabel(option.key)
              .evaluate()
              .where(
                (node) =>
                    node.getSemanticsData().flagsCollection.isSelected ==
                    Tristate.isTrue,
              ),
          hasLength(1),
        );
        await _tap(tester, '计算剩余价值');
        final request = fixture.native.calculations.last;
        expect(request.args['cycle'], option.value);
        expect(request.args['amount'], '35.99');
        expect(request.args['base'], 'USD');
        expect(request.args['quote'], 'CNY');
        request.done.complete({..._estimate, 'formatted': '72.00 CNY'});
        await _frames(tester);
      }
      expect(fixture.native.calculations, hasLength(6));
      expect(fixture.native.rates, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      // Flutter checks handles before package:test runs addTearDown callbacks.
      semantics.dispose();
    }
  });

  testWidgets(
    'cycle keyboard focus survives narrow layout and activates once',
    (tester) async {
      final fixture = await _mount(tester, width: 1000);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      final annual = find.descendant(
        of: _selector('月付'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is GlassFocusRegion && widget.semanticLabel == '年付',
        ),
      );
      final detector = find.descendant(
        of: annual,
        matching: find.byType(FocusableActionDetector),
      );
      final focus = tester.widget<FocusableActionDetector>(detector).focusNode!;
      focus.requestFocus();
      await _frames(tester);
      fixture.width.value = 360;
      await _frames(tester);
      expect(
        tester.widget<FocusableActionDetector>(detector).focusNode,
        same(focus),
      );
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(
        tester.widget<GlassSegmentedControl>(_selector('月付')).selectedIndex,
        3,
      );
      expect(fixture.native.rates, hasLength(1));
      expect(fixture.native.calculations, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _frames(tester);
      final next = find.descendant(
        of: _selector('月付'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is GlassFocusRegion && widget.semanticLabel == '两年付',
        ),
      );
      final nextDetector = find.descendant(
        of: next,
        matching: find.byType(FocusableActionDetector),
      );
      expect(
        tester
            .widget<FocusableActionDetector>(nextDetector)
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'long currency menu titles remain reachable without clearing renewal input',
    (tester) async {
      final fixture = await _mount(
        tester,
        width: 420,
        scale: 2,
        surfaceSize: const Size(420, 1200),
      );
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      await _fill(tester, '例如 35.99', '12.50');
      await _tap(tester, 'USD');
      await tester.pumpAndSettle();
      const title = 'JPY 日元 Japanese Yen — 完整币种名称';
      final choice = find.widgetWithText(CupertinoActionSheetAction, title);
      await tester.ensureVisible(choice);
      await _frames(tester);
      final text = find.descendant(of: choice, matching: find.text(title));
      expect(MediaQuery.textScalerOf(tester.element(text)).scale(14), 28);
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
      final bounds = tester.getRect(choice), glyphs = tester.getRect(text);
      expect(bounds.inflate(.1).contains(glyphs.topLeft), isTrue);
      expect(bounds.inflate(.1).contains(glyphs.bottomRight), isTrue);
      await tester.tap(choice);
      await _frames(tester);
      expect(fixture.native.rates, hasLength(2));
      fixture.native.rates.last.done.complete(_rate);
      await tester.pumpAndSettle();
      expect(_button('JPY'), findsOneWidget);
      expect(fixture.native.rates.last.args['base'], 'JPY');
      expect(
        tester.widget<CupertinoTextField>(_field('例如 35.99')).controller!.text,
        '12.50',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 420.0]) {
    testWidgets('value labels and controls fit $width width at 2x text', (
      tester,
    ) async {
      final fixture = await _mount(tester, width: width, scale: 2);
      fixture.native.rates.single.done.complete(_rate);
      await _frames(tester);
      for (final label in [
        '每期续费金额',
        '续费币种',
        '续费周期',
        '到期日期',
        '折算币种',
        '卖家挂价（CNY）',
      ]) {
        await _reveal(tester, find.text(label));
        expect(find.text(label), findsOneWidget);
      }
      for (final label in ['USD', 'CNY', '计算剩余价值']) {
        final target = _button(label);
        await _reveal(tester, target);
        await _frames(tester);
        final text = find
            .descendant(of: target, matching: find.byType(Text))
            .first;
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        final rect = tester.getRect(target), glyph = tester.getRect(text);
        expect(rect.inflate(.1).contains(glyph.topLeft), isTrue, reason: label);
        expect(
          rect.inflate(.1).contains(glyph.bottomRight),
          isTrue,
          reason: label,
        );
      }
      for (final labels in [
        ['月付', '季付', '半年付', '年付', '两年付', '三年付'],
        ['自动汇率', '手动汇率'],
      ]) {
        final segmented = _selector(labels.first);
        await _reveal(tester, segmented);
        await _frames(tester);
        final controlRect = tester.getRect(segmented);
        for (final label in labels) {
          final text = find
              .descendant(of: segmented, matching: find.text(label))
              .first;
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
            reason: label,
          );
          final rect = tester.getRect(text);
          expect(
            controlRect.inflate(.1).contains(rect.topLeft),
            isTrue,
            reason: label,
          );
          expect(
            controlRect.inflate(.1).contains(rect.bottomRight),
            isTrue,
            reason: label,
          );
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'management long name and records fit $width width at 2x text',
      (tester) async {
        final fixture = await _mount(
          tester,
          screen: _Screen.rulings,
          width: width,
          scale: 2,
          name: '非常长的用户名 LongUnbrokenUserNameForNarrowWindow',
        );
        fixture.native.rulings.single.done.complete({
          'records': [
            {
              'id': 12345,
              'kind': 'management',
              'reason': '完整保留原因，窄窗下按可用宽度自然换行。',
              'actions': '2026-11-15 12:30:00（北京时间）',
            },
          ],
        });
        await _frames(tester);
        final header = find.byType(DeskPageHeader);
        final title = find.descendant(of: header, matching: find.text('管理记录'));
        final close = find.descendant(
          of: header,
          matching: find.byType(DeskIcon),
        );
        expect(
          tester.getRect(title).right,
          lessThanOrEqualTo(tester.getRect(close).left),
        );
        expect(find.text('#12345'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'rankings preserve badges and shared period controls at $width and 2x',
      (tester) async {
        final fixture = await _mount(
          tester,
          screen: _Screen.rankings,
          width: width,
          scale: 2,
        );
        await fixture.state.rankings.refresh(force: true);
        await _frames(tester);
        for (var rank = 1; rank <= 3; rank++) {
          final text = find.text('🔥 $rank');
          expect(text, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(paragraph.didExceedMaxLines, isFalse);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: '🔥 $rank'.length),
          );
          expect(boxes.map((box) => box.top).toSet(), hasLength(1));
        }
        expect(find.text('实时'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
