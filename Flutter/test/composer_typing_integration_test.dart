import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';

class _TypingNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  String content = '- one', title = 'Fixture title';

  JsonMap get snapshot => {
    'title': title,
    'content': content,
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
    'topicID': '17',
    'floor': 0,
    'editToken': 'typing-editor',
    'ready': true,
    'canSave': true,
    'phase': 'ready',
    'category': 'general',
    'rank': 0,
    'maxRank': 3,
    'categories': [
      {'id': 'general', 'title': '常规'},
    ],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'images.draftReferences') {
      return {
        'content': arguments['content'],
        'imageURLs': <String>[],
        'accessRevision': accessRevision,
      };
    }
    if (const {
      'discussion.getDraft',
      'discussion.loadOptions',
      'reader.replyDraft',
      'reader.edit.begin',
    }.contains(method)) {
      return snapshot;
    }
    if (const {
      'discussion.updateDraft',
      'reader.updateReplyDraft',
      'reader.edit.update',
    }.contains(method)) {
      content = stringValue(arguments['content'], content);
      title = stringValue(arguments['title'], title);
      return snapshot;
    }
    // There is no fallback to a platform channel or real forum operation.
    throw NativeFailure('fixture_only', 'Unsupported typing fixture: $method');
  }

  void expectNoForumWrites() => expect(
    calls.where(
      (call) => const {
        'discussion.publish',
        'reader.sendReply',
        'reader.edit.save',
        'system.chooseImage',
      }.contains(call.$1),
    ),
    isEmpty,
  );
}

Finder get _bodyField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
  skipOffstage: false,
);
Finder get _titleField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && !widget.expands,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
CupertinoTextField _body(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_bodyField);
TextEditingController _content(WidgetTester tester) =>
    _body(tester).controller!;

Future<AppState> _mount(
  WidgetTester tester,
  _TypingNative native,
  String kind, {
  String preference = 'commandReturn',
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  final state = AppState(client: native);
  state.domains['settings'] = {'workspace.replySendKey': preference};
  final Widget screen = switch (kind) {
    'inline' => InlineEditScreen(
      state: state,
      topicID: '17',
      floor: 0,
      url: 'https://www.nodeseek.com/post-17-1',
    ),
    'reply' => ComposerScreen(state: state, topicID: '17'),
    _ => ComposerScreen(state: state),
  };
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  _body(tester).focusNode!.requestFocus();
  _content(tester).selection = TextSelection.collapsed(
    offset: _content(tester).text.length,
  );
  await tester.pump();
  return state;
}

Future<void> _clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
  await tester.binding.setSurfaceSize(null);
  expect(tester.takeException(), isNull);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> modifiers = const [],
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  try {
    await tester.sendKeyEvent(key);
  } finally {
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
  }
  await tester.pump();
}

Future<void> _undo(WidgetTester tester, {bool redo = false}) => _key(
  tester,
  LogicalKeyboardKey.keyZ,
  modifiers: [
    LogicalKeyboardKey.metaLeft,
    if (redo) LogicalKeyboardKey.shiftLeft,
  ],
);

