import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/reader_editor_binding.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';
import 'package:seekdesk_flutter/widgets/reader_markdown_workspace.dart';

const _url = 'https://www.nodeseek.com/post-17-1';
const _source = 'Before selected text after';

/// Real embedded documents use only this memory service. Unknown calls fail
/// here instead of falling through to a native channel, upload, or forum write.
class _ToolbarNative extends NativeClient {
  final unexpected = <String>[];
  final calls = <String>[];
  String content = _source;
  int floor = 1;
  Completer<JsonMap>? imageChoice;

  JsonMap get snapshot => {
    'content': content,
    'title': 'Toolbar fixture',
    'topicID': '17',
    'floor': floor,
    'editToken': 'toolbar-fixture-edit',
    'accessRevision': accessRevision,
    'ready': true,
    'category': 'general',
    'rank': 0,
    'maxRank': 3,
    'categories': [
      {'id': 'general', 'title': '常规'},
    ],
    'saving': false,
    'needsVerification': false,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
      case 'reader.replyDraft':
      case 'reader.edit.begin':
        return snapshot;
      case 'discussion.updateDraft':
      case 'reader.updateReplyDraft':
      case 'reader.edit.update':
        content = stringValue(arguments['content'], content);
        return snapshot;
      case 'images.keyStatus':
        return {'configured': true};
      case 'system.chooseImage':
        return imageChoice?.future ?? Future.value(<String, dynamic>{});
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'imageURLs': <String>[],
          'accessRevision': accessRevision,
        };
      default:
        unexpected.add(method);
        throw NativeFailure('fixture_only', 'Unexpected toolbar call: $method');
    }
  }
}

Finder _tool(MarkdownCommand command, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
      (widget) => widget is MarkdownToolButton && widget.command == command,
      skipOffstage: skipOffstage,
    );

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Finder get _bodyField => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
  skipOffstage: false,
);

