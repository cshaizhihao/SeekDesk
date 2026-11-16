import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_focus_region.dart';

const _items = [
  GlassSegment(label: '第一项', icon: Icon(CupertinoIcons.pencil)),
  GlassSegment(label: '第二项', icon: Icon(CupertinoIcons.eye)),
  GlassSegment(label: '第三项', icon: Icon(CupertinoIcons.doc)),
];

const _fourItems = [
  ..._items,
  GlassSegment(label: '第四项', icon: Icon(CupertinoIcons.gear)),
];

class _Harness extends StatefulWidget {
  const _Harness({
    required this.initialItems,
    required this.inverted,
    super.key,
  });

  final List<GlassSegment> initialItems;
  final bool inverted;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<GlassSegment> items = widget.initialItems;
  int selected = 0;
  double width = 420;
  double textScale = 1;
  Axis direction = Axis.horizontal;
  TextDirection textDirection = TextDirection.ltr;
  Brightness brightness = Brightness.light;
  Color? activeColor;
  ValueChanged<int>? onSelection;
  bool acceptSelection = true;
  bool reduceMotion = false;
  bool visible = true;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    final foreground = brightness == Brightness.light
        ? const Color(0xFF222222)
        : const Color(0xFFEEEEEE);
    // Capture this build's callback so replacing it really exercises the
    // control's rebuilt labels, rather than a permanently live harness closure.
    final callback = onSelection;
    return CupertinoApp(
      theme: CupertinoThemeData(
        brightness: brightness,
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(color: foreground),
        ),
      ),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: Directionality(
            textDirection: textDirection,
            child: GlassAdaptiveScope(
              // Widget tests exercise the same motion/label implementation
              // without depending on a host GPU or shader compilation.
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: CupertinoPageScaffold(
                child: Center(
                  child: SizedBox(
                    width: direction == Axis.horizontal ? width : 96,
                    child: !visible
                        ? const SizedBox.shrink()
                        : GlassSegmentedControl(
                            segments: items,
                            selectedIndex: selected,
                            onSegmentSelected: (index) {
                              callback?.call(index);
                              if (acceptSelection) {
                                setState(() => selected = index);
                              }
                            },
                            direction: direction,
                            height: 72,
                            segmentExtent: 72,
                            quality: GlassQuality.premium,
                            indicatorColor: widget.inverted
                                ? const Color(0xFF000000)
                                : null,
                            activeSelectedColor: activeColor,
                            selectedIconColor: widget.inverted
                                ? const Color(0xFFFFFFFF)
                                : null,
                            selectedTextStyle: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: widget.inverted
                                  ? const Color(0xFFFFFFFF)
                                  : null,
                            ),
                            unselectedTextStyle: const TextStyle(fontSize: 13),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  List<GlassSegment> items = _items,
  bool inverted = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  final key = GlobalKey<_HarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    _Harness(key: key, initialItems: items, inverted: inverted),
  );
  await _settle(tester);
  return key.currentState!;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 16),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Finder _region(String label) => find.byWidgetPredicate(
  (widget) => widget is GlassFocusRegion && widget.semanticLabel == label,
);

AnimatedGlassIndicator _indicator(WidgetTester tester) => tester
    .widgetList<AnimatedGlassIndicator>(find.byType(AnimatedGlassIndicator))
    .firstWhere((indicator) => indicator.paintBackground);

Alignment _alignment(WidgetTester tester) => _indicator(tester).alignment
    .resolve(
      Directionality.of(tester.element(find.byType(GlassSegmentedControl))),
    );

Color? _labelColor(WidgetTester tester, String label) => tester
    .widget<AnimatedDefaultTextStyle>(
      find.descendant(
        of: _region(label),
        matching: find.byType(AnimatedDefaultTextStyle),
      ),
    )
    .style
    .color;

Color? _iconColor(WidgetTester tester, String label) => IconTheme.of(
  tester.element(
    find.descendant(of: _region(label), matching: find.byType(Icon)),
  ),
).color;

void _semanticTap(WidgetTester tester, String label) {
  final node = tester.getSemantics(find.bySemanticsLabel(label));
  tester
      .renderObject(find.byType(GlassSegmentedControl))
      .owner!
      .semanticsOwner!
      .performAction(node.id, SemanticsAction.tap);
}

Future<TestGesture> _dragBetween(
  WidgetTester tester,
  String from,
  String to, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final start = tester.getCenter(_region(from));
  final end = tester.getCenter(_region(to));
  final gesture = await tester.startGesture(start, kind: kind);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveTo(Offset.lerp(start, end, .3)!);
  await tester.pump(const Duration(milliseconds: 40));
  await gesture.moveTo(end);
  await tester.pump(const Duration(milliseconds: 120));
  await gesture.moveTo(end);
  return gesture;
}

Future<TestGesture> _timedDrag(
  WidgetTester tester,
  Offset start,
  Offset end, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  int steps = 8,
  int stepMilliseconds = 8,
  int? pointerId,
}) async {
  final pointer = await tester.startGesture(
    start,
    kind: kind,
    pointer: pointerId,
  );
  for (var step = 1; step <= steps; step++) {
    await pointer.moveTo(
      Offset.lerp(start, end, step / steps)!,
      timeStamp: Duration(milliseconds: step * stepMilliseconds),
    );
    await tester.pump(Duration(milliseconds: stepMilliseconds));
  }
  return pointer;
}

void _expectRest(WidgetTester tester, int index, {int count = 3}) {
  final indicator = _indicator(tester);
  final alignment = indicator.alignment.resolve(TextDirection.ltr);
  expect(
    indicator.direction == Axis.horizontal ? alignment.x : alignment.y,
    closeTo(2 * index / (count - 1) - 1, .001),
  );
  expect(indicator.thickness, closeTo(0, .001));
  expect(tester.binding.transientCallbackCount, 0);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final axis in Axis.values) {
    for (final direction in TextDirection.values) {
      for (final startIndex in [0, 2]) {
        for (final slow in [false, true]) {
          testWidgets(
            'timed mouse drag lands on middle item from $startIndex $axis $direction slow=$slow',
            (tester) async {
              final h = await _mount(tester, items: _fourItems);
              final calls = <int>[];
              h.update(() {
                h.direction = axis;
                h.textDirection = direction;
                h.selected = startIndex;
                h.onSelection = calls.add;
              });
              await _settle(tester);
              final pointer = await _timedDrag(
                tester,
                tester.getCenter(_region(_fourItems[startIndex].label!)),
                tester.getCenter(_region('第二项')),
                steps: slow ? 40 : 8,
                stepMilliseconds: slow ? 20 : 8,
              );
              expect(calls, isEmpty);
              await pointer.up(
                timeStamp: Duration(milliseconds: slow ? 801 : 65),
              );
              await pointer.removePointer();
              await _settle(tester);
              expect(calls, [1]);
              expect(h.selected, 1);
              _expectRest(tester, 1, count: 4);
            },
          );
        }
      }

      for (final fraction in [.05, .95]) {
        testWidgets(
          'fast mouse release inside middle cell edge $fraction $axis $direction',
          (tester) async {
            final h = await _mount(tester, items: _fourItems);
            final calls = <int>[];
            h.update(() {
              h.direction = axis;
              h.textDirection = direction;
              h.onSelection = calls.add;
            });
            await _settle(tester);
            final cell = tester.getRect(_region('第二项'));
            final end = axis == Axis.horizontal
                ? Offset(cell.left + cell.width * fraction, cell.center.dy)
                : Offset(cell.center.dx, cell.top + cell.height * fraction);
            final pointer = await _timedDrag(
              tester,
              tester.getCenter(_region('第一项')),
              end,
            );
            await pointer.up(timeStamp: const Duration(milliseconds: 65));
            await pointer.removePointer();
            await _settle(tester);
            expect(calls, [1]);
            _expectRest(tester, 1, count: 4);
          },
        );
      }

      testWidgets('touch retains fast flick projection $axis $direction', (
        tester,
      ) async {
        final h = await _mount(tester, items: _fourItems);
        final calls = <int>[];
        h.update(() {
          h.direction = axis;
          h.textDirection = direction;
          h.onSelection = calls.add;
        });
        await _settle(tester);
        final pointer = await _timedDrag(
          tester,
          tester.getCenter(_region('第一项')),
          tester.getCenter(_region('第二项')),
          kind: PointerDeviceKind.touch,
        );
        await pointer.up(timeStamp: const Duration(milliseconds: 65));
        await _settle(tester);
        expect(calls, [3]);
        _expectRest(tester, 3, count: 4);
      });
    }
  }

  for (final outcome in ['refused', 'cancelled', 'disabled']) {
    testWidgets('fast mouse middle landing preserves $outcome', (tester) async {
      final h = await _mount(
        tester,
        items: [
          _fourItems[0],
          GlassSegment(label: '第二项', enabled: outcome != 'disabled'),
          ..._fourItems.skip(2),
        ],
      );
      final calls = <int>[];
      h.update(() {
        h.acceptSelection = outcome != 'refused';
        h.onSelection = calls.add;
      });
      await _settle(tester);
      final pointer = await _timedDrag(
        tester,
        tester.getCenter(_region('第一项')),
        tester.getCenter(_region('第二项')),
      );
      if (outcome == 'cancelled') {
        await pointer.cancel(timeStamp: const Duration(milliseconds: 65));
      } else {
        await pointer.up(timeStamp: const Duration(milliseconds: 65));
      }
      await pointer.removePointer();
      await _settle(tester);
      expect(calls, outcome == 'refused' ? [1] : isEmpty);
      _expectRest(tester, 0, count: 4);
    });
  }

  testWidgets('successive drags retain each device landing behavior', (
    tester,
  ) async {
    final h = await _mount(tester, items: _fourItems);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await _settle(tester);
    final routes = [
      (PointerDeviceKind.mouse, 0, 1, 1),
      (PointerDeviceKind.touch, 1, 2, 3),
      (PointerDeviceKind.mouse, 3, 2, 2),
    ];
    for (final (kind, from, to, expected) in routes) {
      final pointer = await _timedDrag(
        tester,
        tester.getCenter(_region(_fourItems[from].label!)),
        tester.getCenter(_region(_fourItems[to].label!)),
        kind: kind,
      );
      await pointer.up(timeStamp: const Duration(milliseconds: 65));
      await pointer.removePointer();
      await _settle(tester);
      expect(h.selected, expected);
      _expectRest(tester, expected, count: 4);
    }
    expect(calls, [1, 3, 2]);
  });

  testWidgets('mouse uses coordinates delivered only with pointer up', (
    tester,
  ) async {
    final h = await _mount(tester, items: _fourItems);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await _settle(tester);
    final pointer = await _timedDrag(
      tester,
      tester.getCenter(_region('第一项')),
      tester.getCenter(_region('第二项')),
      pointerId: 501,
    );
    await pointer.updateWithCustomEvent(
      PointerUpEvent(
        pointer: 501,
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(_region('第三项')),
        timeStamp: const Duration(milliseconds: 65),
      ),
    );
    await pointer.removePointer();
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 2, count: 4);
  });

  testWidgets('mouse button change ends drag without committing selection', (
    tester,
  ) async {
    final h = await _mount(tester, items: _fourItems);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await _settle(tester);
    final end = tester.getCenter(_region('第二项'));
    final pointer = await _timedDrag(
      tester,
      tester.getCenter(_region('第一项')),
      end,
      pointerId: 502,
    );
    await pointer.updateWithCustomEvent(
      PointerMoveEvent(
        pointer: 502,
        device: 1,
        kind: PointerDeviceKind.mouse,
        buttons: 2,
        position: end,
        timeStamp: const Duration(milliseconds: 65),
      ),
    );
    await _settle(tester);
    expect(calls, isEmpty);
    _expectRest(tester, 0, count: 4);
    await pointer.up(timeStamp: const Duration(milliseconds: 400));
    await pointer.removePointer();
    await _settle(tester);
    expect(calls, isEmpty);
    await tester.tap(_region('第二项'));
    await _settle(tester);
    expect(calls, [1]);
    _expectRest(tester, 1, count: 4);
  });

  for (final firstKind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('overlapping mouse and touch cancel $firstKind first', (
      tester,
    ) async {
      final h = await _mount(tester, items: _fourItems);
      final calls = <int>[];
      h.update(() => h.onSelection = calls.add);
      await _settle(tester);
      final first = await _timedDrag(
        tester,
        tester.getCenter(_region('第一项')),
        tester.getCenter(_region('第二项')),
        kind: firstKind,
        pointerId: 503,
      );
      final second = await tester.startGesture(
        tester.getCenter(_region('第四项')),
        pointer: 504,
        kind: firstKind == PointerDeviceKind.mouse
            ? PointerDeviceKind.touch
            : PointerDeviceKind.mouse,
      );
      await second.moveBy(
        const Offset(-10, -10),
        timeStamp: const Duration(milliseconds: 70),
      );
      await first.up(timeStamp: const Duration(milliseconds: 80));
      await second.up(timeStamp: const Duration(milliseconds: 90));
      await first.removePointer();
      await second.removePointer();
      await _settle(tester);
      expect(calls, isEmpty);
      _expectRest(tester, 0, count: 4);
      await tester.tap(_region('第二项'));
      await _settle(tester);
      expect(calls, [1]);
      _expectRest(tester, 1, count: 4);
    });
  }

  for (final change in ['axis', 'size', 'removed']) {
    testWidgets('fast mouse release after $change does not submit old target', (
      tester,
    ) async {
      final h = await _mount(tester, items: _fourItems);
      final calls = <int>[];
      h.update(() => h.onSelection = calls.add);
      await _settle(tester);
      final pointer = await _timedDrag(
        tester,
        tester.getCenter(_region('第一项')),
        tester.getCenter(_region('第二项')),
      );
      h.update(() {
        switch (change) {
          case 'axis':
            h.direction = Axis.vertical;
          case 'size':
            h.width = 360;
          case 'removed':
            h.visible = false;
        }
      });
      await tester.pump();
      await pointer.up(timeStamp: const Duration(milliseconds: 65));
      await pointer.removePointer();
      await _settle(tester);
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
      if (change == 'removed') {
        h.update(() => h.visible = true);
        await _settle(tester);
      }
      _expectRest(tester, 0, count: 4);
      await tester.tap(_region('第二项'));
      await _settle(tester);
      expect(calls, [1]);
      _expectRest(tester, 1, count: 4);
    });
  }

  for (final axis in Axis.values) {
    for (final rtl in [false, true]) {
      testWidgets('single mouse move reaches the drag target $axis RTL=$rtl', (
        tester,
      ) async {
        final h = await _mount(tester);
        final calls = <int>[];
        h.update(() {
          h.direction = axis;
          h.textDirection = rtl ? TextDirection.rtl : TextDirection.ltr;
          h.onSelection = calls.add;
        });
        await _settle(tester);
        final pointer = await tester.startGesture(
          tester.getCenter(_region('第一项')),
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveTo(tester.getCenter(_region('第三项')));
        await pointer.up();
        await pointer.removePointer();
        await _settle(tester);
        expect(calls, [2]);
        _expectRest(tester, 2);
      });
    }
  }

  for (final outcome in ['refused', 'cancelled', 'disabled']) {
    testWidgets('single-move drag preserves the $outcome guard', (
      tester,
    ) async {
      final h = await _mount(
        tester,
        items: [
          _items[0],
          _items[1],
          GlassSegment(label: '第三项', enabled: outcome != 'disabled'),
        ],
      );
      final calls = <int>[];
      h.update(() {
        h.acceptSelection = outcome != 'refused';
        h.onSelection = calls.add;
      });
      await tester.pump();
      final pointer = await tester.startGesture(
        tester.getCenter(_region('第一项')),
        kind: PointerDeviceKind.mouse,
      );
      await pointer.moveTo(tester.getCenter(_region('第三项')));
      if (outcome == 'cancelled') {
        await pointer.cancel();
      } else {
        await pointer.up();
      }
      await pointer.removePointer();
      await _settle(tester);
      expect(calls, outcome == 'refused' ? [2] : isEmpty);
      _expectRest(tester, 0);
    });
  }

  testWidgets('rejected drag returns glass to the controlled selection', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final h = await _mount(tester);
      final calls = <int>[];
      h.update(() {
        h.acceptSelection = false;
        h.onSelection = calls.add;
      });
      await tester.pump();
      final gesture = await _dragBetween(tester, '第一项', '第三项');
      await gesture.up();
      await _settle(tester);
      expect(calls, [2]);
      expect(h.selected, 0);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('第一项'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      _expectRest(tester, 0);
      h.update(() => h.width = 390);
      await _settle(tester);
      _expectRest(tester, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('drag cannot select a disabled segment', (tester) async {
    final h = await _mount(
      tester,
      items: const [
        GlassSegment(label: '第一项'),
        GlassSegment(label: '第二项', enabled: false),
        GlassSegment(label: '第三项', enabled: false),
      ],
    );
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await tester.pump();
    final gesture = await _dragBetween(tester, '第一项', '第三项');
    await gesture.up();
    await _settle(tester);
    expect(calls, isEmpty);
    expect(h.selected, 0);
    _expectRest(tester, 0);
  });

  testWidgets('pointer cancellation restores glass without requesting a tab', (
    tester,
  ) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await tester.pump();
    final gesture = await _dragBetween(tester, '第一项', '第三项');
    await gesture.cancel();
    await _settle(tester);
    expect(calls, isEmpty);
    expect(h.selected, 0);
    _expectRest(tester, 0);
  });

  for (final axis in Axis.values) {
    for (final direction in TextDirection.values) {
      testWidgets('slow drag selects its actual center in $axis $direction', (
        tester,
      ) async {
        final h = await _mount(tester);
        final calls = <int>[];
        h.update(() {
          h.direction = axis;
          h.textDirection = direction;
          h.onSelection = calls.add;
        });
        await _settle(tester);
        final gesture = await _dragBetween(tester, '第一项', '第二项');
        await gesture.up();
        await _settle(tester);
        expect(calls, [1]);
        expect(h.selected, 1);
        _expectRest(tester, 1);
      });
    }
  }

  testWidgets('a deferred tap requests selection only once after release', (
    tester,
  ) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() {
      h.acceptSelection = false;
      h.onSelection = calls.add;
    });
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(_region('第三项')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, isEmpty);
    await gesture.up();
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 0);
  });

  testWidgets('cancelling a press on another segment submits nothing', (
    tester,
  ) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(_region('第三项')));
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.cancel();
    await _settle(tester);
    expect(calls, isEmpty);
    _expectRest(tester, 0);
  });

  testWidgets('RTL flick projects toward the physical motion', (tester) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() {
      h.textDirection = TextDirection.rtl;
      h.selected = 1;
      h.onSelection = calls.add;
    });
    await _settle(tester);
    final start = tester.getCenter(_region('第二项'));
    final gesture = await tester.startGesture(start);
    for (var step = 1; step <= 6; step++) {
      await gesture.moveTo(
        start + Offset(-10.0 * step, 0),
        timeStamp: Duration(milliseconds: step * 10),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 70));
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 2);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'deferred selection stays controlled with motion=$reduceMotion',
      (tester) async {
        final h = await _mount(tester);
        final calls = <int>[];
        h.update(() {
          h.acceptSelection = false;
          h.reduceMotion = reduceMotion;
          h.onSelection = calls.add;
        });
        await tester.pump();
        final first = await _dragBetween(tester, '第一项', '第三项');
        await first.up();
        await _settle(tester);
        expect(calls, [2]);
        _expectRest(tester, 0);
        h.update(() => h.selected = 2);
        await _settle(tester);
        _expectRest(tester, 2);
        final second = await _dragBetween(tester, '第三项', '第一项');
        await second.up();
        await _settle(tester);
        expect(calls, [2, 0]);
        _expectRest(tester, 2);
        h.update(() => h.selected = 0);
        await _settle(tester);
        _expectRest(tester, 0);
      },
    );
  }

  for (final mutation in [
    'selected',
    'axis',
    'direction',
    'count',
    'order',
    'enabled',
    'size',
  ]) {
    testWidgets('a $mutation change invalidates only the held gesture', (
      tester,
    ) async {
      final h = await _mount(tester);
      final calls = <int>[];
      h.update(() => h.onSelection = calls.add);
      await tester.pump();
      final gesture = await _dragBetween(tester, '第一项', '第三项');
      h.update(() {
        switch (mutation) {
          case 'selected':
            h.selected = 1;
          case 'axis':
            h.direction = Axis.vertical;
          case 'direction':
            h.textDirection = TextDirection.rtl;
          case 'count':
            h.items = _items.take(2).toList();
          case 'order':
            h.items = [_items[0], _items[2], _items[1]];
          case 'enabled':
            h.items = const [
              GlassSegment(label: '第一项'),
              GlassSegment(label: '第二项'),
              GlassSegment(label: '第三项', enabled: false),
            ];
          case 'size':
            h.width = 330;
        }
      });
      await tester.pump();
      await gesture.up();
      await _settle(tester);
      expect(calls, isEmpty);
      _expectRest(tester, h.selected, count: h.items.length);
      final target = h.items.lastIndexWhere((item) => item.enabled);
      await tester.tap(_region(h.items[target].label!));
      await _settle(tester);
      expect(calls, [target]);
      _expectRest(tester, target, count: h.items.length);
    });
  }

  testWidgets(
    'reordered held tap is ignored and semantic activation recovers',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final h = await _mount(tester);
        final calls = <int>[];
        h.update(() => h.onSelection = calls.add);
        await tester.pump();
        final gesture = await tester.startGesture(
          tester.getCenter(_region('第三项')),
        );
        await tester.pump(const Duration(milliseconds: 150));
        h.update(() => h.items = [_items[0], _items[2], _items[1]]);
        await tester.pump();
        await gesture.up();
        await _settle(tester);
        expect(calls, isEmpty);
        _expectRest(tester, 0);
        _semanticTap(tester, '第三项');
        await _settle(tester);
        expect(calls, [1]);
        _expectRest(tester, 1);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('unrelated rebuild during drag preserves the selection request', (
    tester,
  ) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await tester.pump();
    final gesture = await _dragBetween(tester, '第一项', '第三项');
    h.update(() {
      h.brightness = Brightness.dark;
      h.items = List.of(_items);
    });
    await tester.pump();
    await gesture.up();
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 2);
  });

  testWidgets('mouse drag recovers after refusal and pointer cancellation', (
    tester,
  ) async {
    final h = await _mount(tester);
    final calls = <int>[];
    h.update(() {
      h.acceptSelection = false;
      h.onSelection = calls.add;
    });
    await tester.pump();
    final refused = await _dragBetween(
      tester,
      '第一项',
      '第三项',
      kind: PointerDeviceKind.mouse,
    );
    await refused.up();
    await refused.removePointer();
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 0);
    h.update(() => h.acceptSelection = true);
    await tester.pump();
    final cancelled = await _dragBetween(
      tester,
      '第一项',
      '第三项',
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.cancel();
    await cancelled.removePointer();
    await _settle(tester);
    expect(calls, [2]);
    _expectRest(tester, 0);
    final accepted = await _dragBetween(
      tester,
      '第一项',
      '第二项',
      kind: PointerDeviceKind.mouse,
    );
    await accepted.up();
    await accepted.removePointer();
    await _settle(tester);
    expect(calls, [2, 1]);
    _expectRest(tester, 1);
  });

  for (final drag in [false, true]) {
    for (final cancel in [false, true]) {
      testWidgets('removing a held control handles drag=$drag cancel=$cancel', (
        tester,
      ) async {
        final h = await _mount(tester);
        final calls = <int>[];
        h.update(() => h.onSelection = calls.add);
        await tester.pump();
        final pointer = drag
            ? await _dragBetween(tester, '第一项', '第三项')
            : await tester.startGesture(tester.getCenter(_region('第三项')));
        await tester.pump(const Duration(milliseconds: 150));
        h.update(() => h.visible = false);
        await tester.pump();
        if (cancel) {
          await pointer.cancel();
        } else {
          await pointer.up();
        }
        await _settle(tester);
        expect(calls, isEmpty);
        expect(tester.takeException(), isNull);
        h.update(() => h.visible = true);
        await _settle(tester);
        await tester.tap(_region('第二项'));
        await _settle(tester);
        expect(calls, [1]);
        _expectRest(tester, 1);
      });
    }
  }

  testWidgets('icon-only replacement invalidates a held tap', (tester) async {
    const icons = [
      GlassSegment(icon: Icon(CupertinoIcons.doc), semanticLabel: '文件'),
      GlassSegment(icon: Icon(CupertinoIcons.eye), semanticLabel: '查看'),
      GlassSegment(icon: Icon(CupertinoIcons.pencil), semanticLabel: '编辑'),
    ];
    final h = await _mount(tester, items: icons);
    final calls = <int>[];
    h.update(() => h.onSelection = calls.add);
    await tester.pump();
    final pointer = await tester.startGesture(tester.getCenter(_region('编辑')));
    await tester.pump(const Duration(milliseconds: 150));
    h.update(() => h.items = [icons[0], icons[2], icons[1]]);
    await tester.pump();
    await pointer.up();
    await _settle(tester);
    expect(calls, isEmpty);
    _expectRest(tester, 0);
    await tester.tap(_region('编辑'));
    await _settle(tester);
    expect(calls, [1]);
    _expectRest(tester, 1);
  });

  testWidgets('settling spring retains ordinary label widgets while moving', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.update(() => h.selected = 2);
    await tester.pump();
    final widgets = [
      for (final item in _items) tester.widget(_region(item.label!)),
    ];
    final elements = [
      for (final item in _items) tester.element(_region(item.label!)),
    ];
    final positions = [_alignment(tester).x];
    for (final milliseconds in [16, 16, 32, 48]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      positions.add(_alignment(tester).x);
      for (var i = 0; i < _items.length; i++) {
        expect(tester.widget(_region(_items[i].label!)), same(widgets[i]));
        expect(tester.element(_region(_items[i].label!)), same(elements[i]));
      }
    }
    // The identity assertion must not pass by accidentally freezing motion.
    expect(positions.any((x) => (x - positions.first).abs() > .1), isTrue);
    await _settle(tester);
    expect(_alignment(tester).x, closeTo(1, .001));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inverted lens keeps moving foreground colors and restores rest',
    (tester) async {
      final h = await _mount(tester, inverted: true);
      const white = Color(0xFFFFFFFF);
      const foreground = Color(0xFF222222);
      expect(_labelColor(tester, '第一项'), white);
      expect(_iconColor(tester, '第一项'), white);
      h.update(() => h.selected = 2);
      await tester.pump();
      // isMoving uses lens contrast immediately, before thickness ramps up.
      expect(_labelColor(tester, '第三项'), foreground);
      expect(_iconColor(tester, '第三项'), foreground);
      await tester.pump(const Duration(milliseconds: 32));
      expect(_labelColor(tester, '第三项'), foreground);
      await _settle(tester);
      expect(_labelColor(tester, '第三项'), white);
      expect(_iconColor(tester, '第三项'), white);

      const explicit = Color(0xFF1155DD);
      h.update(() {
        h.activeColor = explicit;
        h.selected = 0;
      });
      await tester.pump();
      expect(_labelColor(tester, '第一项'), explicit);
      expect(_iconColor(tester, '第一项'), explicit);
      await _settle(tester);
      expect(_labelColor(tester, '第一项'), white);
      expect(_iconColor(tester, '第一项'), white);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-count configuration replaces names semantics and actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final h = await _mount(tester);
      final calls = <String>[];
      h.update(() => h.onSelection = (index) => calls.add('old:$index'));
      await tester.pump();
      h.update(() {
        h.selected = 2;
        h.items = const [
          GlassSegment(label: '第一项改名', semanticLabel: '新的第一项'),
          GlassSegment(label: '暂不可用', enabled: false),
          GlassSegment(label: '第三项'),
        ];
        h.onSelection = (index) => calls.add('new:$index');
      });
      await tester.pump();
      expect(find.text('第一项'), findsNothing);
      expect(find.bySemanticsLabel('新的第一项'), findsOneWidget);
      expect(find.bySemanticsLabel('第三项'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('第三项'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('暂不可用'))
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        Tristate.isFalse,
      );
      await tester.tapAt(tester.getCenter(_region('暂不可用')));
      _semanticTap(tester, '暂不可用');
      await tester.pump();
      expect(calls, isEmpty);
      _semanticTap(tester, '新的第一项');
      await tester.pump();
      expect(calls, ['new:0']);
      expect(h.selected, 0);

      // Reorder and enable items without changing their count while in transit.
      h.update(() {
        h.items = const [
          GlassSegment(label: '第三项'),
          GlassSegment(label: '已启用'),
          GlassSegment(label: '第一项改名'),
        ];
        h.selected = 0;
      });
      await tester.pump();
      _semanticTap(tester, '已启用');
      await _settle(tester);
      expect(calls, ['new:0', 'new:1']);
      expect(h.selected, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('retained labels respond to scale theme RTL and new geometry', (
    tester,
  ) async {
    final h = await _mount(tester);
    final originalTextHeight = tester.getSize(find.text('第二项')).height;
    h.update(() => h.selected = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    h.update(() {
      h.width = 360;
      h.textScale = 1.8;
      h.brightness = Brightness.dark;
      h.textDirection = TextDirection.rtl;
    });
    await _settle(tester);
    expect(tester.getSize(find.byType(GlassSegmentedControl)).width, 360);
    expect(
      tester.getSize(find.text('第二项')).height,
      greaterThan(originalTextHeight),
    );
    expect(_labelColor(tester, '第三项'), const Color(0xFFEEEEEE));
    expect(_alignment(tester).x, closeTo(-1, .001));
    expect(
      tester.getCenter(_region('第三项')).dx,
      lessThan(tester.getCenter(_region('第一项')).dx),
    );

    h.update(() {
      h.direction = Axis.vertical;
      h.selected = 1;
    });
    await _settle(tester);
    expect(_indicator(tester).direction, Axis.vertical);
    expect(_alignment(tester).y, closeTo(0, .001));
    expect(
      tester.getCenter(_region('第一项')).dy,
      lessThan(tester.getCenter(_region('第二项')).dy),
    );
    expect(
      tester.getCenter(_region('第二项')).dy,
      lessThan(tester.getCenter(_region('第三项')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing item count keeps retained focus and hover usable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final h = await _mount(tester, items: _items.take(2).toList());
      final calls = <int>[];
      h.update(() => h.onSelection = calls.add);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      h.update(() {
        h.items = _items;
        h.selected = 1;
      });
      await tester.pump();
      await mouse.moveTo(tester.getCenter(_region('第一项')));
      await tester.pump();
      // In particular, an existing cell must not retain a disposed externally
      // owned focus/hover notifier when the controller replaces its items.
      expect(tester.takeException(), isNull);
      _semanticTap(tester, '第三项');
      await _settle(tester);
      expect(calls, [2]);
      expect(_indicator(tester).itemCount, 3);
      h.update(() {
        h.items = _items.take(2).toList();
        h.selected = 0;
      });
      await _settle(tester);
      await mouse.moveTo(tester.getCenter(_region('第二项')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.takeException(), isNull);
      _semanticTap(tester, '第二项');
      await _settle(tester);
      expect(calls, [2, 1]);
      expect(_indicator(tester).itemCount, 2);
      expect(find.text('第三项'), findsNothing);
      expect(_alignment(tester).x, closeTo(1, .001));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
