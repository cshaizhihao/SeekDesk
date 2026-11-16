import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _InboxNative extends NativeClient {
  _InboxNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-continuity'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final drafts = <(int, int), String>{};
  final conversationBodies = <int, List<String>>{};
  final delayedReads = <String, Completer<JsonMap>>{};
  final outstanding = <Completer<JsonMap>>[];
  Completer<JsonMap>? saveGate;
  Completer<JsonMap>? sendGate;
  bool allowSend = false;

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  JsonMap snapshot(String kind, {int? peer, int? revision}) {
    final owner = revision ?? accessRevision;
    final bodies = kind != 'conversation'
        ? const <String>[]
        : conversationBodies[peer] ??
              [
                for (var index = 0; index < 50; index++)
                  _messageText(owner, peer!, index),
              ];
    return {
      'kind': kind,
      'peer': ?peer,
      'accessRevision': owner,
      'loading': false,
      'draft': peer == null ? '' : drafts[(owner, peer)] ?? '',
      'items': kind == 'conversation'
          ? [
              for (final body in bodies)
                {
                  'text': body,
                  'markdown': false,
                  'mine': false,
                  'peerName': 'Peer $peer',
                  'date': '2026-11-15 12:00',
                },
            ]
          : [
              for (var index = 0; index < 60; index++)
                {
                  'id': 20 + index,
                  'name': 'Peer ${20 + index}',
                  'author': '$kind author $index',
                  'title': 'Account $owner $kind notice $index',
                  'preview': 'Account $owner conversation ${20 + index}',
                  'avatar': '',
                  'unread': false,
                  'date': '2026-11-15',
                },
            ],
    };
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final revision = accessRevision;
    calls.add((method, {...arguments, 'accessRevision': revision}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 101,
            'accessRevision': revision,
            'unread': <String, int>{},
          },
        };
      case 'images.draftReferences':
        final content = arguments['content'];
        // These continuity fixtures contain no images. Permit only the local
        // reference query, rejecting malformed input or future image fixtures.
        if (arguments.length != 1 ||
            content is! String ||
            RegExp(r'!\[|<img\b', caseSensitive: false).hasMatch(content)) {
          break;
        }
        return {
          'content': content,
          'imageURLs': <String>[],
          'accessRevision': revision,
        };
      case 'inbox.load':
        final kind = stringValue(arguments['kind']);
        final peer = arguments['peer'] as int?;
        if (!const [
              'mentions',
              'replies',
              'messages',
              'conversation',
            ].contains(kind) ||
            (kind == 'conversation' && (peer == null || peer <= 0))) {
          break;
        }
        final key = '$kind:${peer ?? ''}';
        final gate = delayedReads.remove(key);
        if (gate != null) {
          outstanding.add(gate);
          return gate.future;
        }
        return snapshot(kind, peer: peer, revision: revision);
      case 'inbox.updateDraft':
        final peer = arguments['peer'] as int?;
        if (peer == null || peer <= 0 || arguments['content'] is! String) break;
        final gate = saveGate;
        saveGate = null;
        if (gate != null) {
          outstanding.add(gate);
          await gate.future;
        }
        drafts[(revision, peer)] = arguments['content'] as String;
        return {'content': arguments['content'], 'accessRevision': revision};
      case 'inbox.send':
        if (!allowSend) break;
        final gate = sendGate;
        sendGate = null;
        if (gate != null) {
          outstanding.add(gate);
          final result = await gate.future;
          if (result['kind'] == 'sent' && arguments['peer'] is int) {
            drafts[(revision, arguments['peer'] as int)] = '';
          }
          return result;
        }
        return {'kind': 'unknown', 'accessRevision': revision};
    }
    unexpected.add('$method $arguments');
    throw StateError('Unexpected inbox fixture request: $method $arguments');
  }

  void changeAccount() {
    final next = accessRevision + 1;
    eventStream.add({
      'domain': 'session',
      'accessRevision': next,
      'data': {
        'account': 'signedIn',
        'owner': 202,
        'accessRevision': next,
        'unread': <String, int>{},
      },
    });
  }
}

class _InboxHost extends StatefulWidget {
  const _InboxHost({required this.state, this.peer, this.standalone = false});
  final AppState state;
  final int? peer;
  final bool standalone;
  @override
  State<_InboxHost> createState() => _InboxHostState();
}

