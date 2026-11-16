import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';

const _sectionKey = 'workspace.sidebarSection';
const _topicURL = 'https://www.nodeseek.com/post-810-4';

class _PendingSection {
  _PendingSection(this.value);
  final String value;
  final result = Completer<JsonMap>();
}

/// All reads and writes terminate in this fixture. Unexpected native methods
/// are recorded as well as rejected, since AppState catches service failures.
class _SectionNative extends NativeClient {
  _SectionNative({Object? saved = 'ranking'})
    : super(methods: const MethodChannel('seekdesk.test.sidebar-persistence')) {
    settings = {'workspace.sidebarWidth': 228.0, _sectionKey: ?saved};
  }

  late JsonMap settings;
  bool deferWrites = false;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final pending = <_PendingSection>[];
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  JsonMap get workspace => {
    'board': 'review',
    'showReader': false,
    'selectedTab': '810',
    'posts': <JsonMap>[],
    'tabs': [
      {'id': '810', 'url': _topicURL, 'title': 'Retained tab'},
      {
        'id': '812',
        'url': 'https://www.nodeseek.com/post-812-1',
        'title': 'Background tab',
      },
    ],
    'closedTabs': [
      {
        'id': '811',
        'url': 'https://www.nodeseek.com/post-811-1',
        'title': 'Closed tab',
      },
    ],
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'review', 'title': '测评'},
    ],
  };

  JsonMap get reader => {
    'url': _topicURL,
    'scrollOffset': 283.75,
    'thread': {
      'title': 'Retained tab',
      'root': {
        'id': '0',
        'author': 'Fixture',
        'blocks': [
          {'kind': 'text', 'text': 'Retained text fixture'},
        ],
      },
      'replies': <JsonMap>[],
      'pages': <JsonMap>[],
    },
  };

  List<String> get writes => calls
      .where((call) => call.$1 == 'settings.update')
      .map((call) => stringValue(call.$2['value']))
      .toList();

  void completeNext({JsonMap? response, bool fail = false}) {
    final write = pending.removeAt(0);
    if (fail) {
      write.result.completeError(
        const NativeFailure('unavailable', 'Fixture save failed'),
      );
    } else {
      if (response == null) settings = {...settings, _sectionKey: write.value};
      write.result.complete(response ?? {...settings});
    }
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'settings': {...settings},
          'session': {'account': 'signedOut', 'accessRevision': accessRevision},
          'extensions': {'items': <JsonMap>[]},
          'reader': reader,
        };
      case 'reader.load':
        if (arguments['url'] == _topicURL) return reader;
        break;
      case 'settings.update':
        if (arguments['key'] == _sectionKey &&
            const [
              'boards',
              'shortcuts',
              'ranking',
              'none',
            ].contains(arguments['value'])) {
          final value = arguments['value'] as String;
          if (deferWrites) {
            final write = _PendingSection(value);
            pending.add(write);
            return write.result.future;
          }
          settings = {...settings, _sectionKey: value};
          return {...settings};
        }
        break;
    }
    unexpected.add('$method $arguments');
    throw StateError('Unexpected native fixture request: $method $arguments');
  }
}

DeskSidebarSection? _section(WidgetTester tester) => tester
    .widget<DeskWorkspaceSidebar>(find.byType(DeskWorkspaceSidebar))
    .section;

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _toggle(WidgetTester tester, String group) async {
  await tester.tap(find.byKey(ValueKey('sidebar-header-$group')));
  await _frames(tester);
}

