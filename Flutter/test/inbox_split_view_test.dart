// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/inbox_split_view.dart';

const _listKey = ValueKey('list-state-probe');
const _detailKey = ValueKey('detail-state-probe');
const _boundsKey = ValueKey('split-content-bounds');

/// Owns real input and focus state so resizing tests detect element replacement,
/// controller replacement, selection loss and composing-region loss.
class _PaneProbe extends StatefulWidget {
  const _PaneProbe({
    required this.label,
    required this.onAction,
    this.showBack = false,
    super.key,
  });
  final String label;
  final VoidCallback onAction;
  final bool showBack;

  @override
  State<_PaneProbe> createState() => _PaneProbeState();
}

class _PaneProbeState extends State<_PaneProbe> {
  final content = TextEditingController();
  final focus = FocusNode();

  @override
  void dispose() {
    content.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: CupertinoColors.systemGrey6,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: '${widget.label} pane action',
          button: true,
          onTap: widget.onAction,
          excludeSemantics: true,
          child: GestureDetector(
            key: ValueKey('${widget.label}-action'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onAction,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${widget.label} action'),
            ),
          ),
        ),
        if (widget.showBack)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Return to list fixture'),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: CupertinoTextField(
            key: ValueKey('${widget.label}-editor'),
            controller: content,
            focusNode: focus,
            placeholder: '${widget.label} editor',
            maxLines: 3,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${widget.label} 保留正常字号的正文，窄窗允许自然换行。',
            key: ValueKey('${widget.label}-text'),
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    ),
  );
}

class _Fixture {
  int listActions = 0;
  int detailActions = 0;

  Future<void> render(
    WidgetTester tester, {
    double width = 1100,
    double textScale = 1,
    bool hasDetail = true,
    bool detailOnly = false,
  }) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  key: _boundsKey,
                  width: width,
                  height: 700,
                  child: InboxSplitView(
                    hasDetail: hasDetail,
                    detailOnly: detailOnly,
                    list: _PaneProbe(
                      key: _listKey,
                      label: 'list',
                      onAction: () => listActions++,
                    ),
                    detailBuilder: (showBack) => _PaneProbe(
                      key: _detailKey,
                      label: 'detail',
                      showBack: showBack,
                      onAction: () => detailActions++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<_Fixture> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
  final fixture = _Fixture();
  await fixture.render(tester);
  return fixture;
}

Finder _pane(Key key) => find.byKey(key, skipOffstage: false);
_PaneProbeState _probe(WidgetTester tester, Key key) =>
    tester.state<_PaneProbeState>(_pane(key));
Finder get _divider => find.byKey(const ValueKey('inbox-pane-divider'));

void _inside(WidgetTester tester, Finder target) {
  final bounds = tester.getRect(find.byKey(_boundsKey));
  final rect = tester.getRect(target);
  expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
  expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
  expect(rect.top, greaterThanOrEqualTo(bounds.top - .01));
  expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + .01));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'split breakpoint uses available content width and bounded list width',
    (tester) async {
      final fixture = await _mount(tester);
      for (final sample in [(760.0, 281.2), (900.0, 333.0), (1200.0, 340.0)]) {
        await fixture.render(tester, width: sample.$1);
        expect(_divider, findsOneWidget);
        final list = tester.getRect(find.byKey(_listKey));
        final detail = tester.getRect(find.byKey(_detailKey));
        expect(list.width, closeTo(sample.$2, .01));
        expect(detail.left - list.right, closeTo(1, .01));
        expect(detail.width, closeTo(sample.$1 - sample.$2 - 1, .01));
        expect(find.text('Return to list fixture'), findsNothing);
        _inside(tester, find.byKey(_listKey));
        _inside(tester, find.byKey(_detailKey));
      }
      await fixture.render(tester, width: 759);
      expect(_divider, findsNothing);
      expect(find.byKey(_listKey), findsNothing);
      expect(find.byKey(_detailKey), findsOneWidget);
      expect(find.text('Return to list fixture'), findsOneWidget);
      expect(tester.getSize(find.byKey(_detailKey)).width, 759);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide narrow resizing preserves detail state controller selection and IME',
    (tester) async {
      final fixture = await _mount(tester);
      final detail = _probe(tester, _detailKey);
      final controller = detail.content;
      detail.focus.requestFocus();
      await _frames(tester);
      const editing = TextEditingValue(
        text: 'Draft 正在输入 with selection',
        selection: TextSelection(baseOffset: 6, extentOffset: 10),
        composing: TextRange(start: 6, end: 10),
      );
      controller.value = editing;
      await _frames(tester);
      for (final width in [420.0, 760.0, 1200.0, 500.0, 1100.0]) {
        await fixture.render(tester, width: width);
        expect(_probe(tester, _detailKey), same(detail));
        expect(detail.content, same(controller));
        expect(controller.value, editing);
        expect(detail.focus.hasFocus, isTrue);
        expect(detail.mounted, isTrue);
        _inside(tester, find.byKey(_detailKey));
        expect(tester.takeException(), isNull);
      }
      expect(fixture.listActions, 0);
      expect(fixture.detailActions, 0);
    },
  );

