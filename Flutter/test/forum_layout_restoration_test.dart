import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_sidebar_divider.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

const _topicURL = 'https://www.nodeseek.com/post-2801-1';
const _otherURL = 'https://www.nodeseek.com/post-2802-1';
const _listSetting = 'workspace.topicColumnWidth';

class _PendingWidth {
  _PendingWidth(this.value);
  final double value;
  final result = Completer<JsonMap>();
}

/// All forum, settings and account-revision responses are in memory. This
/// fixture has no platform event stream, credentials, images or network writes.
class _ForumNative extends NativeClient {
  _ForumNative({
    this.reading = true,
    this.board = 'tech',
    double listWidth = 340,
    double sidebarWidth = 228,
  }) : super(methods: const MethodChannel('seekdesk.test.forum-layout')) {
    settings = {
      _listSetting: listWidth,
      'workspace.sidebarWidth': sidebarWidth,
      'workspace.mistBackdrop': false,
      'workspace.readerTextSize': 15.0,
      'workspace.listTextSize': 15.0,
    };
  }

  bool reading;
  final String board;
  String feedOrder = 'postTime';
  String selected = '2801';
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
      for (var index = 1; index <= 8; index++)
        {
          'id': '${2800 + index}',
          'url': 'https://www.nodeseek.com/post-${2800 + index}-1',
          'title': 'List fixture $index',
          'author': 'Fixture',
          'category': '技术',
        },
    ],
    'tabs': [
      {'id': '2801', 'url': _topicURL, 'title': 'Forum tab A'},
      {'id': '2802', 'url': _otherURL, 'title': 'Forum tab B'},
    ],
    'selectedTab': selected,
    'showReader': reading,
    'board': board,
    'feedOrder': feedOrder,
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap reader(String url) => {
    'url': url,
    'scrollOffset': 0.0,
    'thread': {
      'title': 'Reading fixture',
      'root': {
        'id': '0',
        'author': 'Root',
        'blocks': [
          {'kind': 'text', 'text': 'Short opening.'},
        ],
      },
      'replies': [
        for (var index = 1; index <= 60; index++)
          {
            'id': '$index',
            'author': 'User $index',
            'blocks': [
              {'kind': 'text', 'text': 'Short reply $index.'},
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  Iterable<JsonMap> get widthWrites => calls
      .where(
        (call) =>
            call.$1 == 'settings.update' && call.$2['key'] == _listSetting,
      )
      .map((call) => call.$2);

  void completeNextWidth({JsonMap? response}) {
    final pending = pendingWidths.removeAt(0);
    if (response != null) {
      // Delivering an old response does not repeat its original native write.
      pending.result.complete({...response});
    } else {
      settings = {...settings, _listSetting: pending.value};
      pending.result.complete({...settings});
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
        };
      case 'reader.load':
        return reader(stringValue(arguments['url']));
      case 'listing.order':
        feedOrder = stringValue(arguments['order']);
        return workspace;
      case 'reader.rememberPosition':
        return {'saved': true};
      case 'reader.overview':
        reading = false;
        return workspace;
      case 'reader.select':
        selected = stringValue(arguments['id']);
        reading = true;
        return workspace;
      case 'settings.get':
        return {...settings};
      case 'settings.update':
        if (arguments['key'] == _listSetting && deferWidthSaves) {
          final pending = _PendingWidth(numberValue(arguments['value']));
          pendingWidths.add(pending);
          return pending.result.future;
        }
        settings = {
          ...settings,
          stringValue(arguments['key']): arguments['value'],
        };
        return {...settings};
      default:
        unexpectedCalls.add(method);
        throw StateError('Unexpected forum layout fixture request: $method');
    }
  }
}

Finder get _forum => find.byKey(const ValueKey('forum-content'));
Finder get _tabs => find.byKey(const ValueKey('forum-tab-bar'));
Finder get _panes => find.byKey(const ValueKey('forum-pane-row'));
Finder get _list => find.byKey(const ValueKey('forum-list-pane'));
Finder get _readerPane => find.byKey(const ValueKey('forum-reader-pane'));
Finder get _divider => find.byWidgetPredicate(
  (widget) => widget is DeskSidebarDivider && widget.label == '帖子列表宽度',
);
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _tab(String title) =>
    find.descendant(of: find.byType(WorkspaceTabs), matching: find.text(title));
Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);
ScrollController _readerController(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_readerScroll).controller!;

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _ForumNative native, {
  Size size = const Size(1380, 880),
  double textScale = 1,
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
    await tester.pump(const Duration(milliseconds: 50));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpectedCalls, isEmpty);
  });
  await tester.pumpWidget(
    CupertinoApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
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

Future<void> _scrollDown(WidgetTester tester, [double delta = 100]) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(_readerScroll),
      scrollDelta: Offset(0, delta),
      kind: PointerDeviceKind.mouse,
    ),
  );
  await _frames(tester);
}

