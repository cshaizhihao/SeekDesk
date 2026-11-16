import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/reader_content_layout.dart';

const _firstURL = 'https://images.example/content-layout-a.png';
const _secondURL = 'https://images.example/content-layout-b.png';
const _leafKey = ValueKey('content-layout-image');
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _Read {
  _Read(this.arguments);
  final JsonMap arguments;
  final response = Completer<JsonMap>();
}

class _Native extends NativeClient {
  _Native() : super(methods: MethodChannel('seekdesk.test.content.${_next++}'));
  static int _next = 0;
  final reads = <_Read>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    if (method != 'images.load' || arguments['kind'] != 'post') {
      unexpected.add('$method $arguments');
      throw StateError('Unexpected content-layout fixture operation: $method');
    }
    final read = _Read({...arguments, 'accessRevision': accessRevision});
    reads.add(read);
    return read.response.future;
  }

  void complete(int index, {int width = 1000, int height = 6000}) {
    reads[index].response.complete({
      'bytes': _pixel,
      'width': width,
      'height': height,
      'originalWidth': width,
      'originalHeight': height,
    });
  }
}

class _Fixture {
  final native = _Native();
  late final state = AppState(client: native);
  late final layout = ReaderContentLayoutController(
    preserveAnchor: () => prepare(),
    onGeometryResolved: () => geometryResolutions++,
  );
  VoidCallback Function() prepare = () => () {};
  int geometryResolutions = 0;
}

Future<void> _frames(WidgetTester tester, [int count = 3]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<_Fixture> _fixture(WidgetTester tester) async {
  final f = _Fixture();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 900);
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.layout.dispose();
    f.state.dispose();
    for (final read in f.native.reads) {
      if (!read.response.isCompleted) {
        read.response.complete({'bytes': _pixel, 'width': 1, 'height': 1});
      }
    }
    await _frames(tester);
    await tester.binding.setSurfaceSize(null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    expect(f.native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  return f;
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture f,
  Widget child, {
  double? viewport = 600,
}) async {
  Widget content = ReaderContentFloor(floorID: '7', child: child);
  if (viewport != null) {
    content = ReaderContentLayoutScope(
      controller: f.layout,
      viewportHeight: viewport,
      child: content,
    );
  }
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(
          child: SingleChildScrollView(child: content),
        ),
      ),
    ),
  );
  await _frames(tester);
}

Widget _image(
  AppState state, {
  String url = _firstURL,
  JsonMap size = const {},
  String kind = 'nq',
}) => NativeForumImage(
  key: _leafKey,
  state: state,
  url: url,
  size: size,
  reportKind: kind,
);

double _imageHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(_leafKey)).height;

void _expectImageGeometry(
  WidgetTester tester,
  _Fixture fixture, {
  required bool unresolved,
}) {
  expect(
    tester
        .widget<ReaderContentGeometry>(find.byType(ReaderContentGeometry))
        .unresolved,
    unresolved,
  );
  expect(fixture.layout.hasUnresolvedGeometry('7'), unresolved);
  expect(fixture.layout.hasUnresolvedGeometry('another-floor'), false);
}

Finder _text(String value) => find.text(value, findRichText: true);

