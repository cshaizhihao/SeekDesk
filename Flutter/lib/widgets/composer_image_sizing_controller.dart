import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';

@immutable
class DraftImageSize {
  const DraftImageSize({this.ratio = 1, this.previewWidth = 0});

  final double ratio;
  final double previewWidth;

  @override
  bool operator ==(Object other) =>
      other is DraftImageSize &&
      ratio == other.ratio &&
      previewWidth == other.previewWidth;

  @override
  int get hashCode => Object.hash(ratio, previewWidth);
}

class _PendingSize {
  const _PendingSize(this.size, this.generation);
  final DraftImageSize size;
  final int generation;
}

/// Keeps local slider changes separate from confirmed native draft metadata.
/// No image bytes, upload credentials, or Markdown parsing belong here.
class ComposerImageSizingController extends ChangeNotifier {
  ComposerImageSizingController({
    required this.state,
    required this.content,
    required this.revision,
    required this.canChange,
    required this.isCurrent,
    required this.synchronize,
    required this.saveSize,
    this.validateSnapshot,
    required this.onEdited,
  }) : _observedContent = content.text {
    content.addListener(_contentChanged);
    state.addListener(_accessChanged);
    _scheduleReferences();
  }

  final AppState state;
  final TextEditingController content;
  final int revision;

  /// Gates interactive changes. Sending/closing may disable this while still
  /// flushing changes that the user has already made.
  final bool Function() canChange;

  /// Checks the owning editor and target, independently of its busy UI state.
  final bool Function() isCurrent;
  final Future<JsonMap?> Function(String expectedContent) synchronize;
  final Future<JsonMap?> Function(
    String url,
    double ratio,
    double previewWidth,
    String expectedContent,
  )
  saveSize;
  final bool Function(JsonMap)? validateSnapshot;
  final VoidCallback onEdited;

  final Map<String, DraftImageSize> _confirmed = {};
  final Map<String, _PendingSize> _pending = {};
  Set<String> _imageURLs = const {};
  Set<String> get imageURLs => _imageURLs;
  String? _referencesContent;
  String _observedContent;
  int _documentGeneration = 0, _referenceRequest = 0, _editGeneration = 0;
  bool _disposed = false, _invalidated = false, _needsConfirmation = false;
  Timer? _referencesTimer;
  Future<bool>? _flushing;
  bool get busy => _flushing != null;
  bool get hasPendingChanges => _pending.isNotEmpty || _needsConfirmation;
  String? _feedback;
  String? get feedback => _feedback;
  String? _writingURL;

  DraftImageSize sizeFor(String url) =>
      _pending[url]?.size ?? _confirmed[url] ?? const DraftImageSize();

  bool get _current =>
      !_disposed &&
      !_invalidated &&
      revision == state.accessRevision &&
      isCurrent();

  bool stage(String url, double ratio, double previewWidth) {
    if (!_current || !canChange()) return false;
    if (_referencesContent != content.text || !_imageURLs.contains(url)) {
      return false;
    }
    if (!ratio.isFinite ||
        ratio < 0.1 ||
        ratio > 1 ||
        !previewWidth.isFinite ||
        previewWidth <= 0) {
      return false;
    }
    final size = DraftImageSize(
      ratio: ratio,
      previewWidth: previewWidth.clamp(1, 1080).roundToDouble(),
    );
    if (_sameSelection(sizeFor(url), size)) return true;
    final confirmed = _confirmed[url] ?? const DraftImageSize();
    if (_sameSelection(confirmed, size) && _writingURL != url) {
      _pending.remove(url);
    } else {
      _pending[url] = _PendingSize(size, ++_editGeneration);
    }
    _feedback = null;
    onEdited();
    if (!_disposed) notifyListeners();
    return true;
  }

  static bool _sameSelection(DraftImageSize a, DraftImageSize b) =>
      a.ratio == 1 && b.ratio == 1 || a == b;

