import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Owns only window chrome. Navigation, account checks, editing and focus stay
/// with the workspace; the native host never executes forum operations itself.
class WindowChromeBridge extends StatefulWidget {
  const WindowChromeBridge({
    required this.snapshot,
    required this.actionContext,
    required this.onAction,
    required this.builder,
    this.avatarKey,
    this.loadAvatar,
    this.channel = const MethodChannel('cc.seekdesk/window-chrome.v1'),
    super.key,
  });

  final Map<String, Object?> snapshot;
  final Object actionContext;
  final bool Function(String action) onAction;
  final Widget Function(BuildContext context, bool installed) builder;
  final Object? avatarKey;
  final Future<Uint8List> Function()? loadAvatar;
  final MethodChannel channel;

  @override
  State<WindowChromeBridge> createState() => _WindowChromeBridgeState();
}

class _WindowChromeBridgeState extends State<WindowChromeBridge> {
  String? _attachment;
  int _generation = 0;
  int _avatarRevision = 0;
  Uint8List? _avatar;
  bool _installed = false;
  bool _failed = false;
  bool _publishing = false;
  bool _publishAgain = false;
  final _deadlines = <Timer, VoidCallback>{};

  Future<T> _withDeadline<T>(Future<T> request) {
    final completion = Completer<T>();
    late final Timer timer;
    void fail(Object error) {
      timer.cancel();
      _deadlines.remove(timer);
      if (!completion.isCompleted) completion.completeError(error);
    }

    timer = Timer(const Duration(seconds: 3), () {
      fail(TimeoutException('Window chrome did not respond.'));
    });
    _deadlines[timer] = () => fail(StateError('Window chrome was retired.'));
    request.then((value) {
      timer.cancel();
      _deadlines.remove(timer);
      if (!completion.isCompleted) completion.complete(value);
    }, onError: (Object error) => fail(error));
    return completion.future;
  }

  void _cancelDeadlines() {
    for (final cancel in _deadlines.values.toList()) {
      cancel();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler(_handle);
    unawaited(_attach());
  }

  Future<void> _attach() async {
    // A timed-out attach may still create a toolbar later. Retire that exact
    // attachment rather than leaving it above the restored Flutter fallback.
    var retired = false;
    try {
      final request = widget.channel.invokeMapMethod<String, Object?>(
        'attach',
        {'protocol': 1},
      );
      unawaited(
        request.then((value) {
          if (retired || !mounted) _detach(value?['attachment']);
        }, onError: (Object _) {}),
      );
      final result = await _withDeadline(request);
      if (!mounted) return;
      final attachment = result?['attachment'];
      if (result?['installed'] != true ||
          attachment is! String ||
          attachment.isEmpty) {
        _detach(attachment);
        _fail();
        return;
      }
      _attachment = attachment;
      _generation++;
      await _publish();
      if (mounted && !_failed) _loadAvatar();
    } on Object {
      retired = true;
      _fail();
    }
  }

  @override
  void didUpdateWidget(WindowChromeBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(oldWidget.channel.name == widget.channel.name);
    final avatarChanged = oldWidget.avatarKey != widget.avatarKey;
    if (avatarChanged) {
      _avatarRevision++;
      _avatar = null;
    }
    if (avatarChanged ||
        oldWidget.actionContext != widget.actionContext ||
        !_sameSnapshot(oldWidget.snapshot, widget.snapshot)) {
      // Immediately invalidate any action already in flight, before publishing
      // the next frame. The workspace also rechecks the live route/account.
      _generation++;
      unawaited(_publish());
    }
    if (avatarChanged && _installed) _loadAvatar();
  }

  static bool _sameSnapshot(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length &&
      a.entries.every((entry) {
        final next = b[entry.key];
        return entry.value is List && next is List
            ? listEquals(entry.value as List, next)
            : entry.value == next;
      });

  void _loadAvatar() {
    final load = widget.loadAvatar;
    if (load == null || widget.avatarKey == null || _failed) return;
    final revision = ++_avatarRevision;
    final key = widget.avatarKey;
    unawaited(() async {
      try {
        final bytes = await load();
        if (!mounted ||
            _failed ||
            revision != _avatarRevision ||
            key != widget.avatarKey) {
          return;
        }
        _avatar = bytes;
        _generation++;
        await _publish();
      } on Object {
        // The native account button keeps a labelled profile icon. Image
        // failures cannot affect login state, navigation, or fallback chrome.
      }
    }());
  }

  Future<void> _publish() async {
    if (!mounted || _failed || _attachment == null) return;
    if (_publishing) {
      _publishAgain = true;
      return;
    }
    _publishing = true;
    try {
      do {
        _publishAgain = false;
        final generation = _generation;
        final accepted = await _withDeadline(
          widget.channel.invokeMethod<bool>('update', {
            'attachment': _attachment,
            'generation': generation,
            'snapshot': {...widget.snapshot, 'avatarBytes': _avatar},
          }),
        );
        if (!mounted || _failed) return;
        if (accepted != true) {
          _fail();
          return;
        }
        if (!_installed) setState(() => _installed = true);
        // An asynchronous update can be superseded while AppKit processes it.
        _publishAgain |= generation != _generation;
      } while (_publishAgain);
    } on Object {
      _fail();
    } finally {
      _publishing = false;
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'detached') {
      if (_attachment != null &&
          args is Map &&
          args['attachment'] == _attachment) {
        _fail();
      }
      return true;
    }
    if (call.method != 'perform') throw MissingPluginException();
    if (!mounted ||
        !_installed ||
        _failed ||
        args is! Map ||
        args['attachment'] != _attachment ||
        args['generation'] is! int ||
        args['generation'] != _generation) {
      return false;
    }
    final action = args['action'];
    final enabled = widget.snapshot['enabledActions'];
    if (action is! String || enabled is! List || !enabled.contains(action)) {
      return false;
    }
    return widget.onAction(action);
  }

  void _fail() {
    _failed = true;
    _cancelDeadlines();
    _generation++;
    _avatarRevision++;
    _avatar = null;
    final attachment = _attachment;
    _attachment = null;
    _detach(attachment);
    if (mounted && _installed) setState(() => _installed = false);
  }

  void _detach(Object? attachment) {
    if (attachment is! String || attachment.isEmpty) return;
    unawaited(
      widget.channel
          .invokeMethod<void>('detach', {'attachment': attachment})
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _cancelDeadlines();
    _generation++;
    _avatarRevision++;
    widget.channel.setMethodCallHandler(null);
    _detach(_attachment);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _installed);
}