CupertinoTextField _body(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_bodyField);

Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _EmbeddedFixture {
  _EmbeddedFixture(this.inline, {this.withTitle = false}) {
    native.floor = withTitle ? 0 : 1;
    state = AppState(client: native);
    state.domains['session'] = {
      'account': 'signedIn',
      'owner': 42,
      'canCompose': true,
    };
    state.domains['settings'] = {'workspace.replySendKey': 'commandReturn'};
    binding = ReaderEditorBinding(
      accessRevision: state.accessRevision,
      isActive: () => active,
      navigationIdentity: () => this,
      onClosed: () {},
      onSubmitted: (_, _) {},
    );
  }

  final bool inline, withTitle;
  final native = _ToolbarNative();
  late final AppState state;
  late final ReaderEditorBinding binding;
  final navigator = GlobalKey<NavigatorState>();
  final layout = ValueNotifier<(Size, double)>((const Size(560, 440), 1));
  bool active = true;

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 950));
    await tester.pumpWidget(
      CupertinoApp(
        navigatorKey: navigator,
        home: CupertinoPageScaffold(
          child: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: ValueListenableBuilder<(Size, double)>(
              valueListenable: layout,
              builder: (context, value, _) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(value.$2)),
                child: Center(
                  child: SizedBox(
                    key: const ValueKey('toolbar-embedded-panel'),
                    width: value.$1.width,
                    height: value.$1.height,
                    child: inline
                        ? InlineEditScreen(
                            state: state,
                            topicID: '17',
                            url: _url,
                            floor: native.floor,
                            binding: binding,
                          )
                        : ComposerScreen(
                            state: state,
                            topicID: withTitle ? null : '17',
                            url: _url,
                            binding: binding,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
    expect(_body(tester).controller!.text, _source);
    expect(find.byType(ReaderMarkdownWorkspace), findsOneWidget);
  }

  Future<void> resize(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    layout.value = (size, textScale);
    await _frames(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    binding.dispose();
    state.dispose();
    layout.dispose();
    await tester.pump(const Duration(seconds: 6));
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  }
}

void _expectAllToolsVisible(WidgetTester tester) {
  final panel = tester.getRect(
    find.byKey(const ValueKey('toolbar-embedded-panel')),
  );
  final editor = tester.getRect(
    find.byKey(const ValueKey('markdown-workspace-editor')),
  );
  expect(find.byType(MarkdownToolButton), findsNWidgets(13));
  expect(find.text('更多'), findsNothing);
  for (final command in MarkdownCommand.values) {
    final finder = _tool(command);
    expect(finder.hitTestable(), findsOneWidget, reason: command.name);
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(panel.left));
    expect(rect.right, lessThanOrEqualTo(panel.right));
    expect(rect.top, greaterThanOrEqualTo(panel.top));
    expect(rect.bottom, lessThanOrEqualTo(editor.top));
  }
  for (final label in ['上传图片', '表情']) {
    final finder = _button(label);
    expect(finder.hitTestable(), findsOneWidget, reason: label);
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(panel.left));
    expect(rect.right, lessThanOrEqualTo(panel.right));
    expect(rect.bottom, lessThanOrEqualTo(editor.top));
  }
  expect(editor.height, greaterThanOrEqualTo(110));
  // No ensureVisible or scroll operation is used to reach any tool above.
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all thirteen direct tools dispatch their distinct command', (
    tester,
  ) async {
    final commands = <MarkdownCommand>[];
    final enabled = ValueNotifier(true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.binding.setSurfaceSize(const Size(800, 600));
    try {
      await tester.pumpWidget(
        CupertinoApp(
          navigatorKey: navigator,
          home: CupertinoPageScaffold(
            child: GlassAdaptiveScope(
              minQuality: GlassQuality.minimal,
              maxQuality: GlassQuality.minimal,
              child: Center(
                child: SizedBox(
                  width: 412,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: enabled,
                    builder: (context, value, _) => MarkdownToolbar(
                      enabled: value,
                      onCommand: commands.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _frames(tester);
      expect(find.text('更多'), findsNothing);
      for (final command in MarkdownCommand.values) {
        expect(_tool(command).hitTestable(), findsOneWidget);
        await tester.tap(_tool(command));
        await _frames(tester, 2);
      }
      expect(commands, MarkdownCommand.values);

      // Capture the actual command closure before disabling or covering its
      // owner; a retired callback must not mutate the background document.
      final stale = tester
          .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
          .onTap!;
      enabled.value = false;
      await _frames(tester);
      for (final command in MarkdownCommand.values) {
        expect(tester.widget<MarkdownToolButton>(_tool(command)).onTap, isNull);
      }
      stale();
      expect(commands, MarkdownCommand.values);

      enabled.value = true;
      await _frames(tester);
      final covered = tester
          .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
          .onTap!;
      unawaited(
        navigator.currentState!.push<void>(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(
              child: Center(child: Text('Covering route')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      covered();
      expect(commands, MarkdownCommand.values);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(_tool(MarkdownCommand.bold));
      expect(commands, [...MarkdownCommand.values, MarkdownCommand.bold]);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      enabled.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  for (final inline in [false, true]) {
    final kind = inline ? 'inline edit' : 'reply';
    testWidgets(
      '$kind exposes every tool and both media entries across widths and text scales',
      (tester) async {
        final fixture = _EmbeddedFixture(inline);
        try {
          await fixture.mount(tester);
          final controller = _body(tester).controller!;
          final element = tester.element(_bodyField);
          const selection = TextSelection(baseOffset: 7, extentOffset: 20);
          controller.selection = selection;
          for (final (size, scale) in [
            (const Size(560, 440), 1.0),
            (const Size(412, 480), 1.0),
            (const Size(1024, 440), 1.0),
            (const Size(560, 560), 2.0),
            (const Size(412, 600), 2.0),
            (const Size(1024, 480), 2.0),
          ]) {
            await fixture.resize(tester, size, textScale: scale);
            _expectAllToolsVisible(tester);
            expect(_body(tester).controller, same(controller));
            expect(tester.element(_bodyField), same(element));
            expect(controller.text, _source);
            expect(controller.selection, selection);
          }
        } finally {
          await fixture.dispose(tester);
        }
      },
    );

    testWidgets(
      '$kind formatting preserves selection, focus, undo and unfinished IME',
      (tester) async {
        final fixture = _EmbeddedFixture(inline);
        try {
          await fixture.mount(tester);
          final controller = _body(tester).controller!;
          final focus = _body(tester).focusNode!;
          final element = tester.element(_bodyField);
          await tester.showKeyboard(_bodyField);
          const selection = TextSelection(baseOffset: 7, extentOffset: 20);
          controller.selection = selection;
          await tester.pump();
          await tester.tap(_tool(MarkdownCommand.bold));
          await _frames(tester);
          expect(controller.text, 'Before **selected text** after');
          expect(
            controller.selection,
            const TextSelection(baseOffset: 9, extentOffset: 22),
          );
          expect(focus.hasFocus, isTrue);
          expect(tester.element(_bodyField), same(element));

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(controller.text, _source);
          expect(controller.selection, selection);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(controller.text, 'Before *selected text* after');

          final stale = tester
              .widget<MarkdownToolButton>(_tool(MarkdownCommand.table))
              .onTap!;
          const composing = TextEditingValue(
            text: '中文拼',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 2, end: 3),
          );
          tester.testTextInput.updateEditingValue(composing);
          await tester.pump();
          for (final command in MarkdownCommand.values) {
            expect(
              tester.widget<MarkdownToolButton>(_tool(command)).onTap,
              isNull,
              reason: 'Composition must disable ${command.name}',
            );
          }
          stale();
          await fixture.resize(tester, const Size(412, 600), textScale: 2);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(controller.value, composing);
          expect(focus.hasFocus, isTrue);
          expect(tester.element(_bodyField), same(element));

          tester.testTextInput.updateEditingValue(
            composing.copyWith(composing: TextRange.empty),
          );
          await tester.pump();
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNotNull,
          );
          final retired = tester
              .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
              .onTap!;
          fixture.active = false;
          fixture.binding.refresh();
          await tester.pump();
          retired();
          expect(controller.text, composing.text);
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNull,
          );
        } finally {
          await fixture.dispose(tester);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '$kind selection moves retain the toolbar widget and format the latest selection',
      (tester) async {
        final fixture = _EmbeddedFixture(inline);
        try {
          await fixture.mount(tester);
          final controller = _body(tester).controller!;
          final toolbar = tester.widget<MarkdownToolbar>(
            find.byType(MarkdownToolbar),
          );
          final bodyElement = tester.element(_bodyField);
          for (final selection in const [
            TextSelection.collapsed(offset: 3),
            TextSelection(baseOffset: 0, extentOffset: 6),
            TextSelection(baseOffset: 7, extentOffset: 20),
          ]) {
            controller.selection = selection;
            await tester.pump();
            expect(
              tester.widget<MarkdownToolbar>(find.byType(MarkdownToolbar)),
              same(toolbar),
              reason: 'Selection alone must not rebuild the format shelf',
            );
            expect(tester.element(_bodyField), same(bodyElement));
          }
          await tester.tap(_tool(MarkdownCommand.bold));
          await _frames(tester);
          expect(controller.text, 'Before **selected text** after');
          expect(
            controller.selection,
            const TextSelection(baseOffset: 9, extentOffset: 22),
          );
          expect(tester.element(_bodyField), same(bodyElement));
        } finally {
          await fixture.dispose(tester);
        }
      },
    );

    testWidgets(
      '$kind interleaved title and body composition keeps formatting availability current',
      (tester) async {
        final fixture = _EmbeddedFixture(inline, withTitle: true);
        try {
          await fixture.mount(tester);
          await fixture.resize(tester, const Size(560, 700));
          final body = _body(tester).controller!;
          final title = tester
              .widget<CupertinoTextField>(
                find.byWidgetPredicate(
                  (widget) => widget is CupertinoTextField && !widget.expands,
                ),
              )
              .controller!;
          final originalBody = body.text;
          final originalTitle = title.text;
          void expectEnabled(bool enabled) {
            for (final command in MarkdownCommand.values) {
              expect(
                tester.widget<MarkdownToolButton>(_tool(command)).onTap,
                enabled ? isNotNull : isNull,
                reason: '${command.name} composition availability',
              );
            }
          }

          // Values retain their text throughout: only composition changes.
          // Keep title composition active while body composition ends so the
          // combined "title OR body" boolean cannot detect the transition.
          title.value = title.value.copyWith(
            selection: const TextSelection.collapsed(offset: 1),
            composing: const TextRange(start: 0, end: 1),
          );
          await tester.pump();
          expectEnabled(!inline);
          body.value = body.value.copyWith(
            selection: const TextSelection.collapsed(offset: 1),
            composing: const TextRange(start: 0, end: 1),
          );
          await tester.pump();
          expectEnabled(false);
          body.value = body.value.copyWith(composing: TextRange.empty);
          await tester.pump();
          expectEnabled(!inline);
          title.value = title.value.copyWith(composing: TextRange.empty);
          await tester.pump();
          expectEnabled(true);

          // Reverse the order: a title commit must not enable a body that is
          // still composing, and a composition-only body commit must enable it.
          body.value = body.value.copyWith(
            composing: const TextRange(start: 0, end: 1),
          );
          title.value = title.value.copyWith(
            composing: const TextRange(start: 0, end: 1),
          );
          await tester.pump();
          expectEnabled(false);
          title.value = title.value.copyWith(composing: TextRange.empty);
          await tester.pump();
          expectEnabled(false);
          body.value = body.value.copyWith(composing: TextRange.empty);
          await tester.pump();
          expectEnabled(true);
          expect(body.text, originalBody);
          expect(title.text, originalTitle);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );

    testWidgets(
      '$kind toolbar still follows media busy, parent active and expired access',
      (tester) async {
        final fixture = _EmbeddedFixture(inline);
        try {
          await fixture.mount(tester);
          final controller = _body(tester).controller!;
          controller.selection = const TextSelection(
            baseOffset: 7,
            extentOffset: 20,
          );
          await tester.pump();
          final oldFormat = tester
              .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
              .onTap!;
          fixture.native.imageChoice = Completer<JsonMap>();
          await tester.tap(_button('上传图片'));
          await _frames(tester);
          expect(fixture.native.calls, contains('system.chooseImage'));
          expect(tester.widget<DeskButton>(_button('上传图片')).busy, isTrue);
          expect(tester.widget<DeskButton>(_button('表情')).onTap, isNull);
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNull,
          );
          oldFormat();
          expect(controller.text, _source);
          fixture.native.imageChoice!.complete({});
          await _frames(tester);
          expect(tester.widget<DeskButton>(_button('上传图片')).busy, isFalse);
          expect(tester.widget<DeskButton>(_button('上传图片')).onTap, isNotNull);
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNotNull,
          );

          fixture.active = false;
          fixture.binding.refresh();
          await tester.pump();
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNull,
          );
          expect(tester.widget<DeskButton>(_button('上传图片')).onTap, isNull);
          oldFormat();
          expect(controller.text, _source);
          fixture.active = true;
          fixture.binding.refresh();
          await tester.pump();
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNotNull,
          );
          expect(tester.widget<DeskButton>(_button('上传图片')).onTap, isNotNull);

          // Parent session changes remain effective without a content event.
          if (!inline) {
            fixture.state.domains['session']!['canCompose'] = false;
            fixture.binding.refresh();
            await tester.pump();
            expect(tester.widget<DeskButton>(_button('发送回复')).onTap, isNull);
            expect(
              tester
                  .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                  .onTap,
              isNotNull,
            );
          }
          fixture.native.accessRevision++;
          fixture.binding.refresh();
          await tester.pump();
          expect(
            tester
                .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
                .onTap,
            isNull,
          );
          expect(tester.widget<DeskButton>(_button('上传图片')).onTap, isNull);
          oldFormat();
          expect(controller.text, _source);
        } finally {
          if (fixture.native.imageChoice case final pending?
              when !pending.isCompleted) {
            pending.complete({});
            await _frames(tester);
          }
          await fixture.dispose(tester);
        }
      },
    );

    testWidgets('$kind short panel keeps the editor and footer reachable', (
      tester,
    ) async {
      final fixture = _EmbeddedFixture(inline);
      try {
        await fixture.mount(tester);
        final controller = _body(tester).controller!;
        final element = tester.element(_bodyField);
        controller.selection = const TextSelection(
          baseOffset: 7,
          extentOffset: 20,
        );
        await fixture.resize(tester, const Size(412, 230));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('markdown-workspace-editor')))
              .height,
          greaterThanOrEqualTo(110),
        );
        final footer = _button(inline ? '保存修改' : '发送回复');
        await tester.ensureVisible(footer);
        await _frames(tester);
        // Inline save is disabled until edited; the short panel must still
        // expose its visual bounds without replacing the document controller.
        final panel = tester.getRect(
          find.byKey(const ValueKey('toolbar-embedded-panel')),
        );
        final rect = tester.getRect(footer);
        expect(rect.top, greaterThanOrEqualTo(panel.top));
        expect(rect.bottom, lessThanOrEqualTo(panel.bottom));
        expect(_body(tester).controller, same(controller));
        expect(tester.element(_bodyField), same(element));
        expect(
          controller.selection,
          const TextSelection(baseOffset: 7, extentOffset: 20),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }
}
