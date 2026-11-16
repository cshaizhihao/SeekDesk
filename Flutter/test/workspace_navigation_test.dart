// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_navigation_picker.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _tabURL = 'https://www.nodeseek.com/post-991-1';

class NavigationFixture extends NativeClient {
  final calls = <String>[];
  JsonMap extensions = {
    'items': [
      {'id': 'hot', 'active': true},
      {'id': 'keywords', 'active': true},
    ],
    'unread': 6,
  };
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add(method);
    if (method == 'extensions.list') return {...extensions};
    if (method == 'rankings.load') return {'posts': <JsonMap>[]};
    if (method == 'reader.load') {
      return {
        'url': args['url'],
        'thread': {
          'title': '保留的本地标签',
          'root': {'id': '0', 'author': 'Fixture', 'blocks': <JsonMap>[]},
          'replies': <JsonMap>[],
        },
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<AppState> mount(WidgetTester tester, NavigationFixture native) async {
    await tester.binding.setSurfaceSize(const Size(1380, 880));
    final state = AppState(client: native);
    state.connecting = false;
    state.domains['workspace'] = {
      'posts': <JsonMap>[],
      'tabs': [
        {'id': '991', 'url': _tabURL, 'title': '保留的本地标签'},
        {
          'id': '992',
          'url': 'https://www.nodeseek.com/post-992-1',
          'title': '另一标签',
        },
      ],
      'selectedTab': '991',
      'showReader': false,
      'board': '',
      'boards': [
        {'id': '', 'title': '最新帖子'},
        {'id': 'daily', 'title': '日常'},
        {'id': 'tech', 'title': '技术'},
      ],
    };
    state.domains['extensions'] = {...native.extensions};
    state.domains['session'] = {
      'account': 'signedOut',
      'unread': {'mentions': 2, 'replies': 3, 'messages': 4},
    };
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: WorkspaceScreen(state: state),
        ),
      ),
    );
    await tester.pump();
    return state;
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets(
    'restored sidebar and toolbar retain unread counts and forum tabs',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = NavigationFixture();
      final state = await mount(tester, native);
      try {
        final sidebar = find.byType(DeskWorkspaceSidebar);
        final footer = find.byKey(const ValueKey('sidebar-footer'));
        final control = tester.widget<DeskNavigationPicker>(footer);
        expect(control.extent, 34);
        expect(tester.getSize(footer).height, 136);
        expect(control.selectedIndex, isNull);
        expect(control.segments.map((segment) => segment.id), [
          'friends',
          'my',
          'extensions',
          'settings',
        ]);
        final ordered = [
          '发布新帖',
          '最新帖子',
          '论坛版块',
          '快捷功能区',
          '热榜',
          '友情链接',
          '我的',
          '扩展中心',
          '设置',
        ];
        for (var index = 1; index < ordered.length; index++) {
          expect(
            tester
                .getCenter(
                  find.descendant(
                    of: sidebar,
                    matching: find.text(ordered[index]),
                  ),
                )
                .dy,
            greaterThan(
              tester
                  .getCenter(
                    find.descendant(
                      of: sidebar,
                      matching: find.text(ordered[index - 1]),
                    ),
                  )
                  .dy,
            ),
          );
        }
        expect(tester.widget<DeskWorkspaceSidebar>(sidebar).selectedBoard, '');
        expect(tester.widget<DeskWorkspaceSidebar>(sidebar).extensionUnread, 6);
        expect(
          find.descendant(of: footer, matching: find.text('6')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sidebar, matching: find.text('9')),
          findsNothing,
        );
        final notification = find.bySemanticsLabel('消息，9 条未读');
        expect(notification, findsOneWidget);
        expect(
          find.descendant(
            of: notification,
            matching: find.byWidgetPredicate(
              (widget) => widget is DeskIcon && widget.label == '消息',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: notification, matching: find.text('9')),
          findsOneWidget,
        );

        final tabs = state.workspace.tabs.map((topic) => topic.id).toList();
        final selectedTab = state.workspace.selectedTab;
        final footerBounds = tester.getRect(footer);
        await tester.tap(
          find.descendant(of: footer, matching: find.text('设置')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.widget<DeskNavigationPicker>(footer).selectedIndex, 3);
        expect(
          tester.widget<DeskWorkspaceSidebar>(sidebar).selectedBoard,
          isNull,
        );
        expect(find.text('偏好设置'), findsOneWidget);
        expect(native.calls, contains('settings.get'));
        final beforeReturn = native.calls.length;
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is DeskButton && widget.label == '返回论坛',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.widget<DeskNavigationPicker>(footer).selectedIndex,
          isNull,
        );
        expect(tester.widget<DeskWorkspaceSidebar>(sidebar).selectedBoard, '');
        expect(find.text('偏好设置'), findsNothing);
        expect(find.byKey(const ValueKey('forum-list-pane')), findsOneWidget);
        expect(tester.getRect(footer), footerBounds);
        expect(state.workspace.tabs.map((topic) => topic.id), tabs);
        expect(state.workspace.selectedTab, selectedTab);
        expect(
          native.calls
              .skip(beforeReturn)
              .where(
                (method) => [
                  'listing.refresh',
                  'listing.selectBoard',
                  'reader.overview',
                ].contains(method),
              ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester, state);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'extension badge excludes forum unread and hides when keywords are disabled',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = NavigationFixture();
      final state = await mount(tester, native);
      try {
        native.extensions = {
          ...native.extensions,
          'items': [
            {'id': 'hot', 'active': true},
            {'id': 'keywords', 'active': false},
          ],
        };
        await state.act('extensions.list', {}, 'extensions');
        await tester.pump();
        final sidebar = find.byType(DeskWorkspaceSidebar);
        expect(tester.widget<DeskWorkspaceSidebar>(sidebar).extensionUnread, 0);
        expect(
          find.descendant(of: sidebar, matching: find.text('6')),
          findsNothing,
        );
        expect(
          find.descendant(of: sidebar, matching: find.text('9')),
          findsNothing,
        );
        expect(find.bySemanticsLabel('消息，9 条未读'), findsOneWidget);
        expect(find.bySemanticsLabel('扩展中心'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester, state);
        semantics.dispose();
      }
    },
  );
  testWidgets('workspace refresh shortcut is ignored while typing search', (
    tester,
  ) async {
    final native = NavigationFixture();
    final state = await mount(tester, native);
    await chord(tester, LogicalKeyboardKey.keyR);
    expect(native.calls.where((value) => value == 'listing.refresh').length, 1);
    await chord(tester, LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'typed query',
    );
    await chord(tester, LogicalKeyboardKey.keyR);
    expect(native.calls.where((value) => value == 'listing.refresh').length, 1);
    await close(tester, state);
  });
}
