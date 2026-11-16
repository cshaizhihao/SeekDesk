import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

/// Exercise the actual non-embedded route. No forum, preferences, clipboard,
/// upload or network operations can fall through this strict memory service.
class _Native extends NativeClient {
  _Native()
    : super(
        methods: MethodChannel('seekdesk.test.value-standalone.${_next++}'),
      );

  static int _next = 0;
  final calls = <String>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'value.currencies':
        return {
          'items': [
            {'code': 'USD', 'title': 'USD 美元'},
            {'code': 'CNY', 'title': 'CNY 人民币'},
          ],
        };
      case 'value.rate':
        return {
          'base': arguments['base'],
          'quote': arguments['quote'],
          'rate': '7.2',
          'source': 'Memory exchange rate',
          'asOf': DateTime(2027, 1, 1).millisecondsSinceEpoch,
        };
      default:
        unexpected.add(method);
        throw StateError('Unexpected standalone value request: $method');
    }
  }
}

class _Fixture {
  _Fixture({required double textScale}) : scale = ValueNotifier(textScale) {
    state = AppState(client: native)..connecting = false;
    state.domains['session'] = {'account': 'signedIn', 'owner': 42};
  }

  final native = _Native();
  late final AppState state;
  final navigator = GlobalKey<NavigatorState>();
  final ValueNotifier<double> scale;
}

// Cupertino route transitions last 500 ms. The first pump starts their ticker,
// so six 80 ms pumps leave the page translated when geometry is captured.
Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
}) async {
  final fixture = _Fixture(textScale: textScale);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
    fixture.state.dispose();
    fixture.scale.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(fixture.native.unexpected, isEmpty);
    expect(
      fixture.native.calls,
      unorderedEquals(['value.currencies', 'value.rate']),
    );
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        navigatorKey: fixture.navigator,
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable: fixture.scale,
          child: child,
          builder: (context, scale, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
        ),
        home: const CupertinoPageScaffold(
          child: Center(child: Text('Value tool source')),
        ),
      ),
    ),
  );
  await _frames(tester);
  final route = CupertinoPageRoute<void>(
    builder: (_) => ValueScreen(state: fixture.state),
  );
  unawaited(fixture.navigator.currentState!.push<void>(route));
  await _frames(tester);
  expect(route.animation!.status, AnimationStatus.completed);
  expect(find.byType(ValueScreen), findsOneWidget);
  expect(
    tester.widget<ValueScreen>(find.byType(ValueScreen)).embedded,
    isFalse,
  );
  expect(tester.takeException(), isNull);
  return fixture;
}

Finder get _close => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == '关闭估价',
);

Finder get _calculate => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == '计算剩余价值',
);

Finder get _amount => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.placeholder == '例如 35.99',
  skipOffstage: false,
);

Finder get _scroll => find.descendant(
  of: find.byType(ValueScreen),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  ),
);

Future<void> _bottom(WidgetTester tester) async {
  expect(_scroll, findsOneWidget);
  final position = tester.state<ScrollableState>(_scroll).position;
  for (var attempt = 0; attempt < 80; attempt++) {
    if (position.maxScrollExtent > 0 && position.extentAfter <= .5) break;
    // A pointer-scroll event avoids dragging the glass segmented control
    // when that control happens to be in the middle of the form viewport.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(_scroll),
        scrollDelta: const Offset(0, 600),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await _frames(tester, 2);
  }
  expect(position.pixels, greaterThan(0));
  expect(position.extentAfter, lessThanOrEqualTo(.5));
  expect(tester.takeException(), isNull);
}

void _inside(Rect child, Rect parent, {required String reason}) {
  expect(child.width, greaterThan(0), reason: reason);
  expect(child.height, greaterThan(0), reason: reason);
  expect(child.left, greaterThanOrEqualTo(parent.left - .1), reason: reason);
  expect(child.top, greaterThanOrEqualTo(parent.top - .1), reason: reason);
  expect(child.right, lessThanOrEqualTo(parent.right + .1), reason: reason);
  expect(child.bottom, lessThanOrEqualTo(parent.bottom + .1), reason: reason);
}

