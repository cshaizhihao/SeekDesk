import 'dart:async';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/native_wheel_input.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/reader_wheel_scroll.dart';

class _WheelBinding extends AutomatedTestWidgetsFlutterBinding
    with NativeWheelDispatchBinding {}

var _sequence = 0;

Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Injects numeric native classification, then exercises real hit testing and
/// the SDK pointer-signal resolver. No native channel or service is invoked.
Future<void> _wheel(
  WidgetTester tester,
  Finder target,
  Offset delta, {
  bool metadata = true,
  bool precise = false,
  int modifiers = 0,
}) async {
  final sequence = ++_sequence;
  final event = PointerScrollEvent(
    viewId: tester.view.viewId,
    timeStamp: Duration(microseconds: sequence * 1000),
    position: tester.getCenter(target),
    scrollDelta: delta,
    kind: PointerDeviceKind.mouse,
  );
  if (metadata) {
    // The default production matcher reads the actual engine view. The test
    // surface override is a separate wrapper, so use that same engine scale.
    final ratio = ui.PlatformDispatcher.instance
        .view(id: event.viewId)!
        .devicePixelRatio;
    NativeWheelInput.instance.acceptMetadata({
      'version': 1,
      'sequence': sequence,
      'viewId': event.viewId,
      'timestampMicros': event.timeStamp.inMicroseconds,
      'x': event.position.dx * ratio,
      'y': event.position.dy * ratio,
      'dx': delta.dx * ratio,
      'dy': delta.dy * ratio,
      'precise': precise,
      'phase': 0,
      'momentumPhase': 0,
      'modifiers': modifiers,
    });
  }
  await tester.sendEventToBinding(event);
  expect(
    NativeWheelInput.instance.current,
    isNull,
    reason: 'Classification must end with this complete resolver dispatch.',
  );
}

const _rootKey = ValueKey('wheel-test-root');
const _innerKey = ValueKey('wheel-test-horizontal');

class _ScrollFixture {
  _ScrollFixture({double initial = 100}) {
    controller = ReaderWheelScrollController(
      initialScrollOffset: initial,
      onUserWheel: () => inputs++,
      onWheel: (_, smooth) => modes.add(smooth),
    );
  }

