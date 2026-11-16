import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _topicURL = 'https://www.nodeseek.com/post-17-1';
const _otherURL = 'https://www.nodeseek.com/post-18-1';

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _panel => find.byKey(const ValueKey('workspace-search-panel'));
Finder get _input =>
    find.descendant(of: _panel, matching: find.byType(EditableText));

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'toolbar and Command-K cancel back to the embedded settings page without navigation or reads',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.settings(tester);
        expect(find.bySemanticsLabel('搜索帖子或打开链接'), findsOneWidget);
        expect(_button('搜索帖子'), findsOneWidget);
        final workspace = fixture.state.domain('workspace');
        final before = fixture.native.calls.length;
        await fixture.open(tester);
        await tester.enterText(_input, '未提交的设置页草稿');
        await tester.pump();
        await tester.tap(_button('取消'));
        await tester.pumpAndSettle();
        expect(find.text('偏好设置'), findsOneWidget);
        expect(fixture.state.domain('workspace'), same(workspace));
        expect(fixture.native.calls.skip(before), isEmpty);

        await _chord(tester, LogicalKeyboardKey.keyK);
        await tester.pumpAndSettle();
        expect(_panel, findsOneWidget);
        expect(tester.widget<EditableText>(_input).controller.text, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(find.text('偏好设置'), findsOneWidget);
        expect(fixture.native.calls.skip(before), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'cancelling search keeps the real reader element and scroll position while blocking reader shortcuts',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        final reader = tester.element(find.byType(ReaderScreen));
        final scroll = fixture.readerScroll(tester);
        expect(scroll.position.maxScrollExtent, greaterThan(650));
        scroll.jumpTo(650);
        await tester.pump(const Duration(milliseconds: 700));
        final bodyAnchor = fixture.state.readerBodyAnchor(_topicURL);
        expect(bodyAnchor, isNotNull);
        final unchangedPosition = <String, dynamic>{
          'url': _topicURL,
          'topicID': fixture.state.workspace.selected!.id,
          'offset': 650.0,
          'bodyAnchor': bodyAnchor!.toJson(),
        };
        final before = fixture.native.calls.length;
        final selected = fixture.state.workspace.selectedTab;
        await fixture.open(tester);
        await tester.enterText(_input, '未提交的阅读草稿');
        await tester.pump();
        await _chord(tester, LogicalKeyboardKey.keyW);
        await _chord(tester, LogicalKeyboardKey.keyR);
        await _chord(tester, LogicalKeyboardKey.keyK);
        expect(_panel, findsOneWidget);
        expect(fixture.state.workspace.selectedTab, selected);
        await tester.tap(_button('取消'));
        await tester.pumpAndSettle();
        // The 700 ms pump above lays out the body after the initial offset
        // debounce, then starts its 600 ms anchor-save debounce. Opening search
        // must not cancel that local save or turn it into a navigation/read.
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.element(find.byType(ReaderScreen)), same(reader));
        expect(fixture.readerScroll(tester), same(scroll));
        expect(scroll.offset, closeTo(650, .01));
        expect(fixture.state.readerOffset(_topicURL), closeTo(650, .01));
        expect(
          fixture.state.readerBodyAnchor(_topicURL)?.toJson(),
          bodyAnchor.toJson(),
        );
        final calls = fixture.native.calls.skip(before).toList();
        expect(calls, hasLength(1));
        expect(calls.single.$1, 'reader.rememberPosition');
        expect(calls.single.$2, unchangedPosition);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final returnPath in ['toolbar', 'native menu']) {
    testWidgets(
      'account change in settings defers reader loading until returning through $returnPath',
      (tester) async {
        final fixture = await _IntegrationFixture.mount(tester);
        try {
          final oldThread = fixture.state.readerFor(_topicURL)['thread'];
          expect(oldThread, isA<Map>());
          final selection = fixture.state.workspace.selectedTab;
          await fixture.settings(tester);
          final reads = fixture.native.methodsNamed('reader.load').length;
          fixture.native.account(1);
          await tester.pumpAndSettle();
          expect(find.text('偏好设置'), findsOneWidget);
          expect(find.byType(ReaderScreen), findsNothing);
          expect(fixture.state.workspace.selectedTab, selection);
          expect(fixture.state.accessRevision, 1);
          expect(fixture.state.readerFor(_topicURL), isEmpty);
          expect(fixture.native.methodsNamed('reader.load'), hasLength(reads));
          if (returnPath == 'toolbar') {
            await tester.tap(_button('返回论坛'));
          } else {
            fixture.native.navigate('forum');
          }
          await tester.pumpAndSettle();
          expect(find.text('偏好设置'), findsNothing);
          expect(find.byType(ReaderScreen), findsOneWidget);
          expect(find.text('Integration reader content'), findsOneWidget);
          expect(
            fixture.native.methodsNamed('reader.load'),
            hasLength(reads + 1),
          );
          expect(
            fixture.native.methodsNamed('reader.load').last.$2['url'],
            _topicURL,
          );
          expect(fixture.state.accessRevision, 1);
          expect(fixture.state.readerFor(_topicURL)['thread'], isA<Map>());
          expect(
            fixture.state.readerFor(_topicURL)['thread'],
            isNot(same(oldThread)),
          );
          expect(fixture.native.methodsNamed('listing.search'), isEmpty);
          expect(fixture.native.methodsNamed('reader.open'), isEmpty);
          expect(fixture.native.methodsNamed('listing.refresh'), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'returning from settings through toolbar or native menu reuses an existing reader without another read',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        final thread = fixture.state.readerFor(_topicURL)['thread'];
        expect(thread, isA<Map>());
        final reads = fixture.native.methodsNamed('reader.load').length;
        for (final returnPath in ['toolbar', 'native menu']) {
          await fixture.settings(tester);
          if (returnPath == 'toolbar') {
            await tester.tap(_button('返回论坛'));
          } else {
            fixture.native.navigate('forum');
          }
          await tester.pumpAndSettle();
          expect(find.text('偏好设置'), findsNothing);
          expect(find.text('Integration reader content'), findsOneWidget);
          expect(fixture.state.readerFor(_topicURL)['thread'], same(thread));
          expect(fixture.native.methodsNamed('reader.load'), hasLength(reads));
          expect(fixture.native.methodsNamed('reader.open'), isEmpty);
          expect(fixture.native.methodsNamed('listing.refresh'), isEmpty);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'Enter submits detached kind and scope once and only then switches settings to forum overview',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.settings(tester);
        await fixture.open(tester);
        expect(fixture.native.methodsNamed('listing.search'), isEmpty);
        await tester.tap(
          find.descendant(of: _panel, matching: find.text('帖子')),
        );
        await tester.tap(
          find.byKey(const ValueKey('workspace-search-scope-daily')),
        );
        await tester.enterText(_input, '  Integration query  ');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final requests = fixture.native.methodsNamed('listing.search');
        expect(requests, hasLength(1));
        expect(requests.single.$2['query'], 'Integration query');
        expect(requests.single.$2['kind'], 'posts');
        expect(requests.single.$2['scope'], unorderedEquals(['tech', 'daily']));
        expect(_panel, findsNothing);
        expect(find.text('偏好设置'), findsNothing);
        expect(find.byType(ReaderScreen), findsNothing);
        expect(fixture.state.workspace.showReader, isFalse);
        expect(fixture.native.methodsNamed('reader.overview'), isEmpty);
        expect(fixture.native.methodsNamed('listing.refresh'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'history submission uses the saved kind and scope instead of the edited draft',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(_input, 'discard this draft');
        await tester.pump();
        await tester.tap(
          find.descendant(of: _panel, matching: find.text('用户')),
        );
        await tester.tap(
          find.byKey(const ValueKey('workspace-search-history-0')),
        );
        await tester.pumpAndSettle();
        final request = fixture.native.methodsNamed('listing.search').single.$2;
        expect(request['query'], 'Saved query');
        expect(request['kind'], 'posts');
        expect(request['scope'], ['daily']);
        expect(fixture.state.workspace.showReader, isFalse);
        expect(fixture.native.methodsNamed('reader.open'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final link in ['$_topicURL#comment-35', '$_topicURL/#comment-35']) {
    testWidgets(
      'an official same-topic fragment locates the reply without searching: $link',
      (tester) async {
        final fixture = await _IntegrationFixture.mount(tester);
        try {
          await fixture.open(tester);
          await tester.enterText(_input, link);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          for (var frame = 0; frame < 160; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            if (find
                .text('Integration reply 35')
                .hitTestable()
                .evaluate()
                .isNotEmpty) {
              break;
            }
          }
          expect(fixture.native.methodsNamed('reader.open'), hasLength(1));
          expect(
            fixture.native.methodsNamed('reader.open').single.$2['url'],
            link,
          );
          expect(fixture.native.methodsNamed('listing.search'), isEmpty);
          expect(fixture.native.methodsNamed('listing.refresh'), isEmpty);
          expect(fixture.native.methodsNamed('reader.overview'), isEmpty);
          expect(fixture.state.workspace.selectedTab, '17');
          expect(fixture.state.workspace.selected!.url, link);
          expect(
            find.text('Integration reply 35').hitTestable(),
            findsOneWidget,
          );
          final position = fixture.readerScroll(tester).offset;
          await tester.pump(const Duration(milliseconds: 800));
          expect(fixture.readerScroll(tester).offset, closeTo(position, .01));
          expect(fixture.native.methodsNamed('reader.open'), hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  for (final hasResults in [true, false]) {
    testWidgets(
      'people-only search owns the main results area without a posts empty state, results=$hasResults',
      (tester) async {
        final fixture = await _IntegrationFixture.mount(tester);
        try {
          if (hasResults) {
            fixture.native.searchPeople = [
              {'id': 99, 'name': 'Integration member', 'avatar': ''},
            ];
          }
          await fixture.open(tester);
          await tester.tap(
            find.descendant(of: _panel, matching: find.text('用户')),
          );
          await tester.enterText(_input, 'Member lookup');
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          final request = fixture.native
              .methodsNamed('listing.search')
              .single
              .$2;
          expect(request['kind'], 'people');
          expect(request['scope'], isEmpty);
          expect(find.byType(ReaderScreen), findsNothing);
          expect(find.text('暂无帖子'), findsNothing);
          final pane = find.byKey(const ValueKey('forum-list-pane'));
          final columns = find.byKey(const ValueKey('forum-pane-row'));
          expect(
            tester.getSize(pane).width,
            closeTo(tester.getSize(columns).width, .01),
          );
          if (hasResults) {
            expect(
              find.text('Integration member').hitTestable(),
              findsOneWidget,
            );
            expect(find.text('1 位用户'), findsOneWidget);
            expect(find.text('没有匹配的用户'), findsNothing);
            final people = find.byKey(
              const PageStorageKey('forum-people:0:Member lookup'),
            );
            expect(
              tester.getSize(people).height,
              greaterThan(tester.getSize(pane).height * .6),
            );
          } else {
            expect(find.text('没有匹配的用户'), findsOneWidget);
            expect(find.text('0 位用户'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  for (final link in [
    'http://www.nodeseek.com/post-17-1#35',
    'https://www.nodeseek.com.evil.invalid/post-17-1',
    'https://user@www.nodeseek.com/post-17-1',
    'https://www.nodeseek.com:444/post-17-1',
  ]) {
    testWidgets('nonofficial topic boundary submits as search: $link', (
      tester,
    ) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(_input, link);
        await tester.pump();
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(fixture.native.methodsNamed('reader.open'), isEmpty);
        expect(
          fixture.native.methodsNamed('listing.search').single.$2['query'],
          link,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    });
  }

  testWidgets(
    'native menu commands are consumed while search is open and unknown destinations are ignored',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.settings(tester);
        final before = fixture.native.calls.length;
        await fixture.open(tester);
        fixture.native.navigate('forum');
        fixture.native.navigate('inbox');
        await tester.pump();
        expect(_panel, findsOneWidget);
        await tester.tap(_button('取消'));
        await tester.pumpAndSettle();
        expect(find.text('偏好设置'), findsOneWidget);
        fixture.native.emit('settings', fixture.native.settings);
        fixture.native.navigate('unexpected-destination');
        await tester.pumpAndSettle();
        expect(find.text('偏好设置'), findsOneWidget);
        expect(fixture.native.calls.skip(before), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'covered routes and the office cover block both a captured toolbar callback and Command-K',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        final open = tester.widget<DeskButton>(_button('搜索帖子')).onTap!;
        unawaited(
          fixture.navigator.currentState!.push(
            CupertinoPageRoute<void>(
              builder: (context) => const CupertinoPageScaffold(
                child: Center(child: Text('Integration covering route')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        open();
        await _chord(tester, LogicalKeyboardKey.keyK);
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(find.text('Integration covering route'), findsOneWidget);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        fixture.native.cover(true);
        await tester.pump();
        open();
        await _chord(tester, LogicalKeyboardKey.keyK);
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(find.text('Integration office cover'), findsOneWidget);
        fixture.native.cover(false);
        await tester.pump();
        await _chord(tester, LogicalKeyboardKey.keyK);
        await tester.pumpAndSettle();
        expect(_panel, findsOneWidget);
        await tester.tap(_button('取消'));
        await tester.pumpAndSettle();
        expect(fixture.native.methodsNamed('listing.search'), isEmpty);
        expect(fixture.native.methodsNamed('reader.open'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'account changes reject a captured submit and a delayed history response',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        fixture.native.deferClear = true;
        await fixture.open(tester);
        await tester.enterText(_input, 'Old identity draft');
        await tester.pump();
        final submit = tester.widget<DeskButton>(_button('搜索')).onTap!;
        await tester.tap(_button('清空记录'));
        await tester.pump();
        expect(fixture.native.pendingClear, isNotNull);
        fixture.native.account(1);
        submit();
        fixture.native.pendingClear!.complete(fixture.native.workspace);
        await tester.pumpAndSettle();
        expect(find.text('账号已变更'), findsOneWidget);
        expect(find.text('Old identity draft'), findsNothing);
        expect(fixture.native.methodsNamed('listing.search'), isEmpty);
        expect(fixture.native.methodsNamed('reader.open'), isEmpty);
        await tester.tap(_button('关闭搜索'));
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(find.text('Integration reader content'), findsOneWidget);
        expect(fixture.state.accessRevision, 1);
        expect(fixture.state.readerFor(_topicURL)['thread'], isA<Map>());
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final boundary in ['account', 'office']) {
    testWidgets(
      '$boundary change between route pop and search completion rejects the returned request',
      (tester) async {
        final fixture = await _IntegrationFixture.mount(tester);
        try {
          await fixture.open(tester);
          await tester.enterText(_input, 'Late completed draft');
          await tester.pump();
          final submit = tester.widget<DeskButton>(_button('搜索')).onTap!;
          submit();
          if (boundary == 'account') {
            fixture.native.account(1);
          } else {
            fixture.native.cover(true);
          }
          await tester.pumpAndSettle();
          expect(fixture.native.methodsNamed('listing.search'), isEmpty);
          expect(fixture.native.methodsNamed('reader.open'), isEmpty);
          if (boundary == 'office') {
            expect(find.text('Integration office cover'), findsOneWidget);
            fixture.native.cover(false);
            await tester.pumpAndSettle();
          }
          expect(_panel, findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'a navigation revision invalidates the draft even when the selected tab and board stay the same',
    (tester) async {
      final fixture = await _IntegrationFixture.mount(tester);
      try {
        await fixture.open(tester);
        await tester.enterText(_input, 'Old navigation draft');
        await tester.pump();
        final selection = fixture.state.workspace.selectedTab;
        final board = fixture.state.workspace.board;
        await fixture.state.selectTopic(
          TopicData({'id': '17', 'url': _topicURL}),
        );
        await tester.pump();
        expect(fixture.state.workspace.selectedTab, selection);
        expect(fixture.state.workspace.board, board);
        await tester.tap(_button('搜索'));
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(fixture.native.methodsNamed('reader.select'), hasLength(1));
        expect(fixture.native.methodsNamed('listing.search'), isEmpty);
        expect(fixture.native.methodsNamed('reader.open'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final changed in ['board', 'selectedTab']) {
    testWidgets(
      'a detached search cannot submit after $changed changes underneath it',
      (tester) async {
        final fixture = await _IntegrationFixture.mount(tester);
        try {
          await fixture.open(tester);
          await tester.enterText(_input, 'Stale navigation draft');
          await tester.pump();
          fixture.native.workspace = {
            ...fixture.native.workspace,
            if (changed == 'board') ...{
              'board': 'daily',
              'boardCategoryID': 'daily',
            },
            if (changed == 'selectedTab') 'selectedTab': '18',
          };
          fixture.native.emit('workspace', fixture.native.workspace);
          await tester.pump();
          await tester.tap(_button('搜索'));
          await tester.pumpAndSettle();
          expect(_panel, findsNothing);
          expect(fixture.native.methodsNamed('listing.search'), isEmpty);
          expect(fixture.native.methodsNamed('reader.open'), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }
}

class _IntegrationNative extends NativeClient {
  _IntegrationNative()
    : super(
        methods: MethodChannel(
          'seekdesk.test.search.integration.${_channel++}',
        ),
      );
  static int _channel = 0;
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  int eventID = 0;
  bool deferClear = false;
  Completer<JsonMap>? pendingClear;
  List<JsonMap> searchPeople = [];
  final JsonMap settings = {
    'appearance': 'light',
    'workspace.autoLoadOlder': false,
  };
  JsonMap workspace = {
    'board': 'tech',
    'boardCategoryID': 'tech',
    'boardURL': 'https://www.nodeseek.com/categories/tech',
    'query': '',
    'appliedSearchKind': 'all',
    'appliedSearchScope': <String>[],
    'searchHistory': [
      {
        'query': 'Saved query',
        'kind': 'posts',
        'scope': ['daily'],
      },
    ],
    'showReader': true,
    'selectedTab': '17',
    'tabs': [
      {'id': '17', 'url': _topicURL, 'title': 'Integration topic'},
      {'id': '18', 'url': _otherURL, 'title': 'Other integration topic'},
    ],
    'posts': <JsonMap>[],
    'boards': [
      {'id': '', 'title': '最新帖子', 'searchable': false},
      {'id': 'tech', 'title': '技术', 'searchable': true},
      {'id': 'daily', 'title': '日常', 'searchable': true},
    ],
  };

  JsonMap extensions(bool covered) => {
    'items': [
      {'id': 'office', 'active': true},
    ],
    'settings': {
      'office': {
        'presented': covered,
        'title': 'Integration office cover',
        'button': '恢复窗口',
        'key': '9',
      },
    },
  };

  JsonMap reader(String url) => {
    'url': url,
    'scrollOffset': 0,
    'thread': {
      'title': 'Integration reader content',
      'root': {
        'id': '0',
        'author': 'Fixture',
        'blocks': [
          {'kind': 'text', 'text': 'Local integration root'},
        ],
      },
      'replies': [
        for (var floor = 1; floor <= 45; floor++)
          {
            'id': '$floor',
            'author': 'Fixture $floor',
            'blocks': [
              {'kind': 'text', 'text': 'Integration reply $floor'},
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  Iterable<(String, JsonMap)> methodsNamed(String method) =>
      calls.where((call) => call.$1 == method);
  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  void emit(String domain, JsonMap data) => eventsController.add({
    'domain': domain,
    'data': data,
    'accessRevision': accessRevision,
  });
  void navigate(String destination) =>
      emit('navigation', {'destination': destination, 'id': '${eventID++}'});
  void cover(bool covered) => emit('extensions', extensions(covered));
  void account(int revision) => eventsController.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {
      'account': 'signedIn',
      'owner': revision + 1,
      'accessRevision': revision,
    },
  });

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'session': {'account': 'signedIn', 'owner': 1, 'accessRevision': 0},
          'extensions': extensions(false),
          'settings': settings,
        };
      case 'settings.get':
        return {...settings};
      case 'reader.load':
        return reader(stringValue(arguments['url']));
      case 'reader.rememberPosition':
        return {};
      case 'reader.select':
        workspace = {
          ...workspace,
          'showReader': true,
          'selectedTab': arguments['id'],
        };
        return workspace;
      case 'listing.search':
        workspace = {
          ...workspace,
          'query': arguments['query'],
          'appliedSearchKind': arguments['kind'],
          'appliedSearchScope': arguments['scope'],
          'showReader': false,
          'people': arguments['kind'] == 'people' ? searchPeople : <JsonMap>[],
        };
        return workspace;
      case 'reader.open':
        final url = stringValue(arguments['url']);
        final id = Uri.parse(url).pathSegments
            .where((segment) => segment.isNotEmpty)
            .single
            .split('-')[1];
        workspace = {
          ...workspace,
          'showReader': true,
          'selectedTab': id,
          'tabs': [
            for (final tab in jsonItems(workspace['tabs']))
              if (tab['id'] == id) {...tab, 'url': url} else tab,
          ],
        };
        return workspace;
      case 'listing.clearHistory':
        if (deferClear) {
          pendingClear = Completer<JsonMap>();
          return pendingClear!.future;
        }
        workspace = {...workspace, 'searchHistory': <JsonMap>[]};
        return workspace;
      case 'extensions.office':
        return extensions(arguments['presented'] == true);
      default:
        throw StateError(
          'Unexpected workspace search integration call: $method',
        );
    }
  }
}

class _IntegrationFixture {
  _IntegrationFixture(this.native, this.state);
  final _IntegrationNative native;
  final AppState state;
  final navigator = GlobalKey<NavigatorState>();

  static Future<_IntegrationFixture> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1380, 880));
    final native = _IntegrationNative();
    final state = AppState(client: native);
    await state.connect();
    state.readers[_topicURL] = native.reader(_topicURL);
    state.readers[_otherURL] = native.reader(_otherURL);
    final fixture = _IntegrationFixture(native, state);
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: fixture.navigator,
          builder: (context, child) =>
              ExtensionOverlays(state: state, child: child!),
          home: WorkspaceScreen(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  ScrollController readerScroll(WidgetTester tester) => tester
      .widget<CustomScrollView>(
        find.descendant(
          of: find.byType(ReaderScreen),
          matching: find.byType(CustomScrollView),
        ),
      )
      .controller!;

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-footer')),
        matching: find.text('设置'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('偏好设置'), findsOneWidget);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(_button('搜索帖子'));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    final clear = native.pendingClear;
    if (clear != null && !clear.isCompleted) clear.complete(native.workspace);
    await tester.pump();
    await native.eventsController.close();
    await tester.binding.setSurfaceSize(null);
  }
}
