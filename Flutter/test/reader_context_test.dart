import 'dart:async';
import 'dart:convert';

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
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_material_scope.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';
import 'package:seekdesk_flutter/widgets/reader_editor_host.dart';

const _id = '3701';
const _author = 73;
const _name = 'Context author';
const _avatar = 'https://www.nodeseek.com/avatar/fixture.png';
const _summary = 'A retained RSS summary for a temporarily unavailable thread.';
String _url([int page = 2]) => 'https://www.nodeseek.com/post-$_id-$page';
JsonMap _topic([int page = 2]) => {
  'id': _id,
  'url': _url(page),
  'title': 'Reader context fixture',
  'category': 'tech',
  'categoryLabel': '技术',
  'summary': _summary,
};

JsonMap _floor({String id = '0', int? authorID = _author}) => {
  'id': id,
  'authorID': ?authorID,
  'author': authorID == null ? 'Anonymous fixture' : _name,
  'avatar': '',
  'date': '2026-11-15 09:37:00',
  'dateLabel': '刚刚',
  'tags': ['主题作者'],
  'blocks': [
    {
      'kind': 'text',
      'text': id == '0' ? 'Original context body' : 'Reply body $id',
    },
  ],
};

/// Every request ends here. This fixture has no platform/network fallback and
/// rejects mutations and unsolicited full-profile reads.
class _ContextNative extends NativeClient {
  _ContextNative()
    : super(methods: const MethodChannel('seekdesk.test.reader-context'));

  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Completer<JsonMap>? pendingAuthor;
  Completer<JsonMap>? pendingReader;
  bool allowProfileScreen = false;
  bool failLoads = false;
  String draft = '';
  double savedOffset = 0;
  JsonMap? savedBodyAnchor;
  int page = 2;
  JsonMap root = _floor();
  List<JsonMap> replies = [_floor(id: '1'), _floor(id: '2', authorID: null)];
  JsonMap authorProfile = {
    'member_id': _author,
    'member_name': _name,
    'rank': 7,
    'roles': [
      {'display_text': '摘要身份'},
    ],
    'signature_markdown': 'Signature from the lightweight author summary',
  };

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  JsonMap get workspace => {
    'posts': [_topic(page)],
    'tabs': [_topic(page)],
    'selectedTab': _id,
    'showReader': true,
    'board': 'tech',
    'boards': [
      {'id': '', 'title': '最新帖子'},
      {'id': 'tech', 'title': '技术'},
    ],
  };

  JsonMap reader([String? url]) => {
    'url': url ?? _url(page),
    'accessRevision': accessRevision,
    'authorProfilesSupported': true,
    'loading': false,
    'scrollOffset': savedOffset,
    if (savedBodyAnchor != null) 'bodyAnchor': savedBodyAnchor,
    'thread': {
      'title': 'Reader context fixture',
      'category': '技术',
      'page': page,
      'root': root,
      'replies': replies,
      // Missing the current page and repeating a neighbour matches real
      // pagination fragments; both controls must normalize the same sequence.
      'pages': [
        {'number': 3, 'url': _url(3)},
        {'number': 1, 'url': _url(1)},
        {'number': 3, 'url': _url(3)},
      ],
    },
  };

  JsonMap get replyDraft => {
    'topicID': _id,
    'content': draft,
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
  };

  List<(String, JsonMap)> named(String method) =>
      calls.where((entry) => entry.$1 == method).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments, 'accessRevision': accessRevision}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'session': {
            'account': 'signedIn',
            'owner': 42,
            'canCompose': true,
            'accessRevision': accessRevision,
            'profile': {'id': 42, 'name': 'Fixture owner', 'avatar': ''},
          },
          'settings': {
            'workspace.sidebarWidth': 228.0,
            'workspace.topicColumnWidth': 280.0,
          },
          'extensions': {'items': <JsonMap>[]},
        };
      case 'reader.author':
        if (arguments['id'] != _author || arguments['url'] != _url(page)) {
          unexpected.add('author outside the loaded page');
          throw StateError('Only the loaded floor author is available.');
        }
        final pending = pendingAuthor;
        if (pending != null) return pending.future;
        return {'profile': authorProfile, 'accessRevision': accessRevision};
      case 'profile.load':
        if (!allowProfileScreen) break;
        return {
          'account': 'signedIn',
          'profile': {...authorProfile, 'avatar': _avatar},
          'accessRevision': accessRevision,
        };
      case 'reader.load':
        if (failLoads) {
          throw const NativeFailure(
            'network',
            'Memory reader connection failed',
          );
        }
        final readerResponse = pendingReader;
        if (readerResponse != null) return readerResponse.future;
        return reader(stringValue(arguments['url']));
      case 'reader.open':
        page = int.parse(
          RegExp(r'post-3701-(\d+)')
              .firstMatch(stringValue(arguments['url']))![1]!,
        );
        return workspace;
      case 'reader.rememberPosition':
        savedOffset = numberValue(arguments['offset']);
        savedBodyAnchor = arguments['bodyAnchor'] is Map
            ? jsonMap(arguments['bodyAnchor'])
            : null;
        return {'saved': true};
      case 'images.load':
        if (arguments['url'] != _avatar || arguments['kind'] != 'avatar') break;
        return {
          'bytes': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          'width': 1,
          'height': 1,
        };
      case 'reader.replyDraft':
        return replyDraft;
      case 'reader.updateReplyDraft':
        draft = stringValue(arguments['content']);
        return replyDraft;
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
        };
      case 'stickers.list':
        return {'packs': <JsonMap>[]};
      case 'session.verify':
      case 'session.signIn':
      case 'external.open':
        return {'recorded': true};
    }
    unexpected.add(method);
    throw StateError('Unexpected context fixture operation: $method');
  }
}

