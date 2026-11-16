import '../models/reader_position.dart';

/// Silent, bounded in-process progress. The owner checks account/reader lifetime
/// before recording; native storage remains responsible for cross-session saves.
class ReaderPositionMemory {
  final _entries = <String, _ReaderProgress>{};

  // Match native storage: host aliases, fragments and query strings identify
  // the same page, while the page number remains part of the document identity.
  static String pageKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null &&
        const ['nodeseek.com', 'www.nodeseek.com'].contains(uri.host)) {
      final match = RegExp(r'^/post-([0-9]+)-([0-9]+)/?$').firstMatch(uri.path);
      if (match != null) {
        final topic = int.tryParse(match[1]!);
        final page = int.tryParse(match[2]!);
        if (topic != null && topic > 0 && page != null && page > 0) {
          return 'https://www.nodeseek.com/post-$topic-$page';
        }
      }
    }
    return url.split('#').first;
  }

  double? offset(String url) {
    final key = pageKey(url);
    final progress = _entries.remove(key);
    if (progress != null) _entries[key] = progress;
    return progress?.offset;
  }

  ReaderBodyAnchor? bodyAnchor(String url) =>
      _entries[pageKey(url)]?.bodyAnchor;

  bool record(String url, double offset, {ReaderBodyAnchor? bodyAnchor}) {
    if (!offset.isFinite ||
        offset < 0 ||
        offset > 100000000 ||
        bodyAnchor != null &&
            ReaderBodyAnchor.parse(bodyAnchor.toJson()) == null) {
      return false;
    }
    final key = pageKey(url);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        !RegExp(r'^https://www\.nodeseek\.com/post-[1-9][0-9]*-[1-9][0-9]*$')
            .hasMatch(key)) {
      return false;
    }
    _entries.remove(key);
    // Offset and anchor have the same lifetime and are always evicted together.
    _entries[key] = _ReaderProgress(offset, bodyAnchor);
    while (_entries.length > 500) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  void clear() => _entries.clear();
}

class _ReaderProgress {
  const _ReaderProgress(this.offset, this.bodyAnchor);
  final double offset;
  final ReaderBodyAnchor? bodyAnchor;
}
