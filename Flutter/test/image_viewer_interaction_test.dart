import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/image_viewer_toolbar.dart';

const _url = 'https://images.example/viewer-interaction.png';
const _viewportKey = ValueKey('image-viewer-viewport');
const _pictureKey = ValueKey('image-viewer-picture');
const _heroTag = 'interaction-image-source';

// A locally generated, valid 160 × 100 PNG. All loads stay in memory.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAABkCAYAAAABtjuPAAABGUlEQVR4nO3SIQEAIBDAwO9EJzqRFmJMcOL8xGbtc6EydQB/MyApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5J6nXv+ecQkRlMAAAAASUVORK5CYII=',
);

class _Load {
  _Load(this.arguments);
  final JsonMap arguments;
  final result = Completer<JsonMap>();
}

class _Native extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final loads = <_Load>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments}));
    if (method == 'images.release') return Future.value({'released': true});
    if (method != 'images.load') {
      throw StateError('Unexpected native operation: $method');
    }
    final load = _Load({...arguments});
    loads.add(load);
    return load.result.future;
  }

  void complete(int index, {Size natural = const Size(160, 100)}) {
    loads[index].result.complete({
      'bytes': _png,
      'width': 160,
      'height': 100,
      'originalWidth': natural.width,
      'originalHeight': natural.height,
    });
  }
}

class _State extends AppState {
  _State(_Native native) : super(client: native);
  bool hideImageMetadata = false, hideOriginalMetadata = false;

  @override
  JsonMap imageDimensions(String url, {String kind = 'post'}) =>
      hideImageMetadata || (hideOriginalMetadata && kind == 'original')
      ? const {}
      : super.imageDimensions(url, kind: kind);

  void cover(bool value) {
    domains['extensions'] = {
      'items': [
        {'id': 'office', 'active': true},
      ],
      'settings': {
        'office': {'presented': value, 'key': '9', 'title': '工作计划'},
      },
    };
    notifyListeners();
  }
}

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  final popped = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

class _RetainedPage extends StatefulWidget {
  const _RetainedPage({super.key});

  @override
  State<_RetainedPage> createState() => _RetainedPageState();
}

class _RetainedPageState extends State<_RetainedPage> {
  final draft = TextEditingController(text: '保留正在编辑的草稿');
  final scroll = ScrollController(initialScrollOffset: 120);

  @override
  void dispose() {
    draft.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    child: Column(
      children: [
        CupertinoTextField(controller: draft),
        const Hero(
          tag: _heroTag,
          child: SizedBox(
            width: 160,
            height: 100,
            child: ColoredBox(color: Color(0xff336699)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemExtent: 40,
            itemCount: 100,
            itemBuilder: (context, index) => Text('本地阅读内容 $index'),
          ),
        ),
      ],
    ),
  );
}

class _Fixture {
  final native = _Native();
  late final state = _State(native);
  final routes = _Routes();
  final page = GlobalKey<_RetainedPageState>();
  final navigator = GlobalKey<NavigatorState>();
  Future<void>? completion;

  Future<void> mount(
    WidgetTester tester, {
    bool reducedMotion = false,
    bool rootViewer = false,
    Size natural = const Size(160, 100),
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    final thumbnail = state.image(_url);
    native.complete(0, natural: natural);
    await thumbnail;
    addTearDown(() async {
      for (var index = 0; index < native.loads.length; index++) {
        if (!native.loads[index].result.isCompleted) native.complete(index);
      }
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: navigator,
          navigatorObservers: [routes],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reducedMotion),
            child: ExtensionOverlays(state: state, child: child!),
          ),
          home: rootViewer
              ? NativeImageViewer(state: state, url: _url, thumbnail: _png)
              : _RetainedPage(key: page),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> open(
    WidgetTester tester, {
    bool hero = false,
    bool finishTransition = true,
  }) async {
    completion = showNativeImageViewer(
      page.currentContext!,
      state: state,
      url: _url,
      thumbnail: _png,
      label: '本地测试图片',
      heroTag: hero ? _heroTag : null,
    );
    await tester.pump();
    if (finishTransition) await tester.pump(const Duration(milliseconds: 300));
  }
}

ImageViewerToolbar _toolbar(WidgetTester tester) =>
    tester.widget<ImageViewerToolbar>(find.byType(ImageViewerToolbar));

Rect _paintedPicture(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byKey(_pictureKey));
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

Matrix4 _pictureMatrix(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(
        of: find.byKey(_viewportKey),
        matching: find.byType(Transform),
      ),
    )
    .transform;

double _pictureScale(WidgetTester tester) => _pictureMatrix(tester).entry(0, 0);

void _expectPictureScale(WidgetTester tester, Size unscaled, double scale) {
  final matrix = _pictureMatrix(tester);
  expect(matrix.entry(0, 0), closeTo(scale, 1e-10));
  expect(matrix.entry(1, 1), closeTo(scale, 1e-10));
  final painted = _paintedPicture(tester);
  expect(painted.width, closeTo(unscaled.width * scale, 1e-6));
  expect(painted.height, closeTo(unscaled.height * scale, 1e-6));
}

Future<void> _controlWheelToScale(WidgetTester tester, double scale) async {
  final current = _pictureMatrix(tester).entry(0, 0);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(_viewportKey)),
        scrollDelta: Offset(0, -200 * math.log(scale / current)),
        kind: PointerDeviceKind.mouse,
      ),
    );
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

class _ToolbarBuilds {
  int count = 0;
}

_ToolbarBuilds _observeToolbarBuilds() {
  final observations = _ToolbarBuilds();
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    if (element.widget is ImageViewerToolbar) observations.count++;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = previous);
  return observations;
}

