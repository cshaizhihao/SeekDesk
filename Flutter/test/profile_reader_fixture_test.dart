// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart' show WorkspaceScreen;
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

import '../tool/profile_reader.dart';
import '../tool/editor_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var outboundCalls = 0;

  setUp(() {
    outboundCalls = 0;
    for (final name in [
      'cc.seekdesk/native.methods.v1',
      'cc.seekdesk/native.events.v1',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async {
            outboundCalls++;
            throw StateError('The memory fixture must never call the host.');
          });
    }
  });
  tearDown(() {
    for (final name in [
      'cc.seekdesk/native.methods.v1',
      'cc.seekdesk/native.events.v1',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    expect(outboundCalls, 0);
  });

  test('editor fixture keeps drafts and every submission in memory', () async {
    final client = MemoryEditorClient();
    final state = AppState(client: client);
    await state.connect();
    expect(state.connectionError, isNull);
    await client.call('discussion.updateDraft', {
      'title': 'Fixture only',
      'content': 'Memory only',
    });
    expect(
      (await client.call('discussion.getDraft'))['content'],
      'Memory only',
    );
    for (final method in ['discussion.publish', 'reader.sendReply']) {
      expect((await client.call(method))['accepted'], false);
    }
    final edit = await client.call('reader.edit.begin', {
      'topicID': '8101',
      'url': editorFixtureURL,
      'floor': 1,
    });
    final editorArguments = {
      'topicID': '8101',
      'url': editorFixtureURL,
      'floor': 1,
      'editToken': edit['editToken'],
    };
    await client.call('reader.edit.update', {
      ...editorArguments,
      'content': 'Edited memory only',
    });
    final verification = await client.call('reader.edit.save', editorArguments);
    expect(verification['accepted'], false);
    expect(verification['needsVerification'], true);
    expect(
      (await client.call('session.verify', {
        'url': editorFixtureURL,
      }))['opened'],
      true,
    );
    final continued = await client.call(
      'reader.edit.continueVerification',
      editorArguments,
    );
    expect(continued['needsVerification'], false);
    expect(continued['content'], 'Edited memory only');
    expect(continued['editToken'], edit['editToken']);
    expect(
      (await client.call('reader.edit.save', editorArguments))['accepted'],
      false,
    );
    await expectLater(
      client.call('reader.edit.save', {
        ...editorArguments,
        'editToken': 'wrong-editor',
      }),
      throwsA(isA<NativeFailure>()),
    );
    for (final method in [
      'reader.react',
      'inbox.send',
      'session.signIn',
      'external.open',
      'unknown',
    ]) {
      await expectLater(client.call(method), throwsA(isA<NativeFailure>()));
    }
    expect((await client.call('images.keyStatus'))['configured'], true);
    expect((await client.call('images.load'))['width'], 1);
    state.dispose();
  });

  test('editor fixture key settings stay in memory and expose only bool status', () async {
    final client = MemoryEditorClient();
    expect(await client.call('images.keyStatus'), {'configured': true});
    expect(await client.call('images.removeKey'), {'configured': false});
    expect(await client.call('images.keyStatus'), {'configured': false});
    expect(await client.call('images.removeKey'), {'configured': false});

    for (final key in [null, '', '   ', 'fixture\nkey', 'fixture\u2028key']) {
      await expectLater(
        client.call('images.setKey', {'key': key}),
        throwsA(
          isA<NativeFailure>().having(
            (error) => error.code,
            'code',
            'invalid_key',
          ),
        ),
      );
      expect(await client.call('images.keyStatus'), {'configured': false});
    }
    expect(
      await client.call('images.setKey', {
        'key': '  fixture-only-replacement  ',
      }),
      {'configured': true},
    );
    client.accessRevision++;
    expect(await client.call('images.keyStatus'), {'configured': true});
    await client.call('images.removeKey');
    expect(await client.call('images.keyStatus'), {'configured': false});
    // A fresh GUI fixture starts configured independently of the previous one.
    expect(await MemoryEditorClient().call('images.keyStatus'), {
      'configured': true,
    });
  });

  test(
    'connects the exact synthetic reader without native calls or events',
    () async {
      final client = MemoryProfileClient();
      final state = AppState(client: client);
      await state.connect();
      expect(state.connectionError, isNull);
      expect(state.workspace.showReader, isTrue);
      expect(state.workspace.selected?.url, profileFixtureURL);
      final thread = jsonMap(state.readerFor(profileFixtureURL)['thread']);
      expect(jsonItems(thread['replies']), hasLength(25));
      final blocks = jsonItems(jsonMap(thread['root'])['blocks']);
      final terminal = blocks.singleWhere(
        (block) => block['kind'] == 'terminal',
      );
      expect(terminal['terminal'], hasLength(250));

      await state.act('settings.update', {
        'key': 'workspace.nqReportScale',
        'value': 120,
      }, 'settings');
      expect(state.domain('settings')['workspace.nqReportScale'], 120);
      await client.call('reader.rememberPosition', {
        'url': profileFixtureURL,
        'offset': 540,
      });
      expect(
        (await client.call('reader.load', {
          'url': profileFixtureURL,
        }))['scrollOffset'],
        540,
      );
      for (final method in [
        'reader.react',
        'discussion.send',
        'session.signIn',
        'images.load',
        'external.open',
        'unknown',
      ]) {
        await expectLater(client.call(method), throwsA(isA<NativeFailure>()));
      }
      expect(await state.flushDrafts(), isTrue);
      state.dispose();

      final reset = await MemoryProfileClient().call('bootstrap');
      expect(jsonMap(reset['reader'])['scrollOffset'], 0);
      expect(jsonMap(reset['settings'])['workspace.nqReportScale'], 100);
    },
  );

  testWidgets('compiles and paints the real reader and 250-line terminal', (
    tester,
  ) async {
    final state = AppState(client: MemoryProfileClient());
    await state.connect();
    await tester.binding.setSurfaceSize(const Size(1380, 880));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: WorkspaceScreen(state: state),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    final terminal = tester.widget<NativeTerminalReport>(
      find.byType(NativeTerminalReport),
    );
    expect(terminal.rows, hasLength(250));
    expect(find.text('本地性能夹具 · NQ 250 行与 25 条回复'), findsWidgets);
    expect(find.text('估价'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
