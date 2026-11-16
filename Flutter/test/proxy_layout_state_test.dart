import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/proxy_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// Local synthetic snapshots only. Never calls a platform/network service.
class _ProxyNative extends NativeClient {
  JsonMap snapshot = _snapshot();
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    if (response != null) return response!(method, args);
    return snapshot;
  }
}

JsonMap _snapshot({
  int count = 1,
  bool available = true,
  bool enabled = false,
}) => {
  'available': available,
  'enabled': enabled,
  'running': false,
  'starting': false,
  'selectedId': count > 0 ? 'node-0' : null,
  'nodes': [
    for (var i = 0; i < count; i++)
      {
        'id': 'node-$i',
        'name': '本机夹具节点 $i 很长的中文名称 Mixed Latin Name',
        'protocolName': 'SOCKS5',
        'host': 'local-fixture-$i.example.invalid',
        'port': 18881,
        'subscriptionId': 'fixture-sub',
        'latency': {'state': 'idle'},
      },
  ],
  'subscriptions': [
    {
      'id': 'fixture-sub',
      'name': '测试订阅 Fixture source',
      'nodeCount': count,
      'updatedAt': 1760000000000,
    },
  ],
  'supportedProtocols': ['socks5', 'vless'],
};

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder get _source => find.byKey(const ValueKey('proxy-source'));

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<(AppState, ValueNotifier<double>)> _mount(
  WidgetTester tester,
  _ProxyNative native, {
  double width = 760,
  double scale = 1,
  JsonMap? extensions,
  Widget? header,
  bool withExtensionOverlays = false,
  bool disableAnimations = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 800));
  final paneWidth = ValueNotifier(width);
  final state = AppState(client: native);
  state.domains['proxy'] = native.snapshot;
  if (extensions != null) state.domains['extensions'] = extensions;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
    state.dispose();
    paneWidth.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: disableAnimations,
          ),
          child: withExtensionOverlays
              ? ExtensionOverlays(state: state, child: child!)
              : child!,
        ),
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: paneWidth,
              child: ProxyScreen(state: state, header: header),
              builder: (context, width, child) =>
                  SizedBox(width: width, height: 640, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return (state, paneWidth);
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.ensureVisible(_button('添加节点 / 订阅'));
  await _frames(tester);
  await tester.tap(_button('添加节点 / 订阅'));
  await _frames(tester);
}

