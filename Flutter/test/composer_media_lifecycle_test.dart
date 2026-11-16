import 'dart:async';
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
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';
import 'package:seekdesk_flutter/widgets/node_image_settings.dart';

const _imageMarkdown = '![fixture](https://example.invalid/fixture.png)';
const _initialBody = 'Fixture body';

enum _EditorKind {
  discussion,
  reply,
  inline;

  Widget screen(AppState state) => switch (this) {
    discussion => ComposerScreen(state: state),
    reply => ComposerScreen(
      state: state,
      topicID: '17',
      url: 'https://www.nodeseek.com/post-17-1',
    ),
    inline => InlineEditScreen(
      state: state,
      topicID: '17',
      url: 'https://www.nodeseek.com/post-17-1',
      floor: 0,
    ),
  };

  String get submit => switch (this) {
    discussion => '发布帖子',
    reply => '发送回复',
    inline => '保存修改',
  };

  List<String> get closingButtons =>
      this == inline ? const ['取消编辑'] : const ['放弃编辑', '保存并关闭'];

  String get draftMethod => switch (this) {
    discussion => 'discussion.updateDraft',
    reply => 'reader.updateReplyDraft',
    inline => 'reader.edit.update',
  };
}

/// Every operation stays in this memory fake, including previews' image reads.
/// No inherited NativeClient method can upload or submit to the real forum.
class _MediaNativeFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function()? keyStatus;
  Future<JsonMap> Function()? chooseImage;
  JsonMap Function(String, JsonMap)? readEditor;
  String? editToken;
  int editGeneration = 0;

  final draft = <String, dynamic>{
    'ready': true,
    'title': 'Fixture title',
    'content': _initialBody,
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
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
      case 'reader.replyDraft':
        return readEditor?.call(method, arguments) ?? {...draft};
      case 'reader.edit.begin':
        editToken = 'media-edit-${++editGeneration}';
        return {
          ...draft,
          ...?readEditor?.call(method, arguments),
          ...editIdentity(arguments),
        };
      case 'discussion.updateDraft':
      case 'reader.updateReplyDraft':
        draft.addAll(arguments);
        return {...draft};
      case 'reader.edit.update':
        draft.addAll(arguments);
        return {...draft, ...editIdentity(arguments)};
      case 'images.keyStatus':
        return await keyStatus?.call() ?? {'configured': true};
      case 'system.chooseImage':
        return await chooseImage?.call() ?? {'markdown': _imageMarkdown};
      case 'images.load':
        return {
          'width': 1,
          'height': 1,
          'bytes': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        };
      case 'discussion.publish':
      case 'reader.sendReply':
        return {...draft, 'accepted': false, 'message': 'Fixture rejected'};
      case 'reader.edit.save':
        return {
          ...draft,
          ...editIdentity(arguments),
          'accepted': false,
          'message': 'Fixture rejected',
        };
      case 'discussion.discard':
        return {'discarded': true};
      case 'reader.edit.cancel':
        return {...editIdentity(arguments), 'ready': false, 'accepted': false};
      default:
        throw NativeFailure(
          'fixture_only',
          'Unsupported fixture call: $method',
        );
    }
  }

  JsonMap editIdentity(JsonMap arguments) => {
    'editToken': editToken,
    'topicID': arguments['topicID'],
    'floor': arguments['floor'],
    'accessRevision': accessRevision,
  };

  Iterable<(String, JsonMap)> get writes => calls.where(
    (call) => const {
      'discussion.publish',
      'reader.sendReply',
      'reader.edit.save',
      'discussion.discard',
      'reader.edit.cancel',
    }.contains(call.$1),
  );
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder _formatButton(String label) => find.byWidgetPredicate(
  (widget) => widget is MarkdownToolButton && widget.label == label,
);

Finder _bodyField({bool skipOffstage = true}) => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
  skipOffstage: skipOffstage,
);

