import 'dart:async';

import 'package:flutter/widgets.dart';

/// History for one document, independent of its editor/preview layout.
///
/// Ordinary controller edits coalesce until idle or a selection-only change.
/// Programmatic commands must use [execute], [apply], or [runAtomic] to create
/// explicit boundaries on both sides of the command. These methods are
/// synchronous: finish any asynchronous preparation before calling them.
class DocumentHistory extends ChangeNotifier {
  DocumentHistory({
    required this.controller,
    this.typingWindow = const Duration(milliseconds: 500),
    this.maxEntries = 100,
    this.maxRetainedCharacters = 2 * 1024 * 1024,
  }) : assert(typingWindow >= Duration.zero),
       assert(maxEntries > 0),
       assert(maxRetainedCharacters > 0),
       _observed = controller.value {
    if (isComposing) {
      _startComposition(_observed);
    }
    controller.addListener(_changed);
  }

  final TextEditingController controller;
  final Duration typingWindow;
  final int maxEntries;

  /// Conservative UTF-16 character budget for retained before/after snapshots.
  /// A transaction larger than this budget clears history instead of retaining
  /// an unbounded old document. The controller's current value is not counted.
  final int maxRetainedCharacters;

  final List<_DocumentEdit> _entries = [];
  int _position = 0, _retainedCharacters = 0;
  TextEditingValue _observed;
  _DocumentEdit? _typing;
  TextEditingValue? _compositionBefore;
  Timer? _typingTimer;
  bool _composing = false, _mutating = false, _disposed = false;

  bool get isDisposed => _disposed;
  bool get isComposing => !_disposed && _hasComposition(controller.value);
  bool get canUndo =>
      !_disposed && !isComposing && (_typing != null || _position > 0);
  bool get canRedo =>
      !_disposed &&
      !isComposing &&
      _typing == null &&
      _position < _entries.length;

  /// Applies a computed edit as one transaction. Returning false means no edit
  /// was applied (disposed, composing, reentrant, or a composing result).
  bool execute(TextEditingValue Function(TextEditingValue) transform) {
    if (!_canMutate) return false;
    final before = controller.value;
    final next = transform(before);
    // A transformer is expected to be pure. Do not overwrite an unexpected
    // reentrant edit or a document disposed while computing its replacement.
    if (!_canMutate || controller.value != before) return false;
    return apply(next);
  }

  bool apply(TextEditingValue next) {
    if (!_canMutate || _hasComposition(next)) return false;
    return runAtomic(() => controller.value = _snapshot(next));
  }

  /// Groups synchronous controller mutations into one command. A no-op is
  /// accepted without adding an entry or destroying redo. If [edit] throws
  /// after changing text, that partial change remains undoable and is rethrown.
  bool runAtomic(VoidCallback edit) {
    if (!_canMutate) return false;
    _commitTyping();
    final before = _snapshot(controller.value);
    _mutating = true;
    try {
      edit();
    } finally {
      _mutating = false;
      if (!_disposed) {
        final after = controller.value;
        _observed = after;
        if (_hasComposition(after)) {
          // A callback should not start IME composition, but if it does, never
          // retain its intermediate values or make them available to undo.
          _startComposition(before);
        } else {
          _append(_DocumentEdit(before, _snapshot(after)));
        }
        notifyListeners();
      }
    }
    return true;
  }

  bool get _canMutate => !_disposed && !_mutating && !isComposing;

  /// Ends a typing group without changing the document.
  void commitTyping() {
    if (_disposed || _mutating || isComposing) return;
    if (_commitTyping()) notifyListeners();
  }

  bool undo() {
    if (!_canMutate) return false;
    _commitTyping();
    if (_position == 0) return false;
    final entry = _entries[--_position];
    _restore(entry.before);
    return true;
  }

  bool redo() {
    if (!_canMutate || _typing != null || _position >= _entries.length) {
      return false;
    }
    final entry = _entries[_position++];
    _restore(entry.after);
    return true;
  }

  /// Starts a fresh baseline. With no argument, it leaves the controller's
  /// value unchanged; use after initially loading a draft. With [baseline],
  /// replaces the controller as well. This never becomes an undoable edit.
  void reset([TextEditingValue? baseline]) {
    if (_disposed || _mutating) return;
    _clear();
    _mutating = true;
    try {
      if (baseline != null) controller.value = baseline;
      if (_disposed) return;
      _observed = controller.value;
      _composing = _hasComposition(_observed);
      _compositionBefore = _composing ? _boundedSnapshot(_observed) : null;
    } finally {
      _mutating = false;
    }
    notifyListeners();
  }

