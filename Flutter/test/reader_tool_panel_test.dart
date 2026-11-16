import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/reader_tool_panel.dart';

const _surface = ValueKey('reader-tool-surface');
const _input = ValueKey('fixture-tool-input');
const _close = ValueKey('fixture-tool-close');

/// The presentation must not need even a read request. Unexpected transport
/// calls fail teardown as well, so caught failures cannot conceal forum writes.
class _Native extends NativeClient {
  _Native()
    : super(methods: MethodChannel('seekdesk.test.tool-panel.${_next++}'));

  static int _next = 0;
  final calls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add(method);
    throw StateError('Tool presentation must not call native: $method');
  }
}

class _State extends AppState {
  _State(_Native native) : super(client: native) {
    connecting = false;
    domains['session'] = {'account': 'signedIn', 'owner': 71};
    domains['extensions'] = {
      'items': [
        {'id': 'value', 'active': true},
        {'id': 'rulings', 'active': true},
        {'id': 'office', 'active': false},
      ],
    };
    domains['workspace'] = {
      'showReader': true,
      'selectedTab': '91',
      'tabs': [
        {
          'id': '91',
          'url': 'https://www.nodeseek.com/post-91-1',
          'title': 'Retained local reading',
        },
      ],
    };
  }

  void changed() => notifyListeners();

  void invalidate(String cause) {
    switch (cause) {
      case 'revision':
        client.accessRevision++;
      case 'owner':
        domains['session'] = {...domain('session'), 'owner': 72};
      case 'account':
        domains['session'] = {...domain('session'), 'account': 'signedOut'};
      case 'extension':
        domains['extensions'] = {
          'items': [
            {'id': 'value', 'active': false},
            {'id': 'rulings', 'active': true},
          ],
        };
      case 'office':
        domains['extensions'] = {
          'items': [
            {'id': 'value', 'active': true},
            {'id': 'office', 'active': true},
          ],
          'settings': {
            'office': {'presented': true},
          },
        };
      default:
        throw StateError('Unknown local invalidation: $cause');
    }
    notifyListeners();
  }
}

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  final popped = <Route<dynamic>>[];
  final removed = <Route<dynamic>>[];

  List<RawDialogRoute<void>> get tools => pushed
      .where((route) => route.settings.name?.startsWith('reader-tool/') == true)
      .cast<RawDialogRoute<void>>()
      .toList();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removed.add(route);
  }
}

class _Fixture {
  _Fixture({required this.reducedMotion, required this.scale}) {
    state = _State(native);
  }

  final bool reducedMotion;
  final double scale;
  final native = _Native();
  late final _State state;
  final controller = ReaderToolPanelController();
  final secondController = ReaderToolPanelController();
  final navigator = GlobalKey<NavigatorState>();
  final sourceKey = GlobalKey();
  final routes = _Routes();
  final sourceFocus = FocusNode(debugLabel: 'Original reading focus');
  final nextFocus = FocusNode(debugLabel: 'New user-selected focus');
  final toolFocus = FocusNode(debugLabel: 'Tool input focus');
  final upperFocus = FocusNode(debugLabel: 'Upper currency menu focus');
  final sourceText = TextEditingController(text: 'Original reading selection');
  final draft = TextEditingController(text: 'Retained calculator fields');
  final readerScroll = ScrollController(initialScrollOffset: 320);
  bool sourceValid = true;