typedef _ReadingMark = ({
  String floor,
  Finder body,
  Element element,
  double dy,
});

// Observe actual paragraph geometry without consulting the reader's stored
// anchor or pixel offset. A responsive header may change the pixels needed
// to keep this same visible paragraph at its original viewport position.
_ReadingMark _visibleReadingMark(
  WidgetTester tester, {
  double minimumDy = double.negativeInfinity,
}) {
  final viewport = tester.getRect(_readerScroll);
  _ReadingMark? result;
  for (var floor = 0; floor <= 60; floor++) {
    final text = find.descendant(
      of: find.byType(ReaderScreen),
      matching: find.text(
        floor == 0 ? 'Short opening.' : 'Short reply $floor.',
        findRichText: true,
      ),
    );
    if (text.evaluate().isEmpty) continue;
    expect(text, findsOneWidget);
    final body = find.ancestor(of: text, matching: find.byType(ForumBlocks));
    expect(body, findsOneWidget);
    final rect = tester.getRect(body);
    if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
    final dy = rect.top - viewport.top;
    if (dy < minimumDy) continue;
    if (result == null || dy < result.dy) {
      result = (
        floor: '$floor',
        body: body,
        element: tester.element(body),
        dy: dy,
      );
    }
  }
  expect(result, isNotNull, reason: 'The fixture must have visible body text.');
  return result!;
}

double _readingMarkDy(WidgetTester tester, _ReadingMark mark) {
  expect(mark.body, findsOneWidget);
  expect(tester.element(mark.body), same(mark.element));
  return tester.getTopLeft(mark.body).dy - tester.getTopLeft(_readerScroll).dy;
}

void _expectReadingMark(WidgetTester tester, _ReadingMark mark) {
  expect(_readingMarkDy(tester, mark), closeTo(mark.dy, 1));
}

Future<void> _expectWheelMovement(
  WidgetTester tester,
  ScrollController controller, [
  double delta = 100,
]) async {
  // Observe a paragraph that stays inside the viewport after this wheel
  // input; a short paragraph near the top is legitimately recycled when it
  // scrolls out. The input-distance and pixel assertions remain exact.
  final mark = _visibleReadingMark(tester, minimumDy: delta + 1);
  final offset = controller.offset;
  await _scrollDown(tester, delta);
  expect(controller.offset, closeTo(offset + delta, 1));
  expect(_readingMarkDy(tester, mark), closeTo(mark.dy - delta, 1));
}

