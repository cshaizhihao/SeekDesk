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
import 'package:seekdesk_flutter/widgets/composer_media_controller.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class ComposerNativeFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;
  String? editToken;
  int editGeneration = 0;
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    final revision = accessRevision;
    if (method == 'reader.edit.begin') {
      editToken = 'safety-edit-${++editGeneration}';
    }
    final token = editToken;
    final result = await response?.call(method, arguments) ?? {};
    if (!method.startsWith('reader.edit.')) return result;
    return {
      'editToken': token,
      'topicID': arguments['topicID'],
      'floor': arguments['floor'],
      'accessRevision': revision,
      ...result,
    };
  }
}

/// Closure tests own a local discussion draft and cannot publish or discard it.
class _CloseDraftNative extends NativeClient {
  final calls = <String>[];
  final unexpected = <String>[];
  String content = 'Original fixture draft';
  Completer<void>? pendingSave;

  JsonMap get snapshot => {
    'title': 'Fixture title',
    'content': content,
    'phase': 'ready',
    'ready': true,
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
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
        return snapshot;
      case 'discussion.updateDraft':
        final text = arguments['content'] as String;
        await pendingSave?.future;
        content = text;
        return snapshot;
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
        };
      default:
        unexpected.add(method);
        throw const NativeFailure(
          'fixture_only',
          'Unexpected close fixture call',
        );
    }
  }
}

/// These existing failure-path tests keep the media owner alive independently
/// of its toolbar, just as the full editors do.
class _MediaTestHost extends StatefulWidget {
  const _MediaTestHost({required this.state});
  final AppState state;

  @override
  State<_MediaTestHost> createState() => _MediaTestHostState();
}

class _MediaTestHostState extends State<_MediaTestHost> {
  final content = TextEditingController();
  late final ComposerMediaController media;

  @override
  void initState() {
    super.initState();
    media = ComposerMediaController(
      state: widget.state,
      content: content,
      revision: widget.state.accessRevision,
      documentIdentity: this,
      canStart: () => mounted,
    );
  }

  @override
  void dispose() {
    media.dispose();
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: media,
    builder: (context, _) => ComposerMediaTools(
      controller: media,
      onUpload: () =>
          media.upload(requestKey: () => showComposerUploadKey(context)),
      onStickers: () {},
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: child,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
  }

  Future<(NavigatorState, CupertinoPageRoute<void>)> mountComposerRoute(
    WidgetTester tester,
    AppState state,
  ) async {
    await mount(
      tester,
      const CupertinoPageScaffold(
        child: Center(child: Text('Composer closure fixture home')),
      ),
    );
    final navigator = Navigator.of(
      tester.element(find.text('Composer closure fixture home')),
    );
    final route = CupertinoPageRoute<void>(
      builder: (_) => GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: ComposerScreen(state: state),
      ),
    );
    unawaited(navigator.push(route));
    await tester.pumpAndSettle();
    return (navigator, route);
  }

