import 'dart:typed_data';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

class _NoServiceClient extends NativeClient {
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async =>
      throw StateError('First-paint fixture must not call native services.');
}

class _RegionPixels {
  const _RegionPixels(this.bytes, this.inkPixels);
  final Uint8List bytes;
  final int inkPixels;
}

/// Rasterize the existing root layer and crop it in memory. Deliberately do not
/// add a new repaint boundary to the body, rebuild, or pump while capturing.
Future<_RegionPixels> _captureRegion(
  WidgetTester tester,
  GlobalKey capture,
  Finder region,
) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final rect = tester.getRect(region);
  final origin = boundary.localToGlobal(Offset.zero);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final source = data.buffer.asUint8List();
      final left = (rect.left - origin.dx).ceil().clamp(0, image.width);
      final right = (rect.right - origin.dx).floor().clamp(0, image.width);
      final top = (rect.top - origin.dy).ceil().clamp(0, image.height);
      final bottom = (rect.bottom - origin.dy).floor().clamp(0, image.height);
      final bytes = BytesBuilder();
      var ink = 0;
      for (var y = top; y < bottom; y++) {
        final row = source.sublist(
          (y * image.width + left) * 4,
          (y * image.width + right) * 4,
        );
        bytes.add(row);
        for (var x = 0; x < row.length; x += 4) {
          // Body has only white background and dark text. No borders, author,
          // or reaction controls can satisfy this actual painted-ink check.
          if (row[x] < 180 && row[x + 1] < 180 && row[x + 2] < 200) ink++;
        }
      }
      return _RegionPixels(bytes.takeBytes(), ink);
    } finally {
      image.dispose();
    }
  }))!;
}

int _differentPixels(_RegionPixels first, _RegionPixels later) {
  expect(first.bytes.length, later.bytes.length);
  var differences = 0;
  for (var i = 0; i < first.bytes.length; i += 4) {
    if (first.bytes[i] != later.bytes[i] ||
        first.bytes[i + 1] != later.bytes[i + 1] ||
        first.bytes[i + 2] != later.bytes[i + 2] ||
        first.bytes[i + 3] != later.bytes[i + 3]) {
      differences++;
    }
  }
  return differences;
}

