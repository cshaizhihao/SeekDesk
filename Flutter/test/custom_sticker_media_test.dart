import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/composer_sticker_selection.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';

const _choice = CustomStickerSelection(groupID: 'group-a', itemID: 'one.gif');
const _url = 'https://images.example/sticker.gif';
const _markdown = '![表情](<$_url>)';

class _Native extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;
  bool configured = true;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (respond != null) return respond!(method, arguments);
    return switch (method) {
      'stickers.list' => {'packs': <JsonMap>[]},
      'images.keyStatus' => {'configured': configured},
      'images.setKey' || 'request.cancel' => {},
      'stickers.custom.upload' => {'url': _url, 'markdown': _markdown},
      _ => throw StateError('Unexpected service: $method'),
    };
  }
}

class _Editor {
  final native = _Native();
  late final state = AppState(client: native);
  final content = TextEditingController.fromValue(
    const TextEditingValue(
      text: 'word!',
      selection: TextSelection(baseOffset: 0, extentOffset: 4),
    ),
  );
  late final media = ComposerMediaController(
    state: state,
    content: content,
    revision: 0,
    documentIdentity: this,
    canStart: () => true,
    applyEdit: (value) {
      edits++;
      content.value = value;
      return true;
    },
  );
  int edits = 0;
  bool disposed = false;

  Future<void> choose({Future<String?> Function()? requestKey}) =>
      media.chooseSticker(
        presentPicker: (_) async => _choice,
        requestKey: requestKey ?? () async => 'fixture-key',
      );

  void close() {
    if (disposed) return;
    disposed = true;
    media.dispose();
    content.dispose();
  }

