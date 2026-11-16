import 'dart:ui' show PointerDeviceKind;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as material;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/document_history.dart';
import 'package:seekdesk_flutter/widgets/desk_material_scope.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';

const _labels = ['撤销 ⌘Z', '重做 ⇧⌘Z', 'Markdown 帮助'];
const _bodyKey = ValueKey('controls-theme-body');
const _trailingKey = ValueKey('controls-theme-trailing');
const _statusText =
    '上一次发布结果尚未确认，请先检查帖子是否已经发布。当前草稿仍保存在本机，'
    '确认后再决定是否重试；完整状态需要保留在提示中。';

class _Harness extends StatefulWidget {
  const _Harness({
    this.statusOnly = false,
    this.sdkBaseline = false,
    super.key,
  });
  final bool statusOnly, sdkBaseline;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = TextEditingController.fromValue(
    const TextEditingValue(
      text: 'original',
      selection: TextSelection.collapsed(offset: 8),
    ),
  );
  final bodyFocus = FocusNode();
  late final history = DocumentHistory(controller: controller);
  Brightness brightness = Brightness.light;
  Color primary = const Color(0xff256593);
  material.ThemeData? materialTheme, expectedTheme;
  bool enabled = true;
  int mode = 0, revision = 0;
  double textScale = 1;
  final modeChanges = <int>[];
  final rawModeSelections = <int>[];

  void update(VoidCallback change) => setState(change);

  void selectMode(int value) {
    rawModeSelections.add(value);
    // ComposerScreen and InlineEditScreen both reject their current mode
    // synchronously, even before the selectedIndex widget is rebuilt.
    if (mode == value) return;
    update(() {
      modeChanges.add(value);
      mode = value;
    });
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
    theme: CupertinoThemeData(brightness: brightness, primaryColor: primary),
    home: Builder(
      builder: (context) {
        final content = Builder(
          builder: (context) {
            // Omit the oracle in identity tests: repeated SDK fallbacks would
            // themselves evict entries from ThemeData.localize's small cache.
            expectedTheme = widget.sdkBaseline
                ? material.Theme.of(context)
                : null;
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: GlassAdaptiveScope(
                minQuality: GlassQuality.minimal,
                maxQuality: GlassQuality.minimal,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: widget.statusOnly
                      ? Align(
                          alignment: Alignment.bottomRight,
                          child: const SizedBox(
                            width: 180,
                            child: MarkdownStatus(_statusText),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MarkdownEditorControls(
                              mode: mode,
                              onModeChanged: selectMode,
                              history: history,
                              enabled: enabled,
                              trailing: Text(
                                'trailing $revision',
                                key: _trailingKey,
                              ),
                            ),
                            const SizedBox(height: 20),
                            CupertinoTextField(
                              key: _bodyKey,
                              controller: controller,
                              focusNode: bodyFocus,
                            ),
                          ],
                        ),
                ),
              ),
            );
          },
        );
        if (materialTheme case final theme?) {
          return material.Theme(data: theme, child: content);
        }
        return content;
      },
    ),
  );

  @override
  void dispose() {
    history.dispose();
    controller.dispose();
    bodyFocus.dispose();
    super.dispose();
  }
}

Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);

Finder _tooltip(String label) =>
    find.descendant(of: _icon(label), matching: find.byType(material.Tooltip));

List<material.ThemeData> _themes(WidgetTester tester) => [
  for (final label in _labels)
    material.Theme.of(tester.element(_tooltip(label))),
];

void _expectShared(WidgetTester tester, material.ThemeData expected) {
  for (final theme in _themes(tester)) {
    expect(theme, same(expected));
  }
}

void _expectEnabled(WidgetTester tester, List<bool> enabled) {
  for (var index = 0; index < _labels.length; index++) {
    expect(
      tester.widget<DeskIcon>(_icon(_labels[index])).onTap != null,
      enabled[index],
      reason: _labels[index],
    );
  }
}

