/// Bounded lexical highlighting. It never executes code, changes the source or
/// guesses a language for unlabelled forum content. Long input stays plain.
enum CodeTokenKind { plain, comment, string, number, keyword }

typedef CodeToken = ({String text, CodeTokenKind kind});

abstract final class CodeHighlight {
  static const maxLength = 24000;
  static const maxTokens = 1800;

  static String language(String value) {
    final name = value.trim().toLowerCase().replaceFirst('language-', '');
    return switch (name) {
      'js' || 'jsx' => 'javascript',
      'ts' || 'tsx' => 'typescript',
      'py' => 'python',
      'sh' || 'bash' || 'zsh' => 'shell',
      'yml' => 'yaml',
      'c++' => 'cpp',
      'rs' => 'rust',
      _ => name,
    };
  }

  static const _supported = {
    'javascript',
    'typescript',
    'dart',
    'swift',
    'go',
    'java',
    'c',
    'cpp',
    'rust',
    'python',
    'shell',
    'json',
    'yaml',
  };
  static const _keywords = {
    'abstract',
    'as',
    'async',
    'await',
    'bool',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'def',
    'default',
    'defer',
    'do',
    'done',
    'double',
    'elif',
    'else',
    'enum',
    'except',
    'export',
    'extends',
    'false',
    'False',
    'fi',
    'final',
    'finally',
    'float',
    'for',
    'from',
    'func',
    'function',
    'if',
    'implements',
    'import',
    'in',
    'int',
    'interface',
    'is',
    'let',
    'match',
    'new',
    'nil',
    'None',
    'null',
    'override',
    'package',
    'private',
    'protected',
    'public',
    'raise',
    'return',
    'static',
    'struct',
    'super',
    'switch',
    'then',
    'this',
    'throw',
    'throws',
    'true',
    'True',
    'try',
    'type',
    'typeof',
    'undefined',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',
  };

  static List<CodeToken> tokenize(String source, {String language = ''}) {
    final name = CodeHighlight.language(language);
    List<CodeToken> plain() => [(text: source, kind: CodeTokenKind.plain)];
    if (source.length > maxLength || !_supported.contains(name)) return plain();
    final hashComments = const {'python', 'shell', 'yaml'}.contains(name);
    final slashComments = !hashComments && name != 'json';
    final result = <CodeToken>[];
    var cursor = 0, plainStart = 0;
    void add(int start, int end, CodeTokenKind kind) {
      if (start > plainStart) {
        result.add((
          text: source.substring(plainStart, start),
          kind: CodeTokenKind.plain,
        ));
      }
      result.add((text: source.substring(start, end), kind: kind));
      plainStart = end;
    }

    while (cursor < source.length) {
      if (result.length >= maxTokens - 2) return plain();
      final start = cursor, unit = source.codeUnitAt(cursor);
      if (hashComments && unit == 35 ||
          slashComments && source.startsWith('//', cursor)) {
        final newline = source.indexOf('\n', cursor);
        cursor = newline < 0 ? source.length : newline;
        add(start, cursor, CodeTokenKind.comment);
      } else if (slashComments && source.startsWith('/*', cursor)) {
        final end = source.indexOf('*/', cursor + 2);
        cursor = end < 0 ? source.length : end + 2;
        add(start, cursor, CodeTokenKind.comment);
      } else if (unit == 34 ||
          unit == 39 ||
          unit == 96 && (name == 'javascript' || name == 'typescript')) {
        final triple =
            name == 'python' &&
            source.startsWith(String.fromCharCode(unit) * 3, cursor);
        final delimiter = String.fromCharCode(unit) * (triple ? 3 : 1);
        cursor += delimiter.length;
        while (cursor < source.length) {
          if (source.codeUnitAt(cursor) == 92) {
            cursor = (cursor + 2).clamp(0, source.length);
          } else if (source.startsWith(delimiter, cursor)) {
            cursor += delimiter.length;
            break;
          } else {
            cursor++;
          }
        }
        add(start, cursor, CodeTokenKind.string);
      } else if (_digit(unit) &&
          (cursor == 0 || !_word(source.codeUnitAt(cursor - 1)))) {
        cursor++;
        while (cursor < source.length &&
            (_digit(source.codeUnitAt(cursor)) ||
                source.codeUnitAt(cursor) == 46)) {
          cursor++;
        }
        add(start, cursor, CodeTokenKind.number);
      } else if (_word(unit)) {
        cursor++;
        while (cursor < source.length &&
            (_word(source.codeUnitAt(cursor)) ||
                _digit(source.codeUnitAt(cursor)))) {
          cursor++;
        }
        if (_keywords.contains(source.substring(start, cursor))) {
          add(start, cursor, CodeTokenKind.keyword);
        }
      } else {
        cursor++;
      }
    }
    if (plainStart < source.length) {
      result.add((
        text: source.substring(plainStart),
        kind: CodeTokenKind.plain,
      ));
    }
    return result;
  }

  static bool _digit(int unit) => unit >= 48 && unit <= 57;
  static bool _word(int unit) =>
      unit >= 65 && unit <= 90 ||
      unit >= 97 && unit <= 122 ||
      unit == 95 ||
      unit == 36;
}
