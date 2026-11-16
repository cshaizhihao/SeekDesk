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
import 'package:seekdesk_flutter/widgets/inbox_notice_detail.dart';

String _title(int index, [int revision = 0]) =>
    'Account $revision notice $index';

JsonMap _notice(int index, {int revision = 0, bool unread = false}) => {
  'id': '${7000 + index}',
  'postID': 9000 + index,
  'floor': index + 1,
  'url': 'https://www.nodeseek.com/post-${9000 + index}-1#${index + 1}',
  'authorID': 200 + index,
  'author': 'Author $index',
  'avatar': '',
  'title': _title(index, revision),
  'date': '2026-11-15T10:30:00',
  'unread': unread,
};

class _Preview {
  _Preview(this.arguments);
  final JsonMap arguments;
  final gate = Completer<JsonMap>();

  void finish(String body) => gate.complete({
    'requestID': arguments['requestID'],
    'accessRevision': arguments['accessRevision'],
    'postID': arguments['postID'],
    'floor': arguments['floor'],
    'blocks': [
      {'kind': 'paragraph', 'text': body},
    ],
  });
}

/// Complete notice DTOs with different notice/post identities. Every write and
/// reader operation is rejected; selection tests may only list or preview.
class _SelectionNative extends NativeClient {
  _SelectionNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-selection'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final previews = <_Preview>[];
  List<JsonMap> rows = [
    for (var index = 0; index < 80; index++) _notice(index),
  ];
  Completer<JsonMap>? nextLoad;
  final outstandingLoads = <Completer<JsonMap>>[];

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String name) =>
      calls.where((call) => call.$1 == name).toList();

  JsonMap snapshot({String kind = 'mentions', String? error}) => {
    'kind': kind,
    'accessRevision': accessRevision,
    'loading': false,
    'draft': '',
    'error': error,
    'items': [
      for (final row in rows) {...row},
    ],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 101,
            'accessRevision': accessRevision,
            'unread': <String, int>{},
          },
        };
      case 'inbox.load':
        final kind = stringValue(arguments['kind']);
        if (!const ['mentions', 'replies', 'messages'].contains(kind)) break;
        final pending = nextLoad;
        nextLoad = null;
        if (pending != null) {
          outstandingLoads.add(pending);
          return pending.future;
        }
        return snapshot(kind: kind);
      case 'inbox.preview':
        final preview = _Preview({...arguments});
        previews.add(preview);
        return preview.gate.future;
      case 'inbox.cancelPreview':
        return {'cancelled': true};
    }
    unexpected.add(method);
    throw StateError('Selection fixture rejected $method');
  }

  void changeAccount() {
    final revision = accessRevision + 1;
    rows = [
      for (var index = 0; index < 80; index++)
        _notice(index, revision: revision),
    ];
    eventStream.add({
      'domain': 'session',
      'accessRevision': revision,
      'data': {
        'account': 'signedIn',
        'owner': 202,
        'accessRevision': revision,
        'unread': <String, int>{},
      },
    });
  }
}

class _Fixture {
  _Fixture(this.native, this.state);
  final _SelectionNative native;
  final AppState state;

  Future<void> render(WidgetTester tester, {double width = 1200}) async {
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          theme: const CupertinoThemeData(
            textTheme: CupertinoTextThemeData(textStyle: DeskTypography.base),
          ),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: CupertinoPageScaffold(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: 900,
                    child: InboxScreen(state: state),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  double width = 1200,
  _SelectionNative? native,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1100));
  final client = native ?? _SelectionNative();
  final state = AppState(client: client);
  await state.connect();
  final fixture = _Fixture(client, state);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final request in client.previews) {
      if (!request.gate.isCompleted) {
        request.gate.completeError(
          const NativeFailure('cancelled', 'Fixture disposed'),
        );
      }
    }
    for (final gate in client.outstandingLoads) {
      if (!gate.isCompleted) gate.complete(client.snapshot());
    }
    await _frames(tester);
    state.dispose();
    await client.eventStream.close();
    await tester.binding.setSurfaceSize(null);
    expect(client.unexpected, isEmpty);
    for (final method in [
      'reader.open',
      'reader.load',
      'inbox.markRead',
      'inbox.send',
      'inbox.updateDraft',
    ]) {
      expect(client.named(method), isEmpty);
    }
  });
  await fixture.render(tester, width: width);
  return fixture;
}

