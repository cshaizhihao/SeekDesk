import '../core/native_client.dart';

/// A successful activity page can outlive its widget without retaining a
/// controller, request, context or private data from another account.
class ActivityPaneMemory {
  int? _revision, _memberId, _owner;
  String? _route;
  bool? _signedIn;
  int _page = 1;
  bool _loaded = false, _hasNext = false;
  List<JsonMap> _items = const [];
  final Map<int, double> _offsets = {};

  int get page => _page;
  bool get loaded => _loaded;
  bool get hasNext => _hasNext;
  List<JsonMap> get items => _items;
  double offsetFor(int page) => _offsets[page] ?? 0;

  /// Returns true when the supplied identity invalidates the saved page.
  bool activate({
    required int revision,
    required int memberId,
    required String route,
    required int owner,
    required bool signedIn,
  }) {
    if (_revision == revision &&
        _memberId == memberId &&
        _route == route &&
        _owner == owner &&
        _signedIn == signedIn) {
      return false;
    }
    clear();
    _revision = revision;
    _memberId = memberId;
    _route = route;
    _owner = owner;
    _signedIn = signedIn;
    return true;
  }

  void rememberOffset(int page, double offset) {
    if (!_loaded || page <= 0 || !offset.isFinite || offset < 0) return;
    _offsets.remove(page);
    _offsets[page] = offset;
    while (_offsets.length > 32) {
      _offsets.remove(_offsets.keys.first);
    }
  }

  /// Commit only an accepted successful response. Failed paging leaves the
  /// previous page, its hasNext value and its exact scroll position intact.
  void acceptPage({
    required int page,
    required List<JsonMap> items,
    required bool hasNext,
  }) {
    _page = page;
    _items = List<JsonMap>.unmodifiable(
      items.map((item) => Map<String, dynamic>.unmodifiable(item)),
    );
    _hasNext = hasNext && page < 10000;
    _loaded = true;
  }

  void clear() {
    _revision = null;
    _memberId = null;
    _owner = null;
    _route = null;
    _signedIn = null;
    _page = 1;
    _loaded = false;
    _hasNext = false;
    _items = const [];
    _offsets.clear();
  }
}