void _publish(AppState state, JsonMap proxy, {JsonMap? extensions}) {
  state.domains['proxy'] = proxy;
  if (extensions != null) state.domains['extensions'] = extensions;
  state.showMessage('Fixture state changed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [360.0, 420.0, 452.0, 453.0, 480.0, 850.0, 960.0]) {
    testWidgets(
      'proxy local width $width keeps nodes and bounded editor usable',
      (tester) async {
        final native = _ProxyNative()..snapshot = _snapshot(count: 9);
        await _mount(
          tester,
          native,
          width: width,
          scale: width == 360 ? 1.6 : 1.3,
        );
        expect(find.text('我的节点 · 9'), findsOneWidget);
        expect(find.byType(CupertinoSearchTextField), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(Size(width, 800));
        await _frames(tester);
        await _openEditor(tester);
        final field = tester.widget<CupertinoTextField>(_source);
        expect(field.obscureText, isFalse);
        expect(field.minLines, 2);
        expect(field.maxLines, 3);
        expect(
          tester.getSize(find.byType(GlassSegmentedControl)).width,
          lessThanOrEqualTo(220),
        );
        final panel = tester.getRect(_source);
        expect(panel.left, greaterThanOrEqualTo(0));
        expect(panel.right, lessThanOrEqualTo(width));
        await tester.enterText(_source, 'socks5://local.invalid:18881');
        await _frames(tester);
        expect(_button('识别并预览').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(native.calls.every((call) => call.$1 == 'proxy.get'), isTrue);
      },
    );
  }

  testWidgets(
    'bootstrap empty nodes remain loading until lazy storage read completes',
    (tester) async {
      final native = _ProxyNative()..snapshot = _snapshot(count: 0);
      final get = Completer<JsonMap>();
      native.response = (method, args) =>
          method == 'proxy.get' ? get.future : Future.value({});
      await _mount(tester, native);
      expect(find.text('正在读取节点…'), findsOneWidget);
      expect(find.text('还没有节点'), findsNothing);
      expect(tester.widget<DeskButton>(_button('添加节点 / 订阅')).onTap, isNull);
      get.complete(_snapshot(count: 2));
      await _frames(tester);
      expect(find.text('我的节点 · 2'), findsOneWidget);
      expect(find.text('正在读取节点…'), findsNothing);
      expect(tester.widget<DeskButton>(_button('添加节点 / 订阅')).onTap, isNotNull);
    },
  );

  testWidgets('failed initial read shows retry instead of an empty node list', (
    tester,
  ) async {
    final native = _ProxyNative()..snapshot = _snapshot(count: 0);
    native.response = (method, args) async =>
        throw const NativeFailure('fixture', 'Unavailable');
    await _mount(tester, native);
    expect(find.text('未能读取代理信息，请重试。'), findsOneWidget);
    expect(find.text('还没有节点'), findsNothing);
    expect(_button('重新读取'), findsOneWidget);
    expect(tester.widget<DeskButton>(_button('添加节点 / 订阅')).onTap, isNull);
  });

  for (final stale in [true, false]) {
    testWidgets(
      'inactive proxy blocks pointer keyboard semantics with stale snapshot $stale',
      (tester) async {
        final native = _ProxyNative()..snapshot = _snapshot(available: stale);
        final (state, _) = await _mount(
          tester,
          native,
          extensions: {
            'items': [
              {
                'id': 'proxy',
                'installed': true,
                'enabled': false,
                'active': false,
              },
            ],
          },
        );
        final semantics = tester.ensureSemantics();
        await _frames(tester);
        try {
          expect(find.text('扩展已停用'), findsOneWidget);
          expect(tester.widget<DeskButton>(_button('添加节点 / 订阅')).onTap, isNull);
          final switchWidget = tester
              .widgetList<GlassSwitch>(find.byType(GlassSwitch))
              .first;
          switchWidget.onChanged(
            true,
          ); // Even a retained callback cannot bypass disablement.
          await tester.tap(find.byType(GlassSwitch).first, warnIfMissed: false);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await _frames(tester);
          final node = find.byKey(const ValueKey('proxy-select-node-0'));
          await tester.ensureVisible(node);
          await _frames(tester);
          final data = tester.getSemantics(node).getSemanticsData();
          expect(data.flagsCollection.isEnabled, Tristate.isFalse);
          expect(data.hasAction(SemanticsAction.tap), isFalse);
          final menu = tester.widget<GlassMenu>(find.byType(GlassMenu).first);
          for (final action in menu.items.whereType<GlassMenuItem>()) {
            action.onTap();
          }
          await _frames(tester);
          expect(native.calls.every((call) => call.$1 == 'proxy.get'), isTrue);
          expect(state.domain('proxy')['available'], stale);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('disabled extension retains stop but cannot start or configure', (
    tester,
  ) async {
    final native = _ProxyNative()
      ..snapshot = _snapshot(available: false, enabled: true);
    await _mount(tester, native);
    final switchWidget = tester.widget<GlassSwitch>(
      find.byType(GlassSwitch).first,
    );
    switchWidget.onChanged(false);
    await _frames(tester);
    expect(native.calls.where((call) => call.$1 == 'proxy.stop'), hasLength(1));
    switchWidget.onChanged(true);
    await _frames(tester);
    expect(native.calls.where((call) => call.$1 == 'proxy.start'), isEmpty);
  });

  testWidgets(
    'failed connection offers reconnect and keeps switch while starting',
    (tester) async {
      final native = _ProxyNative()
        ..snapshot = {..._snapshot(enabled: true), 'issue': 'Fixture failure'};
      final (state, _) = await _mount(tester, native);
      expect(tester.widget<DeskButton>(_button('重新连接')).onTap, isNotNull);
      expect(tester.widget<DeskButton>(_button('检测连接')).onTap, isNull);
      final before = tester.getRect(find.byType(GlassSwitch).first);
      _publish(state, {...native.snapshot, 'starting': true});
      await _frames(tester);
      expect(find.text('正在连接'), findsOneWidget);
      expect(tester.getRect(find.byType(GlassSwitch).first), before);
      expect(tester.widget<DeskButton>(_button('重新连接')).onTap, isNull);
      expect(native.calls.every((call) => call.$1 == 'proxy.get'), isTrue);
    },
  );

  testWidgets(
    'editor resize preserves controllers selection composing and plaintext',
    (tester) async {
      final native = _ProxyNative();
      final (_, width) = await _mount(tester, native, width: 960);
      await _openEditor(tester);
      expect(
        tester
            .getSize(
              find.ancestor(of: _source, matching: find.byType(DeskGlassPanel)),
            )
            .height,
        lessThan(450),
        reason:
            'An empty editor should not reserve space for an import preview.',
      );
      final original = tester.widget<CupertinoTextField>(_source).controller!;
      const input = TextEditingValue(
        text: 'socks5://local.invalid/测试',
        selection: TextSelection.collapsed(offset: 24),
        composing: TextRange(start: 22, end: 24),
      );
      original.value = input;
      await _frames(tester);
      width.value = 360;
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await _frames(tester);
      final current = tester.widget<CupertinoTextField>(_source);
      expect(current.controller, same(original));
      expect(current.controller!.value, input);
      expect(current.focusNode!.hasFocus, isTrue);
      expect(current.obscureText, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(
        _source,
        findsOneWidget,
      ); // Escape during composition belongs to the IME.
      expect(tester.takeException(), isNull);
    },
  );

  for (final closeKind in ['close', 'account', 'disabled']) {
    testWidgets('late preview is discarded after $closeKind', (tester) async {
      final native = _ProxyNative();
      final preview = Completer<JsonMap>();
      native.response = (method, args) async =>
          method == 'proxy.import' ? preview.future : native.snapshot;
      final (state, _) = await _mount(tester, native);
      await _openEditor(tester);
      await tester.enterText(_source, 'socks5://local.invalid:18881');
      await _frames(tester);
      await tester.tap(_button('识别并预览'));
      await _frames(tester);
      switch (closeKind) {
        case 'close':
          await tester.tap(_icon('关闭节点编辑器'));
        case 'account':
          native.accessRevision++;
          state.showMessage('Account changed');
        case 'disabled':
          _publish(
            state,
            native.snapshot,
            extensions: {
              'items': [
                {
                  'id': 'proxy',
                  'installed': true,
                  'enabled': false,
                  'active': false,
                },
              ],
            },
          );
      }
      preview.complete({
        'importToken': 'late-$closeKind',
        'summary': 'Stale result',
        'nodes': [],
      });
      await _frames(tester);
      expect(find.text('Stale result'), findsNothing);
      expect(
        native.calls.where(
          (call) =>
              call.$1 == 'proxy.discardImport' &&
              call.$2['importToken'] == 'late-$closeKind',
        ),
        hasLength(1),
      );
      expect(
        native.calls.where(
          (call) =>
              call.$2.containsKey('importToken') &&
              call.$1 != 'proxy.discardImport',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('preview is bounded and confirmation remains visible', (
    tester,
  ) async {
    final native = _ProxyNative();
    native.response = (method, args) async => method == 'proxy.import'
        ? {
            'importToken': 'preview-many',
            'summary': '识别 40 个节点',
            'nodes': [
              for (var i = 0; i < 40; i++)
                {'name': 'Preview $i', 'protocolName': 'SOCKS5'},
            ],
            'duplicates': 2,
            'skipped': ['第 3 项：格式不受支持。'],
          }
        : native.snapshot;
    await _mount(tester, native, width: 360, scale: 1.3);
    await _openEditor(tester);
    final editorPanel = find.ancestor(
      of: _source,
      matching: find.byType(DeskGlassPanel),
    );
    final compactHeight = tester.getSize(editorPanel).height;
    await tester.enterText(_source, 'socks5://local.invalid:18881');
    await _frames(tester);
    await tester.tap(_button('识别并预览'));
    await _frames(tester);
    expect(find.text('Preview 3 · SOCKS5'), findsOneWidget);
    expect(find.text('Preview 4 · SOCKS5'), findsNothing);
    expect(find.text('另有 36 个节点'), findsOneWidget);
    expect(tester.getSize(editorPanel).height, greaterThan(compactHeight));
    expect(find.text('已合并 2 个重复节点'), findsOneWidget);
    expect(find.text('跳过 1 项'), findsOneWidget);
    expect(_button('确认导入').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('node probe and menu do not select and long lists build lazily', (
    tester,
  ) async {
    final native = _ProxyNative()..snapshot = _snapshot(count: 300);
    await _mount(tester, native);
    expect(find.byType(GlassMenu).evaluate().length, lessThan(30));
    final target = _icon('检测节点延迟').first;
    await tester.ensureVisible(target);
    await tester.tap(target);
    await _frames(tester);
    expect(
      native.calls.where((call) => call.$1 == 'proxy.probe'),
      hasLength(1),
    );
    expect(native.calls.where((call) => call.$1 == 'proxy.select'), isEmpty);
    final more = _icon('节点更多操作').first;
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is GlassMenuItem && widget.title == '编辑节点',
      ),
      findsOneWidget,
    );
    expect(native.calls.where((call) => call.$1 == 'proxy.select'), isEmpty);
  });
  testWidgets(
    'root editor blocks detail actions and cannot close during commit',
    (tester) async {
      final native = _ProxyNative();
      final saved = Completer<JsonMap>();
      native.response = (method, args) async {
        if (method == 'proxy.import') {
          if (args.containsKey('importToken')) return saved.future;
          return {
            'importToken': 'commit-fixture',
            'summary': 'Ready',
            'nodes': [],
          };
        }
        return native.snapshot;
      };
      var headerActions = 0;
      await _mount(
        tester,
        native,
        header: CupertinoButton(
          onPressed: () => headerActions++,
          child: const Text('Fixture outer action'),
        ),
      );
      await _openEditor(tester);
      await tester.enterText(_source, 'socks5://local.invalid:18881');
      await _frames(tester);
      await tester.tap(_button('识别并预览'));
      await _frames(tester);
      await tester.tap(_button('确认导入'));
      await _frames(tester);
      expect(tester.widget<DeskIcon>(_icon('关闭节点编辑器')).onTap, isNull);
      expect(tester.widget<CupertinoTextField>(_source).enabled, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(5, 5));
      await tester.tap(find.text('Fixture outer action'), warnIfMissed: false);
      await _frames(tester);
      expect(_source, findsOneWidget);
      expect(headerActions, 0);
      saved.complete(native.snapshot);
      await _frames(tester);
      expect(_source, findsNothing);
      expect(
        native.calls.where(
          (call) =>
              call.$1 == 'proxy.import' && call.$2.containsKey('importToken'),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late decrypted editor cannot survive account or availability changes',
    (tester) async {
      final native = _ProxyNative();
      final link = Completer<JsonMap>();
      native.response = (method, args) async =>
          method == 'proxy.editNode' ? link.future : native.snapshot;
      final (state, _) = await _mount(tester, native);
      final menu = tester.widget<GlassMenu>(find.byType(GlassMenu).first);
      menu.items
          .whereType<GlassMenuItem>()
          .singleWhere((item) => item.title == '编辑节点')
          .onTap();
      await _frames(tester);
      native.accessRevision++;
      state.showMessage('Fixture account changed');
      link.complete({
        'id': 'node-0',
        'name': 'Stale editor',
        'link': 'socks5://stale.invalid:18881',
      });
      await _frames(tester);
      expect(_source, findsNothing);
      expect(find.text('Stale editor'), findsNothing);
      expect(native.calls.where((call) => call.$1 == 'proxy.import'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('revoking extension closes and clears an idle editor', (
    tester,
  ) async {
    final native = _ProxyNative();
    final (state, _) = await _mount(tester, native);
    await _openEditor(tester);
    await tester.enterText(_source, 'socks5://local.invalid:18881');
    final controller = tester.widget<CupertinoTextField>(_source).controller!;
    _publish(state, {...native.snapshot, 'available': false});
    await _frames(tester);
    expect(_source, findsNothing);
    expect(controller.text, isEmpty);
    expect(native.calls.where((call) => call.$1 == 'proxy.import'), isEmpty);
  });

  for (final editing in [false, true]) {
    for (final close in ['button', 'escape', 'navigator']) {
      testWidgets(
        '${editing ? 'edit' : 'preview'} content and geometry survive $close reverse animation',
        (tester) async {
          final native = _ProxyNative();
          native.response = (method, args) async => switch (method) {
            'proxy.editNode' => {
              'id': 'node-0',
              'name': 'Fixture edited node',
              'link': 'socks5://local.invalid:18881',
            },
            'proxy.import' => {
              'importToken': 'reverse-fixture-token',
              'summary': 'Fixture preview summary',
              'nodes': [],
            },
            _ => native.snapshot,
          };
          final (state, _) = await _mount(
            tester,
            native,
            disableAnimations: false,
          );
          if (editing) {
            await tester.tap(_icon('节点更多操作').first);
            await tester.pumpAndSettle();
            await tester.tap(find.text('编辑节点'));
            await _frames(tester);
          } else {
            await _openEditor(tester);
          }
          await tester.pump(const Duration(milliseconds: 250));
          if (!editing) {
            await tester.enterText(_source, 'socks5://local.invalid:18881');
            await _frames(tester);
            await tester.tap(_button('识别并预览'));
            await _frames(tester);
          }
          final panel = find.ancestor(
            of: _source,
            matching: find.byType(DeskGlassPanel),
          );
          final original = tester.getRect(panel);
          final route = ModalRoute.of(tester.element(_source))!;
          final controller = tester
              .widget<CupertinoTextField>(_source)
              .controller!;
          final label = editing ? '编辑节点' : 'Fixture preview summary';
          final commit = tester
              .widget<DeskButton>(_button(editing ? '保存节点' : '确认导入'))
              .onTap!;
          expect(find.text(label), findsOneWidget);
          expect(state.watchPopupDeferred.value, isTrue);
          switch (close) {
            case 'button':
              await tester.tap(_icon('关闭节点编辑器'));
            case 'escape':
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            case 'navigator':
              Navigator.of(tester.element(_source)).pop();
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
          expect(route.animation!.status, AnimationStatus.reverse);
          expect(route.animation!.value, greaterThan(0));
          expect(route.animation!.value, lessThan(1));
          expect(find.text(label), findsOneWidget);
          expect(tester.getRect(panel), original);
          expect(controller.text, 'socks5://local.invalid:18881');
          expect(state.watchPopupDeferred.value, isTrue);
          expect(tester.widget<DeskButton>(_button('添加节点 / 订阅')).onTap, isNull);
          commit();
          await tester.pump(const Duration(milliseconds: 250));
          await _frames(tester);
          expect(_source, findsNothing);
          expect(controller.text, isEmpty);
          expect(state.watchPopupDeferred.value, isFalse);
          expect(
            native.calls.where((call) => call.$1 == 'proxy.discardImport'),
            hasLength(editing ? 0 : 1),
          );
          expect(
            native.calls.where(
              (call) =>
                  call.$1 == 'proxy.import' &&
                  (call.$2.containsKey('importToken') ||
                      call.$2.containsKey('replacingId')),
            ),
            isEmpty,
          );
          await _openEditor(tester);
          expect(
            tester.widget<CupertinoTextField>(_source).controller!.text,
            isEmpty,
          );
          expect(find.text('Fixture preview summary'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('an in-flight mode gesture cannot clear a closing preview', (
    tester,
  ) async {
    final native = _ProxyNative();
    native.response = (method, args) async => method == 'proxy.import'
        ? {
            'importToken': 'closing-mode-token',
            'summary': 'Fixture gesture preview',
            'nodes': [],
          }
        : native.snapshot;
    await _mount(tester, native, disableAnimations: false);
    await _openEditor(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(_source, 'socks5://local.invalid:18881');
    await _frames(tester);
    await tester.tap(_button('识别并预览'));
    await _frames(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('订阅链接')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    expect(find.text('Fixture gesture preview'), findsOneWidget);
    expect(
      tester.widget<CupertinoTextField>(_source).controller!.text,
      'socks5://local.invalid:18881',
    );
    expect(native.calls.where((call) => call.$1 == 'proxy.subscribe'), isEmpty);
    await tester.pump(const Duration(milliseconds: 250));
    await _frames(tester);
    expect(_source, findsNothing);
    expect(
      native.calls.where((call) => call.$1 == 'proxy.discardImport'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final revoke in ['account', 'extension']) {
    testWidgets('$revoke change clears data during reverse animation', (
      tester,
    ) async {
      final native = _ProxyNative();
      native.response = (method, args) async => method == 'proxy.import'
          ? {
              'importToken': 'revoked-reverse-token',
              'summary': 'Fixture reverse preview',
              'nodes': [],
            }
          : native.snapshot;
      final (state, _) = await _mount(tester, native, disableAnimations: false);
      await _openEditor(tester);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(_source, 'socks5://local.invalid:18881');
      await _frames(tester);
      await tester.tap(_button('识别并预览'));
      await _frames(tester);
      final controller = tester.widget<CupertinoTextField>(_source).controller!;
      final navigator = Navigator.of(tester.element(_source));
      await tester.tap(_icon('关闭节点编辑器'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('Fixture reverse preview'), findsOneWidget);
      final cover = CupertinoPageRoute<void>(
        builder: (_) =>
            const CupertinoPageScaffold(child: Text('Fixture covering route')),
      );
      unawaited(navigator.push(cover));
      if (revoke == 'account') {
        native.accessRevision++;
        state.showMessage('Fixture account changed');
      } else {
        _publish(state, {...native.snapshot, 'available': false});
      }
      expect(controller.text, isEmpty);
      await tester.pump();
      expect(find.text('Fixture reverse preview'), findsNothing);
      expect(cover.isCurrent, isTrue);
      expect(
        native.calls.where((call) => call.$1 == 'proxy.discardImport'),
        hasLength(1),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await _frames(tester);
      expect(cover.isCurrent, isTrue);
      expect(state.watchPopupDeferred.value, isFalse);
      expect(
        native.calls.where(
          (call) =>
              call.$1 == 'proxy.import' && call.$2.containsKey('importToken'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'closing route retains editor resources through reverse animation and host disposal',
    (tester) async {
      final native = _ProxyNative();
      final state = AppState(client: native)
        ..domains['proxy'] = native.snapshot;
      final visible = ValueNotifier(true);
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        state.dispose();
        visible.dispose();
        await tester.binding.setSurfaceSize(null);
      });
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
                    : const Text('Closed host'),
              ),
            ),
          ),
        ),
      );
      await _frames(tester);
      await _openEditor(tester);
      expect(state.watchPopupDeferred.value, isTrue);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(_source, 'socks5://local.invalid:18881');
      await tester.tap(_icon('关闭节点编辑器'));
      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ProxyScreen), findsNothing);
      expect(_source, findsNothing);
      expect(state.watchPopupDeferred.value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real extension overlay defers keyword navigation through editor commit without consuming unread',
    (tester) async {
      final native = _ProxyNative();
      final saved = Completer<JsonMap>();
      JsonMap hit(String id) => {
        'id': id,
        'words': ['fixture'],
        'post': {
          'id': id,
          'title': 'Keyword fixture $id',
          'url': 'https://www.nodeseek.com/post-$id-1',
          'author': 'Fixture',
        },
      };
      final firstHit = hit('42'), nextHit = hit('43');
      JsonMap extensions = {
        'items': [
          {'id': 'proxy', 'installed': true, 'enabled': true, 'active': true},
          {
            'id': 'keywords',
            'installed': true,
            'enabled': true,
            'active': true,
          },
        ],
        'hits': [firstHit],
        'unread': 1,
        'watchPopup': {
          'id': 'first-popup',
          'hits': [firstHit],
        },
      };
      native.response = (method, args) async {
        if (method == 'proxy.import') {
          if (args.containsKey('importToken')) return saved.future;
          return {
            'importToken': 'keyword-modal-preview',
            'summary': 'Ready',
            'nodes': [],
          };
        }
        if (method == 'extensions.dismissWatchPopup') {
          extensions = {...extensions, 'watchPopup': null};
          return extensions;
        }
        return native.snapshot;
      };
      final (state, _) = await _mount(
        tester,
        native,
        extensions: extensions,
        withExtensionOverlays: true,
      );
      expect(find.text('Keyword fixture 42'), findsOneWidget);
      await _openEditor(tester);
      expect(state.watchPopupDeferred.value, isTrue);
      expect(find.text('Keyword fixture 42'), findsNothing);
      expect(_icon('关闭关键词提示'), findsNothing);
      await tester.enterText(_source, 'socks5://local.invalid:18881');
      await _frames(tester);
      await tester.tap(_button('识别并预览'));
      await _frames(tester);
      await tester.tap(_button('确认导入'));
      await _frames(tester);

      // A fresh notification arriving during the commit is also deferred. Its
      // persisted hits/unread stay intact; nothing is acknowledged or dismissed.
      extensions = {
        ...extensions,
        'hits': [firstHit, nextHit],
        'unread': 2,
        'watchPopup': {
          'id': 'next-popup',
          'hits': [nextHit],
        },
      };
      _publish(state, native.snapshot, extensions: extensions);
      await _frames(tester);
      expect(find.text('Keyword fixture 43'), findsNothing);
      expect(_icon('关闭关键词提示'), findsNothing);
      await tester.tapAt(const Offset(1000, 110));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(_source, findsOneWidget);
      expect(state.watchPopupDeferred.value, isTrue);
      expect(state.domain('extensions')['unread'], 2);
      expect(state.domain('extensions')['hits'], [firstHit, nextHit]);
      expect(
        native.calls.where(
          (call) =>
              call.$1.startsWith('reader.') ||
              call.$1.startsWith('extensions.'),
        ),
        isEmpty,
      );

      saved.complete(native.snapshot);
      await _frames(tester);
      expect(_source, findsNothing);
      expect(state.watchPopupDeferred.value, isFalse);
      expect(find.text('Keyword fixture 43'), findsOneWidget);
      expect(state.domain('extensions')['unread'], 2);
      expect(state.domain('extensions')['hits'], [firstHit, nextHit]);
      expect(
        native.calls.where((call) => call.$1.startsWith('reader.')),
        isEmpty,
      );

      // Only an explicit click after the editor is gone dismisses the popup.
      await tester.tap(_icon('关闭关键词提示'));
      await _frames(tester);
      expect(find.text('Keyword fixture 43'), findsNothing);
      expect(state.domain('extensions')['unread'], 2);
      expect(state.domain('extensions')['hits'], [firstHit, nextHit]);
      expect(
        native.calls.where((call) => call.$1 == 'extensions.dismissWatchPopup'),
        hasLength(1),
      );
      expect(
        native.calls.where((call) => call.$1 == 'extensions.acknowledgeHits'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
