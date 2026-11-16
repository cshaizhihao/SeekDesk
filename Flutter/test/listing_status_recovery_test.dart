import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

List<JsonMap> _posts([int count = 1]) => [
  for (var index = 0; index < count; index++)
    {
      'id': '${7000 + index}',
      'url': 'https://www.nodeseek.com/post-${7000 + index}-1',
      'title': 'Cached post $index',
      'author': 'Local fixture',
      'category': '技术',
    },
];

const _person = {'id': 77, 'name': 'Cached member', 'avatar': ''};

JsonMap _workspace([JsonMap values = const {}]) => {
  'posts': <JsonMap>[],
  'tabs': <JsonMap>[],
  'selectedTab': '',
  'showReader': false,
  'board': '',
  'boardURL': 'https://www.nodeseek.com/',
  'boards': [
    {'id': '', 'title': '最新帖子'},
    {'id': 'tech', 'title': '技术', 'searchable': true},
  ],
  'query': '',
  'appliedSearchKind': 'all',
  'appliedSearchScope': <String>[],
  'people': <JsonMap>[],
  'peopleLoading': false,
  'peopleErrorCode': null,
  'peopleError': null,
  'showsPeopleResults': false,
  'loading': false,
  'error': null,
  'errorCode': null,
  'hasForumPage': true,
  'failedToLoadOlder': false,
  'failedToRefresh': false,
  'canLoadOlder': false,
  ...values,
};

JsonMap _peopleSearch([JsonMap values = const {}]) => _workspace({
  'query': 'member',
  'appliedSearchKind': 'people',
  'showsPeopleResults': true,
  ...values,
});

class _ListingNative extends NativeClient {
  _ListingNative(this.workspace)
    : super(methods: const MethodChannel('seekdesk.test.listing-status'));

