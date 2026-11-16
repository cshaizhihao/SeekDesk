import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/friend_links_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/reader_editors.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';
import 'package:seekdesk_flutter/widgets/reader_editor_host.dart';

const _a = '2101';
const _b = '2102';
String _url(String id) => 'https://www.nodeseek.com/post-$id-1';
JsonMap _topic(String id) => {
  'id': id,
  'url': _url(id),
  'title': id == _a ? 'Thread A' : 'Thread B',
};

/// All reads, editor mutations, and simulated submissions stay in memory.
/// Unknown methods fail instead of falling through to a native/network client.
class _EditorNative extends NativeClient {
  _EditorNative({this.restricted = false})
    : super(methods: const MethodChannel('seekdesk.test.reader-editor-host'));

  final bool restricted;
  bool failReaderLoads = false;
  bool failNextEditBegin = false;
  String selected = _a;
  final tabIDs = <String>[_a, _b];
  final drafts = <String, String>{_a: '', _b: ''};
  final rootText = <String, String>{};
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final edits = <String, JsonMap>{};
  int nextToken = 0;
  Completer<JsonMap>? pendingReply;
  Completer<JsonMap>? pendingReplyDraft;

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  JsonMap get settings => {
    'workspace.sidebarWidth': 228.0,
    'workspace.topicColumnWidth': 280.0,
    'workspace.replySendKey': 'commandReturn',
  };

  JsonMap get session => {
    'account': 'signedIn',
    'owner': 42,
    'canCompose': true,
    'accessRevision': accessRevision,
    'profile': {'id': 42, 'name': 'Owner', 'avatar': ''},
  };

