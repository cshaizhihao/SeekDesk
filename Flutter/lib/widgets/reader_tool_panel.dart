import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/native_client.dart';
import '../state/app_state.dart';
import 'glass_chrome.dart';

/// Owns the lifetime of one lightweight tool above its existing reading page.
/// Input memory belongs to the embedded tool, never to this presentation.
class ReaderToolPanelController {
  static final _presentations = Expando<_ToolPresentation>();
  _ToolPresentation? _presentation;
  bool _disposed = false;

  bool get isOpen => _presentation != null;

  Future<void> show(
    BuildContext context, {
    required AppState state,
    required String extensionID,
    required String title,
    required WidgetBuilder builder,
    bool Function()? canReturnToSource,
  }) async {
    if (_disposed ||
        !context.mounted ||
        _presentation != null ||
        _presentations[state] != null ||
        !_extensionActive(state, extensionID) ||
        _officeCovered(state) ||
        canReturnToSource?.call() == false ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final entry = _ToolPresentation(
      state: state,
      extensionID: extensionID,
      navigator: Navigator.of(context, rootNavigator: true),
      sourceRoute: ModalRoute.of(context),
      sourceFocus: FocusManager.instance.primaryFocus,
      canReturnToSource: canReturnToSource,
    );
    final reducedMotion =
        MediaQuery.disableAnimationsOf(context) ||
        GlassAccessibilityData.of(context).reduceMotion;
    final dark = DeskColors(context).dark;
    entry.route = RawDialogRoute<void>(
      settings: RouteSettings(name: 'reader-tool/$extensionID'),
      barrierDismissible: false,
      barrierLabel: '关闭$title',
      barrierColor: dark ? const Color(0x38000000) : const Color(0x18000000),
      requestFocus: true,
      transitionDuration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 150),
      transitionBuilder: (context, animation, secondary, child) =>
          FadeTransition(opacity: animation, child: child),
      pageBuilder: (context, animation, secondary) => ReaderToolPanel(
        title: title,
        onDismiss: entry.dismiss,
        child: Builder(builder: builder),
      ),
    );
    _presentation = entry;
    _presentations[state] = entry;
    final release = state.deferWatchPopup();
    state.addListener(entry.changed);
    try {
      // completed includes the reverse transition and overlay disposal, so the
      // notification lease and duplicate-open guard outlive Navigator.pop.
      unawaited(entry.navigator.push(entry.route));
      await entry.route.completed;
    } finally {
      state.removeListener(entry.changed);
      release();
      if (identical(_presentation, entry)) _presentation = null;
      if (identical(_presentations[state], entry)) {
        _presentations[state] = null;
      }
      entry.restoreFocus();
    }
  }

  /// Removes only the route owned by this controller, even below another modal.
  /// Source disposal/identity changes must never return focus to that source.
  void dismiss({bool restoreFocus = false}) =>
      _presentation?.dismiss(restoreFocus: restoreFocus);

  void dispose() {
    _disposed = true;
    dismiss();
  }
}

bool _extensionActive(AppState state, String id) =>
    jsonItems(state.domain('extensions')['items'])
        .any((item) => item['id'] == id && item['active'] == true);

bool _officeCovered(AppState state) =>
    _extensionActive(state, 'office') &&
    jsonMap(
          jsonMap(state.domain('extensions')['settings'])['office'],
        )['presented'] ==
        true;

class _ToolPresentation {
  _ToolPresentation({
    required this.state,
    required this.extensionID,
    required this.navigator,
    required this.sourceRoute,
    required this.sourceFocus,
    required this.canReturnToSource,
  }) : revision = state.accessRevision,
       owner = intValue(state.domain('session')['owner'], -1),
       account = stringValue(state.domain('session')['account']),
       navigation = state.navigationRevision;

  final AppState state;
  final String extensionID;
  final NavigatorState navigator;
  final ModalRoute<dynamic>? sourceRoute;
  final FocusNode? sourceFocus;
  final bool Function()? canReturnToSource;
  final int revision, navigation, owner;
  final String account;
  late final RawDialogRoute<void> route;
  bool _retired = false, _restore = true;

