import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/draft_sticker_image.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _Native extends NativeClient {
  final calls = <String>[];
  String content = 'seed';
  JsonMap get snapshot => {
    'title': 'Local fixture',
    'content': content,
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
    'topicID': '17',
    'floor': 0,
    'editToken': 'sticker-editor',
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
    calls.add(method);
    switch (method) {
      case 'stickers.list':
        return {
          'packs': [
            {
              'id': 'ac',
              'title': 'AC',
              'items': [
                {
                  'id': 'ac01',
                  'label': 'AC 01',
                  'url':
                      'https://www.nodeseek.com/static/image/sticker/ac/01.png',
                  'insertion': ' :ac01: ',
                },
              ],
            },
          ],
        };
      case 'stickers.custom.list':
        return {
          'groups': [
            {
              'id': 'saved',
              'name': '我的收藏',
              'items': [
                {'id': 'cat.gif', 'label': '我的收藏 1'},
              ],
            },
          ],
        };
      case 'images.keyStatus':
        return {'configured': true};
      case 'stickers.custom.upload':
        return {'url': 'https://images.example/cat.gif'};
      case 'stickers.custom.thumbnail':
      case 'images.load':
        return {
          'bytes': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          'width': 1,
          'height': 1,
        };
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
        throw StateError('Unexpected service: $method');
    }
  }
}

void main() {
  Future<void> pumpPicker(WidgetTester tester) async {
    // A nonopaque dialog keeps the underlying editor's media-busy indicator
    // ticking. Advance its finite route/spring transition without waiting for
    // that deliberately ongoing activity to become idle before selection.
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final kind in ['discussion', 'reply', 'inline']) {
    for (final custom in [false, true]) {
      testWidgets(
        '$kind ${custom ? 'custom' : 'official'} sticker keeps compact preview and one undo',
        (tester) async {
          final native = _Native();
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
            GlassAdaptiveScope(
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: CupertinoApp(home: editor),
            ),
          );
          await tester.pumpAndSettle();
          final field = tester.widget<CupertinoTextField>(
            find.byWidgetPredicate((w) => w is CupertinoTextField && w.expands),
          );
          final content = field.controller!;
          field.focusNode!.requestFocus();
          await tester.pump();
          content.selection = TextSelection.collapsed(
            offset: content.text.length,
          );
          final before = content.value;
          await tester.tap(
            find.byWidgetPredicate((w) => w is DeskButton && w.label == '表情'),
          );
          await pumpPicker(tester);
          if (custom) {
            await tester.tap(find.text('我的收藏').first);
            await pumpPicker(tester);
          }
          await tester.tap(
            find.byKey(
              ValueKey(
                custom
                    ? 'custom-sticker-saved-cat.gif'
                    : 'official-sticker-ac01',
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            content.text,
            custom
                ? 'seed![表情](<https://images.example/cat.gif>)'
                : 'seed :ac01: ',
          );
          expect(find.text('表情预览'), custom ? findsNothing : findsOneWidget);
          expect(
            find.byType(DraftStickerImage),
            custom ? findsNothing : findsOneWidget,
          );
          expect(
            native.calls.where((m) => m == 'stickers.custom.upload'),
            hasLength(custom ? 1 : 0),
          );
          final inserted = content.value;
          for (final mode in ['对照', '预览']) {
            await tester.tap(find.text(mode).first);
            await tester.pumpAndSettle();
            expect(find.text('表情预览'), findsNothing);
            expect(find.byType(DraftStickerImage), findsOneWidget);
            final image = tester.widget<DraftStickerImage>(
              find.byType(DraftStickerImage),
            );
            expect(image.size, 48);
            expect(find.byType(NativeForumImage), findsNothing);
            expect(content.value, inserted);
          }
          await tester.tap(find.text('编辑').first);
          await tester.pumpAndSettle();
          field.focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pumpAndSettle();
          expect(content.value, before);
          expect(find.text('表情预览'), findsNothing);
          expect(
            native.calls.where(
              (m) => {
                'discussion.publish',
                'reader.sendReply',
                'reader.edit.save',
                'images.uploadClipboardSnapshot',
                'system.chooseImage',
              }.contains(m),
            ),
            isEmpty,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          state.dispose();
          await tester.binding.setSurfaceSize(null);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }
}
