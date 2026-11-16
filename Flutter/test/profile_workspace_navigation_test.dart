import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_navigation_picker.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/profile_introduction_editor.dart';

const _originalSignature = 'Original local signature';
const _originalReadme = 'Original local introduction';
const _editedSignature = 'Keep this unsaved signature';
const _editedReadme = 'Keep this unsaved Markdown introduction';
const _retainedURL = 'https://www.nodeseek.com/post-991-1';
const _blockedURL = 'https://www.nodeseek.com/post-77001-2#31';
const _chromeChannel = MethodChannel('cc.seekdesk/window-chrome.v1');

class _ProfileChromeHost {
  JsonMap current = {};

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'attach':
        return {'installed': true, 'attachment': 'profile-workspace-test'};
      case 'update':
        current = jsonMap(call.arguments);
        return true;
      case 'detach':
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<void> toggleSidebar(WidgetTester tester) async {
    final response = tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          _chromeChannel.name,
          _chromeChannel.codec.encodeMethodCall(
            MethodCall('perform', {
              'attachment': current['attachment'],
              'generation': current['generation'],
              'action': 'sidebar',
            }),
          ),
          null,
        );
    await tester.idle();
    expect(_chromeChannel.codec.decodeEnvelope((await response)!), isTrue);
    await _frames(tester);
  }
}

/// Every transport here is in memory. Unexpected requests fail teardown even
/// when production code catches the thrown error to display recovery UI.
class _ProfileWorkspaceNative extends NativeClient {
  _ProfileWorkspaceNative()
    : super(
        methods: MethodChannel('seekdesk.test.profile-workspace.${_next++}'),
      );

  static int _next = 0;
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Completer<JsonMap>? saveGate;
  bool allowActivity = false, allowReader = false;
  int menuSequence = 0;
  JsonMap workspace = {
    'posts': <JsonMap>[],
    'tabs': [
      {'id': '991', 'url': _retainedURL, 'title': 'Retained local topic'},
      {
        'id': '992',
        'url': 'https://www.nodeseek.com/post-992-1',
        'title': 'Another retained topic',
      },
    ],
    'selectedTab': '991',
    'showReader': false,
    'board': '',
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap get profile => {
    'id': 1,
    'name': 'Local profile owner',
    'avatar': '',
    'topics': 27,
    'replies': 12,
    'followers': 3,
    'following': 4,
    'coin': 123,
    'rank': 2,
  };
  JsonMap get session => {
    'account': 'signedIn',
    'owner': 1,
    'accessRevision': accessRevision,
    'profile': profile,
    'unread': {'mentions': 0, 'replies': 0, 'messages': 0},
  };
  JsonMap get settings => {
    'appearance': 'light',
    'workspace.sidebarSection': 'boards',
    'workspace.sidebarWidth': 228,
    'workspace.mistBackdrop': false,
  };
  JsonMap get extensions => {'items': <JsonMap>[], 'unread': 0};

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  void navigate(String destination) => eventStream.add({
    'domain': 'navigation',
    'accessRevision': accessRevision,
    'data': {'destination': destination, 'sequence': ++menuSequence},
  });

  void publishUnchangedIdentity() => eventStream.add({
    'domain': 'session',
    'accessRevision': accessRevision,
    'data': session,
  });

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': session,
          'workspace': workspace,
          'settings': settings,
          'extensions': extensions,
        };
      case 'extensions.list':
        return extensions;
      case 'settings.get':
        return settings;
      case 'profile.load':
        if (args['id'] != null && args['id'] != 1) break;
        return {...session, 'profile': profile};
      case 'profile.introduction':
        return {
          'kind': 'ready',
          'accessRevision': accessRevision,
          'data': {'signature': _originalSignature, 'readme': _originalReadme},
        };
      case 'profile.saveIntroduction':
        if (saveGate case final pending?) return pending.future;
        break;
      case 'space.activity':
        final page = args['page'];
        if (!allowActivity ||
            args['memberId'] != 1 ||
            args['route'] != 'discussions' ||
            page is! int ||
            page < 1 ||
            page > 2) {
          break;
        }
        return {
          'route': 'discussions',
          'memberId': 1,
          'page': page,
          'accessRevision': accessRevision,
          'hasNext': page == 1,
          'items': [
            for (var index = 0; index < (page == 1 ? 15 : 12); index++)
              {
                'id': '${70000 + page * 100 + index}-0',
                'postId': 70000 + page * 100 + index,
                'title': 'My topic page $page row $index',
                'floor': 0,
                'text': '',
                'url':
                    'https://www.nodeseek.com/post-${70000 + page * 100 + index}-1',
                'publishedMillis': 1794736800000,
              },
          ],
        };
      case 'reader.open':
        if (!allowReader) break;
        final url = stringValue(args['url']);
        final match = RegExp(
          r'^https://www\.nodeseek\.com/post-(702[0-9]{2})-1$',
        ).firstMatch(url);
        if (match == null || args['id'] != match[1]) break;
        final id = match[1]!;
        workspace = {
          ...workspace,
          'tabs': [
            ...jsonItems(workspace['tabs']).where((item) => item['id'] != id),
            {'id': id, 'url': url, 'title': 'Opened local activity topic'},
          ],
          'selectedTab': id,
          'showReader': true,
        };
        return {'workspace': workspace, 'accessRevision': accessRevision};
      case 'reader.load':
        if (!allowReader ||
            args['url'] != jsonItems(workspace['tabs']).last['url']) {
          break;
        }
        return {
          'url': args['url'],
          'accessRevision': accessRevision,
          'thread': {
            'title': 'Opened local activity topic',
            'root': {
              'id': '0',
              'author': 'Local author',
              'blocks': <JsonMap>[],
            },
            'replies': <JsonMap>[],
            'pages': <JsonMap>[],
          },
        };
    }
    unexpected.add('$method $args');
    throw StateError('Profile workspace fixture rejected $method $args');
  }
}

