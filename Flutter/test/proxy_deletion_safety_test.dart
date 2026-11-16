import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/proxy_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// All data and mutations stay in this fixture. No platform proxy or saved
/// user nodes/subscriptions are read, updated, or deleted.
class ProxyDeletionFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Completer<void>? removalGate;
  final nodes = <JsonMap>[
    {
      'id': 'node-target',
      'name': 'Standalone fixture',
      'protocolName': 'SOCKS5',
      'host': '127.0.0.1',
      'port': 18881,
    },
    {
      'id': 'node-subscription-target',
      'subscriptionId': 'subscription-target',
      'name': 'Target subscription fixture',
      'protocolName': 'SOCKS5',
      'host': '127.0.0.1',
      'port': 18882,
    },
    {
      'id': 'node-keep',
      'subscriptionId': 'subscription-keep',
      'name': 'Preserved subscription fixture',
      'protocolName': 'SOCKS5',
      'host': '127.0.0.1',
      'port': 18883,
    },
  ];
  final subscriptions = <JsonMap>[
    {'id': 'subscription-target', 'name': 'Target fixture', 'nodeCount': 1},
    {'id': 'subscription-keep', 'name': 'Preserved fixture', 'nodeCount': 1},
  ];

  JsonMap get snapshot => {
    'available': true,
    'nodes': nodes.map((node) => {...node}).toList(),
    'subscriptions': subscriptions.map((item) => {...item}).toList(),
    'startWithApp': false,
  };

  Iterable<(String, JsonMap)> get removals => calls.where(
    (call) =>
        call.$1 == 'proxy.remove' || call.$1 == 'proxy.removeSubscription',
  );

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    if (method == 'proxy.remove' || method == 'proxy.removeSubscription') {
      final gate = removalGate;
      if (gate != null) await gate.future;
      final id = args['id'];
      if (method == 'proxy.remove') {
        nodes.removeWhere((node) => node['id'] == id);
      } else {
        subscriptions.removeWhere((item) => item['id'] == id);
        nodes.removeWhere((node) => node['subscriptionId'] == id);
      }
    }
    return snapshot;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder subscriptionDeletion() => find.byWidgetPredicate(
    (widget) => widget is DeskIcon && widget.label == '删除订阅',
  );

  Finder nodeMenu() => find.byType(GlassMenu);

  VoidCallback deletionCallback(WidgetTester tester, bool subscription) =>
      subscription
      ? tester.widget<DeskIcon>(subscriptionDeletion().first).onTap!
      : tester
            .widget<GlassMenu>(nodeMenu().first)
            .items
            .whereType<GlassMenuItem>()
            .singleWhere((item) => item.title == '删除节点')
            .onTap;

  bool deletionEnabled(WidgetTester tester, bool subscription) => subscription
      ? tester
            .widgetList<DeskIcon>(subscriptionDeletion())
            .every((icon) => icon.onTap != null)
      : tester
            .widgetList<GlassMenu>(nodeMenu())
            .every(
              (menu) => menu.items
                  .whereType<GlassMenuItem>()
                  .singleWhere((item) => item.title == '删除节点')
                  .enabled,
            );

  Future<ValueNotifier<bool>> mount(WidgetTester tester, AppState state) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.binding.setSurfaceSize(const Size(1100, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, shown, child) => shown
                  ? ProxyScreen(state: state)
                  : const Text('Fixture route closed'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return visible;
  }

  AppState stateFor(ProxyDeletionFixture native) {
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'owner': 101};
    state.domains['proxy'] = native.snapshot;
    return state;
  }

  Future<void> openConfirmation(WidgetTester tester, bool subscription) async {
    if (subscription) {
      final target = subscriptionDeletion().first;
      await tester.ensureVisible(target);
      await tester.tap(target);
    } else {
      final trigger = find
          .byWidgetPredicate(
            (widget) => widget is DeskIcon && widget.label == '节点更多操作',
          )
          .first;
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassMenuItem && widget.title == '删除节点',
        ),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DeskDialog), findsOneWidget);
  }

  Future<void> finishDialog(WidgetTester tester, String choice) async {
    await tester.tap(find.widgetWithText(DeskDialogAction, choice));
    // CupertinoDialogRoute uses a spring simulation whose settling time can
    // exceed its nominal duration. Do not mistake the exiting route for a
    // newly opened confirmation while a fixture mutation is still pending.
    await tester.pumpAndSettle(const Duration(milliseconds: 25));
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
  }

  void expectUnchanged(ProxyDeletionFixture native, JsonMap before) {
    expect(native.removals, isEmpty);
    expect(native.snapshot, before);
  }

  for (final subscription in [false, true]) {
    final kind = subscription ? 'subscription' : 'node';
    final method = subscription ? 'proxy.removeSubscription' : 'proxy.remove';
    final id = subscription ? 'subscription-target' : 'node-target';

    testWidgets('$kind deletion cancellation preserves every fixture item', (
      tester,
    ) async {
      final native = ProxyDeletionFixture();
      final before = native.snapshot;
      final state = stateFor(native);
      await mount(tester, state);
      await openConfirmation(tester, subscription);
      await finishDialog(tester, '取消');
      expectUnchanged(native, before);
      expect(deletionEnabled(tester, subscription), isTrue);
      await cleanup(tester, state);
    });

    testWidgets('$kind deletion confirmation is invalid after account change', (
      tester,
    ) async {
      final native = ProxyDeletionFixture();
      final before = native.snapshot;
      final state = stateFor(native);
      await mount(tester, state);
      await openConfirmation(tester, subscription);
      native.accessRevision++;
      state.domains['session'] = {'account': 'signedIn', 'owner': 202};
      await finishDialog(tester, '删除');
      expectUnchanged(native, before);
      expect(deletionEnabled(tester, subscription), isTrue);
      await cleanup(tester, state);
    });

    testWidgets('$kind deletion confirmation cannot act after screen disposal', (
      tester,
    ) async {
      final native = ProxyDeletionFixture();
      final before = native.snapshot;
      final state = stateFor(native);
      final visible = await mount(tester, state);
      await openConfirmation(tester, subscription);
      // Keep the root Navigator/dialog alive while removing its source screen.
      visible.value = false;
      await tester.pump();
      expect(find.byType(ProxyScreen), findsNothing);
      await finishDialog(tester, '删除');
      expectUnchanged(native, before);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    });

    testWidgets('$kind confirmation deletes only its intended fixture target', (
      tester,
    ) async {
      final native = ProxyDeletionFixture();
      final state = stateFor(native);
      await mount(tester, state);
      await openConfirmation(tester, subscription);
      await finishDialog(tester, '删除');
      expect(native.removals.single.$1, method);
      expect(native.removals.single.$2, {'id': id});
      expect(
        native.nodes.map((node) => node['id']),
        subscription
            ? ['node-target', 'node-keep']
            : ['node-subscription-target', 'node-keep'],
      );
      expect(
        native.subscriptions.map((item) => item['id']),
        subscription
            ? ['subscription-keep']
            : ['subscription-target', 'subscription-keep'],
      );
      expect(state.domain('proxy'), native.snapshot);
      await cleanup(tester, state);
    });

    testWidgets(
      '$kind repeated callbacks cannot stack dialogs or delete twice',
      (tester) async {
        final native = ProxyDeletionFixture();
        final gate = Completer<void>();
        native.removalGate = gate;
        final state = stateFor(native);
        await mount(tester, state);
        final callback = deletionCallback(tester, subscription);
        callback();
        callback();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(DeskDialog), findsOneWidget);
        expect(native.removals, isEmpty);
        await finishDialog(tester, '删除');
        callback();
        await tester.pump();
        expect(find.byType(DeskDialog), findsNothing);
        expect(native.removals.single.$1, method);
        expect(native.removals.single.$2, {'id': id});
        for (final type in [false, true]) {
          expect(deletionEnabled(tester, type), isFalse);
        }
        gate.complete();
        await tester.pump();
        await tester.pump();
        expect(native.removals, hasLength(1));
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      },
    );
  }
}