void _focusIcon(WidgetTester tester, String label) {
  final glyph = find.descendant(of: _icon(label), matching: find.byType(Icon));
  Focus.of(tester.element(glyph)).requestFocus();
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

TextEditingValue _value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('only the three history/help tooltips share a retained theme', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    final host = key.currentState!;
    final theme = _themes(tester).first;
    _expectShared(tester, theme);
    for (final label in _labels) {
      expect(
        find.ancestor(
          of: _tooltip(label),
          matching: find.byType(DeskMaterialScope),
        ),
        findsOneWidget,
      );
    }
    for (final sibling in [
      find.byType(GlassSegmentedControl),
      find.byKey(_trailingKey),
    ]) {
      expect(
        find.ancestor(of: sibling, matching: find.byType(DeskMaterialScope)),
        findsNothing,
      );
    }
    final elements = [
      for (final label in _labels) tester.element(_tooltip(label)),
    ];
    for (var update = 1; update <= 3; update++) {
      host.update(() => host.revision = update);
      await tester.pump();
      expect(find.text('trailing $update'), findsOneWidget);
      _expectShared(tester, theme);
      for (var index = 0; index < _labels.length; index++) {
        expect(tester.element(_tooltip(_labels[index])), same(elements[index]));
      }
    }
    // This notification rebuilds ListenableBuilder without its controls parent.
    host.history.apply(_value('edited'));
    await tester.pump();
    _expectEnabled(tester, [true, false, true]);
    _expectShared(tester, theme);
    host.history.undo();
    await tester.pump();
    _expectEnabled(tester, [false, true, true]);
    _expectShared(tester, theme);
    host.update(() => host.textScale = 1.5);
    await tester.pump();
    _expectShared(tester, theme);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'history notifications, disabled, preview and composition keep their guards',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      final host = key.currentState!;
      _expectEnabled(tester, [false, false, true]);
      host.history.apply(_value('edited'));
      await tester.pump();
      _expectEnabled(tester, [true, false, true]);
      await tester.tap(_icon(_labels[0]));
      await _frames(tester);
      expect(host.controller.text, 'original');
      _expectEnabled(tester, [false, true, true]);
      await tester.tap(_icon(_labels[1]));
      await _frames(tester);
      expect(host.controller.text, 'edited');

      host.update(() => host.enabled = false);
      await tester.pump();
      _expectEnabled(tester, [false, false, false]);
      await tester.tap(_icon(_labels[0]), warnIfMissed: false);
      await tester.tap(_icon(_labels[2]), warnIfMissed: false);
      await _frames(tester);
      expect(host.controller.text, 'edited');
      expect(find.byType(DeskDialog), findsNothing);

      host.update(() {
        host.enabled = true;
        host.mode = 2;
      });
      await tester.pump();
      expect(host.history.canUndo, isTrue);
      _expectEnabled(tester, [false, false, true]);
      await tester.tap(_icon(_labels[0]), warnIfMissed: false);
      await tester.tap(find.text('对照'));
      await _frames(tester);
      expect(host.modeChanges, [1]);
      expect(host.rawModeSelections, [1]);
      _expectEnabled(tester, [true, false, true]);
      expect(host.controller.text, 'edited');

      await tester.showKeyboard(find.byKey(_bodyKey));
      const composing = TextEditingValue(
        text: 'edited 拼',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 7, end: 8),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      _expectEnabled(tester, [false, false, false]);
      await tester.tap(_icon(_labels[2]), warnIfMissed: false);
      await tester.pump();
      expect(host.controller.value, composing);
      expect(host.bodyFocus.hasFocus, isTrue);
      expect(find.byType(DeskDialog), findsNothing);
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      _expectEnabled(tester, [true, false, true]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'control themes follow Cupertino changes and an inherited Material override',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, sdkBaseline: true));
      final host = key.currentState!;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        host.update(() {
          host.brightness = brightness;
          host.primary = const Color(0xff9b4f36);
        });
        await _frames(tester);
        final themes = _themes(tester);
        _expectShared(tester, themes.first);
        expect(themes.first, host.expectedTheme);
        expect(themes.first.brightness, brightness);
        expect(themes.first.colorScheme.primary, host.primary);
      }
      for (final color in [const Color(0xff287744), const Color(0xff804e91)]) {
        host.update(
          () => host.materialTheme = material.ThemeData(
            colorScheme: material.ColorScheme.fromSeed(
              seedColor: color,
              primary: color,
            ),
            tooltipTheme: const material.TooltipThemeData(
              textStyle: TextStyle(fontSize: 18, color: Color(0xfffbefcf)),
            ),
          ),
        );
        await _frames(tester);
        final theme = _themes(tester).first;
        _expectShared(tester, theme);
        expect(theme, host.expectedTheme);
        expect(theme.colorScheme.primary, color);
        expect(theme.tooltipTheme.textStyle!.fontSize, 18);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pointer history edits preserve body focus and keyboard help retains its route guard',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      final host = key.currentState!;
      host.history.apply(_value('edited'));
      await tester.showKeyboard(find.byKey(_bodyKey));
      await tester.pump();
      final fieldElement = tester.element(find.byKey(_bodyKey));
      await tester.tap(_icon(_labels[0]));
      await _frames(tester);
      expect(host.controller.text, 'original');
      expect(host.bodyFocus.hasFocus, isTrue);
      expect(tester.element(find.byKey(_bodyKey)), same(fieldElement));

      _focusIcon(tester, _labels[1]);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(host.controller.text, 'edited');
      final beforeHelp = host.controller.value;
      final help = tester.widget<DeskIcon>(_icon(_labels[2])).onTap!;
      _focusIcon(tester, _labels[2]);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      // Mount the route before advancing its spring. A single delayed pump
      // mounts it at that timestamp and still measures the initial 1.3 scale.
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.text('Markdown 快速帮助'), findsOneWidget);
      expect(find.textContaining('⌘B 粗体'), findsOneWidget);
      expect(host.controller.value, beforeHelp);
      // A retained callback from the now-covered editor must not stack dialogs.
      help();
      await tester.pump();
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(DeskDialog),
          matching: find.byType(DeskMaterialScope),
        ),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(DeskDialogAction, '知道了'));
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byType(DeskDialog), findsNothing);
      expect(host.controller.value, beforeHelp);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'DeskIcon tooltip delay and single button semantics survive the local scope',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key));
        await _frames(tester);
        for (final label in _labels) {
          final tooltip = tester.widget<material.Tooltip>(_tooltip(label));
          expect(tooltip.message, label);
          expect(tooltip.waitDuration, const Duration(milliseconds: 450));
          expect(tooltip.excludeFromSemantics, isTrue);
          final node = find.bySemanticsLabel(label);
          expect(node, findsOneWidget);
          final data = tester.getSemantics(node).getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.tooltip, isEmpty);
        }
        final bubble = find.text(_labels[2], findRichText: true);
        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(_icon(_labels[2])));
        await tester.pump(const Duration(milliseconds: 449));
        expect(bubble, findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 180));
        expect(bubble, findsOneWidget);
        final decoration = find
            .ancestor(of: bubble, matching: find.byType(DecoratedBox))
            .first;
        final light = tester.widget<DecoratedBox>(decoration).decoration;
        key.currentState!.update(
          () => key.currentState!.brightness = Brightness.dark,
        );
        await _frames(tester);
        expect(bubble, findsOneWidget);
        expect(
          tester.widget<DecoratedBox>(decoration).decoration,
          isNot(light),
        );
        await mouse.moveTo(const Offset(1, 1));
        await tester.pump(const Duration(milliseconds: 400));
        // Expiring the exit timer starts the reverse animation at this frame;
        // advance another frame interval to finish removing the overlay.
        await tester.pump(const Duration(milliseconds: 180));
        expect(bubble, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'an independently scoped status follows SDK themes and retains ellipsis plus full tooltip',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(
          _Harness(key: key, statusOnly: true, sdkBaseline: true),
        );
        final host = key.currentState!;
        final status = find.byType(MarkdownStatus);
        final tooltipFinder = find.descendant(
          of: status,
          matching: find.byType(material.Tooltip),
        );
        for (final brightness in [Brightness.light, Brightness.dark]) {
          host.update(() {
            host.brightness = brightness;
            host.textScale = brightness == Brightness.light ? 1 : 1.75;
          });
          await _frames(tester);
          expect(
            material.Theme.of(tester.element(tooltipFinder)),
            host.expectedTheme,
          );
          final text = tester.widget<Text>(
            find.descendant(of: status, matching: find.byType(Text)),
          );
          expect(text.data, _statusText);
          expect(text.maxLines, 2);
          expect(text.overflow, TextOverflow.ellipsis);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: status, matching: find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isTrue);
          expect(tester.getSize(status).width, lessThanOrEqualTo(180));
          final label = find.bySemanticsLabel(_statusText);
          expect(label, findsOneWidget);
          expect(
            tester.getSemantics(label).getSemanticsData().tooltip,
            isEmpty,
          );
        }
        host.update(
          () => host.materialTheme = material.ThemeData(
            colorScheme: material.ColorScheme.fromSeed(
              seedColor: const Color(0xff41795e),
            ),
            tooltipTheme: const material.TooltipThemeData(
              waitDuration: Duration(milliseconds: 80),
            ),
          ),
        );
        await _frames(tester);
        expect(
          material.Theme.of(tester.element(tooltipFinder)),
          host.expectedTheme,
        );
        expect(
          tester.widget<material.Tooltip>(tooltipFinder).message,
          _statusText,
        );
        expect(
          tester.widget<material.Tooltip>(tooltipFinder).excludeFromSemantics,
          isTrue,
        );
        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(status));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 180));
        final fullTexts = find.text(_statusText, findRichText: true);
        expect(fullTexts, findsNWidgets(2));
        // The status uses Text(data); the SDK tooltip uses Text.rich. Select its
        // actual overlay text without depending on the traversal order of the two
        // matching RichText descendants.
        final popup = find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.textSpan?.toPlainText() == _statusText,
        );
        expect(popup, findsOneWidget);
        final bounds = tester.getRect(popup);
        final surface = tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(surface.width));
        expect(bounds.bottom, lessThanOrEqualTo(surface.height));
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    },
  );
}
