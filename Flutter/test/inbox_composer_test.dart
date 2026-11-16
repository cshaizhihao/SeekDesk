import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/composer_preview.dart';
import 'package:seekdesk_flutter/widgets/composer_sticker_picker.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/inbox_composer.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';
import 'package:seekdesk_flutter/widgets/markdown_toolbar.dart';

const _image = 'https://www.nodeseek.com/assets/inbox-fixture.png';
const _imageMarkdown = '![]($_image)';
const _bodyKey = ValueKey('inbox-composer-body');
const _panelKey = ValueKey('inbox-composer-panel');
const _sendKey = ValueKey('inbox-composer-send');
const _markdownKey = ValueKey('inbox-composer-markdown');

class _Native extends NativeClient {
  _Native()
    : super(methods: const MethodChannel('seekdesk.test.inbox-composer'));
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  Completer<JsonMap>? upload;
  Completer<JsonMap>? draftRead;
  JsonMap? savedSize;
  NativeFailure? sizeFailure;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'inbox.getDraft':
        return draftRead?.future ?? Future.value(<String, dynamic>{});
      case 'images.keyStatus':
        return {'configured': true};
      case 'system.chooseImage':
        if (upload case final pending?) return pending.future;
        return {'markdown': _imageMarkdown};
      case 'images.draftReferences':
        return {
          'content': arguments['content'],
          'accessRevision': accessRevision,
          'imageURLs': stringValue(arguments['content']).contains(_image)
              ? [_image]
              : <String>[],
        };
      case 'inbox.setImageSize':
        if (sizeFailure case final failure?) throw failure;
        savedSize = {...arguments};
        return {
          'peer': arguments['peer'],
          'accessRevision': accessRevision,
          'content': arguments['expectedContent'],
          'imageURLs': [_image],
          'imageSizing': [
            if (arguments['ratio'] != 1)
              {
                'url': arguments['url'],
                'ratio': arguments['ratio'],
                'previewWidth': arguments['previewWidth'],
              },
          ],
        };
      case 'stickers.list':
        return {
          'packs': [
            {
              'id': 'ac',
              'title': 'AC',
              'items': [
                {
                  'id': 'ac01',
                  'label': 'AC 01',
                  'url':
                      'https://www.nodeseek.com/static/image/sticker/ac/01.png',
                  'insertion': ' :ac01: ',
                },
              ],
            },
          ],
        };
      case 'stickers.custom.list':
        return {'groups': <JsonMap>[]};
      case 'images.load':
        return {
          'bytes': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          'width': 1000,
          'height': 500,
        };
      default:
        // In particular inbox.send and any real forum write are forbidden.
        unexpected.add(method);
        throw StateError(
          'Unexpected private composer fixture operation: $method',
        );
    }
  }
}

class _Fixture {
  _Fixture({String text = 'draft'}) {
    controller = TextEditingController.fromValue(_value(text));
    state = AppState(client: native);
    savedText = text;
  }
  final native = _Native();
  late final AppState state;
  late final TextEditingController controller;
  final key = GlobalKey<_HarnessState>();
  final navigationGuard = InboxComposerNavigationGuard();
  int peer = 73, revision = 0, flushes = 0;
  bool markdown = true, enabled = true, sending = false, ownerCurrent = true;
  bool flushSucceeds = true;
  Completer<bool>? flushGate;
  JsonMap? snapshotOverride;
  late String savedText;
  final changes = <String>[];
  final modes = <bool>[];
  final sends = <(int, int, String, bool)>[];

  JsonMap get snapshot =>
      snapshotOverride ??
      {
        'peer': peer,
        'accessRevision': revision,
        'draft': savedText,
        'imageURLs': savedText.contains(_image) ? [_image] : <String>[],
        'imageSizing': [
          if (native.savedSize case final value?)
            {
              'url': value['url'],
              'ratio': value['ratio'],
              'previewWidth': value['previewWidth'],
            },
        ],
      };

  Future<bool> flush() async {
    flushes++;
    final result = await (flushGate?.future ?? Future.value(flushSucceeds));
    if (result) savedText = controller.text;
    return result;
  }

