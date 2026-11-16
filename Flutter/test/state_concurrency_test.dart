import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

class ConcurrencyNative extends NativeClient {
  Future<JsonMap> Function(String, JsonMap)? respond;
  final calls = <(String, JsonMap)>[];
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return await respond?.call(method, args) ?? {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'settings writes serialize per setting and preserve the final drag value',
    () async {
      final native = ConcurrencyNative(), first = Completer<JsonMap>();
      native.respond = (method, args) async => native.calls.length == 1
          ? first.future
          : {'workspace.readerTextSize': args['value']};
      final state = AppState(client: native);
      final a = state.act('settings.update', {
        'key': 'workspace.readerTextSize',
        'value': 16,
      }, 'settings');
      final b = state.act('settings.update', {
        'key': 'workspace.readerTextSize',
        'value': 19,
      }, 'settings');
      await Future<void>.delayed(Duration.zero);
      expect(native.calls.length, 1);
      first.complete({'workspace.readerTextSize': 16});
      await a;
      await b;
      expect(native.calls.length, 2);
      expect(state.domain('settings')['workspace.readerTextSize'], 19);
      state.dispose();
    },
  );
  test('simultaneous reader requests await one native operation', () async {
    final native = ConcurrencyNative(), response = Completer<JsonMap>();
    native.respond = (_, _) => response.future;
    final state = AppState(client: native);
    const url = 'https://www.nodeseek.com/post-17-1';
    final a = state.loadReader(url), b = state.loadReader(url);
    expect(native.calls.length, 1);
    response.complete({
      'url': url,
      'thread': {'title': 'Fixture'},
    });
    await a;
    await b;
    expect(state.readerFor(url)['thread'], isNotNull);
    state.dispose();
  });
  test(
    'closing an in-flight original does not recreate retained image metadata',
    () async {
      final native = ConcurrencyNative(), response = Completer<JsonMap>();
      native.respond = (method, args) async =>
          method == 'images.load' ? response.future : {};
      final state = AppState(client: native);
      const url = 'https://example.test/image.png';
      final loading = state.image(url, kind: 'original');
      await state.releaseImage(url);
      response.complete({
        'bytes': Uint8List.fromList([1]),
        'width': 100,
        'height': 200,
      });
      await loading;
      expect(state.imageDimensions(url, kind: 'original'), isEmpty);
      expect(native.calls.any((item) => item.$1 == 'images.release'), true);
      state.dispose();
    },
  );
  test('quit flush awaits registered drafts and preserves failure', () async {
    final state = AppState(client: ConcurrencyNative());
    final saved = Completer<bool>();
    var second = false;
    state.registerDraftFlusher('first', () => saved.future);
    state.registerDraftFlusher('second', () async {
      second = true;
      return true;
    });
    final flush = state.flushDrafts();
    expect(second, false);
    saved.complete(true);
    expect(await flush, true);
    expect(second, true);
    state.registerDraftFlusher('failed', () async => false);
    expect(await state.flushDrafts(), false);
    state.unregisterDraftFlusher('failed');
    expect(await state.flushDrafts(), true);
    state.dispose();
  });
  test(
    'quit flush rejects an identity change during local persistence',
    () async {
      final client = ConcurrencyNative(), saved = Completer<bool>();
      final state = AppState(client: client);
      state.registerDraftFlusher('draft', () => saved.future);
      final flush = state.flushDrafts();
      client.accessRevision = 1;
      saved.complete(true);
      expect(await flush, false);
      state.dispose();
    },
  );
  test(
    'quit waits for tracked save even after a composer unregisters',
    () async {
      final state = AppState(client: ConcurrencyNative()),
          saved = Completer<bool>();
      state.registerDraftFlusher('composer', () async => true);
      state.trackDraftSave(saved.future);
      state.unregisterDraftFlusher('composer');
      var done = false;
      final flush = state.flushDrafts().then((value) {
        done = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(done, false);
      saved.complete(true);
      expect(await flush, true);
      state.dispose();
    },
  );
  test('failed tracked save cancels the current quit handshake', () async {
    final state = AppState(client: ConcurrencyNative()),
        saved = Completer<bool>();
    state.trackDraftSave(saved.future);
    final flush = state.flushDrafts();
    saved.complete(false);
    expect(await flush, false);
    state.dispose();
  });
}