Finder get _category => find.byKey(const ValueKey('inbox-category-surface'));
Finder _rowTitle(int index, [int revision = 0]) => find.descendant(
  of: _category,
  matching: find.text(_title(index, revision)),
);
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder _body(String body) => find.text(body, findRichText: true);
ScrollController _listController(WidgetTester tester) => tester
    .widget<ListView>(
      find.byKey(const ValueKey('mentions:'), skipOffstage: false),
    )
    .controller!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'wide initial state leaves notices unselected with no preview or unread consumption',
    (tester) async {
      final native = _SelectionNative();
      native.rows[0] = _notice(0, unread: true);
      final fixture = await _mount(tester, native: native);
      expect(find.text('选择一条通知'), findsOneWidget);
      expect(fixture.state.inboxNavigation.notice, isNull);
      expect(find.byType(InboxNoticeDetail), findsNothing);
      expect(native.previews, isEmpty);
      expect(native.named('inbox.load'), hasLength(1));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_rowTitle(0)));
        await _frames(tester);
        final focus = Focus.of(tester.element(_rowTitle(0)));
        focus.requestFocus();
        await _frames(tester);
        expect(focus.hasFocus, isTrue);
        expect(fixture.state.inboxNavigation.notice, isNull);
        expect(native.previews, isEmpty);
        expect(native.named('inbox.markRead'), isEmpty);
      } finally {
        await mouse.removePointer();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clicking an already read notice only previews and resizing preserves its identity',
    (tester) async {
      final fixture = await _mount(tester);
      await tester.tap(_rowTitle(1));
      await _frames(tester);
      expect(fixture.state.inboxNavigation.noticeID, '7001');
      expect(fixture.native.previews, hasLength(1));
      final preview = fixture.native.previews.single;
      expect(preview.arguments['postID'], 9001);
      expect(preview.arguments['floor'], 2);
      expect(
        preview.arguments['url'],
        'https://www.nodeseek.com/post-9001-1#2',
      );
      preview.finish('Selected notification preview');
      await _frames(tester);
      expect(_body('Selected notification preview'), findsOneWidget);
      final detailState = tester.state(find.byType(InboxNoticeDetail));
      final screenState = tester.state(find.byType(InboxScreen));
      final list = _listController(tester);
      for (final width in [500.0, 1200.0, 620.0]) {
        await fixture.render(tester, width: width);
        expect(tester.state(find.byType(InboxNoticeDetail)), same(detailState));
        expect(tester.state(find.byType(InboxScreen)), same(screenState));
        expect(_listController(tester), same(list));
        expect(_body('Selected notification preview'), findsOneWidget);
        expect(fixture.native.previews, hasLength(1));
        expect(fixture.native.named('inbox.load'), hasLength(1));
        expect(fixture.native.named('inbox.cancelPreview'), isEmpty);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'narrow back restores list offset and the activating keyboard focus',
    (tester) async {
      final fixture = await _mount(tester, width: 500);
      final controller = _listController(tester);
      controller.jumpTo(600);
      await _frames(tester);
      await tester.ensureVisible(_rowTitle(12));
      await _frames(tester);
      final offset = controller.offset;
      final rowFocus = Focus.of(tester.element(_rowTitle(12)));
      rowFocus.requestFocus();
      await _frames(tester);
      expect(rowFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(fixture.state.inboxNavigation.noticeID, '7012');
      expect(fixture.native.previews, hasLength(1));
      fixture.native.previews.single.finish('Keyboard selected floor');
      await _frames(tester);
      expect(_category, findsNothing);
      expect(rowFocus.canRequestFocus, isFalse);
      await tester.tap(_button('返回通知列表'));
      await _frames(tester);
      expect(fixture.state.inboxNavigation.notice, isNull);
      expect(find.byType(InboxNoticeDetail), findsNothing);
      expect(_category, findsOneWidget);
      expect(_listController(tester), same(controller));
      expect(controller.offset, closeTo(offset, .5));
      expect(rowFocus.canRequestFocus, isTrue);
      expect(rowFocus.hasPrimaryFocus, isTrue);
      expect(fixture.native.named('inbox.load'), hasLength(1));
      expect(fixture.native.named('inbox.cancelPreview'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful refresh removing the selection clears detail without selecting the first row',
    (tester) async {
      final fixture = await _mount(tester);
      await tester.tap(_rowTitle(1));
      await _frames(tester);
      fixture.native.previews.single.finish('Removed notification body');
      await _frames(tester);
      final refresh = Completer<JsonMap>();
      fixture.native.nextLoad = refresh;
      await tester.tap(_icon('刷新通知'));
      await _frames(tester);
      expect(fixture.state.inboxNavigation.noticeID, '7001');
      expect(_body('Removed notification body'), findsOneWidget);
      fixture.native.rows.removeWhere((row) => row['id'] == '7001');
      refresh.complete(fixture.native.snapshot());
      await _frames(tester);
      expect(fixture.native.named('inbox.load').last.$2['force'], isTrue);
      expect(fixture.state.inboxNavigation.notice, isNull);
      expect(find.byType(InboxNoticeDetail), findsNothing);
      expect(find.text('选择一条通知'), findsOneWidget);
      expect(_rowTitle(0), findsOneWidget);
      expect(_body('Removed notification body'), findsNothing);
      expect(fixture.native.previews, hasLength(1));
      expect(fixture.native.named('inbox.cancelPreview'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed refresh does not clear a valid selected preview', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.tap(_rowTitle(1));
    await _frames(tester);
    fixture.native.previews.single.finish('Retained despite failed refresh');
    await _frames(tester);
    final refresh = Completer<JsonMap>();
    fixture.native.nextLoad = refresh;
    await tester.tap(_icon('刷新通知'));
    await _frames(tester);
    refresh.complete({
      ...fixture.native.snapshot(error: 'Local refresh failure'),
      'items': <JsonMap>[],
    });
    await _frames(tester);
    expect(fixture.state.inboxNavigation.noticeID, '7001');
    expect(_body('Retained despite failed refresh'), findsOneWidget);
    expect(fixture.native.previews, hasLength(1));
    expect(fixture.native.named('inbox.cancelPreview'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account change clears selected notice and rejects its late preview',
    (tester) async {
      final fixture = await _mount(tester);
      await tester.tap(_rowTitle(1));
      await _frames(tester);
      final old = fixture.native.previews.single;
      fixture.native.changeAccount();
      await _frames(tester);
      expect(fixture.state.accessRevision, 1);
      expect(fixture.state.inboxNavigation.notice, isNull);
      expect(find.byType(InboxNoticeDetail), findsNothing);
      expect(find.text('选择一条通知'), findsOneWidget);
      expect(_rowTitle(0, 1), findsOneWidget);
      old.finish('Old account preview must stay private');
      await _frames(tester);
      expect(_body('Old account preview must stay private'), findsNothing);
      expect(fixture.native.previews, hasLength(1));
      await tester.tap(_rowTitle(1, 1));
      await _frames(tester);
      expect(fixture.native.previews, hasLength(2));
      final current = fixture.native.previews.last;
      expect(current.arguments['accessRevision'], 1);
      current.finish('New account selected preview');
      await _frames(tester);
      expect(_body('New account selected preview'), findsOneWidget);
      expect(_body('Old account preview must stay private'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching A to B ignores late A data and keeps B selected', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.tap(_rowTitle(1));
    await _frames(tester);
    final a = fixture.native.previews.single;
    await tester.tap(_rowTitle(2));
    await _frames(tester);
    expect(fixture.native.previews, hasLength(2));
    final b = fixture.native.previews.last;
    expect(fixture.state.inboxNavigation.noticeID, '7002');
    expect(
      fixture.native.named('inbox.cancelPreview').single.$2['requestID'],
      a.arguments['requestID'],
    );
    b.finish('Current B body');
    await _frames(tester);
    a.finish('Late A body');
    await _frames(tester);
    expect(fixture.state.inboxNavigation.noticeID, '7002');
    expect(_body('Current B body'), findsOneWidget);
    expect(_body('Late A body'), findsNothing);
    expect(fixture.native.named('inbox.load'), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
