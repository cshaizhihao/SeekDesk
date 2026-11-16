import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

typedef _Target = ({String topic, int floor});
const _initialTarget = (topic: '17', floor: 0);
const _verifyMethod = 'session.verify';
const _continueMethod = 'reader.edit.continueVerification';
const _openLabel = '打开验证窗口';
const _continueLabel = '验证后继续';

/// Owns every operation in memory. Unknown requests fail rather than reaching
/// NativeClient, so verification, editor writes and reader loads stay offline.
class _VerificationNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap?> Function(String, JsonMap)? response;
  _Target target = _initialTarget;
  String token = '';
  int generation = 0;
  String title = 'Original title', content = 'Original body';
  bool needsVerification = false;

  JsonMap get snapshot => {
    'editToken': token,
    'topicID': target.topic,
    'floor': target.floor,
    'accessRevision': accessRevision,
    'title': title,
    'content': content,
    'ready': true,
    'saving': false,
    'canSave': !needsVerification,
    'needsVerification': needsVerification,
    'accepted': false,
    'message': needsVerification ? 'Fixture verification required' : '',
  };

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    // Match the real NativeClient's wire-level revision injection.
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    final custom = await response?.call(method, args);
    if (custom != null) return custom;
    if (method == 'reader.edit.begin') {
      target = (
        topic: stringValue(args['topicID']),
        floor: intValue(args['floor']),
      );
      token = 'memory-edit-${++generation}';
      title = 'Original title';
      content = 'Original body';
      needsVerification = false;
      return snapshot;
    }
    if (method == _verifyMethod) return {'opened': true};
    if (method.startsWith('reader.edit.')) {
      if (args['editToken'] != token ||
          args['topicID'] != target.topic ||
          args['floor'] != target.floor) {
        throw const NativeFailure('stale_editor', 'Fixture editor changed');
      }
      switch (method) {
        case 'reader.edit.update':
          title = stringValue(args['title'], title);
          content = stringValue(args['content'], content);
          return snapshot;
        case 'reader.edit.save':
          needsVerification = true;
          return snapshot;
        case _continueMethod:
          needsVerification = false;
          return snapshot;
        case 'reader.edit.cancel':
          final cancelled = {...snapshot, 'ready': false};
          token = '';
          return cancelled;
      }
    }
    throw NativeFailure('fixture_only', 'Unsupported fixture request: $method');
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
String _body(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_bodyField).controller!.text;
String _title(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_titleField).controller!.text;
VoidCallback _callback(WidgetTester tester, String label) =>
    tester.widget<DeskButton>(_button(label)).onTap!;

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  ValueNotifier<_Target>? target,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final navigator = GlobalKey<NavigatorState>();
  Widget editor(_Target document) => GlassAdaptiveScope(
    minQuality: GlassQuality.minimal,
    maxQuality: GlassQuality.minimal,
    child: InlineEditScreen(
      key: const ValueKey('verification-editor'),
      state: state,
      topicID: document.topic,
      url: 'https://www.nodeseek.com/post-${document.topic}-1',
      floor: document.floor,
    ),
  );
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
      CupertinoPageRoute(
        builder: (_) => target == null
            ? editor(_initialTarget)
            : ValueListenableBuilder<_Target>(
                valueListenable: target,
                builder: (_, document, _) => editor(document),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(_button(label));
  await tester.pump();
}

Future<VoidCallback> _requireVerification(WidgetTester tester) async {
  await tester.enterText(_titleField, 'Local title');
  await tester.enterText(_bodyField, 'Local body');
  await tester.pump();
  final save = _callback(tester, '保存修改');
  await _tap(tester, '保存修改');
  expect(_button(_openLabel), findsOneWidget);
  expect(_button(_continueLabel), findsOneWidget);
  return save;
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  await tester.pump(const Duration(seconds: 6));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'captured standalone inline close cannot cancel the editor or dismiss a covering route',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      try {
        await _mount(tester, state);
        final originalEditor = tester.element(find.byType(InlineEditScreen));
        final editorRoute = ModalRoute.of(originalEditor)!;
        final navigator = Navigator.of(originalEditor);
        final close = _callback(tester, '取消编辑');
        final controller = tester
            .widget<CupertinoTextField>(_bodyField)
            .controller!;
        final token = native.token;
        var editorCompleted = false, coveringCompleted = false;
        unawaited(
          editorRoute.completed.then((_) {
            editorCompleted = true;
          }),
        );
        final covering = CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Newer inline fixture route')),
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
        expect(controller.text, 'Original body');
        expect(native.token, token);
        expect(native.named('reader.edit.cancel'), isEmpty);
        expect(native.named('reader.edit.update'), isEmpty);
        expect(native.named('reader.edit.save'), isEmpty);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(editorRoute.isCurrent, true);
        expect(
          tester.element(find.byType(InlineEditScreen)),
          same(originalEditor),
        );
        await tester.tap(_button('取消编辑'));
        await tester.pumpAndSettle();
        expect(editorCompleted, true);
        expect(editorRoute.isActive, false);
        expect(native.named('reader.edit.cancel'), hasLength(1));
        expect(
          native.named('reader.edit.cancel').single.$2['editToken'],
          token,
        );
        expect(find.text('Fixture home'), findsOneWidget);
      } finally {
        await _cleanup(tester, state);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a pending standalone inline cancellation closes only its own route after another route covers it',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      final pending = Completer<JsonMap>();
      JsonMap? cancellation;
      try {
        await _mount(tester, state);
        final originalEditor = tester.element(find.byType(InlineEditScreen));
        final editorRoute = ModalRoute.of(originalEditor)!;
        final navigator = Navigator.of(originalEditor);
        cancellation = {...native.snapshot, 'ready': false};
        final token = native.token;
        var editorCompleted = false, coveringCompleted = false;
        unawaited(
          editorRoute.completed.then((_) {
            editorCompleted = true;
          }),
        );
        native.response = (method, args) async =>
            method == 'reader.edit.cancel' ? pending.future : null;
        await tester.tap(_button('取消编辑'));
        await tester.pump();
        expect(native.named('reader.edit.cancel'), hasLength(1));
        expect(
          native.named('reader.edit.cancel').single.$2['editToken'],
          token,
        );
        expect(editorCompleted, false);
        final covering = CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Newer inline fixture route')),
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
        // Commit only this fixture's cancellation before delivering its reply.
        // The real editor must not leave an ended native session stranded below
        // the covering page, or use its context to dismiss that newer page.
        native.token = '';
        pending.complete(cancellation);
        await tester.pumpAndSettle();
        expect(covering.isCurrent, true);
        expect(coveringCompleted, false);
        expect(find.text('Newer inline fixture route'), findsOneWidget);
        expect(editorCompleted, true);
        expect(editorRoute.isActive, false);
        expect(native.named('reader.edit.cancel'), hasLength(1));
        expect(native.named('reader.edit.update'), isEmpty);
        expect(native.named('reader.edit.save'), isEmpty);
        expect(native.content, 'Original body');
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Fixture home'), findsOneWidget);
        expect(
          find.byType(InlineEditScreen, skipOffstage: false),
          findsNothing,
        );
      } finally {
        if (!pending.isCompleted) {
          pending.complete(cancellation ?? native.snapshot);
        }
        await _cleanup(tester, state);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'verification stays visible and continuation never reloads or auto-saves local text',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      final bodyElement = tester.element(_bodyField);
      await _requireVerification(tester);
      expect(tester.element(_bodyField), same(bodyElement));
      final identity = native.snapshot;
      await tester.pump(const Duration(seconds: 6));
      expect(_button(_openLabel), findsOneWidget);
      expect(_button(_continueLabel), findsOneWidget);
      expect(await state.flushDrafts(), false);
      await _tap(tester, _openLabel);
      expect(
        native.named(_verifyMethod).single.$2['url'],
        'https://www.nodeseek.com/post-17-1',
      );
      expect(native.named(_continueMethod), isEmpty);
      expect(native.named('reader.edit.save'), hasLength(1));
      expect(_button(_continueLabel), findsOneWidget);
      await tester.enterText(_titleField, 'Edited during verification');
      await tester.enterText(_bodyField, 'Body during verification');
      await tester.pump();
      await _tap(tester, _continueLabel);
      expect(_title(tester), 'Edited during verification');
      expect(_body(tester), 'Body during verification');
      expect(native.named('reader.edit.begin'), hasLength(1));
      expect(native.named('reader.edit.update'), hasLength(1));
      expect(native.named('reader.edit.save'), hasLength(1));
      expect(native.named(_continueMethod), hasLength(1));
      expect(_button(_continueLabel), findsNothing);
      expect(tester.element(_bodyField), same(bodyElement));
      expect(await state.flushDrafts(), false);
      await _tap(tester, '保存修改');
      expect(native.named('reader.edit.save'), hasLength(2));
      final update = native.named('reader.edit.update').last.$2;
      expect(update['title'], 'Edited during verification');
      expect(update['content'], 'Body during verification');
      for (final call in native.calls.where(
        (call) => const {
          'reader.edit.update',
          'reader.edit.save',
          _continueMethod,
        }.contains(call.$1),
      )) {
        expect(call.$2['editToken'], identity['editToken']);
        expect(call.$2['topicID'], '17');
        expect(call.$2['floor'], 0);
        expect(call.$2['accessRevision'], 0);
      }
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final failure in ['cancelled', 'offline']) {
    testWidgets(
      '$failure opening verification preserves text and permits retry without completing verification',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await _requireVerification(tester);
        var attempts = 0;
        native.response = (method, args) async {
          if (method == _verifyMethod && attempts++ == 0) {
            throw NativeFailure(failure, 'Fixture $failure');
          }
          return null;
        };
        await _tap(tester, _openLabel);
        expect(_body(tester), 'Local body');
        expect(_title(tester), 'Local title');
        expect(_button(_continueLabel), findsOneWidget);
        expect(tester.widget<DeskButton>(_button(_openLabel)).onTap, isNotNull);
        await _tap(tester, _openLabel);
        expect(native.named(_verifyMethod), hasLength(2));
        expect(native.named(_continueMethod), isEmpty);
        expect(native.named('reader.edit.begin'), hasLength(1));
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(_button(_continueLabel), findsOneWidget);
        expect(await state.flushDrafts(), false);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  for (final failure in ['offline', 'still-required']) {
    testWidgets(
      '$failure continuation leaves verification retryable with local text intact',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await _requireVerification(tester);
        var attempts = 0;
        native.response = (method, args) async {
          if (method == _continueMethod && attempts++ == 0) {
            if (failure == 'offline') {
              throw const NativeFailure('offline', 'Fixture offline');
            }
            return native.snapshot;
          }
          return null;
        };
        await _tap(tester, _continueLabel);
        expect(_body(tester), 'Local body');
        expect(_title(tester), 'Local title');
        expect(_button(_continueLabel), findsOneWidget);
        expect(
          tester.widget<DeskButton>(_button(_continueLabel)).onTap,
          isNotNull,
        );
        await _tap(tester, _continueLabel);
        expect(native.named(_continueMethod), hasLength(2));
        expect(_button(_continueLabel), findsNothing);
        expect(_body(tester), 'Local body');
        expect(native.named('reader.edit.begin'), hasLength(1));
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(await state.flushDrafts(), false);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  for (final operation in [
    (method: _verifyMethod, label: _openLabel),
    (method: _continueMethod, label: _continueLabel),
  ]) {
    testWidgets(
      '${operation.method} serializes duplicate and stale callbacks against save, close and continuation',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        final save = await _requireVerification(tester);
        final pending = Completer<JsonMap>();
        final open = _callback(tester, _openLabel);
        final continuation = _callback(tester, _continueLabel);
        final close = _callback(tester, '取消编辑');
        native.response = (method, args) async =>
            method == operation.method ? pending.future : null;
        await _tap(tester, operation.label);
        open();
        continuation();
        save();
        close();
        await tester.pump();
        await tester.enterText(_bodyField, 'Edited while verification waits');
        await tester.pump();
        expect(native.named(operation.method), hasLength(1));
        expect(
          native.named(
            operation.method == _verifyMethod ? _continueMethod : _verifyMethod,
          ),
          isEmpty,
        );
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(native.named('reader.edit.cancel'), isEmpty);
        expect(find.byType(DeskDialog), findsNothing);
        expect(await state.flushDrafts(), false);
        pending.complete(
          operation.method == _verifyMethod
              ? {'opened': true}
              : {...native.snapshot, 'needsVerification': false},
        );
        await tester.pump();
        expect(_body(tester), 'Edited while verification waits');
        expect(native.named('reader.edit.save'), hasLength(1));
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${operation.method} ignores an old account completion and rejects stale callbacks',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await _requireVerification(tester);
        final pending = Completer<JsonMap>();
        final oldSnapshot = native.snapshot;
        final open = _callback(tester, _openLabel);
        final continuation = _callback(tester, _continueLabel);
        native.response = (method, args) async =>
            method == operation.method ? pending.future : null;
        await _tap(tester, operation.label);
        native.accessRevision++;
        pending.complete(
          operation.method == _verifyMethod
              ? {'opened': true}
              : {...oldSnapshot, 'needsVerification': false},
        );
        await tester.pump();
        open();
        continuation();
        await tester.pump();
        expect(native.named(operation.method), hasLength(1));
        expect(
          native.named(
            operation.method == _verifyMethod ? _continueMethod : _verifyMethod,
          ),
          isEmpty,
        );
        expect(native.named('reader.edit.begin'), hasLength(1));
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(_body(tester), 'Local body');
        expect(await state.flushDrafts(), false);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '${operation.method} ignores completion after the editor is disposed',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await _requireVerification(tester);
        final pending = Completer<JsonMap>();
        final result = {...native.snapshot, 'needsVerification': false};
        native.response = (method, args) async =>
            method == operation.method ? pending.future : null;
        await _tap(tester, operation.label);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        pending.complete(
          operation.method == _verifyMethod ? {'opened': true} : result,
        );
        await tester.pump();
        expect(native.named('reader.edit.begin'), hasLength(1));
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(native.named('reader.edit.cancel'), isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    for (final next in [(topic: '18', floor: 0), (topic: '17', floor: 1)]) {
      testWidgets(
        '${operation.method} cannot affect a replacement editor at $next',
        (tester) async {
          final native = _VerificationNative();
          final state = AppState(client: native);
          final target = ValueNotifier<_Target>(_initialTarget);
          await _mount(tester, state, target: target);
          await _requireVerification(tester);
          final pending = Completer<JsonMap>();
          final result = {...native.snapshot, 'needsVerification': false};
          native.response = (method, args) async =>
              method == operation.method ? pending.future : null;
          await _tap(tester, operation.label);
          target.value = next;
          await tester.pump();
          await tester.pump();
          final nextToken = native.token;
          await tester.enterText(_bodyField, 'Replacement local body');
          await tester.pump();
          pending.complete(
            operation.method == _verifyMethod ? {'opened': true} : result,
          );
          await tester.pump();
          expect(_body(tester), 'Replacement local body');
          expect(_button(_continueLabel), findsNothing);
          expect(native.named('reader.edit.begin'), hasLength(2));
          expect(native.named('reader.edit.save'), hasLength(1));
          expect(native.named('reader.edit.cancel'), isEmpty);
          native.response = null;
          await _tap(tester, '保存修改');
          final save = native.named('reader.edit.save').last.$2;
          expect(save['editToken'], nextToken);
          expect(save['topicID'], next.topic);
          expect(save['floor'], next.floor);
          expect(
            native.named('reader.edit.update').last.$2['content'],
            'Replacement local body',
          );
          await _cleanup(tester, state);
          target.dispose();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }

  for (final wrong in [
    {'editToken': 'other-editor'},
    {'topicID': '18'},
    {'floor': 1},
    {'accessRevision': 1},
  ]) {
    testWidgets('continuation rejects a mismatched response identity $wrong', (
      tester,
    ) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      await _requireVerification(tester);
      native.response = (method, args) async => method == _continueMethod
          ? {...native.snapshot, 'needsVerification': false, ...wrong}
          : null;
      await _tap(tester, _continueLabel);
      expect(_body(tester), 'Local body');
      expect(_title(tester), 'Local title');
      expect(_button(_continueLabel), findsOneWidget);
      expect(find.textContaining('编辑会话已失效'), findsOneWidget);
      expect(tester.widget<DeskButton>(_button(_continueLabel)).onTap, isNull);
      expect(tester.widget<DeskButton>(_button('保存修改')).onTap, isNull);
      expect(native.named('reader.edit.begin'), hasLength(1));
      expect(native.named('reader.edit.save'), hasLength(1));
      expect(await state.flushDrafts(), false);
      await _cleanup(tester, state);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final missingToken in [null, '']) {
    testWidgets(
      'a ready response with invalid editToken $missingToken cannot write',
      (tester) async {
        final native = _VerificationNative();
        native.response = (method, args) async => method == 'reader.edit.begin'
            ? {...native.snapshot, 'editToken': missingToken}
            : null;
        final state = AppState(client: native);
        await _mount(tester, state);
        expect(find.text('未取得有效的编辑会话，请重试。'), findsOneWidget);
        expect(_bodyField, findsNothing);
        final save = _button('保存修改');
        if (save.evaluate().isNotEmpty) {
          expect(tester.widget<DeskButton>(save).onTap, isNull);
        }
        expect(native.named('reader.edit.update'), isEmpty);
        expect(native.named('reader.edit.save'), isEmpty);
        expect(native.named(_continueMethod), isEmpty);
        await _tap(tester, '取消编辑');
        await tester.pumpAndSettle();
        expect(native.named('reader.edit.cancel'), isEmpty);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'cancelling the discard dialog retains verification and explicit discard uses the same token',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      await _requireVerification(tester);
      final identity = native.snapshot;
      await _tap(tester, '取消编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
      await tester.pumpAndSettle();
      expect(_body(tester), 'Local body');
      expect(_button(_continueLabel), findsOneWidget);
      expect(native.named('reader.edit.cancel'), isEmpty);
      await _tap(tester, '取消编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
      await tester.pumpAndSettle();
      final cancel = native.named('reader.edit.cancel').single.$2;
      expect(cancel['editToken'], identity['editToken']);
      expect(cancel['topicID'], '17');
      expect(cancel['floor'], 0);
      expect(find.byType(InlineEditScreen), findsNothing);
      expect(native.named('reader.edit.save'), hasLength(1));
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a replaced editor can discard locally without cancelling the current native editor',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      await _requireVerification(tester);
      final oldToken = native.token;
      final replacement = await native.call('reader.edit.begin', {
        'topicID': '17',
        'url': 'https://www.nodeseek.com/post-17-1',
        'floor': 1,
      });
      await native.call('reader.edit.update', {
        'topicID': '17',
        'url': 'https://www.nodeseek.com/post-17-1',
        'floor': 1,
        'editToken': replacement['editToken'],
        'content': 'Current native editor must survive',
      });
      await _tap(tester, '取消编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(InlineEditScreen), findsNothing);
      expect(
        native.named('reader.edit.cancel').single.$2['editToken'],
        oldToken,
      );
      expect(native.named('reader.edit.cancel').single.$2['floor'], 0);
      expect(native.token, replacement['editToken']);
      expect(native.content, 'Current native editor must survive');
      expect(native.named('reader.edit.save'), hasLength(1));
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'ordinary cancellation failure retains the editor and allows explicit retry',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      await _requireVerification(tester);
      var attempts = 0;
      native.response = (method, args) async {
        if (method == 'reader.edit.cancel' && attempts++ == 0) {
          throw const NativeFailure('offline', 'Fixture cancellation offline');
        }
        return null;
      };
      await _tap(tester, '取消编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(InlineEditScreen), findsOneWidget);
      expect(_body(tester), 'Local body');
      expect(_title(tester), 'Local title');
      expect(native.named('reader.edit.cancel'), hasLength(1));
      expect(await state.flushDrafts(), false);
      await _tap(tester, '取消编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(InlineEditScreen), findsNothing);
      expect(native.named('reader.edit.cancel'), hasLength(2));
      expect(native.named('reader.edit.save'), hasLength(1));
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final wrong in [
    {'editToken': 'other-editor'},
    {'topicID': '18'},
    {'floor': 1},
    {'accessRevision': 1},
  ]) {
    testWidgets(
      'a cancellation receipt with wrong identity $wrong cannot close the editor',
      (tester) async {
        final native = _VerificationNative();
        final state = AppState(client: native);
        await _mount(tester, state);
        await _requireVerification(tester);
        native.response = (method, args) async => method == 'reader.edit.cancel'
            ? {...native.snapshot, 'ready': false, ...wrong}
            : null;
        await _tap(tester, '取消编辑');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
        await tester.pumpAndSettle();
        expect(find.byType(InlineEditScreen), findsOneWidget);
        expect(_body(tester), 'Local body');
        expect(_title(tester), 'Local title');
        expect(native.named('reader.edit.cancel'), hasLength(1));
        expect(native.named('reader.edit.save'), hasLength(1));
        expect(await state.flushDrafts(), false);
        await _cleanup(tester, state);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }
  testWidgets(
    'short window keeps usable editor with long verification notice',
    (tester) async {
      final native = _VerificationNative();
      final state = AppState(client: native);
      await _mount(tester, state);
      final field = tester.element(_bodyField);
      native.response = (method, _) async {
        if (method != 'reader.edit.save') return null;
        native.needsVerification = true;
        return {
          ...native.snapshot,
          'message': List.filled(20, '请完成站点验证，当前修改仍然保留。').join('\n'),
        };
      };
      await _requireVerification(tester);
      await tester.binding.setSurfaceSize(const Size(780, 540));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_bodyField).height, greaterThanOrEqualTo(150));
      expect(tester.element(_bodyField), same(field));
      expect(_body(tester), 'Local body');
      await tester.ensureVisible(_button(_continueLabel));
      await tester.pumpAndSettle();
      expect(_button(_continueLabel).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(native.named('reader.edit.save'), hasLength(1));
      await _cleanup(tester, state);
    },
  );

  testWidgets('help cannot cover a pending save completion', (tester) async {
    final native = _VerificationNative();
    final state = AppState(client: native);
    await _mount(tester, state);
    final pending = Completer<JsonMap?>();
    native.response = (method, _) async =>
        method == 'reader.edit.save' ? pending.future : null;
    await tester.enterText(_bodyField, 'Changed body');
    await tester.pump();
    await _tap(tester, '保存修改');
    final help = find.byWidgetPredicate(
      (w) => w is DeskIcon && w.label == 'Markdown 帮助',
    );
    expect(tester.widget<DeskIcon>(help).onTap, isNull);
    pending.complete({...native.snapshot, 'accepted': false});
    await tester.pumpAndSettle();
    expect(tester.widget<DeskIcon>(help).onTap, isNotNull);
    expect(_body(tester), 'Changed body');
    await _cleanup(tester, state);
  });
}
