import 'dart:ui' show PointerDeviceKind, SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/desk_sidebar_divider.dart';

void main() {
  Future<_DividerHarnessState> mount(
    WidgetTester tester, {
    double width = 228,
    double minimum = 184,
    double maximum = 360,
  }) async {
    final key = GlobalKey<_DividerHarnessState>();
    await tester.pumpWidget(
      CupertinoApp(
        home: _DividerHarness(
          key: key,
          initialWidth: width,
          minimum: minimum,
          maximum: maximum,
        ),
      ),
    );
    return key.currentState!;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // DoubleTapGestureRecognizer leaves its 40 ms minimum-interval countdown
    // alive after disposal. Advance that specific deadline explicitly.
    await tester.pump(const Duration(milliseconds: 50));
  }

  final handle = find.byType(DeskSidebarDivider);

  testWidgets('global drag stays accurate as the sidebar relayouts', (
    tester,
  ) async {
    final harness = await mount(tester);
    final origin = tester.getCenter(handle);
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(origin + const Offset(40, 0));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(80, 0));
    await tester.pump();
    expect(harness.width, 308);
    expect(tester.getCenter(handle).dx, closeTo(origin.dx + 80, 0.001));
    expect(harness.commits, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(harness.commits, [308]);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('drag clamps both ends and recovers from overshooting', (
    tester,
  ) async {
    final harness = await mount(tester, minimum: 200, maximum: 320);
    final origin = tester.getCenter(handle);
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(origin + const Offset(1000, 0));
    await tester.pump();
    expect(harness.width, 320);
    await gesture.moveTo(origin - const Offset(1000, 0));
    await tester.pump();
    expect(harness.width, 200);
    await gesture.moveTo(origin + const Offset(12, 0));
    await tester.pump();
    expect(harness.width, 240);
    expect(
      harness.changes.every((width) => width >= 200 && width <= 320),
      isTrue,
    );
    expect(harness.commits, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(harness.commits, [240]);
    await unmount(tester);
  });

  testWidgets('cancel restores the starting width without a persistence call', (
    tester,
  ) async {
    final harness = await mount(tester);
    final origin = tester.getCenter(handle);
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(origin + const Offset(60, 0));
    await tester.pump();
    expect(harness.width, 288);
    await gesture.cancel();
    await tester.pump();
    expect(harness.width, 228);
    expect(harness.changes.last, 288);
    expect(harness.cancels, 1);
    expect(harness.commits, isEmpty);
    expect(harness.resets, 0);
    await unmount(tester);
  });

  testWidgets('cancel lets the parent restore its newer pending width', (
    tester,
  ) async {
    final harness = await mount(tester);
    final origin = tester.getCenter(handle);
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(origin + const Offset(60, 0));
    await tester.pump();
    harness.cancelWidth = 260;
    await gesture.cancel();
    await tester.pump();
    expect(harness.width, 260);
    expect(harness.changes.last, 288);
    expect(harness.cancels, 1);
    expect(harness.commits, isEmpty);
    await unmount(tester);
  });

  testWidgets('double click resets once without committing a resize', (
    tester,
  ) async {
    final harness = await mount(tester, width: 280);
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(handle);
    await tester.pump();
    expect(harness.resets, 1);
    expect(harness.width, 228);
    expect(harness.changes, isEmpty);
    expect(harness.commits, isEmpty);
    await unmount(tester);
  });

  testWidgets(
    'keyboard repeats preview eight points and commit once on key up',
    (tester) async {
      final harness = await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.changes, [236, 244, 252]);
      expect(harness.commits, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.commits, [252]);
      await unmount(tester);
    },
  );

  testWidgets('Cmd Ctrl Alt combinations bubble without resizing or saving', (
    tester,
  ) async {
    final harness = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
      ]) {
        harness.bubbledKeys.clear();
        await tester.sendKeyDownEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        final bubbled = harness.bubbledKeys.where(
          (event) => event.logicalKey == key,
        );
        expect(bubbled.whereType<KeyDownEvent>(), hasLength(1));
        expect(bubbled.whereType<KeyRepeatEvent>(), hasLength(1));
        expect(bubbled.whereType<KeyUpEvent>(), hasLength(1));
      }
      await tester.sendKeyUpEvent(modifier);
    }
    expect(harness.width, 228);
    expect(harness.changes, isEmpty);
    expect(harness.commits, isEmpty);
    await unmount(tester);
  });

  testWidgets('adding a modifier preserves release of an ordinary adjustment', (
    tester,
  ) async {
    final harness = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]) {
      final before = harness.width;
      final commitsBefore = harness.commits.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.width, before + 8);
      await tester.sendKeyDownEvent(modifier);
      harness.bubbledKeys.clear();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      expect(harness.width, before + 8);
      expect(
        harness.bubbledKeys.whereType<KeyRepeatEvent>().where(
          (event) => event.logicalKey == LogicalKeyboardKey.arrowRight,
        ),
        hasLength(1),
      );
      expect(harness.commits.length, commitsBefore);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.commits.length, commitsBefore + 1);
      expect(harness.commits.last, before + 8);
      await tester.sendKeyUpEvent(modifier);
    }
    // A new ordinary key sequence must not retain any of the previous keys.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(harness.width, 244);
    expect(harness.commits, [236, 244, 252, 244]);
    await unmount(tester);
  });

  testWidgets('Home End and arrows honor bounds without redundant writes', (
    tester,
  ) async {
    final harness = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(harness.changes, [184, 192, 360, 352]);
    expect(harness.commits, [184, 192, 360, 352]);
    await unmount(tester);
  });

  testWidgets('unmounting an active drag never calls the parent', (
    tester,
  ) async {
    final harness = await mount(tester);
    final origin = tester.getCenter(handle);
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(origin + const Offset(60, 0));
    await tester.pump();
    final changes = List<double>.of(harness.changes);
    await unmount(tester);
    await gesture.cancel();
    expect(harness.changes, changes);
    expect(harness.commits, isEmpty);
    expect(harness.cancels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounting with a held key never commits from dispose', (
    tester,
  ) async {
    final harness = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(harness.width, 236);
    await unmount(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(harness.commits, isEmpty);
    expect(harness.cancels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'accessible adjustments expose values and stop at each boundary',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await mount(tester);
        final label = find.bySemanticsLabel('侧边栏宽度');
        expect(label, findsOneWidget);
        var node = tester.getSemantics(label);
        var data = node.getSemanticsData();
        expect(data.value, '228 点');
        expect(data.increasedValue, '236 点');
        expect(data.decreasedValue, '220 点');
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        tester
            .renderObject(handle)
            .owner!
            .semanticsOwner!
            .performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        expect(harness.width, 236);
        expect(harness.commits, [236]);

        harness.setWidth(360);
        await tester.pump();
        node = tester.getSemantics(label);
        data = node.getSemanticsData();
        expect(data.value, '360 点');
        expect(data.hasAction(SemanticsAction.increase), isFalse);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        tester
            .renderObject(handle)
            .owner!
            .semanticsOwner!
            .performAction(node.id, SemanticsAction.decrease);
        await tester.pump();
        expect(harness.width, 352);
        expect(harness.commits, [236, 352]);
        harness.setWidth(184);
        await tester.pump();
        data = tester.getSemantics(label).getSemanticsData();
        expect(data.hasAction(SemanticsAction.decrease), isFalse);
        expect(data.hasAction(SemanticsAction.increase), isTrue);
      } finally {
        await unmount(tester);
        semantics.dispose();
      }
    },
  );

  testWidgets('hover keeps a nine-point hit area and has no animation', (
    tester,
  ) async {
    await mount(tester);
    final rectangle = tester.getRect(handle);
    expect(rectangle.width, 9);
    final mouseRegion = find.descendant(
      of: handle,
      matching: find.byType(MouseRegion),
    );
    expect(
      tester.widget<MouseRegion>(mouseRegion).cursor,
      SystemMouseCursors.resizeLeftRight,
    );
    final line = find.descendant(of: handle, matching: find.byType(ColoredBox));
    final restingColor = tester.widget<ColoredBox>(line).color;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(rectangle.center);
    await tester.pump();
    expect(tester.widget<ColoredBox>(line).color, isNot(restingColor));
    expect(tester.getRect(handle), rectangle);
    expect(tester.hasRunningAnimations, isFalse);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(tester.widget<ColoredBox>(line).color, restingColor);
    await mouse.removePointer();
    await unmount(tester);
  });
}

class _DividerHarness extends StatefulWidget {
  const _DividerHarness({
    required this.initialWidth,
    required this.minimum,
    required this.maximum,
    super.key,
  });

  final double initialWidth;
  final double minimum;
  final double maximum;

  @override
  State<_DividerHarness> createState() => _DividerHarnessState();
}

class _DividerHarnessState extends State<_DividerHarness> {
  late double width = widget.initialWidth;
  double? cancelWidth;
  final changes = <double>[];
  final commits = <double>[];
  final bubbledKeys = <KeyEvent>[];
  int resets = 0;
  int cancels = 0;

  void setWidth(double value) => setState(() => width = value);

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    includeSemantics: false,
    onKeyEvent: (_, event) {
      bubbledKeys.add(event);
      return KeyEventResult.ignored;
    },
    child: CupertinoPageScaffold(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 300,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: width),
              DeskSidebarDivider(
                width: width,
                minimum: widget.minimum,
                maximum: widget.maximum,
                onChanged: (value) {
                  changes.add(value);
                  setWidth(value);
                },
                onChangeEnd: commits.add,
                onCancel: () {
                  cancels++;
                  setWidth(cancelWidth ?? widget.initialWidth);
                },
                onReset: () {
                  resets++;
                  setWidth(228);
                },
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
}
