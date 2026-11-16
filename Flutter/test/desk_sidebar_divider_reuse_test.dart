import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/desk_sidebar_divider.dart';

final _handle = find.byType(DeskSidebarDivider);

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Let the double-click recognizer's minimum-interval timer expire.
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets(
    'default and custom divider labels name the same focusable handle',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final key = GlobalKey<_DividerHarnessState>();
        await tester.pumpWidget(CupertinoApp(home: _DividerHarness(key: key)));
        expect(find.bySemanticsLabel('侧边栏宽度'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focus = tester
            .widget<Focus>(
              find.descendant(of: _handle, matching: find.byType(Focus)),
            )
            .focusNode!;
        expect(focus.debugLabel, '侧边栏宽度');
        expect(focus.hasPrimaryFocus, isTrue);

        key.currentState!.rename('帖子列表宽度');
        await tester.pump();
        expect(find.bySemanticsLabel('侧边栏宽度'), findsNothing);
        expect(find.bySemanticsLabel('帖子列表宽度'), findsOneWidget);
        final currentFocus = tester
            .widget<Focus>(
              find.descendant(of: _handle, matching: find.byType(Focus)),
            )
            .focusNode!;
        expect(currentFocus, same(focus));
        expect(currentFocus.debugLabel, '帖子列表宽度');
        expect(currentFocus.hasPrimaryFocus, isTrue);
        expect(tester.getSize(_handle).width, 9);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'post-list handle honors its larger range in keyboard and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final key = GlobalKey<_DividerHarnessState>();
        await tester.pumpWidget(CupertinoApp(home: _DividerHarness(key: key)));
        final harness = key.currentState!;
        harness.rename('帖子列表宽度');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        for (final key in [
          LogicalKeyboardKey.end,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.home,
          LogicalKeyboardKey.arrowLeft,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pump();
        }
        expect(harness.changes, [620, 240]);
        expect(harness.commits, [620, 240]);
        final node = tester.getSemantics(find.bySemanticsLabel('帖子列表宽度'));
        final data = node.getSemanticsData();
        expect(data.value, '240 点');
        expect(data.increasedValue, '248 点');
        expect(data.hasAction(SemanticsAction.decrease), isFalse);
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'post-list reset invokes its parent once without a resize commit',
    (tester) async {
      final key = GlobalKey<_DividerHarnessState>();
      await tester.pumpWidget(CupertinoApp(home: _DividerHarness(key: key)));
      final harness = key.currentState!;
      harness.rename('帖子列表宽度');
      await tester.pump();
      expect(harness.width, 520);
      await tester.tap(_handle);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(_handle);
      await tester.pump();
      expect(harness.width, 340);
      expect(harness.resets, 1);
      expect(harness.changes, isEmpty);
      expect(harness.commits, isEmpty);
      expect(harness.cancels, 0);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  for (final sample in <(double?, double)>[(null, 8), (24, 24)]) {
    testWidgets(
      '${sample.$1 == null ? 'default' : 'explicit'} adjustment step ${sample.$2} matches keyboard and semantics',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final key = GlobalKey<_DividerHarnessState>();
          await tester.pumpWidget(
            CupertinoApp(
              home: _DividerHarness(key: key, adjustmentStep: sample.$1),
            ),
          );
          final harness = key.currentState!;
          final step = sample.$2;
          expect(
            tester.widget<DeskSidebarDivider>(_handle).adjustmentStep,
            step,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(harness.width, 520 + step);
          expect(harness.commits, isEmpty);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(harness.width, 520 + step * 2);
          expect(harness.commits, isEmpty);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(harness.commits, [520 + step * 2]);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(harness.width, 520 + step);

          final label = find.bySemanticsLabel('侧边栏宽度');
          final node = tester.getSemantics(label);
          final data = node.getSemanticsData();
          expect(data.value, '${(520 + step).round()} 点');
          expect(data.increasedValue, '${(520 + step * 2).round()} 点');
          expect(data.decreasedValue, '520 点');
          tester
              .renderObject(_handle)
              .owner!
              .semanticsOwner!
              .performAction(node.id, SemanticsAction.increase);
          await tester.pump();
          expect(harness.width, 520 + step * 2);
          final updatedNode = tester.getSemantics(label);
          tester
              .renderObject(_handle)
              .owner!
              .semanticsOwner!
              .performAction(updatedNode.id, SemanticsAction.decrease);
          await tester.pump();
          expect(harness.width, 520 + step);
          expect(harness.changes, [
            520 + step,
            520 + step * 2,
            520 + step,
            520 + step * 2,
            520 + step,
          ]);
          expect(harness.commits, [
            520 + step * 2,
            520 + step,
            520 + step * 2,
            520 + step,
          ]);
          expect(tester.takeException(), isNull);
        } finally {
          await _unmount(tester);
          semantics.dispose();
        }
      },
    );
  }
}

class _DividerHarness extends StatefulWidget {
  const _DividerHarness({this.adjustmentStep, super.key});

  final double? adjustmentStep;

  @override
  State<_DividerHarness> createState() => _DividerHarnessState();
}

class _DividerHarnessState extends State<_DividerHarness> {
  String? label;
  double width = 520;
  final changes = <double>[];
  final commits = <double>[];
  int resets = 0;
  int cancels = 0;

  void rename(String value) => setState(() => label = value);

  @override
  Widget build(BuildContext context) {
    void changed(double value) {
      changes.add(value);
      setState(() => width = value);
    }

    void reset() {
      resets++;
      setState(() => width = 340);
    }

    final divider = widget.adjustmentStep != null
        ? DeskSidebarDivider(
            width: width,
            minimum: 240,
            maximum: 620,
            label: label ?? '侧边栏宽度',
            adjustmentStep: widget.adjustmentStep!,
            onChanged: changed,
            onChangeEnd: commits.add,
            onCancel: () => cancels++,
            onReset: reset,
          )
        : label == null
        ? DeskSidebarDivider(
            width: width,
            minimum: 240,
            maximum: 620,
            onChanged: changed,
            onChangeEnd: commits.add,
            onCancel: () => cancels++,
            onReset: reset,
          )
        : DeskSidebarDivider(
            width: width,
            minimum: 240,
            maximum: 620,
            label: label!,
            onChanged: changed,
            onChangeEnd: commits.add,
            onCancel: () => cancels++,
            onReset: reset,
          );
    return CupertinoPageScaffold(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 300,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: width),
              divider,
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }
}
