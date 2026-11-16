import 'dart:typed_data';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

JsonMap officeSnapshot(bool presented) => {
  'items': [
    {'id': 'office', 'active': true},
  ],
  'settings': {
    'office': {
      'presented': presented,
      'key': '9',
      'title': 'Project sheet',
      'button': '恢复窗口',
    },
  },
};

class OfficeDragFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return method == 'extensions.office'
        ? officeSnapshot(args['presented'] == true)
        : {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'office hotkey covers a live tab drag before the pointer is released',
    (tester) async {
      final native = OfficeDragFixture();
      final state = AppState(client: native)..connecting = false;
      state.domains['extensions'] = officeSnapshot(false);
      state.domains['workspace'] = {
        'tabs': [
          for (final id in ['1', '2', '3'])
            {
              'id': id,
              'url': 'https://www.nodeseek.com/post-$id-1',
              'title': 'Private title $id',
            },
        ],
        'selectedTab': '1',
      };
      final capture = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: CupertinoApp(
              builder: (context, child) =>
                  ExtensionOverlays(state: state, child: child!),
              home: CupertinoPageScaffold(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 90),
                    child: SizedBox(
                      width: 850,
                      child: WorkspaceTabs(state: state),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('tab-drag-1'))),
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveTo(const Offset(430, 330));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Private title 1'), findsNWidgets(2));
      expect(
        tester.getRect(find.text('Private title 1').last).top,
        greaterThan(300),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'extensions.office').length,
        1,
      );
      expect(find.text('Project sheet'), findsOneWidget);

      // The drag is deliberately kept alive and moves after the cover opens.
      // Hit tests cannot reveal this regression because feedback ignores input;
      // compare the actual painted pixels with the unobstructed cover instead.
      await gesture.moveTo(const Offset(510, 390));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Private title 1'), findsNWidgets(2));
      final feedbackRect = tester
          .getRect(find.text('Private title 1').last)
          .inflate(22);

      Future<Uint8List> regionPixels() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final bytes = BytesBuilder();
            final left = feedbackRect.left.floor().clamp(0, image.width);
            final right = feedbackRect.right.ceil().clamp(0, image.width);
            for (
              var y = feedbackRect.top.floor().clamp(0, image.height);
              y < feedbackRect.bottom.ceil().clamp(0, image.height);
              y++
            ) {
              bytes.add(
                pixels.buffer.asUint8List(
                  (y * image.width + left) * 4,
                  (right - left) * 4,
                ),
              );
            }
            return bytes.takeBytes();
          } finally {
            image.dispose();
          }
        }))!;
      }

      final withDrag = await regionPixels();
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Private title 1'), findsOneWidget);
      final withoutDrag = await regionPixels();
      expect(withDrag.length, withoutDrag.length);
      var differentPixels = 0;
      for (var offset = 0; offset < withDrag.length; offset += 4) {
        if (List.generate(
          4,
          (channel) =>
              withDrag[offset + channel] != withoutDrag[offset + channel],
        ).any((different) => different)) {
          differentPixels++;
        }
      }
      expect(
        differentPixels,
        0,
        reason: 'An active tab drag must paint underneath the office sheet, including after the pointer moves.',
      );
      expect(native.calls.where((call) => call.$1 == 'reader.move'), isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    },
  );
}
