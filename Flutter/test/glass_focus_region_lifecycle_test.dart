// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_focus_region.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_focus_ring_painter.dart';

const _regionKey = ValueKey('lifecycle-focus-region');
const _hostKey = ValueKey('lifecycle-focus-host');
const _shape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);

Future<void> _mountInteractive(
  WidgetTester tester, {
  ValueNotifier<bool>? focused,
  ValueNotifier<bool>? hovered,
  FocusNode? focusNode,
}) => tester.pumpWidget(
  CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        child: GlassFocusRegion(
          key: _regionKey,
          enabled: true,
          isButton: true,
          semanticLabel: '生命周期测试',
          shape: _shape,
          isFocusedNotifier: focused,
          isHoveredNotifier: hovered,
          focusNode: focusNode,
          child: const SizedBox(width: 120, height: 40),
        ),
      ),
    ),
  ),
);

FocusableActionDetector _detector(WidgetTester tester) =>
    tester.widget<FocusableActionDetector>(
      find.descendant(
        of: find.byKey(_regionKey),
        matching: find.byType(FocusableActionDetector),
      ),
    );

Future<void> _mountObserved(
  WidgetTester tester, {
  required FocusNode first,
  required FocusNode second,
  required FocusNode observed,
}) => tester.pumpWidget(
  CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Both nodes remain attached while the observed node changes.
            // Rebinding must evaluate an already focused node correctly.
            Focus(
              focusNode: first,
              child: const SizedBox(width: 40, height: 40),
            ),
            Focus(
              focusNode: second,
              child: const SizedBox(width: 40, height: 40),
            ),
            GlassFocusRegion.observe(
              key: _regionKey,
              focusNode: observed,
              shape: _shape,
              child: const SizedBox(width: 120, height: 40),
            ),
          ],
        ),
      ),
    ),
  ),
);

Finder get _ring => find.descendant(
  of: find.byKey(_regionKey),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint && widget.painter is GlassFocusRingPainter,
  ),
);

Listener _observerListener(WidgetTester tester) => tester.widget<Listener>(
  find.descendant(of: find.byKey(_regionKey), matching: find.byType(Listener)),
);

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _focusAndPaint(WidgetTester tester, FocusNode node) async {
  node.requestFocus();
  // When no frame is initially scheduled, the first pump can only flush the
  // focus microtask. Verify the real focus, then paint the notification's frame.
  await tester.pump();
  expect(node.hasFocus, isTrue);
  await tester.pump();
}

Future<void> _unfocusAndPaint(WidgetTester tester, FocusNode node) async {
  node.unfocus();
  await tester.pump();
  expect(node.hasFocus, isFalse);
  await tester.pump();
}

// A failed ownership assertion must not leak a node into the next test, or
// dispose a node twice if the widget has already released it during cleanup.
void _disposeIfLive(ChangeNotifier notifier) {
  try {
    ChangeNotifier.debugAssertNotDisposed(notifier);
  } on FlutterError {
    return;
  }
  notifier.dispose();
}

class _RetirableNotifier extends ValueNotifier<bool> {
  _RetirableNotifier() : super(false);

  bool retired = false;

  @override
  bool get value {
    if (retired) throw StateError('Reading a retired notifier');
    return super.value;
  }

  @override
  set value(bool next) {
    if (retired) throw StateError('Writing a retired notifier');
    super.value = next;
  }

  @override
  void dispose() {
    super.dispose();
    retired = true;
  }
}

GlassFocusRegion _interactiveRegion({
  ValueNotifier<bool>? focused,
  ValueNotifier<bool>? hovered,
  FocusNode? focusNode,
  VoidCallback? onActivate,
}) => GlassFocusRegion(
  key: _regionKey,
  enabled: true,
  isButton: true,
  shape: _shape,
  isFocusedNotifier: focused,
  isHoveredNotifier: hovered,
  focusNode: focusNode,
  onKeyboardActivate: onActivate,
  child: const SizedBox(width: 120, height: 40),
);