void _expectCommonTabBar(WidgetTester tester) {
  final forum = tester.getRect(_forum);
  final tabs = tester.getRect(_tabs);
  final panes = tester.getRect(_panes);
  expect(tabs.left, closeTo(forum.left, .01));
  expect(tabs.right, closeTo(forum.right, .01));
  expect(panes.left, closeTo(forum.left, .01));
  expect(panes.right, closeTo(forum.right, .01));
  expect(tabs.bottom, lessThanOrEqualTo(panes.top + .01));
  expect(
    find.descendant(of: _tabs, matching: find.byType(WorkspaceTabs)),
    findsOneWidget,
  );
  expect(find.descendant(of: _list, matching: _tabs), findsNothing);
  expect(find.descendant(of: _readerPane, matching: _tabs), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sample in [
    (456.0, 1.0, true),
    (340.0, 1.0, false),
    (456.0, 1.6, false),
  ]) {
    testWidgets(
      'feed controls fit a ${sample.$1} pane at ${sample.$2} text scale without changing reading',
      (tester) async {
        final native = _ForumNative(board: '', listWidth: sample.$1);
        final state = await _mount(tester, native, textScale: sample.$2);
        final reader = tester.element(find.byType(ReaderScreen));
        final picker = find.descendant(
          of: _list,
          matching: find.byType(GlassSegmentedControl),
        );
        expect(picker, findsOneWidget);
        expect(
          find.byKey(const ValueKey('listing-header-inline')),
          sample.$3 ? findsOneWidget : findsNothing,
        );
        final listRect = tester.getRect(_list);
        final pickerRect = tester.getRect(picker);
        expect(pickerRect.left, greaterThanOrEqualTo(listRect.left));
        expect(pickerRect.right, lessThanOrEqualTo(listRect.right));
        final headerTitle = find
            .descendant(of: _list, matching: find.text('最新帖子'))
            .first;
        if (sample.$3) {
          expect(
            (tester.getRect(headerTitle).center.dy - pickerRect.center.dy)
                .abs(),
            lessThan(2),
          );
        } else {
          expect(tester.getRect(headerTitle).bottom, lessThan(pickerRect.top));
        }
        await tester.tap(
          find.descendant(of: picker, matching: find.text('最新回复')),
        );
        await _frames(tester);
        expect(
          native.calls.where((call) => call.$1 == 'listing.order').single.$2,
          {'order': 'replyTime'},
        );
        expect(state.workspace.selectedTab, '2801');
        expect(tester.element(find.byType(ReaderScreen)), same(reader));
        expect(native.widthWrites, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [const Size(1380, 880), const Size(780, 540)]) {
    testWidgets(
      'overview uses the full available list width at ${size.width}',
      (tester) async {
        final native = _ForumNative(reading: false, listWidth: 620);
        await _mount(tester, native, size: size);
        _expectCommonTabBar(tester);
        expect(_readerPane, findsNothing);
        expect(find.byType(ReaderScreen), findsNothing);
        expect(_divider, findsNothing);
        expect(tester.getRect(_list), tester.getRect(_panes));
        expect(_button('返回总览'), findsNothing);
        expect(_button('收起列表'), findsNothing);
        expect(_button('展开列表'), findsNothing);
        expect(find.text('List fixture 1'), findsOneWidget);
        expect(native.widthWrites, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'tabs span both panes and overview sits next to the list toggle',
    (tester) async {
      await _mount(tester, _ForumNative());
      _expectCommonTabBar(tester);
      final list = tester.getRect(_list);
      final reader = tester.getRect(_readerPane);
      final panes = tester.getRect(_panes);
      final divider = tester.getRect(_divider);
      expect(list.top, panes.top);
      expect(reader.top, panes.top);
      expect(list.bottom, panes.bottom);
      expect(reader.bottom, panes.bottom);
      expect(list.left, panes.left);
      expect(reader.right, panes.right);
      expect(divider.left, list.right);
      expect(divider.right, reader.left);
      expect(divider.width, 9);
      final back = tester.getRect(_button('返回总览'));
      final toggle = tester.getRect(_button('收起列表'));
      expect(back.center.dy, closeTo(toggle.center.dy, .01));
      expect(toggle.left - back.right, inInclusiveRange(0.0, 12.0));
      expect(back.bottom, lessThanOrEqualTo(panes.top));
      expect(tester.takeException(), isNull);
    },
  );

  for (final sample in [('Forum tab A', '2801'), ('Forum tab B', '2802')]) {
    testWidgets('overview resumes reading by clicking ${sample.$1}', (
      tester,
    ) async {
      final native = _ForumNative();
      final state = await _mount(tester, native);
      final originalTabs = state.workspace.tabs.map((tab) => tab.id).toList();
      await tester.tap(_button('返回总览'));
      await _frames(tester);
      expect(find.byType(ReaderScreen), findsNothing);
      expect(state.workspace.showReader, isFalse);
      expect(state.workspace.selectedTab, '2801');
      expect(tester.getRect(_list), tester.getRect(_panes));
      await tester.tap(_tab(sample.$1));
      await _frames(tester);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(state.workspace.showReader, isTrue);
      expect(state.workspace.selectedTab, sample.$2);
      expect(state.workspace.tabs.map((tab) => tab.id), originalTabs);
      expect(
        native.calls.where((call) => call.$1 == 'reader.select').single.$2,
        {'id': sample.$2},
      );
      expect(
        native.calls.where((call) => call.$1 == 'reader.overview'),
        hasLength(1),
      );
      expect(native.widthWrites, isEmpty);
      _expectCommonTabBar(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'list visibility and drag keep the reader mounted during successive wheel events',
    (tester) async {
      final native = _ForumNative();
      final state = await _mount(tester, native);
      final element = tester.element(find.byType(ReaderScreen));
      final readerState = tester.state(find.byType(ReaderScreen));
      final controller = _readerController(tester);
      final tab = state.workspace.selectedTab;
      for (var index = 0; index < 3; index++) {
        await _expectWheelMovement(tester, controller);
      }
      var mark = _visibleReadingMark(tester);
      final callsBefore = native.calls.length;
      await tester.tap(_button('收起列表'));
      await _frames(tester);
      expect(_list, findsNothing);
      expect(_divider, findsNothing);
      expect(tester.getRect(_readerPane), tester.getRect(_panes));
      expect(tester.element(find.byType(ReaderScreen)), same(element));
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(_readerController(tester), same(controller));
      _expectReadingMark(tester, mark);
      await _expectWheelMovement(tester, controller);
      mark = _visibleReadingMark(tester);
      await tester.tap(_button('展开列表'));
      await _frames(tester);
      expect(_list, findsOneWidget);
      expect(_divider, findsOneWidget);
      expect(tester.element(find.byType(ReaderScreen)), same(element));
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      _expectReadingMark(tester, mark);
      final gesture = await _startResize(tester, 70);
      expect(native.widthWrites, isEmpty);
      expect(tester.element(find.byType(ReaderScreen)), same(element));
      _expectReadingMark(tester, mark);
      await gesture.up();
      await _frames(tester);
      _expectReadingMark(tester, mark);
      await _expectWheelMovement(tester, controller);
      expect(_readerController(tester), same(controller));
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(state.workspace.selectedTab, tab);
      expect(native.widthWrites, hasLength(1));
      expect(
        native.calls
            .skip(callsBefore)
            .where(
              (call) => const {
                'reader.load',
                'reader.select',
                'reader.overview',
              }.contains(call.$1),
            ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('list drag clamps both ends and double click restores 340 once', (
    tester,
  ) async {
    final native = _ForumNative();
    final state = await _mount(tester, native);
    final maxWidth = (tester.getSize(_panes).width - 412 - 9).clamp(
      240.0,
      620.0,
    );
    final gesture = await _startResize(tester, 1500);
    expect(tester.getSize(_list).width, maxWidth);
    expect(native.widthWrites, isEmpty);
    await gesture.moveBy(const Offset(-3000, 0));
    await _frames(tester);
    expect(tester.getSize(_list).width, 240);
    expect(native.widthWrites, isEmpty);
    await gesture.up();
    await _frames(tester);
    expect(native.widthWrites.single, {'key': _listSetting, 'value': 240.0});
    await tester.tap(_divider);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(_divider);
    await _frames(tester);
    expect(tester.getSize(_list).width, 340);
    expect(state.domain('settings')[_listSetting], 340);
    expect(native.widthWrites, hasLength(2));
    expect(native.widthWrites.last, {'key': _listSetting, 'value': 340.0});
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an older save completion cannot move a newer drag under the pointer',
    (tester) async {
      final native = _ForumNative()..deferWidthSaves = true;
      final state = await _mount(tester, native);
      final first = await _startResize(tester, 40);
      final firstWidth = tester.getSize(_list).width.roundToDouble();
      await first.up();
      await _frames(tester);
      expect(native.pendingWidths, hasLength(1));
      final second = await _startResize(tester, 35);
      final preview = tester.getSize(_list).width;
      expect(preview, greaterThan(firstWidth));
      native.completeNextWidth();
      await _frames(tester);
      expect(state.domain('settings')[_listSetting], firstWidth);
      expect(tester.getSize(_list).width, preview);
      expect(native.widthWrites, hasLength(1));
      await second.moveBy(const Offset(15, 0));
      await _frames(tester);
      final newest = tester.getSize(_list).width.roundToDouble();
      expect(newest, greaterThan(preview));
      await second.up();
      await _frames(tester);
      native.completeNextWidth();
      await _frames(tester);
      expect(state.domain('settings')[_listSetting], newest);
      expect(tester.getSize(_list).width, newest);
      expect(native.widthWrites, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'serialized replies do not roll back the latest completed resize',
    (tester) async {
      final native = _ForumNative()..deferWidthSaves = true;
      final state = await _mount(tester, native);
      final first = await _startResize(tester, 35);
      await first.up();
      await _frames(tester);
      final second = await _startResize(tester, 45);
      final newest = tester.getSize(_list).width.roundToDouble();
      await second.up();
      await _frames(tester);
      expect(
        native.widthWrites,
        hasLength(1),
        reason: 'Saves to one key are serialized.',
      );
      expect(tester.getSize(_list).width, newest);
      native.completeNextWidth();
      await _frames(tester);
      expect(native.widthWrites, hasLength(2));
      expect(native.pendingWidths, hasLength(1));
      expect(tester.getSize(_list).width, newest);
      native.completeNextWidth();
      await _frames(tester);
      expect(state.domain('settings')[_listSetting], newest);
      expect(tester.getSize(_list).width, newest);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling a preview restores the saved width and accepts later settings',
    (tester) async {
      final native = _ForumNative();
      final state = await _mount(tester, native);
      final gesture = await _startResize(tester, 75);
      expect(tester.getSize(_list).width, greaterThan(340));
      await gesture.cancel();
      await _frames(tester);
      expect(tester.getSize(_list).width, 340);
      expect(native.widthWrites, isEmpty);
      native.settings = {...native.settings, _listSetting: 480.0};
      await state.act('settings.get', {}, 'settings');
      await _frames(tester);
      expect(tester.getSize(_list).width, 480);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final sidebarWidth in [228.0, 360.0]) {
    testWidgets(
      'adaptive list width preserves 620 and reader position with sidebar $sidebarWidth',
      (tester) async {
        final native = _ForumNative(listWidth: 620, sidebarWidth: sidebarWidth);
        final state = await _mount(tester, native);
        final element = tester.element(find.byType(ReaderScreen));
        final readerState = tester.state(find.byType(ReaderScreen));
        final controller = _readerController(tester);
        await _scrollDown(tester, 300);
        expect(controller.offset, greaterThan(0));
        final mark = _visibleReadingMark(tester);
        expect(mark.floor, '1');
        final available = tester.getSize(_panes).width;
        final threshold = 1380 - available + 780;
        await tester.binding.setSurfaceSize(Size(threshold, 880));
        await _frames(tester);
        expect(tester.getSize(_panes).width, 780);
        expect(_divider, findsOneWidget);
        expect(tester.getSize(_list).width, 359);
        expect(state.domain('settings')[_listSetting], 620);
        expect(native.widthWrites, isEmpty);
        _expectReadingMark(tester, mark);
        for (final width in [threshold - 1, 780.0]) {
          await tester.binding.setSurfaceSize(Size(width, 880));
          await _frames(tester);
          expect(_list, findsNothing);
          expect(_divider, findsNothing);
          expect(_button('收起列表'), findsNothing);
          expect(tester.getRect(_readerPane), tester.getRect(_panes));
          expect(tester.element(find.byType(ReaderScreen)), same(element));
          expect(tester.state(find.byType(ReaderScreen)), same(readerState));
          expect(_readerController(tester), same(controller));
          _expectReadingMark(tester, mark);
          expect(state.domain('settings')[_listSetting], 620);
          expect(native.widthWrites, isEmpty);
          expect(tester.takeException(), isNull);
        }
        await tester.binding.setSurfaceSize(const Size(1380, 880));
        await _frames(tester);
        expect(_divider, findsOneWidget);
        expect(
          tester.getSize(_list).width,
          (available - 412 - 9).clamp(240.0, 620.0),
        );
        expect(tester.element(find.byType(ReaderScreen)), same(element));
        expect(tester.state(find.byType(ReaderScreen)), same(readerState));
        expect(_readerController(tester), same(controller));
        _expectReadingMark(tester, mark);
        expect(native.widthWrites, isEmpty);

        // A prior floor's tail may enter the viewport during the width
        // round trip. Persist the original visible body, not that new tail.
        final saves = native.calls.where(
          (call) =>
              call.$1 == 'reader.rememberPosition' &&
              call.$2['url'] == _topicURL,
        );
        final savesBefore = saves.length;
        await _frames(tester);
        await tester.pump(const Duration(milliseconds: 650));
        await _frames(tester);
        _expectReadingMark(tester, mark);
        expect(saves.length, greaterThan(savesBefore));
        final saved = saves.last.$2;
        final savedBody = jsonMap(saved['bodyAnchor']);
        expect(savedBody['floor'], mark.floor);
        expect(savedBody['dy'], closeTo(_readingMarkDy(tester, mark), 1));
        expect(saved['offset'], closeTo(controller.offset, .5));
        expect(
          controller.offset,
          inInclusiveRange(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'opening search during a list drag discards the preview without saving',
    (tester) async {
      final native = _ForumNative();
      final state = await _mount(tester, native);
      final originalWidth = tester.getSize(_list).width;
      final reader = tester.element(find.byType(ReaderScreen));
      final gesture = await _startResize(tester, 70);
      expect(tester.getSize(_list).width, greaterThan(originalWidth));
      expect(native.widthWrites, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _frames(tester, 12);
      final search = find.byKey(const ValueKey('workspace-search-panel'));
      expect(search, findsOneWidget);
      // The route may already have cancelled the pointer. Releasing it while
      // covered must never commit the interrupted drag in either event order.
      await gesture.up();
      await _frames(tester);
      expect(native.widthWrites, isEmpty);
      expect(state.domain('settings')[_listSetting], originalWidth);

      await tester.tap(_button('取消'));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(tester.getSize(_list).width, originalWidth);
      expect(state.domain('settings')[_listSetting], originalWidth);
      expect(native.widthWrites, isEmpty);
      expect(tester.element(find.byType(ReaderScreen)), same(reader));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shrinking during a drag cancels its preview without persisting a narrow width',
    (tester) async {
      final native = _ForumNative(sidebarWidth: 360);
      final state = await _mount(tester, native);
      final available = tester.getSize(_panes).width;
      final threshold = 1380 - available + 780;
      final gesture = await _startResize(tester, 70);
      expect(tester.getSize(_list).width, greaterThan(340));
      await tester.binding.setSurfaceSize(Size(threshold - 1, 880));
      await _frames(tester);
      expect(_divider, findsNothing);
      await gesture.moveBy(const Offset(20, 0));
      await gesture.up();
      await _frames(tester);
      expect(native.widthWrites, isEmpty);
      await tester.binding.setSurfaceSize(const Size(1380, 880));
      await _frames(tester);
      expect(tester.getSize(_list).width, 340);
      expect(state.domain('settings')[_listSetting], 340);
      native.settings = {...native.settings, _listSetting: 420.0};
      await state.act('settings.get', {}, 'settings');
      await _frames(tester);
      expect(tester.getSize(_list).width, 420);
      expect(native.widthWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account changes retire old pending width without clearing a new resize',
    (tester) async {
      final native = _ForumNative()..deferWidthSaves = true;
      final state = await _mount(tester, native);
      await state.connect();
      await _frames(tester);
      final previousRevision = state.accessRevision;
      final first = await _startResize(tester, 60);
      await first.up();
      await _frames(tester);
      expect(native.pendingWidths, hasLength(1));
      final oldWidth = native.pendingWidths.single.value;
      final oldReply = {...native.settings, _listSetting: oldWidth};
      native.settings = {...native.settings, _listSetting: 280.0};
      // Preferences remain global. A newer snapshot is authoritative; this does
      // not assert that the already issued native write itself was rolled back.
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
          'workspace': native.workspace,
          'reader': native.reader(_topicURL),
        },
      });
      await _frames(tester);
      expect(state.accessRevision, previousRevision + 1);
      expect(state.domain('session')['owner'], 202);
      expect(tester.getSize(_list).width, 280);
      expect(
        find.byKey(ValueKey('topic-column-divider-${previousRevision + 1}')),
        findsOneWidget,
      );
      final current = await _startResize(tester, 45);
      final newest = tester.getSize(_list).width.roundToDouble();
      await current.up();
      await _frames(tester);
      expect(native.widthWrites, hasLength(1));
      native.completeNextWidth(response: oldReply);
      await _frames(tester);
      expect(state.domain('settings')[_listSetting], 280);
      expect(tester.getSize(_list).width, newest);
      expect(native.widthWrites, hasLength(2));
      expect(native.pendingWidths, hasLength(1));
      native.completeNextWidth();
      await _frames(tester);
      expect(state.domain('settings')[_listSetting], newest);
      expect(tester.getSize(_list).width, newest);
      expect(state.accessRevision, previousRevision + 1);
      expect(state.domain('session')['owner'], 202);
      expect(tester.takeException(), isNull);
    },
  );
}
