import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _url = 'https://www.nodeseek.com/post-28101-1';
const _title =
    '阅读栏正在使用时收起列表会改变标题和作者的换行，'
    '已经读到的正文应继续留在原来的屏幕位置';
const _intro =
    'This opening paragraph deliberately wraps into several lines in a narrow '
    'reading column. Expanding the same mounted reader changes the height of '
    'this content above the visible reply, without changing the topic or '
    'performing another reader load.';
const _bodyLabel = 'Live reflow floor one body';
const _author = 73;

String _bodyLabelFor(int floor) =>
    floor == 1 ? _bodyLabel : 'Following reply body $floor';

JsonMap _topic() => {'id': '28101', 'url': _url, 'title': _title};

/// The text-only document, optional delayed author response, and position
/// persistence are all local. No media, network fallback, or forum writes.
class _ReflowNative extends NativeClient {
  _ReflowNative({
    this.floorCount = 14,
    this.longFloor = 1,
    this.rootParagraphs = 1,
    this.shortReplies = false,
    this.wrapLongBody = false,
    bool enrichAuthor = false,
  }) : pendingAuthor = enrichAuthor ? Completer<JsonMap>() : null,
       super(methods: const MethodChannel('seekdesk.test.reader-live-reflow'));

  final int floorCount, longFloor, rootParagraphs;
  final bool shortReplies, wrapLongBody;
  final Completer<JsonMap>? pendingAuthor;
  int authorRequests = 0;
  final saves = <JsonMap>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'reader.rememberPosition' && arguments['url'] == _url) {
      saves.add({...arguments});
      return {'saved': true};
    }
    if (method == 'reader.author' &&
        arguments['url'] == _url &&
        arguments['id'] == _author &&
        pendingAuthor != null) {
      authorRequests++;
      return pendingAuthor!.future;
    }
    if (method == 'settings.update' &&
        arguments['key'] == 'workspace.readingDensity' &&
        const ['compact', 'comfortable'].contains(arguments['value'])) {
      return {
        'workspace.readerTextSize': 15.0,
        'workspace.floorAuthorScale': 100.0,
        'workspace.readingDensity': arguments['value'],
      };
    }
    unexpected.add(method);
    throw StateError('Unexpected live reflow operation: $method');
  }

  JsonMap get snapshot => {
    'url': _url,
    'accessRevision': accessRevision,
    'loading': false,
    'authorProfilesSupported': pendingAuthor != null,
    'scrollOffset': 0.0,
    'thread': {
      'title': _title,
      'category': '技术',
      'page': 1,
      'pages': <JsonMap>[],
      'root': {
        'id': '0',
        if (pendingAuthor != null) 'authorID': _author,
        'author': '具有较长中文姓名的作者 LongAuthorNameForResponsiveReading',
        'date': '2026-11-15 09:37:00 UTC+08:00',
        'tags': ['长期社区贡献者', 'A community role with a complete label'],
        'blocks': [
          for (var paragraph = 0; paragraph < rootParagraphs; paragraph++)
            {'kind': 'text', 'text': _intro},
        ],
      },
      'replies': [
        for (var floor = 1; floor <= floorCount; floor++)
          {
            'id': '$floor',
            'author': floor == longFloor
                ? '第一楼的长作者姓名 AnotherLongAuthorName'
                : 'Following author $floor',
            'date': '2026-11-15 09:38:00 UTC+08:00',
            if (floor == longFloor)
              'tags': ['完整的身份标签', 'Another community role'],
            'blocks': [
              {'kind': 'text', 'text': _bodyLabelFor(floor)},
              if (floor == longFloor)
                // Keep the target body mounted across the minimum live
                // reflow. Deep sliver recycling is exercised separately.
                for (var line = 1; line <= 18; line++)
                  {
                    'kind': 'text',
                    'text': wrapLongBody
                        ? 'Stable target body paragraph $line. $_intro'
                        : 'Stable target body paragraph $line.',
                  }
              else if (!shortReplies)
                {
                  'kind': 'text',
                  'text':
                      'More text keeps the position away from either '
                      'scroll boundary.',
                },
            ],
          },
      ],
    },
  };
}