  testWidgets(
    'captured standalone composer close cannot dismiss a covering route or lose its draft',
    (tester) async {
      final native = _CloseDraftNative();
      final state = AppState(client: native);
      try {
        final (navigator, editorRoute) = await mountComposerRoute(
          tester,
          state,
        );
        final originalEditor = tester.element(find.byType(ComposerScreen));
        final controller = tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
            .controller!;
        final close = tester.widget<DeskButton>(button('保存并关闭')).onTap!;
        var editorCompleted = false, coveringCompleted = false;
        unawaited(
          editorRoute.completed.then((_) {
            editorCompleted = true;
          }),
        );
        final covering = CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Newer composer fixture route')),
          ),
        );
        unawaited(
          covering.completed.then((_) {
            coveringCompleted = true;
          }),
        );
        unawaited(navigator.push(covering));
        await tester.pumpAndSettle();
        close();
        await tester.pumpAndSettle();
        expect(covering.isCurrent, true);
        expect(coveringCompleted, false);
        expect(editorRoute.isActive, true);
        expect(editorCompleted, false);
        expect(originalEditor.mounted, true);
        expect(controller.text, 'Original fixture draft');
        expect(native.content, 'Original fixture draft');
        expect(
          native.calls.where((method) => method == 'discussion.updateDraft'),
          isEmpty,
        );
        expect(native.unexpected, isEmpty);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(editorRoute.isCurrent, true);
        expect(
          tester.element(find.byType(ComposerScreen)),
          same(originalEditor),
        );
        await tester.tap(button('保存并关闭'));
        await tester.pumpAndSettle();
        expect(editorCompleted, true);
        expect(editorRoute.isActive, false);
        expect(find.text('Composer closure fixture home'), findsOneWidget);
        expect(native.content, 'Original fixture draft');
        expect(native.unexpected, isEmpty);
      } finally {
        await cleanup(tester, state);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a pending standalone composer save closes only its own route after another route covers it',
    (tester) async {
      final native = _CloseDraftNative();
      final pending = Completer<void>();
      final state = AppState(client: native);
      try {
        final (navigator, editorRoute) = await mountComposerRoute(
          tester,
          state,
        );
        var editorCompleted = false, coveringCompleted = false;
        unawaited(
          editorRoute.completed.then((_) {
            editorCompleted = true;
          }),
        );
        await tester.enterText(
          find.byType(CupertinoTextField).last,
          'Latest fixture text must survive closing',
        );
        await tester.pump();
        native.pendingSave = pending;
        await tester.tap(button('保存并关闭'));
        await tester.pump();
        expect(
          native.calls.where((method) => method == 'discussion.updateDraft'),
          hasLength(1),
        );
        expect(editorCompleted, false);
        final covering = CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Newer composer fixture route')),
          ),
        );
        unawaited(
          covering.completed.then((_) {
            coveringCompleted = true;
          }),
        );
        unawaited(navigator.push(covering));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(covering.isCurrent, true);
        pending.complete();
        await tester.pumpAndSettle();
        expect(covering.isCurrent, true);
        expect(coveringCompleted, false);
        expect(find.text('Newer composer fixture route'), findsOneWidget);
        // The user's legitimate save-and-close must still finish, targeting
        // its own route rather than silently abandoning the successful close.
        expect(editorCompleted, true);
        expect(editorRoute.isActive, false);
        expect(native.content, 'Latest fixture text must survive closing');
        expect(
          native.calls.where((method) => method == 'discussion.updateDraft'),
          hasLength(1),
        );
        expect(native.unexpected, isEmpty);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Composer closure fixture home'), findsOneWidget);
        expect(find.byType(ComposerScreen, skipOffstage: false), findsNothing);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await cleanup(tester, state);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'initial upload key dialog validates before saving a trimmed key or opening a picker',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async => switch (method) {
        'images.keyStatus' => {'configured': false},
        'images.setKey' => {'configured': true},
        'system.chooseImage' => {'cancelled': true},
        _ => throw NativeFailure(
          'fixture_only',
          'Unexpected fixture call: $method',
        ),
      };
      final state = AppState(client: native);
      await mount(
        tester,
        CupertinoPageScaffold(
          child: Center(child: _MediaTestHost(state: state)),
        ),
      );
      await tester.tap(button('上传图片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('设置 NodeImage 上传密钥'), findsOneWidget);
      await tester.tap(find.widgetWithText(DeskDialogAction, '保存'));
      await tester.pump();
      expect(find.text('请粘贴 NodeImage API 密钥。'), findsOneWidget);
      final input = tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller!;
      input.text = 'first\nsecond';
      await tester.pump();
      await tester.tap(find.widgetWithText(DeskDialogAction, '保存'));
      await tester.pump();
      expect(find.text('密钥不能包含换行，请重新复制完整的一行。'), findsOneWidget);
      expect(
        native.calls.where(
          (call) =>
              const {'images.setKey', 'system.chooseImage'}.contains(call.$1),
        ),
        isEmpty,
      );
      await tester.enterText(
        find.byType(CupertinoTextField),
        ' fixture-only-key ',
      );
      await tester.tap(find.widgetWithText(DeskDialogAction, '保存'));
      await tester.pumpAndSettle();
      expect(find.byType(DeskDialog), findsNothing);
      expect(
        native.calls.where((call) => call.$1 == 'images.setKey').single.$2,
        {'key': 'fixture-only-key'},
      );
      expect(
        native.calls.where((call) => call.$1 == 'system.chooseImage'),
        hasLength(1),
      );
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'failed draft reads cannot overwrite a draft with an empty editor',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async =>
          throw const NativeFailure('offline', 'Offline');
      final state = AppState(client: native);
      await mount(
        tester,
        ComposerScreen(
          state: state,
          topicID: '17',
          url: 'https://www.nodeseek.com/post-17-1',
        ),
      );
      expect(find.text('无法打开草稿'), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(
        native.calls.where((call) => call.$1 == 'reader.updateReplyDraft'),
        isEmpty,
      );
      await cleanup(tester, state);
    },
  );

  testWidgets('lifecycle flush saves the latest text before debounce fires', (
    tester,
  ) async {
    final native = ComposerNativeFixture();
    native.response = (method, args) async => {'content': 'Original'};
    final state = AppState(client: native);
    await mount(tester, ComposerScreen(state: state, topicID: '17'));
    await tester.enterText(find.byType(CupertinoTextField).last, 'Latest edit');
    expect(
      native.calls.where((call) => call.$1 == 'reader.updateReplyDraft'),
      isEmpty,
    );
    expect(await state.flushDrafts(), true);
    expect(
      native.calls
          .where((call) => call.$1 == 'reader.updateReplyDraft')
          .single
          .$2['content'],
      'Latest edit',
    );
    await cleanup(tester, state);
  });

  testWidgets(
    'new discussion exposes existing private rank and editable allowed ranks',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async => {
        'phase': 'ready',
        'ready': true,
        'title': 'Fixture title',
        'content': 'Fixture body',
        'rank': 255,
        'category': 'general',
        'maxRank': 3,
        'categories': [
          {'id': 'general', 'title': '常规'},
        ],
      };
      final state = AppState(client: native);
      await mount(tester, ComposerScreen(state: state));
      expect(button('阅读权限：私有'), findsOneWidget);
      await tester.tap(button('阅读权限：私有'));
      await tester.pumpAndSettle();
      expect(find.text('Lv.3 及以上'), findsOneWidget);
      expect(find.text('Lv.4 及以上'), findsNothing);
      await tester.tap(find.widgetWithText(CupertinoButton, '公开'));
      await tester.pump();
      expect(await state.flushDrafts(), true);
      expect(
        native.calls
            .where((call) => call.$1 == 'discussion.updateDraft')
            .last
            .$2['rank'],
        0,
      );
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'failed sends retain local text and require explicit confirmation',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async {
        if (method == 'reader.replyDraft') return {'content': 'Original'};
        if (method == 'reader.sendReply') {
          return {'accepted': false, 'message': 'Offline, draft retained'};
        }
        return {'content': args['content']};
      };
      final state = AppState(client: native);
      await mount(
        tester,
        ComposerScreen(
          state: state,
          topicID: '17',
          url: 'https://www.nodeseek.com/post-17-1',
        ),
      );
      await tester.enterText(
        find.byType(CupertinoTextField).last,
        'Keep this draft',
      );
      await tester.pump();
      await tester.tap(button('发送回复'));
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'reader.sendReply'),
        isEmpty,
      );
      final field = tester.widget<CupertinoTextField>(
        find.byType(CupertinoTextField).last,
      );
      expect(field.enabled, false);
      await tester.tap(find.widgetWithText(DeskDialogAction, '发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        native.calls.where((call) => call.$1 == 'reader.sendReply').length,
        1,
      );
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
            .controller
            ?.text,
        'Keep this draft',
      );
      expect(find.byType(ComposerScreen), findsOneWidget);
      await cleanup(tester, state);
    },
  );

  testWidgets('account changes during confirmation block discard', (
    tester,
  ) async {
    final native = ComposerNativeFixture();
    native.response = (method, args) async => {'content': 'Original'};
    final state = AppState(client: native);
    await mount(
      tester,
      ComposerScreen(
        state: state,
        topicID: '17',
        url: 'https://www.nodeseek.com/post-17-1',
      ),
    );
    await tester.tap(button('放弃编辑'));
    await tester.pump();
    native.accessRevision = 1;
    await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
    await tester.pump();
    expect(
      native.calls.where(
        (call) =>
            call.$1 == 'reader.updateReplyDraft' ||
            call.$1 == 'reader.discardReplyDraft',
      ),
      isEmpty,
    );
    expect(find.byType(ComposerScreen), findsOneWidget);
    await cleanup(tester, state);
  });

  for (final reply in [false, true]) {
    for (final closeLabel in ['保存并关闭', '放弃编辑']) {
      for (final confirm in [false, true]) {
        testWidgets(
          '${reply ? 'reply' : 'new discussion'}: $closeLabel after account change '
          '${confirm ? 'closes only the local route' : 'can be cancelled without losing text'}',
          (tester) async {
            final native = ComposerNativeFixture();
            native.response = (method, args) async => switch (method) {
              'reader.replyDraft' => {'content': 'Original reply'},
              'discussion.getDraft' => {
                'title': 'Original title',
                'content': 'Original discussion',
                'category': 'general',
              },
              'discussion.loadOptions' => {
                'maxRank': 3,
                'categories': [
                  {'id': 'general', 'title': '常规'},
                ],
              },
              _ => throw NativeFailure(
                'fixture_only',
                'Unexpected fixture call: $method',
              ),
            };
            final state = AppState(client: native);
            const landing = 'Composer route closed';
            await mount(
              tester,
              const CupertinoPageScaffold(child: Center(child: Text(landing))),
            );
            final navigator = Navigator.of(tester.element(find.text(landing)));
            var routeClosed = false;
            unawaited(
              navigator
                  .push<void>(
                    CupertinoPageRoute<void>(
                      builder: (_) => GlassAdaptiveScope(
                        minQuality: GlassQuality.minimal,
                        maxQuality: GlassQuality.minimal,
                        child: ComposerScreen(
                          state: state,
                          topicID: reply ? '17' : null,
                          url: reply
                              ? 'https://www.nodeseek.com/post-17-1'
                              : null,
                        ),
                      ),
                    ),
                  )
                  .then((_) {
                    routeClosed = true;
                  }),
            );
            await tester.pumpAndSettle();
            expect(find.byType(ComposerScreen), findsOneWidget);
            expect(
              find.byType(CupertinoTextField),
              findsNWidgets(reply ? 1 : 2),
            );
            final body = tester
                .widget<CupertinoTextField>(
                  find.byType(CupertinoTextField).last,
                )
                .controller!;
            final title = reply
                ? null
                : tester
                      .widget<CupertinoTextField>(
                        find.byType(CupertinoTextField).first,
                      )
                      .controller!;
            if (!reply) {
              await tester.enterText(
                find.byType(CupertinoTextField).first,
                'Keep this local title',
              );
            }
            await tester.enterText(
              find.byType(CupertinoTextField).last,
              'Keep this unsaved local body',
            );

            // Invalidate the loaded account before its pending debounce fires.
            // A state notification also exercises the media owner's invalidation.
            final callsBeforeChange = native.calls.length;
            native.accessRevision++;
            state.showMessage('Fixture account changed');
            await tester.pump();
            await tester.tap(button(closeLabel));
            await tester.pumpAndSettle();
            expect(find.text('关闭旧账号的编辑器'), findsOneWidget);
            expect(routeClosed, isFalse);
            expect(native.calls.skip(callsBeforeChange), isEmpty);

            await tester.tap(
              find.widgetWithText(DeskDialogAction, confirm ? '关闭此编辑器' : '取消'),
            );
            await tester.pumpAndSettle();
            // Let any former draft debounce and route disposal work finish.
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.byType(DeskDialog), findsNothing);
            expect(routeClosed, confirm);
            if (confirm) {
              expect(find.byType(ComposerScreen), findsNothing);
              expect(find.text(landing), findsOneWidget);
              expect(await state.flushDrafts(), isTrue);
            } else {
              expect(find.byType(ComposerScreen), findsOneWidget);
              expect(find.text(landing), findsNothing);
              expect(
                tester
                    .widget<CupertinoTextField>(
                      find.byType(CupertinoTextField).last,
                    )
                    .controller,
                same(body),
              );
              expect(body.text, 'Keep this unsaved local body');
              if (title != null) expect(title.text, 'Keep this local title');
              expect(await state.flushDrafts(), isFalse);
            }
            // This also rejects a clear/discard call made under the new account.
            expect(native.calls.skip(callsBeforeChange), isEmpty);
            await cleanup(tester, state);
            expect(native.calls.skip(callsBeforeChange), isEmpty);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.macOS),
        );
      }
    }
  }

  testWidgets('account changes during send confirmation prevent publishing', (
    tester,
  ) async {
    final native = ComposerNativeFixture();
    native.response = (method, args) async => {'content': 'Original'};
    final state = AppState(client: native);
    await mount(
      tester,
      ComposerScreen(
        state: state,
        topicID: '17',
        url: 'https://www.nodeseek.com/post-17-1',
      ),
    );
    await tester.tap(button('发送回复'));
    await tester.pump();
    native.accessRevision = 1;
    await tester.tap(find.widgetWithText(DeskDialogAction, '发送'));
    await tester.pump();
    expect(
      native.calls.where((call) => call.$1 == 'reader.sendReply'),
      isEmpty,
    );
    expect(find.byType(ComposerScreen), findsOneWidget);
    await cleanup(tester, state);
  });

  testWidgets('failed draft flush blocks the send confirmation', (
    tester,
  ) async {
    final native = ComposerNativeFixture();
    native.response = (method, args) async {
      if (method == 'reader.replyDraft') return {'content': 'Original'};
      if (method == 'reader.updateReplyDraft') {
        throw const NativeFailure('offline', 'Offline');
      }
      return {};
    };
    final state = AppState(client: native);
    await mount(tester, ComposerScreen(state: state, topicID: '17'));
    await tester.enterText(find.byType(CupertinoTextField).last, 'Keep me');
    await tester.tap(button('发送回复'));
    await tester.pump();
    expect(find.byType(DeskDialog), findsNothing);
    expect(
      native.calls.where((call) => call.$1 == 'reader.sendReply'),
      isEmpty,
    );
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
          .controller
          ?.text,
      'Keep me',
    );
    await cleanup(tester, state);
  });

  testWidgets('closing queues the latest draft after an earlier pending save', (
    tester,
  ) async {
    final pending = Completer<JsonMap>();
    final native = ComposerNativeFixture();
    native.response = (method, args) async {
      if (method == 'reader.replyDraft') return {'content': 'Original'};
      if (method == 'reader.updateReplyDraft' && args['content'] == 'First') {
        return pending.future;
      }
      return {};
    };
    final state = AppState(client: native);
    await mount(tester, ComposerScreen(state: state, topicID: '17'));
    await tester.enterText(find.byType(CupertinoTextField).last, 'First');
    await tester.pump(const Duration(milliseconds: 410));
    await tester.enterText(find.byType(CupertinoTextField).last, 'Latest');
    await tester.pumpWidget(const SizedBox.shrink());
    var flushed = false;
    final flushing = state.flushDrafts().then((saved) {
      flushed = true;
      return saved;
    });
    await tester.pump();
    expect(flushed, false);
    expect(
      native.calls
          .where((call) => call.$1 == 'reader.updateReplyDraft')
          .map((call) => call.$2['content']),
      ['First'],
    );
    pending.complete({});
    await tester.pump();
    expect(await flushing, true);
    expect(
      native.calls
          .where((call) => call.$1 == 'reader.updateReplyDraft')
          .map((call) => call.$2['content']),
      ['First', 'Latest'],
    );
    await cleanup(tester, state);
  });

  for (final preference in ['commandReturn', 'returnKey', 'buttonOnly']) {
    testWidgets('reply send key respects $preference', (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async => {'content': 'Original'};
      final state = AppState(client: native);
      state.domains['settings'] = {'workspace.replySendKey': preference};
      await mount(tester, ComposerScreen(state: state, topicID: '17'));
      await tester.tap(find.byType(CupertinoTextField).last);
      await tester.pump();
      if (preference == 'commandReturn') {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      if (preference == 'commandReturn') {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.pump();
      expect(
        find.byType(DeskDialog),
        preference == 'buttonOnly' ? findsNothing : findsOneWidget,
      );
      expect(
        native.calls.where((call) => call.$1 == 'reader.sendReply'),
        isEmpty,
      );
      await cleanup(tester, state);
    });
  }

  testWidgets('inline editing retains changed text after a rejected save', (
    tester,
  ) async {
    final native = ComposerNativeFixture();
    native.response = (method, args) async => {
      'ready': true,
      'title': 'Title',
      'content': 'Original',
      if (method == 'reader.edit.save') 'accepted': false,
      if (method == 'reader.edit.save') 'message': 'Not saved',
    };
    final state = AppState(client: native);
    await mount(
      tester,
      InlineEditScreen(
        state: state,
        topicID: '17',
        url: 'https://www.nodeseek.com/post-17-1',
        floor: 0,
      ),
    );
    await tester.enterText(
      find.byType(CupertinoTextField).last,
      'Changed text',
    );
    await tester.pump();
    await tester.tap(button('保存修改'));
    await tester.pump();
    expect(
      native.calls.where((call) => call.$1 == 'reader.edit.save').length,
      1,
    );
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
          .controller
          ?.text,
      'Changed text',
    );
    expect(find.byType(InlineEditScreen), findsOneWidget);
    expect(await state.flushDrafts(), false);
    await cleanup(tester, state);
  });

  testWidgets('inline account changes after update prevent saving', (
    tester,
  ) async {
    final pending = Completer<JsonMap>();
    final native = ComposerNativeFixture();
    native.response = (method, args) async {
      if (method == 'reader.edit.update') return pending.future;
      return {'ready': true, 'title': 'Title', 'content': 'Original'};
    };
    final state = AppState(client: native);
    await mount(
      tester,
      InlineEditScreen(
        state: state,
        topicID: '17',
        url: 'https://www.nodeseek.com/post-17-1',
        floor: 0,
      ),
    );
    await tester.enterText(find.byType(CupertinoTextField).last, 'Changed');
    await tester.pump();
    await tester.tap(button('保存修改'));
    await tester.pump();
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
          .enabled,
      false,
    );
    native.accessRevision = 1;
    pending.complete({'ready': true});
    await tester.pump();
    expect(
      native.calls.where((call) => call.$1 == 'reader.edit.save'),
      isEmpty,
    );
    await cleanup(tester, state);
  });

  testWidgets(
    'upload status failures never open credentials or choose an image',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async =>
          throw const NativeFailure('offline', 'Offline');
      final state = AppState(client: native);
      await mount(
        tester,
        CupertinoPageScaffold(
          child: Center(child: _MediaTestHost(state: state)),
        ),
      );
      await tester.tap(button('上传图片'));
      await tester.pump();
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      expect(find.text('设置 NodeImage 上传密钥'), findsNothing);
      await cleanup(tester, state);
    },
  );

  testWidgets('pending image status lookup blocks duplicate upload clicks', (
    tester,
  ) async {
    final pending = Completer<JsonMap>();
    final native = ComposerNativeFixture();
    native.response = (method, args) async => pending.future;
    final state = AppState(client: native);
    await mount(
      tester,
      CupertinoPageScaffold(
        child: Center(child: _MediaTestHost(state: state)),
      ),
    );
    final upload = tester.widget<DeskButton>(button('上传图片')).onTap!;
    upload();
    upload();
    await tester.pump();
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    native.accessRevision = 1;
    pending.complete({'configured': true});
    await tester.pump();
    expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
    await cleanup(tester, state);
  });

  testWidgets(
    'account change in upload key dialog prevents saving credentials',
    (tester) async {
      final native = ComposerNativeFixture();
      native.response = (method, args) async => {'configured': false};
      final state = AppState(client: native);
      await mount(
        tester,
        CupertinoPageScaffold(
          child: Center(child: _MediaTestHost(state: state)),
        ),
      );
      await tester.tap(button('上传图片'));
      await tester.pump();
      await tester.enterText(
        find.byType(CupertinoTextField),
        'fixture-only-key',
      );
      native.accessRevision = 1;
      await tester.tap(find.widgetWithText(DeskDialogAction, '保存'));
      await tester.pump();
      expect(native.calls.map((call) => call.$1), ['images.keyStatus']);
      await cleanup(tester, state);
    },
  );
}
