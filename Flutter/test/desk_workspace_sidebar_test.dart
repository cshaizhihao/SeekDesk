import 'dart:ui' show Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/widgets/desk_navigation_picker.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';

const _boards = <JsonMap>[
  {'id': '', 'title': '最新帖子'},
  {'id': 'daily', 'title': '日常'},
  {'id': 'tech', 'title': '技术'},
  {'id': 'info', 'title': '情报'},
  {'id': 'review', 'title': '测评'},
  {'id': 'trade', 'title': '交易'},
  {'id': 'carpool', 'title': '拼车'},
  {'id': 'dev', 'title': 'Dev'},
  {'id': 'photo-share', 'title': '贴图'},
  {'id': 'expose', 'title': '曝光'},
  {'id': 'promotion', 'title': '推广'},
  {'id': 'life', 'title': '生活'},
  {'id': 'inside', 'title': '内版'},
  {'id': 'sandbox', 'title': '沙盒'},
];
const _shortcuts = <JsonMap>[
  {'id': 'award', 'title': '精品区'},
  {'id': 'ruling', 'title': '管理记录'},
  {'id': 'lucky', 'title': '幸运抽奖'},
  {'id': 'invite', 'title': '邀请好友'},
];

Finder _key(String key, {bool skipOffstage = true}) =>
    find.byKey(ValueKey(key), skipOffstage: skipOffstage);

DeskNavigationPicker _picker(WidgetTester tester, String group) => tester
    .widget<DeskNavigationPicker>(_key('sidebar-$group', skipOffstage: false));

ScrollController _scroll(WidgetTester tester, String section) => tester
    .widget<SingleChildScrollView>(
      _key('sidebar-scroll-$section', skipOffstage: false),
    )
    .controller!;

