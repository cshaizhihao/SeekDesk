import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/frame_diagnostics.dart';
import '../core/reader_editor_binding.dart';
import '../core/floor_reply.dart';
import '../models/snapshots.dart';
import 'app_state.dart';

class ReaderEditorSession {
  ReaderEditorSession({
    required this.id,
    required this.revision,
    required this.topic,
    required this.floor,
  });
  final int id, revision;
  final TopicData topic;
  final int? floor;
  final LayerLink link = LayerLink();
  late final ReaderEditorBinding binding;
  Size size = const Size(520, 340);
  bool get reply => floor == null;
}

/// Lives above reader keys and destination routes. Ordinary navigation hides a
/// document; only its explicit completion or guarded tab closure retires it.
class ReaderEditors extends ChangeNotifier {
  ReaderEditors({
    required this.state,
    required this.readerVisible,
    required this.canInteract,
    required this.navigationIdentity,
    required this.revealTopic,
  }) {
    state.addListener(_changed);
    state.registerTopicCloseGuard(this, prepareTopicClose);
  }
  final AppState state;
  final bool Function() readerVisible, canInteract;
  final Object Function() navigationIdentity;
  final Future<void> Function(TopicData) revealTopic;
  final List<ReaderEditorSession> _sessions = [];
  List<ReaderEditorSession> get sessions => List.unmodifiable(_sessions);
  ReaderEditorSession? recovery;
  int _nextID = 0;
  bool _disposed = false, _scheduled = false, _opening = false;

  ReaderEditorSession? forTopic(String id) {
    for (final session in _sessions) {
      if (session.revision == state.accessRevision && session.topic.id == id) {
        return session;
      }
    }
    return null;
  }

  ReaderEditorSession? get presented {
    if (recovery != null) return recovery;
    if (!readerVisible()) return null;
    return forTopic(state.workspace.selectedTab);
  }

  bool active(ReaderEditorSession session) =>
      !_disposed &&
      _sessions.contains(session) &&
      identical(presented, session) &&
      canInteract();

  bool contains(ReaderEditorSession session) => _sessions.contains(session);

  Future<bool> replyTo(
    TopicData topic,
    FloorData floor, {
    bool quoting = false,
  }) async {
    if (_disposed ||
        _opening ||
        !readerVisible() ||
        !canInteract() ||
        !state.signedIn ||
        state.workspace.selectedTab != topic.id ||
        state.domain('session')['canCompose'] == false) {
      return false;
    }
    final suffix = floorReplyInsertion(
      floor,
      topic.url,
      quoting: quoting,
      after: '',
    );
    if (suffix == null) {
      state.showMessage('无法引用这个楼层，请刷新帖子后重试。');
      return false;
    }
    final revision = state.accessRevision;
    final navigation = navigationIdentity();
    var session = forTopic(topic.id);
    if (session != null && !session.reply) {
      state.showMessage('请先保存或关闭当前楼层编辑，再回复或引用。');
      return false;
    }
    if (session == null) {
      await open(topic);
      if (_disposed ||
          revision != state.accessRevision ||
          navigation != navigationIdentity()) {
        return false;
      }
      session = forTopic(topic.id);
    }
    if (session == null || !session.reply || !active(session)) return false;
    final accepted = await session.binding.appendReply(
      (draft) => floorReplyInsertion(
        floor,
        topic.url,
        quoting: quoting,
        after: draft,
      )!,
    );
    if (!accepted &&
        !_disposed &&
        revision == state.accessRevision &&
        navigation == navigationIdentity()) {
      state.showMessage('暂未添加引用，请完成当前输入或图片处理后重试。草稿已保留。');
    }
    return accepted;
  }

