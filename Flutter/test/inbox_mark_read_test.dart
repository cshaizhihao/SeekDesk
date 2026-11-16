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

class _Native extends NativeClient {
  _Native() : super(methods: const MethodChannel('seekdesk.test.mark-read'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final gates = <Completer<JsonMap>>[];
  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  JsonMap session({int? revision}) => {
    'account': 'signedIn',
    'owner': 101 + (revision ?? accessRevision),
    'accessRevision': revision ?? accessRevision,
    'unread': {'mentions': 1},
  };
  JsonMap snapshot({bool unread = true, int? revision}) => {
    'kind': 'mentions',
    'accessRevision': revision ?? accessRevision,
    'loading': false,
    'items': [
      {
        'id': '77',
        'postID': 99,
        'floor': 4,
        'url': 'https://www.nodeseek.com/post-99-1#4',
        'title': 'Unread notice',
        'author': 'Author',
        'date': '2026-11-15',
        'unread': unread,
      },
    ],
  };
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'bootstrap') return {'session': session()};
    if (method == 'inbox.load') return snapshot();
    if (method == 'inbox.markRead') {
      final gate = Completer<JsonMap>();
      gates.add(gate);
      return gate.future;
    }
    unexpected.add(method);
    throw StateError('Unexpected request $method');
  }

  void switchAccount() {
    final nextRevision = accessRevision + 1;
    eventStream.add({
      'domain': 'session',
      'accessRevision': nextRevision,
      'data': session(revision: nextRevision),
    });
  }
}

Finder get _mark => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == '标为已读',
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<(_Native, AppState)> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 850));
  final native = _Native();
  final app = AppState(client: native);
  await app.connect();
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(child: InboxScreen(state: app)),
      ),
    ),
  );
  await _frames(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final gate in native.gates) {
      if (!gate.isCompleted) gate.complete(native.snapshot());
    }
    await _frames(tester);
    app.dispose();
    await native.eventStream.close();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(
      native.calls.where(
        (call) => !const [
          'bootstrap',
          'inbox.load',
          'inbox.markRead',
        ].contains(call.$1),
      ),
      isEmpty,
    );
  });
  return (native, app);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('marking read does not select, preview or reload a notice', (
    tester,
  ) async {
    final (native, state) = await _mount(tester);
    final loads = native.calls.where((call) => call.$1 == 'inbox.load').length;
    await tester.tap(_mark);
    await _frames(tester);
    expect(native.gates, hasLength(1));
    expect(state.inboxNavigation.notice, isNull);
    expect(tester.widget<DeskIcon>(_mark).onTap, isNull);
    final write = native.calls.last;
    expect(write.$1, 'inbox.markRead');
    expect(write.$2['kind'], 'mentions');
    expect(write.$2['id'], 77);
    native.gates.single.complete(native.snapshot(unread: false));
    await _frames(tester);
    expect(_mark, findsNothing);
    expect(state.inboxNavigation.notice, isNull);
    expect(
      native.calls.where((call) => call.$1 == 'inbox.load'),
      hasLength(loads),
    );
    expect(find.text('选择一条通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged unread response permits an explicit retry', (
    tester,
  ) async {
    final (native, state) = await _mount(tester);
    await tester.tap(_mark);
    await _frames(tester);
    native.gates.single.complete(native.snapshot());
    await _frames(tester);
    expect(_mark, findsOneWidget);
    expect(tester.widget<DeskIcon>(_mark).onTap, isNotNull);
    expect(state.inboxNavigation.notice, isNull);
    await tester.tap(_mark);
    await _frames(tester);
    expect(native.gates, hasLength(2));
    native.gates.last.complete(native.snapshot(unread: false));
    await _frames(tester);
    expect(_mark, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed transport retains unread and re-enables the action', (
    tester,
  ) async {
    final (native, state) = await _mount(tester);
    await tester.tap(_mark);
    await _frames(tester);
    native.gates.single.completeError(
      const NativeFailure('network', 'Local failure'),
    );
    await _frames(tester);
    expect(_mark, findsOneWidget);
    expect(tester.widget<DeskIcon>(_mark).onTap, isNotNull);
    expect(state.inboxNavigation.notice, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'old account completion cannot mark the new account notice read',
    (tester) async {
      final (native, state) = await _mount(tester);
      await tester.tap(_mark);
      await _frames(tester);
      native.switchAccount();
      await _frames(tester);
      native.gates.single.complete(native.snapshot(unread: false, revision: 0));
      await _frames(tester);
      expect(state.accessRevision, 1);
      expect(_mark, findsOneWidget);
      expect(tester.widget<DeskIcon>(_mark).onTap, isNotNull);
      expect(state.inboxNavigation.notice, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retained row action cannot write after account changes', (
    tester,
  ) async {
    final (native, _) = await _mount(tester);
    final oldAction = tester.widget<DeskIcon>(_mark).onTap!;
    native.switchAccount();
    // Invoke before the old row can be replaced by the next frame.
    oldAction();
    await _frames(tester);
    expect(native.gates, isEmpty);
    expect(_mark, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained row action cannot write to a different category', (
    tester,
  ) async {
    final (native, state) = await _mount(tester);
    final oldAction = tester.widget<DeskIcon>(_mark).onTap!;
    tester
        .widget<GlassSegmentedControl>(
          find.byKey(const ValueKey('inbox-categories')),
        )
        .onSegmentSelected(1);
    await _frames(tester);
    expect(state.inboxNavigation.category, 1);
    oldAction();
    await _frames(tester);
    expect(native.gates, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
