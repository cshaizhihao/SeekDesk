import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/screens/inbox_screen.dart';

Finder get _composerBody => find.byKey(const ValueKey('inbox-composer-body'));
bool _bodyEditable(WidgetTester tester) {
  final field = tester.widget<CupertinoTextField>(_composerBody);
  return field.enabled != false && !field.readOnly;
}

class InboxFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Future<JsonMap> Function(String, JsonMap)? respond;
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    if (method == 'images.draftReferences') {
      final content = args['content'];
      if (args.length == 1 &&
          content is String &&
          !RegExp(r'!\[|<img\b', caseSensitive: false).hasMatch(content)) {
        return {
          'content': content,
          'imageURLs': <String>[],
          'accessRevision': accessRevision,
        };
      }
      unexpected.add('$method $args');
      throw StateError('Draft fixture rejects image or malformed references');
    }
    // The reference query above parses text locally. Merely mounting or typing
    // must not upload media, request previews or profiles, or perform any
    // writes other than the expected draft persistence.
    if (!const ['inbox.load', 'inbox.updateDraft'].contains(method)) {
      unexpected.add(method);
      throw StateError('Draft fixture rejects $method');
    }
    return await respond?.call(method, args) ?? {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> mount(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(1000, 750));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(
            child: InboxScreen(
              state: state,
              initialPeer: 20,
              peerName: 'Fixture',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    expect((state.client as InboxFixture).unexpected, isEmpty);
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets(
    'conversation cannot overwrite typing while saved draft is still loading',
    (tester) async {
      final native = InboxFixture();
      final read = Completer<JsonMap>();
      native.respond = (method, args) =>
          method == 'inbox.load' ? read.future : Future.value({});
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn'};
      await mount(tester, state);
      expect(_bodyEditable(tester), false);
      read.complete({
        'kind': 'conversation',
        'peer': 20,
        'items': <JsonMap>[],
        'draft': 'kept draft',
        'loading': false,
      });
      await tester.pump();
      await tester.pump();
      final field = tester.widget<CupertinoTextField>(_composerBody);
      expect(field.enabled != false && !field.readOnly, true);
      expect(field.controller?.text, 'kept draft');
      await dispose(tester, state);
    },
  );

  testWidgets(
    'termination flush writes the latest text without waiting for debounce',
    (tester) async {
      final native = InboxFixture();
      native.respond = (method, args) async => method == 'inbox.load'
          ? {
              'kind': 'conversation',
              'peer': 20,
              'items': <JsonMap>[],
              'draft': 'old',
              'loading': false,
            }
          : {'content': args['content']};
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn'};
      await mount(tester, state);
      await tester.pump();
      await tester.enterText(_composerBody, 'last keystroke before quit');
      expect(await state.flushDrafts(), true);
      final save = native.calls.lastWhere(
        (call) => call.$1 == 'inbox.updateDraft',
      );
      expect(save.$2['content'], 'last keystroke before quit');
      expect(save.$2['peer'], 20);
      await dispose(tester, state);
    },
  );

  testWidgets('failed draft flush blocks termination and keeps editable text', (
    tester,
  ) async {
    final native = InboxFixture();
    native.respond = (method, args) async {
      if (method == 'inbox.load') {
        return {
          'kind': 'conversation',
          'peer': 20,
          'items': <JsonMap>[],
          'draft': 'old',
          'loading': false,
        };
      }
      throw const NativeFailure('disk', 'fixture failure');
    };
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn'};
    await mount(tester, state);
    await tester.pump();
    await tester.enterText(_composerBody, 'must survive');
    expect(await state.flushDrafts(), false);
    expect(
      tester.widget<CupertinoTextField>(_composerBody).controller?.text,
      'must survive',
    );
    await tester.pump(const Duration(seconds: 6));
    await dispose(tester, state);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets(
    'quit waits for a save after the conversation widget has closed',
    (tester) async {
      final native = InboxFixture();
      final saved = Completer<JsonMap>();
      native.respond = (method, args) async => method == 'inbox.load'
          ? {
              'kind': 'conversation',
              'peer': 20,
              'items': <JsonMap>[],
              'draft': 'old',
              'loading': false,
            }
          : saved.future;
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn'};
      await mount(tester, state);
      await tester.pump();
      await tester.enterText(_composerBody, 'last edit');
      await tester.pumpWidget(const SizedBox.shrink());
      var finished = false;
      final quit = state.flushDrafts().then((value) {
        finished = true;
        return value;
      });
      await tester.pump();
      expect(finished, false);
      saved.complete({'content': 'last edit'});
      expect(await quit, true);
      state.dispose();
      expect(native.unexpected, isEmpty);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
