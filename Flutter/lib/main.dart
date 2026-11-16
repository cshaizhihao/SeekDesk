import 'dart:async';

// Keep the official 1.17.3 package's Flutter 3.41-compatible Cupertino API.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/glass_work_diagnostics.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'state/app_state.dart';
import 'core/native_client.dart';
import 'models/snapshots.dart';
import 'widgets/glass_chrome.dart';
import 'widgets/desk_theme.dart';
import 'widgets/desk_page_transition.dart';
import 'widgets/reader_backdrop.dart';
import 'widgets/desk_workspace_sidebar.dart';
import 'widgets/sidebar_rankings.dart';
import 'screens/friend_links_screen.dart';
import 'widgets/desk_sidebar_divider.dart';
import 'widgets/desk_wordmark.dart';
import 'screens/reader_screen.dart';
import 'screens/composer_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/preferences_screen.dart';
import 'screens/extensions_screen.dart';
import 'screens/tools_screen.dart';
import 'screens/account_screen.dart';
import 'widgets/extension_overlays.dart';
import 'widgets/workspace_tabs.dart';
import 'widgets/workspace_message.dart';
import 'widgets/forum_post_list.dart';
import 'widgets/workspace_search.dart';
import 'widgets/edit_menu_bridge.dart';
import 'widgets/window_chrome_bridge.dart';
import 'core/frame_diagnostics.dart';
import 'state/reader_editors.dart';
import 'widgets/reader_editor_host.dart';
import 'widgets/document_history_scope.dart';
import 'core/native_wheel_input.dart';

Future<void> main() async {
  SeekDeskFlutterBinding();
  await NativeWheelInput.instance.start();
  PaintingBinding.instance.imageCache.maximumSize = 64;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
  await LiquidGlassWidgets.initialize();
  FrameDiagnostics.start();
  if (GlassWorkDiagnostics.enabled) {
    GlassWorkDiagnostics.observer = _recordGlassWork;
  }
  runApp(const SeekDeskApp());
}

void _recordGlassWork(
  GlassWorkKind kind, {
  required int startedUnixMicros,
  required int durationMicros,
  int? width,
  int? height,
  int? count,
  int? frameNumber,
}) {
  FrameDiagnostics.recordUiWork(
    switch (kind) {
      GlassWorkKind.shapeGeometry => UiWorkKind.glassShapeGeometry,
      GlassWorkKind.geometryPicture => UiWorkKind.glassGeometryPicture,
      GlassWorkKind.geometryImageHandle => UiWorkKind.glassGeometryImageHandle,
      GlassWorkKind.shadowBake => UiWorkKind.glassShadow,
      GlassWorkKind.shaderInstance => UiWorkKind.glassShaderInstance,
    },
    startedUnixMicros: startedUnixMicros,
    durationMicros: durationMicros,
    width: width?.toDouble(),
    height: height?.toDouble(),
    count: count,
    frameNumber: frameNumber,
  );
}

class SeekDeskApp extends StatefulWidget {
  const SeekDeskApp({super.key});
  @override
  State<SeekDeskApp> createState() => _SeekDeskAppState();
}