Future<void> _mountAncestorListener(
  WidgetTester tester,
  ValueNotifier<bool> target, {
  required bool focus,
}) => tester.pumpWidget(
  CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        child: ValueListenableBuilder<bool>(
          valueListenable: target,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('target:$value'),
              _interactiveRegion(
                focused: focus ? target : null,
                hovered: focus ? null : target,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<void> _mountMode(
  WidgetTester tester, {
  required bool observe,
  required FocusNode observedNode,
  required FocusNode interactiveNode,
  ValueNotifier<bool>? focused,
  ValueNotifier<bool>? hovered,
  VoidCallback? onActivate,
}) => tester.pumpWidget(
  CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Focus(
              focusNode: observedNode,
              child: const SizedBox(width: 40, height: 40),
            ),
            observe
                ? GlassFocusRegion.observe(
                    key: _regionKey,
                    focusNode: observedNode,
                    shape: _shape,
                    child: const SizedBox(width: 120, height: 40),
                  )
                : _interactiveRegion(
                    focused: focused,
                    hovered: hovered,
                    focusNode: interactiveNode,
                    onActivate: onActivate,
                  ),
          ],
        ),
      ),
    ),
  ),
);

Future<void> _mountQueuedRegion(
  WidgetTester tester, {
  required ValueNotifier<bool> focused,
  required ValueNotifier<bool> hovered,
}) => tester.pumpWidget(
  CupertinoApp(
    home: CupertinoPageScaffold(
      child: Center(
        key: _hostKey,
        child: _interactiveRegion(focused: focused, hovered: hovered),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'a shaped region passes tight constraints through every focus state',
    (tester) async {
      const childKey = ValueKey('tight-focus-child');
      const expectedSize = Size(200, 48);
      final node = FocusNode(debugLabel: 'tight constrained region');
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await tester.pumpWidget(
          CupertinoApp(
            home: CupertinoPageScaffold(
              child: Center(
                child: SizedBox(
                  width: expectedSize.width,
                  height: expectedSize.height,
                  child: GlassFocusRegion(
                    key: _regionKey,
                    enabled: true,
                    shape: _shape,
                    focusNode: node,
                    child: const SizedBox(
                      key: childKey,
                      width: 120,
                      height: 32,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final childElement = tester.element(find.byKey(childKey));
        void expectTightChild() {
          expect(tester.getSize(find.byKey(_regionKey)), expectedSize);
          expect(tester.getSize(find.byKey(childKey)), expectedSize);
          expect(tester.element(find.byKey(childKey)), same(childElement));
        }

        expectTightChild();
        expect(_ring, findsNothing);
        await _focusAndPaint(tester, node);
        expectTightChild();
        expect(_ring, findsOneWidget);
        await _unfocusAndPaint(tester, node);
        expectTightChild();
        expect(_ring, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        _disposeIfLive(node);
      }
    },
  );

  for (final focus in [true, false]) {
    final kind = focus ? 'focus' : 'hover';
    testWidgets('replacing an external $kind notifier retires the old target', (
      tester,
    ) async {
      final oldNotifier = ValueNotifier(false);
      final nextNotifier = ValueNotifier(false);
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _mountInteractive(
          tester,
          focused: focus ? oldNotifier : null,
          hovered: focus ? null : oldNotifier,
        );
        final element = tester.element(find.byKey(_regionKey));
        // Mirrors segmented-control item-count updates: the owner disposes
        // its old notifier before the retained child receives its replacement.
        oldNotifier.dispose();
        await _mountInteractive(
          tester,
          focused: focus ? nextNotifier : null,
          hovered: focus ? null : nextNotifier,
        );
        expect(tester.element(find.byKey(_regionKey)), same(element));
        final detector = _detector(tester);
        if (focus) {
          await _focusAndPaint(tester, detector.focusNode!);
        } else {
          // A pointer move alone may not change the hover highlight. Trigger
          // the current detector's actual output callback deterministically.
          expect(() => detector.onShowHoverHighlight!(true), returnsNormally);
        }
        expect(nextNotifier.value, isTrue);
        await tester.pump();
        if (focus) {
          await _unfocusAndPaint(tester, detector.focusNode!);
        } else {
          expect(() => detector.onShowHoverHighlight!(false), returnsNormally);
        }
        expect(nextNotifier.value, isFalse);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await _unmount(tester);
        expect(ChangeNotifier.debugAssertNotDisposed(nextNotifier), isTrue);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        _disposeIfLive(oldNotifier);
        _disposeIfLive(nextNotifier);
      }
    });
  }

  testWidgets(
    'an owned focus node is released when an external node replaces it',
    (tester) async {
      final external = FocusNode(debugLabel: 'borrowed replacement');
      FocusNode? owned;
      try {
        await _mountInteractive(tester);
        owned = _detector(tester).focusNode!;
        final element = tester.element(find.byKey(_regionKey));
        await _mountInteractive(tester, focusNode: external);
        expect(tester.element(find.byKey(_regionKey)), same(element));
        expect(_detector(tester).focusNode, same(external));
        expect(
          () => ChangeNotifier.debugAssertNotDisposed(owned!),
          throwsFlutterError,
        );
        external.requestFocus();
        await tester.pump();
        expect(external.hasFocus, isTrue);
        await _unmount(tester);
        expect(ChangeNotifier.debugAssertNotDisposed(external), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        if (owned != null) _disposeIfLive(owned);
        _disposeIfLive(external);
      }
    },
  );

  testWidgets(
    'an external focus node is borrowed when an owned node replaces it',
    (tester) async {
      final external = FocusNode(debugLabel: 'retired borrowed node');
      FocusNode? owned;
      try {
        await _mountInteractive(tester, focusNode: external);
        final element = tester.element(find.byKey(_regionKey));
        await _mountInteractive(tester);
        expect(tester.element(find.byKey(_regionKey)), same(element));
        owned = _detector(tester).focusNode!;
        expect(owned, isNot(same(external)));
        expect(ChangeNotifier.debugAssertNotDisposed(external), isTrue);
        owned.requestFocus();
        await tester.pump();
        expect(owned.hasFocus, isTrue);
        await _unmount(tester);
        expect(ChangeNotifier.debugAssertNotDisposed(external), isTrue);
        expect(
          () => ChangeNotifier.debugAssertNotDisposed(owned!),
          throwsFlutterError,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        if (owned != null) _disposeIfLive(owned);
        _disposeIfLive(external);
      }
    },
  );

  testWidgets('replacing a borrowed focus node adopts the current node only', (
    tester,
  ) async {
    final first = FocusNode(debugLabel: 'first borrowed node');
    final second = FocusNode(debugLabel: 'second borrowed node');
    try {
      await _mountInteractive(tester, focusNode: first);
      final element = tester.element(find.byKey(_regionKey));
      await _mountInteractive(tester, focusNode: second);
      expect(tester.element(find.byKey(_regionKey)), same(element));
      expect(_detector(tester).focusNode, same(second));
      expect(ChangeNotifier.debugAssertNotDisposed(first), isTrue);
      second.requestFocus();
      await tester.pump();
      expect(second.hasFocus, isTrue);
      await _unmount(tester);
      expect(ChangeNotifier.debugAssertNotDisposed(first), isTrue);
      expect(ChangeNotifier.debugAssertNotDisposed(second), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
      _disposeIfLive(first);
      _disposeIfLive(second);
    }
  });

  testWidgets(
    'the first focus on a replacement interactive node shows its ring',
    (tester) async {
      final first = FocusNode(debugLabel: 'focused node being replaced');
      final second = FocusNode(debugLabel: 'initially unfocused replacement');
      final highlighted = ValueNotifier(false);
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _mountInteractive(tester, focusNode: first, focused: highlighted);
        final element = tester.element(find.byKey(_regionKey));
        await _focusAndPaint(tester, first);
        expect(highlighted.value, isTrue);
        expect(_ring, findsOneWidget);

        await _mountInteractive(
          tester,
          focusNode: second,
          focused: highlighted,
        );
        await tester.pump();
        expect(tester.element(find.byKey(_regionKey)), same(element));
        expect(_detector(tester).focusNode, same(second));
        expect(second.hasFocus, isFalse);
        expect(highlighted.value, isFalse);
        expect(_ring, findsNothing);

        // No preliminary false highlight callback is injected. A retained FAD
        // can still cache the old node's true focus and omit this first event.
        await _focusAndPaint(tester, second);
        expect(highlighted.value, isTrue);
        expect(_ring, findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        _disposeIfLive(first);
        _disposeIfLive(second);
        _disposeIfLive(highlighted);
      }
    },
  );

  testWidgets(
    'observe ring toggles retain the focused editable child and selection',
    (tester) async {
      const fieldKey = ValueKey('retained-focus-field');
      const selection = TextSelection(baseOffset: 0, extentOffset: 2);
      final node = FocusNode(debugLabel: 'observed editable descendant');
      final controller = TextEditingController.fromValue(
        const TextEditingValue(text: '保留编辑状态', selection: selection),
      );
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await tester.pumpWidget(
          CupertinoApp(
            home: CupertinoPageScaffold(
              child: Center(
                child: SizedBox(
                  width: 280,
                  child: GlassFocusRegion.observe(
                    key: _regionKey,
                    focusNode: node,
                    shape: _shape,
                    child: CupertinoTextField(
                      key: fieldKey,
                      controller: controller,
                      focusNode: node,
                      selectAllOnFocus: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final fieldElement = tester.element(find.byKey(fieldKey));
        final fieldState = tester.state(find.byKey(fieldKey));
        final editableState = tester.state(find.byType(EditableText));
        expect(_ring, findsNothing);
        await _focusAndPaint(tester, node);
        expect(_ring, findsOneWidget);
        expect(tester.element(find.byKey(fieldKey)), same(fieldElement));
        expect(tester.state(find.byKey(fieldKey)), same(fieldState));
        expect(tester.state(find.byType(EditableText)), same(editableState));
        expect(controller.selection, selection);

        await _unfocusAndPaint(tester, node);
        expect(_ring, findsNothing);
        expect(tester.element(find.byKey(fieldKey)), same(fieldElement));
        expect(tester.state(find.byKey(fieldKey)), same(fieldState));
        expect(tester.state(find.byType(EditableText)), same(editableState));
        expect(controller.text, '保留编辑状态');
        expect(controller.selection, selection);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        _disposeIfLive(node);
        _disposeIfLive(controller);
      }
    },
  );

  testWidgets('an observed-node replacement respects touch highlight mode', (
    tester,
  ) async {
    final first = FocusNode(debugLabel: 'first observed node');
    final second = FocusNode(debugLabel: 'second observed node');
    final originalStrategy = FocusManager.instance.highlightStrategy;
    try {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await _mountObserved(
        tester,
        first: first,
        second: second,
        observed: first,
      );
      final element = tester.element(find.byKey(_regionKey));
      await _focusAndPaint(tester, second);
      expect(_ring, findsNothing);
      await _mountObserved(
        tester,
        first: first,
        second: second,
        observed: second,
      );
      expect(tester.element(find.byKey(_regionKey)), same(element));
      expect(_ring, findsNothing);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      expect(_ring, findsOneWidget);
      await _focusAndPaint(tester, first);
      expect(second.hasFocus, isFalse);
      expect(_ring, findsNothing);
      await _focusAndPaint(tester, second);
      expect(_ring, findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
      FocusManager.instance.highlightStrategy = originalStrategy;
      _disposeIfLive(first);
      _disposeIfLive(second);
    }
  });

  testWidgets(
    'an observed-node replacement keeps pointer focus unhighlighted',
    (tester) async {
      final first = FocusNode(debugLabel: 'first pointer-observed node');
      final second = FocusNode(debugLabel: 'second pointer-observed node');
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _mountObserved(
          tester,
          first: first,
          second: second,
          observed: first,
        );
        await _focusAndPaint(tester, second);
        _observerListener(tester)
            .onPointerDown!(const PointerDownEvent(pointer: 1));
        await _mountObserved(
          tester,
          first: first,
          second: second,
          observed: second,
        );
        expect(_ring, findsNothing);
        _observerListener(tester)
            .onPointerUp!(const PointerUpEvent(pointer: 1));
        await tester.pump();
        expect(_ring, findsNothing);

        // A later genuine focus loss/gain without a pointer restores the
        // keyboard highlight instead of permanently suppressing the new node.
        await _focusAndPaint(tester, first);
        expect(second.hasFocus, isFalse);
        await _focusAndPaint(tester, second);
        expect(_ring, findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        _disposeIfLive(first);
        _disposeIfLive(second);
      }
    },
  );

  for (final focus in [true, false]) {
    final kind = focus ? 'focus' : 'hover';
    testWidgets(
      'replacing an active $kind target synchronizes its listening ancestor safely',
      (tester) async {
        final oldTarget = _RetirableNotifier();
        final nextTarget = _RetirableNotifier();
        final originalStrategy = FocusManager.instance.highlightStrategy;
        try {
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.alwaysTraditional;
          await _mountAncestorListener(tester, oldTarget, focus: focus);
          if (focus) {
            await _focusAndPaint(tester, _detector(tester).focusNode!);
          } else {
            _detector(tester).onShowHoverHighlight!(true);
          }
          await tester.pump();
          expect(oldTarget.value, isTrue);
          final element = tester.element(find.byKey(_regionKey));

          // Its value is no longer readable. The region must remember its
          // actual highlight state instead of consulting a retired resource.
          oldTarget.dispose();
          await _mountAncestorListener(tester, nextTarget, focus: focus);
          expect(tester.takeException(), isNull);
          await tester.pump();
          expect(tester.element(find.byKey(_regionKey)), same(element));
          // No second pointer/highlight callback occurs after replacement.
          expect(nextTarget.value, isTrue);
          expect(find.text('target:true'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _unmount(tester);
          FocusManager.instance.highlightStrategy = originalStrategy;
          _disposeIfLive(oldTarget);
          _disposeIfLive(nextTarget);
        }
      },
    );
  }

  testWidgets(
    'mode round trips retire old detector callbacks and keep the element',
    (tester) async {
      final observed = FocusNode(debugLabel: 'round-trip observed');
      final interactive = FocusNode(debugLabel: 'round-trip interactive');
      final oldFocus = _RetirableNotifier();
      final oldHover = _RetirableNotifier();
      final nextFocus = _RetirableNotifier();
      final nextHover = _RetirableNotifier();
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _mountMode(
          tester,
          observe: false,
          observedNode: observed,
          interactiveNode: interactive,
          focused: oldFocus,
          hovered: oldHover,
        );
        final element = tester.element(find.byKey(_regionKey));
        final retiredDetector = _detector(tester);
        await _mountMode(
          tester,
          observe: true,
          observedNode: observed,
          interactiveNode: interactive,
        );
        expect(tester.element(find.byKey(_regionKey)), same(element));
        oldFocus.dispose();
        oldHover.dispose();
        expect(
          () => retiredDetector.onShowFocusHighlight!(true),
          returnsNormally,
        );
        expect(
          () => retiredDetector.onShowHoverHighlight!(true),
          returnsNormally,
        );
        await tester.pump();
        expect(_ring, findsNothing);

        await _mountMode(
          tester,
          observe: false,
          observedNode: observed,
          interactiveNode: interactive,
          focused: nextFocus,
          hovered: nextHover,
        );
        expect(tester.element(find.byKey(_regionKey)), same(element));
        // Checking only the current mode is insufficient: this is interactive
        // again, but callbacks captured from the earlier epoch are still stale.
        expect(
          () => retiredDetector.onShowFocusHighlight!(true),
          returnsNormally,
        );
        expect(
          () => retiredDetector.onShowHoverHighlight!(true),
          returnsNormally,
        );
        await tester.pump();
        expect(nextFocus.value, isFalse);
        expect(nextHover.value, isFalse);
        expect(_ring, findsNothing);
        final current = _detector(tester);
        await _focusAndPaint(tester, current.focusNode!);
        current.onShowHoverHighlight!(true);
        await tester.pump();
        expect(nextFocus.value, isTrue);
        expect(nextHover.value, isTrue);
        expect(_ring, findsOneWidget);
        retiredDetector.onShowFocusHighlight!(false);
        retiredDetector.onShowHoverHighlight!(false);
        await tester.pump();
        expect(nextFocus.value, isTrue);
        expect(nextHover.value, isTrue);
        expect(_ring, findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        for (final resource in [
          observed,
          interactive,
          oldFocus,
          oldHover,
          nextFocus,
          nextHover,
        ]) {
          _disposeIfLive(resource);
        }
      }
    },
  );

  testWidgets(
    'an initially observed region gains current interactive actions',
    (tester) async {
      final observed = FocusNode(debugLabel: 'initially observed');
      final interactive = FocusNode(debugLabel: 'new interactive');
      var activations = 0;
      try {
        await _mountMode(
          tester,
          observe: true,
          observedNode: observed,
          interactiveNode: interactive,
        );
        final element = tester.element(find.byKey(_regionKey));
        await _mountMode(
          tester,
          observe: false,
          observedNode: observed,
          interactiveNode: interactive,
          onActivate: () => activations++,
        );
        expect(tester.element(find.byKey(_regionKey)), same(element));
        final detector = _detector(tester);
        expect(detector.focusNode, same(interactive));
        final actionContext = detector.focusNode!.context!;
        expect(
          Actions.maybeFind<Intent>(
            actionContext,
            intent: const ActivateIntent(),
          ),
          isNotNull,
        );
        Actions.maybeInvoke(actionContext, const ActivateIntent());
        expect(activations, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        _disposeIfLive(observed);
        _disposeIfLive(interactive);
      }
    },
  );

  for (final unmountBeforeSync in [false, true]) {
    final action = unmountBeforeSync ? 'unmounting' : 'replacing again';
    testWidgets('$action before queued synchronization retires pending targets', (
      tester,
    ) async {
      final oldFocus = _RetirableNotifier();
      final oldHover = _RetirableNotifier();
      final middleFocus = _RetirableNotifier();
      final middleHover = _RetirableNotifier();
      final lastFocus = _RetirableNotifier();
      final lastHover = _RetirableNotifier();
      final originalStrategy = FocusManager.instance.highlightStrategy;
      try {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _mountQueuedRegion(tester, focused: oldFocus, hovered: oldHover);
        final detector = _detector(tester);
        await _focusAndPaint(tester, detector.focusNode!);
        detector.onShowHoverHighlight!(true);
        await tester.pump();
        final element = tester.element(find.byKey(_regionKey));
        final host = tester.element(find.byKey(_hostKey));

        // Register before the frame that replaces the targets. This callback
        // runs before any synchronization queued by that frame's didUpdateWidget.
        // Direct Element.update controls this narrow lifecycle ordering without
        // adding a public product hook or relying on a pointer event's timing.
        tester.binding.addPostFrameCallback((_) {
          final owner = tester.binding.buildOwner!;
          // StatefulElement.update performs a rebuild and must run under a
          // real build scope, including the framework's state lock.
          owner.buildScope(host, () {
            if (unmountBeforeSync) {
              host.update(
                const Center(key: _hostKey, child: SizedBox.shrink()),
              );
            } else {
              element.update(
                _interactiveRegion(focused: lastFocus, hovered: lastHover),
              );
            }
          });
          if (unmountBeforeSync) owner.finalizeTree();
          middleFocus.dispose();
          middleHover.dispose();
        });
        oldFocus.dispose();
        oldHover.dispose();
        await _mountQueuedRegion(
          tester,
          focused: middleFocus,
          hovered: middleHover,
        );
        expect(tester.takeException(), isNull);
        await tester.pump();
        expect(tester.takeException(), isNull);
        if (unmountBeforeSync) {
          expect(find.byKey(_regionKey), findsNothing);
        } else {
          expect(tester.element(find.byKey(_regionKey)), same(element));
          expect(lastFocus.value, isTrue);
          expect(lastHover.value, isTrue);
        }
      } finally {
        await _unmount(tester);
        FocusManager.instance.highlightStrategy = originalStrategy;
        for (final resource in [
          oldFocus,
          oldHover,
          middleFocus,
          middleHover,
          lastFocus,
          lastHover,
        ]) {
          _disposeIfLive(resource);
        }
      }
    });
  }
}
