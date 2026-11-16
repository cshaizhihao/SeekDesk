import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

Finder get _composerBody => find.byKey(const ValueKey('inbox-composer-body'));
bool _bodyEditable(WidgetTester tester) {
  final field = tester.widget<CupertinoTextField>(_composerBody);
  return field.enabled != false && !field.readOnly;
}

const _boundsKey = ValueKey('inbox-layout-fixture-bounds');
const _longName = '这是一个需要完整提示但不能挤走日期的很长用户名 Long display name';
const _summary =
    '这是用于布局测试的主题摘要。它需要超过两行才能完整展示，以确认通知列表不会因为长内容不断长高。'
    ' This is a long local fixture summary with additional context.';
const _date = '2026-06-04T11:07:08';
const _fullDate = '2026年6月4日 11:07:08（本地时间）';
const _incoming = 'Incoming plain message with selectable content.';
const _outgoing = 'Outgoing plain message with selectable content.';

/// All reads are local values. No test in this file may acknowledge a notice,
/// save a draft, send a message, open a topic or reach the platform service.
class _InboxLayoutNative extends NativeClient {
  _InboxLayoutNative()
    : super(methods: const MethodChannel('seekdesk.test.inbox-layout'));

  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  JsonMap unread = {'mentions': 0, 'replies': 0, 'messages': 0};

