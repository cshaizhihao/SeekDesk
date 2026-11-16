import 'dart:ui' show Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_navigation_picker.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/sidebar_rankings.dart';

const _topicURL = 'https://www.nodeseek.com/post-901-1';
const _title = '布局夹具帖子：较长的标题应遵循用户字号并在窄分栏内正常换行';
const _author = 'Layout fixture author with a deliberately long display name';
const _category = 'Fixture category with a deliberately long name';
const _published = 'Fixture publication time';
const _boardTitle = '夹具版块';
const _otherBoardTitle = '另一版块';

JsonMap _post() => {
  'id': '901',
  'url': _topicURL,
  'title': _title,
  'author': _author,
  'avatar': '',
  'category': _category,
  'dateLabel': _published,
};

JsonMap _thread() => {
  'url': _topicURL,
  'scrollOffset': 0,
  'thread': {
    'title': '本地阅读夹具',
    'root': {
      'id': '0',
      'author': 'Reader fixture',
      'blocks': [
        {'kind': 'text', 'text': 'This local fixture has no external media.'},
      ],
    },
    'replies': <JsonMap>[],
    'pages': <JsonMap>[],
  },
};

/// Every host request is handled in memory. No desktop, event stream, account,
/// file, network request, or persisted preference is involved in these tests.
class _LayoutNative extends NativeClient {
  _LayoutNative({bool reading = false})
    : super(methods: const MethodChannel('seekdesk.test.layout-fidelity')) {
    workspace = {
      'posts': [_post()],
      'tabs': [
        if (reading) {'id': '901', 'url': _topicURL, 'title': '布局夹具标签'},
      ],
      'selectedTab': reading ? '901' : '',
      'showReader': reading,
      'board': 'layout',
      'boards': [
        {'id': 'layout', 'title': _boardTitle},
        {'id': 'other', 'title': _otherBoardTitle},
      ],
    };
  }

