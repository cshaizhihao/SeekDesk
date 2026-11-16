import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/inbox_peer_lookup.dart';

/// No channel, inbox request, account write or forum side effect is allowed.
class _LookupState extends AppState {
  _LookupState() {
    domains['session'] = {'account': 'signedIn', 'owner': 101};
  }

  final calls = <(String, JsonMap)>[];
  Future<JsonMap?> Function(JsonMap args)? response;

  @override
  Future<JsonMap?> act(
    String method, [
    JsonMap arguments = const {},
    String? domainName,
  ]) async {
    if (method != 'profile.load') throw StateError('Unexpected $method');
    calls.add((method, {...arguments}));
    expect(domainName, isNull);
    if (response != null) return response!(arguments);
    return {
      'member_id': arguments['id'],
      'member_name': 'Fixture peer',
      'accessRevision': accessRevision,
      'owner': domains['session']!['owner'],
    };
  }

  void changeAccount({bool signedIn = true}) {
    client.accessRevision++;
    domains['session'] = {
      'account': signedIn ? 'signedIn' : 'signedOut',
      'owner': signedIn ? 202 : null,
    };
    notifyListeners();
  }
}

Finder get _input => find.byKey(const ValueKey('inbox-peer-lookup-input'));
Finder get _open => find.byKey(const ValueKey('inbox-peer-lookup-open'));
String _text(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_input).controller!.text;

