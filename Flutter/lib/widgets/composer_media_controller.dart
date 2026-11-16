import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/native_client.dart';
import '../core/composer_sticker_selection.dart';
import '../state/app_state.dart';

enum ComposerMediaPhase {
  idle,
  capturingClipboard,
  capturingDrop,
  checkingKey,
  requestingKey,
  selectingOrUploadingImage,
  uploadingClipboard,
  uploadingDrop,
  choosingSticker,
  uploadingSticker,
  managingSettings,
  waitingForComposition,
}

class _ClipboardSnapshot {
  _ClipboardSnapshot(this.operation, this.token);
  final int operation;
  final String token;
  Future<void>? release;
}

/// One editor owns one controller for its entire lifetime, including preview.
/// The toolbar only starts operations; it never owns their results.
class ComposerMediaController extends ChangeNotifier {
  ComposerMediaController({
    required this.state,
    required this.content,
    required this.revision,
    required this.documentIdentity,
    required this.canStart,
    this.applyEdit,
  }) : _observedValue = content.value {
    content.addListener(_contentChanged);
    state.addListener(_accessChanged);
  }

  final AppState state;
  final TextEditingController content;
  final int revision;
  final Object documentIdentity;
  final bool Function() canStart;
  static final _documentSession = DateTime.now().microsecondsSinceEpoch
      .toRadixString(36);
  static int _nextDocument = 0;
  final String documentID = 'composer-$_documentSession-${++_nextDocument}';

  /// The document owns undo transactions; async media only commits here once
  /// its result is ready and composition has finished.
  final bool Function(TextEditingValue)? applyEdit;

  ComposerMediaPhase _phase = ComposerMediaPhase.idle;
  ComposerMediaPhase get phase => _phase;
  bool get busy => _phase != ComposerMediaPhase.idle || _settingsPresented;
  String? _feedback;
  String? get feedback => _feedback;
  bool _disposed = false, _invalidated = false, _inserting = false;
  bool _settingsPresented = false;
  int _operation = 0, _bookmark = 0;
  int _valueGeneration = 0;
  TextEditingValue _observedValue;
  String _bookmarkText = '';
  String? _pendingInsertion;
  _ClipboardSnapshot? _clipboardSnapshot;
  String? _stickerRequestID;

  int? _begin(ComposerMediaPhase phase) {
    if (_disposed || _invalidated || busy || !canStart()) return null;
    if (revision != state.accessRevision) {
      invalidate();
      return null;
    }
    _bookmarkText = content.text;
    _bookmark = _safeOffset(
      _bookmarkText,
      content.selection.isValid ? content.selection.end : content.text.length,
    );
    _pendingInsertion = null;
    final token = ++_operation;
    _setPhase(phase);
    return token;
  }

  bool _valid(int token) {
    if (_disposed || _invalidated || token != _operation) return false;
    if (revision != state.accessRevision) {
      invalidate();
      return false;
    }
    return true;
  }

  /// Classifies one frozen clipboard snapshot. Text replaces the original
  /// selection; an image follows the existing asynchronous insertion bookmark.
  /// The callback checks the body route/focus independently of this operation's
  /// own media busy state, which stays held throughout capture and upload.
  Future<void> paste({
    required Future<String?> Function() requestKey,
    required bool Function() canPasteText,
  }) => _captureAndUpload(requestKey: requestKey, canPasteText: canPasteText);

  /// A system drag owns an opaque one-shot credential. Capturing it uses the
  /// exact same frozen-image upload, bookmark, undo and release lane as paste.
  Future<void> dropImage({
    required String dropToken,
    required Future<String?> Function() requestKey,
    required bool Function() canCaptureDrop,
  }) async {
    if (dropToken.isEmpty) return;
    try {
      if (!canCaptureDrop()) return;
      await _captureAndUpload(
        requestKey: requestKey,
        canPasteText: () => false,
        dropToken: dropToken,
        canCaptureDrop: canCaptureDrop,
      );
    } finally {
      // Also releases credentials rejected before capture (busy/IME/route).
      // A successful native capture has already consumed this token.
      try {
        await state.client.call('system.releaseComposerDrop', {
          'dropToken': dropToken,
        });
      } catch (_) {
        // Native ownership expiry provides final cleanup after account changes.
      }
    }
  }

