import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

/// Read-only integration: account events and profile/activity replies are local
/// values. Any write, image read or unrelated operation is rejected at teardown.
class _OverviewNative extends NativeClient {
  _OverviewNative()
    : super(methods: const MethodChannel('seekdesk.test.profile-overview'));

  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap, int)>[];
  final unexpected = <String>[];
  Completer<JsonMap>? secondProfile;
  bool allowActivity = false;

  JsonMap profile(int owner) => {
    'id': owner,
    'name': 'Local owner $owner',
    'avatar': '',
    'topics': 25,
    'replies': 30,
    'following': 4,
    'followers': 5,
    'coin': 120,
    // Both owners must have enough content to retain 600px. Otherwise Flutter
    // could clamp the old offset to zero and accidentally hide the regression.
    'bio': List.generate(
      70,
      (index) => 'Owner $owner local biography line $index.',
    ).join('\n'),
  };

  JsonMap session(int revision) => {
    'account': 'signedIn',
    'owner': revision + 1,
    'accessRevision': revision,
    'unread': {'mentions': 0, 'replies': 0, 'messages': 0},
  };

  JsonMap profileResponse(int revision) => {
    ...session(revision),
    'profile': profile(revision + 1),
  };

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap, int)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  void changeAccount() => eventStream.add({
    'domain': 'session',
    'accessRevision': 1,
    'data': session(1),
  });

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    final revision = accessRevision;
    calls.add((method, {...args}, revision));
    switch (method) {
      case 'bootstrap':
        if (args.isNotEmpty) break;
        return {'session': session(revision)};
      case 'profile.load':
        if (args.length != 1 || args['force'] != false) break;
        if (revision == 1 && secondProfile != null) {
          return secondProfile!.future;
        }
        return profileResponse(revision);
      case 'profile.introduction':
        if (args.isNotEmpty) break;
        return {
          'kind': 'ready',
          'accessRevision': revision,
          'data': {
            'signature': 'Local signature ${revision + 1}',
            'readme': 'Local introduction ${revision + 1}',
          },
        };
      case 'space.activity':
        if (!allowActivity ||
            args.length != 3 ||
            args['memberId'] != 1 ||
            args['route'] != 'discussions' ||
            args['page'] != 1) {
          break;
        }
        return {
          'memberId': 1,
          'route': 'discussions',
          'page': 1,
          'accessRevision': revision,
          'hasNext': false,
          'items': [
            {
              'postId': 707,
              'title': 'Local overview tab topic',
              'floor': 0,
              'text': '',
              'url': 'https://www.nodeseek.com/post-707-1',
            },
          ],
        };
    }
    unexpected.add('$method $args');
    throw StateError('Overview continuity fixture rejected $method $args');
  }
}

class _OverviewHost extends StatefulWidget {
  const _OverviewHost({required this.state, super.key});
  final AppState state;
  @override
  State<_OverviewHost> createState() => _OverviewHostState();
}

class _OverviewHostState extends State<_OverviewHost> {
  bool visible = true;
  void show(bool value) => setState(() => visible = value);
  @override
  Widget build(BuildContext context) => visible
      ? AccountScreen(state: widget.state, onClose: () => show(false))
      : const CupertinoPageScaffold(
          child: Center(child: Text('Local other page')),
        );
}

Finder get _overview => find.byKey(const ValueKey('profile-overview-scroll'));
Finder get _sections => find.byKey(const ValueKey('profile-space-sections'));
ScrollController _scroll(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(_overview).controller!;

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 5; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<({GlobalKey<_OverviewHostState> host, AppState state})> _mount(
  WidgetTester tester,
  _OverviewNative native,
) async {
  await tester.binding.setSurfaceSize(const Size(1040, 680));
  final state = AppState(client: native);
  await state.connect();
  final host = GlobalKey<_OverviewHostState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    final second = native.secondProfile;
    if (second != null && !second.isCompleted) {
      second.complete(native.profileResponse(1));
    }
    await tester.pump();
    state.dispose();
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(
      native.calls.every(
        (call) => const [
          'bootstrap',
          'profile.load',
          'profile.introduction',
          'space.activity',
        ].contains(call.$1),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: _OverviewHost(key: host, state: state),
      ),
    ),
  );
  await _frames(tester);
  expect(_overview, findsOneWidget);
  expect(_scroll(tester).position.maxScrollExtent, greaterThan(600));
  return (host: host, state: state);
}

