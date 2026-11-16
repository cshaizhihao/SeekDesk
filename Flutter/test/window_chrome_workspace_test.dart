import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_wordmark.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_editor_host.dart';

const _chromeChannel = MethodChannel('cc.seekdesk/window-chrome.v1');
const _readerURL = 'https://www.nodeseek.com/post-2101-1';

/// No connection, preferences, media, or forum writes. The fixture exposes just
/// the read/navigation contracts used by the workspace, account and empty draft.
class _WorkspaceNative extends NativeClient {
  _WorkspaceNative({
    this.account = 'signedIn',
    this.withReader = false,
    this.withTools = false,
    this.withRankings = false,
  }) : super(methods: const MethodChannel('seekdesk.test.window-chrome'));

  String account;
  final bool withReader;
  final bool withTools;
  final bool withRankings;
  bool covered = false;
  String readerText = 'Reader content remains behind its editor';
  String draftContent = '';
  String board = 'tech';
  String feedOrder = 'postTime';
  bool loading = false;
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];

  JsonMap get topic => {
    'id': '2101',
    'url': _readerURL,
    'title': 'Native chrome reader fixture',
  };

  JsonMap get reader => {
    'url': _readerURL,
    'scrollOffset': 0.0,
    'thread': {
      'title': 'Native chrome reader fixture',
      'root': {
        'id': '0',
        'authorID': 42,
        'author': 'Chrome fixture owner',
        'blocks': [
          {'kind': 'text', 'text': readerText},
        ],
      },
      'replies': <JsonMap>[],
      'pages': <JsonMap>[],
    },
  };

  JsonMap get workspace => {
    'posts': <JsonMap>[if (withReader) topic],
    'tabs': <JsonMap>[if (withReader) topic],
    'selectedTab': withReader ? '2101' : '',
    'showReader': withReader,
    'board': board,
    'feedOrder': feedOrder,
    'loading': loading,
    'query': '',
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap get session => {
    'account': account,
    'accessRevision': accessRevision,
    'canCompose': account == 'signedIn',
    'sending': <String>[],
    if (account == 'signedIn') ...{
      'owner': 42,
      'profile': {'id': 42, 'name': 'Chrome fixture owner', 'avatar': ''},
    },
    'unread': {'mentions': 2, 'replies': 3, 'messages': 1},
  };

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  JsonMap get extensions => {
    'items': [
      {'id': 'office', 'active': true},
      if (withRankings) {'id': 'hot', 'active': true},
      if (withTools) ...[
        {'id': 'value', 'active': true},
        {'id': 'rulings', 'active': true},
      ],
    ],
    'settings': {
      'office': {'presented': covered, 'button': '集中办公', 'title': '工作计划'},
    },
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': session,
          'workspace': workspace,
          'extensions': extensions,
          'settings': {'workspace.sidebarWidth': 228.0},
        };
      case 'reader.updateReplyDraft':
        draftContent = stringValue(arguments['content']);
        eventsController.add({
          'domain': 'session',
          'accessRevision': accessRevision,
          'data': session,
        });
        return {
          'topicID': arguments['topicID'],
          'content': draftContent,
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
          'imageSizing': <JsonMap>[],
        };
      case 'rankings.load' when withRankings:
        return {'period': arguments['period'], 'posts': <JsonMap>[]};
      case 'profile.load':
        return session;
      case 'profile.introduction':
        return {'kind': 'ready', 'data': <String, Object?>{}};
      case 'session.signIn':
        return <String, Object?>{};
      case 'extensions.get':
        return extensions;
      case 'extensions.office':
        covered = arguments['presented'] == true;
        return extensions;
      case 'listing.selectBoard':
        return {...workspace, 'board': stringValue(arguments['id'])};
      case 'listing.order':
        feedOrder = stringValue(arguments['order']);
        return workspace;
      case 'reader.replyDraft':
        return {
          'topicID': arguments['topicID'],
          'content': draftContent,
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
          'imageSizing': <JsonMap>[],
        };
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'imageURLs': <String>[],
          'accessRevision': accessRevision,
        };
      case 'reader.rememberPosition':
        return {'saved': true};
      case 'reader.load':
        return reader;
      case 'value.currencies' when withTools:
        return {
          'items': [
            {'code': 'USD', 'title': 'USD 美元'},
            {'code': 'CNY', 'title': 'CNY 人民币'},
          ],
        };
      case 'value.rate' when withTools:
        return {
          'base': arguments['base'],
          'quote': arguments['quote'],
          'rate': '7.2',
          'source': 'Memory rate',
          'asOf': DateTime(2027, 1, 1).millisecondsSinceEpoch,
        };
      case 'value.hint' when withTools:
        return {'available': false};
      case 'rulings.load' when withTools:
        return {'records': <JsonMap>[]};
      default:
        unexpected.add(method);
        throw StateError('Unexpected window chrome fixture request: $method');
    }
  }
}

