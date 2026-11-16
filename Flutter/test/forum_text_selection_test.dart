// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

class _SelectionFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (method == 'external.open') return {};
    throw StateError('Selection fixtures must not call real services: $method');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var clipboard = '';

  setUp(() {
    clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = stringValue(jsonMap(call.arguments)['text']);
          } else if (call.method == 'Clipboard.getData') {
            return {'text': clipboard};
          } else if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard.isNotEmpty};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: Padding(padding: const EdgeInsets.all(40), child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  Finder paragraph(String text) => find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == text,
  );

  Offset textPoint(WidgetTester tester, String text, int offset) {
    final render = tester.renderObject<RenderParagraph>(paragraph(text));
    final glyph = offset.clamp(0, text.length - 1);
    final box = render
        .getBoxesForSelection(
          TextSelection(baseOffset: glyph, extentOffset: glyph + 1),
        )
        .first;
    final caret = render.getOffsetForCaret(
      TextPosition(offset: offset),
      Rect.zero,
    );
    return render.localToGlobal(Offset(caret.dx + 1, box.toRect().center.dy));
  }

  Future<void> command(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  testWidgets(
    'body uses one paragraph region and supports Cmd+A/C across blocks',
    (tester) async {
      final native = _SelectionFixture();
      final state = AppState(client: native);
      await mount(
        tester,
        ForumBlocks(
          state: state,
          blocks: const [
            {'kind': 'paragraph', 'text': 'First **bold** paragraph.'},
            {'kind': 'paragraph', 'text': 'Second paragraph.'},
          ],
        ),
      );
      expect(find.byType(SelectableRegion), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      await tester.tapAt(textPoint(tester, 'First bold paragraph.', 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('First bold paragraph.'));
      expect(clipboard, contains('Second paragraph.'));
      expect(clipboard, isNot(contains('**')));
      expect(
        clipboard.indexOf('First bold paragraph.'),
        lessThan(clipboard.indexOf('Second paragraph.')),
      );
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('mouse drag selects across paragraphs without opening links', (
    tester,
  ) async {
    final native = _SelectionFixture();
    final state = AppState(client: native);
    await mount(
      tester,
      ForumBlocks(
        state: state,
        blocks: const [
          {'kind': 'paragraph', 'text': 'Alpha first paragraph.'},
          {
            'kind': 'paragraph',
            'text': 'Beta [reference](https://example.com/reference) end.',
          },
        ],
      ),
    );
    final mouse = await tester.startGesture(
      textPoint(tester, 'Alpha first paragraph.', 0),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(textPoint(tester, 'Beta reference end.', 19));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    await command(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, contains('Alpha first paragraph.'));
    expect(clipboard, contains('Beta reference end.'));
    expect(native.calls, isEmpty);
    await mouse.removePointer();
    await cleanup(tester, state);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'right-click Copy works under CupertinoApp without Material locale',
    (tester) async {
      final state = AppState(client: _SelectionFixture());
      await mount(
        tester,
        InlineMarkdown(
          state: state,
          text: 'Alpha selectable message.',
          style: const TextStyle(fontSize: 16),
        ),
      );
      final mouse = await tester.startGesture(
        textPoint(tester, 'Alpha selectable message.', 2),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(clipboard, 'Alpha');
      expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsNothing);
      await mouse.down(textPoint(tester, 'Alpha selectable message.', 8));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsOneWidget);
      await mouse.removePointer();
      await cleanup(tester, state);
      await tester.pump();
      expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final preview in [false, true]) {
    testWidgets(
      '${preview ? 'preview' : 'standalone'} markdown preserves nested emphasis link pointer, AX and copy',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final native = _SelectionFixture();
          final state = AppState(client: native);
          await mount(
            tester,
            preview
                ? MarkdownDocument(
                    state: state,
                    text: '[***Reference***](https://example.com/reference)',
                  )
                : InlineMarkdown(
                    state: state,
                    text: '[***Reference***](https://example.com/reference)',
                    style: const TextStyle(fontSize: 16),
                  ),
          );
          expect(find.byType(SelectableRegion), findsOneWidget);
          expect(find.byType(EditableText), findsNothing);
          // TextSpan creates a virtual child semantics node. An element finder
          // resolves the enclosing RenderParagraph node, not that actionable link.
          final link = find.semantics.byLabel('Reference');
          expect(link, findsOneWidget);
          final node = link.evaluate().single;
          final data = node.getSemanticsData();
          expect(data.flagsCollection.isLink, isTrue);
          expect(data.hasAction(SemanticsAction.tap), isTrue);
          await tester.tapAt(textPoint(tester, 'Reference', 2));
          await tester.pump();
          expect(native.calls.single.$1, 'external.open');
          expect(native.calls.single.$2, {
            'url': 'https://example.com/reference',
          });
          tester
              .renderObject(paragraph('Reference'))
              .owner!
              .semanticsOwner!
              .performAction(node.id, SemanticsAction.tap);
          await tester.pump();
          expect(native.calls.length, 2);
          expect(native.calls.last.$1, 'external.open');
          final mouse = await tester.startGesture(
            textPoint(tester, 'Reference', 2),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await mouse.up();
          await tester.pumpAndSettle();
          expect(
            find.byType(CupertinoDesktopTextSelectionToolbar),
            findsOneWidget,
          );
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          expect(clipboard, 'Reference');
          expect(native.calls.length, 2);
          await mouse.removePointer();
          expect(tester.takeException(), isNull);
          await cleanup(tester, state);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'nested tabs and disclosure share body selection and omit controls',
    (tester) async {
      final native = _SelectionFixture();
      final state = AppState(client: native);
      await mount(
        tester,
        ForumBlocks(
          state: state,
          reportKind: 'tq',
          blocks: const [
            {'kind': 'paragraph', 'text': 'Outer body.'},
            {
              'kind': 'tabs',
              'tabs': [
                {
                  'label': 'Tab Alpha',
                  'blocks': [
                    {'kind': 'paragraph', 'text': 'Selected tab body.'},
                  ],
                },
                {
                  'label': 'Tab Beta',
                  'blocks': [
                    {'kind': 'paragraph', 'text': 'Other tab body.'},
                  ],
                },
              ],
            },
            {
              'kind': 'disclosure',
              'text': 'Show details',
              'blocks': [
                {'kind': 'paragraph', 'text': 'Expanded body.'},
              ],
            },
          ],
        ),
      );
      await tester.tap(find.text('Show details'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableRegion), findsOneWidget);
      await tester.tapAt(textPoint(tester, 'Outer body.', 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('Outer body.'));
      expect(clipboard, contains('Selected tab body.'));
      expect(clipboard, contains('Expanded body.'));
      for (final excluded in [
        'Tab Alpha',
        'Tab Beta',
        'Other tab body.',
        'Show details',
        '100%',
        '重置',
      ]) {
        expect(clipboard, isNot(contains(excluded)));
      }
      await tester.tap(find.text('Tab Beta'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableRegion), findsOneWidget);
      await tester.tapAt(textPoint(tester, 'Outer body.', 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('Other tab body.'));
      expect(clipboard, isNot(contains('Selected tab body.')));
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a selected lazy floor survives eviction until focus leaves its body',
    (tester) async {
      final native = _SelectionFixture();
      final state = AppState(client: native);
      final scroll = ScrollController();
      await mount(
        tester,
        CustomScrollView(
          controller: scroll,
          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => RepaintBoundary(
                  key: ValueKey('floor-$index'),
                  child: SizedBox(
                    height: 220,
                    child: ForumBlocks(
                      state: state,
                      blocks: [
                        {'kind': 'paragraph', 'text': 'Floor $index first.'},
                        {'kind': 'paragraph', 'text': 'Floor $index second.'},
                      ],
                    ),
                  ),
                ),
                childCount: 40,
              ),
            ),
          ],
        ),
      );
      Finder floor(int index) =>
          find.byKey(ValueKey('floor-$index'), skipOffstage: false);
      Finder selectionIn(int index) => find.descendant(
        of: floor(index),
        matching: find.byType(SelectableRegion, skipOffstage: false),
        skipOffstage: false,
      );
      final originalRegion = tester.state<SelectableRegionState>(
        selectionIn(1),
      );
      await tester.tapAt(textPoint(tester, 'Floor 1 first.', 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('Floor 1 first.'));
      expect(clipboard, contains('Floor 1 second.'));
      clipboard = '';

      scroll.jumpTo(25 * 220);
      await tester.pumpAndSettle();
      expect(
        floor(0),
        findsNothing,
        reason: 'Unfocused floors must be evicted.',
      );
      expect(originalRegion.mounted, isTrue);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('Floor 1 first.'));
      expect(clipboard, contains('Floor 1 second.'));

      scroll.jumpTo(220);
      await tester.pumpAndSettle();
      expect(
        tester.state<SelectableRegionState>(selectionIn(1)),
        originalRegion,
      );
      clipboard = '';
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('Floor 1 second.'));
      tester.widget<SelectableRegion>(selectionIn(1)).focusNode!.unfocus();
      await tester.pump();
      scroll.jumpTo(25 * 220);
      await tester.pumpAndSettle();
      expect(floor(1), findsNothing);
      expect(originalRegion.mounted, isFalse);
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
      scroll.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'code keeps independent text selection without leaking into body copy',
    (tester) async {
      final state = AppState(client: _SelectionFixture());
      const code =
          'print("code only");\n'
          'const longLine = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";';
      await mount(
        tester,
        ForumBlocks(
          state: state,
          blocks: const [
            {'kind': 'paragraph', 'text': 'Ordinary body.'},
            {'kind': 'code', 'text': code},
          ],
        ),
      );
      await tester.tapAt(textPoint(tester, 'Ordinary body.', 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, 'Ordinary body.');
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(SelectableRegion), findsNWidgets(2));
      await tester.tapAt(textPoint(tester, code, 2));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, code);
      final horizontal = tester.state<ScrollableState>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      horizontal.position.jumpTo(horizontal.position.maxScrollExtent);
      await tester.pump();
      clipboard = '';
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, code);
      expect(tester.takeException(), isNull);
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