  bool get _sourceValid =>
      state.accessRevision == revision &&
      intValue(state.domain('session')['owner'], -1) == owner &&
      stringValue(state.domain('session')['account']) == account &&
      _extensionActive(state, extensionID) &&
      !_officeCovered(state) &&
      canReturnToSource?.call() != false;

  void changed() {
    if (!_sourceValid) dismiss(restoreFocus: false);
  }

  void dismiss({bool restoreFocus = true}) {
    if (!restoreFocus) _restore = false;
    if (_retired) return;
    _retired = true;
    void remove() {
      if (!navigator.mounted || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        // A currency picker or unrelated route above us owns its own lifetime.
        // Never pop it as a side effect of this tool becoming unavailable.
        navigator.removeRoute(route);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks ||
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }

  void restoreFocus() {
    final focus = sourceFocus;
    if (!_restore ||
        !_sourceValid ||
        state.navigationRevision != navigation ||
        sourceRoute?.isCurrent == false ||
        focus == null ||
        focus.context?.mounted != true ||
        !focus.canRequestFocus) {
      return;
    }
    final current = FocusManager.instance.primaryFocus;
    // Navigator usually restores its saved focus itself. Do not override an
    // intentional newer focus after dismissal or a newly presented modal.
    if (current == null || current is FocusScopeNode || current == focus) {
      focus.requestFocus();
    }
  }
}

/// The embedded child supplies its heading, close action and scrollable body.
/// The shell bounds content without forcing a short status to fill its height.
/// Expanding forms still use the full space; only controls use glass lenses.
class ReaderToolPanel extends StatelessWidget {
  const ReaderToolPanel({
    required this.title,
    required this.onDismiss,
    required this.child,
    super.key,
  });

  final String title;
  final VoidCallback onDismiss;
  final Widget child;

  bool get _composing {
    final context = FocusManager.instance.primaryFocus?.context;
    final editable = context?.widget is EditableText
        ? context!.widget as EditableText
        : context?.findAncestorStateOfType<EditableTextState>()?.widget;
    final composing = editable?.controller.value.composing;
    return composing != null && composing.isValid && !composing.isCollapsed;
  }

  KeyEventResult _key(BuildContext context, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true ||
        event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // Keep Escape available to the platform IME without allowing a parent
    // DismissIntent to close this tool while a candidate is being composed.
    if (_composing) return KeyEventResult.skipRemainingHandlers;
    if (event is KeyDownEvent) onDismiss();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = GlassThemeData.of(context);
    final colors = DeskColors(context);
    return GlassTheme(
      data: theme.copyWith(
        interaction: theme.interaction.copyWith(
          interactionScale: 1,
          stretch: 0,
          anchorStretch: false,
        ),
      ),
      child: FocusScope(
        autofocus: true,
        onKeyEvent: (_, event) => _key(context, event),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('reader-tool-dismiss'),
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: const SizedBox.expand(),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, bounds) => Center(
                    child: ConstrainedBox(
                      key: const ValueKey('reader-tool-surface'),
                      constraints: BoxConstraints(
                        minWidth: math.min(620.0, bounds.maxWidth),
                        maxWidth: math.min(620.0, bounds.maxWidth),
                        maxHeight: math.min(740.0, bounds.maxHeight),
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        child: Semantics(
                          scopesRoute: true,
                          namesRoute: true,
                          label: title,
                          explicitChildNodes: true,
                          // A detached form needs an optical backing: a bare
                          // clear glass lens over forum text creates two layers
                          // of competing letters. Keep the official glass and
                          // interactive controls above this calm reading plane.
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.paper.withValues(
                                alpha:
                                    GlassAccessibilityData.of(context)
                                        .reduceTransparency
                                    ? 1
                                    : colors.dark
                                    ? .94
                                    : .96,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xff000000,
                                  ).withValues(alpha: colors.dark ? .22 : .12),
                                  blurRadius: 32,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: DeskGlassPanel(
                              quiet: true,
                              padding: EdgeInsets.zero,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: GlassTheme(data: theme, child: child),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