  Future<void> _captureAndUpload({
    required Future<String?> Function() requestKey,
    required bool Function() canPasteText,
    String? dropToken,
    bool Function()? canCaptureDrop,
  }) async {
    if (_disposed || _invalidated || _isComposing) return;
    final dropping = dropToken != null;
    final initialValue = content.value;
    final initialGeneration = _valueGeneration;
    final operation = _begin(
      dropping
          ? ComposerMediaPhase.capturingDrop
          : ComposerMediaPhase.capturingClipboard,
    );
    if (operation == null) return;
    _ClipboardSnapshot? snapshot;
    String? insertion, feedback;
    try {
      if (!_valid(operation) || dropping && canCaptureDrop?.call() != true) {
        return;
      }
      // Bypass AppState.act so a late image token remains available for cleanup
      // after account invalidation, and provider errors cannot leak to the UI.
      final capture = await state.client.call(
        dropping ? 'system.captureComposerDrop' : 'system.captureComposerPaste',
        {..._clipboardArgs(operation), 'dropToken': ?dropToken},
      );
      if (capture['kind'] == 'image' &&
          capture['token'] is String &&
          (capture['token'] as String).isNotEmpty) {
        snapshot = _ClipboardSnapshot(operation, capture['token'] as String);
      }
      if (!_valid(operation) || dropping && canCaptureDrop?.call() != true) {
        return;
      }
      // File drags cannot downgrade into text/paths, even if a host returns an
      // unexpected payload. Only the native image snapshot can enter upload.
      if (dropping && capture['kind'] != 'image') {
        feedback = '请拖入单张本地图片。';
        return;
      }
      switch (capture['kind']) {
        case 'text':
          final text = capture['text'];
          if (text is! String) {
            feedback = '剪贴板中没有可粘贴的文字或图片。';
            return;
          }
          feedback = _insertTextSnapshot(
            text,
            initialValue,
            initialGeneration,
            canPasteText,
          );
        case 'image':
          if (snapshot == null) {
            feedback = dropping ? '拖放图片已失效，请重新拖入。' : '剪贴板图片已失效，请重新复制后粘贴。';
            return;
          }
          _clipboardSnapshot = snapshot;
          _setPhase(ComposerMediaPhase.checkingKey);
          if (!_valid(operation)) return;
          final status = await state.client.call('images.keyStatus');
          if (!_valid(operation)) return;
          if (status['configured'] != true) {
            _settingsPresented = true;
            _setPhase(ComposerMediaPhase.requestingKey);
            String? key;
            try {
              if (!_valid(operation)) return;
              key = await requestKey();
            } finally {
              _settingsPresented = false;
              if (!_disposed) notifyListeners();
            }
            if (!_valid(operation) || key == null || key.trim().isEmpty) return;
            await state.client.call('images.setKey', {'key': key.trim()});
            if (!_valid(operation)) return;
          }
          _setPhase(
            dropping
                ? ComposerMediaPhase.uploadingDrop
                : ComposerMediaPhase.uploadingClipboard,
          );
          if (!_valid(operation)) return;
          final uploaded = await state.client.call(
            'images.uploadClipboardSnapshot',
            _clipboardArgs(operation, snapshot.token),
          );
          if (!_valid(operation)) return;
          final markdown = uploaded['markdown'];
          if (markdown is String && markdown.isNotEmpty) {
            insertion = markdown;
          } else {
            feedback = dropping ? '未取得图片上传结果，请重新拖入图片。' : '未取得图片上传结果，请重新粘贴。';
          }
        case 'empty':
          feedback = '剪贴板中没有可粘贴的文字或图片。';
        default:
          feedback = '暂不支持这份剪贴板内容，请复制文字或单张图片后重试。';
      }
    } catch (error) {
      // Native/provider diagnostics may include clipboard or credential data.
      // Only allowlisted codes select fixed feedback; never display messages.
      if (_valid(operation)) {
        feedback = dropping
            ? _dropFailureMessage(error)
            : _pasteFailureMessage(error);
      }
    } finally {
      if (snapshot != null) await _releaseClipboardSnapshot(snapshot);
      if (_valid(operation)) {
        if (insertion != null) _queueInsertion(operation, insertion);
        if (_pendingInsertion == null) _finish(feedback: feedback);
      }
    }
  }