  testWidgets(
    'hidden list has no focus semantics hits or ticking descendants',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(tester);
        final list = _probe(tester, _listKey);
        list.focus.requestFocus();
        await _frames(tester);
        expect(list.focus.hasFocus, isTrue);
        expect(find.bySemanticsLabel('list pane action'), findsOneWidget);
        await fixture.render(tester, width: 420);
        expect(_probe(tester, _listKey), same(list));
        expect(list.focus.hasFocus, isFalse);
        expect(list.focus.canRequestFocus, isFalse);
        list.focus.requestFocus();
        await _frames(tester);
        expect(list.focus.hasFocus, isFalse);
        expect(find.bySemanticsLabel('list pane action'), findsNothing);
        expect(find.bySemanticsLabel('detail pane action'), findsOneWidget);
        expect(_pane(_listKey).hitTestable(), findsNothing);
        expect(
          TickerMode.valuesOf(tester.element(_pane(_listKey))).enabled,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('detail-action')));
        expect(fixture.listActions, 0);
        expect(fixture.detailActions, 1);
        await fixture.render(tester, width: 1100);
        expect(_probe(tester, _listKey), same(list));
        expect(list.focus.canRequestFocus, isTrue);
        expect(find.bySemanticsLabel('list pane action'), findsOneWidget);
        expect(
          TickerMode.valuesOf(tester.element(_pane(_listKey))).enabled,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'no-selection narrow mode hides retained detail from all interaction',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(tester);
        final detail = _probe(tester, _detailKey);
        detail.content.value = const TextEditingValue(
          text: 'Unsent text survives a layout change',
          selection: TextSelection(baseOffset: 2, extentOffset: 8),
        );
        final editing = detail.content.value;
        detail.focus.requestFocus();
        await _frames(tester);
        await fixture.render(tester, width: 420, hasDetail: false);
        expect(_probe(tester, _detailKey), same(detail));
        expect(detail.content.value, editing);
        expect(detail.focus.hasFocus, isFalse);
        expect(detail.focus.canRequestFocus, isFalse);
        detail.focus.requestFocus();
        await _frames(tester);
        expect(detail.focus.hasFocus, isFalse);
        expect(find.bySemanticsLabel('detail pane action'), findsNothing);
        expect(find.bySemanticsLabel('list pane action'), findsOneWidget);
        expect(_pane(_detailKey).hitTestable(), findsNothing);
        expect(
          TickerMode.valuesOf(tester.element(_pane(_detailKey))).enabled,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('list-action')));
        expect(fixture.listActions, 1);
        expect(fixture.detailActions, 0);
        await fixture.render(tester, width: 420, hasDetail: true);
        expect(_probe(tester, _detailKey), same(detail));
        expect(detail.content.value, editing);
        expect(find.bySemanticsLabel('detail pane action'), findsOneWidget);
        expect(detail.focus.canRequestFocus, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'wide no-selection keeps both panes without inventing a selection',
    (tester) async {
      final fixture = await _mount(tester);
      await fixture.render(tester, hasDetail: false);
      expect(find.byKey(_listKey), findsOneWidget);
      expect(find.byKey(_detailKey), findsOneWidget);
      expect(find.text('Return to list fixture'), findsNothing);
      expect(fixture.listActions, 0);
      expect(fixture.detailActions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standalone detail-only mode never exposes the list or split back',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(tester);
        final detail = _probe(tester, _detailKey);
        final controller = detail.content;
        controller.text = 'Standalone draft';
        for (final width in [1200.0, 420.0]) {
          await fixture.render(tester, width: width, detailOnly: true);
          expect(_probe(tester, _detailKey), same(detail));
          expect(detail.content, same(controller));
          expect(controller.text, 'Standalone draft');
          expect(_divider, findsNothing);
          expect(find.byKey(_listKey), findsNothing);
          expect(find.bySemanticsLabel('list pane action'), findsNothing);
          expect(find.text('Return to list fixture'), findsNothing);
          expect(tester.getSize(find.byKey(_detailKey)).width, width);
          _inside(tester, find.byKey(_detailKey));
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'double-size text raises split threshold without shrinking typography',
    (tester) async {
      final fixture = await _mount(tester);
      final detail = _probe(tester, _detailKey);
      for (final sample in [
        (360.0, false),
        (1100.0, false),
        (1120.0, false),
        (1121.0, true),
        (1400.0, true),
      ]) {
        await fixture.render(tester, width: sample.$1, textScale: 2);
        expect(_probe(tester, _detailKey), same(detail));
        expect(_divider, sample.$2 ? findsOneWidget : findsNothing);
        final text = find.byKey(const ValueKey('detail-text'));
        expect(MediaQuery.textScalerOf(tester.element(text)).scale(14), 28);
        _inside(tester, find.byKey(_detailKey));
        _inside(tester, text);
        if (sample.$2) {
          _inside(tester, find.byKey(_listKey));
          expect(
            tester.getSize(find.byKey(_detailKey)).width,
            greaterThanOrEqualTo(780),
          );
        } else {
          expect(find.byKey(_listKey), findsNothing);
          expect(find.text('Return to list fixture'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
}
