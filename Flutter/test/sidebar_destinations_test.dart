import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/friend_links.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/screens/friend_links_screen.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _url = 'https://www.nodeseek.com/post-1731-1';

class _NavigationNative extends NativeClient {
  _NavigationNative()
    : super(methods: const MethodChannel('seekdesk.test.sidebar-destinations'));
  final calls = <(String, JsonMap)>[];
  String board = '';
  bool reading = true;
  bool hot = false;
  bool covered = false;
  bool closed = false;
  JsonMap settings = {'workspace.sidebarWidth': 228.0};
  JsonMap get workspace => {
    'board': board,
    'showReader': reading,
    'posts': <JsonMap>[],
    'tabs': [
      {'id': '1731', 'url': _url, 'title': 'Navigation fixture'},
    ],
    'selectedTab': '1731',
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };
  JsonMap get extensions => {
    'items': [
      {
        'id': 'hot',
        'title': 'NodeSeek 热榜',
        'description': '查看社区热门讨论',
        'installed': true,
        'enabled': hot,
        'active': hot,
      },
      {'id': 'office', 'active': true},
    ],
    'settings': {
      'office': {'presented': covered, 'button': '集中办公'},
    },
  };
  JsonMap get reader => {
    'url': _url,
    'thread': {
      'title': 'Navigation fixture',
      'root': {
        'id': '0',
        'author': 'Fixture',
        'blocks': [
          {'kind': 'text', 'text': 'Public fixture paragraph.'},
        ],
      },
      'replies': <JsonMap>[],
      'pages': <JsonMap>[],
    },
  };
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'settings.update':
        if (arguments['key'] != 'workspace.sidebarSection' ||
            !const [
              'boards',
              'shortcuts',
              'ranking',
              'none',
            ].contains(arguments['value'])) {
          throw StateError('Unexpected sidebar preference $arguments');
        }
        settings = {
          ...settings,
          'workspace.sidebarSection': arguments['value'],
        };
        return {...settings};
      case 'reader.load':
        return reader;
      case 'reader.rememberPosition':
        return {'saved': true};
      case 'reader.close':
        closed = true;
        return {
          ...workspace,
          'tabs': <JsonMap>[],
          'selectedTab': '',
          'showReader': false,
        };
      case 'profile.load':
        return {
          'account': 'signedIn',
          'profile': {'id': 42, 'name': 'Fixture account', 'avatar': ''},
        };
      case 'profile.introduction':
        return {'kind': 'ready', 'data': {}};
      case 'listing.selectBoard':
        board = stringValue(arguments['id']);
        reading = false;
        return workspace;
      case 'extensions.office':
        covered = arguments['presented'] == true;
        return extensions;
      case 'extensions.get':
      case 'extensions.list':
        return extensions;
      case 'rankings.load':
        return {
          'period': arguments['period'],
          'updatedAt': 1700000000,
          'error': null,
          'posts': [
            {
              'id': '1732',
              'url': 'https://www.nodeseek.com/post-1732-1',
              'title': 'Ranked fixture',
              'author': 'Fixture',
              'position': 4,
            },
          ],
        };
      case 'external.open':
      case 'shortcuts.open':
        return {'opened': true};
      default:
        throw StateError('Unexpected fixture request $method');
    }
  }
}

Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _footer(String label) => find.descendant(
  of: find.byKey(const ValueKey('sidebar-footer')),
  matching: find.text(label),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppState> _mount(WidgetTester tester, _NavigationNative native) async {
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  final state = AppState(client: native)..connecting = false;
  state.domains['workspace'] = native.workspace;
  state.domains['extensions'] = native.extensions;
  state.domains['session'] = {
    'account': 'signedIn',
    'owner': 42,
    'profile': {'id': 42, 'name': 'Fixture account', 'avatar': ''},
  };
  state.domains['settings'] = {...native.settings};
  state.readers[_url] = native.reader;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: WorkspaceScreen(state: state),
      ),
    ),
  );
  await _frames(tester);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'friends restores all original partners and returns to the same topic without listing actions',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      await tester.tap(_footer('友情链接'));
      await _frames(tester);
      expect(find.byType(FriendLinksScreen), findsOneWidget);
      expect(_button('返回论坛'), findsOneWidget);
      for (final partner in seekDeskPartners) {
        expect(find.text(partner['name']!), findsOneWidget);
        expect(find.text(partner['description']!), findsOneWidget);
        final bytes = await tester.runAsync(
          () => rootBundle.load(partner['asset']!),
        );
        expect(bytes!.lengthInBytes, greaterThan(100));
      }
      final cow = find.byWidgetPredicate(
        (widget) =>
            widget is DeskButton && widget.semanticLabel == 'CowCode 官网',
      );
      await tester.ensureVisible(cow);
      await tester.tap(cow);
      await _frames(tester);
      expect(
        native.calls.where((call) => call.$1 == 'external.open').single.$2,
        {'url': 'https://cowcode.top/r/cshaizhihao'},
      );
      await tester.tap(_button('返回论坛').first);
      await _frames(tester);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(state.workspace.selectedTab, '1731');
      expect(state.workspace.tabs, hasLength(1));
      expect(
        native.calls.where(
          (call) => [
            'listing.refresh',
            'listing.selectBoard',
            'reader.overview',
          ].contains(call.$1),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'my account stays inside the workspace and close cannot pop its root route',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      await tester.tap(_footer('我的'));
      await _frames(tester);
      expect(find.byType(AccountScreen), findsOneWidget);
      expect(find.byType(DeskWorkspaceSidebar), findsOneWidget);
      expect(find.text('我的账号'), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(AccountScreen))).canPop(),
        isFalse,
      );
      expect(
        native.calls.where((call) => call.$1 == 'profile.load'),
        hasLength(1),
      );
      await tester.tap(_icon('关闭账号'));
      await _frames(tester);
      expect(find.byType(AccountScreen), findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(state.workspace.selectedTab, '1731');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'featured shortcut uses the main listing and other official shortcuts keep their existing service',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      await tester.tap(find.byKey(const ValueKey('sidebar-header-shortcuts')));
      await _frames(tester);
      await tester.tap(find.text('精品区'));
      await _frames(tester);
      expect(
        native.calls
            .where((call) => call.$1 == 'listing.selectBoard')
            .single
            .$2,
        {'id': 'award'},
      );
      expect(
        native.calls.where((call) => call.$1 == 'shortcuts.open'),
        isEmpty,
      );
      expect(state.workspace.tabs, hasLength(1));
      expect(
        tester
            .widget<DeskWorkspaceSidebar>(find.byType(DeskWorkspaceSidebar))
            .selectedShortcut,
        'award',
      );
      await tester.tap(find.text('管理记录'));
      await _frames(tester);
      expect(
        native.calls.where((call) => call.$1 == 'shortcuts.open').single.$2,
        {'id': 'ruling'},
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'embedded destinations protect hidden forum shortcuts and preserve the topic across the narrow breakpoint',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      for (final destination in ['我的', '友情链接']) {
        await tester.tap(_footer(destination));
        await _frames(tester);
        final accountState = destination == '我的'
            ? tester.state(find.byType(AccountScreen))
            : null;
        final initialLoads = native.calls
            .where(
              (call) => call.$1 == 'profile.load' || call.$1 == 'reader.load',
            )
            .length;
        for (final size in [const Size(780, 540), const Size(1380, 880)]) {
          await tester.binding.setSurfaceSize(size);
          await _frames(tester);
          if (size.width < 990) {
            expect(_footer(destination), findsNothing);
            await tester.tap(_icon('打开导航'));
            await _frames(tester);
            expect(_footer(destination).hitTestable(), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await _frames(tester);
          } else {
            expect(find.text(destination).hitTestable(), findsWidgets);
          }
          if (accountState != null) {
            expect(
              tester.state(find.byType(AccountScreen)),
              same(accountState),
            );
          }
          expect(tester.takeException(), isNull);
        }
        for (final icon in ['收起侧栏', '展开侧栏']) {
          await tester.tap(_icon(icon));
          await _frames(tester);
          if (accountState != null) {
            expect(
              tester.state(find.byType(AccountScreen)),
              same(accountState),
            );
          }
        }
        for (final key in [
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyR,
          LogicalKeyboardKey.keyT,
        ]) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          if (key == LogicalKeyboardKey.keyT) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          }
          await tester.sendKeyEvent(key);
          if (key == LogicalKeyboardKey.keyT) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          }
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        }
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _frames(tester);
        expect(
          native.calls
              .where(
                (call) => call.$1 == 'profile.load' || call.$1 == 'reader.load',
              )
              .length,
          initialLoads,
        );
        expect(
          native.calls.where(
            (call) => [
              'reader.close',
              'reader.select',
              'reader.reopen',
              'listing.refresh',
            ].contains(call.$1),
          ),
          isEmpty,
        );
        expect(state.workspace.selectedTab, '1731');
        expect(state.workspace.tabs, hasLength(1));
        expect(
          tester
              .widget<DeskWorkspaceSidebar>(find.byType(DeskWorkspaceSidebar))
              .selectedFooter,
          destination == '我的' ? 'my' : 'friends',
        );
      }
      await tester.tap(_button('返回论坛').first);
      await _frames(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _frames(tester);
      expect(
        native.closed,
        isTrue,
        reason: 'The forum still owns its close-tab shortcut.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one ranking visibility owner follows sidebar, full page, routes, app lifecycle and office cover',
    (tester) async {
      final native = _NavigationNative()..hot = true;
      final state = await _mount(tester, native);
      expect(state.rankings.visible, isTrue);
      expect(
        native.calls.where((call) => call.$1 == 'rankings.load'),
        hasLength(1),
      );
      await tester.ensureVisible(_button('完整热榜'));
      await tester.tap(_button('完整热榜'));
      await _frames(tester);
      await tester.tap(_icon('收起侧栏'));
      await _frames(tester);
      expect(
        state.rankings.visible,
        isTrue,
        reason: 'The full ranking still owns visibility.',
      );
      await tester.tap(_button('返回论坛'));
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      await tester.tap(_icon('展开侧栏'));
      await _frames(tester);
      expect(state.rankings.visible, isTrue);
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      unawaited(
        navigator.push(
          CupertinoPageRoute<void>(
            builder: (_) =>
                const CupertinoPageScaffold(child: Text('Cover fixture')),
          ),
        ),
      );
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      navigator.pop();
      await _frames(tester);
      expect(state.rankings.visible, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(state.rankings.visible, isTrue);
      native.covered = true;
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      native.covered = false;
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      expect(state.rankings.visible, isTrue);
      native.hot = false;
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      expect(
        native.calls.where((call) => call.$1 == 'rankings.load'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'extension ranking entry shares the workspace cache and preserves reading tabs',
    (tester) async {
      final native = _NavigationNative()..hot = true;
      final state = await _mount(tester, native);
      await tester.tap(_footer('扩展中心'));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('extension-card-hot')));
      await _frames(tester);
      await tester.ensureVisible(_button('打开热榜'));
      await tester.tap(_button('打开热榜'));
      await _frames(tester);
      expect(find.byType(RankingsScreen), findsOneWidget);
      expect(state.rankings.visible, isTrue);
      expect(
        native.calls.where((call) => call.$1 == 'rankings.load'),
        hasLength(1),
      );
      expect(state.workspace.selectedTab, '1731');
      expect(state.workspace.tabs, hasLength(1));
      expect(
        native.calls.where((call) => call.$1 == 'extensions.setEnabled'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'extension ranking callback cannot navigate through another route or a revoked extension',
    (tester) async {
      final native = _NavigationNative()..hot = true;
      final state = await _mount(tester, native);
      await tester.tap(_footer('扩展中心'));
      await _frames(tester);
      final open = tester
          .widget<ExtensionsScreen>(find.byType(ExtensionsScreen))
          .onOpenRankings!;
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      unawaited(
        navigator.push(
          CupertinoPageRoute<void>(
            builder: (_) =>
                const CupertinoPageScaffold(child: Text('Covered fixture')),
          ),
        ),
      );
      await _frames(tester);
      open();
      await _frames(tester);
      expect(find.byType(RankingsScreen, skipOffstage: false), findsNothing);
      navigator.pop();
      await _frames(tester);
      native.hot = false;
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      open();
      await _frames(tester);
      expect(find.byType(ExtensionsScreen), findsOneWidget);
      expect(find.byType(RankingsScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfirmed account opens account view without requesting sign-in',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      state.domains['session'] = {'account': 'unconfirmed'};
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      await tester.tap(find.bySemanticsLabel('NodeSeek 账户'));
      await _frames(tester);
      expect(find.byType(AccountScreen), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'session.signIn'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'configured office toolbar button enters the cover without forum navigation',
    (tester) async {
      final native = _NavigationNative();
      final state = await _mount(tester, native);
      await tester.tap(_icon('集中办公'));
      await _frames(tester);
      expect(
        native.calls.where((call) => call.$1 == 'extensions.office').single.$2,
        {'presented': true},
      );
      expect(state.workspace.selectedTab, '1731');
      expect(
        native.calls.where((call) => call.$1 == 'listing.selectBoard'),
        isEmpty,
      );
    },
  );
}