  static String _dropFailureMessage(Object error) =>
      switch (error is NativeFailure ? error.code : null) {
        'clipboard_image_size' => '图片为空或超过 100 MB，请换一张图片。',
        'clipboard_image_pixels' => '图片超过 2400 万像素，请先缩小图片。',
        'clipboard_image_frames' => '暂不支持多帧或多页图片，请使用单张静态图片。',
        'clipboard_image_invalid' => '无法读取这张图片，请换一张图片后重试。',
        'clipboard_snapshot_expired' ||
        'invalid_clipboard_operation' ||
        'composer_drop_expired' ||
        'invalid_composer_drop' => '拖放图片已取消或过期，请重新拖入。',
        'image_key_missing' => '请先配置 NodeImage 密钥，再拖入图片。',
        'image_key_invalid' => 'NodeImage 拒绝了密钥，请检查图床设置。',
        'image_key_store' => '无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。',
        'clipboard_upload_failed' => '图片上传失败，正文已保留，请稍后重新拖入。',
        _ => '图片拖放未完成，正文已保留，请重试。',
      };

  static String _pasteFailureMessage(Object error) =>
      switch (error is NativeFailure ? error.code : null) {
        'clipboard_image_size' => '剪贴板图片为空或超过 100 MB，请换一张图片。',
        'clipboard_image_pixels' => '剪贴板图片超过 2400 万像素，请先缩小图片。',
        'clipboard_image_frames' => '暂不支持粘贴多帧或多页图片，请使用单张静态图片。',
        'clipboard_image_invalid' => '无法读取剪贴板图片，请重新复制一张 PNG 或 TIFF 图片。',
        'clipboard_changed' => '读取时剪贴板已变化，请重新粘贴。',
        'clipboard_snapshot_expired' ||
        'invalid_clipboard_operation' => '图片粘贴已取消或过期，请重新粘贴。',
        'image_key_missing' => '请先配置 NodeImage 密钥，再粘贴图片。',
        'image_key_invalid' => 'NodeImage 拒绝了密钥，请检查图床设置。',
        'image_key_store' => '无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。',
        'clipboard_upload_failed' => '图片上传失败，正文已保留，请稍后重新粘贴。',
        _ => '粘贴未完成，请重试。',
      };

  /// The explicit "paste as plain text" path never classifies or uploads an
  /// image. Its supplied reader runs once and shares the same text safeguards.
  Future<void> pasteTextOnly({
    required Future<String?> Function() requestText,
    required bool Function() canPasteText,
  }) async {
    if (_disposed || _invalidated || _isComposing) return;
    final initialValue = content.value;
    final initialGeneration = _valueGeneration;
    final operation = _begin(ComposerMediaPhase.capturingClipboard);
    if (operation == null) return;
    String? feedback;
    try {
      if (!_valid(operation)) return;
      final text = await requestText();
      if (!_valid(operation)) return;
      feedback = _insertTextSnapshot(
        text ?? '',
        initialValue,
        initialGeneration,
        canPasteText,
      );
    } catch (_) {
      if (_valid(operation)) feedback = '粘贴未完成，请重试。';
    } finally {
      if (_valid(operation)) _finish(feedback: feedback);
    }
  }

  String? _insertTextSnapshot(
    String text,
    TextEditingValue initialValue,
    int initialGeneration,
    bool Function() canPasteText,
  ) {
    if (text.isEmpty) return '剪贴板中没有可粘贴的文字。';
    if (!canPasteText() ||
        _isComposing ||
        initialGeneration != _valueGeneration ||
        content.value != initialValue) {
      return '正文或选区已变化，请重新粘贴。';
    }
    final selection = initialValue.selection;
    if (!selection.isValid ||
        selection.end > initialValue.text.length ||
        _safeOffset(initialValue.text, selection.start) != selection.start ||
        _safeOffset(initialValue.text, selection.end) != selection.end) {
      return '请先在正文中选择有效的粘贴位置。';
    }
    final next = initialValue.copyWith(
      text: initialValue.text.replaceRange(
        selection.start,
        selection.end,
        text,
      ),
      selection: TextSelection.collapsed(
        offset: selection.start + text.length,
        affinity: selection.affinity,
      ),
      composing: TextRange.empty,
    );
    _inserting = true;
    try {
      if (applyEdit case final apply?) {
        if (!apply(next)) return '正文暂时无法粘贴，请重试。';
      } else {
        content.value = next;
      }
    } finally {
      _inserting = false;
    }
    return null;
  }

