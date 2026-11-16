import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

class _MarkupNative extends NativeClient {
  final calls = <(String, JsonMap)>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'external.open') return {};
    throw StateError('Unexpected fixture request: $method');
  }
}

void main() {
  final fixtures = jsonItems(
    jsonDecode(File('../Tests/Fixtures/forum-markup.json').readAsStringSync()),
  );

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: Padding(padding: const EdgeInsets.all(24), child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder paragraph(String text) => find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == text,
  );

  Offset point(WidgetTester tester, String text) {
    final render = tester.renderObject<RenderParagraph>(paragraph(text));
    final box = render
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first;
    return render.localToGlobal(box.toRect().center);
  }

  for (final fixture in fixtures) {
    testWidgets('native DTO displays ${fixture['name']}', (tester) async {
      final native = _MarkupNative();
      final state = AppState(client: native);
      await mount(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ForumBlocks(state: state, blocks: jsonItems(fixture['blocks'])),
            if (fixture['signatureMarkdown'] != null)
              InlineMarkdown(
                state: state,
                text: stringValue(fixture['signatureMarkdown']),
                style: const TextStyle(fontSize: 16),
              ),
          ],
        ),
      );
      if (fixture['disclosure'] != null) {
        await tester.tap(find.text(stringValue(fixture['disclosure'])));
        await tester.pumpAndSettle();
      }
      for (final text in fixture['visible'] as List) {
        expect(paragraph(text as String), findsOneWidget);
      }
      if (fixture['signatureVisible'] != null) {
        expect(
          paragraph(stringValue(fixture['signatureVisible'])),
          findsOneWidget,
        );
      }
      if (fixture['link'] != null) {
        final text = (fixture['visible'] as List).single as String;
        await tester.tapAt(point(tester, text));
        await tester.pump();
        expect(native.calls, hasLength(1));
        expect(native.calls.single.$1, 'external.open');
        expect(native.calls.single.$2, {'url': fixture['link']});
      } else {
        await tester.tapAt(point(tester, (fixture['visible'] as List).first));
        await tester.pump();
        expect(native.calls, isEmpty);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets('raw inline Markdown decodes entities once and preserves code', (
    tester,
  ) async {
    final state = AppState(client: _MarkupNative());
    const source =
        r'"A & B" &quot; &#34; &#x1F525; &amp;quot; '
        r'\&quot; `&quot; <T> \path` **&lt;T&gt;**';
    const visible =
        '"A & B" " " 🔥 &quot; '
        r'&quot; &quot; <T> \path <T>';
    await mount(
      tester,
      InlineMarkdown(
        state: state,
        text: source,
        style: const TextStyle(fontSize: 16),
      ),
    );
    expect(paragraph(visible), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('selection copies visible characters without encoded artifacts', (
    tester,
  ) async {
    final native = _MarkupNative();
    final state = AppState(client: native);
    final fixture = fixtures[1];
    final visible = (fixture['visible'] as List).single as String;
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
    await mount(
      tester,
      ForumBlocks(state: state, blocks: jsonItems(fixture['blocks'])),
    );
    expect(paragraph(visible), findsOneWidget);
    await tester.tapAt(point(tester, visible));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, visible);
    expect(native.calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
