import 'dart:async';

import 'package:flutter/foundation.dart';

/// A single-use append command owned by one retained document and navigation.
class ReaderReplyAppend {
  ReaderReplyAppend(this.insertion, this.navigation);
  final String Function(String draft) insertion;
  final Object navigation;
  final Completer<bool> _result = Completer<bool>();
  void complete(bool accepted) {
    if (!_result.isCompleted) _result.complete(accepted);
  }
}

/// A retained document's UI lease. Account ownership remains in the document;
/// hiding the reader must not prevent its local draft from being flushed.
class ReaderEditorBinding extends ChangeNotifier {
  ReaderEditorBinding({
    required this.accessRevision,
    required this.isActive,
    required this.navigationIdentity,
    required this.onClosed,
    required this.onSubmitted,
  });

  final int accessRevision;
  final bool Function() isActive;
  final Object Function() navigationIdentity;
  final VoidCallback onClosed;
  final void Function(Object navigation, String? destination) onSubmitted;
  Future<void> Function()? requestClose;
  Future<bool> Function()? prepareForTabClose;
  bool Function()? operationBusy;
  ReaderReplyAppend? _replyAppend;
  bool _retired = false;

  bool get active => !_retired && isActive();
  bool get busy => _replyAppend != null || (operationBusy?.call() ?? true);
  bool get hasReplyAppend => _replyAppend != null;

  Future<bool> appendReply(String Function(String draft) insertion) {
    if (!active || _replyAppend != null) return Future.value(false);
    final request = ReaderReplyAppend(insertion, navigationIdentity());
    _replyAppend = request;
    notifyListeners();
    return request._result.future;
  }

  ReaderReplyAppend? takeReplyAppend() {
    _cancelStaleAppend();
    final request = _replyAppend;
    _replyAppend = null;
    return request;
  }

  void _cancelStaleAppend() {
    final request = _replyAppend;
    if (request != null &&
        (!active || request.navigation != navigationIdentity())) {
      _replyAppend = null;
      request.complete(false);
    }
  }

  void refresh() {
    if (!_retired) {
      _cancelStaleAppend();
      notifyListeners();
    }
  }

  void close() {
    if (!_retired) {
      _replyAppend?.complete(false);
      _replyAppend = null;
      onClosed();
    }
  }

  void submitted(Object navigation, {String? destination}) {
    if (!_retired) onSubmitted(navigation, destination);
  }

  @override
  void dispose() {
    _retired = true;
    _replyAppend?.complete(false);
    _replyAppend = null;
    requestClose = null;
    prepareForTabClose = null;
    operationBusy = null;
    super.dispose();
  }
}