  JsonMap _clipboardArgs(int operation, [String? token]) => {
    'documentID': documentID,
    'operationID': operation,
    'accessRevision': revision,
    'token': ?token,
  };

  Future<void> _releaseClipboardSnapshot(_ClipboardSnapshot snapshot) {
    if (snapshot.release case final release?) return release;
    final completion = Completer<void>();
    snapshot.release = completion.future;
    unawaited(() async {
      try {
        await state.client.call(
          'images.releaseClipboardSnapshot',
          _clipboardArgs(snapshot.operation, snapshot.token),
        );
      } catch (_) {
        // Native invalidation/expiry also releases bytes. A cleanup request
        // crossing an account revision is deliberately rejected by native.
      } finally {
        if (identical(_clipboardSnapshot, snapshot)) _clipboardSnapshot = null;
        completion.complete();
      }
    }());
    return completion.future;
  }

  Future<void> upload({required Future<String?> Function() requestKey}) async {
    final token = _begin(ComposerMediaPhase.checkingKey);
    if (token == null) return;
    try {
      final status = await state.act('images.keyStatus');
      if (!_valid(token) || status == null) return;
      if (status['configured'] != true) {
        _setPhase(ComposerMediaPhase.requestingKey);
        final key = await requestKey();
        if (!_valid(token) || key == null || key.trim().isEmpty) return;
        final saved = await state.act('images.setKey', {'key': key.trim()});
        if (!_valid(token) || saved == null) return;
      }
      _setPhase(ComposerMediaPhase.selectingOrUploadingImage);
      // The native operation owns both the OS chooser and upload.
      final result = await state.act('system.chooseImage');
      if (!_valid(token) || result == null) return;
      _queueInsertion(token, stringValue(result['markdown']));
    } finally {
      if (_valid(token) && _pendingInsertion == null) _finish();
    }
  }

  Future<void> chooseSticker({
    required Future<ComposerStickerSelection?> Function(List<JsonMap> packs)
    presentPicker,
    Future<String?> Function()? requestKey,
  }) async {
    final token = _begin(ComposerMediaPhase.choosingSticker);
    if (token == null) return;
    String? feedback;
    try {
      final data = await state.client.call('stickers.list');
      if (!_valid(token)) return;
      _settingsPresented = true;
      final ComposerStickerSelection? selection;
      try {
        selection = await presentPicker(jsonItems(data['packs']));
      } finally {
        _settingsPresented = false;
        if (!_disposed) notifyListeners();
      }
      if (!_valid(token) || selection == null) return;
      if (selection is OfficialStickerSelection) {
        _queueInsertion(token, selection.insertion);
        return;
      }
      final custom = selection as CustomStickerSelection;
      _setPhase(ComposerMediaPhase.checkingKey);
      if (!_valid(token)) return;
      final status = await state.client.call('images.keyStatus');
      if (!_valid(token)) return;
      if (status['configured'] != true) {
        if (requestKey == null) {
          feedback = '请先在图床设置中配置 NodeImage 密钥。';
          return;
        }
        _settingsPresented = true;
        _setPhase(ComposerMediaPhase.requestingKey);
        String? key;
        try {
          if (!_valid(token)) return;
          key = await requestKey();
        } finally {
          _settingsPresented = false;
          if (!_disposed) notifyListeners();
        }
        if (!_valid(token) || key == null || key.trim().isEmpty) return;
        await state.client.call('images.setKey', {'key': key.trim()});
        if (!_valid(token)) return;
      }
      _setPhase(ComposerMediaPhase.uploadingSticker);
      if (!_valid(token)) return;
      final requestID = 'sticker-$documentID-$token';
      _stickerRequestID = requestID;
      final JsonMap result;
      try {
        result = await state.client.call('stickers.custom.upload', {
          'groupID': custom.groupID,
          'itemID': custom.itemID,
          'requestId': requestID,
        });
      } finally {
        if (_stickerRequestID == requestID) _stickerRequestID = null;
      }
      if (!_valid(token)) return;
      final url = Uri.tryParse(stringValue(result['url']));
      if (url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        feedback = '未取得有效的表情图片链接，请重试。';
        return;
      }
      _queueInsertion(token, '![表情](<$url>)');
    } catch (error) {
      if (_valid(token)) feedback = _stickerFailureMessage(error);
    } finally {
      if (_valid(token) && _pendingInsertion == null) {
        _finish(feedback: feedback);
      }
    }
  }

