import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_wheel_input.dart';

class _WheelBinding extends AutomatedTestWidgetsFlutterBinding
    with NativeWheelDispatchBinding {
  NativeWheelInput? input;

  @override
  NativeWheelInput get nativeWheelInput => input ?? super.nativeWheelInput;
}

/// This messenger has no delegate to the engine or the real native channel.
class _Messenger implements BinaryMessenger {
  static const codec = StandardMessageCodec();
  MessageHandler? handler;
  final outgoing = <Object?>[];
  final outgoingChannels = <String>[];
  final handlerInstalledAtSend = <bool>[];
  bool autoReply = true;
  Object? readyReply = const {'version': 1};
  Object? sendError;
  Completer<ByteData?> pendingReply = Completer<ByteData?>();

  @override
  Future<ByteData?> send(String channel, ByteData? message) {
    outgoingChannels.add(channel);
    outgoing.add(codec.decodeMessage(message));
    handlerInstalledAtSend.add(handler != null);
    if (sendError != null) return Future<ByteData?>.error(sendError!);
    return autoReply
        ? Future<ByteData?>.value(codec.encodeMessage(readyReply))
        : pendingReply.future;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    expect(channel, NativeWheelInput.channelName);
    this.handler = handler;
  }

  void push(Object? message) {
    final result = handler?.call(codec.encodeMessage(message));
    if (result != null) unawaited(result);
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {
    callback?.call(await handler?.call(data));
  }
}

class _Fixture {
  _Fixture() {
    input = NativeWheelInput(
      messenger: messenger,
      clock: () => now,
      devicePixelRatioForView: (viewId) => ratios[viewId],
    );
  }

  final messenger = _Messenger();
  final ratios = <int, double>{0: 1, 7: 2};
  int now = 0;
  late final NativeWheelInput input;

