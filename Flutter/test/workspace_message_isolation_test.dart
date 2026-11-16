// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/workspace_message.dart';

import 'workspace_reader_test.dart' as reader;

class _MessageState extends AppState {
  _MessageState({required super.client});
  void publish() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1100, 700),
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(size: size, textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump();
  }

  for (final size in [const Size(240, 180), const Size(780, 540)]) {
    for (final scale in [1.0, 2.5]) {
      testWidgets('long feedback stays bounded at $size / text scale $scale', (
        tester,
      ) async {
        final state = AppState(client: reader.ReaderFixture())
          ..connecting = false;
        final message = '请重试保存，已经保留当前草稿。' * 60;
        state.message = message;
        await mount(
          tester,
          CupertinoPageScaffold(
            child: Stack(
              children: [
                const Positioned.fill(child: SizedBox.expand()),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: WorkspaceMessage(state: state),
                ),
              ],
            ),
          ),
          size: size,
          scale: scale,
        );
        final feedback = find.byType(WorkspaceMessage);
        final scroll = find.descendant(
          of: feedback,
          matching: find.byType(SingleChildScrollView),
        );
        final rect = tester.getRect(scroll);
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(size.width - 16));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 16));
        expect(rect.height, lessThanOrEqualTo(size.height * .3));
        expect(find.text(message), findsOneWidget);
        final semantics = find.descendant(
          of: feedback,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.liveRegion == true,
          ),
        );
        expect(semantics, findsOneWidget);
        await tester.drag(scroll, const Offset(0, -40));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await cleanup(tester, state);
      });
    }
  }

  testWidgets(
    'showing, replacing and expiring feedback does not rebuild the workspace reader',
    (tester) async {
      final native = reader.ReaderFixture();
      native.response = (method, _) async =>
          method == 'reader.load' ? reader.threadSnapshot() : {};
      final state = AppState(client: native)..connecting = false;
      state.domains['workspace'] = {
        'tabs': [
          {'id': '17', 'url': reader.topicURL, 'title': 'Reader fixture'},
        ],
        'selectedTab': '17',
        'showReader': true,
        'posts': <JsonMap>[],
        'boards': [
          {'id': 'home', 'title': '首页'},
        ],
      };
      state.domains['session'] = {
        'account': 'signedIn',
        'owner': 1,
        'accessRevision': 0,
      };
      state.domains['settings'] = {'appearance': 'light'};
      state.readers[reader.topicURL] = reader.threadSnapshot();
      await mount(tester, WorkspaceScreen(state: state));
      final readerWidget = tester.widget<ReaderScreen>(
        find.byType(ReaderScreen),
      );
      final readerElement = tester.element(find.byType(ReaderScreen));
      final rebuilt = <Type>[];
      final previousHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousHook?.call(element, builtOnce);
        if (element.widget is WorkspaceScreen ||
            element.widget is ReaderScreen ||
            element.widget is ForumBlocks) {
          rebuilt.add(element.widget.runtimeType);
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousHook);

      state.showMessage('First feedback');
      await tester.pumpAndSettle();
      expect(find.text('First feedback'), findsOneWidget);
      state.showMessage('Second feedback');
      await tester.pumpAndSettle();
      expect(find.text('First feedback'), findsNothing);
      expect(find.text('Second feedback'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Second feedback'), findsNothing);
      expect(rebuilt, isEmpty);
      expect(
        tester.widget<ReaderScreen>(find.byType(ReaderScreen)),
        same(readerWidget),
      );
      expect(tester.element(find.byType(ReaderScreen)), same(readerElement));
      expect(find.text('A short fixture paragraph.'), findsOneWidget);
      expect(native.calls.where((call) => call.$1 == 'reader.load'), isEmpty);
      expect(tester.takeException(), isNull);
      debugOnRebuildDirtyWidget = previousHook;
      await cleanup(tester, state);
    },
  );

  testWidgets('feedback swaps subscriptions when its AppState owner changes', (
    tester,
  ) async {
    final first = _MessageState(client: reader.ReaderFixture())
      ..message = 'First owner';
    final second = _MessageState(client: reader.ReaderFixture())
      ..message = 'Second owner';
    var current = first;
    late StateSetter rebuild;
    await mount(
      tester,
      CupertinoPageScaffold(
        child: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return WorkspaceMessage(state: current);
          },
        ),
      ),
    );
    expect(find.text('First owner'), findsOneWidget);
    rebuild(() => current = second);
    await tester.pumpAndSettle();
    expect(find.text('Second owner'), findsOneWidget);
    first.message = 'Retired owner';
    first.publish();
    await tester.pumpAndSettle();
    expect(find.text('Retired owner'), findsNothing);
    second.message = 'Current owner';
    second.publish();
    await tester.pumpAndSettle();
    expect(find.text('Current owner'), findsOneWidget);
    expect(tester.takeException(), isNull);
    first.dispose();
    await cleanup(tester, second);
  });
}