  JsonMap get workspace => {
    'posts': [for (final id in tabIDs) _topic(id)],
    'tabs': [for (final id in tabIDs) _topic(id)],
    'selectedTab': selected,
    'showReader': selected.isNotEmpty,
    'board': 'tech',
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap reader(String url) {
    final id = RegExp(r'post-(\d+)').firstMatch(url)?.group(1) ?? _a;
    return {
      'url': _url(id),
      'scrollOffset': 0.0,
      'thread': {
        'title': id == _a ? 'Thread A' : 'Thread B',
        'replyRestriction': restricted ? '已关闭回复' : '',
        'root': {
          'id': '0',
          'authorID': 42,
          'author': 'Owner',
          'avatar': '',
          'blocks': [
            {
              'kind': 'text',
              'text':
                  rootText[id] ??
                  (id == _a ? 'A visible root' : 'B visible root'),
            },
          ],
        },
        'replies': <JsonMap>[],
        'pages': <JsonMap>[],
      },
    };
  }

  JsonMap draft(String id) => {
    'topicID': id,
    'content': drafts[id] ?? '',
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
  };

  List<(String, JsonMap)> named(String method) =>
      calls.where((entry) => entry.$1 == method).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments, 'accessRevision': accessRevision}));
    final id = stringValue(arguments['topicID']);
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'session': session,
          'settings': settings,
          'extensions': {'items': <JsonMap>[]},
        };
      case 'reader.load':
        if (failReaderLoads) {
          throw const NativeFailure('network', 'Memory reader load failed');
        }
        return reader(stringValue(arguments['url']));
      case 'reader.rememberPosition':
        return {'saved': true};
      case 'reader.select':
        selected = stringValue(arguments['id']);
        return workspace;
      case 'reader.open':
        selected = RegExp(r'post-(\d+)')
            .firstMatch(stringValue(arguments['url']))!
            .group(1)!;
        if (!tabIDs.contains(selected)) tabIDs.add(selected);
        return workspace;
      case 'reader.close':
        tabIDs.remove(stringValue(arguments['id']));
        if (!tabIDs.contains(selected)) selected = tabIDs.firstOrNull ?? '';
        return workspace;
      case 'reader.closeAll':
        tabIDs.clear();
        selected = '';
        return workspace;
      case 'reader.replyDraft':
        final pending = pendingReplyDraft;
        if (pending != null) return pending.future;
        return draft(id);
      case 'reader.updateReplyDraft':
        drafts[id] = stringValue(arguments['content']);
        return draft(id);
      case 'reader.discardReplyDraft':
        drafts[id] = '';
        return draft(id);
      case 'reader.sendReply':
        final pending = pendingReply;
        if (pending == null) {
          unexpected.add('unplanned fixture submission');
          throw StateError(
            'Tests must explicitly arrange a memory-only receipt.',
          );
        }
        return pending.future;
      case 'reader.edit.begin':
        if (failNextEditBegin) {
          failNextEditBegin = false;
          throw const NativeFailure('network', 'Memory editor begin failed');
        }
        final value = <String, dynamic>{
          'topicID': id,
          'floor': arguments['floor'],
          'editToken': 'memory-edit-${++nextToken}',
          'accessRevision': accessRevision,
          'ready': true,
          'saving': false,
          'needsVerification': false,
          'accepted': false,
          'title': 'Original title',
          'content': 'Original edit body',
          'imageURLs': <String>[],
          'imageSizing': <JsonMap>[],
        };
        edits[id] = value;
        return {...value};
      case 'reader.edit.update':
      case 'reader.edit.cancel':
        final value = edits[id];
        if (value == null ||
            value['editToken'] != arguments['editToken'] ||
            value['floor'] != arguments['floor'] ||
            value['accessRevision'] != accessRevision) {
          throw const NativeFailure('stale_editor', 'Memory editor is stale');
        }
        if (method == 'reader.edit.update') {
          value['title'] = arguments['title'] ?? value['title'];
          value['content'] = arguments['content'] ?? value['content'];
          return {...value};
        }
        edits.remove(id);
        return {...value, 'ready': false, 'cancelled': true};
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
        };
      case 'stickers.list':
        return {'packs': <JsonMap>[]};
      case 'settings.get':
        return settings;
      default:
        unexpected.add(method);
        throw StateError('Unexpected reader editor fixture request: $method');
    }
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder _footer(String text) => find.descendant(
  of: find.byKey(const ValueKey('sidebar-footer')),
  matching: find.text(text),
);
Finder get _body => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);
TextEditingController _controller(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_body).controller!;

Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _EditorNative native, {
  Size size = const Size(1380, 880),
}) async {
  await tester.binding.setSurfaceSize(size);
  final state = AppState(client: native);
  await state.connect();
  state.readers[_url(_a)] = native.reader(_url(_a));
  state.readers[_url(_b)] = native.reader(_url(_b));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Let dispose-time local draft writes finish while their owner exists.
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    await native.snapshotEvents.close();
    await tester.pump();
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

Future<void> _openReply(WidgetTester tester) async {
  await tester.tap(_button('写回复'));
  await _frames(tester);
  expect(find.byType(ComposerScreen), findsOneWidget);
  expect(_body, findsOneWidget);
}

Future<void> _openEdit(WidgetTester tester) async {
  await tester.tap(_icon('编辑楼层'));
  await _frames(tester);
  expect(find.byType(InlineEditScreen), findsOneWidget);
  expect(_body, findsOneWidget);
}

Future<void> _select(WidgetTester tester, AppState state, String id) async {
  await state.selectTopic(TopicData(_topic(id)));
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reply stays beside the original reader without pushing a route',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      final reader = tester.state(find.byType(ReaderScreen));
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      await _openReply(tester);
      expect(navigator.canPop(), isFalse);
      expect(tester.state(find.byType(ReaderScreen)), same(reader));
      expect(find.text('A visible root', findRichText: true), findsOneWidget);
      expect(find.byType(ReaderEditorAnchor), findsOneWidget);
      expect(state.workspace.selectedTab, _a);
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'covering routes disable retained editor bindings and restore the same draft',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native);
      await _openReply(tester);
      await tester.enterText(_body, 'Memory draft retained beneath an overlay');
      await _frames(tester);
      final input = _controller(tester);
      input.selection = const TextSelection(baseOffset: 3, extentOffset: 8);
      final originalValue = input.value;
      final editors = tester
          .widget<ReaderEditorHost>(find.byType(ReaderEditorHost))
          .editors;
      final session = editors.presented!;
      final navigator = Navigator.of(
        tester.element(find.byType(WorkspaceScreen)),
      );
      var bindingNotifications = 0;
      session.binding.addListener(() => bindingNotifications++);
      expect(session.binding.active, isTrue);
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (_, animation, secondaryAnimation) =>
                const Center(child: Text('Editor covering overlay')),
          ),
        ),
      );
      // A stale editor action is rejected even before the chrome builder runs.
      expect(session.binding.active, isFalse);
      expect(
        await session.binding.appendReply((text) => '$text forbidden'),
        isFalse,
      );
      await _frames(tester);
      expect(bindingNotifications, greaterThan(0));
      final composer = find.byType(ComposerScreen);
      expect(
        find.ancestor(
          of: composer,
          matching: find.byWidgetPredicate(
            (widget) => widget is ExcludeFocus && widget.excluding,
          ),
        ),
        findsWidgets,
      );
      expect(TickerMode.valuesOf(tester.element(composer)).enabled, isFalse);
      expect(_controller(tester), same(input));
      expect(input.value, originalValue);
      final coveredNotifications = bindingNotifications;
      navigator.pop();
      await _frames(tester);
      expect(session.binding.active, isTrue);
      expect(bindingNotifications, greaterThan(coveredNotifications));
      expect(TickerMode.valuesOf(tester.element(composer)).enabled, isTrue);
      expect(editors.presented, same(session));
      expect(_controller(tester), same(input));
      expect(input.value, originalValue);
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor lifecycle and measured-size refresh reuse the existing reader body',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native);
      final reader = find.byType(ReaderScreen);
      final readerState = tester.state(reader);
      final body = find.descendant(
        of: reader,
        matching: find.byType(ForumBlocks),
      );
      final viewport = find.descendant(
        of: reader,
        matching: find.byType(CustomScrollView),
      );
      final originalBody = tester.widget<ForumBlocks>(body);
      final originalElement = tester.element(body);
      final controller = tester.widget<CustomScrollView>(viewport).controller;
      final fullHeight = tester.getSize(viewport).height;
      final pending = Completer<JsonMap>();
      native.pendingReplyDraft = pending;
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(native.draft(_a));
      });

      void expectBodyRetained() {
        expect(tester.state(reader), same(readerState));
        expect(tester.widget<ForumBlocks>(body), same(originalBody));
        expect(tester.element(body), same(originalElement));
        expect(
          tester.widget<CustomScrollView>(viewport).controller,
          same(controller),
        );
      }

      await tester.tap(_button('写回复'));
      // Observe opening, draft-pending notifications and the measured anchor
      // one frame at a time, before a completed draft can mask any churn.
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
        expectBodyRetained();
      }
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(_body, findsNothing);
      expect(_button('写回复'), findsNothing);
      expect(find.byType(ReaderEditorAnchor), findsOneWidget);
      final editingHeight = tester.getSize(viewport).height;
      expect(editingHeight, greaterThan(0));
      expect(editingHeight, lessThan(fullHeight));

      final editors = tester
          .widget<ReaderEditorHost>(find.byType(ReaderEditorHost))
          .editors;
      final session = editors.presented!;
      final measuredSize = session.size;
      // Size callbacks belong to the retained host, not the forum document.
      // Exercise a changed measurement and its correction independently of a
      // real width change, which legitimately needs to reflow forum text.
      editors.updateSize(
        session,
        Size(measuredSize.width, measuredSize.height - 1),
      );
      await tester.pump();
      expectBodyRetained();
      editors.updateSize(session, measuredSize);
      editors.refresh();
      await tester.pump();
      expectBodyRetained();
      expect(tester.getSize(viewport).height, editingHeight);
      expect(native.named('reader.replyDraft'), hasLength(1));

      native.pendingReplyDraft = null;
      pending.complete(native.draft(_a));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
        expectBodyRetained();
      }
      expect(_body, findsOneWidget);
      expect(native.named('reader.replyDraft'), hasLength(1));

      await tester.tap(_button('保存并关闭'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
        expectBodyRetained();
      }
      expect(find.byType(ComposerScreen), findsNothing);
      expect(find.byType(ReaderEditorAnchor), findsNothing);
      expect(_button('写回复'), findsOneWidget);
      expect(tester.getSize(viewport).height, fullHeight);
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first draft notification preserves a manually hidden list through editor resizing',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      final list = find.byKey(const ValueKey('forum-list-pane'));
      final readerState = tester.state(find.byType(ReaderScreen));
      final workspace = state.domains['workspace'];
      final settings = state.domains['settings'];
      var notifications = 0;
      void observedNotification() => notifications++;
      state.addListener(observedNotification);
      addTearDown(() => state.removeListener(observedNotification));
      expect(list, findsOneWidget);
      expect(settings?['workspace.hideListWhileReading'], isNot(true));

      await tester.tap(_button('收起列表'));
      await tester.pump();
      await tester.pump();
      expect(list, findsNothing);
      expect(_button('展开列表'), findsOneWidget);
      // The app was already connected before mounting. Opening the draft below
      // is the first AppState notification since the user's local list toggle.
      expect(notifications, 0);
      final pending = Completer<JsonMap>();
      native.pendingReplyDraft = pending;
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(native.draft(_a));
      });
      await tester.tap(_button('写回复'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(notifications, greaterThan(0));
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(
        state.pending.any((key) => key.startsWith('reader.replyDraft:')),
        isTrue,
      );
      expect(state.domains['workspace'], same(workspace));
      expect(state.domains['settings'], same(settings));
      expect(list, findsNothing);
      expect(_button('展开列表'), findsOneWidget);

      // Local editor notifications may leave the old widget tree intact. A
      // height-only window resize exposes any silently reset listVisible value
      // while retaining the same reading layout width and pending draft.
      await tester.binding.setSurfaceSize(const Size(1380, 900));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(list, findsNothing);
      expect(_button('展开列表'), findsOneWidget);
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(find.byType(ReaderEditorAnchor), findsOneWidget);
      expect(native.named('reader.replyDraft'), hasLength(1));

      native.pendingReplyDraft = null;
      pending.complete(native.draft(_a));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(_body, findsOneWidget);
      expect(list, findsNothing);
      await tester.tap(_button('保存并关闭'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(find.byType(ComposerScreen), findsNothing);
      expect(list, findsNothing);
      expect(_button('展开列表'), findsOneWidget);

      // The label and backing state agree: one user click actually expands it.
      await tester.tap(_button('展开列表'));
      await tester.pump();
      await tester.pump();
      expect(list, findsOneWidget);
      expect(_button('收起列表'), findsOneWidget);
      expect(tester.state(find.byType(ReaderScreen)), same(readerState));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader snapshot replacement still updates a body retained beside an editor',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openReply(tester);
      final reader = find.byType(ReaderScreen);
      final readerState = tester.state(reader);
      final body = find.descendant(
        of: reader,
        matching: find.byType(ForumBlocks),
      );
      final previousBody = tester.widget<ForumBlocks>(body);
      final editorController = _controller(tester);
      native.rootText[_a] = 'A refreshed body from the latest reader snapshot';
      await state.loadReader(_url(_a), force: true);
      await _frames(tester);
      expect(tester.state(reader), same(readerState));
      expect(tester.widget<ForumBlocks>(body), isNot(same(previousBody)));
      expect(find.text('A visible root', findRichText: true), findsNothing);
      expect(
        find.text(native.rootText[_a]!, findRichText: true),
        findsOneWidget,
      );
      expect(_controller(tester), same(editorController));
      expect(native.named('reader.replyDraft'), hasLength(1));
      final refreshedBody = tester.widget<ForumBlocks>(body);
      tester
          .widget<ReaderEditorHost>(find.byType(ReaderEditorHost))
          .editors
          .refresh();
      await tester.pump();
      expect(tester.widget<ForumBlocks>(body), same(refreshedBody));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader observes same-revision compose permission and owner completion directly',
    (tester) async {
      final native = _EditorNative();
      final state = AppState(client: native);
      await state.connect();
      state.readers[_url(_a)] = native.reader(_url(_a));
      final editors = ReaderEditors(
        state: state,
        readerVisible: () => true,
        canInteract: () => true,
        navigationIdentity: () => 0,
        revealTopic: (_) async {},
      );
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        editors.dispose();
        state.dispose();
        await native.snapshotEvents.close();
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        expect(native.unexpected, isEmpty);
      });
      // A fixed parent cannot hide a missing reader subscription by rebuilding
      // the reader when the workspace's separate session listener fires.
      await tester.pumpWidget(
        GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoApp(
            home: ReaderEditorHost(
              editors: editors,
              child: ReaderScreen(
                state: state,
                topic: TopicData(_topic(_a)),
                editors: editors,
              ),
            ),
          ),
        ),
      );
      await _frames(tester);
      final readerState = tester.state(find.byType(ReaderScreen));
      final revision = state.accessRevision;
      final snapshot = state.readerFor(_url(_a));

      void expectPermissions({required bool canCompose, required bool owner}) {
        expect(state.accessRevision, revision);
        expect(state.readerFor(_url(_a)), same(snapshot));
        expect(tester.state(find.byType(ReaderScreen)), same(readerState));
        expect(
          tester.widget<DeskButton>(_button('写回复')).onTap,
          canCompose ? isNotNull : isNull,
        );
        expect(
          tester
              .widget<CupertinoButton>(
                find.widgetWithText(CupertinoButton, '引用'),
              )
              .onPressed,
          canCompose ? isNotNull : isNull,
        );
        expect(_icon('编辑楼层'), owner ? findsOneWidget : findsNothing);
      }

      expectPermissions(canCompose: true, owner: true);
      native.snapshotEvents.add({
        'domain': 'session',
        'accessRevision': revision,
        'data': {...native.session, 'canCompose': false},
      });
      await tester.pump();
      expectPermissions(canCompose: false, owner: true);
      native.snapshotEvents.add({
        'domain': 'session',
        'accessRevision': revision,
        'data': {...native.session, 'canCompose': false, 'owner': null},
      });
      await tester.pump();
      expectPermissions(canCompose: false, owner: false);
      native.snapshotEvents.add({
        'domain': 'session',
        'accessRevision': revision,
        'data': native.session,
      });
      await tester.pump();
      expectPermissions(canCompose: true, owner: true);
      expect(native.named('reader.replyDraft'), isEmpty);
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact short reader keeps reply controls bounded and original text visible',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native, size: const Size(850, 540));
      await _openReply(tester);
      final readerScroll = find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.byType(CustomScrollView),
      );
      expect(tester.getSize(readerScroll).height, greaterThan(70));
      expect(find.text('A visible root', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Empty drafts intentionally disable sending and ignore pointer hits.
      // Exercise layout with a valid in-memory draft and both actions enabled.
      await tester.enterText(_body, 'Memory-only compact draft');
      await _frames(tester);
      await tester.ensureVisible(_button('发送回复'));
      await _frames(tester);
      expect(_button('发送回复').hitTestable(), findsOneWidget);
      expect(_button('放弃编辑').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact inline comparison falls back while resizing retains source and selection',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native, size: const Size(780, 540));
      await _openEdit(tester);
      final controller = _controller(tester);
      const source = 'Floor edit survives a compact comparison fallback';
      const selection = TextSelection(baseOffset: 6, extentOffset: 10);
      await tester.enterText(_body, source);
      controller.selection = selection;
      await _frames(tester);

      final comparison = find.descendant(
        of: find.byType(InlineEditScreen),
        matching: find.text('对照'),
      );
      final controls = find.descendant(
        of: find.byType(InlineEditScreen),
        matching: find.byType(MarkdownEditorControls),
      );
      final viewport = find.descendant(
        of: find.byType(InlineEditScreen),
        matching: find.byType(ComposerContentViewport),
      );
      await tester.ensureVisible(comparison);
      await _frames(tester);
      expect(comparison.hitTestable(), findsOneWidget);
      await tester.tap(comparison);
      await _frames(tester);
      expect(tester.widget<MarkdownEditorControls>(controls).mode, 0);
      expect(tester.widget<ComposerContentViewport>(viewport).split, isFalse);
      expect(_controller(tester), same(controller));
      expect(controller.text, source);
      expect(controller.selection, selection);
      expect(tester.takeException(), isNull);

      // The embedded panel deliberately caps its height. A wider, taller
      // workspace allows horizontal comparison without shrinking either pane.
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      await _frames(tester);
      await tester.ensureVisible(comparison);
      await _frames(tester);
      expect(comparison.hitTestable(), findsOneWidget);
      await tester.tap(comparison);
      await _frames(tester);
      expect(tester.widget<MarkdownEditorControls>(controls).mode, 1);
      expect(tester.widget<ComposerContentViewport>(viewport).split, isTrue);
      expect(_controller(tester), same(controller));
      expect(controller.text, source);
      expect(controller.selection, selection);
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(780, 540));
      await _frames(tester);
      expect(tester.widget<MarkdownEditorControls>(controls).mode, 0);
      expect(tester.widget<ComposerContentViewport>(viewport).split, isFalse);
      expect(_controller(tester), same(controller));
      expect(controller.text, source);
      expect(controller.selection, selection);
      expect(native.named('reader.edit.begin'), hasLength(1));
      await tester.ensureVisible(_button('保存修改'));
      await _frames(tester);
      expect(_button('保存修改').hitTestable(), findsOneWidget);
      await tester.ensureVisible(_button('取消编辑'));
      await _frames(tester);
      expect(_button('取消编辑').hitTestable(), findsOneWidget);
      expect(native.named('reader.edit.save'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [780.0, 850.0]) {
    testWidgets(
      'short ${width.toInt()} wide reader can retry a failed inline edit without overflow',
      (tester) async {
        final native = _EditorNative()..failNextEditBegin = true;
        await _mount(tester, native, size: Size(width, 540));
        final reader = tester.state(find.byType(ReaderScreen));
        await tester.tap(_icon('编辑楼层'));
        await _frames(tester);
        expect(find.byType(InlineEditScreen), findsOneWidget);
        expect(_body, findsNothing);
        expect(find.text('暂时无法编辑'), findsOneWidget);
        expect(find.text('A visible root', findRichText: true), findsOneWidget);
        expect(native.named('reader.edit.begin'), hasLength(1));
        expect(tester.takeException(), isNull);

        final retry = find.descendant(
          of: find.byType(InlineEditScreen),
          matching: _button('重试'),
        );
        await tester.ensureVisible(retry);
        await _frames(tester);
        expect(retry.hitTestable(), findsOneWidget);
        await tester.tap(retry);
        await _frames(tester);
        expect(_body, findsOneWidget);
        expect(_controller(tester).text, 'Original edit body');
        expect(native.named('reader.edit.begin'), hasLength(2));
        expect(tester.state(find.byType(ReaderScreen)), same(reader));
        expect(
          Navigator.of(tester.element(find.byType(WorkspaceScreen))).canPop(),
          isFalse,
        );
        await tester.ensureVisible(_button('取消编辑'));
        await _frames(tester);
        expect(_button('取消编辑').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'A to B to A retains the same reply controller and reads its draft once',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openReply(tester);
      final controller = _controller(tester);
      await tester.enterText(_body, 'Reply draft kept across tabs');
      await _frames(tester);
      await _select(tester, state, _b);
      expect(find.byType(ComposerScreen), findsNothing);
      expect(find.text('B visible root', findRichText: true), findsOneWidget);
      expect(_button('继续编辑 · 1'), findsOneWidget);
      await _select(tester, state, _a);
      expect(_controller(tester), same(controller));
      expect(controller.text, 'Reply draft kept across tabs');
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained reply reserves its return bar without clipping sidebar footer navigation',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native, size: const Size(1380, 880));
      await _openReply(tester);
      final controller = _controller(tester);
      await tester.enterText(
        _body,
        'Reply retained while using sidebar destinations',
      );
      await _frames(tester);
      await tester.tap(_footer('设置'));
      await _frames(tester);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(find.byType(ComposerScreen), findsNothing);

      void expectFooterFitsAndReceivesHits() {
        final hostFinder = find.byType(ReaderEditorHost);
        final host = tester.widget<ReaderEditorHost>(hostFinder);
        final hostBounds = tester.getRect(hostFinder);
        final childBounds = tester.getRect(find.byWidget(host.child));
        final sidebarBounds = tester.getRect(
          find.byKey(const ValueKey('workspace-sidebar')),
        );
        // Measure the actual laid-out workspace, not constraints captured
        // before the retained-editor host reserves its 44px return bar.
        expect(childBounds.bottom, closeTo(hostBounds.bottom - 44, .01));
        expect(sidebarBounds.top, greaterThanOrEqualTo(childBounds.top));
        expect(
          sidebarBounds.bottom,
          lessThanOrEqualTo(childBounds.bottom + .01),
        );
        expect(
          sidebarBounds.height,
          lessThanOrEqualTo(childBounds.height + .01),
        );
        for (final label in ['友情链接', '我的', '扩展中心', '设置']) {
          expect(_footer(label).hitTestable(), findsOneWidget, reason: label);
        }
        expect(_button('继续编辑 · 1').hitTestable(), findsOneWidget);
      }

      expectFooterFitsAndReceivesHits();
      await tester.tap(_footer('友情链接'));
      await _frames(tester);
      expect(find.byType(FriendLinksScreen), findsOneWidget);
      expect(find.byType(PreferencesScreen), findsNothing);
      expectFooterFitsAndReceivesHits();

      await tester.tap(_button('继续编辑 · 1'));
      await _frames(tester);
      expect(find.byType(FriendLinksScreen), findsNothing);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(_controller(tester), same(controller));
      expect(
        controller.text,
        'Reply retained while using sidebar destinations',
      );
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'floor editor survives settings and dirty tab closure reveals it without rebeginning',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openEdit(tester);
      final controller = _controller(tester);
      await tester.enterText(_body, 'Unsaved floor edit');
      await _frames(tester);
      await tester.tap(_footer('设置'));
      await _frames(tester);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(find.byType(InlineEditScreen), findsNothing);
      await tester.tap(_button('返回论坛'));
      await _frames(tester);
      expect(_controller(tester), same(controller));
      expect(controller.text, 'Unsaved floor edit');
      expect(native.named('reader.edit.begin'), hasLength(1));

      await _select(tester, state, _b);
      expect(await state.closeTopic(_a), isFalse);
      await _frames(tester);
      expect(state.workspace.selectedTab, _a);
      expect(_controller(tester), same(controller));
      expect(native.named('reader.close'), isEmpty);
      await _select(tester, state, _b);
      expect(await state.closeAllTopics(), isFalse);
      await _frames(tester);
      expect(state.workspace.selectedTab, _a);
      expect(_controller(tester), same(controller));
      expect(native.named('reader.closeAll'), isEmpty);
      expect(native.named('reader.edit.begin'), hasLength(1));
      expect(await state.flushDrafts(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old-account recovery keeps source copyable and blocks submission',
    (tester) async {
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard.isNotEmpty};
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openReply(tester);
      final controller = _controller(tester);
      await tester.enterText(_body, 'Old owner source to recover');
      await _frames(tester);
      native.snapshotEvents.add({
        'domain': 'session',
        'accessRevision': 1,
        'data': {
          'account': 'signedIn',
          'owner': 99,
          'canCompose': true,
          'profile': {'id': 99, 'name': 'New owner', 'avatar': ''},
        },
      });
      await _frames(tester);
      expect(state.accessRevision, 1);
      expect(find.byType(ComposerScreen), findsNothing);
      await tester.tap(_button('继续编辑 · 1'));
      await _frames(tester);
      expect(find.text('旧账号保留的编辑 · 仅供复制后关闭'), findsOneWidget);
      expect(_controller(tester), same(controller));
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
      expect(tester.widget<DeskButton>(_button('发送回复')).onTap, isNull);

      final editableFinder = find.descendant(
        of: _body,
        matching: find.byType(EditableText),
      );
      final editable = tester.state<EditableTextState>(editableFinder);
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      await tester.pump();
      editable.copySelection(SelectionChangedCause.toolbar);
      await tester.idle();
      expect(clipboard, 'Old owner source to recover');
      expect(native.named('reader.sendReply'), isEmpty);
      expect(
        native
            .named('reader.updateReplyDraft')
            .where((entry) => entry.$2['accessRevision'] == 1),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a hidden accepted reply retires only its own editor without navigating away from B',
    (tester) async {
      final native = _EditorNative()..pendingReply = Completer<JsonMap>();
      final state = await _mount(tester, native);
      await _openReply(tester);
      await tester.enterText(_body, 'Memory-only reply receipt');
      await _frames(tester);
      await tester.ensureVisible(_button('发送回复'));
      await tester.tap(_button('发送回复'));
      await _frames(tester);
      await tester.tap(find.widgetWithText(DeskDialogAction, '发送'));
      await _frames(tester);
      expect(native.named('reader.sendReply'), hasLength(1));
      await _select(tester, state, _b);
      final navigation = state.navigationRevision;
      native.pendingReply!.complete({
        'accepted': true,
        'destination': '${_url(_a)}#comment-12',
      });
      await _frames(tester);
      expect(state.workspace.selectedTab, _b);
      expect(state.navigationRevision, navigation);
      expect(find.text('B visible root', findRichText: true), findsOneWidget);
      expect(find.byType(ComposerScreen, skipOffstage: false), findsNothing);
      expect(native.named('reader.open'), isEmpty);
      expect(
        native
            .named('reader.load')
            .where(
              (entry) =>
                  entry.$2['url'] == _url(_a) && entry.$2['force'] == true,
            ),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reply restrictions remove reply entry while preserving owner floor editing',
    (tester) async {
      final native = _EditorNative(restricted: true);
      await _mount(tester, native);
      expect(find.text('已关闭回复'), findsNWidgets(2));
      expect(_button('写回复'), findsNothing);
      expect(_icon('编辑楼层'), findsOneWidget);
      await _openEdit(tester);
      expect(native.named('reader.replyDraft'), isEmpty);
      expect(native.named('reader.edit.begin'), hasLength(1));
      expect(find.text('A visible root', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Command K in an inline Markdown body inserts a link without opening search',
    (tester) async {
      final native = _EditorNative();
      await _mount(tester, native);
      await _openReply(tester);
      await tester.enterText(_body, 'selected link');
      final controller = _controller(tester);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 13,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _frames(tester);
      expect(controller.text, '[selected link](https://)');
      expect(
        Navigator.of(tester.element(find.byType(WorkspaceScreen))).canPop(),
        isFalse,
      );
      expect(find.byType(CupertinoTextField), findsOneWidget);
      expect(native.named('listing.search'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reply composition blocks tab closure and lifecycle flush until IME commits',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openReply(tester);
      final controller = _controller(tester);
      await tester.showKeyboard(_body);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '正在输入',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      final host = tester.widget<ReaderEditorHost>(
        find.byType(ReaderEditorHost),
      );
      expect(controller.value.composing, const TextRange(start: 0, end: 4));
      expect(host.editors.forTopic(_a)!.binding.busy, isTrue);
      expect(await state.flushDrafts(), isFalse);
      expect(await state.closeTopic(_a), isFalse);
      await _frames(tester);
      expect(state.workspace.tabs.map((tab) => tab.id), contains(_a));
      expect(native.named('reader.close'), isEmpty);
      expect(_controller(tester), same(controller));

      // A close-all request reaches the same guard without using a toolbar
      // tap, which could itself commit the platform's composition first.
      controller.value = const TextEditingValue(
        text: '正在输入',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      );
      expect(await state.closeAllTopics(), isFalse);
      await _frames(tester);
      expect(native.named('reader.closeAll'), isEmpty);
      expect(_controller(tester), same(controller));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '输入完成',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await _frames(tester);
      expect(controller.value.composing, TextRange.empty);
      expect(await state.flushDrafts(), isTrue);
      expect(native.drafts[_a], '输入完成');
      expect(await state.closeTopic(_a), isTrue);
      await _frames(tester);
      expect(native.named('reader.close'), hasLength(1));
      expect(state.workspace.tabs.map((tab) => tab.id), isNot(contains(_a)));
      expect(find.byType(ComposerScreen, skipOffstage: false), findsNothing);
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composition-only changes still block flushing an otherwise saved reply',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openReply(tester);
      await tester.enterText(_body, '已存草稿');
      await _frames(tester);
      expect(await state.flushDrafts(), isTrue);
      expect(native.drafts[_a], '已存草稿');
      final controller = _controller(tester);
      final saves = native.named('reader.updateReplyDraft').length;

      // The text did not change, so the ordinary dirty flag remains false.
      // IME ownership is nevertheless an independent reason to refuse exit.
      controller.value = const TextEditingValue(
        text: '已存草稿',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      );
      await tester.pump();
      expect(await state.flushDrafts(), isFalse);
      expect(await state.closeTopic(_a), isFalse);
      await _frames(tester);
      expect(_controller(tester), same(controller));
      expect(native.named('reader.close'), isEmpty);
      expect(native.named('reader.updateReplyDraft'), hasLength(saves));

      controller.value = controller.value.copyWith(composing: TextRange.empty);
      await tester.pump();
      expect(await state.flushDrafts(), isTrue);
      expect(await state.closeAllTopics(), isTrue);
      await _frames(tester);
      expect(native.named('reader.closeAll'), hasLength(1));
      expect(native.drafts[_a], '已存草稿');
      expect(find.byType(ComposerScreen, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'evicted reader content and a failed reload retain the floor editor and its close action',
    (tester) async {
      final native = _EditorNative();
      final state = await _mount(tester, native);
      await _openEdit(tester);
      final controller = _controller(tester);
      await tester.enterText(_body, 'Floor source survives a failed reader');
      await _frames(tester);

      // Model cache eviction independently of account identity, then exercise
      // the real correlated load failure path without a previous thread body.
      state.readers.remove(_url(_a));
      state.domains.remove('reader');
      native.failReaderLoads = true;
      await state.loadReader(_url(_a), force: true);
      await _frames(tester);
      expect(state.readerFor(_url(_a))['thread'], isNull);
      expect(state.readerFor(_url(_a))['error'], 'Memory reader load failed');
      expect(find.text('A visible root', findRichText: true), findsNothing);
      expect(find.byType(ReaderEditorAnchor), findsOneWidget);
      expect(_controller(tester), same(controller));
      expect(controller.text, 'Floor source survives a failed reader');
      expect(native.named('reader.edit.begin'), hasLength(1));
      expect(_button('取消编辑').hitTestable(), findsOneWidget);

      await tester.tap(_button('取消编辑'));
      await _frames(tester);
      expect(find.text('放弃这次修改'), findsOneWidget);
      await tester.tap(find.widgetWithText(DeskDialogAction, '放弃修改'));
      await _frames(tester);
      expect(native.named('reader.edit.cancel'), hasLength(1));
      expect(find.byType(InlineEditScreen, skipOffstage: false), findsNothing);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(state.workspace.selectedTab, _a);
      expect(
        Navigator.of(tester.element(find.byType(WorkspaceScreen))).canPop(),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final editingTitle in [false, true]) {
    testWidgets(
      'inline ${editingTitle ? 'title' : 'body'} composition-only changes disable and restore save and cancel buttons',
      (tester) async {
        final native = _EditorNative();
        await _mount(tester, native);
        await _openEdit(tester);
        final field = editingTitle
            ? find.descendant(
                of: find.byType(InlineEditScreen),
                matching: find.byWidgetPredicate(
                  (widget) => widget is CupertinoTextField && !widget.expands,
                ),
              )
            : _body;
        expect(field, findsOneWidget);
        final controller = tester.widget<CupertinoTextField>(field).controller!;
        const text = 'Edited source awaiting commit';
        controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        await _frames(tester);
        expect(tester.widget<DeskButton>(_button('保存修改')).onTap, isNotNull);
        expect(tester.widget<DeskButton>(_button('取消编辑')).onTap, isNotNull);

        // Text and selection stay identical. Only the composing range changes,
        // so rebuilding these buttons must not depend on a dirty-text event or
        // an unrelated network/image callback.
        controller.value = controller.value.copyWith(
          composing: const TextRange(start: 0, end: 6),
        );
        await tester.pump();
        expect(controller.text, text);
        expect(tester.widget<DeskButton>(_button('保存修改')).onTap, isNull);
        expect(tester.widget<DeskButton>(_button('取消编辑')).onTap, isNull);

        controller.value = controller.value.copyWith(
          composing: TextRange.empty,
        );
        await tester.pump();
        expect(controller.text, text);
        expect(tester.widget<DeskButton>(_button('保存修改')).onTap, isNotNull);
        expect(tester.widget<DeskButton>(_button('取消编辑')).onTap, isNotNull);
        expect(native.named('reader.edit.save'), isEmpty);
        expect(native.named('reader.edit.cancel'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