class _ChromeHost {
  _ChromeHost({this.installed = true});

  final bool installed;
  final calls = <MethodCall>[];
  final updates = <JsonMap>[];

  JsonMap get current => updates.last;
  JsonMap get snapshot => jsonMap(current['snapshot']);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'attach':
        expect(call.arguments, {'protocol': 1});
        return {'installed': installed, 'attachment': 'workspace-test'};
      case 'update':
        updates.add(jsonMap(call.arguments));
        return true;
      case 'detach':
        return null;
      default:
        throw MissingPluginException('Unexpected chrome method ${call.method}');
    }
  }

  JsonMap action(String action, {JsonMap? from}) {
    final value = from ?? current;
    return {
      'attachment': value['attachment'],
      'generation': value['generation'],
      'action': action,
    };
  }

  Future<bool> perform(
    WidgetTester tester,
    String action, {
    JsonMap? from,
  }) async {
    final response = tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          _chromeChannel.name,
          _chromeChannel.codec.encodeMethodCall(
            MethodCall('perform', this.action(action, from: from)),
          ),
          null,
        );
    // Flush messages without rendering a frame: several cases deliberately
    // deliver a stale click before the workspace can publish new capabilities.
    await tester.idle();
    final envelope = await response;
    if (envelope == null) throw MissingPluginException('No toolbar handler');
    return _chromeChannel.codec.decodeEnvelope(envelope) as bool;
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _WorkspaceNative native,
  _ChromeHost host, {
  Size size = const Size(1380, 880),
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _chromeChannel,
    host.handle,
  );
  final state = AppState(client: native)..connecting = false;
  state.domains['workspace'] = native.workspace;
  state.domains['session'] = native.session;
  state.domains['extensions'] = native.extensions;
  state.domains['settings'] = {'workspace.sidebarWidth': 228.0};
  if (native.withReader) state.readers[_readerURL] = native.reader;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await native.eventsController.close();
    await tester.pump(const Duration(seconds: 1));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _chromeChannel,
      null,
    );
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) =>
            ExtensionOverlays(state: state, child: child!),
        home: WorkspaceScreen(state: state),
      ),
    ),
  );
  await _frames(tester);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loading order picker restores refused drag then accepts once', (
    tester,
  ) async {
    final native = _WorkspaceNative()
      ..board = ''
      ..loading = true;
    final host = _ChromeHost();
    final state = await _mount(tester, native, host);
    await state.connect();
    await _frames(tester);
    final picker = find.byWidgetPredicate(
      (widget) =>
          widget is GlassSegmentedControl &&
          widget.segments.length == 2 &&
          widget.segments.last.label == '最新回复',
    );
    expect(picker, findsOneWidget);
    final first = find.descendant(of: picker, matching: find.text('最新帖子'));
    final second = find.descendant(of: picker, matching: find.text('最新回复'));
    Future<void> drag() async {
      final start = tester.getCenter(first);
      final end = tester.getCenter(second);
      final pointer = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 20));
      await pointer.moveTo(Offset.lerp(start, end, .4)!);
      await tester.pump(const Duration(milliseconds: 40));
      await pointer.moveTo(end);
      await tester.pump(const Duration(milliseconds: 150));
      await pointer.moveTo(end);
      await pointer.up();
      await _frames(tester);
      await _frames(tester);
    }

    void expectRest(int index) {
      final control = tester.widget<GlassSegmentedControl>(picker);
      final indicator = tester
          .widgetList<AnimatedGlassIndicator>(
            find.descendant(
              of: picker,
              matching: find.byType(AnimatedGlassIndicator),
            ),
          )
          .firstWhere((value) => value.paintBackground);
      expect(control.selectedIndex, index);
      expect(
        indicator.alignment.resolve(TextDirection.ltr).x,
        closeTo(index == 0 ? -1 : 1, .001),
      );
      expect(indicator.thickness, closeTo(0, .001));
      expect(tester.takeException(), isNull);
    }

    await drag();
    expect(native.calls.where((call) => call.$1 == 'listing.order'), isEmpty);
    expectRest(0);
    native.loading = false;
    native.eventsController.add({
      'domain': 'workspace',
      'data': native.workspace,
    });
    await _frames(tester);
    expectRest(0);
    await drag();
    final requests = native.calls.where((call) => call.$1 == 'listing.order');
    expect(requests, hasLength(1));
    expect(requests.single.$2, {'order': 'replyTime'});
    expect(state.domain('workspace')['feedOrder'], 'replyTime');
    expectRest(1);
  });

  testWidgets('toolbar profile loading uses the current confirmed owner only', (
    tester,
  ) async {
    final native = _WorkspaceNative(account: 'unconfirmed');
    final host = _ChromeHost();
    final state = await _mount(tester, native, host);
    await state.connect();
    await _frames(tester);
    expect(host.snapshot['accountName'], '账号');
    expect(host.snapshot['accountLabel'], 'NodeSeek 账户');

    Future<void> session(JsonMap value, {int revision = 0}) async {
      native.eventsController.add({
        'domain': 'session',
        'accessRevision': revision,
        'data': {'accessRevision': revision, ...value},
      });
      await _frames(tester);
    }

    await session({'account': 'signedIn', 'owner': 42});
    expect(host.snapshot['accountName'], '我的账号');
    expect(host.snapshot['accountLabel'], '我的账号');
    final mismatchedProfile = {
      'id': 77,
      'name': 'Another owner',
      'avatar': 'https://example.invalid/retired-avatar.png',
    };
    await session({
      'account': 'signedIn',
      'owner': 42,
      'profile': mismatchedProfile,
    });
    expect(host.snapshot['accountName'], '我的账号');
    expect(host.snapshot['avatarBytes'], isNull);
    expect(native.calls.where((call) => call.$1 == 'images.load'), isEmpty);

    final oldProfile = {'id': 42, 'name': 'Current owner', 'avatar': ''};
    await session({'account': 'signedIn', 'owner': 42, 'profile': oldProfile});
    expect(host.snapshot['accountName'], 'Current owner');
    expect(host.snapshot['accountLabel'], '我的账号，Current owner');
    await session({
      'account': 'signedIn',
      'owner': 43,
      'profile': oldProfile,
    }, revision: 1);
    expect(host.snapshot['accountName'], '我的账号');
    expect(host.snapshot['avatarBytes'], isNull);
    await session({
      'account': 'signedIn',
      'owner': 43,
      'profile': {'id': 43, 'name': 'Next owner', 'avatar': ''},
    }, revision: 1);
    expect(host.snapshot['accountName'], 'Next owner');
    await session({
      'account': 'signedOut',
      'owner': 43,
      'profile': oldProfile,
    }, revision: 2);
    expect(host.snapshot['accountName'], '登录 NodeSeek');
    expect(host.snapshot['accountLabel'], '登录 NodeSeek');
    expect(host.snapshot['avatarBytes'], isNull);
    expect(state.signedIn, isFalse);
    expect(native.calls.map((call) => call.$1), ['bootstrap']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'delayed profile leaves fallback account and search positions stable',
    (tester) async {
      final native = _WorkspaceNative(account: 'unconfirmed');
      final host = _ChromeHost(installed: false);
      final state = await _mount(tester, native, host);
      await state.connect();
      await _frames(tester);
      Finder account(String label) => find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      );
      final search = find.byWidgetPredicate(
        (widget) => widget is DeskButton && widget.label == '搜索帖子',
      );
      final initialAccount = tester.getRect(account('NodeSeek 账户'));
      final initialSearch = tester.getRect(search);
      Future<void> profile(String? name) async {
        native.eventsController.add({
          'domain': 'session',
          'accessRevision': 0,
          'data': {
            'account': 'signedIn',
            'owner': 42,
            if (name != null) 'profile': {'id': 42, 'name': name, 'avatar': ''},
          },
        });
        await _frames(tester);
      }

      const longName = '很长的账号名称👩‍💻包含中文和表情仍然保留完整的辅助说明';
      for (final name in ['A', longName, 'Current owner']) {
        await profile(name);
        expect(tester.getRect(account('我的账号，$name')), initialAccount);
        expect(tester.getRect(search), initialSearch);
        expect(tester.takeException(), isNull);
      }
      await profile(null);
      expect(tester.getRect(account('我的账号')), initialAccount);
      expect(tester.getRect(search), initialSearch);
      await profile('Current owner');
      await tester.binding.setSurfaceSize(const Size(850, 750));
      await _frames(tester);
      final compactAccount = tester.getRect(account('我的账号，Current owner'));
      final compactSearch = tester.getRect(search);
      expect(compactAccount.width, lessThan(initialAccount.width));
      await profile(longName);
      expect(tester.getRect(account('我的账号，$longName')), compactAccount);
      expect(tester.getRect(search), compactSearch);
      await tester.binding.setSurfaceSize(const Size(1380, 880));
      await _frames(tester);
      expect(tester.getRect(account('我的账号，$longName')), initialAccount);
      expect(tester.getRect(search), initialSearch);
      expect(native.calls.map((call) => call.$1), ['bootstrap']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native attachment replaces the extra Flutter header', (
    tester,
  ) async {
    final native = _WorkspaceNative();
    final host = _ChromeHost();
    await _mount(tester, native, host);
    expect(host.calls.where((call) => call.method == 'attach'), hasLength(1));
    expect(find.byType(DeskWordmark), findsNothing);
    expect(host.snapshot['accountName'], 'Chrome fixture owner');
    expect(host.snapshot['accountLabel'], '我的账号，Chrome fixture owner');
    expect(host.snapshot['unreadCount'], 6);
    expect(
      host.snapshot['enabledActions'],
      containsAll([
        'sidebar',
        'home',
        'search',
        'notifications',
        'account',
        'office',
      ]),
    );
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the native sidebar button opens and closes compact navigation', (
    tester,
  ) async {
    final native = _WorkspaceNative();
    final host = _ChromeHost();
    await _mount(tester, native, host, size: const Size(850, 750));
    expect(host.snapshot['compact'], isTrue);
    expect(host.snapshot['sidebarOpen'], isFalse);
    expect(await host.perform(tester, 'sidebar'), isTrue);
    await _frames(tester);
    expect(
      find.byKey(const ValueKey('compact-sidebar-dismiss')),
      findsOneWidget,
    );
    expect(host.snapshot['sidebarOpen'], isTrue);
    expect(host.snapshot['enabledActions'], ['sidebar']);
    expect(await host.perform(tester, 'sidebar'), isTrue);
    await _frames(tester);
    expect(find.byKey(const ValueKey('compact-sidebar-dismiss')), findsNothing);
    expect(host.snapshot['sidebarOpen'], isFalse);
    expect(host.snapshot['enabledActions'], contains('search'));
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'embedded editor open and close invalidate native clicks before publishing',
    (tester) async {
      final native = _WorkspaceNative(withReader: true);
      final host = _ChromeHost();
      final state = await _mount(tester, native, host);
      final editors = tester
          .widget<ReaderEditorHost>(find.byType(ReaderEditorHost))
          .editors;
      final beforeOpen = {...host.current};
      final beforeOpenUpdates = host.updates.length;
      expect(host.snapshot['enabledActions'], contains('home'));

      await editors.open(state.workspace.selected!);
      // No frame has reached WindowChromeBridge.didUpdateWidget yet. Its
      // old generation still matches, so only the live context/epoch guard
      // can reject this previously enabled Home action.
      expect(editors.presented, isNotNull);
      expect(await host.perform(tester, 'home', from: beforeOpen), isFalse);
      expect(host.updates, hasLength(beforeOpenUpdates));
      expect(state.workspace.board, 'tech');
      await _frames(tester);
      final whileOpen = {...host.current};
      expect(
        intValue(whileOpen['generation']),
        greaterThan(intValue(beforeOpen['generation'])),
      );
      expect(whileOpen['attachment'], beforeOpen['attachment']);
      expect(find.byType(ComposerScreen), findsOneWidget);
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(await host.perform(tester, 'home', from: beforeOpen), isFalse);
      expect(
        native.calls.where((call) => call.$1 == 'reader.replyDraft'),
        hasLength(1),
      );

      final beforeCloseUpdates = host.updates.length;
      final close = editors.presented!.binding.requestClose;
      expect(close, isNotNull);
      await close!();
      expect(editors.presented, isNull);
      expect(await host.perform(tester, 'home', from: whileOpen), isFalse);
      expect(host.updates, hasLength(beforeCloseUpdates));
      await _frames(tester);
      expect(
        intValue(host.current['generation']),
        greaterThan(intValue(whileOpen['generation'])),
      );
      expect(host.current['attachment'], beforeOpen['attachment']);
      expect(find.byType(ComposerScreen), findsNothing);
      expect(await host.perform(tester, 'home', from: whileOpen), isFalse);
      expect(await host.perform(tester, 'home', from: beforeOpen), isFalse);
      expect(state.workspace.board, 'tech');
      expect(state.workspace.selectedTab, '2101');

      // Current commands still work; stale rejection must not disable the
      // native toolbar permanently after the editor's local rebuild.
      expect(host.snapshot['sidebarOpen'], isTrue);
      expect(await host.perform(tester, 'sidebar'), isTrue);
      await _frames(tester);
      expect(host.snapshot['sidebarOpen'], isFalse);
      expect(
        native.calls.where(
          (call) =>
              call.$1 == 'listing.selectBoard' || call.$1 == 'reader.sendReply',
        ),
        isEmpty,
      );
      expect(host.calls.where((call) => call.method == 'attach'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search rejects old toolbar clicks and never replays them on close',
    (tester) async {
      final native = _WorkspaceNative();
      final host = _ChromeHost();
      final state = await _mount(tester, native, host);
      final previous = {...host.current};
      expect(await host.perform(tester, 'search'), isTrue);
      // No frame has published the disabled toolbar yet. The live route/search
      // guard still prevents an old Home click from clearing the board.
      expect(await host.perform(tester, 'home', from: previous), isFalse);
      await _frames(tester);
      expect(find.byType(CupertinoTextField), findsOneWidget);
      expect(host.snapshot['enabledActions'], isEmpty);
      expect(await host.perform(tester, 'account'), isFalse);
      Navigator.of(tester.element(find.byType(CupertinoTextField))).pop();
      await _frames(tester);
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(await host.perform(tester, 'home', from: previous), isFalse);
      expect(state.workspace.board, 'tech');
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local draft session echoes do not rebuild workspace or reader', (
    tester,
  ) async {
    final native = _WorkspaceNative(withReader: true);
    final host = _ChromeHost();
    final state = await _mount(tester, native, host);
    await state.connect();
    await _frames(tester);
    final editors = tester
        .widget<ReaderEditorHost>(find.byType(ReaderEditorHost))
        .editors;
    await editors.open(state.workspace.selected!);
    await _frames(tester);
    final editor = find.descendant(
      of: find.byType(ReaderEditorHost),
      matching: find.byType(EditableText),
    );
    expect(editor, findsOneWidget);
    await tester.tap(editor);
    await tester.enterText(editor, 'Keep this local draft and its selection');
    final field = tester.widget<EditableText>(editor);
    field.controller.selection = const TextSelection(
      baseOffset: 5,
      extentOffset: 15,
    );
    await tester.pump();
    final selection = field.controller.selection;
    final connection = tester.testTextInput.setClientArgs;
    final readerState = tester.state(find.byType(ReaderScreen));
    final editorState = tester.state(editor);
    final builds = <Type, int>{};
    final previousHook = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousHook?.call(element, builtOnce);
      if (element.widget is WorkspaceScreen || element.widget is ReaderScreen) {
        final type = element.widget.runtimeType;
        builds[type] = (builds[type] ?? 0) + 1;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
    await tester.pump(const Duration(seconds: 1));
    await _frames(tester);
    expect(native.draftContent, field.controller.text);
    expect(
      native.calls.where((call) => call.$1 == 'reader.updateReplyDraft'),
      isNotEmpty,
    );
    expect(builds, isEmpty);
    expect(tester.state(find.byType(ReaderScreen)), same(readerState));
    expect(tester.state(editor), same(editorState));
    expect(field.controller.selection, selection);
    expect(field.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.setClientArgs, same(connection));
    expect(editors.presented, isNotNull);

    native.eventsController.add({
      'domain': 'session',
      'accessRevision': state.accessRevision,
      'data': {
        ...native.session,
        'unread': {'mentions': 8, 'replies': 3, 'messages': 1},
      },
    });
    await _frames(tester);
    expect(builds[WorkspaceScreen], greaterThan(0));
    expect(host.snapshot['unreadCount'], 12);
    expect(field.controller.text, 'Keep this local draft and its selection');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'transparent route changes do not rebuild the cached workspace or reader',
    (tester) async {
      final native = _WorkspaceNative(withReader: true);
      final host = _ChromeHost();
      await _mount(tester, native, host);
      final readerElement = tester.element(find.byType(ReaderScreen));
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      final builds = <Type, int>{};
      final previousHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousHook?.call(element, builtOnce);
        if (element.widget is WorkspaceScreen ||
            element.widget is ReaderScreen ||
            element.widget is ReaderEditorHost) {
          final type = element.widget.runtimeType;
          builds[type] = (builds[type] ?? 0) + 1;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
      final before = {...host.current};
      final route = PageRouteBuilder<void>(
        opaque: false,
        allowSnapshotting: false,
        pageBuilder: (_, animation, secondaryAnimation) =>
            const Center(child: Text('Transparent reader overlay')),
        transitionsBuilder: (_, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      );
      unawaited(navigator.push(route));
      // Even before the new toolbar is published, live route identity rejects
      // a previously captured native action.
      expect(await host.perform(tester, 'home', from: before), isFalse);
      await _frames(tester);
      expect(host.snapshot['enabledActions'], isEmpty);
      expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
      expect(builds, isEmpty, reason: 'Opening only covers the reader.');
      navigator.pop();
      await _frames(tester);
      expect(find.text('Transparent reader overlay'), findsNothing);
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(await host.perform(tester, 'home', from: before), isFalse);
      expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
      expect(builds, isEmpty, reason: 'Closing only uncovers the reader.');
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a transparent overlay does not prevent authoritative reader updates',
    (tester) async {
      final native = _WorkspaceNative(withReader: true);
      final host = _ChromeHost();
      final state = await _mount(tester, native, host);
      final readerState = tester.state(find.byType(ReaderScreen));
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (_, animation, secondaryAnimation) =>
                const Center(child: Text('Covering updated reader')),
          ),
        ),
      );
      await _frames(tester);
      native.readerText = 'New authoritative content while covered';
      await state.loadReader(_readerURL, force: true);
      await _frames(tester);
      expect(host.snapshot['enabledActions'], isEmpty);
      expect(find.text(native.readerText, findRichText: true), findsOneWidget);
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      navigator.pop();
      await _frames(tester);
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(find.text(native.readerText, findRichText: true), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'reader.load'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a covering editor route blocks native navigation without popping it',
    (tester) async {
      final native = _WorkspaceNative();
      final host = _ChromeHost();
      await _mount(tester, native, host);
      final previous = {...host.current};
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      unawaited(
        navigator.push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(
              child: Center(child: Text('Editor route fixture')),
            ),
          ),
        ),
      );
      expect(await host.perform(tester, 'home', from: previous), isFalse);
      await _frames(tester);
      expect(host.snapshot['enabledActions'], isEmpty);
      expect(await host.perform(tester, 'account'), isFalse);
      expect(find.text('Editor route fixture'), findsOneWidget);
      navigator.pop();
      await _frames(tester);
      expect(await host.perform(tester, 'home', from: previous), isFalse);
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'route chrome keeps ranking visibility in sync without refetching',
    (tester) async {
      final native = _WorkspaceNative(withReader: true, withRankings: true);
      final host = _ChromeHost();
      final state = await _mount(tester, native, host);
      expect(state.rankings.visible, isTrue);
      expect(
        native.calls.where((call) => call.$1 == 'rankings.load'),
        hasLength(1),
      );
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (_, animation, secondaryAnimation) =>
                const Center(child: Text('Covering ranking visibility')),
          ),
        ),
      );
      await _frames(tester);
      expect(state.rankings.visible, isFalse);
      navigator.pop();
      await _frames(tester);
      expect(state.rankings.visible, isTrue);
      expect(
        native.calls.where((call) => call.$1 == 'rankings.load'),
        hasLength(1),
      );
      expect(host.snapshot['enabledActions'], contains('home'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final tool in ['value', 'rulings']) {
    testWidgets(
      'using $tool does not subscribe the reader root to later route changes',
      (tester) async {
        final native = _WorkspaceNative(withReader: true, withTools: true);
        final host = _ChromeHost();
        await _mount(tester, native, host);
        final readerElement = tester.element(find.byType(ReaderScreen));
        final navigator = Navigator.of(
          tester.element(find.byType(WorkspaceScreen)),
        );
        final launch = find.byWidgetPredicate(
          (widget) => tool == 'value'
              ? widget is DeskButton && widget.label == '估价'
              : widget is DeskIcon && widget.label == '管理记录',
        );
        expect(launch.hitTestable(), findsOneWidget);
        await tester.tap(launch);
        await _frames(tester);
        final toolScreen = find.byType(
          tool == 'value' ? ValueScreen : RulingsScreen,
        );
        expect(toolScreen, findsOneWidget);
        expect(host.snapshot['enabledActions'], isEmpty);
        final close = find.descendant(
          of: toolScreen,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DeskIcon &&
                widget.label == (tool == 'value' ? '关闭估价' : '关闭'),
          ),
        );
        expect(close.hitTestable(), findsOneWidget);
        await tester.tap(close);
        await _frames(tester);
        expect(toolScreen, findsNothing);
        expect(host.snapshot['enabledActions'], contains('home'));
        expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
        expect(
          native.calls.map((call) => call.$1),
          unorderedEquals(
            tool == 'value'
                ? ['value.currencies', 'value.rate', 'value.hint']
                : ['rulings.load'],
          ),
        );
        native.calls.clear();

        // A route dependency registered by a launch callback survives closing
        // its tool. A second unrelated overlay catches that persistent cost.
        final builds = <Type, int>{};
        final previousHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousHook?.call(element, builtOnce);
          if (element.widget is WorkspaceScreen ||
              element.widget is ReaderScreen ||
              element.widget is ReaderEditorHost) {
            final type = element.widget.runtimeType;
            builds[type] = (builds[type] ?? 0) + 1;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
        final before = {...host.current};
        unawaited(
          navigator.push(
            PageRouteBuilder<void>(
              opaque: false,
              allowSnapshotting: false,
              pageBuilder: (_, animation, secondaryAnimation) =>
                  const Center(child: Text('Overlay after reader tool')),
              transitionsBuilder: (_, animation, secondaryAnimation, child) =>
                  FadeTransition(opacity: animation, child: child),
            ),
          ),
        );
        expect(await host.perform(tester, 'home', from: before), isFalse);
        await _frames(tester);
        expect(find.text('Overlay after reader tool'), findsOneWidget);
        expect(host.snapshot['enabledActions'], isEmpty);
        expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
        expect(
          builds,
          isEmpty,
          reason: 'Only the tool button reads its route.',
        );
        navigator.pop();
        await _frames(tester);
        expect(find.text('Overlay after reader tool'), findsNothing);
        expect(host.snapshot['enabledActions'], contains('home'));
        expect(await host.perform(tester, 'home', from: before), isFalse);
        expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
        expect(builds, isEmpty);
        expect(native.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'office cover removes forum identity and blocks native commands',
    (tester) async {
      final native = _WorkspaceNative();
      final host = _ChromeHost();
      final state = await _mount(tester, native, host);
      final previous = {...host.current};
      native.covered = true;
      state.domains['extensions'] = native.extensions;
      expect(await host.perform(tester, 'account', from: previous), isFalse);
      await state.act('extensions.get', {}, 'extensions');
      await _frames(tester);
      expect(host.snapshot['officeCovered'], isTrue);
      expect(host.snapshot['accountName'], isEmpty);
      expect(host.snapshot['accountLabel'], isEmpty);
      expect(host.snapshot['unreadCount'], 0);
      expect(host.snapshot['avatarBytes'], isNull);
      expect(host.snapshot['enabledActions'], isEmpty);
      for (final action in ['sidebar', 'home', 'search', 'account', 'office']) {
        expect(await host.perform(tester, action), isFalse);
      }
      expect(find.text('工作计划'), findsOneWidget);
      expect(native.calls.map((call) => call.$1), ['extensions.get']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfirmed account opens the account page without starting sign-in',
    (tester) async {
      final native = _WorkspaceNative(account: 'unconfirmed');
      final host = _ChromeHost();
      await _mount(tester, native, host);
      expect(host.snapshot['accountLabel'], 'NodeSeek 账户');
      expect(await host.perform(tester, 'account'), isTrue);
      await _frames(tester);
      expect(find.byType(AccountScreen), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'session.signIn'),
        isEmpty,
      );
      expect(
        native.calls.where((call) => call.$1 == 'profile.load'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an explicitly signed-out native account button starts sign-in', (
    tester,
  ) async {
    final native = _WorkspaceNative(account: 'signedOut');
    final host = _ChromeHost();
    await _mount(tester, native, host);
    expect(host.snapshot['accountLabel'], '登录 NodeSeek');
    expect(await host.perform(tester, 'account'), isTrue);
    await _frames(tester);
    expect(
      native.calls.where((call) => call.$1 == 'session.signIn'),
      hasLength(1),
    );
    expect(find.byType(AccountScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an account revision change rejects old native actions before rebuilding',
    (tester) async {
      final native = _WorkspaceNative();
      final host = _ChromeHost();
      await _mount(tester, native, host);
      final previous = {...host.current};
      final updateCount = host.updates.length;
      native.accessRevision++;
      expect(await host.perform(tester, 'home', from: previous), isFalse);
      expect(host.updates, hasLength(updateCount));
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
