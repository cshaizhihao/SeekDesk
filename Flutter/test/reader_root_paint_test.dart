import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/frame_diagnostics.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/editor_header_diagnostics.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _url = 'https://www.nodeseek.com/post-66001-1';
const _title = 'Long root paint fixture';
const _paragraphCount = 64;
const _paragraphPrefix = 'Root paragraph ';
const _replyParagraphCount = 48;

String _replyParagraphPrefix(int floor) => 'Reply $floor paragraph ';

String _paragraphText(int index, [int revision = 0]) =>
    '$_paragraphPrefix${index.toString().padLeft(2, '0')}. '
    '${revision == 0 ? 'Original reading content.' : 'Updated reading content with an extra sentence.'} '
    'A static passage remains clear while the page moves through its long '
    'opening post. Width and font changes must still lay out and paint the '
    'current text, including the part that enters the viewport for the first time.';

String _replyParagraphText(int floor, int index, [int revision = 0]) =>
    '${_replyParagraphPrefix(floor)}${index.toString().padLeft(2, '0')}. '
    '${revision == 0 ? 'Original reply content.' : 'Updated reply content with an extra sentence.'} '
    'This passage belongs to a lazily mounted reply. Scrolling must retain '
    'its clear text while newly revealed passages appear in their first frame. '
    'Content, font and width changes must still paint the current reply.';

JsonMap _topic() => {'id': '66001', 'url': _url, 'title': _title};

/// Seed the real ReaderScreen without network, media, delayed author metadata,
/// or native persistence. Every permitted operation remains in this fixture.
class _PaintNative extends NativeClient {
  _PaintNative({this.withReplies = false})
    : super(methods: const MethodChannel('seekdesk.test.reader-root-paint'));

  final bool withReplies;
  int contentRevision = 0;
  double fontSize = 15;
  final unexpected = <String>[];

  JsonMap get settings => {
    'workspace.readerTextSize': fontSize,
    'workspace.floorAuthorScale': 100.0,
    'workspace.readingDensity': 'comfortable',
  };

  JsonMap get snapshot => {
    'url': _url,
    'accessRevision': accessRevision,
    'authorProfilesSupported': false,
    'loading': false,
    'scrollOffset': 0.0,
    'thread': {
      'title': _title,
      'page': 1,
      'pages': <JsonMap>[],
      'root': {
        'id': '0',
        'author': 'Local root author',
        'avatar': '',
        'date': '2026-11-16 09:00',
        'blocks': [
          for (
            var index = 0;
            index < (withReplies ? 1 : _paragraphCount);
            index++
          )
            {
              'kind': 'text',
              'text': _paragraphText(index, withReplies ? 0 : contentRevision),
            },
        ],
      },
      'replies': <JsonMap>[
        if (withReplies)
          for (var floor = 1; floor <= 3; floor++)
            {
              'id': '$floor',
              'author': 'Local reply author $floor',
              'avatar': '',
              'date': '2026-11-16 09:00',
              'blocks': [
                for (var index = 0; index < _replyParagraphCount; index++)
                  {
                    'kind': 'text',
                    'text': _replyParagraphText(floor, index, contentRevision),
                  },
              ],
            },
      ],
    },
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'reader.rememberPosition' && arguments['url'] == _url) {
      return {'saved': true};
    }
    if (method == 'reader.load' && arguments['url'] == _url) {
      return snapshot;
    }
    if (method == 'settings.update' &&
        arguments['key'] == 'workspace.readerTextSize') {
      fontSize = numberValue(arguments['value'], fontSize);
      return settings;
    }
    unexpected.add(method);
    throw StateError('Unexpected root paint fixture operation: $method');
  }
}

class _ReaderHarness extends StatefulWidget {
  const _ReaderHarness({
    required this.reader,
    required this.capture,
    super.key,
  });

  final ReaderScreen reader;
  final GlobalKey capture;

  @override
  State<_ReaderHarness> createState() => _ReaderHarnessState();
}

class _ReaderHarnessState extends State<_ReaderHarness> {
  double width = 760;

  void resize(double value) => setState(() => width = value);

