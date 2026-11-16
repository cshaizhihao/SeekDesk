import 'dart:async';
import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/widgets/desk_workspace_sidebar.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_sidebar_divider.dart';
import 'package:seekdesk_flutter/widgets/desk_wordmark.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _topicURL = 'https://www.nodeseek.com/post-1701-1';
const _otherURL = 'https://www.nodeseek.com/post-1702-1';
const _sidebarSetting = 'workspace.sidebarWidth';

class _PendingWidth {
  _PendingWidth(this.value);
  final double value;
  final result = Completer<JsonMap>();
}

/// Only in-memory workspace, settings, and text-only reading fixtures. It never
/// connects to the native event stream or accesses user preferences or media.
class _SidebarNative extends NativeClient {
  _SidebarNative({this.reading = true, double sidebarWidth = 228})
    : super(methods: const MethodChannel('seekdesk.test.sidebar-layout')) {
    settings = {
      _sidebarSetting: sidebarWidth,
      'workspace.topicColumnWidth': 240.0,
      'workspace.readerTextSize': 18.0,
      'workspace.listTextSize': 17.0,
    };
  }

  bool reading;
  String board = 'tech';
  String query = '';
  late JsonMap settings;
  bool deferWidthSaves = false;
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final pendingWidths = <_PendingWidth>[];
  final calls = <(String, JsonMap)>[];
  final unexpectedCalls = <String>[];

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  JsonMap get workspace => {
    'posts': [
      {
        'id': '1701',
        'url': _topicURL,
        'title': 'Sidebar fixture post',
        'author': 'Fixture author',
        'category': '技术',
      },
    ],
    'tabs': [
      {'id': '1701', 'url': _topicURL, 'title': 'Sidebar tab A'},
      {'id': '1702', 'url': _otherURL, 'title': 'Sidebar tab B'},
    ],
    'selectedTab': '1701',
    'showReader': reading,
    'board': board,
    'query': query,
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap reader(String url) => {
    'url': url,
    'scrollOffset': 0.0,
    'thread': {
      'title': 'Sidebar reader fixture',
      'root': {
        'id': '0',
        'author': 'Root',
        'blocks': [
          {'kind': 'text', 'text': 'Short opening line.'},
        ],
      },
      'replies': [
        for (var index = 1; index <= 40; index++)
          {
            'id': '$index',
            'author': 'User $index',
            'blocks': [
              {'kind': 'text', 'text': 'Short floor $index.'},
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  Iterable<JsonMap> get widthWrites => calls
      .where(
        (call) =>
            call.$1 == 'settings.update' && call.$2['key'] == _sidebarSetting,
      )
      .map((call) => call.$2);

  void completeNextWidth({JsonMap? response}) {
    final pending = pendingWidths.removeAt(0);
    if (response != null) {
      // A delayed reply may carry the earlier snapshot after a newer settings
      // event. Delivering that reply does not repeat its original native write.
      pending.result.complete({...response});
      return;
    }
    settings = {...settings, _sidebarSetting: pending.value};
    pending.result.complete({...settings});
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
        };
      case 'reader.load':
        return reader(stringValue(arguments['url']));
      case 'reader.rememberPosition':
        return {'saved': true};
      case 'settings.get':
        return {...settings};
      case 'settings.update':
        if (arguments['key'] == _sidebarSetting && deferWidthSaves) {
          final pending = _PendingWidth(numberValue(arguments['value']));
          pendingWidths.add(pending);
          return pending.result.future;
        }
        settings = {
          ...settings,
          stringValue(arguments['key']): arguments['value'],
        };
        return {...settings};
      case 'listing.selectBoard':
        board = stringValue(arguments['id']);
        query = '';
        reading = false;
        return workspace;
      case 'listing.search':
        query = stringValue(arguments['query']);
        reading = false;
        return workspace;
      case 'listing.clearSearch':
        query = '';
        return workspace;
      default:
        unexpectedCalls.add(method);
        throw StateError('Unexpected local sidebar fixture request: $method');
    }
  }
}

Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);

Finder get _sidebar => find.byKey(const ValueKey('workspace-sidebar'));
Finder get _content => find.byKey(const ValueKey('workspace-content'));
Finder get _divider => find.byWidgetPredicate(
  (widget) => widget is DeskSidebarDivider && widget.label == '侧边栏宽度',
);
Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

ScrollController _readerController(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_readerScroll).controller!;

/// Observe public body geometry independently of the reader's saved anchor.
/// Cached offstage floors are included, then filtered against the real viewport.
({String floor, double dy}) _visibleReaderBody(WidgetTester tester) {
  final viewport = tester.getRect(_readerScroll);
  final candidates = <({String floor, double dy})>[];
  final floors = find.descendant(
    of: find.byType(ReaderScreen),
    matching: find.byType(ReaderFloorContext, skipOffstage: false),
    skipOffstage: false,
  );
  for (final element in floors.evaluate()) {
    final floor = (element.widget as ReaderFloorContext).floor.id;
    final body = find.descendant(
      of: find.byElementPredicate(
        (candidate) => identical(candidate, element),
        skipOffstage: false,
      ),
      matching: find.byType(ForumBlocks, skipOffstage: false),
      skipOffstage: false,
    );
    final rect = tester.getRect(body);
    if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
    candidates.add((floor: floor, dy: rect.top - viewport.top));
  }
  expect(candidates, isNotEmpty);
  candidates.sort((a, b) => a.dy.compareTo(b.dy));
  return candidates.first;
}

void _expectReaderBody(
  WidgetTester tester,
  ({String floor, double dy}) before,
) {
  final actual = _visibleReaderBody(tester);
  expect(actual.floor, before.floor);
  expect(
    actual.dy,
    closeTo(before.dy, 1),
    reason:
        'The same visible body must stay at its actual viewport position '
        'when sidebar width changes the document above it.',
  );
}

Future<void> _expectSavedReaderBody(
  WidgetTester tester,
  _SidebarNative native,
  AppState state,
  ({String floor, double dy}) before,
) async {
  await _frames(tester);
  await tester.pump(const Duration(milliseconds: 650));
  await _frames(tester);
  _expectReaderBody(tester, before);
  final actual = _visibleReaderBody(tester);
  final controller = _readerController(tester);
  expect(
    controller.offset,
    inInclusiveRange(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    ),
  );
  final saves = native.calls.where(
    (call) =>
        call.$1 == 'reader.rememberPosition' && call.$2['url'] == _topicURL,
  );
  expect(saves, isNotEmpty);
  final saved = saves.last.$2;
  expect(saved['offset'], closeTo(controller.offset, .5));
  final savedBody = jsonMap(saved['bodyAnchor']);
  expect(savedBody['floor'], actual.floor);
  expect(savedBody['dy'], closeTo(actual.dy, 1));
  expect(state.readerOffset(_topicURL), closeTo(controller.offset, .5));
  expect(state.readerBodyAnchor(_topicURL)?.floor, actual.floor);
  expect(state.readerBodyAnchor(_topicURL)?.dy, closeTo(actual.dy, 1));
}

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _SidebarNative native, {
  Size size = const Size(1380, 880),
}) async {
  await tester.binding.setSurfaceSize(size);
  final state = AppState(client: native);
  state.connecting = false;
  state.domains['workspace'] = native.workspace;
  state.domains['settings'] = {...native.settings};
  state.domains['session'] = {'account': 'signedOut'};
  state.domains['extensions'] = {'items': <JsonMap>[]};
  state.readers[_topicURL] = native.reader(_topicURL);
  state.readers[_otherURL] = native.reader(_otherURL);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    native.deferWidthSaves = false;
    while (native.pendingWidths.isNotEmpty) {
      native.completeNextWidth();
    }
    await tester.pump();
    state.dispose();
    await native.snapshotEvents.close();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpectedCalls, isEmpty);
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

Future<TestGesture> _startResize(WidgetTester tester, double delta) async {
  final gesture = await tester.startGesture(
    tester.getCenter(_divider),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(Offset(delta, 0));
  await _frames(tester);
  return gesture;
}

Future<FocusNode> _focusBody(WidgetTester tester) async {
  // Attach under the actual workspace ExcludeFocus without changing layout or
  // replacing the retained reader. This models an editor/reader focus target.
  final node = FocusNode(debugLabel: 'Sidebar fixture body focus');
  node.attach(tester.element(_content)).reparent();
  addTearDown(node.dispose);
  node.requestFocus();
  await _frames(tester);
  expect(node.hasPrimaryFocus, isTrue);
  return node;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'home wordmark clears the active search and scope while keeping open tabs',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final native = _SidebarNative(reading: false);
        final state = await _mount(tester, native);
        final originalTabs = state.workspace.tabs.map((tab) => tab.id).toList();
        final originalSelected = state.workspace.selectedTab;

        await tester.tap(find.widgetWithText(DeskButton, '搜索帖子'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoTextField).first,
          'before home',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final initialSearch = native.calls
            .where((call) => call.$1 == 'listing.search')
            .last
            .$2;
        expect(initialSearch['query'], 'before home');
        expect(initialSearch['scope'], ['tech']);

        expect(find.byType(DeskWordmark), findsOneWidget);
        final home = find.bySemanticsLabel('SeekDesk 首页');
        expect(home, findsOneWidget);
        expect(
          tester
              .getSemantics(home)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        await tester.tap(find.byType(DeskWordmark));
        await _frames(tester);
        expect(
          native.calls
              .where((call) => call.$1 == 'listing.selectBoard')
              .single
              .$2,
          {'id': ''},
        );
        expect(state.workspace.board, '');
        expect(state.domain('workspace')['query'], isEmpty);
        expect(find.byType(CupertinoTextField), findsNothing);
        expect(state.workspace.tabs.map((tab) => tab.id), originalTabs);
        expect(state.workspace.selectedTab, originalSelected);
        await tester.tap(find.widgetWithText(DeskButton, '搜索帖子'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
              .controller!
              .text,
          isEmpty,
        );

        await tester.enterText(
          find.byType(CupertinoTextField).first,
          'after home',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final nextSearch = native.calls
            .where((call) => call.$1 == 'listing.search')
            .last
            .$2;
        expect(nextSearch['query'], 'after home');
        expect(nextSearch['scope'], isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final sample in [
    (const Size(1380, 880), 228.0, 228.0),
    (const Size(990, 540), 360.0, 360.0),
  ]) {
    testWidgets(
      'sidebar toggle expands content without replacing the reader at ${sample.$1.width}',
      (tester) async {
        final native = _SidebarNative(sidebarWidth: sample.$2);
        final state = await _mount(tester, native, size: sample.$1);
        expect(tester.getSize(_sidebar).width, sample.$3);
        expect(_divider, sample.$1.width < 990 ? findsNothing : findsOneWidget);
        final readerState = tester.state(find.byType(ReaderScreen));
        final readerElement = tester.element(find.byType(ReaderScreen));
        final readerKey = tester
            .widget<ReaderScreen>(find.byType(ReaderScreen))
            .key;
        final controller = _readerController(tester);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(_readerScroll),
            scrollDelta: const Offset(0, 420),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await _frames(tester);
        expect(controller.offset, greaterThan(0));
        final visibleBody = _visibleReaderBody(tester);
        final originalContentWidth = tester.getSize(_content).width;
        final selectedTab = state.workspace.selectedTab;
        final settings = {...state.domain('settings')};
        final beforeCalls = native.calls.length;

        await tester.tap(_icon('收起侧栏'));
        await _frames(tester);
        expect(_sidebar, findsNothing);
        expect(_divider, findsNothing);
        expect(_icon('展开侧栏'), findsOneWidget);
        expect(
          tester.getSize(_content).width,
          greaterThan(originalContentWidth),
        );
        final panels = find
            .byType(DeskDocument)
            .evaluate()
            .map((element) => tester.getRect(find.byWidget(element.widget)));
        expect(
          panels.map((rect) => rect.left).reduce((a, b) => a < b ? a : b),
          16,
        );
        expect(
          panels.map((rect) => rect.right).reduce((a, b) => a > b ? a : b),
          sample.$1.width - 16,
        );
        expect(tester.state(find.byType(ReaderScreen)), same(readerState));
        expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
        expect(
          tester.widget<ReaderScreen>(find.byType(ReaderScreen)).key,
          readerKey,
        );
        expect(_readerController(tester), same(controller));
        // Width changes can shorten the title/header above the viewport. A
        // matching pixel offset would move the body by that layout delta.
        _expectReaderBody(tester, visibleBody);
        await _expectSavedReaderBody(tester, native, state, visibleBody);
        expect(tester.takeException(), isNull);

        await tester.tap(_icon('展开侧栏'));
        await _frames(tester);
        expect(tester.getSize(_sidebar).width, sample.$3);
        expect(
          tester.getSize(_content).width,
          closeTo(originalContentWidth, 1),
        );
        expect(tester.state(find.byType(ReaderScreen)), same(readerState));
        expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
        expect(_readerController(tester), same(controller));
        _expectReaderBody(tester, visibleBody);
        await _expectSavedReaderBody(tester, native, state, visibleBody);
        expect(state.workspace.selectedTab, selectedTab);
        expect(state.domain('settings'), settings);
        expect(
          native.calls
              .skip(beforeCalls)
              .where(
                (call) => const {
                  'reader.load',
                  'reader.overview',
                  'reader.select',
                  'settings.update',
                }.contains(call.$1),
              ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'sidebar drag previews locally and commits once, then survives hide and show',
    (tester) async {
      final native = _SidebarNative();
      final state = await _mount(tester, native);
      final readerState = tester.state(find.byType(ReaderScreen));
      final start = tester.getSize(_sidebar).width;
      final gesture = await _startResize(tester, 40);
      expect(tester.getSize(_sidebar).width, greaterThan(start));
      expect(native.widthWrites, isEmpty);
      expect(state.domain('settings')[_sidebarSetting], start);
      await gesture.moveBy(const Offset(25, 0));
      await _frames(tester);
      final preview = tester.getSize(_sidebar).width;
      expect(preview, greaterThan(start + 40));
      expect(native.widthWrites, isEmpty);
      await gesture.up();
      await _frames(tester);
      expect(native.widthWrites.single, {
        'key': _sidebarSetting,
        'value': preview.roundToDouble(),
      });
      expect(
        state.domain('settings')[_sidebarSetting],
        preview.roundToDouble(),
      );
      await tester.tap(_icon('收起侧栏'));
      await _frames(tester);
      await tester.tap(_icon('展开侧栏'));
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, preview.roundToDouble());
      expect(native.widthWrites, hasLength(1));
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double clicking the divider restores 228 with a single settings write',
    (tester) async {
      final native = _SidebarNative(sidebarWidth: 310);
      final state = await _mount(tester, native);
      await tester.tap(_divider);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(_divider);
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, 228);
      expect(state.domain('settings')[_sidebarSetting], 228);
      expect(native.widthWrites.single, {
        'key': _sidebarSetting,
        'value': 228.0,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a delayed save cannot replace a newer drag still under the pointer',
    (tester) async {
      final native = _SidebarNative()..deferWidthSaves = true;
      final state = await _mount(tester, native);
      final first = await _startResize(tester, 45);
      final firstWidth = tester.getSize(_sidebar).width;
      await first.up();
      await _frames(tester);
      expect(native.pendingWidths, hasLength(1));
      final second = await _startResize(tester, 35);
      final secondWidth = tester.getSize(_sidebar).width;
      expect(secondWidth, greaterThan(firstWidth));
      native.completeNextWidth();
      await _frames(tester);
      expect(
        state.domain('settings')[_sidebarSetting],
        firstWidth.roundToDouble(),
      );
      expect(tester.getSize(_sidebar).width, secondWidth);
      expect(native.widthWrites, hasLength(1));
      await second.moveBy(const Offset(10, 0));
      await _frames(tester);
      final finalWidth = tester.getSize(_sidebar).width;
      expect(finalWidth, greaterThan(secondWidth));
      await second.up();
      await _frames(tester);
      expect(native.widthWrites, hasLength(2));
      native.completeNextWidth();
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, finalWidth.roundToDouble());
      expect(
        state.domain('settings')[_sidebarSetting],
        finalWidth.roundToDouble(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an older serialized save cannot undo a newer completed resize', (
    tester,
  ) async {
    final native = _SidebarNative()..deferWidthSaves = true;
    final state = await _mount(tester, native);
    final first = await _startResize(tester, 40);
    await first.up();
    await _frames(tester);
    final second = await _startResize(tester, 45);
    final newestWidth = tester.getSize(_sidebar).width.roundToDouble();
    await second.up();
    await _frames(tester);
    expect(
      native.widthWrites,
      hasLength(1),
      reason: 'AppState serializes writes to one settings key.',
    );
    expect(tester.getSize(_sidebar).width, newestWidth);
    native.completeNextWidth();
    await _frames(tester);
    expect(native.widthWrites, hasLength(2));
    expect(native.pendingWidths, hasLength(1));
    expect(tester.getSize(_sidebar).width, newestWidth);
    native.completeNextWidth();
    await _frames(tester);
    expect(state.domain('settings')[_sidebarSetting], newestWidth);
    expect(tester.getSize(_sidebar).width, newestWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled resize restores its width and permits a later settings update',
    (tester) async {
      final native = _SidebarNative(sidebarWidth: 250);
      final state = await _mount(tester, native);
      final gesture = await _startResize(tester, 55);
      expect(tester.getSize(_sidebar).width, greaterThan(250));
      await gesture.cancel();
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, 250);
      expect(native.widthWrites, isEmpty);
      native.settings = {...native.settings, _sidebarSetting: 310.0};
      await state.act('settings.get', {}, 'settings');
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, 310);
      expect(state.domain('settings')[_sidebarSetting], 310);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'crossing the compact breakpoint cancels an unfinished resize without saving',
    (tester) async {
      final native = _SidebarNative(reading: false, sidebarWidth: 250);
      final state = await _mount(tester, native, size: const Size(990, 540));
      expect(_divider, findsOneWidget);
      final gesture = await _startResize(tester, 60);
      expect(tester.getSize(_sidebar).width, greaterThan(250));
      expect(native.widthWrites, isEmpty);

      await tester.binding.setSurfaceSize(const Size(989, 540));
      await _frames(tester);
      expect(_divider, findsNothing);
      expect(_sidebar, findsNothing);
      expect(tester.getSize(_content).width, 989);
      expect(native.widthWrites, isEmpty);
      await gesture.moveBy(const Offset(15, 0));
      await gesture.up();
      await _frames(tester);
      expect(native.widthWrites, isEmpty);

      await tester.binding.setSurfaceSize(const Size(990, 540));
      await _frames(tester);
      expect(_divider, findsOneWidget);
      expect(tester.getSize(_sidebar).width, 250);
      expect(state.domain('settings')[_sidebarSetting], 250);
      native.settings = {...native.settings, _sidebarSetting: 285.0};
      await state.act('settings.get', {}, 'settings');
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, 285);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an account revision retires old pending width and rejects its late settings reply',
    (tester) async {
      final native = _SidebarNative(reading: false, sidebarWidth: 250)
        ..deferWidthSaves = true;
      final state = await _mount(tester, native);
      // Connect only to this fake's in-memory stream. Let AppState process the
      // real snapshot path; never assign client.accessRevision in the fixture.
      await state.connect();
      await _frames(tester);
      final previousRevision = state.accessRevision;
      final first = await _startResize(tester, 55);
      await first.up();
      await _frames(tester);
      expect(native.pendingWidths, hasLength(1));
      final oldWidth = native.pendingWidths.single.value;
      final oldReply = {...native.settings, _sidebarSetting: oldWidth};
      expect(tester.getSize(_sidebar).width, oldWidth);

      // Sidebar preferences are global, not per-account storage. This models a
      // newer settings snapshot arriving with an identity change while the old
      // write's response is still pending; it does not claim that write was undone.
      native.settings = {...native.settings, _sidebarSetting: 196.0};
      native.snapshotEvents.add({
        'domain': 'snapshot',
        'accessRevision': previousRevision + 1,
        'data': {
          'session': {
            'account': 'signedIn',
            'owner': 202,
            'accessRevision': previousRevision + 1,
          },
          'settings': {...native.settings},
        },
      });
      await _frames(tester);
      expect(state.accessRevision, previousRevision + 1);
      expect(state.domain('session')['owner'], 202);
      expect(state.domain('settings')[_sidebarSetting], 196);
      expect(tester.getSize(_sidebar).width, 196);
      expect(native.pendingWidths, hasLength(1));

      // A fresh resize belongs to the new identity even though AppState still
      // serializes it behind the outstanding old settings request.
      final current = await _startResize(tester, 45);
      final currentWidth = tester.getSize(_sidebar).width.roundToDouble();
      await current.up();
      await _frames(tester);
      expect(currentWidth, greaterThan(196));
      expect(native.widthWrites, hasLength(1));
      native.completeNextWidth(response: oldReply);
      await _frames(tester);
      expect(state.accessRevision, previousRevision + 1);
      expect(state.domain('session')['owner'], 202);
      expect(
        state.domain('settings')[_sidebarSetting],
        196,
        reason: 'The old reply must not overwrite the newer settings domain.',
      );
      expect(
        tester.getSize(_sidebar).width,
        currentWidth,
        reason: 'Old completion cleanup must not remove the new pending width.',
      );
      expect(native.widthWrites, hasLength(2));
      expect(native.pendingWidths, hasLength(1));
      native.completeNextWidth();
      await _frames(tester);
      expect(state.domain('settings')[_sidebarSetting], currentWidth);
      expect(tester.getSize(_sidebar).width, currentWidth);
      expect(state.domain('session')['owner'], 202);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact navigation overlays full-width reader and dismisses without losing position',
    (tester) async {
      final native = _SidebarNative(sidebarWidth: 308);
      await _mount(tester, native, size: const Size(780, 540));
      expect(_sidebar, findsNothing);
      expect(tester.getSize(_content).width, 780);
      final readerState = tester.state(find.byType(ReaderScreen));
      final controller = _readerController(tester);
      controller.jumpTo(300);
      await _frames(tester);
      final offset = controller.offset;
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      expect(tester.getSize(_sidebar).width, 308);
      expect(tester.getSize(_content).width, 780);
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      final count = native.calls.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(controller.offset, offset);
      expect(native.calls.length, count);
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      await tester.tapAt(const Offset(650, 300));
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(controller.offset, offset);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact board selection closes navigation and wide resize restores saved sidebar',
    (tester) async {
      final native = _SidebarNative(reading: false, sidebarWidth: 308)
        ..board = '';
      final state = await _mount(tester, native, size: const Size(780, 540));
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      final sidebarState = tester.state(find.byType(DeskWorkspaceSidebar));
      await tester.tap(find.byKey(const ValueKey('sidebar-header-boards')));
      await _frames(tester);
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('技术')),
      );
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(
        native.calls.where((call) => call.$1 == 'listing.selectBoard'),
        hasLength(1),
      );
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      expect(
        tester.state(find.byType(DeskWorkspaceSidebar)),
        same(sidebarState),
      );
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('compact-sidebar-dismiss')),
        findsNothing,
      );
      expect(tester.getSize(_sidebar).width, 308);
      expect(
        tester.state(find.byType(DeskWorkspaceSidebar)),
        same(sidebarState),
      );
      expect(state.domain('settings')[_sidebarSetting], 308);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact dismissal restores retained body focus after focus exclusion rebuilds',
    (tester) async {
      final native = _SidebarNative();
      await _mount(tester, native, size: const Size(780, 540));
      final focus = await _focusBody(tester);
      for (final escape in [true, false]) {
        await tester.tap(_icon('打开导航'));
        await _frames(tester);
        expect(focus.hasFocus, isFalse);
        expect(focus.canRequestFocus, isFalse);
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tapAt(const Offset(650, 300));
        }
        await _frames(tester);
        expect(_sidebar, findsNothing);
        expect(focus.canRequestFocus, isTrue);
        expect(focus.hasPrimaryFocus, isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'choosing a new compact destination does not restore the old body focus',
    (tester) async {
      final native = _SidebarNative()..board = '';
      await _mount(tester, native, size: const Size(780, 540));
      final focus = await _focusBody(tester);
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar-header-boards')));
      await _frames(tester);
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('技术')),
      );
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(focus.hasFocus, isFalse);
      expect(
        native.calls.where((call) => call.$1 == 'listing.selectBoard'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final boundary in [
    'account',
    'route',
    'office',
    'reopen',
    'navigation',
    'dispose',
  ]) {
    testWidgets(
      'compact deferred focus restoration is cancelled by $boundary',
      (tester) async {
        final native = _SidebarNative();
        final state = await _mount(tester, native, size: const Size(780, 540));
        final focus = await _focusBody(tester);
        await tester.tap(_icon('打开导航'));
        await _frames(tester);
        final toggle = tester.widget<DeskIcon>(_icon('关闭导航')).onTap!;
        final barrier = tester.widget<ModalBarrier>(
          find.byKey(const ValueKey('compact-sidebar-dismiss')),
        );
        barrier.onDismiss!();
        switch (boundary) {
          case 'account':
            native.accessRevision++;
          case 'route':
            unawaited(
              Navigator.of(tester.element(find.byType(WorkspaceScreen))).push(
                CupertinoPageRoute<void>(
                  builder: (_) => const CupertinoPageScaffold(
                    child: Center(child: Text('Focus boundary route')),
                  ),
                ),
              ),
            );
          case 'office':
            state.domains['extensions'] = {
              'items': [
                {'id': 'office', 'active': true},
              ],
              'settings': {
                'office': {'presented': true},
              },
            };
          case 'reopen':
            toggle();
          case 'navigation':
            state.navigationRevision++;
          case 'dispose':
            await tester.pumpWidget(const SizedBox.shrink());
        }
        await _frames(tester);
        expect(focus.hasFocus, isFalse);
        if (boundary == 'reopen') expect(_sidebar, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reselecting the current compact board dismisses without a repeat request or reader reset',
    (tester) async {
      final native = _SidebarNative();
      final state = await _mount(tester, native, size: const Size(780, 540));
      final controller = _readerController(tester);
      controller.jumpTo(300);
      await _frames(tester);
      final focus = await _focusBody(tester);
      final readerState = tester.state(find.byType(ReaderScreen));
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar-header-boards')));
      await _frames(tester);
      final beforeCalls = native.calls.length;
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('技术')),
      );
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(native.calls.length, beforeCalls);
      expect(state.workspace.showReader, isTrue);
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(controller.offset, 300);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'current compact home and footer dismiss while wide reselect remains a no-op',
    (tester) async {
      final native = _SidebarNative(reading: false)..board = '';
      await _mount(tester, native, size: const Size(780, 540));
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      var beforeCalls = native.calls.length;
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('最新帖子')),
      );
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(native.calls.length, beforeCalls);

      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('设置')),
      );
      await _frames(tester);
      await tester.tap(_icon('打开导航'));
      await _frames(tester);
      beforeCalls = native.calls.length;
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('设置')),
      );
      await _frames(tester);
      expect(_sidebar, findsNothing);
      expect(native.calls.length, beforeCalls);

      await tester.binding.setSurfaceSize(const Size(1100, 700));
      await _frames(tester);
      beforeCalls = native.calls.length;
      await tester.tap(
        find.descendant(of: _sidebar, matching: find.text('设置')),
      );
      await _frames(tester);
      expect(_sidebar, findsOneWidget);
      expect(native.calls.length, beforeCalls);
      expect(tester.takeException(), isNull);
    },
  );
}
