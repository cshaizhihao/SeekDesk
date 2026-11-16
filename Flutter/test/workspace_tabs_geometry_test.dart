import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

JsonMap _tab(String id, String title) => {
  'id': id,
  'title': title,
  'url': 'https://www.nodeseek.com/post-$id-1',
};

List<JsonMap> _threeTabs() => [
  _tab('1', '甲'),
  _tab('2', '乙乙'),
  _tab('3', '第三篇较长标题'),
];

/// Selections and explicit close actions end in this memory workspace. Readers
/// are already cached: a layout update must never issue a forum/network read.
class _GeometryNative extends NativeClient {
  _GeometryNative(this.tabs, this.selected)
    : super(methods: const MethodChannel('seekdesk.test.tab-geometry'));

  List<JsonMap> tabs;
  String selected;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];

  JsonMap get workspace => {
    'tabs': tabs,
    'selectedTab': selected,
    'showReader': true,
    'posts': <JsonMap>[],
    'boards': <JsonMap>[],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    final id = args['id'];
    if (method == 'reader.select' && tabs.any((tab) => tab['id'] == id)) {
      selected = id as String;
      return workspace;
    }
    if (method == 'reader.close' && tabs.any((tab) => tab['id'] == id)) {
      tabs = tabs.where((tab) => tab['id'] != id).toList();
      if (selected == id) selected = tabs.first['id'] as String;
      return workspace;
    }
    unexpected.add(method);
    throw StateError('Unexpected tab geometry operation: $method');
  }
}

class _GeometryState extends AppState {
  _GeometryState(this.native) : super(client: native) {
    connecting = false;
    domains['session'] = {'account': 'signedOut'};
    domains['workspace'] = native.workspace;
    for (final tab in native.tabs) {
      readers[tab['url'] as String] = {
        'url': tab['url'],
        'thread': <String, dynamic>{},
      };
    }
  }

  final _GeometryNative native;

  void replaceTabs(List<JsonMap> tabs) {
    native.tabs = tabs;
    domains['workspace'] = native.workspace;
    notifyListeners();
  }
}

class _GeometryHarness extends StatefulWidget {
  const _GeometryHarness({
    required this.state,
    required this.initialWidth,
    required this.reduceMotion,
    super.key,
  });

  final _GeometryState state;
  final double initialWidth;
  final bool reduceMotion;

  @override
  State<_GeometryHarness> createState() => _GeometryHarnessState();
}

class _GeometryHarnessState extends State<_GeometryHarness> {
  late double width = widget.initialWidth;
  double textScale = 1;
  int selections = 0;

  void resize(double value) => setState(() => width = value);
  void scaleText(double value) => setState(() => textScale = value);

