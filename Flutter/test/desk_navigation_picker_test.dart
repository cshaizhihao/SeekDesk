import 'dart:ui' show SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/widgets/desk_navigation_picker.dart';

const _labels = ['社区', '消息', '扩展', '设置'];

void main() {
  Future<_PickerHarnessState> mount(
    WidgetTester tester, {
    int? selected = 0,
    bool reduceMotion = false,
    Set<int> disabled = const {},
  }) async {
    final key = GlobalKey<_PickerHarnessState>();
    await tester.pumpWidget(
      CupertinoApp(
        home: _PickerHarness(
          key: key,
          initialSelection: selected,
          initialReduceMotion: reduceMotion,
          disabled: disabled,
        ),
      ),
    );
    return key.currentState!;
  }

  List<AnimatedGlassIndicator> indicators(WidgetTester tester) => tester
      .widgetList<AnimatedGlassIndicator>(find.byType(AnimatedGlassIndicator))
      .toList();

  void expectSelection(WidgetTester tester, int? index) {
    for (var row = 0; row < _labels.length; row++) {
      final data = tester
          .getSemantics(find.bySemanticsLabel(_labels[row]))
          .getSemanticsData();
      expect(
        data.flagsCollection.isSelected,
        row == index ? Tristate.isTrue : Tristate.isFalse,
      );
    }
  }

  testWidgets('null selection has no pill and keeps four accessible actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await mount(tester, selected: null);
      expect(indicators(tester), isEmpty);
      expectSelection(tester, null);
      for (final label in _labels) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(label))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      final node = tester.getSemantics(find.bySemanticsLabel('消息'));
      tester
          .renderObject(find.byType(DeskNavigationPicker))
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(harness.activated, [1]);
      expectSelection(tester, 1);
      expect(
        (indicators(tester).single.alignment as Alignment).y,
        closeTo(-1 / 3, 0.00001),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(harness.activated, [1, 3]);
      expectSelection(tester, 3);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('clearing selection stops motion without remounting row labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await mount(tester, selected: 3);
      final states = harness.labelKeys
          .map((key) => tester.state(find.byKey(key)))
          .toList();
      final rectangles = harness.labelKeys
          .map((key) => tester.getRect(find.byKey(key)))
          .toList();
      harness.select(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(indicators(tester).single.velocity, isNot(0));
      harness.select(null);
      await tester.pump();
      expect(indicators(tester), isEmpty);
      expectSelection(tester, null);
      expect(tester.hasRunningAnimations, isFalse);
      for (var i = 0; i < states.length; i++) {
        expect(tester.state(find.byKey(harness.labelKeys[i])), same(states[i]));
        expect(tester.getRect(find.byKey(harness.labelKeys[i])), rectangles[i]);
      }
      harness.select(2);
      await tester.pump();
      expect(
        (indicators(tester).single.alignment as Alignment).y,
        closeTo(1 / 3, 0.00001),
      );
      expect(indicators(tester).single.velocity, 0);
      expect(indicators(tester).single.thickness, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('rapid redirects settle at the latest selected row', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await mount(tester);
      for (final destination in [3, 1, 2, 0, 3, 1]) {
        harness.select(destination);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 35));
        expectSelection(tester, destination);
        final indicator = indicators(tester).single;
        final alignment = indicator.alignment as Alignment;
        expect(alignment.y.isFinite, isTrue);
        expect(alignment.y.abs(), lessThan(3));
        expect(indicator.velocity.isFinite, isTrue);
        expect(indicator.thickness.isFinite, isTrue);
      }
      await tester.pumpAndSettle();
      final indicator = indicators(tester).single;
      expect((indicator.alignment as Alignment).y, closeTo(-1 / 3, 0.00001));
      expect(indicator.velocity, 0);
      expect(indicator.thickness, 0);
      expectSelection(tester, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('Reduce Motion snaps selection and stops an in-flight spring', (
    tester,
  ) async {
    final harness = await mount(tester, reduceMotion: true);
    harness.select(3);
    await tester.pump();
    expect(indicators(tester).single.alignment, const Alignment(0, 1));
    expect(indicators(tester).single.velocity, 0);
    expect(indicators(tester).single.thickness, 0);
    expect(tester.hasRunningAnimations, isFalse);

    harness.setReduceMotion(false);
    await tester.pump();
    harness.select(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(indicators(tester).single.velocity, isNot(0));
    harness.setReduceMotion(true);
    await tester.pump();
    expect(indicators(tester).single.alignment, const Alignment(0, -1));
    expect(indicators(tester).single.velocity, 0);
    expect(indicators(tester).single.thickness, 0);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard activation skips disabled rows and calls once', (
    tester,
  ) async {
    final harness = await mount(tester, selected: null, disabled: {1});
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(harness.activated, [0]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(harness.activated, [0]);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.activated, [0, 2]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled row has no tap action or pointer activation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await mount(tester, disabled: {1});
      final data = tester
          .getSemantics(find.bySemanticsLabel('消息'))
          .getSemanticsData();
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      await tester.tap(find.text('消息'), warnIfMissed: false);
      await tester.pump();
      expect(harness.activated, isEmpty);
      expect(indicators(tester).single.thickness, 0);
      expectSelection(tester, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('press bloom leaves row geometry and labels fixed', (
    tester,
  ) async {
    final harness = await mount(tester);
    final before = harness.labelKeys
        .map((key) => tester.getRect(find.byKey(key)))
        .toList();
    expect(
      tester.getSize(find.byType(DeskNavigationPicker)),
      const Size(204, 172),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('社区')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(indicators(tester).single.thickness, greaterThan(0));
    for (var index = 0; index < before.length; index++) {
      expect(
        tester.getRect(find.byKey(harness.labelKeys[index])),
        before[index],
      );
    }
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(indicators(tester).single.thickness, 0);
    expect(harness.activated, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('adaptive quality ceiling applies to the shared indicator', (
    tester,
  ) async {
    await mount(tester);
    final picker = tester.widget<DeskNavigationPicker>(
      find.byType(DeskNavigationPicker),
    );
    expect(picker.quality, GlassQuality.premium);
    final indicator = indicators(tester).single;
    expect(indicator.quality, GlassQuality.minimal);
    expect(indicator.paintBackground, isTrue);
    expect(indicator.paintGlass, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _PickerHarness extends StatefulWidget {
  const _PickerHarness({
    required this.initialSelection,
    required this.initialReduceMotion,
    required this.disabled,
    super.key,
  });

  final int? initialSelection;
  final bool initialReduceMotion;
  final Set<int> disabled;

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  late int? selection = widget.initialSelection;
  late bool reduceMotion = widget.initialReduceMotion;
  final activated = <int>[];
  final labelKeys = List.generate(4, (index) => ValueKey('label-$index'));

  void select(int? index) => setState(() => selection = index);
  void setReduceMotion(bool value) => setState(() => reduceMotion = value);

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: 204,
            child: DeskNavigationPicker(
              selectedIndex: selection,
              onSelected: (index) {
                activated.add(index);
                select(index);
              },
              segments: [
                for (var index = 0; index < _labels.length; index++)
                  GlassSegment(
                    id: _labels[index],
                    semanticLabel: _labels[index],
                    enabled: !widget.disabled.contains(index),
                    icon: _PersistentLabel(
                      key: labelKeys[index],
                      label: _labels[index],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PersistentLabel extends StatefulWidget {
  const _PersistentLabel({required this.label, super.key});
  final String label;

  @override
  State<_PersistentLabel> createState() => _PersistentLabelState();
}

class _PersistentLabelState extends State<_PersistentLabel> {
  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(width: 17),
      const Icon(CupertinoIcons.circle, size: 17),
      const SizedBox(width: 12),
      Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w500)),
    ],
  );
}
