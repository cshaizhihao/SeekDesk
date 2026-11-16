import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_preview.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/composer_image_sizing_controller.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _image = 'https://example.invalid/draft.png';
const _body = 'Original ![image]($_image)';

class _SizingNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  String content = _body, title = 'Draft title';
  List<JsonMap> sizes = [
    {'url': _image, 'ratio': 0.5, 'previewWidth': 800},
  ];
  bool failSize = false;
  Completer<void>? sizeGate;
  JsonMap get snapshot => {
    'title': title,
    'content': content,
    'accessRevision': accessRevision,
    'imageURLs': content.contains(_image) ? [_image] : <String>[],
    'imageSizing': sizes,
    'topicID': '17',
    'floor': 0,
    'editToken': 'memory-sizing-editor',
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
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    if (method == 'images.draftReferences') {
      final text = stringValue(args['content']);
      return {
        'content': text,
        'imageURLs': text.contains(_image) ? [_image] : <String>[],
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
      content = stringValue(args['content'], content);
      title = stringValue(args['title'], title);
      return snapshot;
    }
    if (const {
      'discussion.setImageSize',
      'reader.setReplyImageSize',
      'reader.edit.setImageSize',
    }.contains(method)) {
      if (sizeGate case final gate?) await gate.future;
      if (failSize) {
        throw const NativeFailure('fixture_failure', 'Memory save failed');
      }
      if (args['expectedContent'] != content) {
        throw const NativeFailure(
          'stale_image_draft',
          'Memory document changed',
        );
      }
      final ratio = numberValue(args['ratio']);
      sizes = ratio == 1
          ? []
          : [
              {
                'url': args['url'],
                'ratio': ratio,
                'previewWidth': args['previewWidth'],
              },
            ];
      return snapshot;
    }
    if (method == 'reader.discardReplyDraft') {
      content = '';
      sizes = [];
      return snapshot;
    }
    // There is no fallback to a platform channel or real forum operation.
    throw NativeFailure('fixture_only', 'Unsupported memory call $method');
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _field => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);

Future<ComposerImageSizingController> _mount(
  WidgetTester tester,
  AppState state,
  String kind,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  final Widget screen = switch (kind) {
    'inline' => InlineEditScreen(
      state: state,
      topicID: '17',
      floor: 0,
      url: 'https://www.nodeseek.com/post-17-1',
    ),
    'reply' => ComposerScreen(
      state: state,
      topicID: '17',
      url: 'https://www.nodeseek.com/post-17-1',
    ),
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
  final viewport = tester.widget<ComposerContentViewport>(
    find.byType(ComposerContentViewport),
  );
  return (viewport.preview as ComposerMarkdownPreview).imageSizing!;
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
  await tester.binding.setSurfaceSize(null);
}

void main() {
  for (final kind in ['discussion', 'reply', 'inline']) {
    testWidgets(
      '$kind restores native sizes and saves current text before resetting one image',
      (tester) async {
        final native = _SizingNative();
        final activeState = AppState(client: native);
        final sizing = await _mount(tester, activeState, kind);
        expect(sizing.sizeFor(_image).ratio, 0.5);
        expect(sizing.stage(_image, 1, 800), true);
        await tester.enterText(_field, 'Latest ![image]($_image)');
        expect(await sizing.flush(), true);
        await tester.pump();
        final patch = native.calls.lastWhere(
          (call) =>
              call.$1.endsWith('setImageSize') ||
              call.$1 == 'reader.setReplyImageSize',
        );
        expect(patch.$2['url'], _image);
        expect(patch.$2['expectedContent'], 'Latest ![image]($_image)');
        expect(patch.$2['ratio'], 1);
        if (kind == 'inline') {
          expect(patch.$2['editToken'], 'memory-sizing-editor');
        }
        expect(native.sizes, isEmpty);
        expect(
          tester.widget<CupertinoTextField>(_field).controller!.text,
          'Latest ![image]($_image)',
        );
        expect(sizing.hasPendingChanges, false);
        expect(
          native.calls.any(
            (call) => const {
              'discussion.publish',
              'reader.sendReply',
              'reader.edit.save',
              'system.chooseImage',
            }.contains(call.$1),
          ),
          false,
        );
        await _cleanup(tester, activeState);
      },
    );
  }

  testWidgets(
    'failed size persistence prevents reply confirmation and survives retry',
    (tester) async {
      final native = _SizingNative()..failSize = true;
      final state = AppState(client: native);
      final sizing = await _mount(tester, state, 'reply');
      expect(sizing.stage(_image, 0.25, 800), true);
      await tester.tap(_button('发送回复'));
      await tester.pumpAndSettle();
      expect(find.byType(DeskDialog), findsNothing);
      expect(sizing.hasPendingChanges, true);
      expect(
        native.calls.where((call) => call.$1 == 'reader.sendReply'),
        isEmpty,
      );
      native.failSize = false;
      expect(await sizing.flush(), true);
      expect(native.sizes.single['ratio'], 0.25);
      await _cleanup(tester, state);
    },
  );

  testWidgets(
    'in-flight image save disables closing and blocks the app draft flusher',
    (tester) async {
      final native = _SizingNative()..sizeGate = Completer<void>();
      final state = AppState(client: native);
      final sizing = await _mount(tester, state, 'reply');
      sizing.stage(_image, 0.25, 800);
      final saving = sizing.flush();
      await tester.pump();
      expect(sizing.busy, true);
      expect(tester.widget<DeskButton>(_button('保存并关闭')).onTap, isNull);
      expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNull);
      expect(await state.flushDrafts(), false);
      native.sizeGate!.complete();
      expect(await saving, true);
      await tester.pump();
      expect(await state.flushDrafts(), true);
      await _cleanup(tester, state);
    },
  );

  testWidgets('explicit reply discard uses the metadata-clearing method', (
    tester,
  ) async {
    final native = _SizingNative();
    final activeState = AppState(client: native);
    await _mount(tester, activeState, 'reply');
    await tester.tap(_button('放弃编辑'));
    await tester.pump();
    await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
    await tester.pumpAndSettle();
    expect(
      native.calls
          .where((call) => call.$1 == 'reader.discardReplyDraft')
          .single
          .$2['confirmed'],
      true,
    );
    expect(native.sizes, isEmpty);
    await _cleanup(tester, activeState);
  });
}
