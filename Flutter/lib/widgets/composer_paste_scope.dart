import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'composer_media_controller.dart';
import 'composer_drop_scope.dart';

/// The native Edit menu uses a separate intent so plain-text paste can never
/// enter image capture, even when the clipboard also contains an image.
class PastePlainTextIntent extends Intent {
  const PastePlainTextIntent(this.cause);
  final SelectionChangedCause cause;
}

/// One paste dispatcher for a document body, its Edit menu and context menu.
///
/// [enabled] describes the document, mode and non-media business state. Do not
/// include media.busy: this scope checks it before starting, while a pending
/// text result must remain eligible during its own media operation.
class ComposerPasteScope extends StatefulWidget {
  const ComposerPasteScope({
    required this.media,
    required this.bodyFocus,
    required this.enabled,
    required this.requestKey,
    required this.child,
    this.imageDropEnabled = true,
    super.key,
  });

  final ComposerMediaController media;
  final FocusNode bodyFocus;
  final bool enabled;
  final Future<String?> Function() requestKey;
  final Widget child;
  final bool imageDropEnabled;

  static ComposerPasteScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ComposerPasteScopeState>();

  /// Default EditableText context-menu paste bypasses Actions. Replace that
  /// entry, and expose it for image-only clipboards without reading them here.
  static Widget contextMenuBuilder(
    BuildContext context,
    EditableTextState editable,
  ) {
    final scope = maybeOf(editable.context);
    if (scope == null || !scope.owns(editable.widget.controller)) {
      return CupertinoAdaptiveTextSelectionToolbar.editableText(
        editableTextState: editable,
      );
    }
    return ListenableBuilder(
      listenable: scope,
      builder: (context, _) {
        final items = editable.contextMenuButtonItems
            .where((item) => item.kind != ContextMenuButtonKind.paste)
            .toList();
        final insertAt = items.indexWhere(
          (item) => item.kind == ContextMenuButtonKind.selectAll,
        );
        final paste = ContextMenuButtonItem(
          kind: ContextMenuButtonKind.paste,
          onPressed: scope.canPaste
              ? () {
                  // Do not use the overlay's context to resolve document
                  // Actions. Its focus/controller must still be the same body.
                  if (!editable.mounted || !scope.canPaste) return;
                  final focusedContext = scope.widget.bodyFocus.context;
                  if (focusedContext == null || !focusedContext.mounted) return;
                  editable.hideToolbar();
                  Actions.maybeInvoke(
                    focusedContext,
                    const PasteTextIntent(SelectionChangedCause.toolbar),
                  );
                }
              : null,
        );
        items.insert(insertAt < 0 ? items.length : insertAt, paste);
        return CupertinoAdaptiveTextSelectionToolbar.buttonItems(
          anchors: editable.contextMenuAnchors,
          buttonItems: items,
        );
      },
    );
  }

  @override
  State<ComposerPasteScope> createState() => ComposerPasteScopeState();
}