class _InboxHostState extends State<_InboxHost> {
  bool visible = true;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    child: Column(
      children: [
        CupertinoButton(
          onPressed: () => setState(() => visible = !visible),
          child: Text(visible ? 'Leave inbox fixture' : 'Return inbox fixture'),
        ),
        Expanded(
          child: visible
              ? InboxScreen(
                  state: widget.state,
                  initialPeer: widget.peer,
                  peerName: widget.peer == null ? '' : 'Peer ${widget.peer}',
                  standalone: widget.standalone,
                )
              : const Center(child: Text('Another workspace destination')),
        ),
      ],
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

String _messageText(int revision, int peer, int index) =>
    'Account $revision peer $peer message $index\nLocal message body for scrolling.';

Finder get _composerBody => find.byKey(const ValueKey('inbox-composer-body'));
Finder get _composerEditable =>
    find.descendant(of: _composerBody, matching: find.byType(EditableText));
bool _bodyEditable(WidgetTester tester) {
  final field = tester.widget<CupertinoTextField>(_composerBody);
  return field.enabled != false && !field.readOnly;
}

Finder get _categorySurface =>
    find.byKey(const ValueKey('inbox-category-surface'));
Finder get _conversationSurface =>
    find.byKey(const ValueKey('inbox-conversation-surface'));
Finder get _categoryList =>
    find.descendant(of: _categorySurface, matching: find.byType(ListView));
Finder get _conversationList =>
    find.descendant(of: _conversationSurface, matching: find.byType(ListView));
Finder get _list =>
    _conversationList.evaluate().isNotEmpty ? _conversationList : _categoryList;
ScrollController _scroll(WidgetTester tester) =>
    tester.widget<ListView>(_list).controller!;
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);

Future<void> _tapSend(WidgetTester tester) async {
  final send = find.byKey(const ValueKey('inbox-composer-send'));
  await tester.pump();
  // The compact editor scrolls its toolbar, body and footer together. Reach
  // the actual button without advancing the autosave timer before the click.
  await tester.ensureVisible(send);
  await tester.pump();
  expect(send.hitTestable(), findsOneWidget);
  await tester.tap(send);
}

bool _messageIsVisible(WidgetTester tester, String text) {
  if (_list.evaluate().length != 1) return false;
  final message = find.text(text).hitTestable();
  if (message.evaluate().length != 1) return false;
  final viewport = tester.getRect(_list);
  final bounds = tester.getRect(message);
  return bounds.top >= viewport.top - 1 &&
      bounds.bottom <= viewport.bottom + 1 &&
      bounds.left < viewport.right &&
      bounds.right > viewport.left;
}

Future<void> _waitForLastMessage(WidgetTester tester, String text) async {
  var stableFrames = 0;
  double? previousEnd;
  for (var frame = 0; frame < 32; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (_list.evaluate().length != 1 || !_scroll(tester).hasClients) continue;
    final position = _scroll(tester).position;
    final atEnd = (position.pixels - position.maxScrollExtent).abs() <= 1;
    final stableEnd =
        previousEnd != null &&
        (position.maxScrollExtent - previousEnd).abs() <= 1;
    stableFrames = _messageIsVisible(tester, text) && atEnd && stableEnd
        ? stableFrames + 1
        : 0;
    previousEnd = position.maxScrollExtent;
    if (stableFrames >= 2) return;
  }
  expect(
    _messageIsVisible(tester, text),
    isTrue,
    reason: 'The final message must be visible and interactive after bounded layout.',
  );
  expect(_scroll(tester).position.extentAfter, lessThanOrEqualTo(1));
  expect(stableFrames, greaterThanOrEqualTo(2));
}

Future<double> _wheel(WidgetTester tester, double delta) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(_list),
      scrollDelta: Offset(0, delta),
      kind: PointerDeviceKind.mouse,
    ),
  );
  await _frames(tester);
  return _scroll(tester).offset;
}

Future<void> _category(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await _frames(tester);
}

Future<AppState> _mount(
  WidgetTester tester,
  _InboxNative native, {
  int? peer,
  bool standalone = false,
  double width = 1100,
  void Function(AppState)? prepare,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 850));
  final state = AppState(client: native);
  await state.connect();
  prepare?.call(state);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final gate in native.outstanding) {
      if (!gate.isCompleted) gate.complete({});
    }
    await tester.pump();
    state.dispose();
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: _InboxHost(state: state, peer: peer, standalone: standalone),
      ),
    ),
  );
  await _frames(tester);
  return state;
}

