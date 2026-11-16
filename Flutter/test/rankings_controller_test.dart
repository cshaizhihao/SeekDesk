import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/rankings_controller.dart';

import 'support/rankings_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'same-period refreshes and forced refreshes share one request future',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final controller = fixture.controller;
        final first = controller.refresh();
        expect(identical(first, controller.refresh()), isTrue);
        expect(identical(first, controller.refresh(force: true)), isTrue);
        expect(fixture.native.requests, hasLength(1));
        expect(controller.loading, isTrue);
        fixture.native.requests.single.complete();
        await first;
        expect(controller.loading, isFalse);
        await controller.refresh();
        expect(fixture.native.requests, hasLength(1));
        final forced = controller.refresh(force: true);
        expect(identical(forced, controller.refresh()), isTrue);
        expect(fixture.native.requests, hasLength(2));
        expect(fixture.native.requests.last.arguments['force'], isTrue);
        fixture.native.requests.last.complete(posts: [rankingPost(2)]);
        await forced;
        expect(controller.posts.single['id'], '2');
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final period in RankingPeriod.values) {
    testWidgets(
      '${period.name} reuses received cache until its exact TTL boundary',
      (tester) async {
        final fixture = await _Fixture.create();
        try {
          final initial = fixture.controller.selectPeriod(period);
          // The source feed timestamp can be old; it is not our fetched time.
          fixture.native.requests.last.complete(updatedAt: 100);
          await initial;
          expect(fixture.controller.updatedAt!.millisecondsSinceEpoch, 100000);
          fixture.now = fixture.now.add(
            period.ttl - const Duration(milliseconds: 1),
          );
          await fixture.controller.refresh();
          expect(fixture.native.requests, hasLength(1));
          fixture.now = fixture.now.add(const Duration(milliseconds: 1));
          final next = fixture.controller.refresh();
          expect(fixture.native.requests, hasLength(2));
          expect(fixture.native.requests.last.arguments['period'], period.name);
          fixture.native.requests.last.complete();
          await next;
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'visibility owns one polling timer and hidden completions do not restart it',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final controller = fixture.controller;
        expect(fixture.native.requests, isEmpty);
        controller.setVisible(true);
        controller.setVisible(true);
        expect(fixture.native.requests, hasLength(1));
        fixture.native.requests.last.complete();
        await tester.pump();
        await fixture.advance(tester, const Duration(seconds: 59));
        expect(fixture.native.requests, hasLength(1));
        await fixture.advance(tester, const Duration(seconds: 1));
        expect(fixture.native.requests, hasLength(2));
        controller.setVisible(false);
        fixture.native.requests.last.complete();
        await tester.pump();
        await fixture.advance(tester, const Duration(hours: 2));
        expect(fixture.native.requests, hasLength(2));
        controller.setVisible(true);
        expect(fixture.native.requests, hasLength(3));
        fixture.native.requests.last.complete();
        await tester.pump();
        final weekly = controller.selectPeriod(RankingPeriod.weekly);
        fixture.native.requests.last.complete();
        await weekly;
        await fixture.advance(tester, const Duration(seconds: 60));
        expect(fixture.native.requests, hasLength(4));
        await fixture.advance(tester, const Duration(seconds: 3540));
        expect(fixture.native.requests, hasLength(5));
        expect(fixture.native.requests.last.arguments['period'], 'weekly');
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'failed refresh retains content and retries with backoff instead of success TTL',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final controller = fixture.controller;
        controller.setVisible(true);
        fixture.native.requests.last.complete(posts: [rankingPost(7)]);
        await tester.pump();
        final refresh = controller.refresh(force: true);
        fixture.native.requests.last.complete(
          posts: [],
          error: 'Fixture offline',
        );
        await refresh;
        expect(controller.posts.single['position'], 7);
        expect(controller.error, 'Fixture offline');
        await controller.refresh();
        expect(fixture.native.requests, hasLength(2));
        await fixture.advance(tester, const Duration(seconds: 4));
        expect(fixture.native.requests, hasLength(2));
        await fixture.advance(tester, const Duration(seconds: 1));
        expect(fixture.native.requests, hasLength(3));
        fixture.native.requests.last.complete(
          posts: [],
          error: 'Still offline',
        );
        await tester.pump();
        await fixture.advance(tester, const Duration(seconds: 9));
        expect(fixture.native.requests, hasLength(3));
        await fixture.advance(tester, const Duration(seconds: 1));
        expect(fixture.native.requests, hasLength(4));
        fixture.native.requests.last.complete(
          posts: [],
          error: 'Retry manually',
        );
        await tester.pump();
        final forced = controller.refresh(force: true);
        expect(fixture.native.requests, hasLength(5));
        expect(identical(forced, controller.refresh(force: true)), isTrue);
        fixture.native.requests.last.complete(posts: [rankingPost(8)]);
        await forced;
        expect(controller.error, isNull);
        expect(controller.posts.single['position'], 8);
        await fixture.advance(tester, const Duration(seconds: 59));
        expect(fixture.native.requests, hasLength(5));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'first failed response can display native stale rows without treating it as success',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        fixture.controller.setVisible(true);
        fixture.native.requests.last.complete(
          posts: [rankingPost(9)],
          error: 'Stale snapshot',
        );
        await tester.pump();
        expect(fixture.controller.hasSnapshot, isTrue);
        expect(fixture.controller.posts.single['position'], 9);
        expect(fixture.controller.error, 'Stale snapshot');
        await fixture.advance(tester, const Duration(seconds: 5));
        expect(fixture.native.requests, hasLength(2));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'switching period never shows another period and preserves independent late snapshots',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final controller = fixture.controller;
        final hot = controller.refresh();
        final daily = controller.selectPeriod(RankingPeriod.daily);
        expect(controller.posts, isEmpty);
        fixture.native.requests.first.complete(
          posts: [rankingPost(1, title: 'Hot result')],
        );
        await hot;
        expect(controller.period, RankingPeriod.daily);
        expect(controller.posts, isEmpty);
        expect(controller.loading, isTrue);
        fixture.native.requests.last.complete(
          posts: [rankingPost(2, title: 'Daily result')],
        );
        await daily;
        expect(controller.posts.single['title'], 'Daily result');
        final weekly = controller.selectPeriod(RankingPeriod.weekly);
        expect(controller.posts, isEmpty);
        expect(controller.hasSnapshot, isFalse);
        await controller.selectPeriod(RankingPeriod.hot);
        expect(controller.posts.single['title'], 'Hot result');
        fixture.native.requests.last.complete(
          posts: [rankingPost(3, title: 'Weekly result')],
        );
        await weekly;
        expect(controller.posts.single['title'], 'Hot result');
        await controller.selectPeriod(RankingPeriod.weekly);
        expect(controller.posts.single['title'], 'Weekly result');
        expect(fixture.native.requests, hasLength(3));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'summary filters original first ten, keeps positions, and prioritizes author IDs',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final rows = [for (var rank = 1; rank <= 12; rank++) rankingPost(rank)];
        rows[0] = {...rows[0], 'authorID': 101, 'normalizedAuthor': 'same'};
        rows[1] = {...rows[1], 'authorID': 202, 'normalizedAuthor': 'same'};
        rows[2] = {...rows[2], 'id': '1'};
        rows[3] = {
          ...rows[3],
          'authorID': null,
          'normalizedAuthor': 'folded name',
        };
        rows[4] = {
          ...rows[4],
          'authorID': 55,
          'normalizedAuthor': 'renamed author',
        };
        final blocked = <JsonMap>[
          {'id': 'member:101', 'memberId': 101, 'normalizedName': 'same'},
          {
            'id': 'name:folded name',
            'memberId': null,
            'normalizedName': 'folded name',
          },
          {'id': 'member:55', 'memberId': 55, 'normalizedName': 'old name'},
        ];
        fixture.native.emit('extensions', {
          'items': [
            {'id': 'block', 'active': true},
          ],
          'blocked': blocked,
        });
        final loading = fixture.controller.refresh();
        fixture.native.requests.last.complete(posts: rows);
        await loading;
        expect(fixture.controller.posts.map((post) => post['position']), [
          2,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
        ]);
        expect(
          fixture.controller.summaryPosts.map((post) => post['position']),
          [2, 6, 7, 8, 9, 10],
        );
        expect(
          () => fixture.controller.posts.add(rankingPost(99)),
          throwsUnsupportedError,
        );
        expect(
          () => fixture.controller.posts.first['title'] = 'changed',
          throwsUnsupportedError,
        );
        fixture.native.emit('extensions', {
          'items': [
            {'id': 'block', 'active': false},
          ],
          'blocked': blocked,
        });
        expect(fixture.controller.posts, hasLength(11));
        expect(fixture.controller.summaryPosts, hasLength(9));
        expect(fixture.controller.posts.map((post) => post['position']), [
          1,
          2,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
        ]);
        expect(fixture.native.requests, hasLength(1));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'missing rank falls back to original index and empty IDs never become rows',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final loading = fixture.controller.refresh();
        fixture.native.requests.last.complete(
          posts: [
            {...rankingPost(1), 'id': ''},
            {...rankingPost(2), 'position': null},
            {...rankingPost(3), 'position': -1},
            {...rankingPost(4), 'position': 41},
          ],
        );
        await loading;
        expect(fixture.controller.posts.map((post) => post['position']), [
          2,
          3,
          41,
        ]);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'account revision clears cache and serializes successor against the old pending key',
    (tester) async {
      final fixture = await _Fixture.create();
      try {
        final controller = fixture.controller;
        controller.setVisible(true);
        fixture.native.requests.last.complete(
          posts: [rankingPost(1, title: 'Old owner snapshot')],
        );
        await tester.pump();
        final old = controller.refresh(force: true);
        fixture.native.account(1);
        expect(controller.posts, isEmpty);
        expect(controller.hasSnapshot, isFalse);
        expect(controller.loading, isTrue);
        expect(fixture.native.requests, hasLength(2));
        final successor = controller.refresh(force: true);
        fixture.native.requests.last.complete(
          posts: [rankingPost(2, title: 'Late old owner')],
        );
        await old;
        await tester.pump();
        expect(fixture.native.requests, hasLength(3));
        expect(fixture.native.requests.last.arguments['accessRevision'], 1);
        expect(controller.posts, isEmpty);
        expect(controller.loading, isTrue);
        fixture.native.requests.last.complete(
          posts: [rankingPost(3, title: 'Current owner')],
        );
        await successor;
        expect(controller.posts.single['title'], 'Current owner');
        expect(controller.error, isNull);
        expect(controller.loading, isFalse);
        expect(fixture.state.pending, isEmpty);
        // Older broadcasts cannot regress the revision or the current cache.
        fixture.native.account(0);
        expect(fixture.state.accessRevision, 1);
        expect(controller.posts.single['title'], 'Current owner');
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'AppState owns one controller and disposes its polling and late notifications',
    (tester) async {
      final native = RankingsNative();
      final state = AppState(client: native);
      await state.connect();
      final controller = state.rankings;
      expect(identical(controller, state.rankings), isTrue);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.setVisible(true);
      final pending = controller.refresh();
      state.dispose();
      final count = notifications;
      native.requests.single.complete();
      await pending;
      await tester.pump(const Duration(hours: 2));
      controller.setVisible(false);
      controller.setVisible(true);
      await controller.refresh(force: true);
      expect(native.requests, hasLength(1));
      expect(notifications, count);
      await native.snapshotEvents.close();
    },
  );
}

class _Fixture {
  _Fixture(this.native, this.state) {
    controller = RankingsController(state, now: () => now);
  }

  final RankingsNative native;
  final AppState state;
  late final RankingsController controller;
  DateTime now = DateTime.utc(2026, 11, 14, 12);

  static Future<_Fixture> create() async {
    final native = RankingsNative();
    final state = AppState(client: native);
    await state.connect();
    return _Fixture(native, state);
  }

  Future<void> advance(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }

  Future<void> close(WidgetTester tester) async {
    controller.dispose();
    state.dispose();
    native.completePending();
    await tester.pump();
    await native.snapshotEvents.close();
  }
}
