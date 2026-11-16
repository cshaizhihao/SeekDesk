// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/widgets/desk_interaction.dart';
import 'package:seekdesk_flutter/widgets/desk_page_transition.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

void main() {
  testWidgets('edge light preserves full-width button hit targets', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 480,
            child: DeskButton('Retry', onTap: () => taps++),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DeskButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('glass shadow does not darken the transparent panel interior', (
    tester,
  ) async {
    const key = ValueKey('glass-shadow-sample');
    await tester.pumpWidget(
      const CupertinoApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: CupertinoColors.white,
              child: SizedBox(
                width: 240,
                height: 120,
                child: DeskGlassPanel(child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final rgba = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    });
    final pixel = (60 * 240 + 120) * 4;
    expect(rgba!.getUint8(pixel), greaterThan(240));
    expect(rgba.getUint8(pixel + 1), greaterThan(240));
    expect(rgba.getUint8(pixel + 2), greaterThan(240));
  });
  testWidgets(
    'page changes animate without retaining old content or scaling text',
    (tester) async {
      var page = 0;
      late StateSetter update;
      var reduced = false;
      await tester.pumpWidget(
        CupertinoApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced, devicePixelRatio: 2),
                child: DeskPageTransition(
                  identity: page,
                  child: Text('Page $page'),
                ),
              );
            },
          ),
        ),
      );
      update(() => page = 1);
      await tester.pump();
      expect(find.text('Page 0'), findsNothing);
      expect(find.text('Page 1'), findsOneWidget);
      final transforms = find.descendant(
        of: find.byType(DeskPageTransition),
        matching: find.byType(Transform),
      );
      Matrix4 matrix() => tester.widget<Transform>(transforms).transform;
      expect(matrix().storage[12], 12);
      await tester.pump(const Duration(milliseconds: 70));
      final dx = matrix().storage[12];
      expect(dx, greaterThan(0));
      expect(dx, lessThan(12));
      expect(dx * 2, (dx * 2).roundToDouble());
      expect(matrix().storage[0], 1);
      expect(matrix().storage[5], 1);
      update(() {});
      await tester.pump();
      expect(matrix().storage[12], dx);
      update(() => reduced = true);
      await tester.pump();
      expect(matrix().storage[12], 0);
      update(() => page = 2);
      await tester.pump();
      expect(matrix().storage[12], 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hover and press feedback do not resize labels or duplicate activation',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        CupertinoApp(
          home: Center(
            child: DeskInteraction(
              color: const Color(0xff4263df),
              child: CupertinoButton(
                onPressed: () => taps++,
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      final original = tester.getRect(find.text('Open'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Open')));
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getRect(find.text('Open')), original);
      await mouse.down(tester.getCenter(find.text('Open')));
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getRect(find.text('Open')), original);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'mounted panel and card use their actual material at $brightness',
      (tester) async {
        await tester.pumpWidget(
          CupertinoApp(
            theme: CupertinoThemeData(brightness: brightness),
            home: const Column(
              children: [
                DeskGlassPanel(
                  level: GlassLevel.background,
                  child: Text('Sidebar'),
                ),
                DeskGlassPanel(
                  level: GlassLevel.panel,
                  child: Text('Settings'),
                ),
                DeskGlassPanel(level: GlassLevel.card, child: Text('Card')),
              ],
            ),
          ),
        );
        final surfaces = tester
            .widgetList<GlassContainer>(find.byType(GlassContainer))
            .toList();
        expect(surfaces, hasLength(3));
        expect(surfaces[0].settings!.thickness, 18);
        expect(surfaces[1].settings!.thickness, 20);
        expect(surfaces[2].settings!.thickness, 21);
        expect(surfaces[0].settings!.blur, 0);
        expect(surfaces[1].settings!.blur, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
