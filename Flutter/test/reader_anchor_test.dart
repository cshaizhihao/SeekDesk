// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

class AnchorNative extends NativeClient {
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async => {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'notification fragment locates a reply outside the initial viewport',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final state = AppState(client: AnchorNative());
      const url = 'https://www.nodeseek.com/post-17-1';
      state.readers[url] = {
        'url': url,
        'scrollOffset': 0,
        'thread': {
          'title': 'Fixture',
          'root': {
            'id': '0',
            'author': 'Root',
            'blocks': [
              {'kind': 'text', 'text': 'Root body'},
            ],
          },
          'replies': [
            for (var i = 1; i <= 45; i++)
              {
                'id': '$i',
                'author': 'Author$i',
                'blocks': [
                  {'kind': 'text', 'text': 'Reply content $i'},
                ],
              },
          ],
        },
      };
      await tester.pumpWidget(
        CupertinoApp(
          home: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: CupertinoPageScaffold(
              child: ReaderScreen(
                state: state,
                topic: TopicData({'id': '17', 'url': '$url#comment-35'}),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('Reply content 35').hitTestable().evaluate().isNotEmpty) {
          break;
        }
      }
      expect(tester.takeException(), isNull);
      expect(find.text('Reply content 35').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    },
  );
}
