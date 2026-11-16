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

/// All native work terminates in this fixture. Only the long-feedback test
/// explicitly permits a local draft write and a mock unconfirmed send.
class _RecoveryNative extends NativeClient {
  _RecoveryNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-recovery'));

  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final transportFailures = <String, int>{};
  final snapshotFailures = <String, int>{};
  final readGates = <String, Completer<JsonMap>>{};
  final pending = <Completer<JsonMap>>[];
  Completer<JsonMap>? profileGate;
  int activeReads = 0, maximumReads = 0;
  bool allowMockSend = false;
  String draft = '', sendMessage = '';

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  bool _consume(Map<String, int> counts, String key) {
    final count = counts[key] ?? 0;
    if (count <= 0) return false;
    counts[key] = count - 1;
    return true;
  }

  JsonMap snapshot(String kind, {int? peer}) => {
    'kind': kind,
    'peer': ?peer,
    'accessRevision': accessRevision,
    'loading': false,
    'draft': peer == 20 ? draft : '',
    'draftMarkdown': true,
    'items': kind == 'conversation'
        ? [
            {
              'id': 'message-$peer',
              'text': 'Message from peer $peer',
              'mine': false,
              'markdown': false,
              'date': '2026-11-15',
            },
          ]
        : kind == 'messages'
        ? [
            for (final id in [20, 21])
              {
                'id': id,
                'name': 'Contact $id',
                'preview': 'Local conversation $id',
                'avatar': '',
                'unread': false,
                'date': '2026-11-15',
              },
          ]
        : [
            {
              'id': 100,
              'author': 'Local author',
              'title': 'Recovered $kind notice',
              'avatar': '',
              'unread': false,
              'date': '2026-11-15',
              'url': 'https://www.nodeseek.com/post-9900001-1',
            },
          ],
    if (kind == 'messages') 'olderItems': <JsonMap>[],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 101,
            'accessRevision': accessRevision,
            'unread': {'mentions': 0, 'replies': 0, 'messages': 0},
          },
        };
      case 'inbox.load':
        final kind = args['kind'];
        final peer = args['peer'];
        if (!const [
              'mentions',
              'replies',
              'messages',
              'conversation',
            ].contains(kind) ||
            kind == 'conversation' && !const [20, 21, 99].contains(peer) ||
            kind != 'conversation' && peer != null) {
          break;
        }
        final key = '$kind:${peer ?? ''}';
        activeReads++;
        if (activeReads > maximumReads) maximumReads = activeReads;
        try {
          final gate = readGates.remove(key);
          if (gate != null) {
            pending.add(gate);
            return await gate.future;
          }
          if (_consume(transportFailures, key)) {
            eventStream.add({
              'domain': 'inbox',
              'accessRevision': accessRevision,
              'data': {
                'kind': kind,
                'peer': ?peer,
                'accessRevision': accessRevision,
                'loading': true,
                'items': <JsonMap>[],
              },
            });
            throw const NativeFailure(
              'unavailable',
              'Local service disconnected.',
            );
          }
          final result = snapshot(kind as String, peer: peer as int?);
          return _consume(snapshotFailures, key)
              ? {...result, 'items': <JsonMap>[], 'error': 'Local read failed.'}
              : result;
        } finally {
          activeReads--;
        }
      case 'profile.load':
        if (args.length != 1 || args['id'] != 99) break;
        final gate = profileGate;
        profileGate = null;
        if (gate != null) {
          pending.add(gate);
          return gate.future;
        }
        return {
          'member_id': 99,
          'member_name': 'Looked-up 99',
          'owner': 101,
          'accessRevision': accessRevision,
        };
      case 'images.draftReferences':
        if (args.length != 1 ||
            !const ['', 'Local draft'].contains(args['content'])) {
          break;
        }
        return {
          'content': args['content'],
          'accessRevision': accessRevision,
          'imageURLs': <String>[],
        };
      case 'images.load':
        if (args['kind'] != 'avatar' ||
            !const [20, 21, 99].any(
              (id) => args['url'] == 'https://www.nodeseek.com/avatar/$id.png',
            )) {
          break;
        }
        throw const NativeFailure('local_avatar', 'Local avatar unavailable.');
      case 'inbox.updateDraft':
        if (!allowMockSend ||
            args['peer'] != 20 ||
            args['content'] != 'Local draft' ||
            args['markdown'] != true) {
          break;
        }
        draft = args['content'] as String;
        return {
          'content': draft,
          'markdown': true,
          'accessRevision': accessRevision,
        };
      case 'inbox.send':
        if (!allowMockSend ||
            args['peer'] != 20 ||
            args['expectedContent'] != 'Local draft' ||
            args['expectedMarkdown'] != true ||
            args['markdown'] != true) {
          break;
        }
        return {
          'kind': 'unknown',
          'message': sendMessage,
          'accessRevision': accessRevision,
        };
    }
    unexpected.add('$method $args');
    throw StateError('Recovery fixture rejected $method $args');
  }
}

