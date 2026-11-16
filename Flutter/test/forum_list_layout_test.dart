import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/floor_reply.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_content_layout.dart';

class _ListNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final image = Completer<JsonMap>();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'external.open' || method == 'images.release') return {};
    if (method == 'images.load') return image.future;
    throw StateError('Unexpected list fixture operation: $method');
  }
}

final _fixtures = jsonItems(
  jsonDecode(File('../Tests/Fixtures/forum-lists.json').readAsStringSync()),
);

Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

Offset _point(WidgetTester tester, String text) {
  final render = tester.renderObject<RenderParagraph>(_paragraph(text));
  final box = render
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .first;
  return render.localToGlobal(box.toRect().center);
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  double width = 760,
  double scale = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  for (final fixture in _fixtures.where((item) => item['media'] != true)) {
    testWidgets('list DTO renders ${fixture['name']}', (tester) async {
      final native = _ListNative();
      final state = AppState(client: native);
      await _mount(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ForumBlocks(state: state, blocks: jsonItems(fixture['blocks'])),
            if (fixture['signatureMarkdown'] != null)
              InlineMarkdown(
                state: state,
                text: stringValue(fixture['signatureMarkdown']),
                style: const TextStyle(fontSize: 15),
              ),
          ],
        ),
      );
      if (fixture['disclosure'] != null) {
        await tester.tap(find.text(stringValue(fixture['disclosure'])));
        await tester.pumpAndSettle();
      }
      for (final text in fixture['visible'] as List) {
        expect(_paragraph(text as String), findsOneWidget);
      }
      if (fixture['signatureVisible'] != null) {
        expect(
          _paragraph(fixture['signatureVisible'] as String),
          findsOneWidget,
        );
      }
      if (fixture['link'] != null) {
        await tester.tapAt(_point(tester, (fixture['visible'] as List).single));
        await tester.pump();
        expect(native.calls, hasLength(1));
        expect(native.calls.single.$1, 'external.open');
        expect(native.calls.single.$2, {'url': fixture['link']});
      } else {
        expect(native.calls, isEmpty);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets(
    'markers share the first line and paragraphs keep hanging alignment',
    (tester) async {
      final state = AppState(client: _ListNative());
      await _mount(
        tester,
        ForumBlocks(state: state, blocks: jsonItems(_fixtures[0]['blocks'])),
      );
      final markers = _paragraph('• ');
      expect(markers, findsNWidgets(3));
      for (final entry in [(0, 'Direct'), (1, 'Wrapped'), (2, 'Div wrapped')]) {
        expect(
          tester.getTopLeft(markers.at(entry.$1)).dy,
          closeTo(tester.getTopLeft(_paragraph(entry.$2)).dy, .01),
        );
      }
      expect(
        tester.getTopLeft(_paragraph('Wrapped')).dy -
            tester.getBottomLeft(_paragraph('Direct')).dy,
        closeTo(8, .01),
      );
      expect(
        tester.getTopLeft(_paragraph('Continuation')).dx,
        tester.getTopLeft(_paragraph('Wrapped')).dx,
      );
      expect(find.byType(SelectableRegion), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'nested list indentation returns to its parent and copies in reading order',
    (tester) async {
      final native = _ListNative();
      final state = AppState(client: native);
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = stringValue(jsonMap(call.arguments)['text']);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _mount(
        tester,
        ForumBlocks(state: state, blocks: jsonItems(_fixtures[1]['blocks'])),
      );
      double x(String text) => tester.getTopLeft(_paragraph(text)).dx;
      expect(x('Inner first'), greaterThan(x('Parent')));
      expect(x('Deep child'), greaterThan(x('Inner first')));
      expect(x('Parent continuation'), x('Parent'));
      expect(x('Sibling'), x('Parent'));
      await tester.tapAt(_point(tester, 'Parent'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(clipboard, contains('• Parent'));
      expect(clipboard, contains('3. Inner first'));
      expect(clipboard, contains('• Deep child'));
      expect(clipboard, contains('4. Inner second'));
      expect(
        clipboard.indexOf('Deep child'),
        lessThan(clipboard.indexOf('Inner second')),
      );
      expect(
        clipboard.indexOf('Inner second'),
        lessThan(clipboard.indexOf('Parent continuation')),
      );
      expect(
        clipboard.indexOf('Parent continuation'),
        lessThan(clipboard.indexOf('Sibling')),
      );
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'narrow columns large fonts and wide numbers fit without clipping content',
    (tester) async {
      final state = AppState(client: _ListNative());
      const long =
          'A long list paragraph wraps within its content column and keeps every word available to read';
      await _mount(
        tester,
        ForumBlocks(
          state: state,
          fontSize: 20,
          blocks: const [
            {
              'kind': 'list',
              'items': [
                {
                  'marker': '999999.',
                  'blocks': [
                    {'kind': 'text', 'text': long},
                  ],
                },
                {
                  'marker': '1000000.',
                  'blocks': [
                    {'kind': 'text', 'text': 'Following item'},
                  ],
                },
              ],
            },
          ],
        ),
        width: 320,
        scale: 1.5,
      );
      expect(tester.getSize(_paragraph(long)).height, greaterThan(52.5));
      expect(tester.getRect(_paragraph(long)).right, lessThanOrEqualTo(320));
      expect(
        tester.getTopLeft(_paragraph(long)).dx,
        tester.getTopLeft(_paragraph('Following item')).dx,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'media first item has no blank marker row and registers media leaves',
    (tester) async {
      final native = _ListNative();
      final state = AppState(client: native);
      final layout = ReaderContentLayoutController(preserveAnchor: () => () {});
      addTearDown(layout.dispose);
      await _mount(
        tester,
        ReaderContentLayoutScope(
          controller: layout,
          viewportHeight: 1000,
          child: ReaderContentFloor(
            floorID: '0',
            child: ForumBlocks(
              state: state,
              blocks: jsonItems(_fixtures[7]['blocks']),
            ),
          ),
        ),
        settle: false,
      );
      expect(
        tester.getTopLeft(find.byType(NativeForumImage)).dy,
        tester.getTopLeft(_paragraph('• ').first).dy,
      );
      expect(layout.hasVariableMedia('0'), isTrue);
      expect(_paragraph('Image caption'), findsOneWidget);
      expect(_paragraph('<tag> &quot;'), findsOneWidget);
      expect(_paragraph('Cell'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      native.image.complete({});
      await tester.pump();
      state.dispose();
    },
  );

  testWidgets(
    'nested terminal uses its own scaling controls without duplicate image controls',
    (tester) async {
      final state = AppState(client: _ListNative());
      await _mount(
        tester,
        ForumBlocks(
          state: state,
          blocks: jsonItems(
            _fixtures.firstWhere(
              (item) =>
                  item['name'] ==
                  'terminal report survives list and tab nesting',
            )['blocks'],
          ),
        ),
      );
      expect(find.byType(NativeTerminalReport), findsOneWidget);
      final smaller = find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '缩小报告',
      );
      expect(smaller, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NativeTerminalReport),
          matching: smaller,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  test(
    'nested list quotation keeps markers continuation and excerpt limits',
    () {
      String quote(List<JsonMap> blocks) => floorReplyInsertion(
        FloorData({'id': '0', 'author': 'A', 'blocks': blocks}),
        'https://www.nodeseek.com/post-101-1',
        quoting: true,
        after: '',
      )!;
      expect(
        quote(jsonItems(_fixtures[1]['blocks'])),
        contains(
          '> • Parent\n>   3. Inner first\n>      • Deep child\n>   4. Inner second\n>   Parent continuation\n> • Sibling',
        ),
      );
      expect(
        quote(jsonItems(_fixtures[7]['blocks'])),
        contains('> • [图片]\n>   Image caption'),
      );
      final many = quote([
        {
          'kind': 'list',
          'items': [
            for (var i = 0; i < 100; i++)
              {
                'marker': '${i + 1}.',
                'blocks': [
                  {'kind': 'text', 'text': 'entry $i'},
                ],
              },
          ],
        },
      ]);
      expect(many, contains('entry 18'));
      expect(many, isNot(contains('entry 19')));
      var deep = <JsonMap>[
        {'kind': 'text', 'text': 'beyond budget'},
      ];
      for (var i = 0; i < 100; i++) {
        deep = [
          {
            'kind': 'list',
            'items': [
              {'marker': '•', 'blocks': deep},
            ],
          },
        ];
      }
      expect(quote(deep), isNot(contains('beyond budget')));
    },
  );
}
