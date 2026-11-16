import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class BlockNativeFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? respond;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return await respond?.call(method, arguments) ?? {};
  }
}

final Uint8List pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: GlassAdaptiveScope(
          minQuality: GlassQuality.minimal,
          maxQuality: GlassQuality.minimal,
          child: CupertinoPageScaffold(
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );
  Finder icon(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskIcon && widget.label == label,
  );

  test(
    'NQ keeps long-image aspect ratio and TQ retains its accepted baseline',
    () {
      expect(
        ReportImageGeometry.size(
          const Size(1000, 6000),
          available: 900,
          kind: 'nq',
        ),
        const Size(640, 3840),
      );
      expect(
        ReportImageGeometry.size(
          const Size(1000, 6000),
          available: 400,
          kind: 'nq',
        ),
        const Size(400, 2400),
      );
      final tq = ReportImageGeometry.size(
        const Size(1000, 1000),
        available: 900,
        kind: 'tq',
        viewportHeight: 600,
      );
      expect(tq.width, closeTo(577.5, .001));
      expect(tq.height, closeTo(577.5, .001));
      expect(
        ReportImageGeometry.size(
          const Size(1000, 2000),
          available: 900,
          sticker: true,
        ),
        const Size(45, 90),
      );
    },
  );

  testWidgets('long NQ image reserves the same geometry before decoding', (
    tester,
  ) async {
    final native = BlockNativeFixture();
    final response = Completer<JsonMap>();
    native.respond = (method, args) async =>
        method == 'images.load' ? response.future : {};
    final state = AppState(client: native);
    final image = NativeForumImage(
      state: state,
      url: 'https://images.example/long.png',
      size: const {'width': 1000, 'height': 6000},
      reportKind: 'nq',
    );
    await mount(tester, image);
    final reserved = tester.getSize(find.byType(NativeForumImage));
    expect(reserved.height, 3840);
    response.complete({'bytes': pixel, 'width': 1000, 'height': 6000});
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(NativeForumImage)), reserved);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('same image URL reloads after an account revision changes', (
    tester,
  ) async {
    final native = BlockNativeFixture();
    native.respond = (method, args) async => method == 'images.load'
        ? {'bytes': pixel, 'width': 1, 'height': 1}
        : {};
    final state = AppState(client: native);
    Widget image() =>
        NativeForumImage(state: state, url: 'https://images.example/avatar');
    await mount(tester, image());
    expect(native.calls.where((call) => call.$1 == 'images.load').length, 1);
    native.accessRevision++;
    await mount(tester, image());
    expect(native.calls.where((call) => call.$1 == 'images.load').length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'ragged forum tables render every cell without Table assertions',
    (tester) async {
      final state = AppState(client: BlockNativeFixture());
      await mount(
        tester,
        ForumBlocks(
          state: state,
          blocks: const [
            {
              'kind': 'table',
              'rows': [
                ['A', 'B'],
                ['C'],
                ['D', 'E', 'F'],
              ],
            },
          ],
        ),
      );
      expect(find.text('F', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'a long colored terminal flows in the page and expands with font controls',
    (tester) async {
      final native = BlockNativeFixture();
      native.respond = (method, args) async => method == 'settings.update'
          ? {stringValue(args['key']): args['value']}
          : {};
      final state = AppState(client: native);
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = stringValue(jsonMap(call.arguments)['text']);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      final rows = List.generate(
        120,
        (index) => <JsonMap>[
          {
            'text': 'line $index',
            'foreground': 'rgb(224,108,117)',
            'background': 'rgba(12, 34, 56, 0.5)',
            'bold': true,
          },
        ],
      );
      final plain = List.generate(120, (index) => 'line $index').join('\n');
      Finder textFor(String content) => find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText() == content,
      );
      Future<void> command(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      }

      Future<void> focusText(String content) async {
        final render = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: textFor(content),
            matching: find.byType(RichText),
          ),
        );
        final glyph = render
            .getBoxesForSelection(
              const TextSelection(baseOffset: 1, extentOffset: 2),
            )
            .first;
        await tester.tapAt(render.localToGlobal(glyph.toRect().center));
        await tester.pump();
      }

      await mount(
        tester,
        ListenableBuilder(
          listenable: state,
          builder: (context, _) =>
              NativeTerminalReport(state: state, rows: rows),
        ),
      );
      final text = tester.widget<Text>(textFor(plain));
      final styled = (text.textSpan! as TextSpan).children!.single as TextSpan;
      final run = styled.children!.first as TextSpan;
      expect(run.style!.color, const Color(0xffe06c75));
      expect(run.style!.backgroundColor, const Color(0x800c2238));
      expect(run.style!.fontWeight, FontWeight.bold);
      expect(text.textScaler, TextScaler.noScaling);
      expect(text.textDirection, TextDirection.ltr);
      expect(text.strutStyle!.forceStrutHeight, isTrue);
      expect(text.strutStyle!.fontSize, 16);
      final reportPanel = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color ==
                const Color(0xff172033),
      );
      expect(tester.getSize(reportPanel).width, 640);
      expect(tester.getSize(reportPanel).height, closeTo(3102.72, .001));
      expect(
        tester.getSize(find.byType(NativeTerminalReport)).height,
        greaterThan(3000),
      );
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      await focusText(plain);
      await command(LogicalKeyboardKey.keyA);
      await command(LogicalKeyboardKey.keyC);
      expect(clipboard, plain);
      await tester.tap(icon('缩小报告'));
      await tester.pump();
      expect(state.domain('settings')['workspace.nqReportScale'], 90.0);
      expect(tester.getSize(reportPanel).width, 576);
      expect(tester.getSize(reportPanel).height, closeTo(2792.448, .001));
      await tester.tap(icon('放大报告'));
      await tester.pump();
      expect(tester.getSize(reportPanel).width, 640);
      clipboard = '';
      await tester.tap(button('复制报告'));
      await tester.pump();
      expect(clipboard, plain);
      await tester.tap(button('放大查看'));
      await tester.pumpAndSettle();
      expect(find.text('14 点'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(
        tester.widget<ListView>(find.byType(ListView)).itemExtent,
        closeTo(22.4, .0001),
      );
      expect(textFor('line 119'), findsNothing);
      final viewerRun =
          (tester.widget<Text>(textFor('line 0')).textSpan! as TextSpan)
                  .children!
                  .single
              as TextSpan;
      expect(viewerRun.style!.color, const Color(0xffe06c75));
      expect(viewerRun.style!.backgroundColor, const Color(0x800c2238));
      expect(viewerRun.style!.fontWeight, FontWeight.bold);
      await focusText('line 0');
      await command(LogicalKeyboardKey.keyA);
      await command(LogicalKeyboardKey.keyC);
      expect(clipboard, 'line 0');
      await tester.tap(icon('放大报告字号'));
      await tester.pump();
      expect(find.text('15 点'), findsOneWidget);
      expect(tester.widget<ListView>(find.byType(ListView)).itemExtent, 24);
      expect(
        tester.widget<Text>(textFor('line 0')).textSpan!.style!.fontSize,
        15,
      );
      clipboard = '';
      await tester.tap(button('复制报告'));
      await tester.pump();
      expect(clipboard, plain);
      final vertical = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ),
      );
      vertical.position.jumpTo(vertical.position.maxScrollExtent);
      await tester.pump();
      expect(textFor('line 119'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('report tabs reset nested disclosures and retain report kind', (
    tester,
  ) async {
    final state = AppState(client: BlockNativeFixture());
    await mount(
      tester,
      BlockTabs(
        state: state,
        fontSize: 15,
        reportKind: 'nq',
        tabs: const [
          {
            'label': '甲',
            'blocks': [
              {
                'kind': 'disclosure',
                'text': '展开甲',
                'blocks': [
                  {'kind': 'text', 'text': '甲正文'},
                ],
              },
            ],
          },
          {
            'label': '乙',
            'blocks': [
              {
                'kind': 'disclosure',
                'text': '展开乙',
                'blocks': [
                  {'kind': 'text', 'text': '乙正文'},
                ],
              },
            ],
          },
        ],
      ),
    );
    await tester.tap(find.text('展开甲'));
    await tester.pump();
    expect(find.text('甲正文', findRichText: true), findsOneWidget);
    expect(
      tester.widget<BlockDisclosure>(find.byType(BlockDisclosure)).reportKind,
      'nq',
    );
    final segments = tester.widget<GlassSegmentedControl>(
      find.byType(GlassSegmentedControl),
    );
    segments.onSegmentSelected(1);
    await tester.pump();
    expect(find.text('乙正文', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'closing an original image releases an unfinished request after it completes',
    (tester) async {
      final native = BlockNativeFixture();
      final response = Completer<JsonMap>();
      native.respond = (method, args) async =>
          method == 'images.load' ? response.future : {};
      final state = AppState(client: native);
      await mount(tester, const SizedBox.shrink());
      final context = tester.element(find.byType(CupertinoPageScaffold));
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => NativeImageViewer(
            state: state,
            url: 'https://images.example/full.png',
            thumbnail: pixel,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        native.calls
            .where((call) => call.$1 == 'images.load')
            .single
            .$2['kind'],
        'original',
      );
      await tester.tap(icon('关闭图片'));
      await tester.pumpAndSettle();
      final releases = native.calls
          .where((call) => call.$1 == 'images.release')
          .length;
      expect(releases, greaterThanOrEqualTo(1));
      response.complete({'bytes': pixel, 'width': 2000, 'height': 2000});
      await tester.pump();
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'images.release').length,
        greaterThan(releases),
      );
      expect(
        state.imageDimensions(
          'https://images.example/full.png',
          kind: 'original',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('an older image viewer does not release another active viewer', (
    tester,
  ) async {
    final native = BlockNativeFixture();
    final response = Completer<JsonMap>();
    native.respond = (method, args) async =>
        method == 'images.load' ? response.future : {};
    final state = AppState(client: native);
    Future<void> viewers({required bool first, required bool second}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: Stack(
              children: [
                if (first)
                  NativeImageViewer(
                    key: const ValueKey('first'),
                    state: state,
                    url: 'https://images.example/shared.png',
                    thumbnail: pixel,
                  ),
                if (second)
                  NativeImageViewer(
                    key: const ValueKey('second'),
                    state: state,
                    url: 'https://images.example/shared.png',
                    thumbnail: pixel,
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await viewers(first: true, second: true);
    expect(native.calls.where((call) => call.$1 == 'images.load').length, 1);
    await viewers(first: false, second: true);
    expect(native.calls.where((call) => call.$1 == 'images.release'), isEmpty);
    response.complete({'bytes': pixel, 'width': 2000, 'height': 2000});
    await tester.pump();
    await tester.pump();
    expect(native.calls.where((call) => call.$1 == 'images.release'), isEmpty);
    await viewers(first: false, second: false);
    expect(
      native.calls.where((call) => call.$1 == 'images.release'),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'repeated image URLs use unique Hero flights into the original viewer',
    (tester) async {
      final native = BlockNativeFixture();
      native.respond = (method, args) async => method == 'images.load'
          ? {'bytes': pixel, 'width': 100, 'height': 100}
          : {};
      final state = AppState(client: native);
      await mount(
        tester,
        Column(
          children: [
            for (var index = 0; index < 2; index++)
              NativeForumImage(
                key: ValueKey(index),
                state: state,
                url: 'https://images.example/repeated.png',
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
      expect(heroes.length, 2);
      expect(heroes[0].tag, isNot(heroes[1].tag));
      await tester.tap(find.byType(Hero).first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NativeImageViewer>(find.byType(NativeImageViewer))
            .heroTag,
        heroes[0].tag,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(icon('关闭图片'));
      await tester.pumpAndSettle();
      expect(find.byType(NativeImageViewer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
