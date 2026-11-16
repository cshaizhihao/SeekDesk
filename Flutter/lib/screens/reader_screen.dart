import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart'
    show
        RenderSliverList,
        ScrollDirection,
        SliverGeometry,
        SliverMultiBoxAdaptorParentData;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/frame_diagnostics.dart';
import '../core/native_client.dart';
import '../models/snapshots.dart';
import '../models/reader_position.dart';
import '../state/app_state.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/forum_blocks.dart';
import 'composer_screen.dart';
import 'tools_screen.dart';
import 'inline_edit_screen.dart';
import '../widgets/reader_context.dart';
import '../widgets/reader_content_layout.dart';
import '../state/reader_editors.dart';
import '../widgets/reader_editor_host.dart';
import '../widgets/editor_header_diagnostics.dart';
import '../widgets/reader_tool_panel.dart';
import '../widgets/reader_wheel_scroll.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.state,
    required this.topic,
    this.editors,
    super.key,
  });
  final AppState state;
  final TopicData topic;
  final ReaderEditors? editors;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  static int _nextDiagnosticInstance = 0;
  final int _diagnosticInstance =
      FrameDiagnostics.enabled && FrameDiagnostics.rawFrames
      ? ++_nextDiagnosticInstance
      : 0;
  final _toolPanel = ReaderToolPanelController();
  late final _contentLayout = ReaderContentLayoutController(
    preserveAnchor: () => _preserveReadingAnchor(content: true),
    onGeometryResolved: _mediaGeometryResolved,
    readScrollPosition: () => scroll.hasClients ? scroll.position : null,
  );
  String? _waitingForMediaFloor;
  ReaderContentPoint? _contentPoint;
  double? _contentPointDy;
  double? _readerViewportHeight;
  late final ReaderWheelScrollController scroll;
  Timer? persist;
  Timer? _copyTimer;
  bool _copied = false;
  bool onlyAuthor = false;
  int _authorScan = 0;
  String? _authorStatus;
  bool _authorFailed = false;
  double? _normalOffset;
  List<FloorData>? _authorReplies;
  List<FloorData> _laidOutReplies = const [];
  FloorData? _authorRoot;
  Map<String, String> _authorSources = {};
  double fontSize = 15;
  JsonMap _snapshot = {};
  late final int revision;
  late final int positionEpoch;
  bool restored = false;
  final Set<String> reacting = {};
  final Set<String> revealed = {};
  Object? _settings, _extensions;
  late ({bool signedIn, String account, int owner, bool canCompose})
  _sessionValues;
  late ThreadData thread;
  double _lastOffset = 0;
  ReaderBodyAnchor? _lastBodyAnchor;
  bool _captureScheduled = false;
  int _captureGeneration = 0;
  bool _positionObserved = false;
  bool _restoring = false;
  bool seeking = false;
  final Map<String, GlobalKey> floorKeys = {};
  final Map<String, GlobalKey> _bodyKeys = {};
  final GlobalKey _replyReflowKey = GlobalKey();
  bool _anchorPending = false;
  bool _anchorUnresolved = false;
  // After successful reflow this remains the preferred visible floor until
  // actual input/navigation takes ownership. Reflow alone must not replace
  // it merely because an earlier body's tail has re-entered the viewport.
  String? _anchorFloor;
  double? _anchorDy;
  bool _applyingAnchor = false;
  int _anchorGeneration = 0;
  int _anchorLayoutGeneration = 0;
  ({
    double width,
    double fontSize,
    double authorScale,
    TextScaler textScaler,
    bool compact,
  })?
  _readingGeometry;
  int _restoreGeneration = 0;
  int _navigationSequence = 0;
  int _interactionEpoch = 0;

  bool get _hasBody => thread.root != null || thread.replies.isNotEmpty;
  FloorData? get _displayRoot =>
      thread.root ?? (onlyAuthor ? _authorRoot : null);

  List<FloorData> get _displayReplies {
    if (!onlyAuthor) return thread.replies;
    final author = _displayRoot;
    final local = thread.replies.where(
      (floor) => _belongsToAuthor(floor, author),
    );
    final collected = _authorReplies;
    if (collected == null) return local.toList();
    final result = {
      for (final floor in collected)
        if (_authorSources.containsKey(floor.id)) floor.id: floor,
      for (final floor in local) floor.id: floor,
    };
    return result.values.toList()
      ..sort((a, b) => intValue(a.id).compareTo(intValue(b.id)));
  }

  bool _belongsToAuthor(FloorData floor, FloorData? author) =>
      floor.isAuthor ||
      author != null &&
          (floor.authorID != null && author.authorID != null
              ? floor.authorID == author.authorID
              : floor.author.isNotEmpty && floor.author == author.author);

  void _clearAuthorView() {
    _authorScan++;
    onlyAuthor = false;
    _authorStatus = null;
    _authorFailed = false;
    _authorRoot = null;
    _authorReplies = null;
    _authorSources = {};
    _normalOffset = null;
  }

  void _toggleAuthorView() {
    if (!_ownsPosition || !_hasBody) return;
    scroll.cancelWheel();
    _cancelReadingAnchor();
    if (onlyAuthor) {
      final offset = _normalOffset;
      setState(_clearAuthorView);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !onlyAuthor && offset != null && scroll.hasClients) {
          scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
        }
      });
      return;
    }
    persist?.cancel();
    _normalOffset = scroll.hasClients ? scroll.offset : null;
    setState(() => onlyAuthor = true);
    unawaited(_scanAuthorPages());
  }

  Future<void> _scanAuthorPages() async {
    final source = Uri.tryParse(widget.topic.url);
    final route = source == null
        ? null
        : RegExp(r'^/post-([1-9][0-9]*)-[1-9][0-9]*/?$')
              .firstMatch(source.path);
    final initial = thread;
    if (source == null || route == null) return;
    final scan = ++_authorScan;
    bool active() =>
        mounted && _ownsPosition && onlyAuthor && scan == _authorScan;
    var last = initial.page;
    void expand(ThreadData page) {
      for (final link in page.pages) {
        final number = intValue(link['number']);
        final url = AppState.webLink(stringValue(link['url']));
        if (url != null &&
            const {'nodeseek.com', 'www.nodeseek.com'}.contains(url.host) &&
            url.scheme == 'https' &&
            url.path.replaceFirst(RegExp(r'/$'), '') ==
                '/post-${route[1]}-$number' &&
            number > last) {
          last = number;
        }
      }
    }

    expand(initial);
    if (last == 1 && initial.page == 1) return;
    final found = <String, FloorData>{};
    final origins = <String, String>{};
    FloorData? author = initial.root;
    var number = 1;
    setState(() => _authorFailed = false);
    try {
      for (; number <= last; number++) {
        if (!active()) return;
        setState(() => _authorStatus = '正在汇总楼主回复 · 第 $number / $last 页');
        var page = initial;
        if (number != initial.page) {
          final result = await widget.state.client.call('reader.authorPage', {
            'url': widget.topic.url,
            'page': number,
          });
          if (!active()) return;
          if (intValue(result['accessRevision'], revision) != revision ||
              result['thread'] is! Map) {
            throw const NativeFailure('unavailable', '帖子页面暂时无法读取。');
          }
          page = ThreadData(jsonMap(result['thread']));
          if (page.page != number) {
            throw const NativeFailure('changed', '帖子页码已变化。');
          }
        }
        author ??= page.root;
        expand(page);
        for (final floor in page.replies) {
          if (floor.id.isEmpty || !_belongsToAuthor(floor, author)) continue;
          found.putIfAbsent(floor.id, () => floor);
          if (number != initial.page) {
            origins.putIfAbsent(
              floor.id,
              () => source
                  .replace(
                    path: '/post-${route[1]}-$number',
                    query: '',
                    fragment: 'comment-${floor.id}',
                  )
                  .toString(),
            );
          } else {
            found[floor.id] = floor;
            origins.remove(floor.id);
          }
        }
      }
      if (!active()) return;
      setState(() {
        _authorRoot = author;
        _authorReplies = found.values.toList()
          ..sort((a, b) => intValue(a.id).compareTo(intValue(b.id)));
        _authorSources = origins;
        _authorStatus = null;
      });
    } catch (_) {
      if (!active()) return;
      setState(() {
        _authorFailed = true;
        _authorStatus = '第 $number 页读取失败，尚未汇总全部楼主回复。';
      });
    }
  }

  ({bool signedIn, String account, int owner, bool canCompose})
  get _sessionProjection {
    final session = widget.state.domain('session');
    return (
      signedIn: widget.state.signedIn,
      account: stringValue(session['account']),
      owner: intValue(session['owner'], -1),
      canCompose: session['canCompose'] != false,
    );
  }

  bool get _ownsPosition =>
      widget.state.ownsReaderPosition(revision, positionEpoch);

  double get _savedOffset {
    final value =
        widget.state.readerOffset(widget.topic.url) ??
        numberValue(_snapshot['scrollOffset']);
    return value.isFinite ? value.clamp(0, 100000000).toDouble() : 0;
  }

  ReaderBodyAnchor? get _savedBodyAnchor =>
      widget.state.readerOffset(widget.topic.url) != null
      ? widget.state.readerBodyAnchor(widget.topic.url)
      : ReaderBodyAnchor.parse(_snapshot['bodyAnchor']);

  @override
  void initState() {
    super.initState();
    revision = widget.state.accessRevision;
    positionEpoch = widget.state.readerPositionEpoch;
    fontSize = numberValue(
      widget.state.domain('settings')['workspace.readerTextSize'],
      15,
    );
    _snapshot = widget.state.readerFor(widget.topic.url);
    thread = ThreadData(jsonMap(_snapshot['thread']));
    _settings = widget.state.domains['settings'];
    _extensions = widget.state.domains['extensions'];
    _sessionValues = _sessionProjection;
    scroll = ReaderWheelScrollController(
      onUserWheel: _userScroll,
      onWheel: FrameDiagnostics.enabled && FrameDiagnostics.rawFrames
          ? (event, smooth) => FrameDiagnostics.recordReaderEvent(
              smooth
                  ? ReaderTimingEvent.wheelSmooth
                  : ReaderTimingEvent.wheelImmediate,
              sourceTime: event.timeStamp,
              dx: event.scrollDelta.dx,
              dy: event.scrollDelta.dy,
              interaction: _interactionEpoch,
              nativeMatched: scroll.input.current?.matched,
              nativePrecise: scroll.input.current?.precise,
              nativeModifiers: scroll.input.current?.modifiers,
              nativePhase: scroll.input.current?.phase,
              nativeMomentumPhase: scroll.input.current?.momentumPhase,
              wheelMotionEnabled: scroll.motionEnabled,
            )
          : null,
      initialScrollOffset: _savedOffset,
      keepScrollOffset: false,
      onAttach: _readerAttached,
      onDetach: _readerDetached,
    );
    _lastOffset = _savedOffset;
    scroll.addListener(_position);
    widget.state.addListener(_changed);
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.readerInit);
    }
    if (_hasBody) {
      _scheduleRestore();
    }
  }

  void _readerAttached(ScrollPosition position) {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.readerAttach);
    }
    // A controller survives a temporary error/empty body, but its next
    // ScrollPosition starts from the controller's original initial offset.
    // Restore that new position before accepting any of its observations.
    if (_hasBody && !_restoring) _scheduleRestore();
  }

  void _readerDetached(ScrollPosition position) {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.readerDetach);
    }
    _retireBodyRestore();
  }

  void _retireBodyRestore() {
    scroll.cancelWheel();
    _cancelReadingAnchor();
    _restoreGeneration++;
    _captureGeneration++;
    _captureScheduled = false;
    _restoring = false;
    _waitingForMediaFloor = null;
    restored = false;
    seeking = false;
    persist?.cancel();
    // The last mature position remains valid for disposal while an error is
    // visible. Detaching never publishes the new position's temporary zero.
  }

  void _changed() {
    if (!_ownsPosition) {
      scroll.cancelWheel();
      _cancelReadingAnchor();
      persist?.cancel();
      _positionObserved = false;
      _lastOffset = 0;
      _lastBodyAnchor = null;
      _restoreGeneration++;
      _restoring = false;
      _waitingForMediaFloor = null;
      seeking = false;
      revealed.clear();
      if (mounted) {
        setState(() {
          _clearAuthorView();
          _snapshot = {};
          thread = ThreadData({});
        });
      }
      return;
    }
    final next = widget.state.readerFor(widget.topic.url);
    final nextSession = _sessionProjection;
    final bodyChanged = !identical(_snapshot['thread'], next['thread']);
    final nextThread = bodyChanged
        ? ThreadData(jsonMap(next['thread']))
        : thread;
    final nextHasBody =
        nextThread.root != null || nextThread.replies.isNotEmpty;
    final nextSettings = widget.state.domain('settings');
    final previousSettings = jsonMap(_settings);
    final reportScaleChanged = ['nq', 'tq'].any(
      (kind) =>
          numberValue(previousSettings['workspace.${kind}ReportScale'], 100) !=
          numberValue(nextSettings['workspace.${kind}ReportScale'], 100),
    );
    final restoreBodyLayout =
        _hasBody &&
            nextHasBody &&
            (bodyChanged || _sessionValues != nextSession || reportScaleChanged)
        ? _preserveReadingAnchor(content: reportScaleChanged)
        : null;
    if (bodyChanged) {
      _captureGeneration++;
      _captureScheduled = false;
    }
    if (_hasBody && !nextHasBody) _retireBodyRestore();
    final changed =
        !identical(next, _snapshot) ||
        !identical(_settings, widget.state.domains['settings']) ||
        !identical(_extensions, widget.state.domains['extensions']) ||
        _sessionValues != nextSession;
    if (changed && mounted) {
      setState(() {
        _snapshot = next;
        thread = nextThread;
        fontSize = numberValue(
          widget.state.domain('settings')['workspace.readerTextSize'],
          15,
        );
        _settings = widget.state.domains['settings'];
        _extensions = widget.state.domains['extensions'];
        _sessionValues = nextSession;
      });
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        _recordReaderTiming(ReaderTimingEvent.readerSnapshot);
      }
    }
    if (restoreBodyLayout != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => restoreBodyLayout());
    }
    final navigation = widget.state.readerNavigation(widget.topic.url);
    if (nextHasBody &&
        (!restored && !_restoring ||
            bodyChanged && _restoring ||
            navigation != null && navigation.sequence != _navigationSequence)) {
      _scheduleRestore();
    } else if (bodyChanged && nextHasBody && restored && !_restoring) {
      _capturePositionAfterLayout();
    }
  }

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.topic.url != widget.topic.url) {
      scroll.cancelWheel();
      _toolPanel.dismiss();
      _cancelReadingAnchor();
      _readingGeometry = null;
    }
  }

  void _scheduleRestore() {
    scroll.cancelWheel();
    _cancelReadingAnchor();
    _waitingForMediaFloor = null;
    restored = false;
    _navigationSequence =
        widget.state.readerNavigation(widget.topic.url)?.sequence ?? 0;
    final generation = ++_restoreGeneration;
    // Retire the previous seek immediately, before the next frame can resume it.
    _restoring = true;
    persist?.cancel();
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.restoreScheduled);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_currentRestore(generation)) {
        unawaited(_restore(generation));
      } else if (mounted && generation == _restoreGeneration) {
        // A scheduled frame is not proof that a scroll body was attached.
        // A later attach or real body arrival will schedule the attempt.
        _restoring = false;
      }
    });
  }

  bool _currentRestore(int generation, [ScrollPosition? position]) =>
      mounted &&
      _ownsPosition &&
      generation == _restoreGeneration &&
      _hasBody &&
      scroll.hasClients &&
      (position == null || identical(position, scroll.position)) &&
      scroll.position.hasContentDimensions;

  void _consumeRestoreNavigation() {
    final navigation = widget.state.readerNavigation(widget.topic.url);
    if (navigation?.sequence == _navigationSequence) {
      widget.state.takeReaderNavigation(widget.topic.url);
    }
  }

  void _mediaGeometryResolved() {
    final floor = _waitingForMediaFloor;
    if (!mounted ||
        !_ownsPosition ||
        !_restoring ||
        floor == null ||
        _contentLayout.hasUnresolvedGeometry(floor) ||
        _bodyKeys[floor]?.currentContext == null) {
      return;
    }
    // The image's own update supplies this frame. Resume only after its new
    // layout; no polling, timers, extra image fetches or repeated seek loops.
    _scheduleRestore();
  }

  Future<void> _restore(int generation) async {
    if (!_currentRestore(generation)) return;
    final position = scroll.position;
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.restoreStart);
    }
    // Keep the command pending across temporary body removal. Completion or
    // real user input consumes it; a cancelled old position cannot consume a
    // newer navigation command.
    final navigation = widget.state.readerNavigation(widget.topic.url);
    final savedOffset = _savedOffset;
    final savedBodyAnchor = _savedBodyAnchor;
    final localOffset = widget.state.readerOffset(widget.topic.url);
    final fragment = Uri.tryParse(widget.topic.url)?.fragment ?? '';
    final anchor = stringValue(_snapshot['anchor']);
    final initialFloor =
        widget.state.canRestoreReaderURLFragment(widget.topic.url)
        ? (RegExp(r'^(?:comment-)?([0-9]{1,12})$').firstMatch(fragment)?[1])
        : null;
    // A retained tab URL is not a fresh navigation command. Only first-open
    // fallback with no saved progress may derive a floor from that URL, and
    // a previous account's fragment cannot become the new account's progress.
    final requested =
        navigation?.floor ??
        (localOffset == null && _savedOffset == 0
            ? initialFloor ??
                  (anchor.startsWith('floor-') ? anchor.substring(6) : null)
            : null);
    if (requested != null && int.tryParse(requested) != null) {
      final all = [if (thread.root != null) thread.root!, ...thread.replies];
      if (all.isEmpty) {
        _restoring = false;
        return;
      }
      var target = all.first;
      for (final floor in all) {
        if (((int.tryParse(floor.id) ?? 0) - int.parse(requested)).abs() <
            ((int.tryParse(target.id) ?? 0) - int.parse(requested)).abs()) {
          target = floor;
        }
      }
      setState(() {
        if (onlyAuthor &&
            !_belongsToAuthor(target, thread.root ?? _authorRoot)) {
          _clearAuthorView();
        }
        seeking = true;
      });
      scroll.jumpTo(0);
      for (
        var attempt = 0;
        attempt < 400 && _currentRestore(generation, position);
        attempt++
      ) {
        await WidgetsBinding.instance.endOfFrame;
        if (!_currentRestore(generation, position)) return;
        final targetContext = floorKeys[target.id]?.currentContext;
        if (targetContext != null && targetContext.mounted) {
          await Scrollable.ensureVisible(
            targetContext,
            alignment: .08,
            duration: Duration.zero,
          );
          if (!_currentRestore(generation, position)) return;
          break;
        }
        final next = (scroll.offset + scroll.position.viewportDimension * .85)
            .clamp(0, scroll.position.maxScrollExtent);
        if (next == scroll.offset) break;
        scroll.jumpTo(next.toDouble());
      }
      if (!_currentRestore(generation, position)) return;
      // ensureVisible/jumpTo updates pixels before the body's boxes are laid
      // out. Read the final geometry before publishing an explicit location.
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!_currentRestore(generation, position)) return;
      _restoring = false;
      restored = true;
      _consumeRestoreNavigation();
      setState(() => seeking = false);
      _anchorFloor = target.id;
      _capturePosition(intentional: true);
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        _recordReaderTiming(ReaderTimingEvent.restoreEnd);
      }
      return;
    }
    final anchored =
        savedBodyAnchor != null &&
        await _restoreBodyAnchor(savedBodyAnchor, generation, position);
    if (!_currentRestore(generation, position)) return;
    if (_waitingForMediaFloor != null) {
      // Unknown media inside the saved floor makes its temporary pixels an
      // invalid restoration source. Keep the complete original DTO/local pair
      // until geometry resolves or genuine input takes ownership. The normal
      // body stays interactive; this branch never presents a seeking overlay.
      return;
    }
    if (anchored) {
      if (!_currentRestore(generation, position)) return;
      // Capture the floor that actually restored, rather than replacing it
      // with an earlier body exposed by this width's different wrapping.
      _anchorFloor = savedBodyAnchor.floor;
    } else {
      if (!_currentRestore(generation, position)) return;
      scroll.jumpTo(savedOffset.clamp(0, scroll.position.maxScrollExtent));
    }
    // Commit pixels and body anchor together after the final layout. Publishing
    // only pixels here would erase the known anchor until the next frame.
    _restoring = false;
    restored = true;
    _consumeRestoreNavigation();
    if (seeking) setState(() => seeking = false);
    _capturePositionAfterLayout();
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.restoreEnd);
    }
  }

  Future<bool> _restoreBodyAnchor(
    ReaderBodyAnchor anchor,
    int generation,
    ScrollPosition position,
  ) async {
    final floors = [if (thread.root != null) thread.root!, ...thread.replies];
    final matches = floors.where((floor) => floor.id == anchor.floor);
    if (matches.isEmpty ||
        (_blocked(matches.first) && !revealed.contains(anchor.floor))) {
      return false;
    }
    // Start near the old pixels, then use the stable body rather than treating
    // those pixels as coordinates in an un-enriched version of the document.
    var restarted = false;
    for (var attempt = 0; attempt < 400; attempt++) {
      if (!mounted || !_currentRestore(generation, position)) return false;
      if (_contentLayout.hasUnresolvedGeometry(anchor.floor)) {
        _waitingForMediaFloor = anchor.floor;
        if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
          _recordReaderTiming(ReaderTimingEvent.restoreMediaWait);
        }
        return false;
      }
      final box = _bodyBox(anchor.floor);
      final viewport = context.findRenderObject();
      if (box != null && viewport is RenderBox && viewport.hasSize) {
        final dy =
            box.localToGlobal(Offset.zero).dy -
            viewport.localToGlobal(Offset.zero).dy;
        if (!dy.isFinite) return false;
        final target = (scroll.offset + dy - anchor.dy).clamp(
          scroll.position.minScrollExtent,
          scroll.position.maxScrollExtent,
        );
        if ((target - scroll.offset).abs() < .1) return true;
        scroll.jumpTo(target);
        // Recheck the actual body after layout: a cached author may have
        // completed between the first correction and this frame.
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      if (!restarted) {
        restarted = true;
        scroll.jumpTo(0);
      } else {
        final next = (scroll.offset + scroll.position.viewportDimension * .85)
            .clamp(0, scroll.position.maxScrollExtent);
        if (next == scroll.offset) return false;
        scroll.jumpTo(next.toDouble());
      }
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  void _userScroll() {
    _interactionEpoch++;
    _waitingForMediaFloor = null;
    final hadAnchor =
        _anchorPending || _anchorUnresolved || _anchorFloor != null;
    _cancelReadingAnchor();
    if (!_restoring) {
      if (hadAnchor) _capturePositionAfterLayout();
      return;
    }
    _restoreGeneration++;
    _restoring = false;
    restored = true;
    _consumeRestoreNavigation();
    if (seeking) setState(() => seeking = false);
    _capturePositionAfterLayout();
  }

  void _fontSize(double size) {
    final next = size.clamp(13, 24).toDouble();
    if (next == fontSize) return;
    setState(() => fontSize = next);
    widget.state.act('settings.update', {
      'key': 'workspace.readerTextSize',
      'value': fontSize,
    }, 'settings');
  }

  void _position() {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.position);
    }
    // A local correction is recorded only after its new sliver layout. Any
    // other controller notification owns the position and retires pending
    // compensation; layout's silent correctBy remains free to be reconciled.
    if (_applyingAnchor) return;
    // Cupertino physics may start a boundary spring when a shorter document
    // leaves the old pixels beyond the new extent. That dimension response is
    // part of this reflow, not user input; the bounded correction below owns
    // its final clamp. Real input has already invalidated it in _userScroll.
    if (_anchorPending && scroll.hasClients && scroll.position.outOfRange) {
      return;
    }
    if (_anchorPending || _anchorUnresolved || _anchorFloor != null) {
      _cancelReadingAnchor();
    }
    if (!_ownsPosition ||
        onlyAuthor ||
        _restoring ||
        !restored ||
        thread.root == null && thread.replies.isEmpty ||
        !scroll.hasClients ||
        !scroll.position.hasContentDimensions) {
      return;
    }
    _lastOffset = scroll.offset.clamp(0, 100000000).toDouble();
    _lastBodyAnchor = null;
    if (!widget.state.recordReaderOffset(
      widget.topic.url,
      _lastOffset,
      revision: revision,
      epoch: positionEpoch,
    )) {
      return;
    }
    _positionObserved = true;
    _capturePositionAfterLayout();
    persist?.cancel();
    persist = Timer(const Duration(milliseconds: 600), _savePosition);
  }

  // Diagnostic observations never drive scrolling, anchoring or persistence.
  // Missing dimensions remain absent instead of inventing usable extents.
  void _recordReaderTiming(ReaderTimingEvent kind) {
    final position = scroll.hasClients ? scroll.position : null;
    final hasPixels = position?.hasPixels == true;
    final hasExtents = position?.hasContentDimensions == true;
    FrameDiagnostics.recordReaderEvent(
      kind,
      pixels: hasPixels ? position!.pixels : null,
      minExtent: hasExtents ? position!.minScrollExtent : null,
      maxExtent: hasExtents ? position!.maxScrollExtent : null,
      viewportDimension: position?.hasViewportDimension == true
          ? position!.viewportDimension
          : null,
      interaction: _interactionEpoch,
      correcting: _applyingAnchor,
      restoring: _restoring,
      pending: _anchorPending,
      outOfRange: hasPixels && hasExtents ? position!.outOfRange : null,
      readerInstance: _diagnosticInstance,
      accessRevision: revision,
      positionEpoch: positionEpoch,
      restoreGeneration: _restoreGeneration,
      savedPixels: _snapshot['scrollOffset'] is num
          ? numberValue(_snapshot['scrollOffset'])
          : null,
      observedPixels: _lastOffset,
      bodyAnchorDy: _lastBodyAnchor?.dy,
      hasBodyAnchor: _lastBodyAnchor != null,
      hasThread: thread.root != null || thread.replies.isNotEmpty,
      hasOwner: intValue(widget.state.domain('session')['owner']) > 0,
      restored: restored,
    );
  }

  void _savePosition() {
    if (_positionObserved &&
        _ownsPosition &&
        !_anchorPending &&
        !_anchorUnresolved) {
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        _recordReaderTiming(ReaderTimingEvent.positionSave);
      }
      widget.state.client
          .call('reader.rememberPosition', {
            'url': widget.topic.url,
            'topicID': widget.topic.id,
            'offset': _lastOffset,
            if (_lastBodyAnchor != null)
              'bodyAnchor': _lastBodyAnchor!.toJson(),
          })
          .catchError((Object error) => <String, dynamic>{});
    }
  }

  RenderBox? _bodyBox(String floor) {
    final box = _bodyKeys[floor]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    RenderObject child = box;
    for (var parent = child.parent; parent != null; parent = child.parent) {
      if (!parent.paintsChild(child)) return null;
      child = parent;
    }
    return box;
  }

  Iterable<String> _laidOutFloors() sync* {
    final root = _displayRoot;
    if (root != null) yield root.id;
    final replies = _laidOutReplies;
    final sliver = _replyReflowKey.currentContext?.findRenderObject();
    if (sliver is! _RenderReaderReflowList || !sliver.attached) return;
    for (
      var child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)
    ) {
      final index = sliver.indexOf(child);
      if (index >= 0 && index < replies.length) {
        yield replies[index].id;
      }
    }
  }

  ({String floor, RenderBox box, double dy})? _visibleBody({
    String? preferredFloor,
  }) {
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return null;
    }
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom =
        top +
        (scroll.hasClients
            ? scroll.position.viewportDimension
            : viewport.size.height);
    if (!top.isFinite || !bottom.isFinite || bottom <= top) return null;
    ({String floor, RenderBox box, double dy})? result;
    for (final floor in _laidOutFloors()) {
      final box = _bodyBox(floor);
      if (box == null || !box.size.height.isFinite || box.size.isEmpty) {
        continue;
      }
      final y = box.localToGlobal(Offset.zero).dy;
      if (!y.isFinite || y + box.size.height <= top || y >= bottom) continue;
      if (floor == preferredFloor) {
        return (floor: floor, box: box, dy: y - top);
      }
      if (result == null || y - top < result.dy) {
        result = (floor: floor, box: box, dy: y - top);
      }
    }
    return result;
  }

  void _capturePositionAfterLayout() {
    if (_captureScheduled || !scroll.hasClients) return;
    _captureScheduled = true;
    final generation = ++_captureGeneration;
    final position = scroll.position;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _captureGeneration) return;
      _captureScheduled = false;
      if (scroll.hasClients && identical(position, scroll.position)) {
        _capturePosition();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  // Call only after layout. In particular, a correction's jumpTo changes
  // pixels immediately while its RenderBox positions still describe the old
  // frame. The owning anchor transaction captures after that layout finishes.
  void _capturePosition({bool intentional = false}) {
    if (!mounted ||
        !_ownsPosition ||
        onlyAuthor && !intentional ||
        _restoring ||
        !restored ||
        !_hasBody ||
        _anchorPending ||
        _anchorUnresolved ||
        !scroll.hasClients ||
        !scroll.position.hasContentDimensions) {
      return;
    }
    final body = _visibleBody(preferredFloor: _anchorFloor);
    _lastOffset = scroll.offset.clamp(0, 100000000).toDouble();
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.capture);
    }
    // Keep the known floor, but always sample its actual new dy. If clamping
    // removed it from view, the real visible body becomes the next preference.
    // Without a geometry transaction, ordinary scroll capture is unchanged.
    if (_anchorFloor != null) {
      _anchorFloor = _lastOffset < 1 ? null : body?.floor;
      _anchorDy = _anchorFloor == null ? null : body?.dy;
    }
    _lastBodyAnchor = body == null || _lastOffset < 1
        ? null
        : ReaderBodyAnchor.parse({'floor': body.floor, 'dy': body.dy});
    widget.state.recordReaderOffset(
      widget.topic.url,
      _lastOffset,
      revision: revision,
      epoch: positionEpoch,
      bodyAnchor: _lastBodyAnchor,
    );
    if (intentional ||
        _positionObserved ||
        _lastOffset > 0 && _lastBodyAnchor != null) {
      _positionObserved = true;
      persist?.cancel();
      persist = Timer(const Duration(milliseconds: 600), _savePosition);
    }
  }

  @override
  void dispose() {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _recordReaderTiming(ReaderTimingEvent.readerDispose);
    }
    _toolPanel.dispose();
    _cancelReadingAnchor();
    _contentLayout.dispose();
    _copyTimer?.cancel();
    persist?.cancel();
    _restoreGeneration++;
    _savePosition();
    widget.state.removeListener(_changed);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DeskColors(context), snapshot = _snapshot;
    final loading = snapshot['loading'] == true,
        error = stringValue(snapshot['error']);
    return _ReaderWheelMotionGate(
      controller: scroll,
      child: Listener(
        onPointerDown: (_) => scroll.cancelWheel(),
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final position = scroll.hasClients ? scroll.position : null;
            final outwardAtBoundary =
                position != null &&
                position.hasPixels &&
                position.hasContentDimensions &&
                position.axisDirection == AxisDirection.down &&
                (event.scrollDelta.dy < 0 &&
                        position.pixels <= position.minScrollExtent ||
                    event.scrollDelta.dy > 0 &&
                        position.pixels >= position.maxScrollExtent);
            // The resolver does not claim an outward input at an edge. It
            // must still retire an older tail before its first smooth pixel.
            if (scroll.input.current?.eligible != true || outwardAtBoundary) {
              scroll.cancelWheel();
            }
            if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
              FrameDiagnostics.recordReaderEvent(
                ReaderTimingEvent.wheel,
                sourceTime: event.timeStamp,
                dx: event.scrollDelta.dx,
                dy: event.scrollDelta.dy,
                interaction: _interactionEpoch,
              );
            }
          }
        },
        onPointerPanZoomStart: (event) {
          scroll.cancelWheel();
          if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
            FrameDiagnostics.recordReaderEvent(
              ReaderTimingEvent.panStart,
              sourceTime: event.timeStamp,
              interaction: _interactionEpoch,
            );
          }
        },
        onPointerPanZoomUpdate:
            FrameDiagnostics.enabled && FrameDiagnostics.rawFrames
            ? (event) {
                if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
                  FrameDiagnostics.recordReaderEvent(
                    ReaderTimingEvent.panUpdate,
                    sourceTime: event.timeStamp,
                    dx: event.panDelta.dx,
                    dy: event.panDelta.dy,
                    interaction: _interactionEpoch,
                  );
                }
              }
            : null,
        onPointerPanZoomEnd:
            FrameDiagnostics.enabled && FrameDiagnostics.rawFrames
            ? (event) {
                if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
                  FrameDiagnostics.recordReaderEvent(
                    ReaderTimingEvent.panEnd,
                    sourceTime: event.timeStamp,
                    interaction: _interactionEpoch,
                  );
                }
              }
            : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final userDirection =
                notification is UserScrollNotification &&
                notification.direction != ScrollDirection.idle;
            final dragStart =
                notification is ScrollStartNotification &&
                notification.dragDetails != null;
            final continuedDrag =
                _restoring &&
                notification is ScrollUpdateNotification &&
                notification.dragDetails != null &&
                (notification.scrollDelta ?? 0) != 0;
            final source = notification.context;
            if ((!userDirection && !dragStart && !continuedDrag) ||
                notification.depth != 0 ||
                notification.metrics.axis != Axis.vertical ||
                source == null ||
                !scroll.hasClients ||
                !identical(
                  Scrollable.maybeOf(source)?.position,
                  scroll.position,
                )) {
              return false;
            }
            if (scroll.dispatchingWheel) return false;
            if (userDirection || continuedDrag) {
              _userScroll();
            } else if (notification is ScrollStartNotification) {
              if (notification.dragDetails!.kind !=
                  PointerDeviceKind.trackpad) {
                _userScroll();
              }
              if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
                FrameDiagnostics.recordReaderEvent(
                  ReaderTimingEvent.dragStart,
                  sourceTime: notification.dragDetails!.sourceTimeStamp,
                  interaction: _interactionEpoch,
                );
              }
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (context, bounds) =>
                _body(context, colors, snapshot, loading, error, bounds),
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    DeskColors colors,
    JsonMap snapshot,
    bool loading,
    String error,
    BoxConstraints bounds,
  ) {
    // The full reader pane keeps its width when an editor opens below it.
    // Observe reading geometry here, before laying out the stable scroll body,
    // rather than rebuilding every floor when only viewport height changes.
    final minimumInset = bounds.maxWidth < 520 ? 22.0 : 32.0;
    final readingWidth =
        widget.state.domain('settings')['workspace.readingDensity'] == 'compact'
        ? 960.0
        : 860.0;
    final horizontalInset = bounds.maxWidth > readingWidth + minimumInset * 2
        ? (bounds.maxWidth - readingWidth) / 2
        : minimumInset;
    if (thread.root != null || thread.replies.isNotEmpty) {
      _preserveReadingLayout(
        width: bounds.maxWidth - horizontalInset * 2,
        textScaler: MediaQuery.textScalerOf(context),
      );
    }
    final reader = thread.root == null && thread.replies.isEmpty
        ? loading || snapshot.isEmpty
              ? const Center(child: CupertinoActivityIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(colors, loading),
                      const SizedBox(height: 20),
                      _failure(colors, error, summary: true),
                    ],
                  ),
                )
        : _readerContent(context, colors, loading, error, horizontalInset);
    final editors = widget.editors;
    if (editors == null) {
      return _readerLayout(colors, bounds.maxHeight, reader);
    }
    return ListenableBuilder(
      listenable: editors,
      child: reader,
      builder: (context, child) =>
          _readerLayout(colors, bounds.maxHeight, child!),
    );
  }

  Widget _readerContent(
    BuildContext context,
    DeskColors colors,
    bool loading,
    String error,
    double horizontalInset,
  ) {
    final root = _displayRoot;
    final replies = _displayReplies;
    _laidOutReplies = replies;
    return Actions(
      actions: <Type, Action<Intent>>{
        ScrollIntent: _ReaderScrollAction(scroll, () {
          scroll.cancelWheel();
          _userScroll();
        }),
      },
      child: Stack(
        children: [
          CustomScrollView(
            key: PageStorageKey('reader:${widget.topic.url}'),
            controller: scroll,
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalInset,
                  25,
                  horizontalInset,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(colors, loading),
                      const SizedBox(height: 20),
                      if (root != null)
                        RepaintBoundary(
                          key: floorKeys.putIfAbsent(root.id, GlobalKey.new),
                          child: sampleEditorHeader(
                            layoutKind: UiWorkKind.readerRootLayout,
                            paintKind: UiWorkKind.readerRootPaint,
                            child: _floor(
                              context,
                              root,
                              root: true,
                              sourceURL: thread.root == null
                                  ? _pageURL(1, root)
                                  : null,
                            ),
                          ),
                        ),
                      if (error.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: _failure(colors, error),
                        ),
                      Container(height: 1, color: colors.line),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Text(
                            onlyAuthor ? '楼主回复' : '回复',
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${replies.length}',
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      if (!onlyAuthor)
                        ReaderPagination(
                          state: widget.state,
                          topic: widget.topic,
                          thread: thread,
                          position: 'top',
                        )
                      else if (replies.isEmpty && _authorStatus == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            '这篇帖子还没有楼主回复。',
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                sliver: _ReaderReflowList(
                  key: _replyReflowKey,
                  itemCount: replies.length,
                  itemBuilder: (context, index) {
                    final floor = replies[index];
                    return RepaintBoundary(
                      key: floorKeys.putIfAbsent(floor.id, GlobalKey.new),
                      child: _floor(
                        context,
                        floor,
                        sourceURL: onlyAuthor ? _authorSources[floor.id] : null,
                      ),
                    );
                  },
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalInset,
                  16,
                  horizontalInset,
                  28,
                ),
                sliver: SliverToBoxAdapter(
                  child: onlyAuthor
                      ? const SizedBox.shrink()
                      : ReaderPagination(
                          state: widget.state,
                          topic: widget.topic,
                          thread: thread,
                          position: 'bottom',
                        ),
                ),
              ),
            ],
          ),
          if (seeking)
            Positioned.fill(
              child: ColoredBox(
                color: colors.paper,
                child: const Center(child: CupertinoActivityIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _readerLayout(
    DeskColors colors,
    double availableHeight,
    Widget reader,
  ) {
    final editor = widget.editors?.forTopic(widget.topic.id);
    // Read permissions at each editor notification, including those that leave
    // the document itself unchanged. Session changes also rebuild floor actions.
    final signedOut = widget.state.domain('session')['account'] == 'signedOut';
    final confirmed =
        widget.state.signedIn &&
        widget.state.domain('session')['canCompose'] != false;
    final replyAllowed = thread.replyRestriction.isEmpty && confirmed;
    return sampleEditorHeader(
      layoutKind: UiWorkKind.readerWorkspaceLayout,
      paintKind: UiWorkKind.readerWorkspacePaint,
      child: Column(
        children: [
          Expanded(
            child: sampleEditorHeader(
              layoutKind: UiWorkKind.readerViewportLayout,
              paintKind: UiWorkKind.readerViewportPaint,
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final previousHeight = _readerViewportHeight;
                  _readerViewportHeight = bounds.maxHeight;
                  if (previousHeight != null &&
                      previousHeight != bounds.maxHeight) {
                    final restore = _preserveReadingAnchor(content: true);
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => restore(),
                    );
                  }
                  return ReaderContentLayoutScope(
                    controller: _contentLayout,
                    viewportHeight: bounds.maxHeight,
                    child: reader,
                  );
                },
              ),
            ),
          ),
          if (editor != null)
            ReaderEditorAnchor(
              editors: widget.editors!,
              session: editor,
              height: (availableHeight * .46)
                  .clamp(160.0, 380.0)
                  .clamp(0.0, (availableHeight - 185).clamp(0.0, 380.0)),
            )
          else if (thread.root != null || thread.replies.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      thread.replyRestriction.isNotEmpty
                          ? thread.replyRestriction
                          : signedOut
                          ? '登录后参与讨论'
                          : !confirmed
                          ? '正在确认账号…'
                          : '参与这场讨论',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.secondary, fontSize: 12),
                    ),
                  ),
                  if (thread.replyRestriction.isEmpty)
                    DeskButton(
                      signedOut ? '登录 NodeSeek' : '写回复',
                      icon: CupertinoIcons.square_pencil,
                      width: 108,
                      onTap: replyAllowed
                          ? widget.editors == null
                                ? () => Navigator.push(
                                    context,
                                    CupertinoPageRoute<void>(
                                      builder: (context) => ComposerScreen(
                                        state: widget.state,
                                        topicID: widget.topic.id,
                                        url: widget.topic.url,
                                      ),
                                    ),
                                  )
                                : () => widget.editors!.open(widget.topic)
                          : signedOut
                          ? () => widget.state.act('session.signIn')
                          : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(DeskColors colors, bool loading) {
    var category = widget.topic.categoryLabel.isNotEmpty
        ? widget.topic.categoryLabel
        : thread.category.isNotEmpty
        ? thread.category
        : '阅读';
    for (final board in widget.state.workspace.boards) {
      if (stringValue(board['id']) == category) {
        category = stringValue(board['title'], category);
        break;
      }
    }
    final metadata = Wrap(
      spacing: 9,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          category,
          style: DeskTypography.control.copyWith(color: colors.secondary),
        ),
        if (widget.topic.featured)
          Text('精品', style: TextStyle(fontSize: 11, color: colors.accent)),
        if (widget.topic.readingRank != null)
          Text(
            'Lv.${widget.topic.readingRank} 可读',
            style: TextStyle(fontSize: 11, color: colors.secondary),
          ),
        if (thread.replyRestriction.isNotEmpty)
          Text(
            thread.replyRestriction,
            style: TextStyle(fontSize: 11, color: colors.secondary),
          ),
      ],
    );
    final actions = Wrap(
      spacing: 5,
      runSpacing: 7,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DeskIcon(
          '缩小文字',
          CupertinoIcons.textformat_size,
          fontSize <= 13 ? null : () => _fontSize(fontSize - 1),
          quiet: true,
        ),
        DeskIcon(
          '放大文字',
          CupertinoIcons.plus,
          fontSize >= 24 ? null : () => _fontSize(fontSize + 1),
          quiet: true,
        ),
        DeskButton(
          _copied ? '已复制' : '复制链接',
          width: 94,
          height: 32,
          quiet: true,
          icon: _copied ? CupertinoIcons.check_mark : CupertinoIcons.link,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: widget.topic.url));
            if (!mounted) return;
            _copyTimer?.cancel();
            setState(() => _copied = true);
            _copyTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _copied = false);
            });
          },
        ),
        DeskButton(
          '刷新帖子',
          width: 94,
          height: 32,
          quiet: true,
          icon: CupertinoIcons.arrow_clockwise,
          busy: loading,
          onTap: () async {
            await widget.state.loadReader(widget.topic.url, force: true);
            if (mounted && onlyAuthor && _ownsPosition) {
              await _scanAuthorPages();
            }
          },
        ),
        if (_hasBody)
          DeskButton(
            onlyAuthor ? '查看全部' : '只看楼主',
            width: 94,
            height: 32,
            icon: onlyAuthor
                ? CupertinoIcons.text_alignleft
                : CupertinoIcons.person,
            quiet: !onlyAuthor,
            selected: onlyAuthor,
            onTap: _toggleAuthorView,
          ),
        if (_active('value'))
          Builder(
            builder: (sourceContext) => DeskButton(
              '估价',
              width: 70,
              height: 32,
              icon: CupertinoIcons.money_dollar_circle,
              onTap: () => _showValue(sourceContext),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassBackdropGroup(
          enabled: const bool.fromEnvironment(
            'SEEKDESK_SHARED_BACKDROP',
            defaultValue: true,
          ),
          child: LayoutBuilder(
            builder: (context, bounds) => bounds.maxWidth < 660
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [metadata, const SizedBox(height: 10), actions],
                  )
                : Row(
                    children: [
                      Expanded(child: metadata),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  ),
          ),
        ),
        if (_authorStatus case final status?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    status,
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                ),
                if (_authorFailed)
                  DeskButton(
                    '重试',
                    width: 66,
                    height: 29,
                    onTap: _scanAuthorPages,
                  ),
              ],
            ),
          ),
        const SizedBox(height: 17),
        ForumTextSelection(
          child: Text(
            thread.title.isNotEmpty ? thread.title : widget.topic.title,
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w600,
              color: colors.ink,
              height: 1.3,
              letterSpacing: -.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _failure(DeskColors colors, String error, {bool summary = false}) {
    final code = stringValue(_snapshot['errorCode']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          summary ? '暂时无法打开原帖' : '刷新暂未完成，已保留当前内容',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          error.isEmpty ? '暂时无法加载，请稍后重试。' : error,
          style: TextStyle(fontSize: 12, color: colors.secondary, height: 1.5),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (code == 'verification_required')
              DeskButton(
                '打开验证窗口',
                width: 120,
                onTap: () => widget.state.act('session.verify', {
                  'url': widget.topic.url,
                }),
              ),
            if (code == 'sign_in_required')
              DeskButton(
                '登录 NodeSeek',
                width: 120,
                onTap: () => widget.state.act('session.signIn'),
              ),
            DeskButton(
              '重试',
              width: 64,
              onTap: () =>
                  widget.state.loadReader(widget.topic.url, force: true),
            ),
            DeskButton(
              '在浏览器查看原帖',
              width: 154,
              icon: CupertinoIcons.arrow_up_right_square,
              onTap: () =>
                  widget.state.act('external.open', {'url': widget.topic.url}),
            ),
          ],
        ),
        if (summary && widget.topic.summary.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            'RSS 摘要',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ForumTextSelection(
            child: Text(
              widget.topic.summary,
              style: TextStyle(color: colors.ink, fontSize: 14, height: 1.6),
            ),
          ),
        ],
      ],
    );
  }

  bool _active(String id) =>
      jsonItems(widget.state.domain('extensions')['items'])
          .any((item) => item['id'] == id && item['active'] == true);

  void _showValue(BuildContext sourceContext) {
    final state = widget.state, topic = widget.topic;
    final title = thread.title.isNotEmpty ? thread.title : topic.title;
    unawaited(
      _toolPanel.show(
        sourceContext,
        state: state,
        extensionID: 'value',
        title: '剩余价值计算器',
        canReturnToSource: () =>
            mounted &&
            identical(widget.state, state) &&
            widget.topic.url == topic.url &&
            _ownsPosition,
        builder: (_) => ValueScreen(
          state: state,
          topicKey: topic.id.isNotEmpty ? topic.id : topic.url,
          topicTitle: title,
          embedded: true,
        ),
      ),
    );
  }

  void _showRulings(BuildContext sourceContext, String name) {
    final state = widget.state, topic = widget.topic;
    unawaited(
      _toolPanel.show(
        sourceContext,
        state: state,
        extensionID: 'rulings',
        title: '管理记录',
        canReturnToSource: () =>
            mounted &&
            identical(widget.state, state) &&
            widget.topic.url == topic.url &&
            _ownsPosition,
        builder: (_) => RulingsScreen(state: state, name: name, embedded: true),
      ),
    );
  }

  bool _blocked(FloorData floor) =>
      _active('block') &&
      jsonItems(widget.state.domain('extensions')['blocked']).any(
        (user) =>
            user['memberId'] != null && user['memberId'] == floor.authorID ||
            user['name'] == floor.author,
      );

  void _cancelReadingAnchor() {
    _anchorGeneration++;
    _anchorPending = false;
    _anchorUnresolved = false;
    _anchorFloor = null;
    _anchorDy = null;
    _contentPoint = null;
    _contentPointDy = null;
  }

  void _preserveReplySliver() {
    final floor = _anchorFloor, dy = _anchorDy;
    if (floor == null || dy == null || floor == thread.root?.id) return;
    final sliver = _replyReflowKey.currentContext?.findRenderObject();
    if (sliver is! _RenderReaderReflowList) return;
    final generation = _anchorGeneration;
    final point = _contentPoint;
    final hasPoint = point?.resolve() != null;
    sliver.preserveBody(
      position: scroll.position,
      viewportDy: hasPoint ? _contentPointDy! : dy,
      body: () {
        if (hasPoint) return point?.resolve()?.box;
        return _bodyBox(floor);
      },
      localDy: () => hasPoint ? point?.resolve()?.localDy ?? 0 : 0,
      isCurrent: () =>
          mounted &&
          _ownsPosition &&
          _anchorPending &&
          generation == _anchorGeneration &&
          !_restoring &&
          !seeking,
    );
  }

  void _preserveReadingLayout({
    required double width,
    required TextScaler textScaler,
  }) {
    final geometry = (
      width: width,
      fontSize: fontSize,
      authorScale:
          (numberValue(
                    widget.state.domain(
                      'settings',
                    )['workspace.floorAuthorScale'],
                    100,
                  ) /
                  100)
              .clamp(.75, 1.6),
      textScaler: textScaler,
      compact:
          widget.state.domain('settings')['workspace.readingDensity'] ==
          'compact',
    );
    final previous = _readingGeometry;
    _readingGeometry = geometry;
    if (previous == null || previous == geometry) return;

    // LayoutBuilder invokes this before laying out the new document width.
    // Its layout callback permits reading the old boxes, including dirty
    // descendants; reading them after layout would capture the displacement
    // instead of the user's prior reading position. Only geometry changes
    // schedule a callback, so ordinary rebuilds never create a frame loop.
    final restore = _preserveReadingAnchor();
    WidgetsBinding.instance.addPostFrameCallback((_) => restore());
  }

  VoidCallback _preserveReadingAnchor({bool content = false}) {
    void unchanged() {}
    if (!_ownsPosition ||
        _anchorUnresolved ||
        !scroll.hasClients ||
        _restoring ||
        seeking ||
        scroll.offset < 1 ||
        scroll.position.isScrollingNotifier.value) {
      return unchanged;
    }
    // Both callers represent a known layout change: either the actual
    // reading geometry changed, or new author metadata is about to apply.
    // A second change joins the pending transaction instead of capturing a
    // partly corrected position or applying the same delta twice.
    _anchorLayoutGeneration++;
    if (_anchorPending) {
      _preserveReplySliver();
      return unchanged;
    }
    final body = _visibleBody(preferredFloor: _anchorFloor);
    if (body == null) return unchanged;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return unchanged;
    }
    final dy = body.dy;
    _anchorPending = true;
    _anchorFloor = body.floor;
    _anchorDy = dy;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    _contentPoint = content || _contentLayout.hasVariableMedia(body.floor)
        ? _contentLayout.capture(
            floorID: body.floor,
            top: viewportTop,
            bottom: viewportTop + scroll.position.viewportDimension,
          )
        : null;
    final initialPoint = _contentPoint?.resolve();
    _contentPointDy = initialPoint == null
        ? null
        : initialPoint.box.localToGlobal(Offset(0, initialPoint.localDy)).dy -
              viewportTop;
    if (initialPoint == null) _contentPoint = null;
    final anchorGeneration = ++_anchorGeneration;
    _preserveReplySliver();
    final state = widget.state, url = widget.topic.url;
    final position = scroll.position;
    final generation = _restoreGeneration, navigation = _navigationSequence;
    final interaction = _interactionEpoch;
    var layoutGeneration = _anchorLayoutGeneration;
    var corrections = 0;
    var waitedForBody = false;

    void complete() {
      _anchorPending = false;
      _contentPoint = null;
      _contentPointDy = null;
      _capturePosition();
    }

    late VoidCallback restore;
    void nextLayout() {
      WidgetsBinding.instance.addPostFrameCallback((_) => restore());
      WidgetsBinding.instance.scheduleFrame();
    }

    restore = () {
      // Late author metadata and responsive reflow share this transaction.
      // The first capture owns their combined layout delta. A cancelled
      // callback cannot clear or apply a newer transaction's pending work.
      if (anchorGeneration != _anchorGeneration) return;
      if (!mounted ||
          !_ownsPosition ||
          !identical(state, widget.state) ||
          url != widget.topic.url ||
          !scroll.hasClients ||
          !identical(position, scroll.position) ||
          generation != _restoreGeneration ||
          navigation != _navigationSequence ||
          interaction != _interactionEpoch ||
          _restoring ||
          seeking ||
          !viewport.attached) {
        _anchorPending = false;
        return;
      }
      if (layoutGeneration != _anchorLayoutGeneration) {
        // A continuing resize shares the earliest still-valid anchor, but
        // gives its newly changed layout its own finite correction budget.
        layoutGeneration = _anchorLayoutGeneration;
        corrections = 0;
        waitedForBody = false;
      }
      final anchor = _bodyBox(body.floor);
      if (anchor == null) {
        // A lazy sliver can recycle a box during reflow. Resolve by floor ID
        // on the next layout once; never seek/scan the whole thread here.
        if (!waitedForBody) {
          waitedForBody = true;
          nextLayout();
        } else {
          // Do not silently replace the intended progress with whichever
          // other floor became visible after a failed local recovery. A real
          // user scroll/navigation can establish a new position afterwards.
          _anchorPending = false;
          _anchorUnresolved = true;
          persist?.cancel();
        }
        return;
      }
      final point = _contentPoint?.resolve();
      final delta =
          (point == null
                  ? anchor.localToGlobal(Offset.zero)
                  : point.box.localToGlobal(Offset(0, point.localDy)))
              .dy -
          viewport.localToGlobal(Offset.zero).dy -
          (point == null ? dy : _contentPointDy!);
      if (!delta.isFinite) {
        _anchorPending = false;
        _anchorUnresolved = true;
        persist?.cancel();
        return;
      }
      final current = scroll.offset;
      final target = (current + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      // A body can keep the same dy while its document shrinks below the
      // current pixels. Only the clamped target can establish convergence.
      if (!position.outOfRange && (target - current).abs() < .5) {
        complete();
        return;
      }
      if (corrections >= 2) {
        if (position.outOfRange) {
          // End the finite transaction without persisting illegal pixels.
          _anchorPending = false;
          _anchorUnresolved = true;
          persist?.cancel();
        } else {
          complete();
        }
        return;
      }
      corrections++;
      _applyingAnchor = true;
      try {
        scroll.jumpTo(target);
      } finally {
        _applyingAnchor = false;
      }
      nextLayout();
    };
    return restore;
  }

  String? _pageURL(int number, FloorData floor) {
    final source = Uri.tryParse(widget.topic.url);
    final route = RegExp(r'^/post-([1-9][0-9]*)-[1-9][0-9]*/?$')
        .firstMatch(source?.path ?? '');
    if (source == null || route == null) return null;
    return source
        .replace(
          path: '/post-${route[1]}-$number',
          query: '',
          fragment: 'comment-${floor.id}',
        )
        .toString();
  }

  Widget _floor(
    BuildContext context,
    FloorData floor, {
    bool root = false,
    String? sourceURL,
  }) {
    final colors = DeskColors(context);
    if (_blocked(floor) && !revealed.contains(floor.id)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已折叠屏蔽用户的内容 · ${floor.author}',
                style: TextStyle(color: colors.secondary, fontSize: 12),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(5),
              onPressed: () => setState(() => revealed.add(floor.id)),
              child: const Text('展开', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }
    final authorScale =
        numberValue(
          widget.state.domain('settings')['workspace.floorAuthorScale'],
          100,
        ) /
        100;
    return Padding(
      padding: EdgeInsets.only(
        top: root ? 0 : 14,
        bottom:
            widget.state.domain('settings')['workspace.readingDensity'] ==
                'compact'
            ? 14
            : 27,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReaderFloorContext(
            state: widget.state,
            topic: widget.topic,
            floor: floor,
            root: root,
            authorScale: authorScale,
            preserveAnchor: _preserveReadingAnchor,
            profilesSupported:
                sourceURL == null &&
                _snapshot['authorProfilesSupported'] == true &&
                _snapshot['loading'] != true,
            actions: [
              if (jsonItems(widget.state.domain('extensions')['items']).any(
                (item) => item['id'] == 'rulings' && item['active'] == true,
              ))
                Builder(
                  builder: (sourceContext) => DeskIcon(
                    '管理记录',
                    CupertinoIcons.shield,
                    () => _showRulings(sourceContext, floor.author),
                    quiet: true,
                  ),
                ),
              if (_active('block') &&
                  floor.authorID !=
                      intValue(widget.state.domain('session')['owner'], -1))
                DeskIcon(
                  '屏蔽作者',
                  CupertinoIcons.person_crop_circle_badge_xmark,
                  () async {
                    if (await confirmAction(
                      context,
                      title: '屏蔽作者',
                      message: '将折叠 ${floor.author} 的帖子正文和回复。',
                      accept: '屏蔽',
                    )) {
                      widget.state.act('extensions.block', {
                        'name': floor.author,
                        'memberId': floor.authorID,
                      }, 'extensions');
                    }
                  },
                  quiet: true,
                ),
              if (sourceURL == null &&
                  floor.authorID != null &&
                  floor.authorID ==
                      intValue(widget.state.domain('session')['owner'], -1))
                DeskIcon(
                  '编辑楼层',
                  CupertinoIcons.pencil,
                  widget.editors == null
                      ? () => Navigator.push(
                          context,
                          CupertinoPageRoute<void>(
                            builder: (context) => InlineEditScreen(
                              state: widget.state,
                              url: widget.topic.url,
                              topicID: widget.topic.id,
                              floor: int.tryParse(floor.id) ?? 0,
                            ),
                          ),
                        )
                      : () => widget.editors!.open(
                          widget.topic,
                          floor: int.tryParse(floor.id) ?? 0,
                        ),
                  quiet: true,
                ),
            ],
            body: KeyedSubtree(
              key: _bodyKeys.putIfAbsent(floor.id, GlobalKey.new),
              child: floor.blocks.isEmpty
                  ? Text(
                      '原站未显示这层的正文。',
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: fontSize,
                      ),
                    )
                  : ReaderContentFloor(
                      floorID: floor.id,
                      child: ForumBlocks(
                        state: widget.state,
                        blocks: floor.blocks,
                        fontSize: fontSize,
                      ),
                    ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 5,
            children: [
              if (sourceURL != null)
                DeskButton(
                  '查看原楼层',
                  width: 106,
                  height: 27,
                  icon: CupertinoIcons.arrow_turn_down_right,
                  quiet: true,
                  onTap: () => widget.state.openLink(sourceURL),
                )
              else ...[
                _reaction(
                  '赞同',
                  CupertinoIcons.hand_thumbsup,
                  floor.likes,
                  floor.upvoted,
                  floor,
                  'upvote',
                ),
                _reaction(
                  '鸡腿',
                  CupertinoIcons.gift,
                  floor.chicken,
                  floor.gaveChicken,
                  floor,
                  'like',
                ),
                _reaction(
                  '反对',
                  CupertinoIcons.hand_thumbsdown,
                  floor.dislikes,
                  floor.downvoted,
                  floor,
                  'dislike',
                ),
                if (widget.editors != null && thread.replyRestriction.isEmpty)
                  for (final quoting in [false, true])
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 5,
                      ),
                      minimumSize: Size.zero,
                      onPressed:
                          widget.state.signedIn &&
                              widget.state.domain('session')['canCompose'] !=
                                  false
                          ? () => widget.editors!.replyTo(
                              widget.topic,
                              floor,
                              quoting: quoting,
                            )
                          : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            quoting
                                ? CupertinoIcons.quote_bubble
                                : CupertinoIcons.reply,
                            size: 13,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            quoting ? '引用' : '回复',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _reaction(
    String label,
    IconData icon,
    int count,
    bool selected,
    FloorData floor,
    String kind,
  ) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
    minimumSize: Size.zero,
    onPressed: widget.state.signedIn ? () => _react(floor, kind) : null,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: selected
              ? DeskColors(context).accent
              : DeskColors(context).secondary,
        ),
        const SizedBox(width: 5),
        Text(
          '$label${count > 0 ? ' · $count' : ''}',
          style: TextStyle(
            fontSize: 11,
            color: selected
                ? DeskColors(context).accent
                : DeskColors(context).secondary,
          ),
        ),
      ],
    ),
  );
  Future<void> _react(FloorData floor, String kind) async {
    final key = '${floor.id}:$kind';
    if (reacting.contains(key)) return;
    reacting.add(key);
    final actionRevision = widget.state.accessRevision;
    try {
      var approval = kind == 'upvote' ? 'direct' : 'quote';
      if (kind == 'dislike') {
        if (!await confirmAction(
              context,
              title: '确认点踩',
              message: '点踩会按 NodeSeek 社区规则扣除鸡腿，确定继续？',
              accept: '确认点踩',
            ) ||
            !mounted ||
            actionRevision != widget.state.accessRevision) {
          return;
        }
        approval = 'paid';
      }
      final args = <String, dynamic>{
        'topicID': widget.topic.id,
        'url': widget.topic.url,
        'floor': int.tryParse(floor.id) ?? 0,
        'kind': kind,
        'approval': approval,
      };
      var result = await widget.state.act('reader.react', args);
      if (result == null ||
          !mounted ||
          actionRevision != widget.state.accessRevision) {
        return;
      }
      if (result['kind'] == 'confirmFree' || result['kind'] == 'confirmPaid') {
        final free = result['kind'] == 'confirmFree';
        if (!await confirmAction(
              context,
              title: '送鸡腿',
              message: free ? '本次使用免费鸡腿额度，确定送出？' : '免费额度已用完，本次会消耗账号鸡腿，确定继续？',
              accept: '送鸡腿',
            ) ||
            !mounted ||
            actionRevision != widget.state.accessRevision) {
          return;
        }
        result = await widget.state.act('reader.react', {
          ...args,
          'approval': free ? 'free' : 'paid',
        });
      }
      if (result == null || actionRevision != widget.state.accessRevision) {
        return;
      }
      if (result['kind'] == 'accepted' || result['kind'] == 'already') {
        widget.state.showMessage(
          result['kind'] == 'already' ? '已经操作过了' : '操作成功',
        );
        await widget.state.loadReader(widget.topic.url, force: true);
      } else {
        widget.state.showMessage(
          stringValue(result['message'], '操作未完成，请刷新确认后再重试。'),
        );
      }
    } finally {
      reacting.remove(key);
    }
  }
}

// Keyboard ScrollActions animate with no dragDetails. Retire pending restores
// before that real input, while leaving programmatic corrections untouched.
// The scope only surrounds the reading body, not the separate editor below it.
class _ReaderScrollAction extends ScrollAction {
  _ReaderScrollAction(this.controller, this.onScroll);

  final ScrollController controller;
  final VoidCallback onScroll;

  @override
  void invoke(ScrollIntent intent, [BuildContext? context]) {
    if (context != null &&
        controller.hasClients &&
        axisDirectionToAxis(intent.direction) == Axis.vertical) {
      final nearest = Scrollable.maybeOf(context);
      final primary = nearest == null
          ? PrimaryScrollController.maybeOf(context)
          : null;
      final target =
          nearest?.position ??
          (primary != null && primary.positions.length == 1
              ? primary.position
              : null);
      if (identical(target, controller.position) &&
          target != null &&
          target.physics.shouldAcceptUserOffset(target)) {
        onScroll();
      }
    }
    super.invoke(intent, context);
  }
}

// Route and motion changes must cancel a wheel tail without rebuilding the
// cached reader subtree. Keep those dependencies on this small wrapper only.
class _ReaderWheelMotionGate extends StatefulWidget {
  const _ReaderWheelMotionGate({required this.controller, required this.child});

  final ReaderWheelScrollController controller;
  final Widget child;

  @override
  State<_ReaderWheelMotionGate> createState() => _ReaderWheelMotionGateState();
}

class _ReaderWheelMotionGateState extends State<_ReaderWheelMotionGate> {
  void _updateMotion() {
    widget.controller.motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        !GlassAccessibilityData.of(context).reduceMotion &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(_ReaderWheelMotionGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.cancelWheel();
      _updateMotion();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// Before the regular lazy-list layout can recycle an anchored short reply,
// lay out only the already-mounted range from firstChild through that reply.
// New preceding sliver extent and new local child geometry enter ONE viewport
// correction. The normal RenderSliverList then owns all layout and recycling.
class _ReaderReflowList extends SliverList {
  _ReaderReflowList({
    required NullableIndexedWidgetBuilder itemBuilder,
    required int itemCount,
    super.key,
  }) : super(
         delegate: SliverChildBuilderDelegate(
           itemBuilder,
           childCount: itemCount,
           // Each visible floor already owns its keyed repaint boundary.
           addRepaintBoundaries: false,
         ),
       );

  @override
  _RenderReaderReflowList createRenderObject(BuildContext context) =>
      _RenderReaderReflowList(
        childManager: context as SliverMultiBoxAdaptorElement,
      );
}

class _RenderReaderReflowList extends RenderSliverList {
  _RenderReaderReflowList({required super.childManager});

  double? _viewportDy;
  ScrollPosition? _position;
  RenderBox? Function()? _body;
  double Function()? _localDy;
  bool Function()? _isCurrent;

  void preserveBody({
    required ScrollPosition position,
    required double viewportDy,
    required RenderBox? Function() body,
    required double Function() localDy,
    required bool Function() isCurrent,
  }) {
    _viewportDy = viewportDy;
    _position = position;
    _body = body;
    _localDy = localDy;
    _isCurrent = isCurrent;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final viewportDy = _viewportDy;
    final position = _position;
    final body = _body;
    final localDy = _localDy;
    final isCurrent = _isCurrent;
    // Consume before emitting a correction: the viewport may restart layout
    // immediately. A retry must use the actual new geometry, not add it twice.
    _viewportDy = null;
    _position = null;
    _body = null;
    _localDy = null;
    _isCurrent = null;
    if (viewportDy != null &&
        position != null &&
        body != null &&
        isCurrent?.call() == true) {
      final anchor = body();
      var targetChild = anchor;
      while (targetChild != null && targetChild.parent != this) {
        final parent = targetChild.parent;
        targetChild = parent is RenderBox ? parent : null;
      }
      var current = firstChild;
      final initialOffset = current == null ? null : childScrollOffset(current);
      if (targetChild != null && initialOffset != null) {
        double offset = initialOffset;
        final targetIndex = indexOf(targetChild);
        final childConstraints = constraints.asBoxConstraints();
        // No creation, keepAlive promotion or search through unmounted
        // indices: this is bounded by the existing cache's linked children.
        while (current != null && indexOf(current) <= targetIndex) {
          current.layout(childConstraints, parentUsesSize: true);
          final parentData =
              current.parentData! as SliverMultiBoxAdaptorParentData;
          parentData.layoutOffset = offset;
          if (identical(current, targetChild)) {
            final laidOutBody = body();
            if (laidOutBody != null) {
              final innerDy = laidOutBody
                  .localToGlobal(
                    Offset(0, localDy?.call() ?? 0),
                    ancestor: current,
                  )
                  .dy;
              final target =
                  (constraints.precedingScrollExtent +
                          offset +
                          innerDy -
                          viewportDy)
                      .clamp(position.minScrollExtent, double.infinity);
              final delta = target - position.pixels;
              if (delta.abs() > .1) {
                geometry = SliverGeometry(scrollOffsetCorrection: delta);
                return;
              }
            }
            break;
          }
          offset = offset + paintExtentOf(current);
          current = childAfter(current);
        }
      }
    }
    super.performLayout();
  }
}
