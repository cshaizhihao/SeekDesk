import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _AccountVisualNative extends NativeClient {
  _AccountVisualNative()
    : super(methods: MethodChannel('seekdesk.test.account.visual.${_next++}'));

  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return await response?.call(method, arguments) ?? {};
  }

  Iterable<(String, JsonMap)> requests(String method) =>
      calls.where((call) => call.$1 == method);
}

const _originalSignature = 'Original forum signature';
const _originalReadme = 'Original Markdown introduction';

JsonMap _profile({int id = 1, String name = 'Fixture account'}) => {
  'id': id,
  'name': name,
  'avatar': '',
  'rank': 7,
  'roles': [
    {'display_text': 'Patron'},
    {'display_text': 'Member'},
  ],
  'bio': 'A member of the NodeSeek community.',
  'topics': 120,
  'replies': 318,
  'following': 12,
  'followers': 42,
  'coin': 589,
};

AppState _owner(_AccountVisualNative native) {
  final state = AppState(client: native);
  state.domains['session'] = {
    'account': 'signedIn',
    'owner': 1,
    'profile': _profile(),
  };
  native.response = (method, args) async => switch (method) {
    'profile.load' => {'account': 'signedIn', 'profile': _profile()},
    'profile.introduction' => {
      'kind': 'ready',
      'data': {'signature': _originalSignature, 'readme': _originalReadme},
    },
    _ => {},
  };
  return state;
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

Offset _linkPoint(WidgetTester tester, String text) {
  final render = tester.renderObject<RenderParagraph>(_paragraph(text));
  final box = render
      .getBoxesForSelection(const TextSelection(baseOffset: 1, extentOffset: 2))
      .first;
  return render.localToGlobal(box.toRect().center);
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1100, 1100),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CupertinoPageScaffold(child: child),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump(const Duration(seconds: 6));
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.ensureVisible(_button('编辑签名与简介'));
  await tester.tap(_button('编辑签名与简介'));
  // Cupertino routes take 500 ms in the pinned Flutter SDK. During that
  // transition the profile is still onstage and editor semantics are excluded.
  await tester.pumpAndSettle();
  expect(find.text('编辑个人资料'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'unchanged profile cannot save and reverting restores disabled save',
    (tester) async {
      final native = _AccountVisualNative();
      final state = _owner(native);
      await _mount(tester, AccountScreen(state: state));
      await _openEditor(tester);
      expect(tester.widget<DeskButton>(_button('保存资料')).onTap, isNull);
      await tester.tap(_button('保存资料'), warnIfMissed: false);
      await tester.pump();
      expect(native.requests('profile.saveIntroduction'), isEmpty);

      final signature = find.byType(CupertinoTextField).first;
      await tester.enterText(signature, 'A changed signature');
      await tester.pump();
      final staleSave = tester.widget<DeskButton>(_button('保存资料')).onTap!;
      await tester.enterText(signature, _originalSignature);
      await tester.pump();
      expect(tester.widget<DeskButton>(_button('保存资料')).onTap, isNull);
      staleSave();
      await tester.pump();
      expect(native.requests('profile.saveIntroduction'), isEmpty);
      expect(find.text('编辑个人资料'), findsOneWidget);
      await _cleanup(tester, state);
    },
  );

  testWidgets(
    'a saved result from the previous account cannot close or erase an editor',
    (tester) async {
      final native = _AccountVisualNative();
      final state = _owner(native);
      final saved = Completer<JsonMap>();
      final baseline = native.response!;
      native.response = (method, args) => method == 'profile.saveIntroduction'
          ? saved.future
          : baseline(method, args);
      await _mount(tester, AccountScreen(state: state));
      await _openEditor(tester);
      await tester.enterText(
        find.byType(CupertinoTextField).first,
        'Keep my edited signature',
      );
      await tester.enterText(
        find.byType(CupertinoTextField).last,
        'Keep my **edited introduction**',
      );
      await tester.pump();
      final save = tester.widget<DeskButton>(_button('保存资料')).onTap!;
      save();
      save();
      await tester.pump();
      expect(native.requests('profile.saveIntroduction'), hasLength(1));
      expect(tester.widget<DeskButton>(_button('保存资料')).busy, isTrue);
      expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNull);

      native.accessRevision = 1;
      state.domains['session'] = {'account': 'signedIn', 'owner': 2};
      state.showMessage('Fixture account changed');
      saved.complete({'kind': 'saved', 'accessRevision': 0});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('编辑个人资料'), findsOneWidget);
      expect(find.text('Keep my edited signature'), findsOneWidget);
      expect(find.text('Keep my **edited introduction**'), findsOneWidget);
      expect(find.text('账号已经变化，本次返回结果不会应用到当前账号。输入已保留。'), findsOneWidget);
      expect(tester.widget<DeskButton>(_button('保存资料')).busy, isFalse);
      expect(find.byType(DeskDialog), findsNothing);
      expect(native.requests('profile.saveIntroduction'), hasLength(1));
      await _cleanup(tester, state);
    },
  );

  testWidgets(
    'retargeting the same account screen rejects the old member response',
    (tester) async {
      final native = _AccountVisualNative();
      final state = AppState(client: native);
      final oldMember = Completer<JsonMap>();
      var memberId = 41;
      late StateSetter changeMember;
      native.response = (method, args) async {
        if (method != 'profile.load') return {};
        if (args['id'] == 41) return oldMember.future;
        return _profile(id: 42, name: 'Current member B');
      };
      await _mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            changeMember = setState;
            return AccountScreen(
              key: const ValueKey('retained-account'),
              state: state,
              memberId: memberId,
            );
          },
        ),
      );
      final element = tester.element(find.byType(AccountScreen));
      expect(native.requests('profile.load').single.$2['id'], 41);
      changeMember(() => memberId = 42);
      await tester.pump();
      expect(tester.element(find.byType(AccountScreen)), same(element));
      oldMember.complete(_profile(id: 41, name: 'Obsolete member A'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Obsolete member A'), findsNothing);
      expect(find.text('Current member B'), findsOneWidget);
      expect(find.text('NodeSeek · #42'), findsOneWidget);
      expect(native.requests('profile.load').map((call) => call.$2['id']), [
        41,
        42,
      ]);
      expect(tester.takeException(), isNull);
      await _cleanup(tester, state);
    },
  );

  testWidgets('ready empty introduction still opens a blank editable profile', (
    tester,
  ) async {
    final native = _AccountVisualNative();
    final state = _owner(native);
    final baseline = native.response!;
    native.response = (method, args) async => method == 'profile.introduction'
        ? {'kind': 'ready', 'data': <String, dynamic>{}}
        : baseline(method, args);
    await _mount(tester, AccountScreen(state: state));
    expect(find.text('Fixture account'), findsOneWidget);
    await _openEditor(tester);
    final fields = tester.widgetList<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    expect(fields, hasLength(2));
    expect(fields.map((field) => field.controller!.text), ['', '']);
    expect(fields.every((field) => field.enabled != false), isTrue);
    expect(tester.widget<DeskButton>(_button('保存资料')).onTap, isNull);
    await tester.enterText(
      find.byType(CupertinoTextField).last,
      'My first README',
    );
    await tester.pump();
    expect(tester.widget<DeskButton>(_button('保存资料')).onTap, isNotNull);
    expect(native.requests('profile.saveIntroduction'), isEmpty);
    await _cleanup(tester, state);
  });

  testWidgets(
    'introduction verification preserves basic profile and retries independently',
    (tester) async {
      final native = _AccountVisualNative();
      final state = _owner(native);
      final baseline = native.response!;
      final retry = Completer<JsonMap>();
      var reads = 0;
      native.response = (method, args) async {
        if (method != 'profile.introduction') return baseline(method, args);
        reads++;
        if (reads == 1) return {'kind': 'verification'};
        return retry.future;
      };
      await _mount(tester, AccountScreen(state: state));
      expect(find.text('Fixture account'), findsOneWidget);
      expect(find.text('NodeSeek · #1'), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsNothing);
      expect(_button('登录 NodeSeek'), findsNothing);
      await tester.ensureVisible(_button('验证访问'));
      await tester.tap(_button('验证访问'));
      await tester.pump();
      expect(native.requests('session.verify').single.$2, {
        'url': 'https://www.nodeseek.com/',
      });
      final retryButton = _button('重新读取简介');
      expect(retryButton, findsOneWidget);
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
      await tester.pump();
      expect(reads, 2);
      expect(native.requests('profile.load'), hasLength(1));
      expect(find.text('Fixture account'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsNothing);
      retry.complete({
        'kind': 'ready',
        'data': {
          'signature': 'Recovered signature',
          'readme': 'Recovered introduction',
        },
      });
      await tester.pump();
      expect(find.text('Fixture account'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsOneWidget);
      expect(_button('验证访问'), findsNothing);
      expect(native.requests('session.signIn'), isEmpty);
      await _openEditor(tester);
      expect(
        tester
            .widgetList<CupertinoTextField>(find.byType(CupertinoTextField))
            .map((field) => field.controller!.text),
        ['Recovered signature', 'Recovered introduction'],
      );
      await _cleanup(tester, state);
    },
  );

  testWidgets(
    'failed introduction remains retryable without hiding basic account data',
    (tester) async {
      final native = _AccountVisualNative();
      final state = _owner(native);
      final baseline = native.response!;
      var reads = 0;
      native.response = (method, args) async {
        if (method != 'profile.introduction') return baseline(method, args);
        reads++;
        if (reads == 1) {
          return {'kind': 'failed', 'message': 'Fixture introduction timeout'};
        }
        return {'kind': 'ready', 'data': <String, dynamic>{}};
      };
      await _mount(tester, AccountScreen(state: state));
      expect(find.text('Fixture account'), findsOneWidget);
      expect(find.text('318'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsNothing);
      expect(_button('验证访问'), findsNothing);
      expect(_button('登录 NodeSeek'), findsNothing);
      final retryButton = _button('重新读取简介');
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
      await tester.pump();
      expect(reads, 2);
      expect(native.requests('profile.load'), hasLength(1));
      expect(find.text('Fixture account'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsOneWidget);
      expect(retryButton, findsNothing);
      expect(tester.takeException(), isNull);
      await _cleanup(tester, state);
    },
  );

  testWidgets(
    'editor fields expose names and preview links cannot navigate away',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = _AccountVisualNative();
      final state = _owner(native);
      await _mount(tester, AccountScreen(state: state));
      await _openEditor(tester);
      for (final label in ['论坛签名', '个人简介']) {
        final editable = find.semantics
            .byLabel(label)
            .evaluate()
            .where(
              (node) => node.getSemanticsData().flagsCollection.isTextField,
            );
        expect(
          editable,
          hasLength(1),
          reason: '$label needs an accessible field name.',
        );
      }
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
            .minLines,
        7,
      );
      await tester.enterText(
        find.byType(CupertinoTextField).first,
        '[Signature link](https://example.com/signature)',
      );
      await tester.enterText(
        find.byType(CupertinoTextField).last,
        '[README link](https://example.com/readme)',
      );
      await tester.tap(find.text('预览'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      for (final label in ['Signature link', 'README link']) {
        await tester.ensureVisible(_paragraph(label));
        await tester.tapAt(_linkPoint(tester, label));
        await tester.pump();
      }
      expect(native.requests('external.open'), isEmpty);
      expect(native.requests('reader.open'), isEmpty);
      expect(find.text('编辑个人资料'), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pump();
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
            .controller!
            .text,
        '[Signature link](https://example.com/signature)',
      );
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).last)
            .controller!
            .text,
        '[README link](https://example.com/readme)',
      );
      await _cleanup(tester, state);
      semantics.dispose();
    },
  );

  for (final failure in [
    (
      kind: 'conflict',
      message: '资料已在其他地方被修改。请先复制保留本次编辑，再重新读取资料。',
      recovery: '',
      method: '',
    ),
    (
      kind: 'verification',
      message: '请先完成 NodeSeek 站点验证，当前输入已保留。',
      recovery: '验证访问',
      method: 'session.verify',
    ),
    (
      kind: 'signedOut',
      message: '登录已失效。请重新登录后再操作，当前输入已保留。',
      recovery: '登录 NodeSeek',
      method: 'session.signIn',
    ),
    (
      kind: 'rejected',
      message: 'NodeSeek 拒绝了这次更新，当前输入已保留。',
      recovery: '',
      method: '',
    ),
    (
      kind: 'unavailable',
      message: '暂时无法保存个人资料，请稍后重试。当前输入已保留。',
      recovery: '',
      method: '',
    ),
  ]) {
    testWidgets(
      'typed ${failure.kind} save retains content and offers only its recovery',
      (tester) async {
        final native = _AccountVisualNative();
        final state = _owner(native);
        final baseline = native.response!;
        native.response = (method, args) async =>
            method == 'profile.saveIntroduction'
            ? {'kind': failure.kind}
            : baseline(method, args);
        await _mount(tester, AccountScreen(state: state));
        await _openEditor(tester);
        await tester.enterText(
          find.byType(CupertinoTextField).first,
          'Unsaved signature',
        );
        await tester.pump();
        await tester.tap(_button('保存资料'));
        await tester.pump();
        expect(find.text('编辑个人资料'), findsOneWidget);
        expect(
          tester
              .widgetList<CupertinoTextField>(find.byType(CupertinoTextField))
              .map((field) => field.controller!.text),
          ['Unsaved signature', _originalReadme],
        );
        expect(find.text(failure.message), findsOneWidget);
        expect(native.requests('profile.saveIntroduction'), hasLength(1));
        expect(tester.widget<DeskButton>(_button('保存资料')).busy, isFalse);
        if (failure.recovery.isEmpty) {
          expect(_button('验证访问'), findsNothing);
          expect(_button('登录 NodeSeek'), findsNothing);
        } else {
          expect(
            _button(failure.recovery == '验证访问' ? '登录 NodeSeek' : '验证访问'),
            findsNothing,
          );
          await tester.ensureVisible(_button(failure.recovery));
          await tester.tap(_button(failure.recovery));
          await tester.pump();
          expect(native.requests(failure.method), hasLength(1));
          if (failure.method == 'session.verify') {
            expect(native.requests(failure.method).single.$2, {
              'url': 'https://www.nodeseek.com/setting',
            });
          }
          expect(find.text('编辑个人资料'), findsOneWidget);
          expect(find.text('Unsaved signature'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await _cleanup(tester, state);
      },
    );
  }

  for (final layout in [
    (size: const Size(1400, 1100), scale: 1.0),
    (size: const Size(420, 1100), scale: 2.0),
  ]) {
    testWidgets(
      'account panels stay bounded at ${layout.size.width} wide and ${layout.scale} text scale',
      (tester) async {
        const name = '一个很长但仍然需要完整阅读的社区用户名称用于验证桌面布局';
        final native = _AccountVisualNative();
        final state = _owner(native);
        final baseline = native.response!;
        native.response = (method, args) async => method == 'profile.load'
            ? {'account': 'signedIn', 'profile': _profile(name: name)}
            : baseline(method, args);
        await _mount(
          tester,
          AccountScreen(state: state),
          size: layout.size,
          textScale: layout.scale,
        );
        expect(find.text(name), findsOneWidget);
        expect(find.text('Patron'), findsOneWidget);
        expect(find.text('Member'), findsOneWidget);
        final panels = find.descendant(
          of: find.byType(AccountScreen),
          matching: find.byType(DeskGlassPanel),
        );
        expect(panels, findsWidgets);
        for (final element in panels.evaluate()) {
          final rect = tester.getRect(
            find.byElementPredicate((e) => e == element),
          );
          expect(rect.width, lessThanOrEqualTo(760));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(layout.size.width));
        }
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(_button('编辑签名与简介'));
        await tester.pump();
        expect(_button('编辑签名与简介').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _cleanup(tester, state);
      },
    );
  }

  for (final sample in [
    (
      name: 'paragraph link',
      markdown: '[***Reference***](https://example.com/reference)',
      text: 'Reference',
      allowsNavigation: true,
    ),
    (
      name: 'heading link',
      markdown: '# [***Reference***](https://example.com/reference)',
      text: 'Reference',
      allowsNavigation: true,
    ),
    (
      name: 'table link',
      markdown: '| Entry |\n| --- |\n| [***Reference***](https://example.com/reference) |',
      text: 'Reference',
      allowsNavigation: true,
    ),
    (
      name: 'table bare URL',
      markdown: '| Entry |\n| --- |\n| https://example.com/reference |',
      text: 'https://example.com/reference',
      allowsNavigation: true,
    ),
    (
      name: 'table code literal',
      markdown: '| Entry |\n| --- |\n| `[Reference](https://example.com/reference)` |',
      text: '[Reference](https://example.com/reference)',
      allowsNavigation: false,
    ),
  ]) {
    for (final opensLinks in [false, true]) {
      testWidgets(
        'Markdown ${sample.name} respects ${opensLinks ? 'default' : 'disabled'} pointer and accessibility navigation',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final native = _AccountVisualNative();
          final state = AppState(client: native);
          await _mount(
            tester,
            Padding(
              padding: const EdgeInsets.all(32),
              child: opensLinks
                  ? MarkdownDocument(state: state, text: sample.markdown)
                  : MarkdownDocument(
                      state: state,
                      text: sample.markdown,
                      opensLinks: false,
                    ),
            ),
          );
          expect(find.byType(SelectableRegion), findsOneWidget);
          expect(_paragraph(sample.text), findsOneWidget);
          await tester.tapAt(_linkPoint(tester, sample.text));
          await tester.pump();
          final links = find.semantics.byLabel(sample.text).evaluate();
          final actionable = links.where(
            (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
          );
          if (opensLinks && sample.allowsNavigation) {
            expect(native.requests('external.open'), hasLength(1));
            expect(actionable, hasLength(1));
            final link = actionable.single;
            expect(link.getSemanticsData().flagsCollection.isLink, isTrue);
            tester
                .renderObject(_paragraph(sample.text))
                .owner!
                .semanticsOwner!
                .performAction(link.id, SemanticsAction.tap);
            await tester.pump();
            expect(native.requests('external.open'), hasLength(2));
            expect(native.requests('external.open').last.$2, {
              'url': 'https://example.com/reference',
            });
          } else {
            expect(actionable, isEmpty);
            expect(native.calls, isEmpty);
          }
          expect(tester.takeException(), isNull);
          await _cleanup(tester, state);
          semantics.dispose();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }

  testWidgets(
    'one Markdown selection region copies headings and multiple blocks together',
    (tester) async {
      var clipboard = '';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = stringValue(jsonMap(call.arguments)['text']);
        } else if (call.method == 'Clipboard.getData') {
          return {'text': clipboard};
        } else if (call.method == 'Clipboard.hasStrings') {
          return {'value': clipboard.isNotEmpty};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final native = _AccountVisualNative();
      final state = AppState(client: native);
      await _mount(
        tester,
        Padding(
          padding: const EdgeInsets.all(32),
          child: MarkdownDocument(
            state: state,
            opensLinks: false,
            text:
                '# Reading heading\n\nFirst **bold** paragraph.\n\nSecond paragraph.\n\n'
                '> Quoted paragraph.\n\n| Item |\n| --- |\n| Table body |',
          ),
        ),
      );
      final region = find.byType(SelectableRegion);
      expect(region, findsOneWidget);
      final regionElement = tester.element(region);
      const contents = [
        'Reading heading',
        'First bold paragraph.',
        'Second paragraph.',
        'Quoted paragraph.',
        'Table body',
      ];
      for (final text in contents) {
        final owner = find.ancestor(of: _paragraph(text), matching: region);
        expect(owner, findsOneWidget);
        expect(tester.element(owner), same(regionElement));
      }
      await tester.tapAt(_linkPoint(tester, 'Reading heading'));
      await tester.pump();
      for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyC]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      }
      for (final text in contents) {
        expect(clipboard, contains(text));
      }
      for (var index = 1; index < contents.length; index++) {
        expect(
          clipboard.indexOf(contents[index - 1]),
          lessThan(clipboard.indexOf(contents[index])),
        );
      }
      expect(clipboard, isNot(contains('**')));
      expect(clipboard, isNot(contains('# Reading heading')));
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await _cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
