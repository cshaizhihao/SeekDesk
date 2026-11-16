import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _aURL = 'https://www.nodeseek.com/post-17-1';
const _bURL = 'https://www.nodeseek.com/post-18-1';
const _anchorURL = '$_aURL#comment-35';

/// This fake exposes only local workspace/read/position operations. It never
/// contacts the forum, loads remote media, or accepts publication operations.
class _PositionNative extends NativeClient {
  _PositionNative({String firstURL = _aURL}) : aURL = firstURL;

  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final offsets = <(int, String), double>{};
  String aURL;
  String selected = '17';
  bool showReader = true;
  JsonMap? initialBodyAnchor;

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  JsonMap get workspace => {
    'tabs': [
      {'id': '17', 'url': aURL, 'title': 'Position A'},
      {'id': '18', 'url': _bURL, 'title': 'Position B'},
    ],
    'selectedTab': selected,
    'showReader': showReader,
    'posts': <JsonMap>[],
    'boards': <JsonMap>[],
  };

  JsonMap snapshot(String url) {
    final page = url.split('#').first;
    final name = page == _aURL ? 'A' : 'B';
    return {
      'url': url,
      'accessRevision': accessRevision,
      'loading': false,
      'scrollOffset': offsets[(accessRevision, page)] ?? 0.0,
      if (initialBodyAnchor != null) 'bodyAnchor': initialBodyAnchor,
      'thread': {
        'title': 'Reader $name',
        'root': {
          'id': '0',
          'author': 'Root $name',
          'blocks': [
            {'kind': 'text', 'text': 'Opening paragraph $name'},
          ],
        },
        'replies': [
          for (var index = 1; index <= 60; index++)
            {
              'id': '$index',
              'author': 'Author $name $index',
              'blocks': [
                {'kind': 'text', 'text': 'Reply $name $index'},
                {
                  'kind': 'text',
                  'text':
                      'Stable paragraph $name $index. '
                      'A text-only fixture keeps image and font reflow out '
                      'of the position lifecycle assertions.',
                },
              ],
            },
        ],
        'pages': <JsonMap>[],
      },
    };
  }

  Iterable<JsonMap> get saves => calls
      .where((entry) => entry.$1 == 'reader.rememberPosition')
      .map((entry) => entry.$2);

  int loadCount(String url) => calls
      .where(
        (entry) =>
            entry.$1 == 'reader.load' &&
            stringValue(entry.$2['url']).split('#').first ==
                url.split('#').first,
      )
      .length;

  void switchAccount() {
    final revision = accessRevision + 1;
    eventsController.add({
      'domain': 'session',
      'accessRevision': revision,
      'data': {
        'account': 'signedIn',
        'owner': revision + 1,
        'accessRevision': revision,
      },
    });
  }

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    // NativeClient.call injects the live revision at dispatch. Preserve that
    // behavior here so an old Reader cannot hide a cross-account save.
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 1,
            'accessRevision': accessRevision,
          },
          'workspace': workspace,
          'settings': {'appearance': 'light'},
          'extensions': {'items': <JsonMap>[]},
        };
      case 'reader.load':
        return snapshot(stringValue(args['url']));
      case 'reader.select':
        selected = stringValue(args['id']);
        showReader = true;
        return workspace;
      case 'reader.open':
        final url = stringValue(args['url']);
        if (url.split('#').first == _aURL) {
          aURL = url;
          selected = '17';
        } else {
          selected = '18';
        }
        showReader = true;
        return workspace;
      case 'reader.overview':
        showReader = false;
        return workspace;
      case 'reader.rememberPosition':
        final offset = numberValue(args['offset']);
        offsets[(accessRevision, stringValue(args['url']).split('#').first)] =
            offset;
        return {'saved': true, 'scrollOffset': offset};
      default:
        throw StateError('Unexpected operation in read-only fixture: $method');
    }
  }
}

class _PositionFixture {
  _PositionFixture(this.native) : state = AppState(client: native);
  final _PositionNative native;
  final AppState state;
  final bucket = PageStorageBucket();
}

Finder get _readerScroll => find.descendant(
  of: find.byType(ReaderScreen),
  matching: find.byType(CustomScrollView),
);

ScrollController _controller(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_readerScroll).controller!;

Future<void> _frames(WidgetTester tester, [int count = 3]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _withWorkspace(
  WidgetTester tester,
  Future<void> Function(_PositionFixture value) body, {
  String firstURL = _aURL,
  int initialFrames = 4,
  JsonMap? bodyAnchor,
}) async {
  final value = _PositionFixture(_PositionNative(firstURL: firstURL));
  value.native.initialBodyAnchor = bodyAnchor;
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  try {
    await value.state.connect();
    value.state.readers[_aURL] = value.native.snapshot(firstURL);
    value.state.readers[_bURL] = value.native.snapshot(_bURL);
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: PageStorage(
            bucket: value.bucket,
            child: WorkspaceScreen(state: value.state),
          ),
        ),
      ),
    );
    await _frames(tester, initialFrames);
    await body(value);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    value.state.dispose();
    await value.native.eventsController.close();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  }
}

