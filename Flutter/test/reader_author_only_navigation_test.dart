// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const _page = 'https://www.nodeseek.com/post-72001-1';
const _retainedURL = '$_page#comment-35';
const _rootAuthor = 'Fixture root author';
const _targetBody = 'Author-only reply 35';

enum _TargetAuthor { other, authorFlag, sameName }

JsonMap _topic() => {
  'id': '72001',
  'url': _retainedURL,
  'title': 'Author-only fragment fixture',
};

/// Only local workspace, reader and position operations are accepted. The
/// fixture has no remote media, author-profile requests or publication paths.
class _AuthorOnlyNative extends NativeClient {
  _AuthorOnlyNative(this.targetAuthor)
    : super(
        methods: const MethodChannel('seekdesk.test.author-only-navigation'),
      );

  final _TargetAuthor targetAuthor;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];

  JsonMap get workspace => {
    'tabs': [_topic()],
    'selectedTab': '72001',
    'showReader': true,
  };

  JsonMap get snapshot => {
    'url': _retainedURL,
    'accessRevision': accessRevision,
    'loading': false,
    'scrollOffset': 0.0,
    'authorProfilesSupported': false,
    'thread': {
      'title': 'Author-only fragment fixture',
      'root': {
        'id': '0',
        'author': _rootAuthor,
        'authorID': 1,
        'blocks': [
          {'kind': 'text', 'text': 'Author-only root paragraph'},
        ],
      },
      'replies': [
        for (var floor = 1; floor <= 45; floor++)
          {
            'id': '$floor',
            'author': floor == 35
                ? targetAuthor == _TargetAuthor.sameName
                      ? _rootAuthor
                      : 'Target author'
                : floor % 3 == 0
                ? _rootAuthor
                : 'Fixture author $floor',
            'isAuthor': floor == 35
                ? targetAuthor == _TargetAuthor.authorFlag
                : floor % 3 == 0,
            'blocks': [
              {'kind': 'text', 'text': 'Author-only reply $floor'},
              {
                'kind': 'text',
                'text':
                    'A local paragraph keeps the requested reply outside the '
                    'initial viewport, including when only the original '
                    'author remains visible.',
              },
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  Iterable<JsonMap> get saves => calls
      .where((entry) => entry.$1 == 'reader.rememberPosition')
      .map((entry) => entry.$2);

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    if (arguments['url'] == _retainedURL) {
      switch (method) {
        case 'reader.open':
          return workspace;
        case 'reader.load':
          return snapshot;
        case 'reader.rememberPosition':
          return {'saved': true};
      }
    }
    unexpected.add(method);
    throw StateError('Unexpected author-only fixture operation: $method');
  }
}

class _PagedAuthorNative extends _AuthorOnlyNative {
  _PagedAuthorNative() : super(_TargetAuthor.other);

  final pagesRead = <int>[];

  JsonMap page(int number) {
    final original = jsonMap(super.snapshot['thread']);
    return {
      ...original,
      'page': number,
      'root': number == 1 ? original['root'] : null,
      'pages': [
        if (number == 1)
          {'number': 3, 'url': 'https://www.nodeseek.com/post-72001-3'},
      ],
      'replies': [
        for (final (id, member) in [(number * 10, 1), (number * 10 + 1, 2)])
          {
            'id': '$id',
            'author': _rootAuthor,
            'authorID': member,
            'blocks': [
              {'kind': 'text', 'text': 'Page $number member $member'},
            ],
          },
      ],
    };
  }

  @override
  JsonMap get snapshot => {...super.snapshot, 'thread': page(1)};

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    if (method != 'reader.authorPage') return super.call(method, arguments);
    final number = arguments['page']! as int;
    pagesRead.add(number);
    return Future.value({
      'thread': page(number),
      'accessRevision': accessRevision,
    });
  }
}

Finder get _reader => find.byType(ReaderScreen);

ScrollController _controller(WidgetTester tester) => tester
    .widget<CustomScrollView>(
      find.descendant(of: _reader, matching: find.byType(CustomScrollView)),
    )
    .controller!;

Future<void> _completeSeek(WidgetTester tester, AppState state) async {
  for (var frame = 0; frame < 180; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (state.readerNavigation(_page) == null) break;
  }
  expect(state.readerNavigation(_page), isNull);
  // Navigation is consumed just before the completed seek rebuild. Observe
  // the document after its temporary pending-floor exemption is removed.
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(find.byType(CupertinoActivityIndicator), findsNothing);
}

Future<void> _reopenSameFragment(
  WidgetTester tester,
  _TargetAuthor targetAuthor,
) async {
  final native = _AuthorOnlyNative(targetAuthor);
  final state = AppState(client: native)..connecting = false;
  state.domains['workspace'] = native.workspace;
  state.domains['session'] = {'account': 'signedOut'};
  state.domains['settings'] = {
    'workspace.readerTextSize': 15.0,
    'workspace.floorAuthorScale': 100.0,
    'workspace.readingDensity': 'comfortable',
  };
  state.domains['extensions'] = {
    'items': [
      {'id': 'authorOnly', 'active': true},
    ],
  };
  state.readers[_page] = native.snapshot;

  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });

  await state.openTopic(TopicData(_topic()));
  final firstNavigation = state.readerNavigation(_page)!;
  expect(firstNavigation.floor, '35');
  await tester.binding.setSurfaceSize(const Size(900, 720));
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: GlassAccessibilityScope(
          reduceMotion: true,
          child: CupertinoPageScaffold(
            child: ListenableBuilder(
              listenable: state,
              builder: (context, child) {
                final topic = state.workspace.selected!;
                return ReaderScreen(
                  // Match WorkspaceScreen identity: reopening the exact URL
                  // must retain this reader and its existing author filter.
                  key: ValueKey(
                    '${state.accessRevision}:${state.readerPositionEpoch}:${topic.url}',
                  ),
                  state: state,
                  topic: topic,
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await _completeSeek(tester, state);
  expect(find.text(_targetBody).hitTestable(), findsOneWidget);
  final readerElement = tester.element(_reader);
  final readerState = tester.state(_reader);
  final controller = _controller(tester);
  expect(controller.offset, greaterThan(0));

  controller.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.tap(find.text('只看楼主'));
  await tester.pumpAndSettle();
  expect(find.text('查看全部'), findsOneWidget);
  expect(find.text(_targetBody).hitTestable(), findsNothing);

  await state.openTopic(TopicData(_topic()));
  final repeatedNavigation = state.readerNavigation(_page)!;
  expect(state.workspace.selected!.url, _retainedURL);
  expect(repeatedNavigation.floor, '35');
  expect(repeatedNavigation.sequence, greaterThan(firstNavigation.sequence));
  expect(tester.element(_reader), same(readerElement));
  expect(tester.state(_reader), same(readerState));
  await _completeSeek(tester, state);

  expect(tester.element(_reader), same(readerElement));
  expect(tester.state(_reader), same(readerState));
  expect(_controller(tester), same(controller));
  expect(
    find.text(_targetBody).hitTestable(),
    findsOneWidget,
    reason: 'The explicit target must remain visible after seeking completes.',
  );
  final settledOffset = controller.offset;
  expect(settledOffset.isFinite, isTrue);
  expect(
    settledOffset,
    inInclusiveRange(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    ),
  );
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump();
  expect(find.text(_targetBody).hitTestable(), findsOneWidget);
  expect(controller.offset, closeTo(settledOffset, .01));
  expect(state.readerOffset(_page), closeTo(settledOffset, .01));
  expect(tester.element(_reader), same(readerElement));
  expect(state.readerNavigation(_page), isNull);
  expect(native.saves, isNotEmpty);
  expect(native.saves.last['offset'], closeTo(settledOffset, .01));
  expect(jsonMap(native.saves.last['bodyAnchor'])['floor'], '35');
  expect(
    native.calls
        .where((entry) => entry.$1 == 'reader.open')
        .map((entry) => entry.$2['url']),
    [_retainedURL, _retainedURL],
  );

  // Check the filter control after the target has stayed visible through its
  // position save. The header is offscreen while the distant target is shown.
  controller.jumpTo(0);
  await tester.pumpAndSettle();
  expect(
    find
        .text(targetAuthor == _TargetAuthor.other ? '只看楼主' : '查看全部')
        .hitTestable(),
    findsOneWidget,
  );
  expect(tester.element(_reader), same(readerElement));
  expect(tester.state(_reader), same(readerState));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'built-in author filter fills pagination gaps and uses author identity',
    (tester) async {
      final native = _PagedAuthorNative();
      final state = AppState(client: native)..connecting = false;
      state.readers[_page] = native.snapshot;
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        CupertinoApp(
          home: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: ReaderScreen(state: state, topic: TopicData(_topic())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 1 member 2'), findsOneWidget);
      await tester.tap(find.text('只看楼主'));
      await tester.pumpAndSettle();
      expect(native.pagesRead, [2, 3]);
      expect(find.text('Page 1 member 1'), findsOneWidget);
      expect(find.text('Page 2 member 1'), findsOneWidget);
      expect(find.text('Page 3 member 1'), findsOneWidget);
      expect(find.textContaining('member 2'), findsNothing);
      expect(find.text('查看原楼层'), findsNWidgets(2));
      await tester.tap(find.text('查看全部'));
      await tester.pumpAndSettle();
      expect(find.text('Page 1 member 2'), findsOneWidget);
      expect(find.text('Page 2 member 1'), findsNothing);
      expect(state.readerFor(_page)['thread'], native.page(1));
    },
  );

  testWidgets(
    'reopening the same fragment reveals a reply hidden by author-only mode',
    (tester) => _reopenSameFragment(tester, _TargetAuthor.other),
  );

  testWidgets(
    'reopening the same fragment keeps author-only mode for an author-marked reply',
    (tester) => _reopenSameFragment(tester, _TargetAuthor.authorFlag),
  );

  testWidgets(
    'reopening the same fragment keeps author-only mode for the root author name',
    (tester) => _reopenSameFragment(tester, _TargetAuthor.sameName),
  );
}
