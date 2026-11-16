import 'dart:ui' show SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const _buttonKey = ValueKey('reparent-format-button');
const _label = '格式操作';

typedef _LifecycleCounts = ({int activate, int deactivate, int dependencies});

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe();

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  int activations = 0;
  int deactivations = 0;
  int dependencyChanges = 0;
  Brightness? lastBrightness;

  _LifecycleCounts get counts => (
    activate: activations,
    deactivate: deactivations,
    dependencies: dependencyChanges,
  );

  @override
  void activate() {
    super.activate();
    activations++;
  }

  @override
  void deactivate() {
    deactivations++;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    dependencyChanges++;
  }

  @override
  Widget build(BuildContext context) {
    // A normal inherited dependency distinguishes a retained element from
    // one reactivated through FAD's GlobalKey. This probe does not depend on
    // Actions, so changing an action map alone must not invalidate its theme.
    lastBrightness = CupertinoTheme.of(context).brightness;
    return Icon(
      CupertinoIcons.bold,
      size: 17,
      color: lastBrightness == Brightness.dark
          ? CupertinoColors.white
          : CupertinoColors.black,
    );
  }
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final focusNode = FocusNode(debugLabel: 'reparent format action');
  bool enabled = true;
  Brightness brightness = Brightness.light;
  int activations = 0;
  int ancestorActivations = 0;
  late final Map<Type, Action<Intent>> ancestorActions = {
    ActivateIntent: CallbackAction<Intent>(
      onInvoke: (_) {
        ancestorActivations++;
        return null;
      },
    ),
  };

  void update(VoidCallback change) => setState(change);

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
    theme: CupertinoThemeData(brightness: brightness),
    home: CupertinoPageScaffold(
      child: Center(
        child: Actions(
          actions: ancestorActions,
          child: IgnorePointer(
            ignoring: !enabled,
            // Real format-button quality and motion. Transparent buttons do
            // not need a shader fallback in this widget test.
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
              child: const _LifecycleProbe(),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 16),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Future<_HarnessState> _mount(WidgetTester tester) async {
  final key = GlobalKey<_HarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pumpWidget(_Harness(key: key));
  await _settle(tester);
  return key.currentState!;
}

_LifecycleProbeState _probe(WidgetTester tester) =>
    tester.state<_LifecycleProbeState>(find.byType(_LifecycleProbe));

void main() {
  testWidgets(
    'enabled round trips retain the button descendant without reactivation',
    (tester) async {
      final h = await _mount(tester);
      final probe = _probe(tester);
      final element = tester.element(find.byType(_LifecycleProbe));
      final before = probe.counts;
      final observations = <_LifecycleCounts>[];
      for (final enabled in [false, true, false, true]) {
        h.update(() => h.enabled = enabled);
        await _settle(tester);
        expect(_probe(tester), same(probe));
        expect(tester.element(find.byType(_LifecycleProbe)), same(element));
        observations.add(probe.counts);
      }
      expect(
        observations,
        List<_LifecycleCounts>.filled(4, before),
        reason:
            'Keeping State through a GlobalKey move still deactivates and '
            'reactivates descendants and invalidates unchanged dependencies',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained button content still responds to inherited theme changes',
    (tester) async {
      final h = await _mount(tester);
      final probe = _probe(tester);
      final element = tester.element(find.byType(_LifecycleProbe));
      final before = probe.counts;
      expect(probe.lastBrightness, Brightness.light);
      h.update(() => h.brightness = Brightness.dark);
      await _settle(tester);
      expect(_probe(tester), same(probe));
      expect(tester.element(find.byType(_LifecycleProbe)), same(element));
      expect(probe.lastBrightness, Brightness.dark);
      expect(probe.dependencyChanges, greaterThan(before.dependencies));
      expect(probe.activations, before.activate);
      expect(probe.deactivations, before.deactivate);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disabled action stays unavailable to keyboard pointer and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final h = await _mount(tester);
        h.focusNode.requestFocus();
        await tester.pump();
        await _settle(tester);
        expect(h.focusNode.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(h.activations, 1);

        h.update(() => h.enabled = false);
        await _settle(tester);
        expect(h.focusNode.canRequestFocus, isFalse);
        expect(h.focusNode.hasFocus, isFalse);
        final disabled = tester
            .getSemantics(find.bySemanticsLabel(_label))
            .getSemanticsData();
        expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);
        expect(disabled.hasAction(SemanticsAction.tap), isFalse);
        await tester.tapAt(tester.getCenter(find.byKey(_buttonKey)));
        h.focusNode.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _settle(tester);
        expect(h.activations, 1);
        expect(h.focusNode.hasFocus, isFalse);

        h.update(() => h.enabled = true);
        await _settle(tester);
        final node = tester.getSemantics(find.bySemanticsLabel(_label));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        tester
            .renderObject(find.byKey(_buttonKey))
            .owner!
            .semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        expect(h.activations, 2);
        h.focusNode.requestFocus();
        await tester.pump();
        await _settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(h.activations, 3);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'disabled local action allows ancestor action lookup to fall through',
    (tester) async {
      final h = await _mount(tester);
      Actions.maybeInvoke(_probe(tester).context, const ActivateIntent());
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(h.activations, 1);
      expect(h.ancestorActivations, 0);

      h.update(() => h.enabled = false);
      await _settle(tester);
      Actions.maybeInvoke(_probe(tester).context, const ActivateIntent());
      expect(h.activations, 1);
      expect(h.ancestorActivations, 1);

      h.update(() => h.enabled = true);
      await _settle(tester);
      Actions.maybeInvoke(_probe(tester).context, const ActivateIntent());
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(h.activations, 2);
      expect(h.ancestorActivations, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