Future<_SidebarHarnessState> _mount(
  WidgetTester tester, {
  double width = 228,
  double height = 540,
  double fontSize = 13,
  double scale = 1,
  bool reduceMotion = true,
  DeskSidebarSection? section = DeskSidebarSection.ranking,
  List<JsonMap> boards = _boards,
  List<JsonMap> shortcuts = _shortcuts,
}) async {
  final key = GlobalKey<_SidebarHarnessState>();
  await tester.pumpWidget(
    CupertinoApp(
      home: _SidebarHarness(
        key: key,
        width: width,
        height: height,
        fontSize: fontSize,
        scale: scale,
        reduceMotion: reduceMotion,
        initialSection: section,
        boards: boards,
        shortcuts: shortcuts,
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

void main() {
  testWidgets('restores the native hierarchy and keeps home outside boards', (
    tester,
  ) async {
    final harness = await _mount(tester);
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
        tester.getCenter(find.text(ordered[index])).dy,
        greaterThan(tester.getCenter(find.text(ordered[index - 1])).dy),
      );
    }
    expect(find.text('最新帖子', skipOffstage: false), findsOneWidget);
    expect(
      _picker(tester, 'picker-boards').segments.map((item) => item.id),
      _boards.skip(1).map((item) => item['id']),
    );
    expect(
      _picker(tester, 'picker-shortcuts').segments.map((item) => item.id),
      ['award', 'ruling', 'lucky', 'invite'],
    );
    expect(_picker(tester, 'footer').segments.map((item) => item.id), [
      'friends',
      'my',
      'extensions',
      'settings',
    ]);
    await tester.tap(find.text('发布新帖'));
    await tester.pump();
    expect(harness.composed, 1);
    await tester.tap(find.text('最新帖子'));
    await tester.pump();
    expect(harness.boardActions, ['']);
    expect(harness.section, DeskSidebarSection.ranking);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sections are mutually exclusive and a repeated header closes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await _mount(tester);
      final rankingState = tester.state(find.byType(_RankingProbe));
      expect(find.text('榜单条目 0'), findsOneWidget);
      expect(find.text('日常'), findsNothing);
      await tester.tap(_key('sidebar-header-boards'));
      await tester.pump();
      expect(harness.section, DeskSidebarSection.boards);
      expect(find.text('日常'), findsOneWidget);
      expect(find.text('精品区'), findsNothing);
      expect(find.text('榜单条目 0'), findsNothing);
      expect(tester.getSemantics(find.bySemanticsLabel('论坛版块')).value, '已展开');
      await tester.tap(_key('sidebar-header-shortcuts'));
      await tester.pump();
      expect(harness.section, DeskSidebarSection.shortcuts);
      expect(find.text('日常'), findsNothing);
      expect(find.text('精品区'), findsOneWidget);
      await tester.tap(_key('sidebar-header-shortcuts'));
      await tester.pump();
      expect(harness.section, isNull);
      expect(find.text('精品区'), findsNothing);
      expect(tester.getSemantics(find.bySemanticsLabel('快捷功能区')).value, '已收起');
      expect(
        tester.state(find.byType(_RankingProbe, skipOffstage: false)),
        same(rankingState),
      );
      expect(harness.sections, [
        DeskSidebarSection.boards,
        DeskSidebarSection.shortcuts,
        null,
      ]);
      expect(harness.boardActions, isEmpty);
      expect(harness.shortcutActions, isEmpty);
      expect(harness.footerActions, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('footer stays fixed while a section scrolls or changes', (
    tester,
  ) async {
    await _mount(
      tester,
      width: 172,
      fontSize: 24,
      section: DeskSidebarSection.boards,
    );
    final footer = tester.getRect(_key('sidebar-footer'));
    final compose = tester.getRect(_key('sidebar-compose'));
    await tester.drag(_key('sidebar-scroll-boards'), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(_scroll(tester, 'boards').offset, greaterThan(0));
    expect(tester.getRect(_key('sidebar-footer')), footer);
    expect(tester.getRect(_key('sidebar-compose')), compose);
    for (final section in ['shortcuts', 'ranking', 'ranking', 'boards']) {
      await tester.tap(_key('sidebar-header-$section'));
      await tester.pumpAndSettle();
      expect(tester.getRect(_key('sidebar-footer')), footer);
      expect(tester.getRect(_key('sidebar-compose')), compose);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('172 point sidebar fits large type with accessible full labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await _mount(
        tester,
        width: 172,
        fontSize: 24,
        scale: 1.6,
      );
      for (final section in DeskSidebarSection.values) {
        harness.changeSection(section);
        await tester.pumpAndSettle();
        final sidebar = tester.getRect(find.byType(DeskWorkspaceSidebar));
        expect(sidebar.size, const Size(172, 540));
        // At large text the footer is reachable through the same outer
        // viewport; it no longer consumes all space reserved for destinations.
        await tester.ensureVisible(find.text('设置'));
        await tester.pumpAndSettle();
        final footer = tester.getRect(_key('sidebar-footer'));
        expect(footer.bottom, lessThanOrEqualTo(sidebar.bottom));
        expect(footer.left, greaterThanOrEqualTo(sidebar.left));
        expect(footer.right, lessThanOrEqualTo(sidebar.right));
        for (final title in ['论坛版块', '快捷功能区', '热榜']) {
          await tester.ensureVisible(find.text(title));
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel(title), findsOneWidget);
          final text = tester.widget<Text>(find.text(title));
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          expect(text.style!.fontSize, 23);
        }
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  for (final height in [480.0, 320.0]) {
    testWidgets(
      '24 point 2x text keeps boards shortcuts and settings reachable at $height height',
      (tester) async {
        final harness = await _mount(
          tester,
          width: 228,
          height: height,
          fontSize: 24,
          scale: 2,
          section: DeskSidebarSection.boards,
        );
        expect(
          tester.getSize(_key('sidebar-body-boards')).height,
          greaterThanOrEqualTo(65),
        );
        final boardScroll = find
            .descendant(
              of: _key('sidebar-scroll-boards'),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.ensureVisible(_key('sidebar-body-boards'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('沙盒').hitTestable(),
          150,
          scrollable: boardScroll,
        );
        await tester.tap(find.text('沙盒').hitTestable());
        await tester.pumpAndSettle();
        expect(harness.boardActions, ['sandbox']);
        expect(_scroll(tester, 'boards').offset, greaterThan(0));

        await tester.ensureVisible(_key('sidebar-header-shortcuts'));
        await tester.pumpAndSettle();
        await tester.tap(_key('sidebar-header-shortcuts').hitTestable());
        await tester.pumpAndSettle();
        expect(harness.section, DeskSidebarSection.shortcuts);
        expect(
          tester.getSize(_key('sidebar-body-shortcuts')).height,
          greaterThanOrEqualTo(65),
        );
        final shortcutScroll = find
            .descendant(
              of: _key('sidebar-scroll-shortcuts'),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.ensureVisible(_key('sidebar-body-shortcuts'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('邀请好友').hitTestable(),
          100,
          scrollable: shortcutScroll,
        );
        await tester.tap(find.text('邀请好友').hitTestable());
        await tester.pumpAndSettle();
        expect(harness.shortcutActions, ['invite']);

        // Drag the side padding so this gesture targets the whole sidebar,
        // independently of the nested destination list under the pointer.
        final sidebar = tester.getRect(find.byType(DeskWorkspaceSidebar));
        await tester.dragFrom(
          Offset(sidebar.right - 3, sidebar.center.dy),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        final outer = tester.widget<SingleChildScrollView>(
          _key('sidebar-overflow'),
        );
        expect(outer.controller!.offset, greaterThan(0));
        expect(find.text('设置').hitTestable(), findsOneWidget);
        await tester.tap(find.text('设置').hitTestable());
        await tester.pumpAndSettle();
        expect(harness.footerActions, ['settings']);

        await tester.ensureVisible(find.text('发布新帖'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('发布新帖').hitTestable());
        await tester.pumpAndSettle();
        expect(harness.composed, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short to tall resize keeps picker states focus and section scroll positions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final harness = await _mount(
        tester,
        width: 228,
        height: 480,
        fontSize: 24,
        scale: 2,
        section: DeskSidebarSection.boards,
      );
      final boardController = _scroll(tester, 'boards');
      boardController.jumpTo(80);
      await tester.pumpAndSettle();
      final boardState = tester.state(_key('sidebar-picker-boards'));
      final footerState = tester.state(_key('sidebar-footer'));
      final boardOffset = boardController.offset;
      final settingsElement = tester.element(find.text('设置'));
      await tester.ensureVisible(find.text('设置'));
      await tester.pumpAndSettle();
      final settingsFocus = Focus.of(tester.element(find.text('设置')));
      settingsFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(settingsFocus.hasFocus, isTrue);

      harness.resize(900);
      await tester.pumpAndSettle();
      expect(tester.state(_key('sidebar-picker-boards')), same(boardState));
      expect(tester.state(_key('sidebar-footer')), same(footerState));
      expect(tester.element(find.text('设置')), same(settingsElement));
      expect(Focus.of(tester.element(find.text('设置'))), same(settingsFocus));
      expect(settingsFocus.hasFocus, isTrue);
      expect(_scroll(tester, 'boards'), same(boardController));
      expect(boardController.offset, boardOffset);
      final outer = tester.widget<SingleChildScrollView>(
        _key('sidebar-overflow'),
      );
      expect(outer.controller!.position.maxScrollExtent, 0);

      harness.resize(480);
      await tester.pumpAndSettle();
      expect(tester.state(_key('sidebar-picker-boards')), same(boardState));
      expect(tester.state(_key('sidebar-footer')), same(footerState));
      expect(boardController.offset, boardOffset);
      expect(settingsFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection follows its owning group with null elsewhere', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await _mount(tester, section: DeskSidebarSection.boards);
      void selected(int? home, int? boards, int? shortcuts, int? footer) {
        expect(_picker(tester, 'home').selectedIndex, home);
        expect(_picker(tester, 'picker-boards').selectedIndex, boards);
        expect(_picker(tester, 'picker-shortcuts').selectedIndex, shortcuts);
        expect(_picker(tester, 'footer').selectedIndex, footer);
      }

      selected(null, null, null, null);
      await tester.tap(find.text('日常'));
      await tester.pump();
      selected(null, 0, null, null);
      expect(harness.boardActions, ['daily']);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('日常'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await tester.tap(find.text('最新帖子'));
      await tester.pump();
      selected(0, null, null, null);
      await tester.tap(_key('sidebar-header-shortcuts'));
      await tester.pump();
      await tester.tap(find.text('精品区'));
      await tester.pump();
      selected(null, null, 0, null);
      expect(harness.shortcutActions, ['award']);
      await tester.tap(find.text('扩展中心'));
      await tester.pump();
      selected(null, null, null, 2);
      expect(harness.footerActions, ['extensions']);
      expect(harness.section, DeskSidebarSection.shortcuts);
      expect(find.text('9'), findsOneWidget);
      expect(find.bySemanticsLabel('扩展中心，9 条未读'), findsOneWidget);
      harness.selectUnknown();
      await tester.pump();
      selected(null, null, null, null);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets(
    'all three section scroll offsets survive switching and folding',
    (tester) async {
      await _mount(tester, width: 172, fontSize: 24);
      final ranking = tester.state<_RankingProbeState>(
        find.byType(_RankingProbe),
      );
      await tester.drag(_key('ranking-scroll'), const Offset(0, -210));
      await tester.pumpAndSettle();
      final rankingOffset = ranking.controller.offset;
      expect(rankingOffset, greaterThan(0));
      await tester.tap(_key('sidebar-header-boards'));
      await tester.pump();
      final boards = _scroll(tester, 'boards');
      await tester.drag(_key('sidebar-scroll-boards'), const Offset(0, -220));
      await tester.pumpAndSettle();
      final boardOffset = boards.offset;
      expect(boardOffset, greaterThan(0));
      await tester.tap(_key('sidebar-header-shortcuts'));
      await tester.pump();
      final shortcuts = _scroll(tester, 'shortcuts');
      await tester.drag(_key('sidebar-scroll-shortcuts'), const Offset(0, -80));
      await tester.pumpAndSettle();
      final shortcutOffset = shortcuts.offset;
      expect(shortcutOffset, greaterThan(0));

      for (final section in ['boards', 'ranking', 'ranking', 'shortcuts']) {
        await tester.tap(_key('sidebar-header-$section'));
        await tester.pumpAndSettle();
        expect(_scroll(tester, 'boards'), same(boards));
        expect(_scroll(tester, 'shortcuts'), same(shortcuts));
        expect(boards.offset, boardOffset);
        expect(shortcuts.offset, shortcutOffset);
        expect(ranking.controller.offset, rankingOffset);
        expect(
          tester.state(find.byType(_RankingProbe, skipOffstage: false)),
          same(ranking),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabling ranking hides it without selecting another group', (
    tester,
  ) async {
    final harness = await _mount(tester);
    harness.enableRanking(false);
    await tester.pump();
    expect(harness.section, DeskSidebarSection.ranking);
    expect(find.text('热榜', skipOffstage: false), findsNothing);
    expect(find.text('日常'), findsNothing);
    expect(find.text('精品区'), findsNothing);
    expect(harness.sections, isEmpty);
    harness.enableRanking(true);
    await tester.pump();
    expect(find.text('榜单条目 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown IDs and empty groups remain usable', (tester) async {
    final harness = await _mount(
      tester,
      section: DeskSidebarSection.boards,
      boards: const [
        {'id': '', 'title': '最新帖子'},
        {'id': 'future-board', 'title': '将来的版块'},
      ],
      shortcuts: const [],
    );
    expect(_picker(tester, 'picker-boards').segments, hasLength(1));
    expect(
      find.descendant(
        of: _key('sidebar-picker-boards'),
        matching: find.byIcon(CupertinoIcons.square_grid_2x2),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('将来的版块'));
    await tester.pump();
    expect(harness.boardActions, ['future-board']);
    await tester.tap(_key('sidebar-header-shortcuts'));
    await tester.pump();
    expect(_key('sidebar-picker-shortcuts', skipOffstage: false), findsNothing);
    expect(find.text('友情链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Reduce Motion removes header rotation and picker springs', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(_key('sidebar-header-boards'));
    await tester.pump();
    for (final rotation in tester.widgetList<AnimatedRotation>(
      find.byType(AnimatedRotation),
    )) {
      expect(rotation.duration, Duration.zero);
    }
    await tester.tap(find.text('日常'));
    await tester.pump();
    await tester.tap(find.text('技术'));
    await tester.pump();
    for (final indicator in tester.widgetList<AnimatedGlassIndicator>(
      find.byType(AnimatedGlassIndicator),
    )) {
      expect(indicator.velocity, 0);
      expect(indicator.thickness, 0);
    }
    void checkStill() {
      final boardIndicators = tester.widgetList<AnimatedGlassIndicator>(
        find.descendant(
          of: _key('sidebar-picker-boards'),
          matching: find.byType(AnimatedGlassIndicator),
        ),
      );
      expect(boardIndicators, isNotEmpty);
      for (final indicator in boardIndicators) {
        expect(
          indicator.alignment.resolve(TextDirection.ltr).y,
          closeTo(-1 + 2 / 12, 0.000001),
        );
        expect(indicator.velocity, 0);
        expect(indicator.thickness, 0);
      }
      for (final rotation in tester.widgetList<RotationTransition>(
        find.descendant(
          of: _key('sidebar-header-boards'),
          matching: find.byType(RotationTransition),
        ),
      )) {
        expect(rotation.turns.value, .5);
      }
      for (final fade in tester.widgetList<FadeTransition>(
        find.descendant(
          of: _key('sidebar-picker-boards'),
          matching: find.byType(FadeTransition),
        ),
      )) {
        expect(fade.opacity.value, 1);
      }
    }

    checkStill();
    await tester.pump(const Duration(milliseconds: 16));
    checkStill();
    // CupertinoButton still times a 1→1 opacity press even with
    // pressedOpacity: 1. Let its fixed down/up phases finish separately.
    await tester.pump(const Duration(milliseconds: 121));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 181));
    checkStill();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _SidebarHarness extends StatefulWidget {
  const _SidebarHarness({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.scale,
    required this.reduceMotion,
    required this.initialSection,
    required this.boards,
    required this.shortcuts,
    super.key,
  });

  final double width, height, fontSize, scale;
  final bool reduceMotion;
  final DeskSidebarSection? initialSection;
  final List<JsonMap> boards, shortcuts;

  @override
  State<_SidebarHarness> createState() => _SidebarHarnessState();
}

class _SidebarHarnessState extends State<_SidebarHarness> {
  late DeskSidebarSection? section = widget.initialSection;
  late double height = widget.height;
  String? board, shortcut, footer;
  bool rankingEnabled = true;
  int composed = 0;
  final sections = <DeskSidebarSection?>[];
  final boardActions = <String>[];
  final shortcutActions = <String>[];
  final footerActions = <String>[];

  void changeSection(DeskSidebarSection? value) =>
      setState(() => section = value);
  void enableRanking(bool value) => setState(() => rankingEnabled = value);
  void resize(double value) => setState(() => height = value);
  void selectUnknown() => setState(() {
    board = 'unknown';
    shortcut = 'unknown';
    footer = 'unknown';
  });

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: widget.reduceMotion,
      textScaler: TextScaler.linear(widget.scale),
    ),
    child: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: widget.width,
            height: height,
            child: DeskWorkspaceSidebar(
              boards: widget.boards,
              shortcuts: widget.shortcuts,
              boardTextSize: widget.fontSize,
              selectedBoard: board,
              selectedShortcut: shortcut,
              selectedFooter: footer,
              section: section,
              rankingEnabled: rankingEnabled,
              extensionUnread: 9,
              ranking: const _RankingProbe(),
              onSectionChanged: (value) {
                sections.add(value);
                changeSection(value);
              },
              onBoard: (value) => setState(() {
                boardActions.add(value);
                board = value;
                shortcut = null;
                footer = null;
              }),
              onShortcut: (value) => setState(() {
                shortcutActions.add(value);
                board = null;
                shortcut = value;
                footer = null;
              }),
              onFooter: (value) => setState(() {
                footerActions.add(value);
                board = null;
                shortcut = null;
                footer = value;
              }),
              onCompose: () => composed++,
            ),
          ),
        ),
      ),
    ),
  );
}

class _RankingProbe extends StatefulWidget {
  const _RankingProbe();

  @override
  State<_RankingProbe> createState() => _RankingProbeState();
}

class _RankingProbeState extends State<_RankingProbe> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('ranking-scroll'),
    controller: controller,
    child: Column(
      children: [
        for (var index = 0; index < 30; index++)
          SizedBox(height: 36, child: Text('榜单条目 $index')),
      ],
    ),
  );
}
