import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native_client.dart';
import '../core/frame_diagnostics.dart';
import '../core/official_stickers.dart';
import '../models/reader_position.dart';
import '../models/snapshots.dart';
import 'inbox_drafts.dart';
import 'inbox_navigation.dart';
import 'image_memory_cache.dart';
import 'rankings_controller.dart';
import 'profile_space_memory.dart';
import 'reader_position_memory.dart';
import 'value_tool_memory.dart';

class AppState extends ChangeNotifier {
  AppState({NativeClient? client}) : client = client ?? NativeClient() {
    this.client.methods.setMethodCallHandler((call) async {
      if (call.method == 'lifecycle.flush') {
        return {'saved': await flushDrafts()};
      }
      throw MissingPluginException('Unsupported host callback ${call.method}');
    });
  }
  final NativeClient client;
  String? _bundleVersion, _bundleBuild;
  String? get bundleVersion => _bundleVersion;
  String? get bundleBuild => _bundleBuild;
  final ValueToolStore _valueTools = ValueToolStore();
  ValueToolStore get valueTools {
    _valueTools.activate(
      accessRevision,
      intValue(domain('session')['owner']),
      signedIn,
    );
    return _valueTools;
  }

  final ProfileSpaceStore _profileSpaces = ProfileSpaceStore();
  ProfileSpaceStore get profileSpaces {
    _profileSpaces.activate(
      accessRevision,
      intValue(domain('session')['owner']),
      signedIn,
    );
    return _profileSpaces;
  }

  InboxDraftStore? _inboxDrafts;
  InboxDraftStore get inboxDrafts {
    final drafts = _inboxDrafts ??= InboxDraftStore(
      write:
          ({
            required revision,
            required peer,
            required content,
            required markdown,
          }) async {
            if (_disposed || revision != accessRevision) {
              throw const NativeFailure('cancelled', '私信草稿所属账号已改变。');
            }
            try {
              await client.call('inbox.updateDraft', {
                'peer': peer,
                'content': content,
                'markdown': markdown,
              });
            } catch (_) {
              if (!_disposed && revision == accessRevision) {
                showMessage('私信草稿保存失败，文字已保留。请返回对话重试保存。');
              }
              rethrow;
            }
            if (_disposed || revision != accessRevision) {
              throw const NativeFailure('cancelled', '私信草稿所属账号已改变。');
            }
          },
    );
    drafts.activate(accessRevision);
    return drafts;
  }

  final InboxNavigation _inboxNavigation = InboxNavigation();
  final Map<String, _InboxReadRequest> _inboxReads = {};
  InboxNavigation get inboxNavigation {
    _inboxNavigation.activate(accessRevision);
    return _inboxNavigation;
  }

  RankingsController? _rankings;
  RankingsController get rankings => _rankings ??= RankingsController(this);
  final Map<String, JsonMap> domains = {};
  final Map<String, JsonMap> readers = {};
  final _readerPositions = ReaderPositionMemory();
  final Map<String, ReaderNavigation> _readerNavigations = {};
  final Set<String> _retiredReaderFragments = {};
  int _readerPositionEpoch = 0;
  int _readerNavigationSequence = 0;
  final Set<String> pending = {};
  late final _imageCache = ImageMemoryCache(client: client);
  OfficialStickerCatalog? _officialStickers;
  _OfficialStickerRequest? _officialStickerRequest;
  int? _officialStickerRevision;
  int _officialStickerGeneration = 0;
  final Map<String, _ReaderLoadRequest> _readerLoads = {};
  final LinkedHashMap<String, _ReaderAuthorRequest> _readerAuthors =
      LinkedHashMap();
  int _readerGeneration = 0;
  final Map<String, Future<JsonMap?>> _writes = {};
  final Map<_SharedReadKey, _SharedReadRequest> _sharedReads = {};
  final Map<String, _SharedReadRequest> _sharedReadTails = {};
  final Map<Object, Future<bool> Function()> _draftFlushers = {};
  final Map<Object, Future<bool> Function()> _workspaceLeaveGuards = {};
  final Map<Object, Future<bool> Function(Set<String>)> _topicCloseGuards = {};
  final Set<Future<bool>> _pendingDraftSaves = {};
  int _draftSaveFailures = 0;
  StreamSubscription<JsonMap>? _subscription;
  bool connecting = true;
  String? connectionError;
  String? message;
  int _messageRevision = 0;
  Timer? _messageTimer;
  bool _disposed = false;
  final _watchPopupDeferred = ValueNotifier<bool>(false);
  int _watchPopupLeases = 0;
  int navigationRevision = 0;
  Future<void> _tabMutationTail = Future<void>.value();
  int _tabMutationCount = 0;
  bool get changingTabs => _tabMutationCount > 0;

  JsonMap? _workspaceSource;
  WorkspaceData? _workspaceValue;
  WorkspaceData get workspace {
    final source = domains['workspace'];
    if (!identical(source, _workspaceSource) || _workspaceValue == null) {
      _workspaceSource = source;
      _workspaceValue = WorkspaceData(source ?? {});
    }
    return _workspaceValue!;
  }

