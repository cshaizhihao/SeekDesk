import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/state/inbox_drafts.dart';

class _Write {
  _Write(this.revision, this.peer, this.content, this.markdown);
  final int revision, peer;
  final String content;
  final bool markdown;
  final completion = Completer<void>();
}

class _Fixture {
  _Fixture() {
    store = InboxDraftStore(
      write:
          ({
            required revision,
            required peer,
            required content,
            required markdown,
          }) {
            final call = _Write(revision, peer, content, markdown);
            writes.add(call);
            return call.completion.future;
          },
    )..activate(0);
    addTearDown(() async {
      store.dispose();
      for (final call in writes) {
        if (!call.completion.isCompleted) call.completion.complete();
      }
      await _turn();
    });
  }

  late final InboxDraftStore store;
  final writes = <_Write>[];

  InboxDraftSnapshot bind(
    Object owner, {
    int peer = 20,
    String text = 'Disk draft',
  }) => store.acquire(
    owner,
    revision: store.revision,
    peer: peer,
    nativeContent: text,
  )!;

  InboxDraftSnapshot? read(int peer) =>
      store.read(revision: store.revision, peer: peer);
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('format mode shares the draft version without changing text', () async {
    final fixture = _Fixture(), first = Object(), second = Object();
    final initial = fixture.store.acquire(
      first,
      revision: 0,
      peer: 20,
      nativeContent: '**literal text**',
      nativeMarkdown: false,
    )!;
    expect(initial.markdown, isFalse);
    final attached = fixture.store.acquire(
      second,
      revision: 0,
      peer: 20,
      nativeContent: 'Stale',
      nativeMarkdown: true,
    )!;
    expect(attached.markdown, isFalse);
    expect(fixture.store.edit(second, initial.content, markdown: true), isTrue);
    final changed = fixture.read(20)!;
    expect(changed.content, initial.content);
    expect(changed.markdown, isTrue);
    expect(changed.version, greaterThan(initial.version));
    final saving = fixture.store.flush(revision: 0, peer: 20);
    expect(fixture.writes.single.markdown, isTrue);
    fixture.writes.single.completion.complete();
    expect(await saving, isTrue);
    expect(fixture.read(20)!.dirty, isFalse);
  });

