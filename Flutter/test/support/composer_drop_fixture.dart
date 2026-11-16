import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:seekdesk_flutter/core/document_history.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';

const droppedMarkdown = '![](https://example.invalid/drop.png)';
const droppedSnapshot = {'kind': 'image', 'token': 'frozen-image-fixture'};

class DropNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Completer<JsonMap>? captureGate, uploadGate;
  JsonMap capture = {...droppedSnapshot};
  bool configured = true;
  Object? failure;

  List<JsonMap> arguments(String method) => [
    for (final call in calls)
      if (call.$1 == method) call.$2,
  ];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'system.captureComposerDrop':
      case 'system.captureComposerPaste':
        if (failure case final error?) throw error;
        return captureGate?.future ?? capture;
      case 'images.keyStatus':
        return {'configured': configured};
      case 'images.setKey':
        return {'saved': true};
      case 'images.uploadClipboardSnapshot':
        return uploadGate?.future ?? {'markdown': droppedMarkdown};
      case 'images.releaseClipboardSnapshot':
      case 'system.releaseComposerDrop':
        return {'released': true};
      default:
        throw StateError('Unexpected isolated drop fixture method: $method');
    }
  }
}

class DropEditor {
  DropEditor() {
    state = AppState(client: native);
    history = DocumentHistory(controller: content);
    media = ComposerMediaController(
      state: state,
      content: content,
      revision: 0,
      documentIdentity: this,
      canStart: () => enabled,
      applyEdit: (value) {
        applied++;
        return history.apply(value);
      },
    );
  }
  final native = DropNative();
  final content = TextEditingController.fromValue(
    const TextEditingValue(
      text: 'before after',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  final focus = FocusNode();
  late final AppState state;
  late final DocumentHistory history;
  late final ComposerMediaController media;
  bool enabled = true, accepts = true, disposed = false;
  int applied = 0, prompts = 0;
  Future<String?> Function()? requestKey;

  Future<void> drop([String token = 'drop-fixture']) => media.dropImage(
    dropToken: token,
    requestKey: () {
      prompts++;
      return requestKey?.call() ?? Future.value('key-fixture');
    },
    canCaptureDrop: () => accepts,
  );

  void retire() {
    if (disposed) return;
    disposed = true;
    media.dispose();
  }

  void dispose() {
    retire();
    history.dispose();
    content.dispose();
    focus.dispose();
    state.dispose();
  }
}
