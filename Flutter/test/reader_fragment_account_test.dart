import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';

const _page = 'https://www.nodeseek.com/post-17-1';
const _retainedURL = '$_page#comment-35';

class _FragmentNative extends NativeClient {
  _FragmentNative()
    : super(
        methods: MethodChannel('seekdesk.test.fragment.account.${_channel++}'),
      );

  static int _channel = 0;
  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  String anchor = '';
  JsonMap workspace = {
    'tabs': [
      {'id': '17', 'url': _retainedURL, 'title': 'Retained fragment'},
      {
        'id': '18',
        'url': 'https://www.nodeseek.com/post-18-1',
        'title': 'Retained plain URL',
      },
    ],
    'selectedTab': '17',
    'showReader': true,
    'posts': <JsonMap>[],
    'boards': <JsonMap>[],
  };

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  JsonMap reader(String url) => {
    'url': url,
    'accessRevision': accessRevision,
    'scrollOffset': 0,
    'anchor': anchor,
    'thread': {
      'title': 'Fragment reader revision $accessRevision',
      'root': {
        'id': '0',
        'author': 'Fixture root',
        'blocks': [
          {'kind': 'text', 'text': 'Fragment root paragraph'},
        ],
      },
      'replies': [
        for (var floor = 1; floor <= 45; floor++)
          {
            'id': '$floor',
            'author': 'Fixture $floor',
            'blocks': [
              {'kind': 'text', 'text': 'Fragment reply $floor'},
              {
                'kind': 'text',
                'text': 'A local paragraph keeps the target outside the initial viewport.',
              },
            ],
          },
      ],
      'pages': <JsonMap>[],
    },
  };

  void account(int revision) => eventsController.add({
    'domain': 'session',
    'accessRevision': revision,
    'data': {
      'account': 'signedIn',
      'owner': revision + 1,
      'accessRevision': revision,
    },
  });

  void updateWorkspace(JsonMap value) {
    workspace = value;
    eventsController.add({
      'domain': 'workspace',
      'accessRevision': accessRevision,
      'data': workspace,
    });
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments, 'accessRevision': accessRevision}));
    switch (method) {
      case 'bootstrap':
        return {
          'workspace': workspace,
          'session': {'account': 'signedIn', 'owner': 1, 'accessRevision': 0},
          'settings': {'appearance': 'light'},
        };
      case 'reader.load':
        return reader(stringValue(arguments['url']));
      case 'reader.open':
        workspace = {
          ...workspace,
          'tabs': [
            for (final tab in jsonItems(workspace['tabs']))
              if (tab['id'] == '17') {...tab, 'url': arguments['url']} else tab,
          ],
        };
        return workspace;
      case 'reader.rememberPosition':
        return {'saved': true};
      default:
        throw StateError('Unexpected fragment fixture operation: $method');
    }
  }
}

Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

ScrollController _scroll(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_readerScroll).controller!;

Future<void> _mountReader(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(900, 720));
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(
          child: ReaderScreen(
            key: ValueKey(
              '${state.accessRevision}:${state.readerPositionEpoch}',
            ),
            state: state,
            topic: TopicData({'id': '17', 'url': _retainedURL}),
          ),
        ),
      ),
    ),
  );
}

Future<void> _waitForFloor(WidgetTester tester, int floor) async {
  for (var frame = 0; frame < 180; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.text('Fragment reply $floor').hitTestable().evaluate().isNotEmpty) {
      break;
    }
  }
  expect(find.text('Fragment reply $floor').hitTestable(), findsOneWidget);
}

