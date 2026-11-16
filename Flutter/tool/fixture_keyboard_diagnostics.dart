// Opt-in observation for the isolated memory fixture only. No text, clipboard,
// key labels, account data or actual editor values are written to the log.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class FixtureKeyboardDiagnostics {
  static const enabled = bool.fromEnvironment('SEEKDESK_KEYBOARD_DIAGNOSTICS');
  static final _file = File('/tmp/seekdesk-fixture-dart-keyboard.log');
  static TextEditingController? _controller;

  static void start() {
    if (!enabled || !const bool.fromEnvironment('SEEKDESK_PROFILE_FIXTURE')) {
      return;
    }
    _file.writeAsStringSync('');
    HardwareKeyboard.instance.addHandler(_key);
    FocusManager.instance.addListener(_focus);
    _record('start');
  }

  static void stop() {
    if (!enabled) return;
    HardwareKeyboard.instance.removeHandler(_key);
    FocusManager.instance.removeListener(_focus);
    _controller?.removeListener(_selection);
    _controller = null;
  }

  static bool _key(KeyEvent event) {
    final known = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.keyA: 'A',
      LogicalKeyboardKey.keyC: 'C',
      LogicalKeyboardKey.keyV: 'V',
      LogicalKeyboardKey.keyX: 'X',
      LogicalKeyboardKey.metaLeft: 'Meta',
      LogicalKeyboardKey.metaRight: 'Meta',
    };
    _record('key', {
      'kind': event.runtimeType.toString(),
      'key': known[event.logicalKey] ?? 'other',
      'meta': HardwareKeyboard.instance.isMetaPressed,
      'control': HardwareKeyboard.instance.isControlPressed,
      'shift': HardwareKeyboard.instance.isShiftPressed,
      'alt': HardwareKeyboard.instance.isAltPressed,
      'synthesized': event.synthesized,
    });
    scheduleMicrotask(() => _record('after-key'));
    return false;
  }

  static void _focus() {
    _controller?.removeListener(_selection);
    final context = FocusManager.instance.primaryFocus?.context;
    final widget = context?.widget;
    _controller = widget is EditableText
        ? widget.controller
        : context?.findAncestorWidgetOfExactType<EditableText>()?.controller;
    _controller?.addListener(_selection);
    _record('focus');
  }

  static void _selection() => _record('selection');

  static void _record(String event, [Map<String, Object?> extra = const {}]) {
    final controller = _controller;
    _file.writeAsStringSync(
      '${jsonEncode({
        'time': DateTime.now().toIso8601String(),
        'event': event,
        'focus': FocusManager.instance.primaryFocus?.context?.widget.runtimeType.toString(),
        if (controller != null) ...{'length': controller.text.length, 'base': controller.selection.baseOffset, 'extent': controller.selection.extentOffset, 'composing': controller.value.composing.isValid},
        ...extra,
      })}\n',
      mode: FileMode.append,
    );
  }
}
