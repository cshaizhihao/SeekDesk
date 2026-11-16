import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

String _url(String id, [int page = 1]) =>
    'https://www.nodeseek.com/post-$id-$page';

JsonMap _topic(String id, [int page = 1]) => {
  'id': id,
  'url': _url(id, page),
  'title': 'Post $id',
};

JsonMap _workspace({
  String selected = '1',
  List<String> ids = const ['1', '2', '3'],
  bool showReader = true,
  int page = 1,
}) => {
  'tabs': [for (final id in ids) _topic(id, page)],
  'selectedTab': selected,
  'showReader': showReader,
  'posts': <JsonMap>[],
  'boards': [
    {'id': 'home', 'title': '首页'},
  ],
};

JsonMap _reader(String url) => {
  'url': url,
  'scrollOffset': 0,
  'thread': {
    'title': 'Reader lifecycle fixture',
    'root': {
      'id': '0',
      'author': 'fixture',
      'dateLabel': 'Today',
      'blocks': [
        {'kind': 'text', 'text': 'A short fixture paragraph.'},
      ],
    },
    'replies': <JsonMap>[],
    'pages': <JsonMap>[],
  },
};

class _ReaderLifecycleClient extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (response != null) return response!(method, arguments);
    return method == 'reader.load' ? _reader(arguments['url'] as String) : {};
  }

  List<String> get loads => [
    for (final call in calls)
      if (call.$1 == 'reader.load') call.$2['url'] as String,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState fixture(_ReaderLifecycleClient client, {JsonMap? workspace}) {
    final state = AppState(client: client)..connecting = false;
    state.domains['workspace'] = workspace ?? _workspace();
    state.domains['session'] = {'account': 'signedOut'};
    state.domains['settings'] = {'appearance': 'light'};
    return state;
  }

  Future<void> mount(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(1380, 880));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(child: WorkspaceScreen(state: state)),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
    await tester.binding.setSurfaceSize(null);
  }

  test('selecting a removed tab does not navigate or call native', () async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client, workspace: _workspace(ids: ['1']));
    addTearDown(state.dispose);
    await state.selectTopic(TopicData(_topic('2')));
    expect(state.navigationRevision, 0);
    expect(client.calls, isEmpty);
  });

  test(
    'selection loads the returned live page instead of a captured URL',
    () async {
      final client = _ReaderLifecycleClient();
      final state = fixture(client, workspace: _workspace(page: 2));
      addTearDown(state.dispose);
      client.response = (method, arguments) async => method == 'reader.select'
          ? _workspace(selected: '2', page: 3)
          : _reader(arguments['url'] as String);
      await state.selectTopic(TopicData(_topic('2')));
      expect(client.calls.first.$1, 'reader.select');
      expect(client.calls.first.$2, {'id': '2'});
      expect(client.loads, [_url('2', 3)]);
      expect(state.readerFor(_url('2')), isEmpty);
      expect(state.readerFor(_url('2', 2)), isEmpty);
    },
  );

  for (final outcome in ['removed', 'different selection', 'overview']) {
    test('selection does not read when native returns $outcome', () async {
      final client = _ReaderLifecycleClient();
      final state = fixture(client);
      addTearDown(state.dispose);
      client.response = (method, arguments) async => switch (outcome) {
        'removed' => _workspace(ids: ['1', '3']),
        'different selection' => _workspace(selected: '3'),
        _ => _workspace(selected: '2', showReader: false),
      };
      await state.selectTopic(TopicData(_topic('2')));
      expect(client.calls.map((call) => call.$1), ['reader.select']);
      expect(client.loads, isEmpty);
    });
  }

  test('selection completion cannot read across an account revision', () async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client);
    addTearDown(state.dispose);
    final selected = Completer<JsonMap>();
    client.response = (method, arguments) => selected.future;
    final selecting = state.selectTopic(TopicData(_topic('2')));
    client.accessRevision++;
    selected.complete(_workspace(selected: '2'));
    await selecting;
    expect(client.loads, isEmpty);
  });

  testWidgets('overview startup retains tabs without reading their bodies', (
    tester,
  ) async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client, workspace: _workspace(showReader: false));
    // A previously consumed navigation command must not replay after remount.
    state.navigationRevision = 3;
    await mount(tester, state);
    state.showMessage('Unrelated workspace notification');
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.workspace.selectedTab, '1');
    expect(find.byKey(const ValueKey('forum-reader-pane')), findsNothing);
    expect(client.loads, isEmpty);
    expect(state.readers, isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('visible startup loads the selected reader once', (tester) async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client);
    await mount(tester, state);
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.loads, [_url('1')]);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('rapid selection before the next frame reads only the last tab', (
    tester,
  ) async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client);
    state.readers[_url('1')] = _reader(_url('1'));
    await mount(tester, state);
    state.domains['workspace'] = _workspace(selected: '2');
    state.showMessage('Select second');
    state.domains['workspace'] = _workspace(selected: '3');
    state.showMessage('Select third');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.loads, [_url('3')]);
    expect(state.readerFor(_url('2')), isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('closing a selection before the next frame cancels its read', (
    tester,
  ) async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client);
    state.readers[_url('1')] = _reader(_url('1'));
    await mount(tester, state);
    state.domains['workspace'] = _workspace(selected: '2');
    state.showMessage('Select second');
    state.domains['workspace'] = _workspace(
      selected: '',
      ids: ['1', '3'],
      showReader: false,
    );
    state.showMessage('Close second');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.loads, isEmpty);
    expect(state.readerFor(_url('2')), isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('an account change invalidates a queued read before the frame', (
    tester,
  ) async {
    final client = _ReaderLifecycleClient();
    final state = fixture(client);
    state.readers[_url('1')] = _reader(_url('1'));
    await mount(tester, state);
    state.domains['workspace'] = _workspace(selected: '2');
    state.showMessage('Select second');
    client.accessRevision++;
    state.domains['workspace'] = _workspace(selected: '2', showReader: false);
    state.showMessage('New account in overview');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.loads, isEmpty);
    expect(state.readerFor(_url('2')), isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });
}
