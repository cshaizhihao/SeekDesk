import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/engine/glass_drag_builder.dart';
import 'package:liquid_glass_widgets/src/engine/stretch.dart'
    show LiquidStretch, RawLiquidStretch, RenderRawLiquidStretch;
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_renderer.dart'
    show GlassGlowLayer, GlassGlowLayerState;
import 'package:liquid_glass_widgets/widgets/shared/glass_focus_region.dart';

const _buttonKey = ValueKey('transparent-format-button');
const _label = '格式工具';

class _Harness extends StatefulWidget {
  const _Harness({required this.initiallyEnabled, super.key});

  final bool initiallyEnabled;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late bool enabled = widget.initiallyEnabled;
  final focusNode = FocusNode(debugLabel: 'format button');
  final nextFocusNode = FocusNode(debugLabel: 'next control');
  int activations = 0;

  void setEnabled(bool value) => setState(() => enabled = value);

  @override
  void dispose() {
    focusNode.dispose();
    nextFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Match the format shelf's premium transparent button, including
            // its disabled pointer guard. Transparent buttons have no glass
            // shader, so this uses the real quality without a test downgrade.
            IgnorePointer(
              ignoring: !enabled,
              child: GlassButton.custom(
                key: _buttonKey,
                width: 32,
                height: 32,
                label: _label,
                shape: const LiquidRoundedSuperellipse(borderRadius: 7),
                style: GlassButtonStyle.transparent,
                quality: GlassQuality.premium,
                stretch: .15,
                enabled: enabled,
                focusNode: focusNode,
                onTap: () => activations++,
                child: const Icon(CupertinoIcons.bold, size: 17),
              ),
            ),
            Focus(
              focusNode: nextFocusNode,
              child: const SizedBox(width: 40, height: 40),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  bool initiallyEnabled = true,
}) async {
  final key = GlobalKey<_HarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pumpWidget(
    _Harness(key: key, initiallyEnabled: initiallyEnabled),
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

Finder _withinButton(Type type) =>
    find.descendant(of: find.byKey(_buttonKey), matching: find.byType(type));

void _expectReleased(WidgetTester tester) {
  final stretch = tester.renderObject<RenderRawLiquidStretch>(
    _withinButton(RawLiquidStretch),
  );
  expect(stretch.pressGrowthPixels, closeTo(0, .001));
  expect(stretch.stretchPixels.distance, closeTo(0, .001));
  expect(
    tester.state<GlassGlowLayerState>(_withinButton(GlassGlowLayer)).dragging,
    isFalse,
  );
  expect(
    _withinButton(ColoredBox),
    findsNothing,
    reason: 'A released button must not keep its held-down highlight',
  );
}

typedef _Identity = ({
  Type type,
  Element element,
  State<StatefulWidget>? state,
});

List<_Identity> _animationIdentities(WidgetTester tester) => [
  for (final type in [
    LiquidStretch,
    GlassDragBuilder,
    OffsetSpringBuilder,
    SpringBuilder,
    GlassGlow,
    GlassGlowLayer,
  ])
    for (final element in tester.elementList(_withinButton(type)))
      (
        type: type,
        element: element,
        state: element is StatefulElement ? element.state : null,
      ),
];

void _expectSameAnimationTree(WidgetTester tester, List<_Identity> original) {
  final current = _animationIdentities(tester);
  expect(current.length, original.length);
  for (var index = 0; index < original.length; index++) {
    expect(current[index].type, original[index].type);
    expect(
      current[index].element,
      same(original[index].element),
      reason: '${original[index].type} must survive enabled changes',
    );
    if (original[index].state != null) {
      expect(current[index].state, same(original[index].state));
      expect(original[index].state!.mounted, isTrue);
    }
  }
}

void main() {
  for (final initiallyEnabled in [true, false]) {
    testWidgets(
      'transparent button retains animation elements and state starting '
      '${initiallyEnabled ? 'enabled' : 'disabled'}',
      (tester) async {
        final h = await _mount(tester, initiallyEnabled: initiallyEnabled);
        final buttonState = tester.state(find.byKey(_buttonKey));
        final focusState = tester.state(_withinButton(GlassFocusRegion));
        final original = _animationIdentities(tester);
        // Ensure the identity test cannot pass by removing animation widgets.
        for (final type in [
          LiquidStretch,
          GlassDragBuilder,
          OffsetSpringBuilder,
          SpringBuilder,
          GlassGlow,
          GlassGlowLayer,
        ]) {
          expect(original.any((entry) => entry.type == type), isTrue);
        }
        expect(_withinButton(AdaptiveGlass), findsNothing);
        for (final enabled in [
          !initiallyEnabled,
          initiallyEnabled,
          !initiallyEnabled,
          initiallyEnabled,
        ]) {
          h.setEnabled(enabled);
          await _settle(tester);
          expect(tester.state(find.byKey(_buttonKey)), same(buttonState));
          expect(
            tester.state(_withinButton(GlassFocusRegion)),
            same(focusState),
          );
          _expectSameAnimationTree(tester, original);
          if (!enabled) {
            final region = tester.widget<GlassFocusRegion>(
              _withinButton(GlassFocusRegion),
            );
            expect((region.child as Opacity).opacity, .5);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('disabled button releases focus and hover and cannot activate', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final oldStrategy = FocusManager.instance.highlightStrategy;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    try {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      final h = await _mount(tester);
      final focusState = tester.state(_withinButton(GlassFocusRegion));
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(_buttonKey)));
      await _settle(tester);
      var region = tester.widget<GlassFocusRegion>(
        _withinButton(GlassFocusRegion),
      );
      expect(region.isHoveredNotifier!.value, isTrue);
      h.focusNode.requestFocus();
      await _settle(tester);
      expect(h.focusNode.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.activations, 1);

      h.setEnabled(false);
      await _settle(tester);
      expect(tester.state(_withinButton(GlassFocusRegion)), same(focusState));
      expect(h.focusNode.canRequestFocus, isFalse);
      expect(h.focusNode.hasFocus, isFalse);
      region = tester.widget<GlassFocusRegion>(_withinButton(GlassFocusRegion));
      expect(region.isFocusedNotifier!.value, isFalse);
      expect(region.isHoveredNotifier!.value, isFalse);
      final data = tester
          .getSemantics(find.bySemanticsLabel(_label))
          .getSemanticsData();
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      await tester.tapAt(tester.getCenter(find.byKey(_buttonKey)));
      h.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      expect(h.activations, 1);
      expect(h.focusNode.hasFocus, isFalse);

      h.nextFocusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(h.focusNode.hasFocus, isFalse);
      h.setEnabled(true);
      await _settle(tester);
      h.focusNode.requestFocus();
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.activations, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      FocusManager.instance.highlightStrategy = oldStrategy;
      semantics.dispose();
    }
  });

  for (final drag in [false, true]) {
    for (final cancel in [false, true]) {
      testWidgets(
        'disable during ${drag ? 'drag' : 'press'} clears motion and glow '
        'after pointer ${cancel ? 'cancel' : 'up'} without activation',
        (tester) async {
          final h = await _mount(tester);
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(_buttonKey)),
          );
          await tester.pump();
          if (drag) {
            await gesture.moveBy(const Offset(10, 6));
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 200));
          // With no focus or hover, this ColoredBox is the press's ambient lift.
          expect(_withinButton(ColoredBox), findsOneWidget);
          final pressed = tester.renderObject<RenderRawLiquidStretch>(
            _withinButton(RawLiquidStretch),
          );
          expect(pressed.pressGrowthPixels, greaterThan(0));
          if (drag) expect(pressed.stretchPixels.distance, greaterThan(0));
          expect(
            tester
                .state<GlassGlowLayerState>(_withinButton(GlassGlowLayer))
                .dragging,
            isTrue,
          );
          h.setEnabled(false);
          await tester.pump();
          if (cancel) {
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await _settle(tester);
          expect(h.activations, 0);
          _expectReleased(tester);
          h.setEnabled(true);
          await _settle(tester);
          _expectReleased(tester);
          await tester.tap(find.byKey(_buttonKey));
          await _settle(tester);
          expect(h.activations, 1);
          _expectReleased(tester);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