  void update(VoidCallback change) => key.currentState!.update(change);

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      state.dispose();
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
      expect(native.unexpected, isEmpty);
    });
    await tester.pumpWidget(_Harness(key: key, fixture: this));
    await _frames(tester);
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.fixture, super.key});
  final _Fixture fixture;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  double scale = 1;
  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    final f = widget.fixture;
    return CupertinoApp(
      home: LayoutBuilder(
        builder: (context, bounds) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: bounds.biggest,
            textScaler: TextScaler.linear(scale),
          ),
          child: GlassAdaptiveScope(
            minQuality: GlassQuality.minimal,
            maxQuality: GlassQuality.minimal,
            child: Column(
              children: [
                const Expanded(
                  child: Center(child: Text('Conversation history')),
                ),
                InboxComposer(
                  state: f.state,
                  controller: f.controller,
                  peer: f.peer,
                  revision: f.revision,
                  enabled: f.enabled,
                  sending: f.sending,
                  markdown: f.markdown,
                  onMarkdownChanged: (value) => update(() {
                    f.modes.add(value);
                    f.markdown = value;
                  }),
                  onChanged: f.changes.add,
                  onSend: () => f.sends.add((
                    f.peer,
                    f.revision,
                    f.controller.text,
                    f.markdown,
                  )),
                  flushDraft: f.flush,
                  snapshot: f.snapshot,
                  synchronizeDraft: () async => f.snapshot,
                  isCurrent: () => f.ownerCurrent,
                  navigationGuard: f.navigationGuard,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextEditingValue _value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);
Finder get _body => find.byKey(_bodyKey, skipOffstage: false);
Finder _tool(MarkdownCommand command) => find.byWidgetPredicate(
  (w) => w is MarkdownToolButton && w.command == command,
);
Finder _icon(String label) =>
    find.byWidgetPredicate((w) => w is DeskIcon && w.label == label);
Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is DeskButton && w.label == label);
MarkdownEditorControls _controls(WidgetTester tester) =>
    tester.widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls));
ComposerMediaTools _media(WidgetTester tester) =>
    tester.widget<ComposerMediaTools>(find.byType(ComposerMediaTools));

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _frames(tester);
  await tester.tap(finder);
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final markdown in [true, false]) {
    testWidgets(
      'long inbox history reveals the restored caret with markdown=$markdown',
      (tester) async {
        final original = List.generate(90, (i) => 'Paragraph $i').join('\n');
        final f = _Fixture(text: original)..markdown = markdown;
        await f.mount(tester);
        final field = tester.widget<CupertinoTextField>(_body);
        field.focusNode!.requestFocus();
        await tester.pump();
        final editable = field.focusNode!.context!
            .findAncestorStateOfType<EditableTextState>()!;
        f.controller.selection = const TextSelection.collapsed(offset: 4);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: original.replaceRange(4, 4, 'A'),
            selection: const TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();
        final firstEdit = f.controller.text;
        f.controller.selection = TextSelection.collapsed(
          offset: firstEdit.length,
        );
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '$firstEdit\nLast edit',
            selection: TextSelection.collapsed(offset: firstEdit.length + 10),
          ),
        );
        await tester.pumpAndSettle();
        expect(editable.renderEditable.offset.pixels, greaterThan(500));
        for (var i = 0; i < 2; i++) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pumpAndSettle();
        }
        expect(f.controller.text, original);
        expect(f.controller.selection.extentOffset, 4);
        final caret = editable.renderEditable.getLocalRectForCaret(
          f.controller.selection.extent,
        );
        expect(caret.top, greaterThanOrEqualTo(-1));
        expect(
          caret.bottom,
          lessThanOrEqualTo(editable.renderEditable.size.height + 1),
        );
        if (markdown) {
          f.controller.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 9,
          );
          final position = editable.renderEditable.offset as ScrollPosition;
          position.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pumpAndSettle();
          expect(f.controller.text, startsWith('**Paragraph** 0'));
          final formattedCaret = editable.renderEditable.getLocalRectForCaret(
            f.controller.selection.extent,
          );
          expect(formattedCaret.top, greaterThanOrEqualTo(-1));
          expect(
            formattedCaret.bottom,
            lessThanOrEqualTo(editable.renderEditable.size.height + 1),
          );
        }
        expect(f.sends, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'thirteen tools, history and all modes retain the shared controller and local edits',
    (tester) async {
      final f = _Fixture(text: 'selected');
      await f.mount(tester);
      expect(find.byType(MarkdownToolButton), findsNWidgets(13));
      expect(_button('上传图片'), findsOneWidget);
      expect(_button('表情'), findsOneWidget);
      final field = tester.element(_body);
      final history = _controls(tester).history;
      f.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();
      await _tap(tester, _tool(MarkdownCommand.bold));
      expect(f.controller.text, '**selected**');
      expect(f.changes, ['**selected**']);
      await _tap(tester, _icon('撤销 ⌘Z'));
      expect(f.controller.text, 'selected');
      await _tap(tester, _icon('重做 ⇧⌘Z'));
      expect(f.controller.text, '**selected**');
      expect(f.changes, ['**selected**', 'selected', '**selected**']);
      for (final mode in [1, 2, 0]) {
        _controls(tester).onModeChanged(mode);
        await _frames(tester);
        expect(_controls(tester).mode, mode);
        expect(_controls(tester).history, same(history));
        expect(tester.element(_body), same(field));
        expect(
          tester.widget<CupertinoTextField>(_body).controller,
          same(f.controller),
        );
      }
      expect(f.controller.text, '**selected**');
      expect(f.sends, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'external shared text is not echoed and starts a new undo baseline',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.enterText(_body, 'local text');
      await _frames(tester);
      expect(f.changes, ['local text']);
      expect(_controls(tester).history.canUndo, isTrue);
      f.controller.value = _value('updated in another window');
      await _frames(tester);
      expect(f.changes, ['local text']);
      expect(_controls(tester).history.canUndo, isFalse);
      expect(_controls(tester).history.canRedo, isFalse);
      f.update(() {});
      await _frames(tester);
      expect(f.controller.text, 'updated in another window');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'body shortcuts use document history and plain paste cannot upload an image',
    (tester) async {
      final f = _Fixture(text: 'selected');
      await f.mount(tester);
      await tester.showKeyboard(_body);
      f.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();
      Future<void> command(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await _frames(tester);
      }

      await command(LogicalKeyboardKey.keyB);
      expect(f.controller.text, '**selected**');
      await command(LogicalKeyboardKey.keyZ);
      expect(f.controller.text, 'selected');
      tester.widget<DeskButton>(find.byKey(_markdownKey)).onTap!();
      await _frames(tester);
      expect(f.markdown, isFalse);
      await tester.showKeyboard(_body);
      f.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'literal **text**'};
          }
          return null;
        },
      );
      try {
        await command(LogicalKeyboardKey.keyV);
        expect(f.controller.text, 'literal **text**');
        expect(f.changes.last, 'literal **text**');
        expect(
          f.native.calls.where(
            (entry) => entry.$1 == 'system.captureComposerPaste',
          ),
          isEmpty,
        );
        await command(LogicalKeyboardKey.keyZ);
        expect(f.controller.text, 'selected');
        f.flushGate = Completer<bool>();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(f.flushes, 1);
        f.flushGate!.complete(true);
        await _frames(tester);
        expect(f.sends, [(73, 0, 'selected', false)]);
        expect(tester.takeException(), isNull);
      } finally {
        if (f.flushGate case final pending? when !pending.isCompleted) {
          pending.complete(false);
        }
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'IME and preview block formatting, mode changes, media and send',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final oldFormat = tester
          .widget<MarkdownToolButton>(_tool(MarkdownCommand.bold))
          .onTap!;
      final oldMedia = _media(tester).onUpload;
      final oldSend = tester.widget<DeskButton>(find.byKey(_sendKey)).onTap!;
      await tester.showKeyboard(_body);
      const composing = TextEditingValue(
        text: 'draft 拼',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 6, end: 7),
      );
      tester.testTextInput.updateEditingValue(composing);
      await _frames(tester);
      oldFormat();
      oldMedia();
      oldSend();
      _controls(tester).onModeChanged(2);
      tester.widget<DeskButton>(find.byKey(_markdownKey)).onTap?.call();
      await _frames(tester);
      expect(f.controller.value, composing);
      expect(_controls(tester).mode, 0);
      expect(f.modes, isEmpty);
      expect(f.sends, isEmpty);
      expect(
        f.native.calls.where((entry) => entry.$1 == 'system.chooseImage'),
        isEmpty,
      );
      expect(await f.state.flushDrafts(), isFalse);
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await _frames(tester);
      _controls(tester).onModeChanged(2);
      await _frames(tester);
      oldFormat();
      oldMedia();
      await _frames(tester);
      expect(f.controller.text, composing.text);
      expect(
        tester.widget<CupertinoTextField>(_body).focusNode!.hasFocus,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'send flushes once, rejects stale text and respects Markdown and same-turn repeat guards',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      f.flushGate = Completer<bool>();
      final send = tester.widget<DeskButton>(find.byKey(_sendKey)).onTap!;
      send();
      send();
      await tester.pump();
      expect(f.flushes, 1);
      expect(f.sends, isEmpty);
      f.controller.value = _value('shared newer text');
      f.flushGate!.complete(true);
      await _frames(tester);
      expect(f.sends, isEmpty);
      expect(find.text('草稿已在其他窗口更新，请检查内容后再发送。').hitTestable(), findsOneWidget);
      f.flushGate = null;
      await _tap(tester, find.byKey(_markdownKey));
      expect(f.markdown, isFalse);
      expect(f.modes, [false]);
      await _tap(tester, find.byKey(_sendKey));
      expect(f.sends, [(73, 0, 'shared newer text', false)]);
      f.update(() => f.sending = true);
      await _frames(tester);
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
      send();
      await _frames(tester);
      expect(f.sends, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'upload insertion is one undo edit and old peer or account results are discarded',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      _media(tester).onUpload();
      await _frames(tester);
      expect(f.controller.text, 'draft$_imageMarkdown');
      expect(f.changes, ['draft$_imageMarkdown']);
      _controls(tester).history.undo();
      await _frames(tester);
      expect(f.controller.text, 'draft');
      final oldHistory = _controls(tester).history;
      f.native.upload = Completer<JsonMap>();
      _media(tester).onUpload();
      await _frames(tester);
      f.ownerCurrent = false;
      f.update(() {
        f.peer = 99;
        f.controller.value = _value('other peer');
      });
      await _frames(tester);
      f.ownerCurrent = true;
      f.update(() {});
      await _frames(tester);
      expect(_controls(tester).history, isNot(same(oldHistory)));
      expect(_controls(tester).history.canUndo, isFalse);
      f.native.upload!.complete({'markdown': 'STALE PEER'});
      await _frames(tester);
      expect(f.controller.text, 'other peer');
      expect(f.changes.any((text) => text.contains('STALE')), isFalse);

      f.native.upload = Completer<JsonMap>();
      _media(tester).onUpload();
      await _frames(tester);
      f.native.accessRevision = 1;
      f.update(() {});
      await _frames(tester);
      f.native.upload!.complete({'markdown': 'STALE ACCOUNT'});
      await _frames(tester);
      expect(f.controller.text, 'other peer');
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'official sticker picker inserts through the same guarded history',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      _media(tester).onStickers();
      await _frames(tester, 30);
      expect(find.byType(ComposerStickerPicker), findsOneWidget);
      final selection = find.byKey(const ValueKey('official-sticker-ac01'));
      await tester.tap(selection);
      await _frames(tester, 30);
      expect(find.byType(ComposerStickerPicker), findsNothing);
      expect(f.controller.text, 'draft :ac01: ');
      expect(f.changes, ['draft :ac01: ']);
      _controls(tester).history.undo();
      await _frames(tester);
      expect(f.controller.text, 'draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigation keeps the current peer during upload and resumes after insertion is saved',
    (tester) async {
      final f = _Fixture();
      expect(await f.navigationGuard.flush(), isTrue);
      await f.mount(tester);
      Future<bool> navigate(int peer) async {
        if (!await f.navigationGuard.flush()) return false;
        f.update(() {
          f.peer = peer;
          f.controller.value = _value('peer $peer');
        });
        return true;
      }

      f.native.upload = Completer<JsonMap>();
      _media(tester).onUpload();
      await _frames(tester);
      expect(await navigate(99), isFalse);
      expect(f.peer, 73);
      expect(f.controller.text, 'draft');
      expect(f.flushes, 0);
      f.native.upload!.complete({'markdown': _imageMarkdown});
      await _frames(tester);
      expect(f.controller.text, 'draft$_imageMarkdown');
      final oldHistory = _controls(tester).history;
      expect(await navigate(99), isTrue);
      expect(f.savedText, 'draft$_imageMarkdown');
      await _frames(tester);
      expect(f.peer, 99);
      expect(_controls(tester).history, isNot(same(oldHistory)));
      expect(f.controller.text, 'peer 99');
      // Replacement mounts before old disposal. The same handle must still
      // consult the new document, rather than becoming an unbound true gate.
      f.flushSucceeds = false;
      expect(await f.navigationGuard.flush(), isFalse);
      f.flushSucceeds = true;
      expect(await f.navigationGuard.flush(), isTrue);
      await tester.showKeyboard(_body);
      final composing = f.controller.value.copyWith(
        composing: const TextRange(start: 0, end: 1),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      expect(await navigate(101), isFalse);
      expect(f.peer, 99);
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      expect(await navigate(101), isTrue);
      await _frames(tester);
      expect(f.peer, 101);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unacquired disabled draft does not block local or global navigation',
    (tester) async {
      final f = _Fixture(text: '')
        ..enabled = false
        ..ownerCurrent = false
        ..flushSucceeds = false;
      await f.mount(tester);
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
      expect(await f.navigationGuard.flush(), isTrue);
      expect(await f.state.flushDrafts(), isTrue);
      expect(
        f.flushes,
        0,
        reason: 'There is no acquired draft to save or retry.',
      );
      f.update(() {
        f.enabled = true;
        f.ownerCurrent = true;
      });
      await _frames(tester);
      expect(
        await f.navigationGuard.flush(),
        isFalse,
        reason: 'An acquired draft still respects a save failure.',
      );
      expect(await f.state.flushDrafts(), isFalse);
      f.flushSucceeds = true;
      expect(await f.navigationGuard.flush(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AppState loading notifications do not retire an unacquired document and ready resumes image references',
    (tester) async {
      final f = _Fixture(text: _imageMarkdown)
        ..enabled = false
        ..ownerCurrent = false
        // Deliberately retain the same text and snapshot through acquisition.
        // There is no content edit or inline reference list to mask a missed
        // reference read while the initial conversation was still loading.
        ..snapshotOverride = {
          'peer': 73,
          'accessRevision': 0,
          'content': _imageMarkdown,
          'imageSizing': <JsonMap>[],
        };
      await f.mount(tester);
      final field = tester.element(_body);
      final media = _media(tester).controller;
      f.native.draftRead = Completer<JsonMap>();
      final loading = f.state.act('inbox.getDraft', {'peer': 73});
      await _frames(tester, 8);
      expect(f.state.pending, isNotEmpty);
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isTrue);
      expect(media.feedback, isNull);
      expect(find.text('账号已变更，请重新打开编辑器。'), findsNothing);
      expect(
        f.native.calls.where((call) => call.$1 == 'images.draftReferences'),
        isEmpty,
      );

      f.native.draftRead!.complete(f.snapshot);
      expect(await loading, f.snapshot);
      f.update(() {
        f.ownerCurrent = true;
        f.enabled = true;
      });
      await _frames(tester);
      expect(tester.element(_body), same(field));
      expect(tester.widget<CupertinoTextField>(_body).readOnly, isFalse);
      expect(_media(tester).controller, same(media));
      var openedSettings = 0;
      await media.manageSettings(
        presentSettings: () async {
          openedSettings++;
        },
      );
      await _frames(tester);
      expect(openedSettings, 1);
      expect(media.feedback, isNull);
      expect(find.text('账号已变更，请重新打开编辑器。'), findsNothing);
      expect(
        f.native.calls
            .where((call) => call.$1 == 'images.draftReferences')
            .map((call) => call.$2['content']),
        [_imageMarkdown],
      );
      _controls(tester).onModeChanged(2);
      await _frames(tester);
      final sizing = tester
          .widget<ComposerMarkdownPreview>(find.byType(ComposerMarkdownPreview))
          .imageSizing!;
      expect(sizing.imageURLs, {_image});
      expect(sizing.stage(_image, .5, 500), isTrue);
      expect(sizing.feedback, isNull);
      expect(f.controller.text, _imageMarkdown);
      expect(f.changes, isEmpty);
      expect(
        f.native.calls.where((call) => call.$1 == 'system.chooseImage'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a retired account permits departure without accepting its unfinished upload',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      f.native.upload = Completer<JsonMap>();
      _media(tester).onUpload();
      await _frames(tester);
      expect(await f.navigationGuard.flush(), isFalse);
      f.native.accessRevision = 1;
      f.state.showMessage('账号状态已更新');
      f.update(() => f.ownerCurrent = false);
      await _frames(tester);
      expect(await f.navigationGuard.flush(), isTrue);
      expect(await f.state.flushDrafts(), isTrue);
      expect(f.flushes, 0);
      f.native.upload!.complete({'markdown': 'RETIRED ACCOUNT UPLOAD'});
      await _frames(tester);
      expect(f.controller.text, 'draft');
      expect(f.changes, isEmpty);
      expect(f.sends, isEmpty);
      f.update(() {
        f.revision = 1;
        f.ownerCurrent = true;
        f.controller.value = _value('new account draft');
      });
      await _frames(tester);
      f.flushSucceeds = false;
      expect(await f.navigationGuard.flush(), isFalse);
      f.flushSucceeds = true;
      expect(await f.navigationGuard.flush(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a flush begun by a current owner cannot turn retirement into approval',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      f.flushGate = Completer<bool>();
      final pending = f.navigationGuard.flush();
      await tester.pump();
      expect(f.flushes, 1);
      f.update(() => f.ownerCurrent = false);
      await tester.pump();
      f.flushGate!.complete(true);
      expect(await pending, isFalse);
      // A new departure check can leave the retired shell. It is not approval
      // from the old save, whose original owner contract has already failed.
      expect(await f.navigationGuard.flush(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigation blocks pending or failed sizing and rejects a retired flush completion',
    (tester) async {
      final f = _Fixture(text: _imageMarkdown);
      await f.mount(tester);
      _controls(tester).onModeChanged(2);
      await _frames(tester);
      final sizing = tester
          .widget<ComposerMarkdownPreview>(find.byType(ComposerMarkdownPreview))
          .imageSizing!;
      expect(sizing.stage(_image, .5, 500), isTrue);
      f.flushGate = Completer<bool>();
      final saving = sizing.flush();
      await tester.pump();
      expect(sizing.busy, isTrue);
      expect(await f.navigationGuard.flush(), isFalse);
      expect(f.peer, 73);
      f.flushGate!.complete(false);
      expect(await saving, isFalse);
      f.flushGate = null;
      f.flushSucceeds = false;
      expect(await f.navigationGuard.flush(), isFalse);
      expect(sizing.hasPendingChanges, isTrue);
      f.flushSucceeds = true;
      expect(await f.navigationGuard.flush(), isTrue);
      expect(sizing.hasPendingChanges, isFalse);
      expect(f.native.savedSize!['ratio'], .5);

      f.flushGate = Completer<bool>();
      final oldFlush = f.navigationGuard.flush();
      await tester.pump();
      // Simulate an account/route replacement outside normal guarded navigation.
      f.update(() {
        f.peer = 99;
        f.controller.value = _value('replacement document');
      });
      await _frames(tester);
      f.flushGate!.complete(true);
      expect(await oldFlush, isFalse);
      f.flushGate = null;
      f.flushSucceeds = false;
      expect(await f.navigationGuard.flush(), isFalse);
      f.flushSucceeds = true;
      expect(await f.navigationGuard.flush(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await f.navigationGuard.flush(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image sizing flushes the exact private draft and retains unsaved choices on failure',
    (tester) async {
      final f = _Fixture(text: _imageMarkdown);
      await f.mount(tester);
      _controls(tester).onModeChanged(2);
      await _frames(tester);
      final preview = tester.widget<ComposerMarkdownPreview>(
        find.byType(ComposerMarkdownPreview),
      );
      final sizing = preview.imageSizing!;
      expect(sizing.stage(_image, .5, 500), isTrue);
      expect(await sizing.flush(), isTrue);
      expect(f.flushes, 1);
      expect(f.native.savedSize, {
        'peer': 73,
        'expectedContent': _imageMarkdown,
        'url': _image,
        'ratio': .5,
        'previewWidth': 500.0,
      });
      expect(f.controller.text, _imageMarkdown);
      expect(f.changes, isEmpty);
      expect(sizing.stage(_image, .4, 500), isTrue);
      f.flushSucceeds = false;
      expect(await sizing.flush(), isFalse);
      expect(sizing.hasPendingChanges, isTrue);
      expect(f.native.savedSize!['ratio'], .5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long local sizing errors scroll independently in a short window without hiding tools or send',
    (tester) async {
      final f = _Fixture(text: _imageMarkdown);
      await f.mount(tester);
      await tester.binding.setSurfaceSize(const Size(340, 360));
      f.update(() => f.key.currentState!.scale = 2);
      await _frames(tester);
      final field = tester.element(_body);
      _controls(tester).onModeChanged(2);
      await _frames(tester);
      final preview = tester.widget<ComposerMarkdownPreview>(
        find.byType(ComposerMarkdownPreview),
      );
      final sizing = preview.imageSizing!;
      _controls(tester).onModeChanged(0);
      await _frames(tester);
      final diagnostic = List.generate(
        12,
        (index) => '本地测试错误第 ${index + 1} 行：草稿目录暂时无法写入。',
      ).join('\n');
      f.native.sizeFailure = NativeFailure('local_fixture', diagnostic);
      expect(sizing.stage(_image, .5, 500), isTrue);
      expect(await sizing.flush(), isFalse);
      await _frames(tester);

      final status = find.byKey(const ValueKey('inbox-composer-status'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: status, matching: find.byType(Scrollable)),
      );
      expect(find.text('$diagnostic 图片大小修改已保留，可重试。'), findsOneWidget);
      expect(
        tester.getSize(status).height,
        lessThanOrEqualTo(tester.getSize(find.byKey(_panelKey)).height * .25),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      await tester.drag(status, const Offset(0, -150));
      await _frames(tester);
      expect(scroll.position.pixels, greaterThan(0));
      expect(find.text('Conversation history').hitTestable(), findsOneWidget);
      for (final tool in MarkdownCommand.values) {
        await tester.ensureVisible(_tool(tool));
        await _frames(tester);
        expect(_tool(tool).hitTestable(), findsOneWidget);
        expect(find.byKey(_sendKey).hitTestable(), findsOneWidget);
      }
      await tester.ensureVisible(_body);
      await _frames(tester);
      expect(_body.hitTestable(), findsOneWidget);
      expect(tester.element(_body), same(field));
      expect(find.byKey(_sendKey).hitTestable(), findsOneWidget);
      expect(f.controller.text, _imageMarkdown);
      expect(sizing.hasPendingChanges, isTrue);
      expect(f.native.savedSize, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short and narrow windows leave chat space and scroll every direct tool into view',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final field = tester.element(_body);
      for (final (size, scale) in [
        (const Size(1000, 900), 1.0),
        (const Size(520, 540), 1.0),
        (const Size(340, 460), 2.0),
      ]) {
        await tester.binding.setSurfaceSize(size);
        f.update(() => f.key.currentState!.scale = scale);
        await _frames(tester);
        expect(
          tester.getSize(find.byKey(_panelKey)).height,
          lessThanOrEqualTo(size.height * .42 + .01),
        );
        expect(find.text('Conversation history').hitTestable(), findsOneWidget);
        expect(tester.element(_body), same(field));
        expect(find.byType(MarkdownToolButton), findsNWidgets(13));
        expect(find.byKey(_sendKey).hitTestable(), findsOneWidget);
        for (final tool in MarkdownCommand.values) {
          await tester.ensureVisible(_tool(tool));
          await _frames(tester);
          expect(_tool(tool).hitTestable(), findsOneWidget);
          expect(find.byKey(_sendKey).hitTestable(), findsOneWidget);
        }
        expect(find.byKey(_sendKey).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
