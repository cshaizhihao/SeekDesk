import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _firstURL = 'https://images.example/leaf-a.png';
const _secondURL = 'https://images.example/leaf-b.png';
const _retryLabel = '图片加载失败，点按重试';
const _leafKey = ValueKey('image-leaf');
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _ImageRead {
  _ImageRead(this.arguments);
  final JsonMap arguments;
  final result = Completer<JsonMap>();
}

class _LeafNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final loads = <_ImageRead>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments, 'accessRevision': accessRevision}));
    if (method == 'images.release') return Future.value({'released': true});
    if (method != 'images.load') {
      throw StateError('Unexpected native operation: $method');
    }
    final read = _ImageRead({...arguments, 'accessRevision': accessRevision});
    loads.add(read);
    return read.result.future;
  }

  Uint8List complete(
    int index, {
    Uint8List? bytes,
    int width = 100,
    int height = 60,
  }) {
    // Each success has its own MemoryImage identity even when using a tiny
    // shared PNG fixture, allowing the widget's source to be checked precisely.
    final value = bytes ?? Uint8List.fromList(_pixel);
    loads[index].result.complete({
      'bytes': value,
      'width': width,
      'height': height,
      'originalWidth': width,
      'originalHeight': height,
    });
    return value;
  }

  void fail(int index) => loads[index].result.completeError(
    const NativeFailure('image', 'Fake transport failure'),
  );
}

class _Fixture {
  final native = _LeafNative();
  late final state = AppState(client: native);
  void dispose() => state.dispose();
}

Finder _leafImages() =>
    find.descendant(of: find.byKey(_leafKey), matching: find.byType(Image));

Uint8List _shownBytes(WidgetTester tester) =>
    (tester.widget<Image>(_leafImages()).image as MemoryImage).bytes;

