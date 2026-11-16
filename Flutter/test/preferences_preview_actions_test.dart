import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/preference_previews.dart';

const _initialSettings = <String, dynamic>{
  'appearance': 'system',
  'workspace.logoPalette': 'Teal',
  'workspace.readingDensity': 'comfortable',
  'workspace.replySendKey': 'commandReturn',
  'workspace.readerTextSize': 19.0,
  'workspace.floorAuthorScale': 135.0,
  'workspace.listTextSize': 21.0,
  'workspace.boardTextSize': 17.0,
  'workspace.rankingTextSize': 16.0,
  'workspace.sidebarWidth': 250.0,
  'workspace.topicColumnWidth': 412.0,
  'workspace.nqReportScale': 150.0,
  'workspace.tqReportScale': 125.0,
};

/// All operations terminate in this fixture. Even unexpected requests are
/// recorded because AppState converts native errors into user feedback.
class _PreferencesNative extends NativeClient {
  _PreferencesNative()
    : super(
        methods: const MethodChannel(
          'seekdesk.test.preferences-preview-actions',
        ),
      );

  JsonMap settings = {..._initialSettings};
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Future<void> Function(JsonMap arguments)? beforeWrite;

  List<JsonMap> get writes => calls
      .where((call) => call.$1 == 'settings.update')
      .map((call) => call.$2)
      .toList();

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'settings.get') return {...settings};
    if (method == 'settings.update') {
      await beforeWrite?.call(arguments);
      settings = {
        ...settings,
        stringValue(arguments['key']): arguments['value'],
      };
      return {...settings};
    }
    if (method == 'external.open') return {};
    unexpected.add(method);
    throw StateError('Unexpected preferences fixture request: $method');
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<(_PreferencesNative, AppState)> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1600));
  final native = _PreferencesNative();
  final state = AppState(client: native)..connecting = false;
  state.domains['settings'] = {...native.settings};
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
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
  return (native, state);
}

Future<void> _tab(WidgetTester tester, String label) async {
  final tab = find.text(label);
  await tester.ensureVisible(tab);
  await tester.pump();
  await tester.tap(tab);
  await _frames(tester);
}

GlassSlider _slider(WidgetTester tester, String key) =>
    tester.widget<GlassSlider>(
      find.descendant(
        of: find.byKey(ValueKey('preference-slider-$key')),
        matching: find.byType(GlassSlider),
      ),
    );

Finder _reset(String key) => find.byKey(ValueKey('preference-reset-$key'));

