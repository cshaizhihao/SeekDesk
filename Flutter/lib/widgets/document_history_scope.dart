import 'package:flutter/widgets.dart';

import '../core/document_history.dart';

/// Routes only this document's keyboard/menu actions to its explicit history.
/// Place around the body editor, not around unrelated title/search fields.
class DocumentHistoryScope extends StatefulWidget {
  const DocumentHistoryScope({
    required this.history,
    required this.child,
    this.enabled = true,
    this.onHistoryApplied,
    super.key,
  });

  final DocumentHistory history;
  final bool enabled;

  /// Called only after a user undo/redo succeeds, not for ordinary edits.
  final VoidCallback? onHistoryApplied;
  final Widget child;

  /// Non-dependent lookup for command dispatch and native menu capabilities.
  static DocumentHistoryScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<DocumentHistoryScopeState>();

  @override
  State<DocumentHistoryScope> createState() => DocumentHistoryScopeState();
}

class DocumentHistoryScopeState extends State<DocumentHistoryScope>
    implements Listenable {
  final _changes = _ScopeChanges();
  late final _DocumentHistoryAction<UndoTextIntent> _undo;
  late final _DocumentHistoryAction<RedoTextIntent> _redo;

  DocumentHistory get history => widget.history;
  bool get enabled => mounted && widget.enabled;
  bool get canUndo => enabled && history.canUndo;
  bool get canRedo => enabled && history.canRedo;
  bool owns(TextEditingController controller) =>
      identical(history.controller, controller);

  @override
  void initState() {
    super.initState();
    _undo = _DocumentHistoryAction<UndoTextIntent>(
      available: () => canUndo,
      perform: () => _apply(history.undo),
    );
    _redo = _DocumentHistoryAction<RedoTextIntent>(
      available: () => canRedo,
      perform: () => _apply(history.redo),
    );
    history.addListener(_changed);
  }

  bool _apply(bool Function() command) {
    if (!command()) return false;
    if (mounted) widget.onHistoryApplied?.call();
    return true;
  }

  void _changed() {
    _undo.changed();
    _redo.changed();
    _changes.changed();
  }

  @override
  void didUpdateWidget(DocumentHistoryScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.history, history)) {
      oldWidget.history.removeListener(_changed);
      history.addListener(_changed);
    }
    if (!identical(oldWidget.history, history) ||
        oldWidget.enabled != widget.enabled) {
      _changed();
    }
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  @override
  void dispose() {
    history.removeListener(_changed);
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{
      UndoTextIntent: _undo,
      RedoTextIntent: _redo,
    },
    child: widget.child,
  );
}

class _ScopeChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class _DocumentHistoryAction<T extends Intent> extends Action<T> {
  _DocumentHistoryAction({required this.available, required this.perform});
  final bool Function() available;
  final bool Function() perform;

  @override
  bool get isActionEnabled => available();

  @override
  bool isEnabled(T intent) => available();

  @override
  Object? invoke(T intent) {
    if (available()) perform();
    return null;
  }

  void changed() => notifyActionListeners();
}