class ComposerPasteScopeState extends State<ComposerPasteScope>
    implements Listenable {
  final _changes = _PasteScopeChanges();
  late final _ComposerPasteAction<PasteTextIntent> _paste;
  late final _ComposerPasteAction<PastePlainTextIntent> _plainText;
  ModalRoute<dynamic>? _route;
  bool _routeCurrent = true;
  int _ownerGeneration = 0;

  bool owns(TextEditingController controller) =>
      identical(widget.media.content, controller);

  EditableTextState? get _editable =>
      widget.bodyFocus.context?.findAncestorStateOfType<EditableTextState>();

  bool get _ownsFocusedBody {
    if (!mounted || !widget.bodyFocus.hasFocus) return false;
    final editable = _editable;
    return editable != null &&
        editable.mounted &&
        owns(editable.widget.controller);
  }

  bool get _canAcceptText {
    if (!_ownsFocusedBody ||
        !widget.enabled ||
        widget.media.revision != widget.media.state.accessRevision ||
        !(_route?.isCurrent ?? true)) {
      return false;
    }
    final editable = _editable!;
    final value = widget.media.content.value;
    return !editable.widget.readOnly &&
        editable.widget.selectionEnabled &&
        value.selection.isValid &&
        value.selection.start >= 0 &&
        value.selection.end <= value.text.length &&
        !(value.composing.isValid && !value.composing.isCollapsed);
  }

  /// Used by native-menu capabilities and the context menu. Disabled keyboard
  /// pastes are still consumed by the override, without invoking a fallback.
  bool get canPaste => _canAcceptText && !widget.media.busy;

  @override
  void initState() {
    super.initState();
    _paste = _ComposerPasteAction<PasteTextIntent>(
      ownsFocus: () => _ownsFocusedBody,
      perform: () => _startPaste(plainText: false),
    );
    _plainText = _ComposerPasteAction<PastePlainTextIntent>(
      ownsFocus: () => _ownsFocusedBody,
      perform: () => _startPaste(plainText: true),
    );
    _listen(widget);
  }

  void _listen(ComposerPasteScope target) {
    target.media.addListener(_changed);
    target.media.content.addListener(_changed);
    target.bodyFocus.addListener(_focusChanged);
  }

  void _unlisten(ComposerPasteScope target) {
    target.media.removeListener(_changed);
    target.media.content.removeListener(_changed);
    target.bodyFocus.removeListener(_focusChanged);
  }

  void _focusChanged() {
    _ownerGeneration++;
    _changed();
  }

  void _changed() {
    _paste.changed();
    _plainText.changed();
    _changes.changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final current = route?.isCurrent ?? true;
    if (!identical(route, _route) || current != _routeCurrent) {
      _route = route;
      _routeCurrent = current;
      _ownerGeneration++;
      _changed();
    }
  }

  @override
  void didUpdateWidget(ComposerPasteScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media) ||
        !identical(oldWidget.bodyFocus, widget.bodyFocus)) {
      _unlisten(oldWidget);
      _listen(widget);
      _ownerGeneration++;
      _changed();
    } else if (oldWidget.enabled != widget.enabled) {
      _ownerGeneration++;
      _changed();
    }
  }

  void _startPaste({required bool plainText}) {
    if (!canPaste) return;
    final media = widget.media;
    final focus = widget.bodyFocus;
    final generation = _ownerGeneration;
    // media.busy intentionally is not part of this callback: capture has
    // already reserved it. Focus/mode/route ABA still invalidates text results.
    bool canPasteText() =>
        mounted &&
        identical(media, widget.media) &&
        identical(focus, widget.bodyFocus) &&
        generation == _ownerGeneration &&
        _canAcceptText;
    if (plainText) {
      unawaited(
        media.pasteTextOnly(
          requestText: () async =>
              (await Clipboard.getData(Clipboard.kTextPlain))?.text,
          canPasteText: canPasteText,
        ),
      );
    } else {
      unawaited(
        media.paste(requestKey: widget.requestKey, canPasteText: canPasteText),
      );
    }
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  @override
  void dispose() {
    _ownerGeneration++;
    _unlisten(widget);
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    // EditableText already uses Action.overridable for PasteTextIntent. This
    // ancestor override is reached from its leaf Actions by every shortcut and
    // the native menu. Calling callingAction would re-read the text clipboard
    // and bypass the media operation, so it is deliberately never invoked.
    actions: <Type, Action<Intent>>{
      PasteTextIntent: _paste,
      PastePlainTextIntent: _plainText,
    },
    child: ComposerDropScope(
      media: widget.media,
      bodyFocus: widget.bodyFocus,
      enabled: widget.enabled && widget.imageDropEnabled,
      requestKey: widget.requestKey,
      child: widget.child,
    ),
  );
}

class _PasteScopeChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class _ComposerPasteAction<T extends Intent> extends Action<T> {
  _ComposerPasteAction({required this.ownsFocus, required this.perform});
  final bool Function() ownsFocus;
  final VoidCallback perform;

  // Remain dispatchable while this body owns focus, even when busy/IME blocks
  // the mutation. Returning false would let a key fall through to macOS text
  // input and bypass the document's busy/owner guards. Menus use canPaste.
  @override
  bool get isActionEnabled => ownsFocus();

  @override
  bool isEnabled(T intent) => ownsFocus();

  @override
  Object? invoke(T intent) {
    if (ownsFocus()) perform();
    return null;
  }

  void changed() => notifyActionListeners();
}