void _expectCalculateUnclipped(WidgetTester tester, Size surface) {
  expect(_calculate.hitTestable(), findsOneWidget);
  final buttonRect = tester.getRect(_calculate);
  _inside(
    buttonRect,
    Offset.zero & surface,
    reason: 'The full calculate button must remain inside the short window.',
  );
  // A center hit alone can miss a button whose right edge is outside a clip.
  expect(_calculate.hitTestable(at: const Alignment(.9, 0)), findsOneWidget);
  final label = find.descendant(of: _calculate, matching: find.text('计算剩余价值'));
  expect(label, findsOneWidget);
  _inside(
    tester.getRect(label),
    buttonRect,
    reason: 'The calculate label must fit within its button, including at 2x.',
  );
  expect(
    tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
    isFalse,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // These are Flutter logical surfaces, not a claim that the 1720x665 macOS
  // outer frame supplies exactly that much content area below its title bar.
  for (final (size, scale) in [
    (const Size(1720, 665), 1.0),
    (const Size(780, 540), 2.0),
  ]) {
    testWidgets(
      'standalone value keeps close and calculate visible at the form bottom in $size at ${scale}x',
      (tester) async {
        await _mount(tester, size: size, textScale: scale);
        expect(_close.hitTestable(), findsOneWidget);
        final closeRect = tester.getRect(_close);
        await _bottom(tester);

        // Check the suspected right clipping independently before the known
        // scrolling-header failure, so the baseline tells these apart.
        _expectCalculateUnclipped(tester, size);
        expect(
          _close.hitTestable(),
          findsOneWidget,
          reason: 'Scrolling the standalone form must not scroll away Close.',
        );
        expect(tester.getRect(_close), closeRect);
        _inside(
          closeRect,
          Offset.zero & size,
          reason: 'Close stays in bounds.',
        );
        final calculateRect = tester.getRect(_calculate);
        final formRect = tester.getRect(_scroll);
        expect(
          closeRect.bottom,
          lessThanOrEqualTo(formRect.top),
          reason: 'The form must not paint or scroll over the close control.',
        );
        expect(
          calculateRect.top,
          greaterThanOrEqualTo(formRect.bottom),
          reason: 'The form scrollbar must not intercept the calculate button.',
        );
        final position = tester.state<ScrollableState>(_scroll).position;
        position.jumpTo(position.minScrollExtent);
        await _frames(tester);
        expect(tester.getRect(_close), closeRect);
        expect(tester.getRect(_calculate), calculateRect);
        _expectCalculateUnclipped(tester, size);
        expect(tester.takeException(), isNull);
        await tester.tap(_close);
        await _frames(tester);
        expect(find.byType(ValueScreen), findsNothing);
        expect(find.text('Value tool source'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'standalone value keeps its input connection focus selection and IME through short large-text reflow',
    (tester) async {
      final fixture = await _mount(tester, size: const Size(1100, 900));
      await tester.showKeyboard(_amount);
      const editing = TextEditingValue(
        text: '123.45',
        selection: TextSelection(baseOffset: 1, extentOffset: 4),
        composing: TextRange(start: 1, end: 4),
      );
      tester.testTextInput.updateEditingValue(editing);
      await _frames(tester);
      final element = tester.element(_amount);
      final controller = tester.widget<CupertinoTextField>(_amount).controller!;
      final editable = find.descendant(
        of: _amount,
        matching: find.byType(EditableText, skipOffstage: false),
        skipOffstage: false,
      );
      final editorState = tester.state<EditableTextState>(editable);
      final focus = tester.widget<EditableText>(editable).focusNode;
      void expectInputRetained(TextEditingValue value) {
        expect(tester.element(_amount), same(element));
        expect(
          tester.widget<CupertinoTextField>(_amount).controller,
          same(controller),
        );
        expect(tester.state<EditableTextState>(editable), same(editorState));
        expect(tester.widget<EditableText>(editable).focusNode, same(focus));
        expect(focus.hasFocus, isTrue);
        expect(controller.value, value);
      }

      expectInputRetained(editing);
      fixture.scale.value = 2;
      const short = Size(780, 540);
      await tester.binding.setSurfaceSize(short);
      await _frames(tester);
      expectInputRetained(editing);
      await _bottom(tester);
      expectInputRetained(editing);
      _expectCalculateUnclipped(tester, short);
      expect(_close.hitTestable(), findsOneWidget);
      _inside(
        tester.getRect(_close),
        Offset.zero & short,
        reason: 'A composing field must not hide the standalone close control.',
      );

      // Continue through the same platform input connection. Calling showKeyboard
      // or enterText here would conceal a discarded/recreated EditableText.
      final continued = editing.copyWith(
        text: '123.456',
        selection: const TextSelection.collapsed(offset: 7),
        composing: const TextRange(start: 4, end: 7),
      );
      tester.testTextInput.updateEditingValue(continued);
      await _frames(tester);
      expectInputRetained(continued);
      fixture.scale.value = 1;
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      await _frames(tester);
      expectInputRetained(continued);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
