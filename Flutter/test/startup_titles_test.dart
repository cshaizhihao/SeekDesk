import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

const _openIDs = ['41', '42', '43'];
const _closedIDs = ['44', '45'];
const _selectedURL = 'https://www.nodeseek.com/post-42-3#24';
const _titlesA = {
  '41': '甲的线路记录',
  '42': '甲的阅读主题',
  '43': '甲的服务器笔记',
  '44': '甲较早关闭主题',
  '45': '甲最近关闭主题',
};
const _titlesB = {
  '41': '乙的线路记录',
  '42': '乙的阅读主题',
  '43': '乙的服务器笔记',
  '44': '乙较早关闭主题',
  '45': '乙最近关闭主题',
};

String _placeholder(String id) => '帖子 #$id';

/// Only the real workspace event supplies names. Selected reader requests stay
/// pending so neither a body response nor hidden-tab fetches can repair labels.
class _TitleNative extends NativeClient {
  _TitleNative({required this.showReader})
    : super(methods: MethodChannel('seekdesk.test.startup-titles.${_next++}'));

  static int _next = 0;
  final bool showReader;
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final pendingReads = <Completer<JsonMap>>[];
  final unexpected = <String>[];

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  Iterable<JsonMap> get reads =>
      calls.where((call) => call.$1 == 'reader.load').map((call) => call.$2);

  JsonMap workspace([Map<String, String> titles = const {}]) {
    JsonMap topic(String id) => {
      'id': id,
      'url': id == '42' ? _selectedURL : 'https://www.nodeseek.com/post-$id-1',
      'title': titles[id] ?? _placeholder(id),
    };
    return {
      'tabs': _openIDs.map(topic).toList(),
      'closedTabs': _closedIDs.map(topic).toList(),
      'selectedTab': '42',
      'showReader': showReader,
      'posts': <JsonMap>[],
      'boards': <JsonMap>[],
    };
  }

  void confirmOwner(int revision, int owner) => eventStream.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {
      'account': 'signedIn',
      'owner': owner,
      'accessRevision': revision,
      'canCompose': true,
    },
  });

  void publishTitles(int revision, Map<String, String> titles) =>
      eventStream.add({
        'domain': 'workspace',
        'accessRevision': revision,
        'data': workspace(titles),
      });

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    if (method == 'bootstrap') {
      return {
        'session': {'account': 'unconfirmed', 'accessRevision': 0},
        'workspace': workspace(),
        'settings': {
          'appearance': 'light',
          'workspace.hideListWhileReading': true,
          'workspace.mistBackdrop': false,
        },
        'extensions': {'items': <JsonMap>[]},
      };
    }
    if (method == 'reader.load' && showReader && args['url'] == _selectedURL) {
      final response = Completer<JsonMap>();
      pendingReads.add(response);
      return response.future;
    }
    unexpected.add('$method $args');
    throw StateError('Unexpected startup-title operation: $method');
  }
}

Future<void> _frames(WidgetTester tester, [int count = 20]) async {
  // Bounded fake frames also finish the tab regrid and dialog transitions.
  // A pending reader intentionally keeps its activity indicator mounted.
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppState> _mount(WidgetTester tester, _TitleNative native) async {
  final state = AppState(client: native);
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    for (final read in native.pendingReads) {
      if (!read.isCompleted) read.complete({});
    }
    await _frames(tester, 2);
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await state.connect();
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(home: WorkspaceScreen(state: state)),
    ),
  );
  await _frames(tester);
  return state;
}

void _expectTabs(
  WidgetTester tester,
  AppState state,
  Map<String, String> titles, {
  required bool showReader,
}) {
  final control = tester.widget<GlassSegmentedControl>(
    find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.byType(GlassSegmentedControl),
    ),
  );
  expect(control.segments.map((segment) => segment.id), _openIDs);
  expect(control.selectedIndex, 1);
  for (final id in _openIDs) {
    expect(
      find.descendant(
        of: find.byKey(ValueKey('tab-target-$id')).first,
        matching: find.text(titles[id] ?? _placeholder(id)),
      ),
      findsOneWidget,
    );
  }
  expect(state.workspace.tabs.map((topic) => topic.id), _openIDs);
  expect(state.workspace.closedTabs.map((topic) => topic.id), _closedIDs);
  expect(state.workspace.selectedTab, '42');
  expect(state.workspace.selected!.url, _selectedURL);
  expect(state.workspace.showReader, showReader);
  expect(state.navigationRevision, 0);
}

Future<void> _openClosedTabs(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (widget) => widget is DeskButton && widget.label == '最近关闭',
    ),
  );
  await _frames(tester);
  expect(find.text('最近关闭的标签'), findsOneWidget);
}

void _expectClosedTitles(WidgetTester tester, Map<String, String> titles) {
  for (final id in _closedIDs) {
    expect(
      find.descendant(
        of: find.byKey(ValueKey('closed-tab-$id')),
        matching: find.text(titles[id] ?? _placeholder(id)),
      ),
      findsOneWidget,
    );
  }
  expect(
    tester.getTopLeft(find.byKey(const ValueKey('closed-tab-45'))).dy,
    lessThan(tester.getTopLeft(find.byKey(const ValueKey('closed-tab-44'))).dy),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'confirmed owner workspace titles refresh overview tabs and an open history without reading posts',
    (tester) async {
      final native = _TitleNative(showReader: false);
      final state = await _mount(tester, native);
      _expectTabs(tester, state, const {}, showReader: false);

      native.confirmOwner(1, 101);
      await _frames(tester);
      _expectTabs(tester, state, const {}, showReader: false);
      await _openClosedTabs(tester);
      _expectClosedTitles(tester, const {});

      native.publishTitles(1, _titlesA);
      await _frames(tester);
      _expectTabs(tester, state, _titlesA, showReader: false);
      _expectClosedTitles(tester, _titlesA);
      expect(state.domain('session')['owner'], 101);
      expect(native.calls.map((call) => call.$1), ['bootstrap']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'an old revision cannot resurrect previous owner titles or load background tabs',
    (tester) async {
      final native = _TitleNative(showReader: true);
      final state = await _mount(tester, native);
      _expectTabs(tester, state, const {}, showReader: true);
      expect(native.reads, hasLength(1));

      native.confirmOwner(1, 101);
      await _frames(tester);
      final beforeTitlesA = native.reads.length;
      native.publishTitles(1, _titlesA);
      await _frames(tester);
      _expectTabs(tester, state, _titlesA, showReader: true);
      expect(native.reads.length, beforeTitlesA);

      native.confirmOwner(2, 202);
      await _frames(tester);
      final beforeTitlesB = native.reads.length;
      native.publishTitles(2, _titlesB);
      await _frames(tester);
      _expectTabs(tester, state, _titlesB, showReader: true);
      expect(native.reads.length, beforeTitlesB);
      await _openClosedTabs(tester);
      _expectClosedTitles(tester, _titlesB);

      native.publishTitles(1, _titlesA);
      await _frames(tester);
      _expectTabs(tester, state, _titlesB, showReader: true);
      _expectClosedTitles(tester, _titlesB);
      for (final oldTitle in _titlesA.values) {
        expect(find.text(oldTitle), findsNothing);
      }
      expect(state.accessRevision, 2);
      expect(state.domain('session')['owner'], 202);
      expect(native.reads.length, beforeTitlesB);
      expect(
        native.reads.map((read) => read['url']),
        everyElement(_selectedURL),
      );
      expect(native.reads.map((read) => read['accessRevision']), [0, 1, 2]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
