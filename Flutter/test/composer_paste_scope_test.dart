import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/document_history.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';
import 'package:seekdesk_flutter/widgets/composer_paste_scope.dart';
import 'package:seekdesk_flutter/widgets/document_history_scope.dart';
import 'package:seekdesk_flutter/widgets/edit_menu_bridge.dart';

const _menu = MethodChannel('cc.seekdesk/edit-menu.paste-scope-test');
const _bodyKey = ValueKey('paste-body');
const _otherKey = ValueKey('other-text-field');

class _PasteNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  JsonMap capture = {'kind': 'text', 'text': '<text>'};
  Completer<JsonMap>? captureGate, uploadGate;

  int count(String method) => calls.where((call) => call.$1 == method).length;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'system.captureComposerPaste':
        return await captureGate?.future ?? capture;
      case 'images.keyStatus':
        return {'configured': true};
      case 'images.uploadClipboardSnapshot':
        return await uploadGate?.future ?? {'markdown': '<image>'};
      case 'images.releaseClipboardSnapshot':
        return {'released': true};
      default:
        // Never fall through to the real platform, keys or network.
        throw NativeFailure('fixture_only', 'Unexpected paste fixture call');
    }
  }
}

class _PasteFixture {
  _PasteFixture() {
    state = AppState(client: native);
    history = DocumentHistory(controller: content);
    media = ComposerMediaController(
      state: state,
      content: content,
      revision: state.accessRevision,
      documentIdentity: this,
      canStart: () => enabled.value,
      applyEdit: history.apply,
    );
  }

  final native = _PasteNative();
  final navigator = GlobalKey<NavigatorState>();
  final enabled = ValueNotifier(true);
  final bodyFocus = FocusNode(), otherFocus = FocusNode();
  final content = TextEditingController.fromValue(
    const TextEditingValue(
      text: 'before chosen after',
      selection: TextSelection(baseOffset: 7, extentOffset: 13),
    ),
  );
  final other = TextEditingController(text: 'title');
  late final AppState state;
  late final DocumentHistory history;
  late final ComposerMediaController media;
  var keyRequests = 0;

