import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/reader_content_layout.dart';

Widget _document({
  required ReaderContentLayoutController controller,
  required ScrollController scroll,
  required Widget child,
  String floor = '705',
  bool offstage = false,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      key: const ValueKey('viewport'),
      width: 280,
      height: 300,
      child: ReaderContentLayoutScope(
        controller: controller,
        viewportHeight: 300,
        child: SingleChildScrollView(
          controller: scroll,
          child: Offstage(
            offstage: offstage,
            child: ReaderContentFloor(floorID: floor, child: child),
          ),
        ),
      ),
    ),
  ),
);

ReaderContentPoint? _capture(
  WidgetTester tester,
  ReaderContentLayoutController controller, {
  String floor = '705',
}) {
  final viewport = tester.getRect(find.byKey(const ValueKey('viewport')));
  return controller.capture(
    floorID: floor,
    top: viewport.top,
    bottom: viewport.bottom,
  );
}

double _globalDy(ReaderContentPoint point) {
  final resolved = point.resolve()!;
  return resolved.box.localToGlobal(Offset(0, resolved.localDy)).dy;
}

Future<void> _finishScrollFrames(
  WidgetTester tester,
  ScrollController scroll,
) async {
  // jumpTo/dimension notifications can leave the Scrollable's own work queued.
  // Require bounded quiescence, rather than treating that first frame as a
  // marker loop or silently accepting an indefinitely self-scheduling fixture.
  for (
    var frame = 0;
    frame < 60 &&
        (scroll.position.isScrollingNotifier.value ||
            tester.binding.hasScheduledFrame);
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(scroll.position.isScrollingNotifier.value, isFalse);
  expect(tester.binding.hasScheduledFrame, isFalse);
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.onLayout, required super.child});
  final VoidCallback onLayout;

  @override
  _RenderLayoutProbe createRenderObject(BuildContext context) =>
      _RenderLayoutProbe(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLayoutProbe renderObject,
  ) {
    renderObject.onLayout = onLayout;
  }
}

class _RenderLayoutProbe extends RenderProxyBox {
  _RenderLayoutProbe(this.onLayout);
  VoidCallback onLayout;

  @override
  void performLayout() {
    // Tight outer dimensions make this the relayout boundary, while the loose
    // child may grow without relaying out an outer FractionalTranslation.
    child?.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(child?.size ?? Size.zero);
    onLayout();
  }
}