  /// Concurrent callers share one attempt. A failed or superseded attempt
  /// retains pending choices for an explicit retry; it never loops on errors.
  Future<bool> flush() {
    if (_flushing case final operation?) return operation;
    if (!_current) return Future<bool>.value(false);
    if (!hasPendingChanges) return Future<bool>.value(true);
    final completion = Completer<bool>();
    _flushing = completion.future;
    notifyListeners();
    unawaited(() async {
      var saved = false;
      try {
        saved = await _flush();
      } catch (error) {
        if (_current) {
          _feedback = error is NativeFailure
              ? '${error.message} 图片大小修改已保留，可重试。'
              : '图片大小未保存，修改已保留，可重试。';
        }
      } finally {
        _writingURL = null;
        _flushing = null;
        if (!_disposed) notifyListeners();
        completion.complete(saved);
      }
    }());
    return completion.future;
  }

  Future<bool> _flush() async {
    if (!_current) return false;
    final expectedContent = content.text;
    final documentGeneration = _documentGeneration;
    final synchronized = await synchronize(expectedContent);
    if (!_stillDocument(documentGeneration, expectedContent)) return false;
    if (!_validSnapshot(synchronized, expectedContent)) {
      _feedback = '正文尚未同步，图片大小修改已保留，可重试。';
      return false;
    }
    acceptSnapshot(synchronized!);
    if (!_stillDocument(documentGeneration, expectedContent)) return false;
    if (synchronized['imageSizing'] is List) {
      _needsConfirmation = false;
    } else if (_needsConfirmation) {
      _feedback = '图片大小尚未确认保存，请重试。';
      return false;
    }
    final batch = Map<String, _PendingSize>.of(_pending);
    for (final entry in batch.entries) {
      if (!_stillDocument(documentGeneration, expectedContent)) return false;
      final pending = _pending[entry.key];
      // A newer drag is left for the next explicit flush. Never write an old
      // value over a newer local selection while draining this batch.
      if (pending == null || pending.generation != entry.value.generation) {
        continue;
      }
      if (_referencesContent != expectedContent ||
          !_imageURLs.contains(entry.key)) {
        _feedback = '正文中的图片已变化，图片大小修改已保留，请更新预览后重试。';
        return false;
      }
      _writingURL = entry.key;
      // A lost reply may follow a successful native mutation. Even if current
      // references retire this URL's pending change, the next explicit flush
      // must synchronize metadata before declaring the draft fully saved.
      _needsConfirmation = true;
      final result = await saveSize(
        entry.key,
        pending.size.ratio,
        pending.size.previewWidth,
        expectedContent,
      );
      _writingURL = null;
      if (!_current) return false;
      final validResult = _validSnapshot(result, expectedContent);
      final confirmed =
          validResult && _confirmSavedSize(entry.key, pending.size, result!);
      if (!_stillDocument(documentGeneration, expectedContent)) return false;
      if (!validResult) {
        _feedback = '图片大小未保存，修改已保留，可重试。';
        return false;
      }
      if (!confirmed) {
        _feedback = '图片大小尚未确认保存，修改已保留，可重试。';
        return false;
      }
      acceptSnapshot(result);
      if (!_stillDocument(documentGeneration, expectedContent)) return false;
      if (_pending[entry.key]?.generation == pending.generation) {
        _pending.remove(entry.key);
      }
    }
    _feedback = !hasPendingChanges ? null : '还有新的图片大小修改尚未保存，请重试。';
    return !hasPendingChanges;
  }

  bool _confirmSavedSize(String url, DraftImageSize submitted, JsonMap result) {
    final sizes = _readSizes(result);
    if (sizes == null) return false;
    final confirmed = sizes[url] ?? const DraftImageSize();
    if (!_sameSelection(confirmed, submitted)) return false;
    // The owner and submitted content have been verified, but the current
    // document may have moved on. Acknowledge only this setter's URL so undo
    // can restore its actual saved size. Never adopt stale refs or drop newer
    // slider choices from a later document generation.
    if (confirmed.ratio == 1) {
      _confirmed.remove(url);
    } else {
      _confirmed[url] = confirmed;
    }
    _needsConfirmation = false;
    return true;
  }

  bool _stillDocument(int generation, String text) {
    if (!_current) return false;
    if (generation != _documentGeneration || text != content.text) {
      _feedback = hasPendingChanges ? '正文已变化，图片大小修改已保留，请重试。' : null;
      return false;
    }
    return true;
  }

  bool _validSnapshot(JsonMap? snapshot, String expectedContent) =>
      snapshot != null &&
      _current &&
      snapshot['content'] == expectedContent &&
      (!snapshot.containsKey('accessRevision') ||
          snapshot['accessRevision'] == revision) &&
      (validateSnapshot?.call(snapshot) ?? true);

