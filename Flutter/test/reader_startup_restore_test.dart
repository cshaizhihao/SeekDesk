import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _ownerA = 101, _ownerB = 202;
const _page = 'https://www.nodeseek.com/post-1055415-71';
const _url = '$_page#707';
const _otherPage = 'https://www.nodeseek.com/post-1055415-1';
const _anchorA = {'floor': '705', 'dy': 18.0};
const _anchorB = {'floor': '709', 'dy': 32.0};

class _Read {
  _Read(this.arguments, this.ownerAtDispatch);
  final JsonMap arguments;
  final int? ownerAtDispatch;
  final response = Completer<JsonMap>();
}

class _Write {
  _Write(this.arguments, this.owner, this.nativeRevision, this.accepted);
  final JsonMap arguments;
  final int? owner;
  final int nativeRevision;
  final bool accepted;
}

/// Models the native boundary, not Flutter's implementation of restoration.
/// Positions are partitioned by owner/page; revisions independently authorize
/// requests. Pending reads can finish after native identity discovery and carry
/// the new revision, as NativeForumServices.loadReader does after its retry.
class _Native extends NativeClient {
  _Native({this.nativeOwner, this.nativeRevision = 0})
    : super(
        methods: MethodChannel('seekdesk.test.startup-position.${_next++}'),
      ) {
    positions[(_ownerA, _page)] = {
      'offset': 1194.0,
      'bodyAnchor': Map<String, dynamic>.of(_anchorA),
    };
    positions[(_ownerA, _otherPage)] = {
      'offset': 2050.25,
      'bodyAnchor': {'floor': '5', 'dy': 63.75},
    };
    positions[(_ownerB, _page)] = {
      'offset': 2200.0,
      'bodyAnchor': Map<String, dynamic>.of(_anchorB),
    };
  }

  static int _next = 0;
  int? nativeOwner;
  int nativeRevision;
  bool showReader = true;
  JsonMap? bootstrapSession;
  final settings = <String, dynamic>{
    'appearance': 'light',
    'workspace.hideListWhileReading': true,
    'workspace.mistBackdrop': false,
  };
  final stream = StreamController<JsonMap>.broadcast(sync: true);
  final positions = <(int?, String), JsonMap>{};
  final calls = <(String, JsonMap)>[];
  final reads = <_Read>[];
  final writes = <_Write>[];
  final unexpected = <String>[];

  @override
  Stream<JsonMap> get snapshots => stream.stream;

  JsonMap get workspace => {
    'tabs': [
      {'id': '1055415', 'url': _url, 'title': 'Startup position fixture'},
    ],
    'selectedTab': '1055415',
    'showReader': showReader,
    'posts': <JsonMap>[],
    'boards': <JsonMap>[],
  };

  JsonMap session({required int revision, required int? owner}) => {
    'account': revision == 0 && owner == null ? 'unconfirmed' : 'signedIn',
    'owner': owner,
    'accessRevision': revision,
    'canCompose': owner != null,
  };

  /// Native identity and delivery of a queued session event are independently
  /// controlled. confirmOwner publishes a transient owner=null before its final
  /// owner; delivery can trail a method result even after native owns A.
  void publishIdentity({
    required int revision,
    required int? owner,
    bool updateNative = true,
  }) {
    if (updateNative) {
      nativeRevision = revision;
      nativeOwner = owner;
    }
    stream.add({
      'domain': 'session',
      'accessRevision': revision,
      'data': session(revision: revision, owner: owner),
    });
  }

  void publishReadingSize(double size) {
    settings['workspace.readerTextSize'] = size;
    stream.add({
      'domain': 'settings',
      'accessRevision': nativeRevision,
      'data': Map<String, dynamic>.of(settings),
    });
  }

  JsonMap snapshot({int? owner, int? revision}) {
    final stored = positions[(owner ?? nativeOwner, _page)];
    return {
      'url': _url,
      'topicID': '1055415',
      'accessRevision': revision ?? nativeRevision,
      'loading': false,
      'scrollOffset': stored?['offset'] ?? 0.0,
      if (stored?['bodyAnchor'] != null)
        'bodyAnchor': Map<String, dynamic>.of(jsonMap(stored!['bodyAnchor'])),
      'authorProfilesSupported': false,
      'thread': {
        'title': 'Startup position fixture',
        'page': 71,
        'root': floor(701),
        'replies': [for (var id = 702; id <= 720; id++) floor(id)],
        'pages': <JsonMap>[],
      },
    };
  }

  JsonMap floor(int id) => {
    'id': '$id',
    'author': 'Fixture author $id',
    'authorID': id.isOdd ? _ownerA : _ownerB,
    'avatar': '',
    'blocks': [
      {'kind': 'text', 'text': 'Body floor $id'},
      {
        'kind': 'text',
        'text':
            'A stable text-only fixture paragraph for floor $id. '
            'The reader must preserve this body relative to its viewport '
            'while session identity and delayed native responses settle.',
      },
    ],
  };

  void complete(_Read read, {JsonMap? value}) {
    expect(read.response.isCompleted, false);
    read.response.complete(value ?? snapshot());
  }

