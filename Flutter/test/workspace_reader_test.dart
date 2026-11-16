// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class ReaderFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return await response?.call(method, args) ?? {};
  }
}

const topicURL = 'https://www.nodeseek.com/post-17-1';
JsonMap threadSnapshot() => {
  'url': topicURL,
  'scrollOffset': 0,
  'thread': {
    'title': '真实阅读组件的夹具测试',
    'root': {
      'id': '0',
      'author': 'fixture',
      'authorID': 99,
      'blocks': [
        {'kind': 'text', 'text': 'A short fixture paragraph.'},
      ],
      'dateLabel': 'Today',
    },
    'replies': <JsonMap>[],
    'pages': <JsonMap>[],
  },
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1380, 880),
  }) async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(child: child),
        ),
      ),
    );
    await tester.pump();
  }

  AppState fixture(ReaderFixture native) {
    final state = AppState(client: native);
    state.connecting = false;
    state.domains['workspace'] = {
      'tabs': [
        {'id': '17', 'url': topicURL, 'title': 'Fixture'},
      ],
      'selectedTab': '17',
      'showReader': true,
      'posts': <JsonMap>[],
      'boards': [
        {'id': 'home', 'title': '首页'},
      ],
    };
    state.domains['session'] = {
      'account': 'signedIn',
      'owner': 1,
      'accessRevision': 0,
    };
    state.domains['settings'] = {'appearance': 'light'};
    state.readers[topicURL] = threadSnapshot();
    return state;
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    state.dispose();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets(
    'minimum desktop window uses one reading column without overflow',
    (tester) async {
      final native = ReaderFixture();
      native.response = (method, args) async =>
          method == 'reader.load' ? threadSnapshot() : {};
      final state = fixture(native);
      await mount(
        tester,
        WorkspaceScreen(state: state),
        size: const Size(780, 540),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('真实阅读组件的夹具测试'), findsOneWidget);
      expect(find.byKey(const ValueKey('forum-list-pane')), findsNothing);
      await cleanup(tester, state);
    },
  );
  testWidgets(
    'reading UI retains the real three-column layout at desktop width',
    (tester) async {
      final native = ReaderFixture();
      native.response = (method, args) async =>
          method == 'reader.load' ? threadSnapshot() : {};
      final state = fixture(native);
      await mount(tester, WorkspaceScreen(state: state));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      final list = find.byKey(const ValueKey('forum-list-pane'));
      final reader = find.byKey(const ValueKey('forum-reader-pane'));
      expect(list, findsOneWidget);
      expect(reader, findsOneWidget);
      expect(tester.getRect(list).right, lessThan(tester.getRect(reader).left));
      expect(tester.getRect(list).top, tester.getRect(reader).top);
      expect(find.text('真实阅读组件的夹具测试'), findsOneWidget);
      await cleanup(tester, state);
    },
  );
  testWidgets('paid chicken confirmation cannot cross an identity change', (
    tester,
  ) async {
    final native = ReaderFixture();
    native.response = (method, args) async =>
        method == 'reader.react' ? {'kind': 'confirmPaid'} : {};
    final state = fixture(native);
    await mount(
      tester,
      ReaderScreen(
        state: state,
        topic: TopicData({'id': '17', 'url': topicURL}),
      ),
    );
    await tester.tap(find.text('鸡腿'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('送鸡腿'), findsNWidgets(2));
    native.accessRevision = 1;
    await tester.tap(find.widgetWithText(DeskDialogAction, '送鸡腿'));
    await tester.pump();
    expect(native.calls.where((item) => item.$1 == 'reader.react').length, 1);
    await cleanup(tester, state);
  });
  testWidgets('page two without a root still renders replies and composer', (
    tester,
  ) async {
    final native = ReaderFixture();
    final state = fixture(native);
    const pageURL = 'https://www.nodeseek.com/post-17-2';
    state.readers[pageURL] = {
      'url': pageURL,
      'thread': {
        'title': 'Second page',
        'page': 2,
        'root': null,
        'replies': [
          {
            'id': '51',
            'author': 'Second-page author',
            'authorID': 99,
            'blocks': [
              {'kind': 'text', 'text': 'Reply without a main post'},
            ],
          },
        ],
        'pages': <JsonMap>[],
      },
    };
    await mount(
      tester,
      ReaderScreen(
        state: state,
        topic: TopicData({'id': '17', 'url': pageURL}),
      ),
    );
    expect(find.text('暂时无法打开帖子'), findsNothing);
    expect(find.text('Second page'), findsOneWidget);
    expect(find.text('Second-page author'), findsOneWidget);
    expect(find.text('写回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });
}
