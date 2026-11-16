import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/inbox_notice_detail.dart';

JsonMap _notice({String id = 'notice-71', int post = 9201, int floor = 7}) => {
  'id': id,
  'postID': post,
  'floor': floor,
  'url': 'https://www.nodeseek.com/post-$post-1#$floor',
  'authorID': 42,
  'author': 'Local notice author',
  'avatar': '',
  'title': 'Local notice title',
  'date': '2026-11-15T10:30:00',
  'unread': true,
};

class _PreviewRequest {
  _PreviewRequest(this.arguments);
  final JsonMap arguments;
  final completion = Completer<JsonMap>();

  void succeed(String text, {JsonMap overrides = const {}}) {
    completion.complete({
      'requestID': arguments['requestID'],
      'accessRevision': arguments['accessRevision'],
      'postID': arguments['postID'],
      'floor': arguments['floor'],
      'blocks': [
        {'kind': 'paragraph', 'text': text},
      ],
      ...overrides,
    });
  }

  void fail(Object error) => completion.completeError(error);
}

/// Only these local preview/cancellation replies are accepted by default.
/// Forum reader calls are enabled solely for the explicit open-thread test.
class _PreviewNative extends NativeClient {
  _PreviewNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-preview'));
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final previews = <_PreviewRequest>[];
  bool allowReader = false;

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  List<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'bootstrap') {
      return {
        'session': {
          'account': 'signedIn',
          'owner': 101,
          'accessRevision': accessRevision,
          'unread': {'mentions': 1, 'replies': 0, 'messages': 0},
        },
      };
    }
    if (method == 'inbox.preview') {
      final request = _PreviewRequest({...arguments});
      previews.add(request);
      return request.completion.future;
    }
    if (method == 'inbox.cancelPreview') return {'cancelled': true};
    if (allowReader && method == 'reader.open') {
      return {
        'showReader': true,
        'selectedTab': arguments['id'],
        'tabs': [
          {'id': arguments['id'], 'url': arguments['url']},
        ],
        'posts': <JsonMap>[],
      };
    }
    if (allowReader && method == 'reader.load') {
      return {
        'url': arguments['url'],
        'accessRevision': accessRevision,
        'loading': false,
        'thread': <String, dynamic>{},
      };
    }
    unexpected.add(method);
    throw StateError('Preview fixture rejected $method');
  }

  void changeAccount() {
    final revision = accessRevision + 1;
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
  final _PreviewNative native;
  final AppState state;
  int backCount = 0;

  Future<void> render(
    WidgetTester tester, {
    JsonMap? notice,
    int category = 0,
    double width = 820,
    double textScale = 1,
    bool showBack = false,
  }) async {
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
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: true,
              ),
              child: CupertinoPageScaffold(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: 880,
                    child: InboxNoticeDetail(
                      key: const ValueKey('selected-notice-fixture'),
                      state: state,
                      notice: notice ?? _notice(),
                      category: category,
                      revision: state.accessRevision,
                      onBack: () => backCount++,
                      showBack: showBack,
                    ),
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
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<_Fixture> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1300, 1000));
  final native = _PreviewNative();
  final state = AppState(client: native);
  await state.connect();
  final fixture = _Fixture(native, state);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final request in native.previews) {
      if (!request.completion.isCompleted) {
        request.fail(const NativeFailure('cancelled', 'Fixture disposed'));
      }
    }
    await _frames(tester);
    state.dispose();
    await native.eventStream.close();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(native.named('inbox.markRead'), isEmpty);
    expect(native.named('inbox.send'), isEmpty);
    expect(native.named('inbox.updateDraft'), isEmpty);
  });
  await fixture.render(tester);
  return fixture;
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _body(String text) => find.text(text, findRichText: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'notice preview is read-only and preserves precise floor identity',
    (tester) async {
      final fixture = await _mount(tester);
      final native = fixture.native;
      expect(native.previews, hasLength(1));
      final request = native.previews.single;
      expect(request.arguments['requestID'], isNotEmpty);
      expect(request.arguments['accessRevision'], 0);
      expect(request.arguments['postID'], 9201);
      expect(request.arguments['floor'], 7);
      expect(request.arguments['authorID'], 42);
      expect(
        request.arguments['url'],
        'https://www.nodeseek.com/post-9201-1#7',
      );
      expect(request.arguments['force'], isFalse);
      request.succeed('Read-only selected floor body');
      await _frames(tester);
      expect(_body('Read-only selected floor body'), findsOneWidget);
      expect(find.text('在帖子中提到了你'), findsOneWidget);
      expect(find.text('第 7 楼'), findsOneWidget);
      expect(native.named('reader.open'), isEmpty);
      expect(native.named('reader.load'), isEmpty);
      expect(fixture.state.workspace.tabs, isEmpty);
      expect(fixture.state.readers, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'back visibility and resizing do not reload the selected preview',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.native.previews.single.succeed('Retained floor');
      await _frames(tester);
      final detailState = tester.state(find.byType(InboxNoticeDetail));
      await fixture.render(tester, width: 420, showBack: true);
      expect(tester.state(find.byType(InboxNoticeDetail)), same(detailState));
      expect(_body('Retained floor'), findsOneWidget);
      expect(fixture.native.previews, hasLength(1));
      await tester.tap(_button('返回通知列表'));
      expect(fixture.backCount, 1);
      expect(fixture.native.named('reader.open'), isEmpty);
      await fixture.render(tester, width: 820);
      expect(_button('返回通知列表'), findsNothing);
      expect(fixture.native.previews, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a late previous selection cannot replace the current preview', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final old = fixture.native.previews.single;
    await fixture.render(tester, notice: _notice(id: 'notice-72', post: 9202));
    final latest = fixture.native.previews.last;
    expect(fixture.native.previews, hasLength(2));
    expect(
      fixture.native.named('inbox.cancelPreview').single.$2['requestID'],
      old.arguments['requestID'],
    );
    latest.succeed('Current selection body');
    await _frames(tester);
    old.succeed('Stale selection body');
    await _frames(tester);
    expect(_body('Current selection body'), findsOneWidget);
    expect(_body('Stale selection body'), findsNothing);
    expect(fixture.native.named('reader.open'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a late cancellation error stays out of the new selected detail',
    (tester) async {
      final fixture = await _mount(tester);
      final old = fixture.native.previews.single;
      await fixture.render(tester, category: 1);
      fixture.native.previews.last.succeed('Reply category body');
      await _frames(tester);
      old.fail(const NativeFailure('cancelled', 'Old selection cancelled'));
      await _frames(tester);
      expect(_body('Reply category body'), findsOneWidget);
      expect(find.text('回复了你的主题'), findsOneWidget);
      expect(find.text('Old selection cancelled'), findsNothing);
      expect(_button('重新读取'), findsNothing);
      expect(fixture.native.previews, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final error in [false, true]) {
    testWidgets(
      'disposal cancels ownership and ignores late ${error ? 'error' : 'data'}',
      (tester) async {
        final fixture = await _mount(tester);
        final request = fixture.native.previews.single;
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          fixture.native.named('inbox.cancelPreview').single.$2['requestID'],
          request.arguments['requestID'],
        );
        if (error) {
          request.fail(const NativeFailure('cancelled', 'Disposed request'));
        } else {
          request.succeed('Disposed request body');
        }
        await _frames(tester);
        expect(_body('Disposed request body'), findsNothing);
        expect(fixture.native.named('reader.open'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('account change rejects old data before rebuilding the detail', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final old = fixture.native.previews.single;
    fixture.native.changeAccount();
    expect(fixture.state.accessRevision, 1);
    old.succeed('Previous account private body');
    await _frames(tester);
    expect(_body('Previous account private body'), findsNothing);
    await fixture.render(tester);
    expect(fixture.native.previews, hasLength(2));
    final current = fixture.native.previews.last;
    expect(current.arguments['accessRevision'], 1);
    expect(current.arguments['requestID'], isNot(old.arguments['requestID']));
    current.succeed('Current account body');
    await _frames(tester);
    expect(_body('Current account body'), findsOneWidget);
    expect(_body('Previous account private body'), findsNothing);
    expect(
      fixture.native
          .named('inbox.cancelPreview')
          .where((call) => call.$2['requestID'] == old.arguments['requestID']),
      isEmpty,
      reason: 'Do not issue an old-owner cancellation through the new account.',
    );
    expect(tester.takeException(), isNull);
  });

  for (final mismatch in <JsonMap>[
    {'requestID': 'unrelated-request'},
    {'accessRevision': 99},
    {'postID': 9999},
    {'floor': 99},
  ]) {
    testWidgets(
      'mismatched ${mismatch.keys.single} is rejected with explicit retry',
      (tester) async {
        final fixture = await _mount(tester);
        fixture.native.previews.single.succeed(
          'Wrong preview',
          overrides: mismatch,
        );
        await _frames(tester);
        expect(_body('Wrong preview'), findsNothing);
        expect(_button('重新读取'), findsOneWidget);
        expect(fixture.native.previews, hasLength(1));
        await tester.tap(_button('重新读取'));
        await _frames(tester);
        expect(fixture.native.previews, hasLength(2));
        final retry = fixture.native.previews.last;
        expect(retry.arguments['force'], isTrue);
        expect(
          retry.arguments['requestID'],
          isNot(fixture.native.previews.first.arguments['requestID']),
        );
        retry.succeed('Explicit retry body');
        await _frames(tester);
        expect(_body('Explicit retry body'), findsOneWidget);
        expect(_button('重新读取'), findsNothing);
        expect(fixture.native.named('reader.open'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('empty preview provides recovery without opening a reader', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    fixture.native.previews.single.succeed(
      '',
      overrides: {'blocks': <JsonMap>[]},
    );
    await _frames(tester);
    expect(_button('重新读取'), findsOneWidget);
    expect(_button('进入帖子'), findsOneWidget);
    expect(fixture.native.previews, hasLength(1));
    expect(fixture.native.named('reader.open'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only explicit enter-topic opens the actual post at its floor', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    fixture.native.previews.single.succeed('Selected floor');
    await _frames(tester);
    expect(fixture.native.named('reader.open'), isEmpty);
    fixture.native.allowReader = true;
    await tester.tap(_button('进入帖子'));
    await _frames(tester);
    final opened = fixture.native.named('reader.open').single.$2;
    expect(opened['url'], 'https://www.nodeseek.com/post-9201-1#7');
    expect(opened['id'], '9201', reason: 'Notification ID is not the post ID.');
    final loaded = fixture.native.named('reader.load').single.$2;
    expect(loaded['url'], opened['url']);
    expect(fixture.native.previews, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow double-size text keeps metadata and actions reachable', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final notice = {
      ..._notice(),
      'author': '很长的通知作者姓名 Long display name for local layout',
      'title': '长标题用来确认两倍文字在窄窗口里正常换行，而不会挤出阅读区域。',
    };
    await fixture.render(
      tester,
      notice: notice,
      width: 360,
      textScale: 2,
      showBack: true,
    );
    fixture.native.previews.single.succeed('两倍字号的本地回复内容，不访问论坛。');
    await _frames(tester);
    final title = find.text(notice['title'] as String);
    expect(title, findsOneWidget);
    expect(MediaQuery.textScalerOf(tester.element(title)).scale(18), 36);
    final scroll = find.byKey(const ValueKey('inbox-notice-preview-scroll'));
    final bounds = tester.getRect(scroll);
    final titleBounds = tester.getRect(title);
    expect(titleBounds.left, greaterThanOrEqualTo(bounds.left));
    expect(titleBounds.right, lessThanOrEqualTo(bounds.right));
    await tester.ensureVisible(_button('进入帖子'));
    await _frames(tester);
    expect(_button('进入帖子').hitTestable(), findsOneWidget);
    expect(fixture.native.named('reader.open'), isEmpty);
    expect(fixture.native.previews, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