  List<_Write> acceptedWrites(int owner) =>
      writes.where((write) => write.accepted && write.owner == owner).toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    final args = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, args));
    switch (method) {
      case 'bootstrap':
        return {
          'session':
              bootstrapSession ??
              session(revision: nativeRevision, owner: nativeOwner),
          'workspace': workspace,
          'settings': Map<String, dynamic>.of(settings),
          'extensions': {'items': <JsonMap>[]},
        };
      case 'reader.overview':
        showReader = false;
        return workspace;
      case 'reader.select':
        if (args['id'] != '1055415') break;
        showReader = true;
        return workspace;
      case 'reader.open':
        if (args['url'] != _url ||
            args['id'] != '1055415' ||
            args['background'] == true) {
          break;
        }
        showReader = true;
        return workspace;
      case 'reader.load':
        if (args['url'] != _url) break;
        final read = _Read(args, nativeOwner);
        reads.add(read);
        return read.response.future;
      case 'settings.update':
        final size = args['value'];
        if (args['key'] != 'workspace.readerTextSize' ||
            size is! num ||
            !size.isFinite ||
            size < 13 ||
            size > 24) {
          break;
        }
        settings['workspace.readerTextSize'] = size;
        return Map<String, dynamic>.of(settings);
      case 'reader.rememberPosition':
        if (args['url'] != _url || args['topicID'] != '1055415') break;
        final accepted = args['accessRevision'] == nativeRevision;
        writes.add(_Write(args, nativeOwner, nativeRevision, accepted));
        if (!accepted) {
          throw const NativeFailure(
            'stale_authorization',
            'Fixture identity changed',
          );
        }
        positions[(nativeOwner, _page)] = {
          'offset': args['offset'],
          if (args['bodyAnchor'] != null)
            'bodyAnchor': Map<String, dynamic>.of(jsonMap(args['bodyAnchor'])),
        };
        return {'saved': true, 'scrollOffset': args['offset']};
    }
    unexpected.add('$method $args');
    throw StateError('Unexpected startup position fixture operation: $method');
  }
}

class _Fixture {
  _Fixture(this.native) : state = AppState(client: native);
  final _Native native;
  final AppState state;
}

Finder get _reader => find.byType(ReaderScreen);
Finder get _readerScroll =>
    find.descendant(of: _reader, matching: find.byType(CustomScrollView));

ScrollController _controller(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_readerScroll).controller!;

Finder _floorContext(String id) => find.byWidgetPredicate(
  (widget) => widget is ReaderFloorContext && widget.floor.id == id,
);

Finder _body(WidgetTester tester, String id) {
  final floor = tester.widget<ReaderFloorContext>(_floorContext(id));
  return find.byKey(floor.body.key!);
}

double? _bodyDy(WidgetTester tester, String id) {
  if (_floorContext(id).evaluate().isEmpty ||
      _readerScroll.evaluate().isEmpty) {
    return null;
  }
  return tester.getTopLeft(_body(tester, id)).dy -
      tester.getTopLeft(_reader).dy;
}

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _ReadingDrag {
  _ReadingDrag(this.gesture);
  final TestGesture gesture;
  var timestamp = Duration.zero;
  var ended = false;

  Future<void> move(double dy) async {
    timestamp += const Duration(milliseconds: 40);
    await gesture.moveBy(Offset(0, dy), timeStamp: timestamp);
  }

  Future<void> end() async {
    if (ended) return;
    ended = true;
    for (var sample = 0; sample < 3; sample++) {
      timestamp += const Duration(milliseconds: 40);
      await gesture.moveBy(Offset.zero, timeStamp: timestamp);
    }
    await gesture.up(timeStamp: timestamp);
  }
}

Future<_ReadingDrag> _startReadingDrag(
  WidgetTester tester,
  PointerDeviceKind kind,
) async {
  final gesture = await tester.createGesture(kind: kind);
  final center = tester.getCenter(_readerScroll);
  if (kind == PointerDeviceKind.trackpad) {
    await gesture.panZoomStart(center);
  } else {
    await gesture.down(center);
  }
  final drag = _ReadingDrag(gesture);
  addTearDown(drag.end);
  return drag;
}

Future<_Fixture> _mount(WidgetTester tester, _Native native) async {
  final f = _Fixture(native);
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.state.dispose();
    for (final read in native.reads) {
      if (!read.response.isCompleted) read.response.complete({});
    }
    await _frames(tester);
    await native.stream.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await f.state.connect();
  // WorkspaceScreen is the production destination inside SeekDeskApp. Keeping
  // its real AppState listener, reader key, post-frame load and ReaderScreen
  // avoids injecting ready readers or testing only DTO/memory state.
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(home: WorkspaceScreen(state: f.state)),
    ),
  );
  await _waitForReads(tester, f, 1);
  return f;
}

Future<void> _waitForReads(WidgetTester tester, _Fixture f, int count) async {
  for (var frame = 0; frame < 30 && f.native.reads.length < count; frame++) {
    await _frames(tester, 1);
  }
  expect(f.native.reads.length, greaterThanOrEqualTo(count));
}

Future<void> _waitForAnchor(
  WidgetTester tester,
  String floor,
  double dy, {
  bool allowPartialBody = false,
}) async {
  for (var frame = 0; frame < 240; frame++) {
    await _frames(tester, 1);
    final actual = _bodyDy(tester, floor);
    if (actual != null && (actual - dy).abs() < 2) break;
  }
  expect(_readerScroll, findsOneWidget);
  expect(_controller(tester).offset, greaterThan(0));
  expect(_bodyDy(tester, floor), closeTo(dy, 2));
  final body = _body(tester, floor);
  if (allowPartialBody) {
    final bounds = tester.getRect(body);
    final visible = bounds.intersect(tester.getRect(_readerScroll));
    expect(visible.isEmpty, isFalse);
    final point = visible.center;
    expect(
      body.hitTestable(
        at: Alignment(
          2 * (point.dx - bounds.left) / bounds.width - 1,
          2 * (point.dy - bounds.top) / bounds.height - 1,
        ),
      ),
      findsOneWidget,
    );
  } else {
    expect(body.hitTestable(), findsOneWidget);
  }
  await _frames(tester, 4);
  expect(_bodyDy(tester, floor), closeTo(dy, 2));
}

Future<void> _saveWindow(WidgetTester tester) async {
  // Bounded fake frames allow restoration/capture and the 600ms Flutter save
  // timer to finish. This is not a wall-clock sleep or a real native flush.
  await _frames(tester, 80);
}

Future<void> _requestFloor(_Fixture f) => f.state.openTopic(
  TopicData({
    'id': '1055415',
    'url': _url,
    'title': 'Startup position fixture',
  }),
);

