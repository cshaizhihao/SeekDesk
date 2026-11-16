import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/document_history.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';

const _image = '![](https://example.invalid/clipboard.png)';
const _snapshot = {
  'kind': 'image',
  'token': 'fixture-image-token',
  'byteCount': 42,
  'mime': 'image/png',
};

class _ClipboardNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  JsonMap capture = {..._snapshot};
  bool configured = true;
  Future<JsonMap?> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    final result = await response?.call(method, args);
    if (result != null) return result;
    return switch (method) {
      'system.captureComposerPaste' => {...capture},
      'images.keyStatus' => {'configured': configured},
      'images.setKey' => {'saved': true},
      'images.uploadClipboardSnapshot' => {
        'url': 'https://example.invalid/clipboard.png',
        'markdown': _image,
      },
      'images.releaseClipboardSnapshot' => {'released': true},
      'system.chooseImage' => {'markdown': '<file-image>'},
      'stickers.list' => {'packs': <JsonMap>[]},
      _ => throw StateError('Unexpected clipboard fixture method: $method'),
    };
  }

  List<JsonMap> argumentsFor(String method) => [
    for (final call in calls)
      if (call.$1 == method) call.$2,
  ];
}

class _Editor {
  _Editor({
    String text = 'alpha beta',
    TextSelection? selection,
    _ClipboardNative? client,
  }) : native = client ?? _ClipboardNative() {
    state = AppState(client: native);
    content = TextEditingController.fromValue(
      TextEditingValue(
        text: text,
        selection: selection ?? TextSelection.collapsed(offset: text.length),
      ),
    );
    history = DocumentHistory(controller: content);
    media = ComposerMediaController(
      state: state,
      content: content,
      revision: state.accessRevision,
      documentIdentity: this,
      canStart: () => enabled,
      applyEdit: (value) {
        if (!allowApply) return false;
        applied++;
        return history.apply(value);
      },
    );
  }

  final _ClipboardNative native;
  late final AppState state;
  late final TextEditingController content;
  late final DocumentHistory history;
  late final ComposerMediaController media;
  bool enabled = true, textAllowed = true, allowApply = true, disposed = false;
  int applied = 0, keyPrompts = 0;
  Future<String?> Function()? requestKey;

  Future<void> paste() => media.paste(
    requestKey: () {
      keyPrompts++;
      return requestKey?.call() ?? Future<String?>.value('fixture-key');
    },
    canPasteText: () => textAllowed,
  );

  void invalidate() {
    native.accessRevision++;
    state.showMessage('Fixture account changed');
  }

  void disposeEditor() {
    if (disposed) return;
    disposed = true;
    media.dispose();
    history.dispose();
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

  test('plain-text-only paste reads once, shares one history edit and never calls image native APIs', () async {
    final editor = _Editor(
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    addTearDown(editor.dispose);
    final original = editor.content.value;
    var reads = 0;
    await editor.media.pasteTextOnly(
      requestText: () async {
        reads++;
        expect(editor.media.busy, true);
        return 'plain';
      },
      canPasteText: () => editor.textAllowed,
    );
    expect(reads, 1);
    expect(editor.native.calls, isEmpty);
    expect(editor.content.text, 'plain beta');
    expect(editor.applied, 1);
    expect(editor.media.busy, false);
    expect(editor.history.undo(), true);
    expect(editor.content.value, original);
    expect(editor.history.canUndo, false);
  });

  for (final reason in ['selectionABA', 'account', 'dispose', 'route']) {
    test(
      'plain-text-only paste rejects $reason and holds busy against image reentry',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        final text = Completer<String?>();
        final original = editor.content.value;
        final pasting = editor.media.pasteTextOnly(
          requestText: () => text.future,
          canPasteText: () => editor.textAllowed,
        );
        await editor.paste();
        expect(editor.native.calls, isEmpty);
        switch (reason) {
          case 'selectionABA':
            editor.content.selection = const TextSelection.collapsed(offset: 0);
            editor.content.value = original;
          case 'account':
            editor.invalidate();
          case 'dispose':
            editor.disposeEditor();
          case 'route':
            editor.textAllowed = false;
        }
        text.complete('obsolete text');
        await pasting;
        expect(editor.applied, 0);
        expect(editor.native.calls, isEmpty);
        if (!editor.disposed) expect(editor.content.value, original);
      },
    );
  }

  test('plain-text-only read errors are sanitized and release busy for a later attempt', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    await editor.media.pasteTextOnly(
      requestText: () async => throw StateError('Sensitive clipboard payload'),
      canPasteText: () => true,
    );
    expect(editor.media.feedback, '粘贴未完成，请重试。');
    expect(editor.media.busy, false);
    expect(editor.history.canUndo, false);
    expect(editor.native.calls, isEmpty);
    await editor.media.pasteTextOnly(
      requestText: () async => null,
      canPasteText: () => true,
    );
    expect(editor.media.busy, false);
    expect(editor.history.canUndo, false);
    expect(editor.native.calls, isEmpty);
  });

