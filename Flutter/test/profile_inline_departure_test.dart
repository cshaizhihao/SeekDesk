import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/profile_introduction_editor.dart';

const _signature = ValueKey('profile-introduction-signature');
const _save = ValueKey('profile-introduction-save');
const _sections = ValueKey('profile-space-sections');

/// All responses, including the one explicitly requested profile save, are
/// local values. Any unexpected native operation fails the fixture teardown.
class _DepartureNative extends NativeClient {
  _DepartureNative()
    : super(
        methods: MethodChannel('seekdesk.test.profile-departure.${_next++}'),
      );

  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Completer<JsonMap>? saveGate;

  JsonMap profile(int member) => {
    'id': member,
    'name': member == 1 ? 'Local owner' : 'Public member $member',
    'avatar': '',
    'topics': 12,
    'replies': 17,
    'following': 2,
    'followers': 3,
    'coin': 90,
    'signature_markdown': 'Public signature $member',
    'readme': 'Public introduction $member',
  };

  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'profile.load':
        final member = arguments['id'] ?? 1;
        if (member == 1 || member == 42) {
          return {'account': 'signedIn', 'profile': profile(member as int)};
        }
        break;
      case 'profile.introduction':
        return {
          'kind': 'ready',
          'data': {
            'signature': 'Original private signature',
            'readme': 'Original private introduction',
          },
        };
      case 'profile.saveIntroduction':
        if (saveGate case final pending?) return pending.future;
        break;
    }
    unexpected.add('$method $arguments');
    throw StateError('Profile departure fixture rejected $method');
  }
}

class _RouteObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
    super.didPop(route, previousRoute);
  }
}

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 40),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _edit(WidgetTester tester) async {
  final edit = _button('编辑签名与简介');
  await tester.ensureVisible(edit);
  await tester.tap(edit);
  await _frames(tester);
  expect(find.byType(ProfileIntroductionEditor), findsOneWidget);
  await tester.ensureVisible(find.byKey(_signature));
  await tester.enterText(
    find.byKey(_signature),
    'Keep this local unsaved signature',
  );
  await _frames(tester);
}