void _testMac(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  test('TQ default fits short positive viewports and preserves its normal baseline', () {
    for (final viewport in [185.0, 80.0, 1.0, .25]) {
      for (final natural in [const Size(1000, 1000), const Size(1000, 6000)]) {
        final rendered = ReportImageGeometry.size(
          natural,
          available: 900,
          kind: 'tq',
          viewportHeight: viewport,
        );
        expect(rendered.height, closeTo(viewport, .000001));
        expect(rendered.height, lessThanOrEqualTo(viewport));
        expect(
          rendered.width / rendered.height,
          closeTo(natural.width / natural.height, .000001),
        );
      }
    }
    expect(
      ReportImageGeometry.size(
        const Size(1000, 1000),
        available: 900,
        kind: 'tq',
        viewportHeight: 600,
      ),
      const Size(577.5, 577.5),
    );
    expect(
      ReportImageGeometry.size(
        const Size(1000, 1000),
        available: 900,
        kind: 'tq',
        viewportHeight: 900,
      ),
      const Size(770, 770),
    );
    expect(
      ReportImageGeometry.size(
        const Size(1000, 1000),
        available: 100,
        kind: 'tq',
        viewportHeight: 185,
      ),
      const Size(100, 100),
    );
  });

  test(
    'TQ user zoom can exceed a short viewport without changing NQ full height',
    () {
      for (final entry in [
        (50.0, 92.5),
        (100.0, 185.0),
        (150.0, 277.5),
        (200.0, 370.0),
      ]) {
        final tq = ReportImageGeometry.size(
          const Size(1000, 1000),
          available: 900,
          kind: 'tq',
          viewportHeight: 185,
          percentage: entry.$1,
        );
        expect(tq.width, closeTo(entry.$2, .000001));
        expect(tq.height, closeTo(entry.$2, .000001));
      }
      for (final viewport in [185.0, 80.0, .25, double.nan]) {
        expect(
          ReportImageGeometry.size(
            const Size(1000, 6000),
            available: 900,
            kind: 'nq',
            viewportHeight: viewport,
          ),
          const Size(640, 3840),
        );
      }
    },
  );

  test('invalid TQ viewport heights use a finite positive fallback', () {
    for (final viewport in [
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      final rendered = ReportImageGeometry.size(
        const Size(1000, 1000),
        available: 900,
        kind: 'tq',
        viewportHeight: viewport,
      );
      expect(rendered.width.isFinite && rendered.height.isFinite, true);
      expect(rendered.width, greaterThan(0));
      expect(rendered.height, closeTo(693, .000001));
    }
  });

  for (final kind in ['image', 'sticker', 'terminal']) {
    _testMac(
      'nested $kind registers variable media only while its tab is mounted',
      (tester) async {
        final f = await _fixture(tester);
        await _mount(
          tester,
          f,
          ForumBlocks(
            state: f.state,
            blocks: [
              {
                'kind': 'tabs',
                'tabs': [
                  {
                    'label': 'Media',
                    'blocks': [
                      {
                        'kind': kind,
                        'url': _firstURL,
                        'imageSize': {'width': 100, 'height': 60},
                        'terminal': [
                          [
                            {'text': 'NQ fixture line'},
                          ],
                        ],
                      },
                    ],
                  },
                  {
                    'label': 'Text',
                    'blocks': [
                      {'kind': 'text', 'text': 'Plain replacement'},
                    ],
                  },
                ],
              },
            ],
          ),
        );
        expect(f.layout.hasVariableMedia('7'), true);
        expect(f.layout.hasVariableMedia('another-floor'), false);
        tester
            .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
            .onSegmentSelected(1);
        await _frames(tester);
        expect(_text('Plain replacement'), findsOneWidget);
        expect(
          f.layout.hasVariableMedia('7'),
          false,
          reason: 'Retired tab media must not change the anchoring policy for its text-only successor.',
        );
        expect(f.native.reads, hasLength(kind == 'terminal' ? 0 : 1));
      },
    );
  }

  _testMac(
    'late image dimensions capture the old layout before the new height is installed',
    (tester) async {
      final f = await _fixture(tester);
      final before = <double>[], after = <double>[];
      f.prepare = () {
        before.add(_imageHeight(tester));
        return () => after.add(_imageHeight(tester));
      };
      await _mount(tester, f, _image(f.state));
      expect(_imageHeight(tester), 120);
      _expectImageGeometry(tester, f, unresolved: true);
      expect(f.geometryResolutions, 0);
      final geometry = tester.element(find.byType(ReaderContentGeometry));
      expect(
        before,
        isEmpty,
        reason: 'The first placeholder is not a geometry replacement.',
      );
      f.native.complete(0);
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: false);
      expect(f.geometryResolutions, 1);
      expect(
        identical(geometry, tester.element(find.byType(ReaderContentGeometry))),
        true,
        reason: 'The mounted request resolves its existing geometry owner.',
      );
      expect(before, [120]);
      expect(after, [3840]);
      expect(
        _imageHeight(tester),
        3840,
        reason: 'The long NQ report keeps its full accepted aspect ratio.',
      );
      await _mount(tester, f, _image(f.state));
      _expectImageGeometry(tester, f, unresolved: false);
      expect(f.geometryResolutions, 1);
      expect(before, [
        120,
      ], reason: 'An unchanged rebuild must not begin another correction.');
      expect(f.native.reads, hasLength(1));
    },
  );

  _testMac(
    'unknown image error stays unresolved and retry owns a new geometry registration',
    (tester) async {
      final f = await _fixture(tester);
      await _mount(tester, f, _image(f.state));
      final failedGeometry = tester.element(find.byType(ReaderContentGeometry));
      _expectImageGeometry(tester, f, unresolved: true);
      f.native.reads.single.response.completeError(
        StateError('Fixture image unavailable'),
      );
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: true);
      expect(f.geometryResolutions, 0);
      expect(_imageHeight(tester), 120);
      expect(find.text('图片加载失败，点按重试'), findsOneWidget);
      expect(
        identical(
          failedGeometry,
          tester.element(find.byType(ReaderContentGeometry)),
        ),
        true,
        reason: 'Failure must retain the unresolved owner until retry.',
      );
      await tester.tap(find.text('图片加载失败，点按重试'));
      await _frames(tester);
      expect(f.native.reads, hasLength(2));
      expect(failedGeometry.mounted, false);
      _expectImageGeometry(tester, f, unresolved: true);
      expect(f.geometryResolutions, 0);
      f.native.complete(1);
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: false);
      expect(f.geometryResolutions, 1);
      expect(_imageHeight(tester), 3840);
    },
  );

  _testMac(
    'retired source completion cannot resolve the replacement image geometry',
    (tester) async {
      final f = await _fixture(tester);
      await _mount(tester, f, _image(f.state));
      final retiredGeometry = tester.element(
        find.byType(ReaderContentGeometry),
      );
      await _mount(tester, f, _image(f.state, url: _secondURL));
      final replacementGeometry = tester.element(
        find.byType(ReaderContentGeometry),
      );
      expect(retiredGeometry.mounted, false);
      _expectImageGeometry(tester, f, unresolved: true);
      expect(f.geometryResolutions, 0);
      expect(f.native.reads, hasLength(2));
      f.native.complete(0);
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: true);
      expect(f.geometryResolutions, 0);
      expect(_imageHeight(tester), 120);
      expect(
        identical(
          replacementGeometry,
          tester.element(find.byType(ReaderContentGeometry)),
        ),
        true,
      );
      f.native.complete(1, height: 3000);
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: false);
      expect(f.geometryResolutions, 1);
      expect(_imageHeight(tester), 1920);
    },
  );

  _testMac(
    'known dimensions are resolved while loading and remain resolved on failure',
    (tester) async {
      final f = await _fixture(tester);
      await _mount(
        tester,
        f,
        _image(f.state, size: const {'width': 1000, 'height': 6000}),
      );
      _expectImageGeometry(tester, f, unresolved: false);
      expect(_imageHeight(tester), 3840);
      f.native.reads.single.response.completeError(
        StateError('Fixture known-size image unavailable'),
      );
      await _frames(tester);
      _expectImageGeometry(tester, f, unresolved: false);
      expect(f.geometryResolutions, 0);
      expect(_imageHeight(tester), 3840);
      expect(find.text('图片加载失败，点按重试'), findsOneWidget);
    },
  );

  _testMac(
    'known NQ image dimensions neither change height nor request a correction on completion',
    (tester) async {
      final f = await _fixture(tester);
      var captures = 0;
      f.prepare = () {
        captures++;
        return () {};
      };
      await _mount(
        tester,
        f,
        _image(f.state, size: const {'width': 1000, 'height': 6000}),
      );
      expect(_imageHeight(tester), 3840);
      f.native.complete(0);
      await _frames(tester);
      expect(_imageHeight(tester), 3840);
      expect(captures, 0);
    },
  );

  for (final sourceChange in ['URL', 'revision', 'AppState']) {
    _testMac(
      'same-key $sourceChange replacement resets its own previous image geometry',
      (tester) async {
        final f = await _fixture(tester);
        await _mount(tester, f, _image(f.state));
        f.native.complete(0);
        await _frames(tester);
        expect(_imageHeight(tester), 3840);
        final before = <double>[];
        f.prepare = () {
          before.add(_imageHeight(tester));
          return () {};
        };
        var state = f.state;
        var native = f.native;
        var url = _firstURL;
        if (sourceChange == 'URL') {
          url = _secondURL;
        } else if (sourceChange == 'revision') {
          f.native.accessRevision++;
        } else {
          final replacement = await _fixture(tester);
          state = replacement.state;
          native = replacement.native;
        }
        await _mount(tester, f, _image(state, url: url));
        expect(_imageHeight(tester), 120);
        expect(
          before,
          isEmpty,
          reason: 'Different source ownership cannot compensate from the retired image height.',
        );
        native.complete(native.reads.length - 1, height: 3000);
        await _frames(tester);
        expect(before, [120]);
        expect(_imageHeight(tester), 1920);
      },
    );
  }

  _testMac(
    'TQ follows the scoped reader height while NQ keeps its full long-image height',
    (tester) async {
      final f = await _fixture(tester);
      Widget image() => _image(
        f.state,
        kind: 'tq',
        size: const {'width': 1000, 'height': 1000},
      );
      await _mount(tester, f, image(), viewport: 600);
      expect(
        MediaQuery.sizeOf(tester.element(find.byKey(_leafKey))).height,
        900,
      );
      expect(_imageHeight(tester), closeTo(577.5, .001));
      await _mount(tester, f, image(), viewport: 320);
      expect(
        MediaQuery.sizeOf(tester.element(find.byKey(_leafKey))).height,
        900,
      );
      expect(_imageHeight(tester), closeTo(308, .001));
      for (final height in [185.0, 80.0]) {
        await _mount(tester, f, image(), viewport: height);
        expect(
          MediaQuery.sizeOf(tester.element(find.byKey(_leafKey))).height,
          900,
        );
        expect(
          _imageHeight(tester),
          closeTo(height, .001),
          reason:
              'The window remains tall while the actual reading pane shrinks.',
        );
      }
      await _mount(
        tester,
        f,
        _image(f.state, size: const {'width': 1000, 'height': 6000}),
        viewport: 320,
      );
      expect(_imageHeight(tester), 3840);
      await _mount(
        tester,
        f,
        _image(f.state, size: const {'width': 1000, 'height': 6000}),
        viewport: 600,
      );
      expect(_imageHeight(tester), 3840);
      expect(f.native.reads, hasLength(1));
    },
  );

  _testMac('a TQ image outside a reader retains the window-height fallback', (
    tester,
  ) async {
    final f = await _fixture(tester);
    await _mount(
      tester,
      f,
      _image(f.state, kind: 'tq', size: const {'width': 1000, 'height': 1000}),
      viewport: null,
    );
    expect(_imageHeight(tester), closeTo(770, .001));
  });

  _testMac(
    'disclosure and report tabs prepare before mutation and register only visible nested leaves',
    (tester) async {
      final f = await _fixture(tester);
      final before = <double>[], after = <double>[];
      f.prepare = () {
        before.add(tester.getTopLeft(_text('Following text')).dy);
        return () => after.add(tester.getTopLeft(_text('Following text')).dy);
      };
      await _mount(
        tester,
        f,
        ForumBlocks(
          state: f.state,
          blocks: const [
            {
              'kind': 'tabs',
              'tabs': [
                {
                  'label': 'One',
                  'blocks': [
                    {'kind': 'text', 'text': 'First tab body'},
                  ],
                },
                {
                  'label': 'Two',
                  'blocks': [
                    {'kind': 'text', 'text': 'Second tab body'},
                    {'kind': 'text', 'text': 'Extra tab paragraph'},
                  ],
                },
              ],
            },
            {
              'kind': 'disclosure',
              'text': 'Expand fixture',
              'blocks': [
                {'kind': 'text', 'text': 'Nested disclosure body'},
              ],
            },
            {'kind': 'text', 'text': 'Following text'},
          ],
        ),
      );
      expect(before, isEmpty);
      ReaderContentPoint pointAt(String text) {
        final rect = tester.getRect(_text(text));
        return f.layout.capture(
          floorID: '7',
          top: rect.top + 1,
          bottom: rect.bottom,
        )!;
      }

      void expectLeafFor(ReaderContentPoint point, String text) {
        final resolved = point.resolve();
        expect(resolved, isNotNull);
        final box = resolved!.box;
        final leaf = box.localToGlobal(Offset.zero) & box.size;
        final passage = tester.getRect(_text(text));
        expect(leaf.top, closeTo(passage.top, .01));
        expect(
          leaf.bottom,
          closeTo(passage.bottom, .01),
          reason: 'The point must belong to this leaf, not its whole tabs/disclosure container.',
        );
        final sample = box.localToGlobal(Offset(0, resolved.localDy));
        expect(sample.dy, inInclusiveRange(passage.top, passage.bottom));
      }

      final firstPoint = pointAt('First tab body');
      expectLeafFor(firstPoint, 'First tab body');
      final segments = tester.widget<GlassSegmentedControl>(
        find.byType(GlassSegmentedControl),
      );
      final originalY = tester.getTopLeft(_text('Following text')).dy;
      segments.onSegmentSelected(0);
      await _frames(tester);
      expect(
        before,
        isEmpty,
        reason: 'Reselecting the active tab does not change layout.',
      );
      segments.onSegmentSelected(1);
      expect(before, [originalY]);
      await _frames(tester);
      expect(after.single, greaterThan(originalY));
      expect(
        firstPoint.resolve(),
        isNull,
        reason: 'A hidden tab cannot remain a live content anchor.',
      );
      expectLeafFor(pointAt('Extra tab paragraph'), 'Extra tab paragraph');
      final beforeOpen = tester.getTopLeft(_text('Following text')).dy;
      await tester.tap(_text('Expand fixture'));
      expect(before.last, beforeOpen);
      await _frames(tester);
      expect(after.last, greaterThan(beforeOpen));
      final nested = pointAt('Nested disclosure body');
      expectLeafFor(nested, 'Nested disclosure body');
      final beforeClose = tester.getTopLeft(_text('Following text')).dy;
      await tester.tap(_text('Expand fixture'));
      expect(before.last, beforeClose);
      await _frames(tester);
      expect(after.last, closeTo(beforeOpen, .001));
      expect(nested.resolve(), isNull);
      expect(before, hasLength(3));
      expect(after, hasLength(3));
      expect(f.native.reads, isEmpty);
    },
  );
}
