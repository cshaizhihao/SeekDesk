import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/activity_screen.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class DirectoryNativeFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return await respond?.call(method, arguments) ?? {};
  }
}

class DirectoryStateFixture extends AppState {
  DirectoryStateFixture({required super.client});
  final opened = <TopicData>[];
  @override
  Future<void> openTopic(TopicData topic) async {
    opened.add(topic);
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    AppState state, {
    String route = 'comments',
    int member = 101,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: ActivityScreen(state: state, memberId: member, route: route),
        ),
      ),
    );
    await tester.pump();
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  testWidgets(
    'activity pagination preserves member route and opens its exact comment destination',
    (tester) async {
      final native = DirectoryNativeFixture();
      native.respond = (method, args) async => method == 'space.activity'
          ? {
              'accessRevision': 0,
              'items': [
                {
                  'id': '77-31',
                  'postId': 77,
                  'floor': 31,
                  'title': 'Fixture page ${args['page']}',
                  'text': 'Comment body',
                  'url': 'https://www.nodeseek.com/post-77-2#31',
                },
              ],
              'hasNext': args['page'] == 1,
            }
          : {};
      final state = DirectoryStateFixture(client: native);
      await mount(tester, state, member: 202);
      expect(find.text('Fixture page 1'), findsOneWidget);
      await tester.tap(button('下一页'));
      await tester.pump();
      final request = native.calls.last.$2;
      expect(request['memberId'], 202);
      expect(request['route'], 'comments');
      expect(request['page'], 2);
      expect(find.text('Fixture page 2'), findsOneWidget);
      expect(tester.widget<DeskButton>(button('下一页')).onTap, isNull);
      await tester.tap(find.text('Fixture page 2'));
      expect(state.opened.single.id, '77');
      expect(state.opened.single.url, 'https://www.nodeseek.com/post-77-2#31');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'a private directory clears immediately after account change and ignores its late response',
    (tester) async {
      final native = DirectoryNativeFixture();
      final pending = Completer<JsonMap>();
      native.respond = (method, args) async =>
          method == 'space.members' ? pending.future : {};
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 101};
      await mount(tester, state, route: 'fans');
      expect(native.calls.single.$1, 'space.members');
      native.accessRevision = 1;
      state.domains['session'] = {'account': 'signedIn', 'owner': 303};
      await state.act('session.refresh');
      await tester.pump();
      expect(find.text('只能读取当前账号的粉丝和关注列表。'), findsOneWidget);
      pending.complete({
        'accessRevision': 0,
        'items': [
          {'id': 202, 'name': 'Old private member'},
        ],
      });
      await tester.pump();
      expect(find.text('Old private member'), findsNothing);
      expect(
        native.calls.where((call) => call.$1 == 'space.members').length,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'member rows open profile and do not pretend the private API is paginated',
    (tester) async {
      final native = DirectoryNativeFixture();
      native.respond = (method, args) async => switch (method) {
        'space.members' => {
          'accessRevision': 0,
          'items': [
            {'id': 202, 'name': 'Member', 'avatar': ''},
          ],
          'hasNext': false,
        },
        'profile.load' => {'id': 202, 'name': 'Member'},
        _ => {},
      };
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 101};
      await mount(tester, state, route: 'follow');
      expect(button('下一页'), findsNothing);
      await tester.tap(find.text('Member'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<AccountScreen>(find.byType(AccountScreen)).memberId,
        202,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      state.dispose();
    },
  );

  testWidgets(
    'directory failures can be retried without replacing a different page',
    (tester) async {
      final native = DirectoryNativeFixture();
      var attempts = 0;
      native.respond = (method, args) async {
        if (method != 'space.activity') return {};
        if (attempts++ == 0) {
          throw const NativeFailure('offline', 'Fixture unavailable');
        }
        return {
          'items': [
            {
              'postId': 77,
              'title': 'Restored activity',
              'url': 'https://www.nodeseek.com/post-77-1',
            },
          ],
          'hasNext': false,
        };
      };
      final state = AppState(client: native);
      await mount(tester, state, route: 'discussions');
      expect(find.text('Fixture unavailable'), findsOneWidget);
      await tester.tap(button('重新读取'));
      await tester.pump();
      expect(find.text('Restored activity'), findsOneWidget);
      expect(attempts, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
