import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'composer_paste_scope.dart';
import 'document_history_scope.dart';

/// Routes the native Edit menu through the same focused Actions as Flutter's
/// shortcuts. Only capabilities and a focus generation cross this channel;
/// editor contents and clipboard data remain with the focused text widget.
class EditMenuBridge extends StatefulWidget {
  const EditMenuBridge({required this.child, this.channel, super.key});

  final Widget child;
  final MethodChannel? channel;

  @override
  State<EditMenuBridge> createState() => _EditMenuBridgeState();
}

class _EditMenuBridgeState extends State<EditMenuBridge> {
  late final MethodChannel _channel;
  FocusNode? _focus;
  TextEditingController? _controller;
  DocumentHistoryScopeState? _documentHistory;
  ComposerPasteScopeState? _composerPaste;
  int _focusToken = 0;
  bool _notificationPending = false;

  @override
  void initState() {
    super.initState();
    _channel =
        widget.channel ?? const MethodChannel('cc.seekdesk/edit-menu.v1');
    _channel.setMethodCallHandler(_handle);
    FocusManager.instance.addListener(_focusChanged);
    _focusChanged();
  }

  BuildContext? get _focusedContext => _focus?.context;

  EditableTextState? get _editable =>
      _focusedContext?.findAncestorStateOfType<EditableTextState>();

  SelectableRegionState? get _region =>
      _focusedContext?.findAncestorStateOfType<SelectableRegionState>();

  void _focusChanged() {
    final next = FocusManager.instance.primaryFocus;
    if (!identical(next, _focus)) {
      _controller?.removeListener(_notifyChanged);
      _focus = next;
      _focusToken++;
      _controller = _editable?.widget.controller;
      _controller?.addListener(_notifyChanged);
    }
    _syncDocumentHistory();
    _syncComposerPaste();
    _notifyChanged();
  }

  void _syncComposerPaste() {
    final context = _focusedContext;
    final active =
        context != null && context.mounted && _focus?.hasFocus == true;
    final controller = active ? _editable?.widget.controller : null;
    final scope = active ? ComposerPasteScope.maybeOf(context) : null;
    final next = controller != null && scope?.owns(controller) == true
        ? scope
        : null;
    if (identical(next, _composerPaste)) return;
    _composerPaste?.removeListener(_notifyChanged);
    _composerPaste = next;
    _composerPaste?.addListener(_notifyChanged);
  }

  void _syncDocumentHistory() {
    final context = _focusedContext;
    final active =
        context != null && context.mounted && _focus?.hasFocus == true;
    final controller = active ? _editable?.widget.controller : null;
    final scope = active ? DocumentHistoryScope.maybeOf(context) : null;
    final next = controller != null && scope?.owns(controller) == true
        ? scope
        : null;
    if (identical(next, _documentHistory)) return;
    _documentHistory?.removeListener(_notifyChanged);
    _documentHistory = next;
    _documentHistory?.addListener(_notifyChanged);
  }

  void _notifyChanged() {
    if (!mounted || _notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() async {
      _notificationPending = false;
      if (!mounted) return;
      try {
        await _channel.invokeMethod<void>('changed');
      } on MissingPluginException {
        // Widget fixtures and non-macOS previews have no native menu host.
      } on PlatformException {
        // A menu refresh must never interrupt editing or draft persistence.
      }
    });
  }

  Map<String, Intent> _commands() {
    _syncDocumentHistory();
    _syncComposerPaste();
    final context = _focusedContext;
    if (context == null || !context.mounted || _focus?.hasFocus != true) {
      return const {};
    }
    final editable = _editable;
    final region = _region;
    final commands = <String, Intent>{};
    const cause = SelectionChangedCause.toolbar;
    if (editable != null && editable.widget.selectionEnabled) {
      final value = editable.widget.controller.value;
      final selected = value.selection.isValid && !value.selection.isCollapsed;
      final writable = !editable.widget.readOnly;
      if (value.text.isNotEmpty) {
        commands['selectAll'] = const SelectAllTextIntent(cause);
      }
      if (selected && !editable.widget.obscureText) {
        commands['copy'] = CopySelectionTextIntent.copy;
        if (writable) {
          commands['cut'] = const CopySelectionTextIntent.cut(cause);
        }
      }
      if (writable && value.selection.isValid) {
        final composerPaste = _composerPaste;
        if (composerPaste == null || composerPaste.canPaste) {
          commands['paste'] = const PasteTextIntent(cause);
          commands['pasteAsPlainText'] = composerPaste == null
              ? const PasteTextIntent(cause)
              : const PastePlainTextIntent(cause);
        }
        if (selected) {
          commands['delete'] = ReplaceTextIntent(
            value,
            '',
            value.selection,
            cause,
          );
        }
        final documentHistory = _documentHistory;
        if (documentHistory != null) {
          // A disabled document scope must not fall back to the text field's
          // independently coalesced history during IME, submission or disposal.
          if (documentHistory.canUndo) {
            commands['undo'] = const UndoTextIntent(cause);
          }
          if (documentHistory.canRedo) {
            commands['redo'] = const RedoTextIntent(cause);
          }
        } else {
          final history = context
              .findAncestorWidgetOfExactType<UndoHistory<TextEditingValue>>();
          final undo = identical(history?.focusNode, _focus)
              ? UndoManager.client
              : null;
          if (undo?.canUndo == true) {
            commands['undo'] = const UndoTextIntent(cause);
          }
          if (undo?.canRedo == true) {
            commands['redo'] = const RedoTextIntent(cause);
          }
        }
      }
    } else if (region != null) {
      commands['selectAll'] = const SelectAllTextIntent(cause);
      if (region.contextMenuButtonItems.any(
        (item) => item.type == ContextMenuButtonType.copy,
      )) {
        commands['copy'] = CopySelectionTextIntent.copy;
      }
    }
    commands.removeWhere((_, intent) {
      final action = Actions.maybeFind<Intent>(context, intent: intent);
      return action == null || !action.isEnabled(intent);
    });
    return commands;
  }

  Future<Object?> _handle(MethodCall call) async {
    if (!mounted) return false;
    // Focus notifications are coalesced; synchronize before accepting a host
    // command so a menu opened for one document cannot edit a different one.
    if (!identical(_focus, FocusManager.instance.primaryFocus)) _focusChanged();
    switch (call.method) {
      case 'capabilities':
        return {
          'focusToken': _focusToken,
          'commands': _commands().keys.toList(),
        };
      case 'perform':
        final args = call.arguments;
        if (args is! Map ||
            args['focusToken'] is! int ||
            args['focusToken'] != _focusToken) {
          return false;
        }
        final command = args['command'];
        if (command is! String) return false;
        final intent = _commands()[command];
        final context = _focusedContext;
        if (intent == null || context == null || !context.mounted) return false;
        Actions.maybeInvoke<Intent>(context, intent);
        _notifyChanged();
        return true;
      default:
        throw MissingPluginException('Unsupported Edit menu operation.');
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _controller?.removeListener(_notifyChanged);
    _documentHistory?.removeListener(_notifyChanged);
    _composerPaste?.removeListener(_notifyChanged);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
