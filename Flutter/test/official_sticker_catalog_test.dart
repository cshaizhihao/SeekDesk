import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

JsonMap _catalog(String code) => {
  'packs': [
    {
      'id': 'ac',
      'title': 'AC 娘',
      'items': [
        {
          'id': code,
          'label': code,
          'url':
              'https://www.nodeseek.com/static/image/sticker/ac/${code.substring(2)}.png',
          'insertion': ' :$code: ',
        },
      ],
    },
  ],
};

class _StickerNative extends NativeClient {
  final eventController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final loads = <Completer<JsonMap>>[];

  @override
  Stream<JsonMap> get snapshots => eventController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments}));
    if (method == 'bootstrap') {
      return Future<JsonMap>.value({
        'session': {'account': 'signedIn', 'accessRevision': accessRevision},
      });
    }
    if (method == 'stickers.list') {
      final completion = Completer<JsonMap>();
      loads.add(completion);
      return completion.future;
    }
    throw StateError('Unexpected native operation: $method');
  }

  void changeAccount(int revision) {
    eventController.add({
      'domain': 'session',
      'accessRevision': revision,
      'data': {
        'account': 'signedIn',
        'owner': revision + 1,
        'accessRevision': revision,
      },
    });
  }
}

Matcher _failure(String code) =>
    throwsA(isA<NativeFailure>().having((error) => error.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _StickerNative native;
  late AppState state;
  late bool disposed;

  void disposeState() {
    if (disposed) return;
    disposed = true;
    state.dispose();
  }

  setUp(() async {
    native = _StickerNative();
    state = AppState(client: native);
    disposed = false;
    await state.connect();
    native.calls.clear();
  });

  tearDown(() async {
    disposeState();
    await native.eventController.close();
  });

  test(
    'concurrent previews share one metadata request and a success cache',
    () async {
      var notifications = 0;
      state.addListener(() => notifications++);
      state.message = 'Unrelated message';
      state.pending.add('unrelated');
      state.domains['fixture'] = {'retained': true};

      final first = state.loadOfficialStickers();
      final second = state.loadOfficialStickers();
      expect(identical(first, second), isTrue);
      expect(native.calls.map((call) => call.$1), ['stickers.list']);
      expect(native.calls.single.$2, isEmpty);
      expect(native.loads, hasLength(1));
      native.loads.single.complete(_catalog('ac01'));
      final catalog = await first;
      expect(identical(await second, catalog), isTrue);
      expect(catalog.byCode, hasLength(1));
      expect(identical(await state.loadOfficialStickers(), catalog), isTrue);
      expect(native.loads, hasLength(1));
      expect(state.pending, {'unrelated'});
      expect(state.message, 'Unrelated message');
      expect(state.domain('fixture'), {'retained': true});
      expect(notifications, 0);
    },
  );

  test('an empty successful catalog is cached', () async {
    final loading = state.loadOfficialStickers();
    native.loads.single.complete({'packs': <JsonMap>[]});
    final empty = await loading;
    expect(empty.byCode, isEmpty);
    expect(identical(await state.loadOfficialStickers(), empty), isTrue);
    expect(native.loads, hasLength(1));
  });

  test('a shared failure stays local and an explicit call retries', () async {
    var notifications = 0;
    state.addListener(() => notifications++);
    state.message = 'Existing message';
    state.pending.add('existing');
    final first = state.loadOfficialStickers();
    final second = state.loadOfficialStickers();
    final failedFirst = expectLater(first, _failure('fixture'));
    final failedSecond = expectLater(second, _failure('fixture'));
    native.loads.single.completeError(
      const NativeFailure('fixture', 'Local catalog unavailable'),
    );
    await Future.wait([failedFirst, failedSecond]);
    expect(native.loads, hasLength(1));
    expect(state.message, 'Existing message');
    expect(state.pending, {'existing'});
    expect(notifications, 0);

    final retry = state.loadOfficialStickers();
    expect(identical(first, retry), isFalse);
    expect(native.loads, hasLength(2));
    native.loads.last.complete(_catalog('ac02'));
    final catalog = await retry;
    expect(catalog.byCode, hasLength(1));
    expect(identical(await state.loadOfficialStickers(), catalog), isTrue);
    expect(notifications, 0);
  });

  test(
    'old success and finally cannot clear the next account request',
    () async {
      final old = state.loadOfficialStickers();
      final oldFailure = expectLater(old, _failure('stale'));
      native.changeAccount(1);
      final current = state.loadOfficialStickers();
      expect(native.loads, hasLength(2));
      native.loads.first.complete(_catalog('ac01'));
      await oldFailure;
      final follower = state.loadOfficialStickers();
      expect(identical(current, follower), isTrue);
      expect(native.loads, hasLength(2));

      native.loads.last.complete(_catalog('ac02'));
      final catalog = await current;
      expect(identical(await follower, catalog), isTrue);
      expect(identical(await state.loadOfficialStickers(), catalog), isTrue);
      expect(native.loads, hasLength(2));
      expect(state.message, isNull);
    },
  );

  test('old failure after a new success cannot erase the new cache', () async {
    final old = state.loadOfficialStickers();
    final oldFailure = expectLater(old, _failure('stale'));
    native.changeAccount(1);
    final current = state.loadOfficialStickers();
    native.loads.last.complete(_catalog('ac02'));
    final catalog = await current;
    native.loads.first.completeError(
      const NativeFailure('fixture', 'Old catalog failure'),
    );
    await oldFailure;
    expect(identical(await state.loadOfficialStickers(), catalog), isTrue);
    expect(native.loads, hasLength(2));
    expect(state.message, isNull);
  });

  test('an account event invalidates the successful cache', () async {
    final old = state.loadOfficialStickers();
    native.loads.single.complete(_catalog('ac01'));
    final oldCatalog = await old;
    native.changeAccount(1);
    final current = state.loadOfficialStickers();
    expect(native.loads, hasLength(2));
    native.loads.last.complete(_catalog('ac02'));
    final currentCatalog = await current;
    expect(identical(currentCatalog, oldCatalog), isFalse);
    expect(
      identical(await state.loadOfficialStickers(), currentCatalog),
      isTrue,
    );
  });

  test(
    'a direct native revision change also invalidates pending ownership',
    () async {
      final old = state.loadOfficialStickers();
      final oldFailure = expectLater(old, _failure('stale'));
      native.accessRevision = 1;
      final current = state.loadOfficialStickers();
      native.loads.first.complete(_catalog('ac01'));
      await oldFailure;
      expect(identical(state.loadOfficialStickers(), current), isTrue);
      expect(native.loads, hasLength(2));
      native.loads.last.complete(_catalog('ac02'));
      final catalog = await current;
      expect(identical(await state.loadOfficialStickers(), catalog), isTrue);
    },
  );

  test('a cached delivery rejects an intervening account change', () async {
    final initial = state.loadOfficialStickers();
    native.loads.single.complete(_catalog('ac01'));
    await initial;
    final cached = state.loadOfficialStickers();
    final rejected = expectLater(cached, _failure('stale'));
    native.changeAccount(1);
    await rejected;
    expect(native.loads, hasLength(1));
    expect(state.message, isNull);
  });

  test(
    'disposal rejects a pending result and prevents any later native call',
    () async {
      final pending = state.loadOfficialStickers();
      final rejected = expectLater(pending, _failure('disposed'));
      disposeState();
      native.loads.single.complete(_catalog('ac01'));
      await rejected;
      await expectLater(state.loadOfficialStickers(), _failure('disposed'));
      expect(native.loads, hasLength(1));
      expect(native.calls.map((call) => call.$1), ['stickers.list']);
      expect(state.message, isNull);
    },
  );

  test('disposal also rejects an already queued cached delivery', () async {
    final initial = state.loadOfficialStickers();
    native.loads.single.complete(_catalog('ac01'));
    await initial;
    final cached = state.loadOfficialStickers();
    final rejected = expectLater(cached, _failure('disposed'));
    disposeState();
    await rejected;
    await expectLater(state.loadOfficialStickers(), _failure('disposed'));
    expect(native.loads, hasLength(1));
  });

  test(
    'disposal before the first read does not contact native services',
    () async {
      disposeState();
      await expectLater(state.loadOfficialStickers(), _failure('disposed'));
      expect(native.calls, isEmpty);
    },
  );

  test(
    'catalog requests and caches belong to each AppState instance',
    () async {
      final otherNative = _StickerNative();
      final other = AppState(client: otherNative);
      try {
        final first = state.loadOfficialStickers();
        final second = other.loadOfficialStickers();
        expect(identical(first, second), isFalse);
        expect(native.loads, hasLength(1));
        expect(otherNative.loads, hasLength(1));
        native.loads.single.complete(_catalog('ac01'));
        otherNative.loads.single.complete(_catalog('ac02'));
        final firstCatalog = await first;
        final secondCatalog = await second;
        expect(identical(firstCatalog, secondCatalog), isFalse);
        expect(
          identical(await state.loadOfficialStickers(), firstCatalog),
          isTrue,
        );
        expect(
          identical(await other.loadOfficialStickers(), secondCatalog),
          isTrue,
        );
        expect(native.loads, hasLength(1));
        expect(otherNative.loads, hasLength(1));
      } finally {
        other.dispose();
        await otherNative.eventController.close();
      }
    },
  );
}