  @override
  Widget build(BuildContext context) => CupertinoApp(
    theme: const CupertinoThemeData(brightness: Brightness.light),
    home: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: GlassAccessibilityScope(
        reduceMotion: true,
        child: CupertinoPageScaffold(
          backgroundColor: const Color(0xffffffff),
          child: Align(
            alignment: Alignment.topLeft,
            // The capture surface exists from the first mount, outside the
            // real reader viewport. Capturing never adds a boundary to its
            // root floor or changes the scroll subtree under test.
            child: RepaintBoundary(
              key: widget.capture,
              child: ColoredBox(
                color: const Color(0xffffffff),
                child: SizedBox(
                  width: width,
                  height: 720,
                  child: widget.reader,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder get _reader => find.byType(ReaderScreen);
Finder get _scroll =>
    find.descendant(of: _reader, matching: find.byType(CustomScrollView));
Finder get _root => find.byWidgetPredicate(
  (widget) => widget is ReaderFloorContext && widget.root,
);
Finder _paragraph(int index, [int revision = 0]) => find.descendant(
  of: _root,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is RichText &&
        widget.text.toPlainText() == _paragraphText(index, revision),
  ),
);
Finder _reply(int floor) => find.byWidgetPredicate(
  (widget) =>
      widget is ReaderFloorContext && !widget.root && widget.floor.id == '$floor',
);
Finder _replyParagraph(int floor, int index, [int revision = 0]) =>
    find.descendant(
      of: _reply(floor),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText() ==
                _replyParagraphText(floor, index, revision),
      ),
    );

class _Fixture {
  const _Fixture(this.native, this.state, this.harness, this.capture);

  final _PaintNative native;
  final AppState state;
  final GlobalKey<_ReaderHarnessState> harness;
  final GlobalKey capture;

  ScrollController controller(WidgetTester tester) =>
      tester.widget<CustomScrollView>(_scroll).controller!;
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  bool withReplies = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  final native = _PaintNative(withReplies: withReplies);
  final state = AppState(client: native)..connecting = false;
  state.domains['workspace'] = {
    'tabs': [_topic()],
    'selectedTab': '66001',
    'showReader': true,
  };
  state.domains['session'] = {'account': 'signedOut'};
  state.domains['settings'] = native.settings;
  state.domains['extensions'] = {'items': <JsonMap>[]};
  state.readers[_url] = native.snapshot;
  final harness = GlobalKey<_ReaderHarnessState>();
  final capture = GlobalKey();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  // Exactly one first frame. Callers decide when settling is appropriate.
  await tester.pumpWidget(
    _ReaderHarness(
      key: harness,
      capture: capture,
      reader: ReaderScreen(state: state, topic: TopicData(_topic())),
    ),
  );
  return _Fixture(native, state, harness, capture);
}

class _BodyPaints {
  _BodyPaints(this.prefix);

  final String prefix;
  int count = 0;

  void observe(RenderObject object) {
    if (object is RenderParagraph &&
        object.text.toPlainText().startsWith(prefix)) {
      count++;
    }
  }
}

_BodyPaints _observeBodyPaints({String prefix = _paragraphPrefix}) {
  final observations = _BodyPaints(prefix);
  final previous = debugOnProfilePaint;
  debugOnProfilePaint = (object) {
    previous?.call(object);
    observations.observe(object);
  };
  addTearDown(() => debugOnProfilePaint = previous);
  return observations;
}

class _ParagraphPixels {
  const _ParagraphPixels(this.bytes, this.ink);

  final Uint8List bytes;
  final int ink;
}

/// Rasterize the already painted capture layer. No pump, rebuild, new repaint
/// boundary, or markNeedsPaint may repair a missing first frame during capture.
Future<_ParagraphPixels> _captureParagraph(
  WidgetTester tester,
  _Fixture fixture,
  Finder paragraph,
) async {
  final boundary =
      fixture.capture.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  final rect = tester.getRect(paragraph);
  final viewport = tester.getRect(_scroll);
  expect(rect.top, greaterThanOrEqualTo(viewport.top));
  expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
  final origin = boundary.localToGlobal(Offset.zero);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final source = data.buffer.asUint8List();
      final left = (rect.left - origin.dx).ceil().clamp(0, image.width);
      final right = (rect.right - origin.dx).floor().clamp(0, image.width);
      final top = (rect.top - origin.dy).ceil().clamp(0, image.height);
      final bottom = (rect.bottom - origin.dy).floor().clamp(0, image.height);
      final bytes = BytesBuilder();
      var ink = 0;
      for (var y = top; y < bottom; y++) {
        final row = source.sublist(
          (y * image.width + left) * 4,
          (y * image.width + right) * 4,
        );
        bytes.add(row);
        for (var x = 0; x < row.length; x += 4) {
          if (row[x + 3] > 200 &&
              row[x] < 180 &&
              row[x + 1] < 180 &&
              row[x + 2] < 200) {
            ink++;
          }
        }
      }
      return _ParagraphPixels(bytes.takeBytes(), ink);
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> _placeFirstReply(
  WidgetTester tester,
  _Fixture fixture,
) async {
  final target = _replyParagraph(1, 0);
  expect(target, findsOneWidget);
  final controller = fixture.controller(tester);
  final offset =
      controller.offset +
      tester.getTopLeft(target).dy -
      tester.getRect(_scroll).top -
      100;
  controller.jumpTo(offset.roundToDouble());
  await tester.pumpAndSettle();
  final viewport = tester.getRect(_scroll);
  final paragraph = tester.getRect(target);
  expect(paragraph.top, greaterThanOrEqualTo(viewport.top));
  expect(paragraph.bottom, lessThanOrEqualTo(viewport.bottom));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normal builds do not wrap the root for diagnostics', () {
    const child = SizedBox(width: 120, height: 32);
    expect(
      sampleEditorHeader(
        layoutKind: UiWorkKind.readerRootLayout,
        paintKind: UiWorkKind.readerRootPaint,
        child: child,
      ),
      same(child),
    );
  }, skip: FrameDiagnostics.enabled && FrameDiagnostics.rawFrames);

  testWidgets('warm long root retains text paint during vertical scrolling', (
    tester,
  ) async {
    final paints = _observeBodyPaints();
    final fixture = await _mount(tester);
    await tester.pumpAndSettle();
    final controller = fixture.controller(tester);
    final rootElement = tester.element(_root);
    final bodyElement = tester.element(_paragraph(0));
    expect(paints.count, greaterThanOrEqualTo(_paragraphCount));
    expect(tester.getSize(_root).height, greaterThan(4000));
    final perFrame = <int>[];
    for (final offset in [120.0, 240.0, 360.0, 480.0, 360.0, 240.0, 120.0]) {
      final before = paints.count;
      controller.jumpTo(offset);
      await tester.pump();
      perFrame.add(paints.count - before);
      expect(controller.offset, offset);
      expect(tester.element(_root), same(rootElement));
      expect(tester.element(_paragraph(0)), same(bodyElement));
    }
    // Captures the unisolated baseline before the product boundary is added.
    // These counts establish framework paint work, not raster duration or FPS.
    // ignore: avoid_print
    print('rootBodyPaintsPerScrollFrame=$perFrame');
    expect(
      perFrame,
      everyElement(0),
      reason: 'Pure scrolling must retain unchanged root paragraph paint.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'root text is present in its first frame and first visible frame',
    (tester) async {
      final fixture = await _mount(tester);
      final first = await _captureParagraph(tester, fixture, _paragraph(0));
      await tester.pumpAndSettle();
      final stable = await _captureParagraph(tester, fixture, _paragraph(0));
      expect(first.ink, greaterThan(600));
      expect(first.bytes, orderedEquals(stable.bytes));
      final controller = fixture.controller(tester);
      for (final index in [20, 45, 4]) {
        final target = _paragraph(index);
        final viewport = tester.getRect(_scroll);
        expect(tester.getRect(target).overlaps(viewport), isFalse);
        final offset =
            controller.offset +
            tester.getTopLeft(target).dy -
            viewport.top -
            100;
        controller.jumpTo(offset.roundToDouble());
        // One frame only before inspecting the newly visible body pixels.
        await tester.pump();
        final entered = await _captureParagraph(tester, fixture, target);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pumpAndSettle();
        final settled = await _captureParagraph(tester, fixture, target);
        expect(entered.ink, greaterThan(600));
        expect(entered.bytes, orderedEquals(settled.bytes));
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final change in ['content', 'font', 'width']) {
    testWidgets('root paint invalidates when $change changes', (tester) async {
      final paints = _observeBodyPaints();
      final fixture = await _mount(tester);
      await tester.pumpAndSettle();
      final readerElement = tester.element(_reader);
      final rootElement = tester.element(_root);
      final paragraphElement = tester.element(_paragraph(0));
      final originalSize = tester.getSize(_paragraph(0));
      final original = await _captureParagraph(tester, fixture, _paragraph(0));
      final before = paints.count;
      switch (change) {
        case 'content':
          fixture.native.contentRevision++;
          await fixture.state.loadReader(_url, force: true);
        case 'font':
          await fixture.state.act('settings.update', {
            'key': 'workspace.readerTextSize',
            'value': 20.0,
          }, 'settings');
        case 'width':
          fixture.harness.currentState!.resize(440);
      }
      await tester.pump();
      final target = _paragraph(0, fixture.native.contentRevision);
      expect(tester.element(_reader), same(readerElement));
      expect(tester.element(_root), same(rootElement));
      expect(tester.element(target), same(paragraphElement));
      expect(paints.count, greaterThan(before));
      if (change == 'font' || change == 'width') {
        expect(tester.getSize(target).height, greaterThan(originalSize.height));
      }
      final first = await _captureParagraph(tester, fixture, target);
      await tester.pumpAndSettle();
      final stable = await _captureParagraph(tester, fixture, target);
      expect(first.ink, greaterThan(600));
      expect(first.bytes, orderedEquals(stable.bytes));
      expect(first.bytes, isNot(orderedEquals(original.bytes)));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('warm long reply retains text paint during vertical scrolling', (
    tester,
  ) async {
    final paints = _observeBodyPaints(prefix: _replyParagraphPrefix(1));
    final fixture = await _mount(tester, withReplies: true);
    await tester.pumpAndSettle();
    await _placeFirstReply(tester, fixture);
    final controller = fixture.controller(tester);
    final origin = controller.offset;
    final replyElement = tester.element(_reply(1));
    final paragraphElement = tester.element(_replyParagraph(1, 0));
    expect(paints.count, greaterThanOrEqualTo(_replyParagraphCount));
    expect(tester.getSize(_reply(1)).height, greaterThan(4000));
    final perFrame = <int>[];
    for (final delta in [120.0, 240.0, 360.0, 480.0, 360.0, 240.0, 120.0]) {
      final before = paints.count;
      controller.jumpTo(origin + delta);
      await tester.pump();
      perFrame.add(paints.count - before);
      expect(controller.offset, origin + delta);
      expect(tester.element(_reply(1)), same(replyElement));
      expect(tester.element(_replyParagraph(1, 0)), same(paragraphElement));
    }
    // Framework paint observations are distinct from raster duration or FPS.
    // ignore: avoid_print
    print('replyBodyPaintsPerScrollFrame=$perFrame');
    expect(
      perFrame,
      everyElement(0),
      reason: 'Pure scrolling must retain unchanged reply paragraph paint.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cached and newly mounted reply text appears in its first visible frame',
    (tester) async {
      final fixture = await _mount(tester, withReplies: true);
      await tester.pumpAndSettle();
      await _placeFirstReply(tester, fixture);
      final controller = fixture.controller(tester);
      for (final index in [20, 35, 4]) {
        final target = _replyParagraph(1, index);
        final viewport = tester.getRect(_scroll);
        expect(tester.getRect(target).overlaps(viewport), isFalse);
        final offset =
            controller.offset +
            tester.getTopLeft(target).dy -
            viewport.top -
            100;
        controller.jumpTo(offset.roundToDouble());
        await tester.pump();
        final entered = await _captureParagraph(tester, fixture, target);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pumpAndSettle();
        final settled = await _captureParagraph(tester, fixture, target);
        expect(entered.ink, greaterThan(600));
        expect(entered.bytes, orderedEquals(settled.bytes));
      }

      // The next reply is still unmounted. Keep the known first reply's
      // bottom visible so its following sibling enters in this exact frame.
      expect(_reply(2), findsNothing);
      final offset =
          controller.offset +
          tester.getBottomLeft(_reply(1)).dy -
          tester.getRect(_scroll).top -
          100;
      controller.jumpTo(offset.roundToDouble());
      await tester.pump();
      final target = _replyParagraph(2, 0);
      expect(target, findsOneWidget);
      final entered = await _captureParagraph(tester, fixture, target);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();
      final settled = await _captureParagraph(tester, fixture, target);
      expect(entered.ink, greaterThan(600));
      expect(entered.bytes, orderedEquals(settled.bytes));
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['content', 'font', 'width']) {
    testWidgets('reply paint invalidates when $change changes', (tester) async {
      final paints = _observeBodyPaints(prefix: _replyParagraphPrefix(1));
      final fixture = await _mount(tester, withReplies: true);
      await tester.pumpAndSettle();
      await _placeFirstReply(tester, fixture);
      final readerElement = tester.element(_reader);
      final replyElement = tester.element(_reply(1));
      final paragraphElement = tester.element(_replyParagraph(1, 0));
      final originalSize = tester.getSize(_replyParagraph(1, 0));
      final original = await _captureParagraph(
        tester,
        fixture,
        _replyParagraph(1, 0),
      );
      final before = paints.count;
      switch (change) {
        case 'content':
          fixture.native.contentRevision++;
          await fixture.state.loadReader(_url, force: true);
        case 'font':
          await fixture.state.act('settings.update', {
            'key': 'workspace.readerTextSize',
            'value': 20.0,
          }, 'settings');
        case 'width':
          fixture.harness.currentState!.resize(440);
      }
      await tester.pump();
      final target = _replyParagraph(1, 0, fixture.native.contentRevision);
      expect(tester.element(_reader), same(readerElement));
      expect(tester.element(_reply(1)), same(replyElement));
      expect(tester.element(target), same(paragraphElement));
      expect(paints.count, greaterThan(before));
      if (change == 'font' || change == 'width') {
        expect(tester.getSize(target).height, greaterThan(originalSize.height));
      }
      final first = await _captureParagraph(tester, fixture, target);
      await tester.pumpAndSettle();
      final stable = await _captureParagraph(tester, fixture, target);
      expect(first.ink, greaterThan(600));
      expect(first.bytes, orderedEquals(stable.bytes));
      expect(first.bytes, isNot(orderedEquals(original.bytes)));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opt-in root probes report real root layout and paint', (
    tester,
  ) async {
    final records = <Map<String, dynamic>>[];
    await runZoned(
      () async {
        FrameDiagnostics.start();
        try {
          await _mount(tester);
          await tester.pumpAndSettle();
          FrameDiagnostics.report();
          final root = tester.getRect(_root);
          final samples = [
            for (final record in records)
              for (final sample
                  in record['uiWorkSamples'] as List<dynamic>? ?? [])
                if (sample['kind'] == 'readerRootLayout' ||
                    sample['kind'] == 'readerRootPaint')
                  sample as Map<String, dynamic>,
          ];
          expect(
            samples.map((sample) => sample['kind']),
            containsAll(['readerRootLayout', 'readerRootPaint']),
          );
          for (final sample in samples) {
            expect(sample['width'], root.width);
            // The probe surrounds the complete floor including its trailing
            // reaction row and padding, beyond ReaderFloorContext's box.
            expect(sample['height'], greaterThanOrEqualTo(root.height));
            expect(sample['durationMicros'], greaterThanOrEqualTo(0));
            expect(sample['count'], 1);
            expect(sample['frameNumber'], isA<int>());
          }
        } finally {
          FrameDiagnostics.stop();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          if (line.startsWith('{"seekdeskDiagnostics":')) {
            records.add(jsonDecode(line) as Map<String, dynamic>);
          } else {
            parent.print(zone, line);
          }
        },
      ),
    );
    expect(tester.takeException(), isNull);
  }, skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames);
}