void main() {
  testWidgets('new lazy markdown rows paint body pixels in their first frame', (
    tester,
  ) async {
    final state = AppState(client: _NoServiceClient());
    final scroll = ScrollController();
    final capture = GlobalKey();
    final built = <int>{};
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CupertinoApp(
        theme: const CupertinoThemeData(brightness: Brightness.light),
        home: RepaintBoundary(
          key: capture,
          child: ColoredBox(
            color: const Color(0xffffffff),
            child: ListView.builder(
              controller: scroll,
              padding: EdgeInsets.zero,
              itemCount: 40,
              // Production SliverList retains its default automatic boundary;
              // each floor also has an explicit boundary below, as in Reader.
              addRepaintBoundaries: true,
              itemBuilder: (context, index) {
                built.add(index);
                return RepaintBoundary(
                  key: ValueKey('floor-$index'),
                  child: SizedBox(
                    height: 260,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(30, 14, 30, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '本地回复者 $index · #$index',
                            key: ValueKey('author-$index'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xff26314a),
                            ),
                          ),
                          const SizedBox(height: 15),
                          Column(
                            key: ValueKey('body-$index'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              InlineMarkdown(
                                state: state,
                                text:
                                    '第 $index 条固定回复。连续滚动经过多种正文和工具按钮，检查文字清晰度、列表布局与玻璃折射的稳定性。**这些数据仅用于本机性能测量。**',
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.75,
                                  color: Color(0xff26314a),
                                ),
                              ),
                              const SizedBox(height: 13),
                              InlineMarkdown(
                                state: state,
                                text:
                                    'Fixed local content $index: **renderer measurements** include build, raster and total span. 没有网络请求或随机数据影响这段阅读路径。',
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.75,
                                  color: Color(0xff26314a),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            '赞同 · 鸡腿 · 反对',
                            key: ValueKey('actions-$index'),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff5d6a80),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final floor in [13, 17, 22]) {
      expect(
        built,
        isNot(contains(floor)),
        reason: 'The target must never have been built or painted before.',
      );
      scroll.jumpTo(floor * 260);
      // Exactly one frame: no settling or second pump before this capture.
      await tester.pump();
      final body = find.byKey(ValueKey('body-$floor'));
      expect(tester.takeException(), isNull);
      final first = await _captureRegion(tester, capture, body);
      final author = await _captureRegion(
        tester,
        capture,
        find.byKey(ValueKey('author-$floor')),
      );
      final actions = await _captureRegion(
        tester,
        capture,
        find.byKey(ValueKey('actions-$floor')),
      );

      await tester.pump(const Duration(milliseconds: 16));
      final second = await _captureRegion(tester, capture, body);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final stable = await _captureRegion(tester, capture, body);
      final firstDelta = _differentPixels(first, stable);
      final secondDelta = _differentPixels(second, stable);
      // These figures describe software-rendered widget-test pixels only.
      // They do not establish the behavior of macOS Impeller or native fonts.
      // ignore: avoid_print
      print(
        'firstPaint floor=$floor firstInk=${first.inkPixels} '
        'secondInk=${second.inkPixels} stableInk=${stable.inkPixels} '
        'firstVsStable=$firstDelta secondVsStable=$secondDelta',
      );
      expect(author.inkPixels, greaterThan(100));
      expect(actions.inkPixels, greaterThan(100));
      expect(
        stable.inkPixels,
        greaterThan(1000),
        reason: 'The body crop must contain actual painted glyph pixels.',
      );
      expect(
        first.inkPixels,
        greaterThan(1000),
        reason: 'A body missing on the first frame is a regression.',
      );
      expect(
        firstDelta,
        0,
        reason: 'Fresh body paint must match its later settled pixels.',
      );
      expect(secondDelta, 0);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    state.dispose();
  });

  testWidgets('lazy code paints glyphs immediately while scrolling both ways', (
    tester,
  ) async {
    final state = AppState(client: _NoServiceClient());
    final scroll = ScrollController();
    final capture = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CupertinoApp(
        theme: const CupertinoThemeData(brightness: Brightness.light),
        home: RepaintBoundary(
          key: capture,
          child: ColoredBox(
            color: const Color(0xffffffff),
            child: ListView.builder(
              controller: scroll,
              padding: EdgeInsets.zero,
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              itemCount: 40,
              itemBuilder: (context, index) => RepaintBoundary(
                key: ValueKey('code-floor-$index'),
                child: SizedBox(
                  height: 240,
                  child: Padding(
                    padding: const EdgeInsets.all(25),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Code author $index'),
                        const SizedBox(height: 12),
                        ForumBlocks(
                          key: ValueKey('code-body-$index'),
                          state: state,
                          blocks: [
                            {
                              'kind': 'code',
                              'text':
                                  'final floor = $index;\n'
                                  'final label = "First visible frame";\n'
                                  'print("Scroll down and back up");\n'
                                  'return floor + label.length;',
                            },
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final floor in [13, 24, 16, 24]) {
      expect(find.byKey(ValueKey('code-floor-$floor')), findsNothing);
      scroll.jumpTo(floor * 240);
      await tester.pump();
      final body = find.byKey(ValueKey('code-body-$floor'));
      expect(find.byType(EditableText), findsNothing);
      final first = await _captureRegion(tester, capture, body);
      await tester.pump(const Duration(milliseconds: 16));
      final second = await _captureRegion(tester, capture, body);
      await tester.pumpAndSettle();
      final stable = await _captureRegion(tester, capture, body);
      // The code background is light (#f1f4fa), so only its dark glyphs can
      // satisfy the ink threshold. A painted empty panel is not a pass.
      expect(first.inkPixels, greaterThan(1000));
      expect(_differentPixels(first, stable), 0);
      expect(_differentPixels(second, stable), 0);
      // ignore: avoid_print
      print(
        'codeFirstPaint floor=$floor firstInk=${first.inkPixels} '
        'stableInk=${stable.inkPixels} '
        'firstVsStable=${_differentPixels(first, stable)}',
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    state.dispose();
  });
}
