import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_context_menu.dart';
import 'package:seekdesk_flutter/widgets/workspace_tabs.dart';

import 'workspace_tabs_test.dart' as tabs;

class _MenuState extends AppState {
  _MenuState({required super.client});
  void publish() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late tabs.TabFixture native;
  late _MenuState state;
  late GlobalKey<NavigatorState> navigator;
  final clipboard = <String>[];

  void fixture() {
    native = tabs.TabFixture();
    state = _MenuState(client: native)..connecting = false;
    state.domains['workspace'] = tabs.workspace(['1', '2', '3'], selected: '2');
    state.domains['session'] = {'account': 'signedOut'};
    navigator = GlobalKey<NavigatorState>();
    clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(jsonMap(call.arguments)['text'] as String);
          }
          return null;
        });
  }

  tearDown(() {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1100, 700),
    double scale = 1,
    bool Function()? canInteract,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(size: size, textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: 850,
                child: WorkspaceTabs(state: state, canInteract: canInteract),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, [String id = '1']) async {
    final label = find
        .descendant(
          of: find.byKey(ValueKey('tab-target-$id')),
          matching: find.text('Post $id'),
        )
        .first;
    await tester.tap(label, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制帖子链接'), findsOneWidget);
    expect(state.watchPopupDeferred.value, isTrue);
  }

  Future<void> closeSurface(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  VoidCallback menuAction(WidgetTester tester, String label) => tester
      .widget<CupertinoButton>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(CupertinoButton),
            )
            .first,
      )
      .onPressed!;

  Future<void> upperRoute(WidgetTester tester) async {
    unawaited(
      navigator.currentState!.push(
        CupertinoPageRoute<void>(
          builder: (context) => const CupertinoPageScaffold(
            child: Center(child: Text('Upper route stays open')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final neutral in [false, true]) {
    testWidgets(
      'right-clicking a ${neutral ? 'neutral' : 'background'} tab preserves selection and closes only its target',
      (tester) async {
        fixture();
        state.domains['workspace'] = tabs.workspace([
          '1',
          '2',
          '3',
        ], selected: neutral ? '' : '2');
        native.response = (method, arguments) async => method == 'reader.close'
            ? tabs.workspace(
                ['2', '3'],
                selected: neutral ? '' : '2',
                closed: ['1'],
              )
            : {};
        await mount(tester);
        await open(tester);
        expect(state.workspace.selectedTab, neutral ? '' : '2');
        expect(native.calls, isEmpty);
        await tester.tap(find.text('关闭此标签'));
        await tester.pumpAndSettle();
        tabs.expectCalls(native.calls, [
          ('reader.close', {'id': '1'}),
        ]);
        expect(state.workspace.tabs.map((tab) => tab.id), ['2', '3']);
        expect(state.workspace.selectedTab, neutral ? '' : '2');
        expect(state.watchPopupDeferred.value, isFalse);
        expect(tester.takeException(), isNull);
        await closeSurface(tester);
      },
    );
  }

  testWidgets(
    'copy targets the background tab without selecting or loading it',
    (tester) async {
      fixture();
      await mount(tester);
      await open(tester);
      await tester.tap(find.text('复制帖子链接'));
      await tester.pumpAndSettle();
      expect(clipboard, ['https://www.nodeseek.com/post-1-1']);
      expect(native.calls, isEmpty);
      expect(state.workspace.selectedTab, '2');
      expect(state.watchPopupDeferred.value, isFalse);
      expect(state.message, '帖子链接已复制');
      await closeSurface(tester);
    },
  );

  for (final neutral in [false, true]) {
    testWidgets(
      'a retained ${neutral ? 'neutral' : 'selected'} tab menu entry cannot adopt a new account revision',
      (tester) async {
        fixture();
        state.domains['workspace'] = tabs.workspace([
          '1',
          '2',
          '3',
        ], selected: neutral ? '' : '2');
        await mount(tester);
        final target = find.byKey(const ValueKey('tab-target-1'));
        final entry = tester
            .widget<GestureDetector>(
              find
                  .ancestor(
                    of: target,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is GestureDetector &&
                          widget.onSecondaryTapUp != null,
                    ),
                  )
                  .first,
            )
            .onSecondaryTapUp!;
        final position = tester.getCenter(target);

        // Keep the same tab IDs and deliver the old pointer callback before
        // the account notification has had a frame to replace the rail.
        native.accessRevision++;
        state.publish();
        entry(
          TapUpDetails(kind: PointerDeviceKind.mouse, globalPosition: position),
        );
        expect(state.watchPopupDeferred.value, isFalse);
        await tester.pumpAndSettle();
        expect(find.text('复制帖子链接'), findsNothing);
        expect(native.calls, isEmpty);
        expect(clipboard, isEmpty);

        // The replacement rail still supports a fresh, explicit interaction.
        await open(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(state.watchPopupDeferred.value, isFalse);
        expect(tester.takeException(), isNull);
        await closeSurface(tester);
      },
    );
  }

  for (final blocker in ['upper route', 'interaction disabled']) {
    for (final failure in [false, true]) {
      testWidgets(
        'late clipboard ${failure ? 'failure' : 'success'} does not show feedback after $blocker',
        (tester) async {
          fixture();
          final pendingCopy = Completer<Object?>();
          var interactive = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method == 'Clipboard.setData') {
                  clipboard.add(jsonMap(call.arguments)['text'] as String);
                  return pendingCopy.future;
                }
                return null;
              });
          await mount(tester, canInteract: () => interactive);
          await open(tester);
          await tester.tap(find.text('复制帖子链接'));
          await tester.pumpAndSettle();
          expect(clipboard, ['https://www.nodeseek.com/post-1-1']);
          expect(state.watchPopupDeferred.value, isFalse);
          expect(state.message, isNull);

          if (blocker == 'upper route') {
            await upperRoute(tester);
          } else {
            interactive = false;
          }
          if (failure) {
            pendingCopy.completeError(PlatformException(code: 'copy-failed'));
          } else {
            pendingCopy.complete();
          }
          await tester.pumpAndSettle();
          expect(state.message, isNull);
          expect(native.calls, isEmpty);
          expect(state.workspace.selectedTab, '2');
          if (blocker == 'upper route') {
            expect(find.text('Upper route stays open'), findsOneWidget);
            expect(navigator.currentState!.canPop(), isTrue);
          }
          expect(tester.takeException(), isNull);
          await closeSurface(tester);
        },
      );
    }
  }

  testWidgets(
    'external open targets the background tab without moving reader selection',
    (tester) async {
      fixture();
      await mount(tester);
      await open(tester);
      await tester.tap(find.text('在 NodeSeek 打开'));
      await tester.pumpAndSettle();
      tabs.expectCalls(native.calls, [
        ('external.open', {'url': 'https://www.nodeseek.com/post-1-1'}),
      ]);
      expect(state.workspace.selectedTab, '2');
      expect(state.watchPopupDeferred.value, isFalse);
      await closeSurface(tester);
    },
  );

  testWidgets('Escape and clicking outside dismiss without mutating tabs', (
    tester,
  ) async {
    fixture();
    await mount(tester);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('复制帖子链接'), findsNothing);
    expect(state.watchPopupDeferred.value, isFalse);
    await open(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('复制帖子链接'), findsNothing);
    expect(state.watchPopupDeferred.value, isFalse);
    expect(native.calls, isEmpty);
    expect(clipboard, isEmpty);
    await closeSurface(tester);
  });

  testWidgets(
    'arrow keys and Enter choose an action without selecting the tab',
    (tester) async {
      fixture();
      await mount(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      tabs.expectCalls(native.calls, [
        ('external.open', {'url': 'https://www.nodeseek.com/post-1-1'}),
      ]);
      expect(state.workspace.selectedTab, '2');
      expect(state.watchPopupDeferred.value, isFalse);
      await closeSurface(tester);
    },
  );

  for (final invalidation in ['account', 'removed tab', 'office']) {
    for (final covered in [false, true]) {
      testWidgets(
        '$invalidation invalidates only its menu ${covered ? 'under another route' : 'while current'}',
        (tester) async {
          fixture();
          await mount(tester);
          await open(tester);
          final lateAction = menuAction(tester, '关闭此标签');
          if (covered) await upperRoute(tester);
          switch (invalidation) {
            case 'account':
              native.accessRevision++;
            case 'removed tab':
              state.domains['workspace'] = tabs.workspace([
                '2',
                '3',
              ], selected: '2');
            case 'office':
              state.domains['extensions'] = {
                'items': [
                  {'id': 'office', 'active': true},
                ],
                'settings': {
                  'office': {'presented': true},
                },
              };
          }
          state.publish();
          lateAction();
          await tester.pumpAndSettle();
          expect(find.text('复制帖子链接', skipOffstage: false), findsNothing);
          if (covered) {
            expect(find.text('Upper route stays open'), findsOneWidget);
            expect(navigator.currentState!.canPop(), isTrue);
          }
          expect(state.watchPopupDeferred.value, isFalse);
          expect(native.calls, isEmpty);
          expect(clipboard, isEmpty);
          expect(tester.takeException(), isNull);
          await closeSurface(tester);
        },
      );
    }
  }

  testWidgets(
    'a covered menu callback cannot pop or activate through the upper route',
    (tester) async {
      fixture();
      await mount(tester);
      await open(tester);
      final lateAction = menuAction(tester, '关闭此标签');
      await upperRoute(tester);
      lateAction();
      await tester.pumpAndSettle();
      expect(find.text('Upper route stays open'), findsOneWidget);
      expect(native.calls, isEmpty);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('复制帖子链接'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(state.watchPopupDeferred.value, isFalse);
      await closeSurface(tester);
    },
  );

  testWidgets(
    'restore menu is conditional and restores the last closed tab once',
    (tester) async {
      fixture();
      state.domains['workspace'] = tabs.workspace(
        ['1', '2', '3'],
        selected: '2',
        closed: ['4'],
      );
      native.response = (method, _) async => method == 'reader.reopen'
          ? tabs.workspace(['1', '2', '3', '4'], selected: '4')
          : {};
      state.readers['https://www.nodeseek.com/post-4-1'] = {
        'thread': {'title': 'Already cached'},
      };
      await mount(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      tabs.expectCalls(native.calls, [('reader.reopen', <String, dynamic>{})]);
      expect(state.workspace.selectedTab, '4');
      expect(state.watchPopupDeferred.value, isFalse);
      await open(tester);
      expect(find.text('恢复最近关闭的标签'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await closeSurface(tester);
    },
  );

  testWidgets('context menu remains bounded near the corner with large text', (
    tester,
  ) async {
    fixture();
    await tester.binding.setSurfaceSize(const Size(260, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: const Size(260, 180),
              textScaler: const TextScaler.linear(2.5),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: CupertinoButton(
                child: const Text('Open'),
                onPressed: () => showDeskContextMenu<String>(
                  context,
                  position: const Offset(258, 178),
                  entries: const [
                    DeskMenuEntry('copy', '复制帖子链接', CupertinoIcons.link),
                    DeskMenuEntry('open', '在 NodeSeek 打开', CupertinoIcons.link),
                    DeskMenuEntry('close', '关闭此标签', CupertinoIcons.xmark),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final scroll = find.byType(SingleChildScrollView);
    final rect = tester.getRect(scroll);
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(252));
    expect(rect.top, greaterThanOrEqualTo(8));
    expect(rect.bottom, lessThanOrEqualTo(172));
    await tester.drag(scroll, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await closeSurface(tester);
  });
}
