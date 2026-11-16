import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class AccountDesignFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return await response?.call(method, arguments) ?? {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  JsonMap basic([int id = 1]) => {
    'id': id,
    'name': 'Member $id',
    'avatar': '',
    'topics': 18,
    'replies': 32,
    'following': 7,
    'followers': 12,
    'coin': 2048,
    'rank': 5,
    'bio': '分享记录与讨论。',
    'joined': '2024-01-01',
  };

  AppState owner(AccountDesignFixture native) {
    final state = AppState(client: native);
    state.domains['session'] = {
      'account': 'signedIn',
      'owner': 1,
      'profile': basic(),
    };
    native.response = (method, arguments) async => switch (method) {
      'profile.load' => {'profile': basic()},
      'profile.introduction' => {'kind': 'ready', 'data': <String, dynamic>{}},
      _ => {},
    };
    return state;
  }

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1100, 1000),
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, Iterable<AppState> states) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final state in states) {
      state.dispose();
    }
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.ensureVisible(button('编辑签名与简介'));
    await tester.tap(button('编辑签名与简介'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'basic identity is visible during introduction load and local retry does not reload it',
    (tester) async {
      final native = AccountDesignFixture();
      final state = owner(native);
      final pending = Completer<JsonMap>();
      var attempts = 0;
      native.response = (method, arguments) async => switch (method) {
        'profile.load' => {'profile': basic()},
        'profile.introduction' =>
          ++attempts == 1
              ? pending.future
              : {
                  'kind': 'ready',
                  'data': {'readme': 'Recovered README'},
                },
        _ => {},
      };
      await mount(tester, AccountScreen(state: state));
      expect(find.text('Member 1'), findsOneWidget);
      expect(find.text('正在读取个人简介…'), findsOneWidget);
      expect(button('编辑签名与简介'), findsNothing);
      pending.complete({'kind': 'unavailable'});
      await tester.pump();
      expect(find.text('Member 1'), findsOneWidget);
      expect(button('重新读取简介'), findsOneWidget);
      await tester.tap(button('重新读取简介'));
      await tester.pump();
      expect(button('编辑签名与简介'), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'profile.load'),
        hasLength(1),
      );
      expect(
        native.calls.where((call) => call.$1 == 'profile.introduction'),
        hasLength(2),
      );
      await cleanup(tester, [state]);
    },
  );

  for (final kind in ['signedOut']) {
    testWidgets(
      'introduction $kind has a persistent recovery beside retained identity',
      (tester) async {
        final native = AccountDesignFixture();
        final state = owner(native);
        native.response = (method, arguments) async => switch (method) {
          'profile.load' => {'profile': basic()},
          'profile.introduction' => {'kind': kind},
          _ => {},
        };
        await mount(tester, AccountScreen(state: state));
        expect(find.text('Member 1'), findsOneWidget);
        expect(button('编辑签名与简介'), findsNothing);
        expect(
          button(kind == 'verification' ? '验证访问' : '登录 NodeSeek'),
          findsOneWidget,
        );
        expect(button('重新读取简介'), findsOneWidget);
        expect(
          native.calls.where((call) => call.$1.startsWith('session.')),
          isEmpty,
        );
        await cleanup(tester, [state]);
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'narrow account and editor wrap controls at text scale $scale',
      (tester) async {
        final native = AccountDesignFixture();
        final state = owner(native);
        await mount(
          tester,
          AccountScreen(state: state),
          size: const Size(360, 1100),
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final statistics = find.byKey(const ValueKey('account-statistics'));
        expect(tester.getSize(statistics).width, lessThanOrEqualTo(312));
        expect(
          tester
              .getTopLeft(
                find.descendant(of: statistics, matching: find.text('主题')),
              )
              .dy,
          lessThan(tester.getTopLeft(find.text('鸡腿')).dy),
        );
        await openEditor(tester);
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byType(CupertinoTextField).first,
          'Local draft',
        );
        await tester.pump();
        expect(tester.widget<DeskButton>(button('保存资料')).onTap, isNotNull);
        expect(tester.getRect(button('保存资料')).right, lessThanOrEqualTo(336));
        expect(await state.flushDrafts(), isFalse);
        await cleanup(tester, [state]);
      },
    );
  }

  testWidgets(
    'public profile shows deduplicated role display names without an edit action',
    (tester) async {
      final native = AccountDesignFixture();
      final state = AppState(client: native);
      native.response = (method, arguments) async => {
        ...basic(42),
        'roles': [
          {'display_text': '管理'},
          {'display_text': '管理'},
          {'display_text': '  '},
        ],
        'readme': '',
      };
      await mount(tester, AccountScreen(state: state, memberId: 42));
      expect(find.text('管理'), findsOneWidget);
      expect(find.text('等级 Lv.5'), findsOneWidget);
      expect(find.text('NodeSeek · #42'), findsOneWidget);
      expect(button('编辑签名与简介'), findsNothing);
      expect(
        native.calls.where((call) => call.$1 == 'profile.introduction'),
        isEmpty,
      );
      await cleanup(tester, [state]);
    },
  );

  testWidgets(
    'replacing AppState detaches the old source and rejects its completion',
    (tester) async {
      final oldNative = AccountDesignFixture(),
          newNative = AccountDesignFixture();
      final oldState = owner(oldNative), newState = owner(newNative);
      final pending = Completer<JsonMap>();
      oldNative.response = (method, arguments) async => pending.future;
      newNative.response = (method, arguments) async => method == 'profile.load'
          ? {
              'profile': {...basic(), 'name': 'Replacement owner'},
            }
          : {'kind': 'ready', 'data': <String, dynamic>{}};
      var current = oldState;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AccountScreen(state: current);
          },
        ),
      );
      update(() => current = newState);
      await tester.pump();
      pending.complete({
        'profile': {...basic(), 'name': 'Retired owner'},
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('Retired owner'), findsNothing);
      expect(find.text('Replacement owner'), findsOneWidget);
      oldNative.accessRevision = 1;
      oldState.showMessage('Old source notification');
      await tester.pump();
      expect(find.text('Replacement owner'), findsOneWidget);
      expect(
        newNative.calls.where((call) => call.$1 == 'profile.load'),
        hasLength(1),
      );
      await cleanup(tester, [oldState, newState]);
    },
  );

  testWidgets('editor captures account revision before its first save', (
    tester,
  ) async {
    final native = AccountDesignFixture();
    final state = owner(native);
    await mount(tester, AccountScreen(state: state));
    await openEditor(tester);
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'Original account draft',
    );
    native.accessRevision = 1;
    state.domains['session'] = {'account': 'signedIn', 'owner': 2};
    state.showMessage('Account changed');
    await tester.pump();
    await tester.tap(button('保存资料'));
    await tester.pump();
    expect(find.text('账号已经变化，请关闭后重新打开当前账号资料。'), findsOneWidget);
    expect(
      native.calls.where((call) => call.$1 == 'profile.saveIntroduction'),
      isEmpty,
    );
    expect(find.text('Original account draft'), findsOneWidget);
    await cleanup(tester, [state]);
  });
}