Future<double> _waitForRequestedFloor(WidgetTester tester, _Fixture f) async {
  double? targetDy;
  for (var frame = 0; frame < 240; frame++) {
    await _frames(tester, 1);
    final actual = _bodyDy(tester, '707');
    if (actual != null &&
        actual > 0 &&
        actual < 180 &&
        f.state.readerNavigation(_url) == null) {
      targetDy = actual;
      break;
    }
  }
  expect(targetDy, isNotNull);
  await _frames(tester);
  expect(_body(tester, '707').hitTestable(), findsOneWidget);
  expect(_bodyDy(tester, '707'), closeTo(targetDy!, 1));
  return targetDy;
}

void _expectProtectedAnchor(_Fixture f, int owner, String floor, double dy) {
  final saved = f.native.positions[(owner, _page)]!;
  expect(numberValue(saved['offset']), greaterThan(0));
  expect(jsonMap(saved['bodyAnchor'])['floor'], floor);
  expect(numberValue(jsonMap(saved['bodyAnchor'])['dy']), closeTo(dy, 2));
  for (final write in f.native.acceptedWrites(owner)) {
    expect(
      numberValue(write.arguments['offset']),
      greaterThan(0),
      reason: 'No-input startup must never replace known progress with zero.',
    );
    expect(write.arguments['bodyAnchor'], isA<Map>());
  }
  expect(f.native.positions[(_ownerA, _otherPage)], {
    'offset': 2050.25,
    'bodyAnchor': {'floor': '5', 'dy': 63.75},
  });
}

void _expectCompleteAnchorSource(_Fixture f, String floor, double dy) {
  final localOffset = f.state.readerOffset(_url);
  final localAnchor = f.state.readerBodyAnchor(_url);
  if (localOffset != null) {
    expect(localOffset, greaterThan(0));
    expect(
      localAnchor?.floor,
      floor,
      reason: 'Publishing local pixels must not hide the DTO while dropping its body anchor.',
    );
    expect(localAnchor?.dy, closeTo(dy, .1));
  } else {
    expect(localAnchor, isNull);
    final retained = f.state.readerFor(_url);
    expect(numberValue(retained['scrollOffset']), greaterThan(0));
    expect(
      jsonMap(retained['bodyAnchor'])['floor'],
      floor,
      reason: 'Before an atomic local commit, the retained DTO must remain a complete restoration source.',
    );
    expect(numberValue(jsonMap(retained['bodyAnchor'])['dy']), closeTo(dy, .1));
  }
}

JsonMap _withTallerOpening(_Native native) {
  final snapshot = native.snapshot();
  final thread = jsonMap(snapshot['thread']);
  final opening = jsonMap(thread['root']);
  return {
    ...snapshot,
    'thread': {
      ...thread,
      'root': {
        ...opening,
        'blocks': [
          ...jsonItems(opening['blocks']),
          for (var paragraph = 0; paragraph < 4; paragraph++)
            {
              'kind': 'text',
              'text':
                  'Inserted opening paragraph $paragraph. '
                  '${List.filled(5, 'This refreshed text increases content before the reading anchor and must not move the current passage.').join(' ')}',
            },
        ],
      },
    },
  };
}

Future<void> _wheel(WidgetTester tester, double delta, {int frames = 4}) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(_readerScroll),
      scrollDelta: Offset(0, delta),
      kind: PointerDeviceKind.mouse,
    ),
  );
  await _frames(tester, frames);
}

Future<void> _firstBodyFrame(WidgetTester tester) async {
  for (var frame = 0; frame < 30; frame++) {
    await _frames(tester, 1);
    if (_readerScroll.evaluate().isNotEmpty) break;
  }
  expect(_readerScroll, findsOneWidget);
}

Future<void> _firstRestoredFrame(
  WidgetTester tester,
  String floor,
  double dy,
) async {
  // Stop on the first rendered match, without the usual extra stability
  // frames. Leaving now exercises restoration's commit/capture boundary.
  for (var frame = 0; frame < 240; frame++) {
    await _frames(tester, 1);
    final actual = _bodyDy(tester, floor);
    if (actual != null && (actual - dy).abs() < .1) break;
  }
  expect(_bodyDy(tester, floor), closeTo(dy, .1));
  expect(_controller(tester).offset, greaterThan(0));
}

