import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _ClipboardNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  String content = 'before selected after';
  JsonMap capture = {'kind': 'text', 'text': 'pasted'};
  Completer<JsonMap>? upload;

  JsonMap get snapshot => {
    'title': 'Local clipboard fixture',
    'content': content,
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
    'topicID': '17',
    'floor': 0,
    'editToken': 'clipboard-editor',
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
    switch (method) {
      case 'system.captureComposerPaste':
        return capture;
      case 'images.keyStatus':
        return {'configured': true};
      case 'images.uploadClipboardSnapshot':
        return upload!.future;
      case 'images.releaseClipboardSnapshot':
        return {'released': true};
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'imageURLs': <String>[],
          'accessRevision': accessRevision,
        };
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
      case 'reader.replyDraft':
      case 'reader.edit.begin':
        return snapshot;
      case 'discussion.updateDraft':
      case 'reader.updateReplyDraft':
      case 'reader.edit.update':
        content = stringValue(arguments['content'], content);
        return snapshot;
      default:
        // No platform fallback: an unexpected write never reaches a service.
        throw NativeFailure('fixture_only', 'Unsupported clipboard fixture');
    }
  }
}

Finder get _bodyFinder => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
  skipOffstage: false,
);
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

void main() {
  for (final kind in ['discussion', 'reply', 'inline']) {
    testWidgets(
      '$kind pastes text and one image through its real body action',
      (tester) async {
        final native = _ClipboardNative();
        final state = AppState(client: native);
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        final Widget editor = switch (kind) {
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
              child: editor,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<CupertinoTextField>(_bodyFinder);
        final content = field.controller!;
        final media = tester
            .widget<ComposerMediaTools>(find.byType(ComposerMediaTools))
            .controller;
        field.focusNode!.requestFocus();
        await tester.pump();
        content.selection = const TextSelection(
          baseOffset: 7,
          extentOffset: 15,
        );
        await _shortcut(tester, LogicalKeyboardKey.keyV);
        await tester.pump();
        expect(content.text, 'before pasted after');
        expect(
          native.calls.where((call) => call.$1 == 'images.keyStatus'),
          isEmpty,
        );
        await _shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(content.text, 'before selected after');

        native.capture = {
          'kind': 'image',
          'token': 'local-image-token',
          'byteCount': 20,
          'mime': 'image/png',
        };
        native.upload = Completer<JsonMap>();
        await _shortcut(tester, LogicalKeyboardKey.keyV);
        await tester.pump();
        expect(media.busy, true);
        expect(await state.flushDrafts(), false);
        final submit = kind == 'inline'
            ? '保存修改'
            : kind == 'reply'
            ? '发送回复'
            : '发布帖子';
        expect(tester.widget<DeskButton>(_button(submit)).onTap, isNull);
        await _shortcut(tester, LogicalKeyboardKey.keyV);
        expect(
          native.calls.where(
            (call) => call.$1 == 'images.uploadClipboardSnapshot',
          ),
          hasLength(1),
        );
        await tester.tap(find.text('预览').first);
        await tester.pump();
        expect(field.focusNode!.hasFocus, false);
        native.upload!.complete({
          'url': 'https://example.invalid/paste.png',
          'markdown': '<uploaded-image>',
        });
        await tester.pump();
        await tester.pump();
        expect(content.text, 'before selected<uploaded-image> after');
        expect(
          field.focusNode!.hasFocus,
          false,
          reason: 'Image completion must not steal focus from preview.',
        );
        expect(media.busy, false);
        expect(
          native.calls.where(
            (call) => call.$1 == 'images.releaseClipboardSnapshot',
          ),
          hasLength(1),
        );
        await tester.tap(find.text('编辑').first);
        await tester.pump();
        await _shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(content.text, 'before selected after');
        expect(
          native.calls.where(
            (call) => const {
              'discussion.publish',
              'reader.sendReply',
              'reader.edit.save',
              'system.chooseImage',
            }.contains(call.$1),
          ),
          isEmpty,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
        await tester.binding.setSurfaceSize(null);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'long text paste reveals its final caret and remains one undo transaction',
    (tester) async {
      final original = List.generate(
        90,
        (index) => 'Original paragraph $index',
      ).join('\n');
      final pasted = List.generate(
        12,
        (index) => '\nPasted paragraph $index',
      ).join();
      final native = _ClipboardNative()
        ..content = original
        ..capture = {'kind': 'text', 'text': pasted};
      final state = AppState(client: native);
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      await tester.pumpWidget(
        CupertinoApp(
          home: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: ComposerScreen(state: state, topicID: '17'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<CupertinoTextField>(_bodyFinder);
      final content = field.controller!;
      field.focusNode!.requestFocus();
      content.selection = TextSelection.collapsed(offset: content.text.length);
      await tester.pump();
      final editable = field.focusNode!.context!
          .findAncestorStateOfType<EditableTextState>()!;
      editable.bringIntoView(content.selection.extent);
      await tester.pumpAndSettle();
      final previousOffset = editable.renderEditable.offset.pixels;
      final before = content.value;
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(content.text, '$original$pasted');
      final render = editable.renderEditable;
      final caret = render.getLocalRectForCaret(content.selection.extent);
      expect(render.offset.pixels, greaterThan(previousOffset));
      expect(caret.top, greaterThanOrEqualTo(-1));
      expect(caret.bottom, lessThanOrEqualTo(render.size.height + 1));
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(content.value, before);
      final undo = find.byWidgetPredicate(
        (widget) => widget is DeskIcon && widget.label == '撤销 ⌘Z',
      );
      expect(tester.widget<DeskIcon>(undo).onTap, isNull);
      expect(
        native.calls.where((call) => call.$1 == 'system.captureComposerPaste'),
        hasLength(1),
      );
      expect(
        native.calls.where(
          (call) => const {
            'images.keyStatus',
            'images.uploadClipboardSnapshot',
            'discussion.publish',
            'reader.sendReply',
            'reader.edit.save',
          }.contains(call.$1),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