  @override
  Widget build(BuildContext context) => CupertinoApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: GlassAccessibilityScope(
        reduceMotion: widget.reduceMotion,
        child: child!,
      ),
    ),
    home: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: width,
            child: WorkspaceTabs(
              state: widget.state,
              onSelect: () => selections++,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<
  ({
    _GeometryNative native,
    _GeometryState state,
    _GeometryHarnessState harness,
  })
>
_mount(
  WidgetTester tester, {
  List<JsonMap>? tabs,
  String selected = '2',
  double width = 1000,
  bool reduceMotion = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 600));
  final native = _GeometryNative(tabs ?? _threeTabs(), selected);
  final state = _GeometryState(native);
  final key = GlobalKey<_GeometryHarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    _GeometryHarness(
      key: key,
      state: state,
      initialWidth: width,
      reduceMotion: reduceMotion,
    ),
  );
  await _settle(tester);
  return (native: native, state: state, harness: key.currentState!);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  // Text weight itself animates for 200 ms in the official scrollable cell.
  // Check its final measured geometry, not the old or an intermediate style.
  await tester.pumpAndSettle(
    const Duration(milliseconds: 25),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Future<void> _expectNoContinuousFrames(WidgetTester tester) async {
  expect(tester.binding.hasScheduledFrame, isFalse);
  expect(tester.binding.transientCallbackCount, 0);
  // Explicit unrelated frames must not restart an unchanged size observer,
  // post-layout measurement, or a settled spring. Include a longer timer gap.
  for (final delay in [16, 16, 250, 1000]) {
    await tester.pump(Duration(milliseconds: delay));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  }
  expect(tester.takeException(), isNull);
}

Finder get _control => find.byType(GlassSegmentedControl);
Finder _target(String id) => find.byKey(ValueKey('tab-target-$id'));
Finder _title(String id) =>
    find.descendant(of: _target(id), matching: find.byType(Text));

void _expectOnlyCall(_GeometryNative native, String method, String id) {
  expect(native.calls, hasLength(1));
  expect(native.calls.single.$1, method);
  expect(native.calls.single.$2, {'id': id});
}

/// The cell is its actual label box plus the control's public label padding.
/// Comparing only selectedIndex or the indicator's input properties would miss
/// a correct selection drawn with stale cached widths/offsets.
Rect _cellRect(WidgetTester tester, String id) {
  final control = tester.widget<GlassSegmentedControl>(_control);
  final direction = Directionality.of(tester.element(_control));
  final padding = control.labelPadding.resolve(direction);
  final inset = control.padding.resolve(direction);
  final label = tester.getRect(_target(id));
  final track = tester.getRect(_control);
  return Rect.fromLTRB(
    label.left - padding.left,
    track.top + inset.top,
    label.right + padding.right,
    track.bottom - inset.bottom,
  );
}

void _expectLensAt(WidgetTester tester, String id, {bool fullyVisible = true}) {
  final control = tester.widget<GlassSegmentedControl>(_control);
  expect(control.segments[control.selectedIndex].id, id);
  final expected = _cellRect(tester, id);
  final indicators = find.descendant(
    of: _control,
    matching: find.byType(AnimatedGlassIndicator),
  );
  expect(indicators, findsNWidgets(2));
  for (final element in indicators.evaluate()) {
    final indicator = find.byElementPredicate(
      (value) => identical(value, element),
    );
    // AnimatedGlassIndicator has a full-track outer box. Its explicitly
    // positioned child is the actual resting pill/lens box we must compare.
    final positioned = find.descendant(
      of: indicator,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Positioned && widget.width != null && widget.left != null,
      ),
    );
    expect(positioned, findsOneWidget);
    final actual = tester.getRect(positioned);
    expect(
      actual.left,
      closeTo(expected.left, .75),
      reason: 'Selected $id lens left',
    );
    expect(
      actual.right,
      closeTo(expected.right, .75),
      reason: 'Selected $id lens right',
    );
    expect(
      actual.top,
      closeTo(expected.top, .75),
      reason: 'Selected $id lens top',
    );
    expect(
      actual.bottom,
      closeTo(expected.bottom, .75),
      reason: 'Selected $id lens bottom',
    );
  }
  if (fullyVisible) {
    final track = tester.getRect(_control);
    expect(expected.left, greaterThanOrEqualTo(track.left - .75));
    expect(expected.right, lessThanOrEqualTo(track.right + .75));
    expect(_title(id).hitTestable(), findsOneWidget);
  }
  expect(tester.takeException(), isNull);
}

