import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

Finder get _entry => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == '最近关闭',
);
Finder get _close => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == '关闭最近标签列表',
);
Finder get _row => find.byKey(const ValueKey('closed-tab-17'));
Finder get _title => find.text('最近关闭的标签');

VoidCallback _closeCallback(WidgetTester tester) =>
    tester.widget<DeskIcon>(_close).onTap!;
VoidCallback _reopenCallback(WidgetTester tester) =>
    tester.widget<HoverRow>(_row).onTap;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'own dialog can close and reopen although its workspace route is covered',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        expect(fixture.canInteract(), isTrue);
        await fixture.open(tester);
        expect(fixture.canInteract(), isFalse);
        await tester.tap(_close);
        await tester.pumpAndSettle();
        expect(_title, findsNothing);
        expect(fixture.canInteract(), isTrue);
        expect(fixture.native.reopens, isEmpty);

        await fixture.open(tester);
        expect(fixture.canInteract(), isFalse);
        await tester.tap(_row);
        await tester.pumpAndSettle();
        expect(_title, findsNothing);
        expect(fixture.native.reopens, hasLength(1));
        expect(fixture.native.reopens.single.$2['id'], '17');
        expect(fixture.state.workspace.selectedTab, '17');
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'captured dialog actions cannot pop a newer route and still work after uncovering',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        final close = _closeCallback(tester);
        final reopen = _reopenCallback(tester);
        unawaited(
          fixture.navigator.currentState!.push(
            CupertinoPageRoute<void>(
              builder: (_) => const CupertinoPageScaffold(
                child: Center(child: Text('Newer closed-tabs route')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        close();
        reopen();
        await tester.pumpAndSettle();
        expect(find.text('Newer closed-tabs route'), findsOneWidget);
        expect(fixture.native.reopens, isEmpty);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(_title, findsOneWidget);
        await tester.tap(_row);
        await tester.pumpAndSettle();
        expect(fixture.native.reopens, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'office cover rejects captured close and reopen without losing the dialog',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        final close = _closeCallback(tester);
        final reopen = _reopenCallback(tester);
        fixture.native.cover(true);
        await tester.pump();
        close();
        reopen();
        await tester.pumpAndSettle();
        expect(find.text('Closed-tabs work sheet'), findsOneWidget);
        expect(_title, findsOneWidget);
        expect(fixture.native.reopens, isEmpty);
        fixture.native.cover(false);
        await tester.pumpAndSettle();
        expect(_row.hitTestable(), findsOneWidget);
        await tester.tap(_row);
        await tester.pumpAndSettle();
        expect(fixture.native.reopens, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final action in ['close', 'reopen']) {
    testWidgets(
      'a $action pointer already down cannot dismiss the dialog after the office hotkey',
      (tester) async {
        final fixture = await _Fixture.mount(tester);
        try {
          await fixture.open(tester);
          final gesture = await tester.startGesture(
            tester.getCenter(action == 'close' ? _close : _row),
          );
          await tester.pump(const Duration(milliseconds: 50));
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(find.text('Closed-tabs work sheet'), findsOneWidget);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_title, findsOneWidget);
          expect(fixture.native.reopens, isEmpty);
          fixture.native.cover(false);
          await tester.pumpAndSettle();
          expect(_row.hitTestable(), findsOneWidget);
          await tester.tap(_close);
          await tester.pumpAndSettle();
          expect(_title, findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets(
    'a captured selection rejects a new account before and after rebuild, while close remains available',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        final reopen = _reopenCallback(tester);
        final close = _closeCallback(tester);
        fixture.native.account(1);
        // This is the old row's still-mounted callback before the next frame.
        reopen();
        await tester.pumpAndSettle();
        expect(_title, findsOneWidget);
        expect(find.text('没有可恢复的标签'), findsOneWidget);
        expect(fixture.native.reopens, isEmpty);
        // The row is now disposed; a retained callback must also be harmless.
        reopen();
        close();
        await tester.pumpAndSettle();
        expect(_title, findsNothing);
        expect(fixture.native.reopens, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final boundary in ['account', 'office']) {
    testWidgets(
      '$boundary change after selection pops but before completion prevents reopening',
      (tester) async {
        final fixture = await _Fixture.mount(tester);
        try {
          await fixture.open(tester);
          _reopenCallback(tester)();
          if (boundary == 'account') {
            fixture.native.account(1);
          } else {
            fixture.native.cover(true);
          }
          await tester.pumpAndSettle();
          expect(_title, findsNothing);
          expect(fixture.native.reopens, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets('disposed dialog callbacks cannot close a later dialog', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    try {
      await fixture.open(tester);
      final oldClose = _closeCallback(tester);
      final oldReopen = _reopenCallback(tester);
      oldClose();
      await tester.pumpAndSettle();
      await fixture.open(tester);
      oldClose();
      oldReopen();
      await tester.pumpAndSettle();
      expect(_title, findsOneWidget);
      expect(fixture.native.reopens, isEmpty);
      await tester.tap(_close);
      await tester.pumpAndSettle();
      expect(_title, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'a disabled office extension with a saved presented flag does not block actions',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        fixture.native.cover(true, active: false);
        await tester.pump();
        expect(find.text('Closed-tabs work sheet'), findsNothing);
        await tester.tap(_row);
        await tester.pumpAndSettle();
        expect(_title, findsNothing);
        expect(fixture.native.reopens, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}

class _ClosedTabsNative extends NativeClient {
  _ClosedTabsNative()
    : super(methods: MethodChannel('seekdesk.test.closed-tabs.${_channel++}'));
  static int _channel = 0;
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  Iterable<(String, JsonMap)> get reopens =>
      calls.where((call) => call.$1 == 'reader.reopen');
  final JsonMap topic = {
    'id': '17',
    'url': 'https://www.nodeseek.com/post-17-1',
    'title': 'Closed fixture post',
  };
  bool reopened = false;

  JsonMap get workspace => {
    'tabs': reopened ? [topic] : <JsonMap>[],
    'closedTabs': reopened ? <JsonMap>[] : [topic],
    'selectedTab': reopened ? '17' : '',
    'showReader': reopened,
  };
  JsonMap extensions(bool covered, {bool active = true}) => {
    'items': [
      {'id': 'office', 'active': active},
    ],
    'settings': {
      'office': {
        'presented': covered,
        'key': '9',
        'title': 'Closed-tabs work sheet',
        'button': '恢复窗口',
      },
    },
  };

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {'account': 'signedIn', 'accessRevision': 0},
          'workspace': workspace,
          'extensions': extensions(false),
        };
      case 'reader.reopen':
        reopened = true;
        return workspace;
      case 'reader.load':
        return {'url': topic['url'], 'thread': <String, dynamic>{}};
      case 'extensions.office':
        return extensions(arguments['presented'] == true);
      default:
        throw StateError('Unexpected closed-tabs fixture call: $method');
    }
  }

  void account(int revision) => snapshotEvents.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {'account': 'signedIn', 'accessRevision': revision},
  });

  void cover(bool covered, {bool active = true}) => snapshotEvents.add({
    'domain': 'extensions',
    'accessRevision': accessRevision,
    'data': extensions(covered, active: active),
  });
}

class _Fixture {
  _Fixture(this.native, this.state);
  final _ClosedTabsNative native;
  final AppState state;
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext workspaceContext;

  bool canInteract() {
    final extensions = state.domain('extensions');
    final covered =
        jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] == true;
    return workspaceContext.mounted &&
        ModalRoute.of(workspaceContext)?.isCurrent == true &&
        !covered;
  }

  static Future<_Fixture> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    final native = _ClosedTabsNative();
    final state = AppState(client: native);
    await state.connect();
    final fixture = _Fixture(native, state);
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: fixture.navigator,
          builder: (context, child) =>
              ExtensionOverlays(state: state, child: child!),
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) {
                fixture.workspaceContext = context;
                return Center(
                  child: ClosedTabsButton(
                    state: state,
                    canInteract: fixture.canInteract,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return fixture;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(_entry);
    await tester.pumpAndSettle();
    expect(_title, findsOneWidget);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await native.snapshotEvents.close();
    await tester.binding.setSurfaceSize(null);
  }
}