  JsonMap get session => {
    'account': 'signedIn',
    'owner': 101,
    'accessRevision': accessRevision,
    'unread': {...unread},
    'profile': {'id': 101, 'name': 'Local owner', 'avatar': ''},
  };

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  void publishUnread(int count) {
    unread = {'mentions': count, 'replies': count, 'messages': count};
    eventStream.add({
      'domain': 'session',
      'accessRevision': accessRevision,
      'data': session,
    });
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'bootstrap') return {'session': session};
    if (method == 'images.draftReferences' &&
        arguments.length == 1 &&
        arguments['content'] == '') {
      return {
        'content': '',
        'imageURLs': <String>[],
        'accessRevision': accessRevision,
      };
    }
    if (method == 'inbox.load') {
      final kind = stringValue(arguments['kind']);
      final peer = arguments['peer'];
      if (const [
        'mentions',
        'replies',
        'messages',
        'conversation',
      ].contains(kind)) {
        return {
          'kind': kind,
          'peer': ?peer,
          'accessRevision': accessRevision,
          'loading': false,
          'draft': '',
          'items': kind == 'conversation'
              ? [
                  {
                    'id': 'message-1',
                    'text': _incoming,
                    'mine': false,
                    'markdown': false,
                    // Real conversation DTOs may include an empty peerName.
                    'peerName': '',
                    'date': _date,
                  },
                  {
                    'id': 'message-2',
                    'text': _outgoing,
                    'mine': true,
                    'markdown': false,
                    'date': _date,
                  },
                ]
              : [
                  {
                    'id': 20,
                    'name': _longName,
                    'author': _longName,
                    'title': _summary,
                    'preview': _summary,
                    'avatar': '',
                    'unread': false,
                    'date': _date,
                    'url': 'https://www.nodeseek.com/post-9900001-1',
                  },
                ],
        };
      }
    }
    unexpected.add('$method $arguments');
    throw StateError('Read-only inbox layout fixture rejected $method');
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<_InboxLayoutNative> _mount(
  WidgetTester tester, {
  required double width,
  double textScale = 1,
  bool conversation = false,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1200));
  final native = _InboxLayoutNative();
  final state = AppState(client: native);
  await state.connect();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await native.eventStream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(
      native.calls.every(
        (call) => const [
          'bootstrap',
          'inbox.load',
          'images.draftReferences',
        ].contains(call.$1),
      ),
      isTrue,
      reason:
          'Visual checks must never consume unread or perform forum writes.',
    );
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        theme: CupertinoThemeData(
          brightness: brightness,
          textTheme: const CupertinoTextThemeData(
            textStyle: DeskTypography.base,
          ),
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  key: _boundsKey,
                  width: width,
                  height: 1080,
                  child: InboxScreen(
                    state: state,
                    initialPeer: conversation ? 20 : null,
                    peerName: conversation ? _longName : '',
                    standalone: conversation,
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
  return native;
}

Finder get _header => find.byKey(const ValueKey('inbox-header'));
Finder get _categories => find.byKey(const ValueKey('inbox-categories'));
Finder get _shell {
  final conversation = find.byKey(const ValueKey('inbox-conversation-surface'));
  return conversation.evaluate().isNotEmpty
      ? conversation
      : find.byKey(const ValueKey('inbox-category-surface'));
}

Finder get _composer => find.byKey(const ValueKey('inbox-composer-row'));
Finder get _contact => find.byKey(const ValueKey('inbox-contact-header'));

void _inside(WidgetTester tester, Finder finder, Rect bounds) {
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
  expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
}

void _expectNoticeTextContract(WidgetTester tester, double textScale) {
  final name = tester.widget<Text>(find.text(_longName));
  expect(name.maxLines, 1);
  expect(name.overflow, TextOverflow.ellipsis);
  final summary = tester.widget<Text>(find.text(_summary));
  expect(summary.maxLines, 2);
  expect(summary.overflow, TextOverflow.ellipsis);
  expect(
    MediaQuery.textScalerOf(tester.element(find.text(_longName))).scale(13),
    closeTo(13 * textScale, .01),
    reason: 'Narrow layouts must not defeat the requested text scale.',
  );
  expect(
    find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == _longName,
    ),
    findsOneWidget,
  );
  expect(
    find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == _fullDate,
    ),
    findsOneWidget,
  );
  expect(
    find.byWidgetPredicate(
      (widget) => widget is Text && widget.semanticsLabel == _fullDate,
    ),
    findsOneWidget,
  );
  final avatars = find.byType(NativeAvatar);
  expect(avatars, findsOneWidget);
  expect(tester.getSize(avatars), const Size(32, 32));
  expect(
    tester.getTopLeft(find.text(_longName)).dx,
    closeTo(tester.getTopLeft(find.text(_summary)).dx, .01),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop inbox has compact glass navigation and aligned notice content',
    (tester) async {
      final native = await _mount(tester, width: 1100);
      final header = tester.getRect(_header);
      expect(header.height, inInclusiveRange(56.0, 64.0));
      expect(tester.widget(_categories), isA<GlassSegmentedControl>());
      _inside(tester, _categories, tester.getRect(find.byKey(_boundsKey)));
      _expectNoticeTextContract(tester, 1);
      expect(
        tester.getTopLeft(find.text('通知')).dx,
        closeTo(tester.getTopLeft(find.byType(NativeAvatar)).dx, 1.5),
        reason: 'Heading and avatar use one left axis, allowing the document border.',
      );
      expect(
        native.calls.where((call) => call.$1 == 'inbox.load'),
        hasLength(1),
      );
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'narrow inbox preserves long names and text scale $scale without overflow',
      (tester) async {
        final native = await _mount(tester, width: 360, textScale: scale);
        expect(tester.getSize(_header).height, greaterThan(64));
        final bounds = tester.getRect(find.byKey(_boundsKey));
        _inside(tester, _header, bounds);
        _inside(tester, _shell, bounds);
        _expectNoticeTextContract(tester, scale);
        final strip = find.descendant(
          of: _header,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          ),
        );
        expect(strip, findsOneWidget);
        _inside(tester, strip, bounds);
        final reads = native.calls.length;
        // Desktop horizontal wheel/trackpad input must reach a clipped category
        // without dragging the segmented control's own selection lens.
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(strip),
            scrollDelta: const Offset(1000, 0),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await _frames(tester);
        expect(find.text('私信').hitTestable(), findsOneWidget);
        expect(native.calls, hasLength(reads));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unread counts through 99+ preserve header geometry and glass state',
    (tester) async {
      final native = await _mount(tester, width: 620, textScale: 1.5);
      final headerRect = tester.getRect(_header);
      final controlRect = tester.getRect(_categories);
      final controlState = tester.state(_categories);
      for (final count in [1, 99, 1000]) {
        native.publishUnread(count);
        await _frames(tester);
        expect(tester.getRect(_header), headerRect);
        expect(tester.getRect(_categories), controlRect);
        expect(tester.state(_categories), same(controlState));
        final control = tester.widget<GlassSegmentedControl>(_categories);
        expect(control.segments.map((segment) => segment.label), [
          '@我 ${count > 99 ? '99+' : count}',
          '回复主题 ${count > 99 ? '99+' : count}',
          '私信 ${count > 99 ? '99+' : count}',
        ]);
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final sample in [(1200.0, 1.0), (420.0, 2.0)]) {
    testWidgets(
      'conversation and composer share the reading axis at ${sample.$1} / ${sample.$2}x',
      (tester) async {
        final native = await _mount(
          tester,
          width: sample.$1,
          textScale: sample.$2,
          conversation: true,
          brightness: Brightness.dark,
        );
        final shell = tester.getRect(_shell);
        final composer = tester.getRect(_composer);
        final contact = tester.getRect(_contact);
        final expectedWidth = sample.$1 >= 860 ? 820.0 : sample.$1 - 40;
        expect(shell.width, closeTo(expectedWidth, .01));
        expect(composer.width, closeTo(shell.width, .01));
        expect(composer.left, closeTo(shell.left, .01));
        expect(composer.right, closeTo(shell.right, .01));
        expect(contact.center.dx, closeTo(shell.center.dx, .01));
        final bounds = tester.getRect(find.byKey(_boundsKey));
        for (final finder in [_shell, _composer, _contact]) {
          _inside(tester, finder, bounds);
        }
        expect(find.text(_incoming), findsOneWidget);
        expect(find.text(_outgoing), findsOneWidget);
        expect(find.text(_longName), findsNWidgets(2));
        expect(find.text('NodeSeek 用户'), findsNothing);
        for (final text in [_incoming, _outgoing]) {
          expect(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(ForumTextSelection),
            ),
            findsOneWidget,
          );
        }
        final avatars = find.byType(NativeAvatar);
        expect(avatars, findsNWidgets(3));
        for (var index = 0; index < 3; index++) {
          expect(tester.getSize(avatars.at(index)), const Size(30, 30));
        }
        final name = find.descendant(
          of: _contact,
          matching: find.text(_longName),
        );
        expect(tester.widget<Text>(name).maxLines, 1);
        expect(_bodyEditable(tester), isTrue);
        expect(tester.takeException(), isNull);
        expect(
          native.calls
              .where((call) => call.$1 == 'inbox.load')
              .map((call) => call.$2['kind']),
          ['conversation'],
          reason: 'An explicit peer window must not read an unrelated category list.',
        );
        expect(find.byKey(const ValueKey('inbox-pane-divider')), findsNothing);
      },
    );
  }
}