Future<AppState> _mount(
  WidgetTester tester,
  _SectionNative native, {
  bool withSettings = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  final state = AppState(client: native)..connecting = false;
  state.domains['workspace'] = native.workspace;
  state.domains['extensions'] = {'items': <JsonMap>[]};
  state.domains['session'] = {'account': 'signedOut'};
  if (withSettings) state.domains['settings'] = {...native.settings};
  state.readers[_topicURL] = native.reader;
  state.recordReaderOffset(
    _topicURL,
    283.75,
    revision: state.accessRevision,
    epoch: state.readerPositionEpoch,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    native.deferWrites = false;
    while (native.pending.isNotEmpty) {
      native.completeNext();
    }
    await tester.pump();
    state.dispose();
    await native.snapshotEvents.close();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
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

  final restorationCases = <(Object?, DeskSidebarSection?)>[
    ('boards', DeskSidebarSection.boards),
    ('shortcuts', DeskSidebarSection.shortcuts),
    ('ranking', DeskSidebarSection.ranking),
    ('none', null),
    (null, DeskSidebarSection.ranking),
    ('invalid', DeskSidebarSection.ranking),
    (42, DeskSidebarSection.ranking),
    (true, DeskSidebarSection.ranking),
  ];
  for (final entry in restorationCases) {
    testWidgets('initial sidebar preference ${entry.$1} restores safely', (
      tester,
    ) async {
      final native = _SectionNative(saved: entry.$1);
      await _mount(tester, native);
      expect(_section(tester), entry.$2);
      expect(native.writes, isEmpty);
    });
  }

  testWidgets('late bootstrap restores a section without saving a default', (
    tester,
  ) async {
    final native = _SectionNative(saved: 'boards');
    final state = await _mount(tester, native, withSettings: false);
    expect(_section(tester), DeskSidebarSection.ranking);
    await state.connect();
    await _frames(tester);
    expect(_section(tester), DeskSidebarSection.boards);
    expect(native.writes, isEmpty);
    expect(state.workspace.board, 'review');
  });

  testWidgets('folding saves none while preserving tabs, positions and board', (
    tester,
  ) async {
    final native = _SectionNative(saved: 'boards');
    final state = await _mount(tester, native);
    final workspace = state.domain('workspace');
    final reader = state.readerFor(_topicURL);
    final navigation = state.navigationRevision;
    native.calls.clear();
    await _toggle(tester, 'boards');
    expect(_section(tester), isNull);
    expect(state.domain('settings')[_sectionKey], 'none');
    await _toggle(tester, 'shortcuts');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    expect(native.writes, ['none', 'shortcuts']);
    expect(native.calls.every((call) => call.$1 == 'settings.update'), isTrue);
    expect(state.domain('workspace'), same(workspace));
    expect(state.readerFor(_topicURL), same(reader));
    expect(state.workspace.board, 'review');
    expect(state.workspace.showReader, isFalse);
    expect(state.workspace.selectedTab, '810');
    expect(state.workspace.tabs.map((tab) => tab.id), ['810', '812']);
    expect(state.workspace.closedTabs.single.id, '811');
    expect(state.readerOffset(_topicURL), 283.75);
    expect(state.navigationRevision, navigation);
  });

  testWidgets('rapid clicks retain the final section through earlier replies', (
    tester,
  ) async {
    final native = _SectionNative()..deferWrites = true;
    final state = await _mount(tester, native);
    await _toggle(tester, 'boards');
    await _toggle(tester, 'boards');
    await _toggle(tester, 'shortcuts');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    expect(native.writes, ['boards']);
    native.completeNext();
    await _frames(tester);
    expect(state.domain('settings')[_sectionKey], 'boards');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    expect(native.writes, ['boards', 'none']);
    native.completeNext();
    await _frames(tester);
    expect(state.domain('settings')[_sectionKey], 'none');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    expect(native.writes, ['boards', 'none', 'shortcuts']);
    native.completeNext();
    await _frames(tester);
    expect(state.domain('settings')[_sectionKey], 'shortcuts');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    expect(native.pending, isEmpty);
  });

  testWidgets('failed save returns to the last authoritative section', (
    tester,
  ) async {
    final native = _SectionNative(saved: 'boards')..deferWrites = true;
    final state = await _mount(tester, native);
    await _toggle(tester, 'shortcuts');
    expect(_section(tester), DeskSidebarSection.shortcuts);
    native.completeNext(fail: true);
    await _frames(tester);
    expect(_section(tester), DeskSidebarSection.boards);
    expect(state.domain('settings')[_sectionKey], 'boards');
    expect(state.message, 'Fixture save failed');
    expect(native.writes, ['shortcuts']);
  });

  testWidgets(
    'failure of the latest click rolls back to the earlier saved choice',
    (tester) async {
      final native = _SectionNative()..deferWrites = true;
      final state = await _mount(tester, native);
      await _toggle(tester, 'boards');
      await _toggle(tester, 'shortcuts');
      native.completeNext();
      await _frames(tester);
      expect(_section(tester), DeskSidebarSection.shortcuts);
      native.completeNext(fail: true);
      await _frames(tester);
      expect(_section(tester), DeskSidebarSection.boards);
      expect(state.domain('settings')[_sectionKey], 'boards');
    },
  );

  testWidgets('account revision rejects stale replies and queued old writes', (
    tester,
  ) async {
    final native = _SectionNative()..deferWrites = true;
    final state = await _mount(tester, native);
    await state.connect();
    await _frames(tester);
    await _toggle(tester, 'boards');
    await _toggle(tester, 'shortcuts');
    final oldResponse = {...native.settings, _sectionKey: 'boards'};
    final revision = state.accessRevision + 1;
    native.settings = {...native.settings, _sectionKey: 'none'};
    native.snapshotEvents.add({
      'domain': 'snapshot',
      'accessRevision': revision,
      'data': {
        'session': {
          'account': 'signedIn',
          'owner': 202,
          'accessRevision': revision,
        },
        'settings': {...native.settings},
      },
    });
    await _frames(tester);
    expect(state.accessRevision, revision);
    expect(_section(tester), isNull);
    await _toggle(tester, 'boards');
    expect(_section(tester), DeskSidebarSection.boards);
    expect(native.writes, ['boards']);
    native.completeNext(response: oldResponse);
    await _frames(tester);
    expect(native.writes, ['boards', 'boards']);
    expect(state.domain('settings')[_sectionKey], 'none');
    expect(_section(tester), DeskSidebarSection.boards);
    expect(native.pending.single.value, 'boards');
    native.completeNext();
    await _frames(tester);
    expect(state.domain('session')['owner'], 202);
    expect(state.domain('settings')[_sectionKey], 'boards');
    expect(state.workspace.board, 'review');
    expect(state.workspace.tabs.map((tab) => tab.id), ['810', '812']);
    expect(native.pending, isEmpty);
  });
}
