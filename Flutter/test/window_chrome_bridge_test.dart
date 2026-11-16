import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/window_chrome_bridge.dart';

const _channel = MethodChannel('seekdesk.test.window-chrome');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? response;
  final actions = <String>[];

  setUp(() {
    calls.clear();
    actions.clear();
    response = (call) async => switch (call.method) {
      'attach' => {'installed': true, 'attachment': 'host-one'},
      'update' => true,
      _ => null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return response!(call);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    Object actionContext = 1,
    Object? avatarKey,
    Future<Uint8List> Function()? loadAvatar,
    List<String> enabled = const ['home', 'search'],
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: WindowChromeBridge(
          channel: _channel,
          snapshot: {'enabledActions': enabled, 'accountName': 'Owner'},
          actionContext: actionContext,
          avatarKey: avatarKey,
          loadAvatar: loadAvatar,
          onAction: (action) {
            actions.add(action);
            return true;
          },
          builder: (_, installed) => Text(installed ? 'Native' : 'Fallback'),
        ),
      ),
    );
    await tester.pump();
  }

  Map<Object?, Object?> getUpdate() =>
      calls.lastWhere((call) => call.method == 'update').arguments as Map;

  Future<Object?> host(WidgetTester tester, String method, Object? args) async {
    final result = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method, args)),
      null,
    );
    await tester.pump();
    return _channel.codec.decodeEnvelope((await result)!);
  }

  Map<String, Object?> action(Map<Object?, Object?> update, String name) => {
    'attachment': update['attachment'],
    'generation': update['generation'],
    'action': name,
  };

  testWidgets('fallback stays until toolbar snapshot is acknowledged', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    response = (call) async => switch (call.method) {
      'attach' => {'installed': true, 'attachment': 'host-one'},
      'update' => pending.future,
      _ => null,
    };
    await mount(tester);
    expect(find.text('Fallback'), findsOneWidget);
    expect(await host(tester, 'perform', action(getUpdate(), 'home')), false);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Native'), findsOneWidget);
    expect(await host(tester, 'perform', action(getUpdate(), 'home')), true);
    expect(actions, ['home']);
  });

  testWidgets(
    'absent host preserves Flutter header and never loads a second avatar',
    (tester) async {
      response = (_) async => throw MissingPluginException();
      var loads = 0;
      await mount(
        tester,
        avatarKey: 'one',
        loadAvatar: () async {
          loads++;
          return Uint8List(1);
        },
      );
      expect(find.text('Fallback'), findsOneWidget);
      expect(loads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale generations attachments and unsupported actions are rejected',
    (tester) async {
      await mount(tester);
      final old = getUpdate();
      await mount(tester, actionContext: 2);
      expect(await host(tester, 'perform', action(old, 'home')), false);
      expect(
        await host(tester, 'perform', {
          ...action(getUpdate(), 'home'),
          'attachment': 'old-host',
        }),
        false,
      );
      expect(
        await host(tester, 'perform', action(getUpdate(), 'deleteEverything')),
        false,
      );
      expect(
        await host(tester, 'perform', {
          ...action(getUpdate(), 'home'),
          'generation': true,
        }),
        false,
      );
      expect(actions, isEmpty);
      expect(
        await host(tester, 'perform', action(getUpdate(), 'search')),
        true,
      );
      expect(actions, ['search']);
    },
  );

  testWidgets('equivalent rebuilds do not republish toolbar or avatar', (
    tester,
  ) async {
    var loads = 0;
    Future<Uint8List> image() async {
      loads++;
      return Uint8List.fromList([1]);
    }

    await mount(tester, avatarKey: 'one', loadAvatar: image);
    await tester.pump();
    final count = calls.where((call) => call.method == 'update').length;
    await mount(
      tester,
      avatarKey: 'one',
      loadAvatar: image,
      enabled: ['home', 'search'],
    );
    expect(calls.where((call) => call.method == 'update').length, count);
    expect(loads, 1);
  });

  testWidgets('failed update detaches toolbar and restores fallback', (
    tester,
  ) async {
    await mount(tester);
    response = (_) async => false;
    await mount(tester, actionContext: 2);
    expect(find.text('Fallback'), findsOneWidget);
    expect(calls.last.method, 'detach');
    expect(await host(tester, 'perform', action(getUpdate(), 'home')), false);
  });

  testWidgets(
    'late attach after timeout is detached without removing fallback',
    (tester) async {
      final pending = Completer<Object?>();
      response = (call) async =>
          call.method == 'attach' ? pending.future : null;
      await mount(tester);
      await tester.pump(const Duration(seconds: 4));
      pending.complete({'installed': true, 'attachment': 'late-host'});
      await tester.pump();
      expect(find.text('Fallback'), findsOneWidget);
      expect(calls.last.method, 'detach');
      expect(calls.last.arguments, {'attachment': 'late-host'});
    },
  );

  testWidgets('late attach after disposal is detached', (tester) async {
    final pending = Completer<Object?>();
    response = (call) async => call.method == 'attach' ? pending.future : null;
    await mount(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete({'installed': true, 'attachment': 'retired-host'});
    await tester.pump();
    expect(calls.last.method, 'detach');
    expect(calls.last.arguments, {'attachment': 'retired-host'});
  });

  testWidgets(
    'account change clears old avatar and rejects its delayed image',
    (tester) async {
      final first = Completer<Uint8List>();
      final second = Completer<Uint8List>();
      await mount(
        tester,
        avatarKey: 'old-owner',
        loadAvatar: () => first.future,
      );
      await mount(
        tester,
        actionContext: 2,
        avatarKey: 'new-owner',
        loadAvatar: () => second.future,
      );
      expect((getUpdate()['snapshot'] as Map)['avatarBytes'], null);
      second.complete(Uint8List.fromList([2]));
      await tester.pump();
      first.complete(Uint8List.fromList([1]));
      await tester.pump();
      expect((getUpdate()['snapshot'] as Map)['avatarBytes'], [2]);
      await mount(tester, actionContext: 3);
      expect((getUpdate()['snapshot'] as Map)['avatarBytes'], null);
    },
  );

  testWidgets('host detachment is attachment scoped and restores fallback', (
    tester,
  ) async {
    await mount(tester);
    await host(tester, 'detached', {'attachment': 'unrelated'});
    expect(find.text('Native'), findsOneWidget);
    await host(tester, 'detached', {'attachment': 'host-one'});
    expect(find.text('Fallback'), findsOneWidget);
  });

  testWidgets('in-flight snapshot cannot accept a superseded action', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<Object?>();
    var updates = 0;
    response = (call) async {
      if (call.method == 'update' && updates++ == 0) return pending.future;
      return true;
    };
    await mount(tester, actionContext: 2);
    final old = getUpdate();
    await mount(tester, actionContext: 3, enabled: ['search']);
    expect(await host(tester, 'perform', action(old, 'home')), false);
    pending.complete(true);
    await tester.pump();
    expect((getUpdate()['snapshot'] as Map)['enabledActions'], ['search']);
    expect(await host(tester, 'perform', action(getUpdate(), 'home')), false);
    expect(await host(tester, 'perform', action(getUpdate(), 'search')), true);
  });
}
