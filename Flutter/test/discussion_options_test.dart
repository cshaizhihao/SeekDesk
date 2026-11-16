import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';

const _verificationURL = 'https://www.nodeseek.com/new-discussion';
const _submissionMessage = '上一次发布结果尚未确认，请先检查是否已经发布。';

JsonMap _options({
  String? phase = 'ready',
  String category = 'general',
  int rank = 2,
  int maxRank = 3,
  String? submissionMessage,
}) => {
  'phase': ?phase,
  'ready': phase == null || phase == 'ready',
  'category': category,
  'rank': rank,
  'maxRank': maxRank,
  'categories': [
    {'id': 'general', 'title': '常规'},
    {'id': 'news', 'title': '新闻'},
  ],
  'message': switch (phase) {
    'verification' => 'Fixture verification required',
    'signedOut' => 'Fixture sign-in required',
    'unavailable' => 'Fixture options unavailable',
    _ => '',
  },
  'verificationURL': _verificationURL,
  'lastSubmissionMessage': submissionMessage,
};

/// Every call is owned here. No method delegates to NativeClient or a channel.
/// Metadata changes model native loadOptions normalizing its shared draft.
class _OptionsNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final draft = <String, dynamic>{
    'title': 'Original title',
    'content': 'Original body',
    'category': 'general',
    'rank': 2,
  };
  Future<JsonMap> Function(int request)? optionsResponse;
  Future<JsonMap> Function(JsonMap args)? draftResponse;
  Future<JsonMap> Function(JsonMap args)? publishResponse;
  Future<JsonMap> Function(String method, JsonMap args)? sessionResponse;
  int optionsRequests = 0;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final requestRevision = accessRevision;
    final args = {...arguments, 'accessRevision': requestRevision};
    calls.add((method, args));
    switch (method) {
      case 'discussion.getDraft':
        return {...draft, 'accessRevision': requestRevision};
      case 'discussion.loadOptions':
        optionsRequests++;
        final result =
            await optionsResponse?.call(optionsRequests) ?? _options();
        if (requestRevision == accessRevision && result['ready'] == true) {
          for (final key in ['category', 'rank']) {
            if (result.containsKey(key)) draft[key] = result[key];
          }
        }
        return {'accessRevision': requestRevision, ...result};
      case 'discussion.updateDraft':
        final result = await draftResponse?.call(args);
        if (requestRevision == accessRevision) {
          for (final key in ['title', 'content', 'category', 'rank']) {
            if (args.containsKey(key)) draft[key] = args[key];
          }
        }
        return {...draft, 'accessRevision': requestRevision, ...?result};
      case 'session.verify':
      case 'session.signIn':
        return await sessionResponse?.call(method, args) ?? {'opened': true};
      case 'discussion.publish':
        final respond = publishResponse;
        if (respond != null) return respond(args);
        throw const NativeFailure(
          'fixture_only',
          'No fake publish response configured',
        );
      default:
        throw NativeFailure('fixture_only', 'Unexpected fixture call: $method');
    }
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _bodyField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);
Finder get _titleField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && !widget.expands,
);
Finder get _categoryButton => find.byWidgetPredicate(
  (widget) =>
      widget is DeskButton && widget.icon == CupertinoIcons.square_grid_2x2,
);
Finder get _rankButton => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label.startsWith('阅读权限：'),
);
TextEditingController _body(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_bodyField).controller!;
TextEditingController _title(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_titleField).controller!;
VoidCallback _callback(WidgetTester tester, String label) =>
    tester.widget<DeskButton>(_button(label)).onTap!;

void _expectLocked(WidgetTester tester) {
  expect(tester.widget<DeskButton>(_categoryButton).onTap, isNull);
  expect(tester.widget<DeskButton>(_rankButton).onTap, isNull);
  expect(tester.widget<DeskButton>(_button('发布帖子')).onTap, isNull);
}

void _expectNoPublish(_OptionsNative native) {
  expect(native.named('discussion.publish'), isEmpty);
  expect(native.named('reader.sendReply'), isEmpty);
}

Future<void> _mount(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    CupertinoApp(
      navigatorKey: navigator,
      home: const CupertinoPageScaffold(
        child: Center(child: Text('Fixture home')),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push<void>(
      CupertinoPageRoute<void>(
        builder: (_) => GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: ComposerScreen(state: state),
        ),
      ),
    ),
  );
  // A pending options request may animate a spinner, so do not settle here.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(_button(label));
  await tester.tap(_button(label));
  await tester.pump();
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  await tester.pump(const Duration(seconds: 6));
  expect(tester.takeException(), isNull);
}

