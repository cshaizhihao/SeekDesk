import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_search.dart';

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _scope(String id) => find.byKey(ValueKey('workspace-search-scope-$id'));
Finder get _input => find.byKey(const ValueKey('workspace-search-input'));
Finder get _panel => find.byKey(const ValueKey('workspace-search-panel'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final dismissal in ['取消', '遮罩', 'Escape']) {
    testWidgets(
      '$dismissal dismisses the draft without searching or changing the workspace',
      (tester) async {
        final fixture = await _Fixture.mount(tester);
        try {
          final before = fixture.state.domain('workspace');
          await fixture.open(tester);
          await tester.enterText(find.byType(EditableText), 'local draft');
          await tester.pump();
          await tester.tap(_scope('daily'));
          await tester.pump();
          switch (dismissal) {
            case '取消':
              await tester.tap(_button('取消'));
            case '遮罩':
              await tester.tapAt(const Offset(8, 8));
            case 'Escape':
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          }
          await tester.pumpAndSettle();
          expect(fixture.completed, isTrue);
          expect(fixture.result, isNull);
          expect(fixture.state.domain('workspace'), same(before));
          expect(fixture.native.calls.map((call) => call.$1), ['bootstrap']);
          expect(find.text('保留的阅读画面'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'empty query defaults to current searchable board and returns an immutable detached draft',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        expect(
          tester
              .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
              .selectedIndex,
          0,
        );
        expect(
          tester.widget<Semantics>(_scope('tech')).properties.selected,
          isTrue,
        );
        expect(_scope('home'), findsNothing);
        expect(_scope('award'), findsNothing);
        expect(_scope('private'), findsNothing);
        expect(_scope('legacy'), findsOneWidget);
        await tester.tap(find.text('帖子').last);
        await tester.tap(_scope('daily'));
        await tester.enterText(find.byType(EditableText), '  search text  ');
        await tester.pump();
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(fixture.completed, isTrue);
        expect(fixture.result!.query, 'search text');
        expect(fixture.result!.kind, 'posts');
        expect(fixture.result!.scope, {'tech', 'daily'});
        expect(
          () => fixture.result!.scope.add('other'),
          throwsUnsupportedError,
        );
        expect(fixture.state.domain('workspace')['query'], '');
        expect(fixture.native.calls.map((call) => call.$1), ['bootstrap']);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'existing query restores applied kind and scope and initially selects all text',
    (tester) async {
      final native = _SearchNative()
        ..query = 'existing query'
        ..appliedKind = 'posts'
        ..appliedScope = ['daily', 'award', 'missing'];
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        final input = tester.widget<GlassTextField>(_input);
        expect(input.focusNode!.hasFocus, isTrue);
        expect(
          input.controller!.selection,
          const TextSelection(baseOffset: 0, extentOffset: 14),
        );
        expect(
          tester
              .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
              .selectedIndex,
          1,
        );
        expect(
          tester.widget<Semantics>(_scope('daily')).properties.selected,
          isTrue,
        );
        expect(
          tester.widget<Semantics>(_scope('tech')).properties.selected,
          isFalse,
        );
        input.onSuffixTap!();
        await tester.pump();
        expect(input.controller!.text, '');
        expect(tester.widget<DeskButton>(_button('搜索')).onTap, isNull);
        expect(
          tester.widget<Semantics>(_scope('daily')).properties.selected,
          isTrue,
        );
        expect(fixture.native.calls, hasLength(1));
        await tester.enterText(find.byType(EditableText), 'next');
        await tester.pump();
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(fixture.result!.scope, {'daily'});
        expect(fixture.result!.kind, 'posts');
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'legacy board fixtures exclude home and award while people submissions have no scope',
    (tester) async {
      final native = _SearchNative()
        ..category = null
        ..board = 'award';
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        expect(
          tester.widget<Semantics>(_scope('')).properties.selected,
          isTrue,
        );
        await tester.tap(_scope('tech'));
        await tester.tap(find.text('用户').last);
        await tester.pump();
        expect(find.text('搜索版块'), findsNothing);
        expect(find.text('按用户名查找论坛成员。'), findsOneWidget);
        await tester.enterText(find.byType(EditableText), 'Fixture user');
        await tester.pump();
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(fixture.result!.kind, 'people');
        expect(fixture.result!.scope, isEmpty);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'only the first five history entries show and replay restores its own query scope and kind',
    (tester) async {
      final native = _SearchNative()
        ..history = [
          {
            'query': 'Historical query',
            'scope': ['daily'],
            'kind': 'posts',
          },
          for (var index = 2; index <= 6; index++)
            {'query': 'History $index', 'scope': <String>[], 'kind': 'all'},
        ];
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        expect(find.text('History 5'), findsOneWidget);
        expect(find.text('History 6'), findsNothing);
        expect(find.text('帖子 · 日常'), findsOneWidget);
        await tester.enterText(find.byType(EditableText), 'Unsubmitted draft');
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('workspace-search-history-0')),
        );
        await tester.pumpAndSettle();
        expect(fixture.result!.query, 'Historical query');
        expect(fixture.result!.scope, {'daily'});
        expect(fixture.result!.kind, 'posts');
        expect(fixture.native.calls.map((call) => call.$1), ['bootstrap']);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'blank input and IME Return or Escape cannot submit or dismiss; committed Return submits once',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), '   ');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(_panel, findsOneWidget);
        expect(fixture.completed, isFalse);
        final field = tester.widget<GlassTextField>(_input);
        field.controller!.value = const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        field.onSubmitted!('拼音');
        await tester.pump();
        expect(_panel, findsOneWidget);
        expect(fixture.completed, isFalse);
        expect(field.controller!.text, '拼音');
        expect(
          field.controller!.value.composing,
          const TextRange(start: 0, end: 2),
        );
        field.controller!.value = const TextEditingValue(
          text: '已确认',
          selection: TextSelection.collapsed(offset: 3),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(fixture.result!.query, '已确认');
        expect(fixture.completions, 1);
        expect(fixture.native.calls, hasLength(1));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'clearing history has one busy request and preserves input and scope',
    (tester) async {
      final native = _SearchNative()..deferClear = true;
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), 'Keep draft');
        await tester.pump();
        final clear = tester.widget<DeskButton>(_button('清空记录'));
        clear.onTap!();
        clear.onTap!();
        await tester.pump();
        expect(
          native.calls.where((call) => call.$1 == 'listing.clearHistory'),
          hasLength(1),
        );
        expect(tester.widget<DeskButton>(_button('清空记录')).busy, isTrue);
        native.history = [];
        native.pendingClear!.complete(native.workspace);
        await tester.pump();
        expect(find.text('最近搜索'), findsNothing);
        expect(
          tester.widget<GlassTextField>(_input).controller!.text,
          'Keep draft',
        );
        expect(
          tester.widget<Semantics>(_scope('tech')).properties.selected,
          isTrue,
        );
        expect(fixture.completed, isFalse);
        expect(
          native.calls.where((call) => call.$1 == 'listing.search'),
          isEmpty,
        );
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'failed history deletion keeps history and permits a fresh explicit retry',
    (tester) async {
      final native = _SearchNative()..failClear = true;
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        await tester.tap(_button('清空记录'));
        await tester.pump();
        expect(find.text('清空记录失败，请重试。'), findsOneWidget);
        expect(find.text('Recent fixture'), findsOneWidget);
        expect(tester.widget<DeskButton>(_button('清空记录')).busy, isFalse);
        native.failClear = false;
        await tester.tap(_button('清空记录'));
        await tester.pump();
        expect(find.text('Recent fixture'), findsNothing);
        expect(
          native.calls.where((call) => call.$1 == 'listing.clearHistory'),
          hasLength(2),
        );
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'account change hides old draft and history and rejects captured submission callbacks',
    (tester) async {
      final native = _SearchNative()..deferClear = true;
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), 'Old account draft');
        await tester.pump();
        final submit = tester.widget<DeskButton>(_button('搜索')).onTap!;
        final history = tester
            .widget<HoverRow>(
              find.byKey(const ValueKey('workspace-search-history-0')),
            )
            .onTap;
        await tester.tap(_button('清空记录'));
        native.account(1);
        submit();
        history();
        native.pendingClear!.complete(native.workspace);
        await tester.pump();
        expect(find.text('账号已变更'), findsOneWidget);
        expect(_input, findsNothing);
        expect(find.text('Recent fixture'), findsNothing);
        expect(find.text('Old account draft'), findsNothing);
        expect(fixture.completed, isFalse);
        await tester.tap(_button('关闭搜索'));
        await tester.pumpAndSettle();
        expect(fixture.completed, isTrue);
        expect(fixture.result, isNull);
        expect(
          native.calls.where((call) => call.$1 == 'listing.search'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'covered search callbacks cannot pop another route and account invalidation waits underneath',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), 'Pending draft');
        await tester.pump();
        final submit = tester.widget<DeskButton>(_button('搜索')).onTap!;
        final cancel = tester.widget<DeskButton>(_button('取消')).onTap!;
        unawaited(
          fixture.navigator.currentState!.push(
            CupertinoPageRoute<void>(
              builder: (context) => const CupertinoPageScaffold(
                child: Center(child: Text('Newer route')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        submit();
        cancel();
        fixture.native.account(1);
        await tester.pump();
        expect(find.text('Newer route'), findsOneWidget);
        expect(fixture.completed, isFalse);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('账号已变更'), findsOneWidget);
        await tester.tap(_button('关闭搜索'));
        await tester.pumpAndSettle();
        expect(fixture.result, isNull);
        expect(fixture.completions, 1);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'office cover blocks captured search actions and removing it preserves the draft',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), 'Office draft');
        await tester.pump();
        final submit = tester.widget<DeskButton>(_button('搜索')).onTap!;
        final cancel = tester.widget<DeskButton>(_button('取消')).onTap!;
        fixture.native.cover(true);
        await tester.pump();
        submit();
        cancel();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(fixture.completed, isFalse);
        expect(find.text('Fixture work sheet'), findsOneWidget);
        fixture.native.cover(false);
        await tester.pump();
        expect(
          tester.widget<GlassTextField>(_input).controller!.text,
          'Office draft',
        );
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(fixture.result!.query, 'Office draft');
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final viewport in [const Size(800, 700), const Size(360, 300)]) {
    testWidgets(
      'bounded search remains scrollable at $viewport and large text without resizing glyphs',
      (tester) async {
        final fixture = await _Fixture.mount(
          tester,
          size: viewport,
          textScale: 2,
        );
        try {
          await fixture.open(tester);
          expect(tester.getSize(_panel).width, lessThanOrEqualTo(560));
          expect(
            tester.getSize(_panel).width,
            lessThanOrEqualTo(viewport.width - 32),
          );
          expect(
            tester.getSize(_panel).height,
            lessThanOrEqualTo(viewport.height - 32),
          );
          expect(tester.widget<GlassTextField>(_input).pressScale, 1);
          final interaction = GlassThemeData.of(tester.element(_button('取消')))
              .interaction;
          expect(interaction.interactionScale, 1);
          expect(interaction.stretch, 0);
          expect(tester.takeException(), isNull);
          final scrollable = find
              .descendant(of: _panel, matching: find.byType(Scrollable))
              .first;
          await tester.scrollUntilVisible(
            _button('取消'),
            120,
            scrollable: scrollable,
          );
          await tester.tap(_button('取消'));
          await tester.pumpAndSettle();
          expect(fixture.completed, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'a late clear response after route disposal cannot mutate a new search draft',
    (tester) async {
      final native = _SearchNative()..deferClear = true;
      final fixture = await _Fixture.mount(tester, native: native);
      try {
        await fixture.open(tester);
        await tester.tap(_button('清空记录'));
        await tester.tap(_button('取消'));
        await tester.pumpAndSettle();
        await fixture.open(tester);
        await tester.enterText(find.byType(EditableText), 'New draft');
        await tester.pump();
        native.history = [];
        native.pendingClear!.complete(native.workspace);
        await tester.pump();
        expect(
          tester.widget<GlassTextField>(_input).controller!.text,
          'New draft',
        );
        expect(fixture.completed, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );
}

class _SearchNative extends NativeClient {
  _SearchNative()
    : super(methods: MethodChannel('seekdesk.test.search.${_nextChannel++}'));
  static int _nextChannel = 0;
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  String query = '', board = 'tech', appliedKind = 'all';
  String? category = 'tech';
  List<String> appliedScope = [];
  bool deferClear = false, failClear = false;
  Completer<JsonMap>? pendingClear;
  List<JsonMap> history = [
    {
      'query': 'Recent fixture',
      'scope': ['daily'],
      'kind': 'posts',
    },
  ];

  JsonMap get workspace => {
    'query': query,
    'board': board,
    if (category != null) 'boardCategoryID': category,
    'appliedSearchKind': appliedKind,
    'appliedSearchScope': appliedScope,
    'searchHistory': history,
    'showReader': true,
    'selectedTab': '17',
    'tabs': [
      {'id': '17', 'url': 'https://www.nodeseek.com/post-17-1'},
    ],
    'boards': [
      {'id': '', 'title': '最新帖子', 'searchable': false},
      {'id': 'home', 'title': '首页'},
      {'id': 'award', 'title': '精品区'},
      {'id': 'tech', 'title': '技术', 'searchable': true},
      {'id': 'daily', 'title': '日常', 'searchable': true},
      {'id': 'private', 'title': '不可搜索', 'searchable': false},
      {'id': 'legacy', 'title': '旧版版块'},
    ],
  };

  JsonMap extensions(bool covered) => {
    'items': [
      {'id': 'office', 'active': true},
    ],
    'settings': {
      'office': {
        'presented': covered,
        'title': 'Fixture work sheet',
        'button': '恢复窗口',
        'key': '9',
      },
    },
  };

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'session': {'account': 'signedIn', 'accessRevision': 0},
          'extensions': extensions(false),
        };
      case 'listing.clearHistory':
        if (deferClear) {
          pendingClear = Completer<JsonMap>();
          return pendingClear!.future;
        }
        if (failClear) {
          throw const NativeFailure('fixture_failure', 'Fixture clear failed');
        }
        history = [];
        return workspace;
      case 'extensions.office':
        return extensions(arguments['presented'] == true);
      default:
        throw StateError('Unexpected search fixture call: $method');
    }
  }

  void account(int revision) => snapshotEvents.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {'account': 'signedIn', 'accessRevision': revision},
  });

  void cover(bool covered) => snapshotEvents.add({
    'domain': 'extensions',
    'accessRevision': accessRevision,
    'data': extensions(covered),
  });
}

class _Fixture {
  _Fixture(this.native, this.state);
  final _SearchNative native;
  final AppState state;
  final navigator = GlobalKey<NavigatorState>();
  bool completed = false;
  int completions = 0;
  WorkspaceSearchRequest? result;

  static Future<_Fixture> mount(
    WidgetTester tester, {
    _SearchNative? native,
    Size size = const Size(1000, 820),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    final client = native ?? _SearchNative();
    final state = AppState(client: client);
    await state.connect();
    final fixture = _Fixture(client, state);
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: fixture.navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: ExtensionOverlays(state: state, child: child!),
          ),
          home: const CupertinoPageScaffold(
            child: Center(
              child: Text('保留的阅读画面', key: ValueKey('search-fixture-root')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return fixture;
  }

  Future<void> open(WidgetTester tester) async {
    completed = false;
    result = null;
    unawaited(
      showWorkspaceSearch(
        tester.element(find.byKey(const ValueKey('search-fixture-root'))),
        state: state,
      ).then((value) {
        completed = true;
        completions++;
        result = value;
      }),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    final pending = native.pendingClear;
    if (pending != null && !pending.isCompleted) {
      pending.complete(native.workspace);
    }
    await tester.pump();
    await native.snapshotEvents.close();
    await tester.binding.setSurfaceSize(null);
  }
}
