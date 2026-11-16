import 'dart:async';

import 'package:flutter/services.dart';

import 'native_client.dart';

/// Only opaque native drop credentials cross this channel, never file paths.
class ComposerDropEvent {
  const ComposerDropEvent({
    required this.phase,
    required this.position,
    this.dropToken,
  });

  final String phase;
  final Offset position;
  final String? dropToken;
}

/// One native destination per window. Ownership and monotonically increasing
/// revisions make a late layout/dispose message harmless to its replacement.
class NativeComposerDrop {
  NativeComposerDrop({
    this.channel = const MethodChannel('cc.seekdesk/composer.drop.v1'),
  });

  static final instance = NativeComposerDrop();
  static int _nextRevision = 0;
  final MethodChannel channel;
  _DropTarget? _target;
  NativeClient? _cleanupClient;
  bool _listening = false;
  final _retiredTokens = <String>{};

  void updateTarget({
    required Object owner,
    required NativeClient client,
    required String documentID,
    required int accessRevision,
    required Rect bounds,
    required bool Function(ComposerDropEvent) onDrag,
  }) {
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler(_handle);
    }
    _cleanupClient = client;
    final current = _target;
    if (current != null &&
        identical(current.owner, owner) &&
        current.documentID == documentID &&
        current.accessRevision == accessRevision &&
        current.bounds == bounds) {
      return;
    }
    final next = _DropTarget(
      owner: owner,
      documentID: documentID,
      accessRevision: accessRevision,
      bounds: bounds,
      revision: ++_nextRevision,
      onDrag: onDrag,
    );
    _endHover(current);
    _target = next;
    _publish({
      'enabled': true,
      'documentID': documentID,
      'accessRevision': accessRevision,
      'targetRevision': next.revision,
      'left': bounds.left,
      'top': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    });
  }

  void removeTarget(Object owner) {
    if (!identical(_target?.owner, owner)) return;
    _endHover(_target);
    _target = null;
    _publish({'enabled': false, 'targetRevision': ++_nextRevision});
  }

  void _endHover(_DropTarget? target) {
    if (target == null) return;
    try {
      target.onDrag(
        ComposerDropEvent(phase: 'exit', position: target.bounds.center),
      );
    } catch (_) {
      // Replacing a retired widget cannot retain its old hover overlay.
    }
  }

  void _publish(JsonMap arguments) {
    unawaited(() async {
      try {
        await channel.invokeMethod<void>('updateTarget', arguments);
      } catch (_) {
        // Old/native-less hosts keep ordinary editor behavior unchanged.
      }
    }());
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'drag') return false;
    final value = jsonMap(call.arguments);
    final phase = value['phase'];
    final rawToken = value['dropToken'];
    final token =
        rawToken is String && rawToken.isNotEmpty && rawToken.length <= 256
        ? rawToken
        : null;
    final drop = phase == 'drop';
    if (drop && token != null && !_retiredTokens.add(token)) return false;
    while (_retiredTokens.length > 128) {
      _retiredTokens.remove(_retiredTokens.first);
    }
    final target = _target;
    final x = value['x'], y = value['y'];
    final eligible =
        target != null &&
        const ['enter', 'update', 'exit', 'drop'].contains(phase) &&
        value['documentID'] == target.documentID &&
        value['accessRevision'] == target.accessRevision &&
        value['targetRevision'] == target.revision &&
        x is num &&
        x.isFinite &&
        y is num &&
        y.isFinite &&
        (!drop || token != null);
    var accepted = false;
    if (eligible) {
      final position = Offset(x.toDouble(), y.toDouble());
      if (phase == 'exit' || target.bounds.contains(position)) {
        try {
          accepted = target.onDrag(
            ComposerDropEvent(
              phase: phase as String,
              position: position,
              dropToken: token,
            ),
          );
        } catch (_) {
          // A retired widget cannot leave a credential or escape the channel.
        }
      }
    }
    if (drop && token != null && !accepted) await _release(token);
    return accepted;
  }

  Future<void> _release(String token) async {
    try {
      await _cleanupClient?.call('system.releaseComposerDrop', {
        'dropToken': token,
      });
    } catch (_) {
      // Native expiry is the final cleanup if the account/host already retired.
    }
  }

  /// Used by isolated channel tests; scopes release only their own target.
  void dispose() {
    if (_target case final target?) removeTarget(target.owner);
    if (_listening) channel.setMethodCallHandler(null);
    _listening = false;
    _cleanupClient = null;
    _retiredTokens.clear();
  }
}

class _DropTarget {
  const _DropTarget({
    required this.owner,
    required this.documentID,
    required this.accessRevision,
    required this.bounds,
    required this.revision,
    required this.onDrag,
  });
  final Object owner;
  final String documentID;
  final int accessRevision, revision;
  final Rect bounds;
  final bool Function(ComposerDropEvent) onDrag;
}
