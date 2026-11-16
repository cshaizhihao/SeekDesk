import 'dart:async';
import 'dart:typed_data';

import '../core/native_client.dart';

/// Account-scoped image bytes and geometry, independent of workspace rebuilds.
/// Callers retain their Future when an entry is evicted; only its current owner
/// can publish metadata or change the budget when the native result arrives.
class ImageMemoryCache {
  ImageMemoryCache({required this.client});

  final NativeClient client;
  static const _entryLimit = 48;
  static const _byteLimit = 24 * 1024 * 1024;
  final _entries = <_ImageKey, _ImageEntry>{};
  int _retainedBytes = 0;
  bool _disposed = false;

  _ImageKey _key(String url, String kind) =>
      (revision: client.accessRevision, kind: kind, url: url);

  JsonMap dimensions(String url, {String kind = 'post'}) =>
      _entries[_key(url, kind)]?.dimensions ?? const {};

  Future<Uint8List> load(String url, {String kind = 'post'}) {
    if (_disposed) {
      return Future<Uint8List>.error(const NativeFailure('disposed', '页面已关闭。'));
    }
    final key = _key(url, kind);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing.completion.future;
    }
    // Install ownership before native code can throw or re-enter this cache.
    final entry = _ImageEntry();
    _entries[key] = entry;
    while (_entries.length > _entryLimit) {
      _forget(_entries.keys.first);
    }
    unawaited(_load(key, entry));
    return entry.completion.future;
  }

  /// A decoding failure belongs to an exact completed request, not just a URL.
  bool evict(
    String url,
    Future<Uint8List> expected, {
    required int revision,
    String kind = 'post',
  }) {
    if (_disposed || revision != client.accessRevision) return false;
    final key = _key(url, kind);
    final entry = _entries[key];
    if (entry == null ||
        !identical(entry.completion.future, expected) ||
        entry.byteCount == null) {
      return false;
    }
    _forget(key);
    return true;
  }

  Future<void> release(String url, {String kind = 'original'}) async {
    _forget(_key(url, kind));
    // Native storage outlives a closing viewer and its Dart state. Always let
    // cleanup reach it, including after disposal, without a late error toast.
    try {
      await client.call('images.release', {'url': url});
    } catch (_) {
      // A failed cleanup must not revive a closed viewer.
    }
  }

  void _checkLifetime(int revision) {
    if (_disposed) throw const NativeFailure('disposed', '页面已关闭。');
    if (revision != client.accessRevision) {
      throw const NativeFailure('stale', '账号已变更。');
    }
  }

  Future<void> _load(_ImageKey key, _ImageEntry entry) async {
    try {
      final value = await client.call('images.load', {
        'url': key.url,
        'kind': key.kind,
      });
      _checkLifetime(key.revision);
      final raw = value['bytes'];
      final bytes = raw is Uint8List
          ? raw
          : raw is List
          ? Uint8List.fromList(raw.cast<int>())
          : null;
      if (bytes == null) throw const NativeFailure('image', '图片暂时无法加载。');
      if (identical(_entries[key], entry)) {
        if (bytes.length > _byteLimit) {
          // One full-size image must not flush every cached avatar/thumbnail.
          // The viewer still receives it, but it is not retained a second time.
          _forget(key);
        } else {
          entry.byteCount = bytes.length;
          entry.dimensions = Map<String, dynamic>.unmodifiable({
            'width': value['width'],
            'height': value['height'],
            'originalWidth': value['originalWidth'],
            'originalHeight': value['originalHeight'],
          });
          _retainedBytes += bytes.length;
          while (_retainedBytes > _byteLimit && _entries.isNotEmpty) {
            _forget(_entries.keys.first);
          }
        }
      }
      entry.completion.complete(bytes);
    } catch (error, stack) {
      if (identical(_entries[key], entry)) _forget(key);
      try {
        _checkLifetime(key.revision);
      } catch (lifetimeError, lifetimeStack) {
        entry.completion.completeError(lifetimeError, lifetimeStack);
        return;
      }
      entry.completion.completeError(error, stack);
    }
  }

  void _forget(_ImageKey key) {
    final removed = _entries.remove(key);
    _retainedBytes -= removed?.byteCount ?? 0;
  }

  void clear() {
    _entries.clear();
    _retainedBytes = 0;
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

typedef _ImageKey = ({int revision, String kind, String url});

class _ImageEntry {
  final completion = Completer<Uint8List>();
  int? byteCount;
  JsonMap dimensions = const {};
}
