import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_tool_panel.dart';

const _surface = ValueKey('reader-tool-surface');
const _source = '数据来源：NS Seek 社区查询服务';

/// Strict memory responses exercise the actual tool route and screens. No
/// navigation, publication, external opening or other native work is allowed.
class _Native extends NativeClient {
  _Native()
    : super(methods: MethodChannel('seekdesk.test.rulings-layout.${_next++}'));

  static int _next = 0;
  final rulings = <Completer<JsonMap>>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    switch (method) {
      case 'rulings.load':
        final pending = Completer<JsonMap>();
        rulings.add(pending);
        return pending.future;
      case 'value.currencies':
        return Future.value({
          'items': [
            {'code': 'USD', 'title': 'USD 美元'},
            {'code': 'CNY', 'title': 'CNY 人民币'},
          ],
        });
      case 'value.rate':
        return Future.value({
          'base': arguments['base'],
          'quote': arguments['quote'],
          'rate': '7.2',
          'source': 'Memory rate',
          'asOf': DateTime(2027, 1, 1).millisecondsSinceEpoch,
        });
      default:
        unexpected.add(method);
        throw StateError('Unexpected tool layout call: $method');
    }
  }

  void finishPending() {
    for (final request in rulings) {
      if (!request.isCompleted) request.complete({'records': <JsonMap>[]});
    }
  }
}

class _Fixture {
  _Fixture() {
    state = AppState(client: native)..connecting = false;
    state.domains['session'] = {'account': 'signedIn', 'owner': 1};
    state.domains['extensions'] = {
      'items': [
        {'id': 'rulings', 'active': true},
        {'id': 'value', 'active': true},
      ],
    };
  }