  static Future<_Fixture> mount(
    WidgetTester tester, {
    bool reducedMotion = false,
    double scale = 1,
    Size size = const Size(1100, 1000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    final fixture = _Fixture(reducedMotion: reducedMotion, scale: scale);
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          navigatorKey: fixture.navigator,
          navigatorObservers: [fixture.routes],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: Builder(
              key: fixture.sourceKey,
              builder: (_) => Column(
                children: [
                  CupertinoTextField(
                    focusNode: fixture.sourceFocus,
                    controller: fixture.sourceText,
                  ),
                  CupertinoTextField(
                    focusNode: fixture.nextFocus,
                    placeholder: 'Another reading action',
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: fixture.readerScroll,
                      itemExtent: 40,
                      itemCount: 100,
                      itemBuilder: (_, index) => Text('Reading floor $index'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> show({ReaderToolPanelController? using}) =>
      (using ?? controller).show(
        sourceKey.currentContext!,
        state: state,
        extensionID: 'value',
        title: 'Local calculator',
        canReturnToSource: () => sourceValid,
        builder: (context) => Column(
          children: [
            Row(
              children: [
                const Expanded(child: Text('工具', maxLines: 1)),
                CupertinoButton(
                  key: _close,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    CupertinoTextField(
                      key: _input,
                      focusNode: toolFocus,
                      controller: draft,
                      autofocus: true,
                    ),
                    const SizedBox(height: 800),
                    const Text('Tool scroll end'),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Future<void> expectRejectedShow(
    WidgetTester tester, {
    ReaderToolPanelController? using,
  }) async {
    var completed = false;
    final rejected = show(using: using).then((_) {
      completed = true;
    });
    await tester.pump();
    // Assert before awaiting, so a regression that opens a route fails here
    // instead of hanging the test while waiting for a dismissal that never came.
    expect(completed, isTrue);
    await rejected;
  }

  Future<void> finished(
    WidgetTester tester,
    Future<void> operation, {
    ReaderToolPanelController? using,
  }) async {
    await tester.pumpAndSettle();
    expect((using ?? controller).isOpen, isFalse);
    await operation;
  }

  RawDialogRoute<void> cover() {
    final route = RawDialogRoute<void>(
      settings: const RouteSettings(name: 'fixture-currency-menu'),
      transitionDuration: Duration.zero,
      requestFocus: true,
      barrierDismissible: false,
      pageBuilder: (_, _, _) => Center(
        child: SizedBox(
          width: 300,
          height: 140,
          child: CupertinoPageScaffold(
            child: Column(
              children: [
                const Text('Upper currency menu'),
                CupertinoTextField(
                  focusNode: upperFocus,
                  autofocus: true,
                  placeholder: 'Currency search',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(navigator.currentState!.push(route));
    return route;
  }

  Future<void> close(WidgetTester tester) async {
    controller.dispose();
    secondController.dispose();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    state.dispose();
    sourceFocus.dispose();
    nextFocus.dispose();
    toolFocus.dispose();
    upperFocus.dispose();
    sourceText.dispose();
    draft.dispose();
    readerScroll.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final close in ['header', 'outside', 'Escape']) {
    testWidgets('$close preserves draft, reader position and source focus', (
      tester,
    ) async {
      final fixture = await _Fixture.mount(tester);
      try {
        fixture.sourceFocus.requestFocus();
        await tester.pump();
        fixture.sourceText.selection = const TextSelection(
          baseOffset: 2,
          extentOffset: 7,
        );
        await tester.pump();
        final workspace = fixture.state.domain('workspace');
        final offset = fixture.readerScroll.offset;
        final opened = fixture.show();
        await tester.pumpAndSettle();
        expect(fixture.state.watchPopupDeferred.value, isTrue);
        expect(fixture.toolFocus.hasFocus, isTrue);
        await tester.enterText(find.byKey(_input), 'Keep these local inputs');
        switch (close) {
          case 'header':
            await tester.tap(find.byKey(_close));
          case 'outside':
            await tester.tapAt(const Offset(8, 8));
          case 'Escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await fixture.finished(tester, opened);
        expect(find.byType(ReaderToolPanel), findsNothing);
        expect(fixture.controller.isOpen, isFalse);
        expect(fixture.state.watchPopupDeferred.value, isFalse);
        expect(fixture.draft.text, 'Keep these local inputs');
        expect(fixture.readerScroll.offset, offset);
        expect(fixture.state.domain('workspace'), same(workspace));
        expect(fixture.sourceFocus.hasFocus, isTrue);
        expect(
          fixture.sourceText.selection,
          const TextSelection(baseOffset: 2, extentOffset: 7),
        );
        final reopened = fixture.show();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CupertinoTextField>(find.byKey(_input))
              .controller!
              .text,
          'Keep these local inputs',
        );
        fixture.controller.dismiss();
        await fixture.finished(tester, reopened);
      } finally {
        await fixture.close(tester);
      }
    });
  }

  testWidgets('duplicate opens stay blocked through the reverse transition', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    try {
      final leases = <bool>[];
      fixture.state.watchPopupDeferred.addListener(
        () => leases.add(fixture.state.watchPopupDeferred.value),
      );
      var completed = false;
      final opened = fixture.show().then((_) {
        completed = true;
      });
      await tester.pumpAndSettle();
      await fixture.expectRejectedShow(tester);
      await fixture.expectRejectedShow(tester, using: fixture.secondController);
      expect(fixture.routes.tools, hasLength(1));
      expect(fixture.secondController.isOpen, isFalse);
      await tester.tap(find.byKey(_close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(completed, isFalse);
      expect(fixture.controller.isOpen, isTrue);
      expect(fixture.state.watchPopupDeferred.value, isTrue);
      await fixture.expectRejectedShow(tester, using: fixture.secondController);
      expect(fixture.routes.tools, hasLength(1));
      await fixture.finished(tester, opened);
      expect(leases, [true, false]);
      final next = fixture.show(using: fixture.secondController);
      await tester.pumpAndSettle();
      expect(fixture.routes.tools, hasLength(2));
      fixture.secondController.dismiss();
      await fixture.finished(tester, next, using: fixture.secondController);
      expect(leases, [true, false, true, false]);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets('dismissal releases only the tool notification lease', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    final releaseOther = fixture.state.deferWatchPopup();
    try {
      final opened = fixture.show();
      await tester.pumpAndSettle();
      fixture.controller.dismiss();
      await fixture.finished(tester, opened);
      expect(fixture.state.watchPopupDeferred.value, isTrue);
      releaseOther();
      releaseOther();
      expect(fixture.state.watchPopupDeferred.value, isFalse);
    } finally {
      releaseOther();
      await fixture.close(tester);
    }
  });

  testWidgets('short narrow windows clamp the shell without replacing input', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester, scale: 2);
    try {
      final opened = fixture.show();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_surface)), const Size(620, 740));
      final editor = tester.element(find.byKey(_input));
      fixture.draft.value = const TextEditingValue(
        text: '输入内容',
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
        composing: TextRange(start: 1, end: 3),
      );
      await tester.pump();
      for (final size in [const Size(360, 240), const Size(460, 310)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(_surface));
        expect(rect.width, size.width - 32);
        expect(rect.height, size.height - 32);
        expect(rect.left, 16);
        expect(rect.top, 16);
        expect(tester.element(find.byKey(_input)), same(editor));
        expect(fixture.toolFocus.hasFocus, isTrue);
        expect(
          fixture.draft.selection,
          const TextSelection(baseOffset: 1, extentOffset: 3),
        );
        expect(
          fixture.draft.value.composing,
          const TextRange(start: 1, end: 3),
        );
        expect(find.byKey(_close).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      fixture.controller.dismiss();
      await fixture.finished(tester, opened);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets('reduced motion removes both entrance and dismissal animation', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester, reducedMotion: true);
    try {
      final opened = fixture.show();
      await tester.pumpAndSettle();
      expect(fixture.routes.tools.single.transitionDuration, Duration.zero);
      expect(
        fixture.routes.tools.single.reverseTransitionDuration,
        Duration.zero,
      );
      await tester.tap(find.byKey(_close));
      await fixture.finished(tester, opened);
      expect(fixture.controller.isOpen, isFalse);
      expect(fixture.state.watchPopupDeferred.value, isFalse);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets('Escape leaves composing input to IME then closes after commit', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    try {
      final opened = fixture.show();
      await tester.pumpAndSettle();
      fixture.draft.value = const TextEditingValue(
        text: '拼音',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(fixture.controller.isOpen, isTrue);
      expect(fixture.routes.popped, isEmpty);
      expect(fixture.draft.value.composing, const TextRange(start: 0, end: 2));
      fixture.draft.value = fixture.draft.value.copyWith(
        composing: TextRange.empty,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await fixture.finished(tester, opened);
      expect(fixture.controller.isOpen, isFalse);
      expect(fixture.draft.text, '拼音');
    } finally {
      await fixture.close(tester);
    }
  });

  for (final cause in ['revision', 'owner', 'account', 'extension', 'office']) {
    testWidgets(
      '$cause invalidation removes its tool but keeps the upper route',
      (tester) async {
        final fixture = await _Fixture.mount(tester);
        try {
          fixture.sourceFocus.requestFocus();
          await tester.pump();
          final opened = fixture.show();
          await tester.pumpAndSettle();
          final tool = fixture.routes.tools.single;
          final staleDismiss = tester
              .widget<ReaderToolPanel>(find.byType(ReaderToolPanel))
              .onDismiss;
          final upper = fixture.cover();
          await tester.pumpAndSettle();
          expect(fixture.upperFocus.hasFocus, isTrue);
          fixture.state.invalidate(cause);
          await fixture.finished(tester, opened);
          expect(fixture.routes.removed, contains(same(tool)));
          expect(fixture.routes.popped, isEmpty);
          expect(upper.isCurrent, isTrue);
          expect(find.text('Upper currency menu'), findsOneWidget);
          expect(find.byType(ReaderToolPanel), findsNothing);
          expect(fixture.upperFocus.hasFocus, isTrue);
          expect(fixture.sourceFocus.hasFocus, isFalse);
          expect(fixture.state.watchPopupDeferred.value, isFalse);
          staleDismiss();
          fixture.controller.dismiss();
          await tester.pumpAndSettle();
          expect(upper.isCurrent, isTrue);
          fixture.navigator.currentState!.pop();
          await tester.pumpAndSettle();
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'source retirement dismisses its tool without altering the reader',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        final workspace = fixture.state.domain('workspace');
        final offset = fixture.readerScroll.offset;
        final opened = fixture.show();
        await tester.pumpAndSettle();
        fixture.sourceValid = false;
        fixture.state.changed();
        await fixture.finished(tester, opened);
        expect(fixture.controller.isOpen, isFalse);
        expect(fixture.state.watchPopupDeferred.value, isFalse);
        expect(fixture.state.domain('workspace'), same(workspace));
        expect(fixture.readerScroll.offset, offset);
        await fixture.expectRejectedShow(tester);
        expect(fixture.routes.tools, hasLength(1));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'controller disposal under a modal cannot pop or refocus that modal',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      try {
        final opened = fixture.show();
        await tester.pumpAndSettle();
        final tool = fixture.routes.tools.single;
        final upper = fixture.cover();
        await tester.pumpAndSettle();
        fixture.controller.dispose();
        await fixture.finished(tester, opened);
        expect(fixture.routes.removed, contains(same(tool)));
        expect(upper.isCurrent, isTrue);
        expect(fixture.upperFocus.hasFocus, isTrue);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await fixture.expectRejectedShow(tester);
        expect(fixture.routes.tools, hasLength(1));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets('a newer focus during reverse transition is never stolen back', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    try {
      fixture.sourceFocus.requestFocus();
      await tester.pump();
      final opened = fixture.show();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_close));
      await tester.pump();
      fixture.nextFocus.requestFocus();
      await tester.pump(const Duration(milliseconds: 40));
      expect(fixture.nextFocus.hasFocus, isTrue);
      await fixture.finished(tester, opened);
      expect(fixture.nextFocus.hasFocus, isTrue);
      expect(fixture.sourceFocus.hasFocus, isFalse);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets('an attempted navigation alone does not dismiss a useful tool', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    try {
      final opened = fixture.show();
      await tester.pumpAndSettle();
      fixture.state.navigationRevision++;
      fixture.state.changed();
      await tester.pumpAndSettle();
      expect(fixture.controller.isOpen, isTrue);
      expect(fixture.routes.popped, isEmpty);
      expect(fixture.routes.removed, isEmpty);
      expect(fixture.draft.text, 'Retained calculator fields');
      await tester.tap(find.byKey(_close));
      await tester.pump();
      fixture.nextFocus.requestFocus();
      await fixture.finished(tester, opened);
      expect(fixture.nextFocus.hasFocus, isTrue);
    } finally {
      await fixture.close(tester);
    }
  });
}