Future<double> _wheel(WidgetTester tester, double delta) async {
  final previous = _controller(tester).offset;
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(_readerScroll),
      scrollDelta: Offset(0, delta),
      kind: PointerDeviceKind.mouse,
    ),
  );
  await tester.pump();
  final next = _controller(tester).offset;
  expect(
    next,
    greaterThan(previous),
    reason: 'The fixture must exercise a real downward mouse-wheel event.',
  );
  return next;
}

Future<void> _select(
  WidgetTester tester,
  _PositionFixture value,
  String id,
) async {
  await value.state.selectTopic(
    value.state.workspace.tabs.singleWhere((topic) => topic.id == id),
  );
  await _frames(tester);
}

Future<void> _waitForFloor(WidgetTester tester, int floor) async {
  for (var frame = 0; frame < 180; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.text('Reply A $floor').hitTestable().evaluate().isNotEmpty) {
      return;
    }
  }
  expect(
    find.text('Reply A $floor').hitTestable(),
    findsOneWidget,
    reason: 'The requested floor must be reached within a bounded seek.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a real wheel input cancels an in-flight explicit floor restore',
    (tester) async {
      await _withWorkspace(
        tester,
        (value) async {
          final chosen = await _wheel(tester, 110);
          await _frames(tester, 100);
          expect(_controller(tester).offset, closeTo(chosen, 1));
          expect(find.text('Reply A 35').hitTestable(), findsNothing);
          expect(value.state.readerOffset(_anchorURL), closeTo(chosen, 1));
        },
        firstURL: _anchorURL,
        initialFrames: 0,
      );
    },
  );

  testWidgets(
    'a distant body anchor from zero schedules its own search frames',
    (tester) async {
      await _withWorkspace(
        tester,
        (value) async {
          expect(
            tester.binding.hasScheduledFrame,
            isTrue,
            reason: 'A no-op jumpTo(0) must not leave restoration waiting for user input.',
          );
          await _waitForFloor(tester, 50);
          await _frames(tester);
          expect(find.text('Reply A 50').hitTestable(), findsOneWidget);
          expect(value.state.readerBodyAnchor(_aURL), isNotNull);
        },
        bodyAnchor: {'floor': '50', 'dy': 140.0},
        initialFrames: 0,
      );
    },
  );

  testWidgets(
    'a real wheel input cancels a distant saved body anchor restore',
    (tester) async {
      await _withWorkspace(
        tester,
        (value) async {
          final chosen = await _wheel(tester, 110);
          await _frames(tester, 100);
          expect(_controller(tester).offset, closeTo(chosen, 1));
          expect(find.text('Reply A 50').hitTestable(), findsNothing);
          expect(value.state.readerOffset(_aURL), closeTo(chosen, 1));
        },
        bodyAnchor: {'floor': '50', 'dy': 140.0},
        initialFrames: 0,
      );
    },
  );

  for (final overview in [false, true]) {
    for (final timerSaved in [false, true]) {
      testWidgets(
        '${overview ? 'A overview A' : 'A B A'} retains wheel position '
        '${timerSaved ? 'after debounce saved' : 'when disposed before debounce'}',
        (tester) async {
          await _withWorkspace(tester, (value) async {
            final first = _controller(tester);
            final expected = await _wheel(tester, 1450);
            if (timerSaved) {
              await tester.pump(const Duration(milliseconds: 650));
              expect(value.native.saves, isNotEmpty);
              expect(value.native.saves.last['offset'], closeTo(expected, 1));
            } else {
              expect(
                value.native.saves,
                isEmpty,
                reason: 'No 600 ms save may have fired before leaving A.',
              );
            }
            final loads = value.native.loadCount(_aURL);
            if (overview) {
              await tester.tap(
                find.byWidgetPredicate(
                  (widget) => widget is DeskButton && widget.label == '返回总览',
                ),
              );
              await _frames(tester);
              expect(find.byType(ReaderScreen), findsNothing);
            } else {
              await _select(tester, value, '18');
              expect(
                tester.widget<ReaderScreen>(find.byType(ReaderScreen)).topic.id,
                '18',
              );
            }
            await _select(tester, value, '17');
            expect(
              _controller(tester),
              isNot(same(first)),
              reason: 'This must exercise actual Reader disposal/recreation.',
            );
            expect(
              _controller(tester).offset,
              closeTo(expected, 1),
              reason: 'A cached DTO must not replace the latest local offset.',
            );
            expect(
              value.native.loadCount(_aURL),
              loads,
              reason: 'Returning to a cached tab should not need a reload.',
            );
            expect(tester.takeException(), isNull);
          });
        },
      );
    }
  }

  testWidgets(
    'an existing stale PageStorage entry cannot outrank a newer wheel position',
    (tester) async {
      await _withWorkspace(tester, (value) async {
        final expected = await _wheel(tester, 1450);
        await tester.pump(const Duration(milliseconds: 650));
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(of: _readerScroll, matching: find.byType(Scrollable))
              .first,
        );
        final storageContext = scrollable.context;
        expect(PageStorage.of(storageContext), same(value.bucket));
        value.bucket.writeState(storageContext, 210.0);
        expect(value.bucket.readState(storageContext), 210.0);
        await _select(tester, value, '18');
        await _select(tester, value, '17');
        expect(
          _controller(tester).offset,
          closeTo(expected, 1),
          reason:
              'PageStorage is an older fallback, not the latest read state.',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'a notification fragment is consumed once and tab return preserves later reading',
    (tester) async {
      await _withWorkspace(tester, (value) async {
        await _waitForFloor(tester, 35);
        final anchored = _controller(tester).offset;
        // A completed explicit seek is itself a useful local return position,
        // even before the user has moved the wheel or the debounce has fired.
        await _select(tester, value, '18');
        await _select(tester, value, '17');
        await _frames(tester, 100);
        expect(
          _controller(tester).offset,
          closeTo(anchored, 1),
          reason: 'Consuming the fragment must retain its resolved position.',
        );
        final expected = await _wheel(tester, 1450);
        expect(expected, greaterThan(anchored + 1000));
        expect(find.text('Reply A 35').hitTestable(), findsNothing);
        await tester.pump(const Duration(milliseconds: 650));
        await _select(tester, value, '18');
        await _select(tester, value, '17');
        // Allow a wrongly restarted seek to finish, rather than merely observing
        // an intermediate scan position or the loading cover.
        await _frames(tester, 100);
        expect(_controller(tester).offset, closeTo(expected, 1));
        expect(find.text('Reply A 35').hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      }, firstURL: _anchorURL);
    },
  );

  testWidgets(
    'explicitly opening the same URL and fragment again creates a new floor request',
    (tester) async {
      await _withWorkspace(tester, (value) async {
        await _waitForFloor(tester, 35);
        final anchored = _controller(tester).offset;
        await _wheel(tester, 1450);
        expect(find.text('Reply A 35').hitTestable(), findsNothing);
        await value.state.openTopic(
          TopicData({'id': '17', 'url': _anchorURL, 'title': 'Position A'}),
        );
        await _waitForFloor(tester, 35);
        expect(_controller(tester).offset, closeTo(anchored, 2));
        expect(
          value.native.calls
              .where((entry) => entry.$1 == 'reader.open')
              .single
              .$2['url'],
          _anchorURL,
        );
        expect(tester.takeException(), isNull);
      }, firstURL: _anchorURL);
    },
  );

  testWidgets(
    'account notification cannot relabel an old Reader offset before its disposal',
    (tester) async {
      await _withWorkspace(tester, (value) async {
        final oldReader = tester.state(find.byType(ReaderScreen));
        final oldOffset = await _wheel(tester, 1450);
        expect(value.native.saves, isEmpty);
        value.native.switchAccount();
        expect(value.state.accessRevision, 1);
        await _frames(tester);
        expect(tester.state(find.byType(ReaderScreen)), isNot(same(oldReader)));
        expect(
          value.native.saves.where(
            (args) =>
                args['accessRevision'] == 1 &&
                (numberValue(args['offset']) - oldOffset).abs() < 1,
          ),
          isEmpty,
          reason: 'Disposal must not write account A position into account B.',
        );
        expect(value.native.offsets[(1, _aURL)], isNull);
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          value.native.offsets[(1, _aURL)],
          isNull,
          reason: 'The old 600 ms timer must also be invalidated.',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  for (final accountChange in [false, true]) {
    testWidgets(
      'an in-flight floor seek stops when ${accountChange ? 'the account changes' : 'its Reader is disposed'}',
      (tester) async {
        await _withWorkspace(
          tester,
          (value) async {
            expect(find.text('Reply A 35').hitTestable(), findsNothing);
            final retired = _controller(tester).position;
            final moves = <double>[];
            retired.addListener(() => moves.add(retired.pixels));
            if (accountChange) {
              value.native.switchAccount();
              await _frames(tester);
              expect(value.state.accessRevision, 1);
            } else {
              await _select(tester, value, '18');
            }
            expect(
              moves,
              isEmpty,
              reason:
                  'Invalidation must stop the old seek before another jump.',
            );
            final countAfterDisposal = moves.length;
            await _frames(tester, 110);
            expect(
              moves.length,
              countAfterDisposal,
              reason: 'The retired restore must not resume on a later frame.',
            );
            expect(
              value.native.saves.where(
                (args) => stringValue(args['url']).split('#').first == _aURL,
              ),
              isEmpty,
              reason: 'Seeking alone is not an observed user reading position.',
            );
            expect(tester.takeException(), isNull);
          },
          firstURL: _anchorURL,
          initialFrames: 1,
        );
      },
    );
  }
}
