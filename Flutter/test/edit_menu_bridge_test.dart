// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/document_history.dart';
import 'package:seekdesk_flutter/widgets/document_history_scope.dart';
import 'package:seekdesk_flutter/widgets/edit_menu_bridge.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';

const _channel = MethodChannel('cc.seekdesk/edit-menu.test');
const _defaultChannel = MethodChannel('cc.seekdesk/edit-menu.v1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var clipboard = '';
  final outgoing = <MethodCall>[];

  setUp(() {
    clipboard = '';
    outgoing.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard};
      } else if (call.method == 'Clipboard.hasStrings') {
        return {'value': clipboard.isNotEmpty};
      }
      return null;
    });
    for (final channel in [_channel, _defaultChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        outgoing.add(call);
        return null;
      });
    }
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    for (final channel in [_channel, _defaultChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool defaultChannel = false,
  }) async {
    await tester.pumpWidget(
      CupertinoApp(
        builder: (context, navigator) => EditMenuBridge(
          channel: defaultChannel ? null : _channel,
          child: navigator!,
        ),
        home: CupertinoPageScaffold(
          child: Padding(padding: const EdgeInsets.all(30), child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Exercise the actual platform->Dart handler. invokeMethod would travel in
  /// the opposite direction and only hit the mock notification receiver.
  Future<Object?> host(
    WidgetTester tester,
    String method, [
    Object? arguments,
    MethodChannel channel = _channel,
  ]) async {
    final response = tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, arguments)),
          null,
        );
    await tester.pump();
    final envelope = await response;
    if (envelope == null) throw MissingPluginException('No edit-menu handler');
    return channel.codec.decodeEnvelope(envelope);
  }

  Future<Map<Object?, Object?>> capabilities(WidgetTester tester) async =>
      (await host(tester, 'capabilities'))! as Map<Object?, Object?>;

  Set<String> commands(Map<Object?, Object?> snapshot) =>
      (snapshot['commands']! as List).cast<String>().toSet();

  Future<bool> perform(WidgetTester tester, String command) async {
    final snapshot = await capabilities(tester);
    expect(snapshot['focusToken'], isA<int>());
    final result = await host(tester, 'perform', {
      'command': command,
      'focusToken': snapshot['focusToken'],
    });
    await tester.pumpAndSettle();
    return result! as bool;
  }

  Future<void> cleanup(
    WidgetTester tester,
    List<TextEditingController> controllers,
    List<FocusNode> nodes,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final node in nodes) {
      node.dispose();
    }
    await tester.pump();
  }

  testWidgets(
    'native edit commands mutate the focused editable selection and clipboard',
    (tester) async {
      final controller = TextEditingController(text: 'Alpha Beta');
      final focus = FocusNode();
      await mount(
        tester,
        CupertinoTextField(controller: controller, focusNode: focus),
      );
      focus.requestFocus();
      await tester.pump();
      expect(commands(await capabilities(tester)), contains('selectAll'));
      expect(await perform(tester, 'selectAll'), isTrue);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 10),
      );
      expect(
        commands(await capabilities(tester)),
        containsAll(['copy', 'cut', 'delete']),
      );
      expect(await perform(tester, 'copy'), isTrue);
      expect(clipboard, 'Alpha Beta');
      expect(controller.text, 'Alpha Beta');
      expect(await perform(tester, 'cut'), isTrue);
      expect(controller.text, isEmpty);
      expect(clipboard, 'Alpha Beta');

      clipboard = 'pasted words';
      expect(
        commands(await capabilities(tester)),
        containsAll(['paste', 'pasteAsPlainText']),
      );
      expect(await perform(tester, 'paste'), isTrue);
      expect(controller.text, 'pasted words');
      expect(await perform(tester, 'selectAll'), isTrue);
      clipboard = '**plain**';
      expect(await perform(tester, 'pasteAsPlainText'), isTrue);
      expect(controller.text, '**plain**');
      expect(await perform(tester, 'selectAll'), isTrue);
      expect(await perform(tester, 'delete'), isTrue);
      expect(controller.text, isEmpty);
      expect(
        clipboard,
        '**plain**',
        reason: 'Delete must not replace the clipboard.',
      );
      expect(tester.takeException(), isNull);
      await cleanup(tester, [controller], [focus]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('native undo and redo use actual focused editor history', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'seed');
    final focus = FocusNode();
    final history = UndoHistoryController();
    await mount(
      tester,
      CupertinoTextField(
        controller: controller,
        focusNode: focus,
        undoController: history,
      ),
    );
    focus.requestFocus();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byType(CupertinoTextField), 'first edit');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byType(CupertinoTextField), 'second edit');
    await tester.pump(const Duration(milliseconds: 600));
    expect(history.value.canUndo, isTrue);
    expect(commands(await capabilities(tester)), contains('undo'));
    expect(await perform(tester, 'undo'), isTrue);
    expect(controller.text, 'first edit');
    expect(history.value.canRedo, isTrue);
    expect(commands(await capabilities(tester)), contains('redo'));
    expect(await perform(tester, 'redo'), isTrue);
    expect(controller.text, 'second edit');
    expect(history.value.canRedo, isFalse);
    expect(commands(await capabilities(tester)), isNot(contains('redo')));
    await cleanup(tester, [controller], [focus]);
    history.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'native menu uses scoped command boundaries before the SDK throttle expires',
    (tester) async {
      final controller = TextEditingController.fromValue(
        const TextEditingValue(
          text: 'seed',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      final focus = FocusNode();
      final history = DocumentHistory(controller: controller);
      await mount(
        tester,
        DocumentHistoryScope(
          history: history,
          child: CupertinoTextField(controller: controller, focusNode: focus),
        ),
      );
      focus.requestFocus();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(CupertinoTextField), 'seed typed');
      history.execute(
        (value) => TextEditingValue(
          text: '**${value.text}**',
          selection: const TextSelection(baseOffset: 2, extentOffset: 12),
        ),
      );
      await tester.enterText(
        find.byType(CupertinoTextField),
        '**seed typed** after',
      );
      await tester.pump();
      expect(history.canUndo, true);
      expect(
        UndoManager.client?.canUndo,
        false,
        reason: 'This deliberately precedes the built-in 500ms commit.',
      );
      expect(commands(await capabilities(tester)), contains('undo'));

      expect(await perform(tester, 'undo'), true);
      expect(controller.text, '**seed typed**');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 12),
      );
      expect(await perform(tester, 'undo'), true);
      expect(controller.text, 'seed typed');
      expect(await perform(tester, 'undo'), true);
      expect(controller.text, 'seed');
      expect(commands(await capabilities(tester)), isNot(contains('undo')));
      expect(await perform(tester, 'redo'), true);
      expect(controller.text, 'seed typed');
      expect(await perform(tester, 'redo'), true);
      expect(controller.text, '**seed typed**');
      expect(await perform(tester, 'redo'), true);
      expect(controller.text, '**seed typed** after');
      expect(tester.takeException(), isNull);
      await cleanup(tester, [controller], [focus]);
      history.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'disabled and composing document scopes never fall back to the SDK undo stack',
    (tester) async {
      final controller = TextEditingController(text: 'seed');
      final focus = FocusNode();
      final history = DocumentHistory(controller: controller);
      var enabled = true;
      late StateSetter rebuild;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return DocumentHistoryScope(
              history: history,
              enabled: enabled,
              child: CupertinoTextField(
                controller: controller,
                focusNode: focus,
              ),
            );
          },
        ),
      );
      focus.requestFocus();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(CupertinoTextField), 'changed');
      await tester.pump(const Duration(milliseconds: 600));
      expect(UndoManager.client?.canUndo, true);
      expect(commands(await capabilities(tester)), contains('undo'));
      final action = Actions.maybeFind<UndoTextIntent>(focus.context!);
      rebuild(() => enabled = false);
      await tester.pump();
      expect(commands(await capabilities(tester)), isNot(contains('undo')));
      expect(await perform(tester, 'undo'), false);
      expect(
        action!.isEnabled(const UndoTextIntent(SelectionChangedCause.keyboard)),
        false,
      );
      Actions.maybeInvoke(
        focus.context!,
        const UndoTextIntent(SelectionChangedCause.keyboard),
      );
      expect(controller.text, 'changed');

      rebuild(() => enabled = true);
      await tester.pump();
      controller.value = const TextEditingValue(
        text: 'changedn',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 7, end: 8),
      );
      await tester.pump();
      expect(UndoManager.client?.canUndo, true);
      expect(commands(await capabilities(tester)), isNot(contains('undo')));
      expect(commands(await capabilities(tester)), isNot(contains('redo')));
      expect(await perform(tester, 'undo'), false);
      expect(controller.text, 'changedn');
      controller.value = const TextEditingValue(
        text: 'changed你',
        selection: TextSelection.collapsed(offset: 8),
      );
      await tester.pump();
      expect(await perform(tester, 'undo'), true);
      expect(controller.text, 'changed');
      expect(tester.takeException(), isNull);
      await cleanup(tester, [controller], [focus]);
      history.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'title history keeps its fallback and stale body menu requests cannot change it',
    (tester) async {
      final body = TextEditingController(text: 'body');
      final title = TextEditingController(text: 'title');
      final bodyFocus = FocusNode(), titleFocus = FocusNode();
      final bodyHistory = DocumentHistory(controller: body);
      final titleHistory = UndoHistoryController();
      await mount(
        tester,
        Column(
          children: [
            CupertinoTextField(
              key: const ValueKey('title'),
              controller: title,
              focusNode: titleFocus,
              undoController: titleHistory,
            ),
            DocumentHistoryScope(
              history: bodyHistory,
              child: CupertinoTextField(
                key: const ValueKey('body'),
                controller: body,
                focusNode: bodyFocus,
              ),
            ),
          ],
        ),
      );
      bodyFocus.requestFocus();
      await tester.pump();
      bodyHistory.apply(
        const TextEditingValue(
          text: 'body command',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      final oldBody = await capabilities(tester);
      titleFocus.requestFocus();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(
        find.byKey(const ValueKey('title')),
        'title edited',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(titleHistory.value.canUndo, true);
      expect(commands(await capabilities(tester)), contains('undo'));
      expect(
        await host(tester, 'perform', {
          'command': 'undo',
          'focusToken': oldBody['focusToken'],
        }),
        false,
      );
      expect(title.text, 'title edited');
      expect(body.text, 'body command');
      expect(await perform(tester, 'undo'), true);
      expect(title.text, 'title');
      expect(body.text, 'body command');
      expect(await perform(tester, 'redo'), true);
      expect(title.text, 'title edited');
      bodyFocus.requestFocus();
      await tester.pump();
      expect(await perform(tester, 'undo'), true);
      expect(body.text, 'body');
      expect(title.text, 'title edited');
      expect(tester.takeException(), isNull);
      await cleanup(tester, [body, title], [bodyFocus, titleFocus]);
      bodyHistory.dispose();
      titleHistory.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'read-only body allows Select All and Copy but rejects editing commands',
    (tester) async {
      await mount(
        tester,
        const ForumTextSelection(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('First body paragraph.'),
              Text('Second body paragraph.'),
            ],
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('First body paragraph.'),
          matching: find.byType(RichText),
        ),
      );
      final glyph = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .first;
      await tester.tapAt(paragraph.localToGlobal(glyph.toRect().center));
      await tester.pump();
      expect(await perform(tester, 'selectAll'), isTrue);
      expect(
        commands(await capabilities(tester)),
        containsAll(['selectAll', 'copy']),
      );
      expect(await perform(tester, 'copy'), isTrue);
      expect(clipboard, contains('First body paragraph.'));
      expect(clipboard, contains('Second body paragraph.'));
      final originalClipboard = clipboard;
      for (final command in [
        'cut',
        'paste',
        'pasteAsPlainText',
        'delete',
        'undo',
        'redo',
      ]) {
        expect(commands(await capabilities(tester)), isNot(contains(command)));
        expect(await perform(tester, command), isFalse);
      }
      expect(clipboard, originalClipboard);
      expect(find.text('First body paragraph.'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      await cleanup(tester, [], []);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('read-only text fields expose copy without cut paste or delete', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Read only');
    final focus = FocusNode();
    await mount(
      tester,
      CupertinoTextField(
        controller: controller,
        focusNode: focus,
        readOnly: true,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(await perform(tester, 'selectAll'), isTrue);
    expect(await perform(tester, 'copy'), isTrue);
    expect(clipboard, 'Read only');
    for (final command in ['cut', 'paste', 'pasteAsPlainText', 'delete']) {
      expect(commands(await capabilities(tester)), isNot(contains(command)));
      expect(await perform(tester, command), isFalse);
    }
    expect(controller.text, 'Read only');
    await cleanup(tester, [controller], [focus]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'stale focus tokens cannot apply a menu command to a different field',
    (tester) async {
      final first = TextEditingController(text: 'first');
      final second = TextEditingController(text: 'second');
      final firstFocus = FocusNode();
      final secondFocus = FocusNode();
      await mount(
        tester,
        Column(
          children: [
            CupertinoTextField(controller: first, focusNode: firstFocus),
            CupertinoTextField(controller: second, focusNode: secondFocus),
          ],
        ),
      );
      firstFocus.requestFocus();
      await tester.pump();
      expect(await perform(tester, 'selectAll'), isTrue);
      final previous = await capabilities(tester);
      secondFocus.requestFocus();
      await tester.pump();
      final current = await capabilities(tester);
      final focusedSelection = second.selection;
      expect(current['focusToken'], isNot(previous['focusToken']));
      clipboard = 'untouched';
      for (final command in ['selectAll', 'copy', 'cut', 'paste', 'delete']) {
        expect(
          await host(tester, 'perform', {
            'command': command,
            'focusToken': previous['focusToken'],
          }),
          isFalse,
        );
      }
      expect(first.text, 'first');
      expect(second.text, 'second');
      expect(second.selection, focusedSelection);
      expect(clipboard, 'untouched');
      expect(await perform(tester, 'selectAll'), isTrue);
      expect(
        second.selection,
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      await cleanup(tester, [first, second], [firstFocus, secondFocus]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'password fields never grant copy or cut even with a selected range',
    (tester) async {
      final controller = TextEditingController(text: 'fixture-only-secret');
      final focus = FocusNode();
      await mount(
        tester,
        CupertinoTextField(
          controller: controller,
          focusNode: focus,
          obscureText: true,
        ),
      );
      focus.requestFocus();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      await tester.pump();
      clipboard = 'existing clipboard';
      final snapshot = await capabilities(tester);
      expect(commands(snapshot), isNot(contains('copy')));
      expect(commands(snapshot), isNot(contains('cut')));
      expect(snapshot.toString(), isNot(contains('fixture-only-secret')));
      expect(await perform(tester, 'copy'), isFalse);
      expect(await perform(tester, 'cut'), isFalse);
      expect(controller.text, 'fixture-only-secret');
      expect(clipboard, 'existing clipboard');
      await cleanup(tester, [controller], [focus]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'unknown commands and unfocused targets are rejected without mutations',
    (tester) async {
      final controller = TextEditingController(text: 'safe text');
      final focus = FocusNode();
      await mount(
        tester,
        CupertinoTextField(controller: controller, focusNode: focus),
      );
      final initial = await capabilities(tester);
      expect(commands(initial), isEmpty);
      expect(await perform(tester, 'selectAll'), isFalse);
      focus.requestFocus();
      await tester.pump();
      final focusedSelection = controller.selection;
      final snapshot = await capabilities(tester);
      clipboard = 'unchanged clipboard';
      expect(await perform(tester, 'unknownCommand'), isFalse);
      for (final malformed in [
        (snapshot['focusToken']! as int).toDouble(),
        true,
        false,
      ]) {
        expect(
          await host(tester, 'perform', {
            'command': 'cut',
            'focusToken': malformed,
          }),
          isFalse,
        );
      }
      Object? failure;
      try {
        await host(tester, 'unknownMethod');
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<MissingPluginException>());
      expect(controller.text, 'safe text');
      expect(controller.selection, focusedSelection);
      expect(clipboard, 'unchanged clipboard');
      await cleanup(tester, [controller], [focus]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'default channel unregisters on disposal and rejects delayed native work',
    (tester) async {
      final controller = TextEditingController(text: 'survives teardown');
      final focus = FocusNode();
      await mount(
        tester,
        CupertinoTextField(controller: controller, focusNode: focus),
        defaultChannel: true,
      );
      focus.requestFocus();
      await tester.pump();
      final snapshot =
          (await host(tester, 'capabilities', null, _defaultChannel))! as Map;
      expect(
        commands(snapshot.cast<Object?, Object?>()),
        contains('selectAll'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      final response = tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            _defaultChannel.name,
            _defaultChannel.codec.encodeMethodCall(
              MethodCall('perform', {
                'command': 'selectAll',
                'focusToken': snapshot['focusToken'],
              }),
            ),
            null,
          );
      await tester.pump();
      expect(
        await response,
        isNull,
        reason: 'The disposed bridge must remove its handler.',
      );
      expect(controller.text, 'survives teardown');
      expect(tester.takeException(), isNull);
      controller.dispose();
      focus.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
