import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

class _DraftNative extends NativeClient {
  _DraftNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-draft-store'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final writes = <(JsonMap, Completer<JsonMap>)>[];
  final unexpected = <String>[];

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'bootstrap') {
      return {
        'session': {
          'account': 'signedIn',
          'owner': 100,
          'accessRevision': accessRevision,
        },
      };
    }
    if (method == 'inbox.updateDraft' &&
        arguments['peer'] is int &&
        arguments['content'] is String) {
      final completion = Completer<JsonMap>();
      writes.add((
        {...arguments, 'accessRevision': accessRevision},
        completion,
      ));
      return completion.future;
    }
    unexpected.add(method);
    throw StateError('Draft store must not call $method');
  }

  void changeAccount(int revision) => eventStream.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {'account': 'signedIn', 'owner': 200, 'accessRevision': revision},
  });
}

class _Fixture {
  _Fixture() {
    state = AppState(client: native);
    addTearDown(() async {
      state.dispose();
      for (final write in native.writes) {
        if (!write.$2.isCompleted) write.$2.complete({});
      }
      await _turn();
      await native.eventStream.close();
      expect(native.unexpected, isEmpty);
    });
  }

  final native = _DraftNative();
  late final AppState state;

  void edit(Object owner, String content, {int peer = 20}) {
    state.inboxDrafts.acquire(
      owner,
      revision: state.accessRevision,
      peer: peer,
      nativeContent: 'Native draft',
    );
    state.inboxDrafts.edit(owner, content);
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('quit retries failures after every screen is gone and never forgets the draft', () async {
    final fixture = _Fixture(), owner = Object();
    fixture.edit(owner, 'Retained across page departure');
    final store = fixture.state.inboxDrafts;
    final departingSave = store.flush(revision: 0, peer: 20);
    store.release(owner);
    fixture.native.writes.first.$2.completeError(
      const NativeFailure('disk', 'Fixture local write failure'),
    );
    expect(await departingSave, isFalse);
    expect(
      store.read(revision: 0, peer: 20)!.content,
      'Retained across page departure',
    );

    final firstQuit = fixture.state.flushDrafts();
    expect(fixture.native.writes, hasLength(2));
    fixture.native.writes.last.$2.completeError(
      const NativeFailure('disk', 'Still unavailable'),
    );
    expect(await firstQuit, isFalse);
    expect(store.read(revision: 0, peer: 20)!.dirty, isTrue);

    final retryQuit = fixture.state.flushDrafts();
    expect(fixture.native.writes, hasLength(3));
    expect(
      fixture.native.writes.last.$1['content'],
      'Retained across page departure',
    );
    fixture.native.writes.last.$2.complete({
      'content': 'Retained across page departure',
    });
    expect(await retryQuit, isTrue);
    expect(store.read(revision: 0, peer: 20), isNull);
    expect(await fixture.state.flushDrafts(), isTrue);
    expect(fixture.native.writes, hasLength(3));
  });

  test(
    'quit joins an unmounted peer save without issuing a duplicate write',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.edit(owner, 'Final text from a removed screen');
      final departing = fixture.state.inboxDrafts.flush(revision: 0, peer: 20);
      fixture.state.inboxDrafts.release(owner);
      var done = false;
      final quit = fixture.state.flushDrafts().then((value) {
        done = true;
        return value;
      });
      await _turn();
      expect(done, isFalse);
      expect(fixture.native.writes, hasLength(1));
      fixture.native.writes.single.$2.complete({});
      expect(await departing, isTrue);
      expect(await quit, isTrue);
    },
  );

  test(
    'existing screen flushers and tracked saves finish before orphan drafts',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.edit(owner, 'Orphan pending text');
      fixture.state.inboxDrafts.release(owner);
      final screen = Completer<bool>(), tracked = Completer<bool>();
      fixture.state.registerDraftFlusher('other-editor', () => screen.future);
      fixture.state.trackDraftSave(tracked.future);
      final quit = fixture.state.flushDrafts();
      expect(fixture.native.writes, isEmpty);
      screen.complete(true);
      await _turn();
      expect(fixture.native.writes, isEmpty);
      tracked.complete(true);
      await _turn();
      expect(fixture.native.writes, hasLength(1));
      fixture.native.writes.single.$2.complete({});
      expect(await quit, isTrue);
    },
  );

  test('AppState owns one store and real account events retire pending private text', () async {
    final fixture = _Fixture(), oldOwner = Object(), newOwner = Object();
    await fixture.state.connect();
    fixture.edit(oldOwner, 'Old account private draft');
    final store = fixture.state.inboxDrafts;
    final retired = store.flush(revision: 0, peer: 20);
    fixture.native.changeAccount(1);
    expect(await retired, isFalse);
    expect(fixture.state.inboxDrafts, same(store));
    expect(store.revision, 1);
    expect(store.read(revision: 0, peer: 20), isNull);
    expect(store.read(revision: 1, peer: 20), isNull);
    expect(store.edit(oldOwner, 'Old editor callback'), isFalse);
    fixture.edit(newOwner, 'New account same-peer draft');
    final quit = fixture.state.flushDrafts();
    expect(fixture.native.writes.map((write) => write.$1['accessRevision']), [
      0,
      1,
    ]);
    fixture.native.writes.first.$2.completeError(
      const NativeFailure('disk', 'Retired write failed late'),
    );
    await _turn();
    expect(
      store.read(revision: 1, peer: 20)!.content,
      'New account same-peer draft',
    );
    expect(store.read(revision: 1, peer: 20)!.error, isNull);
    expect(fixture.state.message, isNull);
    fixture.native.writes.last.$2.complete({});
    expect(await quit, isTrue);
  });

  test(
    'the getter activates a revision changed directly by the native client',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.edit(owner, 'Private revision zero text');
      final store = fixture.state.inboxDrafts;
      fixture.native.accessRevision = 1;
      expect(fixture.state.inboxDrafts, same(store));
      expect(store.revision, 1);
      expect(store.read(revision: 0, peer: 20), isNull);
      expect(store.read(revision: 1, peer: 20), isNull);
      expect(store.edit(owner, 'Stale owner text'), isFalse);
      expect(await fixture.state.flushDrafts(), isTrue);
      expect(fixture.native.writes, isEmpty);
    },
  );

  test('an account change during quit rejects the old handshake without saving into the new account', () async {
    final fixture = _Fixture(), owner = Object();
    await fixture.state.connect();
    fixture.edit(owner, 'Old account quit text');
    fixture.state.inboxDrafts.release(owner);
    final quit = fixture.state.flushDrafts();
    fixture.native.changeAccount(1);
    expect(await quit, isFalse);
    expect(await fixture.state.flushDrafts(), isTrue);
    fixture.native.writes.single.$2.complete({});
    await _turn();
    expect(fixture.state.inboxDrafts.read(revision: 1, peer: 20), isNull);
    expect(fixture.native.writes.single.$1['accessRevision'], 0);
    expect(fixture.native.writes, hasLength(1));
  });
}