TextEditingController _body(WidgetTester tester) => tester
    .widget<CupertinoTextField>(_bodyField(skipOffstage: false))
    .controller!;

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  _EditorKind kind,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 950));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    CupertinoApp(
      navigatorKey: navigator,
      builder: (context, child) => GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: child!,
      ),
      home: const CupertinoPageScaffold(
        child: Center(child: Text('Fixture home')),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push<void>(
      CupertinoPageRoute(
        builder: (_) => GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: kind.screen(state),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(_body(tester).text, _initialBody);
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  await tester.pump(const Duration(seconds: 6));
  expect(tester.takeException(), isNull);
}

Future<void> _startUpload(WidgetTester tester) async {
  await tester.tap(_button('上传图片'));
  await tester.pump();
}

Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in _EditorKind.values) {
    testWidgets(
      '${kind.name}: image settings remain reachable in preview without uploading or remounting the editor',
      (tester) async {
        final native = _MediaNativeFixture();
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        final editor = tester.element(_bodyField());
        expect(
          find.ancestor(
            of: _button('图床设置'),
            matching: find.byType(TextFieldTapRegion),
          ),
          findsWidgets,
        );
        await _switchMode(tester, '预览');
        expect(_button('图床设置').hitTestable(), findsOneWidget);
        final open = tester.widget<DeskButton>(_button('图床设置')).onTap!;
        await tester.tap(_button('图床设置'));
        await tester.pumpAndSettle();
        open();
        await tester.pump();
        expect(find.byType(NodeImageSettings), findsOneWidget);
        expect(
          native.calls.where((call) => call.$1 == 'images.keyStatus'),
          hasLength(1),
        );
        expect(await state.flushDrafts(), false);
        expect(
          native.calls.where((call) => call.$1 == 'system.chooseImage'),
          isEmpty,
        );
        expect(native.writes, isEmpty);
        await tester.tap(_button('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(NodeImageSettings), findsNothing);
        expect(_body(tester).text, _initialBody);
        expect(tester.element(_bodyField(skipOffstage: false)), same(editor));
        expect(_bodyField().hitTestable(), findsNothing);
        expect(await state.flushDrafts(), true);
        await _switchMode(tester, '编辑');
        expect(tester.element(_bodyField()), same(editor));
        expect(tester.widget<DeskButton>(_button('图床设置')).onTap, isNotNull);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${kind.name}: settings block stale submit, close and media callbacks while ordinary draft saving continues',
      (tester) async {
        final status = Completer<JsonMap>();
        final native = _MediaNativeFixture()..keyStatus = () => status.future;
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        await tester.enterText(_bodyField(), 'Text before opening settings');
        await tester.pump();
        final submit = tester.widget<DeskButton>(_button(kind.submit)).onTap!;
        final close = [
          for (final label in kind.closingButtons)
            tester.widget<DeskButton>(_button(label)).onTap!,
        ];
        final upload = tester.widget<DeskButton>(_button('上传图片')).onTap!;
        final sticker = tester.widget<DeskButton>(_button('表情')).onTap!;
        await tester.tap(_button('图床设置'));
        await tester.pump();
        submit();
        for (final callback in close) {
          callback();
        }
        upload();
        sticker();
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(NodeImageSettings), findsOneWidget);
        expect(find.byType(DeskDialog), findsNothing);
        expect(tester.widget<DeskButton>(_button(kind.submit)).onTap, isNull);
        for (final label in kind.closingButtons) {
          expect(tester.widget<DeskButton>(_button(label)).onTap, isNull);
        }
        expect(tester.widget<DeskButton>(_button('上传图片')).busy, false);
        expect(tester.widget<DeskButton>(_button('图床设置')).onTap, isNull);
        expect(await state.flushDrafts(), false);
        expect(native.writes, isEmpty);
        expect(
          native.calls.where(
            (call) =>
                const {'system.chooseImage', 'stickers.list'}.contains(call.$1),
          ),
          isEmpty,
        );
        final drafts = native.calls.where(
          (call) => call.$1 == kind.draftMethod,
        );
        if (kind == _EditorKind.inline) {
          expect(drafts, isEmpty);
        } else {
          expect(drafts.single.$2['content'], 'Text before opening settings');
        }
        await tester.tap(_button('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(NodeImageSettings), findsNothing);
        expect(_body(tester).text, 'Text before opening settings');
        expect(await state.flushDrafts(), kind != _EditorKind.inline);
        expect(
          tester.widget<DeskButton>(_button(kind.submit)).onTap,
          isNotNull,
        );
        status.complete({'configured': true});
        await tester.pumpAndSettle();
        expect(find.byType(NodeImageSettings), findsNothing);
        expect(_body(tester).text, 'Text before opening settings');
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${kind.name}: selection-only changes do not create an unsaved draft',
      (tester) async {
        final native = _MediaNativeFixture();
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        _body(tester).selection = const TextSelection(
          baseOffset: 1,
          extentOffset: 6,
        );
        await tester.pump(const Duration(milliseconds: 450));
        _body(tester).selection = const TextSelection.collapsed(offset: 4);
        await tester.pump(const Duration(milliseconds: 450));
        expect(await state.flushDrafts(), true);
        expect(
          native.calls.where((call) => call.$1 == kind.draftMethod),
          isEmpty,
        );
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${kind.name}: preview keeps the editor and inserts a pending image once',
      (tester) async {
        final pending = Completer<JsonMap>();
        final native = _MediaNativeFixture()
          ..chooseImage = () => pending.future;
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        final controller = _body(tester);
        controller.selection = const TextSelection(
          baseOffset: 2,
          extentOffset: 7,
        );
        final editor = tester.element(_bodyField());
        await _startUpload(tester);
        expect(
          native.calls.where((call) => call.$1 == 'system.chooseImage').length,
          1,
        );
        await _switchMode(tester, '预览');
        expect(tester.element(_bodyField(skipOffstage: false)), same(editor));
        expect(_bodyField().hitTestable(), findsNothing);
        pending.complete({'markdown': _imageMarkdown});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(controller.text, contains(_initialBody.substring(0, 7)));
        expect(controller.text, contains(_initialBody.substring(7)));
        expect(_imageMarkdown.allMatches(controller.text).length, 1);
        await _switchMode(tester, '编辑');
        expect(tester.element(_bodyField()), same(editor));
        await _switchMode(tester, '预览');
        await _switchMode(tester, '编辑');
        expect(_imageMarkdown.allMatches(controller.text).length, 1);
        expect(native.writes, isEmpty);
        if (kind != _EditorKind.inline) {
          expect(await state.flushDrafts(), true);
          final saved = native.calls
              .where((call) => call.$1 == kind.draftMethod)
              .last;
          expect(saved.$2['content'], controller.text);
        } else {
          expect(
            await state.flushDrafts(),
            false,
            reason: 'Inserted media leaves an inline edit dirty.',
          );
        }
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${kind.name}: pending media blocks stale submit callbacks, close and application flush',
      (tester) async {
        final pending = Completer<JsonMap>();
        final native = _MediaNativeFixture()
          ..chooseImage = () => pending.future;
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        await tester.enterText(_bodyField(), 'User edit');
        await tester.pump();
        final staleSubmit = tester
            .widget<DeskButton>(_button(kind.submit))
            .onTap!;
        final staleClosers = [
          for (final label in kind.closingButtons)
            tester.widget<DeskButton>(_button(label)).onTap!,
        ];
        final routeContext = tester.element(_bodyField());
        await _startUpload(tester);
        expect(tester.widget<DeskButton>(_button(kind.submit)).onTap, isNull);
        for (final label in kind.closingButtons) {
          expect(tester.widget<DeskButton>(_button(label)).onTap, isNull);
        }
        staleSubmit();
        for (final close in staleClosers) {
          close();
        }
        await tester.pump();
        expect(find.byType(DeskDialog), findsNothing);
        expect(await state.flushDrafts(), false);
        await Navigator.of(routeContext).maybePop();
        await tester.pump();
        expect(_bodyField(), findsOneWidget);
        expect(native.writes, isEmpty);
        expect(
          native.calls.where(
            (call) =>
                call.$1 == 'reader.updateReplyDraft' &&
                call.$2['content'] == '',
          ),
          isEmpty,
        );
        if (kind != _EditorKind.inline) {
          await tester.tap(_bodyField());
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(find.byType(DeskDialog), findsNothing);
          expect(native.writes, isEmpty);
        }
        pending.complete({'markdown': _imageMarkdown});
        await tester.pump();
        expect(_body(tester).text, contains(_imageMarkdown));
        expect(
          tester.widget<DeskButton>(_button(kind.submit)).onTap,
          isNotNull,
        );
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    for (final phase in ['status', 'upload']) {
      testWidgets(
        '${kind.name}: account change during $phase cannot continue or insert media',
        (tester) async {
          final pending = Completer<JsonMap>();
          final native = _MediaNativeFixture();
          if (phase == 'status') {
            native.keyStatus = () => pending.future;
          } else {
            native.chooseImage = () => pending.future;
          }
          final state = AppState(client: native);
          await _mount(tester, state, kind);
          final controller = _body(tester);
          await _startUpload(tester);
          native.accessRevision++;
          pending.complete(
            phase == 'status'
                ? {'configured': true}
                : {'markdown': _imageMarkdown},
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 450));
          expect(controller.text, _initialBody);
          expect(native.writes, isEmpty);
          if (phase == 'status') {
            expect(
              native.calls.where((call) => call.$1 == 'system.chooseImage'),
              isEmpty,
            );
          }
          expect(tester.takeException(), isNull);
          await _cleanup(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }

    testWidgets(
      '${kind.name}: a disposed editor ignores a late upload result',
      (tester) async {
        final pending = Completer<JsonMap>();
        final native = _MediaNativeFixture()
          ..chooseImage = () => pending.future;
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        await _startUpload(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        pending.complete({'markdown': _imageMarkdown});
        await tester.pump();
        expect(native.writes, isEmpty);
        expect(
          native.calls.where(
            (call) =>
                call.$2['content']?.toString().contains(_imageMarkdown) == true,
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    for (final failure in ['cancelled', 'offline']) {
      testWidgets(
        '${kind.name}: $failure upload preserves text and permits a successful retry',
        (tester) async {
          final first = Completer<JsonMap>();
          final second = Completer<JsonMap>();
          var attempts = 0;
          final native = _MediaNativeFixture()
            ..chooseImage = () =>
                attempts++ == 0 ? first.future : second.future;
          final state = AppState(client: native);
          await _mount(tester, state, kind);
          await _startUpload(tester);
          if (failure == 'cancelled') {
            first.complete({'cancelled': true});
          } else {
            first.completeError(NativeFailure(failure, 'Fixture $failure'));
          }
          await tester.pump();
          expect(_body(tester).text, _initialBody);
          final upload = tester.widget<DeskButton>(_button('上传图片'));
          expect(upload.busy, false);
          expect(upload.onTap, isNotNull);
          await _startUpload(tester);
          expect(attempts, 2);
          second.complete({'markdown': _imageMarkdown});
          await tester.pump();
          expect(_imageMarkdown.allMatches(_body(tester).text).length, 1);
          expect(native.writes, isEmpty);
          await _cleanup(tester, state);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }

  for (final variant in [
    (kind: _EditorKind.reply, changeFloor: false),
    (kind: _EditorKind.inline, changeFloor: false),
    (kind: _EditorKind.inline, changeFloor: true),
  ]) {
    final kind = variant.kind;
    testWidgets(
      '${kind.name}: rebinding ${variant.changeFloor ? 'floor' : 'topic'} rejects old media and leaves the new editor usable',
      (tester) async {
        final pending = Completer<JsonMap>();
        final nextUpload = Completer<JsonMap>();
        var uploads = 0;
        final native = _MediaNativeFixture()
          ..chooseImage = () =>
              uploads++ == 0 ? pending.future : nextUpload.future;
        native.readEditor = (_, args) => {
          ...native.draft,
          'content': args['topicID'] == '18' || args['floor'] == 1
              ? 'Other topic body'
              : _initialBody,
        };
        final state = AppState(client: native);
        final target = ValueNotifier((topic: '17', floor: 0));
        await tester.binding.setSurfaceSize(const Size(1200, 950));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          CupertinoApp(
            home: ValueListenableBuilder<({String topic, int floor})>(
              valueListenable: target,
              builder: (_, document, _) => GlassAdaptiveScope(
                minQuality: GlassQuality.minimal,
                maxQuality: GlassQuality.minimal,
                child: kind == _EditorKind.reply
                    ? ComposerScreen(
                        key: const ValueKey('rebound-editor'),
                        state: state,
                        topicID: document.topic,
                        url:
                            'https://www.nodeseek.com/post-${document.topic}-1',
                      )
                    : InlineEditScreen(
                        key: const ValueKey('rebound-editor'),
                        state: state,
                        topicID: document.topic,
                        url:
                            'https://www.nodeseek.com/post-${document.topic}-1',
                        floor: document.floor,
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final oldEditor = tester.element(_bodyField());
        await tester.enterText(_bodyField(), 'Unsaved old draft');
        await _startUpload(tester);
        target.value = variant.changeFloor
            ? (topic: '17', floor: 1)
            : (topic: '18', floor: 0);
        await tester.pump();
        await tester.pump();
        expect(tester.element(_bodyField()), isNot(same(oldEditor)));
        expect(_body(tester).text, 'Other topic body');
        pending.complete({'markdown': _imageMarkdown});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(_body(tester).text, 'Other topic body');
        expect(native.writes, isEmpty);
        if (kind == _EditorKind.reply) {
          final saves = native.calls
              .where((call) => call.$1 == 'reader.updateReplyDraft')
              .toList();
          expect(saves, hasLength(1));
          expect(saves.single.$2['topicID'], '17');
          expect(saves.single.$2['content'], 'Unsaved old draft');
        } else {
          expect(
            native.calls.where((call) => call.$1 == 'reader.edit.update'),
            isEmpty,
          );
        }
        await _startUpload(tester);
        expect(uploads, 2);
        const nextMarkdown =
            '![new fixture](https://example.invalid/new-fixture.png)';
        nextUpload.complete({'markdown': nextMarkdown});
        await tester.pump();
        expect(_body(tester).text, contains('Other topic body'));
        expect(nextMarkdown.allMatches(_body(tester).text).length, 1);
        expect(_body(tester).text, isNot(contains(_imageMarkdown)));
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
        target.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'reply editor preserves selection and undo history across preview',
    (tester) async {
      final native = _MediaNativeFixture();
      final state = AppState(client: native);
      await _mount(tester, state, _EditorKind.reply);
      await tester.enterText(_bodyField(), 'First edit');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(_bodyField(), 'Second edit');
      await tester.pump(const Duration(milliseconds: 600));
      final controller = _body(tester);
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      final editor = tester.element(_bodyField());
      await _switchMode(tester, '预览');
      expect(tester.element(_bodyField(skipOffstage: false)), same(editor));
      await _switchMode(tester, '编辑');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6),
      );
      final editable = tester.widget<EditableText>(
        find.descendant(of: _bodyField(), matching: find.byType(EditableText)),
      );
      editable.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(controller.text, 'First edit');
      expect(native.writes, isEmpty);
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final kind in [_EditorKind.reply, _EditorKind.inline]) {
    testWidgets(
      '${kind.name}: preview cannot hide an unfinished IME composition while upload waits',
      (tester) async {
        final pending = Completer<JsonMap>();
        final native = _MediaNativeFixture()
          ..chooseImage = () => pending.future;
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        await _startUpload(tester);
        await tester.showKeyboard(_bodyField());
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Draft 拼',
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 6, end: 7),
          ),
        );
        await tester.pump();
        pending.complete({'markdown': _imageMarkdown});
        await tester.pump();
        final controller = _body(tester);
        expect(controller.text, 'Draft 拼');
        expect(controller.value.composing, const TextRange(start: 6, end: 7));
        await _switchMode(tester, '预览');
        expect(_bodyField().hitTestable(), findsOneWidget);
        expect(controller.value.composing, const TextRange(start: 6, end: 7));
        expect(controller.text, 'Draft 拼');
        expect(await state.flushDrafts(), false);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Draft 拼',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();
        expect(controller.text, contains('Draft 拼'));
        expect(_imageMarkdown.allMatches(controller.text).length, 1);
        expect(await state.flushDrafts(), kind != _EditorKind.inline);
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }
  for (final kind in _EditorKind.values) {
    testWidgets(
      '${kind.name}: rapid typing, format, typing undo independently',
      (tester) async {
        final native = _MediaNativeFixture();
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        await tester.enterText(_bodyField(), 'typed');
        final controller = _body(tester);
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(_formatButton('粗体'));
        await tester.pump();
        expect(controller.text, '**typed**');
        await tester.enterText(_bodyField(), '**typed**!');
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(controller.text, '**typed**');
        expect(
          controller.selection,
          const TextSelection(baseOffset: 2, extentOffset: 7),
        );
        final undo = find.byWidgetPredicate(
          (w) => w is DeskIcon && w.label == '撤销 ⌘Z',
        );
        await tester.tap(undo);
        await tester.pump();
        expect(controller.text, 'typed');
        await tester.tap(undo);
        await tester.pump();
        expect(controller.text, _initialBody);
        final redo = find.byWidgetPredicate(
          (w) => w is DeskIcon && w.label == '重做 ⇧⌘Z',
        );
        await tester.tap(redo);
        await tester.pump();
        expect(controller.text, 'typed');
        await tester.tap(redo);
        await tester.pump();
        expect(controller.text, '**typed**');
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${kind.name}: narrow split layout retains field and unfinished IME',
      (tester) async {
        final native = _MediaNativeFixture();
        final state = AppState(client: native);
        await _mount(tester, state, kind);
        final original = tester.element(_bodyField());
        final controller = _body(tester);
        controller.selection = const TextSelection(
          baseOffset: 1,
          extentOffset: 6,
        );
        await _switchMode(tester, '对照');
        await tester.binding.setSurfaceSize(const Size(780, 540));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.element(_bodyField()), same(original));
        expect(
          controller.selection,
          const TextSelection(baseOffset: 1, extentOffset: 6),
        );
        await _switchMode(tester, '预览');
        expect(tester.takeException(), isNull);
        await _switchMode(tester, '编辑');
        expect(tester.element(_bodyField()), same(original));
        await tester.showKeyboard(_bodyField());
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '拼',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();
        expect(
          tester.widget<MarkdownToolButton>(_formatButton('粗体')).onTap,
          isNull,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(controller.value.composing, const TextRange(start: 0, end: 1));
        expect(controller.text, '拼');
        expect(native.writes, isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }
}
