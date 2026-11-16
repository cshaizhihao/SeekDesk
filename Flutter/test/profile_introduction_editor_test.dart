import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/profile_introduction_editor.dart';

const _signatureKey = ValueKey('profile-introduction-signature');
const _readmeKey = ValueKey('profile-introduction-readme');
const _saveKey = ValueKey('profile-introduction-save');
const _discardKey = ValueKey('profile-introduction-discard');
const _original = <String, dynamic>{
  'signature': '  Original signature \n',
  'readme': '\nOriginal **readme**  \n',
  'version': 'fixture-original',
};

class _Native extends NativeClient {
  _Native()
    : super(methods: MethodChannel('seekdesk.test.introduction.${_next++}'));
  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  JsonMap result = {'kind': 'saved'};
  Completer<JsonMap>? saveGate;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      // These are in-memory responses. The fixture never contacts NodeSeek.
      case 'profile.saveIntroduction':
        return saveGate?.future ?? Future.value(result);
      case 'session.verify':
      case 'session.signIn':
        return {};
      default:
        unexpected.add(method);
        throw StateError('Unexpected introduction fixture operation: $method');
    }
  }

  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);
}

class _Fixture {
  _Fixture() {
    state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'owner': 1};
  }
  final native = _Native();
  late final AppState state;
  AppState? replacement;
  final controller = ProfileIntroductionEditorController();
  final key = GlobalKey<_HarnessState>();
  final closes = <bool>[];
  JsonMap original = Map.of(_original);
  bool visible = true;
  double scale = 1;

  void update(VoidCallback change) => key.currentState!.update(change);

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(980, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.setSurfaceSize(null);
      expect(native.unexpected, isEmpty);
    });
    await tester.pumpWidget(_Harness(key: key, fixture: this));
    await _frames(tester);
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.fixture, super.key});
  final _Fixture fixture;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    final f = widget.fixture;
    return GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) =>
            ExtensionOverlays(state: f.replacement ?? f.state, child: child!),
        home: CupertinoPageScaffold(
          child: LayoutBuilder(
            builder: (context, bounds) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: bounds.biggest,
                textScaler: TextScaler.linear(f.scale),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Account page header'),
                    const SizedBox(height: 12),
                    Expanded(
                      child: f.visible
                          ? ProfileIntroductionEditor(
                              state: f.replacement ?? f.state,
                              original: f.original,
                              controller: f.controller,
                              onClose: (saved) => update(() {
                                f.closes.add(saved);
                                f.visible = false;
                              }),
                            )
                          : const Text('Account details'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Finder _field(Key key) => find.byKey(key, skipOffstage: false);
TextEditingController _text(WidgetTester tester, Key key) =>
    tester.widget<CupertinoTextField>(_field(key)).controller!;
DeskButton _button(WidgetTester tester, Key key) =>
    tester.widget<DeskButton>(find.byKey(key));
Finder _label(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _enter(WidgetTester tester, Key key, String text) async {
  await tester.ensureVisible(_field(key));
  await tester.enterText(_field(key), text);
  await _frames(tester);
}

void _mode(WidgetTester tester, int value) => tester
    .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
    .onSegmentSelected(value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'inline save preserves raw whitespace and the initial conflict snapshot',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      expect(find.text('Account page header'), findsOneWidget);
      expect(find.byType(Navigator), findsOneWidget);
      expect(await f.state.flushDrafts(), isTrue);
      expect(_text(tester, _signatureKey).text, _original['signature']);
      expect(_text(tester, _readmeKey).text, _original['readme']);
      expect(_button(tester, _saveKey).onTap, isNull);
      const draft = '  New signature with trailing spaces  \n';
      await _enter(tester, _signatureKey, draft);
      final staleSave = _button(tester, _saveKey).onTap!;
      await _enter(tester, _signatureKey, _original['signature']! as String);
      staleSave();
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction'), isEmpty);
      await _enter(tester, _signatureKey, draft);
      f.update(
        () => f.original = {
          'signature': 'External update',
          'readme': 'Different',
        },
      );
      await _frames(tester);
      expect(_text(tester, _signatureKey).text, draft);
      expect(await f.state.flushDrafts(), isFalse);
      expect(_button(tester, _saveKey).tint, CupertinoColors.systemGreen);
      expect(
        tester.getRect(find.byKey(_discardKey)).right,
        lessThan(tester.getRect(find.byKey(_saveKey)).left),
      );
      _button(tester, _saveKey).onTap!();
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction').single.$2, {
        'original': _original,
        'draft': {'signature': draft, 'readme': _original['readme']},
      });
      expect(f.closes, [true]);
      expect(find.text('Account page header'), findsOneWidget);
      expect(find.text('Account details'), findsOneWidget);
      expect(find.byType(DeskDialog), findsNothing);
      expect(await f.state.flushDrafts(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'close controller shares one discard dialog and cancel retains the exact draft',
    (tester) async {
      final f = _Fixture();
      expect(await f.controller.requestClose(), isTrue);
      await f.mount(tester);
      await _enter(tester, _readmeKey, '  Unsaved introduction\n');
      final first = f.controller.requestClose();
      final duplicate = f.controller.requestClose();
      await _frames(tester);
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(_button(tester, _saveKey).onTap, isNull);
      await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
      await _frames(tester);
      expect(await first, isFalse);
      expect(await duplicate, isFalse);
      expect(f.closes, isEmpty);
      expect(_text(tester, _readmeKey).text, '  Unsaved introduction\n');
      final confirmed = f.controller.requestClose();
      await _frames(tester);
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
      await _frames(tester);
      expect(await confirmed, isTrue);
      expect(f.closes, [false]);
      expect(find.text('Account details'), findsOneWidget);
      expect(f.native.named('profile.saveIntroduction'), isEmpty);
      expect(await f.controller.requestClose(), isTrue);
      expect(await f.state.flushDrafts(), isTrue);
    },
  );

  testWidgets('clean close is inline and never pops the account route', (
    tester,
  ) async {
    final f = _Fixture();
    expect(f.controller.isAttached, isFalse);
    await f.mount(tester);
    expect(f.controller.isAttached, isTrue);
    expect(await f.controller.requestClose(), isTrue);
    await _frames(tester);
    expect(f.controller.isAttached, isFalse);
    expect(f.closes, [false]);
    expect(find.text('Account page header'), findsOneWidget);
    expect(find.text('Account details'), findsOneWidget);
    expect(find.byType(DeskDialog), findsNothing);
    expect(f.native.calls, isEmpty);
  });

  testWidgets(
    'save is single flight and an old-account result keeps the draft open',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _enter(tester, _signatureKey, 'Keep this signature');
      f.native.saveGate = Completer<JsonMap>();
      final send = _button(tester, _saveKey).onTap!;
      send();
      send();
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction'), hasLength(1));
      expect(_button(tester, _saveKey).busy, isTrue);
      expect(await f.controller.requestClose(), isFalse);
      expect(find.byType(DeskDialog), findsNothing);
      expect(
        tester.widget<CupertinoTextField>(_field(_signatureKey)).readOnly,
        isTrue,
      );
      f.native.accessRevision = 1;
      f.state.domains['session'] = {'account': 'signedIn', 'owner': 2};
      f.state.showMessage('Fixture identity changed');
      f.native.saveGate!.complete({'kind': 'saved', 'accessRevision': 0});
      await _frames(tester);
      expect(f.closes, isEmpty);
      expect(_text(tester, _signatureKey).text, 'Keep this signature');
      expect(find.text('账号已经变化，本次返回结果不会应用到当前账号。输入已保留。'), findsOneWidget);
      send();
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction'), hasLength(1));
      expect(find.text('账号已经变化，请关闭后重新打开当前账号资料。'), findsOneWidget);
      expect(await f.state.flushDrafts(), isFalse);
    },
  );

  for (final nextSession in [
    <String, dynamic>{'account': 'signedIn', 'owner': 2},
    <String, dynamic>{'account': 'signedOut', 'owner': 1},
  ]) {
    testWidgets(
      'session ${nextSession['account']}/${nextSession['owner']} change before revision blocks old draft saving',
      (tester) async {
        final f = _Fixture();
        await f.mount(tester);
        await _enter(tester, _signatureKey, 'Old owner unsaved signature');
        final save = _button(tester, _saveKey).onTap!;
        f.state.domains['session'] = nextSession;
        f.state.showMessage('Fixture session update before revision');
        save();
        await _frames(tester);
        expect(f.native.accessRevision, 0);
        expect(f.native.named('profile.saveIntroduction'), isEmpty);
        expect(find.text('账号已经变化，请关闭后重新打开当前账号资料。'), findsOneWidget);
        expect(
          _text(tester, _signatureKey).text,
          'Old owner unsaved signature',
        );
        expect(f.closes, isEmpty);
        expect(await f.state.flushDrafts(), isFalse);
      },
    );
  }

  testWidgets(
    'replacing AppState keeps the live application guarded until the retained draft is discarded',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _enter(tester, _signatureKey, 'Keep across source replacement');
      final field = tester.element(_field(_signatureKey));
      final nextNative = _Native(), lastNative = _Native();
      final next = AppState(client: nextNative),
          last = AppState(client: lastNative);
      addTearDown(() {
        next.dispose();
        last.dispose();
      });
      next.domains['session'] = last.domains['session'] = {
        'account': 'signedIn',
        'owner': 1,
      };
      f.update(() => f.replacement = next);
      await _frames(tester);
      expect(tester.element(_field(_signatureKey)), same(field));
      expect(await f.state.flushDrafts(), isFalse);
      expect(await next.flushDrafts(), isFalse);
      _button(tester, _saveKey).onTap!();
      await _frames(tester);
      expect(find.text('账号已经变化，请关闭后重新打开当前账号资料。'), findsOneWidget);
      expect(f.native.named('profile.saveIntroduction'), isEmpty);
      expect(nextNative.calls, isEmpty);

      f.update(() => f.replacement = last);
      await _frames(tester);
      expect(await next.flushDrafts(), isTrue);
      expect(await last.flushDrafts(), isFalse);
      expect(await f.state.flushDrafts(), isFalse);
      last.domains['extensions'] = {
        'items': [
          {'id': 'office', 'active': true},
        ],
        'settings': {
          'office': {'presented': true},
        },
      };
      last.showMessage('Replacement app cover');
      await _frames(tester);
      expect(await f.controller.requestClose(), isFalse);
      expect(find.byType(DeskDialog), findsNothing);
      last.domains['extensions'] = {};
      last.showMessage('Replacement app restored');
      await _frames(tester);
      final close = f.controller.requestClose();
      await _frames(tester);
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃编辑'));
      await _frames(tester);
      expect(await close, isTrue);
      expect(await f.state.flushDrafts(), isTrue);
      expect(await next.flushDrafts(), isTrue);
      expect(await last.flushDrafts(), isTrue);
      expect(f.closes, [false]);
      expect(nextNative.calls, isEmpty);
      expect(lastNative.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'IME composition blocks preview, stale save, close and app termination',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _enter(tester, _signatureKey, 'draft');
      final save = _button(tester, _saveKey).onTap!;
      final text = _text(tester, _signatureKey);
      text.value = const TextEditingValue(
        text: 'draft 拼',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 6, end: 7),
      );
      await _frames(tester);
      save();
      _mode(tester, 1);
      expect(await f.controller.requestClose(), isFalse);
      expect(await f.state.flushDrafts(), isFalse);
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction'), isEmpty);
      expect(find.byType(MarkdownDocument), findsNothing);
      expect(_field(_signatureKey).hitTestable(), findsOneWidget);
      expect(find.byType(DeskDialog), findsNothing);
      text.value = text.value.copyWith(composing: TextRange.empty);
      await _frames(tester);
      expect(_button(tester, _saveKey).onTap, isNotNull);
    },
  );

  testWidgets(
    'unmounting during a save releases guards and ignores the late completion',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _enter(tester, _signatureKey, 'Retired editor draft');
      f.native.saveGate = Completer<JsonMap>();
      _button(tester, _saveKey).onTap!();
      await _frames(tester);
      f.update(() => f.visible = false);
      await _frames(tester);
      expect(await f.controller.requestClose(), isTrue);
      expect(await f.state.flushDrafts(), isTrue);
      f.native.saveGate!.complete({'kind': 'saved'});
      await _frames(tester);
      expect(f.closes, isEmpty);
      expect(find.text('Account details'), findsOneWidget);
      expect(f.native.named('profile.saveIntroduction'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview retains fields and selection while links cannot leave the editor',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      const markdown = '  [Profile reference](https://example.com/reference)\n';
      await _enter(tester, _readmeKey, markdown);
      final field = tester.element(_field(_readmeKey));
      final text = _text(tester, _readmeKey);
      text.selection = const TextSelection(baseOffset: 2, extentOffset: 8);
      _mode(tester, 1);
      await _frames(tester);
      final link = find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().trim() == 'Profile reference',
      );
      await tester.ensureVisible(link);
      final render = tester.renderObject<RenderParagraph>(link);
      final box = render
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .first;
      await tester.tapAt(render.localToGlobal(box.toRect().center));
      await _frames(tester);
      expect(f.native.calls, isEmpty);
      expect(f.closes, isEmpty);
      expect(tester.element(_field(_readmeKey)), same(field));
      _mode(tester, 0);
      await _frames(tester);
      expect(_text(tester, _readmeKey), same(text));
      expect(text.text, markdown);
      expect(
        text.selection,
        const TextSelection(baseOffset: 2, extentOffset: 8),
      );
      expect(
        tester.widget<CupertinoTextField>(_field(_readmeKey)).selectAllOnFocus,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('macOS select all affects only the focused introduction field', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await tester.showKeyboard(_field(_signatureKey));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await _frames(tester);
    final signature = _text(tester, _signatureKey);
    expect(
      signature.selection,
      TextSelection(baseOffset: 0, extentOffset: signature.text.length),
    );
    expect(_text(tester, _readmeKey).selection.isCollapsed, isTrue);
    expect(f.native.calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final failure in [
    (
      kind: 'conflict',
      message: '资料已在其他地方被修改。请先复制保留本次编辑，再重新读取资料。',
      recovery: '',
    ),
    (
      kind: 'verification',
      message: '请先完成 NodeSeek 站点验证，当前输入已保留。',
      recovery: 'session.verify',
    ),
    (
      kind: 'signedOut',
      message: '登录已失效。请重新登录后再操作，当前输入已保留。',
      recovery: 'session.signIn',
    ),
    (kind: 'rejected', message: 'NodeSeek 拒绝了这次更新，当前输入已保留。', recovery: ''),
    (kind: 'unavailable', message: '暂时无法保存个人资料，请稍后重试。当前输入已保留。', recovery: ''),
    (kind: 'unknown', message: '没有确认保存成功，请保留内容并重新检查账号资料。', recovery: ''),
  ]) {
    testWidgets(
      '${failure.kind} preserves raw input and exposes only its recovery',
      (tester) async {
        final f = _Fixture();
        f.native.result = {'kind': failure.kind};
        await f.mount(tester);
        const draft = '\n Unsaved signature  \n';
        await _enter(tester, _signatureKey, draft);
        _button(tester, _saveKey).onTap!();
        await _frames(tester);
        expect(find.text(failure.message), findsOneWidget);
        expect(_text(tester, _signatureKey).text, draft);
        expect(f.closes, isEmpty);
        expect(await f.state.flushDrafts(), isFalse);
        if (failure.recovery.isEmpty) {
          expect(_label('验证访问'), findsNothing);
          expect(_label('登录 NodeSeek'), findsNothing);
        } else {
          final label = failure.recovery == 'session.verify'
              ? '验证访问'
              : '登录 NodeSeek';
          await tester.ensureVisible(_label(label));
          await tester.tap(_label(label));
          await _frames(tester);
          expect(f.native.named(failure.recovery), hasLength(1));
          if (failure.recovery == 'session.verify') {
            expect(f.native.named(failure.recovery).single.$2, {
              'url': 'https://www.nodeseek.com/setting',
            });
          }
        }
        expect(f.native.named('profile.saveIntroduction'), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'office overlay removes focus and blocks captured save and close callbacks',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _enter(tester, _signatureKey, 'Covered draft');
      await tester.showKeyboard(_field(_signatureKey));
      final save = _button(tester, _saveKey).onTap!;
      f.state.domains['extensions'] = {
        'items': [
          {'id': 'office', 'active': true},
        ],
        'settings': {
          'office': {'presented': true},
        },
      };
      f.state.showMessage('Fixture office cover');
      await _frames(tester);
      expect(
        tester
            .widget<CupertinoTextField>(_field(_signatureKey))
            .focusNode!
            .hasFocus,
        isFalse,
      );
      save();
      expect(await f.controller.requestClose(), isFalse);
      await _frames(tester);
      expect(f.native.named('profile.saveIntroduction'), isEmpty);
      expect(find.byType(DeskDialog), findsNothing);
      expect(f.closes, isEmpty);
    },
  );

  testWidgets(
    'short narrow embedded editor keeps actions available above a long error',
    (tester) async {
      final f = _Fixture()..scale = 2;
      f.native.result = {
        'kind': 'rejected',
        'message': List.filled(30, '本地测试保存失败，输入已保留。').join('\n'),
      };
      await f.mount(tester, size: const Size(340, 460));
      await _enter(tester, _signatureKey, 'Unsaved narrow draft');
      _button(tester, _saveKey).onTap!();
      await _frames(tester);
      expect(find.byKey(_saveKey).hitTestable(), findsOneWidget);
      expect(find.byKey(_discardKey).hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.byKey(_saveKey)).right,
        lessThanOrEqualTo(324),
      );
      await tester.scrollUntilVisible(
        _field(_readmeKey),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('profile-introduction-content')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 40,
      );
      await _frames(tester);
      expect(_field(_readmeKey).hitTestable(), findsOneWidget);
      expect(find.byKey(_saveKey).hitTestable(), findsOneWidget);
      expect(find.text('Account page header').hitTestable(), findsOneWidget);
      expect(_text(tester, _signatureKey).text, 'Unsaved narrow draft');
      expect(f.closes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
