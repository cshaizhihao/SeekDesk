import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/native_composer_drop.dart';

import 'support/composer_drop_fixture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cc.seekdesk/composer.drop.fixture');
  late NativeComposerDrop bridge;
  late DropNative native;
  final updates = <JsonMap>[];

  setUp(() {
    bridge = NativeComposerDrop(channel: channel);
    native = DropNative();
    updates.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'updateTarget');
      updates.add(jsonMap(call.arguments));
      return {'accepted': true};
    });
  });

  tearDown(() async {
    bridge.dispose();
    await Future<void>.delayed(Duration.zero);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<bool> event(JsonMap values) async {
    final response = await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('drag', values)),
      null,
    );
    return channel.codec.decodeEnvelope(response!) == true;
  }

  void target(
    Object owner,
    String id,
    bool Function(ComposerDropEvent) onDrag, {
    Rect bounds = const Rect.fromLTWH(20, 30, 200, 100),
  }) => bridge.updateTarget(
    owner: owner,
    client: native,
    documentID: id,
    accessRevision: 0,
    bounds: bounds,
    onDrag: onDrag,
  );

  JsonMap incoming(
    JsonMap update, {
    String phase = 'enter',
    String? token,
    double x = 40,
    double y = 50,
  }) => {
    'phase': phase,
    'documentID': update['documentID'],
    'accessRevision': update['accessRevision'],
    'targetRevision': update['targetRevision'],
    'x': x,
    'y': y,
    'dropToken': ?token,
  };

  test('unchanged geometry is quiet and an old owner cannot disable its replacement', () async {
    final old = Object(), current = Object();
    final oldPhases = <String>[];
    target(old, 'old-document', (value) {
      oldPhases.add(value.phase);
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    final first = updates.single;
    expect(await event(incoming(first)), isTrue);
    target(old, 'old-document', (_) => true);
    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(1));
    target(current, 'current-document', (_) => true);
    await Future<void>.delayed(Duration.zero);
    expect(oldPhases, ['enter', 'exit']);
    expect(
      updates.last['targetRevision'] as int,
      greaterThan(first['targetRevision'] as int),
    );
    bridge.removeTarget(old);
    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(2));
    expect(await event(incoming(updates.last)), isTrue);
    bridge.removeTarget(current);
    await Future<void>.delayed(Duration.zero);
    expect(updates.last['enabled'], isFalse);
    expect(updates, hasLength(3));
  });

  test('retired, malformed and out-of-bounds drops release credentials without dispatch', () async {
    var drops = 0;
    final owner = Object();
    target(owner, 'current', (value) {
      if (value.phase == 'drop') drops++;
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    final current = updates.single;
    final values = [
      {
        ...incoming(current, phase: 'drop', token: 'wrong-document'),
        'documentID': 'old',
      },
      {
        ...incoming(current, phase: 'drop', token: 'wrong-account'),
        'accessRevision': 9,
      },
      {
        ...incoming(current, phase: 'drop', token: 'wrong-target'),
        'targetRevision': -1,
      },
      incoming(current, phase: 'drop', token: 'outside', x: 5),
      incoming(current, phase: 'drop', token: 'nan', x: double.nan),
    ];
    for (final value in values) {
      expect(await event(value), isFalse);
    }
    expect(drops, 0);
    expect(
      native
          .arguments('system.releaseComposerDrop')
          .map((args) => args['dropToken']),
      ['wrong-document', 'wrong-account', 'wrong-target', 'outside', 'nan'],
    );
    expect(await event(values.first), isFalse);
    expect(native.arguments('system.releaseComposerDrop'), hasLength(5));
  });

  test('accepted credential is delivered once and a duplicate cannot cancel its capture', () async {
    var drops = 0;
    target(Object(), 'current', (value) {
      if (value.phase == 'drop') drops++;
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    final drop = incoming(
      updates.single,
      phase: 'drop',
      token: 'accepted-once',
    );
    expect(await event(drop), isTrue);
    expect(await event(drop), isFalse);
    expect(drops, 1);
    expect(native.calls, isEmpty);
  });

  test('scope-level rejection releases a valid credential and no file path crosses the target channel', () async {
    target(Object(), 'current', (_) => false);
    await Future<void>.delayed(Duration.zero);
    expect(
      await event(incoming(updates.single, phase: 'drop', token: 'covered')),
      isFalse,
    );
    expect(native.arguments('system.releaseComposerDrop'), [
      {'dropToken': 'covered'},
    ]);
    expect(updates.single.keys.toSet(), {
      'enabled',
      'documentID',
      'accessRevision',
      'targetRevision',
      'left',
      'top',
      'width',
      'height',
    });
  });
}