Future<void> _finishClose(WidgetTester tester) async {
  // _dismiss pops at the end of a frame so HeroMode is already rebuilt. The
  // following frame establishes the reverse ticker's initial timestamp.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _finishZoom(WidgetTester tester) async {
  // Start the ticker before advancing through the 160 ms zoom animation.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pump();
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, [
  List<LogicalKeyboardKey> modifiers = const [],
]) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
}

void main() {
  testWidgets('transparent viewer preserves the mounted reader and draft', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    final page = value.page.currentState!;
    page.draft.selection = const TextSelection(baseOffset: 2, extentOffset: 6);
    final editing = page.draft.value;
    final position = page.scroll.offset;
    await value.open(tester);
    final route = value.routes.pushed.last as PageRoute<dynamic>;
    expect(route.opaque, isFalse);
    expect(route.maintainState, isTrue);
    expect(route.allowSnapshotting, isFalse);
    expect(value.page.currentState, same(page));
    expect(page.draft.value, editing);
    expect(page.scroll.offset, position);
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await _finishClose(tester);
    expect(find.byType(NativeImageViewer), findsNothing);
    expect(value.page.currentState, same(page));
    expect(page.draft.value, editing);
    expect(page.scroll.offset, position);
    expect(
      value.native.calls.every(
        (call) => call.$1 == 'images.load' || call.$1 == 'images.release',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('popup deferral survives pop until the reverse route completes', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    var completed = false;
    unawaited(value.completion!.then((_) => completed = true));
    expect(value.state.watchPopupDeferred.value, isTrue);
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(completed, isFalse);
    expect(value.state.watchPopupDeferred.value, isTrue);
    await _finishClose(tester);
    expect(completed, isTrue);
    expect(value.state.watchPopupDeferred.value, isFalse);
  });

  for (final corner in ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']) {
    testWidgets('picture tap stays open and $corner blank tap closes once', (
      tester,
    ) async {
      final value = _Fixture();
      await value.mount(tester);
      await value.open(tester);
      await tester.tapAt(_paintedPicture(tester).center);
      await tester.pump(const Duration(milliseconds: 350));
      expect(value.routes.popped, isEmpty);
      final rect = tester.getRect(find.byKey(_viewportKey)).deflate(8);
      final point = switch (corner) {
        'topLeft' => rect.topLeft,
        'topRight' => rect.topRight,
        'bottomLeft' => rect.bottomLeft,
        _ => rect.bottomRight,
      };
      expect(_paintedPicture(tester).contains(point), isFalse);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      await _finishClose(tester);
      expect(value.routes.popped, hasLength(1));
      expect(find.byType(NativeImageViewer), findsNothing);
    });
  }

  testWidgets('double click toggles 2x and fit without dismissing', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    for (final expected in [2.0, 1.0]) {
      final point = _paintedPicture(tester).center;
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(point);
      await _finishZoom(tester);
      expect(_pictureScale(tester), closeTo(expected, .001));
      expect(_toolbar(tester).originalSize, isFalse);
      expect(value.routes.popped, isEmpty);
    }
  });

  testWidgets('zoom controls share their scale and original-size basis', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
    await _finishZoom(tester);
    expect(_pictureScale(tester), closeTo(1.25, .001));
    await tester.tap(find.byKey(ImageViewerToolbar.zoomOutKey));
    await _finishZoom(tester);
    expect(_pictureScale(tester), closeTo(1, .001));
    final fit = _paintedPicture(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    expect(_toolbar(tester).originalSize, isTrue);
    expect(_paintedPicture(tester).width, greaterThan(fit.width));
    await tester.tap(find.byKey(ImageViewerToolbar.fitKey));
    await tester.pump();
    expect(_toolbar(tester).originalSize, isFalse);
    expect(_pictureScale(tester), closeTo(1, .001));
    expect(_paintedPicture(tester).width, closeTo(fit.width, .01));
    expect(value.native.loads, hasLength(2));
  });

  testWidgets('late original metadata preserves user zoom and image center', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
    await _finishZoom(tester);
    final center = _paintedPicture(tester).center;
    value.native.complete(1, natural: const Size(1600, 1000));
    await tester.pump();
    await tester.pump();
    expect(_pictureScale(tester), closeTo(1.25, .001));
    expect((_paintedPicture(tester).center - center).distance, lessThan(.1));
    expect(value.native.loads, hasLength(2));
    expect(value.routes.popped, isEmpty);
  });

  testWidgets('rapid zoom clicks accumulate against the animation target', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_pictureScale(tester), allOf(greaterThan(1), lessThan(1.25)));
    await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
    await _finishZoom(tester);
    expect(_pictureScale(tester), closeTo(1.5, .001));
    expect(value.native.loads, hasLength(2));
    expect(value.routes.popped, isEmpty);
  });

  testWidgets('unchanged fit rect still adopts larger original dimensions', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    final before = _paintedPicture(tester);
    value.native.complete(1, natural: const Size(3200, 2000));
    await tester.pump();
    await tester.pump();
    final after = _paintedPicture(tester);
    expect(after.width, closeTo(before.width, .01));
    expect(after.height, closeTo(before.height, .01));
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    expect(_toolbar(tester).originalSize, isTrue);
    expect(_paintedPicture(tester).width, closeTo(3200, .01));
    expect(_paintedPicture(tester).height, closeTo(2000, .01));
    expect(value.native.loads, hasLength(2));
  });

  testWidgets(
    'evicted original metadata does not fall back to older thumbnail dimensions',
    (tester) async {
      final value = _Fixture();
      await value.mount(tester, natural: const Size(1600, 1000));
      await value.open(tester);
      value.native.complete(1, natural: const Size(3200, 2000));
      await tester.pump();
      await tester.pump();
      value.state.hideOriginalMetadata = true;
      expect(value.state.imageDimensions(_url)['originalWidth'], 1600);
      await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
      await tester.pump();
      expect(_paintedPicture(tester).size, const Size(3200, 2000));
      expect(value.native.loads, hasLength(2));
    },
  );

  testWidgets('metadata eviction does not shrink an already known original', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    value.native.complete(1, natural: const Size(3200, 2000));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    expect(_paintedPicture(tester).width, closeTo(3200, .01));
    value.state.hideImageMetadata = true;
    expect(value.state.imageDimensions(_url), isEmpty);
    expect(value.state.imageDimensions(_url, kind: 'original'), isEmpty);
    // Resize forces geometry to read the now-empty metadata map while this
    // viewer still owns its valid bitmap and previously discovered dimensions.
    await tester.binding.setSurfaceSize(const Size(780, 540));
    await tester.pump();
    await tester.pump();
    expect(_paintedPicture(tester).width, closeTo(3200, .01));
    await tester.tap(find.byKey(ImageViewerToolbar.fitKey));
    await tester.pump();
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    expect(_paintedPicture(tester).width, closeTo(3200, .01));
    expect(_paintedPicture(tester).height, closeTo(2000, .01));
    expect(value.native.loads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('original completion saves dimensions before the next frame', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    final original = value.state.image(_url, kind: 'original');
    value.native.complete(1, natural: const Size(3200, 2000));
    await original;
    // Drain completion listeners without drawing a frame: another cache user
    // can evict these maps before FutureBuilder next lays out the picture.
    await Future<void>.value();
    await Future<void>.value();
    expect(
      value.state.imageDimensions(_url, kind: 'original')['originalWidth'],
      3200,
    );
    value.state.hideImageMetadata = true;
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    expect(_toolbar(tester).originalSize, isTrue);
    expect(_paintedPicture(tester).width, closeTo(3200, .01));
    expect(_paintedPicture(tester).height, closeTo(2000, .01));
    expect(value.native.loads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an active drag continues from geometry rebased for a late original',
    (tester) async {
      final value = _Fixture();
      await value.mount(tester, natural: const Size(1600, 1000));
      await value.open(tester);
      await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
      await tester.pump();
      final start = _paintedPicture(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_viewportKey)),
        pointer: 51,
      );
      try {
        // Establish a real drag beyond recognizer slop and keep its pointer down
        // throughout the original-size update.
        await gesture.moveBy(const Offset(50, 35));
        await gesture.moveBy(const Offset(30, 20));
        await tester.pump();
        expect(_paintedPicture(tester).left, greaterThan(start.left));
        value.native.complete(1, natural: const Size(3200, 2000));
        await tester.pump();
        await tester.pump();
        final rebased = _paintedPicture(tester);
        expect(rebased.width, closeTo(3200, .01));
        expect(rebased.height, closeTo(2000, .01));
        await gesture.moveBy(const Offset(30, 20));
        await tester.pump();
        final continued = _paintedPicture(tester);
        expect(continued.left - rebased.left, closeTo(30, .01));
        expect(continued.top - rebased.top, closeTo(20, .01));
        expect(continued.size, rebased.size);
        expect(_pictureScale(tester), closeTo(1, .001));
        expect(value.native.loads, hasLength(2));
        expect(value.routes.popped, isEmpty);
      } finally {
        await gesture.up();
      }
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'two-finger pinch keeps the image point under a moving focal point',
    (tester) async {
      final value = _Fixture();
      await value.mount(tester, natural: const Size(1600, 1000));
      await value.open(tester);
      await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
      await tester.pump();
      final center = tester.getCenter(find.byKey(_viewportKey));
      final first = await tester.startGesture(
        center - const Offset(50, 0),
        pointer: 41,
      );
      final second = await tester.startGesture(
        center + const Offset(50, 0),
        pointer: 42,
      );
      // Cross the real scale recognizer's slop before measuring its active
      // gesture. Subsequent positions test actual pointer routing, not callbacks.
      await first.moveTo(center - const Offset(80, 0));
      await second.moveTo(center + const Offset(80, 0));
      await first.moveTo(center - const Offset(100, 0));
      await second.moveTo(center + const Offset(100, 0));
      await tester.pump();
      final before = _paintedPicture(tester);
      final oldScale = _pictureScale(tester);
      expect(oldScale, greaterThan(1));
      final imagePoint = Offset(
        (center.dx - before.left) / before.width,
        (center.dy - before.top) / before.height,
      );
      final focal = center + const Offset(60, 30);
      await first.moveTo(focal - const Offset(160, 0));
      await second.moveTo(focal + const Offset(160, 0));
      await tester.pump();
      final after = _paintedPicture(tester);
      final projected = Offset(
        after.left + imagePoint.dx * after.width,
        after.top + imagePoint.dy * after.height,
      );
      expect(_pictureScale(tester), closeTo(oldScale * 1.6, .001));
      expect((projected - focal).distance, lessThan(.1));
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(value.routes.popped, isEmpty);
      expect(value.native.loads, hasLength(2));
    },
  );

  testWidgets('resize refits a fit image and preserves magnified scale', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    final width = _paintedPicture(tester).width;
    await tester.binding.setSurfaceSize(const Size(780, 540));
    await tester.pump();
    await tester.pump();
    expect(_pictureScale(tester), closeTo(1, .001));
    expect(_paintedPicture(tester).width, lessThan(width));
    await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
    await _finishZoom(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pump();
    await tester.pump();
    expect(_pictureScale(tester), closeTo(1.25, .001));
    expect(
      find.byKey(ImageViewerToolbar.closeKey).hitTestable(),
      findsOneWidget,
    );
    expect(value.native.loads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final dragging in [false, true]) {
    testWidgets(
      '${dragging ? 'drag' : 'wheel'} panning moves the image without rebuilding its unchanged-scale toolbar',
      (tester) async {
        final value = _Fixture();
        await value.mount(
          tester,
          reducedMotion: true,
          natural: const Size(1600, 1000),
        );
        await value.open(tester);
        value.native.complete(1, natural: const Size(1600, 1000));
        await tester.pump();
        await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
        await _finishZoom(tester);
        var toolbarBuilds = 0;
        final previousHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousHook?.call(element, builtOnce);
          if (element.widget is ImageViewerToolbar) toolbarBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
        final before = _paintedPicture(tester);
        final scale = _pictureScale(tester);
        final point = tester.getCenter(find.byKey(_viewportKey));
        if (dragging) {
          final gesture = await tester.startGesture(point);
          await gesture.moveBy(const Offset(80, 50));
          await tester.pump();
          await gesture.moveBy(const Offset(25, 20));
          await tester.pump();
          await gesture.up();
          await tester.pump();
          expect(_paintedPicture(tester).left, greaterThan(before.left));
          expect(_paintedPicture(tester).top, greaterThan(before.top));
        } else {
          for (final distance in [20.0, 30.0, 40.0]) {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: point,
                scrollDelta: Offset(0, distance),
                kind: PointerDeviceKind.mouse,
              ),
            );
            await tester.pump();
          }
          expect(_paintedPicture(tester).top, closeTo(before.top - 90, .01));
        }
        expect(_pictureScale(tester), scale);
        expect(toolbarBuilds, 0);
        expect(_toolbar(tester).originalSize, isTrue);
        await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
        await _finishZoom(tester);
        expect(_pictureScale(tester), closeTo(1.25, .001));
        expect(toolbarBuilds, greaterThan(0));
        expect(value.routes.popped, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final input in ['control-wheel', 'trackpad-pinch']) {
    testWidgets(
      '$input preserves exact image zoom without rebuilding an unchanged toolbar presentation',
      (tester) async {
        final value = _Fixture();
        await value.mount(
          tester,
          reducedMotion: true,
          natural: const Size(1600, 1000),
        );
        await value.open(tester);
        value.native.complete(1, natural: const Size(1600, 1000));
        await tester.pumpAndSettle();
        final point = tester.getCenter(find.byKey(_viewportKey));
        TestGesture? gesture;
        if (input == 'trackpad-pinch') {
          gesture = await tester.createGesture(
            kind: PointerDeviceKind.trackpad,
            pointer: 67,
          );
          await gesture.panZoomStart(point);
          // Accept the real scale recognizer with pan slop while scale is 1.
          // Subsequent updates change only its cumulative pinch scale.
          await gesture.panZoomUpdate(point, pan: const Offset(60, 0));
          await tester.pump();
        }
        final unscaled = _paintedPicture(tester).size;
        final picture = tester.element(find.byKey(_pictureKey));
        final toolbar = tester.element(find.byType(ImageViewerToolbar));
        _expectPictureScale(tester, unscaled, 1);
        final builds = _observeToolbarBuilds();
        final perStep = <int>[];
        try {
          for (final sample in [
            (scale: 1.001, percentage: '100%'),
            (scale: 1.002, percentage: '100%'),
            (scale: 1.004, percentage: '100%'),
            (scale: 1.006, percentage: '101%'),
            (scale: 1.007, percentage: '101%'),
            (scale: 1.004, percentage: '100%'),
          ]) {
            final beforeBuilds = builds.count;
            final beforeMatrix = List<double>.of(
              _pictureMatrix(tester).storage,
            );
            final beforePaint = _paintedPicture(tester);
            if (gesture == null) {
              await _controlWheelToScale(tester, sample.scale);
            } else {
              await gesture.panZoomUpdate(
                point,
                pan: const Offset(60, 0),
                scale: sample.scale,
              );
              await tester.pump();
            }
            perStep.add(builds.count - beforeBuilds);
            _expectPictureScale(tester, unscaled, sample.scale);
            expect(
              _pictureMatrix(tester).storage,
              isNot(orderedEquals(beforeMatrix)),
            );
            expect(_paintedPicture(tester).size, isNot(beforePaint.size));
            expect(tester.element(find.byKey(_pictureKey)), same(picture));
            expect(
              tester.element(find.byType(ImageViewerToolbar)),
              same(toolbar),
            );
            final fit = tester.widget<DeskButton>(
              find.byKey(ImageViewerToolbar.fitKey),
            );
            expect(fit.label, sample.percentage);
            expect(fit.semanticLabel, contains(sample.percentage));
            for (final key in [
              ImageViewerToolbar.zoomOutKey,
              ImageViewerToolbar.zoomInKey,
            ]) {
              expect(tester.widget<DeskIcon>(find.byKey(key)).onTap, isNotNull);
            }
          }
        } finally {
          if (gesture != null) await gesture.panZoomEnd();
        }
        // Observe actual toolbar builds after each routed pointer update. The
        // exact transform and painted bounds above must still change each time.
        // ignore: avoid_print
        print('$input toolbarBuildsPerScaleStep=$perStep');
        expect(perStep, [0, 0, 0, 1, 0, 1]);
        expect(value.native.loads, hasLength(2));
        expect(value.routes.popped, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final lowerLimit in [true, false]) {
    testWidgets(
      '${lowerLimit ? 'lower' : 'upper'} zoom threshold updates button availability within the same percentage',
      (tester) async {
        final value = _Fixture();
        await value.mount(tester, reducedMotion: true);
        await value.open(tester);
        value.native.complete(1);
        await tester.pumpAndSettle();
        final unscaled = _paintedPicture(tester).size;
        final key = lowerLimit
            ? ImageViewerToolbar.zoomOutKey
            : ImageViewerToolbar.zoomInKey;
        final percentage = lowerLimit ? '50%' : '400%';
        await _controlWheelToScale(tester, lowerLimit ? .50002 : 3.99998);
        expect(tester.widget<DeskIcon>(find.byKey(key)).onTap, isNotNull);
        final builds = _observeToolbarBuilds();
        final perStep = <int>[];
        final scales = lowerLimit
            ? [.500009, .500005, .500011, .50002]
            : [3.999991, 3.999995, 3.999989, 3.99998];
        for (var index = 0; index < scales.length; index++) {
          final before = builds.count;
          await _controlWheelToScale(tester, scales[index]);
          perStep.add(builds.count - before);
          _expectPictureScale(tester, unscaled, scales[index]);
          expect(
            tester
                .widget<DeskButton>(find.byKey(ImageViewerToolbar.fitKey))
                .label,
            percentage,
          );
          expect(
            tester.widget<DeskIcon>(find.byKey(key)).onTap != null,
            index >= 2,
          );
          if (index < 2) {
            final matrix = List<double>.of(_pictureMatrix(tester).storage);
            final painted = _paintedPicture(tester);
            final beforeTap = builds.count;
            // Disabled controls intentionally ignore this routed pointer tap.
            await tester.tap(find.byKey(key), warnIfMissed: false);
            await tester.pump();
            expect(_pictureMatrix(tester).storage, orderedEquals(matrix));
            expect(_paintedPicture(tester), painted);
            expect(builds.count, beforeTap);
          }
        }
        // ignore: avoid_print
        print(
          '${lowerLimit ? 'lower' : 'upper'} threshold '
          'toolbarBuildsPerScaleStep=$perStep',
        );
        expect(perStep, [1, 0, 1, 0]);
        await tester.tap(find.byKey(key));
        await _finishZoom(tester);
        _expectPictureScale(tester, unscaled, lowerLimit ? .5 : 4);
        expect(tester.widget<DeskIcon>(find.byKey(key)).onTap, isNull);
        expect(value.routes.popped, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rapid zoom buttons retain sub-percent scale in their exact target',
    (tester) async {
      final value = _Fixture();
      await value.mount(tester, natural: const Size(1600, 1000));
      await value.open(tester);
      value.native.complete(1, natural: const Size(1600, 1000));
      await tester.pumpAndSettle();
      final unscaled = _paintedPicture(tester).size;
      await _controlWheelToScale(tester, 1.004);
      _expectPictureScale(tester, unscaled, 1.004);
      expect(
        tester.widget<DeskButton>(find.byKey(ImageViewerToolbar.fitKey)).label,
        '100%',
      );
      await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        _pictureMatrix(tester).entry(0, 0),
        allOf(greaterThan(1.004), lessThan(1.254)),
      );
      await tester.tap(find.byKey(ImageViewerToolbar.zoomInKey));
      await _finishZoom(tester);
      _expectPictureScale(tester, unscaled, 1.504);
      await tester.tap(find.byKey(ImageViewerToolbar.zoomOutKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        _pictureMatrix(tester).entry(0, 0),
        allOf(greaterThan(1.254), lessThan(1.504)),
      );
      await tester.tap(find.byKey(ImageViewerToolbar.zoomOutKey));
      await _finishZoom(tester);
      _expectPictureScale(tester, unscaled, 1.004);
      expect(value.routes.popped, isEmpty);
      expect(value.native.loads, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ordinary wheel pans while control-wheel zooms the same image', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    final point = tester.getCenter(find.byKey(_viewportKey));
    final before = _paintedPicture(tester);
    final scale = _pictureScale(tester);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: point,
        scrollDelta: const Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    expect(_pictureScale(tester), closeTo(scale, .001));
    expect(_paintedPicture(tester).top, lessThan(before.top));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: point,
        scrollDelta: const Offset(0, -80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(_pictureScale(tester), greaterThan(scale));
    expect(value.routes.popped, isEmpty);
  });

  testWidgets('dragging a magnified image pans without becoming a close tap', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, natural: const Size(1600, 1000));
    await value.open(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.originalSizeKey));
    await tester.pump();
    final before = _paintedPicture(tester);
    await tester.dragFrom(
      tester.getCenter(find.byKey(_viewportKey)),
      const Offset(90, 60),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(_pictureScale(tester), closeTo(1, .001));
    expect(_paintedPicture(tester).left, greaterThan(before.left));
    expect(_paintedPicture(tester).top, greaterThan(before.top));
    expect(value.routes.popped, isEmpty);
  });

  testWidgets('repeated Escape and Command-W only pop the viewer once', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    final staleClose = _toolbar(tester).onClose;
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.keyW, [LogicalKeyboardKey.metaLeft]);
    staleClose();
    await _key(tester, LogicalKeyboardKey.escape);
    await _finishClose(tester);
    expect(value.routes.popped, hasLength(1));
    expect(value.page.currentState, isNotNull);
  });

  testWidgets('only exact unmodified Escape or Command-W closes the viewer', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await _key(tester, LogicalKeyboardKey.escape, [modifier]);
    }
    await _key(tester, LogicalKeyboardKey.keyW);
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]) {
      await _key(tester, LogicalKeyboardKey.keyW, [
        LogicalKeyboardKey.metaLeft,
        modifier,
      ]);
    }
    await tester.pump();
    expect(value.routes.popped, isEmpty);
    await _key(tester, LogicalKeyboardKey.keyW, [LogicalKeyboardKey.metaLeft]);
    await _finishClose(tester);
    expect(value.routes.popped, hasLength(1));
  });

  testWidgets('a directly embedded root viewer never pops the host page', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, rootViewer: true);
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.keyW, [LogicalKeyboardKey.metaLeft]);
    await _finishClose(tester);
    expect(value.routes.popped, isEmpty);
    expect(find.byType(NativeImageViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('office cover blocks stale viewer close and keyboard actions', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    final staleClose = _toolbar(tester).onClose;
    value.state.cover(true);
    await tester.pump();
    staleClose();
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.keyW, [LogicalKeyboardKey.metaLeft]);
    await tester.pump();
    expect(value.routes.popped, isEmpty);
    value.state.cover(false);
    await tester.pump();
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await _finishClose(tester);
    expect(value.routes.popped, hasLength(1));
  });

  testWidgets('a covered image route cannot close the route above it', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester);
    await value.open(tester);
    final staleClose = _toolbar(tester).onClose;
    final cover = PageRouteBuilder<void>(
      pageBuilder: (_, animation, secondary) =>
          const Center(child: Text('Another local route')),
    );
    unawaited(value.navigator.currentState!.push(cover));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    staleClose();
    await tester.pump();
    expect(value.routes.popped, isEmpty);
    expect(cover.isCurrent, isTrue);
    value.navigator.currentState!.pop();
    await _finishClose(tester);
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await _finishClose(tester);
    expect(value.routes.popped, hasLength(2));
  });

  testWidgets('reduced motion keeps the image out of a Hero shuttle', (
    tester,
  ) async {
    final value = _Fixture();
    await value.mount(tester, reducedMotion: true);
    await value.open(tester, hero: true, finishTransition: false);
    await tester.pump(const Duration(milliseconds: 40));
    final images = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is MemoryImage &&
          identical((widget.image as MemoryImage).bytes, _png),
    );
    expect(images, findsOneWidget);
    expect(
      find.ancestor(of: images, matching: find.byType(NativeImageViewer)),
      findsOneWidget,
    );
    expect(value.routes.popped, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
    await _finishClose(tester);
    expect(value.routes.popped, hasLength(1));
  });
}
