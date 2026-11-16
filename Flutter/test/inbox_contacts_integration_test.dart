import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

JsonMap _contact(int id, String name) => {
  'id': id,
  'name': name,
  'preview': 'Local conversation with $name',
  'date': '2026-11-15',
  'avatar': '',
  'unread': false,
};

/// Full AppState/bootstrap integration, with an explicit local request list.
/// Default tests can only read inbox/profile/avatar fixtures and parse local
/// draft references. One opt-in test permits draft persistence plus a mock
/// unconfirmed send, never forum I/O.
class _ContactsNative extends NativeClient {
  _ContactsNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-contacts'));

  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final conversationGates = <int, Completer<JsonMap>>{};
  final pending = <Completer<JsonMap>>[];
  final failedConversations = <int>{};
  final drafts = <(int, int), String>{};
  final draftModes = <(int, int), bool>{};
  bool allowDraftWrite = false, allowSend = false, failSave = false;
  bool emptyRecent = false, emptyOlder = false;

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  JsonMap session(int revision) => {
    'account': 'signedIn',
    'owner': revision == 0 ? 101 : 202,
    'accessRevision': revision,
    'unread': {'mentions': 0, 'replies': 0, 'messages': 0},
  };

  JsonMap snapshot(String kind, {int? peer, int? revision}) {
    final access = revision ?? accessRevision;
    return {
      'kind': kind,
      'peer': ?peer,
      'accessRevision': access,
      'loading': false,
      'error': peer != null && failedConversations.contains(peer)
          ? 'Local conversation read failed.'
          : null,
      'draft': peer == null ? '' : drafts[(access, peer)] ?? '',
      'draftMarkdown': peer == null ? true : draftModes[(access, peer)] ?? true,
      'items': kind == 'conversation'
          ? <JsonMap>[]
          : kind != 'messages' || emptyRecent
          ? <JsonMap>[]
          : access == 0
          ? [_contact(20, 'Recent twenty'), _contact(21, 'Recent twenty-one')]
          : [_contact(70, 'New account recent')],
      if (kind == 'messages')
        'olderItems': emptyOlder
            ? <JsonMap>[]
            : access == 0
            ? [
                _contact(20, 'Duplicate recent must be hidden'),
                _contact(30, 'Older thirty'),
                _contact(30, 'Duplicate older must be hidden'),
                _contact(0, 'Invalid zero must be hidden'),
                _contact(-2, 'Invalid negative must be hidden'),
                _contact(40, 'Older forty'),
              ]
            : [_contact(80, 'New account older')],
    };
  }

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    final revision = accessRevision;
    calls.add((method, {...args, 'accessRevision': revision}));
    switch (method) {
      case 'bootstrap':
        return {'session': session(revision)};
      case 'inbox.load':
        final kind = args['kind'];
        final peer = args['peer'];
        if (!const [
          'mentions',
          'replies',
          'messages',
          'conversation',
        ].contains(kind)) {
          break;
        }
        if (kind == 'conversation') {
          if (peer is! int ||
              !const [20, 21, 30, 40, 70, 80, 99].contains(peer)) {
            break;
          }
          final gate = conversationGates.remove(peer);
          if (gate != null) {
            pending.add(gate);
            return gate.future;
          }
        } else if (peer != null) {
          break;
        }
        return snapshot(kind as String, peer: peer as int?, revision: revision);
      case 'profile.load':
        // The only unknown contact introduced by these scenarios is UID 99.
        if (args['id'] != 99 || args['force'] == true) break;
        return {
          'member_id': 99,
          'member_name': 'Looked-up ninety-nine',
          'accessRevision': revision,
          'owner': session(revision)['owner'],
        };
      case 'images.draftReferences':
        // The composer parses its local text on mount and after edits. These
        // fixtures have no image references; no image fetch or upload is allowed.
        if (args.length != 1 ||
            args['content'] is! String ||
            !const [
              '',
              'Keep the current private draft',
              '**Literal draft**',
              '**Still literal**, edited before mock send',
            ].contains(args['content'])) {
          break;
        }
        return {
          'content': args['content'],
          'accessRevision': revision,
          'imageURLs': <String>[],
        };
      case 'images.load':
        // Lookup returns canonical avatar URLs. Exercise that exact read path
        // with a deliberate local fallback; never accept unrelated media work.
        if (args['kind'] != 'avatar' ||
            !const [20, 30, 99].any(
              (id) => args['url'] == 'https://www.nodeseek.com/avatar/$id.png',
            )) {
          break;
        }
        throw const NativeFailure(
          'fixture_avatar',
          'Local avatar unavailable.',
        );
      case 'inbox.updateDraft':
        if (!allowDraftWrite ||
            args['peer'] != 20 ||
            args['content'] is! String ||
            args['markdown'] is! bool) {
          break;
        }
        if (failSave) {
          throw const NativeFailure('fixture_disk', 'Local draft save failed.');
        }
        drafts[(revision, 20)] = args['content'] as String;
        draftModes[(revision, 20)] = args['markdown'] as bool;
        return {
          'content': args['content'],
          'markdown': args['markdown'],
          'accessRevision': revision,
        };
      case 'inbox.send':
        if (!allowSend ||
            args['peer'] != 20 ||
            args['markdown'] != false ||
            args['expectedMarkdown'] != false ||
            args['expectedContent'] is! String) {
          break;
        }
        // An unconfirmed fixture result must preserve the draft and must not
        // force-refresh the conversation. Nothing crosses the native channel.
        return {'kind': 'unknown', 'accessRevision': revision};
    }
    unexpected.add('$method $args');
    throw StateError('Contacts fixture rejected $method $args');
  }

  void changeAccount() {
    final next = accessRevision + 1;
    eventStream.add({
      'domain': 'session',
      'accessRevision': next,
      'data': session(next),
    });
  }
}