Future<void> _mount(
  WidgetTester tester,
  _LookupState state, {
  required Future<bool> Function(JsonMap) onOpen,
  Iterable<JsonMap> contacts = const [],
  int? contactsRevision,
  bool enabled = true,
  double width = 320,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      builder: (context, child) => GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: width,
            child: InboxPeerLookup(
              state: state,
              contacts: contacts,
              contactsRevision: contactsRevision,
              enabled: enabled,
              onOpen: onOpen,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
  final button = tester.widget<DeskButton>(_open);
  expect(button.onTap, isNotNull);
  button.onTap!();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _cleanup(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void _macTest(String description, WidgetTesterCallback callback) => testWidgets(
  description,
  callback,
  variant: const TargetPlatformVariant({TargetPlatform.macOS}),
);

void main() {
  _macTest('known recent or older contact opens without a native lookup', (
    tester,
  ) async {
    final state = _LookupState();
    final opened = <JsonMap>[];
    await _mount(
      tester,
      state,
      contacts: [
        {'id': 42, 'name': 'Older contact', 'avatar': 'untrusted fixture'},
      ],
      contactsRevision: 0,
      onOpen: (peer) async {
        opened.add(peer);
        return true;
      },
    );
    await _submit(tester, 'https://www.nodeseek.com/space/42');
    expect(state.calls, isEmpty);
    expect(opened, [
      {
        'id': 42,
        'name': 'Older contact',
        'avatar': 'https://www.nodeseek.com/avatar/42.png',
      },
    ]);
    expect(_text(tester), isEmpty);
    await _cleanup(tester, state);
  });

  _macTest('unknown contact uses only profile.load and normalizes native DTO', (
    tester,
  ) async {
    final state = _LookupState();
    final opened = <JsonMap>[];
    await _mount(
      tester,
      state,
      onOpen: (peer) async {
        opened.add(peer);
        return true;
      },
    );
    await _submit(tester, '42');
    expect(state.calls, hasLength(1));
    expect(state.calls.single.$1, 'profile.load');
    expect(state.calls.single.$2, <String, dynamic>{'id': 42});
    expect(opened.single['id'], 42);
    expect(opened.single['name'], 'Fixture peer');
    expect(_text(tester), isEmpty);
    await _cleanup(tester, state);
  });

  _macTest('malformed and own-account input do not start any lookup', (
    tester,
  ) async {
    final state = _LookupState();
    var opens = 0;
    await _mount(
      tester,
      state,
      onOpen: (_) async {
        opens++;
        return true;
      },
    );
    for (final input in ['101', 'https://evil.invalid/space/42', '-2']) {
      await _submit(tester, input);
      expect(_text(tester), input);
      expect(state.calls, isEmpty);
      expect(opens, 0);
    }
    await tester.enterText(_input, '');
    await tester.pump();
    expect(tester.widget<DeskButton>(_open).onTap, isNull);
    await _cleanup(tester, state);
  });

  _macTest(
    'failed profile and failed draft-safe open preserve input for retry',
    (tester) async {
      final state = _LookupState();
      var opens = 0;
      state.response = (_) async => null;
      await _mount(
        tester,
        state,
        onOpen: (_) async {
          opens++;
          return opens > 1;
        },
      );
      await _submit(tester, '42');
      expect(find.textContaining('暂时无法读取'), findsOneWidget);
      expect(_text(tester), '42');
      expect(opens, 0);
      state.response = null;
      await _submit(tester, '42');
      expect(find.textContaining('输入已保留'), findsOneWidget);
      expect(_text(tester), '42');
      await _submit(tester, '42');
      expect(opens, 2);
      expect(_text(tester), isEmpty);
      await _cleanup(tester, state);
    },
  );

  _macTest(
    'double submit has one read and cancellation ignores its late reply',
    (tester) async {
      final state = _LookupState();
      final pending = Completer<JsonMap?>();
      state.response = (_) => pending.future;
      var opens = 0;
      await _mount(
        tester,
        state,
        onOpen: (_) async {
          opens++;
          return true;
        },
      );
      await _submit(tester, '42');
      tester.widget<CupertinoTextField>(_input).onSubmitted!('42');
      await tester.pump();
      expect(state.calls, hasLength(1));
      expect(tester.widget<DeskButton>(_open).busy, isTrue);
      expect(tester.widget<CupertinoTextField>(_input).readOnly, isTrue);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(_text(tester), '42');
      pending.complete({
        'member_id': 42,
        'member_name': 'Late peer',
        'accessRevision': 0,
      });
      await tester.pump();
      expect(opens, 0);
      expect(tester.widget<DeskButton>(_open).busy, isFalse);
      await _cleanup(tester, state);
    },
  );

  _macTest('Escape cancels a read while retaining the typed UID', (
    tester,
  ) async {
    final state = _LookupState();
    final pending = Completer<JsonMap?>();
    state.response = (_) => pending.future;
    var opens = 0;
    await _mount(
      tester,
      state,
      onOpen: (_) async {
        opens++;
        return true;
      },
    );
    await _submit(tester, '42');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<DeskButton>(_open).busy, isFalse);
    expect(_text(tester), '42');
    pending.complete({'member_id': 42, 'accessRevision': 0});
    await tester.pump();
    expect(opens, 0);
    await _cleanup(tester, state);
  });

  _macTest('disposing a lookup never invokes navigation for a late result', (
    tester,
  ) async {
    final state = _LookupState();
    final pending = Completer<JsonMap?>();
    state.response = (_) => pending.future;
    var opens = 0;
    await _mount(
      tester,
      state,
      onOpen: (_) async {
        opens++;
        return true;
      },
    );
    await _submit(tester, '42');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete({'member_id': 42, 'accessRevision': 0});
    await tester.pump();
    expect(opens, 0);
    state.dispose();
    expect(tester.takeException(), isNull);
  });

  _macTest(
    'account revision change clears input and invalidates pending work',
    (tester) async {
      final state = _LookupState();
      final pending = Completer<JsonMap?>();
      state.response = (_) => pending.future;
      var opens = 0;
      await _mount(
        tester,
        state,
        onOpen: (_) async {
          opens++;
          return true;
        },
      );
      await _submit(tester, '42');
      state.changeAccount();
      await tester.pump();
      expect(_text(tester), isEmpty);
      pending.complete({'member_id': 42, 'accessRevision': 0, 'owner': 101});
      await tester.pump();
      expect(opens, 0);
      expect(find.textContaining('账号已变更'), findsOneWidget);
      await _cleanup(tester, state);
    },
  );

  _macTest('mismatched profile, owner or revision cannot open a conversation', (
    tester,
  ) async {
    final state = _LookupState();
    var opens = 0;
    await _mount(
      tester,
      state,
      onOpen: (_) async {
        opens++;
        return true;
      },
    );
    for (final result in [
      {'member_id': 43, 'accessRevision': 0, 'owner': 101},
      {'member_id': 42, 'accessRevision': 1, 'owner': 101},
      {'member_id': 42, 'accessRevision': 0, 'owner': 202},
      {'member_id': 42},
      <String, dynamic>{},
    ]) {
      state.response = (_) async => result;
      await _submit(tester, '42');
      expect(opens, 0);
      expect(_text(tester), '42');
    }
    await _cleanup(tester, state);
  });

  _macTest('late parent open completion cannot clear the next account input', (
    tester,
  ) async {
    final state = _LookupState();
    final pendingOpen = Completer<bool>();
    await _mount(tester, state, onOpen: (_) => pendingOpen.future);
    await _submit(tester, '42');
    expect(find.text('正在打开对话…'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    state.changeAccount();
    await tester.pump();
    await tester.enterText(_input, '73');
    await tester.pump();
    pendingOpen.complete(true);
    await tester.pump();
    expect(_text(tester), '73');
    expect(tester.widget<DeskButton>(_open).busy, isFalse);
    await _cleanup(tester, state);
  });

  _macTest('stale contacts are not reused after account change', (
    tester,
  ) async {
    final state = _LookupState();
    final opened = <JsonMap>[];
    await _mount(
      tester,
      state,
      contacts: [
        {'id': 42, 'name': 'Stale name'},
      ],
      contactsRevision: 0,
      onOpen: (peer) async {
        opened.add(peer);
        return true;
      },
    );
    state.changeAccount();
    await tester.pump();
    await _submit(tester, '42');
    expect(state.calls, hasLength(1));
    expect(opened.single['name'], 'Fixture peer');
    await _cleanup(tester, state);
  });

  _macTest('signed-out and sending states disable lookup', (tester) async {
    final state = _LookupState();
    var opens = 0;
    await _mount(
      tester,
      state,
      enabled: false,
      onOpen: (_) async {
        opens++;
        return true;
      },
    );
    expect(tester.widget<CupertinoTextField>(_input).enabled, isFalse);
    expect(tester.widget<DeskButton>(_open).onTap, isNull);
    state.changeAccount(signedIn: false);
    await tester.pump();
    expect(find.text('登录 NodeSeek 后可以查找私信。'), findsOneWidget);
    expect(state.calls, isEmpty);
    expect(opens, 0);
    await _cleanup(tester, state);
  });

  for (final width in [220.0, 320.0, 456.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      _macTest('lookup fits $width wide with 2x text in $brightness', (
        tester,
      ) async {
        final state = _LookupState();
        await _mount(
          tester,
          state,
          width: width,
          scale: 2,
          brightness: brightness,
          onOpen: (_) async => true,
        );
        await _submit(tester, 'https://untrusted.invalid/space/42');
        expect(tester.takeException(), isNull);
        expect(find.textContaining('有效的数字 UID'), findsOneWidget);
        final bounds = tester.getRect(find.byType(InboxPeerLookup));
        final input = tester.getRect(_input);
        final button = tester.getRect(_open);
        expect(input.left, greaterThanOrEqualTo(bounds.left));
        expect(button.right, lessThanOrEqualTo(bounds.right + 0.1));
        expect(state.calls, isEmpty);
        await _cleanup(tester, state);
      });
    }
  }
}