class _ContextState extends AppState {
  _ContextState(_ContextNative native) : super(client: native);
  final openedTopics = <TopicData>[];

  @override
  Future<void> openTopic(TopicData topic) {
    openedTopics.add(topic);
    return super.openTopic(topic);
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _pagination(String position) =>
    find.byKey(ValueKey('reader-pagination:$position'));
Finder _pageButton(String position, String label) =>
    find.descendant(of: _pagination(position), matching: _button(label));
Finder get _bodyField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);
Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<_ContextState> _prepare(
  WidgetTester tester,
  _ContextNative native,
) async {
  final state = _ContextState(native);
  await state.connect();
  state.readers[_url()] = native.reader();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    await native.snapshotEvents.close();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  return state;
}

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  double width = 900,
  double height = 1200,
  bool workspace = false,
  ValueNotifier<double>? pixelRatio,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1400));
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) => ExtensionOverlays(
          state: state,
          child: pixelRatio == null
              ? child!
              : ValueListenableBuilder<double>(
                  valueListenable: pixelRatio,
                  child: child,
                  builder: (context, value, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(devicePixelRatio: value),
                    child: child!,
                  ),
                ),
        ),
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: width,
              height: height,
              child: workspace
                  ? WorkspaceScreen(state: state)
                  : ReaderScreen(state: state, topic: TopicData(_topic())),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
}

