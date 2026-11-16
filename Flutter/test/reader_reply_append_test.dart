import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/reader_editor_binding.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/reader_editors.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';

const _url = 'https://www.nodeseek.com/post-17-1';
final _topic = TopicData({'id': '17', 'url': _url, 'title': 'Owned topic'});
final _floor = FloorData({
  'id': '9',
  'author': 'Alice',
  'blocks': [
    {'kind': 'text', 'text': 'Quoted source'},
  ],
});

class _ReplyNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Completer<JsonMap>? draftRead, imageRead;
  String draft = 'Existing draft';

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'reader.replyDraft':
        return draftRead == null ? {'content': draft} : await draftRead!.future;
      case 'reader.updateReplyDraft':
        draft = stringValue(arguments['content']);
        return {'content': draft};
      case 'images.keyStatus':
        return {'configured': true};
      case 'system.chooseImage':
        return imageRead == null ? {} : await imageRead!.future;
      default:
        throw NativeFailure(
          'fixture_only',
          'Unsupported fixture call: $method',
        );
    }
  }
}

class _Harness {
  _Harness() {
    state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'canCompose': true};
    state.domains['workspace'] = {
      'selectedTab': '17',
      'tabs': [
        {'id': '17', 'url': _url, 'title': 'Owned topic'},
      ],
    };
    state.readers[_url] = {
      'thread': {'replyRestriction': ''},
    };
    editors = ReaderEditors(
      state: state,
      readerVisible: () => visible,
      canInteract: () => interactive,
      navigationIdentity: () => navigation,
      revealTopic: (_) async {},
    );
  }
  final native = _ReplyNative();
  late final AppState state;
  late final ReaderEditors editors;
  int navigation = 0;
  bool visible = true, interactive = true;

  void leave() {
    navigation++;
    visible = false;
    editors.refresh();
  }
}