  NativeWheelMatch classify(PointerScrollEvent event) {
    NativeWheelMatch? result;
    input.dispatch(event, () => result = input.current);
    expect(input.current, isNull);
    return result!;
  }
}

PointerScrollEvent _event({
  int viewId = 0,
  int timestamp = 1000,
  ui.PointerDeviceKind kind = ui.PointerDeviceKind.mouse,
  Offset position = const Offset(10, 20),
  Offset delta = const Offset(0, 39),
}) => PointerScrollEvent(
  viewId: viewId,
  timeStamp: Duration(microseconds: timestamp),
  kind: kind,
  position: position,
  scrollDelta: delta,
);

Map<String, Object> _metadata(
  PointerScrollEvent event, {
  int sequence = 1,
  double ratio = 1,
  Map<String, Object> overrides = const {},
}) => {
  'version': 1,
  'sequence': sequence,
  'viewId': event.viewId,
  'timestampMicros': event.timeStamp.inMicroseconds,
  'precise': false,
  'phase': 0,
  'momentumPhase': 0,
  'modifiers': 0,
  'x': event.position.dx * ratio,
  'y': event.position.dy * ratio,
  'dx': event.scrollDelta.dx * ratio,
  'dy': event.scrollDelta.dy * ratio,
  ...overrides,
};

void main() {
  final binding = _WheelBinding();
  late _Fixture fixture;

  setUp(() {
    fixture = _Fixture();
    binding.input = fixture.input;
  });
  tearDown(() {
    fixture.input.dispose();
    binding.input = null;
  });

  test(
    'ready handshake installs first and channel storage is synchronous',
    () async {
      final first = fixture.input.start();
      final second = fixture.input.start();
      expect(identical(first, second), isTrue);
      await first;
      expect(fixture.messenger.outgoingChannels, [
        NativeWheelInput.channelName,
      ]);
      expect(fixture.messenger.outgoing, [
        const {'type': 'ready', 'version': 1},
      ]);
      expect(fixture.messenger.handlerInstalledAtSend, [true]);

      final event = _event();
      fixture.messenger.push(_metadata(event));
      // Deliberately no await/pump between the platform message and pointer event.
      final match = fixture.classify(event);
      expect(match.matched, isTrue);
      expect(match.eligible, isTrue);
      expect(match.event, same(event));
      expect(match.sequence, 1);
      expect(match.precise, isFalse);
    },
  );

  test(
    'handshake discards messages until the ready reply has completed',
    () async {
      fixture.messenger.autoReply = false;
      final start = fixture.input.start();
      final old = _event();
      fixture.messenger.push(_metadata(old));
      fixture.messenger.pendingReply.complete(
        _Messenger.codec.encodeMessage({'version': 1}),
      );
      await start;
      expect(fixture.classify(old).matched, isFalse);
      final fresh = _event(timestamp: 2000);
      fixture.messenger.push(_metadata(fresh));
      expect(fixture.classify(fresh).eligible, isTrue);
    },
  );

  for (final response in <Object?>[
    null,
    {'version': 2},
    {'version': 1.0},
    true,
  ]) {
    test(
      'incompatible ready reply $response leaves input unclassified',
      () async {
        fixture.messenger.readyReply = response;
        await fixture.input.start();
        final event = _event();
        fixture.messenger.push(_metadata(event));
        expect(fixture.classify(event).matched, isFalse);
      },
    );
  }

  test('missing native bridge does not fail startup', () async {
    fixture.messenger.sendError = MissingPluginException();
    await expectLater(fixture.input.start(), completes);
    final event = _event();
    fixture.messenger.push(_metadata(event));
    expect(fixture.classify(event).eligible, isFalse);
  });

  testWidgets(
    'a nonresponding host is bounded and ignores a late ready reply',
    (tester) async {
      fixture.messenger.autoReply = false;
      var finished = false;
      final start = fixture.input.start().then((_) => finished = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 999));
      expect(finished, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      await start;
      expect(finished, isTrue);
      fixture.messenger.pendingReply.complete(
        _Messenger.codec.encodeMessage({'version': 1}),
      );
      await tester.pump();
      final event = _event();
      fixture.messenger.push(_metadata(event));
      expect(fixture.classify(event).matched, isFalse);
    },
  );

  test(
    'dispose cancels a pending handshake and restart drains old metadata',
    () async {
      fixture.messenger.autoReply = false;
      final pending = fixture.input.start();
      fixture.input.dispose();
      expect(fixture.messenger.handler, isNull);
      fixture.messenger.pendingReply.complete(
        _Messenger.codec.encodeMessage({'version': 1}),
      );
      await pending;
      final old = _event();
      fixture.input.acceptMetadata(_metadata(old));
      fixture.messenger.autoReply = true;
      await fixture.input.start();
      expect(fixture.classify(old).matched, isFalse);
      final fresh = _event(timestamp: 2000);
      fixture.messenger.push(_metadata(fresh));
      expect(fixture.classify(fresh).eligible, isTrue);
    },
  );

  test('exact matching uses each event view and physical coordinates', () {
    final event = _event(
      viewId: 7,
      position: const Offset(10.25, 20.5),
      delta: const Offset(0, 19.5),
    );
    fixture.input.acceptMetadata(_metadata(event, ratio: 2));
    expect(fixture.classify(event).eligible, isTrue);
  });

  test('fractional view ratios preserve the complete physical signature', () {
    fixture.ratios[7] = 1.5;
    const physical = 0.9;
    final logical = physical / 1.5;
    expect(logical * 1.5, isNot(physical));
    final event = _event(
      viewId: 7,
      position: Offset(logical, logical),
      delta: Offset(0, logical),
    );
    fixture.input.acceptMetadata(
      _metadata(
        event,
        ratio: 1.5,
        overrides: {'x': physical, 'y': physical, 'dy': physical},
      ),
    );
    expect(fixture.classify(event).eligible, isTrue);
  });

  final mismatches = <String, Object>{
    'viewId': 7,
    'timestampMicros': 1001,
    'x': 10.00001,
    'y': 20.00001,
    'dx': 0.00001,
    'dy': 39.00001,
  };
  for (final mismatch in mismatches.entries) {
    test('a different ${mismatch.key} cannot classify a pointer', () {
      final event = _event();
      fixture.input.acceptMetadata(
        _metadata(event, overrides: {mismatch.key: mismatch.value}),
      );
      final match = fixture.classify(event);
      expect(match.matched, isFalse);
      expect(match.eligible, isFalse);
    });
  }

  test('an absent or invalid view ratio remains unknown', () {
    for (final ratio in <double?>[null, 0, -1, double.nan, double.infinity]) {
      final local = _Fixture();
      if (ratio == null) {
        local.ratios.remove(7);
      } else {
        local.ratios[7] = ratio;
      }
      final event = _event(viewId: 7);
      local.input.acceptMetadata(_metadata(event, ratio: 2));
      expect(local.classify(event).matched, isFalse);
      local.input.dispose();
    }
  });

  test('metadata order never substitutes for the exact event signature', () {
    final first = _event(timestamp: 1000, delta: const Offset(0, 39));
    final second = _event(timestamp: 2000, delta: const Offset(0, -78));
    fixture.input.acceptMetadata(_metadata(second, sequence: 1));
    fixture.input.acceptMetadata(_metadata(first, sequence: 2));
    expect(fixture.classify(first).sequence, 2);
    expect(fixture.classify(second).sequence, 1);
  });

  test(
    'missing and late metadata cannot change a current or later dispatch',
    () {
      final event = _event();
      fixture.input.dispatch(event, () {
        final initial = fixture.input.current;
        expect(initial!.matched, isFalse);
        fixture.input.acceptMetadata(_metadata(event));
        expect(fixture.input.current, same(initial));
        expect(fixture.input.consume()!.eligible, isFalse);
      });
      // The receipt expiry does not make an already-dispatched timestamp fresh.
      fixture.now = 500000;
      fixture.input.acceptMetadata(_metadata(event, sequence: 2));
      expect(fixture.classify(event).matched, isFalse);
      expect(fixture.input.consume(), isNull);
    },
  );

  test('old metadata from one view does not invalidate a different view', () {
    fixture.classify(_event(timestamp: 2000));
    final otherView = _event(viewId: 7);
    fixture.input.acceptMetadata(_metadata(otherView, ratio: 2));
    expect(fixture.classify(otherView).eligible, isTrue);
  });

  test('the same sequence or two identical signatures are ambiguous', () {
    for (final nextSequence in [1, 2]) {
      final local = _Fixture();
      final event = _event();
      local.input.acceptMetadata(_metadata(event));
      local.input.acceptMetadata(_metadata(event, sequence: nextSequence));
      final match = local.classify(event);
      expect(match.status, NativeWheelStatus.ambiguous);
      expect(match.eligible, isFalse);
      local.input.dispose();
    }
  });

  test(
    'a reused sequence with changed coordinates invalidates both candidates',
    () {
      final first = _event();
      final second = _event(timestamp: 2000, position: const Offset(30, 40));
      fixture.input.acceptMetadata(_metadata(first));
      fixture.input.acceptMetadata(_metadata(second));
      expect(fixture.classify(first).status, NativeWheelStatus.ambiguous);
      expect(fixture.classify(second).status, NativeWheelStatus.ambiguous);
    },
  );

  test(
    'multiple physical candidates within round-trip tolerance are ambiguous',
    () {
      final event = _event();
      fixture.input.acceptMetadata(
        _metadata(event, overrides: {'x': 9.99999925}),
      );
      fixture.input.acceptMetadata(
        _metadata(event, sequence: 2, overrides: {'x': 10.00000075}),
      );
      expect(fixture.classify(event).status, NativeWheelStatus.ambiguous);
    },
  );

  test(
    'out of order sequence input is rejected without claiming newer input',
    () {
      final earlier = _event();
      final later = _event(timestamp: 2000);
      fixture.input.acceptMetadata(_metadata(later, sequence: 2));
      fixture.input.acceptMetadata(_metadata(earlier, sequence: 1));
      expect(fixture.classify(earlier).eligible, isFalse);
      expect(fixture.classify(later).eligible, isTrue);
    },
  );

  test('pending metadata is bounded and expires at 100 milliseconds', () {
    for (var index = 1; index <= 65; index++) {
      fixture.input.acceptMetadata(
        _metadata(_event(timestamp: index), sequence: index),
      );
    }
    expect(fixture.classify(_event(timestamp: 1)).matched, isFalse);
    expect(fixture.classify(_event(timestamp: 65)).matched, isTrue);
    fixture.now = 100000;
    expect(fixture.classify(_event(timestamp: 64)).matched, isFalse);
  });

  test('a backwards injected clock cannot retain a candidate', () {
    fixture.now = 10;
    final event = _event();
    fixture.input.acceptMetadata(_metadata(event));
    fixture.now = 9;
    expect(fixture.classify(event).matched, isFalse);
  });

  test(
    'malformed protocol values invalidate candidates and safely recover',
    () {
      final invalidFields = <String, Object>{
        'version': 1.0,
        'sequence': 0,
        'viewId': -1,
        'timestampMicros': -1,
        'precise': 0,
        'phase': -1,
        'momentumPhase': '0',
        'modifiers': 0.0,
        'x': 10,
        'y': double.nan,
        'dx': double.infinity,
        'dy': double.negativeInfinity,
      };
      final event = _event();
      final messages = <Object?>[
        null,
        true,
        const [],
        const {},
        _metadata(event)..remove('precise'),
        for (final field in invalidFields.entries)
          _metadata(event, overrides: {field.key: field.value}),
      ];
      for (final message in messages) {
        final local = _Fixture();
        local.input.acceptMetadata(_metadata(event));
        local.input.acceptMetadata(message);
        expect(local.classify(event).eligible, isFalse, reason: '$message');
        final next = _event(timestamp: 2000);
        local.input.acceptMetadata(_metadata(next, sequence: 2));
        expect(local.classify(next).eligible, isTrue);
        local.input.dispose();
      }
    },
  );

  test('metadata is copied without mutating or retaining the incoming map', () {
    final event = _event();
    final data = _metadata(event);
    final original = Map<String, Object>.from(data);
    fixture.input.acceptMetadata(data);
    expect(data, original);
    data['precise'] = true;
    data['dy'] = 1000.0;
    final match = fixture.classify(event);
    expect(match.eligible, isTrue);
    expect(match.precise, isFalse);
    expect(event.scrollDelta, const Offset(0, 39));
  });

  test('precision is native metadata rather than delta size', () {
    final precise = _event(delta: const Offset(0, 39));
    final discrete = _event(timestamp: 2000, delta: const Offset(0, 0.125));
    fixture.input.acceptMetadata(
      _metadata(precise, overrides: {'precise': true}),
    );
    fixture.input.acceptMetadata(_metadata(discrete, sequence: 2));
    expect(fixture.classify(precise).eligible, isFalse);
    expect(fixture.classify(discrete).eligible, isTrue);
  });

  test(
    'phase momentum modifiers horizontal and zero inputs stay ineligible',
    () {
      final cases = <(PointerScrollEvent, Map<String, Object>)>[
        (_event(), {'phase': 1}),
        (_event(), {'momentumPhase': 2}),
        (_event(), {'modifiers': 1}),
        (_event(delta: const Offset(1, 39)), {}),
        (_event(delta: const Offset(0.00000001, 39)), {'dx': 0.0}),
        (_event(delta: Offset.zero), {}),
        (_event(kind: ui.PointerDeviceKind.trackpad), {}),
        (_event(kind: ui.PointerDeviceKind.touch), {}),
        (_event(kind: ui.PointerDeviceKind.stylus), {}),
      ];
      for (final (event, fields) in cases) {
        final local = _Fixture();
        local.input.acceptMetadata(_metadata(event, overrides: fields));
        final match = local.classify(event);
        expect(match.matched, isTrue);
        expect(match.eligible, isFalse);
        local.input.dispose();
      }
    },
  );

  test('consumption is one use and scoped to the identical event', () {
    final event = _event();
    fixture.input.acceptMetadata(_metadata(event));
    expect(fixture.input.current, isNull);
    expect(fixture.input.consume(), isNull);
    fixture.input.dispatch(event, () {
      final snapshot = fixture.input.current;
      expect(snapshot!.eligible, isTrue);
      expect(fixture.input.consume(_event()), isNull);
      expect(
        fixture.input.consume(
          event.transformed(Matrix4.translationValues(1, 2, 0)),
        ),
        same(snapshot),
      );
      expect(fixture.input.current, same(snapshot));
      expect(fixture.input.consume(), isNull);
    });
    expect(fixture.input.consume(), isNull);
    expect(fixture.classify(event).matched, isFalse);
  });

  test('nested dispatch restores outer ownership and exceptions clean up', () {
    final outer = _event();
    final inner = _event(timestamp: 2000);
    fixture.input.acceptMetadata(_metadata(outer));
    fixture.input.acceptMetadata(
      _metadata(inner, sequence: 2, overrides: {'precise': true}),
    );
    expect(
      () => fixture.input.dispatch(outer, () {
        final snapshot = fixture.input.current;
        fixture.input.consume();
        fixture.input.dispatch(const PointerHoverEvent(), () {
          expect(fixture.input.current, isNull);
          expect(fixture.input.consume(), isNull);
        });
        expect(fixture.input.current, same(snapshot));
        fixture.input.dispatch(inner, () {
          expect(fixture.input.current!.event, same(inner));
          expect(fixture.input.consume()!.eligible, isFalse);
        });
        expect(fixture.input.current, same(snapshot));
        expect(fixture.input.consume(), isNull);
        throw StateError('dispatch test');
      }),
      throwsStateError,
    );
    expect(fixture.input.current, isNull);
    expect(fixture.input.consume(), isNull);
  });

  testWidgets(
    'binding scope spans listeners and the real pointer signal resolver',
    (tester) async {
      final trace = <String>[];
      NativeWheelMatch? selected;
      final target = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (signal) {
                trace.add('outer');
                expect(fixture.input.current!.matched, isTrue);
                binding.pointerSignalResolver.register(signal, (_) {
                  trace.add('wrong-owner');
                });
              },
              child: Transform.translate(
                offset: const Offset(3, 4),
                child: Listener(
                  key: target,
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: (signal) {
                    trace.add('inner');
                    expect(fixture.input.current!.matched, isTrue);
                    binding.pointerSignalResolver.register(signal, (resolved) {
                      trace.add('resolved');
                      selected = fixture.input.consume(
                        resolved as PointerScrollEvent,
                      );
                      expect(fixture.input.consume(), isNull);
                    });
                  },
                  child: const SizedBox(width: 160, height: 160),
                ),
              ),
            ),
          ),
        ),
      );
      final event = _event(position: tester.getCenter(find.byKey(target)));
      fixture.input.acceptMetadata(_metadata(event));
      binding.handlePointerEvent(event);
      expect(trace, ['inner', 'outer', 'resolved']);
      expect(selected!.event, same(event));
      expect(selected!.eligible, isTrue);
      expect(fixture.input.current, isNull);
      expect(fixture.input.consume(), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
