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
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/node_image_settings.dart';
import 'package:seekdesk_flutter/widgets/profile_introduction_editor.dart';

/// Every draft and credential exists only in this fixture. Unknown operations
/// are recorded even when production catches the error; no request can reach
/// a native service, the network, or the macOS keychain.
class _Native extends NativeClient {
  _Native()
    : super(methods: MethodChannel('seekdesk.test.destructive.${_next++}'));
  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  String content = 'Fixture draft';
  bool configured = true;

  JsonMap get draft => {
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

  JsonMap get edit => {
    'editToken': 'fixture-edit-token',
    'topicID': '17',
    'floor': 0,
    'accessRevision': accessRevision,
    'title': 'Fixture title',
    'content': 'Original content',
    'ready': true,
    'saving': false,
    'canSave': true,
    'needsVerification': false,
    'accepted': false,
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
      case 'reader.replyDraft':
        return draft;
      case 'discussion.updateDraft':
      case 'reader.updateReplyDraft':
        content = arguments['content'] as String;
        return draft;
      case 'discussion.discard':
      case 'reader.discardReplyDraft':
        content = '';
        return draft;
      case 'reader.edit.begin':
        return edit;
      case 'reader.edit.cancel':
        return {...edit, 'ready': false};
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
        };
      case 'images.keyStatus':
        return {'configured': configured};
      case 'images.removeKey':
        configured = false;
        return {'configured': configured};
      default:
        unexpected.add(method);
        throw StateError('Unexpected destructive fixture operation: $method');
    }
  }

  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);
}

class _State extends AppState {
  _State(_Native native) : super(client: native);

  void changeAccount() {
    client.accessRevision++;
    notifyListeners();
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _body => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 40),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Future<void> _mount(WidgetTester tester, _State state, Widget child) async {
  final native = state.client as _Native;
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  final navigation = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        navigatorKey: navigation,
        home: const CupertinoPageScaffold(
          child: Center(child: Text('Fixture home')),
        ),
      ),
    ),
  );
  unawaited(
    navigation.currentState!.push<void>(
      CupertinoPageRoute(builder: (_) => child),
    ),
  );
  await _settle(tester);
}

void _expectRoles(
  WidgetTester tester,
  String accept, {
  bool destructive = true,
}) {
  expect(find.byType(DeskDialog), findsOneWidget);
  expect(find.byType(DeskDialogAction), findsNWidgets(2));
  final cancel = tester.widget<DeskDialogAction>(
    find.widgetWithText(DeskDialogAction, '取消'),
  );
  final confirm = tester.widget<DeskDialogAction>(
    find.widgetWithText(DeskDialogAction, accept),
  );
  expect(cancel.isDefaultAction, destructive);
  expect(cancel.isDestructiveAction, false);
  expect(confirm.isDefaultAction, !destructive);
  expect(confirm.isDestructiveAction, destructive);
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  await tester.tap(_button(label));
  await tester.pump();
  // Image settings intentionally keeps its busy indicator running behind the
  // confirmation. Wait for the dialog entrance without settling that ticker.
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _answer(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(DeskDialogAction, label));
  await _settle(tester);
  expect(find.byType(DeskDialog), findsNothing);
}

void _testMac(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

Future<FocusNode> _openKeyboardConfirmation(
  WidgetTester tester,
  List<bool> answers, {
  bool destructive = true,
  bool openWithHeldSpace = false,
}) async {
  final native = _Native();
  final state = _State(native);
  final opener = FocusNode();
  addTearDown(opener.dispose);
  await _mount(
    tester,
    state,
    CupertinoPageScaffold(
      child: Center(
        child: Builder(
          builder: (context) => CupertinoButton(
            focusNode: opener,
            onPressed: () async {
              final accepted = await confirmAction(
                context,
                title: 'Keyboard confirmation fixture',
                message: 'No native write is performed.',
                accept: '执行操作',
                destructive: destructive,
              );
              answers.add(accepted);
            },
            child: const Text('Open confirmation fixture'),
          ),
        ),
      ),
    ),
  );
  opener.requestFocus();
  await tester.pump();
  if (openWithHeldSpace) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
  } else {
    await tester.tap(find.text('Open confirmation fixture'));
  }
  await _settle(tester);
  _expectRoles(tester, '执行操作', destructive: destructive);
  return opener;
}

