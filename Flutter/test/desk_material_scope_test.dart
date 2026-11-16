import 'dart:ui' show PointerDeviceKind;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';
import 'package:seekdesk_flutter/widgets/desk_material_scope.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';

class _Ambient {
  _Ambient(BuildContext context)
    : cupertino = CupertinoTheme.of(context),
      icons = IconTheme.of(context),
      text = DefaultTextStyle.of(context).style,
      selection = DefaultSelectionStyle.of(context).selectionColor,
      cursor = DefaultSelectionStyle.of(context).cursorColor,
      mouseCursor = DefaultSelectionStyle.of(context).mouseCursor,
      scale = MediaQuery.textScalerOf(context).scale(14),
      direction = Directionality.of(context);

  final CupertinoThemeData cupertino;
  final IconThemeData icons;
  final TextStyle text;
  final Color? selection, cursor;
  final MouseCursor? mouseCursor;
  final double scale;
  final TextDirection direction;
}

class _Harness extends StatefulWidget {
  const _Harness({this.toolbar = false, this.sdkBaseline = false, super.key});
  final bool toolbar;
  final bool sdkBaseline;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  Brightness? brightness = Brightness.light;
  Brightness platformBrightness = Brightness.light;
  Color primary = const Color(0xff6f3cc3);
  Color contrasting = const Color(0xfff2eefd);
  double textScale = 1;
  bool highContrast = false;
  material.ThemeData? existingMaterial;
  final themes = <int, material.ThemeData>{};
  _Ambient? before, after;
  material.ThemeData? expectedMaterial;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) => MediaQuery(
    // CupertinoApp resolves dynamic theme colors from its parent context.
    // Supply the same environment above the app and below its WidgetsApp.
    data: MediaQueryData.fromView(View.of(context)).copyWith(
      platformBrightness: platformBrightness,
      highContrast: highContrast,
      textScaler: TextScaler.linear(textScale),
    ),
    child: CupertinoApp(
      theme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: primary,
        primaryContrastingColor: contrasting,
      ),
      home: Builder(
        builder: (context) {
          final content = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              platformBrightness: platformBrightness,
              highContrast: highContrast,
              textScaler: TextScaler.linear(textScale),
            ),
            child: IconTheme(
              data: const IconThemeData(color: Color(0xff24865c), size: 21),
              child: const DefaultSelectionStyle(
                cursorColor: Color(0xffbd522a),
                selectionColor: Color(0x667a52c4),
                mouseCursor: SystemMouseCursors.precise,
                child: _PreservedTextScope(),
              ),
            ),
          );
          // The small inherited host supplies the mutable configuration without
          // making the probes depend on implementation-private scope widgets.
          return _HostScope(host: this, child: content);
        },
      ),
    ),
  );
}

class _HostScope extends InheritedWidget {
  const _HostScope({required this.host, required super.child});
  final _HarnessState host;

  @override
  bool updateShouldNotify(_HostScope oldWidget) => true;
}

class _PreservedTextScope extends StatelessWidget {
  const _PreservedTextScope();

