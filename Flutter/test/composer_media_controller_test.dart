import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/composer_sticker_selection.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';

class _MediaNative extends NativeClient {
  final calls = <String>[];
  Future<JsonMap> Function(String)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    return await response?.call(method) ??
        switch (method) {
          'images.keyStatus' => {'configured': true},
          'system.chooseImage' => {'markdown': '<image>'},
          _ => <String, dynamic>{},
        };
  }
}

class _Editor {
  _Editor(String text, {TextSelection? selection}) {
    state = AppState(client: native);
    content = TextEditingController.fromValue(
      TextEditingValue(
        text: text,
        selection: selection ?? TextSelection.collapsed(offset: text.length),
      ),
    );
    media = ComposerMediaController(
      state: state,
      content: content,
      revision: state.accessRevision,
      documentIdentity: this,
      canStart: () => enabled,
    );
  }

  final native = _MediaNative();
  late final AppState state;
  late final TextEditingController content;
  late final ComposerMediaController media;
  bool enabled = true, disposed = false;

  Future<void> upload() => media.upload(requestKey: () async => 'fixture-key');

  void disposeEditor() {
    if (disposed) return;
    disposed = true;
    media.dispose();
    content.dispose();
  }

  void dispose() {
    disposeEditor();
    state.dispose();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings share the media lifecycle and leave text and future insertion intact', () async {
    final editor = _Editor('original');
    addTearDown(editor.dispose);
    final closed = Completer<void>();
    var presentations = 0;
    Future<void> present() {
      presentations++;
      return closed.future;
    }

    final managing = editor.media.manageSettings(presentSettings: present);
    expect(editor.media.phase, ComposerMediaPhase.managingSettings);
    expect(editor.media.busy, true);
    await editor.media.manageSettings(presentSettings: present);
    await editor.upload();
    await editor.media.chooseSticker(
      presentPicker: (_) async => const OfficialStickerSelection('<sticker>'),
    );
    expect(presentations, 1);
    expect(editor.native.calls, isEmpty);
    editor.content.value = const TextEditingValue(
      text: 'changed',
      selection: TextSelection.collapsed(offset: 3),
    );
    closed.complete();
    await managing;
    expect(editor.media.busy, false);
    expect(editor.content.text, 'changed');
    expect(editor.content.selection.baseOffset, 3);
    await editor.upload();
    await _turn();
    expect(editor.content.text, 'cha<image>nged');
  });

  test(
    'a failed settings presenter releases busy and permits a clean retry',
    () async {
      final editor = _Editor('original');
      addTearDown(editor.dispose);
      await expectLater(
        editor.media.manageSettings(
          presentSettings: () async =>
              throw StateError('Fixture presenter failure'),
        ),
        throwsStateError,
      );
      expect(editor.media.busy, false);
      var opened = false;
      await editor.media.manageSettings(
        presentSettings: () async {
          opened = true;
        },
      );
      expect(opened, true);
      expect(editor.content.text, 'original');
      expect(editor.native.calls, isEmpty);
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'disposal' : 'account change'} invalidates pending image settings',
      () async {
        final editor = _Editor('original');
        addTearDown(editor.dispose);
        final closed = Completer<void>();
        final managing = editor.media.manageSettings(
          presentSettings: () => closed.future,
        );
        if (dispose) {
          editor.disposeEditor();
        } else {
          editor.native.accessRevision++;
          editor.content.selection = const TextSelection.collapsed(offset: 0);
          expect(editor.media.busy, true);
        }
        closed.complete();
        await managing;
        if (!dispose) {
          expect(editor.content.text, 'original');
          expect(editor.media.feedback, contains('账号已变更'));
          expect(editor.media.busy, false);
          await editor.media.manageSettings(
            presentSettings: () async => fail('Stale editor reopened settings'),
          );
        }
        expect(editor.native.calls, isEmpty);
      },
    );
  }

  test(
    'media inserts after selected words without extending their selection',
    () async {
      final editor = _Editor(
        'alpha beta omega',
        selection: const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      addTearDown(editor.dispose);
      await editor.upload();
      await _turn();
      expect(editor.content.text, 'alpha beta<image> omega');
      expect(
        editor.content.selection,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      expect(editor.media.busy, false);
    },
  );

  test(
    'bookmark follows edits before it while a cursor move keeps its target',
    () async {
      final editor = _Editor(
        'abcd',
        selection: const TextSelection.collapsed(offset: 2),
      );
      addTearDown(editor.dispose);
      final result = Completer<JsonMap>();
      editor.native.response = (method) async =>
          method == 'system.chooseImage' ? result.future : {'configured': true};
      final upload = editor.upload();
      await _turn();
      editor.content.value = const TextEditingValue(
        text: 'XXabcd',
        selection: TextSelection.collapsed(offset: 0),
      );
      editor.content.selection = const TextSelection.collapsed(offset: 1);
      editor.enabled = false; // Temporary UI state must not discard a result.
      result.complete({'markdown': '<image>'});
      await upload;
      await _turn();
      expect(editor.content.text, 'XXab<image>cd');
      expect(editor.content.selection.baseOffset, 1);
    },
  );

  test(
    'replacement overlapping the bookmark inserts after the replacement',
    () async {
      final editor = _Editor(
        'abcdef',
        selection: const TextSelection.collapsed(offset: 3),
      );
      addTearDown(editor.dispose);
      final result = Completer<JsonMap>();
      editor.native.response = (method) async =>
          method == 'system.chooseImage' ? result.future : {'configured': true};
      final upload = editor.upload();
      await _turn();
      editor.content.value = const TextEditingValue(
        text: 'aZf',
        selection: TextSelection.collapsed(offset: 2),
      );
      result.complete({'markdown': '<image>'});
      await upload;
      await _turn();
      expect(editor.content.text, 'aZ<image>f');
      expect(editor.content.selection.baseOffset, 'aZ<image>'.length);
    },
  );

  test(
    'invalid selection appends and a surrogate midpoint cannot split an emoji',
    () async {
      for (final selection in [
        const TextSelection.collapsed(offset: -1),
        const TextSelection.collapsed(offset: 2),
      ]) {
        final editor = _Editor('A😀', selection: selection);
        await editor.upload();
        await _turn();
        expect(editor.content.text, 'A😀<image>');
        expect(editor.content.selection.baseOffset, 'A😀<image>'.length);
        editor.dispose();
      }
    },
  );

  test(
    'composition defers insertion and commits exactly once without reentrancy',
    () async {
      final editor = _Editor(
        'ni',
        selection: const TextSelection.collapsed(offset: 2),
      );
      addTearDown(editor.dispose);
      editor.content.value = editor.content.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await editor.upload();
      await _turn();
      expect(editor.content.text, 'ni');
      expect(editor.content.value.composing, const TextRange(start: 0, end: 2));
      expect(editor.media.phase, ComposerMediaPhase.waitingForComposition);
      final notifications = <String>[];
      editor.content.addListener(() => notifications.add(editor.content.text));
      editor.content.value = const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      );
      // The controller's listener must leave the IME notification unchanged.
      expect(editor.content.text, '你');
      expect(notifications, ['你']);
      await _turn();
      expect(notifications, ['你', '你<image>']);
      expect(editor.content.text, '你<image>');
      expect(editor.media.busy, false);
      editor.content.selection = const TextSelection.collapsed(offset: 0);
      await _turn();
      expect(editor.content.text, '你<image>');
    },
  );

  test(
    'pending composition is invalidated before a new account can commit',
    () async {
      final editor = _Editor('text');
      addTearDown(editor.dispose);
      editor.content.value = editor.content.value.copyWith(
        composing: const TextRange(start: 0, end: 4),
      );
      await editor.upload();
      await _turn();
      editor.native.accessRevision++;
      editor.content.value = editor.content.value.copyWith(
        composing: TextRange.empty,
      );
      await _turn();
      expect(editor.content.text, 'text');
      expect(editor.media.busy, false);
      expect(editor.media.feedback, contains('账号已变更'));
    },
  );

  test(
    'duplicate starts are rejected across upload and sticker operations',
    () async {
      final editor = _Editor('text');
      addTearDown(editor.dispose);
      final result = Completer<JsonMap>();
      editor.native.response = (method) async =>
          method == 'system.chooseImage' ? result.future : {'configured': true};
      final upload = editor.upload();
      await _turn();
      await editor.upload();
      await editor.media.chooseSticker(
        presentPicker: (_) async => const OfficialStickerSelection('<sticker>'),
      );
      expect(editor.native.calls, ['images.keyStatus', 'system.chooseImage']);
      result.complete({'markdown': '<image>'});
      await upload;
      await _turn();
      expect(editor.content.text, 'text<image>');
    },
  );

  test(
    'key, picker cancellation and failed upload release busy for retry',
    () async {
      final editor = _Editor('text');
      addTearDown(editor.dispose);
      editor.native.response = (_) async => {'configured': false};
      await editor.media.upload(requestKey: () async => null);
      expect(editor.media.busy, false);
      expect(editor.native.calls, ['images.keyStatus']);
      editor.native.response = (method) async {
        if (method == 'system.chooseImage') {
          throw const NativeFailure('cancelled', 'cancelled');
        }
        return {'configured': true};
      };
      await editor.upload();
      expect(editor.media.busy, false);
      expect(editor.content.text, 'text');
      editor.native.response = null;
      await editor.upload();
      await _turn();
      expect(editor.content.text, 'text<image>');
      expect(await editor.state.flushDrafts(), true);
    },
  );

  test('sticker picker cancellation and late selected end insertion share lifecycle', () async {
    final editor = _Editor(
      'word!',
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    addTearDown(editor.dispose);
    await editor.media.chooseSticker(presentPicker: (_) async => null);
    expect(editor.media.busy, false);
    final selected = Completer<ComposerStickerSelection?>();
    final choosing = editor.media.chooseSticker(
      presentPicker: (_) => selected.future,
    );
    await _turn();
    expect(editor.media.phase, ComposerMediaPhase.choosingSticker);
    editor.content.selection = const TextSelection.collapsed(offset: 0);
    selected.complete(const OfficialStickerSelection('<sticker>'));
    await choosing;
    await _turn();
    expect(editor.content.text, 'word<sticker>!');
    expect(editor.content.selection.baseOffset, 0);
  });

  for (final failure in [
    'images.keyStatus',
    'images.setKey',
    'system.chooseImage',
  ]) {
    test(
      '$failure failure releases the operation and permits a clean retry',
      () async {
        final editor = _Editor('original');
        addTearDown(editor.dispose);
        editor.native.response = (method) async {
          if (method == failure) {
            throw const NativeFailure('fixture', 'Synthetic failure');
          }
          return {'configured': false};
        };
        await editor.upload();
        expect(editor.media.busy, false);
        expect(editor.content.text, 'original');
        expect(await editor.state.flushDrafts(), true);
        editor.native.response = null;
        await editor.upload();
        await _turn();
        expect(editor.content.text, 'original<image>');
        expect(editor.media.busy, false);
      },
    );
  }

  for (final boundary in [
    'images.keyStatus',
    'requestKey',
    'images.setKey',
    'system.chooseImage',
  ]) {
    for (final dispose in [false, true]) {
      test(
        '${dispose ? 'dispose' : 'access change'} invalidates upload at $boundary',
        () async {
          final editor = _Editor('original');
          addTearDown(editor.dispose);
          final blocked = Completer<JsonMap>(), key = Completer<String?>();
          editor.native.response = (method) async {
            if (method == boundary) return blocked.future;
            if (method == 'images.keyStatus') return {'configured': false};
            if (method == 'system.chooseImage') return {'markdown': '<image>'};
            return {};
          };
          final upload = editor.media.upload(
            requestKey: () => boundary == 'requestKey'
                ? key.future
                : Future.value('fixture-key'),
          );
          await _turn();
          final count = editor.native.calls.length;
          if (dispose) {
            editor.disposeEditor();
          } else {
            editor.native.accessRevision++;
          }
          if (boundary == 'requestKey') {
            key.complete('fixture-key');
          } else {
            blocked.complete({'configured': false, 'markdown': '<image>'});
          }
          await upload;
          await _turn();
          expect(editor.native.calls.length, count);
          if (!dispose) {
            expect(editor.content.text, 'original');
            expect(editor.media.busy, false);
            await editor.upload();
            expect(editor.native.calls.length, count);
          }
        },
      );
    }
  }

  for (final boundary in ['stickers.list', 'presentPicker']) {
    test('access change rejects sticker continuation at $boundary', () async {
      final editor = _Editor('original');
      addTearDown(editor.dispose);
      final listed = Completer<JsonMap>();
      final selected = Completer<ComposerStickerSelection?>();
      var pickerCount = 0;
      editor.native.response = (_) => boundary == 'stickers.list'
          ? listed.future
          : Future.value({'packs': []});
      final choosing = editor.media.chooseSticker(
        presentPicker: (_) {
          pickerCount++;
          return selected.future;
        },
      );
      await _turn();
      editor.native.accessRevision++;
      if (boundary == 'stickers.list') {
        listed.complete({'packs': []});
      } else {
        selected.complete(const OfficialStickerSelection('<sticker>'));
      }
      await choosing;
      await _turn();
      expect(pickerCount, boundary == 'stickers.list' ? 0 : 1);
      expect(editor.content.text, 'original');
      expect(editor.media.busy, false);
    });
  }
}
