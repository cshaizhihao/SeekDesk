import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

class MemoryNative extends NativeClient {
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <String>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'bootstrap') {
      return {
        'session': {'account': 'unconfirmed', 'accessRevision': 0},
        'workspace': {
          'posts': <JsonMap>[],
          'tabs': [
            {
              'id': '17',
              'url': 'https://www.nodeseek.com/post-17-1',
              'title': '已打开的帖子',
            },
          ],
          'selectedTab': '17',
        },
      };
    }
    return await response?.call(method, arguments) ?? {};
  }

  void event(String domain, JsonMap data, {int revision = 0}) {
    eventsController.add({
      'domain': domain,
      'data': data,
      'accessRevision': revision,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryNative native;
  late AppState state;
  setUp(() async {
    native = MemoryNative();
    state = AppState(client: native);
    await state.connect();
  });
  tearDown(() async {
    state.dispose();
    await native.eventsController.close();
  });

  test('bootstrap restores the actual selected reading tab', () {
    expect(state.connecting, false);
    expect(state.workspace.selected?.id, '17');
    expect(state.workspace.selected?.title, '已打开的帖子');
    expect(state.connectionError, isNull);
  });

  test('reader page cache is bounded and preserves separate pages', () async {
    native.response = (method, arguments) async => {
      'url': arguments['url'],
      'page': int.parse(arguments['url'].toString().split('-').last),
    };
    for (var page = 1; page <= 10; page++) {
      await state.loadReader('https://www.nodeseek.com/post-17-$page');
    }
    expect(state.readers.length, 8);
    expect(state.readerFor('https://www.nodeseek.com/post-17-1'), isEmpty);
    expect(
      state.readerFor('https://www.nodeseek.com/post-17-10#7')['page'],
      10,
    );
  });

  test(
    'identity revision clears private snapshots and rejects old events',
    () async {
      native.response = (_, arguments) async => {
        'url': arguments['url'],
        'draft': 'old account',
      };
      await state.loadReader('https://www.nodeseek.com/post-17-1');
      native.event('inbox', {
        'kind': 'messages',
        'items': [
          {'preview': 'private'},
        ],
      });
      native.event('discussion', {'content': 'private draft'});
      native.event('session', {
        'account': 'signedIn',
        'owner': 99,
        'accessRevision': 1,
      }, revision: 1);
      expect(state.readers, isEmpty);
      expect(state.domain('reader'), isEmpty);
      expect(state.domain('inbox'), isEmpty);
      expect(state.domain('discussion'), isEmpty);
      native.event('inbox', {
        'kind': 'messages',
        'items': [
          {'preview': 'stale'},
        ],
      });
      expect(state.domain('inbox'), isEmpty);
      expect(state.accessRevision, 1);
    },
  );

  test(
    'late old-account method reply never repopulates private content',
    () async {
      final delayed = Completer<JsonMap>();
      native.response = (_, _) => delayed.future;
      final loading = state.act('inbox.load', {'kind': 'messages'}, 'inbox');
      native.event('session', {
        'account': 'signedIn',
        'owner': 99,
        'accessRevision': 1,
      }, revision: 1);
      delayed.complete({
        'kind': 'messages',
        'items': [
          {'preview': 'old account'},
        ],
        'accessRevision': 0,
      });
      expect(await loading, isNull);
      expect(state.domain('inbox'), isEmpty);
    },
  );

  test(
    'account discovery may return a snapshot for the new current revision',
    () async {
      final delayed = Completer<JsonMap>();
      native.response = (_, _) => delayed.future;
      final loading = state.act('inbox.load', {'kind': 'mentions'}, 'inbox');
      native.event('session', {
        'account': 'signedIn',
        'owner': 99,
        'accessRevision': 1,
      }, revision: 1);
      delayed.complete({
        'kind': 'mentions',
        'items': <JsonMap>[],
        'accessRevision': 1,
      });
      expect(await loading, isNotNull);
      expect(state.domain('inbox')['kind'], 'mentions');
    },
  );

  test(
    'image cache shares requests but separates avatars and account identities',
    () async {
      native.response = (_, _) async => {
        'bytes': Uint8List.fromList([1, 2, 3]),
      };
      final first = state.image('https://www.nodeseek.com/avatar/99');
      final second = state.image('https://www.nodeseek.com/avatar/99');
      expect(identical(first, second), true);
      await first;
      await state.image('https://www.nodeseek.com/avatar/99', kind: 'avatar');
      expect(native.calls.where((value) => value == 'images.load').length, 2);
      native.event('session', {
        'account': 'signedOut',
        'accessRevision': 1,
      }, revision: 1);
      await state.image('https://www.nodeseek.com/avatar/99');
      expect(native.calls.where((value) => value == 'images.load').length, 3);
    },
  );

  test('failed image requests can be retried', () async {
    var attempts = 0;
    native.response = (_, _) async {
      attempts++;
      if (attempts == 1) throw const NativeFailure('network', 'retry');
      return {
        'bytes': Uint8List.fromList([1]),
      };
    };
    await expectLater(
      state.image('https://example.org/image.png'),
      throwsA(isA<NativeFailure>()),
    );
    expect(await state.image('https://example.org/image.png'), [1]);
    expect(attempts, 2);
  });
}
