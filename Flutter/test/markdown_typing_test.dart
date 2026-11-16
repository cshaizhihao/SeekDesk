import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';

TextEditingValue _value(
  String text, {
  int? start,
  int? end,
  bool reversed = false,
  TextRange composing = TextRange.empty,
}) {
  final first = start ?? text.length;
  final last = end ?? first;
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: reversed ? last : first,
      extentOffset: reversed ? first : last,
      affinity: TextAffinity.upstream,
      isDirectional: true,
    ),
    composing: composing,
  );
}

TextEditingValue _apply(
  TextEditingValue value,
  MarkdownTypingCommand command,
) => applyMarkdownTypingCommand(value, command)!;

const _endings = [
  '\n',
  '\r\n',
  '\r',
  '\u000b',
  '\u000c',
  '\u0085',
  '\u2028',
  '\u2029',
];

void main() {
  test('list continuation preserves marker style and indentation, increments numbers and resets tasks', () {
    const cases = <String, String>{
      '- 中文🎉': '- 中文🎉\n- ',
      '  + 内容': '  + 内容\n  + ',
      '\t* 内容': '\t* 内容\n\t* ',
      '9. 九': '9. 九\n10. ',
      '9) 九': '9) 九\n10) ',
      '0009) 九': '0009) 九\n10) ',
      '999999999. 上限': '999999999. 上限\n999999999. ',
      '- [x] 已做': '- [x] 已做\n- [ ] ',
      '  + [X]\t已做': '  + [X]\t已做\n  + [ ] ',
      '2) [ ] 待做': '2) [ ] 待做\n3) [ ] ',
      '- [x]没有空格': '- [x]没有空格\n- ',
    };
    for (final entry in cases.entries) {
      final result = _apply(_value(entry.key), MarkdownTypingCommand.newline);
      expect(result.text, entry.value, reason: entry.key);
      expect(result.selection.isCollapsed, isTrue);
      expect(result.selection.extentOffset, entry.value.length);
      expect(result.selection.affinity, TextAffinity.upstream);
      expect(result.selection.isDirectional, isTrue);
      expect(result.composing, TextRange.empty);
    }
  });

  test('empty items exit without creating another line or deleting neighboring separators', () {
    for (final item in [
      '- ',
      '  2.   ',
      '\t*\t',
      '- [x] ',
      '- [X]\t',
      '+ [ ]   ',
    ]) {
      final empty = _apply(_value(item), MarkdownTypingCommand.newline);
      expect(empty.text, '', reason: item);
      expect(empty.selection.extentOffset, 0);
      for (final ending in _endings) {
        final source = 'before$ending$item${ending}after';
        final first = 'before$ending'.length;
        final result = _apply(
          _value(source, start: first + item.length),
          MarkdownTypingCommand.newline,
        );
        expect(result.text, 'before$ending${ending}after');
        expect(result.selection.extentOffset, first);
      }
    }
  });

  test('continuation splits at the caret while selected text and prefix positions use ordinary newline', () {
    const source = '- ab🎉cd';
    final result = _apply(
      _value(source, start: 4),
      MarkdownTypingCommand.newline,
    );
    expect(result.text, '- ab\n- 🎉cd');
    expect(result.selection.extentOffset, 7);
    expect(
      _apply(_value(source, start: 2), MarkdownTypingCommand.newline).text,
      '- \n- ab🎉cd',
    );
    for (final value in [
      _value(source, start: 0),
      _value(source, start: 1),
      _value(source, start: 2, end: 4),
      _value(source, start: 2, end: 4, reversed: true),
      _value('- one\n- two', start: 2, end: 9),
      _value('普通文字'),
      _value('> - 引用中的列表'),
      _value('-没有空格'),
      _value('1234567890. 十位序号'),
    ]) {
      expect(
        applyMarkdownTypingCommand(value, MarkdownTypingCommand.newline),
        isNull,
        reason: value.toString(),
      );
    }
  });

  test('newline uses the current separator or the final line predecessor for every existing line-ending form', () {
    for (final ending in _endings) {
      final source = '- one$ending- two';
      final finalLine = _apply(_value(source), MarkdownTypingCommand.newline);
      expect(finalLine.text, '$source$ending- ');
      final firstLine = _apply(
        _value(source, start: 5),
        MarkdownTypingCommand.newline,
      );
      expect(firstLine.text, '- one$ending- $ending- two');
      expect(firstLine.selection.extentOffset, 7 + ending.length);
    }
    const mixed = 'first\n- second\r\nlast';
    final current = _apply(
      _value(mixed, start: mixed.indexOf('\r')),
      MarkdownTypingCommand.newline,
    );
    expect(current.text, 'first\n- second\r\n- \r\nlast');
  });

  test('backtick and tilde fences suppress lists until a matching complete closing fence', () {
    final cases = <String, bool>{
      '```text\n': true,
      '~~~\r\n': true,
      '   ````dart\n```\n': true,
      '```\n~~~\n': true,
      '~~~\n~~~ trailing\n': true,
      '```\ncode\n```\n': false,
      '  ~~~lang\u2028code\u2028  ~~~~  \u2028': false,
      '````\n```\n`````\n': false,
      '```\ncode\n```\n~~~\n': true,
      '``not-a-fence\n': false,
      '```bad`info\n': false,
      '    ```\n': false,
    };
    for (final entry in cases.entries) {
      final result = applyMarkdownTypingCommand(
        _value('${entry.key}- 内容'),
        MarkdownTypingCommand.newline,
      );
      expect(result == null, entry.value, reason: entry.key);
    }
    final inside = _apply(
      _value('```\ncode', start: 6),
      MarkdownTypingCommand.indent,
    );
    expect(
      inside.text,
      '```\nco    de',
      reason:
          'Fences suppress list continuation, not explicit code indentation.',
    );
  });

  test('Tab uses whole-line indentation for lists or leading whitespace and inserts spaces inside ordinary text', () {
    final cases = <({String text, int caret}), ({String text, int caret})>{
      (text: '正文', caret: 1): (text: '正    文', caret: 5),
      (text: '正文', caret: 2): (text: '正文    ', caret: 6),
      (text: '- 列表', caret: 4): (text: '    - 列表', caret: 8),
      (text: '9) 列表', caret: 1): (text: '    9) 列表', caret: 5),
      (text: '  正文', caret: 1): (text: '      正文', caret: 5),
      (text: '', caret: 0): (text: '    ', caret: 4),
      (text: 'a\r\n', caret: 3): (text: 'a\r\n    ', caret: 7),
    };
    for (final entry in cases.entries) {
      final result = _apply(
        _value(entry.key.text, start: entry.key.caret),
        MarkdownTypingCommand.indent,
      );
      expect(result.text, entry.value.text, reason: entry.key.toString());
      expect(result.selection.extentOffset, entry.value.caret);
    }
    final selected = _apply(
      _value('正文', start: 1, end: 2),
      MarkdownTypingCommand.indent,
    );
    expect(selected.text, '    正文');
    expect(selected.selection.textInside(selected.text), '文');
  });

  test('multiline Tab and Shift-Tab preserve reversed UTF-16 selections and exclude the next unselected line', () {
    for (final ending in _endings) {
      final source = '甲🎉$ending乙$ending丙';
      for (final end in [source.indexOf('乙') + 1, source.indexOf('丙')]) {
        for (final reversed in [false, true]) {
          final original = _value(
            source,
            start: 1,
            end: end,
            reversed: reversed,
          );
          final indented = _apply(original, MarkdownTypingCommand.indent);
          expect(indented.text, '    甲🎉$ending    乙$ending丙');
          expect(indented.selection.start, original.selection.start + 4);
          expect(indented.selection.end, original.selection.end + 8);
          expect(
            indented.selection.baseOffset > indented.selection.extentOffset,
            reversed,
          );
          expect(indented.selection.affinity, original.selection.affinity);
          expect(
            indented.selection.isDirectional,
            original.selection.isDirectional,
          );
          expect(_apply(indented, MarkdownTypingCommand.outdent), original);
        }
      }
    }
    final trailing = _apply(
      _value('a\n', start: 0, end: 2),
      MarkdownTypingCommand.indent,
    );
    expect(
      trailing.text,
      '    a\n',
      reason: 'Selecting a final newline does not select a new empty line.',
    );
  });

  test('outdent removes one leading tab or up to four spaces and clamps endpoints inside removed indentation', () {
    const source = '  alpha\n\tbeta\nuntouched';
    final end = source.indexOf('untouched');
    final value = _value(source, start: 1, end: end, reversed: true);
    final result = _apply(value, MarkdownTypingCommand.outdent);
    expect(result.text, 'alpha\nbeta\nuntouched');
    expect(result.selection.baseOffset, end - 3);
    expect(result.selection.extentOffset, 0);
    expect(result.selection.isDirectional, isTrue);
    for (final entry in <String, String>{
      '\t   a': '   a',
      '      a': '  a',
      ' \ta': '\ta',
      '   ': '',
    }.entries) {
      final reduced = _apply(_value(entry.key), MarkdownTypingCommand.outdent);
      expect(reduced.text, entry.value);
      expect(reduced.selection.extentOffset, entry.value.length);
    }
    final whitespace = _apply(
      _value('    a', start: 1, end: 3, reversed: true),
      MarkdownTypingCommand.outdent,
    );
    expect(whitespace.text, 'a');
    expect(whitespace.selection.isCollapsed, isTrue);
    expect(whitespace.selection.extentOffset, 0);
  });

  test('no-op outdent returns the same value and commands reject composition, invalid selections and split emoji', () {
    for (final value in [
      _value(''),
      _value('正文', start: 1),
      _value('甲\n乙', start: 0, end: 3, reversed: true),
    ]) {
      expect(
        applyMarkdownTypingCommand(value, MarkdownTypingCommand.outdent),
        same(value),
      );
    }
    final rejected = [
      const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: -1),
      ),
      const TextEditingValue(
        text: 'abc',
        selection: TextSelection(baseOffset: -1, extentOffset: 1),
      ),
      _value('abc', start: 4),
      _value('abc', start: 0, end: 4),
      _value('abc', start: 0, end: 4, reversed: true),
      _value('前🎉后', start: 2),
      _value('前🎉后', start: 1, end: 2),
      _value('前🎉后', start: 2, end: 3),
      _value('- 正在输入', composing: const TextRange(start: 2, end: 6)),
    ];
    for (final command in MarkdownTypingCommand.values) {
      for (final value in rejected) {
        expect(
          applyMarkdownTypingCommand(value, command),
          isNull,
          reason: '${command.name}: $value',
        );
      }
    }
    final collapsed = _value('- 完成', composing: const TextRange.collapsed(3));
    expect(
      _apply(collapsed, MarkdownTypingCommand.newline).composing,
      TextRange.empty,
    );
  });

  test('a caret between CR and LF cannot split the separator but indentation still preserves its position', () {
    const source = '- item\r\nnext';
    final original = _value(source, start: source.indexOf('\n'));
    expect(
      applyMarkdownTypingCommand(original, MarkdownTypingCommand.newline),
      isNull,
    );
    final indented = _apply(original, MarkdownTypingCommand.indent);
    expect(indented.text, '    - item\r\nnext');
    expect(
      indented.selection.extentOffset,
      original.selection.extentOffset + 4,
    );
    expect(_apply(indented, MarkdownTypingCommand.outdent), original);
  });
}