  for (final text in ['frozen text', ' \n\t']) {
    test(
      'nonempty frozen text replaces reversed selection once without key or upload ($text)',
      () async {
        final editor = _Editor(
          selection: const TextSelection(baseOffset: 10, extentOffset: 6),
        );
        addTearDown(editor.dispose);
        editor.native.capture = {'kind': 'text', 'text': text};
        final original = editor.content.value;
        await editor.paste();
        expect(editor.content.text, 'alpha $text');
        expect(editor.content.selection.extentOffset, 6 + text.length);
        expect(editor.applied, 1);
        expect(editor.native.calls.map((call) => call.$1), [
          'system.captureComposerPaste',
        ]);
        expect(editor.keyPrompts, 0);
        expect(editor.media.busy, false);
        expect(editor.history.undo(), true);
        expect(editor.content.value, original);
        expect(editor.history.canUndo, false);
        expect(editor.history.redo(), true);
        expect(editor.content.text, 'alpha $text');
      },
    );
  }

  for (final change in [
    'text',
    'selection',
    'textABA',
    'selectionABA',
    'composition',
    'route',
  ]) {
    test(
      'text snapshot cancels on $change instead of overwriting newer editor state',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        final gate = Completer<JsonMap?>();
        editor.native.response = (method, _) =>
            method == 'system.captureComposerPaste'
            ? gate.future
            : Future.value(null);
        final original = editor.content.value;
        final pasting = editor.paste();
        expect(editor.media.phase, ComposerMediaPhase.capturingClipboard);
        switch (change) {
          case 'text':
            editor.content.text = 'new body';
          case 'selection':
            editor.content.selection = const TextSelection.collapsed(offset: 0);
          case 'textABA':
            editor.content.text = 'temporary';
            editor.content.value = original;
          case 'selectionABA':
            editor.content.selection = const TextSelection.collapsed(offset: 0);
            editor.content.value = original;
          case 'composition':
            editor.content.value = original.copyWith(
              composing: const TextRange(start: 0, end: 2),
            );
          case 'route':
            editor.textAllowed = false;
        }
        final latest = editor.content.value;
        gate.complete({'kind': 'text', 'text': 'old clipboard'});
        await pasting;
        expect(editor.content.value, latest);
        expect(editor.applied, 0);
        expect(editor.media.feedback, contains('重新粘贴'));
        expect(editor.media.busy, false);
        expect(editor.native.calls, hasLength(1));
      },
    );
  }

  test('text paste rejects invalid and surrogate-splitting selections without history', () async {
    for (final selection in [
      const TextSelection.collapsed(offset: -1),
      const TextSelection.collapsed(offset: 2),
    ]) {
      final editor = _Editor(text: '甲😀乙', selection: selection);
      addTearDown(editor.dispose);
      editor.native.capture = {'kind': 'text', 'text': 'replacement'};
      final original = editor.content.value;
      await editor.paste();
      expect(editor.content.value, original);
      expect(editor.history.canUndo, false);
      expect(editor.media.feedback, contains('有效的粘贴位置'));
    }
  });

  test(
    'busy, disabled and initial composition never read the clipboard',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.enabled = false;
      await editor.paste();
      editor.enabled = true;
      editor.content.value = editor.content.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await editor.paste();
      editor.content.value = editor.content.value.copyWith(
        composing: TextRange.empty,
      );
      final closed = Completer<void>();
      final settings = editor.media.manageSettings(
        presentSettings: () => closed.future,
      );
      await editor.paste();
      expect(editor.native.calls, isEmpty);
      closed.complete();
      await settings;
    },
  );

  test('image uses one frozen token through first-key configuration and releases after upload', () async {
    final editor = _Editor(
      selection: const TextSelection(baseOffset: 10, extentOffset: 6),
    );
    addTearDown(editor.dispose);
    editor.native.configured = false;
    final original = editor.content.value;
    editor.requestKey = () async {
      expect(editor.media.phase, ComposerMediaPhase.requestingKey);
      expect(editor.media.busy, true);
      editor.native.capture = {'kind': 'text', 'text': 'clipboard changed'};
      return ' fixture-key ';
    };
    await editor.paste();
    await _turn();
    expect(editor.content.text, 'alpha beta$_image');
    expect(editor.applied, 1);
    expect(editor.native.calls.map((call) => call.$1), [
      'system.captureComposerPaste',
      'images.keyStatus',
      'images.setKey',
      'images.uploadClipboardSnapshot',
      'images.releaseClipboardSnapshot',
    ]);
    final capture = editor.native
        .argumentsFor('system.captureComposerPaste')
        .single;
    for (final method in [
      'images.uploadClipboardSnapshot',
      'images.releaseClipboardSnapshot',
    ]) {
      final args = editor.native.argumentsFor(method).single;
      expect(args['documentID'], capture['documentID']);
      expect(args['operationID'], capture['operationID']);
      expect(args['token'], 'fixture-image-token');
    }
    expect(
      editor.native.argumentsFor('images.setKey').single['key'],
      'fixture-key',
    );
    expect(editor.media.busy, false);
    expect(editor.history.undo(), true);
    expect(editor.content.value, original);
    expect(editor.history.canUndo, false);
  });

  test('image preserves newer typing and bookmark while preview disables text paste', () async {
    final editor = _Editor(
      text: 'abcd',
      selection: const TextSelection.collapsed(offset: 2),
    );
    addTearDown(editor.dispose);
    final upload = Completer<JsonMap?>();
    editor.native.response = (method, _) =>
        method == 'images.uploadClipboardSnapshot'
        ? upload.future
        : Future.value(null);
    final pasting = editor.paste();
    await _turn();
    expect(editor.media.phase, ComposerMediaPhase.uploadingClipboard);
    editor.content.value = const TextEditingValue(
      text: 'aXbcd',
      selection: TextSelection.collapsed(offset: 0),
    );
    editor.textAllowed = false;
    upload.complete({'markdown': _image});
    await pasting;
    await _turn();
    expect(editor.content.text, 'aXb${_image}cd');
    expect(editor.content.selection.extentOffset, 0);
    expect(editor.history.undo(), true);
    expect(editor.content.text, 'aXbcd');
    expect(editor.history.undo(), true);
    expect(editor.content.text, 'abcd');
  });

  test(
    'image result waits for composition commit after releasing native snapshot',
    () async {
      final editor = _Editor(text: 'seed');
      addTearDown(editor.dispose);
      final upload = Completer<JsonMap?>();
      editor.native.response = (method, _) =>
          method == 'images.uploadClipboardSnapshot'
          ? upload.future
          : Future.value(null);
      final pasting = editor.paste();
      await _turn();
      const composing = TextEditingValue(
        text: 'seed拼',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 4, end: 5),
      );
      editor.content.value = composing;
      upload.complete({'markdown': _image});
      await pasting;
      await _turn();
      expect(editor.media.phase, ComposerMediaPhase.waitingForComposition);
      expect(editor.media.busy, true);
      expect(editor.content.value, composing);
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      editor.content.value = composing.copyWith(composing: TextRange.empty);
      await _turn();
      expect(editor.content.text, 'seed拼$_image');
      expect(editor.applied, 1);
      expect(editor.media.busy, false);
    },
  );

  test('reentrant paste, upload and sticker attempts cannot duplicate clipboard work', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final capture = Completer<JsonMap?>();
    editor.native.response = (method, _) =>
        method == 'system.captureComposerPaste'
        ? capture.future
        : Future.value(null);
    final pasting = editor.paste();
    await editor.paste();
    await editor.media.upload(requestKey: () async => fail('Reentered upload'));
    await editor.media.chooseSticker(
      presentPicker: (_) async => fail('Reentered sticker'),
    );
    expect(editor.native.calls, hasLength(1));
    capture.complete(_snapshot);
    await pasting;
    await _turn();
    expect(editor.applied, 1);
    expect(
      editor.native.argumentsFor('system.captureComposerPaste'),
      hasLength(1),
    );
    expect(
      editor.native.argumentsFor('images.uploadClipboardSnapshot'),
      hasLength(1),
    );
  });

  for (final at in ['capture', 'keyStatus', 'keyPrompt', 'setKey', 'upload']) {
    for (final disposed in [false, true]) {
      test(
        '${disposed ? 'dispose' : 'account change'} during $at rejects late work and releases token',
        () async {
          final editor = _Editor();
          addTearDown(editor.dispose);
          editor.native.configured = false;
          final gate = Completer<JsonMap?>();
          final key = Completer<String?>();
          final method = switch (at) {
            'capture' => 'system.captureComposerPaste',
            'keyStatus' => 'images.keyStatus',
            'setKey' => 'images.setKey',
            'upload' => 'images.uploadClipboardSnapshot',
            _ => '',
          };
          editor.native.response = (current, _) =>
              current == method ? gate.future : Future.value(null);
          if (at == 'keyPrompt') editor.requestKey = () => key.future;
          final pasting = editor.paste();
          await _turn();
          if (disposed) {
            editor.disposeEditor();
          } else {
            editor.invalidate();
            expect(editor.media.busy, at == 'keyPrompt');
          }
          if (at != 'capture') {
            expect(
              editor.native.argumentsFor('images.releaseClipboardSnapshot'),
              hasLength(1),
            );
          }
          if (at == 'keyPrompt') {
            key.complete('fixture-key');
          } else {
            gate.complete(switch (at) {
              'capture' => _snapshot,
              'keyStatus' => {'configured': false},
              'setKey' => {'saved': true},
              _ => {'markdown': _image},
            });
          }
          await pasting;
          await _turn();
          expect(editor.applied, 0);
          expect(
            editor.native.argumentsFor('images.releaseClipboardSnapshot'),
            hasLength(1),
          );
          expect(
            editor.native.argumentsFor('images.uploadClipboardSnapshot'),
            hasLength(at == 'upload' ? 1 : 0),
          );
          if (!disposed) {
            expect(editor.content.text, 'alpha beta');
            expect(editor.media.busy, false);
            expect(editor.media.feedback, contains('账号已变更'));
          }
        },
      );
    }
  }

  for (final failsAt in [
    'capture',
    'keyStatus',
    'keyPrompt',
    'setKey',
    'upload',
  ]) {
    test(
      '$failsAt errors release snapshot and never expose provider diagnostics',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        editor.native.configured = false;
        const sensitive =
            'secret provider payload / clipboard contents / token';
        final method = switch (failsAt) {
          'capture' => 'system.captureComposerPaste',
          'keyStatus' => 'images.keyStatus',
          'setKey' => 'images.setKey',
          'upload' => 'images.uploadClipboardSnapshot',
          _ => '',
        };
        editor.native.response = (current, _) async {
          if (current == method) {
            throw const NativeFailure('fixture_failure', sensitive);
          }
          return null;
        };
        if (failsAt == 'keyPrompt') {
          editor.requestKey = () async => throw StateError(sensitive);
        }
        await editor.paste();
        expect(editor.content.text, 'alpha beta');
        expect(editor.history.canUndo, false);
        expect(editor.media.busy, false);
        expect(editor.media.feedback, '粘贴未完成，请重试。');
        expect(editor.state.message, isNull);
        expect(
          editor.native.argumentsFor('images.releaseClipboardSnapshot'),
          hasLength(failsAt == 'capture' ? 0 : 1),
        );
      },
    );
  }

  test(
    'cancelled key prompt releases snapshot without upload or history',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.configured = false;
      editor.requestKey = () async => null;
      await editor.paste();
      expect(editor.media.busy, false);
      expect(editor.media.feedback, isNull);
      expect(
        editor.native.argumentsFor('images.uploadClipboardSnapshot'),
        isEmpty,
      );
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      expect(editor.history.canUndo, false);
    },
  );

  test('native clipboard error codes provide fixed useful feedback without leaking raw diagnostics', () async {
    const messages = {
      'clipboard_image_size': '剪贴板图片为空或超过 100 MB，请换一张图片。',
      'clipboard_image_pixels': '剪贴板图片超过 2400 万像素，请先缩小图片。',
      'clipboard_image_frames': '暂不支持粘贴多帧或多页图片，请使用单张静态图片。',
      'clipboard_image_invalid': '无法读取剪贴板图片，请重新复制一张 PNG 或 TIFF 图片。',
      'clipboard_changed': '读取时剪贴板已变化，请重新粘贴。',
      'clipboard_snapshot_expired': '图片粘贴已取消或过期，请重新粘贴。',
      'invalid_clipboard_operation': '图片粘贴已取消或过期，请重新粘贴。',
      'image_key_missing': '请先配置 NodeImage 密钥，再粘贴图片。',
      'image_key_invalid': 'NodeImage 拒绝了密钥，请检查图床设置。',
      'image_key_store': '无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。',
      'clipboard_upload_failed': '图片上传失败，正文已保留，请稍后重新粘贴。',
      'unknown_sensitive_provider_code': '粘贴未完成，请重试。',
    };
    const sensitive =
        'RAW clipboard contents / private API key / provider token';
    for (final entry in messages.entries) {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.response = (method, _) async {
        if (method == 'images.uploadClipboardSnapshot') {
          throw NativeFailure(entry.key, sensitive);
        }
        return null;
      };
      await editor.paste();
      expect(editor.media.feedback, entry.value, reason: entry.key);
      expect(
        editor.media.feedback,
        isNot(contains(sensitive)),
        reason: entry.key,
      );
      expect(editor.state.message, isNull);
      expect(editor.media.busy, false);
      expect(editor.content.text, 'alpha beta');
      expect(editor.history.canUndo, false);
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
    }
  });

  test(
    'cleanup is idempotent and delayed release cannot insert after disposal',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      final release = Completer<JsonMap?>();
      editor.native.response = (method, _) =>
          method == 'images.releaseClipboardSnapshot'
          ? release.future
          : Future.value(null);
      final pasting = editor.paste();
      await _turn();
      expect(editor.media.busy, true);
      expect(editor.applied, 0);
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      editor.media.invalidate();
      editor.disposeEditor();
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      release.complete({'released': true});
      await pasting;
      expect(editor.applied, 0);
      expect(
        editor.native.argumentsFor('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
    },
  );

  test('release rejection does not expose diagnostics or discard a valid finished image', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    editor.native.response = (method, _) async {
      if (method == 'images.releaseClipboardSnapshot') {
        throw const NativeFailure(
          'already_released',
          'Private token provider details',
        );
      }
      return null;
    };
    await editor.paste();
    await _turn();
    expect(editor.content.text, 'alpha beta$_image');
    expect(editor.applied, 1);
    expect(editor.media.busy, false);
    expect(editor.media.feedback, isNull);
    expect(editor.state.message, isNull);
  });

  test(
    'empty capture and refused text apply leave no history and permit retry',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.capture = {'kind': 'empty'};
      await editor.paste();
      expect(editor.history.canUndo, false);
      expect(editor.media.feedback, contains('没有可粘贴'));
      editor.native.capture = {'kind': 'text', 'text': 'new'};
      editor.allowApply = false;
      await editor.paste();
      expect(editor.content.text, 'alpha beta');
      expect(editor.media.feedback, contains('无法粘贴'));
      editor.allowApply = true;
      await editor.paste();
      expect(editor.content.text, 'alpha betanew');
      final captures = editor.native.argumentsFor(
        'system.captureComposerPaste',
      );
      expect(captures.map((args) => args['documentID']).toSet(), {
        editor.media.documentID,
      });
      expect(captures.map((args) => args['operationID']).toSet(), {1, 2, 3});
    },
  );

  test('same text documents have unique owners and old cleanup cannot replace a new result', () async {
    final native = _ClipboardNative();
    final old = _Editor(client: native), current = _Editor(client: native);
    addTearDown(old.dispose);
    addTearDown(current.dispose);
    expect(old.media.documentID, isNot(current.media.documentID));
    final gate = Completer<JsonMap?>();
    native.response = (method, args) =>
        method == 'system.captureComposerPaste' &&
            args['documentID'] == old.media.documentID
        ? gate.future
        : Future.value(null);
    final pasting = old.paste();
    old.disposeEditor();
    await current.paste();
    await _turn();
    gate.complete({..._snapshot, 'token': 'obsolete-token'});
    await pasting;
    expect(current.content.text, 'alpha beta$_image');
    expect(current.applied, 1);
    final releases = native.argumentsFor('images.releaseClipboardSnapshot');
    expect(releases, hasLength(2));
    expect(releases.last['documentID'], old.media.documentID);
    expect(releases.last['token'], 'obsolete-token');
    expect(current.media.busy, false);
  });
}
