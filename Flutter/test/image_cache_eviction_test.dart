import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const _url = 'https://www.nodeseek.com/static/image/sticker/ac/01.png';

class _ImageNative extends NativeClient {
  final calls = <JsonMap>[];
  final recordedMethods = <String>[];
  final loads = <Completer<JsonMap>>[];
  Object? synchronousError;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    if (method != 'images.load' && method != 'images.release') {
      throw StateError('Unexpected native operation: $method');
    }
    recordedMethods.add(method);
    calls.add({...arguments, 'accessRevision': accessRevision});
    if (method == 'images.release') {
      return Future<JsonMap>.value({'released': true});
    }
    final error = synchronousError;
    synchronousError = null;
    if (error != null) throw error;
    final completion = Completer<JsonMap>();
    loads.add(completion);
    return completion.future;
  }

  void complete(int index, int width, {int? byteCount}) =>
      loads[index].complete({
        'bytes': byteCount == null
            ? Uint8List.fromList([width])
            : Uint8List(byteCount),
        'width': width,
        'height': width,
        'originalWidth': width,
        'originalHeight': width,
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ImageNative native;
  late AppState state;
  late bool disposed;

  void disposeState() {
    if (disposed) return;
    disposed = true;
    state.dispose();
  }

  setUp(() {
    native = _ImageNative();
    state = AppState(client: native);
    disposed = false;
  });
  tearDown(disposeState);

  Future<List<(String, Future<Uint8List>)>> fillCache() async {
    final entries = <(String, Future<Uint8List>)>[];
    for (var i = 0; i < 48; i++) {
      final url = '$_url?fixture=$i';
      final loading = state.image(url);
      native.complete(native.loads.length - 1, 1);
      await loading;
      entries.add((url, loading));
    }
    return entries;
  }

  Matcher failure(String code) =>
      throwsA(isA<NativeFailure>().having((error) => error.code, 'code', code));

  test(
    'exact completed image eviction clears metadata and permits one fresh read',
    () async {
      var notifications = 0;
      state.addListener(() => notifications++);
      state.message = 'Retained message';
      final first = state.image(_url);
      native.complete(0, 12);
      await first;
      expect(state.imageDimensions(_url)['width'], 12);

      expect(state.evictImageFuture(_url, first, revision: 0), isTrue);
      expect(state.imageDimensions(_url), isEmpty);
      expect(native.calls, hasLength(1));
      expect(state.evictImageFuture(_url, first, revision: 0), isFalse);
      final fresh = state.image(_url);
      expect(identical(first, fresh), isFalse);
      expect(native.calls, hasLength(2));
      expect(native.calls.last, {
        'url': _url,
        'kind': 'post',
        'accessRevision': 0,
      });
      native.complete(1, 24);
      await fresh;
      expect(state.imageDimensions(_url)['width'], 24);
      expect(identical(state.image(_url), fresh), isTrue);
      expect(native.calls, hasLength(2));
      expect(state.message, 'Retained message');
      expect(state.pending, isEmpty);
      expect(notifications, 0);
    },
  );

  test(
    'an old future or a different image kind cannot evict the current request',
    () async {
      final old = state.image(_url);
      native.complete(0, 12);
      await old;
      expect(state.evictImageFuture(_url, old, revision: 0), isTrue);

      final fresh = state.image(_url);
      expect(
        state.evictImageFuture(_url, fresh, revision: 0),
        isFalse,
        reason: 'A decode retry must not evict a still-running fetch.',
      );
      expect(state.evictImageFuture(_url, old, revision: 0), isFalse);
      expect(identical(state.image(_url), fresh), isTrue);
      expect(native.calls, hasLength(2));
      native.complete(1, 24);
      await fresh;
      expect(state.evictImageFuture(_url, old, revision: 0), isFalse);
      expect(state.imageDimensions(_url)['width'], 24);

      final original = state.image(_url, kind: 'original');
      native.complete(2, 48);
      await original;
      expect(
        state.evictImageFuture(_url, fresh, revision: 0, kind: 'original'),
        isFalse,
      );
      expect(state.evictImageFuture(_url, original, revision: 0), isFalse);
      expect(identical(state.image(_url, kind: 'original'), original), isTrue);
      expect(
        state.evictImageFuture(_url, original, revision: 0, kind: 'original'),
        isTrue,
      );
      expect(state.imageDimensions(_url, kind: 'original'), isEmpty);
      expect(identical(state.image(_url), fresh), isTrue);
      expect(state.imageDimensions(_url)['width'], 24);
      expect(native.calls, hasLength(3));
    },
  );

  test(
    'account changes reject eviction and disposal clears all image metadata',
    () async {
      final old = state.image(_url);
      native.complete(0, 12);
      await old;
      native.accessRevision = 1;
      expect(state.evictImageFuture(_url, old, revision: 0), isFalse);

      final current = state.image(_url);
      native.complete(1, 24);
      await current;
      expect(state.evictImageFuture(_url, old, revision: 1), isFalse);
      expect(state.evictImageFuture(_url, current, revision: 0), isFalse);
      expect(identical(state.image(_url), current), isTrue);
      expect(state.imageDimensions(_url)['width'], 24);
      expect(native.calls, hasLength(2));

      disposeState();
      expect(state.evictImageFuture(_url, current, revision: 1), isFalse);
      expect(state.imageDimensions(_url), isEmpty);
      expect(native.calls, hasLength(2));
    },
  );

  for (final oldSucceeds in [true, false]) {
    for (final newFinished in [false, true]) {
      test(
        'LRU-retired ${oldSucceeds ? 'success' : 'failure'} cannot change a '
        '${newFinished ? 'completed' : 'pending'} successor for the same URL',
        () async {
          final old = state.image(_url);
          await fillCache();
          final fresh = state.image(_url);
          expect(identical(old, fresh), isFalse);
          expect(native.loads, hasLength(50));
          if (newFinished) {
            native.complete(49, 24);
            await fresh;
          }

          if (oldSucceeds) {
            native.complete(0, 12);
            expect(await old, [12]);
          } else {
            final rejected = expectLater(old, failure('fixture'));
            native.loads.first.completeError(
              const NativeFailure('fixture', 'Retired image request failed'),
            );
            await rejected;
          }
          expect(
            state.imageDimensions(_url),
            newFinished
                ? {
                    'width': 24,
                    'height': 24,
                    'originalWidth': 24,
                    'originalHeight': 24,
                  }
                : isEmpty,
          );
          expect(identical(state.image(_url), fresh), isTrue);
          expect(native.loads, hasLength(50));

          if (!newFinished) {
            native.complete(49, 24);
            await fresh;
          }
          expect(state.imageDimensions(_url)['width'], 24);
          expect(identical(state.image(_url), fresh), isTrue);
          expect(state.message, isNull);
        },
      );
    }
  }

  test(
    'a retired oversized result cannot charge or evict the current cache',
    () async {
      final old = state.image(_url);
      final fillers = await fillCache();
      final fresh = state.image(_url);
      native.complete(49, 24);
      await fresh;

      const oversizedLength = 24 * 1024 * 1024 + 1;
      native.complete(0, 12, byteCount: oversizedLength);
      expect((await old).length, oversizedLength);
      expect(state.imageDimensions(_url)['width'], 24);
      // Reopening the original URL evicted fillers.first; every other entry
      // still belongs to the cache and must survive the retired byte payload.
      for (final (url, expected) in fillers.skip(1)) {
        expect(state.imageDimensions(url)['width'], 1);
        expect(identical(state.image(url), expected), isTrue);
      }
      expect(identical(state.image(_url), fresh), isTrue);
      expect(native.loads, hasLength(50));
    },
  );

  test('an oversized original leaves existing thumbnails cached', () async {
    final retained = <(String, Future<Uint8List>)>[];
    for (var index = 0; index < 3; index++) {
      final url = '$_url?thumbnail=$index';
      final future = state.image(url);
      native.complete(index, index + 1);
      await future;
      retained.add((url, future));
    }
    const oversizedLength = 24 * 1024 * 1024 + 1;
    final original = state.image(_url, kind: 'original');
    native.complete(3, 4096, byteCount: oversizedLength);
    expect((await original).length, oversizedLength);
    expect(state.imageDimensions(_url, kind: 'original'), isEmpty);

    for (var index = 0; index < retained.length; index++) {
      final (url, expected) = retained[index];
      expect(state.imageDimensions(url)['width'], index + 1);
      expect(identical(state.image(url), expected), isTrue);
    }
    expect(native.loads, hasLength(4));
  });

  test(
    'byte budget respects LRU access and credits explicit release',
    () async {
      const halfBudget = 12 * 1024 * 1024;
      const firstURL = '$_url?budget=first';
      const secondURL = '$_url?budget=second';
      const thirdURL = '$_url?budget=third';
      final first = state.image(firstURL);
      native.complete(0, 11, byteCount: halfBudget);
      await first;
      final second = state.image(secondURL);
      native.complete(1, 22, byteCount: halfBudget);
      await second;
      expect(identical(state.image(firstURL), first), isTrue);

      final third = state.image(thirdURL);
      native.complete(2, 33);
      await third;
      expect(state.imageDimensions(secondURL), isEmpty);
      expect(identical(state.image(firstURL), first), isTrue);
      expect(identical(state.image(thirdURL), third), isTrue);

      await state.releaseImage(firstURL, kind: 'post');
      final replacement = state.image(firstURL);
      native.complete(3, 44, byteCount: halfBudget);
      await replacement;
      expect(state.imageDimensions(thirdURL)['width'], 33);
      expect(identical(state.image(thirdURL), third), isTrue);
      expect(identical(state.image(firstURL), replacement), isTrue);
      expect(native.loads, hasLength(4));
    },
  );

  for (final nativeSucceeds in [true, false]) {
    test(
      'disposal rejects a pending native ${nativeSucceeds ? 'success' : 'failure'} '
      'and prevents late metadata',
      () async {
        final loading = state.image(_url);
        final rejected = expectLater(loading, failure('disposed'));
        disposeState();
        if (nativeSucceeds) {
          native.complete(0, 12);
        } else {
          native.loads.single.completeError(
            const NativeFailure('fixture', 'Late native provider failure'),
          );
        }
        await rejected;
        expect(state.imageDimensions(_url), isEmpty);
        expect(native.calls, hasLength(1));
        expect(state.message, isNull);
      },
    );
  }

  test('disposed state rejects a cached URL without calling native', () async {
    final cached = state.image(_url);
    native.complete(0, 12);
    await cached;
    expect(identical(state.image(_url), cached), isTrue);
    disposeState();

    final cachedRead = state.image(_url);
    if (native.loads.length > 1) native.complete(1, 24);
    await expectLater(cachedRead, failure('disposed'));
    expect(identical(cachedRead, cached), isFalse);
    expect(state.imageDimensions(_url), isEmpty);
    expect(native.calls, hasLength(1));
  });

  test('disposed state rejects a new URL without calling native', () async {
    disposeState();
    final loading = state.image('$_url?new-after-dispose');
    // Complete an incorrectly started request so the unfixed baseline fails
    // the rejection assertion promptly instead of waiting on the fake forever.
    if (native.loads.isNotEmpty) native.complete(0, 12);
    await expectLater(loading, failure('disposed'));
    expect(native.calls, isEmpty);
    expect(state.imageDimensions('$_url?new-after-dispose'), isEmpty);
  });

  for (final oldSucceeds in [true, false]) {
    test('release followed by reopening protects the new image from an old '
        '${oldSucceeds ? 'success' : 'failure'}', () async {
      final old = state.image(_url, kind: 'original');
      await state.releaseImage(_url);
      final fresh = state.image(_url, kind: 'original');
      expect(identical(old, fresh), isFalse);
      expect(native.recordedMethods, [
        'images.load',
        'images.release',
        'images.load',
      ]);
      native.complete(1, 24);
      await fresh;

      if (oldSucceeds) {
        native.complete(0, 12);
        expect(await old, [12]);
      } else {
        final rejected = expectLater(old, failure('fixture'));
        native.loads.first.completeError(
          const NativeFailure('fixture', 'Released image request failed'),
        );
        await rejected;
      }
      expect(state.imageDimensions(_url, kind: 'original')['width'], 24);
      expect(identical(state.image(_url, kind: 'original'), fresh), isTrue);
      expect(native.loads, hasLength(2));
      expect(native.calls, hasLength(3));
    });
  }

  test('release after disposal still clears native storage without reviving metadata', () async {
    final original = state.image(_url, kind: 'original');
    native.complete(0, 12);
    await original;
    disposeState();

    await state.releaseImage(_url);
    expect(native.recordedMethods, ['images.load', 'images.release']);
    expect(native.calls, hasLength(2));
    expect(native.loads, hasLength(1));
    expect(state.imageDimensions(_url, kind: 'original'), isEmpty);
  });

  for (final oldSucceeds in [true, false]) {
    test(
      'an old account native ${oldSucceeds ? 'success' : 'failure'} rejects as '
      'stale without affecting the current account cache',
      () async {
        final old = state.image(_url);
        final rejected = expectLater(old, failure('stale'));
        native.accessRevision = 1;
        final current = state.image(_url);
        expect(identical(old, current), isFalse);
        native.complete(1, 24);
        await current;

        if (oldSucceeds) {
          native.complete(0, 12);
        } else {
          native.loads.first.completeError(
            const NativeFailure('fixture', 'Old account provider failure'),
          );
        }
        await rejected;
        expect(state.imageDimensions(_url)['width'], 24);
        expect(identical(state.image(_url), current), isTrue);
        expect(native.calls, hasLength(2));
        expect(state.message, isNull);
      },
    );
  }

  test(
    'a synchronous native throw leaves no poisoned Future and permits retry',
    () async {
      native.synchronousError = const NativeFailure(
        'fixture',
        'Synchronous failure',
      );
      final failed = state.image(_url);
      await expectLater(failed, failure('fixture'));
      expect(native.calls, hasLength(1));
      expect(native.loads, isEmpty);
      expect(state.imageDimensions(_url), isEmpty);
      expect(state.message, isNull);

      final retry = state.image(_url);
      expect(identical(failed, retry), isFalse);
      expect(native.calls, hasLength(2));
      expect(native.loads, hasLength(1));
      expect(identical(state.image(_url), retry), isTrue);
      native.complete(0, 24);
      expect(await retry, [24]);
      expect(state.imageDimensions(_url)['width'], 24);
      expect(identical(state.image(_url), retry), isTrue);
      expect(native.calls, hasLength(2));
    },
  );
}