  static String _stickerFailureMessage(Object error) =>
      switch (error is NativeFailure ? error.code : null) {
        'sticker_missing' => '这张表情已移除，请重新选择。',
        'sticker_invalid' => '无法读取这张表情，请重新导入图片。',
        'image_key_missing' => '请先在图床设置中配置 NodeImage 密钥。',
        'image_key_invalid' => 'NodeImage 拒绝了密钥，请检查图床设置。',
        'image_key_store' => '无法访问 NodeImage 密钥，请检查 macOS 钥匙串权限后重试。',
        'cancelled' => '表情上传已取消，正文已保留。',
        _ => '表情操作未完成，正文已保留，请重试。',
      };

  void _cancelStickerUpload() {
    final requestID = _stickerRequestID;
    if (requestID == null) return;
    _stickerRequestID = null;
    unawaited(() async {
      try {
        await state.client.call('request.cancel', {'requestId': requestID});
      } catch (_) {
        // Cancellation is best effort; the local operation is already invalid.
      }
    }());
  }

  Future<void> manageSettings({
    required Future<void> Function() presentSettings,
  }) async {
    final token = _begin(ComposerMediaPhase.managingSettings);
    if (token == null) return;
    _settingsPresented = true;
    try {
      await presentSettings();
    } finally {
      _settingsPresented = false;
      if (_valid(token)) {
        _finish();
      } else if (!_disposed) {
        // Account invalidation must not unlock the underlying route while its
        // settings dialog is still open. Release that hold only on dismissal.
        notifyListeners();
      }
    }
  }

  void _queueInsertion(int token, String insertion) {
    if (insertion.isEmpty) return;
    _pendingInsertion = insertion;
    if (_isComposing) _setPhase(ComposerMediaPhase.waitingForComposition);
    _scheduleInsertion(token);
  }

  bool get _isComposing =>
      content.value.composing.isValid && !content.value.composing.isCollapsed;

  void _scheduleInsertion(int token) {
    // Never mutate an EditableText value reentrantly from its IME notification.
    scheduleMicrotask(() {
      if (!_valid(token) || _pendingInsertion == null) return;
      if (_isComposing) {
        if (_phase != ComposerMediaPhase.waitingForComposition) {
          _setPhase(ComposerMediaPhase.waitingForComposition);
        }
        return;
      }
      final insertion = _pendingInsertion!;
      _pendingInsertion = null;
      final value = content.value;
      final anchor = _safeOffset(value.text, _bookmark);
      int shift(int offset) {
        if (offset < 0) return offset;
        final safe = _safeOffset(value.text, offset);
        final followsInsertion =
            safe > anchor ||
            safe == anchor &&
                (value.selection.isCollapsed ||
                    value.selection.start >= anchor);
        return safe + (followsInsertion ? insertion.length : 0);
      }

      final selection = value.selection.isValid
          ? value.selection.copyWith(
              baseOffset: shift(value.selection.baseOffset),
              extentOffset: shift(value.selection.extentOffset),
            )
          : TextSelection.collapsed(offset: anchor + insertion.length);
      _inserting = true;
      try {
        final next = value.copyWith(
          text: value.text.replaceRange(anchor, anchor, insertion),
          selection: selection,
          composing: TextRange.empty,
        );
        if (applyEdit case final apply?) {
          if (!apply(next)) {
            _pendingInsertion = insertion;
            _setPhase(ComposerMediaPhase.waitingForComposition);
          }
        } else {
          content.value = next;
        }
      } finally {
        _inserting = false;
        if (_valid(token) && _pendingInsertion == null) _finish();
      }
    });
  }

