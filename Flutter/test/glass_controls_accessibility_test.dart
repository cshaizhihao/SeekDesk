import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

void main() {
  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoPageScaffold(child: Center(child: child)),
      ),
    ),
  );

  testWidgets('a glass action exposes one named actionable semantics node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await mount(tester, DeskButton('查看详情', onTap: () => taps++));
    expect(find.bySemanticsLabel('查看详情'), findsOneWidget);
    final node = tester.getSemantics(find.byType(DeskButton));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // Exercise the accessibility action, not just the pointer gesture.
    tester
        .renderObject(find.byType(DeskButton))
        .owner!
        .semanticsOwner!
        .performAction(node.id, SemanticsAction.tap);
    expect(taps, 1);
    await tester.tap(find.byType(DeskButton));
    expect(taps, 2);
    handle.dispose();
  });

  testWidgets('busy and disabled actions expose no accessibility tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    for (final busy in [false, true]) {
      await mount(
        tester,
        DeskButton('保存', onTap: busy ? () => taps++ : null, busy: busy),
      );
      final data = tester
          .getSemantics(find.byType(DeskButton))
          .getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      await tester.tap(find.byType(DeskButton), warnIfMissed: false);
      expect(taps, 0);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('selection and pending status remain available to VoiceOver', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await mount(tester, DeskButton('仅楼主', selected: true, onTap: () {}));
      var data = tester
          .getSemantics(find.byType(DeskButton))
          .getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      expect(data.label, '仅楼主');
      expect(find.bySemanticsLabel('仅楼主'), findsOneWidget);

      await mount(tester, DeskButton('保存', busy: true, onTap: () {}));
      data = tester.getSemantics(find.byType(DeskButton)).getSemanticsData();
      expect(data.label, '保存');
      expect(data.value, '处理中');
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      handle.dispose();
    }
  });

  testWidgets('list hover respects an explicit Reduce Motion override', (
    tester,
  ) async {
    await mount(
      tester,
      GlassAccessibilityScope(
        reduceMotion: true,
        child: HoverRow(onTap: () {}, child: const Text('最近关闭的帖子')),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('最近关闭的帖子')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    await mouse.removePointer();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('icon controls keep their name and explain it on hover', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await mount(tester, DeskIcon('刷新帖子', CupertinoIcons.refresh, () {}));
    expect(find.bySemanticsLabel('刷新帖子'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(DeskIcon)));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();
    expect(find.text('刷新帖子'), findsOneWidget);
    expect(find.bySemanticsLabel('刷新帖子'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('Tab skips disabled and busy glass actions', (tester) async {
    final activated = <String>[];
    await mount(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DeskButton('第一项', onTap: () => activated.add('first')),
          const DeskButton('不可用', onTap: null),
          DeskButton('处理中', busy: true, onTap: () => activated.add('busy')),
          DeskButton('最后一项', onTap: () => activated.add('last')),
        ],
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, ['first']);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, ['first', 'last']);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
