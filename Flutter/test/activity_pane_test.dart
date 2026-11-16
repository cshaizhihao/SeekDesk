import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/activity_screen.dart';
import 'package:seekdesk_flutter/state/activity_memory.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _routes = ['discussions', 'comments', 'fans', 'follow'];

class _ActivityNative extends NativeClient {
  _ActivityNative()
    : super(methods: const MethodChannel('seekdesk.test.activity-pane'));
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final responses = <String, List<Object>>{};
  final pending = <Completer<JsonMap>>[];

  JsonMap response(String route, int member, int page, {int? revision}) => {
    'route': route,
    'memberId': member,
    'page': page,
    'accessRevision': revision ?? accessRevision,
    'hasNext': page < 3,
    'items': [
      for (var index = 0; index < 40; index++)
        if (route == 'fans' || route == 'follow')
          {'id': 200 + index, 'name': '$route member $index', 'avatar': ''}
        else
          {
            'id': '$member-$page-$index',
            'postId': 700 + index,
            'floor': 31,
            'title': '$route member $member page $page item $index',
            'text': 'Local activity body with enough content for scrolling.',
            'url': 'https://www.nodeseek.com/post-${700 + index}-2#31',
          },
    ],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    final route = args['route'], member = args['memberId'];
    final members = route == 'fans' || route == 'follow';
    if (!_routes.contains(route) ||
        member is! int ||
        member <= 0 ||
        method != (members ? 'space.members' : 'space.activity') ||
        args.length != (members ? 2 : 3) ||
        !members && args['page'] is! int) {
      unexpected.add('$method $args');
      throw StateError('Activity fixture rejected $method $args');
    }
    final page = members ? 1 : args['page'] as int;
    final queue = responses['$route:$member:$page'];
    if (queue != null && queue.isNotEmpty) {
      final next = queue.removeAt(0);
      if (next is Completer<JsonMap>) {
        pending.add(next);
        return next.future;
      }
      if (next is NativeFailure) throw next;
      return next as JsonMap;
    }
    return response(route as String, member, page);
  }
}

class _ActivityState extends AppState {
  _ActivityState(_ActivityNative native) : super(client: native) {
    domains['session'] = {'account': 'signedIn', 'owner': 101};
  }
  void changeIdentity({
    int owner = 303,
    bool signedIn = true,
    bool bumpRevision = true,
  }) {
    if (bumpRevision) client.accessRevision++;
    domains['session'] = {
      'account': signedIn ? 'signedIn' : 'signedOut',
      'owner': owner,
    };
    notifyListeners();
  }
}

class _Tabs extends StatefulWidget {
  const _Tabs({
    required this.state,
    required this.memories,
    this.initial = 0,
    super.key,
  });
  final AppState state;
  final Map<String, ActivityPaneMemory> memories;
  final int initial;
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  late int selected = widget.initial;
  int member = 101;
  bool visible = true;
  final openedMembers = <int>[];
  final openedTopics = <TopicData>[];

  void select(int value) => setState(() => selected = value);
  void show(bool value) => setState(() => visible = value);
  void changeMember(int value) => setState(() => member = value);

  @override
  Widget build(BuildContext context) => visible
      ? IndexedStack(
          index: selected < 0 ? null : selected,
          children: [
            for (var index = 0; index < _routes.length; index++)
              ActivityPane(
                key: ValueKey(_routes[index]),
                state: widget.state,
                memberId: member,
                route: _routes[index],
                active: selected == index,
                memory: widget.memories[_routes[index]],
                onOpenMember: openedMembers.add,
                onOpenTopic: openedTopics.add,
              ),
          ],
        )
      : const SizedBox.shrink();
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<
  ({
    GlobalKey<_TabsState> host,
    _ActivityState state,
    Map<String, ActivityPaneMemory> memories,
  })
>
_mount(
  WidgetTester tester,
  _ActivityNative native, {
  int initial = 0,
  double width = 760,
  double height = 600,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final state = _ActivityState(native);
  final memories = {for (final route in _routes) route: ActivityPaneMemory()};
  final host = GlobalKey<_TabsState>();
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final pending in native.pending) {
      if (!pending.isCompleted) {
        pending.completeError(
          const NativeFailure('cancelled', 'Local disposal.'),
        );
      }
    }
    await tester.pump();
    state.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      builder: (context, child) => GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: CupertinoPageScaffold(
        child: _Tabs(
          key: host,
          state: state,
          memories: memories,
          initial: initial,
        ),
      ),
    ),
  );
  await _frames(tester);
  return (host: host, state: state, memories: memories);
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder _list(String route) => find.byKey(ValueKey('activity-$route-list'));
ScrollController _scroll(WidgetTester tester, String route) =>
    tester.widget<ListView>(_list(route)).controller!;