Finder get _category => find.byKey(const ValueKey('inbox-category-surface'));
Finder get _conversation =>
    find.byKey(const ValueKey('inbox-conversation-surface'));
Finder get _body => find.byKey(const ValueKey('inbox-composer-body'));
Finder get _lookup => find.byKey(const ValueKey('inbox-peer-lookup-input'));
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _in(Finder surface, Finder child) =>
    find.descendant(of: surface, matching: child);

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _RecoveryNative native, {
  int? restorePeer,
  double width = 1180,
  double height = 1000,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  final state = AppState(client: native);
  await state.connect();
  if (restorePeer != null) {
    state.inboxNavigation.select(
      revision: state.accessRevision,
      category: 2,
      peer: restorePeer,
      peerName: 'Contact $restorePeer',
      peerAvatar: '',
    );
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final pending in native.pending) {
      if (!pending.isCompleted) {
        pending.completeError(
          const NativeFailure('cancelled', 'Fixture disposed.'),
        );
      }
    }
    await tester.pump();
    state.dispose();
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(native.named('inbox.markRead'), isEmpty);
    if (!native.allowMockSend) {
      expect(native.named('inbox.updateDraft'), isEmpty);
      expect(native.named('inbox.send'), isEmpty);
    }
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    CupertinoApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: child!,
        ),
      ),
      home: CupertinoPageScaffold(child: InboxScreen(state: state)),
    ),
  );
  await _frames(tester);
  return state;
}

