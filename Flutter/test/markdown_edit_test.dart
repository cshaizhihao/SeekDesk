import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/markdown_edit.dart';

TextEditingValue _value(
  String text, {
  int start = 0,
  int? end,
  bool reversed = false,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: text,
  selection: TextSelection(
    baseOffset: reversed ? (end ?? text.length) : start,
    extentOffset: reversed ? start : (end ?? text.length),
    affinity: TextAffinity.upstream,
    isDirectional: true,
  ),
  composing: composing,
);

String _selected(TextEditingValue value) =>
    value.selection.textInside(value.text);

void main() {
  final emptyDocumentCases =
      <MarkdownCommand, ({String text, String selection})>{
        MarkdownCommand.bold: (text: '**加粗文字**', selection: '加粗文字'),
        MarkdownCommand.italic: (text: '*斜体文字*', selection: '斜体文字'),
        MarkdownCommand.strike: (text: '~~划线文字~~', selection: '划线文字'),
        MarkdownCommand.heading: (text: '## 标题', selection: '标题'),
        MarkdownCommand.quote: (text: '> 引用文字', selection: '引用文字'),
        MarkdownCommand.bullets: (text: '- 列表项', selection: '列表项'),
        MarkdownCommand.numbers: (text: '1. 列表项', selection: '列表项'),
        MarkdownCommand.code: (text: '`代码`', selection: '代码'),
        MarkdownCommand.link: (text: '[链接文字](https://)', selection: 'https://'),
        MarkdownCommand.image: (
          text: '![图片说明](https://)',
          selection: 'https://',
        ),
        MarkdownCommand.codeBlock: (text: '```\n代码\n```', selection: '代码'),
        MarkdownCommand.table: (
          text: '\n\n| 标题 1 | 标题 2 |\n| --- | --- |\n| 内容 1 | 内容 2 |\n\n',
          selection: '标题 1',
        ),
        MarkdownCommand.divider: (text: '\n\n---\n\n', selection: ''),
      };

  for (final entry in emptyDocumentCases.entries) {
    test('${entry.key.name} inserts and selects its editing target', () {
      final result = applyMarkdownCommand(_value(''), entry.key)!;
      expect(result.text, entry.value.text);
      expect(_selected(result), entry.value.selection);
      expect(result.composing, TextRange.empty);
      expect(result.selection.affinity, TextAffinity.upstream);
      expect(result.selection.isDirectional, isTrue);
    });
  }

  test(
    'every command rejects an active IME composition without changing input',
    () {
      final value = _value(
        '正在输入',
        composing: const TextRange(start: 0, end: 4),
      );
      for (final command in MarkdownCommand.values) {
        expect(
          applyMarkdownCommand(value, command),
          isNull,
          reason: command.name,
        );
      }
      expect(value.text, '正在输入');
      expect(value.composing, const TextRange(start: 0, end: 4));
    },
  );

  test('a collapsed composing range does not prevent formatting', () {
    final result = applyMarkdownCommand(
      _value('文字', composing: const TextRange.collapsed(1)),
      MarkdownCommand.bold,
    )!;
    expect(result.text, '**文字**');
    expect(result.composing, TextRange.empty);
  });

  test(
    'invalid and out-of-document selections are rejected for all commands',
    () {
      const selections = [
        TextSelection.collapsed(offset: -1),
        TextSelection(baseOffset: -1, extentOffset: 1),
        TextSelection.collapsed(offset: 4),
        TextSelection(baseOffset: 0, extentOffset: 4),
        TextSelection(baseOffset: 4, extentOffset: 0),
      ];
      for (final selection in selections) {
        final value = TextEditingValue(text: 'abc', selection: selection);
        for (final command in MarkdownCommand.values) {
          expect(
            applyMarkdownCommand(value, command),
            isNull,
            reason: command.name,
          );
        }
      }
    },
  );

  test('no command splits an emoji surrogate pair', () {
    for (final value in [
      _value('前😀后', start: 2, end: 2),
      _value('前😀后', start: 1, end: 2),
      _value('前😀后', start: 2, end: 3),
      _value('前😀后', start: 1, end: 2, reversed: true),
    ]) {
      for (final command in MarkdownCommand.values) {
        expect(
          applyMarkdownCommand(value, command),
          isNull,
          reason: command.name,
        );
      }
    }
  });

  for (final reversed in [false, true]) {
    test(
      'UTF-16 content and selection direction survive formatting ($reversed)',
      () {
        final original = _value('前😀中文后', start: 1, end: 5, reversed: reversed);
        final result = applyMarkdownCommand(original, MarkdownCommand.bold)!;
        expect(result.text, '前**😀中文**后');
        expect(_selected(result), '😀中文');
        expect(result.selection.start, 3);
        expect(result.selection.end, 7);
        expect(
          result.selection.baseOffset > result.selection.extentOffset,
          reversed,
        );
        final restored = applyMarkdownCommand(result, MarkdownCommand.bold)!;
        expect(restored.text, original.text);
        expect(restored.selection, original.selection);
      },
    );
  }

  for (final entry in {
    MarkdownCommand.bold: '**',
    MarkdownCommand.italic: '*',
    MarkdownCommand.strike: '~~',
  }.entries) {
    test('${entry.key.name} toggles selected and adjacent wrappers', () {
      final source = '前${entry.value}内容${entry.value}后';
      final selectedWrapper = applyMarkdownCommand(
        _value(source, start: 1, end: source.length - 1, reversed: true),
        entry.key,
      )!;
      final selectedContents = applyMarkdownCommand(
        _value(
          source,
          start: 1 + entry.value.length,
          end: 3 + entry.value.length,
        ),
        entry.key,
      )!;
      expect(selectedWrapper.text, '前内容后');
      expect(selectedContents.text, '前内容后');
      expect(_selected(selectedWrapper), '内容');
      expect(_selected(selectedContents), '内容');
      expect(selectedWrapper.selection.baseOffset, 3);
      expect(selectedWrapper.selection.extentOffset, 1);
    });
  }

  test('italic preserves bold pairs while toggling triple asterisks', () {
    final italic = applyMarkdownCommand(
      _value('**文字**'),
      MarkdownCommand.italic,
    )!;
    expect(italic.text, '***文字***');
    expect(_selected(italic), '**文字**');
    expect(
      applyMarkdownCommand(italic, MarkdownCommand.italic)!.text,
      '**文字**',
    );
    expect(
      applyMarkdownCommand(_value('***文字***'), MarkdownCommand.italic)!.text,
      '**文字**',
    );
    final contents = applyMarkdownCommand(
      _value('***文字***', start: 3, end: 5),
      MarkdownCommand.italic,
    )!;
    expect(contents.text, '**文字**');
    expect(_selected(contents), '文字');
  });

  test(
    'heading normalizes levels, retains indentation and excludes the next line',
    () {
      const source = '  # One\n\t### Two\nUntouched';
      final normalized = applyMarkdownCommand(
        _value(
          source,
          start: 3,
          end: source.indexOf('Untouched'),
          reversed: true,
        ),
        MarkdownCommand.heading,
      )!;
      expect(normalized.text, '  ## One\n\t## Two\nUntouched');
      expect(_selected(normalized), '  ## One\n\t## Two');
      expect(
        normalized.selection.baseOffset > normalized.selection.extentOffset,
        isTrue,
      );
      final removed = applyMarkdownCommand(
        normalized,
        MarkdownCommand.heading,
      )!;
      expect(removed.text, '  One\n\tTwo\nUntouched');
      expect(_selected(removed), '  One\n\tTwo');
    },
  );

  test('quote removes one level without flattening nested quotations', () {
    final result = applyMarkdownCommand(
      _value('> > 甲\n  > 乙'),
      MarkdownCommand.quote,
    )!;
    expect(result.text, '> 甲\n  乙');
    expect(_selected(result), '> 甲\n  乙');
  });

  test(
    'mixed quoted and plain lines are quoted together, then toggle back',
    () {
      final result = applyMarkdownCommand(
        _value('> 甲\n乙'),
        MarkdownCommand.quote,
      )!;
      expect(result.text, '> 甲\n> 乙');
      expect(applyMarkdownCommand(result, MarkdownCommand.quote)!.text, '甲\n乙');
    },
  );

  test('bullets convert ordered lists without changing indentation', () {
    final result = applyMarkdownCommand(
      _value('  9) 甲\n\t* 乙\n丙'),
      MarkdownCommand.bullets,
    )!;
    expect(result.text, '  - 甲\n\t- 乙\n- 丙');
    expect(
      applyMarkdownCommand(result, MarkdownCommand.bullets)!.text,
      '  甲\n\t乙\n丙',
    );
  });

  test('all existing bullet variants toggle off', () {
    expect(
      applyMarkdownCommand(
        _value('- 甲\n+ 乙\n* 丙'),
        MarkdownCommand.bullets,
      )!.text,
      '甲\n乙\n丙',
    );
  });

  test(
    'numbered lists sequence selected lines and preserve the following line',
    () {
      const source = '\t甲\n  8) 乙\n尾';
      final result = applyMarkdownCommand(
        _value(source, end: source.indexOf('尾')),
        MarkdownCommand.numbers,
      )!;
      expect(result.text, '\t1. 甲\n  2. 乙\n尾');
      expect(_selected(result), '\t1. 甲\n  2. 乙');
      expect(
        applyMarkdownCommand(result, MarkdownCommand.numbers)!.text,
        '\t甲\n  乙\n尾',
      );
    },
  );

  test('both ordered-list marker styles toggle off', () {
    expect(
      applyMarkdownCommand(
        _value('9) 甲\n  10. 乙'),
        MarkdownCommand.numbers,
      )!.text,
      '甲\n  乙',
    );
  });

  test('whole-line commands preserve CRLF and mixed original line endings', () {
    const source = '甲\r\n乙\r丙\n尾';
    final result = applyMarkdownCommand(
      _value(source, end: source.indexOf('尾')),
      MarkdownCommand.quote,
    )!;
    expect(result.text, '> 甲\r\n> 乙\r> 丙\n尾');
    expect(_selected(result), '> 甲\r\n> 乙\r> 丙');
    expect(applyMarkdownCommand(result, MarkdownCommand.quote)!.text, source);
  });

  test(
    'selection ending immediately after CR does not modify the next CRLF line',
    () {
      final result = applyMarkdownCommand(
        _value('甲\r\n乙', end: 2),
        MarkdownCommand.bullets,
      )!;
      expect(result.text, '- 甲\r\n乙');
      expect(_selected(result), '- 甲');
    },
  );

  test('a caret formats its entire current line', () {
    final result = applyMarkdownCommand(
      _value('前\n  内容\n后', start: 5, end: 5),
      MarkdownCommand.heading,
    )!;
    expect(result.text, '前\n  ## 内容\n后');
    expect(_selected(result), '  ## 内容');
  });

  test('a final newline provides a new empty line for its placeholder', () {
    final result = applyMarkdownCommand(
      _value('已有正文\n', start: 5, end: 5),
      MarkdownCommand.heading,
    )!;
    expect(result.text, '已有正文\n## 标题');
    expect(_selected(result), '标题');
  });

  test('empty middle lines retain their surrounding paragraph breaks', () {
    final result = applyMarkdownCommand(
      _value('前\n\n后', start: 2, end: 2),
      MarkdownCommand.quote,
    )!;
    expect(result.text, '前\n> 引用文字\n后');
    expect(_selected(result), '引用文字');
  });

  for (final command in [MarkdownCommand.link, MarkdownCommand.image]) {
    test('${command.name} escapes labels and selects only the URL', () {
      final source =
          r'\[站点]'
          '\r\n下一行\u2028尾';
      final result = applyMarkdownCommand(
        _value(source, reversed: true),
        command,
      )!;
      final prefix = command == MarkdownCommand.image ? '!' : '';
      expect(result.text, prefix + r'[\\\[站点\] 下一行 尾](https://)');
      expect(_selected(result), 'https://');
      expect(
        result.selection.baseOffset > result.selection.extentOffset,
        isTrue,
      );
    });
  }

  test(
    'inline code chooses a fence wider than every embedded backtick run',
    () {
      final result = applyMarkdownCommand(
        _value('a``b`c'),
        MarkdownCommand.code,
      )!;
      expect(result.text, '```a``b`c```');
      expect(_selected(result), 'a``b`c');
      expect(
        applyMarkdownCommand(result, MarkdownCommand.code)!.text,
        'a``b`c',
      );
    },
  );

  test(
    'inline code pads boundary backticks and removes that padding on toggle',
    () {
      final result = applyMarkdownCommand(
        _value('`edge'),
        MarkdownCommand.code,
      )!;
      expect(result.text, '`` `edge ``');
      expect(_selected(result), '`edge');
      expect(applyMarkdownCommand(result, MarkdownCommand.code)!.text, '`edge');
    },
  );

  test(
    'inline code preserves meaningful outer spaces and all-space content',
    () {
      final spaced = applyMarkdownCommand(_value(' x '), MarkdownCommand.code)!;
      expect(spaced.text, '`  x  `');
      expect(_selected(spaced), ' x ');
      expect(applyMarkdownCommand(spaced, MarkdownCommand.code)!.text, ' x ');
      final spaces = applyMarkdownCommand(_value('   '), MarkdownCommand.code)!;
      expect(spaces.text, '`   `');
      expect(applyMarkdownCommand(spaces, MarkdownCommand.code)!.text, '   ');
    },
  );

  test('inline code can unwrap a selected complete span', () {
    final result = applyMarkdownCommand(
      _value('``a`b``', reversed: true),
      MarkdownCommand.code,
    )!;
    expect(result.text, 'a`b');
    expect(_selected(result), 'a`b');
    expect(result.selection.baseOffset, 3);
    expect(result.selection.extentOffset, 0);
  });

  for (final command in [MarkdownCommand.code, MarkdownCommand.codeBlock]) {
    test(
      '${command.name} safely fences multiline content containing a fence',
      () {
        const source = 'a\n```\nb';
        final result = applyMarkdownCommand(
          _value(source, reversed: true),
          command,
        )!;
        expect(result.text, '````\na\n```\nb\n````');
        expect(_selected(result), source);
        final restored = applyMarkdownCommand(result, command)!;
        expect(restored.text, source);
        expect(restored.selection.baseOffset, source.length);
        expect(restored.selection.extentOffset, 0);
      },
    );
  }

  test(
    'fenced block toggle retains the paragraph breaks outside its fence',
    () {
      final result = applyMarkdownCommand(
        _value('before target after', start: 7, end: 13),
        MarkdownCommand.codeBlock,
      )!;
      expect(result.text, 'before \n```\ntarget\n```\n after');
      expect(_selected(result), 'target');
      final restored = applyMarkdownCommand(result, MarkdownCommand.codeBlock)!;
      expect(restored.text, 'before \ntarget\n after');
      expect(_selected(restored), 'target');
    },
  );

  test('all newline forms produce a code block rather than an inline span', () {
    for (final ending in [
      '\n',
      '\r',
      '\r\n',
      '\u000b',
      '\u000c',
      '\u0085',
      '\u2028',
      '\u2029',
    ]) {
      final source = 'a${ending}b';
      final result = applyMarkdownCommand(
        _value(source),
        MarkdownCommand.code,
      )!;
      expect(result.text, '```\n$source\n```');
      expect(_selected(result), source);
      expect(applyMarkdownCommand(result, MarkdownCommand.code)!.text, source);
    }
  });

  test(
    'fenced blocks using CRLF can be unwrapped without dropping content',
    () {
      final result = applyMarkdownCommand(
        _value('```\r\n代码\r\n```', start: 5, end: 7),
        MarkdownCommand.codeBlock,
      )!;
      expect(result.text, '代码');
      expect(_selected(result), '代码');
    },
  );

  test('table retains selected content as the first editable heading', () {
    final result = applyMarkdownCommand(
      _value('前标题后', start: 1, end: 3, reversed: true),
      MarkdownCommand.table,
    )!;
    expect(
      result.text,
      '前\n\n| 标题 | 标题 2 |\n| --- | --- |\n| 内容 1 | 内容 2 |\n\n后',
    );
    expect(_selected(result), '标题');
    expect(result.selection.baseOffset > result.selection.extentOffset, isTrue);
  });

  test('divider preserves selected text and content after the insertion', () {
    final result = applyMarkdownCommand(
      _value('前正文后', start: 1, end: 3),
      MarkdownCommand.divider,
    )!;
    expect(result.text, '前正文\n\n---\n\n后');
    expect(_selected(result), '正文');
    expect(result.selection.start, 1);
    expect(result.selection.end, 3);
  });
}
