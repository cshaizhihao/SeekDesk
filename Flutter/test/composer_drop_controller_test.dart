import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';

import 'support/composer_drop_fixture.dart';

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('file drop captures once, uploads frozen bytes and creates one undo transaction', () async {
    final editor = DropEditor();
    addTearDown(editor.dispose);
    final original = editor.content.value;
    await editor.drop();
    await _turn();
    expect(editor.content.text, 'before ${droppedMarkdown}after');
    expect(editor.native.calls.map((call) => call.$1), [
      'system.captureComposerDrop',
      'images.keyStatus',
      'images.uploadClipboardSnapshot',
      'images.releaseClipboardSnapshot',
      'system.releaseComposerDrop',
    ]);
    final capture = editor.native
        .arguments('system.captureComposerDrop')
        .single;
    expect(capture, {
      'documentID': editor.media.documentID,
      'operationID': 1,
      'accessRevision': 0,
      'dropToken': 'drop-fixture',
    });
    for (final method in [
      'images.uploadClipboardSnapshot',
      'images.releaseClipboardSnapshot',
    ]) {
      expect(editor.native.arguments(method).single, {
        'documentID': editor.media.documentID,
        'operationID': 1,
        'accessRevision': 0,
        'token': 'frozen-image-fixture',
      });
    }
    expect(editor.media.busy, isFalse);
    expect(editor.applied, 1);
    expect(editor.history.undo(), isTrue);
    expect(editor.content.value, original);
    expect(editor.history.canUndo, isFalse);
    expect(editor.history.redo(), isTrue);
    expect(editor.content.text, 'before ${droppedMarkdown}after');
  });

  for (final reason in ['IME', 'disabled', 'covered', 'disposed']) {
    test(
      'rejected $reason drop releases its credential without capture or upload',
      () async {
        final editor = DropEditor();
        addTearDown(editor.dispose);
        switch (reason) {
          case 'IME':
            editor.content.value = editor.content.value.copyWith(
              composing: const TextRange(start: 0, end: 3),
            );
          case 'disabled':
            editor.enabled = false;
          case 'covered':
            editor.accepts = false;
          case 'disposed':
            editor.retire();
        }
        await editor.drop();
        expect(editor.native.calls.map((call) => call.$1), [
          'system.releaseComposerDrop',
        ]);
        expect(editor.applied, 0);
      },
    );
  }

  test(
    'capture reserves the existing media lock against another drop and paste',
    () async {
      final editor = DropEditor();
      addTearDown(editor.dispose);
      final gate = editor.native.captureGate = Completer<JsonMap>();
      final first = editor.drop('first-drop');
      expect(editor.media.phase, ComposerMediaPhase.capturingDrop);
      await editor.drop('second-drop');
      await editor.media.paste(
        requestKey: () async => null,
        canPasteText: () => true,
      );
      expect(
        editor.native.arguments('system.captureComposerDrop'),
        hasLength(1),
      );
      expect(editor.native.arguments('system.captureComposerPaste'), isEmpty);
      expect(editor.native.arguments('system.releaseComposerDrop'), [
        {'dropToken': 'second-drop'},
      ]);
      gate.complete({...droppedSnapshot});
      await first;
      await _turn();
      expect(
        editor.native.arguments('images.uploadClipboardSnapshot'),
        hasLength(1),
      );
      expect(editor.applied, 1);
    },
  );

  for (final reason in ['route', 'account', 'dispose']) {
    test(
      'late captured drop after $reason releases its image without upload',
      () async {
        final editor = DropEditor();
        addTearDown(editor.dispose);
        final gate = editor.native.captureGate = Completer<JsonMap>();
        final dropping = editor.drop();
        switch (reason) {
          case 'route':
            editor.accepts = false;
          case 'account':
            editor.native.accessRevision = 1;
          case 'dispose':
            editor.retire();
        }
        gate.complete({...droppedSnapshot});
        await dropping;
        expect(
          editor.native.arguments('images.uploadClipboardSnapshot'),
          isEmpty,
        );
        expect(editor.native.arguments('images.keyStatus'), isEmpty);
        expect(
          editor.native.arguments('images.releaseClipboardSnapshot'),
          hasLength(1),
        );
        expect(
          editor.native.arguments('system.releaseComposerDrop'),
          hasLength(1),
        );
        expect(editor.applied, 0);
        expect(editor.content.text, 'before after');
      },
    );
  }

  test(
    'cancelled key dialog frees snapshot and credential with no upload',
    () async {
      final editor = DropEditor();
      addTearDown(editor.dispose);
      editor.native.configured = false;
      editor.requestKey = () async => null;
      await editor.drop();
      expect(editor.prompts, 1);
      expect(editor.media.busy, isFalse);
      expect(
        editor.native.arguments('images.uploadClipboardSnapshot'),
        isEmpty,
      );
      expect(editor.native.arguments('images.setKey'), isEmpty);
      expect(
        editor.native.arguments('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      expect(
        editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
      expect(editor.applied, 0);
    },
  );

  test('upload keeps its bookmark through typing and waits for IME before one insertion', () async {
    final editor = DropEditor();
    addTearDown(editor.dispose);
    final gate = editor.native.uploadGate = Completer<JsonMap>();
    final dropping = editor.drop();
    await _turn();
    expect(editor.media.phase, ComposerMediaPhase.uploadingDrop);
    editor.content.value = const TextEditingValue(
      text: 'new before after',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 3),
    );
    gate.complete({'markdown': droppedMarkdown});
    await dropping;
    await _turn();
    expect(editor.media.phase, ComposerMediaPhase.waitingForComposition);
    expect(editor.applied, 0);
    editor.content.value = editor.content.value.copyWith(
      composing: TextRange.empty,
    );
    await _turn();
    expect(editor.content.text, 'new before ${droppedMarkdown}after');
    expect(editor.applied, 1);
    expect(editor.media.busy, isFalse);
  });

  test(
    'disposal during upload releases once and never inserts the late result',
    () async {
      final editor = DropEditor();
      addTearDown(editor.dispose);
      final gate = editor.native.uploadGate = Completer<JsonMap>();
      final dropping = editor.drop();
      await _turn();
      editor.retire();
      gate.complete({'markdown': droppedMarkdown});
      await dropping;
      expect(editor.applied, 0);
      expect(
        editor.native.arguments('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      expect(
        editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
    },
  );

  test(
    'a file drop can never turn a text or path response into editor content',
    () async {
      final editor = DropEditor();
      addTearDown(editor.dispose);
      editor.native.capture = {
        'kind': 'text',
        'text': '/private/example/image.png',
      };
      await editor.drop();
      expect(editor.content.text, 'before after');
      expect(editor.applied, 0);
      expect(editor.native.arguments('images.keyStatus'), isEmpty);
      expect(
        editor.native.arguments('images.uploadClipboardSnapshot'),
        isEmpty,
      );
      expect(editor.media.feedback, '请拖入单张本地图片。');
      expect(
        editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
    },
  );

  test(
    'capture failures sanitize native details and never retry upload',
    () async {
      final editor = DropEditor();
      addTearDown(editor.dispose);
      editor.native.failure = const NativeFailure(
        'unknown',
        '/private/credential-file.png secret',
      );
      await editor.drop();
      expect(editor.media.feedback, '图片拖放未完成，正文已保留，请重试。');
      expect(
        editor.native.arguments('system.captureComposerDrop'),
        hasLength(1),
      );
      expect(
        editor.native.arguments('images.uploadClipboardSnapshot'),
        isEmpty,
      );
      expect(
        editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
      expect(editor.state.message, isNull);
      expect(editor.content.text, 'before after');
    },
  );
}
