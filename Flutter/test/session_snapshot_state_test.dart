import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const _url = 'https://www.nodeseek.com/post-2101-1';

JsonMap _session() => {
  'account': 'signedIn',
  'owner': 42,
  'accessRevision': 0,
  'canCompose': true,
  'profile': {
    'id': 42,
    'name': 'Session fixture',
    'avatar': null,
    'medals': [
      {
        'name': 'Member',
        'levels': [1, 2],
      },
    ],
  },
  'unread': {'mentions': 2, 'replies': 3, 'messages': 1},
  'sending': <String>[],
};

JsonMap _copy(JsonMap value) => jsonMap(jsonDecode(jsonEncode(value)));

class _SessionNative extends NativeClient {
  _SessionNative()
    : super(methods: const MethodChannel('seekdesk.test.session-snapshot'));

  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  JsonMap result = {};
  Completer<JsonMap>? response;
  final calls = <String>[];

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'bootstrap') return {'session': _session()};
    if (method == 'session.refresh') return response?.future ?? result;
    throw StateError('Unexpected session fixture request: $method');
  }

  void emit(String domain, JsonMap data, {int? revision}) {
    eventsController.add({
      'domain': domain,
      'accessRevision': revision ?? accessRevision,
      'data': data,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SessionNative native;
  late AppState state;

  setUp(() async {
    native = _SessionNative();
    state = AppState(client: native);
    await state.connect();
  });

  tearDown(() async {
    state.dispose();
    await native.eventsController.close();
  });

  for (final entry in [
    'event',
    'snapshot',
    'bootstrap',
    'result',
    'envelope',
  ]) {
    test(
      '$entry preserves a deeply equal session and still notifies',
      () async {
        final original = state.domain('session');
        final next = _copy(original);
        final reversed = Map<String, dynamic>.fromEntries(
          next.entries.toList().reversed,
        );
        expect(identical(next['profile'], original['profile']), isFalse);
        expect(identical(next['sending'], original['sending']), isFalse);
        var notifications = 0;
        state.addListener(() => notifications++);
        switch (entry) {
          case 'event':
            native.emit('session', reversed);
          case 'snapshot':
            native.emit('snapshot', {'session': reversed});
          case 'bootstrap':
            native.result = {'session': reversed};
            await state.act('session.refresh');
          case 'result':
            native.result = reversed;
            await state.act('session.refresh', {}, 'session');
          case 'envelope':
            native.result = {
              'domain': 'session',
              'accessRevision': 0,
              'data': reversed,
            };
            await state.act('session.refresh');
        }
        expect(state.domain('session'), same(original));
        expect(notifications, greaterThan(0));
      },
    );
  }

  test('every session field and nested value remains authoritative', () async {
    final updates = <void Function(JsonMap)>[
      (value) => (value['unread'] as Map)['mentions'] = 4,
      (value) => value['canCompose'] = false,
      (value) => value['sending'] = ['2101'],
      (value) => (value['profile'] as Map)['name'] = 'Changed profile',
      (value) =>
          ((value['profile'] as Map)['medals'] as List)[0]['levels'] = [2, 1],
      (value) => (value['profile'] as Map).remove('avatar'),
      (value) => (value['profile'] as Map)['avatar'] = null,
      (value) => value['owner'] = 43,
      (value) => value['account'] = 'signedOut',
      (value) => value['profile'] = null,
    ];
    for (var i = 0; i < updates.length; i++) {
      final previous = state.domain('session');
      final next = _copy(previous);
      updates[i](next);
      if (i % 3 == 0) {
        native.emit('session', next);
      } else {
        native.result = i % 3 == 1 ? {'session': next} : next;
        await state.act('session.refresh', {}, 'session');
      }
      expect(
        state.domain('session'),
        isNot(same(previous)),
        reason: 'Change $i',
      );
      expect(state.domain('session'), equals(next), reason: 'Change $i');
    }
  });

  test(
    'equal results retain both pending start and completion notifications',
    () async {
      final original = state.domain('session');
      final pending = <bool>[];
      state.addListener(() => pending.add(state.pending.isNotEmpty));
      final response = native.response = Completer<JsonMap>();
      final operation = state.act('session.refresh', {}, 'session');
      expect(pending, [true]);
      expect(state.domain('session'), same(original));
      response.complete(_copy(original));
      await operation;
      expect(pending, [true, false]);
      expect(state.domain('session'), same(original));
    },
  );

  test('new revision invalidates reader state before equal-value reuse', () {
    final before = state.domain('session');
    final epoch = state.readerPositionEpoch;
    state.readers[_url] = {
      'thread': {'title': 'Previous owner'},
    };
    expect(
      state.recordReaderOffset(_url, 123, revision: 0, epoch: epoch),
      isTrue,
    );
    native.emit('session', _copy(before), revision: 1);
    expect(state.accessRevision, 1);
    expect(state.readerPositionEpoch, epoch + 1);
    expect(state.readerOffset(_url), isNull);
    expect(state.readers, isEmpty);
    expect(state.domain('session'), isNot(same(before)));
    final accepted = state.domain('session');
    native.emit('session', {'account': 'signedOut'}, revision: 0);
    expect(state.domain('session'), same(accepted));
    expect(state.accessRevision, 1);
  });

  test(
    'unchanged session never suppresses other domains or repeated commands',
    () {
      final session = state.domain('session');
      final command = {'destination': 'settings', 'id': 'command'};
      native.emit('snapshot', {
        'session': _copy(session),
        'navigation': command,
      });
      final first = state.domain('navigation');
      native.emit('snapshot', {
        'session': _copy(session),
        'navigation': _copy(command),
        'workspace': {'board': 'tech'},
      });
      expect(state.domain('navigation'), isNot(same(first)));
      expect(state.domain('navigation'), equals(command));
      expect(state.domain('workspace')['board'], 'tech');
      expect(state.domain('session'), same(session));
    },
  );
}
