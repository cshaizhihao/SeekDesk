import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/screens/proxy_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// Every request is handled in memory, including uninstall and OS settings.
/// This fixture never calls a platform service or the forum.
class ExtensionRecoveryFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return await respond?.call(method, args) ?? {};
  }
}

const extensionTitles = {
  'proxy': 'SeekDesk 专用代理',
  'office': '摸鱼老板键',
  'keywords': '关键词监控',
  'attendance': '每日签到',
};

JsonMap extensionSnapshot(
  String id, {
  bool installed = true,
  int? notificationAccess = 1,
  bool systemNotifications = true,
}) => {
  'items': [
    {
      'id': id,
      'title': extensionTitles[id],
      'description': 'Local fixture extension',
      'installed': installed,
      'enabled': installed,
      'active': installed,
    },
  ],
  'settings': {
    'office': {'key': '9', 'title': 'Fixture sheet', 'button': 'Restore'},
    'keywords': {
      'words': 'fixture',
      'systemNotifications': systemNotifications,
      'notificationAccess': ?notificationAccess,
    },
    'attendance': {'automatic': false, 'mode': 'fixed'},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );
  Finder icon(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskIcon && widget.label == label,
  );

  AppState stateFor(ExtensionRecoveryFixture native) {
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'owner': 101};
    return state;
  }

  Future<void> mount(
    WidgetTester tester,
    AppState state, {
    bool proxyOnly = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: proxyOnly
                ? ProxyScreen(state: state)
                : ExtensionsScreen(state: state),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> openDetail(WidgetTester tester) async {
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'extension-card-',
            ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> finishDialog(WidgetTester tester, String choice) async {
    await tester.tap(find.widgetWithText(DeskDialogAction, choice));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets(
    'initial extension failure stays visible after toast expiry and retries',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      var reads = 0;
      native.respond = (method, args) async {
        if (method == 'extensions.list' && ++reads == 1) {
          throw const NativeFailure(
            'fixture_unavailable',
            'Fixture read failed',
          );
        }
        return extensionSnapshot('office');
      };
      final state = stateFor(native);
      await mount(tester, state);
      expect(find.text('暂时无法读取扩展'), findsOneWidget);
      expect(find.text('正在读取扩展'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(state.message, isNull);
      expect(find.text('未能读取扩展信息，请重试。'), findsOneWidget);
      await tester.tap(button('重新加载'));
      await tester.pump();
      await tester.pump();
      expect(reads, 2);
      expect(find.text('摸鱼老板键'), findsOneWidget);
      expect(find.text('暂时无法读取扩展'), findsNothing);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'a successful empty extension response is not an endless loading state',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      native.respond = (method, args) async => {'items': <JsonMap>[]};
      final state = stateFor(native);
      await mount(tester, state);
      expect(find.text('暂无可用扩展'), findsOneWidget);
      expect(find.text('正在读取扩展'), findsNothing);
      expect(button('重新加载'), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'proxy removal needs confirmation and removes the extension without deleting nodes',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      final removed = Completer<JsonMap>();
      native.respond = (method, args) async => switch (method) {
        'extensions.list' => extensionSnapshot('proxy'),
        'extensions.uninstall' => removed.future,
        'proxy.get' => {'nodes': <JsonMap>[], 'startWithApp': false},
        _ => {},
      };
      final state = stateFor(native);
      await mount(tester, state);
      await openDetail(tester);
      expect(find.byType(ProxyScreen), findsOneWidget);
      await tester.ensureVisible(button('移除扩展'));
      await tester.tap(button('移除扩展'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('已保存的节点和订阅会保留'), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'extensions.uninstall'),
        isEmpty,
      );
      await finishDialog(tester, '取消');
      expect(find.byType(ProxyScreen), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'extensions.uninstall'),
        isEmpty,
      );

      await tester.ensureVisible(button('移除扩展'));
      await tester.tap(button('移除扩展'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await finishDialog(tester, '移除');
      expect(tester.widget<DeskButton>(button('移除扩展')).onTap, isNull);
      expect(
        native.calls
            .where((call) => call.$1 == 'extensions.uninstall')
            .single
            .$2,
        {'id': 'proxy'},
      );
      removed.complete(extensionSnapshot('proxy', installed: false));
      await tester.pump();
      expect(find.byType(ProxyScreen), findsNothing);
      expect(button('添加扩展'), findsOneWidget);
      expect(
        native.calls.any(
          (call) =>
              call.$1 == 'proxy.remove' ||
              call.$1 == 'proxy.removeSubscription',
        ),
        false,
      );
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
  );

  testWidgets('account changes invalidate an open removal confirmation', (
    tester,
  ) async {
    final native = ExtensionRecoveryFixture();
    native.respond = (method, args) async =>
        method == 'extensions.list' ? extensionSnapshot('proxy') : {};
    final state = stateFor(native);
    await mount(tester, state);
    await openDetail(tester);
    await tester.ensureVisible(button('移除扩展'));
    await tester.tap(button('移除扩展'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    native.accessRevision++;
    await finishDialog(tester, '移除');
    expect(
      native.calls.where((call) => call.$1 == 'extensions.uninstall'),
      isEmpty,
    );
    await cleanup(tester, state);
  });

  for (final id in ['proxy', 'office', 'keywords', 'attendance']) {
    testWidgets(
      '$id catalog navigates and detail exposes the named extension switch',
      (tester) async {
        final handle = tester.ensureSemantics();
        final native = ExtensionRecoveryFixture();
        native.respond = (method, args) async =>
            method == 'extensions.list' ? extensionSnapshot(id) : {};
        final state = stateFor(native);
        await mount(tester, state);
        final label = '启用${extensionTitles[id]}扩展';
        expect(find.bySemanticsLabel(label), findsNothing);
        expect(
          find.byKey(ValueKey('extension-card-$id')).hitTestable(),
          findsOneWidget,
        );
        await openDetail(tester);
        expect(find.bySemanticsLabel(label), findsOneWidget);
        if (id == 'keywords') {
          expect(find.bySemanticsLabel('关键词系统通知'), findsOneWidget);
        }
        if (id == 'attendance') {
          final automaticSwitch = find.byWidgetPredicate(
            (widget) => widget is GlassSwitch && widget.semanticLabel == '自动签到',
          );
          expect(automaticSwitch, findsOneWidget);
          // The adjacent visible row label has the same text. Check the
          // control's own semantics, rather than also counting that label.
          expect(
            find.descendant(
              of: automaticSwitch,
              matching: find.bySemanticsLabel('自动签到'),
            ),
            findsOneWidget,
          );
        }
        if (id == 'proxy') {
          expect(find.bySemanticsLabel('启动时自动连接代理'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
        handle.dispose();
      },
    );
  }

  testWidgets(
    'boss key documents Command and Shift even when the character field is filled',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      native.respond = (method, args) async => extensionSnapshot('office');
      final state = stateFor(native);
      await mount(tester, state);
      await openDetail(tester);
      final shortcut = tester
          .widgetList<CupertinoTextField>(find.byType(CupertinoTextField))
          .last;
      expect(shortcut.controller?.text, '9');
      expect(shortcut.placeholder, '快捷键字符（配合 ⌘⇧）');
      expect(find.text('同时按下 ⌘⇧ 和该字符即可切换工作表。'), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  const permissions = <(int?, String)>[
    (null, '系统通知权限暂不可用'),
    (0, '尚未请求系统权限'),
    (1, '系统未允许通知'),
    (2, '系统已允许通知'),
    (3, '系统仅允许静默通知'),
    (4, '系统已临时允许通知'),
  ];
  for (final (access, label) in permissions) {
    testWidgets(
      'notification preference does not replace actual system permission $access',
      (tester) async {
        final native = ExtensionRecoveryFixture();
        native.respond = (method, args) async =>
            extensionSnapshot('keywords', notificationAccess: access);
        final state = stateFor(native);
        await mount(tester, state);
        await openDetail(tester);
        expect(find.text(label), findsOneWidget);
        final toggle = tester
            .widgetList<GlassSwitch>(find.byType(GlassSwitch))
            .singleWhere((widget) => widget.semanticLabel == '关键词系统通知');
        expect(toggle.value, true);
        expect(
          native.calls.any(
            (call) =>
                call.$1 == 'settings.openNotifications' ||
                call.$1 == 'extensions.configure',
          ),
          false,
        );
        await cleanup(tester, state);
      },
    );
  }

  testWidgets(
    'system settings opens only on click with no URL and permission refreshes on return',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      var access = 1;
      native.respond = (method, args) async => switch (method) {
        'extensions.list' => extensionSnapshot(
          'keywords',
          notificationAccess: access,
        ),
        'settings.openNotifications' => {'opened': true},
        _ => {},
      };
      final state = stateFor(native);
      await mount(tester, state);
      await openDetail(tester);
      expect(find.text('系统未允许通知'), findsOneWidget);
      expect(
        native.calls.any((call) => call.$1 == 'settings.openNotifications'),
        false,
      );
      await tester.ensureVisible(button('系统通知设置'));
      await tester.tap(button('系统通知设置'));
      await tester.pump();
      final opened = native.calls.where(
        (call) => call.$1 == 'settings.openNotifications',
      );
      expect(opened, hasLength(1));
      expect(opened.single.$2, isEmpty);
      expect(find.text('系统未允许通知'), findsOneWidget);

      access = 2;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.text('系统已允许通知'), findsOneWidget);
      expect(
        native.calls.any((call) => call.$1 == 'extensions.configure'),
        false,
      );
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'failed system-settings launch shows a persistent inline retryable error',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      native.respond = (method, args) async {
        if (method == 'settings.openNotifications') {
          throw const NativeFailure(
            'fixture_settings_failure',
            'Fixture settings could not open',
          );
        }
        return extensionSnapshot('keywords');
      };
      final state = stateFor(native);
      await mount(tester, state);
      await openDetail(tester);
      await tester.ensureVisible(button('系统通知设置'));
      await tester.tap(button('系统通知设置'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Fixture settings could not open'), findsOneWidget);
      expect(tester.widget<DeskButton>(button('系统通知设置')).onTap, isNotNull);
      expect(find.text('系统未允许通知'), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'manual notification permission refresh retains state on failure',
    (tester) async {
      final native = ExtensionRecoveryFixture();
      var fail = false;
      native.respond = (method, args) async {
        if (method == 'extensions.list' && fail) {
          throw const NativeFailure(
            'fixture_permission_failure',
            'Fixture permission read failed',
          );
        }
        return extensionSnapshot('keywords');
      };
      final state = stateFor(native);
      await mount(tester, state);
      await openDetail(tester);
      fail = true;
      await tester.ensureVisible(icon('刷新通知权限'));
      await tester.tap(icon('刷新通知权限'));
      await tester.pump();
      expect(find.text('系统未允许通知'), findsOneWidget);
      expect(find.text('暂时无法刷新系统通知权限，请重试。'), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  testWidgets('standalone proxy startup switch has its own accessible name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final native = ExtensionRecoveryFixture();
    native.respond = (method, args) async => {
      'startWithApp': true,
      'nodes': <JsonMap>[],
    };
    final state = stateFor(native);
    state.domains['proxy'] = {'startWithApp': true, 'nodes': <JsonMap>[]};
    await mount(tester, state, proxyOnly: true);
    expect(find.bySemanticsLabel('启动时自动连接代理'), findsOneWidget);
    expect(
      tester
          .widgetList<GlassSwitch>(find.byType(GlassSwitch))
          .singleWhere((widget) => widget.semanticLabel == '启动时自动连接代理')
          .value,
      true,
    );
    await cleanup(tester, state);
    handle.dispose();
  });
}