Future<void> _unmountReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.binding.setSurfaceSize(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FragmentNative native;
  late AppState state;

  setUp(() async {
    native = _FragmentNative();
    state = AppState(client: native);
    await state.connect();
  });

  tearDown(() async {
    state.dispose();
    await native.eventsController.close();
  });

  test('initial URL fallback is allowed until a revision change retires retained canonical pages', () {
    final aliases = [
      _retainedURL,
      'https://nodeseek.com/post-17-1#35',
      '$_page/#comment-35',
      'https://nodeseek.com/post-17-1/?order=old#comment-35',
    ];
    for (final url in aliases) {
      expect(state.canRestoreReaderURLFragment(url), isTrue);
    }
    final tabs = state.workspace.tabs.map((topic) => topic.url).toList();
    native.account(1);
    for (final url in aliases) {
      expect(state.canRestoreReaderURLFragment(url), isFalse, reason: url);
    }
    expect(
      state.canRestoreReaderURLFragment(
        'https://nodeseek.com/post-18-1/#comment-4',
      ),
      isFalse,
    );
    expect(
      state.canRestoreReaderURLFragment(
        'https://www.nodeseek.com/post-17-2#35',
      ),
      isTrue,
    );
    expect(
      state.canRestoreReaderURLFragment(
        'https://www.nodeseek.com/post-19-1#35',
      ),
      isTrue,
    );
    expect(state.workspace.tabs.map((topic) => topic.url), tabs);
    expect(native.calls.map((call) => call.$1), ['bootstrap']);
  });

  test(
    'retired pages are rebuilt from the tabs retained at each new revision',
    () {
      native.account(1);
      expect(state.canRestoreReaderURLFragment(_retainedURL), isFalse);
      native.updateWorkspace({
        ...native.workspace,
        'tabs': [
          {'id': '19', 'url': 'https://www.nodeseek.com/post-19-1#12'},
        ],
        'selectedTab': '19',
      });
      native.account(2);
      expect(state.canRestoreReaderURLFragment(_retainedURL), isTrue);
      expect(
        state.canRestoreReaderURLFragment(
          'https://nodeseek.com/post-19-1/#comment-12',
        ),
        isFalse,
      );
      expect(
        state.canRestoreReaderURLFragment(
          'https://www.nodeseek.com/post-19-2#12',
        ),
        isTrue,
      );
      expect(native.calls.map((call) => call.$1), ['bootstrap']);
    },
  );

  testWidgets(
    'a first-open fragment with no prior account boundary still locates its floor',
    (tester) async {
      try {
        await state.loadReader(_retainedURL);
        await _mountReader(tester, state);
        await _waitForFloor(tester, 35);
        expect(_scroll(tester).offset, greaterThan(0));
        expect(state.canRestoreReaderURLFragment(_retainedURL), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountReader(tester);
      }
    },
  );

  testWidgets(
    'retained old-account fragments cannot seek or persist progress but an explicit new-account open can',
    (tester) async {
      try {
        await state.loadReader(_retainedURL);
        await _mountReader(tester, state);
        await _waitForFloor(tester, 35);
        native.account(1);
        await state.loadReader(_retainedURL);
        await _mountReader(tester, state);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('Fragment reader revision 1'), findsOneWidget);
        expect(_scroll(tester).offset, 0);
        expect(find.text('Fragment reply 35').hitTestable(), findsNothing);
        expect(state.readerOffset(_page), 0);
        expect(
          native.calls.where(
            (call) =>
                call.$1 == 'reader.rememberPosition' &&
                call.$2['accessRevision'] == 1,
          ),
          isEmpty,
        );

        await state.openTopic(
          TopicData({'id': '17', 'url': '$_page#comment-20'}),
        );
        await _waitForFloor(tester, 20);
        expect(_scroll(tester).offset, greaterThan(0));
        expect(state.canRestoreReaderURLFragment(_retainedURL), isFalse);
        expect(state.readerNavigation(_retainedURL), isNull);
        expect(
          native.calls
              .where((call) => call.$1 == 'reader.open')
              .single
              .$2['url'],
          '$_page#comment-20',
        );
        final position = _scroll(tester).offset;
        await tester.pump(const Duration(milliseconds: 800));
        expect(_scroll(tester).offset, closeTo(position, .01));
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountReader(tester);
      }
    },
  );

  testWidgets(
    'a new-account snapshot anchor remains usable when the retained URL fragment is retired',
    (tester) async {
      try {
        native.account(1);
        native.anchor = 'floor-12';
        await state.loadReader(_retainedURL);
        await _mountReader(tester, state);
        await _waitForFloor(tester, 12);
        expect(state.canRestoreReaderURLFragment(_retainedURL), isFalse);
        expect(find.text('Fragment reply 35').hitTestable(), findsNothing);
        expect(_scroll(tester).offset, greaterThan(0));
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountReader(tester);
      }
    },
  );
}
