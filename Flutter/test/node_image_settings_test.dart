import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/node_image_settings.dart';

/// Synthetic, in-memory credentials only. This client never reaches a channel,
/// network service, native image picker, or the real macOS keychain.
class _SettingsNative extends NativeClient {
  String? stored = 'fixture-existing-key';
  final calls = <(String, JsonMap)>[];
  Future<JsonMap?> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    final overridden = await response?.call(method, arguments);
    if (overridden != null) return overridden;
    switch (method) {
      case 'images.keyStatus':
        return {'configured': stored != null};
      case 'images.setKey':
        stored = arguments['key'] as String;
        return {'configured': true};
      case 'images.removeKey':
        stored = null;
        return {'configured': false};
      default:
        throw const NativeFailure('fixture_only', 'Unsupported fixture call');
    }
  }

  Iterable<(String, JsonMap)> callsFor(String method) =>
      calls.where((call) => call.$1 == method);
}

class _SettingsState extends AppState {
  _SettingsState(_SettingsNative native) : super(client: native);

  void changeAccount() {
    client.accessRevision++;
    notifyListeners();
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

DeskButton _control(WidgetTester tester, String label) =>
    tester.widget<DeskButton>(_button(label));

CupertinoTextField _field(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(find.byType(CupertinoTextField));

Future<void> _frame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<GlobalKey<NavigatorState>> _mount(
  WidgetTester tester,
  _SettingsState state, {
  FocusNode? triggerFocus,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final navigation = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    CupertinoApp(
      navigatorKey: navigation,
      builder: (context, child) => GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: child!,
      ),
      home: CupertinoPageScaffold(
        child: Center(
          child: Builder(
            builder: (context) => CupertinoButton(
              focusNode: triggerFocus,
              autofocus: triggerFocus != null,
              onPressed: () => unawaited(showNodeImageSettings(context, state)),
              child: const Text('Open fixture settings'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture settings'));
  await _frame(tester);
  expect(find.byType(NodeImageSettings), findsOneWidget);
  return navigation;
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump(const Duration(seconds: 6));
  expect(tester.takeException(), isNull);
}

Future<void> _confirmRemoval(WidgetTester tester, {bool accept = true}) async {
  await tester.tap(
    find.widgetWithText(DeskDialogAction, accept ? '移除密钥' : '取消'),
  );
  await _frame(tester);
}

CupertinoPageRoute<void> _coverSettings(GlobalKey<NavigatorState> navigation) {
  final route = CupertinoPageRoute<void>(
    builder: (_) => const CupertinoPageScaffold(
      child: Center(child: Text('Covering fixture route')),
    ),
  );
  unawaited(navigation.currentState!.push(route));
  return route;
}

void _expectNoSensitiveFeedback(WidgetTester tester, String marker) {
  // The secure field may legitimately retain the user-entered value for retry.
  // Feedback, headings, and rendered labels must never echo an error's secret.
  final labels = tester.widgetList<Text>(find.byType(Text)).map((widget) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  });
  expect(labels.where((label) => label.contains(marker)), isEmpty);
}

// The framework restores this variant before postTest invariants, including
// when a test body fails. Global setUp/tearDown overrides run too late here.
void _testMac(String description, WidgetTesterCallback callback) => testWidgets(
  description,
  callback,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final close in ['escape', 'button', 'navigator']) {
    _testMac('pending status permits $close and ignores late results', (
      tester,
    ) async {
      final pending = Completer<JsonMap?>();
      final native = _SettingsNative()
        ..response = (method, args) =>
            method == 'images.keyStatus' ? pending.future : Future.value(null);
      final state = _SettingsState(native);
      final navigator = await _mount(tester, state);
      expect(find.text('正在读取密钥状态…'), findsOneWidget);
      expect(_field(tester).enabled, isFalse);
      expect(_control(tester, '保存密钥').onTap, isNull);
      expect(_control(tester, '移除密钥').onTap, isNull);
      expect(await state.flushDrafts(), isTrue);
      expect(_control(tester, '关闭').onTap, isNotNull);
      switch (close) {
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'button':
          await tester.tap(_button('关闭'));
        case 'navigator':
          await navigator.currentState!.maybePop();
      }
      pending.complete({'configured': true});
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('已配置上传密钥'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(NodeImageSettings), findsNothing);
      expect(find.text('Open fixture settings'), findsOneWidget);
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      expect(native.stored, 'fixture-existing-key');
      await _cleanup(tester, state);
    });
  }

  _testMac(
    'pending retry can close and its late error cannot affect reopened settings',
    (tester) async {
      final pending = Completer<JsonMap?>();
      var attempts = 0;
      final native = _SettingsNative()
        ..response = (method, args) async {
          if (method != 'images.keyStatus') return null;
          attempts++;
          if (attempts == 1) {
            throw const NativeFailure('fixture', 'Synthetic failure');
          }
          if (attempts == 2) return pending.future;
          return {'configured': false};
        };
      final state = _SettingsState(native);
      await _mount(tester, state);
      final retry = _control(tester, '重试').onTap!;
      await tester.tap(_button('重试'));
      await _frame(tester);
      retry();
      _field(tester).onSubmitted!('fixture-new-key');
      await tester.pump();
      expect(attempts, 2);
      expect(_field(tester).enabled, false);
      expect(_control(tester, '保存密钥').onTap, isNull);
      expect(_control(tester, '移除密钥').onTap, isNull);
      expect(await state.flushDrafts(), true);
      await tester.tap(_button('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open fixture settings'));
      await _frame(tester);
      expect(find.text('尚未配置上传密钥'), findsOneWidget);
      pending.completeError(
        const NativeFailure('fixture', 'fixture-sensitive-late-error'),
      );
      await _frame(tester);
      expect(find.text('尚未配置上传密钥'), findsOneWidget);
      expect(find.text('暂时无法读取本机密钥状态，请重试。'), findsNothing);
      _expectNoSensitiveFeedback(tester, 'fixture-sensitive-late-error');
      expect(attempts, 3);
      expect(native.callsFor('images.setKey'), isEmpty);
      expect(native.callsFor('images.removeKey'), isEmpty);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'account change during status read still permits closing before completion',
    (tester) async {
      final pending = Completer<JsonMap?>();
      final native = _SettingsNative()
        ..response = (method, args) => pending.future;
      final state = _SettingsState(native);
      await _mount(tester, state);
      state.changeAccount();
      await tester.pump();
      expect(find.text('设置已暂停'), findsOneWidget);
      expect(_field(tester).enabled, false);
      expect(_control(tester, '关闭').onTap, isNotNull);
      expect(await state.flushDrafts(), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      pending.complete({'configured': true});
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('已配置上传密钥'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(NodeImageSettings), findsNothing);
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      await _cleanup(tester, state);
    },
  );

  for (final fieldFocused in [false, true]) {
    _testMac(
      'idle Escape closes settings once with field focus $fieldFocused and restores trigger focus',
      (tester) async {
        final native = _SettingsNative();
        final state = _SettingsState(native);
        final triggerFocus = FocusNode();
        addTearDown(triggerFocus.dispose);
        final navigator = await _mount(
          tester,
          state,
          triggerFocus: triggerFocus,
        );
        if (fieldFocused) {
          await tester.enterText(
            find.byType(CupertinoTextField),
            'fixture-unsaved-key',
          );
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(NodeImageSettings), findsNothing);
        expect(find.text('Open fixture settings'), findsOneWidget);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(triggerFocus.hasFocus, isTrue);
        expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
        expect(native.stored, 'fixture-existing-key');
        await _cleanup(tester, state);
      },
    );
  }

  _testMac('account change during exit clears the retiring input immediately', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'fixture-unsaved-key',
    );
    await tester.pump();
    final controller = _field(tester).controller!;
    await tester.tap(_button('关闭'));
    state.changeAccount();
    expect(controller.text, isEmpty);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await tester.pumpAndSettle();
    expect(find.byType(NodeImageSettings), findsNothing);
    await _cleanup(tester, state);
  });

  _testMac('Escape preserves IME preedit and closes after composition ends', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.enterText(find.byType(CupertinoTextField), 'fixture-preedit');
    final controller = _field(tester).controller!;
    controller.value = const TextEditingValue(
      text: 'fixture-preedit',
      selection: TextSelection.collapsed(offset: 15),
      composing: TextRange(start: 0, end: 15),
    );
    await tester.pump();
    final before = controller.value;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frame(tester);
    expect(find.byType(NodeImageSettings), findsOneWidget);
    expect(controller.value, before);
    controller.value = before.copyWith(composing: TextRange.empty);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(NodeImageSettings), findsNothing);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await _cleanup(tester, state);
  });

  _testMac('modified Escape leaves settings open and plain Escape closes it', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.shiftLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(modifier);
      await _frame(tester);
      expect(find.byType(NodeImageSettings), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(NodeImageSettings), findsNothing);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await _cleanup(tester, state);
  });

  _testMac('Escape closes only the covering removal confirmation first', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.tap(_button('移除密钥'));
    await _frame(tester);
    expect(find.byType(DeskDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DeskDialog), findsNothing);
    expect(find.byType(NodeImageSettings), findsOneWidget);
    expect(native.callsFor('images.removeKey'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(NodeImageSettings), findsNothing);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await _cleanup(tester, state);
  });

  test('validator rejects blank values and every native newline boundary', () {
    for (final blank in ['', '   ', '\t', '\u00a0', '\u3000']) {
      expect(nodeImageKeyError(blank), isNotNull);
    }
    for (final newline in [
      '\n',
      '\r',
      '\r\n',
      '\u000b',
      '\u000c',
      '\u0085',
      '\u2028',
      '\u2029',
    ]) {
      for (final candidate in [
        '${newline}fixture-key',
        'fixture${newline}key',
        'fixture-key$newline',
      ]) {
        expect(nodeImageKeyError(candidate), contains('换行'));
      }
    }
    expect(nodeImageKeyError('fixture-key'), isNull);
    expect(nodeImageKeyError('  fixture-key  '), isNull);
  });

  _testMac(
    'configured credentials remain blank and are never filled from a response',
    (tester) async {
      final native = _SettingsNative()
        ..response = (method, args) async => method == 'images.keyStatus'
            ? {'configured': true, 'key': 'fixture-secret-from-response'}
            : null;
      final state = _SettingsState(native);
      await _mount(tester, state);
      expect(find.text('已配置上传密钥'), findsOneWidget);
      expect(_field(tester).controller!.text, isEmpty);
      expect(_field(tester).obscureText, true);
      expect(_field(tester).autocorrect, false);
      expect(_field(tester).enableSuggestions, false);
      expect(_control(tester, '更换密钥').onTap, isNull);
      expect(_control(tester, '移除密钥').onTap, isNotNull);
      _expectNoSensitiveFeedback(tester, 'fixture-secret-from-response');
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      await _cleanup(tester, state);
    },
  );

  _testMac('first save trims a valid key and clears the secure input', (
    tester,
  ) async {
    final native = _SettingsNative()..stored = null;
    final state = _SettingsState(native);
    await _mount(tester, state);
    expect(find.text('尚未配置上传密钥'), findsOneWidget);
    expect(_control(tester, '移除密钥').onTap, isNull);
    await tester.enterText(
      find.byType(CupertinoTextField),
      '  fixture-new-key  ',
    );
    await tester.pump();
    await tester.tap(_button('保存密钥'));
    await _frame(tester);
    expect(
      native.callsFor('images.setKey').single.$2['key'],
      'fixture-new-key',
    );
    expect(native.stored, 'fixture-new-key');
    expect(_field(tester).controller!.text, isEmpty);
    expect(find.text('上传密钥已保存。'), findsOneWidget);
    expect(find.text('已配置上传密钥'), findsOneWidget);
    expect(await state.flushDrafts(), true);
    await _cleanup(tester, state);
  });

  for (final configured in [false, true]) {
    _testMac(
      '${configured ? 'replacement' : 'first'} key save rejects IME preedit from a stale click and native submission until committed',
      (tester) async {
        final native = _SettingsNative()
          ..stored = configured ? 'fixture-existing-key' : null;
        final state = _SettingsState(native);
        await _mount(tester, state);
        final label = configured ? '更换密钥' : '保存密钥';
        const text = 'fixture-uncommitted-key';
        await tester.enterText(find.byType(CupertinoTextField), text);
        await tester.pump();
        final staleClick = _control(tester, label).onTap!;
        final controller = _field(tester).controller!;
        controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: TextRange(start: 0, end: text.length),
        );
        await tester.pump();
        expect(_control(tester, label).onTap, isNull);
        staleClick();
        _field(tester).onSubmitted!(text);
        // Exercise EditableText's actual completion path as well: its default
        // onEditingComplete would otherwise erase composing before onSubmitted.
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(native.callsFor('images.setKey'), isEmpty);
        expect(native.stored, configured ? 'fixture-existing-key' : null);
        expect(controller.text, text);
        expect(
          controller.value.composing,
          TextRange(start: 0, end: text.length),
        );
        expect(_control(tester, label).onTap, isNull);
        // A composition-only commit must refresh the button even though the
        // visible text is unchanged and TextField.onChanged would not run.
        controller.value = controller.value.copyWith(
          composing: TextRange.empty,
        );
        await tester.pump();
        expect(_control(tester, label).onTap, isNotNull);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _frame(tester);
        expect(native.callsFor('images.setKey'), hasLength(1));
        expect(native.callsFor('images.setKey').single.$2, {'key': text});
        expect(native.stored, text);
        expect(controller.text, isEmpty);
        expect(find.text('上传密钥已保存。'), findsOneWidget);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac('replacement failure masks sensitive errors and permits retry', (
    tester,
  ) async {
    final native = _SettingsNative();
    var failing = true;
    native.response = (method, args) async {
      if (method == 'images.setKey' && failing) {
        throw const NativeFailure('denied', 'fixture-private-error-key');
      }
      return null;
    };
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'fixture-replacement-key',
    );
    await tester.pump();
    await tester.tap(_button('更换密钥'));
    await _frame(tester);
    expect(find.text('密钥未能保存，请重试。'), findsOneWidget);
    expect(find.text('已配置上传密钥'), findsOneWidget);
    expect(native.stored, 'fixture-existing-key');
    expect(_field(tester).controller!.text, 'fixture-replacement-key');
    expect(state.message, isNull);
    _expectNoSensitiveFeedback(tester, 'fixture-private-error-key');
    expect(await state.flushDrafts(), true);
    failing = false;
    await tester.tap(_button('更换密钥'));
    await _frame(tester);
    expect(native.callsFor('images.setKey').length, 2);
    expect(native.stored, 'fixture-replacement-key');
    expect(_field(tester).controller!.text, isEmpty);
    await _cleanup(tester, state);
  });

  _testMac('blank and multiline submissions never reach the key store', (
    tester,
  ) async {
    final native = _SettingsNative()..stored = null;
    final state = _SettingsState(native);
    await _mount(tester, state);
    for (final value in [
      '  ',
      '\t',
      'fixture\nkey',
      'fixture\rkey',
      'fixture\u2028key',
      'fixture\u0085key',
    ]) {
      // A programmatic value also tests the validation boundary, independently
      // of the platform's single-line field normalization during paste.
      _field(tester).controller!.text = value;
      _field(tester).onSubmitted!(value);
      await tester.pump();
      expect(native.callsFor('images.setKey'), isEmpty);
    }
    expect(find.text('密钥不能包含换行，请重新复制完整的一行。'), findsOneWidget);
    await _cleanup(tester, state);
  });

  for (final malformed in [false, true]) {
    _testMac(
      '${malformed ? 'malformed' : 'failed'} status stays distinct from an unconfigured key and retries',
      (tester) async {
        final native = _SettingsNative();
        var first = true;
        native.response = (method, args) async {
          if (method == 'images.keyStatus' && first) {
            first = false;
            if (malformed) return {'configured': 'yes'};
            throw const NativeFailure(
              'denied',
              'fixture-sensitive-status-error',
            );
          }
          return null;
        };
        final state = _SettingsState(native);
        await _mount(tester, state);
        expect(find.text('无法读取密钥状态'), findsOneWidget);
        expect(find.text('尚未配置上传密钥'), findsNothing);
        expect(_field(tester).enabled, false);
        expect(_control(tester, '保存密钥').onTap, isNull);
        expect(_control(tester, '移除密钥').onTap, isNull);
        _expectNoSensitiveFeedback(tester, 'fixture-sensitive-status-error');
        await tester.tap(_button('重试'));
        await _frame(tester);
        expect(native.callsFor('images.keyStatus').length, 2);
        expect(find.text('已配置上传密钥'), findsOneWidget);
        expect(_field(tester).controller!.text, isEmpty);
        expect(_field(tester).enabled, true);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac(
    'removal confirmation blocks flush and cancellation never removes a key',
    (tester) async {
      final native = _SettingsNative();
      final state = _SettingsState(native);
      await _mount(tester, state);
      final remove = _control(tester, '移除密钥').onTap!;
      await tester.tap(_button('移除密钥'));
      remove(); // A stale click callback cannot open a second confirmation.
      await _frame(tester);
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(await state.flushDrafts(), false);
      expect(native.callsFor('images.removeKey'), isEmpty);
      await _confirmRemoval(tester, accept: false);
      expect(native.callsFor('images.removeKey'), isEmpty);
      expect(find.text('已配置上传密钥'), findsOneWidget);
      expect(_control(tester, '关闭').onTap, isNotNull);
      expect(await state.flushDrafts(), true);
      await _cleanup(tester, state);
    },
  );

  _testMac('confirmed removal clears only the in-memory key and input', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'fixture-unsaved-input',
    );
    await tester.pump();
    await tester.tap(_button('移除密钥'));
    await _frame(tester);
    await _confirmRemoval(tester);
    expect(native.callsFor('images.removeKey').length, 1);
    expect(native.stored, isNull);
    expect(_field(tester).controller!.text, isEmpty);
    expect(find.text('本机上传密钥已移除。'), findsOneWidget);
    expect(find.text('尚未配置上传密钥'), findsOneWidget);
    expect(_control(tester, '移除密钥').onTap, isNull);
    await _cleanup(tester, state);
  });

  _testMac(
    'removal failure preserves configuration and masks native error details',
    (tester) async {
      final native = _SettingsNative();
      var failing = true;
      native.response = (method, args) async {
        if (method == 'images.removeKey' && failing) {
          throw const NativeFailure(
            'denied',
            'fixture-sensitive-removal-error',
          );
        }
        return null;
      };
      final state = _SettingsState(native);
      await _mount(tester, state);
      await tester.tap(_button('移除密钥'));
      await _frame(tester);
      await _confirmRemoval(tester);
      expect(find.text('密钥未能移除，请重试。'), findsOneWidget);
      expect(find.text('已配置上传密钥'), findsOneWidget);
      expect(native.stored, 'fixture-existing-key');
      _expectNoSensitiveFeedback(tester, 'fixture-sensitive-removal-error');
      expect(state.message, isNull);
      failing = false;
      await tester.tap(_button('移除密钥'));
      await _frame(tester);
      await _confirmRemoval(tester);
      expect(native.callsFor('images.removeKey').length, 2);
      expect(native.stored, isNull);
      await _cleanup(tester, state);
    },
  );

  for (final method in ['images.setKey', 'images.removeKey']) {
    _testMac(
      '$method busy blocks repeat calls, route close and lifecycle flush',
      (tester) async {
        final native = _SettingsNative();
        final pending = Completer<JsonMap?>();
        native.response = (called, args) async {
          if (called != method) return null;
          return pending.future;
        };
        final state = _SettingsState(native);
        final navigator = await _mount(tester, state);
        VoidCallback? staleAction;
        if (method == 'images.setKey') {
          await tester.enterText(
            find.byType(CupertinoTextField),
            'fixture-new-key',
          );
          await tester.pump();
          staleAction = _control(tester, '更换密钥').onTap;
          await tester.tap(_button('更换密钥'));
          await _frame(tester);
        } else if (method == 'images.removeKey') {
          staleAction = _control(tester, '移除密钥').onTap;
          await tester.tap(_button('移除密钥'));
          await _frame(tester);
          await _confirmRemoval(tester);
        }
        staleAction?.call();
        _field(tester).onSubmitted!('fixture-new-key');
        await tester.pump();
        expect(native.callsFor(method).length, 1);
        expect(_field(tester).enabled, false);
        expect(_control(tester, '关闭').onTap, isNull);
        expect(await state.flushDrafts(), false);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frame(tester);
        expect(find.byType(NodeImageSettings), findsOneWidget);
        await navigator.currentState!.maybePop();
        await _frame(tester);
        expect(find.byType(NodeImageSettings), findsOneWidget);
        pending.complete({'configured': method != 'images.removeKey'});
        await _frame(tester);
        expect(await state.flushDrafts(), true);
        await tester.tap(_button('关闭'));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 50),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        expect(find.byType(NodeImageSettings), findsNothing);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac('account change while confirming removal prevents the write', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'fixture-pending-key',
    );
    await tester.pump();
    await tester.tap(_button('移除密钥'));
    await _frame(tester);
    state.changeAccount();
    await tester.pump();
    await _confirmRemoval(tester);
    expect(native.callsFor('images.removeKey'), isEmpty);
    expect(find.text('设置已暂停'), findsOneWidget);
    expect(_field(tester).controller!.text, isEmpty);
    expect(_field(tester).enabled, false);
    expect(await state.flushDrafts(), true);
    await _cleanup(tester, state);
  });

  _testMac(
    'covered settings reject captured save submission removal and close callbacks',
    (tester) async {
      final native = _SettingsNative();
      final state = _SettingsState(native);
      final navigator = await _mount(tester, state);
      await tester.enterText(
        find.byType(CupertinoTextField),
        'fixture-covered-key',
      );
      await tester.pump();
      final save = _control(tester, '更换密钥').onTap!;
      final remove = _control(tester, '移除密钥').onTap!;
      final close = _control(tester, '关闭').onTap!;
      final submit = _field(tester).onSubmitted!;
      final controller = _field(tester).controller!;
      final covering = _coverSettings(navigator);
      await _frame(tester);
      save();
      submit('fixture-covered-key');
      remove();
      close();
      await _frame(tester);
      expect(covering.isCurrent, true);
      expect(find.text('Covering fixture route'), findsOneWidget);
      expect(find.byType(DeskDialog), findsNothing);
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      expect(native.stored, 'fixture-existing-key');
      expect(controller.text, 'fixture-covered-key');
      navigator.currentState!.pop();
      await _frame(tester);
      expect(find.byType(NodeImageSettings), findsOneWidget);
      submit('fixture-covered-key');
      await _frame(tester);
      expect(native.callsFor('images.setKey'), hasLength(1));
      expect(native.stored, 'fixture-covered-key');
      expect(find.text('上传密钥已保存。'), findsOneWidget);
      await _cleanup(tester, state);
    },
  );

  _testMac('covered status retry does not start another request', (
    tester,
  ) async {
    final native = _SettingsNative();
    var first = true;
    native.response = (method, args) async {
      if (method == 'images.keyStatus' && first) {
        first = false;
        throw const NativeFailure('fixture', 'Synthetic status failure');
      }
      return null;
    };
    final state = _SettingsState(native);
    final navigator = await _mount(tester, state);
    final retry = _control(tester, '重试').onTap!;
    final covering = _coverSettings(navigator);
    await _frame(tester);
    retry();
    await _frame(tester);
    expect(covering.isCurrent, true);
    expect(native.callsFor('images.keyStatus'), hasLength(1));
    navigator.currentState!.pop();
    await _frame(tester);
    retry();
    await _frame(tester);
    expect(native.callsFor('images.keyStatus'), hasLength(2));
    expect(find.text('已配置上传密钥'), findsOneWidget);
    await _cleanup(tester, state);
  });

  _testMac('confirmed removal rechecks the settings route before dispatching', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    final navigator = await _mount(tester, state);
    await tester.tap(_button('移除密钥'));
    await _frame(tester);
    final accept = tester
        .widget<DeskDialogAction>(find.widgetWithText(DeskDialogAction, '移除密钥'))
        .onPressed;
    // Cover settings after confirming, before the awaited dialog result
    // resumes the removal operation on the microtask queue.
    accept();
    final covering = _coverSettings(navigator);
    await _frame(tester);
    expect(covering.isCurrent, true);
    expect(native.callsFor('images.removeKey'), isEmpty);
    expect(native.stored, 'fixture-existing-key');
    expect(await state.flushDrafts(), true);
    navigator.currentState!.pop();
    await _frame(tester);
    expect(find.text('已配置上传密钥'), findsOneWidget);
    await tester.tap(_button('移除密钥'));
    await _frame(tester);
    await _confirmRemoval(tester);
    expect(native.callsFor('images.removeKey'), hasLength(1));
    expect(native.stored, isNull);
    await _cleanup(tester, state);
  });

  _testMac('closing settings is single shot and cannot close a newer route', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    final navigator = await _mount(tester, state);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'fixture-closing-key',
    );
    await tester.pump();
    final close = _control(tester, '关闭').onTap!;
    final save = _control(tester, '更换密钥').onTap!;
    final submit = _field(tester).onSubmitted!;
    close();
    close();
    final covering = _coverSettings(navigator);
    close();
    save();
    submit('fixture-closing-key');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    expect(covering.isCurrent, true);
    expect(find.text('Covering fixture route'), findsOneWidget);
    expect(find.byType(NodeImageSettings, skipOffstage: false), findsNothing);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    close(); // A retained callback also remains inert after disposal.
    expect(covering.isCurrent, true);
    navigator.currentState!.pop();
    await _frame(tester);
    expect(find.text('Open fixture settings'), findsOneWidget);
    await _cleanup(tester, state);
  });

  _testMac('invalidated settings remain closable on their own route', (
    tester,
  ) async {
    final native = _SettingsNative();
    final state = _SettingsState(native);
    await _mount(tester, state);
    state.changeAccount();
    await tester.pump();
    expect(find.text('设置已暂停'), findsOneWidget);
    expect(_control(tester, '关闭').onTap, isNotNull);
    await tester.tap(_button('关闭'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    expect(find.byType(NodeImageSettings), findsNothing);
    expect(find.text('Open fixture settings'), findsOneWidget);
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await _cleanup(tester, state);
  });

  for (final method in [
    'images.keyStatus',
    'images.setKey',
    'images.removeKey',
  ]) {
    _testMac(
      'an owned $method result remains valid while another route covers settings',
      (tester) async {
        final native = _SettingsNative();
        final pending = Completer<JsonMap?>();
        native.response = (called, args) =>
            called == method ? pending.future : Future.value(null);
        final state = _SettingsState(native);
        final navigator = await _mount(tester, state);
        if (method == 'images.setKey') {
          await tester.enterText(
            find.byType(CupertinoTextField),
            'fixture-pending-key',
          );
          await tester.pump();
          await tester.tap(_button('更换密钥'));
          await _frame(tester);
        } else if (method == 'images.removeKey') {
          await tester.tap(_button('移除密钥'));
          await _frame(tester);
          await _confirmRemoval(tester);
        }
        expect(native.callsFor(method), hasLength(1));
        expect(await state.flushDrafts(), method == 'images.keyStatus');
        final covering = _coverSettings(navigator);
        await _frame(tester);
        pending.complete({'configured': method != 'images.removeKey'});
        await _frame(tester);
        expect(covering.isCurrent, true);
        expect(await state.flushDrafts(), true);
        navigator.currentState!.pop();
        await _frame(tester);
        expect(_control(tester, '关闭').onTap, isNotNull);
        expect(
          find.text(method == 'images.removeKey' ? '尚未配置上传密钥' : '已配置上传密钥'),
          findsOneWidget,
        );
        if (method != 'images.keyStatus') {
          expect(_field(tester).controller!.text, isEmpty);
          expect(
            find.text(method == 'images.setKey' ? '上传密钥已保存。' : '本机上传密钥已移除。'),
            findsOneWidget,
          );
        }
        expect(native.callsFor(method), hasLength(1));
        await _cleanup(tester, state);
      },
    );
  }

  for (final method in [
    'images.keyStatus',
    'images.setKey',
    'images.removeKey',
  ]) {
    for (final dispose in [false, true]) {
      _testMac(
        '${dispose ? 'disposal' : 'revision change'} rejects late $method completion',
        (tester) async {
          final native = _SettingsNative();
          final pending = Completer<JsonMap?>();
          native.response = (called, args) =>
              called == method ? pending.future : Future.value(null);
          final state = _SettingsState(native);
          await _mount(tester, state);
          if (method == 'images.setKey') {
            await tester.enterText(
              find.byType(CupertinoTextField),
              'fixture-pending-key',
            );
            await tester.pump();
            await tester.tap(_button('更换密钥'));
            await _frame(tester);
          } else if (method == 'images.removeKey') {
            await tester.tap(_button('移除密钥'));
            await _frame(tester);
            await _confirmRemoval(tester);
          }
          final before = native.calls.length;
          if (dispose) {
            await tester.pumpWidget(const SizedBox.shrink());
            expect(await state.flushDrafts(), true);
          } else {
            state.changeAccount();
            await tester.pump();
            expect(await state.flushDrafts(), method == 'images.keyStatus');
          }
          pending.complete({'configured': method != 'images.removeKey'});
          await _frame(tester);
          expect(native.calls.length, before);
          expect(await state.flushDrafts(), true);
          if (!dispose) {
            expect(find.text('设置已暂停'), findsOneWidget);
            expect(_field(tester).controller!.text, isEmpty);
            expect(_control(tester, '移除密钥').onTap, isNull);
            expect(find.text('上传密钥已保存。'), findsNothing);
            expect(find.text('本机上传密钥已移除。'), findsNothing);
          }
          await _cleanup(tester, state);
        },
      );
    }
  }

  _testMac(
    'late status also detects a revision change without a notification',
    (tester) async {
      final native = _SettingsNative();
      final pending = Completer<JsonMap?>();
      native.response = (method, args) => pending.future;
      final state = _SettingsState(native);
      await _mount(tester, state);
      native.accessRevision++;
      pending.complete({'configured': true});
      await _frame(tester);
      expect(find.text('设置已暂停'), findsOneWidget);
      expect(_field(tester).enabled, false);
      expect(native.calls.length, 1);
      expect(await state.flushDrafts(), true);
      await _cleanup(tester, state);
    },
  );
}
