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

const _firstURL = 'https://images.example/viewer-source-a.png';
const _secondURL = 'https://images.example/viewer-source-b.png';
const _viewerKey = ValueKey('viewer-source');
const _retryLabel = '重新加载原图';
const _accountLabel = '账号已变更，请关闭图片后重新打开。';
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _Read {
  _Read(this.arguments);
  final JsonMap arguments;
  final result = Completer<JsonMap>();
}

class _ViewerNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final loads = <_Read>[];

  int releases(String url) => calls
      .where((call) => call.$1 == 'images.release' && call.$2['url'] == url)
      .length;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    final captured = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, captured));
    if (method == 'images.release') return Future.value({'released': true});
    if (method != 'images.load') {
      throw StateError('Unexpected native operation: $method');
    }
    final read = _Read(captured);
    loads.add(read);
    return read.result.future;
  }

  Uint8List complete(int index, {Uint8List? bytes, int width = 1}) {
    final value = bytes ?? Uint8List.fromList(_pixel);
    loads[index].result.complete({
      'bytes': value,
      'width': width,
      'height': 1,
      'originalWidth': width,
      'originalHeight': 1,
    });
    return value;
  }

  void fail(int index) => loads[index].result.completeError(
    const NativeFailure('image', 'Controlled original transport failure'),
  );
}

class _ViewerState extends AppState {
  _ViewerState(_ViewerNative native) : super(client: native);
  final evictions = <(String, Future<Uint8List>, int, String, bool)>[];

  void changeAccount() {
    client.accessRevision++;
    notifyListeners();
  }

  @override
  bool evictImageFuture(
    String url,
    Future<Uint8List> expected, {
    required int revision,
    String kind = 'post',
  }) {
    final removed = super.evictImageFuture(
      url,
      expected,
      revision: revision,
      kind: kind,
    );
    evictions.add((url, expected, revision, kind, removed));
    return removed;
  }
}

class _Fixture {
  final native = _ViewerNative();
  late final state = _ViewerState(native);
  final thumbnail = Uint8List.fromList(_pixel);
}

Finder _viewerImages() =>
    find.descendant(of: find.byKey(_viewerKey), matching: find.byType(Image));

Finder _showing(Uint8List bytes) => find.descendant(
  of: find.byKey(_viewerKey),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Image &&
        widget.image is MemoryImage &&
        identical((widget.image as MemoryImage).bytes, bytes),
  ),
);

Finder _anywhereShowing(Uint8List bytes) => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is MemoryImage &&
      identical((widget.image as MemoryImage).bytes, bytes),
);

