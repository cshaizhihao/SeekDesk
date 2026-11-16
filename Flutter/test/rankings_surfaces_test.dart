// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/rankings_controller.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/sidebar_rankings.dart';

import 'support/rankings_fixture.dart';

void main() {
  testWidgets(
    'full rankings retain category metadata and chosen title size in a narrow pane',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(
        tester,
        width: 660,
        textSize: 22,
      );
      try {
        await fixture.ready(tester, [
          {...rankingPost(1), 'category': '交易'},
          {...rankingPost(2), 'categoryLabel': '技术', 'category': '旧分类'},
          rankingPost(3),
        ]);
        final full = find.byType(RankingsScreen);
        expect(
          find.descendant(of: full, matching: find.text('交易')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: full, matching: find.text('技术')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: full, matching: find.text('旧分类')),
          findsNothing,
        );
        final title = tester.widget<Text>(
          find.descendant(of: full, matching: find.text('Fixture ranking 1')),
        );
        expect(title.style?.fontSize, 22);
        expect(fixture.native.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'mounting both ranking surfaces does not fetch and visibility shares one load',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(tester);
      try {
        expect(fixture.native.requests, isEmpty);
        expect(find.text('等待加载热榜'), findsNWidgets(2));
        fixture.state.rankings.setVisible(true);
        await tester.pump();
        expect(fixture.native.requests, hasLength(1));
        final loading = fixture.state.rankings.refresh(force: true);
        expect(fixture.native.requests, hasLength(1));
        fixture.native.requests.single.complete(
          posts: [rankingPost(1), rankingPost(2)],
        );
        await loading;
        await tester.pump();
        expect(find.text('Fixture ranking 1'), findsNWidgets(2));
        expect(find.text('Fixture ranking 2'), findsNWidgets(2));
        fixture.harness.currentState!.rebuild();
        await tester.pump();
        expect(fixture.native.requests, hasLength(1));
        final pickers = tester.widgetList<RankingPeriodPicker>(
          find.byType(RankingPeriodPicker),
        );
        expect(pickers, hasLength(2));
        expect(
          pickers.every(
            (picker) => identical(picker.controller, fixture.state.rankings),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'sidebar period changes update both controls without showing the previous rows',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(tester);
      try {
        await fixture.ready(tester, [rankingPost(1, title: 'Hot only')]);
        await tester.tap(
          find.descendant(
            of: find.byType(SidebarRankings),
            matching: find.text('日榜'),
          ),
        );
        await tester.pump();
        expect(fixture.state.rankings.period, RankingPeriod.daily);
        expect(find.text('Hot only'), findsNothing);
        expect(fixture.native.requests, hasLength(2));
        final controls = tester.widgetList<GlassSegmentedControl>(
          find.byType(GlassSegmentedControl),
        );
        expect(controls, hasLength(2));
        expect(controls.every((control) => control.selectedIndex == 1), isTrue);
        final pending = fixture.state.rankings.refresh(force: true);
        expect(fixture.native.requests, hasLength(2));
        fixture.native.requests.last.complete(
          posts: [rankingPost(3, title: 'Daily only')],
        );
        await pending;
        await tester.pump();
        expect(find.text('Daily only'), findsNWidgets(2));
        await tester.tap(
          find.descendant(
            of: find.byType(RankingsScreen),
            matching: find.text('实时'),
          ),
        );
        await tester.pump();
        expect(find.text('Hot only'), findsNWidgets(2));
        expect(find.text('Daily only'), findsNothing);
        expect(fixture.native.requests, hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'both surfaces use distinct original top-three badges after author filtering',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(tester);
      try {
        await fixture.ready(tester, [
          for (var rank = 1; rank <= 4; rank++) rankingPost(rank),
        ]);
        const colors = [
          Color(0xffeb6a4b),
          Color(0xffc2974b),
          Color(0xff9d83bf),
        ];
        for (var rank = 1; rank <= 3; rank++) {
          final badges = tester.widgetList<Text>(find.text('🔥 $rank'));
          expect(badges, hasLength(2));
          expect(
            badges.every((badge) => badge.style?.color == colors[rank - 1]),
            isTrue,
          );
        }
        fixture.native.emit('extensions', {
          'items': [
            {'id': 'block', 'active': true},
          ],
          'blocked': [
            {
              'id': 'member:1001',
              'memberId': 1001,
              'normalizedName': 'author 1',
            },
            {
              'id': 'member:1002',
              'memberId': 1002,
              'normalizedName': 'author 2',
            },
          ],
        });
        await tester.pump();
        expect(find.text('🔥 1'), findsNothing);
        expect(find.text('🔥 2'), findsNothing);
        expect(find.text('🔥 3'), findsNWidgets(2));
        expect(find.text('4'), findsNWidgets(2));
        expect(fixture.state.rankings.summaryPosts.first['position'], 3);
        expect(fixture.native.requests, hasLength(1));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'sidebar and full rows open topics through the existing reader route',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(tester);
      try {
        await fixture.ready(tester, [rankingPost(1), rankingPost(2)]);
        await tester.tap(find.byKey(const ValueKey('sidebar-ranking-hot-1')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('full-ranking-hot-2')));
        await tester.pump();
        final readerCalls = fixture.native.calls
            .where((call) => call.$1.startsWith('reader.'))
            .toList();
        expect(readerCalls.map((call) => call.$1), [
          'reader.open',
          'reader.load',
          'reader.open',
          'reader.load',
        ]);
        expect(readerCalls.map((call) => call.$2['url']), [
          'https://www.nodeseek.com/post-1-1',
          'https://www.nodeseek.com/post-1-1',
          'https://www.nodeseek.com/post-2-1',
          'https://www.nodeseek.com/post-2-1',
        ]);
        expect(fixture.state.workspace.showReader, isTrue);
        expect(
          fixture.state.readerFor(
            'https://www.nodeseek.com/post-2-1',
          )['thread'],
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    '172px summary tolerates tiny finite heights and large text with all chrome scrollable',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(
        tester,
        full: false,
        width: 172,
        textSize: 22,
      );
      try {
        await fixture.ready(tester, [
          for (var rank = 1; rank <= 12; rank++)
            rankingPost(rank, title: '第 $rank 名：很长的热榜标题用于验证窄侧栏的大字号布局'),
        ]);
        for (final height in [0.0, 12.0, 36.0, 80.0, 180.0]) {
          fixture.harness.currentState!.resize(height);
          await tester.pump();
          expect(
            tester.getSize(find.byType(SidebarRankings)),
            Size(172, height),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'Sidebar height $height',
          );
        }
        final sidebar = find.byType(SidebarRankings);
        final scrollable = find.descendant(
          of: sidebar,
          matching: find.byType(Scrollable),
        );
        expect(scrollable, findsOneWidget);
        final scrollState = tester.state<ScrollableState>(scrollable);
        final fullLink = find.descendant(
          of: sidebar,
          matching: find.byWidgetPredicate(
            (widget) => widget is DeskButton && widget.label == '完整热榜',
          ),
        );
        await tester.scrollUntilVisible(fullLink, 160, scrollable: scrollable);
        await tester.pump();
        expect(scrollState.position.pixels, greaterThan(0));
        await tester.tap(fullLink);
        await tester.pump();
        expect(fixture.harness.currentState!.openFullCount, 1);
        expect(fixture.state.rankings.summaryPosts.last['position'], 10);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'maintained sidebar visibility preserves summary scroll position and its controller',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(
        tester,
        full: false,
        width: 172,
        textSize: 22,
        height: 180,
      );
      try {
        await fixture.ready(tester, [
          for (var rank = 1; rank <= 10; rank++) rankingPost(rank),
        ]);
        final scrollable = find.descendant(
          of: find.byType(SidebarRankings),
          matching: find.byType(Scrollable),
        );
        final scrollState = tester.state<ScrollableState>(scrollable);
        await tester.drag(find.byType(SidebarRankings), const Offset(0, -230));
        await tester.pumpAndSettle();
        final offset = scrollState.position.pixels;
        expect(offset, greaterThan(0));
        final controller = fixture.state.rankings;
        fixture.harness.currentState!.show(false);
        await tester.pump();
        fixture.harness.currentState!.show(true);
        await tester.pump();
        expect(tester.state<ScrollableState>(scrollable), same(scrollState));
        expect(scrollState.position.pixels, offset);
        expect(fixture.state.rankings, same(controller));
        expect(fixture.native.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'failed refresh leaves both views readable and manual retry shares one load',
    (tester) async {
      final fixture = await _SurfaceFixture.mount(tester);
      try {
        await fixture.ready(tester, [rankingPost(1)]);
        final failed = fixture.state.rankings.refresh(force: true);
        fixture.native.requests.last.complete(
          posts: [],
          error: 'Fixture offline',
        );
        await failed;
        await tester.pump();
        expect(find.text('Fixture ranking 1'), findsNWidgets(2));
        expect(find.text('更新失败，保留上次榜单'), findsOneWidget);
        expect(find.text('更新失败，保留上次榜单。可点击刷新重试。'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(SidebarRankings),
            matching: find.text('重试'),
          ),
        );
        await tester.pump();
        expect(fixture.native.requests, hasLength(3));
        final retry = fixture.state.rankings.refresh(force: true);
        expect(fixture.native.requests, hasLength(3));
        fixture.native.requests.last.complete(posts: [rankingPost(2)]);
        await retry;
        await tester.pump();
        expect(find.text('Fixture ranking 2'), findsNWidgets(2));
        expect(find.text('更新失败，保留上次榜单'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );
}

class _SurfaceFixture {
  _SurfaceFixture(this.native, this.state, this.harness);
  final RankingsNative native;
  final AppState state;
  final GlobalKey<_RankingHarnessState> harness;

  static Future<_SurfaceFixture> mount(
    WidgetTester tester, {
    bool full = true,
    double width = 220,
    double height = 650,
    double textSize = 12,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 780));
    final native = RankingsNative();
    native.settings = {'workspace.rankingTextSize': textSize};
    final state = AppState(client: native);
    await state.connect();
    final harness = GlobalKey<_RankingHarnessState>();
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: _RankingHarness(
            key: harness,
            state: state,
            full: full,
            width: width,
            height: height,
          ),
        ),
      ),
    );
    await tester.pump();
    return _SurfaceFixture(native, state, harness);
  }

  Future<void> ready(
    WidgetTester tester,
    List<Map<String, dynamic>> posts,
  ) async {
    final loading = state.rankings.refresh();
    native.requests.last.complete(posts: posts);
    await loading;
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    native.completePending();
    await tester.pump();
    await native.snapshotEvents.close();
    await tester.binding.setSurfaceSize(null);
  }
}

class _RankingHarness extends StatefulWidget {
  const _RankingHarness({
    required this.state,
    required this.full,
    required this.width,
    required this.height,
    super.key,
  });
  final AppState state;
  final bool full;
  final double width, height;

  @override
  State<_RankingHarness> createState() => _RankingHarnessState();
}

class _RankingHarnessState extends State<_RankingHarness> {
  late double height = widget.height;
  bool visible = true;
  int openFullCount = 0;

  void resize(double value) => setState(() => height = value);
  void show(bool value) => setState(() => visible = value);
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 1040,
      height: 720,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Visibility(
            visible: visible,
            maintainState: true,
            child: SizedBox(
              width: widget.width,
              height: height,
              child: SidebarRankings(
                state: widget.state,
                onOpenFull: () => openFullCount++,
              ),
            ),
          ),
          if (widget.full) Expanded(child: RankingsScreen(state: widget.state)),
        ],
      ),
    ),
  );
}