enum _Departure { sidebarSettings, returnToForum, escape, nativeSettings }

Finder get _footer => find.byKey(const ValueKey('sidebar-footer'));
Finder get _signature =>
    find.byKey(const ValueKey('profile-introduction-signature'));
Finder get _readme => find.byKey(const ValueKey('profile-introduction-readme'));
Finder get _save => find.byKey(const ValueKey('profile-introduction-save'));
Finder get _sections => find.byKey(const ValueKey('profile-space-sections'));
Finder get _activityList =>
    find.byKey(const ValueKey('activity-discussions-list'));
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _footerItem(String label) =>
    find.descendant(of: _footer, matching: find.text(label));

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await _frames(tester);
}

Future<AppState> _mount(
  WidgetTester tester,
  _ProfileWorkspaceNative native, {
  _ProfileChromeHost? chrome,
}) async {
  await tester.binding.setSurfaceSize(const Size(1380, 1000));
  if (chrome != null) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _chromeChannel,
      chrome.handle,
    );
  }
  final state = AppState(client: native);
  await state.connect();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (native.saveGate case final pending? when !pending.isCompleted) {
      pending.complete({'kind': 'unknown'});
    }
    await tester.pump();
    state.dispose();
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 6));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _chromeChannel,
      null,
    );
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: WorkspaceScreen(state: state),
      ),
    ),
  );
  await _frames(tester);
  return state;
}

void _expectMyPage(WidgetTester tester) {
  expect(tester.widget<DeskNavigationPicker>(_footer).selectedIndex, 1);
  expect(find.byType(AccountScreen), findsOneWidget);
  expect(find.byType(PreferencesScreen), findsNothing);
}

void _expectDraft(WidgetTester tester) {
  _expectMyPage(tester);
  expect(find.byType(ProfileIntroductionEditor), findsOneWidget);
  expect(
    tester.widget<CupertinoTextField>(_signature).controller!.text,
    _editedSignature,
  );
  expect(
    tester.widget<CupertinoTextField>(_readme).controller!.text,
    _editedReadme,
  );
}

Future<void> _edit(WidgetTester tester, AppState state) async {
  await _tap(tester, _footerItem('我的'));
  _expectMyPage(tester);
  await _tap(tester, _button('编辑签名与简介'));
  expect(find.byType(ProfileIntroductionEditor), findsOneWidget);
  expect(
    ModalRoute.of(tester.element(find.byType(ProfileIntroductionEditor)))!
        .isFirst,
    isTrue,
    reason: 'Editing belongs to the workspace page, not a pushed route.',
  );
  expect(state.hasWorkspaceLeaveGuard, isTrue);
  await tester.ensureVisible(_signature);
  await tester.enterText(_signature, _editedSignature);
  await tester.ensureVisible(_readme);
  await tester.enterText(_readme, _editedReadme);
  await tester.pump();
  _expectDraft(tester);
}

