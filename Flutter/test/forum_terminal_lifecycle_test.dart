import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_terminal_report.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _report = 'Account-bound terminal measurement';

class _TerminalNative extends NativeClient {
  final eventsStream = StreamController<JsonMap>.broadcast(sync: true);

  @override
  Stream<JsonMap> get snapshots => eventsStream.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'bootstrap') {
      return {
        'session': {'account': 'signedIn', 'owner': 1, 'accessRevision': 0},
      };
    }
    throw StateError('Unexpected terminal operation $method');
  }

  void changeAccount() => eventsStream.add({
    'domain': 'session',
    'accessRevision': accessRevision + 1,
    'data': {'account': 'signedIn', 'owner': 2},
  });
}

class _Routes extends NavigatorObserver {
  final pushes = <Route<dynamic>>[];
  final removals = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removals.add(route);
  }
}

class _Harness {
  final native = _TerminalNative();
  late final state = AppState(client: native);
  final key = GlobalKey<NavigatorState>();
  final routes = _Routes();
  final sourceVisible = ValueNotifier(true);
  final copies = <String>[];
  final clipboard = <Completer<void>>[];
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder _reportText() => find.byWidgetPredicate(
  (widget) => widget is Text && widget.textSpan?.toPlainText() == _report,
  skipOffstage: false,
);

Future<_Harness> _mount(WidgetTester tester) async {
  final fixture = _Harness();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        fixture.copies.add(stringValue(jsonMap(call.arguments)['text']));
        final response = Completer<void>();
        fixture.clipboard.add(response);
        await response.future;
      }
      return null;
    },
  );
  await fixture.state.connect();
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        navigatorKey: fixture.key,
        navigatorObservers: [fixture.routes],
        home: CupertinoPageScaffold(
          child: ValueListenableBuilder<bool>(
            valueListenable: fixture.sourceVisible,
            builder: (context, visible, _) => SingleChildScrollView(
              child: Column(
                children: [
                  const Text('Reader remains open'),
                  if (visible)
                    NativeTerminalReport(
                      state: fixture.state,
                      rows: const [
                        [
                          {'text': _report, 'foreground': '#d6e0f0'},
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    fixture.state.dispose();
    fixture.sourceVisible.dispose();
    await fixture.native.eventsStream.close();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  return fixture;
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_button('放大查看'));
  await tester.pumpAndSettle();
  expect(find.text('测评终端'), findsOneWidget);
}

Future<Route<void>> _cover(WidgetTester tester, _Harness fixture) async {
  final route = CupertinoDialogRoute<void>(
    context: fixture.key.currentContext!,
    builder: (_) => const CupertinoAlertDialog(title: Text('Unrelated dialog')),
  );
  unawaited(fixture.key.currentState!.push(route));
  await tester.pumpAndSettle();
  return route;
}

void main() {
  testWidgets('inline copy announces success only after clipboard completion', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final action = tester.widget<DeskButton>(_button('复制报告')).onTap!;
    action();
    action();
    await tester.pump();
    expect(fixture.copies, [_report]);
    expect(fixture.state.message, isNull);
    expect(tester.widget<DeskButton>(_button('复制报告')).busy, isTrue);
    fixture.clipboard.single.complete();
    await tester.pumpAndSettle();
    expect(fixture.state.message, '报告已复制');
    expect(tester.widget<DeskButton>(_button('复制报告')).busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded copy failure is recoverable and never claims success', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await _expand(tester);
    await tester.tap(_button('复制报告'));
    await tester.pump();
    expect(fixture.state.message, isNull);
    fixture.clipboard.single.completeError(
      PlatformException(code: 'denied', message: 'private platform detail'),
    );
    await tester.pumpAndSettle();
    expect(fixture.state.message, '报告复制失败，请重试。');
    expect(tester.widget<DeskButton>(_button('复制报告')).busy, isFalse);
    await tester.tap(_button('复制报告'));
    await tester.pump();
    fixture.clipboard.last.complete();
    await tester.pumpAndSettle();
    expect(fixture.state.message, '报告已复制');
    expect(fixture.copies, [_report, _report]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate open gestures create exactly one expanded route', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final action = tester.widget<DeskButton>(_button('放大查看')).onTap!;
    action();
    action();
    await tester.pumpAndSettle();
    expect(fixture.routes.pushes, hasLength(2));
    expect(find.text('测评终端'), findsOneWidget);
    await tester.tap(_button('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('Reader remains open'), findsOneWidget);
    expect(tester.widget<DeskButton>(_button('放大查看')).onTap, isNotNull);
    await _expand(tester);
    expect(fixture.routes.pushes, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account changes remove the viewer and clear retained source text',
    (tester) async {
      final fixture = await _mount(tester);
      await _expand(tester);
      final viewer = fixture.routes.pushes.last;
      fixture.native.changeAccount();
      await tester.pump();
      expect(_reportText(), findsNothing);
      await tester.pumpAndSettle();
      expect(fixture.routes.removals, contains(viewer));
      expect(find.text('测评终端', skipOffstage: false), findsNothing);
      expect(_reportText(), findsNothing);
      expect(find.text('Reader remains open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalidateAccount in [true, false]) {
    testWidgets(
      '${invalidateAccount ? 'account change' : 'source disposal'} removes only its own covered viewer',
      (tester) async {
        final fixture = await _mount(tester);
        await _expand(tester);
        final viewer = fixture.routes.pushes.last;
        final close = tester.widget<DeskButton>(_button('关闭')).onTap!;
        final cover = await _cover(tester, fixture);
        close();
        await tester.pump();
        expect(cover.isCurrent, isTrue);
        expect(viewer.isActive, isTrue);
        if (invalidateAccount) {
          fixture.native.changeAccount();
        } else {
          fixture.sourceVisible.value = false;
        }
        await tester.pump();
        await tester.pumpAndSettle();
        expect(fixture.routes.removals, contains(viewer));
        expect(fixture.routes.removals, isNot(contains(cover)));
        expect(cover.isCurrent, isTrue);
        expect(find.text('Unrelated dialog'), findsOneWidget);
        expect(_reportText(), findsNothing);
        fixture.key.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Reader remains open'), findsOneWidget);
        expect(find.text('测评终端', skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final expanded in [false, true]) {
    for (final failure in [false, true]) {
      testWidgets(
        '${expanded ? 'expanded' : 'inline'} copy ${failure ? 'failure' : 'success'} after account change has no feedback',
        (tester) async {
          final fixture = await _mount(tester);
          if (expanded) await _expand(tester);
          await tester.tap(_button('复制报告'));
          await tester.pump();
          fixture.native.changeAccount();
          await tester.pump();
          if (failure) {
            fixture.clipboard.single.completeError(
              PlatformException(code: 'late', message: 'late private detail'),
            );
          } else {
            fixture.clipboard.single.complete();
          }
          await tester.pumpAndSettle();
          expect(fixture.state.message, isNull);
          expect(_reportText(), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('copy completed after its viewer closes produces no late toast', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await _expand(tester);
    await tester.tap(_button('复制报告'));
    await tester.pump();
    await tester.tap(_button('关闭'));
    await tester.pumpAndSettle();
    fixture.clipboard.single.complete();
    await tester.pumpAndSettle();
    expect(fixture.state.message, isNull);
    expect(find.text('Reader remains open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline copy completed after source disposal produces no toast', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.tap(_button('复制报告'));
    await tester.pump();
    fixture.sourceVisible.value = false;
    await tester.pumpAndSettle();
    fixture.clipboard.single.complete();
    await tester.pumpAndSettle();
    expect(fixture.state.message, isNull);
    expect(tester.takeException(), isNull);
  });
}