class _LiveReaderHarness extends StatefulWidget {
  const _LiveReaderHarness({required this.reader, super.key});
  final ReaderScreen reader;

  @override
  State<_LiveReaderHarness> createState() => _LiveReaderHarnessState();
}

class _LiveReaderHarnessState extends State<_LiveReaderHarness> {
  double width = 440;
  double textScale = 1;

  void resize(double value) => setState(() => width = value);
  void scaleText(double value) => setState(() => textScale = value);

  @override
  Widget build(BuildContext context) => CupertinoApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: GlassAccessibilityScope(
        reduceMotion: true,
        child: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, height: 760, child: widget.reader),
          ),
        ),
      ),
    ),
  );
}

Finder get _reader => find.byType(ReaderScreen);
Finder get _scroll =>
    find.descendant(of: _reader, matching: find.byType(CustomScrollView));
Finder get _body => find.text(_bodyLabel, findRichText: true);

Finder _floorContext(int floor, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
      (widget) => widget is ReaderFloorContext && widget.floor.id == '$floor',
      skipOffstage: skipOffstage,
    );

Finder _floorBody(int floor, {bool skipOffstage = true}) => find.descendant(
  of: _floorContext(floor, skipOffstage: skipOffstage),
  matching: find.byType(ForumBlocks, skipOffstage: skipOffstage),
  skipOffstage: skipOffstage,
);

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _Fixture {
  _Fixture(this.native, this.state, this.key, WidgetTester tester)
    : controller = tester.widget<CustomScrollView>(_scroll).controller!,
      readerState = tester.state(_reader),
      readerElement = tester.element(_reader);

  final _ReflowNative native;
  final AppState state;
  final GlobalKey<_LiveReaderHarnessState> key;
  final ScrollController controller;
  final Object readerState;
  final Element readerElement;

  _LiveReaderHarnessState get harness => key.currentState!;

  void expectSameReader(WidgetTester tester) {
    expect(tester.state(_reader), same(readerState));
    expect(tester.element(_reader), same(readerElement));
    expect(
      tester.widget<CustomScrollView>(_scroll).controller,
      same(controller),
    );
    expect(tester.takeException(), isNull);
  }
}

Future<_Fixture> _mount(WidgetTester tester, {_ReflowNative? native}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  final client = native ?? _ReflowNative();
  final state = AppState(client: client)..connecting = false;
  state.domains['workspace'] = {
    'tabs': [_topic()],
    'selectedTab': '28101',
    'showReader': true,
  };
  state.domains['session'] = {'account': 'signedOut'};
  state.domains['settings'] = {
    'workspace.readerTextSize': 15.0,
    'workspace.floorAuthorScale': 100.0,
    'workspace.readingDensity': 'comfortable',
  };
  state.domains['extensions'] = {'items': <JsonMap>[]};
  state.readers[_url] = client.snapshot;
  final key = GlobalKey<_LiveReaderHarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(client.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    _LiveReaderHarness(
      key: key,
      reader: ReaderScreen(state: state, topic: TopicData(_topic())),
    ),
  );
  await _frames(tester);
  return _Fixture(client, state, key, tester);
}

double _bodyDy(WidgetTester tester, int floor) =>
    tester.getTopLeft(_floorBody(floor)).dy - tester.getTopLeft(_scroll).dy;

Future<void> _placeBody(
  WidgetTester tester,
  _Fixture fixture, {
  int floor = 1,
  double dy = 8,
  bool expectSavedAnchor = true,
}) async {
  final controller = fixture.controller;
  for (
    var step = 0;
    _floorBody(floor).evaluate().isEmpty && step < 100;
    step++
  ) {
    final next =
        (controller.offset + controller.position.viewportDimension * .7).clamp(
          0.0,
          controller.position.maxScrollExtent,
        );
    expect(next, greaterThan(controller.offset));
    controller.jumpTo(next);
    await _frames(tester);
  }
  expect(_floorBody(floor), findsOneWidget);
  // Resolve lazy-sliver corrections before capturing the intended position.
  for (var attempt = 0; attempt < 3; attempt++) {
    controller.jumpTo(
      (controller.offset + _bodyDy(tester, floor) - dy).clamp(
        0.0,
        controller.position.maxScrollExtent,
      ),
    );
    await _frames(tester);
  }
  expect(_bodyDy(tester, floor), closeTo(dy, 1));
  expect(controller.offset, greaterThan(0));
  if (expectSavedAnchor) {
    expect(fixture.state.readerBodyAnchor(_url)?.floor, '$floor');
    expect(fixture.state.readerBodyAnchor(_url)?.dy, closeTo(dy, 1));
  }
}