  /// Only metadata is accepted. This controller never assigns content.value,
  /// selection or composing ranges, even when a result contains a full draft.
  void acceptSnapshot(JsonMap snapshot) {
    if (!_validSnapshot(snapshot, content.text)) return;
    var changed = false;
    if (snapshot['imageURLs'] case final List<dynamic> references) {
      _referencesTimer?.cancel();
      _referencesTimer = null;
      _referenceRequest++;
      _acceptReferences(references, content.text);
      changed = true;
    }
    if (_readSizes(snapshot) case final next?) {
      _confirmed
        ..clear()
        ..addAll(next);
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  static Map<String, DraftImageSize>? _readSizes(JsonMap snapshot) {
    final selections = snapshot['imageSizing'];
    if (selections is! List) return null;
    final sizes = <String, DraftImageSize>{};
    for (final selection in selections) {
      if (selection is! Map) continue;
      final url = selection['url'];
      final ratio = selection['ratio'];
      final width = selection['previewWidth'];
      if (url is! String ||
          !_validImageURL(url) ||
          ratio is! num ||
          !ratio.isFinite ||
          ratio < 0.1 ||
          ratio >= 1 ||
          width is! num ||
          !width.isFinite ||
          width < 1 ||
          width > 1080) {
        continue;
      }
      sizes[url] = DraftImageSize(
        ratio: ratio.toDouble(),
        previewWidth: width.roundToDouble(),
      );
    }
    return sizes;
  }

  static bool _validImageURL(String value) {
    final url = Uri.tryParse(value);
    return url != null &&
        url.scheme == 'https' &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty;
  }

  void _acceptReferences(List<dynamic> references, String text) {
    _imageURLs = Set<String>.unmodifiable(
      references.whereType<String>().where(_validImageURL),
    );
    _referencesContent = text;
    // Only native references for this exact document may retire a deleted
    // image's pending change. Confirmed sizes remain available for text undo.
    final hadPendingChanges = _pending.isNotEmpty;
    _pending.removeWhere((url, _) => !_imageURLs.contains(url));
    if (hadPendingChanges && !hasPendingChanges) _feedback = null;
  }

  void _contentChanged() {
    if (_disposed || _invalidated) return;
    if (revision != state.accessRevision) {
      _accessChanged();
      return;
    }
    final text = content.text;
    if (text == _observedContent) return;
    _observedContent = text;
    _documentGeneration++;
    _referenceRequest++;
    _scheduleReferences();
  }

  void _scheduleReferences() {
    _referencesTimer?.cancel();
    _referencesTimer = Timer(const Duration(milliseconds: 120), () {
      _referencesTimer = null;
      unawaited(_refreshReferences());
    });
  }

  Future<void> _refreshReferences() async {
    if (!_current) return;
    final text = content.text;
    final generation = _documentGeneration;
    final request = ++_referenceRequest;
    try {
      // This read deliberately bypasses AppState.act's mutation deduplication:
      // a newer document may need its references while an older read finishes.
      final result = await state.client.call('images.draftReferences', {
        'content': text,
      });
      if (!_current ||
          request != _referenceRequest ||
          generation != _documentGeneration ||
          result['content'] != text ||
          result['accessRevision'] != revision ||
          result['imageURLs'] is! List) {
        return;
      }
      // The reference-only API has no inline editor token. Its request and
      // document generation provide identity; it never carries saved sizes.
      _acceptReferences(result['imageURLs'] as List, text);
      if (!_disposed) notifyListeners();
    } catch (_) {
      // A failed read leaves metadata intact and can be retried by the next
      // edit or explicit flush. Do not create a repeating parser timer.
    }
  }

  void _accessChanged() {
    if (_disposed || _invalidated || revision == state.accessRevision) return;
    _invalidated = true;
    _referenceRequest++;
    _referencesTimer?.cancel();
    _referencesTimer = null;
    _feedback = '账号已变更，图片大小修改未保存。';
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _referenceRequest++;
    _referencesTimer?.cancel();
    content.removeListener(_contentChanged);
    state.removeListener(_accessChanged);
    super.dispose();
  }
}
