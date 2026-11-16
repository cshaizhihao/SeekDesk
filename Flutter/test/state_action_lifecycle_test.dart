import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

class _LifecycleNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final responses = <Completer<JsonMap>>[];

  @override
  Stream<JsonMap> get snapshots => const Stream.empty();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments}));
    final response = Completer<JsonMap>();
    responses.add(response);
    return response.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a disposed state cannot launch reads, writes or session changes', () async {
    final native = _LifecycleNative();
    final state = AppState(client: native)..dispose();
    for (final method in [
      'workspace.load',
      'discussion.submit',
      'inbox.send',
      'session.signIn',
      'settings.update',
    ]) {
      final result = state.act(method);
      // Complete an incorrectly started request so a regression fails promptly.
      if (native.responses.isNotEmpty) {
        native.responses.last.complete({'unexpected': true});
      }
      expect(await result, isNull, reason: method);
    }
    await state.connect();
    state.showMessage('Late callback');
    expect(native.calls, isEmpty);
    expect(state.pending, isEmpty);
    expect(state.domains, isEmpty);
    expect(state.message, isNull);
  });

  test(
    'disposal retires queued settings writes and an active result',
    () async {
      final native = _LifecycleNative();
      final state = AppState(client: native);
      state.domains['settings'] = {'workspace.readerTextSize': 15};
      final original = state.domain('settings');
      final first = state.act('settings.update', {
        'key': 'workspace.readerTextSize',
        'value': 16,
      }, 'settings');
      final queued = state.act('settings.update', {
        'key': 'workspace.readerTextSize',
        'value': 19,
      }, 'settings');
      expect(native.calls, hasLength(1));
      state.dispose();
      native.responses.single.complete({'workspace.readerTextSize': 16});
      expect(await first, isNull);
      expect(await queued, isNull);
      expect(native.calls, hasLength(1));
      expect(state.domain('settings'), same(original));
      expect(state.pending, isEmpty);
      expect(state.message, isNull);
    },
  );

  test('disposal during the pending notification prevents transport', () async {
    final native = _LifecycleNative();
    final state = AppState(client: native);
    state.addListener(() {
      if (state.pending.isNotEmpty) state.dispose();
    });
    final result = state.act('discussion.submit', {'content': 'Draft text'});
    if (native.responses.isNotEmpty) {
      native.responses.single.complete({'submitted': true});
    }
    expect(await result, isNull);
    expect(native.calls, isEmpty);
    expect(state.pending, isEmpty);
  });

  test(
    'owner change during the pending notification cannot send as the new owner',
    () async {
      final native = _LifecycleNative();
      final state = AppState(client: native);
      addTearDown(state.dispose);
      state.addListener(() {
        if (state.pending.isNotEmpty && native.accessRevision == 0) {
          native.accessRevision = 1;
        }
      });
      final result = state.act('discussion.submit', {'content': 'Old draft'});
      if (native.responses.isNotEmpty) {
        native.responses.single.complete({'submitted': true});
      }
      expect(await result, isNull);
      expect(native.calls, isEmpty);
      expect(state.pending, isEmpty);
    },
  );

  for (final method in [
    'discussion.submit',
    'settings.update',
    'session.signIn',
  ]) {
    test(
      '$method failure from an old owner does not replace current feedback',
      () async {
        final native = _LifecycleNative();
        final state = AppState(client: native);
        addTearDown(state.dispose);
        final result = state.act(method);
        expect(native.calls, hasLength(1));
        native.accessRevision = 1;
        state.message = 'Current owner feedback';
        native.responses.single.completeError(
          const NativeFailure('fixture', 'Previous account private detail'),
        );
        expect(await result, isNull);
        expect(state.message, 'Current owner feedback');
        expect(state.pending, isEmpty);
        expect(
          native.calls,
          hasLength(1),
          reason: 'Writes must never auto-retry.',
        );
      },
    );
  }

  test('a late bootstrap cannot repopulate disposed account data', () async {
    final native = _LifecycleNative();
    final state = AppState(client: native);
    final connection = state.connect();
    state.dispose();
    native.responses.single.complete({
      'version': 'fixture',
      'session': {'account': 'signedIn', 'owner': 123, 'accessRevision': 1},
    });
    await connection;
    expect(state.domains, isEmpty);
    expect(state.bundleVersion, isNull);
    expect(state.accessRevision, 0);
  });
}