  void _contentChanged() {
    if (_disposed || _invalidated) return;
    if (content.value != _observedValue) {
      _observedValue = content.value;
      _valueGeneration++;
    }
    if (!busy || _inserting) return;
    if (!_valid(_operation)) return;
    // Settings never insert content. Ordinary editor listeners still save text.
    if (_phase == ComposerMediaPhase.managingSettings) return;
    final next = content.text;
    if (next != _bookmarkText) {
      final previous = _bookmarkText;
      var start = 0;
      while (start < previous.length &&
          start < next.length &&
          previous.codeUnitAt(start) == next.codeUnitAt(start)) {
        start++;
      }
      var oldEnd = previous.length, newEnd = next.length;
      while (oldEnd > start &&
          newEnd > start &&
          previous.codeUnitAt(oldEnd - 1) == next.codeUnitAt(newEnd - 1)) {
        oldEnd--;
        newEnd--;
      }
      if (_bookmark >= start) {
        _bookmark = _bookmark > oldEnd ? _bookmark + newEnd - oldEnd : newEnd;
      }
      _bookmark = _safeOffset(next, _bookmark);
      _bookmarkText = next;
    }
    if (_pendingInsertion != null) _scheduleInsertion(_operation);
  }

  static int _safeOffset(String text, int offset) {
    final clamped = offset.clamp(0, text.length);
    if (clamped > 0 && clamped < text.length) {
      final before = text.codeUnitAt(clamped - 1),
          after = text.codeUnitAt(clamped);
      if (before >= 0xd800 &&
          before <= 0xdbff &&
          after >= 0xdc00 &&
          after <= 0xdfff) {
        return clamped + 1;
      }
    }
    return clamped;
  }

  void _setPhase(ComposerMediaPhase next) {
    _phase = next;
    _feedback = switch (next) {
      ComposerMediaPhase.idle => null,
      ComposerMediaPhase.capturingClipboard => '正在读取剪贴板…',
      ComposerMediaPhase.capturingDrop => '正在读取拖入的图片…',
      ComposerMediaPhase.checkingKey => '正在检查图片上传设置…',
      ComposerMediaPhase.requestingKey => '请完成上传密钥设置',
      ComposerMediaPhase.selectingOrUploadingImage => '正在选择或上传图片…',
      ComposerMediaPhase.uploadingClipboard => '正在上传剪贴板图片…',
      ComposerMediaPhase.uploadingDrop => '正在上传图片…',
      ComposerMediaPhase.choosingSticker => '正在选择表情…',
      ComposerMediaPhase.uploadingSticker => '正在上传自定义表情…',
      ComposerMediaPhase.managingSettings => '图床设置已打开',
      ComposerMediaPhase.waitingForComposition => '图片或表情已就绪，完成当前输入后插入',
    };
    notifyListeners();
  }

  void _finish({String? feedback}) {
    _pendingInsertion = null;
    _bookmarkText = '';
    _phase = ComposerMediaPhase.idle;
    _feedback = feedback;
    notifyListeners();
  }

  void _accessChanged() {
    if (!_disposed && !_invalidated && revision != state.accessRevision) {
      invalidate();
    }
  }

  void invalidate() {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    _cancelStickerUpload();
    if (_clipboardSnapshot case final snapshot?) {
      unawaited(_releaseClipboardSnapshot(snapshot));
    }
    _operation++;
    _pendingInsertion = null;
    _bookmarkText = '';
    _phase = ComposerMediaPhase.idle;
    _feedback = '账号已变更，请重新打开编辑器。';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelStickerUpload();
    if (_clipboardSnapshot case final snapshot?) {
      unawaited(_releaseClipboardSnapshot(snapshot));
    }
    _operation++;
    _pendingInsertion = null;
    content.removeListener(_contentChanged);
    state.removeListener(_accessChanged);
    super.dispose();
  }
}
