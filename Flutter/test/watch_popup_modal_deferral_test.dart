// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// All calls are recorded in memory. No platform or forum service is invoked.
class _PopupNative extends NativeClient {
  final calls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    return {};
  }
}

JsonMap _extensions({bool office = false}) => {
  'items': [
    {'id': 'keywords', 'installed': true, 'enabled': true, 'active': true},
    {'id': 'office', 'installed': true, 'enabled': true, 'active': true},
  ],
  'settings': {
    'office': {'title': 'Fixture work sheet', 'key': '9', 'presented': office},
  },
  'unread': 7,
  'hits': [
    {
      'id': 'hit-fixture',
      'words': ['fixture'],
    },
  ],
  'watchPopup': {
    'id': 'popup-fixture',
    'hits': [
      {
        'id': 'hit-fixture',
        'words': ['fixture'],
        'post': {
          'id': '777',
          'url': 'https://www.nodeseek.com/post-777-1',
          'title': 'Fixture keyword result',
        },
      },
    ],
  },
};

Future<void> _mount(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(900, 700));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) =>
            ExtensionOverlays(state: state, child: child!),
        home: const CupertinoPageScaffold(
          child: Center(child: Text('Workspace')),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('popup leases are independent and releases are idempotent', () {
    final state = AppState(client: _PopupNative());
    addTearDown(state.dispose);
    final transitions = <bool>[];
    var appNotifications = 0;
    state.addListener(() => appNotifications++);
    state.watchPopupDeferred.addListener(
      () => transitions.add(state.watchPopupDeferred.value),
    );
    expect(state.watchPopupDeferred.value, isFalse);
    final first = state.deferWatchPopup();
    final second = state.deferWatchPopup();
    expect(transitions, [true]);
    first();
    first();
    expect(state.watchPopupDeferred.value, isTrue);
    second();
    second();
    expect(transitions, [true, false]);
    final next = state.deferWatchPopup();
    next();
    expect(transitions, [true, false, true, false]);
    expect(
      appNotifications,
      0,
    ); // Popup-only state never rebuilds the workspace.
  });

  test('late releases and late acquisition after disposal are harmless', () {
    final state = AppState(client: _PopupNative());
    final release = state.deferWatchPopup();
    state.dispose();
    expect(release, returnsNormally);
    expect(release, returnsNormally);
    expect(() => state.deferWatchPopup()(), returnsNormally);
  });

  testWidgets('deferred popup returns unchanged and stale actions do nothing', (
    tester,
  ) async {
    final native = _PopupNative();
    final state = AppState(client: native);
    final snapshot = _extensions();
    state.domains['extensions'] = snapshot;
    await _mount(tester, state);
    expect(find.text('Fixture keyword result'), findsOneWidget);
    final staleOpen = tester.widget<HoverRow>(find.byType(HoverRow)).onTap;
    final staleDismiss = tester
        .widget<DeskIcon>(
          find.byWidgetPredicate(
            (widget) => widget is DeskIcon && widget.label == '关闭关键词提示',
          ),
        )
        .onTap!;
    final first = state.deferWatchPopup();
    final second = state.deferWatchPopup();
    // A callback captured before the next frame must consult the live lease.
    staleOpen();
    staleDismiss();
    await tester.pump();
    expect(find.text('Fixture keyword result'), findsNothing);
    expect(find.text('Workspace'), findsOneWidget);
    staleOpen();
    staleDismiss();
    first();
    first();
    await tester.pump();
    expect(find.text('Fixture keyword result'), findsNothing);
    second();
    await tester.pump();
    expect(find.text('Fixture keyword result'), findsOneWidget);
    expect(state.domain('extensions'), same(snapshot));
    expect(snapshot['unread'], 7);
    expect(jsonItems(snapshot['hits']), hasLength(1));
    expect(jsonMap(snapshot['watchPopup'])['id'], 'popup-fixture');
    expect(state.navigationRevision, 0);
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('office cover remains available while popup is deferred', (
    tester,
  ) async {
    final native = _PopupNative();
    final state = AppState(client: native);
    state.domains['extensions'] = _extensions(office: true);
    final release = state.deferWatchPopup();
    await _mount(tester, state);
    expect(find.text('Fixture work sheet'), findsOneWidget);
    final restore = tester.widget<DeskButton>(
      find.byWidgetPredicate(
        (widget) => widget is DeskButton && widget.label == '恢复窗口',
      ),
    );
    expect(restore.onTap, isNotNull);
    expect(find.text('Fixture keyword result'), findsNothing);
    release();
    await tester.pump();
    expect(find.text('Fixture work sheet'), findsOneWidget);
    expect(find.text('Fixture keyword result'), findsNothing);
    expect(state.domain('extensions')['unread'], 7);
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
