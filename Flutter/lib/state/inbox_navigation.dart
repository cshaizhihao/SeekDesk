import 'dart:collection';

/// Lightweight, account-scoped UI continuity. No message bodies or drafts are
/// kept here, and nothing is written to preferences or sent to the forum.
class InboxNavigation {
  int _revision = -1;
  int get revision => _revision;
  int _category = 0;
  int? _peer;
  String _peerName = '';
  String _peerAvatar = '';
  int get category => _category;
  int? get peer => _peer;
  String get peerName => _peerName;
  String get peerAvatar => _peerAvatar;
  Map<String, dynamic>? _notice;

  /// A detached, immutable notice DTO; never includes a loaded floor body.
  Map<String, dynamic>? get notice => _notice;
  String? get noticeID => _notice?['id'] as String?;
  final LinkedHashMap<String, double> _offsets = LinkedHashMap();

  void activate(int revision) {
    if (revision <= _revision) return;
    _revision = revision;
    _category = 0;
    _peer = null;
    _peerName = '';
    _peerAvatar = '';
    _notice = null;
    _offsets.clear();
  }

  bool select({
    required int revision,
    required int category,
    int? peer,
    String peerName = '',
    String peerAvatar = '',
  }) {
    if (revision != _revision ||
        category < 0 ||
        category > 2 ||
        (peer != null && (peer <= 0 || category != 2))) {
      return false;
    }
    if (category != _category || category == 2) _notice = null;
    _category = category;
    _peer = peer;
    _peerName = peer == null ? '' : peerName;
    _peerAvatar = peer == null ? '' : peerAvatar;
    return true;
  }

  /// Selects a notice only after an explicit user action. Notice IDs belong to
  /// their category, so moving to another category discards the old selection.
  bool chooseNotice({
    required int revision,
    required int category,
    required Map<String, dynamic> item,
  }) {
    if (revision != _revision || !_noticeCategory(category)) return false;
    final snapshot = _noticeSnapshot(item);
    if (snapshot == null) return false;
    select(revision: revision, category: category);
    _notice = snapshot;
    return true;
  }

  bool clearNotice({required int revision, required int category}) {
    if (revision != _revision ||
        category != _category ||
        !_noticeCategory(category)) {
      return false;
    }
    _notice = null;
    return true;
  }

  bool choosePeer({
    required int revision,
    required int peer,
    String peerName = '',
    String peerAvatar = '',
  }) => select(
    revision: revision,
    category: 2,
    peer: peer,
    peerName: peerName,
    peerAvatar: peerAvatar,
  );

  /// Reconciles a successfully loaded, complete category list. Loading or error
  /// placeholders are not authoritative and must not be passed here. An absent
  /// selection stays absent; a missing selected ID clears it without fallback.
  bool reconcileNotices({
    required int revision,
    required int category,
    required Iterable<Map<String, dynamic>> items,
  }) {
    if (revision != _revision ||
        category != _category ||
        !_noticeCategory(category)) {
      return false;
    }
    final selectedID = noticeID;
    if (selectedID == null) return true;
    for (final item in items) {
      if (item['id'] != selectedID) continue;
      final snapshot = _noticeSnapshot(item);
      if (snapshot == null) return false;
      _notice = snapshot;
      return true;
    }
    _notice = null;
    return true;
  }

  static bool _noticeCategory(int category) => category == 0 || category == 1;

  static Map<String, dynamic>? _noticeSnapshot(Map<String, dynamic> item) {
    final id = item['id'];
    final postID = item['postID'];
    final floor = item['floor'];
    final url = item['url'];
    if (id is! String ||
        id.trim().isEmpty ||
        postID is! int ||
        postID <= 0 ||
        floor is! int ||
        floor < 0 ||
        url is! String ||
        url.trim().isEmpty) {
      return null;
    }
    String text(String key) => item[key] is String ? item[key] as String : '';
    final authorID = item['authorID'];
    return Map<String, dynamic>.unmodifiable({
      'id': id,
      'author': text('author'),
      'authorID': authorID is int && authorID > 0 ? authorID : null,
      'title': text('title'),
      'date': text('date'),
      'unread': item['unread'] == true,
      'postID': postID,
      'floor': floor,
      'url': url,
      'avatar': text('avatar'),
    });
  }

  static bool _validKey(String key) =>
      const ['mentions:', 'replies:', 'messages:'].contains(key) ||
      RegExp(r'^conversation:[1-9][0-9]*$').hasMatch(key);

  double? offset(String key, {required int revision}) {
    if (revision != _revision) return null;
    final value = _offsets.remove(key);
    if (value != null) _offsets[key] = value;
    return value;
  }

  void remember(String key, double offset, {required int revision}) {
    if (revision != _revision ||
        !_validKey(key) ||
        !offset.isFinite ||
        offset < 0 ||
        offset > 100000000) {
      return;
    }
    _offsets.remove(key);
    _offsets[key] = offset;
    while (_offsets.length > 64) {
      _offsets.remove(_offsets.keys.first);
    }
  }
}
