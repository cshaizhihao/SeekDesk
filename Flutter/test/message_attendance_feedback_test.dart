import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// All requests terminate in this fixture; no platform or forum calls are made.
class FeedbackFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return await respond?.call(method, args) ?? {};
  }
}

const conversation = <String, dynamic>{
  'kind': 'conversation',
  'peer': 20,
  'items': <JsonMap>[],
  'draft': 'Fixture draft',
  'loading': false,
};
const extensionFixture = <String, dynamic>{
  'items': [
    {
      'id': 'attendance',
      'title': '签到工具',
      'description': 'Local fixture',
      'installed': true,
      'enabled': true,
      'active': true,
    },
  ],
  'settings': {
    'attendance': {'mode': 'fixed', 'automatic': false},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  AppState signedIn(FeedbackFixture native) {
    final state = AppState(client: native);
    state.domains['session'] = {
      'account': 'signedIn',
      'owner': 101,
      'canCompose': true,
    };
    return state;
  }

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(home: CupertinoPageScaffold(child: child)),
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

  InboxScreen inbox(AppState state) => InboxScreen(
    state: state,
    initialPeer: 20,
    peerName: 'Fixture peer',
    standalone: true,
  );

  for (final throws in [false, true]) {
    testWidgets(
      'standalone private message ${throws ? 'native error' : 'unknown response'} is visible and preserves its draft',
      (tester) async {
        final native = FeedbackFixture();
        native.respond = (method, args) async {
          if (method == 'inbox.load') return conversation;
          if (method == 'inbox.send') {
            if (throws) {
              throw const NativeFailure('network', 'Fixture timeout');
            }
            return {'kind': 'unknown'};
          }
          return {};
        };
        final state = signedIn(native);
        await mount(tester, inbox(state));
        await tester.tap(button('发送'));
        await tester.pump();
        expect(find.text('未确认发送成功，草稿已保留。请先刷新对话核对，再决定是否重试。'), findsOneWidget);
        expect(
          tester
              .widget<CupertinoTextField>(find.byType(CupertinoTextField))
              .controller
              ?.text,
          'Fixture draft',
        );
        await tester.pump(const Duration(seconds: 6));
        expect(
          native.calls.where((call) => call.$1 == 'inbox.send'),
          hasLength(1),
        );
        expect(
          native.calls.where((call) => call.$1 == 'inbox.load'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      },
    );
  }

  testWidgets('draft-save failure is inline and prevents sending', (
    tester,
  ) async {
    final native = FeedbackFixture();
    native.respond = (method, args) async {
      if (method == 'inbox.load') return conversation;
      if (method == 'inbox.updateDraft') {
        throw const NativeFailure('disk', 'Fixture save failure');
      }
      return {};
    };
    final state = signedIn(native);
    await mount(tester, inbox(state));
    await tester.enterText(find.byType(CupertinoTextField), 'Unsaved fixture');
    await tester.tap(button('发送'));
    await tester.pump();
    expect(find.text('私信草稿保存失败，请重试保存后再发送或关闭。'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller
          ?.text,
      'Unsaved fixture',
    );
    expect(native.calls.any((call) => call.$1 == 'inbox.send'), false);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('message feedback clears when its account changes', (
    tester,
  ) async {
    final native = FeedbackFixture();
    native.respond = (method, args) async =>
        method == 'inbox.load' ? conversation : {'kind': 'unknown'};
    final state = signedIn(native);
    await mount(tester, inbox(state));
    await tester.tap(button('发送'));
    await tester.pump();
    expect(find.textContaining('未确认发送成功'), findsOneWidget);
    native.accessRevision++;
    state.domains['session'] = {'account': 'signedOut'};
    state.domains.remove('inbox');
    state.showMessage('Fixture account change');
    await tester.pump();
    expect(find.textContaining('未确认发送成功'), findsNothing);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller
          ?.text,
      isEmpty,
    );
    await cleanup(tester, state);
  });

  Future<void> openAttendance(WidgetTester tester, AppState state) async {
    state.domains['extensions'] = extensionFixture;
    await mount(tester, ExtensionsScreen(state: state));
    await tester.tap(find.byKey(const ValueKey('extension-card-attendance')));
    await tester.pump();
    await tester.tap(button('立即签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  const results = <(JsonMap, String)>[
    (
      {'kind': 'completed', 'gain': 5, 'current': 100},
      '今日已签到 · 获得 5 个鸡腿 · 当前 100 个鸡腿',
    ),
    ({'kind': 'alreadyCompleted'}, '今天已在 NodeSeek 签到'),
    ({'kind': 'signedOut'}, '请登录 NodeSeek 后继续签到'),
    ({'kind': 'verification'}, '签到需要完成 NodeSeek 验证，请先完成验证后再试。'),
    ({'kind': 'failed'}, '签到暂未成功，请稍后重试。'),
    ({'kind': 'futureKind'}, '未确认签到结果，请刷新账号信息核对。'),
  ];
  for (final (result, expected) in results) {
    testWidgets('attendance ${result['kind']} displays the actual outcome', (
      tester,
    ) async {
      final native = FeedbackFixture();
      native.respond = (method, args) async =>
          method == 'attendance.perform' ? result : extensionFixture;
      final state = signedIn(native);
      await openAttendance(tester, state);
      expect(
        native.calls.any((call) => call.$1 == 'attendance.perform'),
        false,
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.message, expected);
      expect(
        native.calls.where((call) => call.$1 == 'attendance.perform'),
        hasLength(1),
      );
      if (result['kind'] == 'verification') {
        await tester.ensureVisible(button('打开 NodeSeek 验证'));
        await tester.tap(button('打开 NodeSeek 验证'));
        await tester.pump();
        expect(
          native.calls.where((call) => call.$1 == 'session.verify').single.$2,
          {'url': 'https://www.nodeseek.com/'},
        );
      }
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    });
  }

  testWidgets('an account change during confirmation prevents attendance', (
    tester,
  ) async {
    final native = FeedbackFixture();
    native.respond = (method, args) async => extensionFixture;
    final state = signedIn(native);
    await openAttendance(tester, state);
    native.accessRevision++;
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(native.calls.any((call) => call.$1 == 'attendance.perform'), false);
    await cleanup(tester, state);
  });

  testWidgets('a pending attendance request prevents duplicate submissions', (
    tester,
  ) async {
    final native = FeedbackFixture();
    final pending = Completer<JsonMap>();
    native.respond = (method, args) async =>
        method == 'attendance.perform' ? pending.future : extensionFixture;
    final state = signedIn(native);
    await openAttendance(tester, state);
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<DeskButton>(button('立即签到')).onTap, isNull);
    expect(
      native.calls.where((call) => call.$1 == 'attendance.perform'),
      hasLength(1),
    );
    pending.complete({'kind': 'completed'});
    await tester.pump();
    expect(state.message, '今日签到成功');
    await cleanup(tester, state);
  });

  testWidgets(
    'disabling the extension during confirmation prevents attendance',
    (tester) async {
      final native = FeedbackFixture();
      native.respond = (method, args) async => extensionFixture;
      final state = signedIn(native);
      await openAttendance(tester, state);
      state.domains['extensions'] = {
        ...extensionFixture,
        'items': [
          for (final item in jsonItems(extensionFixture['items']))
            {...item, 'active': false, 'enabled': false},
        ],
      };
      state.showMessage('Fixture extension disabled');
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        native.calls.any((call) => call.$1 == 'attendance.perform'),
        isFalse,
      );
      expect(tester.widget<DeskButton>(button('立即签到')).onTap, isNull);
      await cleanup(tester, state);
    },
  );
}