void _macTest(String description, WidgetTesterCallback test) => testWidgets(
  description,
  test,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  _macTest(
    'unseen tabs do not read and returning to a loaded tab does not refresh',
    (tester) async {
      final native = _ActivityNative();
      final f = await _mount(tester, native, initial: -1);
      expect(native.calls, isEmpty);
      f.host.currentState!.select(1);
      await _frames(tester);
      expect(native.calls, hasLength(1));
      expect(native.calls.single.$1, 'space.activity');
      expect(native.calls.single.$2, {
        'memberId': 101,
        'route': 'comments',
        'page': 1,
      });
      f.host.currentState!.select(2);
      await _frames(tester);
      expect(native.calls, hasLength(2));
      expect(native.calls.last.$1, 'space.members');
      expect(native.calls.last.$2, {'memberId': 101, 'route': 'fans'});
      f.host.currentState!.select(1);
      await _frames(tester);
      expect(native.calls, hasLength(2));
      expect(native.calls.any((call) => call.$2['route'] == 'follow'), isFalse);
    },
  );

  _macTest('each tab retains its committed page and scroll across switches', (
    tester,
  ) async {
    final native = _ActivityNative();
    final f = await _mount(tester, native);
    _scroll(tester, 'discussions').jumpTo(340);
    await tester.pump();
    f.host.currentState!.select(1);
    await _frames(tester);
    await tester.tap(_button('下一页'));
    await _frames(tester);
    _scroll(tester, 'comments').jumpTo(520);
    await tester.pump();
    final reads = native.calls.length;
    f.host.currentState!.select(0);
    await _frames(tester);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(_scroll(tester, 'discussions').offset, closeTo(340, 1));
    f.host.currentState!.select(1);
    await _frames(tester);
    expect(find.text('第 2 页'), findsOneWidget);
    expect(_scroll(tester, 'comments').offset, closeTo(520, 1));
    expect(native.calls, hasLength(reads));
  });

  _macTest(
    'external memory restores page and position after the profile unmounts',
    (tester) async {
      final native = _ActivityNative();
      final f = await _mount(tester, native, initial: 1);
      await tester.tap(_button('下一页'));
      await _frames(tester);
      _scroll(tester, 'comments').jumpTo(620);
      await tester.pump();
      final reads = native.calls.length;
      f.host.currentState!.show(false);
      await _frames(tester);
      expect(f.memories['comments']!.page, 2);
      expect(f.memories['comments']!.offsetFor(2), closeTo(620, 1));
      f.host.currentState!.show(true);
      await _frames(tester);
      expect(find.text('第 2 页'), findsOneWidget);
      expect(_scroll(tester, 'comments').offset, closeTo(620, 1));
      expect(native.calls, hasLength(reads));
    },
  );

  _macTest(
    'failed paging keeps the prior page and position then retries the intended page',
    (tester) async {
      final native = _ActivityNative();
      native.responses['comments:101:2'] = [
        const NativeFailure('offline', 'Local next-page failure.'),
      ];
      final f = await _mount(tester, native, initial: 1);
      final controller = _scroll(tester, 'comments');
      controller.jumpTo(420);
      await tester.pump();
      await tester.tap(_button('下一页'));
      await _frames(tester);
      expect(find.text('第 1 页'), findsOneWidget);
      expect(f.memories['comments']!.page, 1);
      expect(f.memories['comments']!.items.first['title'], contains('page 1'));
      expect(_scroll(tester, 'comments'), same(controller));
      expect(controller.offset, closeTo(420, 1));
      expect(find.text('Local next-page failure.'), findsOneWidget);
      await tester.tap(_button('重新读取'));
      await _frames(tester);
      expect(native.calls.last.$2['page'], 2);
      expect(find.text('第 2 页'), findsOneWidget);
      expect(controller.offset, closeTo(0, 1));
      await tester.tap(_button('上一页'));
      await _frames(tester);
      expect(find.text('第 1 页'), findsOneWidget);
      expect(controller.offset, closeTo(420, 1));
    },
  );

  _macTest(
    'explicit refresh reloads only the current tab and retains its scroll',
    (tester) async {
      final native = _ActivityNative();
      await _mount(tester, native, initial: 1);
      _scroll(tester, 'comments').jumpTo(300);
      await tester.pump();
      await tester.tap(_icon('刷新评论'));
      await _frames(tester);
      expect(native.calls, hasLength(2));
      expect(
        native.calls.every((call) => call.$2['route'] == 'comments'),
        isTrue,
      );
      expect(_scroll(tester, 'comments').offset, closeTo(300, 1));
    },
  );

  _macTest(
    'owner change without revision bump clears private results and blocks reads',
    (tester) async {
      final native = _ActivityNative();
      final pending = Completer<JsonMap>();
      native.responses['fans:101:1'] = [pending];
      final f = await _mount(tester, native, initial: 2);
      final old = native.response('fans', 101, 1, revision: 0);
      f.state.changeIdentity(owner: 303, bumpRevision: false);
      await _frames(tester);
      pending.complete(old);
      await _frames(tester);
      expect(find.text('只能读取当前账号的粉丝和关注列表。'), findsOneWidget);
      expect(find.text('fans member 0'), findsNothing);
      expect(f.memories['fans']!.loaded, isFalse);
      expect(native.calls, hasLength(1));
      f.host.currentState!.select(3);
      await _frames(tester);
      expect(native.calls, hasLength(1));
    },
  );

  _macTest(
    'member changes reject late public results and only reload the active tab',
    (tester) async {
      final native = _ActivityNative();
      final old = Completer<JsonMap>();
      native.responses['comments:101:1'] = [old];
      final f = await _mount(tester, native, initial: 1);
      f.host.currentState!.changeMember(202);
      await _frames(tester);
      old.complete(native.response('comments', 101, 1));
      await _frames(tester);
      expect(find.text('comments member 202 page 1 item 0'), findsOneWidget);
      expect(find.text('comments member 101 page 1 item 0'), findsNothing);
      expect(native.calls, hasLength(2));
      expect(
        native.calls.every((call) => call.$2['route'] == 'comments'),
        isTrue,
      );
      expect(f.memories['comments']!.page, 1);
    },
  );

  _macTest(
    'a hidden pending tab can finish but is not read again when selected',
    (tester) async {
      final native = _ActivityNative();
      final pending = Completer<JsonMap>();
      native.responses['comments:101:1'] = [pending];
      final f = await _mount(tester, native, initial: 1);
      f.host.currentState!.select(0);
      await _frames(tester);
      pending.complete(native.response('comments', 101, 1));
      await _frames(tester);
      expect(f.memories['comments']!.loaded, isTrue);
      final reads = native.calls.length;
      f.host.currentState!.select(1);
      await _frames(tester);
      expect(find.text('comments member 101 page 1 item 0'), findsOneWidget);
      expect(native.calls, hasLength(reads));
    },
  );

  _macTest(
    'embedded callbacks preserve member ID and exact comment destination',
    (tester) async {
      final native = _ActivityNative();
      final f = await _mount(tester, native, initial: 1);
      await tester.tap(find.text('comments member 101 page 1 item 0'));
      expect(f.host.currentState!.openedTopics.single.id, '700');
      expect(
        f.host.currentState!.openedTopics.single.url,
        'https://www.nodeseek.com/post-700-2#31',
      );
      expect(find.byType(_Tabs), findsOneWidget);
      f.host.currentState!.select(2);
      await _frames(tester);
      await tester.tap(find.text('fans member 0'));
      expect(f.host.currentState!.openedMembers, [200]);
      expect(native.calls, hasLength(2));
    },
  );

  _macTest(
    'mismatched response identity exposes retry without accepting its items',
    (tester) async {
      final native = _ActivityNative();
      native.responses['comments:101:1'] = [
        native.response('comments', 202, 1),
      ];
      final f = await _mount(tester, native, initial: 1);
      expect(find.text('读取结果已过期，请重新读取。'), findsOneWidget);
      expect(f.memories['comments']!.loaded, isFalse);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.tap(_button('重新读取'));
      await _frames(tester);
      expect(f.memories['comments']!.loaded, isTrue);
      expect(find.text('comments member 101 page 1 item 0'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    _macTest(
      'narrow short ${brightness.name} error is scrollable at 2x text size',
      (tester) async {
        final native = _ActivityNative();
        native.responses['comments:101:1'] = [
          NativeFailure(
            'offline',
            List.filled(30, 'Long local failure.').join(' '),
          ),
        ];
        await _mount(
          tester,
          native,
          initial: 1,
          width: 280,
          height: 280,
          scale: 2,
          brightness: brightness,
        );
        expect(
          find.byKey(const ValueKey('activity-comments-recovery')),
          findsOneWidget,
        );
        final retry = _button('重新读取');
        await tester.ensureVisible(retry);
        await tester.pump();
        expect(retry.hitTestable(), findsOneWidget);
        await tester.tap(retry);
        await _frames(tester);
        expect(find.text('comments member 101 page 1 item 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
