import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/code_highlight.dart';

void main() {
  test(
    'lexical coloring preserves literal source across supported languages',
    () {
      const source = 'const 名称 = "<&>😃\\""; // comment\nreturn 42;\n';
      for (final language in [
        'dart',
        'js',
        'ts',
        'swift',
        'go',
        'java',
        'c',
        'cpp',
        'rust',
        'python',
        'sh',
        'json',
        'yaml',
      ]) {
        final tokens = CodeHighlight.tokenize(source, language: language);
        expect(
          tokens.map((token) => token.text).join(),
          source,
          reason: language,
        );
        expect(
          tokens.any((token) => token.kind == CodeTokenKind.keyword),
          isTrue,
        );
      }
    },
  );

  test('comments and escaped strings do not become keywords or links', () {
    const source = '"https://test.invalid/\\"return" // return 42\nreturn 7';
    final tokens = CodeHighlight.tokenize(source, language: 'language-js');
    expect(
      tokens.where((token) => token.kind == CodeTokenKind.string).single.text,
      '"https://test.invalid/\\"return"',
    );
    expect(
      tokens.where((token) => token.kind == CodeTokenKind.comment).single.text,
      '// return 42',
    );
    expect(
      tokens.where((token) => token.kind == CodeTokenKind.keyword).single.text,
      'return',
    );
    expect(
      tokens.where((token) => token.kind == CodeTokenKind.number).single.text,
      '7',
    );
  });

  test('unknown, oversized and token-heavy inputs safely stay plain', () {
    for (final (source, language) in [
      ('<script>alert(1)</script>', 'html'),
      ('return 5', ''),
      ('a' * (CodeHighlight.maxLength + 1), 'javascript'),
      ('true ' * 3000, 'json'),
    ]) {
      final tokens = CodeHighlight.tokenize(source, language: language);
      expect(tokens, [(text: source, kind: CodeTokenKind.plain)]);
    }
  });

  test('unterminated quotes and comments finish without losing characters', () {
    for (final source in [
      '"\\',
      "'''unfinished\n多行",
      '/* unfinished\n',
      '# 注释\nfalse',
    ]) {
      for (final language in ['python', 'dart', 'json', 'yaml']) {
        expect(
          CodeHighlight.tokenize(
            source,
            language: language,
          ).map((token) => token.text).join(),
          source,
        );
      }
    }
  });
}
