import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class _ProfileNative extends NativeClient {
  _ProfileNative()
    : super(methods: const MethodChannel('seekdesk.test.profile-shared-reads'));

  final eventsController = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap, int)>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  JsonMap session({bool withProfile = true, int? revision}) => {
    'account': 'signedIn',
    'owner': (revision ?? accessRevision) + 1,
    'accessRevision': revision ?? accessRevision,
    if (withProfile)
      'profile': {
        'id': (revision ?? accessRevision) + 1,
        'name': 'Owner ${(revision ?? accessRevision) + 1}',
        'avatar': '',
      },
  };

  @override
  Stream<JsonMap> get snapshots => eventsController.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}, accessRevision));
    if (method == 'bootstrap') return {'session': session()};
    if (response != null) return await response!(method, arguments);
    return switch (method) {
      'profile.load' => session(),
      'profile.introduction' => {
        'kind': 'ready',
        'data': {'signature': 'Local signature', 'readme': 'Local biography'},
      },
      _ => throw StateError('Unexpected fixture request $method'),
    };
  }

  void changeAccount(int revision) {
    eventsController.add({
      'domain': 'session',
      'accessRevision': revision,
      'data': session(revision: revision),
    });
  }

  List<(String, JsonMap, int)> reads(String method) =>
      calls.where((call) => call.$1 == method).toList();
}

class _ProfileHost extends StatefulWidget {
  const _ProfileHost({required this.state, super.key});
  final AppState state;
  @override
  State<_ProfileHost> createState() => _ProfileHostState();
}

class _ProfileHostState extends State<_ProfileHost> {
  bool showingAccount = true;
  void showAccount(bool value) => setState(() => showingAccount = value);
  @override
  Widget build(BuildContext context) => showingAccount
      ? AccountScreen(state: widget.state, onClose: () => showAccount(false))
      : const CupertinoPageScaffold(
          child: Center(child: Text('Another destination')),
        );
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ProfileNative native;
  late AppState state;
  var disposed = false;

  void disposeState() {
    if (disposed) return;
    disposed = true;
    state.dispose();
  }

  setUp(() async {
    native = _ProfileNative();
    state = AppState(client: native);
    disposed = false;
    await state.connect();
    native.calls.clear();
  });

  tearDown(() async {
    disposeState();
    await native.eventsController.close();
  });