Future<AppState> _mount(
  WidgetTester tester,
  _DepartureNative native, {
  required Widget Function(AppState) home,
  List<NavigatorObserver> observers = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(1040, 950));
  final state = AppState(client: native);
  state.domains['session'] = {
    'account': 'signedIn',
    'owner': 1,
    'profile': native.profile(1),
  };
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (native.saveGate case final pending? when !pending.isCompleted) {
      pending.complete({'kind': 'unknown'});
    }
    await tester.pump();
    state.dispose();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(navigatorObservers: observers, home: home(state)),
    ),
  );
  await _frames(tester);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cancelled section drag keeps the draft and glass on overview', (
    tester,
  ) async {
    final native = _DepartureNative();
    final state = await _mount(
      tester,
      native,
      home: (state) => AccountScreen(state: state),
    );
    await _edit(tester);
    final editor = tester.element(find.byType(ProfileIntroductionEditor));
    final picker = find.byKey(_sections);
    final config = tester.widget<GlassSegmentedControl>(picker);
    final first = find.descendant(
      of: picker,
      matching: find.text(config.segments.first.label!),
    );
    final last = find.descendant(
      of: picker,
      matching: find.text(config.segments.last.label!),
    );
    final start = tester.getCenter(first), end = tester.getCenter(last);
    final pointer = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 20));
    await pointer.moveTo(Offset.lerp(start, end, .4)!);
    await tester.pump(const Duration(milliseconds: 40));
    await pointer.moveTo(end);
    await tester.pump(const Duration(milliseconds: 150));
    await pointer.moveTo(end);
    await pointer.up();
    await _settleRoute(tester);
    expect(find.text('放弃个人资料编辑？'), findsOneWidget);
    expect(find.byType(DeskDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
    await _settleRoute(tester);
    expect(
      tester.element(find.byType(ProfileIntroductionEditor)),
      same(editor),
    );
    expect(
      tester
          .widget<CupertinoTextField>(find.byKey(_signature))
          .controller!
          .text,
      'Keep this local unsaved signature',
    );
    expect(tester.widget<GlassSegmentedControl>(picker).selectedIndex, 0);
    final indicator = tester
        .widgetList<AnimatedGlassIndicator>(
          find.descendant(
            of: picker,
            matching: find.byType(AnimatedGlassIndicator),
          ),
        )
        .firstWhere((value) => value.paintBackground);
    expect(indicator.alignment.resolve(TextDirection.ltr).x, closeTo(-1, .001));
    expect(indicator.thickness, closeTo(0, .001));
    expect(state.hasWorkspaceLeaveGuard, isTrue);
    expect(native.named('profile.saveIntroduction'), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'standalone account header close confirms discard once and returns to the original page',
    (tester) async {
      final native = _DepartureNative(), observer = _RouteObserver();
      final state = await _mount(
        tester,
        native,
        observers: [observer],
        home: (state) => Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Original local page'),
                  CupertinoButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      CupertinoPageRoute<void>(
                        builder: (_) => AccountScreen(state: state),
                      ),
                    ),
                    child: const Text('Open standalone account'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open standalone account'));
      await _settleRoute(tester);
      final accountRoute = ModalRoute.of(
        tester.element(find.byType(AccountScreen)),
      )!;
      expect(accountRoute.isFirst, isFalse);
      await _edit(tester);
      expect(await state.flushDrafts(), isFalse);
      final close = find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '关闭账号',
      );
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await _settleRoute(tester);
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(find.text('放弃个人资料编辑？'), findsOneWidget);
      expect(
        observer.popped.where((route) => identical(route, accountRoute)),
        isEmpty,
      );

      // This is the only confirmation and there is no second close/back tap.
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
      await _settleRoute(tester);
      expect(find.byType(AccountScreen), findsNothing);
      expect(find.byType(ProfileIntroductionEditor), findsNothing);
      expect(find.byType(DeskDialog), findsNothing);
      expect(find.text('Original local page').hitTestable(), findsOneWidget);
      expect(
        observer.popped.where((route) => identical(route, accountRoute)),
        hasLength(1),
      );
      expect(
        observer.popped.whereType<CupertinoDialogRoute<bool>>(),
        hasLength(1),
      );
      expect(state.hasWorkspaceLeaveGuard, isFalse);
      expect(await state.flushDrafts(), isTrue);
      expect(native.named('profile.saveIntroduction'), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'late saved introduction from a retargeted account leaves member 42 cache and selected section intact',
    (tester) async {
      final native = _DepartureNative();
      int? member;
      late StateSetter retarget;
      final state = await _mount(
        tester,
        native,
        home: (state) => StatefulBuilder(
          builder: (context, setState) {
            retarget = setState;
            return AccountScreen(
              key: const ValueKey('retained-profile-page'),
              state: state,
              memberId: member,
            );
          },
        ),
      );
      await _edit(tester);
      final accountElement = tester.element(find.byType(AccountScreen));
      final editorElement = tester.element(
        find.byType(ProfileIntroductionEditor),
      );
      native.saveGate = Completer<JsonMap>();
      await tester.tap(find.byKey(_save));
      await _frames(tester);
      expect(native.named('profile.saveIntroduction'), hasLength(1));
      expect(tester.widget<DeskButton>(find.byKey(_save)).busy, isTrue);

      final target = state.profileSpaces.forMember(42);
      target.section = 'comments';
      target.profile = native.profile(42);
      target.introduction = {'readme': 'Cached member 42 introduction'};
      final activity = target.activity('comments');
      activity.activate(
        revision: 0,
        memberId: 42,
        route: 'comments',
        owner: 1,
        signedIn: true,
      );
      activity.acceptPage(
        page: 2,
        hasNext: true,
        items: [
          {
            'postId': 42002,
            'title': 'Member 42 cached comment',
            'floor': 9,
            'text': 'Retained second page comment',
            'url': 'https://www.nodeseek.com/post-42002-1#9',
          },
        ],
      );
      retarget(() => member = 42);
      await _frames(tester);
      expect(tester.element(find.byType(AccountScreen)), same(accountElement));
      expect(
        tester.element(find.byType(ProfileIntroductionEditor)),
        same(editorElement),
      );
      expect(state.accessRevision, 0);
      expect(target.section, 'comments');
      expect(
        tester
            .widget<GlassSegmentedControl>(find.byKey(_sections))
            .selectedIndex,
        2,
      );
      final targetProfile = target.profile,
          targetIntroduction = target.introduction;
      final profileReads = native.named('profile.load').length;
      final introductionReads = native.named('profile.introduction').length;
      expect(native.named('profile.load').last.$2['id'], 42);
      expect(targetProfile['id'], 42);
      expect(targetIntroduction['readme'], 'Public introduction 42');

      native.saveGate!.complete({'kind': 'saved'});
      await _frames(tester);
      expect(find.byType(ProfileIntroductionEditor), findsNothing);
      expect(tester.element(find.byType(AccountScreen)), same(accountElement));
      expect(target.section, 'comments');
      expect(
        tester
            .widget<GlassSegmentedControl>(find.byKey(_sections))
            .selectedIndex,
        2,
      );
      expect(target.profile, same(targetProfile));
      expect(target.introduction, same(targetIntroduction));
      expect(target.activity('comments'), same(activity));
      expect(activity.page, 2);
      expect(activity.items.single['title'], 'Member 42 cached comment');
      expect(
        find.text('Member 42 cached comment').hitTestable(),
        findsOneWidget,
      );
      expect(native.named('profile.load'), hasLength(profileReads));
      expect(
        native.named('profile.introduction'),
        hasLength(introductionReads),
      );
      expect(native.named('space.activity'), isEmpty);
      expect(native.named('profile.saveIntroduction'), hasLength(1));
      expect(state.hasWorkspaceLeaveGuard, isFalse);
      expect(await state.flushDrafts(), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
