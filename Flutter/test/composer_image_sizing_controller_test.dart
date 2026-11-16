import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_image_sizing_controller.dart';

const _one = 'https://example.invalid/one.png';
const _two = 'https://example.invalid/two.png';
const _body = '![]($_one)\n![]($_two)\n![]($_one)';

class _SizingNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  final sizes = <String, DraftImageSize>{};
  final references = <String, List<String>>{
    _body: [_one, _two, _one],
  };
  String text = _body;
  Future<JsonMap?> Function(String, JsonMap)? response;

  JsonMap snapshot({String? content, List<String>? imageURLs}) => {
    'content': content ?? text,
    'accessRevision': accessRevision,
    'editToken': 'fixture-editor',
    'imageURLs': imageURLs ?? references[content ?? text] ?? [],
    'imageSizing': [
      for (final entry in sizes.entries)
        {
          'url': entry.key,
          'ratio': entry.value.ratio,
          'previewWidth': entry.value.previewWidth,
        },
    ],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (response case final callback?) {
      final override = await callback(method, arguments);
      if (override != null) return override;
    }
    switch (method) {
      case 'images.draftReferences':
        final content = arguments['content'] as String;
        return {
          'content': content,
          'imageURLs': references[content] ?? [],
          'accessRevision': accessRevision,
        };
      case 'fixture.synchronize':
        text = arguments['content'] as String;
        return snapshot();
      case 'fixture.setSize':
        expect(arguments['expectedContent'], text);
        final url = arguments['url'] as String;
        final ratio = arguments['ratio'] as double;
        if (ratio == 1) {
          sizes.remove(url);
        } else {
          sizes[url] = DraftImageSize(
            ratio: ratio,
            previewWidth: arguments['previewWidth'] as double,
          );
        }
        return snapshot();
      default:
        throw StateError('Unexpected fixture call: $method');
    }
  }
}

class _Editor {
  _Editor({bool seed = true, bool validateIdentity = false}) {
    state = AppState(client: native);
    content = TextEditingController(text: _body);
    sizing = ComposerImageSizingController(
      state: state,
      content: content,
      revision: state.accessRevision,
      canChange: () => enabled,
      isCurrent: () => current,
      synchronize: (expected) async {
        if (synchronize case final callback?) return callback(expected);
        return native.call('fixture.synchronize', {'content': expected});
      },
      saveSize: (url, ratio, width, expected) async {
        if (saveSize case final callback?) {
          return callback(url, ratio, width, expected);
        }
        return native.call('fixture.setSize', {
          'url': url,
          'ratio': ratio,
          'previewWidth': width,
          'expectedContent': expected,
        });
      },
      validateSnapshot: validateIdentity
          ? (snapshot) => snapshot['editToken'] == 'fixture-editor'
          : null,
      onEdited: () => edits++,
    );
    if (seed) sizing.acceptSnapshot(native.snapshot());
  }

  final native = _SizingNative();
  late final AppState state;
  late final TextEditingController content;
  late final ComposerImageSizingController sizing;
  Future<JsonMap?> Function(String)? synchronize;
  Future<JsonMap?> Function(String, double, double, String)? saveSize;
  bool enabled = true, current = true, disposed = false, stateDisposed = false;
  int edits = 0;

  void disposeEditor() {
    if (disposed) return;
    disposed = true;
    sizing.dispose();
    content.dispose();
  }