  Future<void> open(TopicData topic, {int? floor}) async {
    if (_disposed || _opening || !canInteract() || !state.signedIn) return;
    final revision = state.accessRevision;
    final navigation = navigationIdentity();
    final existing = forTopic(topic.id);
    if (existing?.floor == floor && existing != null) return;
    _opening = true;
    try {
      if (existing != null) {
        final close = existing.binding.requestClose;
        if (close == null || existing.binding.busy) return;
        await close();
        if (contains(existing)) return;
      }
      if (_disposed ||
          revision != state.accessRevision ||
          navigation != navigationIdentity() ||
          !canInteract()) {
        return;
      }
      final session = ReaderEditorSession(
        id: ++_nextID,
        revision: revision,
        topic: topic,
        floor: floor,
      );
      session.binding = ReaderEditorBinding(
        accessRevision: session.revision,
        isActive: () => active(session),
        navigationIdentity: navigationIdentity,
        onClosed: () => _remove(session),
        onSubmitted: (ticket, destination) =>
            _submitted(session, ticket, destination),
      );
      _sessions.add(session);
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        FrameDiagnostics.recordUiWork(
          UiWorkKind.editorOpen,
          width: session.size.width,
          height: session.size.height,
          count: 1,
        );
      }
      _changed();
    } finally {
      _opening = false;
    }
  }

  void updateSize(ReaderEditorSession session, Size size) {
    if (_disposed ||
        !contains(session) ||
        session.size == size ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }
    session.size = size;
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      FrameDiagnostics.recordUiWork(
        UiWorkKind.editorResize,
        width: size.width,
        height: size.height,
        count: 1,
      );
    }
    _changed();
  }

  void _remove(ReaderEditorSession session) {
    if (_disposed || !_sessions.remove(session)) return;
    final measured = FrameDiagnostics.enabled && FrameDiagnostics.rawFrames;
    final started = measured
        ? DateTime.now().toUtc().microsecondsSinceEpoch
        : 0;
    final frameNumber = measured
        ? ui.PlatformDispatcher.instance.frameData.frameNumber
        : null;
    final timer = measured ? (Stopwatch()..start()) : null;
    try {
      if (identical(recovery, session)) recovery = null;
      // Let the document detach its listener and flush registration first.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => session.binding.dispose(),
      );
      _changed();
    } finally {
      if (timer != null) {
        timer.stop();
        FrameDiagnostics.recordUiWork(
          UiWorkKind.editorRemove,
          startedUnixMicros: started,
          durationMicros: timer.elapsedMicroseconds,
          count: 1,
          frameNumber: frameNumber,
        );
      }
    }
  }

  void _submitted(
    ReaderEditorSession session,
    Object ticket,
    String? destination,
  ) {
    if (_disposed ||
        !contains(session) ||
        session.revision != state.accessRevision) {
      return;
    }
    final mayNavigate = active(session) && navigationIdentity() == ticket;
    _remove(session);
    if (mayNavigate && destination != null && destination.isNotEmpty) {
      unawaited(state.openLink(destination));
    } else {
      unawaited(state.loadReader(session.topic.url, force: true));
    }
  }

  Future<void> reveal(ReaderEditorSession session) async {
    if (_disposed || !contains(session)) return;
    final hasTab = state.workspace.tabs.any(
      (tab) => tab.id == session.topic.id,
    );
    if (session.revision != state.accessRevision || !hasTab) {
      recovery = session;
      _changed();
    } else {
      recovery = null;
      await revealTopic(session.topic);
      _changed();
    }
  }

  void hideRecovery() {
    if (recovery == null) return;
    recovery = null;
    _changed();
  }

  Future<bool> prepareTopicClose(Set<String> ids) async {
    final revision = state.accessRevision;
    final affected = _sessions
        .where(
          (session) =>
              session.revision == revision && ids.contains(session.topic.id),
        )
        .toList();
    for (final session in affected) {
      if (!contains(session)) continue;
      final prepare = session.binding.prepareForTabClose;
      if (prepare == null || !await prepare()) {
        if (!_disposed &&
            revision == state.accessRevision &&
            contains(session)) {
          state.showMessage('这篇帖子仍有正在处理或未提交的编辑，请先保存或关闭编辑器。');
          await reveal(session);
        }
        return false;
      }
      if (_disposed || revision != state.accessRevision) return false;
    }
    return true;
  }

  void refresh() {
    // Explicit workspace/route refreshes have no binding to update when no
    // document is retained. _changed still notifies when the last one closes.
    if (_sessions.isNotEmpty) _changed();
  }

  void _changed() {
    if (_disposed) return;
    // Draft reads may notify while a retained document is being mounted.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_scheduled) return;
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        _changed();
      });
      return;
    }
    for (final session in _sessions) {
      session.binding.refresh();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    state.removeListener(_changed);
    state.unregisterTopicCloseGuard(this);
    for (final session in _sessions) {
      session.binding.dispose();
    }
    super.dispose();
  }
}