void _testMac(String description, WidgetTesterCallback callback) => testWidgets(
  description,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _testMac(
    'thirteen categories use a compact scrollable menu with keyboard choose and cancel',
    (tester) async {
      final native = _OptionsNative()
        ..optionsResponse = (_) async => {
          ..._options(category: 'board-0'),
          'categories': [
            for (var index = 0; index < 13; index++)
              {'id': 'board-$index', 'title': '版块 $index'},
          ],
        };
      final state = AppState(client: native);
      await _mount(tester, state);
      await tester.tap(_categoryButton);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsNothing);
      final panel = find.byWidgetPredicate(
        (widget) =>
            widget is DeskGlassPanel && widget.level == GlassLevel.overlay,
      );
      final rect = tester.getRect(panel);
      expect(rect.width, lessThanOrEqualTo(260));
      expect(rect.height, lessThanOrEqualTo(420));
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(1192));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(992));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: panel, matching: find.byType(Scrollable)),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.draft['category'], 'board-12');
      expect(_button('版块 12'), findsOneWidget);
      final writes = native.named('discussion.updateDraft').length;
      await tester.tap(_categoryButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(native.draft['category'], 'board-12');
      expect(native.named('discussion.updateDraft'), hasLength(writes));
      expect(native.named('discussion.loadOptions'), hasLength(1));
      expect(state.watchPopupDeferred.value, isFalse);
      expect(_title(tester).text, 'Original title');
      expect(_body(tester).text, 'Original body');
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'a compact rank menu reaches the maximum allowed rank and private rank by keyboard',
    (tester) async {
      final native = _OptionsNative()
        ..optionsResponse = (_) async => _options(maxRank: 30);
      final state = AppState(client: native);
      await _mount(tester, state);
      await tester.tap(_rankButton);
      await tester.pumpAndSettle();
      final panel = find.byWidgetPredicate(
        (widget) =>
            widget is DeskGlassPanel && widget.level == GlassLevel.overlay,
      );
      expect(tester.getSize(panel).width, lessThanOrEqualTo(260));
      expect(tester.getSize(panel).height, lessThanOrEqualTo(420));
      expect(find.text('Lv.31 及以上'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.draft['rank'], 30);
      await tester.tap(_rankButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.draft['rank'], 255);
      expect(_button('阅读权限：私有'), findsOneWidget);
      expect(native.named('discussion.loadOptions'), hasLength(1));
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  for (final rankMenu in [false, true]) {
    _testMac(
      '${rankMenu ? 'rank' : 'category'} menu retires on account change and rejects a retained choice',
      (tester) async {
        final native = _OptionsNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await tester.tap(rankMenu ? _rankButton : _categoryButton);
        await tester.pumpAndSettle();
        final choice = tester
            .widget<CupertinoButton>(
              find.widgetWithText(
                CupertinoButton,
                rankMenu ? 'Lv.3 及以上' : '新闻',
              ),
            )
            .onPressed!;
        native.accessRevision++;
        state.showMessage('Fixture account changed');
        choice();
        await tester.pumpAndSettle();
        expect(find.text(rankMenu ? 'Lv.3 及以上' : '新闻'), findsNothing);
        expect(state.watchPopupDeferred.value, isFalse);
        expect(native.named('discussion.updateDraft'), isEmpty);
        expect(_body(tester).text, 'Original body');
        _expectNoPublish(native);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac(
    'pending options leave the loaded draft editable and publishing locked',
    (tester) async {
      final pending = Completer<JsonMap>();
      final native = _OptionsNative()..optionsResponse = (_) => pending.future;
      final state = AppState(client: native);
      await _mount(tester, state);
      expect(_title(tester).text, 'Original title');
      expect(_body(tester).text, 'Original body');
      expect(tester.widget<CupertinoTextField>(_bodyField).enabled, isTrue);
      expect(find.textContaining('正在读取发布选项'), findsWidgets);
      _expectLocked(tester);
      await tester.enterText(
        _bodyField,
        'Typed while initial options are pending',
      );
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.named('discussion.updateDraft'), isEmpty);
      pending.complete(_options());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(_body(tester).text, 'Typed while initial options are pending');
      expect(native.named('discussion.getDraft'), hasLength(1));
      expect(
        native.named('discussion.updateDraft').last.$2['content'],
        'Typed while initial options are pending',
      );
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'an options transport failure preserves editable draft and local autosave',
    (tester) async {
      final native = _OptionsNative();
      native.optionsResponse = (_) async {
        // The server may have normalized metadata even when its response is lost.
        native.draft['category'] = 'news';
        native.draft['rank'] = 0;
        throw const NativeFailure('offline', 'Offline');
      };
      final state = AppState(client: native);
      await _mount(tester, state);
      expect(find.text('无法打开草稿'), findsNothing);
      expect(_button('重试'), findsOneWidget);
      expect(_title(tester).text, 'Original title');
      expect(_body(tester).text, 'Original body');
      _expectLocked(tester);
      await tester.enterText(_titleField, 'Local offline title');
      await tester.enterText(_bodyField, 'Local offline body');
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        native.named('discussion.updateDraft').last.$2,
        containsPair('title', 'Local offline title'),
      );
      expect(
        native.named('discussion.updateDraft').last.$2,
        containsPair('content', 'Local offline body'),
      );
      expect(
        native.named('discussion.updateDraft').last.$2,
        isNot(contains('category')),
      );
      expect(
        native.named('discussion.updateDraft').last.$2,
        isNot(contains('rank')),
      );
      expect(native.draft['category'], 'news');
      expect(native.draft['rank'], 0);
      expect(native.named('discussion.getDraft'), hasLength(1));
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  for (final entry in {
    'unavailable': '重试',
    'verification': '验证后重试',
    'signedOut': '登录后重试',
  }.entries) {
    _testMac(
      '${entry.key} options expose recovery without enabling metadata or publish',
      (tester) async {
        final native = _OptionsNative()
          ..optionsResponse = (_) async => _options(phase: entry.key);
        final state = AppState(client: native);
        await _mount(tester, state);
        expect(_button(entry.value), findsOneWidget);
        expect(_body(tester).text, 'Original body');
        expect(tester.widget<CupertinoTextField>(_bodyField).enabled, isTrue);
        _expectLocked(tester);
        await tester.enterText(_bodyField, 'Locally edited ${entry.key} body');
        await tester.pump(const Duration(milliseconds: 450));
        final saved = native.named('discussion.updateDraft').last.$2;
        expect(saved['content'], 'Locally edited ${entry.key} body');
        expect(saved, isNot(contains('category')));
        expect(saved, isNot(contains('rank')));
        _expectNoPublish(native);
        await _cleanup(tester, state);
      },
    );
  }

  for (final phase in <String?>['ready', null]) {
    _testMac(
      '${phase ?? 'legacy ready'} options allow valid metadata and explicit publish confirmation',
      (tester) async {
        final native = _OptionsNative()
          ..optionsResponse = (_) async => _options(phase: phase);
        final state = AppState(client: native);
        await _mount(tester, state);
        expect(tester.widget<DeskButton>(_categoryButton).onTap, isNotNull);
        expect(tester.widget<DeskButton>(_rankButton).onTap, isNotNull);
        expect(tester.widget<DeskButton>(_button('发布帖子')).onTap, isNotNull);
        await tester.enterText(_bodyField, 'Draft with ready metadata');
        await tester.pump(const Duration(milliseconds: 450));
        final saved = native.named('discussion.updateDraft').last.$2;
        expect(saved['category'], 'general');
        expect(saved['rank'], 2);
        await _tap(tester, '发布帖子');
        expect(find.widgetWithText(DeskDialogAction, '发布'), findsOneWidget);
        _expectNoPublish(native);
        await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
        await tester.pumpAndSettle();
        expect(_body(tester).text, 'Draft with ready metadata');
        _expectNoPublish(native);
        await _cleanup(tester, state);
      },
    );
  }

  for (final invalid in [
    'title',
    'content',
    'category',
    'negativeRank',
    'excessRank',
  ]) {
    _testMac(
      'ready options still reject invalid $invalid before confirmation',
      (tester) async {
        final native = _OptionsNative();
        if (invalid == 'title') native.draft['title'] = '  ';
        if (invalid == 'content') native.draft['content'] = '\n ';
        native.optionsResponse = (_) async => _options(
          category: invalid == 'category'
              ? 'not-an-allowed-category'
              : 'general',
          rank: invalid == 'negativeRank'
              ? -1
              : invalid == 'excessRank'
              ? 4
              : 2,
        );
        final state = AppState(client: native);
        await _mount(tester, state);
        expect(tester.widget<DeskButton>(_button('发布帖子')).onTap, isNull);
        expect(find.byType(DeskDialog), findsNothing);
        _expectNoPublish(native);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac(
    'private rank 255 remains publishable when above the ordinary rank cap',
    (tester) async {
      final native = _OptionsNative()
        ..optionsResponse = (_) async => _options(rank: 255, maxRank: 0);
      final state = AppState(client: native);
      await _mount(tester, state);
      expect(_button('阅读权限：私有'), findsOneWidget);
      expect(tester.widget<DeskButton>(_button('发布帖子')).onTap, isNotNull);
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'retry only reloads options and preserves the editor, selection and undo',
    (tester) async {
      final pending = Completer<JsonMap>();
      final native = _OptionsNative()
        ..optionsResponse = (request) async =>
            request == 1 ? _options(phase: 'unavailable') : pending.future;
      final state = AppState(client: native);
      await _mount(tester, state);
      final controller = _body(tester);
      final history = tester
          .widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls))
          .history;
      await tester.enterText(_bodyField, 'Local version');
      controller.selection = const TextSelection(
        baseOffset: 8,
        extentOffset: 2,
      );
      await tester.pump();
      final selection = controller.selection;
      await _tap(tester, '重试');
      pending.complete({
        ..._options(),
        'title': 'Stale native title',
        'content': 'Stale native body',
      });
      await tester.pump();
      expect(_body(tester), same(controller));
      expect(controller.text, 'Local version');
      expect(controller.selection, selection);
      expect(_title(tester).text, 'Original title');
      expect(
        tester
            .widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls))
            .history,
        same(history),
      );
      expect(native.named('discussion.getDraft'), hasLength(1));
      expect(history.canUndo, isTrue);
      final undo = tester.widget<DeskIcon>(
        find.byWidgetPredicate(
          (widget) => widget is DeskIcon && widget.label == '撤销 ⌘Z',
        ),
      );
      expect(undo.onTap, isNotNull);
      undo.onTap!();
      await tester.pump();
      expect(controller.text, 'Original body');
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'retry drains writes, flushes newer text, then saves edits with corrected metadata',
    (tester) async {
      final firstWrite = Completer<JsonMap>();
      final options = Completer<JsonMap>();
      final native = _OptionsNative();
      native.optionsResponse = (request) async =>
          request == 1 ? _options(phase: 'unavailable') : options.future;
      native.draftResponse = (args) async =>
          args['content'] == 'First pending edit'
          ? firstWrite.future
          : <String, dynamic>{};
      final state = AppState(client: native);
      await _mount(tester, state);
      await tester.enterText(_bodyField, 'First pending edit');
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.named('discussion.updateDraft'), hasLength(1));
      await tester.enterText(_bodyField, 'Second edit before retry');
      final retry = _callback(tester, '重试');
      retry();
      retry();
      await tester.pump();
      expect(native.named('discussion.loadOptions'), hasLength(1));
      expect(tester.widget<CupertinoTextField>(_bodyField).enabled, isTrue);
      expect(tester.widget<DeskButton>(_button('保存并关闭')).onTap, isNull);
      expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNull);
      expect(tester.widget<DeskButton>(_button('上传图片')).onTap, isNull);
      expect(tester.widget<DeskButton>(_button('图床设置')).onTap, isNull);
      _expectLocked(tester);
      firstWrite.complete({});
      await tester.pump();
      await tester.pump();
      expect(native.named('discussion.loadOptions'), hasLength(2));
      expect(
        native
            .named('discussion.updateDraft')
            .map((call) => call.$2['content']),
        ['First pending edit', 'Second edit before retry'],
      );
      for (final call in native.named('discussion.updateDraft')) {
        expect(call.$2, isNot(contains('category')));
        expect(call.$2, isNot(contains('rank')));
      }
      final secondWriteIndex = native.calls.indexWhere(
        (call) =>
            call.$1 == 'discussion.updateDraft' &&
            call.$2['content'] == 'Second edit before retry',
      );
      final retryIndex = native.calls.lastIndexWhere(
        (call) => call.$1 == 'discussion.loadOptions',
      );
      expect(secondWriteIndex, lessThan(retryIndex));
      expect(await state.flushDrafts(), isFalse);
      await tester.enterText(_titleField, 'Latest local title');
      await tester.enterText(_bodyField, 'Latest during options');
      await tester.pump(const Duration(milliseconds: 450));
      expect(native.named('discussion.updateDraft'), hasLength(2));
      retry();
      await tester.pump();
      expect(native.named('discussion.loadOptions'), hasLength(2));
      options.complete({
        ..._options(category: 'news', rank: 0),
        'title': 'Old server title',
        'content': 'Old server body',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      final saved = native.named('discussion.updateDraft').last.$2;
      expect(saved['title'], 'Latest local title');
      expect(saved['content'], 'Latest during options');
      expect(saved['category'], 'news');
      expect(saved['rank'], 0);
      expect(_title(tester).text, 'Latest local title');
      expect(_body(tester).text, 'Latest during options');
      expect(_button('新闻'), findsOneWidget);
      expect(_button('阅读权限：公开'), findsOneWidget);
      expect(native.named('discussion.getDraft'), hasLength(1));
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'a failed pre-retry draft flush stops option loading and retains local text',
    (tester) async {
      final native = _OptionsNative();
      native.optionsResponse = (_) async => _options(phase: 'unavailable');
      native.draftResponse = (_) async =>
          throw const NativeFailure('offline', 'Draft not saved');
      final state = AppState(client: native);
      await _mount(tester, state);
      await tester.enterText(_bodyField, 'Unsaved text survives');
      await _tap(tester, '重试');
      await tester.pump();
      expect(native.named('discussion.updateDraft'), isNotEmpty);
      expect(native.named('discussion.loadOptions'), hasLength(1));
      expect(_body(tester).text, 'Unsaved text survives');
      expect(tester.widget<CupertinoTextField>(_bodyField).enabled, isTrue);
      _expectNoPublish(native);
      await _cleanup(tester, state);
    },
  );

  for (final entry in {
    'verification': ('打开验证窗口', '验证后重试', 'session.verify'),
    'signedOut': ('打开登录窗口', '登录后重试', 'session.signIn'),
  }.entries) {
    _testMac(
      '${entry.key} opens recovery without automatically retrying or publishing',
      (tester) async {
        final native = _OptionsNative()
          ..optionsResponse = (request) async => _options(
            phase: request == 1 ? entry.key : 'ready',
            submissionMessage: _submissionMessage,
          );
        final state = AppState(client: native);
        await _mount(tester, state);
        await _tap(tester, entry.value.$1);
        await tester.pump();
        expect(native.named(entry.value.$3), hasLength(1));
        if (entry.key == 'verification') {
          expect(
            native.named('session.verify').single.$2['url'],
            _verificationURL,
          );
        }
        expect(native.named('discussion.loadOptions'), hasLength(1));
        expect(_button(entry.value.$2), findsOneWidget);
        _expectLocked(tester);
        _expectNoPublish(native);
        await _tap(tester, entry.value.$2);
        await tester.pump();
        expect(native.named('discussion.loadOptions'), hasLength(2));
        expect(native.named('discussion.getDraft'), hasLength(1));
        expect(find.textContaining(_submissionMessage), findsWidgets);
        _expectNoPublish(native);
        await _cleanup(tester, state);
      },
    );
  }

  _testMac(
    'transport failure keeps an uncertain submission warning through options retries and cancelled confirmation',
    (tester) async {
      const uncertain = '未收到发布结果。请先检查帖子是否已经出现，再决定是否重发。当前文字已保留。';
      const rejected = 'Fixture second attempt was explicitly rejected';
      final native = _OptionsNative();
      native.optionsResponse = (request) async =>
          _options(phase: request == 1 ? 'unavailable' : 'ready');
      native.publishResponse = (_) async {
        if (native.named('discussion.publish').length == 1) {
          throw const NativeFailure(
            'transport',
            'Fixture connection lost after submission',
          );
        }
        return {..._options(), 'accepted': false, 'message': rejected};
      };
      final state = AppState(client: native);
      await _mount(tester, state);
      final retry = _callback(tester, '重试');
      await _tap(tester, '重试');
      expect(native.named('discussion.loadOptions'), hasLength(2));
      await tester.enterText(_bodyField, 'Keep the uncertain submission body');
      await _tap(tester, '发布帖子');
      expect(native.named('discussion.publish'), isEmpty);
      await tester.tap(find.widgetWithText(DeskDialogAction, '发布'));
      await tester.pumpAndSettle();
      expect(native.named('discussion.publish'), hasLength(1));
      expect(find.textContaining(uncertain), findsWidgets);
      expect(_body(tester).text, 'Keep the uncertain submission body');

      // The durable warning must outlive AppState's transient error message.
      await tester.pump(const Duration(seconds: 6));
      expect(find.textContaining(uncertain), findsWidgets);
      retry();
      await tester.pump();
      expect(native.named('discussion.loadOptions'), hasLength(3));
      expect(native.named('discussion.publish'), hasLength(1));
      expect(find.textContaining(uncertain), findsWidgets);

      // Merely opening and cancelling the confirmation starts no new attempt.
      await _tap(tester, '发布帖子');
      await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
      await tester.pumpAndSettle();
      retry();
      await tester.pump();
      expect(native.named('discussion.loadOptions'), hasLength(4));
      expect(native.named('discussion.publish'), hasLength(1));
      expect(find.textContaining(uncertain), findsWidgets);

      // Only the next explicit confirmation allows its own result to replace it.
      await _tap(tester, '发布帖子');
      expect(native.named('discussion.publish'), hasLength(1));
      await tester.tap(find.widgetWithText(DeskDialogAction, '发布'));
      await tester.pumpAndSettle();
      expect(native.named('discussion.publish'), hasLength(2));
      expect(find.textContaining(uncertain), findsNothing);
      expect(find.textContaining(rejected), findsWidgets);
      expect(_body(tester).text, 'Keep the uncertain submission body');
      expect(native.named('discussion.getDraft'), hasLength(1));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(
        native
            .named('discussion.publish')
            .every((call) => call.$2['feeAccepted'] == true),
        isTrue,
      );
      await _cleanup(tester, state);
    },
  );

  _testMac(
    'account changes during initial options remove loading and reject late metadata or writes',
    (tester) async {
      final pending = Completer<JsonMap>();
      final native = _OptionsNative()..optionsResponse = (_) => pending.future;
      final state = AppState(client: native);
      await _mount(tester, state);
      expect(find.textContaining('正在读取发布选项'), findsWidgets);
      await tester.enterText(_bodyField, 'Old account local text');
      native.accessRevision++;
      state.showMessage('Fixture account changed');
      await tester.pump();
      expect(find.textContaining('正在读取'), findsNothing);
      expect(find.textContaining('账号已变更'), findsWidgets);
      expect(find.textContaining('复制'), findsWidgets);
      expect(_button('重试'), findsNothing);
      expect(tester.widget<DeskButton>(_button('保存并关闭')).onTap, isNotNull);
      expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNotNull);
      final beforeCompletion = native.calls.length;
      pending.complete({
        ..._options(category: 'news', rank: 0),
        'content': 'Late old-account body',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_body(tester).text, 'Old account local text');
      expect(find.textContaining('正在读取'), findsNothing);
      expect(find.textContaining('账号已变更'), findsWidgets);
      expect(native.calls.skip(beforeCompletion), isEmpty);
      expect(tester.widget<DeskButton>(_button('发布帖子')).onTap, isNull);
      expect(_button('新闻'), findsNothing);
      _expectNoPublish(native);
      await _cleanup(tester, state);
      expect(native.calls.skip(beforeCompletion), isEmpty);
    },
  );

  _testMac(
    'disposal waits for pending options then saves latest text with canonical metadata',
    (tester) async {
      final pending = Completer<JsonMap>();
      final native = _OptionsNative()
        ..optionsResponse = (request) async =>
            request == 1 ? _options(phase: 'unavailable') : pending.future;
      final state = AppState(client: native);
      await _mount(tester, state);
      await tester.enterText(_bodyField, 'Before options retry');
      await _tap(tester, '重试');
      expect(native.named('discussion.loadOptions'), hasLength(2));
      await tester.enterText(_titleField, 'Latest disposed title');
      await tester.enterText(_bodyField, 'Latest disposed body');
      await tester.pump(const Duration(milliseconds: 450));
      final writesBeforeDisposal = native
          .named('discussion.updateDraft')
          .length;
      expect(writesBeforeDisposal, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(native.named('discussion.getDraft'), hasLength(1));
      expect(
        native.named('discussion.updateDraft'),
        hasLength(writesBeforeDisposal),
      );
      pending.complete(_options(category: 'news', rank: 0));
      await tester.pump();
      await tester.pump();
      expect(await state.flushDrafts(), isTrue);
      expect(native.named('discussion.getDraft'), hasLength(2));
      expect(
        native.calls.skip(native.calls.length - 2).map((call) => call.$1),
        ['discussion.getDraft', 'discussion.updateDraft'],
      );
      final saved = native.named('discussion.updateDraft').last.$2;
      expect(saved['title'], 'Latest disposed title');
      expect(saved['content'], 'Latest disposed body');
      expect(saved['category'], 'news');
      expect(saved['rank'], 0);
      expect(saved['accessRevision'], 0);
      _expectNoPublish(native);
      state.dispose();
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);
    },
  );
}
