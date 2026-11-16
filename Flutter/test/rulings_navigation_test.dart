import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _targetURL = 'https://www.nodeseek.com/post-17-2#31';
const _parentLabel = 'Fixture parent details';
const _laterLabel = 'Fixture later route';

JsonMap _workspace() => {
  'posts': <JsonMap>[],
  'tabs': [
    {'id': '17', 'url': _targetURL, 'title': 'Already selected fixture topic'},
  ],
  'selectedTab': '17',
  'showReader': true,
};

/// Runs the real AppState navigation with a strictly local transport. The
/// initial selected URL deliberately matches the ruling's URL: its presence
/// must never be confused with a successful new navigation attempt.
class _Native extends NativeClient {
  _Native()
    : super(
        methods: MethodChannel('seekdesk.test.rulings-navigation.${_next++}'),
      );
  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  bool failOpen = false;
  Completer<JsonMap>? openGate;
  Completer<JsonMap>? loadGate;

  JsonMap get opened => {
    'workspace': _workspace(),
    'accessRevision': accessRevision,
  };

  JsonMap get reader => {
    'url': _targetURL,
    'accessRevision': accessRevision,
    'loading': false,
    'thread': {
      'title': 'Locally loaded fixture topic',
      'root': {'id': '0', 'author': 'Fixture', 'blocks': <JsonMap>[]},
      'replies': <JsonMap>[],
      'pages': <JsonMap>[],
    },
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'rulings.load':
        if (arguments['name'] != 'Fixture member') break;
        return {
          'records': [
            {
              'id': 8,
              'kind': 'punish',
              'reason': 'Fixture ruling reason',
              'actions': 'Local fixture timestamp',
              'url': _targetURL,
            },
          ],
        };
      case 'reader.open':
        if (arguments['url'] != _targetURL) break;
        if (failOpen) {
          throw const NativeFailure(
            'fixture_open_failed',
            'Fixture open failed',
          );
        }
        return openGate?.future ?? Future.value(opened);
      case 'reader.load':
        if (arguments['url'] != _targetURL) break;
        return loadGate?.future ?? Future.value(reader);
    }
    unexpected.add('$method $arguments');
    throw StateError('Unexpected rulings navigation fixture call: $method');
  }

  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);

  void finishPending() {
    final opening = openGate, loading = loadGate;
    if (opening != null && !opening.isCompleted) opening.complete(opened);
    if (loading != null && !loading.isCompleted) loading.complete(reader);
  }
}

class _Observer extends NavigatorObserver {
  final popped = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
    super.didPop(route, previousRoute);
  }
}

class _Fixture {
  _Fixture() {
    state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'owner': 1};
    state.domains['workspace'] = _workspace();
  }
  final native = _Native();
  late final AppState state;
  final navigation = GlobalKey<NavigatorState>();
  final observer = _Observer();
  late final Route<void> rulings;

  Future<void> pushLater(WidgetTester tester) async {
    unawaited(
      navigation.currentState!.push<void>(
        CupertinoPageRoute(
          settings: const RouteSettings(name: '/later'),
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text(_laterLabel)),
          ),
        ),
      ),
    );
    await _settle(tester);
  }
}

Future<_Fixture> _mount(WidgetTester tester, {bool embedded = true}) async {
  final f = _Fixture();
  await tester.binding.setSurfaceSize(const Size(1000, 850));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.native.finishPending();
    await _frames(tester);
    f.state.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(f.native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        navigatorKey: f.navigation,
        navigatorObservers: [f.observer],
        home: const CupertinoPageScaffold(
          child: Center(child: Text('Fixture home')),
        ),
      ),
    ),
  );
  unawaited(
    f.navigation.currentState!.push<void>(
      CupertinoPageRoute(
        settings: const RouteSettings(name: '/parent'),
        builder: (_) => const CupertinoPageScaffold(
          child: Center(child: Text(_parentLabel)),
        ),
      ),
    ),
  );
  await _settle(tester);
  f.rulings = CupertinoPageRoute(
    settings: const RouteSettings(name: '/rulings'),
    builder: (_) => CupertinoPageScaffold(
      child: RulingsScreen(
        state: f.state,
        name: 'Fixture member',
        embedded: embedded,
      ),
    ),
  );
  unawaited(f.navigation.currentState!.push(f.rulings));
  await _settle(tester);
  expect(find.text('Fixture ruling reason'), findsOneWidget);
  expect(f.state.workspace.selected!.url, _targetURL);
  expect(f.state.workspace.showReader, true);
  return f;
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 40),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _open(WidgetTester tester) async {
  final button = _button('查看帖子');
  await tester.ensureVisible(button);
  await _frames(tester);
  await tester.tap(button);
  await _frames(tester);
}