List<TextSpan> _textSpans(InlineSpan span) => [
  if (span is TextSpan) ...[
    span,
    for (final child in span.children ?? <InlineSpan>[]) ..._textSpans(child),
  ],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'narrow local reader bounds long author metadata and preserves floor context',
    (tester) async {
      final native = _ContextNative()..replies = [];
      native.root = {
        ...native.root,
        'author': '非常长的作者姓名 LongUnbrokenAuthorNameForNarrowReader',
        'tags': ['主题作者', '很长的论坛身份标签', '另一个身份', '最后一个标签'],
      };
      final state = await _prepare(tester, native);
      state.domains['settings'] = {'workspace.floorAuthorScale': 150};
      state.domains['extensions'] = {
        'items': [
          {'id': 'rulings', 'active': true},
          {'id': 'block', 'active': true},
        ],
      };
      await _mount(tester, state, width: 340);
      expect(find.text('#0'), findsOneWidget);
      expect(find.text('2026-11-15 09:37:00'), findsOneWidget);
      expect(find.text('楼主'), findsOneWidget);
      expect(find.text('摘要身份'), findsOneWidget);
      expect(
        find.text('Original context body', findRichText: true),
        findsOneWidget,
      );
      final avatar = find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.byType(NativeAvatar),
      );
      expect(avatar, findsOneWidget);
      expect(tester.getSize(avatar).width, greaterThan(34));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'both page controls deduplicate neighbours and current page never navigates',
    (tester) async {
      final native = _ContextNative()..replies = [];
      final state = await _prepare(tester, native);
      await _mount(tester, state);
      final navigation = state.navigationRevision;
      for (final position in ['top', 'bottom']) {
        final buttons = tester.widgetList<DeskButton>(
          find.descendant(
            of: _pagination(position),
            matching: find.byType(DeskButton),
          ),
        );
        expect(buttons.map((button) => button.label), [
          '上一页',
          '1',
          '2',
          '3',
          '下一页',
        ]);
        final current = _pageButton(position, '2');
        expect(tester.widget<DeskButton>(current).onTap, isNull);
        await tester.ensureVisible(current);
        await _frames(tester);
        await tester.tapAt(tester.getCenter(current));
        await _frames(tester);
      }
      expect(state.navigationRevision, navigation);
      expect(state.openedTopics, isEmpty);
      expect(native.named('reader.open'), isEmpty);
      expect(native.named('reader.load'), isEmpty);

      for (final position in ['top', 'bottom']) {
        final next = _pageButton(position, '3');
        await tester.ensureVisible(next);
        await _frames(tester);
        expect(next.hitTestable(), findsOneWidget);
        await tester.tap(next);
        await _frames(tester);
        expect(state.openedTopics.last.id, _id);
        expect(state.openedTopics.last.url, _url(3));
        expect(native.named('reader.open').last.$2['id'], _id);
        expect(native.named('reader.open').last.$2['url'], _url(3));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated loaded authors share a lightweight summary without global notification',
    (tester) async {
      final native = _ContextNative()..pendingAuthor = Completer<JsonMap>();
      final state = await _prepare(tester, native);
      await _mount(tester, state);
      expect(native.named('reader.author'), hasLength(1));
      expect(native.named('reader.author').single.$2['id'], _author);
      expect(native.named('reader.author').single.$2['url'], _url());
      expect(native.named('profile.load'), isEmpty);
      var notifications = 0;
      void onStateChanged() => notifications++;
      state.addListener(onStateChanged);
      native.pendingAuthor!.complete({
        'profile': native.authorProfile,
        'accessRevision': state.accessRevision,
      });
      await _frames(tester);
      expect(find.text('摘要身份'), findsNWidgets(2));
      expect(
        find.text(
          'Signature from the lightweight author summary',
          findRichText: true,
        ),
        findsNWidgets(2),
      );
      expect(native.named('reader.author'), hasLength(1));
      expect(native.named('profile.load'), isEmpty);
      expect(notifications, 0);
      state.removeListener(onStateChanged);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late author geometry preserves the scrolled body and refresh keeps existing enrichment',
    (tester) async {
      const signature =
          'A delayed signature with enough text to wrap across the '
          'narrow reading column and add height above the visible reply.';
      final native = _ContextNative()
        ..pendingAuthor = Completer<JsonMap>()
        ..replies = [
          for (var floor = 1; floor <= 16; floor++)
            _floor(id: '$floor', authorID: null),
        ];
      final state = await _prepare(tester, native);
      await _mount(tester, state, width: 440, height: 650);
      final controller = tester
          .widget<CustomScrollView>(_readerScroll)
          .controller!;
      final target = find.text('Reply body 2', findRichText: true);
      controller.jumpTo(300);
      await _frames(tester);
      expect(target, findsOneWidget);
      final viewportTop = tester.getTopLeft(_readerScroll).dy;
      controller.jumpTo(
        (controller.offset + tester.getTopLeft(target).dy - viewportTop - 160)
            .clamp(0.0, controller.position.maxScrollExtent),
      );
      await _frames(tester);
      expect(target.hitTestable(), findsOneWidget);
      expect(controller.offset, greaterThan(1));
      expect(controller.position.isScrollingNotifier.value, isFalse);
      final yBefore = tester.getTopLeft(target).dy;
      final offsetBefore = controller.offset;
      final bodyElement = tester.element(target);
      expect(find.text('Lv.7', skipOffstage: false), findsNothing);
      native.pendingAuthor!.complete({
        'profile': {
          ...native.authorProfile,
          'roles': [
            for (var tag = 1; tag <= 8; tag++)
              {'display_text': 'Delayed author tag $tag'},
          ],
          'signature_markdown': signature,
        },
        'accessRevision': state.accessRevision,
      });
      await _frames(tester);
      expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Delayed author tag 8', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text(signature, findRichText: true, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.getTopLeft(target).dy, closeTo(yBefore, 1));
      expect(tester.element(target), same(bodyElement));
      expect(controller.offset, greaterThan(offsetBefore + 20));
      expect(native.named('reader.author'), hasLength(1));
      expect(tester.takeException(), isNull);

      // While a forced refresh owns the page, the old summary remains visible.
      // A second pending summary after that refresh must retain it as well.
      native.pendingReader = Completer<JsonMap>();
      native.pendingAuthor = Completer<JsonMap>();
      final refresh = state.loadReader(_url(), force: true);
      await _frames(tester);
      expect(state.readerFor(_url())['loading'], isTrue);
      expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
      expect(
        find.text(signature, findRichText: true, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.getTopLeft(target).dy, closeTo(yBefore, 1));
      expect(tester.element(target), same(bodyElement));
      native.pendingReader!.complete(native.reader());
      await refresh;
      await _frames(tester);
      expect(native.named('reader.author'), hasLength(2));
      expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
      expect(
        find.text(signature, findRichText: true, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.getTopLeft(target).dy, closeTo(yBefore, 1));
      expect(tester.element(target), same(bodyElement));
      final viewport = tester.getRect(_readerScroll);
      final gesture = await tester.startGesture(
        Offset(viewport.left + 8, viewport.top + viewport.height * .7),
      );
      var released = false;
      try {
        await gesture.moveBy(const Offset(0, -45));
        await _frames(tester);
        final held = controller.offset;
        native.pendingAuthor!.complete({
          'profile': {
            ...native.authorProfile,
            'rank': 9,
            'signature_markdown': 'Refreshed author signature',
          },
          'accessRevision': state.accessRevision,
        });
        await _frames(tester);
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect(controller.offset, closeTo(held, .01));
        expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
        expect(find.text('Lv.9', skipOffstage: false), findsNothing);
        expect(
          find.text(signature, findRichText: true, skipOffstage: false),
          findsOneWidget,
        );
        await gesture.moveBy(const Offset(0, -25));
        await _frames(tester);
        expect(controller.offset, greaterThan(held + 15));
        final latestY = tester.getTopLeft(target).dy;
        await gesture.up();
        released = true;
        expect(controller.position.isScrollingNotifier.value, isFalse);
        await _frames(tester);
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        expect(find.text('Lv.9', skipOffstage: false), findsOneWidget);
        expect(
          find.text(
            'Refreshed author signature',
            findRichText: true,
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(tester.getTopLeft(target).dy, closeTo(latestY, 1));
        expect(tester.element(target), same(bodyElement));
        expect(native.named('reader.author'), hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        if (!released) await gesture.cancel();
      }
    },
  );

  testWidgets(
    'returning to an enriched reader never accumulates the saved position',
    (tester) async {
      final native = _ContextNative()
        ..replies = [
          for (var floor = 1; floor <= 16; floor++)
            _floor(id: '$floor', authorID: null),
        ];
      final state = await _prepare(tester, native);
      await _mount(tester, state, width: 440, height: 650);
      final controller = tester
          .widget<CustomScrollView>(_readerScroll)
          .controller!;
      final target = find.text('Reply body 2', findRichText: true);
      controller.jumpTo(300);
      await _frames(tester);
      controller.jumpTo(
        controller.offset +
            tester.getTopLeft(target).dy -
            tester.getTopLeft(_readerScroll).dy -
            160,
      );
      await _frames(tester);
      final expected = controller.offset;
      final bodyY = tester.getTopLeft(target).dy;
      for (var visit = 0; visit < 10; visit++) {
        await tester.pumpWidget(const SizedBox.shrink());
        await _frames(tester);
        await _mount(tester, state, width: 440, height: 650);
        final current = tester
            .widget<CustomScrollView>(_readerScroll)
            .controller!;
        expect(current.offset, closeTo(expected, 1), reason: 'Return $visit');
        expect(tester.getTopLeft(target).dy, closeTo(bodyY, 1));
      }
      expect(native.named('reader.author'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a persisted body anchor restores across cold author layouts and changed width',
    (tester) async {
      // Keep the intended body nearest the viewport top. At y=160 the
      // previous floor can still be visible and correctly become the saved
      // anchor; a responsive header between those two bodies may then change
      // this body's position without moving that persisted anchor.
      const targetDy = 40.0;
      final firstNative = _ContextNative()
        ..replies = [
          for (var floor = 1; floor <= 16; floor++)
            _floor(id: '$floor', authorID: null),
        ];
      final first = await _prepare(tester, firstNative);
      await _mount(tester, first, width: 440, height: 650);
      final target = find.text('Reply body 2', findRichText: true);
      final scroll = tester.widget<CustomScrollView>(_readerScroll).controller!;
      scroll.jumpTo(300);
      await _frames(tester);
      scroll.jumpTo(
        scroll.offset +
            tester.getTopLeft(target).dy -
            tester.getTopLeft(_readerScroll).dy -
            targetDy,
      );
      await _frames(tester);
      final bodyY = tester.getTopLeft(target).dy;
      expect(bodyY - tester.getTopLeft(_readerScroll).dy, closeTo(targetDy, 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
      expect(firstNative.savedBodyAnchor, isNotNull);
      expect(firstNative.savedBodyAnchor!['floor'], '2');
      expect(firstNative.savedBodyAnchor!['dy'], closeTo(targetDy, 1));

      for (final width in [440.0, 600.0]) {
        final native = _ContextNative()
          ..replies = firstNative.replies
          ..savedOffset = firstNative.savedOffset
          ..savedBodyAnchor = firstNative.savedBodyAnchor
          ..pendingAuthor = Completer<JsonMap>();
        final state = await _prepare(tester, native);
        await _mount(tester, state, width: width, height: 650);
        expect(state.readerBodyAnchor(_url())?.floor, '2');
        expect(state.readerBodyAnchor(_url())?.dy, closeTo(targetDy, 1));
        expect(tester.getTopLeft(target).dy, closeTo(bodyY, 1));
        native.pendingAuthor!.complete({
          'profile': native.authorProfile,
          'accessRevision': state.accessRevision,
        });
        await _frames(tester);
        expect(state.readerBodyAnchor(_url())?.floor, '2');
        expect(state.readerBodyAnchor(_url())?.dy, closeTo(targetDy, 1));
        expect(tester.getTopLeft(target).dy, closeTo(bodyY, 1));
        if (width == 440) {
          expect(
            tester.widget<CustomScrollView>(_readerScroll).controller!.offset,
            closeTo(firstNative.savedOffset, 1),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _frames(tester);
        expect(native.savedBodyAnchor?['floor'], '2');
        expect(
          native.savedBodyAnchor?['dy'],
          closeTo(firstNative.savedBodyAnchor!['dy'] as num, 1),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an active scroll gesture defers author enrichment until the reader is idle',
    (tester) async {
      const signature = 'Author signature delivered while the drag is active';
      final native = _ContextNative()
        ..pendingAuthor = Completer<JsonMap>()
        ..replies = [
          for (var floor = 1; floor <= 16; floor++)
            _floor(id: '$floor', authorID: null),
        ];
      final state = await _prepare(tester, native);
      // The fixture's other author is not editable by the current owner. Keep
      // a real floor action mounted so the completion also measures its scope.
      state.domains['extensions'] = {
        'items': [
          {'id': 'rulings', 'active': true},
        ],
      };
      await _mount(tester, state, width: 440, height: 650);
      final controller = tester
          .widget<CustomScrollView>(_readerScroll)
          .controller!;
      // Put the reply near the top before dragging so author enrichment above
      // it must compensate this actual reading anchor, not a lower body that
      // can legitimately move while the still-visible root stays anchored.
      final target = find.text('Reply body 2', findRichText: true);
      controller.jumpTo(300);
      await _frames(tester);
      final viewport = tester.getRect(_readerScroll);
      controller.jumpTo(
        (controller.offset + tester.getTopLeft(target).dy - viewport.top - 180)
            .clamp(0.0, controller.position.maxScrollExtent),
      );
      await _frames(tester);
      // Start in the viewport's blank inset so a link, text selection or floor
      // action cannot accidentally own the pointer instead of the scroll view.
      final gesture = await tester.startGesture(
        Offset(viewport.left + 8, viewport.top + viewport.height * .65),
      );
      var released = false;
      try {
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect(controller.offset, greaterThan(0));
        final targetRect = tester.getRect(target);
        expect(targetRect.top, greaterThanOrEqualTo(viewport.top));
        expect(targetRect.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(state.readerBodyAnchor(_url())?.floor, '2');
        final heldOffset = controller.offset;
        final root = find.byWidgetPredicate(
          (widget) => widget is ReaderFloorContext && widget.root,
          skipOffstage: false,
        );
        final rootElement = tester.element(root);
        final actions = find.descendant(
          of: root,
          matching: find.byType(DeskMaterialScope, skipOffstage: false),
          skipOffstage: false,
        );
        expect(actions, findsOneWidget);
        final actionsElement = tester.element(actions);
        var rootBuilds = 0, actionsBuilds = 0;
        final previousHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousHook?.call(element, builtOnce);
          if (identical(element, rootElement)) rootBuilds++;
          if (identical(element, actionsElement)) actionsBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
        native.pendingAuthor!.complete({
          'profile': {...native.authorProfile, 'signature_markdown': signature},
          'accessRevision': state.accessRevision,
        });
        await _frames(tester, 2);
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect(controller.offset, closeTo(heldOffset, .01));
        expect(
          rootBuilds,
          0,
          reason: 'Completing held metadata must not rebuild the floor',
        );
        expect(
          actionsBuilds,
          0,
          reason: 'Completing held metadata must not rebuild floor actions',
        );
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        expect(
          find.text(signature, findRichText: true, skipOffstage: false),
          findsNothing,
        );

        // A parent update must not synchronously apply the completed cache
        // while this mounted floor is still deferring it for the active drag.
        native.snapshotEvents.add({
          'domain': 'settings',
          'accessRevision': state.accessRevision,
          'data': {...state.domain('settings')},
        });
        await _frames(tester, 2);
        expect(controller.offset, closeTo(heldOffset, .01));
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        expect(
          find.text(signature, findRichText: true, skipOffstage: false),
          findsNothing,
        );

        // A subsequent movement must still be handled by the same drag. A
        // metadata-driven jumpTo would have cancelled its activity already.
        await gesture.moveBy(const Offset(0, -35));
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect(controller.offset, greaterThan(heldOffset + 20));
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        final bodyElement = tester.element(target);
        final latestY = tester.getTopLeft(target).dy;
        final latestAnchor = state.readerBodyAnchor(_url());
        expect(latestAnchor?.floor, '2');
        rootBuilds = 0;
        actionsBuilds = 0;
        await gesture.up();
        released = true;
        // Explicitly stop any release momentum; do not depend on physics or
        // wall-clock settling to decide when this test reaches an idle reader.
        controller.jumpTo(controller.offset);
        await _frames(tester);
        expect(controller.position.isScrollingNotifier.value, isFalse);
        expect(rootBuilds, 1);
        expect(actionsBuilds, 1);
        expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
        expect(
          find.text(signature, findRichText: true, skipOffstage: false),
          findsOneWidget,
        );
        expect(tester.getTopLeft(target).dy, closeTo(latestY, 1));
        expect(tester.element(target), same(bodyElement));
        expect(state.readerBodyAnchor(_url())?.floor, '2');
        expect(
          state.readerBodyAnchor(_url())?.dy,
          closeTo(latestAnchor!.dy, 1),
        );
        expect(native.named('reader.author'), hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        if (!released) await gesture.cancel();
      }
    },
  );

  for (final replacePosition in [false, true]) {
    testWidgets(
      replacePosition
          ? 'pending author survives replacement of its active scroll position'
          : 'pending author waits through a second drag before the next layout',
      (tester) async {
        const signature =
            'Delayed complete author signature retained until idle';
        final ratio = ValueNotifier(1.0);
        addTearDown(ratio.dispose);
        final native = _ContextNative()
          ..pendingAuthor = Completer<JsonMap>()
          ..replies = [
            for (var floor = 1; floor <= 16; floor++)
              _floor(id: '$floor', authorID: null),
          ];
        final state = await _prepare(tester, native);
        await _mount(tester, state, width: 440, height: 650, pixelRatio: ratio);
        final controller = tester
            .widget<CustomScrollView>(_readerScroll)
            .controller!;
        final target = find.text('Reply body 2', findRichText: true);
        controller.jumpTo(300);
        await _frames(tester);
        controller.jumpTo(
          controller.offset +
              tester.getTopLeft(target).dy -
              tester.getTopLeft(_readerScroll).dy -
              180,
        );
        await _frames(tester);
        final bodyElement = tester.element(target);
        final viewport = tester.getRect(_readerScroll);
        final origin = Offset(
          viewport.left + 8,
          viewport.top + viewport.height * .7,
        );
        final first = await tester.startGesture(origin);
        TestGesture? second;
        var firstReleased = false, secondReleased = false;
        try {
          await first.moveBy(const Offset(0, -45));
          await tester.pump(const Duration(milliseconds: 16));
          expect(controller.position.isScrollingNotifier.value, isTrue);
          native.pendingAuthor!.complete({
            'profile': {
              ...native.authorProfile,
              'roles': [
                for (var tag = 1; tag <= 8; tag++)
                  {'display_text': 'Pending author tag $tag'},
              ],
              'signature_markdown': signature,
            },
            'accessRevision': state.accessRevision,
          });
          await _frames(tester);
          expect(find.text('Lv.7', skipOffstage: false), findsNothing);
          final position = controller.position;
          if (replacePosition) {
            ratio.value = 2;
            await _frames(tester);
            expect(controller.position, isNot(same(position)));
            expect(controller.position.isScrollingNotifier.value, isTrue);
            expect(find.text('Lv.7', skipOffstage: false), findsNothing);
          } else {
            await first.up();
            firstReleased = true;
            expect(controller.position.isScrollingNotifier.value, isFalse);
            second = await tester.startGesture(origin);
            await second.moveBy(const Offset(0, -45));
            expect(controller.position.isScrollingNotifier.value, isTrue);
            await _frames(tester);
            expect(find.text('Lv.7', skipOffstage: false), findsNothing);
            expect(
              find.text(signature, findRichText: true, skipOffstage: false),
              findsNothing,
            );
          }
          final active = second ?? first;
          final held = controller.offset;
          await active.moveBy(const Offset(0, -25));
          await _frames(tester);
          expect(controller.position.isScrollingNotifier.value, isTrue);
          expect(controller.offset, greaterThan(held + 15));
          expect(find.text('Lv.7', skipOffstage: false), findsNothing);
          final latestY = tester.getTopLeft(target).dy;
          final latestOffset = controller.offset;
          await active.up();
          if (second == null) {
            firstReleased = true;
          } else {
            secondReleased = true;
          }
          expect(controller.position.isScrollingNotifier.value, isFalse);
          await _frames(tester, 12);
          expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
          expect(
            find.text('Pending author tag 8', skipOffstage: false),
            findsOneWidget,
          );
          expect(
            find.text(signature, findRichText: true, skipOffstage: false),
            findsOneWidget,
          );
          expect(tester.getTopLeft(target).dy, closeTo(latestY, 1));
          expect(controller.offset, greaterThan(latestOffset + 20));
          expect(tester.element(target), same(bodyElement));
          expect(native.named('reader.author'), hasLength(1));
          expect(native.named('profile.load'), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          if (!firstReleased) await first.cancel();
          if (second != null && !secondReleased) await second.cancel();
        }
      },
    );
  }

  for (final retirement in ['author', 'revision', 'dispose']) {
    testWidgets('queued author adoption retires safely on $retirement change', (
      tester,
    ) async {
      const signature = 'Metadata belonging to the retired author request';
      final native = _ContextNative()
        ..pendingAuthor = Completer<JsonMap>()
        ..replies = [
          for (var floor = 1; floor <= 16; floor++)
            _floor(id: '$floor', authorID: null),
        ];
      final state = await _prepare(tester, native);
      await _mount(tester, state, width: 440, height: 650);
      final root = find.byWidgetPredicate(
        (widget) => widget is ReaderFloorContext && widget.root,
      );
      final originalFloor = tester.state(root);
      final controller = tester
          .widget<CustomScrollView>(_readerScroll)
          .controller!;
      final viewport = tester.getRect(_readerScroll);
      final gesture = await tester.startGesture(
        Offset(viewport.left + 8, viewport.top + viewport.height * .7),
      );
      var released = false;
      try {
        await gesture.moveBy(const Offset(0, -60));
        await _frames(tester);
        native.pendingAuthor!.complete({
          'profile': {...native.authorProfile, 'signature_markdown': signature},
          'accessRevision': state.accessRevision,
        });
        await _frames(tester);
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        await gesture.up();
        released = true;
        expect(controller.position.isScrollingNotifier.value, isFalse);
        switch (retirement) {
          case 'author':
            native.root = _floor(authorID: null);
            state.readers[_url()] = native.reader();
            state.notifyListeners();
            await _frames(tester);
            expect(tester.state(root), same(originalFloor));
            expect(find.text('Anonymous fixture'), findsWidgets);
          case 'revision':
            native.pendingAuthor = null;
            native.authorProfile = {
              ...native.authorProfile,
              'rank': 9,
              'signature_markdown': 'Current account metadata',
            };
            native.snapshotEvents.add({
              'domain': 'session',
              'accessRevision': 1,
              'data': {'account': 'signedIn', 'owner': 99, 'accessRevision': 1},
            });
            state.readers[_url()] = native.reader();
            state.notifyListeners();
            await _frames(tester);
            expect(state.accessRevision, 1);
            expect(root, findsNothing);
          case 'dispose':
            await tester.pumpWidget(const SizedBox.shrink());
            await _frames(tester);
            expect(root, findsNothing);
        }
        expect(find.text('Lv.7', skipOffstage: false), findsNothing);
        expect(
          find.text(signature, findRichText: true, skipOffstage: false),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        if (retirement == 'author') {
          native.root = _floor();
          state.readers[_url()] = native.reader();
          state.notifyListeners();
          await _frames(tester);
        } else if (retirement == 'dispose') {
          await _mount(tester, state, width: 440, height: 650);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
          await _mount(tester, state, width: 440, height: 650);
          expect(find.text('Lv.9', skipOffstage: false), findsOneWidget);
          expect(native.named('reader.author'), hasLength(2));
        }
        if (retirement != 'revision') {
          expect(find.text('Lv.7', skipOffstage: false), findsOneWidget);
          expect(
            find.text(signature, findRichText: true, skipOffstage: false),
            findsOneWidget,
          );
          expect(
            native.named('reader.author'),
            hasLength(retirement == 'author' ? 2 : 1),
          );
        }
        expect(native.named('profile.load'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!released) await gesture.cancel();
      }
    });
  }

  for (final (hasOwnSignature, ownSignature, expected) in [
    (true, 'Own edited signature', 'Own edited signature'),
    (true, '', ''),
    (false, '', 'Stored floor signature'),
  ]) {
    testWidgets(
      'own signature ${hasOwnSignature
          ? ownSignature.isEmpty
                ? 'explicitly empty'
                : 'edited'
          : 'absent'} preserves authoritative precedence',
      (tester) async {
        final native = _ContextNative()..replies = [];
        native.root = {...native.root, 'signature': 'Stored floor signature'};
        native.authorProfile = {
          ...native.authorProfile,
          if (hasOwnSignature) 'ownSignature': ownSignature,
          'signature_markdown': 'Profile markdown fallback',
          'bio': 'Profile bio fallback',
        };
        final state = await _prepare(tester, native);
        state.domains['session'] = {
          ...state.domain('session'),
          'owner': _author,
        };
        await _mount(tester, state);
        for (final source in [
          'Own edited signature',
          'Stored floor signature',
          'Profile markdown fallback',
          'Profile bio fallback',
        ]) {
          expect(
            find.byWidgetPredicate(
              (widget) => widget is InlineMarkdown && widget.text == source,
            ),
            source == expected ? findsOneWidget : findsNothing,
            reason: 'Signature source: $source',
          );
        }
        expect(native.named('reader.author'), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final source in ['own', 'floor', 'profile', 'bio']) {
    testWidgets('signature $source preserves its text source semantics', (
      tester,
    ) async {
      final native = _ContextNative()..replies = [];
      const raw = r'**Signature** &quot; &amp;quot; `&quot; <T>`';
      const dom = r'**Signature** \&quot; `&quot; <T>`';
      const bio = '**Signature** &quot; [literal](https://example.invalid/)';
      native.root = {...native.root, if (source == 'floor') 'signature': dom};
      native.authorProfile = {
        'member_id': _author,
        'member_name': _name,
        if (source == 'own') 'ownSignature': raw,
        if (source == 'profile') 'signature_markdown': raw,
        'bio': bio,
      };
      final state = await _prepare(tester, native);
      if (source == 'own') {
        state.domains['session'] = {
          ...state.domain('session'),
          'owner': _author,
        };
      }
      await _mount(tester, state);
      final expected = source == 'bio'
          ? bio
          : source == 'floor'
          ? 'Signature &quot; &quot; <T>'
          : 'Signature " &quot; &quot; <T>';
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == expected,
        ),
        findsOneWidget,
      );
      expect(native.named('external.open'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mounted signature changes from plain bio to Markdown to empty', (
    tester,
  ) async {
    final native = _ContextNative()..replies = [];
    const source = '**Shared** &quot;';
    native.authorProfile = {
      'member_id': _author,
      'member_name': _name,
      'bio': source,
    };
    final state = await _prepare(tester, native);
    await _mount(tester, state);
    final element = find.byType(ReaderFloorContext).evaluate().single;
    Finder text(String value) => find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == value,
    );
    expect(text(source), findsOneWidget);
    native.authorProfile = {
      ...native.authorProfile,
      'signature_markdown': source,
    };
    await state.act('reader.load', {'url': _url(), 'force': true});
    await _frames(tester);
    expect(text('Shared "'), findsOneWidget);
    expect(text(source), findsNothing);
    expect(find.byType(ReaderFloorContext).evaluate().single, same(element));
    state.domains['session'] = {...state.domain('session'), 'owner': _author};
    native.authorProfile = {...native.authorProfile, 'ownSignature': ''};
    await state.act('reader.load', {'url': _url(), 'force': true});
    await _frames(tester);
    expect(text('Shared "'), findsNothing);
    expect(text(source), findsNothing);
    expect(find.byType(ReaderFloorContext).evaluate().single, same(element));
    expect(native.named('external.open'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'avatar and author name open the same explicit profile destination',
    (tester) async {
      final native = _ContextNative()..replies = [];
      native.root = {...native.root, 'avatar': _avatar};
      final state = await _prepare(tester, native);
      await _mount(tester, state);
      final avatar = find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.byType(NativeAvatar),
      );
      expect(
        find.descendant(of: avatar, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(native.named('images.load').single.$2['kind'], 'avatar');
      expect(native.named('profile.load'), isEmpty);
      native.allowProfileScreen = true;
      final authorName = find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.text(_name),
      );
      for (final entry in [avatar, authorName]) {
        await tester.ensureVisible(entry);
        await _frames(tester);
        expect(entry.hitTestable(), findsOneWidget);
        await tester.tap(entry);
        await _frames(tester);
        expect(find.byType(AccountScreen), findsOneWidget);
        expect(
          tester.widget<AccountScreen>(find.byType(AccountScreen)).memberId,
          _author,
        );
        expect(native.named('profile.load').last.$2['id'], _author);
        Navigator.of(tester.element(find.byType(AccountScreen))).pop();
        await _frames(tester, 10);
        expect(find.byType(AccountScreen), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'author summary rejects unknown authors and late results from a retired account',
    (tester) async {
      final native = _ContextNative()..pendingAuthor = Completer<JsonMap>();
      final state = await _prepare(tester, native);
      expect(await state.readerAuthor(_url(), 999), isNull);
      expect(native.named('reader.author'), isEmpty);
      final old = state.readerAuthor(_url(), _author);
      expect(native.named('reader.author'), hasLength(1));
      native.snapshotEvents.add({
        'domain': 'session',
        'accessRevision': 1,
        'data': {'account': 'signedIn', 'owner': 99, 'accessRevision': 1},
      });
      expect(state.accessRevision, 1);
      native.pendingAuthor!.complete({
        'profile': {
          ...native.authorProfile,
          'signature_markdown': 'Retired account signature',
        },
        'accessRevision': 0,
      });
      expect(await old, isNull);
      expect(state.readerFor(_url()), isEmpty);
      expect(state.message, isNull);

      native.pendingAuthor = null;
      state.readers[_url()] = native.reader();
      final current = await state.readerAuthor(_url(), _author);
      expect(current?['member_id'], _author);
      expect(
        current?['signature_markdown'],
        'Signature from the lightweight author summary',
      );
      expect(native.named('reader.author'), hasLength(2));
      expect(native.named('reader.author').last.$2['accessRevision'], 1);
      expect(native.named('profile.load'), isEmpty);
    },
  );

  testWidgets(
    'floor signatures keep multiline text and activate only safe inline links',
    (tester) async {
      const signature =
          '**Signature**\nline two\nline three\nline four\n'
          '[external](https://example.com/info) [forum](/post-3701-3) '
          '[unsafe](javascript:alert) [file](file:///tmp/fixture) '
          '![image placeholder](https://example.com/signature.png)';
      final native = _ContextNative()..replies = [];
      native.root = {...native.root, 'signature': signature};
      final state = await _prepare(tester, native);
      await _mount(tester, state);
      final markdown = find.byWidgetPredicate(
        (widget) => widget is InlineMarkdown && widget.text == signature,
      );
      expect(markdown, findsOneWidget);
      final rich = tester.widget<RichText>(
        find.descendant(of: markdown, matching: find.byType(RichText)),
      );
      expect(rich.maxLines, isNull);
      expect(rich.text.toPlainText(), contains('line four'));
      final spans = _textSpans(rich.text);
      for (final unsafe in ['unsafe', 'file']) {
        expect(
          spans.singleWhere((span) => span.text == unsafe).recognizer,
          isNull,
        );
      }
      for (final safe in ['external', 'forum']) {
        final link = spans.singleWhere((span) => span.text == safe).recognizer;
        expect(link, isA<TapGestureRecognizer>());
        (link! as TapGestureRecognizer).onTap!();
        await _frames(tester);
      }
      expect(
        native.named('external.open').single.$2['url'],
        'https://example.com/info',
      );
      expect(native.named('reader.open').single.$2['url'], _url(3));
      expect(native.named('images.load'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (code, label, method) in [
    ('sign_in_required', '登录 NodeSeek', 'session.signIn'),
    ('verification_required', '打开验证窗口', 'session.verify'),
    ('network', '', ''),
  ]) {
    testWidgets(
      '$code failure preserves summary and exposes the matching recovery action',
      (tester) async {
        final native = _ContextNative();
        final state = await _prepare(tester, native);
        state.readers[_url()] = {
          'url': _url(),
          'loading': false,
          'error': 'Memory failure detail',
          'errorCode': code,
          'accessRevision': state.accessRevision,
        };
        await _mount(tester, state, width: 340, height: 650);
        expect(find.text(_summary, findRichText: true), findsOneWidget);
        expect(find.text('Memory failure detail'), findsOneWidget);
        if (method.isNotEmpty) {
          await tester.ensureVisible(_button(label));
          await _frames(tester);
          expect(_button(label).hitTestable(), findsOneWidget);
          await tester.tap(_button(label));
          await _frames(tester);
          expect(native.named(method), hasLength(1));
          if (method == 'session.verify') {
            expect(native.named(method).single.$2['url'], _url());
          }
        } else {
          expect(_button('登录 NodeSeek'), findsNothing);
          expect(_button('打开验证窗口'), findsNothing);
        }
        await tester.ensureVisible(_button('在浏览器查看原帖'));
        await _frames(tester);
        expect(_button('在浏览器查看原帖').hitTestable(), findsOneWidget);
        await tester.tap(_button('在浏览器查看原帖'));
        await _frames(tester);
        expect(native.named('external.open').single.$2['url'], _url());
        await tester.ensureVisible(_button('重试'));
        await _frames(tester);
        expect(_button('重试').hitTestable(), findsOneWidget);
        await tester.tap(_button('重试'));
        await _frames(tester);
        expect(native.named('reader.load').single.$2['force'], isTrue);
        expect(
          find.text('Original context body', findRichText: true),
          findsOneWidget,
        );
        expect(stringValue(state.readerFor(_url())['errorCode']), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'typed refresh failure preserves the existing reader and retained reply controller',
    (tester) async {
      final native = _ContextNative()..replies = [];
      final state = await _prepare(tester, native);
      await _mount(tester, state, workspace: true, width: 1380, height: 880);
      await tester.tap(_button('写回复'));
      await _frames(tester);
      await tester.enterText(_bodyField, 'Reply survives a refresh failure');
      final controller = tester
          .widget<CupertinoTextField>(_bodyField)
          .controller;
      native.failLoads = true;
      await state.loadReader(_url(), force: true);
      await _frames(tester);
      expect(state.readerFor(_url())['errorCode'], 'network');
      expect(
        find.text('Original context body', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(ReaderEditorAnchor), findsOneWidget);
      expect(
        tester.widget<CupertinoTextField>(_bodyField).controller,
        same(controller),
      );
      expect(controller!.text, 'Reply survives a refresh failure');
      await tester.ensureVisible(_button('放弃编辑'));
      await _frames(tester);
      expect(_button('放弃编辑').hitTestable(), findsOneWidget);
      expect(native.named('reader.replyDraft'), hasLength(1));
      expect(native.named('reader.sendReply'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
