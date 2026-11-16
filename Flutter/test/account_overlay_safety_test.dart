import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class ProfileNativeFixture extends NativeClient {
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
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    AppState? overlays,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          builder: overlays == null
              ? null
              : (context, child) =>
                    ExtensionOverlays(state: overlays, child: child!),
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
  }

  AppState owner(ProfileNativeFixture native) {
    final state = AppState(client: native);
    state.domains['session'] = {
      'account': 'signedIn',
      'owner': 1,
      'profile': {'id': 1, 'name': 'Owner'},
    };
    native.response = (method, args) async => switch (method) {
      'profile.load' => {
        'profile': {'id': 1, 'name': 'Owner'},
      },
      'profile.introduction' => {
        'kind': 'ready',
        'data': {
          'signature': 'Original signature',
          'readme': 'Original readme',
        },
      },
      _ => {},
    };
    return state;
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(button('编辑签名与简介'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'Changed signature',
    );
    await tester.pump();
  }

  testWidgets('public profile maps native member fields and readme', (
    tester,
  ) async {
    final native = ProfileNativeFixture();
    native.response = (method, args) async => {
      'member_id': 42,
      'member_name': 'Public member',
      'nPost': 13,
      'signature_markdown': 'Public signature',
      'readme': 'Public readme',
    };
    final state = AppState(client: native);
    await mount(tester, AccountScreen(state: state, memberId: 42));
    expect(find.text('Public member'), findsOneWidget);
    expect(find.text('NodeSeek · #42'), findsOneWidget);
    expect(find.text('13'), findsOneWidget);
    expect(find.text('编辑签名与简介'), findsNothing);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('identity changes serialize profile reloads and clear old data', (
    tester,
  ) async {
    final pending = Completer<JsonMap>();
    final native = ProfileNativeFixture();
    final state = owner(native);
    var loads = 0;
    native.response = (method, args) async {
      if (method == 'profile.load') {
        loads++;
        if (loads == 1) return pending.future;
        return {
          'profile': {'id': 2, 'name': 'New owner'},
          'accessRevision': 1,
        };
      }
      return {
        'kind': 'ready',
        'data': {'signature': 'New signature'},
      };
    };
    await mount(tester, AccountScreen(state: state));
    native.accessRevision = 1;
    state.domains['session'] = {'account': 'signedIn', 'owner': 2};
    state.showMessage('fixture identity event');
    await tester.pump();
    expect(loads, 1);
    pending.complete({
      'profile': {'id': 1, 'name': 'Old private owner'},
    });
    await tester.pump();
    expect(loads, 2);
    expect(find.text('Old private owner'), findsNothing);
    expect(find.text('New owner'), findsOneWidget);
    await cleanup(tester, state);
  });

  testWidgets('unknown profile save retains edited data and open editor', (
    tester,
  ) async {
    final native = ProfileNativeFixture();
    final state = owner(native);
    await mount(tester, AccountScreen(state: state));
    await edit(tester);
    expect(await state.flushDrafts(), false);
    native.response = (method, args) async => {'kind': 'unknown'};
    await tester.tap(button('保存资料'));
    await tester.pump();
    expect(find.text('编辑个人资料'), findsOneWidget);
    expect(find.text('Changed signature'), findsOneWidget);
    expect(find.text('没有确认保存成功，请保留内容并重新检查账号资料。'), findsOneWidget);
    await cleanup(tester, state);
  });

  testWidgets(
    'saved profile closes dirty editor without discard confirmation',
    (tester) async {
      final native = ProfileNativeFixture();
      final state = owner(native);
      await mount(tester, AccountScreen(state: state));
      await edit(tester);
      final previous = native.response!;
      native.response = (method, args) async =>
          method == 'profile.saveIntroduction'
          ? {'kind': 'saved'}
          : previous(method, args);
      await tester.tap(button('保存资料'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('编辑个人资料'), findsNothing);
      expect(find.byType(DeskDialog), findsNothing);
      expect(find.byType(AccountScreen), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  testWidgets('back navigation asks once and confirmed discard exits', (
    tester,
  ) async {
    final native = ProfileNativeFixture();
    final state = owner(native);
    await mount(tester, AccountScreen(state: state));
    await edit(tester);
    final editor = tester.element(find.text('编辑个人资料'));
    Navigator.of(editor).maybePop();
    await tester.pump();
    expect(find.byType(DeskDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('编辑个人资料'), findsNothing);
    expect(find.byType(DeskDialog), findsNothing);
    await cleanup(tester, state);
  });

  testWidgets(
    'office overlay excludes editor focus and keeps the restore action distinct',
    (tester) async {
      final native = ProfileNativeFixture();
      final state = AppState(client: native);
      final focus = FocusNode();
      JsonMap extensions(bool presented) => {
        'items': [
          {'id': 'office', 'active': true},
        ],
        'settings': {
          'office': {
            'presented': presented,
            'title': 'Project',
            'button': '返回阅读',
          },
        },
      };
      state.domains['extensions'] = extensions(false);
      await mount(
        tester,
        CupertinoPageScaffold(child: CupertinoTextField(focusNode: focus)),
        overlays: state,
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, true);
      state.domains['extensions'] = extensions(true);
      state.showMessage('fixture overlay change');
      await tester.pump();
      expect(focus.hasFocus, false);
      expect(button('恢复窗口'), findsOneWidget);
      expect(button('返回阅读'), findsNothing);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
      focus.dispose();
    },
  );

  testWidgets(
    'keyword popup uses independent glass surface and readable content',
    (tester) async {
      final native = ProfileNativeFixture();
      final state = AppState(client: native);
      state.domains['extensions'] = {
        'watchPopup': {
          'id': 'fixture',
          'hits': [
            {
              'words': ['VPS'],
              'post': {
                'id': '17',
                'title': 'A matching post',
                'url': 'https://www.nodeseek.com/post-17-1',
              },
            },
          ],
        },
      };
      await mount(
        tester,
        const CupertinoPageScaffold(child: SizedBox.expand()),
        overlays: state,
      );
      expect(find.text('A matching post'), findsOneWidget);
      expect(find.byType(DeskGlassPanel), findsOneWidget);
      expect(
        find.ancestor(of: button(''), matching: find.byType(GlassContainer)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
  );
}
