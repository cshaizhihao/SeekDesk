import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/inbox_navigation.dart';

class _NavigationNative extends NativeClient {
  _NavigationNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-navigation'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final unexpected = <String>[];

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'bootstrap') {
      return {
        'session': {'account': 'signedIn', 'owner': 101, 'accessRevision': 0},
      };
    }
    unexpected.add(method);
    throw StateError('Navigation memory must not invoke $method');
  }
}

JsonMap _notice({
  String id = 'notice-10',
  String title = 'Selected topic',
  bool unread = true,
}) => {
  'id': id,
  'author': 'Notice author',
  'authorID': 42,
  'title': title,
  'date': '2026-11-15T10:30:00Z',
  'unread': unread,
  'postID': 120,
  'floor': 7,
  'url': 'https://www.nodeseek.com/post-120-1#7',
  'avatar': 'https://www.nodeseek.com/avatar/42.png',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notice memory keeps a detached immutable canonical DTO only', () {
    final memory = InboxNavigation()..activate(4);
    final item = _notice();
    final expected = Map<String, dynamic>.of(item);
    item['body'] = {'private': 'Fetched floor body must not enter memory'};
    item['draft'] = 'Unrelated draft';
    expect(memory.chooseNotice(revision: 4, category: 0, item: item), isTrue);
    expect(memory.noticeID, 'notice-10');
    expect(memory.notice, expected);
    item['title'] = 'Mutated source';
    item['id'] = 'Mutated identity';
    expect(memory.notice, expected);
    expect(
      () => memory.notice!['title'] = 'Mutated getter',
      throwsUnsupportedError,
    );
  });

  test('category changes clear notices without choosing another item', () {
    final memory = InboxNavigation()..activate(4);
    memory.chooseNotice(revision: 4, category: 0, item: _notice());
    memory.remember('mentions:', 93, revision: 4);
    memory.select(revision: 4, category: 0);
    expect(memory.noticeID, 'notice-10');
    memory.select(revision: 4, category: 1);
    expect(memory.notice, isNull);
    // An identical server ID in another category has no inherited selection.
    memory.reconcileNotices(revision: 4, category: 1, items: [_notice()]);
    expect(memory.notice, isNull);
    memory.chooseNotice(revision: 4, category: 1, item: _notice());
    expect(memory.noticeID, 'notice-10');
    memory.select(revision: 4, category: 0);
    expect(memory.notice, isNull);
    expect(memory.offset('mentions:', revision: 4), 93);
  });

  test(
    'notice and peer selection are mutually exclusive in both directions',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.chooseNotice(revision: 4, category: 1, item: _notice());
      expect(
        memory.choosePeer(
          revision: 4,
          peer: 20,
          peerName: 'Contact',
          peerAvatar: 'contact-avatar',
        ),
        isTrue,
      );
      expect(memory.notice, isNull);
      expect(
        (memory.category, memory.peer, memory.peerName, memory.peerAvatar),
        (2, 20, 'Contact', 'contact-avatar'),
      );
      memory.chooseNotice(revision: 4, category: 0, item: _notice());
      expect(
        (memory.category, memory.peer, memory.peerName, memory.peerAvatar),
        (0, null, '', ''),
      );
      expect(memory.noticeID, 'notice-10');
      memory.select(revision: 4, category: 2, peer: 21);
      expect(memory.notice, isNull);
      expect(memory.peer, 21);
    },
  );

  test(
    'invalid and stale notice or peer choices preserve the current route',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.chooseNotice(revision: 4, category: 1, item: _notice());
      final selected = memory.notice;
      for (final input in [(3, 0), (5, 0), (4, -1), (4, 2), (4, 3)]) {
        expect(
          memory.chooseNotice(
            revision: input.$1,
            category: input.$2,
            item: _notice(id: 'replacement'),
          ),
          isFalse,
        );
        expect(memory.category, 1);
        expect(memory.notice, same(selected));
      }
      for (final invalid in <JsonMap>[
        {'id': ''},
        {'id': '  '},
        {'id': 10},
        {'postID': 0},
        {'postID': '120'},
        {'floor': -1},
        {'floor': 7.5},
        {'url': ''},
        {'url': null},
      ]) {
        expect(
          memory.chooseNotice(
            revision: 4,
            category: 0,
            item: {..._notice(), ...invalid},
          ),
          isFalse,
        );
        expect(memory.category, 1);
        expect(memory.notice, same(selected));
      }
      for (final input in [(3, 20), (5, 20), (4, 0), (4, -1)]) {
        expect(memory.choosePeer(revision: input.$1, peer: input.$2), isFalse);
        expect(memory.category, 1);
        expect(memory.peer, isNull);
        expect(memory.notice, same(selected));
      }
    },
  );

  test(
    'explicit clear only affects the current notice category and revision',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.chooseNotice(revision: 4, category: 1, item: _notice());
      memory.remember('replies:', 82, revision: 4);
      for (final input in [(3, 1), (5, 1), (4, 0), (4, 2)]) {
        expect(
          memory.clearNotice(revision: input.$1, category: input.$2),
          isFalse,
        );
        expect(memory.noticeID, 'notice-10');
      }
      expect(memory.clearNotice(revision: 4, category: 1), isTrue);
      expect(memory.notice, isNull);
      expect(memory.category, 1);
      expect(memory.offset('replies:', revision: 4), 82);
      memory.choosePeer(revision: 4, peer: 20);
      expect(memory.clearNotice(revision: 4, category: 2), isFalse);
      expect(memory.peer, 20);
    },
  );

  test(
    'successful refresh updates by stable ID and clears missing selection',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.chooseNotice(revision: 4, category: 0, item: _notice());
      final updated = _notice(title: 'Updated title', unread: false);
      expect(
        memory.reconcileNotices(
          revision: 4,
          category: 0,
          items: [
            _notice(id: 'another'),
            updated,
          ],
        ),
        isTrue,
      );
      expect(memory.notice, updated);
      updated['title'] = 'External mutation';
      expect(memory.notice!['title'], 'Updated title');
      memory.reconcileNotices(
        revision: 4,
        category: 0,
        items: [_notice(id: 'another')],
      );
      expect(memory.notice, isNull);
      memory.reconcileNotices(revision: 4, category: 0, items: [_notice()]);
      expect(memory.notice, isNull);
      memory.chooseNotice(revision: 4, category: 0, item: _notice());
      memory.reconcileNotices(revision: 4, category: 0, items: []);
      expect(memory.notice, isNull);
    },
  );

  test(
    'wrong category, stale and malformed refresh cannot replace selection',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.chooseNotice(revision: 4, category: 0, item: _notice());
      final selected = memory.notice;
      for (final input in [(3, 0), (5, 0), (4, 1), (4, 2), (4, -1)]) {
        expect(
          memory.reconcileNotices(
            revision: input.$1,
            category: input.$2,
            items: [],
          ),
          isFalse,
        );
        expect(memory.notice, same(selected));
      }
      expect(
        memory.reconcileNotices(
          revision: 4,
          category: 0,
          items: [
            {..._notice(), 'postID': null},
          ],
        ),
        isFalse,
      );
      expect(memory.notice, same(selected));
    },
  );

  test('notice DTO supports root floors and an unknown author', () {
    final memory = InboxNavigation()..activate(4);
    expect(
      memory.chooseNotice(
        revision: 4,
        category: 0,
        item: {..._notice(), 'floor': 0, 'authorID': null, 'avatar': ''},
      ),
      isTrue,
    );
    expect(memory.notice!['floor'], 0);
    expect(memory.notice!['authorID'], isNull);
    expect(memory.notice!['avatar'], isEmpty);
  });

  test(
    'independent standalone navigation cannot mutate workspace selection',
    () {
      final workspace = InboxNavigation()..activate(4);
      final standalone = InboxNavigation()..activate(4);
      workspace.chooseNotice(revision: 4, category: 1, item: _notice());
      workspace.remember('replies:', 75, revision: 4);
      standalone.choosePeer(revision: 4, peer: 20);
      standalone.remember('conversation:20', 150, revision: 4);
      standalone.activate(5);
      expect(workspace.revision, 4);
      expect(workspace.noticeID, 'notice-10');
      expect(workspace.offset('replies:', revision: 4), 75);
      expect(workspace.offset('conversation:20', revision: 4), isNull);
      expect(standalone.notice, isNull);
    },
  );

  test('only a newer account revision clears the selected notice', () {
    final memory = InboxNavigation()..activate(4);
    memory.chooseNotice(revision: 4, category: 1, item: _notice());
    final selected = memory.notice;
    memory.activate(4);
    expect(memory.notice, same(selected));
    memory.activate(3);
    expect(memory.notice, same(selected));
    memory.activate(5);
    expect(memory.notice, isNull);
    expect(memory.category, 0);
    expect(
      memory.chooseNotice(revision: 4, category: 1, item: _notice()),
      isFalse,
    );
    expect(
      memory.reconcileNotices(revision: 4, category: 0, items: [_notice()]),
      isFalse,
    );
    expect(memory.notice, isNull);
  });

  test(
    'category navigation removes peer identity without deleting offsets',
    () {
      final memory = InboxNavigation()..activate(4);
      expect(
        memory.select(
          revision: 4,
          category: 2,
          peer: 20,
          peerName: 'Peer fixture',
          peerAvatar: 'fixture-avatar',
        ),
        isTrue,
      );
      memory.remember('conversation:20', 315.5, revision: 4);
      expect(memory.peer, 20);
      expect(memory.peerName, 'Peer fixture');
      expect(memory.peerAvatar, 'fixture-avatar');
      for (final category in [0, 1, 2]) {
        expect(memory.select(revision: 4, category: category), isTrue);
        expect(memory.category, category);
        expect(memory.peer, isNull);
        expect(memory.peerName, isEmpty);
        expect(memory.peerAvatar, isEmpty);
        expect(memory.offset('conversation:20', revision: 4), 315.5);
      }
    },
  );

  test('invalid or stale selections leave the complete route unchanged', () {
    final memory = InboxNavigation()..activate(4);
    memory.select(
      revision: 4,
      category: 2,
      peer: 20,
      peerName: 'Retained',
      peerAvatar: 'retained-avatar',
    );
    for (final input in [
      (3, 0, null),
      (5, 0, null),
      (4, -1, null),
      (4, 3, null),
      (4, 2, 0),
      (4, 2, -20),
      (4, 0, 20),
      (4, 1, 20),
    ]) {
      expect(
        memory.select(revision: input.$1, category: input.$2, peer: input.$3),
        isFalse,
      );
      expect(
        (memory.category, memory.peer, memory.peerName, memory.peerAvatar),
        (2, 20, 'Retained', 'retained-avatar'),
      );
    }
  });

  test(
    'only finite bounded offsets for actual inbox destinations are kept',
    () {
      final memory = InboxNavigation()..activate(0);
      for (final key in [
        'mentions:',
        'replies:',
        'messages:',
        'conversation:20',
      ]) {
        memory.remember(key, 12.25, revision: 0);
        for (final invalid in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
          -1.0,
          100000001.0,
        ]) {
          memory.remember(key, invalid, revision: 0);
          expect(memory.offset(key, revision: 0), 12.25);
        }
      }
      for (final key in [
        '',
        'mentions:20',
        'conversation:',
        'conversation:0',
        'conversation:-1',
        'conversation:020',
        'conversation:abc',
        'profile:20',
      ]) {
        memory.remember(key, 40, revision: 0);
        expect(memory.offset(key, revision: 0), isNull);
      }
      memory.remember('mentions:', 0, revision: 0);
      memory.remember('replies:', 100000000, revision: 0);
      expect(memory.offset('mentions:', revision: 0), 0);
      expect(memory.offset('replies:', revision: 0), 100000000);
      expect(memory.offset('messages:', revision: 0), 12.25);
    },
  );

  test(
    'offset memory evicts the least recently used destination at its bound',
    () {
      final memory = InboxNavigation()..activate(0);
      for (var peer = 1; peer <= 64; peer++) {
        memory.remember('conversation:$peer', peer.toDouble(), revision: 0);
      }
      expect(memory.offset('conversation:1', revision: 0), 1);
      memory.remember('mentions:', 300, revision: 0);
      expect(memory.offset('conversation:2', revision: 0), isNull);
      expect(memory.offset('conversation:1', revision: 0), 1);
      expect(memory.offset('conversation:64', revision: 0), 64);
      expect(memory.offset('mentions:', revision: 0), 300);
    },
  );

  test(
    'revision changes clear routes and positions and reject old callbacks',
    () {
      final memory = InboxNavigation()..activate(4);
      memory.select(
        revision: 4,
        category: 2,
        peer: 20,
        peerName: 'Old account peer',
        peerAvatar: 'old-avatar',
      );
      memory.remember('conversation:20', 315.5, revision: 4);
      memory.activate(4);
      expect(memory.peer, 20);
      memory.activate(3);
      expect(memory.revision, 4);
      memory.activate(5);
      expect(
        (memory.category, memory.peer, memory.peerName, memory.peerAvatar),
        (0, null, '', ''),
      );
      expect(memory.offset('conversation:20', revision: 5), isNull);
      memory.remember('conversation:20', 99, revision: 4);
      expect(memory.select(revision: 4, category: 2, peer: 20), isFalse);
      expect(memory.offset('conversation:20', revision: 4), isNull);
      expect(memory.offset('conversation:20', revision: 5), isNull);
    },
  );

  test(
    'AppState owns one memory and resets it through real account events',
    () async {
      final native = _NavigationNative();
      final state = AppState(client: native);
      await state.connect();
      final memory = state.inboxNavigation;
      memory.select(
        revision: 0,
        category: 2,
        peer: 20,
        peerName: 'Private peer',
      );
      memory.remember('messages:', 270, revision: 0);
      expect(state.inboxNavigation, same(memory));
      native.eventStream.add({
        'domain': 'session',
        'accessRevision': 1,
        'data': {'account': 'signedIn', 'owner': 202, 'accessRevision': 1},
      });
      expect(state.inboxNavigation, same(memory));
      expect(memory.revision, 1);
      expect(memory.category, 0);
      expect(memory.peer, isNull);
      expect(memory.offset('messages:', revision: 1), isNull);
      native.eventStream.add({
        'domain': 'session',
        'accessRevision': 0,
        'data': {'account': 'signedIn', 'owner': 101, 'accessRevision': 0},
      });
      expect(memory.revision, 1);
      expect(state.domain('session')['owner'], 202);
      memory.chooseNotice(revision: 1, category: 1, item: _notice());
      expect(memory.noticeID, 'notice-10');
      native.eventStream.add({
        'domain': 'session',
        'accessRevision': 2,
        'data': {'account': 'signedOut', 'owner': null, 'accessRevision': 2},
      });
      expect(state.inboxNavigation, same(memory));
      expect(memory.revision, 2);
      expect(memory.notice, isNull);
      expect(memory.category, 0);
      expect(native.unexpected, isEmpty);
      state.dispose();
      await native.eventStream.close();
    },
  );
}