  Widget get widget => CupertinoApp(
    navigatorKey: navigator,
    builder: (context, child) => EditMenuBridge(channel: _menu, child: child!),
    home: CupertinoPageScaffold(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            CupertinoTextField(
              key: _otherKey,
              controller: other,
              focusNode: otherFocus,
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder(
              valueListenable: enabled,
              builder: (context, value, _) => ComposerPasteScope(
                media: media,
                bodyFocus: bodyFocus,
                enabled: value,
                requestKey: () async {
                  keyRequests++;
                  return null;
                },
                child: DocumentHistoryScope(
                  history: history,
                  child: CupertinoTextField(
                    key: _bodyKey,
                    controller: content,
                    focusNode: bodyFocus,
                    selectAllOnFocus: false,
                    minLines: 5,
                    maxLines: 5,
                    contextMenuBuilder: ComposerPasteScope.contextMenuBuilder,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void dispose() {
    media.dispose();
    history.dispose();
    content.dispose();
    other.dispose();
    bodyFocus.dispose();
    otherFocus.dispose();
    enabled.dispose();
    state.dispose();
  }
}

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

Future<Object?> _host(
  WidgetTester tester,
  String method, [
  Object? arguments,
]) async {
  final response = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _menu.name,
    _menu.codec.encodeMethodCall(MethodCall(method, arguments)),
    null,
  );
  await tester.pump();
  final envelope = await response;
  if (envelope == null) throw MissingPluginException('Missing fixture menu');
  return _menu.codec.decodeEnvelope(envelope);
}

Future<Map<Object?, Object?>> _capabilities(WidgetTester tester) async =>
    (await _host(tester, 'capabilities'))! as Map<Object?, Object?>;

Set<String> _commands(Map<Object?, Object?> value) =>
    (value['commands']! as List).cast<String>().toSet();

Future<bool> _perform(WidgetTester tester, String command) async {
  final snapshot = await _capabilities(tester);
  return (await _host(tester, 'perform', {
        'command': command,
        'focusToken': snapshot['focusToken'],
      }))!
      as bool;
}

Future<void> _rightClick(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(_bodyKey)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
  expect(find.text('Paste'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var clipboardText = '';
  var clipboardReads = 0;
  Completer<String?>? clipboardReadGate;
  final notifications = <MethodCall>[];

  setUp(() {
    clipboardText = '';
    clipboardReads = 0;
    clipboardReadGate = null;
    notifications.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          clipboardReads++;
          final text = clipboardReadGate == null
              ? clipboardText
              : await clipboardReadGate!.future;
          return text == null ? null : {'text': text};
        case 'Clipboard.hasStrings':
          return {'value': clipboardText.isNotEmpty};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(_menu, (call) async {
      notifications.add(call);
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_menu, null);
  });

  Future<void> mount(WidgetTester tester, _PasteFixture fixture) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    fixture.bodyFocus.requestFocus();
    await tester.pump();
    fixture.content.selection = const TextSelection(
      baseOffset: 7,
      extentOffset: 13,
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, _PasteFixture fixture) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    fixture.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(tester.takeException(), isNull);
  }

  for (final entry in ['Cmd-V', 'native Edit menu', 'right-click menu']) {
    testWidgets(
      '$entry starts one image operation without ordinary paste fallback',
      (tester) async {
        final f = _PasteFixture();
        f.native.capture = {
          'kind': 'image',
          'token': 'fixture-image',
          'mime': 'image/png',
          'byteCount': 10,
        };
        f.native.uploadGate = Completer<JsonMap>();
        await mount(tester, f);
        if (entry == 'right-click menu') await _rightClick(tester);
        final before = f.content.value;
        if (entry == 'Cmd-V') {
          await _shortcut(tester, LogicalKeyboardKey.keyV);
        } else if (entry == 'native Edit menu') {
          expect(await _perform(tester, 'paste'), true);
        } else {
          // A real secondary-button gesture opens the image-capable menu, even
          // though the fake Clipboard.hasStrings reports false.
          await tester.tap(find.text('Paste'));
          await tester.pump();
        }
        await tester.pump();
        expect(f.media.busy, true);
        expect(f.native.count('system.captureComposerPaste'), 1);
        expect(f.native.count('images.uploadClipboardSnapshot'), 1);
        expect(clipboardReads, 0);
        await _shortcut(tester, LogicalKeyboardKey.keyV);
        expect(await _perform(tester, 'paste'), false);
        expect(await _perform(tester, 'pasteAsPlainText'), false);
        expect(f.native.count('system.captureComposerPaste'), 1);
        expect(clipboardReads, 0);
        expect(f.content.value, before);
        f.native.uploadGate!.complete({'markdown': '<image>'});
        await tester.pump();
        await tester.pump();
        expect(
          f.content.text,
          before.text.replaceRange(
            before.selection.end,
            before.selection.end,
            '<image>',
          ),
        );
        expect(f.native.count('images.releaseClipboardSnapshot'), 1);
        expect(f.media.busy, false);
        expect(f.keyRequests, 0);
        await _shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(f.content.value, before);
        expect(f.history.canUndo, false);
        await cleanup(tester, f);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'Cmd-V replaces the captured selection through document history with no text re-read',
    (tester) async {
      final f = _PasteFixture();
      clipboardText = 'unrelated later clipboard';
      await mount(tester, f);
      final before = f.content.value;
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      expect(f.content.text, 'before <text> after');
      expect(clipboardReads, 0);
      expect(f.native.count('images.keyStatus'), 0);
      expect(f.native.count('images.uploadClipboardSnapshot'), 0);
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(f.content.value, before);
      expect(f.history.canUndo, false);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'native plain-text paste bypasses image capture and forms one history transaction',
    (tester) async {
      final f = _PasteFixture();
      f.native.capture = {'kind': 'image', 'token': 'must-not-capture'};
      clipboardText = '**plain**';
      await mount(tester, f);
      final before = f.content.value;
      expect(await _perform(tester, 'pasteAsPlainText'), true);
      expect(f.content.text, 'before **plain** after');
      expect(clipboardReads, 1);
      expect(f.native.calls, isEmpty);
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(f.content.value, before);
      expect(f.history.canUndo, false);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'plain-text paste holds busy and rejects selection ABA before clipboard response',
    (tester) async {
      final f = _PasteFixture();
      clipboardReadGate = Completer<String?>();
      await mount(tester, f);
      final before = f.content.value;
      expect(await _perform(tester, 'pasteAsPlainText'), true);
      expect(f.media.busy, true);
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      expect(clipboardReads, 1);
      expect(f.native.calls, isEmpty);
      f.content.selection = const TextSelection.collapsed(offset: 0);
      f.content.value = before;
      clipboardReadGate!.complete('stale text');
      await tester.pump();
      expect(f.content.value, before);
      expect(f.media.busy, false);
      expect(f.history.canUndo, false);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'plain-text paste with an image-only clipboard does not capture or upload the image',
    (tester) async {
      final f = _PasteFixture();
      f.native.capture = {'kind': 'image', 'token': 'must-not-capture'};
      await mount(tester, f);
      final before = f.content.value;
      expect(await _perform(tester, 'pasteAsPlainText'), true);
      expect(f.content.value, before);
      expect(f.history.canUndo, false);
      expect(f.native.calls, isEmpty);
      expect(clipboardReads, 1);
      expect(f.media.busy, false);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final change in ['focus ABA', 'enabled ABA', 'account']) {
    testWidgets(
      'pending plain-text paste rejects $change without replacing text',
      (tester) async {
        final f = _PasteFixture();
        clipboardReadGate = Completer<String?>();
        await mount(tester, f);
        final before = f.content.value;
        expect(await _perform(tester, 'pasteAsPlainText'), true);
        if (change == 'focus ABA') {
          f.otherFocus.requestFocus();
          await tester.pump();
          f.bodyFocus.requestFocus();
          await tester.pump();
          // Restore the exact value so scope ownership, rather than content
          // inequality alone, has to reject the pending response.
          f.content.value = before;
        } else if (change == 'enabled ABA') {
          f.enabled.value = false;
          await tester.pump();
          f.enabled.value = true;
          await tester.pump();
        } else {
          f.native.accessRevision++;
          f.state.showMessage('Fixture account change');
          await tester.pump();
        }
        clipboardReadGate!.complete('stale text');
        await tester.pump();
        expect(f.content.value, before);
        expect(f.native.calls, isEmpty);
        expect(f.media.busy, false);
        expect(f.history.canUndo, false);
        await cleanup(tester, f);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'pending native capture rejects a route change and never edits a covered body',
    (tester) async {
      final f = _PasteFixture();
      f.native.captureGate = Completer<JsonMap>();
      await mount(tester, f);
      final before = f.content.value;
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      unawaited(
        f.navigator.currentState!.push<void>(
          CupertinoPageRoute(
            builder: (_) => const CupertinoPageScaffold(
              child: Center(child: Text('Other route')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      f.native.captureGate!.complete({
        'kind': 'text',
        'text': 'stale route text',
      });
      await tester.pump();
      expect(f.content.value, before);
      expect(f.history.canUndo, false);
      f.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'IME blocks both menus and consumes Cmd-V without a platform text fallback',
    (tester) async {
      final f = _PasteFixture();
      clipboardText = 'must not replace composing text';
      await mount(tester, f);
      const composing = TextEditingValue(
        text: '输入拼音',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      final menu = _commands(await _capabilities(tester));
      expect(menu, isNot(contains('paste')));
      expect(menu, isNot(contains('pasteAsPlainText')));
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      expect(f.content.value, composing);
      expect(f.native.calls, isEmpty);
      expect(clipboardReads, 0);
      expect(f.keyRequests, 0);
      expect(f.media.busy, false);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'scope enabled and media-only changes refresh native menu capabilities',
    (tester) async {
      final f = _PasteFixture();
      await mount(tester, f);
      expect(
        _commands(await _capabilities(tester)),
        containsAll(['paste', 'pasteAsPlainText']),
      );
      notifications.clear();
      final gate = Completer<void>();
      final managing = f.media.manageSettings(
        presentSettings: () => gate.future,
      );
      await tester.pump();
      expect(notifications.any((call) => call.method == 'changed'), true);
      expect(_commands(await _capabilities(tester)), isNot(contains('paste')));
      notifications.clear();
      gate.complete();
      await managing;
      await tester.pump();
      expect(notifications.any((call) => call.method == 'changed'), true);
      expect(_commands(await _capabilities(tester)), contains('paste'));
      notifications.clear();
      f.enabled.value = false;
      await tester.pump();
      expect(notifications.any((call) => call.method == 'changed'), true);
      expect(
        _commands(await _capabilities(tester)),
        isNot(contains('pasteAsPlainText')),
      );
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      expect(f.native.calls, isEmpty);
      expect(clipboardReads, 0);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('an open context menu disables paste when media becomes busy', (
    tester,
  ) async {
    final f = _PasteFixture();
    await mount(tester, f);
    await _rightClick(tester);
    final original = f.content.value;
    final gate = Completer<void>();
    final managing = f.media.manageSettings(presentSettings: () => gate.future);
    await tester.pump();
    final toolbar = tester.widget<CupertinoAdaptiveTextSelectionToolbar>(
      find.byType(CupertinoAdaptiveTextSelectionToolbar),
    );
    final paste = toolbar.buttonItems!.singleWhere(
      (item) => item.kind == ContextMenuButtonKind.paste,
    );
    expect(paste.onPressed, isNull);
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(f.content.value, original);
    expect(f.native.calls, isEmpty);
    expect(clipboardReads, 0);
    gate.complete();
    await managing;
    await tester.pump();
    await cleanup(tester, f);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'other fields keep ordinary text paste and stale native focus tokens are rejected',
    (tester) async {
      final f = _PasteFixture();
      clipboardText = 'ordinary field text';
      await mount(tester, f);
      final body = f.content.value;
      final oldMenu = await _capabilities(tester);
      f.otherFocus.requestFocus();
      await tester.pump();
      f.other.selection = TextSelection(
        baseOffset: 0,
        extentOffset: f.other.text.length,
      );
      expect(
        await _host(tester, 'perform', {
          'command': 'paste',
          'focusToken': oldMenu['focusToken'],
        }),
        false,
      );
      expect(await _perform(tester, 'pasteAsPlainText'), true);
      expect(f.other.text, clipboardText);
      expect(f.content.value, body);
      expect(f.native.calls, isEmpty);
      expect(clipboardReads, 1);
      await cleanup(tester, f);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'disposing a body with a pending plain-text request discards its result',
    (tester) async {
      final f = _PasteFixture();
      clipboardReadGate = Completer<String?>();
      await mount(tester, f);
      final original = f.content.value;
      expect(await _perform(tester, 'pasteAsPlainText'), true);
      await tester.pumpWidget(const SizedBox.shrink());
      clipboardReadGate!.complete('late text');
      await tester.pump();
      expect(f.content.value, original);
      expect(f.native.calls, isEmpty);
      f.dispose();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
