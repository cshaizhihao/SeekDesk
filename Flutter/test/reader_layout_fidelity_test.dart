// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _url = 'https://www.nodeseek.com/post-1701-1';
const _title = 'Reader layout fixture';
const _opening = 'The opening paragraph stays inside the reading column.';

/// No network, images, credentials or forum mutations are available here.
class _LayoutNative extends NativeClient {
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'reader.rememberPosition') {
      return {'saved': true, 'scrollOffset': arguments['offset']};
    }
    throw StateError('Unexpected operation in layout fixture: $method');
  }
}

class _LayoutState extends AppState {
  _LayoutState(String density, int replies) : super(client: _LayoutNative()) {
    connecting = false;
    domains['session'] = {'account': 'signedOut', 'accessRevision': 0};
    domains['settings'] = {'workspace.readingDensity': density};
    domains['extensions'] = {'items': <JsonMap>[]};
    readers[_url] = {
      'url': _url,
      'scrollOffset': 0.0,
      'thread': {
        'title': _title,
        'root': {
          'id': '0',
          'author': 'Opening author',
          'dateLabel': 'Today',
          'blocks': [
            {'kind': 'text', 'text': _opening},
          ],
        },
        'replies': [
          for (var index = 1; index <= replies; index++)
            {
              'id': '$index',
              'author': 'Reply author $index',
              'dateLabel': 'Today',
              'blocks': [
                {'kind': 'text', 'text': 'Reply body $index'},
              ],
            },
        ],
        'pages': [
          for (var page = 1; page <= 3; page++)
            {'number': page, 'url': 'https://www.nodeseek.com/post-1701-$page'},
        ],
      },
    };
  }

  void density(String value) {
    domains['settings'] = {
      ...domain('settings'),
      'workspace.readingDensity': value,
    };
    notifyListeners();
  }
}

Finder get _scroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

Finder _body(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is ForumBlocks &&
      widget.blocks.any((block) => block['text'] == text),
);

Finder get _discussionHeading => find.byWidgetPredicate(
  (widget) =>
      widget is Row &&
      widget.children.any((child) => child is Text && child.data == '回复'),
);

Finder _pagination(String position) =>
    find.byKey(ValueKey('reader-pagination:$position'));

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _withReader(
  WidgetTester tester, {
  required double width,
  required String density,
  required Future<void> Function(_LayoutState state) check,
  int replies = 1,
  double height = 900,
}) async {
  // Keep the desktop wider than the reader. This detects accidentally using
  // MediaQuery's window width instead of the local split-pane constraints.
  await tester.binding.setSurfaceSize(const Size(1500, 1100));
  final state = _LayoutState(density, replies);
  try {
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: width,
                height: height,
                child: ReaderScreen(
                  state: state,
                  topic: TopicData({
                    'id': '1701',
                    'url': _url,
                    'title': _title,
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
    expect(tester.takeException(), isNull);
    await check(state);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    await tester.binding.setSurfaceSize(null);
  }
}

void _expectReadingColumn(WidgetTester tester, double expectedWidth) {
  final viewport = tester.getRect(_scroll);
  final expectedLeft = viewport.left + (viewport.width - expectedWidth) / 2;
  final expectedRight = expectedLeft + expectedWidth;
  final pieces = <String, Finder>{
    'title': find.text(_title),
    'opening body': _body(_opening),
    'discussion heading': _discussionHeading,
    'reply body': _body('Reply body 1'),
    'top pagination': _pagination('top'),
    'bottom pagination': _pagination('bottom'),
  };
  for (final piece in pieces.entries) {
    expect(piece.value, findsOneWidget, reason: piece.key);
    final rect = tester.getRect(piece.value);
    expect(rect.left, closeTo(expectedLeft, .01), reason: '${piece.key} left');
    expect(
      rect.right,
      closeTo(expectedRight, .01),
      reason: '${piece.key} right',
    );
    expect(
      rect.width,
      closeTo(expectedWidth, .01),
      reason: '${piece.key} width',
    );
  }
  for (final position in ['top', 'bottom']) {
    final previousPage = find.descendant(
      of: _pagination(position),
      matching: find.byWidgetPredicate(
        (widget) => widget is DeskButton && widget.label == '上一页',
      ),
    );
    expect(
      tester.getRect(previousPage).left,
      closeTo(expectedLeft, .01),
      reason: '$position pagination actions start on the same reading edge',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Native production design references:
  // Sources/SeekDesk/TopicReader.swift:28: comfortable 860 / compact 960.
  // Sources/SeekDesk/ThreadReader.swift:58: local width < 520 => 22, else 32.
  // Sources/SeekDesk/ThreadReader.swift:85: one centered column contains the
  // title, opening floor, discussion heading, replies and pagination.
  const cases = <(double, String, double)>[
    (1400, 'comfortable', 860),
    (1400, 'compact', 960),
    (1000, 'comfortable', 860),
    (1000, 'compact', 936),
    (480, 'comfortable', 436),
    (480, 'compact', 436),
    (519, 'comfortable', 475),
    (519, 'compact', 475),
    (520, 'comfortable', 456),
    (520, 'compact', 456),
  ];
  for (final (width, density, expectedWidth) in cases) {
    testWidgets(
      '$density reader at $width aligns title, body, replies and pagination to $expectedWidth',
      (tester) async {
        await _withReader(
          tester,
          width: width,
          density: density,
          check: (_) async => _expectReadingColumn(tester, expectedWidth),
        );
      },
    );
  }

  testWidgets('changing density resizes the existing reading column', (
    tester,
  ) async {
    await _withReader(
      tester,
      width: 1400,
      density: 'comfortable',
      check: (state) async {
        final controller = tester.widget<CustomScrollView>(_scroll).controller;
        _expectReadingColumn(tester, 860);
        state.density('compact');
        await _frames(tester);
        _expectReadingColumn(tester, 960);
        expect(
          tester.widget<CustomScrollView>(_scroll).controller,
          same(controller),
        );
        state.density('comfortable');
        await _frames(tester);
        _expectReadingColumn(tester, 860);
        expect(
          tester.widget<CustomScrollView>(_scroll).controller,
          same(controller),
        );
      },
    );
  });

  testWidgets('constraining the reading column keeps long replies lazy', (
    tester,
  ) async {
    await _withReader(
      tester,
      width: 1400,
      height: 600,
      density: 'comfortable',
      replies: 80,
      check: (_) async {
        expect(
          find.byWidgetPredicate((widget) => widget is SliverList),
          findsOneWidget,
        );
        expect(_body('Reply body 1'), findsOneWidget);
        expect(_body('Reply body 80'), findsNothing);
        final controller = tester.widget<CustomScrollView>(_scroll).controller!;
        controller.jumpTo(1200);
        await _frames(tester);
        expect(controller.offset, closeTo(1200, .01));
        expect(_body('Reply body 80'), findsNothing);
        expect(find.byType(ForumBlocks).evaluate().length, lessThan(20));
      },
    );
  });
}