  void _changed() {
    if (_disposed || _mutating) return;
    final next = controller.value;
    final before = _observed;
    if (next == before) return;
    _observed = next;
    if (_hasComposition(next)) {
      if (!_composing) {
        _commitTyping();
        _startComposition(before);
      }
      notifyListeners();
      return;
    }
    if (_composing) {
      final start = _compositionBefore;
      _compositionBefore = null;
      _composing = false;
      if (start != null) {
        _append(_DocumentEdit(start, _snapshot(next)));
      } else if (before.text != next.text) {
        _clear();
      }
      notifyListeners();
      return;
    }
    if (before.text == next.text) {
      // A deliberate selection move separates subsequent typing, while never
      // adding an undo step of its own.
      if (before.selection != next.selection) _commitTyping();
      notifyListeners();
      return;
    }
    _discardRedo();
    final pending = _typing;
    final edit = _DocumentEdit(
      pending?.before ?? _snapshot(before),
      _snapshot(next),
    );
    _typingTimer?.cancel();
    if (!edit.changesText) {
      _typing = null;
    } else if (edit.cost > maxRetainedCharacters) {
      _clear();
    } else {
      _typing = edit;
      _trim(extraEntries: 1, extraCharacters: edit.cost);
      _typingTimer = Timer(typingWindow, () {
        if (_disposed) return;
        if (_commitTyping()) notifyListeners();
      });
    }
    notifyListeners();
  }

  bool _commitTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    final pending = _typing;
    if (pending == null) return false;
    _typing = null;
    _append(pending);
    return true;
  }

  void _append(_DocumentEdit edit) {
    if (!edit.changesText) return;
    _discardRedo();
    if (edit.cost > maxRetainedCharacters) {
      _clear();
      return;
    }
    _entries.add(edit);
    _retainedCharacters += edit.cost;
    _position = _entries.length;
    _trim();
  }

  void _discardRedo() {
    if (_position == _entries.length) return;
    for (final entry in _entries.skip(_position)) {
      _retainedCharacters -= entry.cost;
    }
    _entries.removeRange(_position, _entries.length);
  }

  void _trim({int extraEntries = 0, int extraCharacters = 0}) {
    while (_entries.isNotEmpty &&
        (_entries.length + extraEntries > maxEntries ||
            _retainedCharacters + extraCharacters > maxRetainedCharacters)) {
      _retainedCharacters -= _entries.removeAt(0).cost;
      if (_position > 0) _position--;
    }
  }

  void _restore(TextEditingValue value) {
    _mutating = true;
    try {
      controller.value = value;
      if (!_disposed) _observed = controller.value;
    } finally {
      _mutating = false;
    }
    if (!_disposed) notifyListeners();
  }

  TextEditingValue? _boundedSnapshot(TextEditingValue value) =>
      value.text.length <= maxRetainedCharacters ? _snapshot(value) : null;

  void _startComposition(TextEditingValue before) {
    _composing = true;
    _compositionBefore = _boundedSnapshot(before);
    final snapshot = _compositionBefore;
    if (snapshot == null) {
      _clear();
    } else {
      _trim(extraEntries: 1, extraCharacters: snapshot.text.length);
    }
  }

  static bool _hasComposition(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  static TextEditingValue _snapshot(TextEditingValue value) {
    final selection = value.selection;
    return value.copyWith(
      composing: TextRange.empty,
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: selection.baseOffset.clamp(0, value.text.length),
              extentOffset: selection.extentOffset.clamp(0, value.text.length),
            )
          : TextSelection.collapsed(offset: value.text.length),
    );
  }

  void _clear() {
    _typingTimer?.cancel();
    _typingTimer = null;
    _typing = null;
    _entries.clear();
    _position = 0;
    _retainedCharacters = 0;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_changed);
    _clear();
    _compositionBefore = null;
    super.dispose();
  }
}

class _DocumentEdit {
  const _DocumentEdit(this.before, this.after);
  final TextEditingValue before, after;
  bool get changesText => before.text != after.text;
  int get cost => before.text.length + after.text.length;
}