  @override
  Widget build(BuildContext context) {
    final host = context.dependOnInheritedWidgetOfExactType<_HostScope>()!.host;
    final child = DefaultTextStyle(
      style: const TextStyle(
        fontSize: 17,
        color: Color(0xff355b7e),
        height: 1.4,
      ),
      child: Builder(
        builder: (context) {
          host.before = _Ambient(context);
          // Use the SDK result in this exact environment as the oracle. Its
          // nullable-brightness fallback is intentionally not a new palette.
          // Identity tests omit this extra fallback, which otherwise fills
          // ThemeData.localize's tiny FIFO cache with unrelated oracle values.
          host.expectedMaterial = host.widget.sdkBaseline
              ? material.Theme.of(context)
              : null;
          return DeskMaterialScope(
            child: Builder(
              builder: (context) {
                host.after = _Ambient(context);
                return Column(
                  children: [
                    for (var index = 0; index < 16; index++)
                      Builder(
                        builder: (context) {
                          host.themes[index] = material.Theme.of(context);
                          return const SizedBox.shrink();
                        },
                      ),
                    if (host.widget.toolbar)
                      Expanded(
                        child: GlassAdaptiveScope(
                          minQuality: GlassQuality.minimal,
                          maxQuality: GlassQuality.minimal,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: SizedBox(
                              width: 410,
                              child: MarkdownToolbar(onCommand: (_) {}),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
    if (host.existingMaterial case final theme?) {
      return material.Theme(data: theme, child: child);
    }
    return child;
  }
}

void _expectShared(_HarnessState host, material.ThemeData expected) {
  expect(host.themes, hasLength(16));
  for (final theme in host.themes.values) {
    expect(theme, same(expected));
  }
}

void _expectAmbientPreserved(_HarnessState host) {
  final before = host.before!, after = host.after!;
  expect(after.cupertino.brightness, before.cupertino.brightness);
  expect(after.cupertino.primaryColor, before.cupertino.primaryColor);
  expect(
    after.cupertino.primaryContrastingColor,
    before.cupertino.primaryContrastingColor,
  );
  expect(
    after.cupertino.scaffoldBackgroundColor,
    before.cupertino.scaffoldBackgroundColor,
  );
  expect(
    after.cupertino.textTheme.textStyle,
    before.cupertino.textTheme.textStyle,
  );
  expect(after.icons, before.icons);
  expect(after.text, before.text);
  expect(after.selection, before.selection);
  expect(after.cursor, before.cursor);
  expect(after.mouseCursor, before.mouseCursor);
  expect(after.scale, before.scale);
  expect(after.direction, before.direction);
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 3; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _tool(MarkdownCommand command) => find.byWidgetPredicate(
  (widget) => widget is MarkdownToolButton && widget.command == command,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'consumers share one material theme across equal-color parent rebuilds',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      final host = key.currentState!;
      final first = host.themes[0]!;
      _expectShared(host, first);
      _expectAmbientPreserved(host);
      for (var index = 0; index < 3; index++) {
        // A newly allocated CupertinoThemeData with the same resolved colors
        // must not recreate the expensive Material fallback per consumer.
        host.update(() {});
        await tester.pump();
        _expectShared(host, first);
        _expectAmbientPreserved(host);
      }
      host.update(() => host.textScale = 1.75);
      await tester.pump();
      _expectShared(host, first);
      expect(host.after!.scale, 24.5);
      _expectAmbientPreserved(host);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resolved brightness and colors match the current SDK fallback', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, sdkBaseline: true));
    final host = key.currentState!;
    expect(host.themes[0], host.expectedMaterial);
    expect(host.themes[0]!.colorScheme.primary, host.primary);
    expect(host.themes[0]!.colorScheme.onPrimary, host.contrasting);
    host.update(() {
      host.primary = const Color(0xff187d95);
      host.contrasting = const Color(0xffffe9bc);
      host.brightness = Brightness.dark;
    });
    await _frames(tester);
    expect(host.themes[0]!.brightness, Brightness.dark);
    expect(host.themes[0]!.colorScheme.primary, host.primary);
    expect(host.themes[0]!.colorScheme.onPrimary, host.contrasting);
    expect(host.themes[0], host.expectedMaterial);
    _expectShared(host, host.themes[0]!);
    _expectAmbientPreserved(host);

    host.update(() {
      host.brightness = null;
      host.platformBrightness = Brightness.light;
    });
    await _frames(tester);
    expect(host.themes[0], host.expectedMaterial);
    host.update(() => host.platformBrightness = Brightness.dark);
    await _frames(tester);
    expect(host.themes[0], host.expectedMaterial);
    _expectShared(host, host.themes[0]!);
    _expectAmbientPreserved(host);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dynamic high-contrast colors resolve before material conversion',
    (tester) async {
      const primary = CupertinoDynamicColor.withBrightnessAndContrast(
        color: Color(0xff2864a1),
        darkColor: Color(0xff81b0dd),
        highContrastColor: Color(0xff153a60),
        darkHighContrastColor: Color(0xffc0defb),
      );
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, sdkBaseline: true));
      final host = key.currentState!;
      for (final (brightness, highContrast, expected) in [
        (Brightness.light, false, primary.color),
        (Brightness.light, true, primary.highContrastColor),
        (Brightness.dark, false, primary.darkColor),
        (Brightness.dark, true, primary.darkHighContrastColor),
      ]) {
        host.update(() {
          host.primary = primary;
          host.brightness = brightness;
          host.platformBrightness = brightness;
          host.highContrast = highContrast;
        });
        await _frames(tester);
        expect(
          host.themes[0]!.colorScheme.primary.toARGB32(),
          expected.toARGB32(),
        );
        expect(host.themes[0], host.expectedMaterial);
        _expectShared(host, host.themes[0]!);
        _expectAmbientPreserved(host);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an existing Material theme keeps precedence and updates', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, sdkBaseline: true));
    final host = key.currentState!;
    for (final (color, platform) in [
      (const Color(0xffd15817), TargetPlatform.macOS),
      (const Color(0xff388643), TargetPlatform.linux),
    ]) {
      host.update(() {
        host.existingMaterial = material.ThemeData(
          platform: platform,
          colorScheme: material.ColorScheme.fromSeed(
            seedColor: color,
            primary: color,
          ),
          tooltipTheme: const material.TooltipThemeData(
            textStyle: TextStyle(fontSize: 19, color: Color(0xffefffac)),
          ),
        );
      });
      await _frames(tester);
      _expectShared(host, host.themes[0]!);
      // Theme.of localizes again inside the scope. Its cached identity can
      // differ from the outer Theme.of while the resulting values stay equal.
      expect(host.themes[0], host.expectedMaterial);
      expect(host.themes[0]!.colorScheme.primary, color);
      expect(host.themes[0]!.platform, platform);
      expect(host.themes[0]!.tooltipTheme.textStyle!.fontSize, 19);
      _expectAmbientPreserved(host);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real format tooltips retain delay, bounds, dismissal and current theme',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await tester.binding.setSurfaceSize(const Size(520, 320));
      try {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key, toolbar: true));
        await _frames(tester);
        final host = key.currentState!;
        final tooltips = tester
            .widgetList<material.Tooltip>(find.byType(material.Tooltip))
            .toList();
        expect(tooltips, hasLength(13));
        for (final tooltip in tooltips) {
          expect(tooltip.waitDuration, const Duration(milliseconds: 350));
          expect(tooltip.excludeFromSemantics, isTrue);
        }
        expect(find.byType(MarkdownToolButton), findsNWidgets(13));
        final target = _tool(MarkdownCommand.divider);
        final tooltip = tester.widget<material.Tooltip>(
          find.descendant(of: target, matching: find.byType(material.Tooltip)),
        );
        final message = tooltip.message!;
        Finder bubble() => find.text(message, findRichText: true);
        Finder decoration() => find
            .ancestor(of: bubble(), matching: find.byType(DecoratedBox))
            .first;

        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 349));
        expect(bubble(), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 180));
        expect(bubble(), findsOneWidget);
        final bounds = tester.getRect(decoration());
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(520));
        expect(bounds.bottom, lessThanOrEqualTo(320));
        final lightDecoration = tester
            .widget<DecoratedBox>(decoration())
            .decoration;
        for (final tool in tester.widgetList<MarkdownToolButton>(
          find.byType(MarkdownToolButton),
        )) {
          final label = find.bySemanticsLabel(
            RegExp('^${RegExp.escape(tool.label)}，'),
          );
          expect(label, findsOneWidget);
          final data = tester.getSemantics(label).getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.tooltip, isEmpty);
        }

        host.update(() => host.brightness = Brightness.dark);
        await _frames(tester);
        expect(bubble(), findsOneWidget);
        expect(
          tester.widget<DecoratedBox>(decoration()).decoration,
          isNot(lightDecoration),
        );
        _expectShared(host, host.themes[0]!);
        await mouse.moveTo(const Offset(1, 1));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 180));
        expect(bubble(), findsNothing);
        await mouse.moveTo(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 200));
        await mouse.moveTo(const Offset(1, 1));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          bubble(),
          findsNothing,
          reason: 'Leaving before the delay cancels the pending tooltip',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
