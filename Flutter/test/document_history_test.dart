import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/document_history.dart';

TextEditingValue _value(String text, [TextSelection? selection]) =>
    TextEditingValue(
      text: text,
      selection: selection ?? TextSelection.collapsed(offset: text.length),
    );

void main() {
  late TextEditingController text;
  late DocumentHistory history;

  setUp(() {
    text = TextEditingController.fromValue(_value('seed'));
    history = DocumentHistory(controller: text);
  });

  tearDown(() {
    history.dispose();
    text.dispose();
  });

  test(
    'rapid typing, atomic formatting, and subsequent typing undo separately',
    () {
      text.value = _value('seed A');
      text.value = _value('seed AB');
      expect(
        history.canUndo,
        true,
        reason: 'Pending typing is immediately undoable.',
      );
      expect(history.execute((value) => _value('**${value.text}**')), true);
      text.value = _value('**seed AB** C');
      text.value = _value('**seed AB** CD');

      expect(history.undo(), true);
      expect(text.text, '**seed AB**');
      expect(history.undo(), true);
      expect(text.text, 'seed AB');
      expect(history.undo(), true);
      expect(text.text, 'seed');
      expect(history.canUndo, false);

      expect(history.redo(), true);
      expect(text.text, 'seed AB');
      expect(history.redo(), true);
      expect(text.text, '**seed AB**');
      expect(history.redo(), true);
      expect(text.text, '**seed AB** CD');
      expect(history.canRedo, false);
    },
  );

  test(
    'atomic edits restore exact directional selections and Unicode text',
    () {
      final original = _value(
        '甲😀乙',
        const TextSelection(
          baseOffset: 4,
          extentOffset: 1,
          isDirectional: true,
        ),
      );
      final formatted = _value(
        '甲**😀乙**',
        const TextSelection(
          baseOffset: 6,
          extentOffset: 3,
          isDirectional: true,
        ),
      );
      history.reset(original);
      expect(history.apply(formatted), true);
      expect(history.undo(), true);
      expect(text.value, original);
      expect(history.redo(), true);
      expect(text.value, formatted);
    },
  );

  test('runAtomic groups several synchronous changes and permits undo after a throw', () {
    history.runAtomic(() {
      text.value = _value('intermediate');
      text.value = _value('final command');
    });
    expect(history.undo(), true);
    expect(text.text, 'seed');
    expect(history.redo(), true);
    expect(text.text, 'final command');
    expect(
      () => history.runAtomic(() {
        text.value = _value('partial command');
        throw StateError('Fixture failure');
      }),
      throwsStateError,
    );
    expect(history.undo(), true);
    expect(text.text, 'final command');
  });

  test(
    'selection movement creates no undo entry but ends the typing group',
    () {
      text.value = _value('seedA');
      text.value = _value('seedAB');
      text.selection = const TextSelection.collapsed(offset: 0);
      text.value = _value('XseedAB', const TextSelection.collapsed(offset: 1));
      expect(history.undo(), true);
      expect(
        text.value,
        _value('seedAB', const TextSelection.collapsed(offset: 0)),
      );
      expect(history.undo(), true);
      expect(text.value, _value('seed'));
      expect(history.canUndo, false);
    },
  );

  testWidgets('idle typing groups commit without delaying command boundaries', (
    tester,
  ) async {
    text.value = _value('seedA');
    await tester.pump(const Duration(milliseconds: 250));
    text.value = _value('seedAB');
    await tester.pump(const Duration(milliseconds: 501));
    text.value = _value('seedABC');
    expect(history.undo(), true);
    expect(text.text, 'seedAB');
    expect(history.undo(), true);
    expect(text.text, 'seed');
    expect(history.redo(), true);
    expect(text.text, 'seedAB');
    expect(history.redo(), true);
    expect(text.text, 'seedABC');
  });

  test(
    'IME commits one transaction and never exposes intermediate composition',
    () {
      text.value = _value('seed ');
      final before = text.value;
      text.value = _value('seed n')
          .copyWith(composing: const TextRange(start: 5, end: 6));
      text.value = _value('seed ni')
          .copyWith(composing: const TextRange(start: 5, end: 7));
      expect(history.isComposing, true);
      expect(history.canUndo, false);
      expect(history.canRedo, false);
      expect(history.undo(), false);
      expect(history.redo(), false);
      var invoked = false;
      expect(history.runAtomic(() => invoked = true), false);
      expect(
        history.execute((_) {
          invoked = true;
          return _value('bad');
        }),
        false,
      );
      expect(history.apply(_value('bad')), false);
      expect(invoked, false);
      expect(text.text, 'seed ni');

      text.value = _value('seed 你');
      expect(history.isComposing, false);
      expect(history.undo(), true);
      expect(text.value, before);
      expect(history.undo(), true);
      expect(text.text, 'seed');
      expect(history.redo(), true);
      expect(history.redo(), true);
      expect(text.value, _value('seed 你'));
    },
  );

  test(
    'cancelled composition keeps redo and never adds a partial-text entry',
    () {
      history.apply(_value('command'));
      history.undo();
      text.value = _value('seedn')
          .copyWith(composing: const TextRange(start: 4, end: 5));
      expect(history.canRedo, false);
      text.value = _value('seed');
      expect(history.canUndo, false);
      expect(history.canRedo, true);
      history.redo();
      expect(text.text, 'command');
    },
  );

  test('new typing drops redo but no-op commands preserve it', () {
    history.apply(_value('one'));
    history.apply(_value('two'));
    history.undo();
    expect(history.runAtomic(() {}), true);
    expect(history.execute((value) => value), true);
    expect(history.canRedo, true);
    text.value = _value('one!');
    expect(history.canRedo, false);
    history.undo();
    expect(text.text, 'one');
    history.redo();
    expect(text.text, 'one!');
  });

  test(
    'reset clears pending edits and redo without making loading undoable',
    () {
      text.value = _value('pending text');
      history.reset();
      expect(text.text, 'pending text');
      expect(history.canUndo, false);
      history.apply(_value('new command'));
      history.undo();
      expect(history.canRedo, true);
      history.reset(_value('another loaded draft'));
      expect(text.text, 'another loaded draft');
      expect(history.canUndo, false);
      expect(history.canRedo, false);
      text.value = _value('another loaded draft!');
      history.undo();
      expect(text.text, 'another loaded draft');
    },
  );

  test('completed media insertion is atomic between surrounding typing', () {
    text.value = _value('seed typed');
    history.apply(
      _value('seed typed![image](https://example.invalid/image.png)'),
    );
    text.value = _value('${text.text} after');
    history.undo();
    expect(text.text, 'seed typed![image](https://example.invalid/image.png)');
    history.undo();
    expect(text.text, 'seed typed');
    history.undo();
    expect(text.text, 'seed');
  });

  test(
    'entry limit discards the oldest commands and keeps recent undo/redo',
    () {
      history.dispose();
      history = DocumentHistory(controller: text, maxEntries: 2);
      history.apply(_value('one'));
      history.apply(_value('two'));
      history.apply(_value('three'));
      history.undo();
      expect(text.text, 'two');
      history.undo();
      expect(text.text, 'one');
      expect(history.undo(), false);
      history.redo();
      history.redo();
      expect(text.text, 'three');
    },
  );

  test(
    'character budget includes pending typing and rejects oversized history',
    () {
      history.dispose();
      history = DocumentHistory(controller: text, maxRetainedCharacters: 16);
      history.apply(_value('aaaa'));
      history.apply(_value('bbbb'));
      text.value = _value('ccccc');
      history.undo();
      expect(text.text, 'bbbb');
      expect(
        history.undo(),
        false,
        reason: 'The pending transaction also consumes the budget.',
      );
      history.apply(_value('a document beyond the configured budget'));
      expect(history.canUndo, false);
      expect(history.canRedo, false);
      text.value = _value('tiny');
      expect(
        history.canUndo,
        false,
        reason: 'A huge old document is not retained on shrink.',
      );
      text.value = _value('tiny!');
      expect(history.undo(), true);
      expect(text.text, 'tiny');
    },
  );

  test('composing results cannot be introduced through apply', () {
    final next = _value('seedn')
        .copyWith(composing: const TextRange(start: 4, end: 5));
    expect(history.apply(next), false);
    expect(history.execute((_) => next), false);
    expect(text.text, 'seed');
    expect(history.canUndo, false);
  });

  test('a reentrant transformer cannot overwrite newer text', () {
    final applied = history.execute((_) {
      text.value = _value('newer edit');
      return _value('stale transformation');
    });
    expect(applied, false);
    expect(text.text, 'newer edit');
    expect(history.undo(), true);
    expect(text.text, 'seed');
  });

  test('dispose rejects late commands, cancels typing and leaves controller usable', () {
    text.value = _value('pending');
    history.dispose();
    expect(history.isDisposed, true);
    expect(history.canUndo, false);
    expect(history.canRedo, false);
    expect(history.undo(), false);
    expect(history.redo(), false);
    var invoked = false;
    expect(history.runAtomic(() => invoked = true), false);
    expect(
      history.execute((_) {
        invoked = true;
        return _value('late');
      }),
      false,
    );
    expect(history.apply(_value('late')), false);
    history.reset(_value('late'));
    history.commitTyping();
    expect(invoked, false);
    expect(text.text, 'pending');
    text.value = _value('another owner can still edit');
    expect(text.text, 'another owner can still edit');
  });
}