FocusNode _confirmationFocus(WidgetTester tester, {required bool accept}) =>
    tester
        .widget<DeskDialogAction>(
          find.byKey(
            ValueKey(accept ? 'confirmation-accept' : 'confirmation-cancel'),
          ),
        )
        .focusNode!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  ]) {
    _testMac(
      'destructive confirmation focuses cancel and ${key.keyLabel} returns without accepting',
      (tester) async {
        final answers = <bool>[];
        final opener = await _openKeyboardConfirmation(tester, answers);
        expect(_confirmationFocus(tester, accept: false).hasPrimaryFocus, true);
        expect(_confirmationFocus(tester, accept: true).hasFocus, false);
        await tester.sendKeyEvent(key);
        await _settle(tester);
        expect(answers, [false]);
        expect(find.byType(DeskDialog), findsNothing);
        expect(opener.hasFocus, true);
      },
    );
  }

  _testMac(
    'holding the opening Space key cannot answer the newly focused confirmation',
    (tester) async {
      final answers = <bool>[];
      await _openKeyboardConfirmation(tester, answers, openWithHeldSpace: true);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(answers, isEmpty);
      expect(_confirmationFocus(tester, accept: false).hasPrimaryFocus, true);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      expect(answers, [false]);
    },
  );

  _testMac(
    'confirmation Tab wraps and a held Tab cannot change the chosen action repeatedly',
    (tester) async {
      final answers = <bool>[];
      final opener = await _openKeyboardConfirmation(tester, answers);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_confirmationFocus(tester, accept: true).hasPrimaryFocus, true);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_confirmationFocus(tester, accept: true).hasPrimaryFocus, true);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_confirmationFocus(tester, accept: false).hasPrimaryFocus, true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_confirmationFocus(tester, accept: true).hasPrimaryFocus, true);
      final staleAccept = tester
          .widget<DeskDialogAction>(
            find.widgetWithText(DeskDialogAction, '执行操作'),
          )
          .onPressed;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      staleAccept();
      staleAccept();
      await _settle(tester);
      expect(answers, [true]);
      expect(find.byType(DeskDialog), findsNothing);
      expect(opener.hasFocus, true);
    },
  );

  _testMac('Escape cancels even when the destructive action has focus', (
    tester,
  ) async {
    final answers = <bool>[];
    final opener = await _openKeyboardConfirmation(tester, answers);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_confirmationFocus(tester, accept: true).hasPrimaryFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(answers, [false]);
    expect(opener.hasFocus, true);
  });

  _testMac(
    'ordinary confirmation keeps its existing default accept role and keyboard focus',
    (tester) async {
      final answers = <bool>[];
      await _openKeyboardConfirmation(tester, answers, destructive: false);
      expect(_confirmationFocus(tester, accept: true).hasPrimaryFocus, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(answers, [true]);
    },
  );

  _testMac('a covered confirmation callback cannot dismiss the newer route', (
    tester,
  ) async {
    final answers = <bool>[];
    await _openKeyboardConfirmation(tester, answers);
    final oldAccept = tester
        .widget<DeskDialogAction>(find.widgetWithText(DeskDialogAction, '执行操作'))
        .onPressed;
    final navigator = Navigator.of(tester.element(find.byType(DeskDialog)));
    unawaited(
      navigator.push<void>(
        CupertinoPageRoute(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Newer fixture route')),
          ),
        ),
      ),
    );
    await _settle(tester);
    oldAccept();
    await _settle(tester);
    expect(find.text('Newer fixture route'), findsOneWidget);
    expect(answers, isEmpty);
    navigator.pop();
    await _settle(tester);
    expect(find.byType(DeskDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(answers, [false]);
  });

  for (final reply in [false, true]) {
    _testMac(
      '${reply ? 'reply' : 'discussion'} discard defaults to cancel and requires one explicit acceptance',
      (tester) async {
        final native = _Native();
        final state = _State(native);
        final method = reply
            ? 'reader.discardReplyDraft'
            : 'discussion.discard';
        await _mount(
          tester,
          state,
          ComposerScreen(state: state, topicID: reply ? '17' : null),
        );
        await tester.enterText(_body, 'Keep this local draft');
        await _tapButton(tester, '放弃编辑');
        _expectRoles(tester, '放弃编辑');
        expect(native.named(method), isEmpty);
        await _answer(tester, '取消');
        expect(find.byType(ComposerScreen), findsOneWidget);
        expect(
          tester.widget<CupertinoTextField>(_body).controller!.text,
          'Keep this local draft',
        );
        expect(native.named(method), isEmpty);
        await _tapButton(tester, '放弃编辑');
        _expectRoles(tester, '放弃编辑');
        await _answer(tester, '放弃编辑');
        expect(native.named(method), hasLength(1));
        expect(native.named(method).single.$2, {
          if (reply) 'topicID': '17',
          'confirmed': true,
        });
        expect(native.content, isEmpty);
        expect(find.text('Fixture home'), findsOneWidget);
      },
    );
  }

  _testMac('old account editor closure defaults to retaining its local text', (
    tester,
  ) async {
    final native = _Native();
    final state = _State(native);
    await _mount(tester, state, ComposerScreen(state: state, topicID: '17'));
    await tester.enterText(_body, 'Unsaved previous account text');
    state.changeAccount();
    await tester.pump();
    await _tapButton(tester, '保存并关闭');
    _expectRoles(tester, '关闭此编辑器');
    await _answer(tester, '取消');
    expect(
      tester.widget<CupertinoTextField>(_body).controller!.text,
      'Unsaved previous account text',
    );
    await _tapButton(tester, '保存并关闭');
    await _answer(tester, '关闭此编辑器');
    expect(find.text('Fixture home'), findsOneWidget);
    expect(native.named('reader.updateReplyDraft'), isEmpty);
    expect(native.named('reader.discardReplyDraft'), isEmpty);
  });

  _testMac(
    'dirty inline edit cancellation retains text until discard is accepted',
    (tester) async {
      final native = _Native();
      final state = _State(native);
      await _mount(
        tester,
        state,
        InlineEditScreen(
          state: state,
          url: 'https://www.nodeseek.com/post-17-1',
          topicID: '17',
          floor: 0,
        ),
      );
      await tester.enterText(_body, 'Unsubmitted content');
      await _tapButton(tester, '取消编辑');
      _expectRoles(tester, '放弃修改');
      expect(native.named('reader.edit.cancel'), isEmpty);
      await _answer(tester, '取消');
      expect(await state.flushDrafts(), false);
      expect(
        tester.widget<CupertinoTextField>(_body).controller!.text,
        'Unsubmitted content',
      );
      expect(native.named('reader.edit.cancel'), isEmpty);
      await _tapButton(tester, '取消编辑');
      _expectRoles(tester, '放弃修改');
      await _answer(tester, '放弃修改');
      expect(native.named('reader.edit.cancel'), hasLength(1));
      expect(
        native.named('reader.edit.cancel').single.$2['editToken'],
        'fixture-edit-token',
      );
      expect(find.text('Fixture home'), findsOneWidget);
    },
  );

  _testMac(
    'image credential removal is destructive and cancel retains configuration',
    (tester) async {
      final native = _Native();
      final state = _State(native);
      await _mount(tester, state, NodeImageSettings(state: state));
      await _tapButton(tester, '移除密钥');
      _expectRoles(tester, '移除密钥');
      expect(native.named('images.removeKey'), isEmpty);
      await _answer(tester, '取消');
      expect(native.configured, true);
      expect(find.text('已配置上传密钥'), findsOneWidget);
      expect(native.named('images.removeKey'), isEmpty);
      expect(await state.flushDrafts(), true);
      await _tapButton(tester, '移除密钥');
      _expectRoles(tester, '移除密钥');
      await _answer(tester, '移除密钥');
      expect(native.named('images.removeKey'), hasLength(1));
      expect(native.configured, false);
      expect(find.text('尚未配置上传密钥'), findsOneWidget);
    },
  );

  _testMac(
    'profile editor already uses cancel as the default destructive role',
    (tester) async {
      final native = _Native();
      final state = _State(native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 1};
      final closes = <bool>[];
      await _mount(
        tester,
        state,
        CupertinoPageScaffold(
          child: ProfileIntroductionEditor(
            state: state,
            original: const {
              'signature': 'Original signature',
              'readme': 'Original readme',
            },
            onClose: closes.add,
          ),
        ),
      );
      final field = find.byKey(
        const ValueKey('profile-introduction-signature'),
      );
      await tester.enterText(field, 'Keep this profile change');
      await _tapButton(tester, '放弃编辑');
      _expectRoles(tester, '放弃编辑');
      await _answer(tester, '取消');
      expect(closes, isEmpty);
      expect(await state.flushDrafts(), false);
      expect(
        tester.widget<CupertinoTextField>(field).controller!.text,
        'Keep this profile change',
      );
      expect(native.calls, isEmpty);
    },
  );

  _testMac(
    'ordinary publish confirmation retains its non-destructive default',
    (tester) async {
      final native = _Native();
      final state = _State(native);
      await _mount(tester, state, ComposerScreen(state: state));
      await _tapButton(tester, '发布帖子');
      _expectRoles(tester, '发布', destructive: false);
      await _answer(tester, '取消');
      expect(find.byType(ComposerScreen), findsOneWidget);
      expect(native.named('discussion.publish'), isEmpty);
      expect(native.content, 'Fixture draft');
    },
  );
}