ScrollController _stripController(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.descendant(
        of: _control,
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .controller!;

bool _focusInside(WidgetTester tester, Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final target = tester.element(finder);
  var found = identical(focused, target);
  focused.visitAncestorElements((element) {
    found = found || identical(element, target);
    return !found;
  });
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final adding in [true, false]) {
    testWidgets(
      'active ${adding ? 'insertion' : 'removal'} regrid accepts same-count title and order updates without replacing survivors',
      (tester) async {
        final fixture = await _mount(tester, reduceMotion: false);
        expect(
          tester.widget<GlassSegmentedControl>(_control).regridDuration,
          const Duration(milliseconds: 200),
        );
        final survivors = adding ? ['1', '2', '3'] : ['1', '2'];
        final elements = {
          for (final id in survivors) id: tester.element(_target(id)),
        };
        final controlElement = tester.element(_control);
        final controller = _stripController(tester);
        final interim = adding
            ? [
                _tab('1', '甲'),
                _tab('4', '新增的第四篇'),
                _tab('2', '乙乙'),
                _tab('3', '第三篇较长标题'),
              ]
            : [_tab('1', '甲'), _tab('2', '乙乙')];
        fixture.state.replaceTabs(interim);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        void expectActiveMorph() {
          // Inspect the official entering/exiting cell's visible interpolation,
          // without importing its private state or declaring an animation by
          // duration alone. The title/order updates below happen mid-morph.
          final animatedCell = find.ancestor(
            of: _target(adding ? '4' : '3'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Align &&
                  widget.widthFactor != null &&
                  widget.widthFactor! > 0 &&
                  widget.widthFactor! < 1,
            ),
          );
          expect(animatedCell, findsOneWidget);
          expect(tester.binding.hasScheduledFrame, isTrue);
        }

        expectActiveMorph();
        final renamed = [
          for (final tab in interim)
            _tab(
              tab['id'] as String,
              tab['id'] == '2' ? '动画中仍然选中的第二篇' : '动画中更新的第${tab['id']}篇标题',
            ),
        ];
        fixture.state.replaceTabs(renamed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        expectActiveMorph();
        expect(
          find.descendant(of: _target('2'), matching: find.text('动画中仍然选中的第二篇')),
          findsOneWidget,
        );
        for (final id in survivors) {
          expect(tester.element(_target(id)), same(elements[id]));
        }

        final byID = {for (final tab in renamed) tab['id'] as String: tab};
        final order = adding ? ['3', '2', '4', '1'] : ['2', '1'];
        fixture.state.replaceTabs([for (final id in order) byID[id]!]);
        await _settle(tester);
        expect(tester.element(_control), same(controlElement));
        expect(_stripController(tester), same(controller));
        expect(fixture.state.workspace.tabs.map((tab) => tab.id), order);
        for (final id in survivors) {
          expect(tester.element(_target(id)), same(elements[id]));
        }
        if (!adding) expect(_target('3'), findsNothing);
        _expectLensAt(tester, '2');
        expect(fixture.native.calls, isEmpty);
        await _expectNoContinuousFrames(tester);
      },
    );
  }

  testWidgets(
    'manual horizontal wheel wins over the same frame pending title measurement',
    (tester) async {
      final fixture = await _mount(
        tester,
        tabs: [for (var id = 1; id <= 6; id++) _tab('$id', '第$id帖标题')],
        selected: '6',
        width: 480,
      );
      final controller = _stripController(tester);
      final originalOffset = controller.offset;
      expect(originalOffset, greaterThan(150));
      final pointerPosition = tester.getCenter(_control);
      double? userOffset;
      // Register before rebuilding: this runs after the new cells lay out but
      // before the measurement callbacks they enqueue in that frame. The wheel
      // deliberately browses older tabs while selection remains on tab six.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: pointerPosition,
            scrollDelta: const Offset(-140, 0),
            kind: PointerDeviceKind.mouse,
          ),
        );
        userOffset = controller.offset;
      });
      fixture.state.replaceTabs([
        for (var id = 1; id <= 6; id++)
          _tab('$id', id == 1 ? '第一篇标题加载后明显变长并等待重新测量' : '第$id帖标题'),
      ]);
      await tester.pump();
      expect(userOffset, isNotNull);
      expect(userOffset!, lessThan(originalOffset - 100));
      await _settle(tester);
      expect(controller.offset, closeTo(userOffset!, .75));
      expect(fixture.state.workspace.selectedTab, '6');
      _expectLensAt(tester, '6', fullyVisible: false);

      // A subsequent natural-size notification must not silently resume the
      // previously cancelled automatic reveal either.
      fixture.state.replaceTabs([
        for (final tab in fixture.native.tabs)
          tab['id'] == '2' ? _tab('2', '第二篇标签接着更新为更长的标题') : {...tab},
      ]);
      await _settle(tester);
      expect(_stripController(tester), same(controller));
      expect(controller.offset, closeTo(userOffset!, .75));
      _expectLensAt(tester, '6', fullyVisible: false);
      expect(fixture.native.calls, isEmpty);
      expect(fixture.harness.selections, 0);
      await _expectNoContinuousFrames(tester);
    },
  );

  testWidgets(
    'settled geometry and identical snapshots do not schedule continuing frames',
    (tester) async {
      final fixture = await _mount(tester, reduceMotion: false);
      fixture.state.replaceTabs([
        _tab('1', '加载后加长的标题'),
        _tab('2', '当前选中的第二个标题'),
        _tab('3', '第三篇'),
      ]);
      fixture.harness.scaleText(2);
      await _settle(tester);
      _expectLensAt(tester, '2');
      await _expectNoContinuousFrames(tester);
      for (var refresh = 0; refresh < 3; refresh++) {
        fixture.state.replaceTabs([
          for (final tab in fixture.native.tabs) {...tab},
        ]);
        await _settle(tester);
        _expectLensAt(tester, '2');
        await _expectNoContinuousFrames(tester);
      }
      expect(fixture.native.calls, isEmpty);
    },
  );

  testWidgets(
    'same-count preceding title changes move the selected lens with its real cell',
    (tester) async {
      final fixture = await _mount(tester);
      final originalCell = _cellRect(tester, '2');
      final controlElement = tester.element(_control);
      final selectedElement = tester.element(_target('2'));
      _expectLensAt(tester, '2');

      fixture.state.replaceTabs([
        _tab('1', '前一个标签加载后的完整标题明显更长'),
        _tab('2', '乙乙'),
        _tab('3', '第三篇较长标题'),
      ]);
      await _settle(tester);
      expect(_cellRect(tester, '2').left, greaterThan(originalCell.left + 50));
      expect(tester.element(_control), same(controlElement));
      expect(tester.element(_target('2')), same(selectedElement));
      _expectLensAt(tester, '2');
      expect(fixture.native.calls, isEmpty);
      expect(fixture.harness.selections, 0);
    },
  );

  testWidgets(
    'selected title grows and shrinks without remounting the official lens control',
    (tester) async {
      final fixture = await _mount(tester);
      final controlState = tester.state(_control);
      final initialWidth = _cellRect(tester, '2').width;
      for (final title in ['选中标签的新标题需要更宽的透镜', '乙']) {
        fixture.state.replaceTabs([
          _tab('1', '甲'),
          _tab('2', title),
          _tab('3', '第三篇较长标题'),
        ]);
        await _settle(tester);
        expect(tester.state(_control), same(controlState));
        _expectLensAt(tester, '2');
        expect(
          _cellRect(tester, '2').width,
          title == '乙'
              ? lessThan(initialWidth)
              : greaterThan(initialWidth + 50),
        );
      }
      expect(fixture.native.calls, isEmpty);
    },
  );

  testWidgets(
    'system text-size changes remeasure both natural widths and the selected lens',
    (tester) async {
      final fixture = await _mount(
        tester,
        tabs: [_tab('1', 'AB'), _tab('2', 'CDE'), _tab('3', 'FGHI')],
        selected: '3',
      );
      final original = _cellRect(tester, '3');
      final controlElement = tester.element(_control);
      final selectedElement = tester.element(_target('3'));
      for (final scale in [2.0, 1.0]) {
        fixture.harness.scaleText(scale);
        await _settle(tester);
        expect(tester.element(_control), same(controlElement));
        expect(tester.element(_target('3')), same(selectedElement));
        expect(
          MediaQuery.textScalerOf(tester.element(_title('3'))).scale(13),
          13 * scale,
        );
        _expectLensAt(tester, '3');
        if (scale == 2) {
          expect(_cellRect(tester, '3').left, greaterThan(original.left + 20));
          expect(
            _cellRect(tester, '3').width,
            greaterThan(original.width + 20),
          );
        } else {
          expect(_cellRect(tester, '3').width, closeTo(original.width, .75));
        }
      }
      expect(fixture.native.calls, isEmpty);
    },
  );

  testWidgets(
    'same-count reorders retain identities and remeasure the selected offset',
    (tester) async {
      final fixture = await _mount(tester);
      final elements = {
        for (final id in ['1', '2', '3']) id: tester.element(_target(id)),
      };
      final tabs = _threeTabs();
      for (final order in [
        [2, 1, 0],
        [1, 0, 2],
      ]) {
        fixture.state.replaceTabs([for (final index in order) tabs[index]]);
        await _settle(tester);
        expect(fixture.state.workspace.selectedTab, '2');
        for (final id in elements.keys) {
          expect(tester.element(_target(id)), same(elements[id]));
        }
        _expectLensAt(tester, '2');
      }
      expect(fixture.native.calls, isEmpty);
      await tester.tap(_title('3'));
      await _settle(tester);
      _expectOnlyCall(fixture.native, 'reader.select', '3');
      expect(fixture.harness.selections, 1);
      _expectLensAt(tester, '3');
    },
  );

  testWidgets(
    'tap selection uses the new titles and settles selected text weight before lens measurement',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.state.replaceTabs([
        _tab('1', '加长后的第一个标签标题'),
        _tab('2', '乙乙'),
        _tab('3', 'WWWWiiii'),
      ]);
      await _settle(tester);
      await tester.tap(_title('3'));
      await _settle(tester);
      _expectOnlyCall(fixture.native, 'reader.select', '3');
      expect(fixture.harness.selections, 1);
      expect(
        DefaultTextStyle.of(tester.element(_title('3'))).style.fontWeight,
        FontWeight.w600,
      );
      expect(
        DefaultTextStyle.of(tester.element(_title('2'))).style.fontWeight,
        FontWeight.w400,
      );
      _expectLensAt(tester, '3');
    },
  );

  testWidgets(
    'resized preceding labels still let a lens drag choose the actual target cell',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.state.replaceTabs([
        _tab('1', '加长后的第一个标签标题'),
        _tab('2', '乙乙'),
        _tab('3', '第三篇较长标题'),
      ]);
      await _settle(tester);
      final start = tester.getCenter(_title('2'));
      final end = tester.getCenter(_title('3'));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await _settle(tester);
      _expectOnlyCall(fixture.native, 'reader.select', '3');
      expect(fixture.harness.selections, 1);
      _expectLensAt(tester, '3');
    },
  );

  testWidgets(
    'a pointer held during reordering cannot select the old numeric slot',
    (tester) async {
      final fixture = await _mount(tester);
      final gesture = await tester.startGesture(tester.getCenter(_title('1')));
      await tester.pump();
      fixture.state.replaceTabs([
        _tab('3', '第三篇较长标题'),
        _tab('2', '乙乙'),
        _tab('1', '按下时的第一个标签现在已经移到最后'),
      ]);
      await _settle(tester);
      await gesture.up();
      await _settle(tester);
      // A moved target may cancel the press or retain its original identity.
      // It must never activate the different tab now occupying the old index.
      expect(fixture.native.calls.length, lessThanOrEqualTo(1));
      for (final call in fixture.native.calls) {
        expect(call.$1, 'reader.select');
        expect(call.$2, {'id': '1'});
      }
      final selected = fixture.native.calls.isEmpty ? '2' : '1';
      expect(fixture.state.workspace.selectedTab, selected);
      expect(fixture.harness.selections, fixture.native.calls.length);
      _expectLensAt(tester, selected);
    },
  );

  testWidgets(
    'a pointer held during title-width changes cannot activate the newly covered tab',
    (tester) async {
      final fixture = await _mount(tester);
      final pressedPoint = tester.getCenter(_title('3'));
      final originalElement = tester.element(_target('3'));
      final gesture = await tester.startGesture(pressedPoint);
      await tester.pump();
      fixture.state.replaceTabs([
        _tab('1', '先前短标题加载后变得明显更长并覆盖按下位置'),
        _tab('2', '乙乙'),
        _tab('3', '仍然是最初按下的第三个帖子'),
      ]);
      await _settle(tester);
      expect(tester.element(_target('3')), same(originalElement));
      expect(_cellRect(tester, '3').left, greaterThan(pressedPoint.dx + 20));
      expect(
        ['1', '2'].any((id) => _cellRect(tester, id).contains(pressedPoint)),
        isTrue,
      );
      await gesture.up();
      await _settle(tester);
      // The label under the stationary pointer is now a different ID. Keep
      // the press's original identity or cancel it; never resolve by new x.
      expect(fixture.native.calls.length, lessThanOrEqualTo(1));
      for (final call in fixture.native.calls) {
        expect(call.$1, 'reader.select');
        expect(call.$2, {'id': '3'});
      }
      final selected = fixture.native.calls.isEmpty ? '2' : '3';
      expect(fixture.state.workspace.selectedTab, selected);
      expect(fixture.harness.selections, fixture.native.calls.length);
      _expectLensAt(tester, selected);
      await _expectNoContinuousFrames(tester);
    },
  );

  testWidgets(
    'accessibility activation works immediately after a structure-changing press is cancelled',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(tester);
        final gesture = await tester.startGesture(
          tester.getCenter(_title('1')),
        );
        await tester.pump();
        fixture.state.replaceTabs([
          _tab('3', '第三篇较长标题'),
          _tab('2', '乙乙'),
          _tab('1', '取消按压时已经移动到最后的标签'),
        ]);
        await _settle(tester);
        await gesture.cancel();
        await _settle(tester);
        expect(fixture.native.calls, isEmpty);
        expect(fixture.state.workspace.selectedTab, '2');

        // Invoke the public semantics action with no intervening mouse press.
        // A cancellation guard must retire with its gesture instead of
        // keeping assistive activation disabled until another pointer-down.
        const title = '第三篇较长标题';
        final otherTitles = fixture.native.tabs
            .where((tab) => tab['id'] != '3')
            .map((tab) => tab['title'] as String);
        final actionable = find.semantics
            .byLabel(RegExp(title))
            .evaluate()
            .where((node) {
              final data = node.getSemanticsData();
              return data.hasAction(SemanticsAction.tap) &&
                  !data.label.startsWith('关闭标签：') &&
                  otherTitles.every((other) => !data.label.contains(other));
            });
        expect(actionable, hasLength(1));
        tester
            .renderObject(_target('3'))
            .owner!
            .semanticsOwner!
            .performAction(actionable.single.id, SemanticsAction.tap);
        await _settle(tester);
        _expectOnlyCall(fixture.native, 'reader.select', '3');
        expect(fixture.harness.selections, 1);
        expect(fixture.state.workspace.selectedTab, '3');
        _expectLensAt(tester, '3');
        await _expectNoContinuousFrames(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'the first lens drag after cancelling a reordered press selects the correct current ID',
    (tester) async {
      final fixture = await _mount(tester);
      final oldGesture = await tester.startGesture(
        tester.getCenter(_title('1')),
      );
      await tester.pump();
      fixture.state.replaceTabs([
        _tab('3', '第三篇较长标题'),
        _tab('1', '重排后位于中间的第一篇'),
        _tab('2', '乙乙'),
      ]);
      await _settle(tester);
      await oldGesture.cancel();
      await _settle(tester);
      expect(fixture.native.calls, isEmpty);
      expect(fixture.state.workspace.selectedTab, '2');
      _expectLensAt(tester, '2');

      // No preliminary click primes the recognizers. The very next gesture
      // begins on the actual current lens and crosses to its new left target.
      final start = tester.getCenter(_title('2'));
      final end = tester.getCenter(_title('3'));
      expect(end.dx, lessThan(start.dx - 50));
      final drag = await tester.startGesture(start);
      await drag.moveBy(const Offset(-25, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await drag.moveTo(end);
      await tester.pump(const Duration(milliseconds: 100));
      await drag.up();
      await _settle(tester);
      _expectOnlyCall(fixture.native, 'reader.select', '3');
      expect(fixture.harness.selections, 1);
      expect(fixture.state.workspace.selectedTab, '3');
      _expectLensAt(tester, '3');
      await _expectNoContinuousFrames(tester);
    },
  );

  testWidgets(
    'offscreen selection stays seated after title and viewport changes without replacing its scroll state',
    (tester) async {
      final fixture = await _mount(
        tester,
        tabs: [for (var id = 1; id <= 6; id++) _tab('$id', '第$id个标签的完整名称')],
        selected: '6',
        width: 480,
      );
      final controller = _stripController(tester);
      final selectedElement = tester.element(_target('6'));
      expect(controller.offset, greaterThan(0));
      _expectLensAt(tester, '6');
      fixture.state.replaceTabs([
        for (var id = 1; id <= 6; id++) _tab('$id', id == 6 ? '六' : '$id'),
      ]);
      await _settle(tester);
      _expectLensAt(tester, '6');
      for (final width in [340.0, 700.0]) {
        fixture.harness.resize(width);
        await _settle(tester);
        expect(_stripController(tester), same(controller));
        expect(tester.element(_target('6')), same(selectedElement));
        _expectLensAt(tester, '6');
      }
      expect(fixture.native.calls, isEmpty);
    },
  );

  testWidgets(
    'keyboard focus on an existing close action survives tab reflow and uses the current selection',
    (tester) async {
      final fixture = await _mount(tester);
      final close = find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '关闭当前标签',
      );
      for (
        var attempt = 0;
        attempt < 8 && !_focusInside(tester, close);
        attempt++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(_focusInside(tester, close), isTrue);
      final focus = FocusManager.instance.primaryFocus;
      final controlElement = tester.element(_control);
      fixture.state.replaceTabs([
        _tab('3', '第三篇较长标题'),
        _tab('1', '改名并且重排后的第一个标签'),
        _tab('2', '仍然选中的第二个标签'),
      ]);
      fixture.harness.scaleText(2);
      await _settle(tester);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(_focusInside(tester, close), isTrue);
      expect(tester.element(_control), same(controlElement));
      _expectLensAt(tester, '2');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      _expectOnlyCall(fixture.native, 'reader.close', '2');
      expect(fixture.state.workspace.tabs.map((tab) => tab.id), ['3', '1']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
