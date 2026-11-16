import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/state/activity_memory.dart';
import 'package:seekdesk_flutter/state/profile_space_memory.dart';

ActivityPaneMemory _activity(
  ProfileSpaceMemory memory,
  String route, {
  int member = 101,
  int revision = 4,
  int owner = 101,
}) {
  final activity = memory.activity(route);
  activity.activate(
    revision: revision,
    memberId: member,
    route: route,
    owner: owner,
    signedIn: true,
  );
  activity.acceptPage(
    page: route == 'comments' ? 3 : 1,
    items: [
      {'id': member + 1000, 'name': 'Local $route for $member'},
    ],
    hasNext: route == 'comments',
  );
  activity.rememberOffset(activity.page, 230);
  return activity;
}

void _populate(ProfileSpaceMemory memory, int member) {
  memory.section = 'comments';
  memory.overviewOffset = 360;
  memory.profile = {'id': member, 'name': 'Local profile $member'};
  memory.introduction = {'readme': 'Local introduction $member'};
  _activity(memory, 'comments', member: member);
}

void _expectCleared(ProfileSpaceMemory memory) {
  expect(memory.section, 'overview');
  expect(memory.overviewOffset, 0);
  expect(memory.profile, isEmpty);
  expect(memory.introduction, isEmpty);
}

void _expectActivityCleared(ActivityPaneMemory activity, int priorPage) {
  expect(activity.loaded, isFalse);
  expect(activity.items, isEmpty);
  expect(activity.page, 1);
  expect(activity.hasNext, isFalse);
  expect(activity.offsetFor(priorPage), 0);
}

void main() {
  test(
    'all 16 visited profiles retain independent successful activity pages',
    () {
      final store = ProfileSpaceStore()..activate(4, 101, true);
      final originals = <int, ProfileSpaceMemory>{};
      for (var member = 1; member <= 16; member++) {
        final memory = store.forMember(member);
        _populate(memory, member);
        originals[member] = memory;
      }
      for (var member = 1; member <= 16; member++) {
        final memory = store.forMember(member);
        expect(memory, same(originals[member]));
        expect(memory.profile['id'], member);
        expect(
          memory.activity('comments').items.single['name'],
          'Local comments for $member',
        );
        expect(memory.activity('comments').page, 3);
        expect(memory.activity('comments').offsetFor(3), 230);
      }
    },
  );

  test('opening more profiles retains exactly the most recent 16', () {
    final store = ProfileSpaceStore()..activate(4, 101, true);
    final originals = <int, ProfileSpaceMemory>{};
    for (var member = 1; member <= 32; member++) {
      final memory = store.forMember(member);
      _populate(memory, member);
      originals[member] = memory;
    }
    // Touch only entries that must still be retained before probing evictions:
    // forMember itself is a visit and can legitimately cause another eviction.
    for (var member = 17; member <= 32; member++) {
      expect(store.forMember(member), same(originals[member]));
    }
    for (var member = 1; member <= 16; member++) {
      final replacement = store.forMember(member);
      expect(replacement, isNot(same(originals[member])));
      _expectCleared(replacement);
      expect(replacement.activity('comments').loaded, isFalse);
    }
  });

  test('revisiting a profile updates LRU before the seventeenth insertion', () {
    final store = ProfileSpaceStore()..activate(4, 101, true);
    final originals = {
      for (var member = 1; member <= 16; member++)
        member: store.forMember(member),
    };
    _populate(originals[1]!, 1);
    expect(store.forMember(1), same(originals[1]));
    final newest = store.forMember(17);
    expect(store.forMember(1), same(originals[1]));
    expect(store.forMember(1).activity('comments').page, 3);
    for (var member = 3; member <= 16; member++) {
      expect(store.forMember(member), same(originals[member]));
    }
    expect(store.forMember(17), same(newest));
    expect(store.forMember(2), isNot(same(originals[2])));
  });

  test('repeated activation of the same identity preserves profile and private routes', () {
    final store = ProfileSpaceStore()..activate(4, 101, true);
    final profile = store.forMember(101);
    _populate(profile, 101);
    final fans = _activity(profile, 'fans');
    final follow = _activity(profile, 'follow');
    profile.section = 'fans';
    store.activate(4, 101, true);
    expect(store.forMember(101), same(profile));
    expect(profile.section, 'fans');
    expect(profile.overviewOffset, 360);
    expect(profile.activity('fans'), same(fans));
    expect(profile.activity('follow'), same(follow));
    expect(fans.items.single['name'], 'Local fans for 101');
    expect(follow.items.single['name'], 'Local follow for 101');
    expect(fans.offsetFor(1), 230);
  });

  for (final identity in [
    (name: 'revision', revision: 5, owner: 101, signedIn: true),
    (
      name: 'owner without a revision bump',
      revision: 4,
      owner: 202,
      signedIn: true,
    ),
    (
      name: 'signed-in state without a revision bump',
      revision: 4,
      owner: 101,
      signedIn: false,
    ),
  ]) {
    test(
      '${identity.name} change scrubs retained private activity objects in place',
      () {
        final store = ProfileSpaceStore()..activate(4, 101, true);
        final own = store.forMember(101), other = store.forMember(202);
        _populate(own, 101);
        _populate(other, 202);
        final fans = _activity(own, 'fans');
        final follow = _activity(own, 'follow');
        final ownComments = own.activity('comments');
        final otherComments = other.activity('comments');
        own.section = 'fans';
        store.activate(identity.revision, identity.owner, identity.signedIn);
        // A mounted profile can still hold these references. Clearing just the
        // store map would leave its old private rows and scroll state reachable.
        _expectCleared(own);
        _expectCleared(other);
        _expectActivityCleared(fans, 1);
        _expectActivityCleared(follow, 1);
        _expectActivityCleared(ownComments, 3);
        _expectActivityCleared(otherComments, 3);
        expect(own.activity('fans'), isNot(same(fans)));
        expect(store.forMember(101), isNot(same(own)));
        expect(store.forMember(202), isNot(same(other)));
      },
    );
  }

  test('explicit clear scrubs snapshots and reactivating the old identity starts clean', () {
    final store = ProfileSpaceStore()..activate(4, 101, true);
    final own = store.forMember(101);
    _populate(own, 101);
    final fans = _activity(own, 'fans');
    store.clear();
    _expectCleared(own);
    _expectActivityCleared(fans, 1);
    store.activate(4, 101, true);
    final replacement = store.forMember(101);
    expect(replacement, isNot(same(own)));
    _expectCleared(replacement);
    expect(replacement.activity('fans').loaded, isFalse);
  });

  test(
    'clearing one profile resets every route without altering another profile',
    () {
      final store = ProfileSpaceStore()..activate(4, 101, true);
      final own = store.forMember(101), other = store.forMember(202);
      _populate(own, 101);
      _populate(other, 202);
      final fans = _activity(own, 'fans'), follow = _activity(own, 'follow');
      final otherActivity = other.activity('comments');
      expect(own.activity('fans'), same(fans));
      expect(fans, isNot(same(follow)));
      own.clear();
      _expectCleared(own);
      _expectActivityCleared(fans, 1);
      _expectActivityCleared(follow, 1);
      expect(other.profile['id'], 202);
      expect(other.activity('comments'), same(otherActivity));
      expect(otherActivity.page, 3);
      expect(otherActivity.offsetFor(3), 230);
    },
  );
}