Future<void> _depart(
  WidgetTester tester,
  _ProfileWorkspaceNative native,
  _Departure departure,
) async {
  switch (departure) {
    case _Departure.sidebarSettings:
      await _tap(tester, _footerItem('设置'));
    case _Departure.returnToForum:
      await _tap(tester, _button('返回论坛'));
    case _Departure.escape:
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus?.context;
      expect(
        focus?.widget is EditableText ||
            focus?.findAncestorStateOfType<EditableTextState>() != null,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
    case _Departure.nativeSettings:
      native.navigate('settings');
      await _frames(tester);
  }
}

Future<void> _answerDiscard(
  WidgetTester tester, {
  required bool discard,
}) async {
  await _tap(
    tester,
    find.widgetWithText(DeskDialogAction, discard ? '放弃编辑' : '取消'),
  );
  // macOS dialog springs can still be reversing after the standard six
  // frames; verify actual completion instead of assuming a fixed duration.
  await tester.pumpAndSettle(
    const Duration(milliseconds: 80),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

void _expectDestination(WidgetTester tester, _Departure departure) {
  if (departure == _Departure.sidebarSettings ||
      departure == _Departure.nativeSettings) {
    expect(tester.widget<DeskNavigationPicker>(_footer).selectedIndex, 3);
    expect(find.byType(PreferencesScreen), findsOneWidget);
  } else {
    expect(tester.widget<DeskNavigationPicker>(_footer).selectedIndex, isNull);
    expect(find.byKey(const ValueKey('forum-list-pane')), findsOneWidget);
  }
  expect(find.byType(ProfileIntroductionEditor), findsNothing);
  expect(find.byType(DeskDialog), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final nativeChrome in [false, true]) {
    testWidgets(
      'cancelled compact sidebar departure returns typing to the profile draft with native chrome $nativeChrome',
      (tester) async {
        final native = _ProfileWorkspaceNative();
        final chrome = nativeChrome ? _ProfileChromeHost() : null;
        final state = await _mount(tester, native, chrome: chrome);
        await _edit(tester, state);
        await tester.binding.setSurfaceSize(const Size(780, 700));
        await _frames(tester);
        final field = tester.widget<CupertinoTextField>(_readme);
        final controller = field.controller!;
        final focus = field.focusNode!;
        controller.selection = const TextSelection.collapsed(offset: 12);
        focus.requestFocus();
        await _frames(tester);
        final before = controller.value;
        expect(focus.hasPrimaryFocus, isTrue);

        if (chrome != null) {
          await chrome.toggleSidebar(tester);
        } else {
          await _tap(
            tester,
            find.byWidgetPredicate(
              (widget) => widget is DeskIcon && widget.label == '打开导航',
            ),
          );
        }
        expect(focus.hasFocus, isFalse);
        await _tap(tester, _footerItem('设置'));
        expect(find.text('放弃个人资料编辑？'), findsOneWidget);
        await _answerDiscard(tester, discard: false);
        expect(find.byType(ProfileIntroductionEditor), findsOneWidget);
        expect(find.byType(PreferencesScreen), findsNothing);
        expect(
          tester.widget<CupertinoTextField>(_readme).controller,
          controller,
        );
        expect(controller.value, before);
        expect(focus.hasPrimaryFocus, isTrue);
        tester.testTextInput.updateEditingValue(
          before.copyWith(
            text:
                '${before.text.substring(0, 12)}!${before.text.substring(12)}',
            selection: const TextSelection.collapsed(offset: 13),
          ),
        );
        await tester.pump();
        expect(controller.text[12], '!');
        expect(native.named('settings.get'), isEmpty);
        expect(native.named('profile.saveIntroduction'), isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  for (final finish in ['dismiss', 'leave', 'covered cancellation']) {
    testWidgets('compact profile sidebar $finish preserves focus ownership', (
      tester,
    ) async {
      final native = _ProfileWorkspaceNative();
      final state = await _mount(tester, native);
      await _edit(tester, state);
      await tester.binding.setSurfaceSize(const Size(780, 700));
      await _frames(tester);
      final field = tester.widget<CupertinoTextField>(_readme);
      final focus = field.focusNode!;
      final controller = field.controller!;
      controller.selection = const TextSelection.collapsed(offset: 12);
      focus.requestFocus();
      await _frames(tester);
      final before = controller.value;
      await _tap(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is DeskIcon && widget.label == '打开导航',
        ),
      );
      expect(focus.hasFocus, isFalse);
      if (finish == 'dismiss') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(controller.value, before);
      } else {
        await _tap(tester, _footerItem('设置'));
        if (finish == 'leave') {
          await _answerDiscard(tester, discard: true);
          expect(find.byType(PreferencesScreen), findsOneWidget);
          expect(find.byType(ProfileIntroductionEditor), findsNothing);
          expect(focus.hasFocus, isFalse);
        } else {
          final navigator = Navigator.of(
            tester.element(find.byType(ProfileIntroductionEditor)),
          );
          await tester.tap(find.widgetWithText(DeskDialogAction, '取消'));
          unawaited(
            navigator.push<void>(
              CupertinoPageRoute<void>(
                builder: (_) => const CupertinoPageScaffold(
                  child: Center(child: Text('New covering page')),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('New covering page'), findsOneWidget);
          expect(focus.hasFocus, isFalse);
          expect(controller.value, before);
          expect(native.named('settings.get'), isEmpty);
        }
      }
      expect(native.named('profile.saveIntroduction'), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final departure in _Departure.values) {
    testWidgets(
      'dirty inline profile ${departure.name} asks once, cancellation stays and confirmation leaves',
      (tester) async {
        final native = _ProfileWorkspaceNative();
        final state = await _mount(tester, native);
        final tabs = state.workspace.tabs
            .map((tab) => (tab.id, tab.url))
            .toList();
        final selected = state.workspace.selectedTab;
        await _edit(tester, state);
        final profileReads = native.named('profile.load').length;
        final introductionReads = native.named('profile.introduction').length;

        await _depart(tester, native, departure);
        expect(find.byType(DeskDialog), findsOneWidget);
        expect(find.text('放弃个人资料编辑？'), findsOneWidget);
        final repeatedGuard = state.prepareWorkspaceLeave();
        if (departure == _Departure.nativeSettings) {
          native.navigate('settings');
        }
        await _frames(tester);
        expect(find.byType(DeskDialog), findsOneWidget);
        await _answerDiscard(tester, discard: false);
        expect(await repeatedGuard, isFalse);
        _expectDraft(tester);
        expect(state.hasWorkspaceLeaveGuard, isTrue);
        expect(await state.flushDrafts(), isFalse);
        expect(find.byType(DeskDialog), findsNothing);
        expect(native.named('settings.get'), isEmpty);

        // A consumed native command must not replay on a later state event.
        native.publishUnchangedIdentity();
        await _frames(tester);
        _expectDraft(tester);
        expect(find.byType(DeskDialog), findsNothing);
        expect(native.named('profile.load'), hasLength(profileReads));
        expect(
          native.named('profile.introduction'),
          hasLength(introductionReads),
        );

        await _depart(tester, native, departure);
        expect(find.byType(DeskDialog), findsOneWidget);
        await _answerDiscard(tester, discard: true);
        _expectDestination(tester, departure);
        expect(state.hasWorkspaceLeaveGuard, isFalse);
        expect(await state.flushDrafts(), isTrue);
        expect(state.workspace.tabs.map((tab) => (tab.id, tab.url)), tabs);
        expect(state.workspace.selectedTab, selected);
        expect(native.named('profile.saveIntroduction'), isEmpty);
        expect(native.named('reader.open'), isEmpty);
        expect(native.named('space.activity'), isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'saving inline profile blocks ${departure.name} without queuing a later departure',
      (tester) async {
        final native = _ProfileWorkspaceNative();
        final state = await _mount(tester, native);
        await _edit(tester, state);
        final gate = Completer<JsonMap>();
        native.saveGate = gate;
        await _tap(tester, _save);
        expect(native.named('profile.saveIntroduction'), hasLength(1));
        expect(tester.widget<DeskButton>(_save).busy, isTrue);
        expect(await state.flushDrafts(), isFalse);

        await _depart(tester, native, departure);
        _expectDraft(tester);
        expect(find.byType(DeskDialog), findsNothing);
        expect(await state.prepareWorkspaceLeave(), isFalse);
        final before = state.navigationRevision;
        await state.openTopic(TopicData({'id': '77001', 'url': _blockedURL}));
        expect(state.navigationRevision, before);
        expect(native.named('reader.open'), isEmpty);
        expect(native.named('settings.get'), isEmpty);

        gate.complete({'kind': 'unknown', 'accessRevision': 0});
        await _frames(tester);
        native.publishUnchangedIdentity();
        await _frames(tester);
        _expectDraft(tester);
        expect(tester.widget<DeskButton>(_save).busy, isFalse);
        expect(find.byType(DeskDialog), findsNothing);
        expect(native.named('settings.get'), isEmpty);
        expect(native.named('profile.saveIntroduction'), hasLength(1));
        expect(native.named('profile.saveIntroduction').single.$2, {
          'original': {
            'signature': _originalSignature,
            'readme': _originalReadme,
          },
          'draft': {'signature': _editedSignature, 'readme': _editedReadme},
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'openTopic cancelled by the real inline editor never opens or selects a reader',
    (tester) async {
      final native = _ProfileWorkspaceNative();
      final state = await _mount(tester, native);
      await _edit(tester, state);
      final navigation = state.navigationRevision;
      final selected = state.workspace.selectedTab;
      final tabs = state.workspace.tabs.map((tab) => tab.id).toList();
      final open = state.openTopic(
        TopicData({'id': '77001', 'url': _blockedURL}),
      );
      await _frames(tester);
      expect(find.byType(DeskDialog), findsOneWidget);
      expect(native.named('reader.open'), isEmpty);
      await _answerDiscard(tester, discard: false);
      await open;
      _expectDraft(tester);
      expect(state.navigationRevision, navigation);
      expect(state.workspace.selectedTab, selected);
      expect(state.workspace.tabs.map((tab) => tab.id), tabs);
      expect(native.named('reader.open'), isEmpty);
      expect(native.named('reader.load'), isEmpty);
      expect(native.named('profile.saveIntroduction'), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'my activity retains its selected section, loaded page and scroll after reading a topic',
    (tester) async {
      final native = _ProfileWorkspaceNative()
        ..allowActivity = true
        ..allowReader = true;
      final state = await _mount(tester, native);
      final originalTabs = state.workspace.tabs
          .map((tab) => (tab.id, tab.url))
          .toList();
      await _tap(tester, _footerItem('我的'));
      expect(native.named('space.activity'), isEmpty);
      await _tap(
        tester,
        find.descendant(of: _sections, matching: find.text('主题')),
      );
      expect(tester.widget<GlassSegmentedControl>(_sections).selectedIndex, 1);
      expect(native.named('space.activity'), hasLength(1));
      await _tap(tester, _button('下一页'));
      expect(find.text('第 2 页'), findsOneWidget);
      expect(native.named('space.activity'), hasLength(2));
      expect(native.named('space.activity').map((call) => call.$2), [
        {'memberId': 1, 'route': 'discussions', 'page': 1},
        {'memberId': 1, 'route': 'discussions', 'page': 2},
      ]);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(_activityList),
          scrollDelta: const Offset(0, 180),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await _frames(tester);
      final offset = tester.widget<ListView>(_activityList).controller!.offset;
      expect(offset, greaterThan(0));
      final visibleTopic = find
          .textContaining('My topic page 2 row ')
          .hitTestable()
          .first;
      final title = tester.widget<Text>(visibleTopic).data!;
      final index = int.parse(title.split(' ').last);
      final openedID = '${70200 + index}';
      final openedURL = 'https://www.nodeseek.com/post-$openedID-1';
      // Tap the visible row directly: ensureVisible could change the position
      // whose restoration this test is measuring.
      await tester.tap(visibleTopic);
      await _frames(tester);
      expect(native.named('reader.open'), hasLength(1));
      expect(native.named('reader.open').single.$2, {
        'id': openedID,
        'url': openedURL,
      });
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(state.workspace.selectedTab, openedID);
      expect(
        state.workspace.tabs
            .take(originalTabs.length)
            .map((tab) => (tab.id, tab.url)),
        originalTabs,
      );

      await _tap(tester, _footerItem('我的'));
      _expectMyPage(tester);
      expect(tester.widget<GlassSegmentedControl>(_sections).selectedIndex, 1);
      expect(find.text('第 2 页'), findsOneWidget);
      expect(find.textContaining('My topic page 2 row '), findsWidgets);
      expect(
        tester.widget<ListView>(_activityList).controller!.offset,
        closeTo(offset, 1),
      );
      expect(native.named('space.activity'), hasLength(2));
      expect(native.named('reader.open'), hasLength(1));
      expect(native.named('space.members'), isEmpty);
      expect(native.named('profile.saveIntroduction'), isEmpty);
      expect(state.workspace.selectedTab, openedID);
      expect(state.workspace.tabs, hasLength(originalTabs.length + 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