/// Measure public body widgets after the final layout. This deliberately does
/// not use AppState's cached anchor as the expected persistence value.
({String floor, double dy})? _actualVisibleBody(WidgetTester tester) {
  final viewport = tester.getRect(_scroll);
  ({String floor, double dy})? result;
  for (final element in find.byType(ReaderFloorContext).evaluate()) {
    final floor = (element.widget as ReaderFloorContext).floor.id;
    final body = find.descendant(
      of: find.byElementPredicate((candidate) => identical(candidate, element)),
      matching: find.byType(ForumBlocks),
    );
    final box = tester.getRect(body);
    if (!box.isFinite || box.isEmpty) continue;
    if (box.bottom <= viewport.top || box.top >= viewport.bottom) continue;
    final dy = box.top - viewport.top;
    if (result == null || dy < result.dy) result = (floor: floor, dy: dy);
  }
  return result;
}

Future<void> _expectPersistedActual(
  WidgetTester tester,
  _Fixture fixture,
) async {
  await _frames(tester, 6);
  await tester.pump(const Duration(milliseconds: 650));
  await _frames(tester);
  final actualOffset = fixture.controller.offset;
  expect(fixture.native.saves, isNotEmpty);
  final saved = fixture.native.saves.last;
  expect(saved['offset'], closeTo(actualOffset, .5));
  expect(fixture.state.readerOffset(_url), closeTo(actualOffset, .5));
  final actual = _actualVisibleBody(tester);
  final savedAnchor = jsonMap(saved['bodyAnchor']);
  if (actualOffset < 1 || actual == null) {
    expect(savedAnchor, isEmpty);
    expect(fixture.state.readerBodyAnchor(_url), isNull);
  } else {
    expect(savedAnchor['floor'], actual.floor);
    expect(savedAnchor['dy'], closeTo(actual.dy, 1));
    expect(fixture.state.readerBodyAnchor(_url)?.floor, actual.floor);
    expect(fixture.state.readerBodyAnchor(_url)?.dy, closeTo(actual.dy, 1));
  }
  fixture.expectSameReader(tester);
  expect(tester.binding.hasScheduledFrame, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final action in ['scroll', 'width', 'text scale']) {
    testWidgets(
      'offscreen selected reply preserves visible reading anchor during $action',
      (tester) async {
        var clipboard = '';
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = stringValue(jsonMap(call.arguments)['text']);
          } else if (call.method == 'Clipboard.getData') {
            return {'text': clipboard};
          } else if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard.isNotEmpty};
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        Future<void> command(LogicalKeyboardKey key) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await _frames(tester);
        }

        final fixture = await _mount(
          tester,
          native: _ReflowNative(floorCount: 60, longFloor: 30),
        );
        await _placeBody(tester, fixture);
        final firstOffset = fixture.controller.offset;
        final selection = find.descendant(
          of: _floorBody(1, skipOffstage: false),
          matching: find.byType(SelectableRegion, skipOffstage: false),
          skipOffstage: false,
        );
        final original = tester.state<SelectableRegionState>(selection);
        final focus = tester.widget<SelectableRegion>(selection).focusNode!;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (widget) =>
                widget is RichText &&
                widget.text.toPlainText() == _bodyLabelFor(1),
          ),
        );
        final glyph = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 1, extentOffset: 2),
        ).first.toRect();
        await tester.tapAt(paragraph.localToGlobal(glyph.center));
        await command(LogicalKeyboardKey.keyA);
        await command(LogicalKeyboardKey.keyC);
        final selectedText = clipboard;
        expect(selectedText, contains(_bodyLabelFor(1)));
        expect(focus.hasFocus, isTrue);

        await _placeBody(
          tester,
          fixture,
          floor: 30,
          expectSavedAnchor: false,
        );
        expect(original.mounted, isTrue);
        expect(focus.hasFocus, isTrue);
        expect(tester.state<SelectableRegionState>(selection), same(original));
        RenderObject retained = paragraph;
        while (retained.parent is! RenderSliverMultiBoxAdaptor) {
          retained = retained.parent!;
        }
        final sliver = retained.parent! as RenderSliverMultiBoxAdaptor;
        expect(
          (retained.parentData! as SliverMultiBoxAdaptorParentData).keptAlive,
          isTrue,
        );
        expect(sliver.paintsChild(retained as RenderBox), isFalse);
        expect(paragraph.localToGlobal(Offset.zero).dy.isNaN, isTrue);

        if (action == 'scroll') {
          final previous = fixture.controller.offset;
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(_scroll),
              scrollDelta: const Offset(0, 42),
              kind: PointerDeviceKind.mouse,
            ),
          );
          await _frames(tester);
          expect(fixture.controller.offset, closeTo(previous + 42, .5));
          expect(_bodyDy(tester, 30), closeTo(8 - 42, 1));
          await _expectPersistedActual(tester, fixture);
        } else {
          final expectedDy = _bodyDy(tester, 30);
          for (final expanded in [true, false]) {
            if (action == 'width') {
              fixture.harness.resize(expanded ? 900 : 440);
            } else {
              fixture.harness.scaleText(expanded ? 2 : 1);
            }
            await _frames(tester, 8);
            expect(
              fixture.controller.offset,
              lessThan(fixture.controller.position.maxScrollExtent - 100),
            );
            expect(_bodyDy(tester, 30), closeTo(expectedDy, 1));
            await _expectPersistedActual(tester, fixture);
          }
        }
        clipboard = '';
        await command(LogicalKeyboardKey.keyC);
        expect(clipboard, selectedText);
        expect(focus.hasFocus, isTrue);
        fixture.controller.jumpTo(firstOffset);
        await _frames(tester);
        await _placeBody(tester, fixture);
        expect(tester.state<SelectableRegionState>(selection), same(original));
        clipboard = '';
        await command(LogicalKeyboardKey.keyC);
        expect(clipboard, selectedText);
        focus.unfocus();
        await _frames(tester);
        await _placeBody(tester, fixture, floor: 30);
        expect(original.mounted, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'the same mounted reader preserves the visible body through live narrow wide narrow reflow',
    (tester) async {
      final fixture = await _mount(tester);
      await _placeBody(tester, fixture);
      expect(_body.hitTestable(), findsOneWidget);
      expect(
        fixture.controller.offset,
        lessThan(fixture.controller.position.maxScrollExtent - 100),
      );
      final bodyY = tester.getTopLeft(_body).dy;
      final bodyElement = tester.element(_body);

      for (final width in [900.0, 440.0]) {
        fixture.harness.resize(width);
        await _frames(tester, 6);
        expect(tester.getSize(_scroll).width, width);
        fixture.expectSameReader(tester);
        expect(tester.element(_body), same(bodyElement));
        expect(
          tester.getTopLeft(_body).dy,
          closeTo(bodyY, 1),
          reason:
              'Live width $width must preserve the same visible body, '
              'without remounting the reader.',
        );
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '1');
        expect(fixture.state.readerBodyAnchor(_url)?.dy, closeTo(8, 1));
        await _expectPersistedActual(tester, fixture);
      }
    },
  );

  testWidgets(
    'continuous live resize does not accumulate body drift or stale saves',
    (tester) async {
      final fixture = await _mount(tester);
      await _placeBody(tester, fixture);
      final bodyElement = tester.element(_body);
      for (var cycle = 0; cycle < 3; cycle++) {
        for (final width in [900.0, 520.0, 720.0, 440.0, 880.0, 500.0, 660.0]) {
          fixture.harness.resize(width);
          // One layout per width: a prior correction may still be pending
          // when the next width arrives, as during a real divider drag.
          await tester.pump(const Duration(milliseconds: 16));
        }
        fixture.harness.resize(440);
        await _frames(tester, 6);
        expect(_bodyDy(tester, 1), closeTo(8, 1));
        expect(tester.element(_body), same(bodyElement));
        fixture.expectSameReader(tester);
      }
      await _expectPersistedActual(tester, fixture);
    },
  );

  testWidgets(
    'live system text scale preserves the body at twice the original size',
    (tester) async {
      final fixture = await _mount(tester);
      await _placeBody(tester, fixture);
      final originalTextHeight = tester.getSize(_body).height;
      for (final scale in [2.0, 1.0]) {
        fixture.harness.scaleText(scale);
        await _frames(tester, 6);
        expect(
          MediaQuery.textScalerOf(tester.element(_body)).scale(15),
          15 * scale,
        );
        if (scale == 2) {
          expect(
            tester.getSize(_body).height,
            greaterThan(originalTextHeight * 1.8),
          );
        }
        expect(_bodyDy(tester, 1), closeTo(8, 1));
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
      }
    },
  );

  testWidgets(
    'a wheel event after reflow layout cancels the pending body correction',
    (tester) async {
      final fixture = await _mount(tester);
      await _placeBody(tester, fixture);
      final pointerPosition = tester.getCenter(_scroll);
      double? beforeWheel, userOffset;
      // Registered first: dispatch the wheel after layout changes the boxes,
      // before the compensation callback registered by that layout can run.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        beforeWheel = fixture.controller.offset;
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: pointerPosition,
            scrollDelta: const Offset(0, 72),
            kind: PointerDeviceKind.mouse,
          ),
        );
        userOffset = fixture.controller.offset;
      });
      fixture.harness.resize(900);
      await tester.pump();
      expect(userOffset, isNotNull);
      expect(userOffset, closeTo(beforeWheel! + 72, 1));
      await _frames(tester, 8);
      expect(fixture.controller.offset, closeTo(userOffset!, 1));
      expect(_bodyDy(tester, 1), isNot(closeTo(8, 1)));
      await _expectPersistedActual(tester, fixture);
      expect(fixture.controller.offset, closeTo(userOffset!, 1));
    },
  );

  testWidgets(
    'top position stays at zero across live width and text scale changes',
    (tester) async {
      final fixture = await _mount(tester);
      // A user scroll back to the top must retire the previous body anchor.
      fixture.controller.jumpTo(80);
      await _frames(tester);
      fixture.controller.jumpTo(0);
      await _frames(tester);
      for (final geometry in [(900.0, 2.0), (440.0, 2.0), (440.0, 1.0)]) {
        fixture.harness.resize(geometry.$1);
        fixture.harness.scaleText(geometry.$2);
        await _frames(tester, 6);
        expect(fixture.controller.offset, 0);
        expect(fixture.state.readerBodyAnchor(_url), isNull);
        fixture.expectSameReader(tester);
      }
      await _expectPersistedActual(tester, fixture);
    },
  );

  testWidgets(
    'shorter content at the bottom clamps compensation and saves actual layout',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(floorCount: 1, wrapLongBody: true),
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        fixture.controller.jumpTo(fixture.controller.position.maxScrollExtent);
        await _frames(tester);
      }
      final previousDy = _bodyDy(tester, 1);
      final previousExtent = fixture.controller.position.maxScrollExtent;
      expect(previousDy, lessThan(-100));
      fixture.harness.resize(900);
      await _frames(tester, 8);
      expect(
        fixture.controller.position.maxScrollExtent,
        lessThan(previousExtent - 100),
      );
      expect(
        fixture.controller.offset,
        closeTo(fixture.controller.position.maxScrollExtent, 1),
      );
      // Keeping the old negative dy is impossible once the body is shorter;
      // the valid boundary and its actual anchor must replace the old values.
      expect(_bodyDy(tester, 1), greaterThan(previousDy + 100));
      await _expectPersistedActual(tester, fixture);
    },
  );

  testWidgets(
    'live reflow preserves a deep reply after earlier slivers were recycled',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(floorCount: 60, longFloor: 30),
      );
      await _placeBody(tester, fixture);
      expect(_floorContext(1), findsOneWidget);
      await _placeBody(tester, fixture, floor: 30);
      expect(_floorContext(1), findsNothing);
      expect(fixture.controller.offset, greaterThan(3000));
      for (final width in [900.0, 440.0]) {
        fixture.harness.resize(width);
        await _frames(tester, 8);
        expect(_bodyDy(tester, 30), closeTo(8, 1));
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '30');
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
      }
    },
  );

  testWidgets(
    'same-frame author enrichment and live width share one body correction',
    (tester) async {
      const signature =
          'The late author signature adds several complete '
          'lines above the current reply at the same moment that the reading '
          'column widens. Both changes must preserve one original anchor.';
      final native = _ReflowNative(enrichAuthor: true);
      final fixture = await _mount(tester, native: native);
      await _placeBody(tester, fixture);
      expect(native.authorRequests, 1);
      expect(find.text('Lv.7', skipOffstage: false), findsNothing);
      native.pendingAuthor!.complete({
        'profile': {
          'member_id': _author,
          'rank': 7,
          'roles': [
            for (var tag = 1; tag <= 8; tag++)
              {'display_text': 'Complete delayed author role $tag'},
          ],
          'signature_markdown': signature,
        },
        'accessRevision': fixture.state.accessRevision,
      });
      fixture.harness.resize(900);
      await tester.pump();
      expect(tester.getSize(_scroll).width, 900);
      expect(
        find.text(signature, findRichText: true, skipOffstage: false),
        findsOneWidget,
      );
      await _frames(tester, 8);
      expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
      expect(_bodyDy(tester, 1), closeTo(8, 1));
      expect(native.authorRequests, 1);
      await _expectPersistedActual(tester, fixture);
    },
  );

  testWidgets(
    'long root width reflow retains the deep short reply beyond the old cache',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(
          floorCount: 60,
          longFloor: 0,
          rootParagraphs: 18,
          shortReplies: true,
        ),
      );
      await _placeBody(tester, fixture, floor: 30);
      expect(_floorContext(1), findsNothing);
      final target = _floorBody(30);
      expect(tester.widget<ForumBlocks>(target).blocks, hasLength(1));
      expect(tester.getSize(target).height, lessThan(100));
      final viewportHeight = fixture.controller.position.viewportDimension;
      var previousOffset = fixture.controller.offset;

      for (final width in [900.0, 440.0]) {
        fixture.harness.resize(width);
        await _frames(tester, 8);
        // A short target cannot survive a large prefix-height change merely
        // by extending into the old cache, unlike the long-body reproduction.
        expect(target, findsOneWidget);
        expect(tester.widget<ForumBlocks>(target).blocks, hasLength(1));
        expect(
          (fixture.controller.offset - previousOffset).abs(),
          greaterThan(viewportHeight * 2),
          reason:
              'The long root must move this short reply by over two '
              'viewports, beyond the old viewport and adjacent cache.',
        );
        expect(_bodyDy(tester, 30), closeTo(8, 1));
        expect(
          find.text(_bodyLabelFor(30), findRichText: true).hitTestable(),
          findsOneWidget,
        );
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '30');
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
        previousOffset = fixture.controller.offset;
      }
    },
  );

  testWidgets(
    'shrinking and growing system text restores a deep one-line reply',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(
          floorCount: 60,
          longFloor: 0,
          rootParagraphs: 18,
          shortReplies: true,
        ),
      );
      fixture.harness.scaleText(2);
      await _frames(tester, 6);
      await _placeBody(tester, fixture, floor: 30);
      expect(_floorContext(1), findsNothing);
      final target = _floorBody(30);
      final viewportHeight = fixture.controller.position.viewportDimension;
      var previousOffset = fixture.controller.offset;

      for (final scale in [1.0, 2.0]) {
        fixture.harness.scaleText(scale);
        await _frames(tester, 8);
        expect(target, findsOneWidget);
        expect(tester.widget<ForumBlocks>(target).blocks, hasLength(1));
        expect(
          MediaQuery.textScalerOf(tester.element(target)).scale(15),
          15 * scale,
        );
        expect(
          (fixture.controller.offset - previousOffset).abs(),
          greaterThan(viewportHeight * 2),
        );
        expect(_bodyDy(tester, 30), closeTo(8, 1));
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '30');
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
        previousOffset = fixture.controller.offset;
      }
    },
  );

  testWidgets(
    'same-width density changes preserve a short reply and update saved layout',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(floorCount: 60, longFloor: 0, shortReplies: true),
      );
      await _placeBody(tester, fixture, floor: 30);
      final target = _floorBody(30);
      final bodyWidth = tester.getSize(target).width;
      final comfortableDistance =
          tester.getTopLeft(_floorBody(31)).dy - tester.getTopLeft(target).dy;
      final beforeOffset = fixture.controller.offset;

      for (final density in ['compact', 'comfortable']) {
        await fixture.state.act('settings.update', {
          'key': 'workspace.readingDensity',
          'value': density,
        }, 'settings');
        await _frames(tester, 8);
        expect(tester.getSize(_scroll).width, 440);
        expect(target, findsOneWidget);
        expect(tester.getSize(target).width, bodyWidth);
        expect(_bodyDy(tester, 30), closeTo(8, 1));
        final distance =
            tester.getTopLeft(_floorBody(31)).dy - tester.getTopLeft(target).dy;
        expect(
          distance,
          closeTo(comfortableDistance - (density == 'compact' ? 13 : 0), 1),
          reason:
              'The floor spacing must actually change from 27 to 14 '
              'without any width change masking the density-only reflow.',
        );
        if (density == 'compact') {
          expect(fixture.controller.offset, lessThan(beforeOffset - 10));
        }
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '30');
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
      }
    },
  );

  testWidgets(
    'an expanding cached long reply preserves the following short reply',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _ReflowNative(
          floorCount: 60,
          longFloor: 29,
          wrapLongBody: true,
          shortReplies: true,
        ),
      );
      await _placeBody(tester, fixture, floor: 30);
      final target = _floorBody(30);
      // SliverMultiBoxAdaptorElement's onstage visitor deliberately excludes
      // cache-only children. Include mounted offstage elements to distinguish
      // an actual cache tail from a genuinely recycled preceding reply.
      final previousBody = _floorBody(29, skipOffstage: false);
      final viewport = tester.getRect(_scroll);
      expect(_floorContext(1, skipOffstage: false), findsNothing);
      expect(previousBody, findsOneWidget);
      expect(tester.widget<ForumBlocks>(previousBody).blocks, hasLength(19));
      expect(tester.widget<ForumBlocks>(target).blocks, hasLength(1));
      expect(tester.getSize(target).height, lessThan(100));
      final originalLongHeight = tester.getSize(previousBody).height;
      expect(originalLongHeight, greaterThan(viewport.height * 2));
      expect(
        tester.getRect(previousBody).bottom,
        lessThan(viewport.top),
        reason:
            'The long preceding reply must already be above the viewport '
            'while its tail remains mounted in the sliver cache.',
      );

      for (final scale in [2.0, 1.0]) {
        fixture.harness.scaleText(scale);
        await _frames(tester, 8);
        // Correcting only the root-to-replies prefix cannot account for the
        // cached reply 29 growing inside the SliverList. Its short successor
        // must not be lost as trailing garbage before body compensation.
        expect(target, findsOneWidget);
        expect(tester.widget<ForumBlocks>(target).blocks, hasLength(1));
        expect(
          MediaQuery.textScalerOf(tester.element(target)).scale(15),
          15 * scale,
        );
        expect(_bodyDy(tester, 30), closeTo(8, 1));
        expect(
          find.text(_bodyLabelFor(30), findRichText: true).hitTestable(),
          findsOneWidget,
        );
        expect(fixture.state.readerBodyAnchor(_url)?.floor, '30');
        fixture.expectSameReader(tester);
        await _expectPersistedActual(tester, fixture);
      }
    },
  );
}