void _testMac(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final completeBeforeReplacement in [true, false]) {
    _testMac(
      'cold identity discovery restores the owner partition when the retried old read finishes ${completeBeforeReplacement ? 'before' : 'after'} the replacement begins',
      (tester) async {
        final f = await _mount(tester, _Native());
        final original = f.native.reads.single;
        expect(original.arguments['accessRevision'], 0);
        expect(original.ownerAtDispatch, isNull);
        f.native.publishIdentity(revision: 1, owner: null);
        if (!completeBeforeReplacement) {
          await _waitForReads(tester, f, 2);
        }
        f.native.publishIdentity(revision: 1, owner: _ownerA);
        f.native.complete(original);
        if (completeBeforeReplacement) {
          // Let the method result settle before the queued post-frame reload.
          await tester.idle();
        } else {
          await _frames(tester);
          expect(
            find.text('Body floor 705'),
            findsNothing,
            reason: 'A replaced read cannot install its late payload.',
          );
          f.native.complete(f.native.reads.last);
        }
        await _waitForAnchor(tester, '705', 18);
        await _saveWindow(tester);
        expect(_bodyDy(tester, '705'), closeTo(18, 2));
        _expectProtectedAnchor(f, _ownerA, '705', 18);
        expect(f.native.acceptedWrites(_ownerA), isNotEmpty);
      },
    );
  }

  _testMac(
    'a method result arriving before queued identity events survives the later identity rebuild',
    (tester) async {
      final f = await _mount(tester, _Native());
      final original = f.native.reads.single;
      f.native.nativeRevision = 1;
      f.native.nativeOwner = _ownerA;
      f.native.complete(original);
      await _waitForAnchor(tester, '705', 18);
      f.native.publishIdentity(revision: 1, owner: null, updateNative: false);
      await _waitForReads(tester, f, 2);
      f.native.publishIdentity(
        revision: 1,
        owner: _ownerA,
        updateNative: false,
      );
      await _saveWindow(tester);
      expect(f.native.positions[(_ownerA, _page)]!['bodyAnchor'], _anchorA);
      f.native.complete(f.native.reads.last);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      _expectProtectedAnchor(f, _ownerA, '705', 18);
    },
  );

  _testMac(
    'same owner revision renewal preserves progress through a delayed replacement read',
    (tester) async {
      final f = await _mount(
        tester,
        _Native(nativeOwner: _ownerA, nativeRevision: 1),
      );
      f.native.complete(f.native.reads.single);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      final originalReader = tester.state(_reader);
      final storedBefore = Map<String, dynamic>.of(
        f.native.positions[(_ownerA, _page)]!,
      );
      f.native.publishIdentity(revision: 2, owner: _ownerA);
      await _waitForReads(tester, f, 2);
      expect(tester.state(_reader), isNot(same(originalReader)));
      await _saveWindow(tester);
      expect(
        f.native.positions[(_ownerA, _page)],
        storedBefore,
        reason: 'A loading placeholder cannot replace owner A progress.',
      );
      f.native.complete(f.native.reads.last);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      _expectProtectedAnchor(f, _ownerA, '705', 18);
    },
  );

  _testMac(
    'late owner publication within a revision preserves the already restored body',
    (tester) async {
      final native = _Native(nativeOwner: _ownerA, nativeRevision: 1);
      native.bootstrapSession = native.session(revision: 1, owner: null);
      final f = await _mount(tester, native);
      native.complete(native.reads.single);
      await _waitForAnchor(tester, '705', 18);
      final originalReader = tester.state(_reader);
      native.publishIdentity(revision: 1, owner: _ownerA);
      await _saveWindow(tester);
      expect(tester.state(_reader), same(originalReader));
      expect(_bodyDy(tester, '705'), closeTo(18, 2));
      expect(native.reads, hasLength(1));
      _expectProtectedAnchor(f, _ownerA, '705', 18);
    },
  );

  for (final emptyThread in [false, true]) {
    _testMac(
      'same reader restores its anchor after ${emptyThread ? 'an empty thread' : 'a failed response without a thread'} detaches the scroll body',
      (tester) async {
        final f = await _mount(
          tester,
          _Native(nativeOwner: _ownerA, nativeRevision: 1),
        );
        f.native.complete(f.native.reads.single);
        await _waitForAnchor(tester, '705', 18);
        await _saveWindow(tester);
        final originalReader = tester.state(_reader);
        final originalController = _controller(tester);
        final savedBefore = Map<String, dynamic>.of(
          f.native.positions[(_ownerA, _page)]!,
        );

        unawaited(f.state.loadReader(_url, force: true));
        await _waitForReads(tester, f, 2);
        // A force-refresh loading snapshot retains its previous body. The
        // completion below is the separate no-body transition under test.
        expect(_controller(tester), same(originalController));
        expect(_bodyDy(tester, '705'), closeTo(18, 2));
        f.native.complete(
          f.native.reads.last,
          value: {
            'url': _url,
            'topicID': '1055415',
            'accessRevision': 1,
            'loading': false,
            'scrollOffset': 1194.0,
            'bodyAnchor': Map<String, dynamic>.of(_anchorA),
            if (emptyThread) 'thread': <String, dynamic>{},
            if (!emptyThread) 'error': 'Fixture body temporarily unavailable',
            if (!emptyThread) 'errorCode': 'network',
          },
        );
        await _saveWindow(tester);
        expect(tester.state(_reader), same(originalReader));
        expect(_readerScroll, findsNothing);
        expect(originalController.hasClients, false);
        expect(f.native.positions[(_ownerA, _page)], savedBefore);

        unawaited(f.state.loadReader(_url, force: true));
        await _waitForReads(tester, f, 3);
        f.native.complete(f.native.reads.last);
        await _waitForAnchor(tester, '705', 18);
        expect(tester.state(_reader), same(originalReader));
        expect(_controller(tester), same(originalController));
        await _saveWindow(tester);
        expect(_bodyDy(tester, '705'), closeTo(18, 2));
        _expectProtectedAnchor(f, _ownerA, '705', 18);
      },
    );
  }

  _testMac(
    'ordinary delayed force refresh retains the mounted body and its anchor',
    (tester) async {
      final f = await _mount(
        tester,
        _Native(nativeOwner: _ownerA, nativeRevision: 1),
      );
      f.native.complete(f.native.reads.single);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      final originalReader = tester.state(_reader);
      final originalController = _controller(tester);
      unawaited(f.state.loadReader(_url, force: true));
      await _waitForReads(tester, f, 2);
      await _saveWindow(tester);
      expect(tester.state(_reader), same(originalReader));
      expect(_controller(tester), same(originalController));
      expect(_bodyDy(tester, '705'), closeTo(18, 2));
      _expectProtectedAnchor(f, _ownerA, '705', 18);
      f.native.complete(f.native.reads.last);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      expect(tester.state(_reader), same(originalReader));
      expect(_controller(tester), same(originalController));
      _expectProtectedAnchor(f, _ownerA, '705', 18);
    },
  );

  _testMac(
    'an unfinished body restore is retired when its scroll body detaches before a new body arrives',
    (tester) async {
      final native = _Native(nativeOwner: _ownerA, nativeRevision: 1);
      native.positions[(_ownerA, _page)] = {
        'offset': 1194.0,
        'bodyAnchor': {'floor': '713', 'dy': 18.0},
      };
      final f = await _mount(tester, native);
      native.complete(native.reads.single);
      await _firstBodyFrame(tester);
      expect(
        find.text('Body floor 713').hitTestable(),
        findsNothing,
        reason: 'The saved destination must still be unreached.',
      );
      final originalReader = tester.state(_reader);
      final originalController = _controller(tester);
      final retiredPosition = originalController.position;

      unawaited(f.state.loadReader(_url, force: true));
      await _waitForReads(tester, f, 2);
      native.complete(
        native.reads.last,
        value: {
          'url': _url,
          'topicID': '1055415',
          'accessRevision': 1,
          'loading': false,
          'error': 'Fixture interrupted the body restore',
        },
      );
      await _frames(tester, 1);
      expect(tester.state(_reader), same(originalReader));
      expect(_readerScroll, findsNothing);
      expect(originalController.hasClients, false);
      expect(
        native.acceptedWrites(_ownerA),
        isEmpty,
        reason: 'An unfinished seek is not a new saved reading position.',
      );
      expect(native.positions[(_ownerA, _page)]!['bodyAnchor'], {
        'floor': '713',
        'dy': 18.0,
      });

      unawaited(f.state.loadReader(_url, force: true));
      await _waitForReads(tester, f, 3);
      native.complete(native.reads.last);
      await _waitForAnchor(tester, '713', 18);
      expect(tester.state(_reader), same(originalReader));
      expect(_controller(tester), same(originalController));
      expect(
        originalController.position,
        isNot(same(retiredPosition)),
        reason: 'The new body must have its own attached ScrollPosition.',
      );
      await _saveWindow(tester);
      _expectProtectedAnchor(f, _ownerA, '713', 18);
      for (final write in native.acceptedWrites(_ownerA)) {
        expect(jsonMap(write.arguments['bodyAnchor'])['floor'], '713');
      }
    },
  );

  _testMac(
    'leaving on the first restored frame keeps an atomic body anchor for a differently sized return',
    (tester) async {
      final f = await _mount(
        tester,
        _Native(nativeOwner: _ownerA, nativeRevision: 1),
      );
      f.native.complete(f.native.reads.single);
      await _firstRestoredFrame(tester, '705', 18);
      final oldController = _controller(tester);
      final firstOffset = oldController.offset;
      _expectCompleteAnchorSource(f, '705', 18);

      // tap/idle deliver the real overview command but do not render the next
      // frame. Reader disposal then precedes any pending post-layout capture.
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is DeskButton && widget.label == '返回总览',
        ),
      );
      await tester.idle();
      await _frames(tester, 1);
      expect(_reader, findsNothing);
      _expectCompleteAnchorSource(f, '705', 18);
      f.native.publishReadingSize(21);
      await _frames(tester, 1);
      await f.state.selectTopic(f.state.workspace.tabs.single);
      await _waitForAnchor(tester, '705', 18);
      expect(_controller(tester), isNot(same(oldController)));
      expect(
        (_controller(tester).offset - firstOffset).abs(),
        greaterThan(2),
        reason: 'The larger text must require a different pixel position, so restoring pixels alone cannot satisfy this test.',
      );
      expect(
        f.native.reads,
        hasLength(1),
        reason: 'Returning to the cached tab exercises its local anchor.',
      );
      await _saveWindow(tester);
      _expectProtectedAnchor(f, _ownerA, '705', 18);
    },
  );

  for (final maturePosition in [true, false]) {
    _testMac(
      'a taller refreshed opening preserves the body ${maturePosition ? 'after stable reading' : 'on the first restored frame before another capture frame'}',
      (tester) async {
        final f = await _mount(
          tester,
          _Native(nativeOwner: _ownerA, nativeRevision: 1),
        );
        f.native.complete(f.native.reads.single);
        if (maturePosition) {
          await _waitForAnchor(tester, '705', 18);
          await _saveWindow(tester);
        } else {
          await _firstRestoredFrame(tester, '705', 18);
          _expectCompleteAnchorSource(f, '705', 18);
        }
        final controller = _controller(tester);
        final position = controller.position;
        final previousPixels = controller.offset;
        final writesBeforeRefresh = f.native.writes.length;
        final replacement = _withTallerOpening(f.native);
        unawaited(f.state.loadReader(_url, force: true));
        await _waitForReads(tester, f, 2);
        // Complete before pumping: in the first-frame variant there has been
        // no extra render/capture frame between correct layout and new data.
        f.native.complete(f.native.reads.last, value: replacement);
        await _waitForAnchor(tester, '705', 18);
        expect(_controller(tester), same(controller));
        expect(controller.position, same(position));
        expect(
          controller.offset - previousPixels,
          greaterThan(100),
          reason: 'The refreshed opening must actually change geometry before floor 705.',
        );
        await _saveWindow(tester);
        expect(_bodyDy(tester, '705'), closeTo(18, 2));
        _expectProtectedAnchor(f, _ownerA, '705', 18);
        final afterRefresh = f.native.writes
            .skip(writesBeforeRefresh)
            .where((write) => write.accepted)
            .toList();
        expect(afterRefresh, isNotEmpty);
        for (final write in afterRefresh) {
          expect(jsonMap(write.arguments['bodyAnchor'])['floor'], '705');
          expect(
            numberValue(jsonMap(write.arguments['bodyAnchor'])['dy']),
            closeTo(18, 2),
            reason: 'A pending capture cannot save the transient new geometry before compensation.',
          );
        }
      },
    );
  }

  _testMac(
    'an explicit floor jump survives leaving on its first completed layout frame and returning with larger text',
    (tester) async {
      final f = await _mount(
        tester,
        _Native(nativeOwner: _ownerA, nativeRevision: 1),
      );
      f.native.complete(f.native.reads.single);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      final writesBeforeJump = f.native.writes.length;
      // Reopening the same retained #707 URL is now a fresh navigation
      // command, and must take priority over the saved floor 705 anchor.
      unawaited(
        f.state.openTopic(
          TopicData({
            'id': '1055415',
            'url': _url,
            'title': 'Startup position fixture',
          }),
        ),
      );
      await _waitForReads(tester, f, 2);
      f.native.complete(f.native.reads.last);
      double? targetDy;
      for (var frame = 0; frame < 240; frame++) {
        await _frames(tester, 1);
        final actual = _bodyDy(tester, '707');
        if (actual != null &&
            actual > 0 &&
            actual < 180 &&
            f.state.readerNavigation(_url) == null) {
          targetDy = actual;
          break;
        }
      }
      expect(
        targetDy,
        isNotNull,
        reason: 'The requested floor must reach the upper viewport and complete the explicit navigation.',
      );
      final expectedDy = targetDy!;
      // Completion runs after layout. The previous frame's seeking overlay
      // may still exist until the next build, but leaving now must already
      // retain the complete new anchor. Do not pump away this boundary.
      expect(
        tester
            .getRect(_readerScroll)
            .contains(tester.getCenter(_body(tester, '707'))),
        isTrue,
      );
      _expectCompleteAnchorSource(f, '707', expectedDy);
      final oldController = _controller(tester);
      final oldPixels = oldController.offset;
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is DeskButton && widget.label == '返回总览',
        ),
      );
      await tester.idle();
      await _frames(tester, 1);
      expect(_reader, findsNothing);
      // A fresh completed navigation cannot fall back to the pre-jump 705
      // DTO after disposal, even if its persistence timer has not fired.
      _expectCompleteAnchorSource(f, '707', expectedDy);
      f.native.publishReadingSize(21);
      await _frames(tester, 1);
      await f.state.selectTopic(f.state.workspace.tabs.single);
      await _waitForAnchor(tester, '707', expectedDy);
      expect(_controller(tester), isNot(same(oldController)));
      expect((_controller(tester).offset - oldPixels).abs(), greaterThan(2));
      expect(f.native.reads, hasLength(2));
      await _saveWindow(tester);
      _expectProtectedAnchor(f, _ownerA, '707', expectedDy);
      final afterJump = f.native.writes
          .skip(writesBeforeJump)
          .where((write) => write.accepted)
          .toList();
      expect(afterJump, isNotEmpty);
      for (final write in afterJump) {
        expect(jsonMap(write.arguments['bodyAnchor'])['floor'], '707');
        expect(
          numberValue(jsonMap(write.arguments['bodyAnchor'])['dy']),
          closeTo(expectedDy, 2),
        );
      }
    },
  );

  _testMac(
    'a real wheel takes over an unfinished restore and a delayed result cannot reinstate the old anchor',
    (tester) async {
      final native = _Native(nativeOwner: _ownerA, nativeRevision: 1);
      native.positions[(_ownerA, _page)] = {
        'offset': 1194.0,
        'bodyAnchor': {'floor': '713', 'dy': 18.0},
      };
      final f = await _mount(tester, native);
      native.complete(native.reads.single);
      await _firstBodyFrame(tester);
      expect(find.text('Body floor 713').hitTestable(), findsNothing);
      final lateSnapshot = native.snapshot();
      unawaited(f.state.loadReader(_url, force: true));
      await _waitForReads(tester, f, 2);
      await _wheel(tester, 260, frames: 0);
      final chosenPixels = _controller(tester).offset;
      expect(chosenPixels, greaterThan(0));
      await _saveWindow(tester);
      expect(_controller(tester).offset, closeTo(chosenPixels, .5));
      final chosenAnchor = f.state.readerBodyAnchor(_url);
      expect(chosenAnchor, isNotNull);
      expect(chosenAnchor!.floor, isNot('713'));
      final chosenDy = _bodyDy(tester, chosenAnchor.floor);
      expect(chosenDy, isNotNull);
      expect(native.acceptedWrites(_ownerA), isNotEmpty);

      // This reply contains the old persisted pixels/713 anchor from before
      // the wheel, even though the user's new choice has already been saved.
      native.complete(native.reads.last, value: lateSnapshot);
      await _saveWindow(tester);
      expect(_controller(tester).offset, closeTo(chosenPixels, .5));
      expect(_bodyDy(tester, chosenAnchor.floor), closeTo(chosenDy!, .5));
      expect(find.text('Body floor 713').hitTestable(), findsNothing);
      expect(
        numberValue(native.positions[(_ownerA, _page)]!['offset']),
        closeTo(chosenPixels, .5),
      );
      expect(
        jsonMap(native.positions[(_ownerA, _page)]!['bodyAnchor'])['floor'],
        chosenAnchor.floor,
      );
      for (final write in native.acceptedWrites(_ownerA)) {
        expect(
          numberValue(write.arguments['offset']),
          closeTo(chosenPixels, .5),
        );
        expect(jsonMap(write.arguments['bodyAnchor'])['floor'], isNot('713'));
      }
    },
  );

  for (final kind in [PointerDeviceKind.trackpad, PointerDeviceKind.touch]) {
    for (final timerSaved in [false, true]) {
      _testMac(
        'continuing ${kind.name} drag supersedes a queued floor request and survives ${timerSaved ? 'saved' : 'immediate'} remount',
        (tester) async {
          final f = await _mount(
            tester,
            _Native(nativeOwner: _ownerA, nativeRevision: 1),
          );
          f.native.complete(f.native.reads.single);
          await _waitForAnchor(tester, '705', 18);
          await _saveWindow(tester);
          f.native.writes.clear();
          final readerState = tester.state(_reader);
          final controller = _controller(tester);
          final position = controller.position;
          final sourceThread = f.state.readerFor(_url)['thread'];
          final drag = await _startReadingDrag(tester, kind);
          try {
            final before = controller.offset;
            await drag.move(-40);
            await _frames(tester, 1);
            await drag.move(-40);
            await _frames(tester, 1);
            expect(controller.offset, greaterThan(before));
            expect(controller.position.isScrollingNotifier.value, isTrue);
            final direction = controller.position.userScrollDirection;
            final opening = f.state.openTopic(
              TopicData({
                'id': '1055415',
                'url': _url,
                'title': 'Startup position fixture',
              }),
            );
            await tester.idle();
            expect(f.native.reads, hasLength(2));
            expect(f.native.reads.last.response.isCompleted, isFalse);
            expect(f.state.readerNavigation(_url)?.floor, '707');
            expect(tester.state(_reader), same(readerState));
            expect(_controller(tester), same(controller));
            expect(controller.position, same(position));
            expect(f.state.readerFor(_url)['thread'], same(sourceThread));
            final beforeContinuation = controller.offset;
            await drag.move(-24);
            final chosen = controller.offset;
            expect(chosen, greaterThan(beforeContinuation));
            expect(controller.position.userScrollDirection, direction);
            expect(controller.position.isScrollingNotifier.value, isTrue);
            expect(f.state.readerNavigation(_url), isNull);
            await _frames(tester, 4);
            expect(controller.offset, closeTo(chosen, 1));
            final anchor = f.state.readerBodyAnchor(_url)!;
            expect(anchor.floor, isNot('707'));
            final chosenDy = _bodyDy(tester, anchor.floor)!;
            await drag.end();
            await _frames(tester);
            expect(controller.offset, closeTo(chosen, 1));
            f.native.complete(f.native.reads.last);
            await tester.idle();
            await opening;
            await _frames(tester);
            expect(controller.offset, closeTo(chosen, 1));
            expect(_bodyDy(tester, anchor.floor), closeTo(chosenDy, 1));
            if (timerSaved) {
              await _saveWindow(tester);
              _expectProtectedAnchor(f, _ownerA, anchor.floor, chosenDy);
            } else {
              expect(f.native.writes, isEmpty);
            }
            await tester.tap(
              find.byWidgetPredicate(
                (widget) => widget is DeskButton && widget.label == '返回总览',
              ),
            );
            await _frames(tester, 1);
            expect(_reader, findsNothing);
            await f.state.selectTopic(f.state.workspace.tabs.single);
            await _waitForAnchor(
              tester,
              anchor.floor,
              chosenDy,
              allowPartialBody: true,
            );
            await _frames(tester, 40);
            expect(_controller(tester), isNot(same(controller)));
            expect(_controller(tester).offset, closeTo(chosen, 1));
            expect(f.state.readerNavigation(_url), isNull);
            expect(f.native.reads, hasLength(2));
            await _saveWindow(tester);
            _expectProtectedAnchor(f, _ownerA, anchor.floor, chosenDy);
            expect(f.native.acceptedWrites(_ownerA), isNotEmpty);
            for (final write in f.native.acceptedWrites(_ownerA)) {
              expect(
                numberValue(write.arguments['offset']),
                closeTo(chosen, 1),
              );
              expect(
                jsonMap(write.arguments['bodyAnchor'])['floor'],
                anchor.floor,
              );
            }
          } finally {
            await drag.end();
          }
        },
      );
    }
  }

  for (final kind in [PointerDeviceKind.trackpad, PointerDeviceKind.touch]) {
    _testMac(
      'a floor request after ${kind.name} movement completes without later effective input',
      (tester) async {
        final f = await _mount(
          tester,
          _Native(nativeOwner: _ownerA, nativeRevision: 1),
        );
        f.native.complete(f.native.reads.single);
        await _waitForAnchor(tester, '705', 18);
        await _saveWindow(tester);
        final controller = _controller(tester);
        final drag = await _startReadingDrag(tester, kind);
        final before = controller.offset;
        await drag.move(-40);
        await _frames(tester, 1);
        await drag.move(-40);
        await _frames(tester, 1);
        expect(controller.offset, greaterThan(before));
        expect(controller.position.isScrollingNotifier.value, isTrue);
        final opening = _requestFloor(f);
        await tester.idle();
        expect(f.native.reads, hasLength(2));
        final sequence = f.state.readerNavigation(_url)!.sequence;
        final beforeEnd = controller.offset;
        await drag.end();
        expect(controller.offset, beforeEnd);
        expect(f.state.readerNavigation(_url)?.sequence, sequence);
        f.native.complete(f.native.reads.last);
        await tester.idle();
        await opening;
        final dy = await _waitForRequestedFloor(tester, f);
        expect(_controller(tester), same(controller));
        await _saveWindow(tester);
        _expectProtectedAnchor(f, _ownerA, '707', dy);
      },
    );

    _testMac(
      'a fresh floor request wins after ${kind.name} movement cancelled the prior sequence',
      (tester) async {
        final f = await _mount(
          tester,
          _Native(nativeOwner: _ownerA, nativeRevision: 1),
        );
        f.native.complete(f.native.reads.single);
        await _waitForAnchor(tester, '705', 18);
        await _saveWindow(tester);
        final controller = _controller(tester);
        final drag = await _startReadingDrag(tester, kind);
        await drag.move(-40);
        await _frames(tester, 1);
        await drag.move(-40);
        await _frames(tester, 1);
        final firstOpening = _requestFloor(f);
        await tester.idle();
        expect(f.native.reads, hasLength(2));
        final firstSequence = f.state.readerNavigation(_url)!.sequence;
        final beforeContinuation = controller.offset;
        final direction = controller.position.userScrollDirection;
        await drag.move(-24);
        expect(controller.offset, greaterThan(beforeContinuation));
        expect(controller.position.userScrollDirection, direction);
        expect(f.state.readerNavigation(_url), isNull);
        final nextOpening = _requestFloor(f);
        await tester.idle();
        final nextSequence = f.state.readerNavigation(_url)!.sequence;
        expect(nextSequence, greaterThan(firstSequence));
        expect(f.native.reads, hasLength(2));
        await drag.end();
        expect(f.state.readerNavigation(_url)?.sequence, nextSequence);
        f.native.complete(f.native.reads.last);
        await tester.idle();
        await Future.wait([firstOpening, nextOpening]);
        final dy = await _waitForRequestedFloor(tester, f);
        expect(_controller(tester), same(controller));
        await _saveWindow(tester);
        _expectProtectedAnchor(f, _ownerA, '707', dy);
        expect(f.state.readerNavigation(_url), isNull);
      },
    );
  }

  _testMac('a programmatic jump preserves a queued floor request', (
    tester,
  ) async {
    final f = await _mount(
      tester,
      _Native(nativeOwner: _ownerA, nativeRevision: 1),
    );
    f.native.complete(f.native.reads.single);
    await _waitForAnchor(tester, '705', 18);
    await _saveWindow(tester);
    final controller = _controller(tester);
    final opening = _requestFloor(f);
    await tester.idle();
    expect(f.native.reads, hasLength(2));
    final sequence = f.state.readerNavigation(_url)!.sequence;
    final chosen = controller.offset + 40;
    controller.jumpTo(chosen);
    expect(controller.offset, chosen);
    expect(f.state.readerNavigation(_url)?.sequence, sequence);
    f.native.complete(f.native.reads.last);
    await tester.idle();
    await opening;
    final dy = await _waitForRequestedFloor(tester, f);
    expect(controller.offset, isNot(closeTo(chosen, 1)));
    await _saveWindow(tester);
    _expectProtectedAnchor(f, _ownerA, '707', dy);
  });

  for (final minimum in [true, false]) {
    _testMac(
      'reader font ${minimum ? 'minimum' : 'maximum'} stops repeat writes and re-enables inward adjustment',
      (tester) async {
        final native = _Native(nativeOwner: _ownerA, nativeRevision: 1);
        native.positions[(_ownerA, _page)] = {'offset': 1.0};
        final limit = minimum ? 13.0 : 24.0;
        final inward = minimum ? 14.0 : 23.0;
        native.settings['workspace.readerTextSize'] = inward;
        final f = await _mount(tester, native);
        native.complete(native.reads.single);
        await _saveWindow(tester);
        final outwardButton = find.byWidgetPredicate(
          (widget) =>
              widget is DeskIcon && widget.label == (minimum ? '缩小文字' : '放大文字'),
        );
        final inwardButton = find.byWidgetPredicate(
          (widget) =>
              widget is DeskIcon && widget.label == (minimum ? '放大文字' : '缩小文字'),
        );
        expect(outwardButton.hitTestable(), findsOneWidget);
        for (var tap = 0; tap < 3; tap++) {
          await tester.tap(outwardButton);
        }
        await _frames(tester);
        expect(native.settings['workspace.readerTextSize'], limit);
        expect(tester.widget<DeskIcon>(outwardButton).onTap, isNull);
        expect(tester.widget<DeskIcon>(inwardButton).onTap, isNotNull);
        for (var tap = 0; tap < 3; tap++) {
          await tester.tap(outwardButton);
          await _frames(tester, 1);
        }
        expect(
          native.calls
              .where((call) => call.$1 == 'settings.update')
              .map((call) => call.$2['value']),
          [limit],
        );
        await tester.tap(inwardButton);
        await _frames(tester);
        expect(native.settings['workspace.readerTextSize'], inward);
        expect(tester.widget<DeskIcon>(outwardButton).onTap, isNotNull);
        expect(tester.widget<DeskIcon>(inwardButton).onTap, isNotNull);
        expect(
          native.calls
              .where((call) => call.$1 == 'settings.update')
              .map((call) => call.$2['value']),
          [limit, inward],
        );
        expect(f.state.domain('settings')['workspace.readerTextSize'], inward);
        expect(native.reads, hasLength(1));
      },
    );
  }

  for (final hasSavedB in [true, false]) {
    _testMac(
      'actual owner A to B change ${hasSavedB ? 'restores B progress' : 'starts at the top'} and rejects the old read',
      (tester) async {
        final native = _Native(nativeOwner: _ownerA, nativeRevision: 1);
        if (!hasSavedB) native.positions.remove((_ownerB, _page));
        final f = await _mount(tester, native);
        native.complete(native.reads.single);
        await _waitForAnchor(tester, '705', 18);
        await _saveWindow(tester);
        final savedA = Map<String, dynamic>.of(
          native.positions[(_ownerA, _page)]!,
        );
        unawaited(f.state.loadReader(_url, force: true));
        await _waitForReads(tester, f, 2);
        final oldRead = native.reads.last;
        final oldResult = native.snapshot();
        native.publishIdentity(revision: 2, owner: _ownerB);
        await _waitForReads(tester, f, 3);
        native.complete(oldRead, value: oldResult);
        await _frames(tester);
        native.complete(native.reads.last);
        if (hasSavedB) {
          await _waitForAnchor(tester, '709', 32);
        }
        await _saveWindow(tester);
        expect(native.positions[(_ownerA, _page)], savedA);
        if (hasSavedB) {
          _expectProtectedAnchor(f, _ownerB, '709', 32);
        } else {
          expect(_controller(tester).offset, closeTo(0, .5));
          expect(f.state.readerBodyAnchor(_url), isNull);
          for (final write in native.acceptedWrites(_ownerB)) {
            expect(numberValue(write.arguments['offset']), closeTo(0, .5));
            expect(write.arguments['bodyAnchor'], isNull);
          }
        }
        expect(
          native
              .acceptedWrites(_ownerB)
              .where(
                (write) =>
                    jsonMap(write.arguments['bodyAnchor'])['floor'] == '705',
              ),
          isEmpty,
        );
      },
    );
  }

  _testMac(
    'a genuine wheel to the top remains a valid zero position and clears its anchor',
    (tester) async {
      final f = await _mount(
        tester,
        _Native(nativeOwner: _ownerA, nativeRevision: 1),
      );
      f.native.complete(f.native.reads.single);
      await _waitForAnchor(tester, '705', 18);
      await _saveWindow(tester);
      final writesBeforeInput = f.native.writes.length;
      await _wheel(tester, -100000);
      expect(_controller(tester).offset, closeTo(0, .5));
      await _saveWindow(tester);
      final saved = f.native.positions[(_ownerA, _page)]!;
      expect(numberValue(saved['offset']), closeTo(0, .5));
      expect(saved['bodyAnchor'], isNull);
      final afterInput = f.native.writes.skip(writesBeforeInput).toList();
      expect(afterInput, isNotEmpty);
      expect(afterInput.last.accepted, true);
      expect(afterInput.last.owner, _ownerA);
      expect(numberValue(afterInput.last.arguments['offset']), closeTo(0, .5));
      unawaited(f.state.loadReader(_url, force: true));
      await _waitForReads(tester, f, 2);
      f.native.complete(f.native.reads.last);
      await _saveWindow(tester);
      expect(_controller(tester).offset, closeTo(0, .5));
      expect(f.state.readerBodyAnchor(_url), isNull);
    },
  );
}