Future<void> _openPeer(WidgetTester tester, int peer) async {
  await tester.tap(
    find.descendant(of: _categorySurface, matching: find.text('Peer $peer')),
  );
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'each category retains its actual wheel position across switches',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      final mentions = await _wheel(tester, 425);
      expect(mentions, greaterThan(100));
      await _category(tester, '回复主题');
      final replies = await _wheel(tester, 280);
      await _category(tester, '私信');
      final messages = await _wheel(tester, 510);
      await _category(tester, '@我');
      expect(_scroll(tester).offset, closeTo(mentions, 1));
      await _category(tester, '回复主题');
      expect(_scroll(tester).offset, closeTo(replies, 1));
      await _category(tester, '私信');
      expect(_scroll(tester).offset, closeTo(messages, 1));
      expect(state.inboxNavigation.category, 2);
      expect(
        native.named('inbox.load').every((call) => call.$2['force'] != true),
        isTrue,
      );
      expect(native.named('inbox.markRead'), isEmpty);
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'new conversations start at bottom and revisits retain each position',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await _waitForLastMessage(tester, _messageText(0, 20, 49));
      expect(
        _scroll(tester).offset,
        closeTo(_scroll(tester).position.maxScrollExtent, 1),
      );
      final first = await _wheel(tester, -350);
      expect(first, lessThan(_scroll(tester).position.maxScrollExtent - 100));
      expect(tester.widget<ListView>(_categoryList).controller!.offset, 0);
      await _openPeer(tester, 21);
      await _waitForLastMessage(tester, _messageText(0, 21, 49));
      expect(
        _scroll(tester).offset,
        closeTo(_scroll(tester).position.maxScrollExtent, 1),
      );
      final second = await _wheel(tester, -650);
      await _openPeer(tester, 20);
      expect(_scroll(tester).offset, closeTo(first, 1));
      expect(
        state.inboxNavigation.offset(
          'conversation:21',
          revision: state.accessRevision,
        ),
        closeTo(second, 1),
      );
      await tester.tap(_icon('刷新通知'));
      await _frames(tester);
      expect(_scroll(tester).offset, closeTo(first, 1));
      expect(native.named('inbox.load').last.$2, containsPair('force', true));
    },
  );

  testWidgets(
    'an explicitly remembered zero remains at the start of a long conversation',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(
        tester,
        native,
        prepare: (state) {
          final revision = state.accessRevision;
          state.inboxNavigation.select(
            revision: revision,
            category: 2,
            peer: 20,
            peerName: 'Peer 20',
          );
          state.inboxNavigation.remember(
            'conversation:20',
            0,
            revision: revision,
          );
        },
      );
      await _frames(tester);
      expect(_scroll(tester).offset, 0);
      expect(_scroll(tester).position.maxScrollExtent, greaterThan(1000));
      expect(_messageIsVisible(tester, _messageText(0, 20, 0)), isTrue);
      expect(_messageIsVisible(tester, _messageText(0, 20, 49)), isFalse);
      expect(state.inboxNavigation.offset('conversation:20', revision: 0), 0);
    },
  );

  testWidgets(
    'short new conversations show both messages at the top without scrolling',
    (tester) async {
      final native = _InboxNative();
      native.conversationBodies[20] = [
        'Short first message',
        'Short last message',
      ];
      await _mount(tester, native, peer: 20);
      await _waitForLastMessage(tester, 'Short last message');
      expect(_scroll(tester).offset, 0);
      expect(_scroll(tester).position.maxScrollExtent, 0);
      expect(_messageIsVisible(tester, 'Short first message'), isTrue);
      final first = tester.getRect(find.text('Short first message'));
      final viewport = tester.getRect(_list);
      expect(first.top - viewport.top, lessThan(viewport.height / 3));
    },
  );

  testWidgets(
    'first entry reaches the actual last message through variable row heights',
    (tester) async {
      final native = _InboxNative();
      native.conversationBodies[20] = [
        for (var index = 0; index < 47; index++)
          'Variable message $index\n${List.filled(1 + index % 9, 'A distinct local line with enough content to wrap on narrower reading widths.').join('\n')}',
        'The actual final message',
      ];
      await _mount(tester, native, peer: 20);
      await _waitForLastMessage(tester, 'The actual final message');
      expect(_scroll(tester).position.maxScrollExtent, greaterThan(3000));
      expect(_messageIsVisible(tester, 'The actual final message'), isTrue);
    },
  );

  testWidgets(
    'wheel input interrupts pending end-follow after new and taller messages',
    (tester) async {
      final native = _InboxNative();
      await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await _waitForLastMessage(tester, _messageText(0, 20, 49));
      native.conversationBodies[20] = [
        for (var index = 0; index < 49; index++) _messageText(0, 20, index),
        'A message that grew\n${List.filled(14, 'Additional locally received line.').join('\n')}',
        'An appended message while already at the end',
      ];
      native.eventStream.add({
        'domain': 'inbox',
        'accessRevision': 0,
        'data': native.snapshot('conversation', peer: 20, revision: 0),
      });
      // One frame starts end-follow and lays out the taller tail; interrupt
      // before any subsequent stabilization callback can win over the wheel.
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(_list),
          scrollDelta: const Offset(0, -600),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      final chosenPosition = _scroll(tester).offset;
      expect(_scroll(tester).position.extentAfter, greaterThan(100));
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_scroll(tester).offset, closeTo(chosenPosition, 1));
      expect(_scroll(tester).position.extentAfter, greaterThan(100));
      expect(
        _messageIsVisible(
          tester,
          'An appended message while already at the end',
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'leaving and remounting restores peer, scroll and the authoritative draft',
    (tester) async {
      final native = _InboxNative();
      native.drafts[(0, 20)] = 'Stored peer draft';
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      final position = await _wheel(tester, -420);
      await tester.enterText(_composerBody, 'Last edit before leaving');
      await tester.tap(find.text('Leave inbox fixture'));
      await _frames(tester);
      expect(find.byType(InboxScreen), findsNothing);
      expect(native.drafts[(0, 20)], 'Last edit before leaving');
      expect(state.inboxNavigation.peer, 20);
      await tester.tap(find.text('Return inbox fixture'));
      await _frames(tester);
      expect(find.text('Peer 20'), findsWidgets);
      expect(_scroll(tester).offset, closeTo(position, 1));
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        'Last edit before leaving',
      );
      expect(native.named('inbox.load').last.$2, containsPair('peer', 20));
      expect(native.named('inbox.load').last.$2['force'], isNot(true));
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'an outer page removal retains a failed draft for reopening and quit retries',
    (tester) async {
      final native = _InboxNative();
      native.drafts[(0, 20)] = 'Previously saved text';
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      const latest = 'Last private text before leaving the whole inbox';
      await tester.enterText(_composerBody, latest);
      final departingSave = Completer<JsonMap>();
      native.saveGate = departingSave;
      await tester.tap(find.text('Leave inbox fixture'));
      await _frames(tester);
      expect(find.byType(InboxScreen), findsNothing);
      expect(native.named('inbox.updateDraft'), hasLength(1));
      departingSave.completeError(
        const NativeFailure('disk', 'Closed-page save failed'),
      );
      await _frames(tester);
      expect(native.drafts[(0, 20)], 'Previously saved text');
      expect(state.inboxDrafts.read(revision: 0, peer: 20)!.content, latest);
      expect(state.inboxDrafts.read(revision: 0, peer: 20)!.dirty, isTrue);
      expect(state.message, contains('私信草稿保存失败'));

      final quitSave = Completer<JsonMap>();
      native.saveGate = quitSave;
      final quit = state.flushDrafts();
      await tester.pump();
      expect(native.named('inbox.updateDraft'), hasLength(2));
      quitSave.completeError(
        const NativeFailure('disk', 'Quit retry still failed'),
      );
      expect(await quit, isFalse);
      await tester.tap(find.text('Return inbox fixture'));
      await _frames(tester);
      final field = tester.widget<CupertinoTextField>(_composerBody);
      expect(field.enabled != false && !field.readOnly, isTrue);
      expect(field.controller!.text, latest);
      expect(state.inboxDrafts.read(revision: 0, peer: 20)!.dirty, isTrue);
      expect(find.text('这份私信草稿尚未保存，文字已恢复。请重试保存后再发送或关闭。'), findsOneWidget);
      await tester.tap(_button('重试保存'));
      await _frames(tester);
      expect(find.text('私信草稿已保存'), findsOneWidget);
      expect(await state.flushDrafts(), isTrue);
      expect(native.drafts[(0, 20)], latest);
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'wide and narrow transitions preserve the live editor selection and composition',
    (tester) async {
      final native = _InboxNative();
      await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await _waitForLastMessage(tester, _messageText(0, 20, 49));
      await tester.enterText(_composerBody, 'Keep this composing draft');
      final field = tester.widget<CupertinoTextField>(_composerBody);
      final controller = field.controller!;
      controller.value = const TextEditingValue(
        text: 'Keep this composing draft',
        selection: TextSelection(baseOffset: 5, extentOffset: 9),
        composing: TextRange(start: 5, end: 9),
      );
      final value = controller.value;
      final editableState = tester.state(_composerEditable);
      final focus = tester.widget<EditableText>(_composerEditable).focusNode;
      final scroll = _scroll(tester);
      final reads = native.named('inbox.load').length;
      expect(focus.hasFocus, isTrue);
      for (final width in [650.0, 1100.0, 500.0, 1100.0]) {
        await tester.binding.setSurfaceSize(Size(width, 850));
        await _frames(tester);
        final current = tester.widget<CupertinoTextField>(_composerBody);
        expect(current.controller, same(controller));
        expect(current.controller!.value, value);
        expect(tester.state(_composerEditable), same(editableState));
        expect(
          tester.widget<EditableText>(_composerEditable).focusNode,
          same(focus),
        );
        expect(focus.hasFocus, isTrue);
        expect(_scroll(tester), same(scroll));
        expect(native.named('inbox.load'), hasLength(reads));
        expect(_button('返回私信列表'), width < 760 ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
      }
      expect(native.drafts[(0, 20)], value.text);
    },
  );

  testWidgets(
    'narrow conversation back restores its list without losing the peer position',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native, width: 650);
      await _category(tester, '私信');
      final listScroll = _scroll(tester);
      await _openPeer(tester, 20);
      await _waitForLastMessage(tester, _messageText(0, 20, 49));
      final position = await _wheel(tester, -360);
      expect(_categoryList, findsNothing);
      await tester.tap(_button('返回私信列表'));
      await _frames(tester);
      expect(state.inboxNavigation.peer, isNull);
      expect(_scroll(tester), same(listScroll));
      expect(_scroll(tester).offset, 0);
      await _openPeer(tester, 20);
      expect(_scroll(tester).offset, closeTo(position, 1));
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'leaving a clean peer for another category releases its draft owner',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await tester.enterText(_composerBody, 'Save before changing category');
      await _category(tester, '回复主题');
      expect(native.drafts[(0, 20)], 'Save before changing category');
      expect(state.inboxDrafts.read(revision: 0, peer: 20), isNull);
      expect(_composerBody, findsNothing);
    },
  );

  testWidgets(
    'late category replies cannot switch the visible route or scroll',
    (tester) async {
      final native = _InboxNative();
      final delayed = Completer<JsonMap>();
      native.delayedReads['mentions:'] = delayed;
      final state = await _mount(tester, native);
      await _category(tester, '回复主题');
      final position = await _wheel(tester, 330);
      delayed.complete(native.snapshot('mentions'));
      await _frames(tester);
      expect(state.inboxNavigation.category, 1);
      expect(_scroll(tester).offset, closeTo(position, 1));
      expect(find.textContaining('replies notice'), findsWidgets);
      expect(find.textContaining('mentions notice'), findsNothing);
    },
  );

  for (final cancelled in [false, true]) {
    testWidgets(
      'A to B to A recovers when the first A ${cancelled ? 'is cancelled' : 'succeeds'}',
      (tester) async {
        final native = _InboxNative();
        final firstA = Completer<JsonMap>();
        final lateB = Completer<JsonMap>();
        native.delayedReads['mentions:'] = firstA;
        native.delayedReads['replies:'] = lateB;
        final state = await _mount(tester, native);
        await _category(tester, '回复主题');
        await _category(tester, '@我');
        expect(state.inboxNavigation.category, 0);
        if (cancelled) {
          firstA.completeError(
            const NativeFailure('cancelled', 'Superseded fixture selection'),
          );
        } else {
          firstA.complete(native.snapshot('mentions'));
        }
        await _frames(tester);
        expect(state.inboxNavigation.category, 0);
        expect(find.textContaining('mentions notice'), findsWidgets);
        expect(_scroll(tester).hasClients, isTrue);
        final position = await _wheel(tester, 290);
        lateB.complete(native.snapshot('replies'));
        await _frames(tester);
        expect(state.inboxNavigation.category, 0);
        expect(find.textContaining('mentions notice'), findsWidgets);
        expect(find.textContaining('replies notice'), findsNothing);
        expect(_scroll(tester).offset, closeTo(position, 1));
        final aCalls = native
            .named('inbox.load')
            .where((call) => call.$2['kind'] == 'mentions');
        expect(aCalls, hasLength(cancelled ? 2 : 1));
        expect(
          native.named('inbox.load').every((call) => call.$2['force'] != true),
          isTrue,
        );
        expect(state.message, isNull);
      },
    );
  }

  testWidgets(
    'remounting an in-flight category recovers a cancelled shared request',
    (tester) async {
      final native = _InboxNative();
      final initial = Completer<JsonMap>();
      native.delayedReads['mentions:'] = initial;
      final state = await _mount(tester, native);
      await tester.tap(find.text('Leave inbox fixture'));
      await _frames(tester);
      expect(find.byType(InboxScreen), findsNothing);
      await tester.tap(find.text('Return inbox fixture'));
      await _frames(tester);
      expect(native.named('inbox.load'), hasLength(1));
      initial.completeError(
        const NativeFailure('cancelled', 'Retired fixture load'),
      );
      await _frames(tester);
      expect(find.textContaining('mentions notice'), findsWidgets);
      expect(state.inboxNavigation.category, 0);
      expect(native.named('inbox.load'), hasLength(2));
      expect(
        native.named('inbox.load').every((call) => call.$2['force'] != true),
        isTrue,
      );
      expect(state.message, isNull);
    },
  );

  testWidgets(
    'only the latest category click runs after an asynchronous draft flush',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await tester.enterText(_composerBody, 'Keep peer 20 edit');
      final saved = Completer<JsonMap>();
      native.saveGate = saved;
      final readsBefore = native.named('inbox.load').length;
      await _category(tester, '回复主题');
      await _category(tester, '@我');
      expect(native.named('inbox.load'), hasLength(readsBefore));
      expect(state.inboxNavigation.peer, 20);
      saved.complete({});
      await _frames(tester);
      expect(state.inboxNavigation.category, 0);
      expect(state.inboxNavigation.peer, isNull);
      expect(
        native
            .named('inbox.load')
            .skip(readsBefore)
            .map((call) => call.$2['kind']),
        ['mentions'],
      );
      expect(native.drafts[(0, 20)], 'Keep peer 20 edit');
      expect(native.named('inbox.updateDraft'), hasLength(1));
    },
  );

  testWidgets(
    'failed navigation flush keeps the conversation and editable draft',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await tester.enterText(_composerBody, 'Do not discard this edit');
      final saved = Completer<JsonMap>();
      native.saveGate = saved;
      final readsBefore = native.named('inbox.load').length;
      await _category(tester, '回复主题');
      saved.completeError(
        const NativeFailure('disk', 'Fixture draft save failed'),
      );
      await _frames(tester);
      expect(state.inboxNavigation.peer, 20);
      expect(native.named('inbox.load'), hasLength(readsBefore));
      final field = tester.widget<CupertinoTextField>(_composerBody);
      expect(field.enabled != false && !field.readOnly, isTrue);
      expect(field.controller!.text, 'Do not discard this edit');
      await _category(tester, '回复主题');
      expect(state.inboxNavigation.category, 1);
      expect(native.drafts[(0, 20)], 'Do not discard this edit');
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'a forced refresh queued behind an ordinary read keeps its force intent',
    (tester) async {
      final native = _InboxNative();
      final ordinary = Completer<JsonMap>();
      final forced = Completer<JsonMap>();
      native.delayedReads['mentions:'] = ordinary;
      final state = await _mount(tester, native);
      native.delayedReads['mentions:'] = forced;
      await tester.tap(_icon('刷新通知'));
      await _frames(tester);
      expect(native.named('inbox.load'), hasLength(1));
      expect(native.named('inbox.load').single.$2['force'], isNot(true));
      ordinary.complete(native.snapshot('mentions', revision: 0));
      await _frames(tester);
      expect(native.named('inbox.load'), hasLength(2));
      expect(native.named('inbox.load').last.$2['force'], isTrue);
      final fresh = native.snapshot('mentions', revision: 0);
      fresh['items'] = [
        for (final item in jsonItems(fresh['items']))
          {...item, 'title': 'Fresh forced notice ${item['id']}'},
      ];
      forced.complete(fresh);
      await _frames(tester);
      expect(state.inboxNavigation.category, 0);
      expect(find.textContaining('Fresh forced notice'), findsWidgets);
      expect(find.textContaining('Account 0 mentions notice'), findsNothing);
      expect(native.named('inbox.load'), hasLength(2));
    },
  );

  testWidgets(
    'a pending old-account category is not reused by the new account',
    (tester) async {
      final native = _InboxNative();
      final retired = Completer<JsonMap>();
      native.delayedReads['mentions:'] = retired;
      final oldSnapshot = native.snapshot('mentions', revision: 0);
      final state = await _mount(tester, native);
      native.changeAccount();
      await _frames(tester);
      retired.complete(oldSnapshot);
      await _frames(tester);
      expect(state.accessRevision, 1);
      expect(state.inboxNavigation.category, 0);
      expect(find.textContaining('Account 1 mentions notice'), findsWidgets);
      expect(find.textContaining('Account 0'), findsNothing);
      expect(
        native.named('inbox.load').map((call) => call.$2['accessRevision']),
        [0, 1],
      );
      expect(state.domain('inbox')['accessRevision'], 1);
      expect(state.message, isNull);
    },
  );

  testWidgets(
    'late old-account private reads cannot restore peer data or positions',
    (tester) async {
      final native = _InboxNative();
      native.drafts[(0, 20)] = 'Old account private draft';
      final oldSnapshot = native.snapshot(
        'conversation',
        peer: 20,
        revision: 0,
      );
      final retired = Completer<JsonMap>();
      native.delayedReads['conversation:20'] = retired;
      final state = await _mount(
        tester,
        native,
        prepare: (state) {
          state.inboxNavigation.select(
            revision: 0,
            category: 2,
            peer: 20,
            peerName: 'Old private peer',
          );
          state.inboxNavigation.remember('conversation:20', 390, revision: 0);
        },
      );
      native.changeAccount();
      await _frames(tester);
      final newPosition = await _wheel(tester, 260);
      retired.complete(oldSnapshot);
      await _frames(tester);
      expect(state.inboxNavigation.category, 0);
      expect(state.inboxNavigation.peer, isNull);
      expect(state.inboxNavigation.peerName, isEmpty);
      expect(
        state.inboxNavigation.offset('conversation:20', revision: 1),
        isNull,
      );
      expect(_scroll(tester).offset, closeTo(newPosition, 1));
      expect(find.textContaining('Account 0'), findsNothing);
      expect(find.text('Old private peer'), findsNothing);
      expect(find.text('Old account private draft'), findsNothing);
      expect(find.textContaining('Account 1 mentions notice'), findsWidgets);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await _waitForLastMessage(tester, _messageText(1, 20, 49));
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        isEmpty,
      );
      expect(native.named('inbox.load').last.$2['accessRevision'], 1);
    },
  );

  testWidgets(
    'account change retires pending navigation and old private positions',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await _wheel(tester, -380);
      await tester.enterText(_composerBody, 'Old account local edit');
      final saved = Completer<JsonMap>();
      native.saveGate = saved;
      await _category(tester, '回复主题');
      native.changeAccount();
      await _frames(tester);
      expect(state.inboxNavigation.category, 0);
      expect(state.inboxNavigation.peer, isNull);
      expect(state.inboxNavigation.peerName, isEmpty);
      expect(
        state.inboxNavigation.offset(
          'conversation:20',
          revision: state.accessRevision,
        ),
        isNull,
      );
      saved.complete({});
      await _frames(tester);
      expect(state.inboxNavigation.category, 0);
      expect(find.text('Old account local edit'), findsNothing);
      expect(
        native
            .named('inbox.load')
            .where(
              (call) =>
                  call.$2['accessRevision'] == 1 &&
                  (call.$2['kind'] == 'replies' || call.$2['peer'] == 20),
            ),
        isEmpty,
      );
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'a shared edit during the send flush cancels the original send intent',
    (tester) async {
      final native = _InboxNative()..allowSend = true;
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      final otherView = Object();
      state.inboxDrafts.acquire(
        otherView,
        revision: 0,
        peer: 20,
        nativeContent: 'Stale native text',
      );
      addTearDown(() => state.inboxDrafts.release(otherView));
      await tester.enterText(_composerBody, 'Text chosen for send');
      final save = Completer<JsonMap>();
      native.saveGate = save;
      await _tapSend(tester);
      await _frames(tester);
      expect(native.named('inbox.send'), isEmpty);
      state.inboxDrafts.edit(otherView, 'Newer edit from the other window');
      save.complete({});
      await _frames(tester);
      expect(native.named('inbox.send'), isEmpty);
      expect(native.drafts[(0, 20)], 'Newer edit from the other window');
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        'Newer edit from the other window',
      );
      expect(_bodyEditable(tester), isTrue);
      expect(find.text('草稿已在其他窗口更新，请检查内容后再发送。'), findsOneWidget);
    },
  );

  testWidgets(
    'a confirmed send after outer unmount still clears the remaining shared owner',
    (tester) async {
      final native = _InboxNative()..allowSend = true;
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      final otherView = Object();
      state.inboxDrafts.acquire(
        otherView,
        revision: 0,
        peer: 20,
        nativeContent: 'Ignored native text',
      );
      addTearDown(() => state.inboxDrafts.release(otherView));
      await tester.enterText(_composerBody, 'Send once and clear both views');
      final sent = Completer<JsonMap>();
      native.sendGate = sent;
      await _tapSend(tester);
      await _frames(tester);
      expect(native.named('inbox.send'), hasLength(1));
      await tester.tap(find.text('Leave inbox fixture'));
      await _frames(tester);
      sent.complete({'kind': 'sent', 'accessRevision': 0});
      await _frames(tester);
      expect(find.byType(InboxScreen), findsNothing);
      final shared = state.inboxDrafts.read(revision: 0, peer: 20)!;
      expect(shared.content, isEmpty);
      expect(shared.dirty, isFalse);
      expect(native.drafts[(0, 20)], isEmpty);
      expect(native.named('inbox.send'), hasLength(1));
      await tester.tap(find.text('Return inbox fixture'));
      await _frames(tester);
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'send completion preserves and persists a newer shared draft from another view',
    (tester) async {
      final native = _InboxNative()..allowSend = true;
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      final otherView = Object();
      state.inboxDrafts.acquire(
        otherView,
        revision: 0,
        peer: 20,
        nativeContent: 'Ignored native text',
      );
      addTearDown(() => state.inboxDrafts.release(otherView));
      await tester.enterText(_composerBody, 'Original sent text');
      final sent = Completer<JsonMap>();
      native.sendGate = sent;
      await _tapSend(tester);
      await _frames(tester);
      state.inboxDrafts.edit(otherView, 'Next message composed elsewhere');
      expect(await state.inboxDrafts.flush(revision: 0, peer: 20), isTrue);
      expect(native.drafts[(0, 20)], 'Next message composed elsewhere');
      sent.complete({'kind': 'sent', 'accessRevision': 0});
      await _frames(tester);
      expect(native.named('inbox.send'), hasLength(1));
      expect(native.drafts[(0, 20)], 'Next message composed elsewhere');
      expect(state.inboxDrafts.read(revision: 0, peer: 20)!.dirty, isFalse);
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        'Next message composed elsewhere',
      );
      expect(_bodyEditable(tester), isTrue);
    },
  );

  testWidgets(
    'account change while preparing a send never sends the retired draft',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await tester.enterText(_composerBody, 'Retired account send intent');
      final saved = Completer<JsonMap>();
      native.saveGate = saved;
      await _tapSend(tester);
      await _frames(tester);
      expect(native.named('inbox.updateDraft'), hasLength(1));
      native.changeAccount();
      await _frames(tester);
      saved.complete({});
      await _frames(tester);
      expect(native.named('inbox.send'), isEmpty);
      expect(state.inboxNavigation.category, 0);
      expect(state.inboxNavigation.peer, isNull);
      expect(find.text('Retired account send intent'), findsNothing);
      expect(find.text('私信已发送'), findsNothing);
    },
  );

  testWidgets(
    'standalone peer routes leave the workspace navigation memory unchanged',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(
        tester,
        native,
        peer: 30,
        standalone: true,
        prepare: (state) {
          state.inboxNavigation.select(
            revision: state.accessRevision,
            category: 1,
          );
          state.inboxNavigation.remember(
            'replies:',
            318,
            revision: state.accessRevision,
          );
        },
      );
      await _wheel(tester, -300);
      await tester.enterText(_composerBody, 'Standalone peer 30 edit');
      expect(await state.flushDrafts(), isTrue);
      expect(native.drafts[(0, 30)], 'Standalone peer 30 edit');
      expect(state.inboxNavigation.category, 1);
      expect(state.inboxNavigation.peer, isNull);
      expect(
        state.inboxNavigation.offset(
          'replies:',
          revision: state.accessRevision,
        ),
        318,
      );
      expect(
        state.inboxNavigation.offset(
          'conversation:30',
          revision: state.accessRevision,
        ),
        isNull,
      );
      expect(native.named('inbox.send'), isEmpty);
    },
  );

  testWidgets(
    'navigation waits for edits typed while the previous draft save is pending',
    (tester) async {
      final native = _InboxNative();
      final state = await _mount(tester, native);
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      await tester.enterText(_composerBody, 'Pending navigation draft');
      final previousSave = Completer<JsonMap>();
      native.saveGate = previousSave;
      final readsBefore = native.named('inbox.load').length;
      await _category(tester, '回复主题');
      expect(native.named('inbox.updateDraft'), hasLength(1));
      expect(state.inboxNavigation.peer, 20);

      const latestText = 'Pending navigation draft with the final keystrokes';
      await tester.enterText(_composerBody, latestText);
      final latestSave = Completer<JsonMap>();
      native.saveGate = latestSave;
      previousSave.complete({});
      // Flush completion microtasks without advancing the 300 ms autosave
      // timer: navigation itself must notice and save these final edits.
      await tester.pump();
      await tester.pump();
      expect(native.drafts[(0, 20)], 'Pending navigation draft');
      expect(native.named('inbox.updateDraft'), hasLength(2));
      expect(native.named('inbox.updateDraft').last.$2['content'], latestText);
      expect(native.named('inbox.load'), hasLength(readsBefore));
      expect(state.inboxNavigation.peer, 20);
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        latestText,
      );

      latestSave.complete({});
      await _frames(tester);
      expect(native.drafts[(0, 20)], latestText);
      expect(state.inboxNavigation.category, 1);
      expect(state.inboxNavigation.peer, isNull);
      expect(native.named('inbox.load'), hasLength(readsBefore + 1));
      expect(native.named('inbox.load').last.$2['kind'], 'replies');
      await _category(tester, '私信');
      await _openPeer(tester, 20);
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        latestText,
      );
      expect(native.named('inbox.updateDraft'), hasLength(2));
      expect(native.named('inbox.send'), isEmpty);
    },
  );
}