class _SeekDeskAppState extends State<SeekDeskApp> with WidgetsBindingObserver {
  late final AppState state;
  final Object _diagnosticsFlusher = Object();
  String appearance = 'system';
  DeskThemeFamily themeFamily = DeskThemeFamily.classic;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state = AppState();
    if (FrameDiagnostics.enabled) {
      state.registerDraftFlusher(_diagnosticsFlusher, () async {
        // Optional trace writes must not consume the native quit deadline for
        // real drafts. Measurements wait for the engine tail batch and verify
        // periodic output before quitting; this final drain is best effort.
        unawaited(FrameDiagnostics.flush().catchError((Object _) {}));
        return true;
      });
    }
    state.addListener(_appearanceChanged);
    state.connect();
  }

  void _appearanceChanged() {
    final settings = state.domain('settings');
    final next = stringValue(settings['appearance'], 'system');
    final family = DeskThemeFamily.fromSetting(
      settings[DeskThemeFamily.preference],
    );
    if (mounted && (next != appearance || family != themeFamily)) {
      setState(() {
        appearance = next;
        themeFamily = family;
      });
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (appearance == 'system' && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (GlassWorkDiagnostics.enabled &&
        identical(GlassWorkDiagnostics.observer, _recordGlassWork)) {
      GlassWorkDiagnostics.observer = null;
    }
    if (FrameDiagnostics.enabled) {
      state.unregisterDraftFlusher(_diagnosticsFlusher);
      FrameDiagnostics.stop();
    }
    state.removeListener(_appearanceChanged);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = appearance == 'dark'
        ? Brightness.dark
        : appearance == 'light'
        ? Brightness.light
        : View.of(context).platformDispatcher.platformBrightness;
    final colors = DeskColors.forBrightness(brightness, family: themeFamily);
    return LiquidGlassWidgets.wrap(
      theme: DeskMaterials.theme(brightness),
      child: CupertinoApp(
        title: 'SeekDesk',
        debugShowCheckedModeBanner: false,
        builder: (context, child) => DeskThemeScope(
          family: themeFamily,
          child: EditMenuBridge(
            child: ExtensionOverlays(
              state: state,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
        theme: CupertinoThemeData(
          brightness: brightness,
          primaryColor: colors.accent,
          scaffoldBackgroundColor: colors.canvas,
          barBackgroundColor: colors.paper,
          textTheme: CupertinoTextThemeData(
            textStyle: DeskTypography.base.copyWith(color: colors.ink),
          ),
        ),
        home: WorkspaceScreen(state: state),
      ),
    );
  }
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({required this.state, super.key});
  final AppState state;
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  late final ReaderEditors _editors;
  Object? _editorLocation, _editorChrome;
  final _editorChromeUpdates = ValueNotifier<int>(0);
  int _editorNavigationEpoch = 0;
  int destination = 0;
  bool _workspaceNavigationPending = false;
  bool _searchPresented = false;
  bool _autoLoading = false;
  final listScroll = ScrollController();
  bool? _hideListPreference;
  bool listVisible = true;
  bool _sidebarVisible = true;
  bool _compactSidebarOpen = false;
  bool _compactLayout = false;
  final _sidebarFocus = FocusScopeNode(debugLabel: 'Compact navigation');
  FocusNode? _beforeSidebarFocus;
  int _sidebarFocusRevision = 0;
  DeskSidebarSection? _sidebarSection = DeskSidebarSection.ranking;
  bool _sidebarSectionPending = false;
  int _sidebarSectionWriteRevision = 0;
  bool _rankingVisibilityScheduled = false;
  ModalRoute<dynamic>? _workspaceRoute;
  bool _routeCurrent = false;
  bool _editorRefreshScheduled = false;
  int _chromeEpoch = 0;
  bool _applicationActive = true;
  double? _sidebarDragWidth;
  double? _sidebarPendingWidth;
  int _sidebarWidthRevision = 0;
  double? _listDragWidth;
  double? _listPendingWidth;
  int _listWidthRevision = 0;
  String selected = '';
  bool overview = false;
  int _revision = -1;
  int _navigationRevision = 0;
  Object? _workspace, _session, _settings, _extensions, _proxy, _navigation;
  bool _connecting = true;
  String? _connectionError;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applicationActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _revision = widget.state.accessRevision;
    _navigationRevision = widget.state.navigationRevision;
    // Seed the same projections used by _changed. A draft-only notification
    // must not look like the first replacement of every loaded domain.
    _workspace = widget.state.domains['workspace'];
    _session = widget.state.domains['session'];
    _settings = widget.state.domains['settings'];
    _extensions = widget.state.domains['extensions'];
    _proxy = widget.state.domains['proxy'];
    _connecting = widget.state.connecting;
    _connectionError = widget.state.connectionError;
    // Native menu events are commands, not a destination to replay on mount.
    _navigation = widget.state.domains['navigation'];
    _sidebarSection = _storedSidebarSection;
    selected = widget.state.workspace.selectedTab;
    overview = !widget.state.workspace.showReader;
    _hideListPreference =
        widget.state.domain('settings')['workspace.hideListWhileReading'] ==
        true;
    listVisible = !_hideListPreference!;
    _editors = ReaderEditors(
      state: widget.state,
      readerVisible: () =>
          destination == 0 &&
          !overview &&
          widget.state.workspace.selected != null,
      canInteract: () =>
          mounted &&
          !_searchPresented &&
          _workspaceRoute?.isCurrent == true &&
          !_officeCovered &&
          !_compactSidebarOpen,
      navigationIdentity: () => _editorNavigationIdentity,
      revealTopic: (topic) async {
        if (!mounted) return;
        setState(() {
          destination = 0;
          overview = false;
        });
        await widget.state.selectTopic(topic);
      },
    );
    _editors.addListener(_editorsChanged);
    widget.state.addListener(_changed);
    listScroll.addListener(_older);
    HardwareKeyboard.instance.addHandler(_shortcut);
    _ensureVisibleReader();
  }

  void _changed() {
    final state = widget.state;
    final identityChanged = _revision != state.accessRevision;
    if (identityChanged) {
      _compactSidebarOpen = false;
      _sidebarSectionWriteRevision++;
      _sidebarSectionPending = false;
      _sidebarWidthRevision++;
      _sidebarDragWidth = null;
      _sidebarPendingWidth = null;
      _listWidthRevision++;
      _listDragWidth = null;
      _listPendingWidth = null;
    }
    if (!_sidebarSectionPending &&
        (identityChanged || !identical(_settings, state.domains['settings']))) {
      _sidebarSection = _storedSidebarSection;
    }
    final menuNavigation = state.domains['navigation'];
    final menuChanged =
        menuNavigation != null && !identical(menuNavigation, _navigation);
    if (menuChanged) {
      _navigation = menuNavigation;
      // Consume covered commands once. Cancelling search or an editor must not
      // replay a menu event and unexpectedly replace the restored page.
      if (_canNavigate) {
        final target = switch (stringValue(menuNavigation['destination'])) {
          'forum' => 0,
          'inbox' => 1,
          'extensions' => 2,
          'settings' => 3,
          _ => destination,
        };
        if (target != destination) {
          _navigate(() => setState(() => destination = target));
        }
      }
    }
    final navigating = _navigationRevision != state.navigationRevision;
    if (navigating) {
      _compactSidebarOpen = false;
      _navigationRevision = state.navigationRevision;
      if (!state.hasWorkspaceLeaveGuard) {
        destination = 0;
        overview = false;
      }
    }
    final hide =
        state.domain('settings')['workspace.hideListWhileReading'] == true;
    if (_hideListPreference != hide) {
      _hideListPreference = hide;
      listVisible = !hide;
    }
    if (!identical(_workspace, state.domains['workspace']) &&
        state.domains['workspace'] != null &&
        !navigating) {
      overview = !state.workspace.showReader;
    }
    final next = state.workspace.selectedTab;
    final selectionChanged = next != selected;
    if (selectionChanged) {
      selected = next;
      if (next.isNotEmpty && !state.hasWorkspaceLeaveGuard) {
        destination = 0;
        overview = !state.workspace.showReader;
      }
    }
    if (identityChanged || menuChanged || selectionChanged) {
      _ensureVisibleReader();
    }
    final disabledRanking = destination == 4 && !_rankingEnabled;
    if (disabledRanking) destination = 0;
    final changed =
        disabledRanking ||
        navigating ||
        menuChanged ||
        _revision != state.accessRevision ||
        !identical(_workspace, state.domains['workspace']) ||
        !identical(_session, state.domains['session']) ||
        !identical(_settings, state.domains['settings']) ||
        !identical(_extensions, state.domains['extensions']) ||
        !identical(_proxy, state.domains['proxy']) ||
        _connecting != state.connecting ||
        _connectionError != state.connectionError;
    _revision = state.accessRevision;
    _workspace = state.domains['workspace'];
    _session = state.domains['session'];
    _settings = state.domains['settings'];
    _extensions = state.domains['extensions'];
    _proxy = state.domains['proxy'];
    _connecting = state.connecting;
    _connectionError = state.connectionError;
    if (mounted && changed) setState(() {});
    _scheduleRankingVisibility();
  }

  Object get _editorNavigationIdentity {
    final location = (
      widget.state.accessRevision,
      widget.state.navigationRevision,
      widget.state.workspace.selectedTab,
      widget.state.workspace.selected?.url,
      destination,
      overview,
    );
    if (_editorLocation != location) {
      _editorLocation = location;
      _editorNavigationEpoch++;
    }
    return _editorNavigationEpoch;
  }

  void _editorsChanged() {
    final identity = (_editors.presented?.id, _editors.recovery?.id);
    if (_editorChrome == identity || !mounted) return;
    _editorChrome = identity;
    // Invalidate queued native actions immediately, but rebuild only chrome.
    // Opening a local editor does not change the forum document or list.
    _chromeEpoch++;
    _editorChromeUpdates.value++;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.rankings.setVisible(false);
    widget.state.removeListener(_changed);
    _editors.removeListener(_editorsChanged);
    _editors.dispose();
    _editorChromeUpdates.dispose();
    HardwareKeyboard.instance.removeHandler(_shortcut);
    listScroll.dispose();
    _sidebarFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context), state = widget.state;
    _editorNavigationIdentity;
    _scheduleEditorRefresh();
    return LayoutBuilder(
      builder: (context, windowBounds) {
        final compact = windowBounds.maxWidth < 990;
        if (_compactLayout != compact) {
          _compactLayout = compact;
          _compactSidebarOpen = false;
          _sidebarDragWidth = null;
        }
        _scheduleRankingVisibility();
        return ListenableBuilder(
          listenable: _editorChromeUpdates,
          child: Expanded(
            child: state.connectionError != null && state.domains.isEmpty
                ? DeskEmpty(
                    '本机服务尚未连接',
                    detail: state.connectionError,
                    action: DeskButton('重新连接', onTap: state.connect),
                  )
                : ReaderEditorHost(
                    editors: _editors,
                    child: LayoutBuilder(
                      builder: (context, bounds) =>
                          _workspaceBody(bounds, compact),
                    ),
                  ),
          ),
          // Only chrome subscribes to route currentness. The reader/list child
          // remains mounted without being rebuilt by an image or tool overlay.
          builder: (context, workspaceChild) => Builder(
            builder: (context) {
              _bindWorkspaceRoute(ModalRoute.of(context));
              final chromeContext = _chromeContext;
              final account = _accountPresentation;
              final avatar = _officeCovered ? '' : account.avatar;
              return WindowChromeBridge(
                snapshot: _chromeSnapshot(compact: compact, dark: colors.dark),
                actionContext: chromeContext,
                onAction: (action) =>
                    _performChromeAction(action, chromeContext),
                avatarKey: avatar.isEmpty
                    ? null
                    : (state.accessRevision, account.owner, avatar),
                loadAvatar: avatar.isEmpty
                    ? null
                    : () => state.image(avatar, kind: 'avatar'),
                builder: (context, nativeChrome) => CupertinoPageScaffold(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: DeskBackdrop.themed(colors),
                        ),
                      ),
                      SafeArea(
                        child: Column(
                          children: [
                            if (!nativeChrome)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  14,
                                  20,
                                  14,
                                ),
                                child: Row(
                                  children: [
                                    TextFieldTapRegion(
                                      child: DeskIcon(
                                        compact
                                            ? (_compactSidebarOpen
                                                  ? '关闭导航'
                                                  : '打开导航')
                                            : _sidebarVisible
                                            ? '收起侧栏'
                                            : '展开侧栏',
                                        CupertinoIcons.sidebar_left,
                                        _toggleSidebar,
                                      ),
                                    ),
                                    const SizedBox(width: 11),
                                    MergeSemantics(
                                      child: Semantics(
                                        label: 'SeekDesk 首页',
                                        button: true,
                                        child: CupertinoButton(
                                          padding: EdgeInsets.zero,
                                          minimumSize: const Size(93, 34),
                                          onPressed: _goHome,
                                          child: DeskWordmark(
                                            palette: stringValue(
                                              state.domain(
                                                'settings',
                                              )['workspace.logoPalette'],
                                              'Cobalt',
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    DeskButton(
                                      '搜索帖子',
                                      semanticLabel: '搜索帖子或打开链接',
                                      icon: CupertinoIcons.search,
                                      width:
                                          MediaQuery.sizeOf(context).width < 920
                                          ? 96
                                          : 116,
                                      onTap: _openSearch,
                                    ),
                                    const SizedBox(width: 12),
                                    if (state.connecting)
                                      const CupertinoActivityIndicator(),
                                    const SizedBox(width: 12),
                                    if (destination != 0 &&
                                        destination != 5) ...[
                                      DeskButton(
                                        '返回论坛',
                                        icon: CupertinoIcons.chevron_left,
                                        onTap: _returnToForum,
                                      ),
                                      const SizedBox(width: 12),
                                    ],
                                    if (jsonItems(
                                      state.domain('extensions')['items'],
                                    ).any(
                                      (item) =>
                                          item['id'] == 'office' &&
                                          item['active'] == true,
                                    )) ...[
                                      DeskIcon(
                                        stringValue(
                                          jsonMap(
                                            jsonMap(
                                              state.domain(
                                                'extensions',
                                              )['settings'],
                                            )['office'],
                                          )['button'],
                                          '切换办公视图',
                                        ),
                                        CupertinoIcons.table,
                                        _openOffice,
                                      ),
                                      const SizedBox(width: 12),
                                    ],
                                    _notificationsButton(),
                                    const SizedBox(width: 12),
                                    _accountButton(compact: compact),
                                  ],
                                ),
                              ),
                            workspaceChild!,
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 16,
                        left: 16,
                        right: 16,
                        child: WorkspaceMessage(state: state),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  bool get _officeCovered {
    final extensions = widget.state.domain('extensions');
    return jsonItems(extensions['items'])
            .any((item) => item['id'] == 'office' && item['active'] == true) &&
        jsonMap(jsonMap(extensions['settings'])['office'])['presented'] == true;
  }

  bool get _canUseWorkspace =>
      mounted &&
      !_searchPresented &&
      _workspaceRoute?.isCurrent == true &&
      !_officeCovered &&
      _editors.recovery == null;

  bool get _canNavigate =>
      _canUseWorkspace && !_compactSidebarOpen && !_workspaceNavigationPending;

  void _navigate(VoidCallback action, {VoidCallback? onCancelled}) {
    if (!_canNavigate) return;
    if (!widget.state.hasWorkspaceLeaveGuard) {
      action();
      return;
    }
    unawaited(_guardedNavigation(action, onCancelled: onCancelled));
  }

  Future<void> _guardedNavigation(
    VoidCallback action, {
    VoidCallback? onCancelled,
  }) async {
    final state = widget.state;
    final revision = state.accessRevision;
    final navigation = state.navigationRevision;
    final origin = destination;
    _workspaceNavigationPending = true;
    bool approved;
    try {
      approved = await state.prepareWorkspaceLeave();
    } finally {
      _workspaceNavigationPending = false;
    }
    if (!approved) {
      onCancelled?.call();
      return;
    }
    if (mounted &&
        identical(state, widget.state) &&
        revision == state.accessRevision &&
        navigation == state.navigationRevision &&
        origin == destination &&
        _canNavigate) {
      action();
    }
  }

  // This token is compared again at action delivery, not only after a rebuild.
  // It prevents a native click made for one account/page from reaching another.
  Object get _chromeContext => (
    widget.state.accessRevision,
    widget.state.navigationRevision,
    widget.state.workspace.selectedTab,
    widget.state.workspace.board,
    destination,
    _chromeEpoch,
    _compactLayout,
    _compactSidebarOpen,
    _sidebarVisible,
    _canUseWorkspace,
    widget.state.domain('session')['account'],
    _editors.presented?.id,
    _editors.recovery?.id,
  );

  Map<String, Object?> _chromeSnapshot({
    required bool compact,
    required bool dark,
  }) {
    final state = widget.state;
    final covered = _officeCovered;
    final unread = jsonMap(state.domain('session')['unread']);
    final office = jsonMap(
      jsonMap(state.domain('extensions')['settings'])['office'],
    );
    final showOffice = jsonItems(state.domain('extensions')['items'])
        .any((item) => item['id'] == 'office' && item['active'] == true);
    final showBack = destination != 0 && destination != 5;
    return {
      'enabledActions': [
        if (_canUseWorkspace) 'sidebar',
        if (_canNavigate) ...[
          'home',
          'search',
          'notifications',
          'account',
          if (showBack) 'back',
          if (showOffice) 'office',
        ],
      ],
      'compact': compact,
      'sidebarOpen': compact ? _compactSidebarOpen : _sidebarVisible,
      'showBack': !covered && showBack,
      'showOffice': !covered && showOffice,
      'officeLabel': stringValue(office['button'], '切换办公视图'),
      'officeCovered': covered,
      'accountLabel': covered ? '' : _accountLabel,
      'accountName': covered ? '' : _accountPresentation.title,
      'unreadCount': covered
          ? 0
          : intValue(unread['mentions']) +
                intValue(unread['replies']) +
                intValue(unread['messages']),
      'connecting': !covered && state.connecting,
      'dark': dark,
      'appearance': stringValue(
        state.domain('settings')['appearance'],
        'system',
      ),
      'palette': stringValue(
        state.domain('settings')['workspace.logoPalette'],
        'Cobalt',
      ),
    };
  }

  bool _performChromeAction(String action, Object expectedContext) {
    if (!mounted || expectedContext != _chromeContext) return false;
    if (action == 'sidebar') {
      if (!_canUseWorkspace) return false;
      _toggleSidebar();
      return true;
    }
    if (!_canNavigate) return false;
    switch (action) {
      case 'home':
        _goHome();
      case 'search':
        _openSearch();
      case 'back':
        if (destination == 0 || destination == 5) return false;
        _returnToForum();
      case 'notifications':
        _openNotifications();
      case 'account':
        _openAccount();
      case 'office':
        if (!_officeEnabled) return false;
        _openOffice();
      default:
        return false;
    }
    return true;
  }

  void _toggleSidebar() {
    if (!_canUseWorkspace) return;
    if (_compactLayout) {
      _toggleCompactSidebar();
    } else {
      setState(() {
        _sidebarVisible = !_sidebarVisible;
        _sidebarDragWidth = null;
      });
    }
  }

  bool get _officeEnabled =>
      jsonItems(widget.state.domain('extensions')['items'])
          .any((item) => item['id'] == 'office' && item['active'] == true);

  void _openOffice() {
    if (!_canNavigate || !_officeEnabled) return;
    widget.state.act('extensions.office', {'presented': true}, 'extensions');
  }

  VoidCallback? _closeCompactSidebar({bool restoreFocus = true}) {
    if (!_compactSidebarOpen) return null;
    final ticket = ++_sidebarFocusRevision;
    final revision = widget.state.accessRevision;
    final navigation = widget.state.navigationRevision;
    final previousDestination = destination;
    final previousOverview = overview;
    final previousTab = widget.state.workspace.selectedTab;
    setState(() => _compactSidebarOpen = false);
    final previous = _beforeSidebarFocus;
    _beforeSidebarFocus = null;
    if (previous == null) return null;
    // ExcludeFocus still blocks the retained body until its next build. Restore
    // after dismissal or a cancelled departure, never a later navigation or
    // popup cycle. The same checks apply when a leave dialog resolves later.
    void restore() {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            ticket != _sidebarFocusRevision ||
            !_compactLayout ||
            _compactSidebarOpen ||
            !_applicationActive ||
            !_canUseWorkspace ||
            revision != widget.state.accessRevision ||
            navigation != widget.state.navigationRevision ||
            previousDestination != destination ||
            previousOverview != overview ||
            previousTab != widget.state.workspace.selectedTab ||
            previous.context == null ||
            !previous.canRequestFocus) {
          return;
        }
        previous.requestFocus();
      });
    }

    if (restoreFocus) restore();
    return restore;
  }

  void _toggleCompactSidebar() {
    if (_compactSidebarOpen) {
      _closeCompactSidebar();
      return;
    }
    final ticket = ++_sidebarFocusRevision;
    final revision = widget.state.accessRevision;
    final navigation = widget.state.navigationRevision;
    _beforeSidebarFocus = FocusManager.instance.primaryFocus;
    setState(() => _compactSidebarOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ticket == _sidebarFocusRevision &&
          _compactSidebarOpen &&
          _canUseWorkspace &&
          revision == widget.state.accessRevision &&
          navigation == widget.state.navigationRevision) {
        _sidebarFocus.requestFocus();
      }
    });
  }

  void _fromSidebar(VoidCallback action) {
    if (!_canUseWorkspace) return;
    final restore = _closeCompactSidebar(restoreFocus: false);
    _navigate(action, onCancelled: restore);
  }

  Widget _workspaceBody(BoxConstraints bounds, bool compact) {
    final width = _sidebarWidth();
    final visible = compact ? _compactSidebarOpen : _sidebarVisible;
    final revision = widget.state.accessRevision;
    final state = widget.state;
    return Stack(
      children: [
        ExcludeFocus(
          excluding: _compactSidebarOpen,
          child: ExcludeSemantics(
            excluding: _compactSidebarOpen,
            child: IgnorePointer(
              ignoring: _compactSidebarOpen,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact && _sidebarVisible) ...[
                    SizedBox(width: width),
                    DeskSidebarDivider(
                      key: ValueKey('sidebar-divider-$revision'),
                      width: width,
                      onChanged: (value) {
                        if (revision != state.accessRevision) return;
                        setState(
                          () => _sidebarDragWidth = value.clamp(184, 360),
                        );
                      },
                      onCancel: () {
                        if (mounted && revision == state.accessRevision) {
                          setState(() => _sidebarDragWidth = null);
                        }
                      },
                      onChangeEnd: (value) {
                        if (revision == state.accessRevision) {
                          _commitSidebarWidth(value);
                        }
                      },
                      onReset: () {
                        if (revision == state.accessRevision) {
                          _commitSidebarWidth(228);
                        }
                      },
                    ),
                  ],
                  Expanded(
                    key: const ValueKey('workspace-content'),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        !compact && _sidebarVisible ? 0 : 16,
                        0,
                        16,
                        16,
                      ),
                      child: LayoutBuilder(
                        builder: (context, content) => DeskPageTransition(
                          identity: (state.accessRevision, destination),
                          child: switch (destination) {
                            0 => _forum(content.maxWidth),
                            1 => InboxScreen(state: state),
                            2 => ExtensionsScreen(
                              state: state,
                              onOpenRankings: _openRankingsFromExtensions,
                            ),
                            3 => PreferencesScreen(state: state),
                            4 => RankingsScreen(state: state),
                            5 => FriendLinksScreen(
                              state: state,
                              onReturn: _returnToForum,
                            ),
                            6 => AccountScreen(
                              state: state,
                              onClose: _returnToForum,
                            ),
                            _ => _forum(content.maxWidth),
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_compactSidebarOpen)
          Positioned.fill(
            child: ModalBarrier(
              key: const ValueKey('compact-sidebar-dismiss'),
              color: const Color(0x08000000),
              dismissible: true,
              onDismiss: _closeCompactSidebar,
              semanticsLabel: '关闭导航',
            ),
          ),
        // Keep a single sidebar mounted at the same keyed Stack position so its
        // section scroll offsets survive popover close/reopen and width changes.
        Positioned(
          key: const ValueKey('sidebar-surface'),
          left: compact ? 10 : 0,
          top: 0,
          width: width,
          height: compact
              ? (bounds.maxHeight - 16).clamp(0, 480)
              : bounds.maxHeight,
          child: Visibility(
            visible: visible,
            maintainState: true,
            child: FocusScope(
              node: _sidebarFocus,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: compact
                      ? DeskColors(context).paper
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(compact ? 16 : 0),
                  border: compact
                      ? Border.all(color: DeskColors(context).line)
                      : null,
                  boxShadow: compact
                      ? const [
                          BoxShadow(
                            color: Color(0x20000000),
                            blurRadius: 18,
                            offset: Offset(0, 5),
                          ),
                        ]
                      : null,
                ),
                child: DeskGlassPanel(
                  level: GlassLevel.background,
                  padding: EdgeInsets.zero,
                  child: _sidebar(width),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _shortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (_compactSidebarOpen &&
        _canUseWorkspace &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      _closeCompactSidebar();
      return true;
    }
    if (!_canNavigate) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editing =
        focus?.widget is EditableText ||
        focus?.findAncestorStateOfType<EditableTextState>() != null;
    final meta = keyboard.isMetaPressed,
        shift = keyboard.isShiftPressed,
        control = keyboard.isControlPressed,
        alt = keyboard.isAltPressed;
    final workspace = widget.state.workspace;
    if (meta &&
        !control &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyK) {
      if (focus != null && DocumentHistoryScope.maybeOf(focus) != null) {
        return false;
      }
      _openSearch();
      return true;
    }
    if (!meta &&
        !control &&
        !alt &&
        !shift &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      final editor = _editors.presented;
      if (editor != null && editor.binding.active) {
        editor.binding.requestClose?.call();
        return true;
      }
      if (editing && !widget.state.hasWorkspaceLeaveGuard) return false;
      if (destination != 0) {
        _returnToForum();
        return true;
      }
      if (!overview && workspace.selected != null) {
        _showOverview();
        return true;
      }
    }
    // Embedded destinations share the workspace route, but must not mutate
    // forum tabs or refresh the hidden listing through reading shortcuts.
    if (editing || destination != 0) return false;
    if (meta &&
        !control &&
        !alt &&
        !shift &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      final topic = workspace.selected;
      if (topic != null) {
        widget.state.closeTopic(topic.id);
      }
      return topic != null;
    }
    if (meta &&
        shift &&
        !control &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyT) {
      widget.state.reopenTopic();
      return true;
    }
    if (meta &&
        !shift &&
        !control &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyR) {
      final topic = workspace.selected;
      if (destination == 0 && topic != null && !overview) {
        widget.state.loadReader(topic.url, force: true);
      } else {
        widget.state.act('listing.refresh', {}, 'workspace');
      }
      return true;
    }
    if (control &&
        !meta &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        workspace.tabs.isNotEmpty) {
      final selected = workspace.tabs.indexWhere(
        (item) => item.id == workspace.selectedTab,
      );
      widget.state.selectTopic(
        workspace.tabs[(selected + (shift ? -1 : 1) + workspace.tabs.length) %
            workspace.tabs.length],
      );
      return true;
    }
    return false;
  }

  void _older() {
    if (_autoLoading ||
        !_canNavigate ||
        !listScroll.hasClients ||
        widget.state.domain('settings')['workspace.autoLoadOlder'] != true ||
        stringValue(widget.state.domain('workspace')['query']).isNotEmpty ||
        widget.state.domain('workspace')['failedToLoadOlder'] == true ||
        !widget.state.workspace.canLoadOlder ||
        widget.state.workspace.loading ||
        listScroll.position.extentAfter > 180) {
      return;
    }
    _autoLoading = true;
    widget.state
        .act('listing.older', {}, 'workspace')
        .whenComplete(() => _autoLoading = false);
  }

  Future<void> _openSearch() async {
    if (!_canNavigate) return;
    if (widget.state.hasWorkspaceLeaveGuard) {
      _navigate(() => unawaited(_openSearch()));
      return;
    }
    final state = widget.state;
    final revision = state.accessRevision;
    final navigation = state.navigationRevision;
    final origin = destination;
    final selection = state.workspace.selectedTab;
    final board = state.workspace.board;
    setState(() {
      _searchPresented = true;
      _chromeEpoch++;
    });
    WorkspaceSearchRequest? request;
    try {
      request = await showWorkspaceSearch(context, state: state);
    } finally {
      if (mounted) {
        setState(() {
          _searchPresented = false;
          _chromeEpoch++;
        });
      }
    }
    if (request == null ||
        !_canNavigate ||
        revision != state.accessRevision ||
        navigation != state.navigationRevision ||
        origin != destination ||
        selection != state.workspace.selectedTab ||
        board != state.workspace.board) {
      return;
    }

    final query = request.query.trim();
    if (query.isEmpty) return;
    final uri = Uri.tryParse(query);
    // Match the native official-topic boundary. Explicit links must use the
    // existing AppState path so same-tab #comment navigation stays one-shot.
    final parts = (uri?.pathSegments ?? const <String>[]).toList();
    while (parts.isNotEmpty && parts.last.isEmpty) {
      parts.removeLast();
    }
    final topicParts = parts.length == 1 ? parts.single.split('-') : <String>[];
    final topicID = topicParts.length >= 2 && topicParts.first == 'post'
        ? int.tryParse(topicParts[1])
        : null;
    if (uri != null &&
        uri.scheme == 'https' &&
        const ['nodeseek.com', 'www.nodeseek.com'].contains(uri.host) &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        topicID != null &&
        topicID > 0) {
      await state.openTopic(TopicData({'url': query}));
      return;
    }
    setState(() {
      destination = 0;
      overview = true;
      listVisible = true;
    });
    await state.act('listing.search', {
      'query': query,
      'scope': request.scope.toList(),
      'kind': request.kind,
    }, 'workspace');
  }

  void _showOverview() {
    if (!_canNavigate || destination != 0) return;
    setState(() => overview = true);
    widget.state.act('reader.overview', {}, 'workspace');
  }

  Future<void> _commitListWidth(double value) async {
    final width = value.roundToDouble().clamp(240, 620).toDouble();
    final ticket = ++_listWidthRevision;
    final revision = widget.state.accessRevision;
    setState(() {
      _listDragWidth = null;
      _listPendingWidth = width;
    });
    await widget.state.act('settings.update', {
      'key': 'workspace.topicColumnWidth',
      'value': width,
    }, 'settings');
    if (mounted &&
        ticket == _listWidthRevision &&
        revision == widget.state.accessRevision) {
      setState(() => _listPendingWidth = null);
    }
  }

  double _sidebarWidth() {
    final stored = numberValue(
      widget.state.domain('settings')['workspace.sidebarWidth'],
      228,
    );
    return (_sidebarDragWidth ??
            _sidebarPendingWidth ??
            (stored.isFinite ? stored : 228))
        .clamp(184, 360)
        .toDouble();
  }

  Future<void> _commitSidebarWidth(double value) async {
    final width = value.roundToDouble().clamp(184, 360).toDouble();
    final ticket = ++_sidebarWidthRevision;
    final revision = widget.state.accessRevision;
    setState(() {
      _sidebarDragWidth = null;
      _sidebarPendingWidth = width;
    });
    await widget.state.act('settings.update', {
      'key': 'workspace.sidebarWidth',
      'value': width,
    }, 'settings');
    if (mounted &&
        ticket == _sidebarWidthRevision &&
        revision == widget.state.accessRevision) {
      setState(() => _sidebarPendingWidth = null);
    }
  }

  DeskSidebarSection? get _storedSidebarSection =>
      switch (widget.state.domain('settings')['workspace.sidebarSection']) {
        'boards' => DeskSidebarSection.boards,
        'shortcuts' => DeskSidebarSection.shortcuts,
        'none' => null,
        _ => DeskSidebarSection.ranking,
      };

  Future<void> _commitSidebarSection(DeskSidebarSection? section) async {
    if (!_canUseWorkspace || _sidebarSection == section) return;
    final ticket = ++_sidebarSectionWriteRevision;
    final revision = widget.state.accessRevision;
    setState(() {
      _sidebarSection = section;
      _sidebarSectionPending = true;
    });
    await widget.state.act('settings.update', {
      'key': 'workspace.sidebarSection',
      'value': section?.name ?? 'none',
    }, 'settings');
    if (!mounted ||
        ticket != _sidebarSectionWriteRevision ||
        revision != widget.state.accessRevision) {
      return;
    }
    // Writes for this key are serialized by AppState. Keep the latest click
    // visible while earlier replies arrive; on failure return to the last
    // authoritative snapshot instead of pretending the preference was saved.
    setState(() {
      _sidebarSectionPending = false;
      _sidebarSection = _storedSidebarSection;
    });
    _scheduleRankingVisibility();
  }

  void _goHome() {
    _navigate(() {
      if (!_canNavigate) return;
      setState(() {
        destination = 0;
        overview = true;
        listVisible = true;
      });
      widget.state.act('listing.selectBoard', {'id': ''}, 'workspace');
    });
  }

  bool get _rankingEnabled =>
      jsonItems(widget.state.domain('extensions')['items'])
          .any((item) => item['id'] == 'hot' && item['active'] == true);

  void _openRankingsFromExtensions() {
    if (!_canNavigate || destination != 2 || !_rankingEnabled) return;
    setState(() => destination = 4);
    _scheduleRankingVisibility();
  }

  void _bindWorkspaceRoute(ModalRoute<dynamic>? route) {
    final current = route?.isCurrent == true;
    if (identical(_workspaceRoute, route) && _routeCurrent == current) return;
    _workspaceRoute = route;
    _routeCurrent = current;
    _chromeEpoch++;
    // Retained editors must update focus/shortcuts even though their document
    // stays mounted. Never notify their listeners during this chrome build.
    _scheduleEditorRefresh();
    _scheduleRankingVisibility();
  }

  void _scheduleEditorRefresh() {
    if (!mounted || _editorRefreshScheduled) return;
    _editorRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editorRefreshScheduled = false;
      if (mounted) _editors.refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applicationActive = state == AppLifecycleState.resumed;
    _syncRankingVisibility();
  }

  void _scheduleRankingVisibility() {
    if (!mounted || _rankingVisibilityScheduled) return;
    _rankingVisibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rankingVisibilityScheduled = false;
      if (mounted) _syncRankingVisibility();
    });
  }

  void _syncRankingVisibility() {
    final extensions = widget.state.domain('extensions');
    final office = jsonMap(jsonMap(extensions['settings'])['office']);
    final officeActive = jsonItems(extensions['items'])
        .any((item) => item['id'] == 'office' && item['active'] == true);
    final visible =
        _rankingEnabled &&
        _routeCurrent &&
        _applicationActive &&
        !(officeActive && office['presented'] == true) &&
        (destination == 4 ||
            (_compactLayout ? _compactSidebarOpen : _sidebarVisible) &&
                _sidebarSection == DeskSidebarSection.ranking);
    widget.state.rankings.setVisible(visible);
  }

  void _returnToForum() {
    _navigate(() {
      if (!_canNavigate) return;
      setState(() => destination = 0);
      _ensureVisibleReader();
    });
  }

  void _ensureVisibleReader() {
    final state = widget.state;
    final topic = state.workspace.selected;
    if (destination != 0 ||
        overview ||
        topic == null ||
        state.readerFor(topic.url).isNotEmpty) {
      return;
    }
    final revision = state.accessRevision;
    // An account change clears cached content even if the selected tab stays
    // the same. Hidden destinations wait until the user returns to reading.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          revision == state.accessRevision &&
          destination == 0 &&
          !overview &&
          state.workspace.selected?.id == topic.id &&
          state.workspace.selected?.url == topic.url &&
          state.readerFor(topic.url).isEmpty) {
        state.loadReader(topic.url);
      }
    });
  }

  void _compose() {
    _navigate(() {
      if (!_canNavigate) return;
      if (!widget.state.signedIn) {
        widget.state.act('session.signIn');
        return;
      }
      Navigator.push(
        context,
        CupertinoPageRoute<void>(
          builder: (context) => ComposerScreen(state: widget.state),
        ),
      );
    });
  }

  void _chooseBoard(String id) {
    _navigate(() {
      if (!_canNavigate) return;
      setState(() {
        destination = 0;
        overview = true;
        listVisible = true;
      });
      widget.state.act('listing.selectBoard', {'id': id}, 'workspace');
    });
  }

  void _chooseShortcut(String id) {
    _navigate(() {
      if (!_canNavigate) return;
      if (id == 'award') {
        _chooseBoard(id);
      } else {
        widget.state.act('shortcuts.open', {'id': id});
      }
    });
  }

  void _chooseFooter(String id) {
    if (id == 'my' && destination == 6) return;
    _navigate(() {
      if (!_canNavigate) return;
      setState(() {
        destination = switch (id) {
          'friends' => 5,
          'my' => 6,
          'extensions' => 2,
          'settings' => 3,
          _ => destination,
        };
      });
    });
  }

  void _openNotifications() {
    _navigate(() {
      if (_canNavigate) setState(() => destination = 1);
    });
  }

  ({String title, String label, String name, String avatar, int owner})
  get _accountPresentation {
    final state = widget.state;
    final owner = intValue(state.domain('session')['owner']);
    final profile = state.profile;
    final matching =
        state.signedIn && owner > 0 && intValue(profile['id']) == owner;
    final name = matching ? stringValue(profile['name']).trim() : '';
    final title = state.signedIn
        ? (name.isEmpty ? '我的账号' : name)
        : state.domain('session')['account'] == 'signedOut'
        ? '登录 NodeSeek'
        : '账号';
    return (
      title: title,
      label: state.signedIn
          ? (name.isEmpty ? '我的账号' : '我的账号，$name')
          : state.domain('session')['account'] == 'signedOut'
          ? '登录 NodeSeek'
          : 'NodeSeek 账户',
      name: name,
      avatar: matching ? stringValue(profile['avatar']) : '',
      owner: matching ? owner : 0,
    );
  }

  String get _accountLabel => _accountPresentation.label;

  void _openAccount() {
    if (!_canNavigate) return;
    if (widget.state.domain('session')['account'] == 'signedOut') {
      widget.state.act('session.signIn');
    } else {
      _chooseFooter('my');
    }
  }

  Widget _notificationsButton() {
    final unread = jsonMap(widget.state.domain('session')['unread']);
    final total =
        intValue(unread['mentions']) +
        intValue(unread['replies']) +
        intValue(unread['messages']);
    return Semantics(
      label: total > 0 ? '消息，$total 条未读' : '消息',
      button: true,
      onTap: _openNotifications,
      excludeSemantics: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DeskIcon('消息', CupertinoIcons.bell, _openNotifications),
          if (total > 0)
            Positioned(
              right: -5,
              top: -5,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemRed,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    total > 99 ? '99+' : '$total',
                    style: const TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _accountButton({required bool compact}) {
    final state = widget.state;
    final account = _accountPresentation;
    return Semantics(
      label: account.label,
      button: true,
      onTap: _openAccount,
      excludeSemantics: true,
      child: SizedBox(
        width: compact ? 36 : 144,
        child: CupertinoButton(
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 8),
          minimumSize: const Size(32, 32),
          onPressed: _openAccount,
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              NativeAvatar(
                state: state,
                name: account.name,
                url: account.avatar,
                size: 22,
              ),
              if (!compact) ...[
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    account.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: DeskColors(context).ink,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sidebar(double width) {
    final state = widget.state, extensions = state.domain('extensions');
    final shortcuts = jsonItems(state.domain('shortcuts')['items']);
    final keywordEnabled = jsonItems(extensions['items'])
        .any((item) => item['id'] == 'keywords' && item['active'] == true);
    return SizedBox(
      key: const ValueKey('workspace-sidebar'),
      width: width,
      child: DeskWorkspaceSidebar(
        boards: state.workspace.boards,
        shortcuts: shortcuts.isEmpty
            ? const [
                {'id': 'award', 'title': '精品区'},
                {'id': 'ruling', 'title': '管理记录'},
                {'id': 'lucky', 'title': '幸运抽奖'},
                {'id': 'invite', 'title': '邀请好友'},
              ]
            : shortcuts,
        boardTextSize: numberValue(
          state.domain('settings')['workspace.boardTextSize'],
          13,
        ).clamp(11, 24).toDouble(),
        selectedBoard: destination == 0 ? state.workspace.board : null,
        selectedShortcut: destination == 0 && state.workspace.board == 'award'
            ? 'award'
            : null,
        selectedFooter: switch (destination) {
          5 => 'friends',
          6 => 'my',
          2 => 'extensions',
          3 => 'settings',
          _ => null,
        },
        section: _sidebarSection,
        rankingEnabled: _rankingEnabled,
        extensionUnread: keywordEnabled ? intValue(extensions['unread']) : 0,
        ranking: SidebarRankings(
          state: state,
          onOpenTopic: (topic) =>
              _fromSidebar(() => widget.state.openTopic(topic)),
          onOpenFull: () => _fromSidebar(() => setState(() => destination = 4)),
        ),
        onSectionChanged: _commitSidebarSection,
        onBoard: (id) => _fromSidebar(() => _chooseBoard(id)),
        onShortcut: (id) => _fromSidebar(() => _chooseShortcut(id)),
        onFooter: (id) => _fromSidebar(() => _chooseFooter(id)),
        onCompose: () => _fromSidebar(_compose),
        onReselect: _compactLayout
            ? () {
                if (_canUseWorkspace) _closeCompactSidebar();
              }
            : null,
      ),
    );
  }

  Widget _forumNavigation({
    required bool reading,
    required bool canToggleList,
  }) {
    final state = widget.state;
    final toolbarHeight = workspaceToolbarHeight(context);
    return Padding(
      key: const ValueKey('forum-tab-bar'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
      child: GlassBackdropGroup(
        enabled: const bool.fromEnvironment(
          'SEEKDESK_SHARED_BACKDROP',
          defaultValue: true,
        ),
        child: Row(
          children: [
            if (reading) ...[
              DeskButton(
                '返回总览',
                icon: CupertinoIcons.chevron_left,
                width: 98,
                height: toolbarHeight,
                quiet: true,
                onTap: _showOverview,
              ),
              if (canToggleList) ...[
                const SizedBox(width: 6),
                DeskButton(
                  listVisible ? '收起列表' : '展开列表',
                  semanticLabel: listVisible ? '收起帖子列表' : '显示帖子列表',
                  icon: CupertinoIcons.sidebar_left,
                  width: 98,
                  height: toolbarHeight,
                  quiet: true,
                  onTap: () {
                    if (_canNavigate) {
                      setState(() => listVisible = !listVisible);
                    }
                  },
                ),
              ],
              const SizedBox(width: 12),
            ],
            if (state.workspace.tabs.isNotEmpty)
              Expanded(
                child: WorkspaceTabs(
                  state: state,
                  canInteract: () => _canNavigate && destination == 0,
                  onSelect: () => setState(() => overview = false),
                ),
              )
            else
              const Spacer(),
            if (state.workspace.closedTabs.isNotEmpty) ...[
              const SizedBox(width: 4),
              ClosedTabsButton(
                state: state,
                canInteract: () => _canNavigate && destination == 0,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _scopeTitle {
    final data = widget.state.domain('workspace');
    if (data['appliedSearchKind'] == 'people') return '仅用户';
    final scope = (data['appliedSearchScope'] as List? ?? const [])
        .whereType<String>()
        .toSet();
    if (scope.isEmpty) return '全部版块';
    if (scope.length == 1) {
      for (final board in widget.state.workspace.boards) {
        if (scope.contains(board['id'])) return stringValue(board['title']);
      }
    }
    return '${scope.length} 个版块';
  }

  Widget _listingHeader() {
    final state = widget.state, colors = DeskColors(context);
    final workspace = state.workspace, data = state.domain('workspace');
    final query = stringValue(data['query']);
    var title = workspace.board == 'award' ? '精品区' : '最新帖子';
    for (final board in workspace.boards) {
      if (board['id'] == workspace.board) {
        title = stringValue(board['title'], title);
      }
    }
    final order = data['feedOrder'] == 'replyTime' ? 1 : 0;
    final heading = Text(
      query.isEmpty ? title : '搜索结果',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DeskTypography.section.copyWith(color: colors.ink),
    );
    final refresh = DeskIcon(
      '刷新列表',
      CupertinoIcons.arrow_clockwise,
      () {
        if (_canNavigate) state.act('listing.refresh', {}, 'workspace');
      },
      busy: workspace.loading,
      quiet: true,
    );
    Widget orderPicker() => GlassSegmentedControl(
      segments: const [
        GlassSegment(label: '最新帖子'),
        GlassSegment(label: '最新回复'),
      ],
      selectedIndex: order,
      height: 29,
      quality: GlassQuality.premium,
      selectedTextStyle: DeskTypography.control.copyWith(fontSize: 11),
      unselectedTextStyle: DeskTypography.control.copyWith(
        fontSize: 11,
        color: colors.secondary,
        fontWeight: FontWeight.w400,
      ),
      backgroundColor: colors.ink.withValues(alpha: .045),
      onSegmentSelected: (index) {
        if (_canNavigate && !workspace.loading) {
          state.act('listing.order', {
            'order': index == 0 ? 'postTime' : 'replyTime',
          }, 'workspace');
        }
      },
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
          // Keep the larger user's text intact. Narrow panes retain the
          // existing two-row hierarchy instead of squeezing the labels.
          if (query.isEmpty &&
              workspace.board.isEmpty &&
              bounds.maxWidth >= 400 * scale) {
            return Row(
              key: const ValueKey('listing-header-inline'),
              children: [
                Expanded(child: heading),
                const SizedBox(width: 12),
                SizedBox(width: 190 * scale, child: orderPicker()),
                const SizedBox(width: 8),
                refresh,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: heading),
                  refresh,
                ],
              ),
              const SizedBox(height: 9),
              if (query.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: DeskButton(
                        query,
                        semanticLabel: '清除搜索：$query',
                        width: double.infinity,
                        height: 29,
                        icon: CupertinoIcons.xmark_circle_fill,
                        onTap: () {
                          if (_canNavigate) {
                            state.act('listing.clearSearch', {}, 'workspace');
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    DeskIcon(
                      '调整搜索范围：$_scopeTitle',
                      CupertinoIcons.slider_horizontal_3,
                      _openSearch,
                    ),
                  ],
                )
              else if (workspace.board.isEmpty)
                orderPicker()
              else
                Text(
                  workspace.board == 'award'
                      ? '论坛推荐'
                      : order == 0
                      ? '最新帖子'
                      : '最新回复',
                  style: DeskTypography.metadata.copyWith(
                    color: colors.secondary,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _listingStatus() {
    final state = widget.state, colors = DeskColors(context);
    final workspace = state.workspace, data = state.domain('workspace');
    final people = jsonItems(data['people']).length;
    final query = stringValue(data['query']);
    final peopleOnly =
        query.isNotEmpty && data['appliedSearchKind'] == 'people';
    final failed = peopleOnly
        ? stringValue(data['peopleErrorCode']).isNotEmpty
        : workspace.error.isNotEmpty ||
              stringValue(data['errorCode']).isNotEmpty;
    final loading = peopleOnly
        ? data['peopleLoading'] == true
        : workspace.loading;
    final hasForumPage = data['hasForumPage'] != false;
    final retryOlder =
        !peopleOnly &&
        data['failedToRefresh'] != true &&
        data['failedToLoadOlder'] == true &&
        workspace.canLoadOlder;
    final String status;
    if (peopleOnly) {
      status = failed
          ? people == 0
                ? '用户结果暂不可用'
                : '用户刷新失败 · 保留当前结果'
          : loading && people == 0
          ? '正在搜索用户…'
          : '$people 位用户';
    } else if (failed && retryOlder) {
      status = query.isEmpty ? '加载更早帖子失败 · 保留当前列表' : '搜索更早帖子失败 · 显示可用结果';
    } else if (query.isNotEmpty) {
      status = failed
          ? workspace.posts.isEmpty
                ? '站内搜索暂不可用'
                : '搜索失败 · 显示可用结果'
          : '搜索结果 · ${workspace.posts.length} 篇';
    } else if (workspace.board == 'award' && !hasForumPage) {
      status = failed ? '精品区暂不可用' : 'NodeSeek 精品帖';
    } else if (failed) {
      status = workspace.posts.isEmpty
          ? '列表暂不可用'
          : hasForumPage
          ? '刷新失败 · 保留当前列表'
          : '论坛列表不可用 · 备用订阅';
    } else {
      status = hasForumPage
          ? '已载入 ${workspace.posts.length} 篇'
          : '订阅 · ${workspace.posts.length} 篇';
    }
    final stamp = numberValue(data['lastRefresh']);
    final date = stamp > 0 && stamp.isFinite && stamp < 8640000000000000
        ? DateTime.fromMillisecondsSinceEpoch(stamp.toInt())
        : null;
    final statusText = Text(
      status,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: colors.secondary, fontSize: 11),
    );
    final detail = peopleOnly
        ? stringValue(data['peopleError'])
        : workspace.error;
    return Padding(
      key: const ValueKey('forum-list-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: failed && detail.isNotEmpty
                ? Tooltip(message: detail, child: statusText)
                : statusText,
          ),
          const SizedBox(width: 8),
          if (loading)
            const CupertinoActivityIndicator(radius: 7)
          else if (failed)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(30, 24),
              onPressed: retryOlder ? _retryOlder : _retryListing,
              child: Text(
                '重试',
                style: TextStyle(fontSize: 11, color: colors.accent),
              ),
            )
          else if (!peopleOnly && date != null)
            Text(
              '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
              style: TextStyle(color: colors.secondary, fontSize: 11),
            ),
        ],
      ),
    );
  }

  void _retryListing() {
    if (_canNavigate && !widget.state.workspace.loading) {
      widget.state.act('listing.refresh', {}, 'workspace');
    }
  }

  void _retryOlder() {
    if (_canNavigate &&
        !widget.state.workspace.loading &&
        widget.state.workspace.canLoadOlder) {
      widget.state.act('listing.older', {}, 'workspace');
    }
  }

  Widget _listingRecovery(String code, {bool older = false}) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      DeskButton(
        '重试',
        onTap: older ? _retryOlder : _retryListing,
        busy: widget.state.workspace.loading,
      ),
      if (code == 'signInRequired' || code == 'verification')
        DeskButton(
          code == 'signInRequired' ? '登录 NodeSeek' : '打开验证窗口',
          width: 126,
          onTap: () {
            if (!_canNavigate) return;
            if (code == 'signInRequired') {
              widget.state.act('session.signIn');
            } else {
              widget.state.act('session.verify', {
                'url': 'https://www.nodeseek.com/',
              });
            }
          },
        ),
    ],
  );

  Widget _postsEmpty() {
    final state = widget.state, data = state.domain('workspace');
    final query = stringValue(data['query']);
    final code = stringValue(data['errorCode']);
    final failed = state.workspace.error.isNotEmpty || code.isNotEmpty;
    // Combined loading includes the people request. A known post failure must
    // remain visible while the independent people search is still running.
    if (!failed && state.workspace.loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    return _scrollableListingEmpty(
      DeskEmpty(
        failed
            ? query.isNotEmpty
                  ? '暂时无法搜索论坛'
                  : '暂时无法读取帖子列表'
            : query.isNotEmpty
            ? '没有匹配的帖子'
            : '暂无帖子',
        key: const ValueKey('forum-posts-empty'),
        detail: failed
            ? state.workspace.error
            : query.isNotEmpty
            ? '调整搜索文字或范围后重试。'
            : '可刷新列表，或加载更早的帖子。',
        action: failed
            ? _listingRecovery(
                code,
                older:
                    data['failedToRefresh'] != true &&
                    data['failedToLoadOlder'] == true &&
                    state.workspace.canLoadOlder,
              )
            : DeskButton(
                query.isNotEmpty ? '调整搜索' : '刷新列表',
                onTap: query.isNotEmpty ? _openSearch : _retryListing,
              ),
      ),
    );
  }

  Widget _scrollableListingEmpty(DeskEmpty empty) => LayoutBuilder(
    builder: (context, bounds) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: bounds.maxHeight),
        child: empty,
      ),
    ),
  );

  Widget _peopleResults({bool compact = false}) {
    final state = widget.state, colors = DeskColors(context);
    final data = state.domain('workspace');
    final people = jsonItems(data['people']);
    final loading = data['peopleLoading'] == true;
    final code = stringValue(data['peopleErrorCode']);
    final failed = code.isNotEmpty;
    final nativeDescription = stringValue(data['peopleError']);
    final description = switch (code) {
      'signInRequired' => '登录 NodeSeek 后可搜索用户。',
      'verification' => '请完成 NodeSeek 站点验证后重试用户搜索。',
      _ => nativeDescription.isNotEmpty ? nativeDescription : '暂时无法读取用户结果。',
    };
    if (!compact && people.isEmpty) {
      if (loading && !failed) {
        return const Center(child: CupertinoActivityIndicator());
      }
      return _scrollableListingEmpty(
        DeskEmpty(
          failed ? '暂时无法读取用户结果' : '没有匹配的用户',
          detail: failed ? description : '调整搜索文字后重试。',
          action: failed
              ? _listingRecovery(code)
              : DeskButton('调整搜索', onTap: _openSearch),
        ),
      );
    }
    final showNotice = loading || failed || people.isEmpty;
    return ListView.builder(
      key: PageStorageKey(
        'forum-people:${state.accessRevision}:${stringValue(state.domain('workspace')['query'])}',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: people.length + (showNotice ? 1 : 0),
      itemBuilder: (context, index) {
        if (showNotice && index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failed
                      ? description
                      : loading
                      ? '正在搜索用户…'
                      : '没有匹配的用户',
                  style: TextStyle(color: colors.secondary, fontSize: 13),
                ),
                if (loading) ...[
                  const SizedBox(height: 8),
                  const CupertinoActivityIndicator(radius: 7),
                ],
                if (failed) ...[
                  const SizedBox(height: 8),
                  _listingRecovery(code),
                ],
              ],
            ),
          );
        }
        final person = people[index - (showNotice ? 1 : 0)];
        return HoverRow(
          onTap: () {
            if (!_canNavigate) return;
            Navigator.push(
              context,
              CupertinoPageRoute<void>(
                builder: (context) => AccountScreen(
                  state: state,
                  memberId: intValue(person['id']),
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
            child: Row(
              children: [
                NativeAvatar(
                  state: state,
                  name: stringValue(person['name']),
                  url: stringValue(person['avatar']),
                  size: 30,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stringValue(person['name']),
                    style: TextStyle(color: colors.ink, fontSize: 14),
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 12,
                  color: colors.secondary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _forum(double available) {
    final colors = DeskColors(context),
        state = widget.state,
        workspace = state.workspace,
        topic = overview ? null : workspace.selected;
    final peopleOnly =
        stringValue(state.domain('workspace')['query']).isNotEmpty &&
        state.domain('workspace')['appliedSearchKind'] == 'people';
    final showPeople =
        stringValue(state.domain('workspace')['query']).isNotEmpty &&
        state.domain('workspace')['appliedSearchKind'] != 'posts' &&
        state.domain('workspace')['showsPeopleResults'] != false;
    final showList =
        (listVisible || topic == null) && (available >= 780 || topic == null);
    final showReader = topic != null;
    if (!showList || !showReader) _listDragWidth = null;
    // Preserve the original 412-point reader minimum plus the 9-point handle.
    final maximumListWidth = (available - 412 - 9)
        .clamp(240.0, 620.0)
        .toDouble();
    final storedListWidth = numberValue(
      state.domain('settings')['workspace.topicColumnWidth'],
      340,
    );
    final listWidth =
        (_listDragWidth ??
                _listPendingWidth ??
                (storedListWidth.isFinite ? storedListWidth : 340.0))
            .clamp(240.0, maximumListWidth)
            .toDouble();
    final revision = state.accessRevision;
    return Column(
      key: const ValueKey('forum-content'),
      children: [
        if (workspace.tabs.isNotEmpty || workspace.closedTabs.isNotEmpty)
          _forumNavigation(
            reading: topic != null,
            canToggleList: available >= 780,
          ),
        Expanded(
          child: Row(
            key: const ValueKey('forum-pane-row'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showList)
                SizedBox(
                  key: const ValueKey('forum-list-pane'),
                  width: topic == null ? available : listWidth,
                  child: DeskDocument(
                    glassLevel: GlassLevel.panel,
                    child: Column(
                      children: [
                        _listingHeader(),
                        if (peopleOnly)
                          Expanded(child: _peopleResults())
                        else if (showPeople)
                          SizedBox(
                            height: 160,
                            child: _peopleResults(compact: true),
                          ),
                        Container(height: 1, color: colors.line),
                        if (!peopleOnly)
                          Expanded(
                            child: workspace.posts.isEmpty
                                ? _postsEmpty()
                                : ForumPostList(
                                    key: ValueKey(
                                      'forum-posts:${state.accessRevision}:${workspace.board}:${stringValue(state.domain('workspace')['query'])}:${stringValue(state.domain('workspace')['feedOrder'])}',
                                    ),
                                    state: state,
                                    controller: listScroll,
                                    selectedURL: topic?.url,
                                    canInteract: () =>
                                        _canNavigate && destination == 0,
                                    onOpen: (item) {
                                      setState(() => overview = false);
                                      state.openTopic(item);
                                    },
                                    footer: workspace.canLoadOlder
                                        ? Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: DeskButton(
                                              state.domain(
                                                        'workspace',
                                                      )['failedToLoadOlder'] ==
                                                      true
                                                  ? '重试加载更早帖子'
                                                  : stringValue(
                                                      state.domain(
                                                        'workspace',
                                                      )['query'],
                                                    ).isEmpty
                                                  ? '加载更早帖子'
                                                  : '搜索更早帖子',
                                              width: 150,
                                              busy: workspace.loading,
                                              onTap: _retryOlder,
                                            ),
                                          )
                                        : null,
                                  ),
                          ),
                        _listingStatus(),
                      ],
                    ),
                  ),
                ),
              if (showList && showReader)
                DeskSidebarDivider(
                  key: ValueKey('topic-column-divider-$revision'),
                  label: '帖子列表宽度',
                  adjustmentStep: 24,
                  width: listWidth,
                  minimum: 240,
                  maximum: maximumListWidth,
                  onChanged: (value) {
                    if (revision != state.accessRevision || !_canNavigate) {
                      return;
                    }
                    setState(() => _listDragWidth = value);
                  },
                  onCancel: () {
                    if (mounted && revision == state.accessRevision) {
                      setState(() => _listDragWidth = null);
                    }
                  },
                  onChangeEnd: (value) {
                    if (revision == state.accessRevision && _canNavigate) {
                      _commitListWidth(value);
                    } else if (mounted && revision == state.accessRevision) {
                      setState(() => _listDragWidth = null);
                    }
                  },
                  onReset: () {
                    if (_canNavigate) _commitListWidth(340);
                  },
                ),
              if (showReader)
                Expanded(
                  key: const ValueKey('forum-reader-pane'),
                  child: DeskDocument(
                    child: ReaderBackdrop(
                      enabled:
                          state.domain('settings')['workspace.mistBackdrop'] !=
                          false,
                      child: ReaderScreen(
                        key: ValueKey(
                          '${state.accessRevision}:${state.readerPositionEpoch}:${topic.url}',
                        ),
                        state: state,
                        topic: topic,
                        editors: _editors,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