Finder get _categorySurface =>
    find.byKey(const ValueKey('inbox-category-surface'));
Finder get _lookupInput =>
    find.byKey(const ValueKey('inbox-peer-lookup-input'));
Finder get _composerBody => find.byKey(const ValueKey('inbox-composer-body'));
Finder _listText(String text) =>
    find.descendant(of: _categorySurface, matching: find.text(text));
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _ContactsNative native, {
  double width = 1180,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1000));
  final state = AppState(client: native);
  await state.connect();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final gate in native.pending) {
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
        child: CupertinoPageScaffold(child: InboxScreen(state: state)),
      ),
    ),
  );
  await _frames(tester);
  await tester.tap(find.text('私信'));
  await _frames(tester);
  expect(state.inboxNavigation.category, 2);
  return state;
}

Future<void> _lookup(WidgetTester tester, String input) async {
  await tester.enterText(_lookupInput, input);
  await tester.pump();
  final button = find.byKey(const ValueKey('inbox-peer-lookup-open'));
  expect(tester.widget<DeskButton>(button).onTap, isNotNull);
  await tester.tap(button);
  await _frames(tester);
}

void _expectReadOnlyContactFlow(_ContactsNative native) {
  expect(native.named('inbox.markRead'), isEmpty);
  expect(native.named('inbox.send'), isEmpty);
  expect(native.named('inbox.updateDraft'), isEmpty);
  expect(
    native.named('inbox.load').every((call) => call.$2['force'] != true),
    isTrue,
  );
  expect(native.unexpected, isEmpty);
}