  final native = _Native();
  late final AppState state;
  final controller = ReaderToolPanelController();
  final source = GlobalKey();
}

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  String name = 'Fixture member',
  double scale = 1,
  bool value = false,
  bool standalone = false,
  Size size = const Size(1100, 1000),
}) async {
  final fixture = _Fixture();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    fixture.controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.native.finishPending();
    await _frames(tester);
    fixture.state.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(fixture.native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: CupertinoPageScaffold(
          child: Builder(
            key: fixture.source,
            builder: (_) => const Center(child: Text('Retained reader')),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  if (standalone) {
    unawaited(
      Navigator.of(fixture.source.currentContext!).push<void>(
        CupertinoPageRoute(
          builder: (_) => RulingsScreen(state: fixture.state, name: name),
        ),
      ),
    );
  } else {
    unawaited(
      fixture.controller.show(
        fixture.source.currentContext!,
        state: fixture.state,
        extensionID: value ? 'value' : 'rulings',
        title: value ? '剩余价值计算器' : '管理记录',
        builder: (_) => value
            ? ValueScreen(state: fixture.state, embedded: true)
            : RulingsScreen(state: fixture.state, name: name, embedded: true),
      ),
    );
  }
  await _frames(tester);
  return fixture;
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder get _close => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == '关闭',
);

Finder get _scroll => find.descendant(
  of: find.byType(RulingsScreen),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  ),
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var step = 0; step < 100; step++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    final viewport = tester.getRect(_scroll);
    final delta = target.evaluate().isEmpty
        ? 600.0
        : (tester.getRect(target).center.dy - viewport.center.dy)
              .clamp(-600.0, 600.0)
              .toDouble();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: viewport.center,
        scrollDelta: Offset(0, delta),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await _frames(tester, 2);
  }
  expect(target.hitTestable(), findsOneWidget);
}

void _expectSafeShell(WidgetTester tester, Size window) {
  final rect = tester.getRect(find.byKey(_surface));
  expect(rect.left, greaterThanOrEqualTo(15.9));
  expect(rect.top, greaterThanOrEqualTo(15.9));
  expect(rect.right, lessThanOrEqualTo(window.width - 15.9));
  expect(rect.bottom, lessThanOrEqualTo(window.height - 15.9));
  expect(_close.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loading and empty rulings use one compact glass route', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final screen = tester.element(find.byType(RulingsScreen));
    final surface = tester.element(find.byKey(_surface));
    final close = tester.element(_close);
    final loadingSize = tester.getSize(find.byKey(_surface));
    expect(loadingSize.width, 620);
    expect(loadingSize.height, inInclusiveRange(140, 360));
    expect(find.text('正在查询管理记录…'), findsOneWidget);
    expect(find.text(_source).hitTestable(), findsOneWidget);
    expect(fixture.native.rulings, hasLength(1));
    fixture.native.rulings.single.complete({'records': <JsonMap>[]});
    await _frames(tester);
    final emptySize = tester.getSize(find.byKey(_surface));
    expect(emptySize.height, inInclusiveRange(140, 360));
    expect(emptySize.height, closeTo(loadingSize.height, 16));
    expect(find.text('没有查到管理记录'), findsOneWidget);
    expect(find.text('时间以北京时间显示'), findsNothing);
    expect(tester.element(find.byType(RulingsScreen)), same(screen));
    expect(tester.element(find.byKey(_surface)), same(surface));
    expect(tester.element(_close), same(close));
    expect(fixture.native.rulings, hasLength(1));
    await tester.tap(_close);
    await _frames(tester);
    expect(find.byType(ReaderToolPanel), findsNothing);
    expect(fixture.controller.isOpen, isFalse);
  });

  testWidgets(
    'failure retries in place and normal records keep a lazy viewport',
    (tester) async {
      final fixture = await _mount(tester);
      final screen = tester.element(find.byType(RulingsScreen));
      final close = tester.element(_close);
      fixture.native.rulings.single.completeError(
        const NativeFailure('fixture_rulings', '内存查询暂时失败，请稍后重试。'),
      );
      await _frames(tester);
      expect(find.text('暂时无法查询'), findsOneWidget);
      expect(tester.getSize(find.byKey(_surface)).height, lessThan(440));
      expect(_button('重试').hitTestable(), findsOneWidget);
      await tester.tap(_button('重试'));
      await _frames(tester);
      expect(fixture.native.rulings, hasLength(2));
      expect(find.text('正在查询管理记录…'), findsOneWidget);
      fixture.native.rulings.last.complete({
        'records': List.generate(
          200,
          (index) => <String, Object>{
            'id': index,
            'kind': 'management',
            'reason': 'Local management reason $index',
            'actions': '2026-11-15 12:30:00（北京时间）',
          },
        ),
      });
      await _frames(tester);
      expect(tester.getSize(find.byKey(_surface)), const Size(620, 740));
      expect(tester.element(find.byType(RulingsScreen)), same(screen));
      expect(tester.element(_close), same(close));
      expect(find.byKey(const ValueKey('ruling-199')), findsNothing);
      final rows = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('ruling-');
      });
      expect(rows.evaluate().length, lessThan(40));
      await _reveal(tester, find.text('#199'));
      expect(find.text('#199').hitTestable(), findsOneWidget);
      await _reveal(tester, find.text(_source));
      expect(find.text(_source).hitTestable(), findsOneWidget);
      expect(_close.hitTestable(), findsOneWidget);
      expect(fixture.native.rulings, hasLength(2));
    },
  );

  for (final feedback in ['loading', 'empty', 'error']) {
    testWidgets(
      'short windows keep $feedback and long query details reachable',
      (tester) async {
        final name = List.filled(8, '长用户名 LongUnbrokenMemberName').join(' ');
        final fixture = await _mount(
          tester,
          name: name,
          scale: 2,
          size: const Size(360, 240),
        );
        if (feedback == 'empty') {
          fixture.native.rulings.single.complete({'records': <JsonMap>[]});
        } else if (feedback == 'error') {
          fixture.native.rulings.single.completeError(
            NativeFailure(
              'fixture_long_error',
              List.filled(12, '完整保留错误说明。').join(),
            ),
          );
        }
        await _frames(tester);
        for (final size in [const Size(360, 240), const Size(460, 310)]) {
          await tester.binding.setSurfaceSize(size);
          await _frames(tester);
          _expectSafeShell(tester, size);
          expect(find.text(name), findsOneWidget);
          if (feedback == 'error') {
            await _reveal(tester, _button('重试'));
            expect(_button('重试').hitTestable(), findsOneWidget);
          }
          await _reveal(tester, find.text(_source));
          expect(find.text(_source).hitTestable(), findsOneWidget);
          _expectSafeShell(tester, size);
        }
        expect(fixture.native.rulings, hasLength(1));
        await tester.tap(_close);
        await _frames(tester);
        expect(find.byType(ReaderToolPanel), findsNothing);
      },
    );
  }

  testWidgets(
    'the real value form retains full height, focus and IME on resize',
    (tester) async {
      await _mount(tester, value: true);
      expect(tester.getSize(find.byKey(_surface)), const Size(620, 740));
      final amount = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField && widget.placeholder == '例如 35.99',
      );
      await tester.tap(amount);
      await _frames(tester);
      final element = tester.element(amount);
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      final controller = tester.widget<CupertinoTextField>(amount).controller!;
      controller.value = const TextEditingValue(
        text: '123.45',
        selection: TextSelection(baseOffset: 1, extentOffset: 4),
        composing: TextRange(start: 1, end: 4),
      );
      await _frames(tester);
      await tester.binding.setSurfaceSize(const Size(520, 650));
      await _frames(tester);
      expect(tester.getSize(find.byKey(_surface)), const Size(488, 618));
      expect(tester.element(amount), same(element));
      expect(
        tester.widget<CupertinoTextField>(amount).controller,
        same(controller),
      );
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(
        controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(controller.value.composing, const TextRange(start: 1, end: 4));
      expect(_button('计算剩余价值').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standalone management feedback also keeps its close action fixed',
    (tester) async {
      final fixture = await _mount(tester, standalone: true, scale: 2);
      fixture.native.rulings.single.complete({'records': <JsonMap>[]});
      await _frames(tester, 30);
      final glass = find.descendant(
        of: find.byType(RulingsScreen),
        matching: find.byType(DeskGlassPanel),
      );
      expect(glass, findsOneWidget);
      expect(tester.getSize(glass).height, lessThan(440));
      await tester.binding.setSurfaceSize(const Size(360, 240));
      await _frames(tester);
      expect(tester.getSize(glass).height, lessThanOrEqualTo(192));
      final closeRect = tester.getRect(_close);
      await _reveal(tester, find.text(_source));
      expect(find.text(_source).hitTestable(), findsOneWidget);
      expect(tester.getRect(_close), closeRect);
      expect(_close.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(_close);
      await _frames(tester, 30);
      expect(find.byType(RulingsScreen), findsNothing);
    },
  );
}
