// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

Finder get _composerBody => find.byKey(const ValueKey('inbox-composer-body'));

const _literalMessage =
    '**literal text** [unparsed link](https://example.invalid) `code`\n'
    'Second plain-text line.';

class _PlainMessageFixture extends NativeClient {
  final calls = <String>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add(method);
    if (method == 'images.draftReferences' &&
        args.length == 1 &&
        args['content'] == '') {
      return {
        'content': '',
        'imageURLs': <String>[],
        'accessRevision': accessRevision,
      };
    }
    if (method != 'inbox.load') {
      unexpected.add('$method $args');
      throw StateError('Plain-message fixture rejects all other requests.');
    }
    return {
      'kind': 'conversation',
      'peer': 20,
      'loading': false,
      'draft': '',
      'items': [
        {
          'text': _literalMessage,
          'markdown': false,
          'mine': false,
          'peerName': 'Local fixture',
          'date': '2026-11-14',
        },
      ],
    };
  }
}

void main() {
  testWidgets(
    'plain messages keep markdown characters and copy without an editing layer',
    (tester) async {
      final native = _PlainMessageFixture();
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn'};
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = stringValue(jsonMap(call.arguments)['text']);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoApp(
            home: CupertinoPageScaffold(
              child: InboxScreen(
                state: state,
                initialPeer: 20,
                peerName: 'Local fixture',
                standalone: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final message = find.text(_literalMessage);
      expect(message, findsOneWidget);
      expect(find.byType(InlineMarkdown), findsNothing);
      final selection = find.ancestor(
        of: message,
        matching: find.byType(ForumTextSelection),
      );
      expect(selection, findsOneWidget);
      expect(
        find.descendant(of: selection, matching: find.byType(EditableText)),
        findsNothing,
      );
      // The keyed reply body remains an editor. Contact lookup is a separate
      // input; read-only messages still have no EditableText descendants.
      expect(_composerBody, findsOneWidget);
      expect(
        find.descendant(of: _composerBody, matching: find.byType(EditableText)),
        findsOneWidget,
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: message, matching: find.byType(RichText)),
      );
      final glyph = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 2, extentOffset: 3),
          )
          .first;
      await tester.tapAt(paragraph.localToGlobal(glyph.toRect().center));
      await tester.pump();
      for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyC]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      }
      expect(clipboard, _literalMessage);
      // Mounting the empty composer also parses its local image references;
      // selecting and copying a message must cause no draft or forum writes.
      expect(native.calls, ['inbox.load', 'images.draftReferences']);
      expect(native.unexpected, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