void main() {
  testWidgets(
    'unknown media resolve once per floor after its last independent token',
    (tester) async {
      late ReaderContentLayoutController controller;
      final resolved = <(bool, bool)>[];
      controller = ReaderContentLayoutController(
        preserveAnchor: () => () {},
        onGeometryResolved: () => resolved.add((
          controller.hasUnresolvedGeometry('705'),
          controller.hasUnresolvedGeometry('706'),
        )),
      );
      addTearDown(controller.dispose);
      Widget build({
        bool first = true,
        bool second = true,
        bool other = true,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: ReaderContentLayoutScope(
          controller: controller,
          viewportHeight: 300,
          child: ReaderContentFloor(
            floorID: '705',
            child: Column(
              children: [
                ReaderContentGeometry(
                  key: const ValueKey('first-media'),
                  unresolved: first,
                  child: const SizedBox(height: 10),
                ),
                ReaderContentGeometry(
                  key: const ValueKey('second-media'),
                  unresolved: second,
                  child: const SizedBox(height: 10),
                ),
                ReaderContentFloor(
                  floorID: '706',
                  child: ReaderContentGeometry(
                    unresolved: other,
                    child: const SizedBox(height: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(build());
      expect(controller.hasUnresolvedGeometry('705'), isTrue);
      expect(controller.hasUnresolvedGeometry('706'), isTrue);
      expect(controller.hasUnresolvedGeometry('707'), isFalse);
      expect(resolved, isEmpty);
      await tester.pumpWidget(build(first: false));
      expect(controller.hasUnresolvedGeometry('705'), isTrue);
      expect(resolved, isEmpty);
      // An error placeholder still passes unresolved=true. Rebuilding it must
      // neither duplicate its token nor report that its dimensions are ready.
      await tester.pumpWidget(build(first: false));
      expect(resolved, isEmpty);
      await tester.pumpWidget(build(first: false, second: false));
      expect(resolved, [(false, true)]);
      await tester.pumpWidget(build(first: false, second: false, other: false));
      expect(resolved, [(false, true), (false, false)]);
      await tester.pumpWidget(build(first: false, second: false, other: false));
      await tester.pump(const Duration(seconds: 2));
      expect(resolved, hasLength(2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'geometry ownership follows scope and floor without clearing another token',
    (tester) async {
      var firstResolved = 0, secondResolved = 0;
      final first = ReaderContentLayoutController(
        preserveAnchor: () => () {},
        onGeometryResolved: () => firstResolved++,
      );
      final second = ReaderContentLayoutController(
        preserveAnchor: () => () {},
        onGeometryResolved: () => secondResolved++,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget build(
        ReaderContentLayoutController movingController,
        String movingFloor, {
        bool movingUnknown = true,
        bool includeFixed = true,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            if (includeFixed)
              ReaderContentLayoutScope(
                key: const ValueKey('fixed-scope'),
                controller: first,
                viewportHeight: 300,
                child: const ReaderContentFloor(
                  floorID: '705',
                  child: ReaderContentGeometry(
                    unresolved: true,
                    child: SizedBox(height: 10),
                  ),
                ),
              ),
            ReaderContentLayoutScope(
              key: const ValueKey('moving-scope'),
              controller: movingController,
              viewportHeight: 300,
              child: ReaderContentFloor(
                floorID: movingFloor,
                child: ReaderContentGeometry(
                  key: const ValueKey('moving-media'),
                  unresolved: movingUnknown,
                  child: const SizedBox(height: 10),
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pumpWidget(build(first, '705'));
      final state = tester.state(find.byKey(const ValueKey('moving-media')));
      await tester.pumpWidget(build(first, '706'));
      expect(
        tester.state(find.byKey(const ValueKey('moving-media'))),
        same(state),
      );
      expect(first.hasUnresolvedGeometry('705'), isTrue);
      expect(first.hasUnresolvedGeometry('706'), isTrue);
      expect(firstResolved, 0);
      await tester.pumpWidget(build(second, '706'));
      expect(
        tester.state(find.byKey(const ValueKey('moving-media'))),
        same(state),
      );
      expect(first.hasUnresolvedGeometry('705'), isTrue);
      expect(first.hasUnresolvedGeometry('706'), isFalse);
      expect(second.hasUnresolvedGeometry('706'), isTrue);
      expect(firstResolved, 1);
      expect(secondResolved, 0);
      await tester.pumpWidget(build(second, '706', movingUnknown: false));
      expect(second.hasUnresolvedGeometry('706'), isFalse);
      expect(secondResolved, 1);
      await tester.pumpWidget(
        build(second, '706', movingUnknown: false, includeFixed: false),
      );
      expect(first.hasUnresolvedGeometry('705'), isFalse);
      expect(firstResolved, 2);
      expect(secondResolved, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'disposing a controller clears unknown geometry without callbacks or revival',
    (tester) async {
      var resolved = 0;
      final controller = ReaderContentLayoutController(
        preserveAnchor: () => () {},
        onGeometryResolved: () => resolved++,
      );
      addTearDown(controller.dispose);
      Widget build(bool unresolved) => ReaderContentLayoutScope(
        controller: controller,
        viewportHeight: 300,
        child: ReaderContentFloor(
          floorID: '705',
          child: ReaderContentGeometry(
            unresolved: unresolved,
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );

      await tester.pumpWidget(build(true));
      expect(controller.hasUnresolvedGeometry('705'), isTrue);
      controller.dispose();
      expect(controller.hasUnresolvedGeometry('705'), isFalse);
      expect(resolved, 0);
      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      expect(controller.hasUnresolvedGeometry('705'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(resolved, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'a change captures the visible leaf before an earlier image grows',
    (tester) async {
      final scroll = ScrollController();
      late ReaderContentLayoutController controller;
      late BuildContext changeContext;
      ReaderContentPoint? point;
      final events = <double>[];
      var openingHeight = 120.0;
      controller = ReaderContentLayoutController(
        preserveAnchor: () {
          point = _capture(tester, controller);
          events.add(_globalDy(point!));
          return () => events.add(_globalDy(point!));
        },
      );
      addTearDown(scroll.dispose);
      addTearDown(controller.dispose);
      Widget build() => _document(
        controller: controller,
        scroll: scroll,
        child: Builder(
          builder: (context) {
            changeContext = context;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ReaderContentBlock(child: SizedBox(height: openingHeight)),
                const ReaderContentBlock(child: SizedBox(height: 800)),
                const ReaderContentBlock(child: SizedBox(height: 800)),
              ],
            );
          },
        ),
      );

      await tester.pumpWidget(build());
      scroll.jumpTo(200);
      await tester.pump();
      expect(
        events,
        isEmpty,
        reason: 'Ordinary scrolling cannot start a transaction.',
      );
      ReaderContentLayoutScope.prepareChange(changeContext);
      expect(events, [0]);
      final original = point!.resolve()!;
      expect(original.localDy, closeTo(80, .01));
      expect(
        ReaderContentLayoutScope.maybeViewportHeightOf(changeContext),
        300,
      );
      expect(_capture(tester, controller, floor: '706'), isNull);

      openingHeight = 300;
      await tester.pumpWidget(build());
      expect(events, [0, 180]);
      expect(point!.resolve()!.box, same(original.box));
      expect(point!.resolve()!.localDy, closeTo(80, .01));
      await tester.pump();
      expect(
        events,
        hasLength(2),
        reason: 'The post-layout callback runs only once.',
      );
    },
  );

  testWidgets(
    'a long report retains its relative internal position when resized',
    (tester) async {
      final scroll = ScrollController();
      var preserves = 0;
      final controller = ReaderContentLayoutController(
        preserveAnchor: () {
          preserves++;
          return () {};
        },
      );
      addTearDown(scroll.dispose);
      addTearDown(controller.dispose);
      Widget build(double height, {bool variableSize = true}) => _document(
        controller: controller,
        scroll: scroll,
        child: ReaderContentBlock(
          variableSize: variableSize,
          child: SizedBox(height: height),
        ),
      );
      await tester.pumpWidget(build(800));
      scroll.jumpTo(200);
      await tester.pump();
      await _finishScrollFrames(tester, scroll);
      expect(controller.hasVariableMedia('705'), isTrue);
      expect(controller.hasVariableMedia('706'), isFalse);
      final point = _capture(tester, controller)!;
      final before = point.resolve()!;
      expect(before.localDy, closeTo(200, .01));
      expect(_globalDy(point), closeTo(0, .01));

      await tester.pumpWidget(build(1600));
      final after = point.resolve()!;
      expect(after.box, same(before.box));
      expect(after.localDy, closeTo(400, .01));
      expect(_globalDy(point), closeTo(200, .01));
      await _finishScrollFrames(tester, scroll);
      await tester.pumpWidget(build(1600, variableSize: false));
      await _finishScrollFrames(tester, scroll);
      expect(controller.hasVariableMedia('705'), isFalse);
      expect(point.resolve()!.box, same(before.box));
      expect(preserves, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        controller.capture(floorID: '705', top: double.nan, bottom: 300),
        isNull,
      );
    },
  );

  testWidgets(
    'an ancestor layout resolves local points without crossing outer translations',
    (tester) async {
      final controller = ReaderContentLayoutController(
        preserveAnchor: () => () {},
      );
      addTearDown(controller.dispose);
      ReaderContentPoint? point;
      final localOffsets = <double?>[];
      Widget build(double height) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: FractionalTranslation(
            translation: const Offset(0, .1),
            child: SizedBox(
              width: 100,
              height: 300,
              child: _LayoutProbe(
                onLayout: () {
                  if (point != null) {
                    localOffsets.add(point.resolve()?.localDy);
                  }
                },
                child: ReaderContentLayoutScope(
                  controller: controller,
                  viewportHeight: 300,
                  child: ReaderContentFloor(
                    floorID: '705',
                    child: Padding(
                      // The probe is not the marker's immediate parent.
                      padding: EdgeInsets.zero,
                      child: ReaderContentBlock(
                        child: SizedBox(width: 100, height: height),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build(100));
      expect(tester.takeException(), isNull);
      // Capture in the completed old layout, before the descendant changes.
      // The outer translation contributes 30 global pixels to this point.
      point = controller.capture(floorID: '705', top: 55, bottom: 330);
      expect(point, isNotNull);
      expect(point!.resolve()!.localDy, closeTo(25, .001));
      expect(localOffsets, isEmpty);
      await tester.pumpWidget(build(200));
      expect(tester.takeException(), isNull);
      expect(localOffsets, [50]);
    },
  );

  testWidgets(
    'reassigned, hidden, detached and disposed blocks retire their points',
    (tester) async {
      final scroll = ScrollController();
      final first = ReaderContentLayoutController(preserveAnchor: () => () {});
      var restores = 0;
      final second = ReaderContentLayoutController(
        preserveAnchor: () =>
            () => restores++,
      );
      late BuildContext changeContext;
      addTearDown(scroll.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget build(
        ReaderContentLayoutController controller,
        String floor, {
        bool offstage = false,
      }) => _document(
        controller: controller,
        scroll: scroll,
        floor: floor,
        offstage: offstage,
        child: Builder(
          builder: (context) {
            changeContext = context;
            return const ReaderContentBlock(
              variableSize: true,
              child: SizedBox(height: 800),
            );
          },
        ),
      );

      await tester.pumpWidget(build(first, '705'));
      expect(first.hasVariableMedia('705'), isTrue);
      final oldFloor = _capture(tester, first)!;
      await tester.pumpWidget(build(first, '706'));
      expect(first.hasVariableMedia('705'), isFalse);
      expect(first.hasVariableMedia('706'), isTrue);
      expect(oldFloor.resolve(), isNull);
      expect(_capture(tester, first), isNull);
      final oldController = _capture(tester, first, floor: '706')!;
      await tester.pumpWidget(build(second, '706'));
      expect(first.hasVariableMedia('706'), isFalse);
      expect(second.hasVariableMedia('706'), isTrue);
      expect(oldController.resolve(), isNull);
      expect(_capture(tester, first, floor: '706'), isNull);
      final hidden = _capture(tester, second, floor: '706')!;
      await tester.pumpWidget(build(second, '706', offstage: true));
      expect(hidden.resolve(), isNull);
      expect(_capture(tester, second, floor: '706'), isNull);
      await tester.pumpWidget(build(second, '706'));
      final detached = _capture(tester, second, floor: '706')!;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.hasVariableMedia('706'), isFalse);
      expect(detached.resolve(), isNull);
      expect(second.capture(floorID: '706', top: 0, bottom: 300), isNull);
      await tester.pumpWidget(build(second, '706'));
      expect(
        detached.resolve(),
        isNull,
        reason: 'A remount cannot revive old points.',
      );
      final disposed = _capture(tester, second, floor: '706')!;
      ReaderContentLayoutScope.prepareChange(changeContext);
      second.dispose();
      expect(second.hasVariableMedia('706'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(disposed.resolve(), isNull);
      expect(
        restores,
        0,
        reason: 'A disposed controller cannot restore later.',
      );
    },
  );

  testWidgets(
    'outside a reader the marker is transparent and changes are inert',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (value) {
              context = value;
              return const ReaderContentGeometry(
                unresolved: true,
                child: ReaderContentBlock(
                  child: SizedBox(
                    key: ValueKey('plain-child'),
                    width: 50,
                    height: 50,
                  ),
                ),
              );
            },
          ),
        ),
      );
      final marker = tester.renderObject<RenderBox>(
        find.byType(ReaderContentBlock),
      );
      final child = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('plain-child')),
      );
      expect(marker, same(child));
      expect(
        tester.renderObject(find.byType(ReaderContentGeometry)),
        same(child),
      );
      expect(ReaderContentLayoutScope.maybeViewportHeightOf(context), isNull);
      ReaderContentLayoutScope.prepareChange(context);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