  JsonMap workspace;
  JsonMap? refreshResponse, clearResponse, searchResponse, olderResponse;
  final snapshotsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];

  @override
  Stream<JsonMap> get snapshots => snapshotsController.stream;

  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);

  void publish(JsonMap value) {
    workspace = value;
    snapshotsController.add({
      'domain': 'workspace',
      'accessRevision': accessRevision,
      'data': {...workspace},
    });
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': {...workspace},
          'settings': {'workspace.autoLoadOlder': true},
          'session': {'account': 'signedOut', 'accessRevision': accessRevision},
          'extensions': {'items': <JsonMap>[]},
        };
      case 'listing.refresh':
        workspace = refreshResponse ?? workspace;
        return {...workspace};
      case 'listing.clearSearch':
        workspace = clearResponse ?? _workspace();
        return {...workspace};
      case 'listing.search':
        workspace = {
          ..._workspace(searchResponse ?? {}),
          'query': arguments['query'],
          'appliedSearchKind': arguments['kind'],
          'appliedSearchScope': arguments['scope'],
          'showsPeopleResults': arguments['kind'] != 'posts',
        };
        return {...workspace};
      case 'listing.older':
        workspace = olderResponse ?? workspace;
        return {...workspace};
      case 'session.signIn':
      case 'session.verify':
        return {};
      default:
        unexpected.add(method);
        throw StateError('Unexpected listing fixture operation: $method');
    }
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _status => find.byKey(const ValueKey('forum-list-status'));
Finder get _search => find.byKey(const ValueKey('workspace-search-panel'));

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _ListingNative native, {
  Size size = const Size(1380, 880),
}) async {
  await tester.binding.setSurfaceSize(size);
  final state = AppState(client: native);
  await state.connect();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await native.snapshotsController.close();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
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

void _expectNoAccessAction() {
  expect(_button('登录 NodeSeek'), findsNothing);
  expect(_button('打开验证窗口'), findsNothing);
  expect(_button('登录 / 验证'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final code in ['network', 'signInRequired', 'verification']) {
    testWidgets('people-only $code failure is not a successful empty search', (
      tester,
    ) async {
      final native = _ListingNative(_peopleSearch({'peopleErrorCode': code}));
      await _mount(tester, native);
      expect(find.text('暂时无法读取用户结果'), findsOneWidget);
      expect(find.text('用户结果暂不可用'), findsOneWidget);
      expect(find.text('没有匹配的用户'), findsNothing);
      expect(find.text('暂无帖子'), findsNothing);
      expect(find.text('0 位用户'), findsNothing);
      if (code == 'network') {
        _expectNoAccessAction();
      } else {
        await tester.tap(
          _button(code == 'signInRequired' ? '登录 NodeSeek' : '打开验证窗口'),
        );
        await _frames(tester);
        final method = code == 'signInRequired'
            ? 'session.signIn'
            : 'session.verify';
        expect(native.named(method), hasLength(1));
        if (code == 'verification') {
          expect(native.named(method).single.$2, {
            'url': 'https://www.nodeseek.com/',
          });
        }
      }
      native.refreshResponse = _peopleSearch({
        'people': [_person],
      });
      await tester.tap(_button('重试'));
      await _frames(tester);
      expect(native.named('listing.refresh'), hasLength(1));
      expect(native.named('listing.search'), isEmpty);
      expect(find.text('Cached member'), findsOneWidget);
      expect(find.text('1 位用户'), findsOneWidget);
      expect(find.text('用户结果暂不可用'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cached users remain visible through retry loading and failure', (
    tester,
  ) async {
    final native = _ListingNative(
      _peopleSearch({
        'people': [_person],
      }),
    );
    await _mount(tester, native);
    native.publish(
      _peopleSearch({
        'people': [_person],
        'peopleLoading': true,
        'loading': true,
      }),
    );
    await _frames(tester);
    expect(find.text('Cached member'), findsOneWidget);
    expect(find.text('正在搜索用户…'), findsOneWidget);
    native.publish(
      _peopleSearch({
        'people': [_person],
        'peopleErrorCode': 'network',
      }),
    );
    await _frames(tester);
    expect(find.text('Cached member'), findsOneWidget);
    expect(find.text('暂时无法读取用户结果。'), findsOneWidget);
    expect(find.text('用户刷新失败 · 保留当前结果'), findsOneWidget);
    expect(find.text('没有匹配的用户'), findsNothing);
    _expectNoAccessAction();
    native.publish(_peopleSearch());
    await _frames(tester);
    expect(find.text('Cached member'), findsNothing);
    expect(find.text('没有匹配的用户'), findsOneWidget);
    expect(find.text('0 位用户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final issue in [
    ('timedOut', '用户搜索超时，请稍后重试。'),
    ('rateLimited', '用户搜索请求较频繁，请稍后重试。'),
  ]) {
    testWidgets('people ${issue.$1} keeps the native contextual explanation', (
      tester,
    ) async {
      final native = _ListingNative(
        _peopleSearch({'peopleErrorCode': issue.$1, 'peopleError': issue.$2}),
      );
      await _mount(tester, native);
      expect(find.text(issue.$2), findsOneWidget);
      expect(find.text('没有匹配的用户'), findsNothing);
      _expectNoAccessAction();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('people loading and empty success ignore unrelated post errors', (
    tester,
  ) async {
    final native = _ListingNative(
      _peopleSearch({
        'peopleLoading': true,
        'loading': true,
        'error': '帖子刷新失败',
        'errorCode': 'network',
      }),
    );
    await _mount(tester, native);
    expect(find.text('正在搜索用户…'), findsOneWidget);
    expect(find.text('用户结果暂不可用'), findsNothing);
    expect(find.text('没有匹配的用户'), findsNothing);
    native.publish(_peopleSearch({'error': '帖子刷新失败', 'errorCode': 'network'}));
    await _frames(tester);
    expect(find.text('没有匹配的用户'), findsOneWidget);
    expect(find.text('0 位用户'), findsOneWidget);
    expect(find.text('帖子刷新失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all search shows independent user loading and failure with post results',
    (tester) async {
      final native = _ListingNative(
        _peopleSearch({
          'appliedSearchKind': 'all',
          'peopleLoading': true,
          'loading': true,
          'posts': _posts(),
        }),
      );
      await _mount(tester, native, size: const Size(780, 540));
      expect(find.text('正在搜索用户…'), findsOneWidget);
      expect(find.text('Cached post 0'), findsOneWidget);
      native.publish(
        _peopleSearch({
          'appliedSearchKind': 'all',
          'peopleErrorCode': 'network',
          'posts': _posts(),
        }),
      );
      await _frames(tester);
      expect(find.text('暂时无法读取用户结果。'), findsOneWidget);
      expect(find.text('Cached post 0'), findsOneWidget);
      expect(find.text('搜索结果 · 1 篇'), findsOneWidget);
      _expectNoAccessAction();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'known post failure stays visible while the independent people request loads',
    (tester) async {
      final native = _ListingNative(
        _peopleSearch({
          'appliedSearchKind': 'all',
          'peopleLoading': true,
          'loading': true,
          'errorCode': 'network',
          'error': '暂时无法读取帖子搜索结果，请重试。',
        }),
      );
      await _mount(tester, native, size: const Size(780, 540));
      expect(find.text('正在搜索用户…'), findsOneWidget);
      expect(find.text('暂时无法搜索论坛'), findsOneWidget);
      expect(find.text('站内搜索暂不可用'), findsOneWidget);
      expect(find.text('没有匹配的帖子'), findsNothing);
      _expectNoAccessAction();
      native.publish(
        _peopleSearch({
          'appliedSearchKind': 'all',
          'people': [_person],
          'errorCode': 'network',
          'error': '暂时无法读取帖子搜索结果，请重试。',
        }),
      );
      await _frames(tester);
      expect(find.text('Cached member'), findsOneWidget);
      expect(find.text('暂时无法搜索论坛'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in <(JsonMap, String)>[
    (
      {'posts': _posts(), 'error': '读取失败', 'hasForumPage': true},
      '刷新失败 · 保留当前列表',
    ),
    (
      {'posts': _posts(), 'error': '读取失败', 'hasForumPage': false},
      '论坛列表不可用 · 备用订阅',
    ),
    ({'posts': _posts(), 'hasForumPage': false}, '订阅 · 1 篇'),
    ({'board': 'award', 'hasForumPage': false, 'error': '读取失败'}, '精品区暂不可用'),
    (
      {
        'query': 'cached',
        'appliedSearchKind': 'posts',
        'posts': _posts(),
        'error': '读取失败',
      },
      '搜索失败 · 显示可用结果',
    ),
  ]) {
    testWidgets('listing status distinguishes ${scenario.$2}', (tester) async {
      final native = _ListingNative(_workspace(scenario.$1));
      await _mount(tester, native);
      expect(
        find.descendant(of: _status, matching: find.text(scenario.$2)),
        findsOneWidget,
      );
      if (jsonItems(scenario.$1['posts']).isNotEmpty) {
        expect(find.text('Cached post 0'), findsOneWidget);
        expect(find.byKey(const ValueKey('forum-posts-empty')), findsNothing);
        if (scenario.$1['error'] != null) {
          final tooltip = tester.widget<Tooltip>(
            find.descendant(of: _status, matching: find.byType(Tooltip)),
          );
          expect(tooltip.message, scenario.$1['error']);
        }
      }
      _expectNoAccessAction();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'post empty state distinguishes ordinary, search, loading and failure without guessing login',
    (tester) async {
      final native = _ListingNative(_workspace());
      await _mount(tester, native);
      expect(find.text('暂无帖子'), findsOneWidget);
      _expectNoAccessAction();
      native.publish(
        _workspace({'query': 'term', 'appliedSearchKind': 'posts'}),
      );
      await _frames(tester);
      expect(find.text('没有匹配的帖子'), findsOneWidget);
      expect(find.text('暂无帖子'), findsNothing);
      native.publish(
        _workspace({
          'query': 'term',
          'appliedSearchKind': 'posts',
          'loading': true,
        }),
      );
      await _frames(tester);
      expect(find.text('没有匹配的帖子'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsWidgets);
      native.publish(
        _workspace({
          'query': 'term',
          'appliedSearchKind': 'posts',
          'error': '读取失败',
          'errorCode': 'network',
        }),
      );
      await _frames(tester);
      expect(find.text('暂时无法搜索论坛'), findsOneWidget);
      _expectNoAccessAction();
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in ['signInRequired', 'verification']) {
    testWidgets('explicit post error $code offers the matching recovery only', (
      tester,
    ) async {
      final native = _ListingNative(
        _workspace({'error': '读取失败', 'errorCode': code}),
      );
      await _mount(tester, native);
      expect(find.text('暂时无法读取帖子列表'), findsOneWidget);
      final label = code == 'signInRequired' ? '登录 NodeSeek' : '打开验证窗口';
      await tester.tap(_button(label));
      await _frames(tester);
      expect(
        native.named(
          code == 'signInRequired' ? 'session.signIn' : 'session.verify',
        ),
        hasLength(1),
      );
      expect(native.named('listing.refresh'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'clear and a new post search discard prior people error and result state',
    (tester) async {
      final native = _ListingNative(
        _peopleSearch({
          'peopleErrorCode': 'network',
          'people': [_person],
        }),
      );
      native.clearResponse = _workspace({'posts': _posts()});
      await _mount(tester, native);
      await tester.tap(_button('member'));
      await _frames(tester);
      expect(native.named('listing.clearSearch'), hasLength(1));
      expect(native.named('listing.refresh'), isEmpty);
      expect(find.text('Cached post 0'), findsOneWidget);
      expect(find.text('Cached member'), findsNothing);
      expect(find.text('暂时无法读取用户结果。'), findsNothing);
      native.searchResponse = _workspace({'posts': _posts()});
      await tester.tap(_button('搜索帖子'));
      await _frames(tester, 14);
      await tester.tap(find.descendant(of: _search, matching: find.text('帖子')));
      await tester.enterText(
        find.descendant(of: _search, matching: find.byType(EditableText)),
        'new search',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester, 14);
      expect(native.named('listing.search').single.$2['kind'], 'posts');
      expect(native.named('listing.search').single.$2['query'], 'new search');
      expect(find.text('搜索结果'), findsOneWidget);
      expect(find.text('Cached member'), findsNothing);
      expect(find.text('没有匹配的用户'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final query in ['', 'term']) {
    testWidgets(
      'pagination failure and query=$query block automatic reads but permit explicit retry',
      (tester) async {
        final native = _ListingNative(
          _workspace({
            'query': query,
            'appliedSearchKind': 'posts',
            'posts': _posts(30),
            'canLoadOlder': true,
            'failedToLoadOlder': true,
            'error': '读取更早帖子超时。',
            'errorCode': 'timedOut',
          }),
        );
        await _mount(tester, native);
        final scroll = tester
            .widget<ListView>(
              find.descendant(
                of: find.byKey(const ValueKey('forum-list-pane')),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ListView && widget.controller != null,
                ),
              ),
            )
            .controller!;
        for (var index = 0; index < 3; index++) {
          scroll.jumpTo(scroll.position.maxScrollExtent - 20);
          await _frames(tester);
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await _frames(tester);
        }
        expect(native.named('listing.older'), isEmpty);
        expect(_button('重试加载更早帖子'), findsOneWidget);
        native.olderResponse = _workspace({
          'query': query,
          'appliedSearchKind': 'posts',
          'posts': _posts(60),
          'canLoadOlder': true,
        });
        await tester.tap(_button('重试加载更早帖子'));
        await _frames(tester);
        expect(native.named('listing.older'), hasLength(1));
        expect(_button('重试加载更早帖子'), findsNothing);
        if (query.isNotEmpty) {
          scroll.jumpTo(scroll.position.maxScrollExtent - 20);
          await _frames(tester);
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await _frames(tester);
          expect(native.named('listing.older'), hasLength(1));
          expect(_button('搜索更早帖子'), findsOneWidget);
        } else {
          // A successful retry adds a page. Reaching that new page's bottom
          // resumes automatic pagination; its terminal response stops there.
          native.olderResponse = _workspace({'posts': _posts(90)});
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await _frames(tester);
          expect(native.named('listing.older'), hasLength(2));
          expect(native.workspace['canLoadOlder'], isFalse);
          expect(_button('加载更早帖子'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final refreshFailed in [false, true]) {
    testWidgets(
      'footer retries ${refreshFailed ? 'refresh ahead of older' : 'only older'} when both error domains are available',
      (tester) async {
        final native = _ListingNative(
          _workspace({
            'posts': _posts(),
            'canLoadOlder': true,
            'failedToLoadOlder': true,
            'failedToRefresh': refreshFailed,
            'error': refreshFailed ? '刷新列表超时。' : '读取更早帖子超时。',
            'errorCode': 'timedOut',
          }),
        );
        await _mount(tester, native);
        final status = refreshFailed ? '刷新失败 · 保留当前列表' : '加载更早帖子失败 · 保留当前列表';
        expect(
          find.descendant(of: _status, matching: find.text(status)),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: _status,
            matching: find.widgetWithText(CupertinoButton, '重试'),
          ),
        );
        await _frames(tester);
        expect(
          native.named(refreshFailed ? 'listing.refresh' : 'listing.older'),
          hasLength(1),
        );
        expect(
          native.named(refreshFailed ? 'listing.older' : 'listing.refresh'),
          isEmpty,
        );
        expect(find.text('Cached post 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'captured recovery callbacks are inert under search or office cover',
    (tester) async {
      final native = _ListingNative(
        _peopleSearch({'peopleErrorCode': 'verification'}),
      );
      await _mount(tester, native);
      final retry = tester.widget<DeskButton>(_button('重试')).onTap!;
      final verify = tester.widget<DeskButton>(_button('打开验证窗口')).onTap!;
      await tester.tap(_button('搜索帖子'));
      await _frames(tester, 14);
      retry();
      verify();
      await _frames(tester);
      expect(native.named('listing.refresh'), isEmpty);
      expect(native.named('session.verify'), isEmpty);
      await tester.tap(_button('取消'));
      await _frames(tester, 14);
      native.snapshotsController.add({
        'domain': 'extensions',
        'accessRevision': 0,
        'data': {
          'items': [
            {'id': 'office', 'active': true},
          ],
          'settings': {
            'office': {'presented': true},
          },
        },
      });
      await _frames(tester);
      retry();
      verify();
      await _frames(tester);
      expect(native.named('listing.refresh'), isEmpty);
      expect(native.named('session.verify'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
