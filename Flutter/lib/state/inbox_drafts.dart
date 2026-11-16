import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

typedef InboxDraftWriter = Future<void> Function({
  required int revision,
  required int peer,
  required String content,
  required bool markdown,
});

/// One immutable observation of the draft shared by every view of a peer.
@immutable
class InboxDraftSnapshot {
  const InboxDraftSnapshot({
    required this.revision,
    required this.peer,
    required this.content,
    required this.markdown,
    required this.version,
    required this.dirty,
    required this.saving,
    required this.error,
  });

  final int revision, peer, version;
  final String content;
  final bool markdown;
  final bool dirty, saving;
  final Object? error;
}

/// Keeps unsaved private text alive across view disposal, in memory only.
///
/// Owners share one draft per account revision and peer. Only explicit edits
/// change that text: attaching a second view or releasing an old controller
/// must never replay a stale value. Successful, unowned drafts are released;
/// failed and in-flight drafts stay available for reopening and quit retries.
class InboxDraftStore extends ChangeNotifier {
  // Keep the writer's public injection name distinct from its private field.
  // ignore: prefer_initializing_formals
  InboxDraftStore({required InboxDraftWriter write}) : _write = write;

  final InboxDraftWriter _write;
  final Map<int, _InboxDraft> _drafts = {};
  final Map<Object, _InboxDraft> _owners = HashMap.identity();
  int _revision = -1;
  int _version = 0;
  bool _disposed = false;

  int get revision => _revision;

  void activate(int revision) {
    if (_disposed || revision <= _revision) return;
    _revision = revision;
    _retire();
    notifyListeners();
  }

  InboxDraftSnapshot? acquire(
    Object owner, {
    required int revision,
    required int peer,
    required String nativeContent,
    bool nativeMarkdown = true,
  }) {
    if (!_accepts(revision, peer)) return null;
    final previous = _owners[owner];
    if (previous != null && previous.peer == peer && _owns(previous)) {
      return _snapshot(previous);
    }
    release(owner);
    final draft = _drafts.putIfAbsent(
      peer,
      () => _InboxDraft(
        revision,
        peer,
        nativeContent,
        nativeMarkdown,
        ++_version,
      ),
    );
    _owners[owner] = draft;
    draft.owners.add(owner);
    return _snapshot(draft);
  }

  InboxDraftSnapshot? read({required int revision, required int peer}) {
    if (!_accepts(revision, peer)) return null;
    final draft = _drafts[peer];
    return draft == null ? null : _snapshot(draft);
  }

  /// Call only for a real edit, never to flush a view's cached controller text.
  bool edit(Object owner, String content, {bool? markdown}) {
    final draft = _owners[owner];
    if (draft == null || !_owns(draft)) return false;
    final nextMarkdown = markdown ?? draft.markdown;
    if (content == draft.content && nextMarkdown == draft.markdown) return true;
    draft
      ..content = content
      ..markdown = nextMarkdown
      ..version = ++_version
      ..dirty = true
      ..error = null;
    notifyListeners();
    return true;
  }

  void release(Object owner) {
    final draft = _owners.remove(owner);
    if (draft == null) return;
    draft.owners.remove(owner);
    _releaseClean(draft);
  }

  /// Joins an existing peer write and drains edits that arrive while it runs.
  /// A failed write returns false while retaining the latest text for retry.
  Future<bool> flush({required int revision, required int peer}) {
    if (!_accepts(revision, peer)) return Future.value(false);
    final draft = _drafts[peer];
    if (draft == null) return Future.value(true);
    final running = draft.running;
    if (running != null) return running.future;
    if (!draft.dirty) {
      _releaseClean(draft);
      return Future.value(true);
    }
    final completion = Completer<bool>();
    draft
      ..running = completion
      ..error = null;
    unawaited(_save(draft, completion));
    return completion.future;
  }

  Future<bool> flushAll({required int revision}) async {
    while (!_disposed && revision == _revision) {
      final pending = [
        for (final draft in _drafts.values)
          if (draft.dirty || draft.running != null) draft.peer,
      ];
      if (pending.isEmpty) return true;
      final results = await Future.wait([
        for (final peer in pending) flush(revision: revision, peer: peer),
      ]);
      if (results.any((saved) => !saved)) return false;
      // Edits in another view may have arrived while its sibling was saving.
    }
    return false;
  }

  /// A confirmed native send already clears its persisted draft. Clear the
  /// shared editor only if it is still the version the user chose to send.
  /// Otherwise retain the newer text and persist it again: the send may have
  /// cleared the native draft after that newer edit's earlier save completed.
  bool confirmSent({
    required int revision,
    required int peer,
    required int version,
  }) {
    if (!_accepts(revision, peer)) return false;
    final draft = _drafts[peer];
    if (draft == null || version <= 0 || version > draft.version) return false;
    final unchanged = version == draft.version;
    if (unchanged) draft.content = '';
    draft
      ..version = ++_version
      ..dirty = !unchanged || draft.running != null
      ..error = null;
    _releaseClean(draft);
    notifyListeners();
    return unchanged;
  }

  bool _accepts(int revision, int peer) =>
      !_disposed && revision == _revision && peer > 0;

  bool _owns(_InboxDraft draft) =>
      !_disposed &&
      draft.revision == _revision &&
      identical(_drafts[draft.peer], draft);

  InboxDraftSnapshot _snapshot(_InboxDraft draft) => InboxDraftSnapshot(
    revision: draft.revision,
    peer: draft.peer,
    content: draft.content,
    markdown: draft.markdown,
    version: draft.version,
    dirty: draft.dirty,
    saving: draft.running != null,
    error: draft.error,
  );

  Future<void> _save(_InboxDraft draft, Completer<bool> completion) async {
    var saved = false;
    try {
      notifyListeners();
      while (_owns(draft) && draft.dirty) {
        final version = draft.version, content = draft.content;
        final markdown = draft.markdown;
        try {
          await _write(
            revision: draft.revision,
            peer: draft.peer,
            content: content,
            markdown: markdown,
          );
        } catch (error) {
          if (_owns(draft)) draft.error = error;
          return;
        }
        if (!_owns(draft)) return;
        if (draft.version == version) {
          draft
            ..dirty = false
            ..error = null;
        }
      }
      saved = _owns(draft);
    } finally {
      if (_owns(draft) && identical(draft.running, completion)) {
        draft.running = null;
        _releaseClean(draft);
        notifyListeners();
      }
      if (!completion.isCompleted) completion.complete(saved);
    }
  }

  void _releaseClean(_InboxDraft draft) {
    if (_owns(draft) &&
        draft.owners.isEmpty &&
        !draft.dirty &&
        draft.running == null) {
      _drafts.remove(draft.peer);
      draft.content = '';
      draft.error = null;
    }
  }

  void _retire() {
    for (final draft in _drafts.values) {
      draft.content = '';
      draft.error = null;
      draft.owners.clear();
      final running = draft.running;
      draft.running = null;
      if (running != null && !running.isCompleted) running.complete(false);
    }
    _drafts.clear();
    _owners.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _retire();
    super.dispose();
  }
}

class _InboxDraft {
  _InboxDraft(
    this.revision,
    this.peer,
    this.content,
    this.markdown,
    this.version,
  );
  final int revision, peer;
  String content;
  bool markdown;
  int version;
  bool dirty = false;
  Object? error;
  Completer<bool>? running;
  final Set<Object> owners = HashSet.identity();
}