Future<ScrollController> _cacheAndRemount(
  WidgetTester tester,
  GlobalKey<_OverviewHostState> host,
  AppState state,
) async {
  _scroll(tester).jumpTo(600);
  await tester.pump();
  expect(state.profileSpaces.forMember(1).overviewOffset, closeTo(600, 1));
  host.currentState!.show(false);
  await _frames(tester);
  expect(find.byType(AccountScreen), findsNothing);
  host.currentState!.show(true);
  await _frames(tester);
  final restored = _scroll(tester);
  expect(restored.initialScrollOffset, 600);
  expect(restored.offset, closeTo(600, 1));
  return restored;
}

void _macTest(String description, WidgetTesterCallback test) => testWidgets(
  description,
  test,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  _macTest(
    'cached overview remount restores its 600px offset without fresh reads',
    (tester) async {
      final native = _OverviewNative();
      final f = await _mount(tester, native);
      final originalController = _scroll(tester);
      final reads = native.calls.length;
      final restored = await _cacheAndRemount(tester, f.host, f.state);
      expect(restored, isNot(same(originalController)));
      expect(native.calls, hasLength(reads));
      expect(f.state.profileSpaces.forMember(1).section, 'overview');
      expect(native.named('space.activity'), isEmpty);
    },
  );

  _macTest(
    'cached 600px controller resets to zero after delayed second-account profile attaches',
    (tester) async {
      final native = _OverviewNative();
      final f = await _mount(tester, native);
      final controller = await _cacheAndRemount(tester, f.host, f.state);
      final pending = Completer<JsonMap>();
      native.secondProfile = pending;
      final reads = native.named('profile.load').length;
      native.changeAccount();
      // Let the first restoration callback run while the new identity still has
      // no overview attached. A single unconditional post-frame restore fails it.
      await _frames(tester);
      expect(f.state.accessRevision, 1);
      expect(native.named('profile.load'), hasLength(reads + 1));
      expect(native.named('profile.load').last.$3, 1);
      expect(_overview, findsNothing);
      expect(controller.hasClients, isFalse);
      expect(find.text('Local owner 1'), findsNothing);
      expect(f.state.profileSpaces.forMember(2).overviewOffset, 0);
      pending.complete(native.profileResponse(1));
      await _frames(tester);
      expect(_overview, findsOneWidget);
      expect(_scroll(tester), same(controller));
      expect(controller.initialScrollOffset, 600);
      expect(controller.position.maxScrollExtent, greaterThan(600));
      expect(controller.offset, closeTo(0, 1));
      expect(f.state.profileSpaces.forMember(2).overviewOffset, 0);
      expect(find.text('Local owner 2'), findsOneWidget);
      expect(find.text('Local owner 1'), findsNothing);
      expect(native.named('space.activity'), isEmpty);
    },
  );

  _macTest(
    'same-page activity tabs retain the overview controller and scroll position',
    (tester) async {
      final native = _OverviewNative()..allowActivity = true;
      final f = await _mount(tester, native);
      final controller = _scroll(tester);
      controller.jumpTo(600);
      await tester.pump();
      final profileReads = native.named('profile.load').length;
      final introductionReads = native.named('profile.introduction').length;
      await tester.tap(
        find.descendant(of: _sections, matching: find.text('主题')),
      );
      await _frames(tester);
      expect(find.text('Local overview tab topic'), findsOneWidget);
      expect(tester.widget<GlassSegmentedControl>(_sections).selectedIndex, 1);
      expect(native.named('space.activity'), hasLength(1));
      expect(
        f.state.profileSpaces.forMember(1).overviewOffset,
        closeTo(600, 1),
      );
      expect(find.byType(AccountScreen), findsOneWidget);
      await tester.tap(
        find.descendant(of: _sections, matching: find.text('概况')),
      );
      await _frames(tester);
      expect(_scroll(tester), same(controller));
      expect(controller.offset, closeTo(600, 1));
      expect(tester.widget<GlassSegmentedControl>(_sections).selectedIndex, 0);
      expect(native.named('profile.load'), hasLength(profileReads));
      expect(
        native.named('profile.introduction'),
        hasLength(introductionReads),
      );
      expect(native.named('space.activity'), hasLength(1));
      expect(f.state.profileSpaces.forMember(1).section, 'overview');
    },
  );
}