void _testMac(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _testMac(
    'failed open keeps rulings even when the same URL is already selected',
    (tester) async {
      final f = await _mount(tester);
      f.native.failOpen = true;
      await _open(tester);
      await _settle(tester);
      expect(f.native.named('reader.open'), hasLength(1));
      expect(f.native.named('reader.load'), isEmpty);
      expect(f.state.workspace.selected!.url, _targetURL);
      expect(f.state.message, 'Fixture open failed');
      expect(f.rulings.isCurrent, true);
      expect(find.byType(RulingsScreen), findsOneWidget);
      expect(find.text('Fixture ruling reason'), findsOneWidget);
      expect(f.observer.popped, isEmpty);
    },
  );

  _testMac(
    'workspace leave refusal keeps rulings and performs no native open',
    (tester) async {
      final f = await _mount(tester);
      final owner = Object();
      var guardCalls = 0;
      f.state.registerWorkspaceLeaveGuard(owner, () async {
        guardCalls++;
        return false;
      });
      await _open(tester);
      await _settle(tester);
      expect(guardCalls, 1);
      expect(f.native.named('reader.open'), isEmpty);
      expect(f.native.named('reader.load'), isEmpty);
      expect(f.rulings.isCurrent, true);
      expect(find.byType(RulingsScreen), findsOneWidget);
      expect(f.observer.popped, isEmpty);
      f.state.unregisterWorkspaceLeaveGuard(owner);
    },
  );

  for (final embedded in [false, true]) {
    _testMac(
      'successful ${embedded ? 'embedded' : 'standalone'} ruling opens the post and closes only itself',
      (tester) async {
        final f = await _mount(tester, embedded: embedded);
        await _open(tester);
        await _settle(tester);
        expect(f.native.named('reader.open'), hasLength(1));
        expect(f.native.named('reader.open').single.$2['url'], _targetURL);
        expect(f.native.named('reader.load'), hasLength(1));
        expect(f.observer.popped, [same(f.rulings)]);
        expect(find.byType(RulingsScreen), findsNothing);
        expect(find.text(_parentLabel), findsOneWidget);
        expect(find.text('Fixture home'), findsNothing);
        expect(f.state.workspace.selected!.url, _targetURL);
      },
    );
  }

  _testMac('an open completing under a later route never pops that route', (
    tester,
  ) async {
    final f = await _mount(tester);
    f.native.openGate = Completer<JsonMap>();
    await _open(tester);
    expect(f.native.named('reader.open'), hasLength(1));
    await f.pushLater(tester);
    f.native.openGate!.complete(f.native.opened);
    await _settle(tester);
    expect(f.native.named('reader.load'), hasLength(1));
    expect(find.text(_laterLabel), findsOneWidget);
    expect(f.observer.popped, isEmpty);
    f.navigation.currentState!.pop();
    await _settle(tester);
    expect(f.rulings.isCurrent, true);
    expect(find.byType(RulingsScreen), findsOneWidget);
    expect(f.observer.popped.map((route) => route.settings.name), ['/later']);
  });

  _testMac(
    'a late reader completion also preserves a subsequently opened route',
    (tester) async {
      final f = await _mount(tester);
      f.native.loadGate = Completer<JsonMap>();
      await _open(tester);
      expect(f.native.named('reader.load'), hasLength(1));
      await f.pushLater(tester);
      f.native.loadGate!.complete(f.native.reader);
      await _settle(tester);
      expect(find.text(_laterLabel), findsOneWidget);
      expect(f.observer.popped, isEmpty);
      f.navigation.currentState!.pop();
      await _settle(tester);
      expect(f.rulings.isCurrent, true);
      expect(find.text('Fixture ruling reason'), findsOneWidget);
    },
  );

  _testMac(
    'an unmounted ruling cannot pop a replacement route on late completion',
    (tester) async {
      final f = await _mount(tester);
      f.native.openGate = Completer<JsonMap>();
      await _open(tester);
      f.navigation.currentState!.pop();
      await _settle(tester);
      expect(find.byType(RulingsScreen), findsNothing);
      expect(f.observer.popped, [same(f.rulings)]);
      await f.pushLater(tester);
      f.native.openGate!.complete(f.native.opened);
      await _settle(tester);
      expect(find.text(_laterLabel), findsOneWidget);
      expect(f.observer.popped, [same(f.rulings)]);
    },
  );
}
