import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cc.seekdesk/test.notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'notification settings uses the standard transport-only envelope',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'opened': true};
      });
      final client = NativeClient(methods: channel);

      expect(await client.call('settings.openNotifications'), {'opened': true});
      client.accessRevision = 7;
      expect(await client.call('settings.openNotifications'), {'opened': true});

      expect(calls.map((call) => call.method), [
        'settings.openNotifications',
        'settings.openNotifications',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'accessRevision': 0},
        {'accessRevision': 7},
      ]);
    },
  );

  test(
    'notification settings preserves native failure code and message',
    () async {
      final client = NativeClient(methods: channel)..accessRevision = 7;
      for (final code in ['unavailable', 'invalid_arguments']) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'settings.openNotifications');
          expect(call.arguments, {'accessRevision': 7});
          throw PlatformException(code: code, message: 'Fixture $code');
        });

        await expectLater(
          client.call('settings.openNotifications'),
          throwsA(
            isA<NativeFailure>()
                .having((failure) => failure.code, 'code', code)
                .having(
                  (failure) => failure.message,
                  'message',
                  'Fixture $code',
                ),
          ),
        );
      }
    },
  );
}