  JsonMap domain(String name) => domains[name] ?? {};
  JsonMap get profile => jsonMap(domain('session')['profile']);
  bool get signedIn => domain('session')['account'] == 'signedIn';
  int get accessRevision => client.accessRevision;

  /// Modal surfaces can temporarily keep the above-Navigator keyword popup
  /// out of the way without acknowledging or dismissing native notifications.
  ValueListenable<bool> get watchPopupDeferred => _watchPopupDeferred;

  /// Each owner releases only its own lease, including after route animations.
  /// Repeated or late releases remain harmless after the app is disposed.
  VoidCallback deferWatchPopup() {
    if (_disposed) return () {};
    _watchPopupLeases++;
    if (_watchPopupLeases == 1) _watchPopupDeferred.value = true;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_disposed) return;
      _watchPopupLeases--;
      if (_watchPopupLeases == 0) _watchPopupDeferred.value = false;
    };
  }

  int get readerPositionEpoch => _readerPositionEpoch;

  bool ownsReaderPosition(int revision, int epoch) =>
      !_disposed && revision == accessRevision && epoch == _readerPositionEpoch;

  static String _readerPage(String url) => ReaderPositionMemory.pageKey(url);

  double? readerOffset(String url) => _readerPositions.offset(url);

  ReaderBodyAnchor? readerBodyAnchor(String url) =>
      _readerPositions.bodyAnchor(url);

  /// Scroll observations are synchronous and silent. Neither a late reader
  /// response nor a persistence acknowledgement may replace this newer value.
  bool recordReaderOffset(
    String url,
    double offset, {
    required int revision,
    required int epoch,
    ReaderBodyAnchor? bodyAnchor,
  }) =>
      ownsReaderPosition(revision, epoch) &&
      _readerPositions.record(url, offset, bodyAnchor: bodyAnchor);

  ReaderNavigation? readerNavigation(String url) =>
      _readerNavigations[_readerPage(url)];

  ReaderNavigation? takeReaderNavigation(String url) =>
      _readerNavigations.remove(_readerPage(url));

  /// A retained tab's fragment belongs to the account that opened it. New
  /// explicit navigation and the current account's saved anchor are separate.
  bool canRestoreReaderURLFragment(String url) =>
      !_retiredReaderFragments.contains(_readerPage(url));

  void registerDraftFlusher(Object key, Future<bool> Function() callback) {
    _draftFlushers[key] = callback;
  }

  void unregisterDraftFlusher(Object key) {
    _draftFlushers.remove(key);
  }

  bool get hasWorkspaceLeaveGuard => _workspaceLeaveGuards.isNotEmpty;

  void registerWorkspaceLeaveGuard(Object key, Future<bool> Function() guard) =>
      _workspaceLeaveGuards[key] = guard;

  void unregisterWorkspaceLeaveGuard(Object key) =>
      _workspaceLeaveGuards.remove(key);

  Future<bool> prepareWorkspaceLeave() async {
    final revision = accessRevision;
    final guards = Map.of(_workspaceLeaveGuards);
    for (final entry in guards.entries) {
      if (!identical(_workspaceLeaveGuards[entry.key], entry.value)) continue;
      try {
        if (!await entry.value()) return false;
      } catch (_) {
        return false;
      }
      if (_disposed || revision != accessRevision) return false;
    }
    // A newly opened editor must not inherit an earlier editor's approval.
    return !_disposed &&
        revision == accessRevision &&
        _workspaceLeaveGuards.entries.every(
          (entry) => identical(guards[entry.key], entry.value),
        );
  }

  void registerTopicCloseGuard(
    Object key,
    Future<bool> Function(Set<String>) callback,
  ) => _topicCloseGuards[key] = callback;

  void unregisterTopicCloseGuard(Object key) => _topicCloseGuards.remove(key);

  Future<bool> _prepareTopicClose(Set<String> ids) async {
    final revision = accessRevision;
    for (final guard in List.of(_topicCloseGuards.values)) {
      try {
        if (!await guard(ids)) return false;
      } catch (_) {
        return false;
      }
      if (_disposed || revision != accessRevision) return false;
    }
    return true;
  }

  void trackDraftSave(Future<bool> operation) {
    late final Future<bool> tracked;
    tracked = operation
        .then(
          (saved) {
            if (!saved) _draftSaveFailures++;
            return saved;
          },
          onError: (Object error) {
            _draftSaveFailures++;
            return false;
          },
        )
        .whenComplete(() => _pendingDraftSaves.remove(tracked));
    _pendingDraftSaves.add(tracked);
  }

  Future<bool> flushDrafts() async {
    final revision = accessRevision;
    final failures = _draftSaveFailures;
    final callbacks = List<Future<bool> Function()>.of(_draftFlushers.values);
    for (final callback in callbacks) {
      try {
        if (!await callback()) return false;
      } catch (_) {
        return false;
      }
    }
    while (_pendingDraftSaves.isNotEmpty) {
      final pending = List<Future<bool>>.of(_pendingDraftSaves);
      if ((await Future.wait(pending)).any((saved) => !saved)) return false;
    }
    if (_disposed ||
        revision != accessRevision ||
        failures != _draftSaveFailures) {
      return false;
    }
    final drafts = _inboxDrafts;
    if (drafts != null) {
      drafts.activate(accessRevision);
      if (!await drafts.flushAll(revision: revision)) return false;
    }
    return !_disposed &&
        revision == accessRevision &&
        failures == _draftSaveFailures;
  }

  Future<void> connect() async {
    if (_disposed) return;
    connecting = true;
    connectionError = null;
    _notify();
    _subscription ??= client.snapshots.listen(
      _event,
      onError: (Object error) {
        if (_disposed) return;
        connectionError = error.toString();
        _notify();
      },
    );
    try {
      final snapshot = await client.call('bootstrap');
      if (!_disposed) _bootstrap(snapshot);
    } catch (error) {
      if (!_disposed) connectionError = error.toString();
    } finally {
      connecting = false;
      _notify();
    }
  }

  void _bootstrap(JsonMap snapshot) {
    final session = jsonMap(snapshot['session']);
    final revision = intValue(
      session['accessRevision'] ?? snapshot['accessRevision'],
      accessRevision,
    );
    if (revision < accessRevision) return;
    _acceptRevision(revision);
    // Bundle metadata belongs to this process, not an account. Partial session
    // snapshots must not erase it or turn invalid values into display strings.
    _bundleVersion = _bundleString(snapshot['version']) ?? _bundleVersion;
    _bundleBuild = _bundleString(snapshot['build']) ?? _bundleBuild;
    for (final entry in snapshot.entries) {
      if (entry.key == 'version' || entry.key == 'build') continue;
      if (entry.value is Map) _storeDomain(entry.key, jsonMap(entry.value));
    }
    final reader = jsonMap(snapshot['reader']);
    if (reader.isNotEmpty) _reader(reader);
  }

  static String? _bundleString(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  void _storeDomain(String name, JsonMap value) {
    if (name == 'session' && _sameSnapshotValue(domains[name], value)) return;
    domains[name] = value;
  }

  static bool _sameSnapshotValue(Object? current, Object? next) {
    if (identical(current, next)) return true;
    if (current is Map && next is Map) {
      if (current.length != next.length) return false;
      for (final key in current.keys) {
        if (!next.containsKey(key) ||
            !_sameSnapshotValue(current[key], next[key])) {
          return false;
        }
      }
      return true;
    }
    if (current is List && next is List) {
      if (current.length != next.length) return false;
      for (var index = 0; index < current.length; index++) {
        if (!_sameSnapshotValue(current[index], next[index])) return false;
      }
      return true;
    }
    return current == next;
  }

  void _acceptRevision(int revision) {
    if (revision == accessRevision) return;
    _retiredReaderFragments
      ..clear()
      ..addAll(workspace.tabs.map((topic) => _readerPage(topic.url)));
    client.accessRevision = revision;
    _inboxDrafts?.activate(revision);
    _inboxNavigation.activate(revision);
    _profileSpaces.clear();
    _valueTools.clear();
    _readerPositionEpoch++;
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      FrameDiagnostics.recordReaderEvent(
        ReaderTimingEvent.accessRevision,
        accessRevision: revision,
        positionEpoch: _readerPositionEpoch,
      );
    }
    _readerPositions.clear();
    _readerNavigations.clear();
    readers.clear();
    _readerAuthors.clear();
    domains.remove('reader');
    _imageCache.clear();
    _clearOfficialStickers();
    domains.remove('session');
    domains.remove('inbox');
    domains.remove('discussion');
    domains.remove('conversation');
  }

  void _event(JsonMap event) {
    final domainName = stringValue(event['domain']);
    final data = jsonMap(event['data']);
    final revision = intValue(event['accessRevision'], accessRevision);
    if (revision < accessRevision) return;
    if (revision > accessRevision) _acceptRevision(revision);
    if (domainName == 'snapshot' ||
        domainName == 'bootstrap' ||
        domainName.isEmpty) {
      _bootstrap(data.isEmpty ? event : data);
    } else if (domainName == 'reader') {
      // Native returns reader documents through correlated method results.
      // Ignore legacy or queued events without a request ID: a closed reader
      // is indistinguishable from a reopened request for the same URL.
      // loadReader owns loading; revision invalidation above still applies.
    } else {
      _storeDomain(domainName, data);
    }
    _notify();
  }

  void _reader(JsonMap value) {
    final url = stringValue(value['url']);
    if (url.isNotEmpty) {
      final key = url.split('#').first;
      final previous = readers[key];
      if (value['loading'] == true &&
          value['thread'] is! Map &&
          previous?['thread'] is Map) {
        value = {...value, 'thread': previous!['thread']};
      }
      final offset = readerOffset(url);
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        FrameDiagnostics.recordReaderEvent(
          ReaderTimingEvent.readerResult,
          accessRevision: accessRevision,
          positionEpoch: _readerPositionEpoch,
          savedPixels: value['scrollOffset'] is num
              ? numberValue(value['scrollOffset'])
              : null,
          localPixels: offset,
          hasBodyAnchor: value['bodyAnchor'] is Map,
          hasThread: value['thread'] is Map,
          hasOwner: intValue(domain('session')['owner']) > 0,
        );
      }
      if (offset != null) value = {...value, 'scrollOffset': offset};
      readers.remove(key);
      readers[key] = value;
      while (readers.length > 8) {
        readers.remove(readers.keys.first);
      }
    }
    domains['reader'] = value;
  }

  JsonMap readerFor(String url) =>
      readers[url.split('#').first] ?? <String, dynamic>{};

  Future<JsonMap?> act(
    String method, [
    JsonMap arguments = const {},
    String? domainName,
  ]) async {
    if (_disposed) return null;
    if (method == 'profile.load' ||
        method == 'profile.introduction' ||
        method == 'extensions.list') {
      final revision = accessRevision;
      final result = await _sharedRead(method, arguments);
      if (_disposed || revision != accessRevision || result == null) {
        return null;
      }
      if (domainName != null && result.isNotEmpty) {
        _applyResult(result, domainName);
        _notify();
      }
      return result;
    }
    if (method == 'reader.load') {
      final url = stringValue(arguments['url']);
      await loadReader(url, force: arguments['force'] == true);
      final snapshot = readerFor(url);
      return snapshot.isEmpty ? null : snapshot;
    }
    if (method == 'settings.update') {
      final key = stringValue(arguments['key']);
      final revision = accessRevision;
      final previous = _writes[key];
      final operation = () async {
        if (previous != null) await previous;
        if (_disposed || revision != accessRevision) return null;
        return _perform(method, arguments, domainName);
      }();
      _writes[key] = operation;
      try {
        return await operation;
      } finally {
        if (identical(_writes[key], operation)) _writes.remove(key);
      }
    }
    return _perform(method, arguments, domainName);
  }

  Future<JsonMap?> _sharedRead(String method, JsonMap arguments) {
    if (_disposed) return Future<JsonMap?>.value();
    final key = (
      method: method,
      id: arguments['id'],
      force: arguments['force'] == true,
      revision: accessRevision,
    );
    final existing = _sharedReads[key];
    if (existing != null) return existing.completion.future;
    final values = Map<String, dynamic>.unmodifiable(arguments);
    final pendingKey = _pendingKey(method, values);
    final previous = _sharedReadTails[pendingKey];
    final request = _SharedReadRequest(key.revision);
    _sharedReads[key] = request;
    _sharedReadTails[pendingKey] = request;
    unawaited(_loadSharedRead(key, values, pendingKey, request, previous));
    return request.completion.future;
  }

  /// Share an active category read, but retry a cancelled predecessor when the
  /// user has returned to it. Native selection cancellation and transport
  /// deduplication otherwise leave A → B → A without a request for A.
  Future<JsonMap?> loadInbox(
    String kind, {
    int? peer,
    bool force = false,
    bool Function()? isCurrent,
  }) async {
    final revision = accessRevision;
    bool accepts() =>
        !_disposed && revision == accessRevision && (isCurrent?.call() ?? true);
    final key = '$kind:${peer ?? ''}';
    while (accepts()) {
      final previous = _inboxReads[key];
      if (previous != null) {
        final result = await previous.completion.future;
        if (!accepts()) return null;
        if (!force &&
            previous.revision == revision &&
            result != null &&
            result['kind'] == kind &&
            result['peer'] == peer) {
          _applyResult(result, 'inbox');
          _notify();
          return result;
        }
        // Another waiter may already own the released transport slot.
        continue;
      }
      final request = _InboxReadRequest(revision);
      _inboxReads[key] = request;
      JsonMap? result;
      try {
        result = await act('inbox.load', {
          'kind': kind,
          'peer': ?peer,
          if (force) 'force': true,
        }, 'inbox');
      } finally {
        if (identical(_inboxReads[key], request)) _inboxReads.remove(key);
        request.completion.complete(
          !_disposed && revision == accessRevision ? result : null,
        );
      }
      return accepts() ? result : null;
    }
    return null;
  }

  Future<void> _loadSharedRead(
    _SharedReadKey key,
    JsonMap arguments,
    String pendingKey,
    _SharedReadRequest request,
    _SharedReadRequest? previous,
  ) async {
    JsonMap? result;
    try {
      // _perform's pending key excludes force and account revision. A forced
      // read or a new owner must wait for that transport slot to be released.
      if (previous != null) await previous.completion.future;
      if (_disposed || request.revision != accessRevision) return;
      result = await _perform(
        key.method,
        arguments,
        null,
        readRevision: request.revision,
      );
    } finally {
      if (identical(_sharedReads[key], request)) _sharedReads.remove(key);
      if (identical(_sharedReadTails[pendingKey], request)) {
        _sharedReadTails.remove(pendingKey);
      }
      request.completion.complete(
        !_disposed && request.revision == accessRevision ? result : null,
      );
    }
  }

  String _pendingKey(String method, JsonMap arguments) =>
      '$method:${['url', 'id', 'kind', 'key', 'topicID', 'peer', 'period', 'name', 'base', 'quote', 'query', 'scope', 'floor', 'amount', 'cycle', 'expires', 'asking', 'rate'].map((key) => arguments[key] ?? '').join(':')}';

  Future<JsonMap?> _perform(
    String method,
    JsonMap arguments,
    String? domainName, {
    int? readRevision,
  }) async {
    bool acceptsRead() =>
        !_disposed && (readRevision == null || readRevision == accessRevision);
    if (!acceptsRead()) return null;
    final key = _pendingKey(method, arguments);
    if (pending.contains(key)) return null;
    pending.add(key);
    final revision = accessRevision;
    _notify();
    try {
      if (!acceptsRead() || revision != accessRevision) return null;
      final result = await client.call(method, arguments);
      if (!acceptsRead()) return null;
      if (revision != accessRevision &&
          !method.startsWith('session.') &&
          intValue(result['accessRevision'], -1) != accessRevision) {
        return null;
      }
      _applyResult(result, domainName, arguments);
      return result;
    } catch (error) {
      if (!_disposed &&
          acceptsRead() &&
          revision == accessRevision &&
          (error is! NativeFailure || error.code != 'cancelled')) {
        showMessage(error.toString());
      }
      return null;
    } finally {
      pending.remove(key);
      _notify();
    }
  }

  void _applyResult(
    JsonMap result,
    String? domainName, [
    JsonMap arguments = const {},
  ]) {
    if (result.containsKey('workspace') || result.containsKey('session')) {
      _bootstrap(result);
    } else if (result.containsKey('domain')) {
      _event(result);
    } else if (domainName != null && result.isNotEmpty) {
      if (domainName == 'reader') {
        _reader({
          ...result,
          if (!result.containsKey('url')) 'url': arguments['url'],
        });
      } else {
        _storeDomain(domainName, result);
      }
    }
  }

  /// Background tabs retain the current destination and reader. In particular,
  /// do not increment navigationRevision or fetch a body before it is selected.
  Future<void> openTopicInBackground(TopicData topic) async {
    await act('reader.open', {
      'url': topic.url,
      'background': true,
    }, 'workspace');
  }

  Future<void> openTopic(TopicData topic) async {
    await tryOpenTopic(topic);
  }

  /// Tools only dismiss after navigation succeeds. A currently selected URL is
  /// not proof of success: opening that same URL can still fail or be cancelled.
  Future<bool> tryOpenTopic(TopicData topic) async {
    if (hasWorkspaceLeaveGuard && !await prepareWorkspaceLeave()) return false;
    if (_disposed) return false;
    final navigation = ++navigationRevision;
    final revision = accessRevision;
    _notify();
    final result = await act('reader.open', {
      'url': topic.url,
      if (topic.id.isNotEmpty) 'id': topic.id,
    }, 'workspace');
    if (result == null ||
        _disposed ||
        revision != accessRevision ||
        navigation != navigationRevision) {
      return false;
    }
    final key = _readerPage(topic.url);
    _readerNavigations.remove(key);
    final fragment = Uri.tryParse(topic.url)?.fragment ?? '';
    final floor = RegExp(r'^(?:comment-)?([0-9]{1,12})$').firstMatch(fragment);
    if (floor != null) {
      _readerNavigations[key] = ReaderNavigation(
        ++_readerNavigationSequence,
        floor[1]!,
      );
      _notify();
    }
    await loadReader(topic.url);
    return !_disposed &&
        revision == accessRevision &&
        navigation == navigationRevision;
  }

  Future<void> selectTopic(TopicData topic) async {
    if (hasWorkspaceLeaveGuard && !await prepareWorkspaceLeave()) return;
    if (_disposed) return;
    final tab = workspace.tabs.where((tab) => tab.id == topic.id).firstOrNull;
    if (tab == null) return;
    final navigation = ++navigationRevision;
    final revision = accessRevision;
    _notify();
    final result = await act('reader.select', {'id': tab.id}, 'workspace');
    if (result == null ||
        _disposed ||
        revision != accessRevision ||
        navigation != navigationRevision) {
      return;
    }
    // Native may have closed this tab or advanced it to another page while
    // selection was in flight. Only read the actual current selection.
    final selected = workspace.selected;
    if (!workspace.showReader || selected == null || selected.id != tab.id) {
      return;
    }
    if (readerFor(selected.url)['thread'] is! Map) {
      await loadReader(selected.url);
    }
  }

  Future<bool> _changeTabs(Future<bool> Function() change) async {
    final revision = accessRevision;
    final previous = _tabMutationTail;
    final finished = Completer<void>();
    _tabMutationTail = finished.future;
    _tabMutationCount++;
    _notify();
    try {
      await previous;
      if (_disposed || revision != accessRevision) return false;
      return await change();
    } finally {
      finished.complete();
      _tabMutationCount--;
      _notify();
    }
  }

  /// Native move targets the destination tab's original index in the array.
  Future<bool> moveTopic(String id, String target) => _changeTabs(() async {
    final ids = workspace.tabs.map((tab) => tab.id).toSet();
    if (id == target || !ids.contains(id) || !ids.contains(target)) {
      return false;
    }
    return await act('reader.move', {'id': id, 'to': target}, 'workspace') !=
        null;
  });

  Future<bool> closeTopic(String id) => _changeTabs(() async {
    final revision = accessRevision;
    if (!workspace.tabs.any((topic) => topic.id == id) ||
        !await _prepareTopicClose({id}) ||
        _disposed ||
        revision != accessRevision) {
      return false;
    }
    final result = await act('reader.close', {'id': id}, 'workspace');
    return result != null && !_disposed && revision == accessRevision;
  });

  Future<bool> closeAllTopics() => _changeTabs(() async {
    final revision = accessRevision;
    if (workspace.tabs.isEmpty) return false;
    if (!await _prepareTopicClose(
      workspace.tabs.map((topic) => topic.id).toSet(),
    )) {
      return false;
    }
    if (!await flushDrafts()) {
      if (!_disposed && revision == accessRevision) {
        showMessage('草稿尚未保存，已保留打开的标签。');
      }
      return false;
    }
    if (_disposed || revision != accessRevision) return false;
    final result = await act('reader.closeAll', {}, 'workspace');
    if (result == null || _disposed || revision != accessRevision) return false;
    _readerGeneration++;
    _readerPositionEpoch++;
    _readerNavigations.clear();
    _readerLoads.clear();
    readers.clear();
    domains.remove('reader');
    _notify();
    return true;
  });

  Future<bool> reopenTopic([String? id]) => _changeTabs(() async {
    if (hasWorkspaceLeaveGuard && !await prepareWorkspaceLeave()) return false;
    final revision = accessRevision;
    if (workspace.closedTabs.isEmpty ||
        id != null && !workspace.closedTabs.any((tab) => tab.id == id)) {
      return false;
    }
    final result = await act('reader.reopen', {'id': ?id}, 'workspace');
    if (result == null || _disposed || revision != accessRevision) return false;
    navigationRevision++;
    _notify();
    final selected = workspace.selected;
    if (selected != null && readerFor(selected.url)['thread'] is! Map) {
      unawaited(loadReader(selected.url));
    }
    return true;
  });

  Future<void> loadReader(String url, {bool force = false}) {
    if (_disposed) return Future<void>.value();
    final key = url.split('#').first;
    final existing = _readerLoads[key];
    final active =
        existing != null &&
        existing.generation == _readerGeneration &&
        existing.accessRevision == accessRevision;
    if (active && !force) {
      return existing.completion.future;
    }
    final request = _ReaderLoadRequest(
      generation: _readerGeneration,
      accessRevision: accessRevision,
      // A force replacement inherits the last stable snapshot, never its
      // predecessor's loading stub. Cancellation must leave a retryable page.
      previous: active ? existing.previous : readers[key],
    );
    // Install ownership before notifying listeners or starting an async call;
    // a listener may synchronously ask for this same page.
    _readerLoads[key] = request;
    unawaited(_loadReader(url, key, request, force: force));
    return request.completion.future;
  }

  bool _ownsReader(String key, _ReaderLoadRequest request) =>
      !_disposed &&
      request.generation == _readerGeneration &&
      identical(_readerLoads[key], request);

  Future<void> _loadReader(
    String url,
    String key,
    _ReaderLoadRequest request, {
    bool force = false,
  }) async {
    try {
      _reader({
        ...?request.previous,
        'url': url,
        'loading': true,
        'error': null,
        'errorCode': null,
        'refreshFailed': false,
      });
      _notify();
      if (!_ownsReader(key, request)) return;
      // Reader ownership is independent of generic action de-duplication. A
      // closed request may still be resolving while a new one uses this URL.
      final result = await client.call('reader.load', {
        'url': url,
        'force': force,
      });
      if (!_ownsReader(key, request)) return;
      // Native may discover a new account and retry the same read internally.
      // Only its response for the current identity may cross that revision.
      if (request.accessRevision != accessRevision &&
          intValue(result['accessRevision'], -1) != accessRevision) {
        return;
      }
      if (result.isEmpty) {
        throw const NativeFailure('empty_reader', '帖子暂时无法加载。');
      }
      _reader({...result, if (!result.containsKey('url')) 'url': url});
    } catch (error) {
      if (!_ownsReader(key, request) ||
          request.accessRevision != accessRevision) {
        return;
      }
      if (error is NativeFailure && error.code == 'cancelled') {
        // Cancellation is not an error page. Restore retained content, or
        // remove the temporary loading entry so a future open can retry.
        if (request.previous case final JsonMap previous) {
          _reader(previous);
        } else {
          readers.remove(key);
          if (stringValue(domains['reader']?['url']).split('#').first == key) {
            domains.remove('reader');
          }
        }
      } else {
        _reader({
          ...?request.previous,
          'url': url,
          'loading': false,
          'error': error.toString(),
          'errorCode': error is NativeFailure ? error.code : 'network',
          'refreshFailed': request.previous?['thread'] is Map,
        });
        showMessage(error.toString());
      }
    } finally {
      if (_ownsReader(key, request)) {
        _readerLoads.remove(key);
        _notify();
      }
      request.completion.complete();
    }
  }

  /// Resolve only ordinary web links; markdown must never launch local files
  /// or an arbitrary installed application through a custom URL scheme.
  static Uri? webLink(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || value.trim().isEmpty) return null;
    final resolved = uri.hasScheme
        ? uri
        : Uri.parse('https://www.nodeseek.com/').resolveUri(uri);
    if (!const ['https', 'http'].contains(resolved.scheme) ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    return resolved;
  }

  Future<void> openLink(String value) async {
    final resolved = webLink(value);
    if (resolved == null) return;
    if (['nodeseek.com', 'www.nodeseek.com'].contains(resolved.host) &&
        RegExp(r'^/post-\d+-\d+/?$').hasMatch(resolved.path)) {
      await openTopic(TopicData({'url': resolved.toString()}));
    } else {
      await act('external.open', {'url': resolved.toString()});
    }
  }

  /// Per-document, bounded coalescing. Only mounted floor widgets ask for an
  /// author; completion rebuilds that widget rather than the whole workspace.
  Object? _readerAuthorSource(String url, int id) {
    final snapshot = readerFor(url);
    final source = snapshot['thread'];
    final body = jsonMap(source);
    if (_disposed ||
        id <= 0 ||
        snapshot['authorProfilesSupported'] != true ||
        snapshot['loading'] == true ||
        source is! Map ||
        !(jsonMap(body['root'])['authorID'] == id ||
            jsonItems(body['replies'])
                .any((floor) => floor['authorID'] == id))) {
      return null;
    }
    return source;
  }

  /// A remounted floor starts with the same geometry as its settled predecessor.
  /// The source check prevents a cached profile leaking into a refreshed page.
  JsonMap? cachedReaderAuthor(String url, int id) {
    final source = _readerAuthorSource(url, id);
    final cached = _readerAuthors['${_readerPage(url)}:$id'];
    return source != null &&
            cached != null &&
            cached.revision == accessRevision &&
            identical(cached.source, source)
        ? cached.value
        : null;
  }

  Future<JsonMap?> readerAuthor(String url, int id) {
    final source = _readerAuthorSource(url, id);
    if (source == null) return Future.value(null);
    final key = '${_readerPage(url)}:$id';
    final existing = _readerAuthors.remove(key);
    if (existing != null && identical(existing.source, source)) {
      _readerAuthors[key] = existing;
      return existing.future;
    }
    final revision = accessRevision;
    late final _ReaderAuthorRequest request;
    final future = () async {
      try {
        final result = await client.call('reader.author', {
          'url': url,
          'id': id,
        });
        if (_disposed ||
            revision != accessRevision ||
            intValue(result['accessRevision'], -1) != revision ||
            !identical(readerFor(url)['thread'], source)) {
          return null;
        }
        final profile = jsonMap(result['profile']);
        if (intValue(profile['member_id'] ?? profile['id'], -1) != id) {
          return null;
        }
        request.value = profile;
        return profile;
      } catch (_) {
        // A missing enrichment is not a failed document and must not toast or
        // trigger another request on every rebuild of this floor.
        return null;
      }
    }();
    request = _ReaderAuthorRequest(source, future, revision);
    _readerAuthors[key] = request;
    while (_readerAuthors.length > 240) {
      _readerAuthors.remove(_readerAuthors.keys.first);
    }
    return future;
  }

  JsonMap imageDimensions(String url, {String kind = 'post'}) =>
      _imageCache.dimensions(url, kind: kind);

  /// A decoded image failure may discard only the bytes that leaf received.
  /// A stale leaf cannot evict a newer request or another account's cache.
  bool evictImageFuture(
    String url,
    Future<Uint8List> expected, {
    required int revision,
    String kind = 'post',
  }) => _imageCache.evict(url, expected, revision: revision, kind: kind);

  /// Reads bundled official sticker metadata without changing global UI state.
  /// Preview widgets own any loading or retry affordance for this request.
  Future<OfficialStickerCatalog> loadOfficialStickers() {
    if (_disposed) {
      return Future<OfficialStickerCatalog>.error(
        const NativeFailure('disposed', '页面已关闭。'),
      );
    }
    final revision = accessRevision;
    if (_officialStickerRevision != revision) {
      _clearOfficialStickers();
      _officialStickerRevision = revision;
    }
    final cached = _officialStickers;
    if (cached != null) {
      final generation = _officialStickerGeneration;
      return Future<OfficialStickerCatalog>.microtask(() {
        _checkOfficialStickerLifetime(revision, generation);
        return cached;
      });
    }
    final existing = _officialStickerRequest;
    if (existing != null) return existing.completion.future;
    final request = _OfficialStickerRequest(
      accessRevision: revision,
      generation: _officialStickerGeneration,
    );
    // Install ownership before calling the native service so simultaneous
    // preview widgets share the same request and completion.
    _officialStickerRequest = request;
    unawaited(_loadOfficialStickers(request));
    return request.completion.future;
  }

  void _checkOfficialStickerLifetime(int revision, int generation) {
    if (_disposed) {
      throw const NativeFailure('disposed', '页面已关闭。');
    }
    if (revision != accessRevision ||
        generation != _officialStickerGeneration) {
      throw const NativeFailure('stale', '账号已变更。');
    }
  }

  Future<void> _loadOfficialStickers(_OfficialStickerRequest request) async {
    try {
      final result = await client.call('stickers.list');
      _checkOfficialStickerLifetime(request.accessRevision, request.generation);
      if (!identical(_officialStickerRequest, request)) {
        throw const NativeFailure('stale', '账号已变更。');
      }
      final catalog = OfficialStickerCatalog.fromPacks(
        jsonItems(result['packs']),
      );
      _officialStickers = catalog;
      request.completion.complete(catalog);
    } catch (error, stack) {
      try {
        _checkOfficialStickerLifetime(
          request.accessRevision,
          request.generation,
        );
      } catch (lifetimeError, lifetimeStack) {
        request.completion.completeError(lifetimeError, lifetimeStack);
        return;
      }
      request.completion.completeError(error, stack);
    } finally {
      // An earlier account's completion must never clear its successor.
      if (identical(_officialStickerRequest, request)) {
        _officialStickerRequest = null;
      }
    }
  }

  void _clearOfficialStickers() {
    _officialStickers = null;
    _officialStickerRequest = null;
    _officialStickerRevision = null;
    _officialStickerGeneration++;
  }

  Future<void> releaseImage(String url, {String kind = 'original'}) =>
      _imageCache.release(url, kind: kind);

  Future<Uint8List> image(String url, {String kind = 'post'}) =>
      _imageCache.load(url, kind: kind);

  void showMessage(String text) {
    if (_disposed) return;
    final revision = ++_messageRevision;
    _messageTimer?.cancel();
    message = text;
    _notify();
    _messageTimer = Timer(const Duration(seconds: 5), () {
      if (_disposed || revision != _messageRevision) return;
      message = null;
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _inboxDrafts?.dispose();
    _profileSpaces.clear();
    _valueTools.clear();
    _watchPopupLeases = 0;
    _watchPopupDeferred.dispose();
    _rankings?.dispose();
    _imageCache.dispose();
    _clearOfficialStickers();
    _readerGeneration++;
    _readerPositionEpoch++;
    _readerPositions.clear();
    _readerNavigations.clear();
    _readerLoads.clear();
    _readerAuthors.clear();
    _sharedReads.clear();
    _sharedReadTails.clear();
    _messageTimer?.cancel();
    client.methods.setMethodCallHandler(null);
    _draftFlushers.clear();
    _workspaceLeaveGuards.clear();
    _topicCloseGuards.clear();
    _subscription?.cancel();
    super.dispose();
  }
}

class _ReaderAuthorRequest {
  _ReaderAuthorRequest(this.source, this.future, this.revision);
  final Object source;
  final Future<JsonMap?> future;
  final int revision;
  JsonMap? value;
}

class _InboxReadRequest {
  _InboxReadRequest(this.revision);
  final int revision;
  final completion = Completer<JsonMap?>();
}

typedef _SharedReadKey = ({
  String method,
  Object? id,
  bool force,
  int revision,
});

class _SharedReadRequest {
  _SharedReadRequest(this.revision);
  final int revision;
  final completion = Completer<JsonMap?>();
}

class ReaderNavigation {
  const ReaderNavigation(this.sequence, this.floor);
  final int sequence;
  final String floor;
}

class _OfficialStickerRequest {
  _OfficialStickerRequest({
    required this.accessRevision,
    required this.generation,
  });

  final int accessRevision;
  final int generation;
  final Completer<OfficialStickerCatalog> completion =
      Completer<OfficialStickerCatalog>();
}

class _ReaderLoadRequest {
  _ReaderLoadRequest({
    required this.generation,
    required this.accessRevision,
    required this.previous,
  });

  final int generation;
  final int accessRevision;
  final JsonMap? previous;
  final Completer<void> completion = Completer<void>();
}
