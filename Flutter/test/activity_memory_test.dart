import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/state/activity_memory.dart';

void main() {
  ActivityPaneMemory ready() {
    final memory = ActivityPaneMemory();
    memory.activate(
      revision: 0,
      memberId: 101,
      route: 'comments',
      owner: 101,
      signedIn: true,
    );
    memory.acceptPage(
      page: 2,
      items: [
        {'postId': 77, 'title': 'Local saved page'},
      ],
      hasNext: true,
    );
    memory.rememberOffset(2, 420);
    return memory;
  }

  test('same identity retains a successful page and immutable snapshot', () {
    final memory = ready();
    expect(
      memory.activate(
        revision: 0,
        memberId: 101,
        route: 'comments',
        owner: 101,
        signedIn: true,
      ),
      isFalse,
    );
    expect(memory.page, 2);
    expect(memory.offsetFor(2), 420);
    expect(memory.loaded, isTrue);
    expect(() => memory.items.add({}), throwsUnsupportedError);
    expect(
      () => memory.items.first['title'] = 'Changed',
      throwsUnsupportedError,
    );
  });

  test(
    'revision member route owner and sign-in identity each clear old data',
    () {
      for (final identity in [
        (
          revision: 1,
          member: 101,
          route: 'comments',
          owner: 101,
          signedIn: true,
        ),
        (
          revision: 0,
          member: 202,
          route: 'comments',
          owner: 101,
          signedIn: true,
        ),
        (
          revision: 0,
          member: 101,
          route: 'discussions',
          owner: 101,
          signedIn: true,
        ),
        (
          revision: 0,
          member: 101,
          route: 'comments',
          owner: 202,
          signedIn: true,
        ),
        (
          revision: 0,
          member: 101,
          route: 'comments',
          owner: 101,
          signedIn: false,
        ),
      ]) {
        final memory = ready();
        expect(
          memory.activate(
            revision: identity.revision,
            memberId: identity.member,
            route: identity.route,
            owner: identity.owner,
            signedIn: identity.signedIn,
          ),
          isTrue,
        );
        expect(memory.loaded, isFalse);
        expect(memory.items, isEmpty);
        expect(memory.page, 1);
        expect(memory.hasNext, isFalse);
        expect(memory.offsetFor(2), 0);
      }
    },
  );

  test('page offsets are finite and bounded and the native maximum page cannot advance', () {
    final memory = ready();
    memory.rememberOffset(2, double.nan);
    memory.rememberOffset(2, -1);
    expect(memory.offsetFor(2), 420);
    for (var page = 1; page <= 40; page++) {
      memory.rememberOffset(page, page * 10.0);
    }
    expect(memory.offsetFor(1), 0);
    expect(memory.offsetFor(40), 400);
    memory.acceptPage(page: 10000, items: [], hasNext: true);
    expect(memory.hasNext, isFalse);
    memory.clear();
    expect(memory.items, isEmpty);
    expect(memory.offsetFor(40), 0);
    expect(memory.loaded, isFalse);
  });
}
