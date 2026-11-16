// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/desk_wordmark.dart';

Widget _host({
  Widget wordmark = const DeskWordmark(),
  Brightness brightness = Brightness.light,
  double dpr = 2,
}) => MediaQuery(
  data: MediaQueryData(devicePixelRatio: dpr),
  child: CupertinoTheme(
    data: CupertinoThemeData(brightness: brightness),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: wordmark),
    ),
  ),
);

Image _image(WidgetTester tester) => tester.widget<Image>(
  find.descendant(of: find.byType(DeskWordmark), matching: find.byType(Image)),
);

ResizeImage _decoded(WidgetTester tester) =>
    _image(tester).image as ResizeImage;

String _asset(WidgetTester tester) =>
    (_decoded(tester).imageProvider as AssetImage).assetName;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all six palettes select their bundled light and dark artwork', (
    tester,
  ) async {
    const assets = {
      'Cobalt': ('Wordmark.png', 'Wordmark-Dark.png'),
      'Teal': ('Wordmark-Teal-Light.png', 'Wordmark-Teal-Dark.png'),
      'Fern': ('Wordmark-Fern-Light.png', 'Wordmark-Fern-Dark.png'),
      'Iris': ('Wordmark-Iris-Light.png', 'Wordmark-Iris-Dark.png'),
      'Amber': ('Wordmark-Amber-Light.png', 'Wordmark-Amber-Dark.png'),
      'Coral': ('Wordmark-Coral-Light.png', 'Wordmark-Coral-Dark.png'),
    };
    final paths = <String>{};
    for (final palette in assets.entries) {
      for (final mode in [
        (Brightness.light, palette.value.$1),
        (Brightness.dark, palette.value.$2),
      ]) {
        await tester.pumpWidget(
          _host(
            wordmark: DeskWordmark(palette: palette.key),
            brightness: mode.$1,
          ),
        );
        final expected = 'assets/brand/${mode.$2}';
        expect(_asset(tester), expected);
        paths.add(expected);
      }
    }
    // Read the actual Flutter bundle as well as checking ImageProvider paths:
    // a correct mapping with a missing pubspec entry must fail this test.
    await tester.runAsync(() async {
      for (final path in paths) {
        final bytes = await rootBundle.load(path);
        expect(bytes.lengthInBytes, greaterThan(1000), reason: path);
        expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 8), [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ], reason: '$path is the original PNG format');
        expect(bytes.getUint32(16), 2172, reason: '$path source width');
        expect(bytes.getUint32(20), 724, reason: '$path source height');
      }
    });
    expect(paths, hasLength(12));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('mounted wordmark follows theme and palette changes', (
    tester,
  ) async {
    const key = ValueKey('retained-wordmark');
    await tester.pumpWidget(
      _host(
        wordmark: const DeskWordmark(key: key, palette: 'Teal'),
      ),
    );
    final element = tester.element(find.byKey(key));
    expect(_asset(tester), 'assets/brand/Wordmark-Teal-Light.png');
    await tester.pumpWidget(
      _host(
        wordmark: const DeskWordmark(key: key, palette: 'Teal'),
        brightness: Brightness.dark,
      ),
    );
    expect(tester.element(find.byKey(key)), same(element));
    expect(_asset(tester), 'assets/brand/Wordmark-Teal-Dark.png');
    await tester.pumpWidget(
      _host(
        wordmark: const DeskWordmark(key: key, palette: 'Coral'),
        brightness: Brightness.dark,
      ),
    );
    expect(tester.element(find.byKey(key)), same(element));
    expect(_asset(tester), 'assets/brand/Wordmark-Coral-Dark.png');
  });

  testWidgets('default and invalid palettes fall back to themed Cobalt', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final expected = brightness == Brightness.dark
          ? 'assets/brand/Wordmark-Dark.png'
          : 'assets/brand/Wordmark.png';
      for (final wordmark in const [
        DeskWordmark(),
        DeskWordmark(palette: ''),
        DeskWordmark(palette: 'teal'),
        DeskWordmark(palette: '../unknown'),
      ]) {
        await tester.pumpWidget(
          _host(wordmark: wordmark, brightness: brightness),
        );
        expect(_asset(tester), expected);
      }
    }
  });

  testWidgets(
    'keeps native frame geometry, untinted artwork and caller semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        for (final height in [30.0, 34.0]) {
          await tester.pumpWidget(
            _host(
              wordmark: Semantics(
                label: 'SeekDesk 首页',
                button: true,
                child: DeskWordmark(height: height),
              ),
            ),
          );
          final size = tester.getSize(find.byType(DeskWordmark));
          expect(size.width, closeTo(height * 3.1, .001));
          expect(size.height, height);
          final image = _image(tester);
          expect(image.fit, BoxFit.contain);
          expect(image.color, isNull);
          expect(image.colorBlendMode, isNull);
          expect(image.excludeFromSemantics, isTrue);
          expect(image.semanticLabel, isNull);
          expect(find.bySemanticsLabel('SeekDesk 首页'), findsOneWidget);
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'decode follows DPR without changing layout or exceeding source pixels',
    (tester) async {
      for (final sample in const [
        (1.0, 90, 30),
        (2.0, 180, 60),
        (1.25, 114, 38),
        (100.0, 2172, 724),
      ]) {
        await tester.pumpWidget(_host(dpr: sample.$1));
        final image = _decoded(tester);
        expect(image.width, sample.$2);
        expect(image.height, sample.$3);
        expect(tester.getSize(find.byType(DeskWordmark)), const Size(93, 30));
      }
    },
  );
}