/// Real codec completion must run outside FakeAsync. This observes the same
/// stream as Image.memory without replacing its production errorBuilder.
Future<bool> _decode(WidgetTester tester) async {
  final image = tester.widget<Image>(_leafImages());
  final stream = image.image.resolve(ImageConfiguration.empty);
  final completed = Completer<bool>();
  final listener = ImageStreamListener(
    (info, synchronous) {
      info.dispose();
      if (!completed.isCompleted) completed.complete(true);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completed.isCompleted) completed.complete(false);
    },
  );
  stream.addListener(listener);
  try {
    return await completed.future.timeout(const Duration(seconds: 5));
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
      value.dispose();
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
    required String kind,
    String url = _firstURL,
    String name = 'Alice',
  }) async {
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: MaterialApp(
          home: CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: kind == 'avatar'
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: NativeAvatar(
                          key: _leafKey,
                          state: value.state,
                          url: url,
                          name: name,
                          size: 40,
                        ),
                      )
                    : NativeForumImage(
                        key: _leafKey,
                        state: value.state,
                        url: url,
                        size: const {'width': 100, 'height': 60},
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    await pump(tester);
  }

  for (final kind in ['avatar', 'post']) {
    testWidgets('$kind clears completed A while a different URL B is pending', (
      tester,
    ) async {
      final value = fixture();
      await mount(tester, value, kind: kind);
      final first = value.native.complete(0);
      await pump(tester);
      expect(_shownBytes(tester), same(first));

      await mount(tester, value, kind: kind, url: _secondURL, name: 'Bob');
      expect(value.native.loads, hasLength(2));
      expect(value.native.loads.last.arguments['url'], _secondURL);
      expect(
        _leafImages(),
        findsNothing,
        reason: 'A completed FutureBuilder snapshot belongs to the old URL.',
      );
      if (kind == 'avatar') expect(find.text('B'), findsOneWidget);
      final second = value.native.complete(1);
      await pump(tester);
      expect(_shownBytes(tester), same(second));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$kind reloads the same URL when AppState changes at the same revision',
      (tester) async {
        final old = fixture(), next = fixture();
        await mount(tester, old, kind: kind);
        final first = old.native.complete(0);
        await pump(tester);
        expect(_shownBytes(tester), same(first));
        expect(old.state.accessRevision, next.state.accessRevision);

        await mount(tester, next, kind: kind, name: 'Bob');
        expect(
          next.native.loads,
          hasLength(1),
          reason: 'AppState identity is part of image ownership.',
        );
        expect(_leafImages(), findsNothing);
        final replacement = next.native.complete(0);
        await pump(tester);
        expect(_shownBytes(tester), same(replacement));
        expect(old.native.loads, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$kind clears the previous account image before the same URL reloads',
      (tester) async {
        final value = fixture();
        await mount(tester, value, kind: kind);
        value.native.complete(0);
        await pump(tester);
        expect(_leafImages(), findsOneWidget);

        value.native.accessRevision++;
        await mount(tester, value, kind: kind, name: 'Bob');
        expect(value.native.loads, hasLength(2));
        expect(value.native.loads.last.arguments['accessRevision'], 1);
        expect(_leafImages(), findsNothing);
        final current = value.native.complete(1);
        await pump(tester);
        expect(_shownBytes(tester), same(current));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'post retains decoded geometry after metadata eviction and a parent rebuild',
    (tester) async {
      final value = fixture();
      await mount(tester, value, kind: 'post');
      final request = value.state.image(_firstURL);
      final bytes = value.native.complete(0, width: 160, height: 200);
      await pump(tester);
      final size = tester.getSize(_leafImages());
      expect(size.height, 200);
      expect(
        value.state.evictImageFuture(
          _firstURL,
          request,
          revision: value.state.accessRevision,
        ),
        isTrue,
      );
      expect(value.state.imageDimensions(_firstURL), isEmpty);
      await mount(tester, value, kind: 'post');
      expect(tester.getSize(_leafImages()), size);
      expect(_shownBytes(tester), same(bytes));
      expect(value.native.loads, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending post B cannot open its viewer using the completed A thumbnail',
    (tester) async {
      final value = fixture();
      await mount(tester, value, kind: 'post');
      value.native.complete(0);
      await pump(tester);
      final contentLocation = tester.getCenter(_leafImages());
      await mount(tester, value, kind: 'post', url: _secondURL);
      // Tap the content's location rather than a private GestureDetector. A
      // loading placeholder should not navigate or initiate an original fetch.
      await tester.tapAt(contentLocation);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NativeImageViewer), findsNothing);
      expect(
        value.native.loads.where(
          (load) => load.arguments['kind'] == 'original',
        ),
        isEmpty,
      );
      value.native.complete(1);
      await pump(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'post transport failure retry is synchronous and clears the old error while loading',
    (tester) async {
      final value = fixture();
      await mount(tester, value, kind: 'post');
      value.native.fail(0);
      await pump(tester);
      expect(find.text(_retryLabel), findsOneWidget);
      await tester.tap(find.text(_retryLabel));
      await pump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'A setState callback must not return the new image Future.',
      );
      expect(value.native.loads, hasLength(2));
      expect(
        find.text(_retryLabel),
        findsNothing,
        reason: 'The new request must not retain the previous error snapshot.',
      );
      final recovered = value.native.complete(1);
      await pump(tester);
      expect(_shownBytes(tester), same(recovered));
      expect(value.state.message, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'post real decode failure evicts its successful corrupt bytes and retries',
    (tester) async {
      await tester.runAsync(() async {
        final value = fixture();
        await mount(tester, value, kind: 'post');
        final failedFuture = value.state.image(_firstURL);
        value.native.complete(
          0,
          bytes: Uint8List.fromList([0x53, 0x44, 0, 1, 2]),
        );
        await pump(tester);
        expect(await _decode(tester), isFalse);
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Image.memory decode errors must become a local retry state.',
        );
        expect(find.text(_retryLabel), findsOneWidget);
        expect(value.state.image(_firstURL), same(failedFuture));

        await tester.tap(find.text(_retryLabel));
        await pump(tester);
        expect(tester.takeException(), isNull);
        expect(value.native.loads, hasLength(2));
        expect(value.state.image(_firstURL), isNot(same(failedFuture)));
        final recovered = value.native.complete(1);
        await pump(tester);
        expect(await _decode(tester), isTrue);
        await tester.pump();
        expect(_shownBytes(tester), same(recovered));
        expect(find.text(_retryLabel), findsNothing);
        expect(
          value.native.calls.every((call) => call.$1 == 'images.load'),
          isTrue,
        );
        expect(value.state.message, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets(
    'avatar transport failure exposes a local retry and recovers its image',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final value = fixture();
        await mount(tester, value, kind: 'avatar');
        value.native.fail(0);
        await pump(tester);
        expect(find.text('A'), findsOneWidget);
        expect(find.bySemanticsLabel('重试头像'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('重试头像'));
        await pump(tester);
        expect(tester.takeException(), isNull);
        expect(value.native.loads, hasLength(2));
        expect(value.native.loads.last.arguments['kind'], 'avatar');
        final recovered = value.native.complete(1);
        await pump(tester);
        expect(_shownBytes(tester), same(recovered));
        expect(value.state.message, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'failed avatar can be retried from the keyboard without a mouse',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final value = fixture();
        await mount(tester, value, kind: 'avatar');
        value.native.fail(0);
        await pump(tester);
        expect(find.bySemanticsLabel('重试头像'), findsOneWidget);
        final bounds = tester.getRect(find.byKey(_leafKey));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await pump(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pump(tester);
        expect(value.native.loads, hasLength(2));
        expect(value.native.loads.last.arguments['kind'], 'avatar');
        expect(tester.getRect(find.byKey(_leafKey)), bounds);
        final recovered = value.native.complete(1);
        await pump(tester);
        expect(_shownBytes(tester), same(recovered));
        expect(find.bySemanticsLabel('重试头像'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    },
  );

  testWidgets('avatar real decode retry replaces only its own cached Future', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.runAsync(() async {
        final value = fixture();
        await mount(tester, value, kind: 'avatar');
        value.native.complete(
          0,
          bytes: Uint8List.fromList([0x53, 0x44, 0, 5, 6]),
        );
        await pump(tester);
        expect(await _decode(tester), isFalse);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('重试头像'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('重试头像'));
        await pump(tester);
        expect(value.native.loads, hasLength(2));
        value.native.complete(1);
        await pump(tester);
        expect(await _decode(tester), isTrue);
        await tester.pump();

        // A second failing leaf loses cache ownership to another consumer before
        // retry. It must reuse that replacement, including its stored metadata.
        await mount(tester, value, kind: 'avatar', url: _secondURL);
        final retired = value.state.image(_secondURL, kind: 'avatar');
        value.native.complete(
          2,
          bytes: Uint8List.fromList([0x53, 0x44, 0, 7, 8]),
        );
        await pump(tester);
        expect(await _decode(tester), isFalse);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          value.state.evictImageFuture(
            _secondURL,
            retired,
            revision: 0,
            kind: 'avatar',
          ),
          isTrue,
        );
        final replacement = value.state.image(_secondURL, kind: 'avatar');
        final recovered = value.native.complete(3, width: 91, height: 73);
        await replacement;
        await tester.tap(find.bySemanticsLabel('重试头像'));
        await pump(tester);
        expect(value.native.loads, hasLength(4));
        expect(
          value.state.image(_secondURL, kind: 'avatar'),
          same(replacement),
        );
        expect(
          value.state.imageDimensions(_secondURL, kind: 'avatar')['width'],
          91,
        );
        expect(_shownBytes(tester), same(recovered));
        expect(await _decode(tester), isTrue);
        await tester.pump();
        expect(find.bySemanticsLabel('重试头像'), findsNothing);
        expect(
          value.native.calls.every((call) => call.$1 == 'images.load'),
          isTrue,
        );
        expect(value.state.message, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    } finally {
      semantics.dispose();
    }
  });

  for (final replacementPending in [true, false]) {
    testWidgets(
      'post decode retry preserves a newer ${replacementPending ? 'pending' : 'completed'} cache entry',
      (tester) async {
        await tester.runAsync(() async {
          final value = fixture();
          await mount(tester, value, kind: 'post');
          final retired = value.state.image(_firstURL);
          value.native.complete(
            0,
            bytes: Uint8List.fromList([0x53, 0x44, 0, 3, 4]),
          );
          await pump(tester);
          expect(await _decode(tester), isFalse);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text(_retryLabel), findsOneWidget);

          expect(
            value.state.evictImageFuture(_firstURL, retired, revision: 0),
            isTrue,
          );
          final replacement = value.state.image(_firstURL);
          Uint8List? recovered;
          if (!replacementPending) {
            recovered = value.native.complete(1, width: 91, height: 73);
            await replacement;
          }
          await tester.tap(find.text(_retryLabel));
          await pump(tester);
          expect(tester.takeException(), isNull);
          expect(
            value.native.loads,
            hasLength(2),
            reason:
                'An old decode failure cannot evict a newer caller\'s Future.',
          );
          expect(value.state.image(_firstURL), same(replacement));
          if (replacementPending) {
            expect(_leafImages(), findsNothing);
            recovered = value.native.complete(1, width: 91, height: 73);
            await replacement;
            await pump(tester);
          }
          expect(value.state.imageDimensions(_firstURL)['width'], 91);
          expect(value.state.imageDimensions(_firstURL)['height'], 73);
          expect(_shownBytes(tester), same(recovered));
          expect(await _decode(tester), isTrue);
          await tester.pump();
          expect(find.text(_retryLabel), findsNothing);
          expect(
            value.native.calls.every((call) => call.$1 == 'images.load'),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );
  }
}
