import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _url = 'https://images.example/viewer-lifecycle.png';
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _ViewerNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final loads = <Completer<JsonMap>>[];

  int get releases => calls.where((call) => call.$1 == 'images.release').length;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments}));
    if (method == 'images.release') {
      return Future<JsonMap>.value({'released': true});
    }
    if (method != 'images.load') {
      throw StateError('Unexpected native operation: $method');
    }
    final response = Completer<JsonMap>();
    loads.add(response);
    return response.future;
  }

  void complete(int index) =>
      loads[index].complete({'bytes': _pixel, 'width': 1, 'height': 1});

  void fail(int index) => loads[index].completeError(
    const NativeFailure('image', 'Fixture image failure.'),
  );
}

void main() {
  late _ViewerNative native;
  late AppState state;
  late bool disposed;

  setUp(() {
    native = _ViewerNative();
    state = AppState(client: native);
    disposed = false;
  });

  tearDown(() {
    if (!disposed) state.dispose();
  });

  Future<void> viewers(WidgetTester tester, List<String> identities) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: Stack(
            children: [
              for (final identity in identities)
                NativeImageViewer(
                  key: ValueKey(identity),
                  state: state,
                  url: _url,
                  thumbnail: _pixel,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settleOriginal(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'native success after app disposal still releases the original resource',
    (tester) async {
      await viewers(tester, ['first']);
      final original = state.image(_url, kind: 'original');
      final rejected = expectLater(
        original,
        throwsA(
          isA<NativeFailure>().having(
            (error) => error.code,
            'code',
            'disposed',
          ),
        ),
      );
      expect(native.loads, hasLength(1));

      state.dispose();
      disposed = true;
      await viewers(tester, []);
      expect(native.releases, 1);

      native.complete(0);
      await settleOriginal(tester);
      await rejected;
      expect(native.releases, 2);
      expect(state.imageDimensions(_url, kind: 'original'), isEmpty);
      expect(state.message, isNull);
      expect(
        native.calls.every(
          (call) => call.$1 == 'images.load' || call.$1 == 'images.release',
        ),
        isTrue,
      );
    },
  );

  testWidgets('late native failure still finishes closed-viewer cleanup', (
    tester,
  ) async {
    await viewers(tester, ['first']);
    await viewers(tester, []);
    expect(native.releases, 1);

    native.fail(0);
    await settleOriginal(tester);
    expect(native.releases, 2);
    expect(state.message, isNull);
  });

  for (final oldRequestFails in [false, true]) {
    testWidgets(
      'reopened viewer survives old request ${oldRequestFails ? 'failure' : 'success'}',
      (tester) async {
        await viewers(tester, ['first']);
        await viewers(tester, []);
        expect(native.releases, 1);
        await viewers(tester, ['second']);
        expect(native.loads, hasLength(2));

        if (oldRequestFails) {
          native.fail(0);
        } else {
          native.complete(0);
        }
        await settleOriginal(tester);
        expect(native.releases, 1);
        expect(find.byKey(const ValueKey('second')), findsOneWidget);

        native.complete(1);
        await settleOriginal(tester);
        expect(native.releases, 1);
        await viewers(tester, []);
        expect(native.releases, 3);
        expect(state.imageDimensions(_url, kind: 'original'), isEmpty);
      },
    );
  }

  testWidgets('only the last of two active viewers releases the original', (
    tester,
  ) async {
    await viewers(tester, ['first', 'second']);
    expect(native.loads, hasLength(1));
    await viewers(tester, ['second']);
    expect(native.releases, 0);

    native.complete(0);
    await settleOriginal(tester);
    expect(native.releases, 0);

    await viewers(tester, []);
    expect(native.releases, 2);
    expect(state.imageDimensions(_url, kind: 'original'), isEmpty);
  });
}
