import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

JsonMap _workspace(
  List<String> ids, {
  String selected = '2',
  String titlePrefix = 'Private title',
}) => {
  'tabs': [
    for (final id in ids)
      {
        'id': id,
        'title': '$titlePrefix $id',
        'url': 'https://www.nodeseek.com/post-$id-1',
      },
  ],
  'selectedTab': selected,
  'showReader': selected.isNotEmpty,
  'posts': <JsonMap>[],
  'boards': <JsonMap>[],
};

class _TabLifecycleClient extends NativeClient {
  final calls = <(String, JsonMap)>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState fixture(_TabLifecycleClient client, {bool neutral = false}) {
    final state = AppState(client: client)..connecting = false;
    state.domains['workspace'] = _workspace([
      '1',
      '2',
      '3',
    ], selected: neutral ? '' : '2');
    state.domains['session'] = {'account': 'signedOut'};
    return state;
  }

  Future<void> mount(
    WidgetTester tester,
    AppState state, {
    VoidCallback? onSelect,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    await tester.pumpWidget(
      CupertinoApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: 850,
                child: WorkspaceTabs(state: state, onSelect: onSelect),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  }

  Finder neutralButton(String id) => find
      .descendant(
        of: find.byKey(ValueKey('tab-neutral-$id')),
        matching: find.byType(CupertinoButton),
      )
      .first;

  for (final neutral in [false, true]) {
    for (final accountChanged in [false, true]) {
      testWidgets(
        '${neutral ? 'neutral' : 'selected'} callback ignores ${accountChanged ? 'a changed account' : 'a removed tab'} before rebuild',
        (tester) async {
          final client = _TabLifecycleClient();
          final state = fixture(client, neutral: neutral);
          var reveals = 0;
          await mount(tester, state, onSelect: () => reveals++);
          final VoidCallback callback;
          if (neutral) {
            callback = tester
                .widget<CupertinoButton>(neutralButton('1'))
                .onPressed!;
          } else {
            final select = tester
                .widget<GlassSegmentedControl>(
                  find.byType(GlassSegmentedControl),
                )
                .onSegmentSelected;
            callback = () => select(0);
          }
          if (accountChanged) {
            client.accessRevision++;
          } else {
            state.domains['workspace'] = _workspace([
              '2',
              '3',
            ], selected: neutral ? '' : '2');
          }
          callback();
          await tester.pump();
          expect(reveals, 0);
          expect(state.navigationRevision, 0);
          expect(client.calls, isEmpty);
          expect(tester.takeException(), isNull);
          await cleanup(tester, state);
        },
      );
    }
  }

  testWidgets('selected callback rejects indices outside its captured rail', (
    tester,
  ) async {
    final client = _TabLifecycleClient();
    final state = fixture(client);
    var reveals = 0;
    await mount(tester, state, onSelect: () => reveals++);
    final select = tester
        .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
        .onSegmentSelected;
    select(-1);
    select(3);
    await tester.pump();
    expect(reveals, 0);
    expect(client.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('captured neutral callback respects a pending close guard', (
    tester,
  ) async {
    final client = _TabLifecycleClient();
    final state = fixture(client, neutral: true);
    final saved = Completer<bool>();
    state.registerDraftFlusher('fixture', () => saved.future);
    var reveals = 0;
    await mount(tester, state, onSelect: () => reveals++);
    final select = tester
        .widget<CupertinoButton>(neutralButton('1'))
        .onPressed!;
    final closing = state.closeAllTopics();
    expect(state.changingTabs, isTrue);
    select();
    expect(reveals, 0);
    expect(client.calls, isEmpty);
    saved.complete(false);
    expect(await closing, isFalse);
    await cleanup(tester, state);
  });

  for (final accountChanged in [false, true]) {
    testWidgets(
      'held drag removes its title when ${accountChanged ? 'the account changes' : 'its source is removed'}',
      (tester) async {
        final client = _TabLifecycleClient();
        final state = fixture(client);
        await mount(tester, state);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('tab-drag-1')).first),
        );
        try {
          await gesture.moveBy(const Offset(0, 45));
          await tester.pump();
          expect(find.text('Private title 1'), findsNWidgets(2));
          if (accountChanged) client.accessRevision++;
          state.domains['workspace'] = _workspace(
            accountChanged ? ['1', '2', '3'] : ['2', '3'],
            titlePrefix: 'Current title',
          );
          state.showMessage('Workspace snapshot changed');
          await tester.pump();
          expect(find.text('Private title 1'), findsNothing);
          if (accountChanged) {
            expect(find.text('Current title 1'), findsOneWidget);
          }
          // The avatar still owns the pointer even after its source is gone.
          await gesture.moveBy(const Offset(50, 25));
          await tester.pump();
          expect(find.text('Private title 1'), findsNothing);
          expect(client.calls, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await gesture.cancel();
          await cleanup(tester, state);
        }
      },
    );
  }

  testWidgets('held drag follows the latest title of the same live tab', (
    tester,
  ) async {
    final client = _TabLifecycleClient();
    final state = fixture(client);
    await mount(tester, state);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('tab-drag-1')).first),
    );
    try {
      await gesture.moveBy(const Offset(0, 45));
      await tester.pump();
      expect(find.text('Private title 1'), findsNWidgets(2));
      state.domains['workspace'] = _workspace([
        '1',
        '2',
        '3',
      ], titlePrefix: 'Updated title');
      state.showMessage('Title updated');
      await tester.pump();
      expect(find.text('Private title 1'), findsNothing);
      expect(find.text('Updated title 1'), findsNWidgets(2));
      expect(client.calls, isEmpty);
    } finally {
      await gesture.cancel();
      await cleanup(tester, state);
    }
  });

  testWidgets('neutral tab retains its focused button when reordered', (
    tester,
  ) async {
    final client = _TabLifecycleClient();
    final state = fixture(client, neutral: true);
    await mount(tester, state);
    final before = tester.element(neutralButton('2'));
    final focus = Focus.of(tester.element(find.text('Private title 2')));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
    state.domains['workspace'] = _workspace(['2', '3', '1'], selected: '');
    state.showMessage('Reordered background tabs');
    await tester.pump();
    expect(tester.element(neutralButton('2')), same(before));
    expect(Focus.of(tester.element(find.text('Private title 2'))), same(focus));
    expect(focus.hasPrimaryFocus, isTrue);
    expect(client.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });
}
