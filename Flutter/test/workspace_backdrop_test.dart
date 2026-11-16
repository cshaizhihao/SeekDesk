// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/desk_theme.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_backdrop.dart';

Widget _host({
  required Widget child,
  Brightness brightness = Brightness.light,
  bool enabled = true,
  DeskThemeFamily family = DeskThemeFamily.classic,
}) => CupertinoApp(
  theme: CupertinoThemeData(brightness: brightness),
  builder: (_, child) => DeskThemeScope(family: family, child: child!),
  home: Center(
    child: SizedBox(
      width: 440,
      height: 260,
      child: ReaderBackdrop(enabled: enabled, child: child),
    ),
  ),
);

Finder get _backgroundImage => find.descendant(
  of: find.byType(ReaderBackdrop),
  matching: find.byType(Image),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final dark in [false, true]) {
    test('window canvas uses one static fill without blur, dark=$dark', () {
      const size = Size(1024, 768);
      final canvas = TestRecordingCanvas();
      final backdrop = DeskBackdrop(dark: dark);
      backdrop.paint(canvas, size);
      expect(canvas.invocations, hasLength(1));
      final call = canvas.invocations.single.invocation;
      expect(call.memberName, #drawRect);
      expect(call.positionalArguments.first, Offset.zero & size);
      final paint = call.positionalArguments[1] as Paint;
      expect(paint.color.a, 1);
      expect(paint.shader, isNotNull);
      expect(paint.imageFilter, isNull);
      expect(paint.maskFilter, isNull);
      expect(backdrop.shouldRepaint(DeskBackdrop(dark: dark)), isFalse);
      expect(backdrop.shouldRepaint(DeskBackdrop(dark: !dark)), isTrue);
    });
  }

  testWidgets(
    'enabled reader uses the original unfiltered day and night assets',
    (tester) async {
      for (final mode in [
        (Brightness.light, ReaderBackdrop.lightAsset, 1283800),
        (Brightness.dark, ReaderBackdrop.darkAsset, 1423044),
      ]) {
        await tester.pumpWidget(
          _host(brightness: mode.$1, child: const SizedBox()),
        );
        final image = tester.widget<Image>(_backgroundImage);
        expect((image.image as AssetImage).assetName, mode.$2);
        expect(image.fit, BoxFit.cover);
        expect(image.alignment, Alignment.center);
        expect(image.color, isNull);
        expect(image.colorBlendMode, isNull);
        expect(image.opacity, isNull);
        final background = find
            .ancestor(
              of: _backgroundImage,
              matching: find.byType(RepaintBoundary),
            )
            .first;
        expect(tester.getSize(background), const Size(440, 260));
        // Check the real bundled PNGs as well as the ImageProvider mapping.
        await tester.runAsync(() async {
          final bytes = await rootBundle.load(mode.$2);
          expect(bytes.lengthInBytes, mode.$3);
          expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 8), [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ]);
          expect(bytes.getUint32(16), 1586);
          expect(bytes.getUint32(20), 992);
        });
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled reader has an opaque paper background in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        _host(brightness: brightness, enabled: false, child: const SizedBox()),
      );
      expect(_backgroundImage, findsNothing);
      final box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(ReaderBackdrop),
          matching: find.byType(ColoredBox),
        ),
      );
      final context = tester.element(find.byType(ReaderBackdrop));
      expect(box.color, DeskColors(context).paper.withValues(alpha: 1));
      expect(box.color.a, 1);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background and appearance changes retain the mounted reader and scroll',
    (tester) async {
      final controller = ScrollController();
      const childKey = ValueKey('retained-reader');
      final child = ListView.builder(
        key: childKey,
        controller: controller,
        itemExtent: 44,
        itemCount: 100,
        itemBuilder: (_, index) => Text('Row $index'),
      );
      try {
        await tester.pumpWidget(_host(child: child));
        final element = tester.element(find.byKey(childKey));
        final position = controller.position;
        controller.jumpTo(440);
        await tester.pump();
        final imageRect = tester.getRect(_backgroundImage);
        expect(imageRect.size, const Size(440, 260));
        for (final mode in [
          (false, Brightness.light, DeskThemeFamily.classic),
          (false, Brightness.dark, DeskThemeFamily.mountain),
          (true, Brightness.dark, DeskThemeFamily.mountain),
          (true, Brightness.light, DeskThemeFamily.coast),
          (true, Brightness.light, DeskThemeFamily.classic),
        ]) {
          await tester.pumpWidget(
            _host(
              child: child,
              enabled: mode.$1,
              brightness: mode.$2,
              family: mode.$3,
            ),
          );
          expect(tester.element(find.byKey(childKey)), same(element));
          expect(controller.position, same(position));
          expect(controller.offset, 440);
          expect(find.text('Row 10'), findsOneWidget);
          if (mode.$1) {
            expect(tester.getRect(_backgroundImage), imageRect);
            final asset =
                tester.widget<Image>(_backgroundImage).image as AssetImage;
            expect(asset.assetName, mode.$3.readingAsset(mode.$2));
          }
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
}