  test(
    'format changes during a write drain atomically with latest text',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner);
      fixture.store.edit(owner, 'First text', markdown: false);
      final saving = fixture.store.flush(revision: 0, peer: 20);
      fixture.store.edit(owner, 'Later text', markdown: true);
      expect(fixture.writes.single.content, 'First text');
      expect(fixture.writes.single.markdown, isFalse);
      fixture.writes.single.completion.complete();
      await _turn();
      expect(fixture.writes.last.content, 'Later text');
      expect(fixture.writes.last.markdown, isTrue);
      fixture.writes.last.completion.complete();
      expect(await saving, isTrue);
    },
  );

  test(
    'failed mode-only save survives disposal and stale native reseed',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner);
      fixture.store.edit(owner, 'Disk draft', markdown: false);
      final saving = fixture.store.flush(revision: 0, peer: 20);
      fixture.store.release(owner);
      fixture.writes.single.completion.completeError(
        StateError('Disk unavailable'),
      );
      expect(await saving, isFalse);
      final reopened = fixture.store.acquire(
        Object(),
        revision: 0,
        peer: 20,
        nativeContent: 'Stale native',
        nativeMarkdown: true,
      )!;
      expect(reopened.content, 'Disk draft');
      expect(reopened.markdown, isFalse);
      expect(reopened.dirty, isTrue);
    },
  );

  test('a late send cannot clear a newer mode-only edit', () async {
    final fixture = _Fixture(), owner = Object();
    final initial = fixture.bind(owner);
    fixture.store.edit(owner, initial.content, markdown: false);
    expect(
      fixture.store.confirmSent(
        revision: 0,
        peer: 20,
        version: initial.version,
      ),
      isFalse,
    );
    expect(fixture.read(20)!.content, initial.content);
    expect(fixture.read(20)!.markdown, isFalse);
    expect(fixture.read(20)!.dirty, isTrue);
    fixture.store.activate(1);
    expect(fixture.store.read(revision: 0, peer: 20), isNull);
    final next = fixture.store.acquire(
      Object(),
      revision: 1,
      peer: 20,
      nativeContent: '',
    )!;
    expect(next.markdown, isTrue);
  });

  test(
    'two views share explicit edits and cannot reseed from stale native text',
    () {
      final fixture = _Fixture(), workspace = Object(), window = Object();
      final initial = fixture.bind(workspace);
      fixture.store.edit(workspace, 'Latest shared text');
      final edited = fixture.read(20)!;
      expect(edited.version, greaterThan(initial.version));
      expect(
        fixture.bind(window, text: 'Stale window read').content,
        'Latest shared text',
      );
      expect(
        fixture.bind(workspace, text: 'Even older read').content,
        'Latest shared text',
      );
      fixture.store.release(workspace);
      expect(
        fixture.store.edit(workspace, 'Disposed controller copy'),
        isFalse,
      );
      expect(fixture.read(20)!.content, 'Latest shared text');
      expect(fixture.store.edit(window, 'Window last keystroke'), isTrue);
      expect(fixture.read(20)!.content, 'Window last keystroke');
      expect(fixture.writes, isEmpty);
    },
  );

  test('clean text is released only after every view detaches', () {
    final fixture = _Fixture(), first = Object(), second = Object();
    fixture.bind(first);
    fixture.bind(second, text: 'Ignored stale text');
    fixture.store.release(first);
    expect(fixture.read(20)!.content, 'Disk draft');
    fixture.store.release(second);
    expect(fixture.read(20), isNull);
    expect(fixture.writes, isEmpty);
    expect(
      fixture.bind(Object(), text: 'Fresh disk read').content,
      'Fresh disk read',
    );
  });

  test(
    'failure after the last view closes survives reopening and retry',
    () async {
      final fixture = _Fixture(), oldView = Object(), reopened = Object();
      fixture.bind(oldView);
      fixture.store.edit(oldView, 'Must survive view disposal');
      final save = fixture.store.flush(revision: 0, peer: 20);
      fixture.store.release(oldView);
      fixture.writes.single.completion.completeError(
        StateError('Local disk unavailable'),
      );
      expect(await save, isFalse);
      expect(fixture.read(20)!.dirty, isTrue);
      expect(fixture.read(20)!.saving, isFalse);
      expect(fixture.read(20)!.error, isA<StateError>());
      final restored = fixture.bind(reopened, text: 'Stale native draft');
      expect(restored.content, 'Must survive view disposal');
      final retry = fixture.store.flush(revision: 0, peer: 20);
      expect(fixture.writes, hasLength(2));
      expect(fixture.writes.last.content, restored.content);
      fixture.writes.last.completion.complete();
      expect(await retry, isTrue);
      expect(fixture.read(20)!.dirty, isFalse);
      expect(fixture.read(20)!.error, isNull);
      fixture.store.release(reopened);
      expect(fixture.read(20), isNull);
    },
  );

  test(
    'same-peer callers join one write and old success cannot clear newer edits',
    () async {
      final fixture = _Fixture(), first = Object(), second = Object();
      fixture.bind(first);
      fixture.bind(second);
      fixture.store.edit(first, 'First write');
      final saving = fixture.store.flush(revision: 0, peer: 20);
      fixture.store.edit(second, 'Intermediate edit');
      fixture.store.edit(first, 'The final shared edit');
      final joined = fixture.store.flush(revision: 0, peer: 20);
      expect(joined, same(saving));
      expect(fixture.writes, hasLength(1));
      var finished = false;
      saving.then((_) => finished = true);
      fixture.writes.first.completion.complete();
      await _turn();
      expect(finished, isFalse);
      expect(fixture.writes, hasLength(2));
      expect(fixture.writes.last.content, 'The final shared edit');
      expect(fixture.read(20)!.dirty, isTrue);
      expect(fixture.read(20)!.saving, isTrue);
      fixture.writes.last.completion.complete();
      expect(await saving, isTrue);
      expect(await joined, isTrue);
      expect(fixture.read(20)!.content, 'The final shared edit');
      expect(fixture.read(20)!.dirty, isFalse);
    },
  );

  test(
    'a failed older write keeps the newest edit for the next attempt',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner);
      fixture.store.edit(owner, 'Older attempt');
      final first = fixture.store.flush(revision: 0, peer: 20);
      fixture.store.edit(owner, 'Typed while older write was pending');
      fixture.store.release(owner);
      fixture.writes.first.completion.completeError(
        StateError('Failed older write'),
      );
      expect(await first, isFalse);
      expect(fixture.read(20)!.content, 'Typed while older write was pending');
      final retry = fixture.store.flushAll(revision: 0);
      expect(
        fixture.writes.last.content,
        'Typed while older write was pending',
      );
      fixture.writes.last.completion.complete();
      expect(await retry, isTrue);
      expect(fixture.read(20), isNull);
    },
  );

  test(
    'peer writes are independent and flushAll waits for every pending peer',
    () async {
      final fixture = _Fixture(), first = Object(), second = Object();
      fixture.bind(first, peer: 20);
      fixture.bind(second, peer: 21);
      fixture.store.edit(first, 'Peer twenty text');
      fixture.store.edit(second, 'Peer twenty-one text');
      fixture.store.release(first);
      fixture.store.release(second);
      var finished = false;
      final flushing = fixture.store.flushAll(revision: 0).then((value) {
        finished = true;
        return value;
      });
      expect(fixture.writes.map((call) => call.peer), [20, 21]);
      fixture.writes.first.completion.complete();
      await _turn();
      expect(finished, isFalse);
      expect(fixture.read(20), isNull);
      expect(fixture.read(21)!.content, 'Peer twenty-one text');
      fixture.writes.last.completion.complete();
      expect(await flushing, isTrue);
      expect(fixture.read(21), isNull);
    },
  );

  test(
    'empty edits are retained as pending deletion rather than missing text',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner, text: 'Native text to delete');
      fixture.store.edit(owner, '');
      fixture.store.release(owner);
      expect(
        fixture.bind(Object(), text: 'Stale native text').content,
        isEmpty,
      );
      final saving = fixture.store.flushAll(revision: 0);
      expect(fixture.writes.single.content, isEmpty);
      fixture.writes.single.completion.complete();
      expect(await saving, isTrue);
    },
  );

  test(
    'listeners see shared text and write status without creating native writes',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner);
      final observations = <InboxDraftSnapshot>[];
      fixture.store.addListener(() {
        final value = fixture.read(20);
        if (value != null) observations.add(value);
      });
      fixture.store.edit(owner, 'Visible in both editors');
      expect(observations.last.content, 'Visible in both editors');
      expect(observations.last.dirty, isTrue);
      expect(fixture.writes, isEmpty);
      final saving = fixture.store.flush(revision: 0, peer: 20);
      expect(observations.last.saving, isTrue);
      fixture.writes.single.completion.complete();
      expect(await saving, isTrue);
      expect(observations.last.saving, isFalse);
      expect(observations.last.dirty, isFalse);
    },
  );

  for (final lateFailure in [false, true]) {
    test(
      'account changes retire text and ignore late ${lateFailure ? 'failure' : 'success'}',
      () async {
        final fixture = _Fixture(), oldOwner = Object(), newOwner = Object();
        fixture.bind(oldOwner);
        fixture.store.edit(oldOwner, 'Old account private text');
        final oldSave = fixture.store.flush(revision: 0, peer: 20);
        fixture.store.edit(oldOwner, 'Old queued edit must never be written');
        fixture.store.activate(1);
        expect(await oldSave, isFalse);
        expect(fixture.store.read(revision: 0, peer: 20), isNull);
        expect(fixture.read(20), isNull);
        expect(
          fixture.store.edit(oldOwner, 'Stale controller callback'),
          isFalse,
        );
        fixture.bind(newOwner, text: 'New account native draft');
        fixture.store.edit(newOwner, 'New account edit');
        final newSave = fixture.store.flush(revision: 1, peer: 20);
        expect(fixture.writes.map((call) => call.revision), [0, 1]);
        if (lateFailure) {
          fixture.writes.first.completion.completeError(
            StateError('Retired account error'),
          );
        } else {
          fixture.writes.first.completion.complete();
        }
        await _turn();
        expect(fixture.writes, hasLength(2));
        expect(fixture.read(20)!.content, 'New account edit');
        expect(fixture.read(20)!.dirty, isTrue);
        expect(fixture.read(20)!.error, isNull);
        fixture.writes.last.completion.complete();
        expect(await newSave, isTrue);
        expect(fixture.read(20)!.dirty, isFalse);
      },
    );
  }

  test(
    'invalid owners, peers, and stale revisions cannot mutate current drafts',
    () async {
      final fixture = _Fixture(), owner = Object();
      final original = fixture.bind(owner);
      fixture.store.activate(0);
      fixture.store.activate(-1);
      expect(fixture.store.revision, 0);
      for (final peer in [0, -1]) {
        expect(
          fixture.store.acquire(
            owner,
            revision: 0,
            peer: peer,
            nativeContent: 'Invalid',
          ),
          isNull,
        );
        expect(await fixture.store.flush(revision: 0, peer: peer), isFalse);
      }
      expect(
        fixture.store.acquire(
          owner,
          revision: 1,
          peer: 20,
          nativeContent: 'Future',
        ),
        isNull,
      );
      expect(await fixture.store.flushAll(revision: 1), isFalse);
      expect(fixture.store.edit(Object(), 'Unbound view'), isFalse);
      expect(
        fixture.store.confirmSent(
          revision: 0,
          peer: 20,
          version: original.version + 100,
        ),
        isFalse,
      );
      expect(fixture.read(20)!.content, original.content);
      expect(fixture.writes, isEmpty);
    },
  );

  test(
    'confirmed send clears only its exact version and never sends anything',
    () async {
      final fixture = _Fixture(), owner = Object();
      final draft = fixture.bind(owner, text: 'Already persisted send text');
      expect(
        fixture.store.confirmSent(
          revision: 0,
          peer: 20,
          version: draft.version,
        ),
        isTrue,
      );
      expect(fixture.read(20)!.content, isEmpty);
      expect(fixture.read(20)!.dirty, isFalse);
      expect(fixture.read(20)!.version, greaterThan(draft.version));
      expect(await fixture.store.flushAll(revision: 0), isTrue);
      expect(fixture.writes, isEmpty);
    },
  );

  test(
    'confirmed older send re-persists newer text even if it was already saved',
    () async {
      final fixture = _Fixture(), first = Object(), second = Object();
      final sent = fixture.bind(first, text: 'Text chosen for sending');
      fixture.bind(second);
      fixture.store.edit(second, 'A newer draft in the other window');
      final newerSave = fixture.store.flush(revision: 0, peer: 20);
      fixture.writes.single.completion.complete();
      expect(await newerSave, isTrue);
      expect(fixture.read(20)!.dirty, isFalse);
      expect(
        fixture.store.confirmSent(revision: 0, peer: 20, version: sent.version),
        isFalse,
      );
      expect(fixture.read(20)!.content, 'A newer draft in the other window');
      expect(fixture.read(20)!.dirty, isTrue);
      final restoreAfterSend = fixture.store.flushAll(revision: 0);
      expect(fixture.writes.last.content, 'A newer draft in the other window');
      fixture.writes.last.completion.complete();
      expect(await restoreAfterSend, isTrue);
    },
  );

  test(
    'matching send during an in-flight save cannot resurrect sent text',
    () async {
      final fixture = _Fixture(), owner = Object();
      fixture.bind(owner);
      fixture.store.edit(owner, 'Text being saved');
      final version = fixture.read(20)!.version;
      final saving = fixture.store.flush(revision: 0, peer: 20);
      expect(
        fixture.store.confirmSent(revision: 0, peer: 20, version: version),
        isTrue,
      );
      fixture.writes.first.completion.complete();
      await _turn();
      expect(fixture.writes, hasLength(2));
      expect(fixture.writes.last.content, isEmpty);
      fixture.writes.last.completion.complete();
      expect(await saving, isTrue);
      expect(fixture.read(20)!.content, isEmpty);
    },
  );

  test(
    'disposing retires waiting callers and does not notify on late completion',
    () async {
      final writes = <_Write>[];
      final store = InboxDraftStore(
        write:
            ({
              required revision,
              required peer,
              required content,
              required markdown,
            }) {
              final write = _Write(revision, peer, content, markdown);
              writes.add(write);
              return write.completion.future;
            },
      )..activate(0);
      final owner = Object();
      store.acquire(owner, revision: 0, peer: 20, nativeContent: 'Native');
      store.edit(owner, 'Private outstanding text');
      final saving = store.flush(revision: 0, peer: 20);
      var notifications = 0;
      store.addListener(() => notifications++);
      store.dispose();
      expect(await saving, isFalse);
      expect(store.read(revision: 0, peer: 20), isNull);
      expect(store.edit(owner, 'Retired edit'), isFalse);
      writes.single.completion.completeError(
        StateError('Late disposal failure'),
      );
      await _turn();
      expect(notifications, 0);
    },
  );
}
