import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _settings = <String, dynamic>{
  'appearance': 'system',
  'workspace.readerTextSize': 19.0,
};

/// Bootstrap, events and links all terminate in memory. Unexpected operations
/// are recorded because AppState can turn a fixture error into UI feedback.
class _AboutNative extends NativeClient {
  _AboutNative(this.metadata)
    : super(methods: const MethodChannel('seekdesk.test.preferences-about'));

  final JsonMap metadata;
  final eventStream = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  JsonMap refreshResult = {};
  JsonMap updateResult = {};

  @override
  Stream<JsonMap> get snapshots => eventStream.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'bootstrap':
        return {
          'session': {'account': 'signedOut', 'accessRevision': 0},
          'settings': {..._settings},
          ...metadata,
        };
      case 'settings.get':
        return {..._settings};
      case 'session.refresh':
        return refreshResult;
      case 'updates.check':
        return updateResult;
      case 'updates.install':
        return {'started': true};
      case 'external.open':
        return {};
      default:
        unexpected.add(method);
        throw StateError('Unexpected About fixture operation: $method');
    }
  }

  void emit(String domain, JsonMap data, {int? revision}) {
    eventStream.add({
      'domain': domain,
      'accessRevision': revision ?? accessRevision,
      'data': data,
    });
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<(_AboutNative, AppState)> _mount(
  WidgetTester tester, {
  JsonMap metadata = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1200));
  final native = _AboutNative(metadata);
  final state = AppState(client: native);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await native.eventStream.close();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  await state.connect();
  expect(state.connectionError, isNull);
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: CupertinoPageScaffold(child: PreferencesScreen(state: state)),
      ),
    ),
  );
  await _frames(tester);
  await tester.tap(find.text('关于'));
  await _frames(tester);
  return (native, state);
}

void _expectVersion(String description) {
  expect(find.text('$description · www.seekdesk.cc'), findsOneWidget);
  expect(find.text('V1.0.0 · www.seekdesk.cc'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('About displays native bootstrap version and build metadata', (
    tester,
  ) async {
    final (native, state) = await _mount(
      tester,
      metadata: {'version': '2.7.4-rc.2', 'build': '809'},
    );
    _expectVersion('V2.7.4-rc.2（构建 809）');
    expect(find.text('CowCode'), findsNothing);
    expect(find.text('项目源码'), findsOneWidget);
    expect(find.text('问题反馈'), findsOneWidget);
    expect(state.domain('settings'), _settings);
    expect(native.calls.map((call) => call.$1), ['bootstrap', 'settings.get']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late metadata refreshes an already mounted About page', (
    tester,
  ) async {
    final (native, state) = await _mount(tester);
    final settings = state.domain('settings');
    native.emit('bootstrap', {'version': '3.1.0', 'build': '910'});
    await _frames(tester);
    _expectVersion('V3.1.0（构建 910）');
    expect(identical(state.domain('settings'), settings), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial and session snapshots preserve accepted bundle metadata',
    (tester) async {
      final (native, state) = await _mount(
        tester,
        metadata: {'version': '2.7.4', 'build': '809'},
      );
      final settings = state.domain('settings');
      native.emit('snapshot', {
        'workspace': {'selectedTab': null},
      });
      await _frames(tester);
      _expectVersion('V2.7.4（构建 809）');

      native.emit('session', {
        'account': 'signedIn',
        'owner': 42,
        'accessRevision': 1,
      }, revision: 1);
      await _frames(tester);
      _expectVersion('V2.7.4（构建 809）');
      expect(state.accessRevision, 1);

      native.refreshResult = {
        'session': {'account': 'signedOut', 'accessRevision': 2},
      };
      await state.act('session.refresh');
      await _frames(tester);
      _expectVersion('V2.7.4（构建 809）');
      expect(state.accessRevision, 2);
      expect(state.signedIn, isFalse);
      expect(identical(state.domain('settings'), settings), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial metadata merges without accepting stale or invalid data',
    (tester) async {
      final (native, state) = await _mount(
        tester,
        metadata: {'version': '2.7.4', 'build': '809'},
      );
      native.emit('bootstrap', {'version': ' 2.7.5 '});
      await _frames(tester);
      _expectVersion('V2.7.5（构建 809）');

      native.emit('snapshot', {'build': ' 810 '}, revision: 1);
      await _frames(tester);
      _expectVersion('V2.7.5（构建 810）');
      expect(state.accessRevision, 1);

      native.emit('bootstrap', {'version': '0.0.1', 'build': '1'}, revision: 0);
      await _frames(tester);
      _expectVersion('V2.7.5（构建 810）');

      native.emit('bootstrap', {'version': null, 'build': '   '});
      native.emit('snapshot', {
        'version': {'unexpected': 'map'},
        'build': 999,
      });
      await _frames(tester);
      _expectVersion('V2.7.5（构建 810）');
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in <({String name, JsonMap metadata, String expected})>[
    (name: 'absent metadata', metadata: {}, expected: '版本信息不可用'),
    (
      name: 'version without build',
      metadata: {'version': '4.2.0'},
      expected: 'V4.2.0',
    ),
    (
      name: 'build without version',
      metadata: {'build': '1250'},
      expected: '版本信息不可用（构建 1250）',
    ),
    (
      name: 'blank or non-string metadata',
      metadata: {'version': '   ', 'build': 1250},
      expected: '版本信息不可用',
    ),
  ]) {
    testWidgets('About uses an honest fallback for ${scenario.name}', (
      tester,
    ) async {
      await _mount(tester, metadata: scenario.metadata);
      _expectVersion(scenario.expected);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'release entry dispatches only the existing external-open action',
    (tester) async {
      final (native, state) = await _mount(
        tester,
        metadata: {'version': '2.7.4', 'build': '809'},
      );
      final release = find.byWidgetPredicate(
        (widget) => widget is DeskButton && widget.label == '查看发布版本',
      );
      expect(release, findsOneWidget);
      await tester.ensureVisible(release);
      await _frames(tester);
      await tester.tap(release);
      await _frames(tester);
      expect(native.calls.map((call) => call.$1), [
        'bootstrap',
        'settings.get',
        'external.open',
      ]);
      expect(native.calls.last.$2, {
        'url': 'https://github.com/cshaizhihao/SeekDesk/releases',
      });
      expect(state.domain('settings'), _settings);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(find.text('CowCode'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('About checks GitHub explicitly and starts the in-app updater', (
    tester,
  ) async {
    final (native, _) = await _mount(
      tester,
      metadata: {'version': '1.0.0', 'build': '70'},
    );
    expect(find.text('友情链接'), findsNothing);
    expect(native.calls.where((call) => call.$1 == 'updates.check'), isEmpty);
    final check = find.text('检查更新');
    native.updateResult = {'status': 'current', 'version': '1.0.0'};
    await tester.ensureVisible(check);
    await tester.tap(check);
    await _frames(tester);
    expect(find.text('已是最新版本（V1.0.0）。'), findsOneWidget);
    expect(find.text('更新并重启'), findsNothing);

    native.updateResult = {
      'status': 'available',
      'version': '1.1.0',
      'releaseURL':
          'https://github.com/cshaizhihao/SeekDesk/releases/tag/v1.1.0',
    };
    await tester.tap(check);
    await _frames(tester);
    expect(find.textContaining('发现新版本 V1.1.0'), findsOneWidget);
    await tester.tap(find.text('更新并重启'));
    await _frames(tester);
    expect(native.calls.last.$1, 'updates.install');
    expect(native.calls.last.$2, isEmpty);
  });
}
