import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/proxy_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class ProxyNativeFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;
  JsonMap snapshot = {'available': true, 'nodes': [], 'subscriptions': []};

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'proxy.get') return snapshot;
    return await respond?.call(method, arguments) ?? {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final native = state.client as ProxyNativeFixture;
    if (state.domain('proxy').isNotEmpty) {
      native.snapshot = {'available': true, ...state.domain('proxy')};
    }
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(child: ProxyScreen(state: state)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  Future<void> openEditor(WidgetTester tester) async {
    await tester.ensureVisible(button('添加节点 / 订阅'));
    await tester.tap(button('添加节点 / 订阅'));
    await tester.pumpAndSettle();
  }

  testWidgets('editing a node saves its original id and visible link', (
    tester,
  ) async {
    final native = ProxyNativeFixture();
    native.respond = (method, args) async => method == 'proxy.editNode'
        ? {
            'id': 'node-1',
            'name': 'Local fixture',
            'link': 'socks5://127.0.0.1:18881',
          }
        : {};
    final state = AppState(client: native);
    state.domains['proxy'] = {
      'nodes': [
        {
          'id': 'node-1',
          'name': 'Local fixture',
          'protocolName': 'SOCKS5',
          'host': '127.0.0.1',
          'port': 18881,
        },
      ],
    };
    await mount(tester, state);
    final more = find.byWidgetPredicate(
      (widget) => widget is DeskIcon && widget.label == '节点更多操作',
    );
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    final edit = find.byWidgetPredicate(
      (widget) => widget is GlassMenuItem && widget.title == '编辑节点',
    );
    await tester.tap(edit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('编辑节点'), findsOneWidget);
    final linkField = find.byKey(const ValueKey('proxy-source'));
    expect(tester.widget<CupertinoTextField>(linkField).obscureText, false);
    expect(
      tester.widget<CupertinoTextField>(linkField).controller?.text,
      'socks5://127.0.0.1:18881',
    );
    await tester.enterText(linkField, 'socks5://127.0.0.1:18882');
    await tester.ensureVisible(button('保存节点'));
    await tester.tap(button('保存节点'));
    await tester.pump();
    final saved = native.calls
        .lastWhere((call) => call.$1 == 'proxy.import')
        .$2;
    expect(saved['replacingId'], 'node-1');
    expect(saved['text'], 'socks5://127.0.0.1:18882');
    expect(saved.containsKey('importToken'), false);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('a late preview is discarded after the source changes', (
    tester,
  ) async {
    final native = ProxyNativeFixture();
    final response = Completer<JsonMap>();
    native.respond = (method, args) async =>
        method == 'proxy.import' ? response.future : {};
    final state = AppState(client: native);
    await mount(tester, state);
    await openEditor(tester);
    final linkField = find.byKey(const ValueKey('proxy-source'));
    await tester.enterText(linkField, 'socks5://127.0.0.1:18881');
    await tester.pump();
    await tester.tap(button('识别并预览'));
    await tester.pump();
    await tester.enterText(linkField, 'socks5://127.0.0.1:18882');
    response.complete({
      'importToken': 'stale-preview',
      'summary': 'Stale',
      'nodes': [],
    });
    await tester.pump();
    expect(find.text('Stale'), findsNothing);
    expect(
      native.calls.any(
        (call) =>
            call.$1 == 'proxy.discardImport' &&
            call.$2['importToken'] == 'stale-preview',
      ),
      true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('mode changes and screen disposal clean up native previews', (
    tester,
  ) async {
    final native = ProxyNativeFixture();
    var count = 0;
    native.respond = (method, args) async {
      if (method == 'proxy.import' || method == 'proxy.subscribe') {
        return {
          'importToken': 'preview-${++count}',
          'summary': 'Ready',
          'nodes': [],
        };
      }
      if (method == 'proxy.discardImport' &&
          args['importToken'] == 'preview-2') {
        throw const NativeFailure('gone', 'The screen has already closed');
      }
      return {};
    };
    final state = AppState(client: native);
    await mount(tester, state);
    await openEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('proxy-source')),
      'socks5://127.0.0.1:18881',
    );
    await tester.pump();
    await tester.tap(button('识别并预览'));
    await tester.pump();
    final control = tester.widget<GlassSegmentedControl>(
      find.byType(GlassSegmentedControl),
    );
    control.onSegmentSelected(1);
    await tester.pump();
    expect(
      native.calls.any(
        (call) =>
            call.$1 == 'proxy.discardImport' &&
            call.$2['importToken'] == 'preview-1',
      ),
      true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('proxy-source')),
      'https://example.org/fixture',
    );
    await tester.pump();
    await tester.tap(button('识别并预览'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      native.calls.any(
        (call) =>
            call.$1 == 'proxy.discardImport' &&
            call.$2['importToken'] == 'preview-2',
      ),
      true,
    );
    expect(tester.takeException(), isNull);
    state.dispose();
  });
}