  void dispose() {
    disposeEditor();
    if (stateDisposed) return;
    stateDisposed = true;
    state.dispose();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshots restore shared URL sizes and omit invalid metadata', () {
    final editor = _Editor();
    addTearDown(editor.dispose);
    editor.sizing.acceptSnapshot({
      ...editor.native.snapshot(),
      'imageURLs': [_one, _one, _two, 'file:///fixture', 'https://u:p@host/a'],
      'imageSizing': [
        {'url': _one, 'ratio': 0.4, 'previewWidth': 640},
        {'url': _two, 'ratio': double.nan, 'previewWidth': 300},
        {'url': 'https://bad.invalid', 'ratio': 0.2, 'previewWidth': 2000},
      ],
    });
    expect(editor.sizing.imageURLs, {_one, _two});
    expect(
      editor.sizing.sizeFor(_one),
      const DraftImageSize(ratio: 0.4, previewWidth: 640),
    );
    expect(editor.sizing.sizeFor(_two), const DraftImageSize());
    expect(editor.sizing.hasPendingChanges, false);
    expect(editor.native.calls, isEmpty);
    expect(() => editor.sizing.imageURLs.add('other'), throwsUnsupportedError);
  });

  test('stage is local, validates inputs and normalizes native width', () {
    final editor = _Editor();
    addTearDown(editor.dispose);
    expect(editor.sizing.stage(_one, 0.5, 1400), true);
    expect(editor.sizing.sizeFor(_one).previewWidth, 1080);
    expect(editor.sizing.hasPendingChanges, true);
    expect(editor.edits, 1);
    expect(editor.sizing.stage(_one, 0.5, 1400), true);
    expect(editor.edits, 1);
    for (final ratio in [double.nan, double.infinity, 0.09, 1.01]) {
      expect(editor.sizing.stage(_one, ratio, 600), false);
    }
    for (final width in [double.nan, double.infinity, 0.0, -1.0]) {
      expect(editor.sizing.stage(_one, 0.5, width), false);
    }
    expect(editor.sizing.stage('https://absent.invalid', 0.5, 600), false);
    expect(editor.sizing.stage(_one, 1, 600), true);
    expect(editor.sizing.hasPendingChanges, false);
    expect(editor.native.calls, isEmpty);
    expect(editor.edits, 2);
  });

  test(
    'flush synchronizes exact content before sizes without editing text',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.content.value = const TextEditingValue(
        text: _body,
        selection: TextSelection(baseOffset: 7, extentOffset: 2),
        composing: TextRange(start: 1, end: 4),
      );
      final original = editor.content.value;
      editor.sizing.stage(_one, 0.5, 639.8);
      editor.sizing.stage(_two, 0.8, 640);
      expect(await editor.sizing.flush(), true);
      expect(editor.native.calls.map((call) => call.$1), [
        'fixture.synchronize',
        'fixture.setSize',
        'fixture.setSize',
      ]);
      for (final call in editor.native.calls.skip(1)) {
        expect(call.$2['expectedContent'], _body);
      }
      expect(editor.content.value, original);
      expect(editor.sizing.sizeFor(_one).previewWidth, 640);
      expect(editor.sizing.hasPendingChanges, false);
      expect(editor.sizing.busy, false);
      expect(editor.edits, 2);
    },
  );

  test('returning to 100 percent deletes the persisted size choice', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    editor.native.sizes[_one] = const DraftImageSize(
      ratio: 0.5,
      previewWidth: 600,
    );
    editor.sizing.acceptSnapshot(editor.native.snapshot());
    editor.sizing.stage(_one, 1, 600);
    expect(await editor.sizing.flush(), true);
    expect(editor.native.sizes, isEmpty);
    expect(editor.sizing.sizeFor(_one), const DraftImageSize());
    expect(editor.sizing.hasPendingChanges, false);
  });

  test(
    'sending or closing may flush existing changes while stage is disabled',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.sizing.stage(_one, 0.5, 600);
      editor.enabled = false;
      expect(editor.sizing.stage(_one, 0.7, 600), false);
      expect(await editor.sizing.flush(), true);
      expect(editor.native.sizes[_one]?.ratio, 0.5);
    },
  );

  test('concurrent flush callers share one serial attempt', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final gate = Completer<JsonMap?>();
    var synchronizations = 0;
    editor.synchronize = (_) {
      synchronizations++;
      return gate.future;
    };
    editor.sizing.stage(_one, 0.5, 600);
    final first = editor.sizing.flush();
    final second = editor.sizing.flush();
    expect(identical(first, second), true);
    expect(editor.sizing.busy, true);
    expect(synchronizations, 1);
    gate.complete(editor.native.snapshot());
    expect(await first, true);
    expect(await second, true);
    expect(
      editor.native.calls.where((call) => call.$1 == 'fixture.setSize'),
      hasLength(1),
    );
    expect(editor.sizing.busy, false);
  });

  for (final failsByThrowing in [false, true]) {
    for (final phase in ['synchronize', 'setSize']) {
      test(
        '$phase ${failsByThrowing ? 'throw' : 'null'} retains choices until explicit retry',
        () async {
          final editor = _Editor();
          addTearDown(editor.dispose);
          var attempts = 0;
          Future<JsonMap?> failAttempt() async {
            attempts++;
            if (failsByThrowing) {
              throw const NativeFailure('fixture_failure', 'Fixture failure');
            }
            return null;
          }

          if (phase == 'synchronize') {
            editor.synchronize = (_) => failAttempt();
          } else {
            editor.saveSize = (_, _, _, _) => failAttempt();
          }
          editor.sizing.stage(_one, 0.5, 600);
          expect(await editor.sizing.flush(), false);
          await _turn();
          expect(attempts, 1);
          expect(editor.sizing.busy, false);
          expect(editor.sizing.hasPendingChanges, true);
          expect(editor.sizing.sizeFor(_one).ratio, 0.5);
          expect(editor.sizing.feedback, contains('已保留'));
          expect(editor.native.sizes, isEmpty);
          editor.synchronize = null;
          editor.saveSize = null;
          expect(await editor.sizing.flush(), true);
          expect(editor.sizing.feedback, isNull);
          expect(editor.sizing.hasPendingChanges, false);
        },
      );
    }
  }

  for (final invalidation in ['account', 'target', 'dispose']) {
    for (final phase in ['synchronize', 'setSize']) {
      test(
        '$invalidation during $phase rejects late results and further writes',
        () async {
          final editor = _Editor();
          addTearDown(editor.dispose);
          final gate = Completer<JsonMap?>();
          var writes = 0;
          final before = editor.native.snapshot();
          editor.synchronize = (_) {
            if (phase == 'synchronize') return gate.future;
            return Future<JsonMap?>.value(before);
          };
          editor.saveSize = (_, _, _, _) async {
            writes++;
            return gate.future;
          };
          editor.sizing.stage(_one, 0.5, 600);
          editor.sizing.stage(_two, 0.6, 600);
          final flushing = editor.sizing.flush();
          await _turn();
          expect(writes, phase == 'setSize' ? 1 : 0);
          switch (invalidation) {
            case 'account':
              editor.native.accessRevision++;
              editor.state.showMessage('fixture account event');
            case 'target':
              editor.current = false;
            case 'dispose':
              editor.disposeEditor();
          }
          gate.complete({
            ...before,
            'imageSizing': [
              {'url': _one, 'ratio': 0.2, 'previewWidth': 400},
            ],
          });
          expect(await flushing, false);
          expect(editor.sizing.hasPendingChanges, true);
          expect(editor.sizing.sizeFor(_one).ratio, 0.5);
          expect(writes, phase == 'setSize' ? 1 : 0);
          expect(await editor.sizing.flush(), false);
          expect(editor.native.calls, isEmpty);
        },
      );
    }
  }

  test('new text during synchronization stops setters and explicit retry uses latest text', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final gate = Completer<JsonMap?>();
    editor.synchronize = (_) => gate.future;
    editor.sizing.stage(_one, 0.5, 600);
    final flushing = editor.sizing.flush();
    const latest = 'new text\n$_body';
    editor.native.references[latest] = [_one, _two];
    editor.content.text = latest;
    gate.complete(editor.native.snapshot());
    expect(await flushing, false);
    expect(editor.content.text, latest);
    expect(editor.sizing.hasPendingChanges, true);
    expect(editor.native.calls, isEmpty);
    editor.synchronize = null;
    expect(await editor.sizing.flush(), true);
    expect(editor.native.calls.last.$2['expectedContent'], latest);
    expect(editor.content.text, latest);
  });

  test(
    'text changing away and back still invalidates a suspended attempt',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      final gate = Completer<JsonMap?>();
      editor.synchronize = (_) => gate.future;
      editor.sizing.stage(_one, 0.5, 600);
      final flushing = editor.sizing.flush();
      editor.content.text = 'temporary';
      editor.content.text = _body;
      gate.complete(editor.native.snapshot());
      expect(await flushing, false);
      expect(editor.sizing.hasPendingChanges, true);
      expect(editor.native.calls, isEmpty);
    },
  );

  test('new text during a setter preserves newer content and stops the remaining batch', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final gate = Completer<JsonMap?>();
    var writes = 0;
    editor.saveSize = (_, _, _, _) {
      writes++;
      return gate.future;
    };
    editor.sizing.stage(_one, 0.5, 600);
    editor.sizing.stage(_two, 0.6, 600);
    final flushing = editor.sizing.flush();
    await _turn();
    editor.content.text = 'new body';
    gate.complete({
      ...editor.native.snapshot(),
      'imageSizing': [
        {'url': _one, 'ratio': 0.5, 'previewWidth': 600},
      ],
    });
    expect(await flushing, false);
    expect(writes, 1);
    expect(editor.content.text, 'new body');
    expect(editor.sizing.hasPendingChanges, true);
    expect(editor.sizing.sizeFor(_two).ratio, 0.6);
  });

  test('a newer slider choice during synchronization is included in the same attempt', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final gate = Completer<JsonMap?>();
    editor.synchronize = (_) => gate.future;
    editor.sizing.stage(_one, 0.5, 600);
    final flushing = editor.sizing.flush();
    editor.sizing.stage(_one, 0.7, 600);
    editor.sizing.acceptSnapshot(editor.native.snapshot());
    expect(editor.sizing.sizeFor(_one).ratio, 0.7);
    gate.complete(editor.native.snapshot());
    expect(await flushing, true);
    expect(editor.native.sizes[_one]?.ratio, 0.7);
  });

  for (final newerRatio in [0.7, 1.0]) {
    test(
      'a newer $newerRatio choice survives the older in-flight setter',
      () async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        final gate = Completer<JsonMap?>();
        editor.saveSize = (_, _, _, _) => gate.future;
        editor.sizing.stage(_one, 0.5, 600);
        final flushing = editor.sizing.flush();
        await _turn();
        editor.sizing.stage(_one, newerRatio, 600);
        editor.native.sizes[_one] = const DraftImageSize(
          ratio: 0.5,
          previewWidth: 600,
        );
        gate.complete(editor.native.snapshot());
        expect(await flushing, false);
        expect(editor.sizing.hasPendingChanges, true);
        expect(editor.sizing.sizeFor(_one).ratio, newerRatio);
        editor.saveSize = null;
        expect(await editor.sizing.flush(), true);
        expect(editor.sizing.sizeFor(_one).ratio, newerRatio);
        expect(editor.sizing.hasPendingChanges, false);
        if (newerRatio == 1) expect(editor.native.sizes, isEmpty);
      },
    );
  }

  test('a failure stops a multi-image batch without retrying or losing later changes', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    final writes = <String>[];
    editor.saveSize = (url, _, _, _) async {
      writes.add(url);
      return null;
    };
    editor.sizing.stage(_one, 0.5, 600);
    editor.sizing.stage(_two, 0.6, 600);
    expect(await editor.sizing.flush(), false);
    expect(writes, [_one]);
    expect(editor.sizing.sizeFor(_one).ratio, 0.5);
    expect(editor.sizing.sizeFor(_two).ratio, 0.6);
    editor.saveSize = null;
    expect(await editor.sizing.flush(), true);
    expect(editor.native.sizes.keys.toSet(), {_one, _two});
  });

  test(
    'old or wrong-target snapshots cannot overwrite sizes or pending overlays',
    () {
      final editor = _Editor(validateIdentity: true);
      addTearDown(editor.dispose);
      editor.native.sizes[_one] = const DraftImageSize(
        ratio: 0.5,
        previewWidth: 600,
      );
      editor.sizing.acceptSnapshot(editor.native.snapshot());
      final saved = editor.sizing.sizeFor(_one);
      for (final changed in [
        {'content': 'old content'},
        {'accessRevision': 22},
        {'editToken': 'old-editor'},
      ]) {
        editor.sizing.acceptSnapshot({
          ...editor.native.snapshot(),
          'imageSizing': [],
          ...changed,
        });
        expect(editor.sizing.sizeFor(_one), saved);
      }
      editor.sizing.acceptSnapshot({
        'content': _body,
        'editToken': 'fixture-editor',
      });
      expect(editor.sizing.sizeFor(_one), saved);
      expect(editor.sizing.imageURLs, {_one, _two});
      editor.sizing.stage(_one, 0.7, 600);
      editor.sizing.acceptSnapshot(editor.native.snapshot());
      expect(editor.sizing.sizeFor(_one).ratio, 0.7);
      expect(editor.sizing.hasPendingChanges, true);
    },
  );

  test(
    'wrong-target synchronize and setter results leave pending changes intact',
    () async {
      for (final phase in ['synchronize', 'setSize']) {
        final editor = _Editor(validateIdentity: true);
        addTearDown(editor.dispose);
        final wrong = {
          ...editor.native.snapshot(),
          'editToken': 'other-editor',
        };
        if (phase == 'synchronize') {
          editor.synchronize = (_) async => wrong;
        } else {
          editor.saveSize = (_, _, _, _) async => wrong;
        }
        editor.sizing.stage(_one, 0.5, 600);
        expect(await editor.sizing.flush(), false);
        expect(editor.sizing.hasPendingChanges, true);
        expect(editor.sizing.sizeFor(_one).ratio, 0.5);
        expect(editor.native.sizes, isEmpty);
      }
    },
  );

  test(
    'an unconfirmed size result cannot silently clear a pending selection',
    () async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.saveSize = (_, _, _, _) async => editor.native.snapshot();
      editor.sizing.stage(_one, 0.5, 600);
      expect(await editor.sizing.flush(), false);
      expect(editor.sizing.hasPendingChanges, true);
      expect(editor.sizing.sizeFor(_one).ratio, 0.5);
      expect(editor.sizing.feedback, contains('尚未确认'));
    },
  );

  testWidgets(
    'reference reads debounce text changes and ignore selection-only changes',
    (tester) async {
      final editor = _Editor(seed: false);
      addTearDown(editor.dispose);
      editor.content.text = 'first';
      await tester.pump(const Duration(milliseconds: 70));
      editor.content.text = 'second';
      editor.native.references['second'] = [_two];
      await tester.pump(const Duration(milliseconds: 119));
      expect(editor.native.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(editor.native.calls.single.$1, 'images.draftReferences');
      expect(editor.native.calls.single.$2, {'content': 'second'});
      expect(editor.sizing.imageURLs, {_two});
      editor.content.selection = const TextSelection.collapsed(offset: 2);
      editor.content.value = editor.content.value.copyWith(
        composing: const TextRange(start: 0, end: 1),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(editor.native.calls, hasLength(1));
      expect(editor.sizing.stage(_two, 0.5, 600), true);
    },
  );

  testWidgets(
    'out-of-order reference responses cannot restore removed URLs or discard new pending sizes',
    (tester) async {
      final editor = _Editor(seed: false);
      addTearDown(editor.dispose);
      final old = Completer<JsonMap?>(), latest = Completer<JsonMap?>();
      editor.native.response = (_, args) =>
          args['content'] == _body ? old.future : latest.future;
      await tester.pump(const Duration(milliseconds: 120));
      editor.content.text = 'latest';
      await tester.pump(const Duration(milliseconds: 120));
      latest.complete({
        'content': 'latest',
        'accessRevision': 0,
        'imageURLs': [_two],
      });
      await tester.pump();
      expect(editor.sizing.stage(_two, 0.7, 600), true);
      old.complete({
        'content': _body,
        'accessRevision': 0,
        'imageURLs': [_one],
      });
      await tester.pump();
      expect(editor.sizing.imageURLs, {_two});
      expect(editor.sizing.sizeFor(_two).ratio, 0.7);
      expect(editor.sizing.hasPendingChanges, true);
    },
  );

  testWidgets(
    'confirmed deletion retires only removed pending sizes and keeps saved metadata for undo',
    (tester) async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.sizes[_one] = const DraftImageSize(
        ratio: 0.4,
        previewWidth: 600,
      );
      editor.sizing.acceptSnapshot(editor.native.snapshot());
      editor.sizing.stage(_one, 0.5, 600);
      editor.content.text = 'without images';
      expect(editor.sizing.hasPendingChanges, true);
      await tester.pump(const Duration(milliseconds: 120));
      expect(editor.sizing.imageURLs, isEmpty);
      expect(editor.sizing.hasPendingChanges, false);
      expect(await editor.sizing.flush(), true);
      expect(editor.native.sizes[_one]?.ratio, 0.4);
      editor.content.text = _body;
      await tester.pump(const Duration(milliseconds: 120));
      expect(editor.sizing.sizeFor(_one).ratio, 0.4);
      expect(
        editor.native.calls.every(
          (call) => call.$1 == 'images.draftReferences',
        ),
        true,
      );
    },
  );

  for (final replyLost in [false, true]) {
    testWidgets(
      'deleting and undoing an in-flight size keeps confirmed metadata consistent (${replyLost ? 'lost reply' : 'success'})',
      (tester) async {
        final editor = _Editor();
        addTearDown(editor.dispose);
        editor.native.sizes[_one] = const DraftImageSize(
          ratio: 0.4,
          previewWidth: 600,
        );
        editor.sizing.acceptSnapshot(editor.native.snapshot());
        final gate = Completer<JsonMap?>();
        var writes = 0;
        editor.saveSize = (_, _, _, _) {
          writes++;
          return gate.future;
        };
        editor.sizing.stage(_one, 0.5, 600);
        final flushing = editor.sizing.flush();
        await tester.pump();
        expect(writes, 1);
        editor.content.text = 'without images';
        await tester.pump(const Duration(milliseconds: 120));
        expect(editor.sizing.imageURLs, isEmpty);
        // Reference removal cannot make an unresolved mutation look saved.
        expect(editor.sizing.hasPendingChanges, true);
        editor.native.sizes[_one] = const DraftImageSize(
          ratio: 0.5,
          previewWidth: 600,
        );
        gate.complete(replyLost ? null : editor.native.snapshot());
        await tester.pump();
        expect(await flushing, false);
        expect(editor.content.text, 'without images');
        expect(editor.sizing.imageURLs, isEmpty);
        expect(editor.sizing.hasPendingChanges, replyLost);
        editor.content.text = _body;
        await tester.pump(const Duration(milliseconds: 120));
        expect(editor.sizing.imageURLs, {_one, _two});
        if (!replyLost) expect(editor.sizing.sizeFor(_one).ratio, 0.5);
        expect(await editor.sizing.flush(), true);
        expect(editor.sizing.sizeFor(_one).ratio, 0.5);
        expect(editor.native.sizes[_one]?.ratio, 0.5);
        expect(editor.sizing.hasPendingChanges, false);
        expect(writes, 1);
      },
    );
  }

  testWidgets(
    'a successful old-document setter confirms only its URL and preserves newer choices',
    (tester) async {
      final editor = _Editor();
      addTearDown(editor.dispose);
      editor.native.sizes[_one] = const DraftImageSize(
        ratio: 0.4,
        previewWidth: 600,
      );
      editor.sizing.acceptSnapshot(editor.native.snapshot());
      final gate = Completer<JsonMap?>();
      editor.saveSize = (_, _, _, _) => gate.future;
      editor.sizing.stage(_one, 0.5, 600);
      final flushing = editor.sizing.flush();
      await tester.pump();
      const latest = 'only one image ![]($_one)';
      editor.native.references[latest] = [_one];
      editor.content.text = latest;
      await tester.pump(const Duration(milliseconds: 120));
      expect(editor.sizing.stage(_one, 0.7, 600), true);
      editor.native.sizes[_one] = const DraftImageSize(
        ratio: 0.5,
        previewWidth: 600,
      );
      gate.complete(editor.native.snapshot());
      await tester.pump();
      expect(await flushing, false);
      expect(editor.content.text, latest);
      expect(editor.sizing.imageURLs, {_one});
      expect(editor.sizing.sizeFor(_one).ratio, 0.7);
      expect(editor.sizing.hasPendingChanges, true);
      editor.saveSize = null;
      expect(await editor.sizing.flush(), true);
      expect(editor.native.sizes[_one]?.ratio, 0.7);
    },
  );

  test('synchronized references allow flushing after the last sized image was deleted', () async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    editor.sizing.stage(_one, 0.5, 600);
    editor.content.text = 'no images';
    expect(await editor.sizing.flush(), true);
    expect(editor.sizing.hasPendingChanges, false);
    expect(editor.native.calls.map((call) => call.$1), ['fixture.synchronize']);
  });

  for (final invalidation in ['account', 'target', 'dispose']) {
    testWidgets('$invalidation rejects pending reference reads', (
      tester,
    ) async {
      final editor = _Editor(seed: false);
      addTearDown(editor.dispose);
      final gate = Completer<JsonMap?>();
      editor.native.response = (_, _) => gate.future;
      await tester.pump(const Duration(milliseconds: 120));
      switch (invalidation) {
        case 'account':
          editor.native.accessRevision++;
          editor.state.showMessage('fixture account event');
        case 'target':
          editor.current = false;
        case 'dispose':
          editor.disposeEditor();
      }
      gate.complete({
        'content': _body,
        'accessRevision': 0,
        'imageURLs': [_one],
      });
      await tester.pump();
      expect(editor.sizing.imageURLs, isEmpty);
      expect(editor.native.calls, hasLength(1));
      editor.dispose();
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('reference errors do not repeat reads or overwrite known sizes', (
    tester,
  ) async {
    final editor = _Editor();
    addTearDown(editor.dispose);
    editor.sizing.stage(_one, 0.5, 600);
    editor.native.response = (_, _) async =>
        throw const NativeFailure('fixture_read', 'Fixture read failure');
    editor.content.text = 'new text';
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(seconds: 2));
    expect(editor.native.calls, hasLength(1));
    expect(editor.sizing.hasPendingChanges, true);
    expect(editor.sizing.sizeFor(_one).ratio, 0.5);
    expect(editor.sizing.stage(_one, 0.6, 600), false);
  });
}