/// Observe the real codec shared by Image.memory. No fake decoder/errorBuilder
/// is installed, and malformed native bytes must reach the viewer's own error UI.
Future<bool> _decoded(Uint8List bytes) async {
  final stream = MemoryImage(bytes).resolve(ImageConfiguration.empty);
  final completion = Completer<bool>();
  final listener = ImageStreamListener(
    (info, synchronous) {
      info.dispose();
      if (!completion.isCompleted) completion.complete(true);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completion.isCompleted) completion.complete(false);
    },
  );
  stream.addListener(listener);
  try {
    return await completion.future.timeout(const Duration(seconds: 5));
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  final fixtures = <_Fixture>[];
  _Fixture fixture() {
    final value = _Fixture();
    fixtures.add(value);
    return value;
  }

  tearDown(() {
    for (final value in fixtures) {
      value.state.dispose();
    }
    fixtures.clear();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(
    WidgetTester tester,
    _Fixture value, {
    String url = _firstURL,
    Uint8List? thumbnail,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: NativeImageViewer(
            key: _viewerKey,
            state: value.state,
            url: url,
            thumbnail: thumbnail ?? value.thumbnail,
          ),
        ),
      ),
    );
    await pump(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'same-key URL replacement clears the completed original and owns the new source',
    (tester) async {
      final value = fixture();
      await mount(tester, value);
      final original = value.native.complete(0);
      await pump(tester);
      expect(_showing(original), findsOneWidget);
      final secondThumbnail = Uint8List.fromList(_pixel);

      await mount(tester, value, url: _secondURL, thumbnail: secondThumbnail);
      expect(value.native.loads, hasLength(2));
      expect(value.native.loads.last.arguments, {
        'url': _secondURL,
        'kind': 'original',
        'accessRevision': 0,
      });
      expect(value.native.releases(_firstURL), greaterThanOrEqualTo(1));
      expect(_showing(original), findsNothing);
      expect(_showing(value.thumbnail), findsNothing);
      expect(_showing(secondThumbnail), findsOneWidget);
      final replacement = value.native.complete(1);
      await pump(tester);
      expect(_showing(replacement), findsOneWidget);
      expect(value.native.releases(_secondURL), 0);
      await close(tester);
    },
  );

  for (final oldFails in [false, true]) {
    testWidgets(
      'same-key A to B to A ignores retired A ${oldFails ? 'failure' : 'success'} without releasing new A',
      (tester) async {
        final value = fixture();
        await mount(tester, value);
        await mount(tester, value, url: _secondURL);
        await mount(tester, value);
        expect(value.native.loads, hasLength(3));
        expect(value.native.loads.map((load) => load.arguments['url']), [
          _firstURL,
          _secondURL,
          _firstURL,
        ]);
        final current = value.state.image(_firstURL, kind: 'original');
        final releases = value.native.releases(_firstURL);
        Uint8List? retired;
        if (oldFails) {
          value.native.fail(0);
        } else {
          retired = value.native.complete(0);
        }
        value.native.complete(1);
        await pump(tester);
        expect(
          value.native.releases(_firstURL),
          releases,
          reason: 'A retired lifetime cannot release the active owner for the same URL.',
        );
        expect(value.state.image(_firstURL, kind: 'original'), same(current));
        expect(value.native.loads, hasLength(3));
        if (retired != null) expect(_showing(retired), findsNothing);
        expect(_showing(value.thumbnail), findsOneWidget);
        expect(find.text(_retryLabel), findsNothing);

        final replacement = value.native.complete(2, width: 21);
        await pump(tester);
        expect(_showing(replacement), findsOneWidget);
        expect(
          value.state.imageDimensions(_firstURL, kind: 'original')['width'],
          21,
        );
        expect(value.state.message, isNull);
        await close(tester);
      },
    );
  }

  testWidgets(
    'same-key AppState replacement at the same revision releases the old state and detaches its listener',
    (tester) async {
      final old = fixture(), next = fixture();
      await mount(tester, old);
      final original = old.native.complete(0);
      await pump(tester);
      expect(_showing(original), findsOneWidget);
      expect(old.state.accessRevision, next.state.accessRevision);

      await mount(tester, next);
      expect(next.native.loads, hasLength(1));
      expect(old.native.releases(_firstURL), greaterThanOrEqualTo(1));
      expect(_showing(original), findsNothing);
      expect(_showing(next.thumbnail), findsOneWidget);
      old.state.changeAccount();
      await pump(tester);
      expect(find.text(_accountLabel), findsNothing);
      expect(next.native.loads, hasLength(1));
      final replacement = next.native.complete(0);
      await pump(tester);
      expect(_showing(replacement), findsOneWidget);
      expect(next.native.releases(_firstURL), 0);
      await close(tester);
    },
  );

  for (final originalLoaded in [false, true]) {
    testWidgets(
      'account notification immediately hides ${originalLoaded ? 'original' : 'thumbnail'} without fetching the old image for the new account',
      (tester) async {
        final value = fixture();
        await mount(tester, value);
        if (originalLoaded) {
          final original = value.native.complete(0);
          await pump(tester);
          expect(_showing(original), findsOneWidget);
        } else {
          expect(_showing(value.thumbnail), findsOneWidget);
        }

        // Deliberately do not rebuild the host: the viewer must listen itself.
        value.state.changeAccount();
        await tester.pump();
        expect(find.text(_accountLabel), findsOneWidget);
        expect(_viewerImages(), findsNothing);
        expect(find.text(_retryLabel), findsNothing);
        expect(value.native.loads, hasLength(1));
        if (!originalLoaded) value.native.complete(0);
        await pump(tester);
        expect(find.text(_accountLabel), findsOneWidget);
        expect(_viewerImages(), findsNothing);
        expect(value.native.loads, hasLength(1));
        expect(
          value.native.calls.where((call) => call.$2['accessRevision'] == 1),
          isEmpty,
          reason: 'An obsolete viewer must neither fetch nor release a new account resource.',
        );
        expect(value.state.message, isNull);
        await close(tester);
      },
    );
  }

  for (final popping in [false, true]) {
    testWidgets(
      'account notification hides a real Hero ${popping ? 'pop' : 'push'} shuttle before its flight finishes',
      (tester) async {
        final value = fixture();
        final navigator = GlobalKey<NavigatorState>();
        const tag = 'viewer-source-account-flight';
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            builder: (context, child) => GlassAdaptiveScope(
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: child!,
            ),
            // The counterpart participates in the real Hero flight, but has no
            // bitmap so a surviving Image can only be the viewer or its shuttle.
            home: const Center(
              child: Hero(
                tag: tag,
                child: SizedBox(
                  width: 96,
                  height: 64,
                  child: ColoredBox(color: Color(0xff334455)),
                ),
              ),
            ),
          ),
        );
        final route = PageRouteBuilder<void>(
          transitionDuration: const Duration(seconds: 1),
          reverseTransitionDuration: const Duration(seconds: 1),
          pageBuilder: (context, animation, secondaryAnimation) =>
              NativeImageViewer(
                key: _viewerKey,
                state: value.state,
                url: _firstURL,
                thumbnail: value.thumbnail,
                heroTag: tag,
              ),
        );
        unawaited(navigator.currentState!.push(route));
        await pump(tester);
        Uint8List? original;
        if (popping) {
          for (
            var frame = 0;
            frame < 20 && route.animation!.status != AnimationStatus.completed;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(route.animation!.status, AnimationStatus.completed);
          original = value.native.complete(0);
          await pump(tester);
          expect(_showing(original), findsOneWidget);
          navigator.currentState!.pop();
          await pump(tester);
        }
        await tester.pump(const Duration(milliseconds: 150));
        final direction = popping
            ? AnimationStatus.reverse
            : AnimationStatus.forward;
        expect(route.animation!.status, direction);
        expect(route.animation!.value, allOf(greaterThan(0), lessThan(1)));
        final shuttle = _anywhereShowing(value.thumbnail);
        expect(
          shuttle,
          findsOneWidget,
          reason: 'This assertion must observe an actual in-flight bitmap.',
        );
        expect(
          find.ancestor(of: shuttle, matching: find.byKey(_viewerKey)),
          findsNothing,
          reason: 'The bitmap must be in the Hero overlay, outside the viewer subtree.',
        );

        value.state.changeAccount();
        await tester.pump();
        expect(
          route.animation!.status,
          direction,
          reason: 'Account invalidation must hide the shuttle before the flight ends.',
        );
        expect(_anywhereShowing(value.thumbnail), findsNothing);
        if (original != null) expect(_anywhereShowing(original), findsNothing);
        expect(find.text(_accountLabel), findsOneWidget);
        expect(value.native.loads, hasLength(1));
        if (!popping) value.native.complete(0);
        await pump(tester);
        expect(_anywhereShowing(value.thumbnail), findsNothing);
        expect(
          value.native.calls.where((call) => call.$2['accessRevision'] == 1),
          isEmpty,
        );

        for (var frame = 0; frame < 20; frame++) {
          if (popping
              ? find.byKey(_viewerKey).evaluate().isEmpty
              : route.animation!.status == AnimationStatus.completed) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        // A popped route disposes its animation after the last frame, so use the
        // widget lifecycle as the final assertion instead of reading it again.
        if (popping) {
          expect(find.byKey(_viewerKey), findsNothing);
        } else {
          expect(route.animation!.status, AnimationStatus.completed);
          expect(find.text(_accountLabel), findsOneWidget);
        }
        expect(value.state.message, isNull);
        await close(tester);
      },
    );
  }

  testWidgets(
    'original transport failure retains its thumbnail and retries without stale error or global message',
    (tester) async {
      final value = fixture();
      await mount(tester, value);
      value.native.fail(0);
      await pump(tester);
      expect(_showing(value.thumbnail), findsOneWidget);
      expect(find.text(_retryLabel), findsOneWidget);
      await tester.tap(find.text(_retryLabel));
      await pump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'A retry setState callback cannot return a Future.',
      );
      expect(value.native.loads, hasLength(2));
      expect(find.text(_retryLabel), findsNothing);
      expect(_showing(value.thumbnail), findsOneWidget);
      expect(value.native.releases(_firstURL), 0);
      final recovered = value.native.complete(1);
      await pump(tester);
      expect(_showing(recovered), findsOneWidget);
      expect(value.state.message, isNull);
      await close(tester);
    },
  );

  testWidgets(
    'real original decode failure keeps thumbnail and retries by evicting only its successful corrupt Future',
    (tester) async {
      await tester.runAsync(() async {
        final value = fixture();
        await mount(tester, value);
        final failed = value.state.image(_firstURL, kind: 'original');
        final broken = Uint8List.fromList([0x53, 0x44, 0, 1, 2]);
        final decoding = _decoded(broken);
        value.native.complete(0, bytes: broken);
        await pump(tester);
        expect(await decoding, isFalse);
        await pump(tester);
        expect(tester.takeException(), isNull);
        expect(_showing(value.thumbnail), findsOneWidget);
        expect(find.text(_retryLabel), findsOneWidget);
        expect(value.state.image(_firstURL, kind: 'original'), same(failed));

        await tester.tap(find.text(_retryLabel));
        await pump(tester);
        expect(value.native.loads, hasLength(2));
        expect(value.state.evictions, hasLength(1));
        expect(value.state.evictions.single, (
          _firstURL,
          failed,
          0,
          'original',
          true,
        ));
        expect(value.native.releases(_firstURL), 0);
        expect(_showing(value.thumbnail), findsOneWidget);
        expect(find.text(_retryLabel), findsNothing);
        final recovered = value.native.complete(1);
        await pump(tester);
        expect(await _decoded(recovered), isTrue);
        await pump(tester);
        expect(_showing(recovered), findsOneWidget);
        expect(find.text(_retryLabel), findsNothing);
        expect(value.state.message, isNull);
        await close(tester);
      });
    },
  );

  for (final successorPending in [true, false]) {
    testWidgets(
      'old decode retry preserves a newer ${successorPending ? 'pending' : 'completed'} original owner',
      (tester) async {
        await tester.runAsync(() async {
          final value = fixture();
          await mount(tester, value);
          final failed = value.state.image(_firstURL, kind: 'original');
          final broken = Uint8List.fromList([0x53, 0x44, 0, 3, 4]);
          final decoding = _decoded(broken);
          value.native.complete(0, bytes: broken);
          await pump(tester);
          expect(await decoding, isFalse);
          await pump(tester);
          expect(tester.takeException(), isNull);
          expect(find.text(_retryLabel), findsOneWidget);

          expect(
            value.state.evictImageFuture(
              _firstURL,
              failed,
              revision: 0,
              kind: 'original',
            ),
            isTrue,
          );
          value.state.evictions.clear();
          final successor = value.state.image(_firstURL, kind: 'original');
          Uint8List? recovered;
          if (!successorPending) {
            recovered = value.native.complete(1, width: 37);
            await successor;
          }
          await tester.tap(find.text(_retryLabel));
          await pump(tester);
          expect(value.state.evictions, hasLength(1));
          expect(value.state.evictions.single, (
            _firstURL,
            failed,
            0,
            'original',
            false,
          ));
          expect(value.native.loads, hasLength(2));
          expect(value.native.releases(_firstURL), 0);
          expect(
            value.state.image(_firstURL, kind: 'original'),
            same(successor),
          );
          if (successorPending) {
            expect(_showing(value.thumbnail), findsOneWidget);
            recovered = value.native.complete(1, width: 37);
            await successor;
            await pump(tester);
          }
          expect(await _decoded(recovered!), isTrue);
          await pump(tester);
          expect(_showing(recovered), findsOneWidget);
          expect(find.text(_retryLabel), findsNothing);
          expect(
            value.state.imageDimensions(_firstURL, kind: 'original')['width'],
            37,
          );
          expect(value.state.message, isNull);
          await close(tester);
        });
      },
    );
  }
}
