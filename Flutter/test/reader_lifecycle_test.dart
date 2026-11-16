import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const readerURL = 'https://www.nodeseek.com/post-17-1';

JsonMap readerWorkspace({bool closed = false}) => {
  'tabs': closed
      ? <JsonMap>[]
      : [
          {'id': '17', 'url': readerURL, 'title': 'Fixture'},
        ],
  'closedTabs': closed
      ? [
          {'id': '17', 'url': readerURL, 'title': 'Fixture'},
        ]
      : <JsonMap>[],
  'selectedTab': closed ? '' : '17',
  'showReader': !closed,
};

JsonMap loadedReader(String title, {int revision = 0}) => {
  'url': readerURL,
  'loading': false,
  'accessRevision': revision,
  'thread': {'title': title},
};

class ReaderLifecycleNative extends NativeClient {
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final loads = <Completer<JsonMap>>[];

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    switch (method) {
      case 'bootstrap':
        return {
          'session': {'account': 'signedIn', 'accessRevision': 0},
          'workspace': readerWorkspace(),
        };
      case 'reader.load':
        final response = Completer<JsonMap>();
        loads.add(response);
        return response.future;
      case 'reader.closeAll':
        return readerWorkspace(closed: true);
      case 'reader.reopen':
        return readerWorkspace();
    }
    return {};
  }

  void emit(String domain, JsonMap data, {int revision = 0}) {
    eventsController.add({
      'domain': domain,
      'data': data,
      'accessRevision': revision,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderLifecycleNative native;
  late AppState state;

  setUp(() async {
    native = ReaderLifecycleNative();
    state = AppState(client: native);
    await state.connect();
  });
  tearDown(() async {
    state.dispose();
    for (final response in native.loads) {
      if (!response.isCompleted) {
        response.completeError(
          const NativeFailure('cancelled', 'fixture cancellation'),
        );
      }
    }
    await Future<void>.delayed(Duration.zero);
    await native.eventsController.close();
  });

  test('cancelled load after close all cannot recreate an error cache before reopening', () async {
    final old = state.loadReader(readerURL);
    expect(await state.closeAllTopics(), isTrue);
    native.loads.first.completeError(
      const NativeFailure('cancelled', 'cancelled by close all'),
    );
    await old;
    expect(state.readerFor(readerURL), isEmpty);
    expect(state.domain('reader'), isEmpty);
    expect(state.message, isNull);

    expect(await state.reopenTopic('17'), isTrue);
    expect(native.loads, hasLength(2));
    final reopened = state.loadReader(readerURL);
    native.loads.last.complete(loadedReader('Reopened'));
    await reopened;
    expect(jsonMap(state.readerFor(readerURL)['thread'])['title'], 'Reopened');
  });

  test('early reopen starts a new request and rejects old finally and uncorrelated events', () async {
    final old = state.loadReader(readerURL);
    expect(await state.closeAllTopics(), isTrue);
    expect(await state.reopenTopic('17'), isTrue);
    expect(native.loads, hasLength(2));
    final reopened = state.loadReader(readerURL);

    native.emit('reader', loadedReader('Stale queued event'));
    expect(
      jsonMap(state.readerFor(readerURL)['thread'])['title'],
      isNot('Stale queued event'),
    );
    native.loads.first.completeError(
      const NativeFailure('cancelled', 'old cancellation'),
    );
    await old;
    final follower = state.loadReader(readerURL);
    expect(native.loads, hasLength(2));
    native.loads.last.complete(loadedReader('Fresh result'));
    await reopened;
    await follower;
    native.emit('reader', loadedReader('Late stale event'));
    expect(
      jsonMap(state.readerFor(readerURL)['thread'])['title'],
      'Fresh result',
    );
    expect(state.message, isNull);
  });

  test(
    'old successful response after close all cannot repopulate the cache',
    () async {
      final old = state.loadReader(readerURL);
      expect(await state.closeAllTopics(), isTrue);
      native.loads.first.complete(loadedReader('Closed request'));
      await old;
      expect(state.readerFor(readerURL), isEmpty);
      expect(state.domain('reader'), isEmpty);
    },
  );

  test('account discovery accepts the current-revision retry result', () async {
    final loading = state.loadReader(readerURL);
    native.emit('session', {
      'account': 'signedIn',
      'owner': 99,
      'accessRevision': 1,
    }, revision: 1);
    expect(state.readerFor(readerURL), isEmpty);
    expect(state.domain('reader'), isEmpty);
    native.loads.first.complete(
      loadedReader('Discovered account', revision: 1),
    );
    await loading;
    expect(
      jsonMap(state.readerFor(readerURL)['thread'])['title'],
      'Discovered account',
    );
    expect(state.accessRevision, 1);
  });

  test('refresh keeps restoration metadata and cancellation restores ready content', () async {
    final previous = {
      ...loadedReader('Retained content'),
      'scrollOffset': 1450.0,
      'anchor': 'floor-7',
      'draft': 'retained local draft',
      'error': 'previous refresh warning',
    };
    final first = state.loadReader(readerURL);
    native.loads.first.complete(previous);
    await first;
    final refreshing = state.loadReader(readerURL, force: true);
    final loading = state.readerFor(readerURL);
    expect(loading['loading'], isTrue);
    expect(loading['scrollOffset'], 1450.0);
    expect(loading['anchor'], 'floor-7');
    expect(loading['draft'], 'retained local draft');
    expect(loading['error'], isNull);
    native.loads.last.completeError(
      const NativeFailure('cancelled', 'fixture cancellation'),
    );
    await refreshing;
    expect(state.readerFor(readerURL), previous);
    expect(state.message, isNull);
  });

  test('a newer account request owns the URL even if the old retry returns the new revision', () async {
    final old = state.loadReader(readerURL);
    native.emit('session', {
      'account': 'signedIn',
      'owner': 99,
      'accessRevision': 1,
    }, revision: 1);
    final fresh = state.loadReader(readerURL);
    expect(native.loads, hasLength(2));
    native.loads.first.complete(loadedReader('Old retry', revision: 1));
    await old;
    expect(
      jsonMap(state.readerFor(readerURL)['thread'])['title'],
      isNot('Old retry'),
    );
    native.loads.last.complete(loadedReader('New request', revision: 1));
    await fresh;
    expect(
      jsonMap(state.readerFor(readerURL)['thread'])['title'],
      'New request',
    );
  });
}
