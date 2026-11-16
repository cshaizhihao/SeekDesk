import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/native_client.dart';
import 'app_state.dart';

enum RankingPeriod {
  hot('实时', Duration(seconds: 60)),
  daily('日榜', Duration(seconds: 300)),
  weekly('周榜', Duration(seconds: 3600));

  const RankingPeriod(this.label, this.ttl);
  final String label;
  final Duration ttl;
}

/// One public ranking cache and one polling timer for both workspace surfaces.
/// The workspace owns visibility; mounting a ranking widget never fetches.
class RankingsController extends ChangeNotifier {
  RankingsController(this._state, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      _revision = _state.accessRevision,
      _extensions = _state.domains['extensions'],
      _settings = _state.domains['settings'] {
    _state.addListener(_stateChanged);
  }

  final AppState _state;
  final DateTime Function() _now;
  final _snapshots = <RankingPeriod, _RankingSnapshot>{};
  final _failures = <RankingPeriod, _RankingFailure>{};
  final _requests = <RankingPeriod, _RankingRequest>{};
  RankingPeriod _period = RankingPeriod.hot;
  int _revision;
  Object? _extensions, _settings;
  bool _visible = false, _disposed = false;
  Timer? _timer;
  List<JsonMap> _posts = const [], _summaryPosts = const [];

  RankingPeriod get period => _period;
  bool get visible => _visible;
  bool get loading => _requests[_period]?.revision == _revision;
  bool get hasSnapshot => _snapshots.containsKey(_period);
  String? get error => _failures[_period]?.message;
  DateTime? get updatedAt => _snapshots[_period]?.updatedAt;
  List<JsonMap> get posts => _posts;
  List<JsonMap> get summaryPosts => _summaryPosts;

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _timer?.cancel();
    _timer = null;
    if (value) unawaited(refresh());
  }

  Future<void> selectPeriod(RankingPeriod value) {
    if (_disposed) return Future<void>.value();
    if (_period != value) {
      _period = value;
      _timer?.cancel();
      _timer = null;
      _rebuildRows();
      notifyListeners();
    }
    return refresh();
  }

  /// Force bypasses cache age and retry delay, but shares an in-flight request.
  /// In particular, a refresh button cannot turn a second view into an empty
  /// result by colliding with AppState's pending-operation guard.
  Future<void> refresh({bool force = false}) {
    if (_disposed) return Future<void>.value();
    final period = _period;
    final existing = _requests[period];
    if (existing != null && existing.revision == _revision) {
      return existing.done.future;
    }
    if (!force && _nextDue(period).isAfter(_now())) {
      _armTimer();
      return Future<void>.value();
    }
    final request = _RankingRequest(_revision);
    _requests[period] = request;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
    unawaited(_load(period, request, existing?.done.future, force));
    return request.done.future;
  }

  Future<void> _load(
    RankingPeriod period,
    _RankingRequest request,
    Future<void>? previous,
    bool force,
  ) async {
    try {
      // AppState's pending key is period-based, not account-based. A successor
      // identity must wait until the old public request releases that key.
      if (previous != null) await previous;
      if (!_current(request)) return;
      final result = await _state.act('rankings.load', {
        'period': period.name,
        'force': force,
      });
      if (!_current(request)) return;
      final data = result ?? const <String, dynamic>{};
      final message = stringValue(data['error']);
      final valid =
          result != null &&
          data['posts'] is List &&
          stringValue(data['period'], period.name) == period.name;
      if (!valid || message.isNotEmpty) {
        // Native can return its previous public snapshot alongside a failure.
        // Keep that useful content on first mounting too, without marking the
        // failed attempt as a fresh successful cache entry.
        if (valid &&
            !_snapshots.containsKey(period) &&
            jsonItems(data['posts']).isNotEmpty) {
          _snapshots[period] = _snapshot(data);
        }
        _failed(period, message.isEmpty ? '热榜暂时无法加载，请稍后重试。' : message);
      } else {
        _snapshots[period] = _snapshot(data);
        _failures.remove(period);
      }
    } catch (_) {
      if (_current(request)) _failed(period, '热榜暂时无法加载，请稍后重试。');
    } finally {
      if (identical(_requests[period], request)) _requests.remove(period);
      if (!_disposed && request.revision == _revision) {
        _rebuildRows();
        notifyListeners();
        _armTimer();
      }
      request.done.complete();
    }
  }

