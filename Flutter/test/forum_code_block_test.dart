import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_code_block.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_document.dart';

class _NoNetwork extends NativeClient {
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) =>
      throw StateError('Unexpected native request: $method');
}

class _AccessClient extends NativeClient {
  final eventsStream = StreamController<JsonMap>.broadcast(sync: true);

  @override
  Stream<JsonMap> get snapshots => eventsStream.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method == 'bootstrap') {
      return {
        'session': {'account': 'signedIn', 'owner': 1, 'accessRevision': 0},
      };
    }
    throw StateError('Unexpected request: $method');
  }

  void changeAccount() => eventsStream.add({
    'domain': 'session',
    'accessRevision': accessRevision + 1,
    'data': {'account': 'signedIn', 'owner': 2},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    await tester.pumpWidget(
      CupertinoApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: child!,
          ),
        ),
        home: CupertinoPageScaffold(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.binding.setSurfaceSize(null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets('copy waits for clipboard success and preserves code exactly', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    final completion = Completer<void>();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
          await completion.future;
        }
        return null;
      },
    );
    const source = '<script> &quot; \\path\n  缩进 😃\n';
    await mount(tester, ForumCodeBlock(state: state, text: source));
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(copied, source);
    expect(find.text('已复制'), findsNothing);
    completion.complete();
    await tester.pump();
    expect(find.text('已复制'), findsOneWidget);
    expect(state.message, isNull);
    await cleanup(tester, state);
  });

  testWidgets('failed copy reports an error without claiming success', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    await mount(tester, ForumCodeBlock(state: state, text: 'value'));
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(find.text('已复制'), findsNothing);
    expect(state.message, contains('复制失败'));
    await cleanup(tester, state);
  });

  testWidgets('wide code scrolls horizontally in a narrow large-text pane', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    await mount(
      tester,
      ForumCodeBlock(
        state: state,
        text: 'const longValue = "${'abc ' * 80}";',
        language: 'dart',
      ),
      scale: 2,
    );
    final scroll = find.byType(SingleChildScrollView);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(scroll),
        scrollDelta: const Offset(120, 0),
      ),
    );
    await tester.pump();
    expect(position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
    await cleanup(tester, state);
  });

  testWidgets('successful copy label stays complete with large text', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    await mount(tester, ForumCodeBlock(state: state, text: 'value'), scale: 2);
    await tester.tap(find.text('复制'));
    await tester.pump();
    final label = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text('已复制'), matching: find.byType(RichText)),
    );
    expect(label.didExceedMaxLines, isFalse);
    await cleanup(tester, state);
  });

  testWidgets('retained copy action cannot claim old code for a new account', (
    tester,
  ) async {
    final native = _AccessClient();
    final state = AppState(client: native);
    var copies = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copies++;
        return null;
      },
    );
    await state.connect();
    await mount(tester, ForumCodeBlock(state: state, text: 'old account code'));
    final action = tester.widget<DeskButton>(find.byType(DeskButton)).onTap!;
    native.changeAccount();
    action(); // Deliberately before the old source can unmount next frame.
    await tester.pump();
    expect(copies, 0);
    expect(find.byType(DeskButton), findsNothing);
    expect(find.text('已复制'), findsNothing);
    await cleanup(tester, state);
    await native.eventsStream.close();
  });

  for (final fail in [false, true]) {
    testWidgets(
      'covered source suppresses late clipboard ${fail ? 'error' : 'success'}',
      (tester) async {
        final state = AppState(client: _NoNetwork());
        final navigator = GlobalKey<NavigatorState>();
        final completion = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') await completion.future;
            return null;
          },
        );
        await mount(
          tester,
          ForumCodeBlock(state: state, text: 'value'),
          navigatorKey: navigator,
        );
        await tester.tap(find.text('复制'));
        await tester.pump();
        navigator.currentState!.push(
          CupertinoDialogRoute<void>(
            context: navigator.currentContext!,
            builder: (_) => const CupertinoAlertDialog(title: Text('Cover')),
          ),
        );
        await tester.pump();
        if (fail) {
          completion.completeError(PlatformException(code: 'unavailable'));
        } else {
          completion.complete();
        }
        await tester.pump();
        expect(state.message, isNull);
        expect(find.text('已复制', skipOffstage: false), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(
          tester.widget<DeskButton>(find.byType(DeskButton)).busy,
          isFalse,
        );
        await cleanup(tester, state);
      },
    );
  }

  testWidgets('replaced source ignores pending copy even if text returns', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    final completion = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') await completion.future;
        return null;
      },
    );
    await mount(tester, ForumCodeBlock(state: state, text: 'A'));
    await tester.tap(find.text('复制'));
    await tester.pump();
    await mount(tester, ForumCodeBlock(state: state, text: 'B'));
    await mount(tester, ForumCodeBlock(state: state, text: 'A'));
    completion.complete();
    await tester.pump();
    expect(find.text('已复制'), findsNothing);
    expect(tester.widget<DeskButton>(find.byType(DeskButton)).busy, isFalse);
    await cleanup(tester, state);
  });

  testWidgets('preview reuses parsed nodes until the document changes', (
    tester,
  ) async {
    final state = AppState(client: _NoNetwork());
    Future<void> preview(String text, double fontSize) => mount(
      tester,
      MarkdownDocument(state: state, text: text, fontSize: fontSize),
    );
    await preview('**first**', 15);
    final original = tester
        .widget<InlineNodeText>(find.byType(InlineNodeText))
        .nodes
        .first;
    await preview('**first**', 17);
    expect(
      identical(
        tester.widget<InlineNodeText>(find.byType(InlineNodeText)).nodes.first,
        original,
      ),
      isTrue,
    );
    await preview('**second**', 17);
    expect(
      identical(
        tester.widget<InlineNodeText>(find.byType(InlineNodeText)).nodes.first,
        original,
      ),
      isFalse,
    );
    await cleanup(tester, state);
  });
}