double _previewValue(WidgetTester tester, String key) => switch (key) {
  'workspace.readerTextSize' =>
    tester
        .widget<PreferenceReaderPreview>(find.byType(PreferenceReaderPreview))
        .bodySize,
  'workspace.floorAuthorScale' =>
    tester
        .widget<PreferenceReaderPreview>(find.byType(PreferenceReaderPreview))
        .authorScale,
  'workspace.listTextSize' =>
    tester
        .widget<PreferenceListPreview>(find.byType(PreferenceListPreview))
        .titleSize,
  'workspace.boardTextSize' =>
    tester
        .widget<PreferenceSidebarPreview>(find.byType(PreferenceSidebarPreview))
        .boardSize,
  'workspace.rankingTextSize' =>
    tester
        .widget<PreferenceSidebarPreview>(find.byType(PreferenceSidebarPreview))
        .rankingSize,
  _ => throw ArgumentError.value(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'final pointer movement and release before a rebuild persist the latest size',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '阅读');
      const key = 'workspace.readerTextSize';
      final finder = find.descendant(
        of: find.byKey(const ValueKey('preference-slider-$key')),
        matching: find.byType(GlassSlider),
      );
      await tester.ensureVisible(finder);
      await _frames(tester);
      final rect = tester.getRect(finder);
      final slider = _slider(tester, key);
      final track = rect.width - slider.thumbRadius * 2;
      Offset point(double fraction) => Offset(
        rect.left + slider.thumbRadius + track * fraction,
        rect.center.dy,
      );
      final gesture = await tester.startGesture(
        point(.35),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(point(.55));
      await _frames(tester);
      await gesture.moveTo(point(.70));
      await _frames(tester);
      expect(_slider(tester, key).value, 21);
      expect(_previewValue(tester, key), 21);
      expect(native.writes, isEmpty);
      await gesture.moveTo(point(1));
      await gesture.up();
      await _frames(tester);
      expect(native.writes, [
        {'key': key, 'value': slider.max},
      ]);
      expect(state.domain('settings')[key], slider.max);
      expect(_previewValue(tester, key), slider.max);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging all reading sizes updates previews locally and only ending each drag persists it',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '阅读');
      const changes = <String, double>{
        'workspace.readerTextSize': 24,
        'workspace.floorAuthorScale': 150,
        'workspace.listTextSize': 22,
        'workspace.boardTextSize': 20,
        'workspace.rankingTextSize': 18,
      };
      for (final entry in changes.entries) {
        _slider(tester, entry.key).onChanged!(entry.value);
        await _frames(tester);
        expect(_previewValue(tester, entry.key), entry.value);
        expect(_slider(tester, entry.key).value, entry.value);
        expect(native.writes, isEmpty);
        expect(state.domain('settings'), _initialSettings);
      }

      final committed = <String, double>{};
      for (final entry in changes.entries) {
        _slider(tester, entry.key).onChangeEnd!(entry.value);
        await _frames(tester);
        committed[entry.key] = entry.value;
        expect(native.writes, hasLength(committed.length));
        expect(native.writes.last, {'key': entry.key, 'value': entry.value});
        expect(state.domain('settings'), {..._initialSettings, ...committed});
        // A snapshot from one committed preference must not discard the
        // uncommitted local previews belonging to the other sliders.
        for (final changed in changes.entries) {
          expect(_previewValue(tester, changed.key), changed.value);
        }
      }
      expect(native.settings, {..._initialSettings, ...changes});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restoring one size writes only that preference and disables its default action',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '阅读');
      const key = 'workspace.readerTextSize';
      final reset = _reset(key);
      var control = tester.widget<DeskButton>(reset);
      expect(control.label, '恢复默认');
      expect(control.semanticLabel, '正文文字，恢复默认');
      expect(control.onTap, isNotNull);
      await tester.ensureVisible(reset);
      await tester.pump();
      await tester.tap(reset);
      await _frames(tester);
      expect(native.writes, [
        {'key': key, 'value': 15.0},
      ]);
      expect(state.domain('settings'), {..._initialSettings, key: 15.0});
      expect(native.settings, {..._initialSettings, key: 15.0});
      expect(_previewValue(tester, key), 15);
      expect(_previewValue(tester, 'workspace.listTextSize'), 21);
      expect(_previewValue(tester, 'workspace.floorAuthorScale'), 135);
      control = tester.widget<DeskButton>(reset);
      expect(control.onTap, isNull);
      await tester.tap(reset, warnIfMissed: false);
      await _frames(tester);
      expect(native.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed restore reports the failure and returns the preview to the stored size',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '阅读');
      const key = 'workspace.readerTextSize';
      native.beforeWrite = (_) async {
        throw const NativeFailure('fixture_write', '无法保存这个设置，请重试。');
      };
      await tester.ensureVisible(_reset(key));
      await tester.pump();
      await tester.tap(_reset(key));
      await _frames(tester);
      expect(native.writes, [
        {'key': key, 'value': 15.0},
      ]);
      expect(state.message, contains('无法保存这个设置'));
      expect(state.domain('settings'), _initialSettings);
      expect(native.settings, _initialSettings);
      expect(_previewValue(tester, key), 19);
      expect(_slider(tester, key).value, 19);
      expect(tester.widget<DeskButton>(_reset(key)).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'about actions open the exact project sources and leave preferences unchanged',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '关于');
      const destinations = {
        '项目源码': 'https://github.com/cshaizhihao/SeekDesk',
        '问题反馈': 'https://github.com/cshaizhihao/SeekDesk/issues',
        'GNU GPLv3.0':
            'https://github.com/cshaizhihao/SeekDesk/blob/main/LICENSE',
        '致谢与许可证': 'https://github.com/cshaizhihao/SeekDesk/blob/main/THIRD_PARTY_NOTICES.md',
      };
      for (final entry in destinations.entries) {
        final button = find.byWidgetPredicate(
          (widget) => widget is DeskButton && widget.label == entry.key,
        );
        expect(button, findsOneWidget);
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
        await _frames(tester);
      }
      expect(
        native.calls
            .where((call) => call.$1 == 'external.open')
            .map((call) => call.$2)
            .toList(),
        [
          for (final url in destinations.values) {'url': url},
        ],
      );
      expect(native.writes, isEmpty);
      expect(state.domain('settings'), _initialSettings);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'serialized A to B to A writes never clear the latest local preview early',
    (tester) async {
      final (native, state) = await _mount(tester);
      await _tab(tester, '阅读');
      const key = 'workspace.readerTextSize';
      final gates = List.generate(3, (_) => Completer<void>());
      var started = 0;
      native.beforeWrite = (_) => gates[started++].future;
      addTearDown(() async {
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        await _frames(tester);
      });

      for (final value in [20.0, 22.0, 20.0]) {
        _slider(tester, key).onChanged!(value);
        _slider(tester, key).onChangeEnd!(value);
        await _frames(tester);
        expect(_previewValue(tester, key), value);
      }
      expect(native.writes, hasLength(1));
      expect(state.domain('settings')[key], 19);

      gates[0].complete();
      await _frames(tester);
      expect(native.writes, hasLength(2));
      expect(state.domain('settings')[key], 20);
      expect(_previewValue(tester, key), 20);

      gates[1].complete();
      await _frames(tester);
      expect(native.writes, hasLength(3));
      expect(state.domain('settings')[key], 22);
      expect(_previewValue(tester, key), 20);
      expect(_slider(tester, key).value, 20);

      gates[2].complete();
      await _frames(tester);
      expect(native.writes, [
        {'key': key, 'value': 20.0},
        {'key': key, 'value': 22.0},
        {'key': key, 'value': 20.0},
      ]);
      expect(state.domain('settings'), {..._initialSettings, key: 20.0});
      expect(_previewValue(tester, key), 20);
      expect(state.message, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