  Future<GlobalKey<_ProfileHostState>> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    final host = GlobalKey<_ProfileHostState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      disposeState();
      await tester.pump(const Duration(seconds: 6));
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: _ProfileHost(key: host, state: state),
        ),
      ),
    );
    await _frames(tester);
    return host;
  }

  Future<void> remountAccount(
    WidgetTester tester,
    GlobalKey<_ProfileHostState> host,
  ) async {
    final original = tester.state(find.byType(AccountScreen));
    host.currentState!.showAccount(false);
    await _frames(tester);
    expect(find.byType(AccountScreen), findsNothing);
    host.currentState!.showAccount(true);
    await _frames(tester);
    expect(
      identical(tester.state(find.byType(AccountScreen)), original),
      isFalse,
    );
  }

  testWidgets(
    'remounted account waits for the shared introduction and restores its editor',
    (tester) async {
      final introduction = Completer<JsonMap>();
      native.response = (method, args) async => switch (method) {
        'profile.load' => native.session(),
        'profile.introduction' => await introduction.future,
        _ => throw StateError('Unexpected request $method'),
      };
      final host = await mount(tester);
      expect(native.reads('profile.introduction'), hasLength(1));
      await remountAccount(tester, host);
      expect(native.reads('profile.introduction'), hasLength(1));
      introduction.complete({
        'kind': 'ready',
        'data': {'signature': 'Shared signature', 'readme': 'Shared biography'},
      });
      await _frames(tester);
      expect(_button('编辑签名与简介'), findsOneWidget);
      expect(find.text('论坛签名'), findsOneWidget);
      expect(find.text('个人简介'), findsOneWidget);
      expect(native.reads('profile.introduction'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remounted account without a cached profile joins the original profile load',
    (tester) async {
      state.domains['session'] = native.session(withProfile: false);
      final profile = Completer<JsonMap>();
      native.response = (method, args) async => switch (method) {
        'profile.load' => await profile.future,
        'profile.introduction' => {'kind': 'ready', 'data': {}},
        _ => throw StateError('Unexpected request $method'),
      };
      final host = await mount(tester);
      await remountAccount(tester, host);
      expect(native.reads('profile.load'), hasLength(1));
      expect(find.text('暂时无法读取资料'), findsNothing);
      profile.complete(native.session());
      await _frames(tester);
      expect(find.text('Owner 1'), findsOneWidget);
      expect(_button('重试加载'), findsNothing);
      expect(native.reads('profile.load'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  test('profile keys separate methods, member IDs and force while serializing the transport slot', () async {
    final normal = Completer<JsonMap>();
    final forced = Completer<JsonMap>();
    final forcedStarted = Completer<void>();
    final other = Completer<JsonMap>();
    final introduction = Completer<JsonMap>();
    native.response = (method, args) async {
      if (method == 'profile.introduction') return introduction.future;
      if (args['id'] == 22) return other.future;
      if (args['force'] == true) {
        forcedStarted.complete();
        return forced.future;
      }
      return normal.future;
    };
    final first = state.act('profile.load', {'id': 11});
    final duplicate = state.act('profile.load', {'id': 11, 'force': false});
    final force = state.act('profile.load', {'id': 11, 'force': true});
    final forceDuplicate = state.act('profile.load', {'id': 11, 'force': true});
    final otherMember = state.act('profile.load', {'id': 22});
    final intro = state.act('profile.introduction');
    final introDuplicate = state.act('profile.introduction');
    expect(native.reads('profile.load'), hasLength(2));
    expect(native.reads('profile.introduction'), hasLength(1));
    expect(
      forcedStarted.isCompleted,
      isFalse,
      reason: 'The forced request must wait for the normal transport slot.',
    );
    normal.complete({
      'profile': {'id': 11, 'name': 'Normal'},
    });
    expect((await first)?['profile']['name'], 'Normal');
    expect((await duplicate)?['profile']['name'], 'Normal');
    // Finishing a predecessor's public Future does not also drain the queued
    // successor. Wait for the fixture's actual transport entry, not its result.
    await forcedStarted.future.timeout(const Duration(seconds: 5));
    expect(native.reads('profile.load'), hasLength(3));
    expect(native.reads('profile.load').last.$2['force'], isTrue);
    forced.complete({
      'profile': {'id': 11, 'name': 'Forced'},
    });
    other.complete({
      'profile': {'id': 22, 'name': 'Other'},
    });
    introduction.complete({
      'kind': 'ready',
      'data': {'signature': 'Signature'},
    });
    expect((await force)?['profile']['name'], 'Forced');
    expect((await forceDuplicate)?['profile']['name'], 'Forced');
    expect((await otherMember)?['profile']['id'], 22);
    expect((await intro)?['kind'], 'ready');
    expect((await introDuplicate)?['kind'], 'ready');
    expect(state.pending, isEmpty);
  });

  for (final method in ['profile.load', 'profile.introduction']) {
    test(
      '$method waits across revisions and discards intermediate and stale responses',
      () async {
        final old = Completer<JsonMap>();
        final current = Completer<JsonMap>();
        final currentStarted = Completer<void>();
        native.response = (method, args) async {
          if (native.accessRevision == 0) return old.future;
          currentStarted.complete();
          return current.future;
        };
        final first = state.act(method, {}, 'profile-fixture');
        final duplicate = state.act(method);
        native.changeAccount(1);
        final intermediate = state.act(method);
        native.changeAccount(2);
        final latest = state.act(method, {}, 'profile-fixture');
        final latestDuplicate = state.act(method);
        expect(native.reads(method), hasLength(1));
        expect(
          currentStarted.isCompleted,
          isFalse,
          reason: 'A new account must wait until the old transport exits.',
        );
        // Even a transport result tagged as current cannot transfer an old
        // caller's ownership into a newly active account.
        old.complete({
          'accessRevision': 2,
          'profile': {'id': 1, 'name': 'Old owner'},
        });
        expect(await first, isNull);
        expect(await duplicate, isNull);
        expect(await intermediate, isNull);
        await currentStarted.future.timeout(const Duration(seconds: 5));
        expect(native.reads(method), hasLength(2));
        expect(native.reads(method).last.$3, 2);
        expect(state.domain('profile-fixture'), isEmpty);
        current.complete({
          'accessRevision': 2,
          'profile': {'id': 3, 'name': 'Current owner'},
        });
        expect((await latest)?['profile']['id'], 3);
        expect((await latestDuplicate)?['profile']['id'], 3);
        expect(state.domain('profile-fixture')['profile']['id'], 3);
        expect(state.pending, isEmpty);
      },
    );
  }

  testWidgets(
    'account remount after an identity change rejects the old signature and loads the new owner',
    (tester) async {
      final old = Completer<JsonMap>();
      final current = Completer<JsonMap>();
      native.response = (method, args) async {
        if (method == 'profile.load') return native.session();
        return native.accessRevision == 0 ? old.future : current.future;
      };
      final host = await mount(tester);
      host.currentState!.showAccount(false);
      await _frames(tester);
      native.changeAccount(1);
      host.currentState!.showAccount(true);
      await _frames(tester);
      expect(native.reads('profile.introduction'), hasLength(1));
      old.complete({
        'kind': 'ready',
        'data': {'signature': 'Old private signature'},
      });
      await _frames(tester);
      expect(native.reads('profile.introduction'), hasLength(2));
      expect(native.reads('profile.introduction').last.$3, 1);
      expect(find.text('论坛签名'), findsNothing);
      expect(_button('编辑签名与简介'), findsNothing);
      current.complete({
        'kind': 'ready',
        'data': {'signature': 'New private signature'},
      });
      await _frames(tester);
      expect(find.text('Owner 2'), findsOneWidget);
      expect(find.text('论坛签名'), findsOneWidget);
      expect(_button('编辑签名与简介'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'shared failure releases both read slots and permits an explicit retry',
    () async {
      for (final method in ['profile.load', 'profile.introduction']) {
        final failed = Completer<JsonMap>();
        native.response = (method, args) => failed.future;
        final first = state.act(method);
        final duplicate = state.act(method);
        failed.completeError(
          const NativeFailure('fixture', 'Local profile read failed'),
        );
        expect(await first, isNull);
        expect(await duplicate, isNull);
        expect(native.reads(method), hasLength(1));
        expect(state.pending, isEmpty);
        native.response = (method, args) async => {'recovered': true};
        expect((await state.act(method))?['recovered'], isTrue);
        expect(native.reads(method), hasLength(2));
      }
    },
  );

  testWidgets(
    'remounted account exposes a real failed read and its retry recovers',
    (tester) async {
      state.domains['session'] = native.session(withProfile: false);
      final failure = Completer<JsonMap>();
      native.response = (method, args) async => switch (method) {
        'profile.load' => await failure.future,
        'profile.introduction' => {'kind': 'ready', 'data': {}},
        _ => throw StateError('Unexpected request $method'),
      };
      final host = await mount(tester);
      await remountAccount(tester, host);
      failure.completeError(
        const NativeFailure('fixture', 'Local profile read failed'),
      );
      await _frames(tester);
      expect(_button('重试加载'), findsOneWidget);
      native.response = (method, args) async => switch (method) {
        'profile.load' => native.session(),
        'profile.introduction' => {'kind': 'ready', 'data': {}},
        _ => throw StateError('Unexpected request $method'),
      };
      await tester.tap(_button('重试加载'));
      await _frames(tester);
      expect(find.text('Owner 1'), findsOneWidget);
      expect(_button('重试加载'), findsNothing);
      expect(native.reads('profile.load'), hasLength(2));
      expect(native.reads('profile.load').last.$2['force'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  test('expired failures are silent and disposed reads neither publish nor start queued requests', () async {
    final old = Completer<JsonMap>();
    native.response = (method, args) => old.future;
    final loading = state.act('profile.load');
    native.changeAccount(1);
    old.completeError(const NativeFailure('fixture', 'Expired failure'));
    expect(await loading, isNull);
    expect(state.message, isNull);

    final pending = Completer<JsonMap>();
    native.response = (method, args) => pending.future;
    final active = state.act('profile.introduction', {}, 'profile-fixture');
    final duplicate = state.act('profile.introduction');
    final forced = state.act('profile.introduction', {'force': true});
    disposeState();
    pending.complete({
      'kind': 'ready',
      'data': {'signature': 'Disposed signature'},
    });
    expect(await active, isNull);
    expect(await duplicate, isNull);
    expect(await forced, isNull);
    expect(await state.act('profile.load'), isNull);
    expect(native.reads('profile.introduction'), hasLength(1));
    expect(state.domain('profile-fixture'), isEmpty);
    expect(state.pending, isEmpty);
    expect(state.message, isNull);
  });

  test(
    'profile writes retain their existing duplicate-operation behavior',
    () async {
      final save = Completer<JsonMap>();
      native.response = (method, args) => save.future;
      final first = state.act('profile.saveIntroduction', {
        'draft': {'signature': 'First'},
      });
      final duplicate = state.act('profile.saveIntroduction', {
        'draft': {'signature': 'Second'},
      });
      expect(await duplicate, isNull);
      expect(native.reads('profile.saveIntroduction'), hasLength(1));
      save.complete({'kind': 'saved'});
      expect((await first)?['kind'], 'saved');
    },
  );
}