Finder get _body => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);
TextEditingController _controller(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(_body).controller!;

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, _Harness h) async {
  await tester.binding.setSurfaceSize(const Size(900, 650));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    CupertinoApp(
      home: GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoPageScaffold(
          child: ListenableBuilder(
            listenable: h.editors,
            builder: (context, _) => Stack(
              children: [
                for (final session in h.editors.sessions)
                  Offstage(
                    key: ValueKey(session.id),
                    offstage: !identical(session, h.editors.presented),
                    child: SizedBox(
                      width: 880,
                      height: 380,
                      child: ComposerScreen(
                        state: h.state,
                        topicID: session.topic.id,
                        url: session.topic.url,
                        binding: session.binding,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    h.editors.dispose();
    h.state.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a queued binding append is single-use and cancels on navigation',
    () async {
      var navigation = 1;
      final binding = ReaderEditorBinding(
        accessRevision: 0,
        isActive: () => true,
        navigationIdentity: () => navigation,
        onClosed: () {},
        onSubmitted: (_, _) {},
      );
      final pending = binding.appendReply((_) => 'one');
      expect(await binding.appendReply((_) => 'two'), false);
      navigation++;
      binding.refresh();
      expect(await pending, false);
      expect(binding.takeReplyAppend(), isNull);
      navigation--;
      binding.refresh();
      expect(binding.takeReplyAppend(), isNull);
      final disposed = binding.appendReply((_) => 'three');
      binding.dispose();
      expect(await disposed, false);
    },
  );

  testWidgets(
    'loaded reply appends at end in one undo transaction and focuses source',
    (tester) async {
      final h = _Harness();
      await _mount(tester, h);
      await h.editors.open(_topic);
      await _frames(tester);
      final controller = _controller(tester);
      controller.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 4,
      );
      final before = controller.value;
      final element = tester.element(_body);
      final accepted = h.editors.replyTo(_topic, _floor);
      await _frames(tester);
      expect(await accepted, true);
      expect(_controller(tester), same(controller));
      expect(tester.element(_body), same(element));
      expect(controller.text, 'Existing draft\n\n@Alice [#9]($_url#9)\n\n');
      expect(controller.selection.baseOffset, controller.text.length);
      expect(
        tester.widget<CupertinoTextField>(_body).focusNode!.hasFocus,
        true,
      );
      final history = tester
          .widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls))
          .history;
      expect(history.undo(), true);
      expect(controller.value, before);
      expect(history.redo(), true);
      expect(controller.text, contains('@Alice [#9]'));
      expect(
        h.native.calls.where((entry) => entry.$1 == 'reader.replyDraft'),
        hasLength(1),
      );
      expect(
        h.native.calls.where((entry) => entry.$1 == 'reader.sendReply'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'new reply waits for owned draft then quotes once with no direct overwrite',
    (tester) async {
      final h = _Harness();
      h.native.draftRead = Completer<JsonMap>();
      await _mount(tester, h);
      final first = h.editors.replyTo(_topic, _floor, quoting: true);
      await _frames(tester);
      final second = h.editors.replyTo(_topic, _floor);
      await _frames(tester);
      expect(await second, false);
      expect(
        h.native.calls.where((entry) => entry.$1 == 'reader.updateReplyDraft'),
        isEmpty,
      );
      h.native.draftRead!.complete({'content': 'Persisted first'});
      await _frames(tester);
      expect(await first, true);
      expect(
        _controller(tester).text,
        'Persisted first\n\n> @Alice [#9]($_url#9)\n>\n> Quoted source\n\n',
      );
      h.editors.refresh();
      await _frames(tester);
      expect('@Alice'.allMatches(_controller(tester).text), hasLength(1));
      expect(
        h.native.calls.where((entry) => entry.$1 == 'reader.updateReplyDraft'),
        isEmpty,
      );
      await tester.pump(const Duration(milliseconds: 450));
      expect(h.native.draft, _controller(tester).text);
    },
  );

  for (final change in ['navigation', 'account', 'close']) {
    testWidgets(
      '$change before draft completion cancels the append without replay',
      (tester) async {
        final h = _Harness();
        h.native.draftRead = Completer<JsonMap>();
        await _mount(tester, h);
        final pending = h.editors.replyTo(_topic, _floor);
        await _frames(tester);
        if (change == 'navigation') {
          h.leave();
        } else if (change == 'account') {
          h.native.accessRevision++;
          h.navigation++;
          h.editors.refresh();
        } else {
          h.editors.sessions.single.binding.close();
        }
        await _frames(tester);
        expect(await pending, false);
        h.native.draftRead!.complete({'content': 'Original only'});
        await _frames(tester);
        h.visible = true;
        h.navigation++;
        h.editors.refresh();
        await _frames(tester);
        if (change == 'navigation') {
          expect(_controller(tester).text, 'Original only');
        }
        expect(
          h.native.calls.where(
            (entry) => entry.$1 == 'reader.updateReplyDraft',
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'IME composition rejects a reply immediately and never replays it',
    (tester) async {
      final h = _Harness();
      await _mount(tester, h);
      await h.editors.open(_topic);
      await _frames(tester);
      final controller = _controller(tester);
      controller.value = const TextEditingValue(
        text: 'pinyin',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      );
      expect(await h.editors.replyTo(_topic, _floor), false);
      controller.value = const TextEditingValue(
        text: '拼音',
        selection: TextSelection.collapsed(offset: 2),
      );
      await _frames(tester);
      expect(controller.text, '拼音');
      expect(h.editors.sessions.single.binding.hasReplyAppend, false);
    },
  );

  testWidgets('draft failure clears the request and retry does not replay it', (
    tester,
  ) async {
    final h = _Harness();
    h.native.draftRead = Completer<JsonMap>();
    await _mount(tester, h);
    final pending = h.editors.replyTo(_topic, _floor);
    await _frames(tester);
    h.native.draftRead!.completeError(
      const NativeFailure('fixture_only', 'Fixture draft read failed'),
    );
    await _frames(tester);
    expect(await pending, false);
    expect(h.editors.sessions.single.binding.hasReplyAppend, false);
    h.native.draftRead = null;
    await tester.tap(find.text('重试'));
    await _frames(tester);
    expect(_controller(tester).text, 'Existing draft');
    expect(
      h.native.calls.where((entry) => entry.$1 == 'reader.updateReplyDraft'),
      isEmpty,
    );
  });

  testWidgets(
    'a newly restricted thread cancels pending insertion after draft loading',
    (tester) async {
      final h = _Harness();
      h.native.draftRead = Completer<JsonMap>();
      await _mount(tester, h);
      final pending = h.editors.replyTo(_topic, _floor);
      await _frames(tester);
      h.state.readers[_url] = {
        'thread': {'replyRestriction': '主题已关闭'},
      };
      h.native.draftRead!.complete({'content': 'Keep this'});
      await _frames(tester);
      expect(await pending, false);
      expect(_controller(tester).text, 'Keep this');
    },
  );

  testWidgets(
    'reply from preview exposes the same source field and restores focus',
    (tester) async {
      final h = _Harness();
      await _mount(tester, h);
      await h.editors.open(_topic);
      await _frames(tester);
      final controller = _controller(tester);
      final element = tester.element(_body);
      tester
          .widget<MarkdownEditorControls>(find.byType(MarkdownEditorControls))
          .onModeChanged(2);
      await _frames(tester);
      expect(_body.hitTestable(), findsNothing);
      final pending = h.editors.replyTo(_topic, _floor, quoting: true);
      await _frames(tester);
      expect(await pending, true);
      expect(tester.element(_body), same(element));
      expect(_controller(tester), same(controller));
      expect(
        tester.widget<CupertinoTextField>(_body).focusNode!.hasFocus,
        true,
      );
      expect(controller.text, contains('> Quoted source'));
    },
  );

  testWidgets(
    'pending media rejects a floor insertion and remains independently owned',
    (tester) async {
      final h = _Harness();
      h.native.imageRead = Completer<JsonMap>();
      await _mount(tester, h);
      await h.editors.open(_topic);
      await _frames(tester);
      final media = tester
          .widget<ComposerMediaTools>(find.byType(ComposerMediaTools))
          .controller;
      final upload = media.upload(requestKey: () async => null);
      await _frames(tester);
      expect(media.busy, true);
      expect(await h.editors.replyTo(_topic, _floor), false);
      h.native.imageRead!.complete({'markdown': '<fixture-image>'});
      await upload;
      await _frames(tester);
      expect(_controller(tester).text, contains('<fixture-image>'));
      expect(_controller(tester).text, isNot(contains('@Alice')));
    },
  );

  test(
    'floor editor blocks reply without invoking close or changing ownership',
    () async {
      final h = _Harness();
      await h.editors.open(_topic, floor: 9);
      final session = h.editors.sessions.single;
      var closes = 0;
      session.binding.requestClose = () async {
        closes++;
      };
      session.binding.operationBusy = () => false;
      expect(await h.editors.replyTo(_topic, _floor), false);
      expect(closes, 0);
      expect(h.editors.sessions.single, same(session));
      expect(h.state.message, contains('请先保存或关闭'));
      h.editors.dispose();
      h.state.dispose();
    },
  );

  test(
    'untrusted floor URL never opens an editor or invokes native work',
    () async {
      final h = _Harness();
      final bad = TopicData({
        'id': '17',
        'url': 'https://example.invalid/post-17-1',
      });
      expect(await h.editors.replyTo(bad, _floor), false);
      expect(h.editors.sessions, isEmpty);
      expect(h.native.calls, isEmpty);
      h.editors.dispose();
      h.state.dispose();
    },
  );
}