void _macTest(String description, WidgetTesterCallback test) => testWidgets(
  description,
  test,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  _macTest(
    'current transport failure replaces loading with an explicit retry',
    (tester) async {
      final native = _RecoveryNative()..transportFailures['mentions:'] = 1;
      await _mount(tester, native);
      expect(find.text('此次读取未完成，请重试。'), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      final retry = _in(_category, _button('重试'));
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await _frames(tester);
      expect(find.text('Recovered mentions notice'), findsOneWidget);
      expect(find.text('此次读取未完成，请重试。'), findsNothing);
      expect(native.named('inbox.load'), hasLength(2));
      expect(native.named('inbox.load').last.$2, {
        'kind': 'mentions',
        'force': true,
      });
    },
  );

  _macTest(
    'left retry reloads only messages and preserves the selected draft',
    (tester) async {
      final native = _RecoveryNative()..snapshotFailures['messages:'] = 1;
      final state = await _mount(tester, native, restorePeer: 20);
      final controller = tester.widget<CupertinoTextField>(_body).controller;
      expect(_in(_category, find.text('Local read failed.')), findsOneWidget);
      expect(
        _in(_conversation, find.text('Message from peer 20')),
        findsOneWidget,
      );
      final reads = native.named('inbox.load').length;
      await tester.tap(_in(_category, _button('重试')));
      await _frames(tester);
      expect(state.inboxNavigation.peer, 20);
      expect(
        tester.widget<CupertinoTextField>(_body).controller,
        same(controller),
      );
      expect(_in(_category, find.text('Contact 20')), findsOneWidget);
      expect(
        _in(_conversation, find.text('Message from peer 20')),
        findsOneWidget,
      );
      expect(native.named('inbox.load'), hasLength(reads + 1));
      expect(native.named('inbox.load').last.$2, {
        'kind': 'messages',
        'force': true,
      });
      expect(
        native.maximumReads,
        1,
        reason: 'Restore and retry must use the native lane serially.',
      );
    },
  );

  _macTest(
    'superseded cancelled conversation cannot report an error in its successor',
    (tester) async {
      final native = _RecoveryNative();
      final oldRead = Completer<JsonMap>();
      native.readGates['conversation:20'] = oldRead;
      final state = await _mount(tester, native);
      await tester.tap(find.text('私信'));
      await _frames(tester);
      await tester.tap(_in(_category, find.text('Contact 20')));
      await _frames(tester);
      await tester.tap(_in(_category, find.text('Contact 21')));
      await _frames(tester);
      oldRead.completeError(
        const NativeFailure('cancelled', 'Old native selection cancelled.'),
      );
      await _frames(tester);
      expect(state.inboxNavigation.peer, 21);
      expect(
        _in(_conversation, find.text('Message from peer 21')),
        findsOneWidget,
      );
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isFalse);
      expect(find.text('此次读取未完成，请重试。'), findsNothing);
      expect(find.text('暂时无法读取对话'), findsNothing);
      expect(
        native.named('inbox.load').where((call) => call.$2['peer'] == 21),
        hasLength(1),
      );
    },
  );

  _macTest(
    'late profile result keeps a newer contact selection even before rebuild',
    (tester) async {
      final native = _RecoveryNative();
      final profile = Completer<JsonMap>();
      native.profileGate = profile;
      final state = await _mount(tester, native);
      await tester.tap(find.text('私信'));
      await _frames(tester);
      await tester.enterText(_lookup, '99');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('inbox-peer-lookup-open')));
      await _frames(tester);
      expect(native.named('profile.load'), hasLength(1));
      await tester.tap(_in(_category, find.text('Contact 20')));
      // Do not pump a rebuilding frame between the new selection and completion:
      // the parent callback's original lease must also close this race window.
      profile.complete({
        'member_id': 99,
        'member_name': 'Late 99',
        'owner': 101,
        'accessRevision': 0,
      });
      await _frames(tester);
      expect(state.inboxNavigation.peer, 20);
      expect(
        native.named('inbox.load').where((call) => call.$2['peer'] == 99),
        isEmpty,
      );
      expect(tester.widget<CupertinoTextField>(_lookup).controller!.text, '99');
      expect(
        tester
            .widget<DeskButton>(
              find.byKey(const ValueKey('inbox-peer-lookup-open')),
            )
            .busy,
        isFalse,
      );
      expect(
        _in(_conversation, find.text('Message from peer 20')),
        findsOneWidget,
      );
    },
  );

  _macTest('small scaled conversation error can scroll to retry and recover', (
    tester,
  ) async {
    final native = _RecoveryNative()..snapshotFailures['conversation:20'] = 1;
    await _mount(
      tester,
      native,
      restorePeer: 20,
      width: 680,
      height: 480,
      scale: 2,
    );
    expect(find.text('暂时无法读取对话'), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
    final scroll = find.byKey(
      const ValueKey('inbox-conversation:20-recovery-scroll'),
    );
    expect(scroll, findsOneWidget);
    final retry = _in(_conversation, _button('重试'));
    await tester.ensureVisible(retry);
    await tester.pump();
    expect(retry.hitTestable(), findsOneWidget);
    await tester.tap(retry);
    await _frames(tester);
    expect(find.text('暂时无法读取对话'), findsNothing);
    expect(tester.widget<CupertinoTextField>(_body).readOnly, isFalse);
    expect(native.named('inbox.load').last.$2, {
      'kind': 'conversation',
      'peer': 20,
      'force': true,
    });
    expect(tester.takeException(), isNull);
  });

  _macTest(
    'long unconfirmed send feedback stays bounded and preserves the draft',
    (tester) async {
      final native = _RecoveryNative()
        ..allowMockSend = true
        ..sendMessage = List.filled(
          70,
          'Local send feedback remains readable.',
        ).join(' ');
      await _mount(tester, native, restorePeer: 20, width: 780, height: 540);
      await tester.enterText(_body, 'Local draft');
      await _frames(tester);
      final send = find.byKey(const ValueKey('inbox-composer-send'));
      final action = tester.widget<DeskButton>(send).onTap;
      expect(action, isNotNull);
      action!();
      await _frames(tester);
      expect(native.named('inbox.send'), hasLength(1));
      final feedback = find.byKey(const ValueKey('inbox-feedback-scroll'));
      expect(feedback, findsOneWidget);
      expect(tester.getSize(feedback).height, lessThanOrEqualTo(160));
      final scrollable = _in(feedback, find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.widget<CupertinoTextField>(_body).controller!.text,
        'Local draft',
      );
      expect(native.draft, 'Local draft');
      expect(
        native.named('inbox.load').every((call) => call.$2['force'] != true),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
