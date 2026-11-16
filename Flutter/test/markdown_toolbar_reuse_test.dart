import 'dart:ui' show SemanticsAction, Tristate;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';

const _toolbarKey = ValueKey('reused-markdown-toolbar');
const _trailingKey = ValueKey('live-toolbar-trailing');

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool enabled = true;
  Brightness brightness = Brightness.light;
  double textScale = 1;
  bool reduceTransparency = false;
  ValueChanged<MarkdownCommand> onCommand = (_) {};
  Widget? trailing;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    // A parent update replaces the actual callback given to MarkdownToolbar.
    // It must not be hidden behind a permanently live harness closure.
    final callback = onCommand;
    return CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: GlassAccessibilityScope(
            reduceTransparency: reduceTransparency,
            child: GlassAdaptiveScope(
              // Exercise the real controls without a GPU shader dependency.
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: CupertinoPageScaffold(
                child: Center(
                  child: SizedBox(
                    width: 440,
                    child: MarkdownToolbar(
                      key: _toolbarKey,
                      enabled: enabled,
                      onCommand: callback,
                      trailing: trailing,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Finder _tool(MarkdownCommand command) => find.byWidgetPredicate(
  (widget) => widget is MarkdownToolButton && widget.command == command,
);

List<MarkdownToolButton> _tools(WidgetTester tester) => [
  for (final command in MarkdownCommand.values)
    tester.widget<MarkdownToolButton>(_tool(command)),
];

List<Widget> _groups(WidgetTester tester) {
  final wrap = tester.widget<Wrap>(
    find
        .descendant(of: find.byKey(_toolbarKey), matching: find.byType(Wrap))
        .first,
  );
  // The direct shelf children are the four always-visible command groups and
  // optionally one caller-owned trailing widget. Avoid private class names.
  return wrap.children.take(4).toList();
}

Finder _surfaces() => find.descendant(
  of: find.byKey(_toolbarKey),
  matching: find.byType(GlassContainer),
);

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void _expectSameWidgets<T extends Widget>(List<T> actual, List<T> original) {
  expect(actual, hasLength(original.length));
  for (var index = 0; index < actual.length; index++) {
    expect(actual[index], same(original[index]), reason: 'child $index');
  }
}

Widget _trailing(String label, VoidCallback onTap) => GestureDetector(
  key: _trailingKey,
  onTap: onTap,
  child: Padding(
    padding: const EdgeInsets.all(4),
    child: Text(label, style: const TextStyle(fontSize: 14)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'same-enabled updates reuse all command widgets and latest callbacks',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await _frames(tester);
      final host = key.currentState!;
      final originalGroups = _groups(tester);
      final originalTools = _tools(tester);
      final originalToolbar = tester.widget<MarkdownToolbar>(
        find.byKey(_toolbarKey),
      );
      final originalState = tester.state(find.byKey(_toolbarKey));
      final old = <MarkdownCommand>[];
      final current = <MarkdownCommand>[];
      var oldTrailingTaps = 0;
      var currentTrailingTaps = 0;

      host.update(() {
        host.onCommand = old.add;
        host.trailing = _trailing('old trailing', () => oldTrailingTaps++);
      });
      await _frames(tester);
      expect(
        tester.widget<MarkdownToolbar>(find.byKey(_toolbarKey)),
        isNot(same(originalToolbar)),
      );
      expect(tester.state(find.byKey(_toolbarKey)), same(originalState));
      _expectSameWidgets(_groups(tester), originalGroups);
      _expectSameWidgets(_tools(tester), originalTools);
      originalTools.first.onTap!();
      expect(old, [MarkdownCommand.values.first]);
      await tester.tap(find.byKey(_trailingKey));
      expect(oldTrailingTaps, 1);

      host.update(() {
        host.onCommand = current.add;
        host.trailing = _trailing(
          'current trailing',
          () => currentTrailingTaps++,
        );
      });
      await _frames(tester);
      _expectSameWidgets(_groups(tester), originalGroups);
      _expectSameWidgets(_tools(tester), originalTools);
      expect(find.text('old trailing'), findsNothing);
      expect(find.text('current trailing'), findsOneWidget);
      // The retained closures must dispatch every command through the new
      // onCommand, not through the callback used to construct the cached groups.
      for (final tool in originalTools) {
        tool.onTap!();
        expect(_tool(tool.command).hitTestable(), findsOneWidget);
      }
      expect(current, MarkdownCommand.values);
      expect(old, [MarkdownCommand.values.first]);
      await tester.tap(find.byKey(_trailingKey));
      expect(oldTrailingTaps, 1);
      expect(currentTrailingTaps, 1);

      host.update(() => host.trailing = null);
      await _frames(tester);
      _expectSameWidgets(_groups(tester), originalGroups);
      _expectSameWidgets(_tools(tester), originalTools);
      expect(find.byKey(_trailingKey), findsNothing);
      expect(find.text('更多'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'enabled changes invalidate actions and semantics without remounting glass',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key));
        await _frames(tester);
        final host = key.currentState!;
        final commands = <MarkdownCommand>[];
        host.update(() => host.onCommand = commands.add);
        await _frames(tester);
        final originalTools = _tools(tester);
        final oldCallbacks = [for (final tool in originalTools) tool.onTap!];
        final boldGlass = find.descendant(
          of: _tool(MarkdownCommand.bold),
          matching: find.byType(GlassButton),
        );
        final glassState = tester.state(boldGlass);
        final label = tester
            .widget<Semantics>(
              find.descendant(
                of: _tool(MarkdownCommand.bold),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics &&
                      widget.properties.label == '粗体，将选中文字加粗',
                ),
              ),
            )
            .properties
            .label!;
        var data = tester
            .getSemantics(find.bySemanticsLabel(label))
            .getSemanticsData();
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.hasAction(SemanticsAction.tap), isTrue);

        host.update(() => host.enabled = false);
        await _frames(tester);
        for (final tool in _tools(tester)) {
          expect(tool.onTap, isNull);
        }
        for (final callback in oldCallbacks) {
          callback();
        }
        expect(commands, isEmpty);
        expect(tester.state(boldGlass), same(glassState));
        data = tester
            .getSemantics(find.bySemanticsLabel(label))
            .getSemanticsData();
        expect(data.flagsCollection.isEnabled, Tristate.isFalse);
        expect(data.hasAction(SemanticsAction.tap), isFalse);
        expect(tester.widget<GlassButton>(boldGlass).enabled, isFalse);

        final disabledGroups = _groups(tester);
        final disabledTools = _tools(tester);
        final latest = <MarkdownCommand>[];
        host.update(() {
          host.onCommand = latest.add;
          host.trailing = const Text('disabled parent refresh');
        });
        await _frames(tester);
        _expectSameWidgets(_groups(tester), disabledGroups);
        _expectSameWidgets(_tools(tester), disabledTools);
        for (final callback in oldCallbacks) {
          callback();
        }
        expect(latest, isEmpty);

        host.update(() => host.enabled = true);
        await _frames(tester);
        expect(tester.state(boldGlass), same(glassState));
        expect(tester.widget<GlassButton>(boldGlass).enabled, isTrue);
        data = tester
            .getSemantics(find.bySemanticsLabel(label))
            .getSemanticsData();
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        await tester.tap(_tool(MarkdownCommand.bold));
        expect(latest, [MarkdownCommand.bold]);
        expect(commands, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        for (final callback in oldCallbacks) {
          callback();
        }
        expect(latest, [MarkdownCommand.bold]);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'cached groups still follow theme, text scale and transparency preferences',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await _frames(tester);
      final host = key.currentState!;
      host.update(
        () => host.trailing = const Text(
          'Scaled trailing',
          key: _trailingKey,
          style: TextStyle(fontSize: 14, height: 1),
        ),
      );
      await _frames(tester);
      final originalGroups = _groups(tester);
      final originalTools = _tools(tester);
      final lightSurfaces = tester
          .widgetList<GlassContainer>(_surfaces())
          .toList();
      expect(lightSurfaces, hasLength(4));
      final lightGlassColor = lightSurfaces.first.settings!.glassColor;
      final boldIcon = find.descendant(
        of: _tool(MarkdownCommand.bold),
        matching: find.byType(Icon),
      );
      final lightInk = tester.widget<Icon>(boldIcon).color;
      final originalTrailingHeight = tester
          .getSize(find.byKey(_trailingKey))
          .height;

      host.update(() {
        host.brightness = Brightness.dark;
        host.textScale = 2;
      });
      await _frames(tester);
      _expectSameWidgets(_groups(tester), originalGroups);
      _expectSameWidgets(_tools(tester), originalTools);
      final darkSurfaces = tester
          .widgetList<GlassContainer>(_surfaces())
          .toList();
      expect(darkSurfaces, hasLength(4));
      expect(darkSurfaces.first.settings!.glassColor, isNot(lightGlassColor));
      expect(tester.widget<Icon>(boldIcon).color, isNot(lightInk));
      expect(
        MediaQuery.textScalerOf(tester.element(_tool(MarkdownCommand.bold)))
            .scale(14),
        28,
      );
      expect(
        tester.getSize(find.byKey(_trailingKey)).height,
        greaterThan(originalTrailingHeight),
      );
      for (final tool in _tools(tester)) {
        expect(_tool(tool.command).hitTestable(), findsOneWidget);
      }

      host.update(() => host.reduceTransparency = true);
      await _frames(tester);
      _expectSameWidgets(_groups(tester), originalGroups);
      _expectSameWidgets(_tools(tester), originalTools);
      for (final surface in tester.widgetList<GlassContainer>(_surfaces())) {
        expect(surface.settings!.glassColor.a, 1);
        expect(surface.quality, GlassQuality.standard);
      }
      // Tool quality and interaction are unchanged by the reuse optimization.
      for (final button in tester.widgetList<GlassButton>(
        find.descendant(
          of: find.byKey(_toolbarKey),
          matching: find.byType(GlassButton),
        ),
      )) {
        expect(button.quality, GlassQuality.premium);
        expect(button.style, GlassButtonStyle.transparent);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
