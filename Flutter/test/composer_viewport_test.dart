// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/composer_preview.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

class _NoServices extends NativeClient {
  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async =>
      throw StateError('Viewport tests must not call a service: $method');
}

const _editorKey = ValueKey('viewport-editor');
Finder get _editor => find.byKey(_editorKey, skipOffstage: false);
Finder get _preview =>
    find.byType(ComposerMarkdownPreview, skipOffstage: false);
MarkdownDocument _document(WidgetTester tester) =>
    tester.widget<MarkdownDocument>(
      find.byType(MarkdownDocument, skipOffstage: false),
    );
ScrollController _previewScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.descendant(
        of: _preview,
        matching: find.byType(SingleChildScrollView, skipOffstage: false),
      ),
    )
    .controller!;

Future<void> _clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'modes and responsive split retain pane elements, editor focus, selection and independent scrolling',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final state = AppState(client: _NoServices());
      final content = TextEditingController(
        text: List.generate(100, (index) => 'Paragraph $index.\n').join('\n'),
      );
      final focus = FocusNode();
      final editorScroll = ScrollController();
      final layout = ValueNotifier((mode: 0, width: 980.0, height: 500.0));
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: Center(
              child:
                  ValueListenableBuilder<
                    ({int mode, double width, double height})
                  >(
                    valueListenable: layout,
                    builder: (_, value, _) => SizedBox(
                      width: value.width,
                      height: value.height,
                      child: ComposerContentViewport(
                        editing: value.mode != 2,
                        split: value.mode == 1,
                        editor: CupertinoTextField(
                          key: _editorKey,
                          controller: content,
                          focusNode: focus,
                          scrollController: editorScroll,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          selectAllOnFocus: false,
                        ),
                        preview: ComposerMarkdownPreview(
                          state: state,
                          controller: content,
                          active: value.mode != 0,
                        ),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      );
      final editorElement = tester.element(_editor);
      expect(_preview, findsNothing);
      focus.requestFocus();
      await tester.pump();
      content.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
      await tester.pump();
      layout.value = (mode: 1, width: 980, height: 500);
      await tester.pump();
      final previewElement = tester.element(_preview);
      expect(tester.element(_editor), same(editorElement));
      expect(focus.hasFocus, true);
      expect(
        content.selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      final editorRect = tester.getRect(_editor);
      final previewRect = tester.getRect(_preview);
      expect(editorRect.right, lessThan(previewRect.left));
      expect(editorRect.top, previewRect.top);
      final previewScroll = _previewScroll(tester);
      editorScroll.jumpTo(220);
      previewScroll.jumpTo(350);
      await tester.pump();
      layout.value = (mode: 2, width: 980, height: 500);
      await tester.pump();
      expect(_editor.hitTestable(), findsNothing);
      expect(editorScroll.offset, 220);
      expect(tester.element(_editor), same(editorElement));
      expect(tester.element(_preview), same(previewElement));
      layout.value = (mode: 0, width: 980, height: 500);
      await tester.pump();
      expect(_preview.hitTestable(), findsNothing);
      expect(previewScroll.offset, 350);
      expect(tester.element(_preview), same(previewElement));
      layout.value = (mode: 1, width: 600, height: 400);
      await tester.pump();
      final narrowEditor = tester.getRect(_editor);
      final narrowPreview = tester.getRect(_preview);
      expect(narrowEditor.bottom, lessThan(narrowPreview.top));
      expect(narrowEditor.left, narrowPreview.left);
      expect(narrowEditor.width, narrowPreview.width);
      expect(tester.element(_editor), same(editorElement));
      expect(tester.element(_preview), same(previewElement));
      expect(
        content.selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      await _clean(tester, state);
      layout.dispose();
      focus.dispose();
      content.dispose();
      editorScroll.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'preview debounces only body changes, suspends hidden work and flushes synchronously on entry',
    (tester) async {
      final state = AppState(client: _NoServices());
      final content = TextEditingController(text: 'First');
      final active = ValueNotifier(true);
      await tester.pumpWidget(
        CupertinoApp(
          home: SizedBox(
            width: 500,
            height: 350,
            child: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, _) => ComposerMarkdownPreview(
                state: state,
                controller: content,
                active: value,
              ),
            ),
          ),
        ),
      );
      final firstDocument = _document(tester);
      content.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_document(tester), same(firstDocument));
      content.text = 'Second';
      await tester.pump(const Duration(milliseconds: 119));
      expect(_document(tester).text, 'First');
      content.text = 'Third';
      await tester.pump(const Duration(milliseconds: 119));
      expect(_document(tester).text, 'First');
      await tester.pump(const Duration(milliseconds: 1));
      expect(_document(tester).text, 'Third');
      final thirdDocument = _document(tester);
      active.value = false;
      await tester.pump();
      content.text = 'Hidden latest';
      await tester.pump(const Duration(seconds: 1));
      expect(_document(tester), same(thirdDocument));
      active.value = true;
      await tester.pump();
      expect(_document(tester).text, 'Hidden latest');
      content.text = 'Pending before exit';
      active.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_document(tester).text, 'Hidden latest');
      active.value = true;
      await tester.pump();
      expect(_document(tester).text, 'Pending before exit');
      content.text = 'Pending before disposal';
      await _clean(tester, state);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      active.dispose();
      content.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'preview switches controller ownership without retaining the old listener',
    (tester) async {
      final state = AppState(client: _NoServices());
      final first = TextEditingController(text: 'First owner');
      final second = TextEditingController(text: 'Second owner');
      final owner = ValueNotifier(first);
      await tester.pumpWidget(
        CupertinoApp(
          home: ValueListenableBuilder<TextEditingController>(
            valueListenable: owner,
            builder: (_, value, _) => ComposerMarkdownPreview(
              state: state,
              controller: value,
              active: true,
            ),
          ),
        ),
      );
      first.text = 'Old pending edit';
      owner.value = second;
      await tester.pump();
      expect(_document(tester).text, 'Second owner');
      first.text = 'Old listener must be detached';
      await tester.pump(const Duration(milliseconds: 150));
      expect(_document(tester).text, 'Second owner');
      second.text = 'New owner edit';
      await tester.pump(const Duration(milliseconds: 120));
      expect(_document(tester).text, 'New owner edit');
      await _clean(tester, state);
      owner.dispose();
      first.dispose();
      second.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'split panes remain finite at narrow and nearly zero available heights',
    (tester) async {
      final state = AppState(client: _NoServices());
      final content = TextEditingController(text: 'Small viewport');
      final size = ValueNotifier(const Size(420, 30));
      await tester.pumpWidget(
        CupertinoApp(
          home: Center(
            child: ValueListenableBuilder<Size>(
              valueListenable: size,
              builder: (_, value, _) => SizedBox(
                width: value.width,
                height: value.height,
                child: ComposerContentViewport(
                  editing: true,
                  split: true,
                  editor: const SizedBox.expand(key: _editorKey),
                  preview: ComposerMarkdownPreview(
                    state: state,
                    controller: content,
                    active: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final height in [30.0, 8.0, 0.0, 180.0]) {
        size.value = Size(420, height);
        await tester.pump();
        expect(tester.getSize(_editor).height.isFinite, true);
        expect(tester.getSize(_editor).height, greaterThanOrEqualTo(0));
        expect(tester.getSize(_preview).height, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
      }
      await _clean(tester, state);
      size.dispose();
      content.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