  late final ReaderWheelScrollController controller;
  final inner = ScrollController();
  final modes = <bool>[];
  final scrolling = <bool>[];
  final updates = <double>[];
  var inputs = 0;
  var starts = 0;
  var ends = 0;

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 500));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      inner.dispose();
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    });
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: NotificationListener<ScrollNotification>(
            onNotification: (event) {
              if (event.depth == 0 && event.metrics.axis == Axis.vertical) {
                if (event is ScrollStartNotification) starts++;
                if (event is ScrollEndNotification) ends++;
              }
              return false;
            },
            child: ListView(
              key: _rootKey,
              controller: controller,
              physics: const ClampingScrollPhysics(),
              children: [
                const SizedBox(height: 100),
                SizedBox(
                  height: 120,
                  child: SingleChildScrollView(
                    key: _innerKey,
                    controller: inner,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: const SizedBox(
                      width: 2400,
                      child: Text('A wide nested scroll owner'),
                    ),
                  ),
                ),
                CupertinoButton(
                  onPressed: () {},
                  child: const Text('Interactive while scrolling'),
                ),
                const SizedBox(
                  height: 4000,
                  child: Text('Reader continuation'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final position = controller.position;
    position.isScrollingNotifier.addListener(
      () => scrolling.add(position.isScrollingNotifier.value),
    );
    controller.addListener(() => updates.add(controller.offset));
  }
}

const _page = 'https://www.nodeseek.com/post-17-1';
const _floorURL = '$_page#comment-35';
final _wideText = List.filled(
  24,
  'wide code preserves horizontal ownership',
).join(' ');

/// Only in-memory workspace, reader and local position operations are allowed.
/// Delayed reads model the stale DTO boundary; no image/network/user data exists.
class _ReaderNative extends NativeClient {
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final pending = <Completer<JsonMap>>[];
  final saves = <JsonMap>[];
  bool delayReads = false;

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  JsonMap get workspace => {
    'tabs': [
      {'id': '17', 'url': _page, 'title': 'Wheel integration'},
    ],
    'selectedTab': '17',
    'showReader': true,
    'posts': <JsonMap>[],
    'boards': <JsonMap>[],
  };

  JsonMap snapshot() => {
    'url': _page,
    'accessRevision': accessRevision,
    'scrollOffset': 0.0,
    'loading': false,
    'authorProfilesSupported': false,
    'thread': {
      'title': 'Wheel integration',
      'root': {
        'id': '0',
        'author': 'Local root',
        'blocks': [
          {'kind': 'code', 'text': _wideText},
          {'kind': 'text', 'text': 'A stable opening passage'},
        ],
      },
      'replies': [
        for (var id = 1; id <= 60; id++)
          {
            'id': '$id',
            'author': 'Local author $id',
            'blocks': [
              {'kind': 'text', 'text': 'Wheel reply $id'},
              {
                'kind': 'text',
                'text':
                    'Text-only geometry for reply $id. '
                    'Real resolver input must retire only the appropriate '
                    'reading restoration without changing another owner.',
              },
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  void completeReads() {
    for (final read in pending) {
      if (!read.isCompleted) read.complete(snapshot());
    }
  }

  void changeOwner() {
    eventsController.add({
      'domain': 'session',
      'accessRevision': accessRevision + 1,
      'data': {
        'account': 'signedIn',
        'owner': 2,
        'accessRevision': accessRevision + 1,
      },
    });
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 1,
            'accessRevision': accessRevision,
          },
          'workspace': workspace,
          'settings': {'appearance': 'light'},
          'extensions': {'items': <JsonMap>[]},
        };
      case 'reader.open':
        return workspace;
      case 'reader.load':
        if (delayReads) {
          final read = Completer<JsonMap>();
          pending.add(read);
          return read.future;
        }
        return snapshot();
      case 'reader.rememberPosition':
        saves.add({...arguments, 'accessRevision': accessRevision});
        return {'saved': true};
      default:
        throw StateError('Unexpected wheel fixture operation: $method');
    }
  }
}

Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

Finder get _codeScroll => find.ancestor(
  of: find.text(_wideText, findRichText: true),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal,
  ),
);

class _ReaderFixture {
  _ReaderFixture() : native = _ReaderNative() {
    state = AppState(client: native);
  }

  final _ReaderNative native;
  late final AppState state;
  final reducedMotion = ValueNotifier(false);
  final tickersEnabled = ValueNotifier(true);
  late ReaderWheelScrollController controller;

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      native.completeReads();
      await native.eventsController.close();
      reducedMotion.dispose();
      tickersEnabled.dispose();
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    });
    await state.connect();
    state.readers[_page] = native.snapshot();
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reducedMotion,
            builder: (context, reduced, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: ValueListenableBuilder<bool>(
                valueListenable: tickersEnabled,
                builder: (_, enabled, child) =>
                    TickerMode(enabled: enabled, child: child!),
                child: CupertinoPageScaffold(
                  child: ReaderScreen(
                    state: state,
                    topic: TopicData({
                      'id': '17',
                      'url': _page,
                      'title': 'Wheel integration',
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester, 5);
    controller =
        tester.widget<CustomScrollView>(_readerScroll).controller!
            as ReaderWheelScrollController;
    expect(controller.keepScrollOffset, isFalse);
    expect(controller.motionEnabled, isTrue);
  }

  Future<void> openFloor() {
    native.delayReads = true;
    return state.openTopic(
      TopicData({'id': '17', 'url': _floorURL, 'title': 'Wheel integration'}),
    );
  }

  Future<void> finishOpening(WidgetTester tester, Future<void> opening) async {
    native.completeReads();
    await tester.idle();
    await opening;
  }
}

Future<void> _waitForFloor(WidgetTester tester) async {
  for (var frame = 0; frame < 180; frame++) {
    await _frames(tester, 1);
    if (find.text('Wheel reply 35').hitTestable().evaluate().isNotEmpty) return;
  }
  expect(find.text('Wheel reply 35').hitTestable(), findsOneWidget);
}

void _macTest(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  _WheelBinding();
  setUp(() {
    NativeWheelInput.instance.dispose();
    _sequence = 0;
  });
  tearDown(() => NativeWheelInput.instance.dispose());

  _macTest(
    'classified resolver input interpolates and conserves a wheel burst',
    (tester) async {
      final f = _ScrollFixture();
      await f.mount(tester);
      final before = f.controller.offset;
      await _wheel(tester, find.byKey(_rootKey), const Offset(0, 72));
      expect(f.inputs, 1);
      expect(f.modes, [true]);
      expect(f.controller.offset, before);
      expect(f.controller.position.isScrollingNotifier.value, isTrue);
      expect(
        find.text('Interactive while scrolling').hitTestable(),
        findsOneWidget,
      );
      await tester.pump();
      await _frames(tester, 1);
      expect(f.controller.offset, greaterThan(before));
      expect(f.controller.offset, lessThan(before + 72));
      await _wheel(tester, find.byKey(_rootKey), const Offset(0, 72));
      await _frames(tester);
      expect(f.controller.offset, closeTo(before + 144, .001));
      expect(f.inputs, 2);
      expect(f.modes, [true, true]);
      expect(f.scrolling, [true, false]);
      expect(f.starts, 1);
      expect(f.ends, 1);
      expect(f.updates, orderedEquals([...f.updates]..sort()));
    },
  );

  _macTest('a reversal discards only the old unconsumed wheel tail', (
    tester,
  ) async {
    final f = _ScrollFixture(initial: 300);
    await f.mount(tester);
    await _wheel(tester, find.byKey(_rootKey), const Offset(0, 120));
    await tester.pump();
    await _frames(tester, 1);
    final reversal = f.controller.offset;
    expect(reversal, inExclusiveRange(300, 420));
    await _wheel(tester, find.byKey(_rootKey), const Offset(0, -48));
    await _frames(tester, 1);
    expect(f.controller.offset, lessThan(reversal));
    await _frames(tester);
    expect(f.controller.offset, closeTo(reversal - 48, .001));
    expect(f.inputs, 2);
    expect(f.scrolling, [true, false]);
  });

  for (final precise in [false, true]) {
    _macTest(
      '${precise ? 'precise' : 'unclassified'} input stops interpolation and uses the immediate SDK path',
      (tester) async {
        final f = _ScrollFixture();
        await f.mount(tester);
        await _wheel(tester, find.byKey(_rootKey), const Offset(0, 120));
        await tester.pump();
        await _frames(tester, 1);
        final before = f.controller.offset;
        await _wheel(
          tester,
          find.byKey(_rootKey),
          const Offset(0, 12),
          metadata: precise,
          precise: precise,
        );
        expect(f.controller.offset, closeTo(before + 12, .001));
        expect(f.modes, [true, false]);
        await _frames(tester, 20);
        expect(f.controller.offset, closeTo(before + 12, .001));
        expect(f.controller.position.isScrollingNotifier.value, isFalse);
      },
    );
  }

  _macTest('nested horizontal and Shift signals keep resolver ownership', (
    tester,
  ) async {
    final f = _ScrollFixture();
    await f.mount(tester);
    final before = f.controller.offset;
    await _wheel(tester, find.byKey(_innerKey), const Offset(72, 0));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await _wheel(
        tester,
        find.byKey(_innerKey),
        const Offset(0, 72),
        modifiers: 1,
      );
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    expect(f.inner.offset, 144);
    expect(f.controller.offset, before);
    expect(f.inputs, 0);
    await _wheel(tester, find.byKey(_innerKey), const Offset(0, 72));
    expect(f.inputs, 1);
    expect(f.controller.offset, before);
    await tester.pump();
    await _frames(tester);
    expect(f.controller.offset, closeTo(before + 72, .001));
    expect(f.inner.offset, 144);
  });

  _macTest('a bounded-out signal neither owns input nor leaks classification', (
    tester,
  ) async {
    final f = _ScrollFixture(initial: 0);
    await f.mount(tester);
    await _wheel(tester, find.byKey(_rootKey), const Offset(0, -72));
    expect(f.inputs, 0);
    expect(f.controller.position.isScrollingNotifier.value, isFalse);
    f.controller.position.pointerScroll(12);
    expect(f.controller.offset, 12);
    await _frames(tester);
    expect(f.controller.offset, 12);
    expect(f.modes, isEmpty);
  });

  for (final cancel in ['jump', 'inertia cancel', 'motion disabled']) {
    _macTest('$cancel retires the wheel tail without later movement', (
      tester,
    ) async {
      final f = _ScrollFixture();
      await f.mount(tester);
      await _wheel(tester, find.byKey(_rootKey), const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      switch (cancel) {
        case 'jump':
          f.controller.jumpTo(80);
        case 'inertia cancel':
          await tester.sendEventToBinding(
            PointerScrollInertiaCancelEvent(
              viewId: tester.view.viewId,
              position: tester.getCenter(find.byKey(_rootKey)),
              kind: PointerDeviceKind.mouse,
            ),
          );
        case 'motion disabled':
          f.controller.motionEnabled = false;
      }
      final stopped = f.controller.offset;
      expect(f.controller.position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
    });
  }

  _macTest(
    'detaching the scrollable cancels its active tail before another tick',
    (tester) async {
      final f = _ScrollFixture();
      await f.mount(tester);
      await _wheel(tester, find.byKey(_rootKey), const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      final count = f.updates.length;
      expect(f.controller.hasClients, isFalse);
      await _frames(tester, 20);
      expect(f.updates, hasLength(count));
    },
  );

  for (final bottom in [false, true]) {
    _macTest(
      'reader ${bottom ? 'bottom' : 'top'} reversal before the first tick retires the old tail',
      (tester) async {
        final f = _ReaderFixture();
        await f.mount(tester);
        final position = f.controller.position;
        if (bottom) {
          // Let the lazy reader settle its measured end before testing input.
          for (var pass = 0; pass < 3; pass++) {
            f.controller.jumpTo(position.maxScrollExtent);
            await _frames(tester, 2);
          }
        }
        final boundary = bottom
            ? position.maxScrollExtent
            : position.minScrollExtent;
        expect(f.controller.offset, boundary);
        expect(position.isScrollingNotifier.value, isFalse);
        final recordedOffset = f.state.readerOffset(_page);
        final navigation = f.state.readerNavigation(_page);
        final updates = <double>[];
        final scrolling = <bool>[];
        void recordPosition() => updates.add(f.controller.offset);
        void recordScrolling() =>
            scrolling.add(position.isScrollingNotifier.value);
        f.controller.addListener(recordPosition);
        position.isScrollingNotifier.addListener(recordScrolling);
        addTearDown(() {
          f.controller.removeListener(recordPosition);
          position.isScrollingNotifier.removeListener(recordScrolling);
        });

        final inward = bottom ? -72.0 : 72.0;
        await _wheel(tester, _readerScroll, Offset(0, inward));
        expect(f.controller.offset, boundary);
        expect(position.isScrollingNotifier.value, isTrue);
        // No pump between these signals: the resolver rejects the outward
        // destination while the old inward activity still has its full tail.
        await _wheel(tester, _readerScroll, Offset(0, -inward));
        expect(f.controller.offset, boundary);
        expect(position.isScrollingNotifier.value, isFalse);
        expect(scrolling, [true, false]);
        expect(updates, isEmpty);
        expect(f.state.readerNavigation(_page), same(navigation));
        await _frames(tester, 20);
        expect(f.controller.offset, boundary);
        expect(updates, isEmpty);
        expect(scrolling, [true, false]);
        expect(f.state.readerOffset(_page), recordedOffset);
        expect(NativeWheelInput.instance.current, isNull);
        expect(NativeWheelInput.instance.consume(), isNull);
      },
    );
  }

  _macTest(
    'a repeated real wheel takes over a queued floor before its first smooth pixel',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      await _wheel(tester, _readerScroll, const Offset(0, 160));
      await tester.pump();
      await _frames(tester, 1);
      final before = f.controller.offset;
      final opening = f.openFloor();
      await tester.idle();
      expect(f.state.readerNavigation(_page)?.floor, '35');
      expect(f.controller.position.isScrollingNotifier.value, isFalse);
      await _wheel(tester, _readerScroll, const Offset(0, 72));
      expect(f.state.readerNavigation(_page), isNull);
      expect(f.controller.offset, before);
      await tester.pump();
      await _frames(tester, 20);
      final chosen = f.controller.offset;
      expect(chosen, closeTo(before + 72, .1));
      expect(find.text('Wheel reply 35').hitTestable(), findsNothing);
      await f.finishOpening(tester, opening);
      await _frames(tester, 50);
      expect(f.controller.offset, closeTo(chosen, .5));
      expect(f.state.readerNavigation(_page), isNull);
      expect(f.native.saves, isNotEmpty);
      expect(numberValue(f.native.saves.last['offset']), closeTo(chosen, .5));
    },
  );

  for (final outwardWheel in [false, true]) {
    _macTest(
      '${outwardWheel ? 'an outward boundary wheel' : 'a retired interpolation tail'} preserves a newer floor request',
      (tester) async {
        final f = _ReaderFixture();
        await f.mount(tester);
        if (!outwardWheel) {
          await _wheel(tester, _readerScroll, const Offset(0, 160));
          await tester.pump();
          await _frames(tester, 1);
        }
        final opening = f.openFloor();
        await tester.idle();
        final sequence = f.state.readerNavigation(_page)!.sequence;
        expect(f.controller.position.isScrollingNotifier.value, isFalse);
        if (outwardWheel) {
          expect(f.controller.offset, closeTo(0, .001));
          await _wheel(tester, _readerScroll, const Offset(0, -72));
          expect(f.state.readerNavigation(_page)?.sequence, sequence);
        }
        await _waitForFloor(tester);
        await f.finishOpening(tester, opening);
        await _frames(tester, 20);
        expect(find.text('Wheel reply 35').hitTestable(), findsOneWidget);
        expect(f.state.readerNavigation(_page), isNull);
      },
    );
  }

  _macTest(
    'wide reader code preserves a pending restore until vertical resolver input wins',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      expect(_codeScroll.hitTestable(), findsOneWidget);
      final inner = Scrollable.of(
        tester.element(find.text(_wideText, findRichText: true)),
      ).position;
      final before = f.controller.offset;
      final opening = f.openFloor();
      await tester.idle();
      final sequence = f.state.readerNavigation(_page)!.sequence;
      await _wheel(tester, _codeScroll, const Offset(72, 0));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      try {
        await _wheel(tester, _codeScroll, const Offset(0, 72), modifiers: 1);
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
      expect(inner.pixels, 144);
      expect(f.controller.offset, before);
      expect(f.state.readerNavigation(_page)?.sequence, sequence);
      await _wheel(tester, _codeScroll, const Offset(0, 72));
      expect(f.state.readerNavigation(_page), isNull);
      expect(f.controller.offset, before);
      await tester.pump();
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(before + 72, .1));
      expect(inner.pixels, 144);
      await f.finishOpening(tester, opening);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(before + 72, .5));
      expect(find.text('Wheel reply 35').hitTestable(), findsNothing);
    },
  );

  _macTest(
    'reader pointer down cancels its wheel tail before any drag movement',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      await _wheel(tester, _readerScroll, const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      expect(f.controller.position.isScrollingNotifier.value, isTrue);
      final hold = await tester.startGesture(tester.getCenter(_readerScroll));
      try {
        final stopped = f.controller.offset;
        expect(f.controller.position.isScrollingNotifier.value, isFalse);
        await _frames(tester, 20);
        expect(f.controller.offset, closeTo(stopped, .001));
      } finally {
        await hold.up();
      }
    },
  );

  _macTest(
    'a transparent route retires the reader wheel tail without resuming it on return',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      final navigator = Navigator.of(tester.element(find.byType(ReaderScreen)));
      final position = f.controller.position;
      await _wheel(tester, _readerScroll, const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      final stopped = f.controller.offset;
      expect(stopped, inExclusiveRange(0, 240));
      expect(position.isScrollingNotifier.value, isTrue);
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            opaque: false,
            allowSnapshotting: false,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, animation, secondaryAnimation) =>
                const Center(child: Text('Covering the active wheel reader')),
          ),
        ),
      );
      await tester.pump();
      expect(f.controller.motionEnabled, isFalse);
      expect(position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
      expect(f.controller.position, same(position));
      navigator.pop();
      await tester.pump();
      expect(f.controller.motionEnabled, isTrue);
      expect(position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
      expect(find.text('Covering the active wheel reader'), findsNothing);
      await _wheel(tester, _readerScroll, const Offset(0, 72));
      expect(f.controller.offset, closeTo(stopped, .001));
      expect(position.isScrollingNotifier.value, isTrue);
      await tester.pump();
      await _frames(tester);
      expect(f.controller.offset, closeTo(stopped + 72, .001));
    },
  );

  _macTest(
    'disabling reader tickers retires the wheel tail without resuming it',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      await _wheel(tester, _readerScroll, const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      final stopped = f.controller.offset;
      expect(stopped, inExclusiveRange(0, 240));
      expect(f.controller.position.isScrollingNotifier.value, isTrue);
      f.tickersEnabled.value = false;
      await tester.pump();
      expect(f.controller.motionEnabled, isFalse);
      expect(f.controller.position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
      f.tickersEnabled.value = true;
      await tester.pump();
      expect(f.controller.motionEnabled, isTrue);
      expect(f.controller.position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
      await _wheel(tester, _readerScroll, const Offset(0, 72));
      expect(f.controller.offset, closeTo(stopped, .001));
      expect(f.controller.position.isScrollingNotifier.value, isTrue);
      await tester.pump();
      await _frames(tester);
      expect(f.controller.offset, closeTo(stopped + 72, .001));
    },
  );

  _macTest(
    'reader reduced motion stops a tail and later wheel input is immediate',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      await _wheel(tester, _readerScroll, const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      f.reducedMotion.value = true;
      await tester.pump();
      final stopped = f.controller.offset;
      expect(f.controller.motionEnabled, isFalse);
      expect(f.controller.position.isScrollingNotifier.value, isFalse);
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped, .001));
      await _wheel(tester, _readerScroll, const Offset(0, 72));
      expect(f.controller.offset, closeTo(stopped + 72, .001));
      await _frames(tester, 20);
      expect(f.controller.offset, closeTo(stopped + 72, .001));
    },
  );

  _macTest(
    'identity invalidation stops the old wheel before another animation frame',
    (tester) async {
      final f = _ReaderFixture();
      await f.mount(tester);
      await _wheel(tester, _readerScroll, const Offset(0, 240));
      await tester.pump();
      await _frames(tester, 1);
      final retired = f.controller.position;
      final moves = <double>[];
      retired.addListener(() => moves.add(retired.pixels));
      expect(retired.isScrollingNotifier.value, isTrue);
      f.native.changeOwner();
      expect(f.state.accessRevision, 1);
      expect(
        retired.isScrollingNotifier.value,
        isFalse,
        reason: 'Identity invalidation must cancel before the next frame, not wait for detach.',
      );
      await _frames(tester, 30);
      expect(moves, isEmpty);
      expect(
        f.native.saves.where((save) => save['accessRevision'] == 1),
        isEmpty,
      );
    },
  );
}