  void dispose() {
    close();
    state.dispose();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'official selection never checks a key or starts a custom upload',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      await editor.media.chooseSticker(
        presentPicker: (_) async => const OfficialStickerSelection(' :ac01: '),
        requestKey: () async => fail('Official stickers do not need a key'),
      );
      await _turn();
      expect(editor.content.text, 'word :ac01: !');
      expect(editor.edits, 1);
      expect(editor.native.calls.map((call) => call.$1), ['stickers.list']);
      expect(editor.state.pending, isEmpty);
      expect(editor.state.message, isNull);
    },
  );

  test(
    'custom choice uploads managed IDs and inserts one standard image',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      await editor.choose();
      await _turn();
      expect(editor.content.text, 'word$_markdown!');
      expect(editor.edits, 1);
      expect(editor.media.busy, false);
      expect(editor.native.calls.map((call) => call.$1), [
        'stickers.list',
        'images.keyStatus',
        'stickers.custom.upload',
      ]);
      final args = editor.native.calls.last.$2;
      expect(args['groupID'], 'group-a');
      expect(args['itemID'], 'one.gif');
      expect(
        args['requestId'],
        startsWith('sticker-${editor.media.documentID}-'),
      );
      expect(args.containsKey('path'), false);
      expect(args.containsKey('url'), false);
      expect(editor.state.pending, isEmpty);
      expect(editor.state.message, isNull);
    },
  );

  test(
    'missing key is configured before uploading the same selected item',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.configured = false;
      var prompts = 0;
      await editor.choose(
        requestKey: () async {
          prompts++;
          expect(editor.media.busy, true);
          return ' fixture-key ';
        },
      );
      await _turn();
      expect(prompts, 1);
      expect(editor.native.calls.map((call) => call.$1), [
        'stickers.list',
        'images.keyStatus',
        'images.setKey',
        'stickers.custom.upload',
      ]);
      expect(editor.native.calls[2].$2, {'key': 'fixture-key'});
      expect(editor.content.text, 'word$_markdown!');
      expect(editor.edits, 1);
    },
  );

  test(
    'cancelled key setup leaves the draft intact and allows another selection',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.configured = false;
      await editor.choose(requestKey: () async => null);
      expect(editor.content.text, 'word!');
      expect(editor.edits, 0);
      expect(editor.media.busy, false);
      expect(editor.native.calls.map((call) => call.$1), [
        'stickers.list',
        'images.keyStatus',
      ]);
      editor.native.configured = true;
      await editor.choose();
      await _turn();
      expect(editor.content.text, 'word$_markdown!');
    },
  );

  test(
    'upload follows the original bookmark and waits for active composition',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      final uploaded = Completer<JsonMap>();
      editor.native.respond = (method, args) async => switch (method) {
        'stickers.custom.upload' => uploaded.future,
        _ => {'configured': true, 'packs': <JsonMap>[]},
      };
      final choosing = editor.choose();
      await _turn();
      expect(editor.media.phase, ComposerMediaPhase.uploadingSticker);
      await editor.choose();
      expect(
        editor.native.calls.where(
          (call) => call.$1 == 'stickers.custom.upload',
        ),
        hasLength(1),
      );
      editor.content.value = const TextEditingValue(
        text: '中word!',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      uploaded.complete({'url': _url});
      await choosing;
      await _turn();
      expect(editor.content.text, '中word!');
      expect(editor.media.phase, ComposerMediaPhase.waitingForComposition);
      editor.content.value = editor.content.value.copyWith(
        composing: TextRange.empty,
      );
      await _turn();
      expect(editor.content.text, '中word$_markdown!');
      expect(editor.content.selection.baseOffset, 1);
      expect(editor.edits, 1);
      expect(editor.media.busy, false);
    },
  );

  for (final boundary in [
    'stickers.list',
    'images.keyStatus',
    'images.setKey',
    'stickers.custom.upload',
  ]) {
    test(
      'failure at $boundary is local, preserves the draft and can retry',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        editor.state.message = 'Keep this message';
        editor.native.respond = (method, args) async {
          if (method == boundary) {
            throw const NativeFailure(
              'provider-secret',
              '/private/path?key=not-for-ui',
            );
          }
          return {'configured': false, 'packs': <JsonMap>[]};
        };
        await editor.choose();
        expect(editor.content.text, 'word!');
        expect(editor.media.busy, false);
        expect(editor.media.feedback, isNot(contains('not-for-ui')));
        expect(editor.state.message, 'Keep this message');
        expect(editor.state.pending, isEmpty);
        editor.native.respond = null;
        await editor.choose();
        await _turn();
        expect(editor.content.text, 'word$_markdown!');
        expect(editor.edits, 1);
      },
    );
  }

  for (final close in [false, true]) {
    test(
      '${close ? 'dispose' : 'invalidation'} cancels its own upload and ignores a late result',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        final uploaded = Completer<JsonMap>();
        editor.native.respond = (method, args) async => switch (method) {
          'stickers.custom.upload' => uploaded.future,
          _ => {'configured': true, 'packs': <JsonMap>[]},
        };
        final choosing = editor.choose();
        await _turn();
        final request = editor.native.calls.last.$2['requestId'];
        if (close) {
          editor.close();
        } else {
          editor.native.accessRevision++;
          editor.media.invalidate();
        }
        await _turn();
        expect(editor.native.calls.last.$1, 'request.cancel');
        expect(editor.native.calls.last.$2, {'requestId': request});
        uploaded.complete({'url': _url});
        await choosing;
        await _turn();
        expect(editor.edits, 0);
        expect(
          editor.native.calls.where((call) => call.$1 == 'request.cancel'),
          hasLength(1),
        );
        expect(editor.state.message, isNull);
      },
    );
  }

  for (final boundary in ['picker', 'key']) {
    test(
      'account invalidation keeps $boundary modal busy until it closes',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        final selected = Completer<ComposerStickerSelection?>();
        final key = Completer<String?>();
        editor.native.configured = false;
        final choosing = editor.media.chooseSticker(
          presentPicker: (_) =>
              boundary == 'picker' ? selected.future : Future.value(_choice),
          requestKey: () => key.future,
        );
        await _turn();
        editor.native.accessRevision++;
        editor.media.invalidate();
        expect(editor.media.busy, true);
        if (boundary == 'picker') {
          selected.complete(_choice);
        } else {
          key.complete('fixture-key');
        }
        await choosing;
        expect(editor.media.busy, false);
        expect(editor.edits, 0);
        expect(
          editor.native.calls.any(
            (call) =>
                call.$1 == 'images.setKey' ||
                call.$1 == 'stickers.custom.upload',
          ),
          false,
        );
      },
    );
  }

  for (final url in [
    '',
    'file:///local/private.gif',
    'http://images.example/photo.png',
    'https://user:secret@images.example/photo.png',
  ]) {
    test('invalid upload URL $url never becomes draft text', () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.respond = (method, args) async =>
          method == 'stickers.custom.upload'
          ? {'url': url, 'markdown': 'arbitrary provider text'}
          : {'configured': true, 'packs': <JsonMap>[]};
      await editor.choose();
      expect(editor.content.text, 'word!');
      expect(editor.media.feedback, '未取得有效的表情图片链接，请重试。');
      expect(editor.media.busy, false);
      expect(editor.edits, 0);
    });
  }
}