void _macTest(String name, WidgetTesterCallback test) => testWidgets(
  name,
  test,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  _macTest('messages groups recent and older contacts and filters duplicates', (
    tester,
  ) async {
    final native = _ContactsNative();
    await _mount(tester, native);
    expect(_listText('最近对话'), findsOneWidget);
    expect(_listText('较早的对话'), findsOneWidget);
    for (final name in [
      'Recent twenty',
      'Recent twenty-one',
      'Older thirty',
      'Older forty',
    ]) {
      expect(_listText(name), findsOneWidget);
    }
    for (final name in [
      'Duplicate recent must be hidden',
      'Duplicate older must be hidden',
      'Invalid zero must be hidden',
      'Invalid negative must be hidden',
    ]) {
      expect(_listText(name), findsNothing);
    }
    expect(
      tester.getTopLeft(_listText('Recent twenty')).dy,
      lessThan(tester.getTopLeft(_listText('较早的对话')).dy),
    );
    expect(
      tester.getTopLeft(_listText('较早的对话')).dy,
      lessThan(tester.getTopLeft(_listText('Older thirty')).dy),
    );
    expect(native.named('profile.load'), isEmpty);
    _expectReadOnlyContactFlow(native);
  });

  _macTest('older-only messages remain visible without a false empty state', (
    tester,
  ) async {
    final native = _ContactsNative()..emptyRecent = true;
    await _mount(tester, native);
    expect(_listText('最近对话'), findsNothing);
    expect(_listText('较早的对话'), findsOneWidget);
    expect(_listText('Older thirty'), findsOneWidget);
    expect(_listText('Duplicate older must be hidden'), findsNothing);
    expect(find.text('暂无私信'), findsNothing);
    _expectReadOnlyContactFlow(native);
  });

  for (final peer in [20, 30]) {
    _macTest('known contact $peer opens through lookup without profile.load', (
      tester,
    ) async {
      final native = _ContactsNative();
      final state = await _mount(tester, native);
      await _lookup(tester, 'https://www.nodeseek.com/space/$peer');
      expect(state.inboxNavigation.peer, peer);
      expect(_composerBody, findsOneWidget);
      expect(native.named('profile.load'), isEmpty);
      expect(
        native
            .named('inbox.load')
            .map((call) => (call.$2['kind'], call.$2['peer'])),
        [('mentions', null), ('messages', null), ('conversation', peer)],
      );
      expect(
        tester.widget<CupertinoTextField>(_lookupInput).controller!.text,
        isEmpty,
      );
      final name = peer == 20 ? 'Recent twenty' : 'Older thirty';
      expect(_listText(name), findsOneWidget);
      _expectReadOnlyContactFlow(native);
    });
  }

  _macTest(
    'unknown contact joins older items and survives narrow return without refresh',
    (tester) async {
      final native = _ContactsNative()..emptyOlder = true;
      final state = await _mount(tester, native, width: 680);
      expect(_listText('较早的对话'), findsNothing);
      await _lookup(tester, '99');
      expect(state.inboxNavigation.peer, 99);
      expect(_composerBody, findsOneWidget);
      expect(native.named('profile.load'), hasLength(1));
      expect(native.named('profile.load').single.$2['id'], 99);
      expect(native.named('inbox.load').last.$2['peer'], 99);
      final reads = native.named('inbox.load').length;
      await tester.tap(_button('返回私信列表'));
      await _frames(tester);
      expect(state.inboxNavigation.peer, isNull);
      expect(_listText('较早的对话'), findsOneWidget);
      expect(_listText('Looked-up ninety-nine'), findsOneWidget);
      expect(
        tester.widget<CupertinoTextField>(_lookupInput).controller!.text,
        isEmpty,
      );
      expect(native.named('inbox.load'), hasLength(reads));
      // The transport has not supplied the new contact. Its presence above proves
      // that the successful lookup was merged into the local messages snapshot.
      expect(native.snapshot('messages')['olderItems'], isEmpty);
      await _lookup(tester, '99');
      expect(state.inboxNavigation.peer, 99);
      expect(native.named('profile.load'), hasLength(1));
      await tester.tap(_button('返回私信列表'));
      await _frames(tester);
      expect(_listText('Looked-up ninety-nine'), findsOneWidget);
      _expectReadOnlyContactFlow(native);
    },
  );

  _macTest(
    'failed conversation does not add the looked-up contact to older items',
    (tester) async {
      final native = _ContactsNative()
        ..emptyOlder = true
        ..failedConversations.add(99);
      final state = await _mount(tester, native, width: 680);
      await _lookup(tester, '99');
      expect(state.inboxNavigation.peer, 99);
      expect(find.text('暂时无法读取对话'), findsOneWidget);
      final body = tester.widget<CupertinoTextField>(_composerBody);
      expect(body.enabled == false || body.readOnly, isTrue);
      await tester.tap(_button('返回私信列表'));
      await _frames(tester);
      expect(_listText('Looked-up ninety-nine'), findsNothing);
      expect(_listText('较早的对话'), findsNothing);
      expect(
        tester.widget<CupertinoTextField>(_lookupInput).controller!.text,
        '99',
      );
      expect(find.textContaining('输入已保留'), findsOneWidget);
      _expectReadOnlyContactFlow(native);
    },
  );

  _macTest('account change during conversation load cannot merge old contact', (
    tester,
  ) async {
    final native = _ContactsNative()..emptyOlder = true;
    final gate = Completer<JsonMap>();
    native.conversationGates[99] = gate;
    final state = await _mount(tester, native);
    await _lookup(tester, '99');
    expect(state.inboxNavigation.peer, 99);
    final oldResult = native.snapshot('conversation', peer: 99, revision: 0);
    native.changeAccount();
    await _frames(tester);
    expect(state.accessRevision, 1);
    gate.complete(oldResult);
    await _frames(tester);
    expect(state.inboxNavigation.peer, isNull);
    await tester.tap(find.text('私信'));
    await _frames(tester);
    expect(_listText('New account recent'), findsOneWidget);
    expect(_listText('Looked-up ninety-nine'), findsNothing);
    expect(_listText('Recent twenty'), findsNothing);
    expect(_listText('较早的对话'), findsNothing);
    expect(
      tester.widget<CupertinoTextField>(_lookupInput).controller!.text,
      isEmpty,
    );
    expect(native.named('profile.load'), hasLength(1));
    _expectReadOnlyContactFlow(native);
  });

  _macTest(
    'failed current draft save prevents lookup navigation and contact merge',
    (tester) async {
      final native = _ContactsNative()
        ..emptyOlder = true
        ..allowDraftWrite = true
        ..failSave = true;
      final state = await _mount(tester, native);
      await tester.tap(_listText('Recent twenty'));
      await _frames(tester);
      await tester.enterText(_composerBody, 'Keep the current private draft');
      await _lookup(tester, '99');
      expect(state.inboxNavigation.peer, 20);
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        'Keep the current private draft',
      );
      expect(
        tester.widget<CupertinoTextField>(_lookupInput).controller!.text,
        '99',
      );
      expect(_listText('Looked-up ninety-nine'), findsNothing);
      expect(_listText('较早的对话'), findsNothing);
      expect(native.named('profile.load'), hasLength(1));
      expect(
        native.named('inbox.load').where((call) => call.$2['peer'] == 99),
        isEmpty,
      );
      expect(native.named('inbox.updateDraft'), isNotEmpty);
      expect(native.named('inbox.markRead'), isEmpty);
      expect(native.named('inbox.send'), isEmpty);
      expect(
        native.named('inbox.load').every((call) => call.$2['force'] != true),
        isTrue,
      );
      expect(native.unexpected, isEmpty);
    },
  );

  _macTest(
    'restored plain draft sends mock expectedMarkdown false without media fetches',
    (tester) async {
      final native = _ContactsNative()
        ..allowDraftWrite = true
        ..allowSend = true;
      native.drafts[(0, 20)] = '**Literal draft**';
      native.draftModes[(0, 20)] = false;
      final state = await _mount(tester, native);
      await tester.tap(_listText('Recent twenty'));
      await _frames(tester);
      final body = tester.widget<CupertinoTextField>(_composerBody);
      expect(body.controller!.text, '**Literal draft**');
      expect(body.enabled != false && !body.readOnly, isTrue);
      expect(_button('纯文本'), findsOneWidget);
      expect(state.inboxDrafts.read(revision: 0, peer: 20)!.markdown, isFalse);
      const content = '**Still literal**, edited before mock send';
      await tester.enterText(_composerBody, content);
      await tester.pump();
      final reads = native.named('inbox.load').length;
      await tester.tap(_button('发送'));
      await _frames(tester);
      expect(native.named('inbox.send'), hasLength(1));
      final sent = native.named('inbox.send').single.$2;
      expect(sent['peer'], 20);
      expect(sent['markdown'], isFalse);
      expect(sent['expectedMarkdown'], isFalse);
      expect(sent['expectedContent'], content);
      expect(native.named('inbox.updateDraft'), isNotEmpty);
      expect(
        native
            .named('inbox.updateDraft')
            .every((call) => call.$2['markdown'] == false),
        isTrue,
      );
      expect(
        tester.widget<CupertinoTextField>(_composerBody).controller!.text,
        content,
      );
      expect(native.drafts[(0, 20)], content);
      expect(native.draftModes[(0, 20)], isFalse);
      expect(native.named('inbox.load'), hasLength(reads));
      expect(
        native.named('inbox.load').every((call) => call.$2['force'] != true),
        isTrue,
      );
      expect(native.named('profile.load'), isEmpty);
      expect(native.named('images.load'), isEmpty);
      expect(native.named('inbox.markRead'), isEmpty);
      expect(native.unexpected, isEmpty);
    },
  );
}