void main() {
  for (final kind in ['discussion', 'reply', 'inline']) {
    testWidgets(
      '$kind long history commands reveal the restored caret in both directions',
      (tester) async {
        final original = List.generate(90, (i) => 'Paragraph $i').join('\n');
        final native = _TypingNative()..content = original;
        final state = await _mount(tester, native, kind);
        final content = _content(tester);
        final editable = _body(tester).focusNode!.context!
            .findAncestorStateOfType<EditableTextState>()!;
        void expectVisibleCaret() {
          final render = editable.renderEditable;
          final caret = render.getLocalRectForCaret(content.selection.extent);
          // macOS paints the first-line cursor slightly above the text origin.
          // Its center must be visible, even when scrolling clamps at zero.
          expect(caret.center.dy, inInclusiveRange(0, render.size.height));
        }

        content.selection = const TextSelection.collapsed(offset: 4);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: original.replaceRange(4, 4, 'A'),
            selection: const TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();
        final firstEdit = content.text;
        content.selection = TextSelection.collapsed(offset: firstEdit.length);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '$firstEdit\nLast edit',
            selection: TextSelection.collapsed(offset: firstEdit.length + 10),
          ),
        );
        await tester.pumpAndSettle();
        expect(editable.renderEditable.offset.pixels, greaterThan(500));
        await _undo(tester);
        await tester.tap(_icon('撤销 ⌘Z'));
        await tester.pumpAndSettle();
        expect(content.text, original);
        expect(content.selection.extentOffset, 4);
        expectVisibleCaret();
        await _undo(tester, redo: true);
        await tester.tap(_icon('重做 ⇧⌘Z'));
        await tester.pumpAndSettle();
        expect(content.text, '$firstEdit\nLast edit');
        expectVisibleCaret();
        native.expectNoForumWrites();
        await _clean(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '$kind formatting reveals an offscreen selection without locking later scrolling',
      (tester) async {
        final original = List.generate(90, (i) => 'Paragraph $i').join('\n');
        final native = _TypingNative()..content = original;
        final state = await _mount(tester, native, kind);
        final content = _content(tester);
        final editable = _body(tester).focusNode!.context!
            .findAncestorStateOfType<EditableTextState>()!;
        editable.bringIntoView(content.selection.extent);
        await tester.pumpAndSettle();
        final bottom = editable.renderEditable.offset.pixels;
        content.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
        await tester.pump();
        expect(
          editable.renderEditable
              .getLocalRectForCaret(content.selection.extent)
              .bottom,
          lessThan(0),
        );
        await _key(
          tester,
          LogicalKeyboardKey.keyB,
          modifiers: [LogicalKeyboardKey.metaLeft],
        );
        await tester.pumpAndSettle();
        expect(content.text, startsWith('**Paragraph** 0'));
        final caret = editable.renderEditable.getLocalRectForCaret(
          content.selection.extent,
        );
        expect(
          caret.center.dy,
          inInclusiveRange(0, editable.renderEditable.size.height),
        );
        editable.renderEditable.offset.jumpTo(bottom);
        await tester.pumpAndSettle();
        expect(editable.renderEditable.offset.pixels, closeTo(bottom, 1));
        native.expectNoForumWrites();
        await _clean(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '$kind routes real Enter and Tab into separate undo transactions',
      (tester) async {
        final native = _TypingNative();
        final state = await _mount(tester, native, kind);
        final content = _content(tester);
        await _key(tester, LogicalKeyboardKey.enter);
        expect(content.text, '- one\n- ');
        expect(content.selection.extentOffset, content.text.length);
        // Platform typing remains an ordinary transaction between commands.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '- one\n- two',
            selection: TextSelection.collapsed(offset: 11),
          ),
        );
        await tester.pump();
        await _key(tester, LogicalKeyboardKey.tab);
        expect(content.text, '- one\n    - two');
        expect(_body(tester).focusNode!.hasFocus, true);
        await _undo(tester);
        expect(content.text, '- one\n- two');
        await _undo(tester);
        expect(content.text, '- one\n- ');
        await _undo(tester);
        expect(content.text, '- one');
        await _undo(tester, redo: true);
        await _undo(tester, redo: true);
        await _undo(tester, redo: true);
        expect(content.text, '- one\n    - two');
        await _key(
          tester,
          LogicalKeyboardKey.tab,
          modifiers: [LogicalKeyboardKey.shiftLeft],
        );
        expect(content.text, '- one\n- two');
        native.expectNoForumWrites();
        await _clean(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    if (kind == 'reply') {
      testWidgets(
        '$kind numpad Enter continues and exits lists without duplicate input actions',
        (tester) async {
          final native = _TypingNative()..content = '9. item';
          final state = await _mount(tester, native, kind);
          final content = _content(tester);
          await _key(tester, LogicalKeyboardKey.numpadEnter);
          expect(content.text, '9. item\n10. ');
          await tester.testTextInput.receiveAction(TextInputAction.newline);
          await tester.pump();
          expect(content.text, '9. item\n10. ');
          await _key(tester, LogicalKeyboardKey.enter);
          expect(content.text, '9. item\n');
          await _key(tester, LogicalKeyboardKey.enter);
          expect(content.text, '9. item\n');
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '9. item\n\n',
              selection: TextSelection.collapsed(offset: 9),
            ),
          );
          await tester.testTextInput.receiveAction(TextInputAction.newline);
          expect(content.text, '9. item\n\n');
          expect(_body(tester).focusNode!.hasFocus, true);
          native.expectNoForumWrites();
          await _clean(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );

      testWidgets(
        '$kind multi-line Tab and Shift Tab preserve reversed selection and body focus',
        (tester) async {
          final native = _TypingNative()..content = 'one\ntwo\nthree';
          final state = await _mount(tester, native, kind);
          final content = _content(tester);
          const selection = TextSelection(
            baseOffset: 7,
            extentOffset: 0,
            isDirectional: true,
          );
          content.selection = selection;
          await _key(tester, LogicalKeyboardKey.tab);
          expect(content.text, '    one\n    two\nthree');
          expect(
            content.selection.baseOffset,
            greaterThan(content.selection.extentOffset),
          );
          await _key(
            tester,
            LogicalKeyboardKey.tab,
            modifiers: [LogicalKeyboardKey.shiftLeft],
          );
          expect(content.text, 'one\ntwo\nthree');
          expect(content.selection, selection);
          final before = content.value;
          await _key(
            tester,
            LogicalKeyboardKey.tab,
            modifiers: [LogicalKeyboardKey.shiftLeft],
          );
          expect(content.value, before);
          expect(_body(tester).focusNode!.hasFocus, true);
          native.expectNoForumWrites();
          await _clean(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );

      testWidgets(
        '$kind active composition leaves structural keys and selection to the IME',
        (tester) async {
          final native = _TypingNative()..content = '- 拼音';
          final state = await _mount(tester, native, kind);
          final content = _content(tester);
          const composing = TextEditingValue(
            text: '- 拼音',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 2, end: 4),
          );
          for (final (key, shift) in [
            (LogicalKeyboardKey.enter, false),
            (LogicalKeyboardKey.numpadEnter, false),
            (LogicalKeyboardKey.tab, false),
            (LogicalKeyboardKey.tab, true),
          ]) {
            _body(tester).focusNode!.requestFocus();
            tester.testTextInput.updateEditingValue(composing);
            await tester.pump();
            final description = '${shift ? 'Shift+' : ''}${key.keyLabel}';
            expect(content.value, composing, reason: 'Before $description');
            // tester.sendKeyEvent adds a fake macOS native selector after an
            // unhandled event. That simulator sends insertTab even while an
            // IME composition is active. Dispatch through the public system
            // channel simulator directly here, then model the IME's commit
            // separately below. False confirms Flutter leaves the key to IME.
            if (shift) {
              await KeyEventSimulator.simulateKeyDownEvent(
                LogicalKeyboardKey.shiftLeft,
              );
            }
            try {
              final handled = await KeyEventSimulator.simulateKeyDownEvent(key);
              await KeyEventSimulator.simulateKeyUpEvent(key);
              expect(
                handled,
                false,
                reason: '$description must reach platform IME',
              );
            } finally {
              if (shift) {
                await KeyEventSimulator.simulateKeyUpEvent(
                  LogicalKeyboardKey.shiftLeft,
                );
              }
            }
            await tester.pump();
            expect(
              content.value,
              composing,
              reason: 'IME value after $description',
            );
            expect(
              _body(tester).focusNode!.hasFocus,
              true,
              reason: 'IME focus after $description',
            );
            expect(find.byType(DeskDialog), findsNothing);
          }
          tester.testTextInput.updateEditingValue(
            composing.copyWith(composing: TextRange.empty),
          );
          await tester.pump();
          await _key(tester, LogicalKeyboardKey.enter);
          expect(content.text, '- 拼音\n- ');
          native.expectNoForumWrites();
          await _clean(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );

      testWidgets(
        '$kind account invalidation and media busy state prevent structural edits',
        (tester) async {
          final native = _TypingNative();
          final state = await _mount(tester, native, kind);
          final content = _content(tester);
          final original = content.value;
          final media = tester
              .widget<ComposerMediaTools>(find.byType(ComposerMediaTools))
              .controller;
          final gate = Completer<void>();
          final waiting = media.manageSettings(
            presentSettings: () => gate.future,
          );
          await tester.pump();
          expect(media.busy, true);
          await _key(tester, LogicalKeyboardKey.enter);
          await _key(tester, LogicalKeyboardKey.tab);
          expect(content.value, original);
          gate.complete();
          await waiting;
          await tester.pump();
          native.accessRevision++;
          state.showMessage('Fixture account invalidation');
          await tester.pump();
          await _key(tester, LogicalKeyboardKey.enter);
          await _key(tester, LogicalKeyboardKey.tab);
          expect(content.value, original);
          expect(find.byType(DeskDialog), findsNothing);
          native.expectNoForumWrites();
          await _clean(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }

  for (final kind in ['discussion', 'reply']) {
    testWidgets('$kind send preferences take priority over list continuation', (
      tester,
    ) async {
      for (final preference in ['commandReturn', 'returnKey', 'buttonOnly']) {
        final native = _TypingNative();
        final state = await _mount(
          tester,
          native,
          kind,
          preference: preference,
        );
        final content = _content(tester);
        if (preference == 'buttonOnly') {
          await _key(
            tester,
            LogicalKeyboardKey.enter,
            modifiers: [LogicalKeyboardKey.metaLeft],
          );
          expect(content.text, '- one');
          expect(find.byType(DeskDialog), findsNothing);
          await _key(tester, LogicalKeyboardKey.enter);
          expect(content.text, '- one\n- ');
        } else {
          await _key(
            tester,
            preference == 'returnKey'
                ? LogicalKeyboardKey.numpadEnter
                : LogicalKeyboardKey.enter,
            modifiers: preference == 'commandReturn'
                ? [LogicalKeyboardKey.metaLeft]
                : [],
          );
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.byType(DeskDialog), findsOneWidget);
          // The async draft flush can mount this route during the first pump;
          // give its entrance a frame to start and a bounded time to finish.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(content.text, '- one');
          native.expectNoForumWrites();
          await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
          await tester.pump();
          // The Cupertino spring can outlive its nominal 350 ms. After cancel,
          // sending has ended, so bounded settling no longer waits on a spinner.
          await tester.pumpAndSettle(
            const Duration(milliseconds: 50),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 2),
          );
          expect(find.byType(DeskDialog), findsNothing);
          _body(tester).focusNode!.requestFocus();
          await tester.pump();
          if (preference == 'commandReturn') {
            await _key(tester, LogicalKeyboardKey.enter);
            expect(content.text, '- one\n- ');
          } else {
            await _key(
              tester,
              LogicalKeyboardKey.enter,
              modifiers: [LogicalKeyboardKey.shiftLeft],
            );
            expect(content.text, '- one');
            expect(find.byType(DeskDialog), findsNothing);
          }
        }
        native.expectNoForumWrites();
        await _clean(tester, state);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets(
    'keyboard history button reveals the edit without stealing its focus',
    (tester) async {
      final original = List.generate(90, (i) => 'Paragraph $i').join('\n');
      final native = _TypingNative()..content = original;
      final state = await _mount(tester, native, 'reply');
      final content = _content(tester);
      final editable = _body(tester).focusNode!.context!
          .findAncestorStateOfType<EditableTextState>()!;
      final history = tester
          .widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls))
          .history;
      for (final letter in ['A', 'B']) {
        content.selection = const TextSelection.collapsed(offset: 4);
        history.execute(
          (value) => value.copyWith(
            text: value.text.replaceRange(4, 4, letter),
            selection: const TextSelection.collapsed(offset: 5),
          ),
        );
      }
      await tester.pump();
      editable.bringIntoView(TextPosition(offset: content.text.length));
      await tester.pumpAndSettle();
      final undoIcon = find.descendant(
        of: _icon('撤销 ⌘Z'),
        matching: find.byType(Icon),
      );
      final buttonFocus = Focus.of(tester.element(undoIcon));
      buttonFocus.requestFocus();
      await tester.pump();
      expect(_body(tester).focusNode!.hasFocus, false);
      await _key(tester, LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(content.text, original.replaceRange(4, 4, 'A'));
      expect(buttonFocus.hasFocus, true);
      expect(
        editable.renderEditable
            .getLocalRectForCaret(content.selection.extent)
            .center
            .dy,
        inInclusiveRange(0, editable.renderEditable.size.height),
      );
      // A second activation exhausts undo and disables that same button. Its
      // resulting focus change must not prevent revealing the final edit.
      editable.bringIntoView(TextPosition(offset: content.text.length));
      await tester.pumpAndSettle();
      await _key(tester, LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(content.text, original);
      expect(
        editable.renderEditable
            .getLocalRectForCaret(content.selection.extent)
            .center
            .dy,
        inInclusiveRange(0, editable.renderEditable.size.height),
      );
      native.expectNoForumWrites();
      await _clean(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('a covered route cancels a pending explicit caret reveal', (
    tester,
  ) async {
    final original = List.generate(90, (i) => 'Paragraph $i').join('\n');
    final native = _TypingNative()..content = original;
    final state = await _mount(tester, native, 'reply');
    final content = _content(tester);
    final editable = _body(tester).focusNode!.context!
        .findAncestorStateOfType<EditableTextState>()!;
    editable.bringIntoView(content.selection.extent);
    await tester.pumpAndSettle();
    final bottom = editable.renderEditable.offset.pixels;
    content.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
    final toolbar = tester.widget<MarkdownToolbar>(
      find.byType(MarkdownToolbar),
    );
    toolbar.onCommand(MarkdownCommand.bold);
    final navigator = Navigator.of(tester.element(_bodyField));
    unawaited(
      navigator.push<void>(
        CupertinoPageRoute(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Covered')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(content.text, startsWith('**Paragraph** 0'));
    expect(editable.renderEditable.offset.pixels, closeTo(bottom, 1));
    navigator.pop();
    await tester.pumpAndSettle();
    native.expectNoForumWrites();
    await _clean(tester, state);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'title, help dialog and preview focus never edit the body structurally',
    (tester) async {
      final native = _TypingNative()..title = '- title';
      final state = await _mount(tester, native, 'discussion');
      final content = _content(tester);
      final before = content.value;
      await tester.tap(_titleField);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(
        tester.widget<CupertinoTextField>(_titleField).controller!.text,
        '- title',
      );
      expect(content.value, before);
      _body(tester).focusNode!.requestFocus();
      await tester.pump();
      await tester.tap(_icon('Markdown 帮助'));
      await tester.pumpAndSettle();
      expect(find.byType(DeskDialog), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.tab);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(content.value, before);
      await tester.pumpAndSettle();
      expect(find.byType(DeskDialog), findsNothing);
      await tester.tap(find.text('预览').first);
      await tester.pumpAndSettle();
      expect(_body(tester).focusNode!.hasFocus, false);
      await _key(tester, LogicalKeyboardKey.tab);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(content.text, before.text);
      expect(content.selection.baseOffset, before.selection.baseOffset);
      expect(content.selection.extentOffset, before.selection.extentOffset);
      expect(content.value.composing, before.composing);
      native.expectNoForumWrites();
      await _clean(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'modifier and repeat routing preserves platform input and never repeats sending',
    (tester) async {
      final native = _TypingNative()..title = '';
      final state = await _mount(
        tester,
        native,
        'discussion',
        preference: 'returnKey',
      );
      final content = _content(tester);
      // Missing title prevents submission. Repeated Return still must not fall
      // through into list continuation or open repeated confirmations.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(content.text, '- one');
      expect(find.byType(DeskDialog), findsNothing);
      for (final modifier in [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ]) {
        await _key(tester, LogicalKeyboardKey.tab, modifiers: [modifier]);
        expect(content.text, '- one');
      }
      await _key(
        tester,
        LogicalKeyboardKey.enter,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      expect(content.text, '- one');
      // Tab repeats are structural edits, unlike repeated send Return.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(content.text, '        - one');
      await _undo(tester);
      expect(content.text, '    - one');
      await _undo(tester);
      expect(content.text, '- one');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- one A',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await _key(
        tester,
        LogicalKeyboardKey.tab,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- one AB',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await _undo(tester);
      expect(
        content.text,
        '- one',
        reason: 'No-op outdent must not split ordinary typing history.',
      );
      native.expectNoForumWrites();
      await _clean(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'inline continuation reveals the new caret in a long body and undoes once',
    (tester) async {
      final original = List.generate(90, (index) => '- row $index').join('\n');
      final native = _TypingNative()..content = original;
      final state = await _mount(tester, native, 'inline');
      final content = _content(tester);
      final editable = _body(tester).focusNode!.context!
          .findAncestorStateOfType<EditableTextState>();
      expect(editable, isNotNull);
      expect(identical(editable!.widget.controller, content), true);
      editable.bringIntoView(content.selection.extent);
      await tester.pumpAndSettle();
      final previousOffset = editable.renderEditable.offset.pixels;
      await _key(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(content.text, '$original\n- ');
      final render = editable.renderEditable;
      final caret = render.getLocalRectForCaret(content.selection.extent);
      expect(render.offset.pixels, greaterThan(previousOffset));
      expect(caret.top, greaterThanOrEqualTo(-1));
      expect(caret.bottom, lessThanOrEqualTo(render.size.height + 1));
      await _undo(tester);
      expect(content.text, original);
      expect(tester.widget<DeskIcon>(_icon('撤销 ⌘Z')).onTap, isNull);
      native.expectNoForumWrites();
      await _clean(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
