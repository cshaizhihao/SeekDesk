import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

JsonMap tab(String id) => {
  'id': id,
  'title': 'Post $id',
  'url': 'https://www.nodeseek.com/post-$id-1',
};

JsonMap workspace(
  List<String> ids, {
  String? selected,
  List<String> closed = const [],
}) => {
  'tabs': ids.map(tab).toList(),
  'closedTabs': closed.map(tab).toList(),
  'selectedTab': selected ?? (ids.isEmpty ? null : ids.first),
  'showReader': ids.isNotEmpty,
  'posts': <JsonMap>[],
  'boards': <JsonMap>[],
};

class TabFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return await response?.call(method, args) ?? {};
  }
}

void expectCalls(
  Iterable<(String, JsonMap)> actual,
  List<(String, JsonMap)> expected,
) {
  expect(
    actual.map((call) => [call.$1, call.$2]).toList(),
    expected.map((call) => [call.$1, call.$2]).toList(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState fixture(TabFixture native, [JsonMap? snapshot]) {
    final state = AppState(client: native)..connecting = false;
    state.domains['workspace'] =
        snapshot ?? workspace(['1', '2', '3'], selected: '2');
    state.domains['session'] = {'account': 'signedOut'};
    return state;
  }

  Future<void> mount(
    WidgetTester tester,
    AppState state, {
    bool full = false,
    Size size = const Size(1100, 700),
    double textScale = 1,
    bool? reduceMotion,
  }) async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: GlassAccessibilityScope(
            reduceMotion: reduceMotion,
            child: child!,
          ),
        ),
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: full
              ? WorkspaceScreen(state: state)
              : CupertinoPageScaffold(
                  child: Center(
                    child: SizedBox(
                      width: 850,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          WorkspaceTabs(state: state),
                          const SizedBox(height: 10),
                          ClosedTabsButton(state: state),
                        ],
                      ),
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

  Future<void> drag(
    WidgetTester tester,
    String id,
    String target, {
    VoidCallback? beforeDrop,
  }) async {
    final start = tester.getCenter(find.byKey(ValueKey('tab-drag-$id')).first);
    final end = tester.getCenter(
      find.byKey(ValueKey('tab-target-$target')).first,
    );
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 160));
    beforeDrop?.call();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  for (final neutral in [false, true]) {
    testWidgets(
      'individual close targets its own ${neutral ? 'neutral' : 'background'} tab',
      (tester) async {
        final native = TabFixture();
        final state = fixture(
          native,
          workspace(['1', '2', '3'], selected: neutral ? '' : '2'),
        );
        native.response = (method, _) async => method == 'reader.close'
            ? workspace(['2', '3'], selected: neutral ? '' : '2', closed: ['1'])
            : {};
        await mount(tester, state);
        await tester.tap(find.byKey(const ValueKey('tab-close-1')));
        await tester.pumpAndSettle();
        expectCalls(native.calls, [
          ('reader.close', {'id': '1'}),
        ]);
        expect(state.workspace.tabs.map((tab) => tab.id), ['2', '3']);
        expect(state.workspace.selectedTab, neutral ? '' : '2');
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      },
    );

    testWidgets(
      'wheel and mouse drag scroll the ${neutral ? 'neutral' : 'selected'} rail without selecting tabs',
      (tester) async {
        final native = TabFixture();
        final state = fixture(
          native,
          workspace([
            for (var i = 1; i <= 20; i++) '$i',
          ], selected: neutral ? '' : '1'),
        );
        await mount(tester, state);
        await tester.pumpAndSettle();
        final rail = find.descendant(
          of: find.byType(WorkspaceTabs),
          matching: find.byType(SingleChildScrollView),
        );
        final controller = tester
            .widget<SingleChildScrollView>(rail)
            .controller!;
        expect(controller.offset, 0);
        final scrollbar = find.byKey(const ValueKey('workspace-tab-scrollbar'));
        expect(tester.widget<RawScrollbar>(scrollbar).controller, controller);
        final point = tester.getCenter(rail);
        Future<void> wheel(Offset delta) async {
          await tester.sendEventToBinding(
            PointerScrollEvent(position: point, scrollDelta: delta),
          );
          await tester.pumpAndSettle();
        }

        await wheel(const Offset(0, 100));
        expect(controller.offset, closeTo(100, .1));
        await wheel(const Offset(0, -40));
        expect(controller.offset, closeTo(60, .1));
        await wheel(const Offset(50, 0));
        expect(controller.offset, closeTo(110, .1));
        await wheel(const Offset(0, 10000));
        expect(controller.offset, controller.position.maxScrollExtent);
        await wheel(const Offset(0, -10000));
        expect(controller.offset, 0);

        final bounds = tester.getRect(scrollbar);
        final thumb = bounds.bottomLeft + const Offset(11, -5);
        expect(thumb.dy, greaterThan(tester.getRect(rail).bottom));
        await tester.dragFrom(
          thumb,
          const Offset(80, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(0));
        expect(native.calls, isEmpty);
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      },
    );
  }

  for (final neutral in [false, true]) {
    for (final alreadyShown in [false, true]) {
      testWidgets(
        '${neutral ? 'neutral' : 'selected'} title hover ${alreadyShown ? 'shows full text' : 'waits'} without selecting and clears on account change',
        (tester) async {
          const title =
              'A complete long topic title that extends beyond the visible tab label';
          final native = TabFixture();
          final snapshot = workspace(['1', '2'], selected: neutral ? '' : '2');
          snapshot['tabs'] = [
            {...tab('1'), 'title': title},
            tab('2'),
          ];
          final state = fixture(native, snapshot);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          try {
            await mount(tester, state);
            expect(
              tester.getSize(find.text(title)).width,
              lessThanOrEqualTo(170),
            );
            await mouse.addPointer(location: Offset.zero);
            await mouse.moveTo(tester.getCenter(find.text(title)));
            await tester.pump(const Duration(milliseconds: 150));
            expect(find.text(title, findRichText: true), findsOneWidget);
            if (alreadyShown) {
              await tester.pump(const Duration(milliseconds: 450));
              await tester.pump(const Duration(milliseconds: 200));
              final copies = find.text(title, findRichText: true);
              expect(copies, findsNWidgets(2));
              expect(tester.getSize(copies.last).width, lessThanOrEqualTo(360));
            }
            expect(native.calls, isEmpty);
            expect(state.workspace.selectedTab, neutral ? '' : '2');
            native.accessRevision++;
            final replacement = workspace([
              '1',
              '2',
            ], selected: neutral ? '' : '2');
            replacement['tabs'] = [
              {...tab('1'), 'title': 'Current title'},
              tab('2'),
            ];
            state.domains['workspace'] = replacement;
            state.showMessage('Workspace snapshot changed');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 800));
            expect(find.text(title, findRichText: true), findsNothing);
            expect(
              find.byWidgetPredicate(
                (widget) => widget is Text && widget.data == 'Current title',
              ),
              findsOneWidget,
            );
            expect(native.calls, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            await mouse.removePointer();
            await cleanup(tester, state);
          }
        },
      );
    }
  }

  for (final forward in [true, false]) {
    testWidgets(
      'handle drag ${forward ? 'right' : 'left'} sends native target id and keeps selected tab',
      (tester) async {
        final native = TabFixture();
        final state = fixture(native);
        final ordered = forward ? ['2', '3', '1'] : ['3', '1', '2'];
        native.response = (method, _) async =>
            method == 'reader.move' ? workspace(ordered, selected: '2') : {};
        await mount(tester, state);
        await drag(tester, forward ? '1' : '3', forward ? '3' : '1');
        expectCalls(
          native.calls.where((call) => call.$1 == 'reader.move').toList(),
          [
            (
              'reader.move',
              {'id': forward ? '1' : '3', 'to': forward ? '3' : '1'},
            ),
          ],
        );
        expect(state.workspace.tabs.map((tab) => tab.id), ordered);
        expect(state.workspace.selectedTab, '2');
        expect(native.calls.any((call) => call.$1 == 'reader.select'), false);
        final control = tester.widget<GlassSegmentedControl>(
          find.byType(GlassSegmentedControl),
        );
        expect(control.segments.map((segment) => segment.id), ordered);
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      },
    );
  }

  testWidgets('a rejected native reorder keeps the prior tab order', (
    tester,
  ) async {
    final native = TabFixture();
    native.response = (method, _) async {
      if (method == 'reader.move') throw StateError('Fixture move rejected');
      return {};
    };
    final state = fixture(native);
    await mount(tester, state);
    await drag(tester, '1', '3');
    expect(state.workspace.tabs.map((tab) => tab.id), ['1', '2', '3']);
    expect(state.message, contains('Fixture move rejected'));
    await cleanup(tester, state);
  });

  testWidgets('a dragged tab cannot cross account revisions', (tester) async {
    final native = TabFixture();
    final state = fixture(native);
    await mount(tester, state);
    await drag(tester, '1', '3', beforeDrop: () => native.accessRevision++);
    expect(native.calls.where((call) => call.$1 == 'reader.move'), isEmpty);
    expect(state.workspace.tabs.map((tab) => tab.id), ['1', '2', '3']);
    await cleanup(tester, state);
  });

  testWidgets(
    'close all waits for draft persistence and leaves a history entry',
    (tester) async {
      final native = TabFixture(), saved = Completer<bool>();
      final state = fixture(native);
      state.registerDraftFlusher('composer', () => saved.future);
      native.response = (method, _) async => method == 'reader.closeAll'
          ? workspace([], closed: ['1', '3', '2'])
          : {};
      await mount(tester, state);
      await tester.tap(find.bySemanticsLabel('关闭全部标签'));
      await tester.pump();
      expect(native.calls, isEmpty);
      expect(state.changingTabs, true);
      saved.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expectCalls(native.calls, [('reader.closeAll', <String, dynamic>{})]);
      expect(state.workspace.tabs, isEmpty);
      expect(state.workspace.closedTabs.map((tab) => tab.id), ['1', '3', '2']);
      expect(find.text('最近关闭'), findsOneWidget);
      expect(find.byType(GlassSegmentedControl), findsNothing);
      await cleanup(tester, state);
    },
  );

  test('failed local persistence preserves all open tabs', () async {
    final native = TabFixture();
    final state = fixture(native);
    state.registerDraftFlusher('composer', () async => false);
    expect(await state.closeAllTopics(), false);
    expect(native.calls, isEmpty);
    expect(state.workspace.tabs.map((tab) => tab.id), ['1', '2', '3']);
    expect(state.message, contains('草稿尚未保存'));
    state.dispose();
  });

  test('account change during draft flush cancels close all', () async {
    final native = TabFixture(), saved = Completer<bool>();
    final state = fixture(native);
    state.registerDraftFlusher('composer', () => saved.future);
    final close = state.closeAllTopics();
    await Future<void>.delayed(Duration.zero);
    native.accessRevision++;
    saved.complete(true);
    expect(await close, false);
    expect(native.calls, isEmpty);
    expect(state.message, isNull);
    state.dispose();
  });

  testWidgets('history is newest first and restores the chosen older entry', (
    tester,
  ) async {
    final native = TabFixture();
    final state = fixture(
      native,
      workspace(['1', '3'], selected: '3', closed: ['2', '4']),
    );
    native.response = (method, _) async => method == 'reader.reopen'
        ? workspace(['1', '2', '3'], selected: '2', closed: ['4'])
        : {};
    await mount(tester, state);
    await tester.tap(find.text('最近关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('closed-tab-4'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('closed-tab-2'))).dy,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('closed-tab-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expectCalls(
      native.calls.where((call) => call.$1 == 'reader.reopen').toList(),
      [
        ('reader.reopen', {'id': '2'}),
      ],
    );
    expect(state.workspace.tabs.map((tab) => tab.id), ['1', '2', '3']);
    expect(state.workspace.closedTabs.map((tab) => tab.id), ['4']);
    expect(state.workspace.selectedTab, '2');
    expect(state.navigationRevision, 1);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  for (final dismissal in ['close button', 'Escape']) {
    testWidgets(
      'recent tabs $dismissal removes the finished route semantics and restores opener focus',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final native = TabFixture();
          final state = fixture(native, workspace(['1'], closed: ['2', '4']));
          await mount(tester, state);
          final opener = find.byWidgetPredicate(
            (widget) => widget is DeskButton && widget.label == '最近关闭',
          );
          final openerFocus = tester
              .widget<FocusableActionDetector>(
                find.descendant(
                  of: opener,
                  matching: find.byType(FocusableActionDetector),
                ),
              )
              .focusNode!;
          openerFocus.requestFocus();
          await tester.pump();
          expect(openerFocus.hasFocus, true);
          final pageRoute = ModalRoute.of(tester.element(opener))!;
          final barriers = find.byType(ModalBarrier, skipOffstage: false);
          final pageBarriers = barriers.evaluate().toSet();
          expect(
            pageBarriers,
            hasLength(1),
            reason: 'The underlying CupertinoPageRoute owns its own barrier before the dialog opens.',
          );
          expect(
            (pageBarriers.single.widget as ModalBarrier).dismissible,
            false,
          );
          await tester.tap(opener);
          await tester.pumpAndSettle(
            const Duration(milliseconds: 40),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 3),
          );
          expect(find.text('最近关闭的标签'), findsOneWidget);
          expect(find.bySemanticsLabel('关闭最近标签列表'), findsOneWidget);
          expect(openerFocus.hasFocus, false);
          final dialogRoute = ModalRoute.of(
            tester.element(find.text('最近关闭的标签')),
          )!;
          expect(dialogRoute, isNot(same(pageRoute)));
          expect(dialogRoute.isCurrent, true);
          final dialogEntries = dialogRoute.overlayEntries.toList(
            growable: false,
          );
          expect(dialogEntries, hasLength(2));
          expect(dialogEntries.every((entry) => entry.mounted), true);
          final dialogBarriers = barriers.evaluate().toSet().difference(
            pageBarriers,
          );
          expect(dialogBarriers, hasLength(1));
          expect(
            (dialogBarriers.single.widget as ModalBarrier).dismissible,
            true,
          );
          var dialogCompleted = false;
          unawaited(
            dialogRoute.completed.then((_) {
              dialogCompleted = true;
            }),
          );
          if (dismissal == 'Escape') {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.tap(
              find.byWidgetPredicate(
                (widget) => widget is DeskIcon && widget.label == '关闭最近标签列表',
              ),
            );
          }
          // A dialog may retain disabled semantics while reversing. Check after
          // the route has finished, including normally offstage descendants.
          await tester.pumpAndSettle(
            const Duration(milliseconds: 40),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 3),
          );
          expect(find.text('最近关闭的标签', skipOffstage: false), findsNothing);
          expect(
            find.byKey(const ValueKey('closed-tab-2'), skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('closed-tab-4'), skipOffstage: false),
            findsNothing,
          );
          expect(dialogCompleted, true);
          expect(dialogRoute.isActive, false);
          expect(dialogEntries.every((entry) => !entry.mounted), true);
          expect(dialogBarriers.single.mounted, false);
          expect(
            barriers.evaluate(),
            unorderedEquals(pageBarriers),
            reason: 'Only the exact pre-existing page barrier may remain; the dialog barrier must be disposed.',
          );
          expect(pageRoute.isCurrent, true);
          expect(
            find.bySemanticsLabel('关闭最近标签列表', skipOffstage: false),
            findsNothing,
          );
          expect(
            find.bySemanticsLabel(RegExp('Post [24]'), skipOffstage: false),
            findsNothing,
          );
          expect(openerFocus.hasFocus, true);
          expect(
            native.calls.where((call) => call.$1 == 'reader.reopen'),
            isEmpty,
          );
          expect(state.workspace.selectedTab, '1');
          expect(state.workspace.closedTabs.map((tab) => tab.id), ['2', '4']);
          expect(tester.takeException(), isNull);
          await cleanup(tester, state);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets('narrow overview exposes recent tabs after all are closed', (
    tester,
  ) async {
    final native = TabFixture();
    final state = fixture(native, workspace([], closed: ['2', '4']));
    await mount(tester, state, full: true, size: const Size(780, 540));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('最近关闭'), findsOneWidget);
    await tester.tap(find.text('最近关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('closed-tab-4')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('Command Shift T restores newest tab without sending an id', (
    tester,
  ) async {
    final native = TabFixture();
    final state = fixture(native, workspace([], closed: ['2', '4']));
    native.response = (method, _) async =>
        method == 'reader.reopen' ? workspace(['4'], closed: ['2']) : {};
    await mount(tester, state, full: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expectCalls(
      native.calls.where((call) => call.$1 == 'reader.reopen').toList(),
      [('reader.reopen', <String, dynamic>{})],
    );
    expect(state.workspace.selectedTab, '4');
    await cleanup(tester, state);
  });

  test('tab mutations serialize and use the latest native ordering', () async {
    final native = TabFixture(), moved = Completer<JsonMap>();
    final state = fixture(native);
    native.response = (method, args) async => args['id'] == '1'
        ? moved.future
        : workspace(['3', '2', '1'], selected: '2');
    final first = state.moveTopic('1', '3');
    final second = state.moveTopic('3', '2');
    await Future<void>.delayed(Duration.zero);
    expectCalls(native.calls, [
      ('reader.move', {'id': '1', 'to': '3'}),
    ]);
    moved.complete(workspace(['2', '3', '1'], selected: '2'));
    expect(await first, true);
    expect(await second, true);
    expectCalls(native.calls, [
      ('reader.move', {'id': '1', 'to': '3'}),
      ('reader.move', {'id': '3', 'to': '2'}),
    ]);
    expect(state.workspace.tabs.map((tab) => tab.id), ['3', '2', '1']);
    expect(state.changingTabs, false);
    state.dispose();
  });

  test('queued mutation is cancelled after an account switch', () async {
    final native = TabFixture(), moved = Completer<JsonMap>();
    final state = fixture(native);
    native.response = (_, _) => moved.future;
    final first = state.moveTopic('1', '3');
    final second = state.moveTopic('3', '2');
    await Future<void>.delayed(Duration.zero);
    native.accessRevision++;
    moved.complete(workspace(['2', '3', '1'], selected: '2'));
    expect(await first, false);
    expect(await second, false);
    expect(native.calls.length, 1);
    expect(state.workspace.tabs.map((tab) => tab.id), ['1', '2', '3']);
    state.dispose();
  });

  test(
    'reopening does not block further tab operations on reader loading',
    () async {
      final native = TabFixture(), loaded = Completer<JsonMap>();
      final state = fixture(native, workspace(['1', '3'], closed: ['2']));
      native.response = (method, _) async => switch (method) {
        'reader.reopen' => workspace(['1', '2', '3'], selected: '2'),
        'reader.load' => loaded.future,
        'reader.move' => workspace(['2', '3', '1'], selected: '2'),
        _ => {},
      };
      expect(await state.reopenTopic('2'), true);
      expect(await state.moveTopic('1', '3'), true);
      expect(native.calls.map((call) => call.$1), [
        'reader.reopen',
        'reader.load',
        'reader.move',
      ]);
      loaded.complete({});
      await Future<void>.delayed(Duration.zero);
      state.dispose();
    },
  );
  testWidgets(
    'background-only tabs have no manufactured selection and first tab opens on click',
    (tester) async {
      final native = TabFixture();
      final state = fixture(native, {
        ...workspace(['1', '2']),
        'selectedTab': '',
        'showReader': false,
      });
      native.response = (method, args) async => method == 'reader.select'
          ? workspace(['1', '2'], selected: args['id'] as String)
          : {};
      await mount(tester, state);
      expect(
        find.byKey(const ValueKey('workspace-tabs-unselected')),
        findsOneWidget,
      );
      expect(find.byType(GlassSegmentedControl), findsNothing);
      expect(state.workspace.selected, isNull);
      await tester.tap(find.text('Post 1'));
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'reader.select'),
        hasLength(1),
      );
      expect(state.workspace.selectedTab, '1');
      expect(find.byType(GlassSegmentedControl), findsOneWidget);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
  );

  testWidgets('neutral and selected six-tab tracks keep the same surface', (
    tester,
  ) async {
    final native = TabFixture();
    const ids = ['1', '2', '3', '4', '5', '6'];
    final state = fixture(native, {
      ...workspace(ids),
      'selectedTab': '',
      'showReader': false,
    });
    await mount(tester, state, size: const Size(640, 700));
    final neutral = tester.widget<Container>(
      find.byKey(const ValueKey('workspace-tabs-unselected')),
    );
    final neutralColor = (neutral.decoration! as BoxDecoration).color;
    final neutralHeight = tester
        .getSize(find.byKey(const ValueKey('workspace-tabs-unselected')))
        .height;
    expect(state.workspace.selected, isNull);
    expect(state.workspace.tabs.map((tab) => tab.id), ids);
    state.domains['workspace'] = workspace(ids, selected: '6');
    state.showMessage('Local selection snapshot');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final control = tester.widget<GlassSegmentedControl>(
      find.byType(GlassSegmentedControl),
    );
    expect(control.backgroundColor, neutralColor);
    expect(control.height, neutralHeight);
    expect(control.segments.map((segment) => segment.id), ids);
    expect(control.selectedIndex, 5);
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('six labels fit the track height at text scale $scale', (
      tester,
    ) async {
      final native = TabFixture();
      const ids = ['1', '2', '3', '4', '5', '6'];
      final state = fixture(native, {
        ...workspace(ids, selected: '6', closed: ['7']),
        'tabs': [
          for (final id in ids) {...tab(id), 'title': '第$id个标签：晚高峰的线路实测与记录'},
        ],
      });
      await mount(tester, state, size: const Size(640, 700), textScale: scale);
      await tester.pump(const Duration(milliseconds: 250));
      final control = tester.widget<GlassSegmentedControl>(
        find.byType(GlassSegmentedControl),
      );
      expect(control.height, scale == 1 ? 34 : 45);
      final target = find.byKey(const ValueKey('tab-target-6')).first;
      final title = find
          .descendant(of: target, matching: find.text('第6个标签：晚高峰的线路实测与记录'))
          .first;
      final trackRect = tester.getRect(find.byType(GlassSegmentedControl));
      final titleRect = tester.getRect(title);
      expect(titleRect.top, greaterThanOrEqualTo(trackRect.top + 2));
      expect(titleRect.bottom, lessThanOrEqualTo(trackRect.bottom - 2));
      expect(
        tester.getSize(find.byKey(const ValueKey('tab-drag-6')).first),
        const Size(22, 22),
      );
      final recent = tester.widget<DeskButton>(
        find.byWidgetPredicate(
          (widget) => widget is DeskButton && widget.label == '最近关闭',
        ),
      );
      expect(recent.quiet, isTrue);
      expect(recent.height, control.height);
      expect(state.workspace.tabs.map((tab) => tab.id), ids);
      expect(state.workspace.selectedTab, '6');
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    });
  }

  testWidgets(
    'six-tab reflow and drag highlight respect the glass motion scope',
    (tester) async {
      final native = TabFixture();
      final state = fixture(
        native,
        workspace(['1', '2', '3', '4', '5', '6'], selected: '6'),
      );
      await mount(tester, state, reduceMotion: true);
      final control = tester.widget<GlassSegmentedControl>(
        find.byType(GlassSegmentedControl),
      );
      expect(control.regridDuration, Duration.zero);
      for (final id in ['1', '2', '3', '4', '5', '6']) {
        final target = tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('tab-target-$id')).first,
        );
        expect(target.duration, Duration.zero);
      }
      expect(native.calls, isEmpty);
      await cleanup(tester, state);
    },
  );
}
