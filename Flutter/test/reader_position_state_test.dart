import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/models/reader_position.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const _url = 'https://www.nodeseek.com/post-17-1';

TopicData _topic([String url = _url]) =>
    TopicData({'id': '17', 'url': url, 'title': 'Position fixture'});

JsonMap _workspace({String url = _url, bool closed = false}) => {
  'tabs': closed
      ? <JsonMap>[]
      : [
          {'id': '17', 'url': url, 'title': 'Position fixture'},
        ],
  'closedTabs': closed
      ? [
          {'id': '17', 'url': url, 'title': 'Position fixture'},
        ]
      : <JsonMap>[],
  'selectedTab': closed ? '' : '17',
  'showReader': !closed,
};

JsonMap _reader({
  String url = _url,
  String title = 'Ready fixture',
  double offset = 10,
  int revision = 0,
}) => {
  'url': url,
  'topicID': '17',
  'accessRevision': revision,
  'loading': false,
  'scrollOffset': offset,
  'anchor': 'floor-3',
  'thread': {'title': title},
};

class _Request {
  _Request(this.arguments);
  final JsonMap arguments;
  final result = Completer<JsonMap>();
}

class _PositionNative extends NativeClient {
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final loads = <_Request>[];
  final opens = <_Request>[];
  String selectedURL = _url;
  Object? closeFailure;

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    final captured = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, captured));
    switch (method) {
      case 'bootstrap':
        return Future.value({
          'session': {'account': 'signedIn', 'owner': 101, 'accessRevision': 0},
          'workspace': _workspace(),
        });
      case 'reader.load':
        final request = _Request(captured);
        loads.add(request);
        return request.result.future;
      case 'reader.open':
        final request = _Request(captured);
        opens.add(request);
        return request.result.future;
      case 'reader.select':
        return Future.value(_workspace(url: selectedURL));
      case 'reader.closeAll':
        final error = closeFailure;
        return error == null
            ? Future.value(_workspace(closed: true))
            : Future<JsonMap>.error(error);
      case 'reader.reopen':
        return Future.value(_workspace());
      default:
        throw StateError('Unexpected native operation: $method');
    }
  }

  void account(int revision) => eventsController.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {
      'account': 'signedIn',
      'owner': 101 + revision,
      'accessRevision': revision,
    },
  });

  void snapshot(JsonMap reader) => eventsController.add({
    'domain': 'snapshot',
    'accessRevision': accessRevision,
    'data': {'reader': reader},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PositionNative native;
  late AppState state;
  late bool disposed;

  setUp(() async {
    native = _PositionNative();
    state = AppState(client: native);
    disposed = false;
    await state.connect();
  });

  tearDown(() async {
    if (!disposed) state.dispose();
    for (final request in [...native.loads, ...native.opens]) {
      if (!request.result.isCompleted) {
        request.result.completeError(
          const NativeFailure('cancelled', 'Fixture cleanup'),
        );
      }
    }
    await Future<void>.delayed(Duration.zero);
    await native.eventsController.close();
  });

  bool record(String url, double offset) => state.recordReaderOffset(
    url,
    offset,
    revision: state.accessRevision,
    epoch: state.readerPositionEpoch,
  );

  Future<void> ready({
    String title = 'Ready fixture',
    double offset = 10,
  }) async {
    final loading = state.loadReader(_url);
    native.loads.last.result.complete(_reader(title: title, offset: offset));
    await loading;
  }

  Future<void> open(String url) async {
    final before = native.loads.length;
    final opening = state.openTopic(_topic(url));
    native.opens.last.result.complete(_workspace(url: url));
    await Future<void>.delayed(Duration.zero);
    if (native.loads.length > before) {
      native.loads.last.result.complete(_reader(url: url));
    }
    await opening;
  }

  test('offsets canonicalize NodeSeek aliases while preserving pages and rejecting invalid locations or numbers', () {
    var notifications = 0;
    state.addListener(() => notifications++);
    final calls = native.calls.length;
    expect(
      record('https://nodeseek.com/post-17-1/?sort=old#comment-9', 125.5),
      isTrue,
    );
    for (final alias in [
      _url,
      'https://nodeseek.com/post-17-1',
      '$_url#7',
      '$_url/?x=1',
      'http://nodeseek.com/post-17-1?x=1#comment-2',
    ]) {
      expect(state.readerOffset(alias), 125.5);
    }
    expect(state.readerOffset('https://www.nodeseek.com/post-17-2'), isNull);
    expect(record('https://www.nodeseek.com/post-17-2', 42), isTrue);
    expect(state.readerOffset(_url), 125.5);
    expect(record(_url, 0), isTrue);
    expect(
      state.readerOffset(_url),
      0,
      reason: 'A recorded top position differs from an absent position.',
    );
    expect(record(_url, 100000000), isTrue);
    for (final invalid in [
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
      100000001.0,
    ]) {
      expect(record(_url, invalid), isFalse);
      expect(state.readerOffset(_url), 100000000);
    }
    for (final invalid in [
      'not-a-url',
      '/post-17-1',
      'https://example.invalid/post-17-1',
      'https://www.nodeseek.com/user-17',
      'https://www.nodeseek.com/post-17-0',
      'https://www.nodeseek.com/post-0-1',
    ]) {
      expect(record(invalid, 30), isFalse);
      expect(state.readerOffset(invalid), isNull);
    }
    expect(
      native.calls,
      hasLength(calls),
      reason: 'Recording a local position must not issue native IO.',
    );
    expect(
      notifications,
      0,
      reason: 'A scroll offset cannot rebuild all AppState listeners.',
    );
  });

  test(
    'body anchors follow the pixel record ownership, page identity and LRU',
    () {
      const anchor = ReaderBodyAnchor(floor: '35', dy: -128.5);
      bool save(String url, double offset, ReaderBodyAnchor? body) =>
          state.recordReaderOffset(
            url,
            offset,
            revision: state.accessRevision,
            epoch: state.readerPositionEpoch,
            bodyAnchor: body,
          );
      expect(
        save('http://nodeseek.com/post-17-1/#comment-35', 800, anchor),
        isTrue,
      );
      expect(state.readerBodyAnchor(_url)?.dy, -128.5);
      expect(
        state.readerBodyAnchor('https://www.nodeseek.com/post-17-2'),
        isNull,
      );
      expect(
        save(_url, 999, const ReaderBodyAnchor(floor: 'x', dy: 1)),
        isFalse,
      );
      expect(state.readerOffset(_url), 800);
      expect(state.readerBodyAnchor(_url)?.floor, '35');
      expect(save(_url, 900, null), isTrue);
      expect(
        state.readerBodyAnchor(_url),
        isNull,
        reason: 'A newer unanchored pixel observation retires an older anchor.',
      );
      expect(save(_url, 900, anchor), isTrue);
      for (var id = 100; id < 600; id++) {
        save('https://www.nodeseek.com/post-$id-1', 50, anchor);
      }
      expect(state.readerOffset(_url), isNull);
      expect(state.readerBodyAnchor(_url), isNull);
      final revision = state.accessRevision, epoch = state.readerPositionEpoch;
      native.account(1);
      expect(
        state.readerBodyAnchor('https://www.nodeseek.com/post-599-1'),
        isNull,
      );
      expect(
        state.recordReaderOffset(
          _url,
          800,
          revision: revision,
          epoch: epoch,
          bodyAnchor: anchor,
        ),
        isFalse,
      );
    },
  );

  test(
    'offset LRU holds 500 pages and protects a recently read or updated page',
    () {
      String page(int id) => 'https://www.nodeseek.com/post-$id-1';
      for (var id = 1; id <= 500; id++) {
        expect(record(page(id), id.toDouble()), isTrue);
      }
      expect(state.readerOffset(page(1)), 1);
      expect(record(page(501), 501), isTrue);
      expect(state.readerOffset(page(2)), isNull);
      expect(state.readerOffset(page(1)), 1);
      expect(record(page(3), 333), isTrue);
      expect(record(page(502), 502), isTrue);
      expect(state.readerOffset(page(4)), isNull);
      expect(state.readerOffset(page(3)), 333);
      expect(state.readerOffset(page(501)), 501);
      expect(state.readerOffset(page(502)), 502);
      expect(
        state.readers,
        isEmpty,
        reason: 'Position retention is independent of the eight-thread content cache.',
      );
    },
  );

  test('account changes and disposal invalidate old position owners and clear navigation', () async {
    await open('$_url#comment-9');
    expect(record(_url, 930), isTrue);
    final revision = state.accessRevision, epoch = state.readerPositionEpoch;
    expect(state.readerNavigation(_url)?.floor, '9');
    native.account(1);
    expect(state.ownsReaderPosition(revision, epoch), isFalse);
    expect(state.readerOffset(_url), isNull);
    expect(state.readerNavigation(_url), isNull);
    expect(
      state.recordReaderOffset(_url, 999, revision: revision, epoch: epoch),
      isFalse,
    );
    expect(record(_url, 55), isTrue);
    final currentRevision = state.accessRevision,
        currentEpoch = state.readerPositionEpoch;
    state.dispose();
    disposed = true;
    expect(state.ownsReaderPosition(currentRevision, currentEpoch), isFalse);
    expect(
      state.recordReaderOffset(
        _url,
        77,
        revision: currentRevision,
        epoch: currentEpoch,
      ),
      isFalse,
    );
    expect(state.readerOffset(_url), isNull);
    expect(state.readerNavigation(_url), isNull);
  });

  test('refresh and bootstrap DTO offsets cannot overwrite newer synchronous local progress', () async {
    await ready(offset: 80);
    // Native fallback is separate from a position observed in this session;
    // otherwise an untouched native zero would consume a first-open fragment.
    expect(state.readerOffset(_url), isNull);
    expect(state.readerFor(_url)['scrollOffset'], 80);
    expect(record(_url, 210), isTrue);
    final refreshing = state.loadReader(_url, force: true);
    expect(state.readerFor(_url)['scrollOffset'], 210);
    expect(record(_url, 340), isTrue);
    native.loads.last.result.complete(
      _reader(title: 'Refreshed content', offset: 100),
    );
    await refreshing;
    expect(
      jsonMap(state.readerFor(_url)['thread'])['title'],
      'Refreshed content',
    );
    expect(state.readerOffset(_url), 340);
    expect(state.readerFor(_url)['scrollOffset'], 340);
    native.snapshot(_reader(title: 'Bootstrapped content', offset: 1));
    expect(state.readerOffset(_url), 340);
    expect(state.readerFor(_url)['scrollOffset'], 340);
    expect(state.domain('reader')['scrollOffset'], 340);
  });

  test('cancelled and failed refresh restoration merges progress recorded after the previous snapshot', () async {
    await ready(title: 'Retained content', offset: 60);
    for (final cancelled in [true, false]) {
      final refresh = state.loadReader(_url, force: true);
      final offset = cancelled ? 440.0 : 550.0;
      expect(record(_url, offset), isTrue);
      native.loads.last.result.completeError(
        NativeFailure(
          cancelled ? 'cancelled' : 'fixture',
          cancelled ? 'Controlled cancellation' : 'Controlled refresh failure',
        ),
      );
      await refresh;
      expect(state.readerFor(_url)['scrollOffset'], offset);
      expect(state.readerOffset(_url), offset);
      expect(
        jsonMap(state.readerFor(_url)['thread'])['title'],
        'Retained content',
      );
      if (cancelled) expect(state.message, isNull);
    }
  });

  test('force replaces an in-flight load and old success or error cannot finish the new request', () async {
    for (final oldFails in [false, true]) {
      final start = native.loads.length;
      final old = state.loadReader(_url, force: true);
      final replacement = state.loadReader(_url, force: true);
      expect(native.loads, hasLength(start + 2));
      expect(native.loads.last.arguments['force'], isTrue);
      expect(state.loadReader(_url), same(replacement));
      expect(record(_url, oldFails ? 620 : 610), isTrue);
      if (oldFails) {
        native.loads[start].result.completeError(
          const NativeFailure('fixture', 'Retired request failure'),
        );
      } else {
        native.loads[start].result.complete(
          _reader(title: 'Retired response', offset: 5),
        );
      }
      await old;
      expect(
        state.loadReader(_url),
        same(replacement),
        reason: 'Retired finally cannot remove its successor.',
      );
      expect(native.loads, hasLength(start + 2));
      expect(
        jsonMap(state.readerFor(_url)['thread'])['title'],
        isNot('Retired response'),
      );
      expect(state.message, isNull);
      native.loads.last.result.complete(
        _reader(title: 'Replacement response', offset: 15),
      );
      await replacement;
      expect(
        jsonMap(state.readerFor(_url)['thread'])['title'],
        'Replacement response',
      );
      expect(state.readerFor(_url)['scrollOffset'], oldFails ? 620 : 610);
    }
  });

  for (final hadContent in [false, true]) {
    test(
      'cancelling the force replacement ${hadContent ? 'restores stable content' : 'removes the loading stub'} instead of retaining an orphaned loading state',
      () async {
        if (hadContent) await ready(title: 'Stable content', offset: 90);
        expect(record(_url, 275), isTrue);
        final start = native.loads.length;
        final old = state.loadReader(_url, force: true);
        final replacement = state.loadReader(_url, force: true);
        expect(native.loads, hasLength(start + 2));
        expect(state.readerFor(_url)['loading'], isTrue);
        native.loads.last.result.completeError(
          const NativeFailure('cancelled', 'Current replacement cancelled'),
        );
        await replacement;

        void expectRestored() {
          if (hadContent) {
            expect(state.readerFor(_url)['loading'], isFalse);
            expect(
              jsonMap(state.readerFor(_url)['thread'])['title'],
              'Stable content',
            );
            expect(state.readerFor(_url)['scrollOffset'], 275);
          } else {
            expect(
              state.readerFor(_url),
              isEmpty,
              reason: 'A cancelled request cannot restore its predecessor\'s loading-only snapshot.',
            );
            expect(state.domain('reader'), isEmpty);
          }
          expect(state.readerOffset(_url), 275);
          expect(state.message, isNull);
        }

        expectRestored();
        native.loads[start].result.complete(
          _reader(
            title: 'Retired request after replacement cancellation',
            offset: 1,
          ),
        );
        await old;
        expectRestored();

        final fresh = state.loadReader(_url);
        expect(
          native.loads,
          hasLength(start + 3),
          reason: 'The cancelled replacement must not leave a phantom request reservation.',
        );
        native.loads.last.result.complete(
          _reader(title: 'Fresh retry', offset: 2),
        );
        await fresh;
        expect(state.readerFor(_url)['loading'], isFalse);
        expect(
          jsonMap(state.readerFor(_url)['thread'])['title'],
          'Fresh retry',
        );
        expect(state.readerFor(_url)['scrollOffset'], 275);
      },
    );
  }

  test('successful close all invalidates position epoch but retains offsets through an early reopen', () async {
    await open('$_url#comment-12');
    expect(record(_url, 720), isTrue);
    final revision = state.accessRevision, epoch = state.readerPositionEpoch;
    final old = state.loadReader(_url, force: true);
    native.closeFailure = const NativeFailure(
      'cancelled',
      'Controlled close rejection',
    );
    expect(await state.closeAllTopics(), isFalse);
    expect(state.readerPositionEpoch, epoch);
    expect(state.ownsReaderPosition(revision, epoch), isTrue);
    native.closeFailure = null;
    expect(await state.closeAllTopics(), isTrue);
    expect(state.readerPositionEpoch, greaterThan(epoch));
    expect(state.ownsReaderPosition(revision, epoch), isFalse);
    expect(
      state.recordReaderOffset(_url, 900, revision: revision, epoch: epoch),
      isFalse,
    );
    expect(state.readerOffset(_url), 720);
    expect(state.readerNavigation(_url), isNull);
    expect(state.readerFor(_url), isEmpty);

    final before = native.loads.length;
    expect(await state.reopenTopic('17'), isTrue);
    expect(native.loads, hasLength(before + 1));
    final fresh = state.loadReader(_url);
    native.loads[before - 1].result.complete(
      _reader(title: 'Closed response', offset: 2),
    );
    await old;
    expect(state.loadReader(_url), same(fresh));
    expect(state.readerOffset(_url), 720);
    native.loads.last.result.complete(
      _reader(title: 'Reopened response', offset: 3),
    );
    await fresh;
    expect(state.readerFor(_url)['scrollOffset'], 720);
    expect(state.readerNavigation(_url), isNull);
  });

  test('explicit successful floor navigation is consumed once and repeated clicks get a new sequence', () async {
    await open('$_url#comment-9');
    final first = state.readerNavigation(_url)!;
    expect(first.floor, '9');
    expect(
      state.readerNavigation('https://nodeseek.com/post-17-1/?x=1'),
      same(first),
    );
    expect(state.takeReaderNavigation(_url), same(first));
    expect(state.takeReaderNavigation(_url), isNull);
    expect(record(_url, 820), isTrue);
    native.selectedURL = '$_url#comment-9';
    await state.selectTopic(_topic(native.selectedURL));
    expect(
      state.readerNavigation(_url),
      isNull,
      reason: 'Selecting a tab cannot replay its historical fragment.',
    );
    expect(state.readerOffset(_url), 820);

    await open('$_url#comment-9');
    final second = state.takeReaderNavigation(_url)!;
    expect(second.floor, '9');
    expect(second.sequence, greaterThan(first.sequence));
    await open('$_url#12');
    expect(state.takeReaderNavigation(_url)?.floor, '12');
  });

  test(
    'invalid URL fragments do not create a floor navigation intent',
    () async {
      for (final fragment in [
        'comment-nope',
        '-1',
        'comment-1.5',
        '7extra',
        'floor-8',
      ]) {
        await open('$_url#$fragment');
        expect(state.readerNavigation(_url), isNull);
        expect(state.takeReaderNavigation(_url), isNull);
      }
    },
  );

  test('failed explicit open cannot leave a navigation intent or start a reader request', () async {
    expect(record(_url, 910), isTrue);
    final opening = state.openTopic(_topic('$_url#comment-5'));
    native.opens.single.result.completeError(
      const NativeFailure('cancelled', 'Controlled open rejection'),
    );
    await opening;
    expect(native.loads, isEmpty);
    expect(state.readerNavigation(_url), isNull);
    expect(state.readerOffset(_url), 910);
  });

  test('account change while explicit open awaits native prevents a new-account load for that old action', () async {
    final opening = state.openTopic(_topic('$_url#comment-5'));
    native.account(1);
    native.opens.single.result.complete(_workspace(url: '$_url#comment-5'));
    await opening;
    expect(native.loads, isEmpty);
    expect(state.readerNavigation(_url), isNull);
    expect(state.readerOffset(_url), isNull);
    expect(
      native.calls.where(
        (call) => call.$1 == 'reader.load' && call.$2['accessRevision'] == 1,
      ),
      isEmpty,
    );
  });

  test('a late explicit open cannot replace the newer navigation intent or start another load', () async {
    final old = state.openTopic(_topic('$_url#comment-5'));
    final recent = state.openTopic(_topic('$_url#comment-9'));
    expect(native.opens, hasLength(2));
    native.opens[1].result.complete(_workspace(url: '$_url#comment-9'));
    await Future<void>.delayed(Duration.zero);
    expect(native.loads, hasLength(1));
    native.loads.single.result.complete(
      _reader(url: '$_url#comment-9', title: 'Current navigation'),
    );
    await recent;
    final current = state.readerNavigation(_url)!;
    expect(current.floor, '9');
    native.opens.first.result.complete(_workspace(url: '$_url#comment-5'));
    await old;
    expect(native.loads, hasLength(1));
    expect(state.readerNavigation(_url), same(current));
    expect(
      jsonMap(state.readerFor(_url)['thread'])['title'],
      'Current navigation',
    );
  });
}
