import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

JsonMap _catalog({
  String id = 'office',
  String title = 'Fixture extension',
  int access = 1,
}) => {
  'items': [
    {
      'id': id,
      'title': title,
      'description': 'In-memory extension snapshot',
      'installed': true,
      'enabled': true,
      'active': true,
    },
  ],
  'settings': {
    'office': {'key': '9', 'title': 'Fixture sheet', 'button': 'Restore'},
    'keywords': {
      'words': '',
      'note': '',
      'systemNotifications': true,
      'notificationAccess': access,
    },
  },
  'hits': <JsonMap>[],
  'unread': 0,
};

class _ExtensionsNative extends NativeClient {
  _ExtensionsNative()
    : super(
        methods: const MethodChannel('seekdesk.test.extensions-shared-reads'),
      );

  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final reads = <({int revision, Completer<JsonMap> result})>[];
  final calls = <String>[];
  final unexpected = <String>[];
  Completer<JsonMap>? write;

  JsonMap session(int revision) => {
    'account': 'signedIn',
    'owner': revision + 1,
    'accessRevision': revision,
    'canCompose': true,
    'profile': {'id': revision + 1, 'name': 'Fixture owner', 'avatar': ''},
  };

  void changeAccount(int revision) => eventsController.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': session(revision),
  });

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'bootstrap':
        return {
          'session': session(accessRevision),
          'settings': <String, dynamic>{},
          'extensions': {'items': <JsonMap>[]},
          'workspace': {
            'posts': <JsonMap>[],
            'tabs': [
              {
                'id': '991',
                'url': 'https://www.nodeseek.com/post-991-1',
                'title': 'Retained tab',
              },
            ],
            'selectedTab': '991',
            'showReader': false,
            'board': '',
            'boards': [
              {'id': '', 'title': '最新帖子'},
            ],
          },
        };
      case 'extensions.list':
        final request = (
          revision: accessRevision,
          result: Completer<JsonMap>(),
        );
        reads.add(request);
        return request.result.future;
      case 'settings.get':
        return {};
      case 'extensions.configure':
        if (write != null) return write!.future;
    }
    unexpected.add(method);
    throw StateError('Unexpected in-memory extension operation: $method');
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ExtensionsNative native;
  late AppState state;
  var disposed = false;

  void disposeState() {
    if (disposed) return;
    disposed = true;
    state.dispose();
  }

  setUp(() async {
    native = _ExtensionsNative();
    state = AppState(client: native);
    disposed = false;
    await state.connect();
  });

  tearDown(() async {
    disposeState();
    for (final request in native.reads) {
      if (!request.result.isCompleted) {
        request.result.complete({'items': <JsonMap>[]});
      }
    }
    await native.eventsController.close();
    expect(native.unexpected, isEmpty);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1380, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      disposeState();
      await tester.pump(const Duration(seconds: 6));
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
  }

  Future<void> navigate(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-footer')),
        matching: find.text(label),
      ),
    );
    await _frames(tester);
  }

  Future<void> remount(WidgetTester tester) async {
    final original = tester.state(find.byType(ExtensionsScreen));
    await navigate(tester, '设置');
    expect(find.byType(ExtensionsScreen), findsNothing);
    await navigate(tester, '扩展中心');
    expect(tester.state(find.byType(ExtensionsScreen)), isNot(same(original)));
  }

  for (final cached in [false, true]) {
    testWidgets(
      'extension destination rejoins its pending ${cached ? 'cached' : 'cold'} catalog',
      (tester) async {
        if (cached) {
          state.domains['extensions'] = _catalog(title: 'Cached extension');
        }
        await mount(tester);
        final tabs = state.workspace.tabs.map((topic) => topic.url).toList();
        await navigate(tester, '扩展中心');
        await remount(tester);
        expect(native.reads, hasLength(1));
        expect(find.text('暂时无法读取扩展'), findsNothing);
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        expect(tester.widget<DeskIcon>(_icon('刷新扩展')).onTap, isNull);
        expect(
          find.text(cached ? 'Cached extension' : '正在读取扩展'),
          findsOneWidget,
        );
        native.reads.single.result.complete(_catalog());
        await _frames(tester);
        expect(find.text('Fixture extension'), findsOneWidget);
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        expect(tester.widget<DeskIcon>(_icon('刷新扩展')).onTap, isNotNull);
        expect(native.reads, hasLength(1));
        expect(state.workspace.tabs.map((topic) => topic.url), tabs);
        expect(state.workspace.selectedTab, '991');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'shared ${cached ? 'cached' : 'cold'} catalog failure remains retryable',
      (tester) async {
        if (cached) {
          state.domains['extensions'] = _catalog(title: 'Cached extension');
        }
        await mount(tester);
        await navigate(tester, '扩展中心');
        await remount(tester);
        native.reads.single.result.completeError(
          const NativeFailure('fixture', 'Local extension read failed'),
        );
        await _frames(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(state.message, isNull);
        expect(find.text('未能读取扩展信息，请重试。'), findsOneWidget);
        expect(
          find.text(cached ? 'Cached extension' : '暂时无法读取扩展'),
          findsOneWidget,
        );
        await tester.tap(cached ? _icon('刷新扩展') : _button('重新加载'));
        await _frames(tester);
        expect(native.reads, hasLength(2));
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        native.reads.last.result.complete(
          _catalog(title: 'Recovered extension'),
        );
        await _frames(tester);
        expect(find.text('Recovered extension'), findsOneWidget);
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        expect(state.pending, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'permission refresh joins the catalog read without a false failure',
    (tester) async {
      state.domains['extensions'] = _catalog(id: 'keywords', title: '关键词监控');
      await mount(tester);
      await navigate(tester, '扩展中心');
      await tester.tap(find.byKey(const ValueKey('extension-card-keywords')));
      await _frames(tester);
      expect(find.text('系统未允许通知'), findsOneWidget);
      await tester.ensureVisible(_icon('刷新通知权限'));
      await tester.tap(_icon('刷新通知权限'));
      await _frames(tester);
      expect(native.reads, hasLength(1));
      expect(find.text('暂时无法刷新系统通知权限，请重试。'), findsNothing);
      expect(tester.widget<DeskIcon>(_icon('刷新通知权限')).onTap, isNull);
      native.reads.single.result.complete(
        _catalog(id: 'keywords', title: '关键词监控', access: 2),
      );
      await _frames(tester);
      expect(find.text('系统已允许通知'), findsOneWidget);
      expect(find.text('暂时无法刷新系统通知权限，请重试。'), findsNothing);
      expect(tester.widget<DeskIcon>(_icon('刷新通知权限')).onTap, isNotNull);
      await tester.tap(_icon('刷新通知权限'));
      await _frames(tester);
      expect(native.reads, hasLength(2));
      native.reads.last.result.completeError(
        const NativeFailure('fixture', 'Permission snapshot failed'),
      );
      await _frames(tester);
      expect(find.text('系统已允许通知'), findsOneWidget);
      expect(find.text('暂时无法刷新系统通知权限，请重试。'), findsOneWidget);
      await tester.tap(_icon('刷新通知权限'));
      await _frames(tester);
      expect(native.reads, hasLength(3));
      native.reads.last.result.complete(
        _catalog(id: 'keywords', title: '关键词监控', access: 1),
      );
      await _frames(tester);
      expect(find.text('系统未允许通知'), findsOneWidget);
      expect(find.text('暂时无法刷新系统通知权限，请重试。'), findsNothing);
      expect(
        native.calls.every(
          (method) => ['bootstrap', 'extensions.list'].contains(method),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final failOld in [false, true]) {
    testWidgets(
      'extension reads discard ${failOld ? 'failed' : 'successful'} retired and intermediate revisions',
      (tester) async {
        await mount(tester);
        await navigate(tester, '扩展中心');
        native.changeAccount(1);
        await _frames(tester);
        native.changeAccount(2);
        await _frames(tester);
        final latest = state.act('extensions.list', {}, 'extensions');
        expect(native.reads.map((request) => request.revision), [0]);
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        if (failOld) {
          native.reads.first.result.completeError(
            const NativeFailure('fixture', 'Retired failure'),
          );
        } else {
          native.reads.first.result.complete({
            ..._catalog(title: 'Retired extension'),
            'accessRevision': 2,
          });
        }
        await _frames(tester);
        expect(native.reads.map((request) => request.revision), [0, 2]);
        expect(find.text('Retired extension'), findsNothing);
        expect(find.text('正在读取扩展'), findsOneWidget);
        expect(state.domain('extensions')['items'], isEmpty);
        expect(state.message, isNull);
        native.reads.last.result.complete(_catalog(title: 'Current extension'));
        expect((await latest)?['items'], isNotEmpty);
        await _frames(tester);
        expect(find.text('Current extension'), findsOneWidget);
        expect(find.text('未能读取扩展信息，请重试。'), findsNothing);
        expect(state.pending, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('extension read ownership is registered before synchronous listener reentry', () async {
    Future<JsonMap?>? joined;
    var entered = false;
    void changed() {
      if (entered || state.pending.isEmpty) return;
      entered = true;
      joined = state.act('extensions.list', {}, 'extensions');
    }

    state.addListener(changed);
    final first = state.act('extensions.list', {}, 'extensions');
    expect(entered, isTrue);
    expect(native.reads, hasLength(1));
    native.reads.single.result.complete(_catalog());
    final result = await first;
    expect(await joined, same(result));
    expect(state.pending, isEmpty);
    state.removeListener(changed);
  });

  test(
    'disposed extension reads neither publish nor start queued work',
    () async {
      final first = state.act('extensions.list', {}, 'extensions');
      final duplicate = state.act('extensions.list');
      native.changeAccount(1);
      final queued = state.act('extensions.list', {}, 'extensions');
      disposeState();
      native.reads.single.result.complete(_catalog());
      expect(await first, isNull);
      expect(await duplicate, isNull);
      expect(await queued, isNull);
      expect(await state.act('extensions.list'), isNull);
      expect(native.reads, hasLength(1));
      expect(state.domain('extensions')['items'], isEmpty);
      expect(state.pending, isEmpty);
      expect(state.message, isNull);
    },
  );

  test('revision changes in a pending notification retire extension transport ownership', () async {
    Future<JsonMap?>? current;
    var transferred = false;
    void changed() {
      if (transferred || state.pending.isEmpty) return;
      transferred = true;
      native.changeAccount(1);
      current = state.act('extensions.list', {}, 'extensions');
    }

    state.addListener(changed);
    expect(await state.act('extensions.list', {}, 'extensions'), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(native.reads.map((request) => request.revision), [1]);
    native.reads.single.result.complete(_catalog());
    expect((await current)?['items'], isNotEmpty);
    expect(state.pending, isEmpty);
    state.removeListener(changed);
  });

  test('extension writes retain their duplicate-operation behavior', () async {
    native.write = Completer<JsonMap>();
    final first = state.act('extensions.configure', {
      'id': 'office',
      'settings': {'key': '8'},
    });
    final duplicate = state.act('extensions.configure', {
      'id': 'office',
      'settings': {'key': '7'},
    });
    expect(await duplicate, isNull);
    expect(
      native.calls.where((method) => method == 'extensions.configure'),
      hasLength(1),
    );
    native.write!.complete(_catalog());
    expect((await first)?['items'], isNotEmpty);
    expect(state.pending, isEmpty);
  });
}