  late JsonMap workspace;
  JsonMap settings = {
    'workspace.listTextSize': 15.0,
    'workspace.topicColumnWidth': 240.0,
  };
  final JsonMap extensions = {
    'items': [
      {
        'id': 'hot',
        'title': 'NodeSeek 热榜',
        'active': true,
        'installed': true,
        'enabled': true,
      },
    ],
  };
  final calls = <(String, JsonMap)>[];
  final unexpectedCalls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'settings.get':
        return {...settings};
      case 'settings.update':
        settings = {
          ...settings,
          stringValue(arguments['key']): arguments['value'],
        };
        return {...settings};
      case 'extensions.list':
        return {...extensions};
      case 'inbox.load':
        return {'kind': arguments['kind'], 'items': <JsonMap>[]};
      case 'rankings.load':
        return {'posts': <JsonMap>[]};
      case 'reader.load':
        return _thread();
      case 'reader.rememberPosition':
        return {};
      case 'listing.selectBoard':
        workspace = {...workspace, 'board': arguments['id']};
        return {...workspace};
      case 'fixture.navigation':
        // Exercise the same domain update consumed from a native menu event.
        return {
          'domain': 'navigation',
          'data': {'destination': arguments['destination']},
        };
      default:
        unexpectedCalls.add(method);
        throw StateError('Unexpected local layout fixture request: $method');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> mount(
    WidgetTester tester,
    _LayoutNative native, {
    Size size = const Size(1380, 1000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    final state = AppState(client: native);
    state.connecting = false;
    state.domains['workspace'] = {...native.workspace};
    state.domains['settings'] = {...native.settings};
    state.domains['extensions'] = {...native.extensions};
    state.domains['session'] = {'account': 'signedOut'};
    state.readers[_topicURL] = _thread();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      expect(native.unexpectedCalls, isEmpty);
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
    await tester.pump();
    return state;
  }

  Finder sidebarControl() => find.byKey(const ValueKey('sidebar-footer'));

  Future<void> selectDestination(WidgetTester tester, String label) async {
    final compactNavigation = find.byWidgetPredicate(
      (widget) => widget is DeskIcon && widget.label == '打开导航',
    );
    if (label != '消息' &&
        label != '返回论坛' &&
        compactNavigation.evaluate().isNotEmpty) {
      await tester.tap(compactNavigation);
      await tester.pump();
    }
    final item = switch (label) {
      '消息' => find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '消息',
      ),
      '返回论坛' => find.byWidgetPredicate(
        (widget) => widget is DeskButton && widget.label == '返回论坛',
      ),
      _ => find.descendant(of: sidebarControl(), matching: find.text(label)),
    };
    expect(item, findsOneWidget);
    await tester.tap(item);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> selectPreference(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(PreferencesScreen),
        matching: find.text(label),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool boardSelected(WidgetTester tester, String title) {
    final picker = tester.widget<DeskNavigationPicker>(
      find.byKey(const ValueKey('sidebar-picker-boards'), skipOffstage: false),
    );
    final index = picker.segments.indexWhere(
      (segment) => segment.semanticLabel == title,
    );
    expect(index, greaterThanOrEqualTo(0));
    return picker.selectedIndex == index;
  }

  Future<void> expandBoards(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sidebar-header-boards')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  double renderedFontSize(WidgetTester tester, String text) => tester
      .renderObject<RenderParagraph>(
        find.descendant(of: find.text(text), matching: find.byType(RichText)),
      )
      .text
      .style!
      .fontSize!;

  for (final size in [const Size(1380, 1000), const Size(780, 540)]) {
    testWidgets(
      'preference title stays at the workspace top across categories at ${size.width} by ${size.height}',
      (tester) async {
        await mount(tester, _LayoutNative(), size: size);
        await selectDestination(tester, '设置');
        final heading = find.text('偏好设置');
        expect(heading, findsOneWidget);
        final initialTop = tester.getTopLeft(heading).dy;
        expect(
          initialTop,
          lessThan(tester.getTopLeft(find.byType(WorkspaceScreen)).dy + 140),
          reason: 'A short settings category must not float halfway down the window.',
        );
        for (final tab in ['外观', '阅读', '通用']) {
          await selectPreference(tester, tab);
          expect(
            tester.getTopLeft(heading).dy,
            closeTo(initialTop, 1),
            reason:
                'Changing content height must not move the settings header ($tab).',
          );
          expect(tester.takeException(), isNull);
        }
        expect(find.text('通用功能'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'changing list text size in settings updates rendered titles and metadata',
    (tester) async {
      final native = _LayoutNative();
      final state = await mount(tester, native);
      final before = {
        for (final label in [_title, '$_author · $_published', _category])
          label: renderedFontSize(tester, label),
      };
      final previousTitleHeight = tester.getSize(find.text(_title)).height;
      await selectDestination(tester, '设置');
      await selectPreference(tester, '阅读');
      final sliderScope = find.byKey(
        const ValueKey('preference-slider-workspace.listTextSize'),
      );
      await tester.ensureVisible(sliderScope);
      final slider = tester.widget<GlassSlider>(
        find.descendant(of: sliderScope, matching: find.byType(GlassSlider)),
      );
      slider.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(state.domain('settings')['workspace.listTextSize'], 24.0);
      expect(
        native.calls.where((call) => call.$1 == 'settings.update').single.$2,
        {'key': 'workspace.listTextSize', 'value': 24.0},
      );
      await selectDestination(tester, '返回论坛');
      expect(renderedFontSize(tester, _title), 24.0);
      for (final label in ['$_author · $_published', _category]) {
        expect(
          renderedFontSize(tester, label),
          greaterThan(before[label]!),
          reason: 'List metadata must follow the changed reading size: $label',
        );
      }
      expect(
        tester.getSize(find.text(_title)).height,
        greaterThan(previousTitleHeight),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large list text and long metadata fit a 240 point reading split',
    (tester) async {
      final native = _LayoutNative(reading: true);
      native.settings = {...native.settings, 'workspace.listTextSize': 24.0};
      await mount(tester, native, size: const Size(1080, 700));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('本地阅读夹具'), findsOneWidget);
      expect(renderedFontSize(tester, _title), 24.0);
      final row = find.ancestor(
        of: find.text(_title),
        matching: find.byType(HoverRow),
      );
      final bounds = tester.getRect(row);
      expect(bounds.width, lessThanOrEqualTo(240));
      for (final text in [_title, '$_author · $_published', _category]) {
        final rect = tester.getRect(find.text(text));
        expect(rect.left, greaterThanOrEqualTo(bounds.left - 1));
        expect(rect.right, lessThanOrEqualTo(bounds.right + 1));
        expect(rect.top, greaterThanOrEqualTo(bounds.top - 1));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 1));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact overview uses full width while preserving the saved wide sidebar preference',
    (tester) async {
      final native = _LayoutNative();
      native.settings = {...native.settings, 'workspace.sidebarWidth': 360.0};
      final state = await mount(tester, native, size: const Size(920, 540));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.workspace.selected, isNull);
      expect(find.text(_title), findsOneWidget);
      expect(find.text('本地阅读夹具'), findsNothing);
      final row = find.ancestor(
        of: find.text(_title),
        matching: find.byType(HoverRow),
      );
      final bounds = tester.getRect(row);
      expect(bounds.left, lessThan(40));
      expect(bounds.width, greaterThan(850));
      expect(state.domain('settings')['workspace.sidebarWidth'], 360);
      expect(bounds.right, lessThanOrEqualTo(920));
      expect(
        tester.takeException(),
        isNull,
        reason: 'An overview without a reader must not reserve a trailing split gap.',
      );
    },
  );

  testWidgets(
    'destinations clear board highlight and return to forum retains the selected tab',
    (tester) async {
      final native = _LayoutNative(reading: true);
      final state = await mount(tester, native);
      await expandBoards(tester);
      final tabs = state.workspace.tabs.map((topic) => topic.id).toList();
      final selectedTab = state.workspace.selectedTab;
      expect(boardSelected(tester, _boardTitle), isTrue);
      for (final destination in [
        ('消息', InboxScreen),
        ('扩展中心', ExtensionsScreen),
        ('设置', PreferencesScreen),
      ]) {
        await selectDestination(tester, destination.$1);
        expect(find.byType(destination.$2), findsOneWidget);
        expect(boardSelected(tester, _boardTitle), isFalse);
        expect(boardSelected(tester, _otherBoardTitle), isFalse);
        expect(
          tester
              .widget<DeskWorkspaceSidebar>(find.byType(DeskWorkspaceSidebar))
              .selectedBoard,
          isNull,
        );
        final beforeReturn = native.calls.length;
        await selectDestination(tester, '返回论坛');
        expect(boardSelected(tester, _boardTitle), isTrue);
        expect(boardSelected(tester, _otherBoardTitle), isFalse);
        expect(state.workspace.tabs.map((topic) => topic.id), tabs);
        expect(state.workspace.selectedTab, selectedTab);
        expect(state.workspace.showReader, isTrue);
        expect(find.text('本地阅读夹具'), findsOneWidget);
        expect(
          native.calls
              .skip(beforeReturn)
              .where(
                (call) => [
                  'listing.refresh',
                  'listing.selectBoard',
                  'reader.overview',
                ].contains(call.$1),
              ),
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native menu navigation clears stale board selection and board click returns to community',
    (tester) async {
      final native = _LayoutNative();
      final state = await mount(tester, native);
      await expandBoards(tester);
      for (final destination in [
        ('settings', PreferencesScreen),
        ('extensions', ExtensionsScreen),
        ('inbox', InboxScreen),
      ]) {
        await state.act('fixture.navigation', {'destination': destination.$1});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(destination.$2), findsOneWidget);
        expect(boardSelected(tester, _boardTitle), isFalse);
        expect(boardSelected(tester, _otherBoardTitle), isFalse);
      }
      await tester.tap(find.text(_otherBoardTitle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(InboxScreen), findsNothing);
      expect(find.text(_title), findsOneWidget);
      expect(state.workspace.board, 'other');
      expect(boardSelected(tester, _boardTitle), isFalse);
      expect(boardSelected(tester, _otherBoardTitle), isTrue);
      expect(
        native.calls
            .where((call) => call.$1 == 'listing.selectBoard')
            .single
            .$2,
        {'id': 'other'},
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rankings never leave settings selected visually or in accessibility',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mount(tester, _LayoutNative());
        await selectDestination(tester, '设置');
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('设置'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        final rankingsAction = find.descendant(
          of: find.byType(SidebarRankings),
          matching: find.byWidgetPredicate(
            (widget) => widget is DeskButton && widget.label == '完整热榜',
          ),
        );
        expect(rankingsAction, findsOneWidget);
        await tester.ensureVisible(rankingsAction);
        await tester.tap(rankingsAction);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(RankingsScreen), findsOneWidget);
        expect(find.byType(PreferencesScreen), findsNothing);
        final navigation = tester.widget<DeskNavigationPicker>(
          sidebarControl(),
        );
        expect(navigation.selectedIndex, isNull);
        final sidebar = tester.widget<DeskWorkspaceSidebar>(
          find.byType(DeskWorkspaceSidebar),
        );
        expect(sidebar.selectedFooter, isNull);
        expect(sidebar.selectedBoard, isNull);
        expect(sidebar.selectedShortcut, isNull);
        for (final label in ['最新帖子', '友情链接', '我的', '扩展中心', '设置']) {
          expect(
            tester
                .getSemantics(find.bySemanticsLabel(label))
                .getSemanticsData()
                .flagsCollection
                .isSelected,
            isNot(Tristate.isTrue),
            reason: 'Rankings must not select another destination ($label).',
          );
        }
        expect(boardSelected(tester, _boardTitle), isFalse);
        expect(boardSelected(tester, _otherBoardTitle), isFalse);
        expect(tester.takeException(), isNull);
        await selectDestination(tester, '设置');
        expect(find.byType(PreferencesScreen), findsOneWidget);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('设置'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
      } finally {
        semantics.dispose();
      }
    },
  );
}