  bool _current(_RankingRequest request) =>
      !_disposed &&
      request.revision == _revision &&
      request.revision == _state.accessRevision;

  _RankingSnapshot _snapshot(JsonMap data) {
    final seconds = numberValue(data['updatedAt']);
    final updated = seconds.isFinite && seconds > 0 && seconds < 8640000000000
        ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round())
        : null;
    final raw = jsonItems(data['posts']);
    return _RankingSnapshot(
      List<JsonMap>.unmodifiable([
        for (var index = 0; index < raw.length; index++)
          Map<String, dynamic>.unmodifiable({
            ...raw[index],
            'position': intValue(raw[index]['position'], index + 1) > 0
                ? intValue(raw[index]['position'], index + 1)
                : index + 1,
          }),
      ]),
      _now(),
      updated,
    );
  }

  void _failed(RankingPeriod period, String message) {
    final attempts = (_failures[period]?.attempts ?? 0) + 1;
    final seconds = (5 * (1 << (attempts - 1).clamp(0, 4).toInt()))
        .clamp(5, 60)
        .toInt();
    _failures[period] = _RankingFailure(
      message,
      attempts,
      _now().add(Duration(seconds: seconds)),
    );
  }

  DateTime _nextDue(RankingPeriod period) =>
      _failures[period]?.retryAt ??
      _snapshots[period]?.fetchedAt.add(period.ttl) ??
      _now();

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_visible || _requests.containsKey(_period)) return;
    final delay = _nextDue(_period).difference(_now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      if (!_disposed && _visible) unawaited(refresh());
    });
  }

  void _stateChanged() {
    if (_disposed) return;
    final revisionChanged = _revision != _state.accessRevision;
    final extensions = _state.domains['extensions'];
    final settings = _state.domains['settings'];
    final filterChanged = !identical(extensions, _extensions);
    final styleChanged = !identical(settings, _settings);
    _extensions = extensions;
    _settings = settings;
    if (revisionChanged) {
      _revision = _state.accessRevision;
      _snapshots.clear();
      _failures.clear();
      _timer?.cancel();
      _timer = null;
      // Requests remain until their completion so a new identity can wait for
      // the existing native pending key without accepting its old result.
    }
    if (revisionChanged || filterChanged) _rebuildRows();
    if (revisionChanged || filterChanged || styleChanged) notifyListeners();
    if (revisionChanged && _visible) unawaited(refresh());
  }

  void _rebuildRows() {
    final raw = _snapshots[_period]?.posts ?? const <JsonMap>[];
    _posts = _filtered(raw);
    // Preserve original ranks: filtering never backfills from rank eleven.
    _summaryPosts = _filtered(raw.take(10));
  }

  List<JsonMap> _filtered(Iterable<JsonMap> source) {
    final extensions = _state.domain('extensions');
    final blocking = jsonItems(extensions['items'])
        .any((item) => item['id'] == 'block' && item['active'] == true);
    final blocked = blocking
        ? jsonItems(extensions['blocked'])
        : const <JsonMap>[];
    final seen = <String>{};
    return List<JsonMap>.unmodifiable(
      source.where((post) {
        final id = stringValue(post['id']);
        if (id.isEmpty || !seen.add(id)) return false;
        return !blocked.any((author) {
          final authorID = intValue(post['authorID']);
          final blockedID = intValue(author['memberId']);
          if (authorID > 0 && blockedID > 0) return authorID == blockedID;
          final name = stringValue(
            post['normalizedAuthor'],
            stringValue(post['author']).toLowerCase(),
          );
          final blockedName = stringValue(
            author['normalizedName'],
            stringValue(author['name']).toLowerCase(),
          );
          return name.isNotEmpty && name == blockedName;
        });
      }),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _state.removeListener(_stateChanged);
    super.dispose();
  }
}

class _RankingSnapshot {
  const _RankingSnapshot(this.posts, this.fetchedAt, this.updatedAt);
  final List<JsonMap> posts;
  final DateTime fetchedAt;
  final DateTime? updatedAt;
}

class _RankingFailure {
  const _RankingFailure(this.message, this.attempts, this.retryAt);
  final String message;
  final int attempts;
  final DateTime retryAt;
}

class _RankingRequest {
  _RankingRequest(this.revision);
  final int revision;
  final done = Completer<void>();
}
