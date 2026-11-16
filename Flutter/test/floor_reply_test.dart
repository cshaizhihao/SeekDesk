import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/floor_reply.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';

const _page = 'https://www.nodeseek.com/post-17-2';

void main() {
  test('reply keeps the page and replaces its fragment with the floor', () {
    final floor = FloorData({'id': '35', 'author': 'Alice'});
    expect(
      floorReplyInsertion(
        floor,
        '$_page?view=all#old',
        quoting: false,
        after: '',
      ),
      '@Alice [#35]($_page?view=all#35)\n\n',
    );
    expect(
      floorReplyInsertion(
        FloorData({'id': '0'}),
        _page,
        quoting: false,
        after: '',
      ),
      '[#0]($_page#0)\n\n',
    );
  });

  test('suffix creates exactly the required separating blank line', () {
    final floor = FloorData({'id': '1', 'author': 'A'});
    for (final entry in {
      '': '',
      'draft': '\n\n',
      'draft\n': '\n',
      'draft\n\n': '',
      'draft\n\n\n': '',
    }.entries) {
      expect(
        floorReplyInsertion(floor, _page, quoting: false, after: entry.key),
        '${entry.value}@A [#1]($_page#1)\n\n',
      );
    }
  });

  test('quote supports native text, placeholders and the first tab only', () {
    final floor = FloorData({
      'id': '8',
      'author': 'A',
      'blocks': [
        {'kind': 'heading', 'text': 'Heading'},
        {'kind': 'text', 'text': 'line 1\r\n\r\nline 2'},
        {'kind': 'image', 'url': 'https://example.invalid/private.png'},
        {'kind': 'terminal'},
        {'kind': 'terminalUnavailable'},
        {
          'kind': 'tabs',
          'tabs': [
            {
              'blocks': [
                {'kind': 'code', 'text': 'first tab'},
              ],
            },
            {
              'blocks': [
                {'kind': 'text', 'text': 'hidden tab'},
              ],
            },
          ],
        },
        {'kind': 'unknown', 'text': 'unsupported'},
      ],
    });
    expect(
      floorReplyInsertion(floor, _page, quoting: true, after: ''),
      '> @A [#8]($_page#8)\n>\n> Heading\n> line 1\n> \n> line 2\n'
      '> [图片]\n> [测评终端]\n> [测评终端]\n> first tab\n\n',
    );
  });

  test('quote limits each excerpt to the first twenty blocks', () {
    final floor = FloorData({
      'id': '1',
      'blocks': [
        for (var i = 0; i < 21; i++) {'kind': 'text', 'text': 'block $i'},
      ],
    });
    final result = floorReplyInsertion(floor, _page, quoting: true, after: '')!;
    expect(result, contains('> block 19\n\n'));
    expect(result, isNot(contains('block 20')));
  });

  test(
    'quote truncates at 1600 graphemes without splitting combined emoji',
    () {
      const glyph = '👩🏽‍💻';
      for (final length in [1599, 1600, 1601]) {
        final floor = FloorData({
          'id': '1',
          'blocks': [
            {'kind': 'text', 'text': List.filled(length, glyph).join()},
          ],
        });
        final result = floorReplyInsertion(
          floor,
          _page,
          quoting: true,
          after: '',
        )!;
        final excerpt = result
            .split('\n>\n> ')
            .last
            .substring(0, result.split('\n>\n> ').last.length - 2);
        expect(
          excerpt.characters.where((c) => c == glyph).length,
          length > 1600 ? 1600 : length,
        );
        expect(excerpt.endsWith('…'), length > 1600);
      }
    },
  );

  test(
    'empty excerpts preserve the quoted mention and editable blank line',
    () {
      final floor = FloorData({
        'id': '3',
        'author': 'A',
        'blocks': [
          {'kind': 'text', 'text': '  \n '},
          {'kind': 'tabs', 'tabs': []},
        ],
      });
      expect(
        floorReplyInsertion(floor, _page, quoting: true, after: 'before'),
        '\n\n> @A [#3]($_page#3)\n\n',
      );
    },
  );

  test('author and legal URL parentheses cannot break markdown boundaries', () {
    final floor = FloorData({'id': '3', 'author': ' A\r\n[B](x) <tag> '});
    expect(
      floorReplyInsertion(floor, '$_page?q=(x)', quoting: false, after: ''),
      '@A \\[B\\]\\(x\\) \\<tag\\> [#3]($_page?q=%28x%29#3)\n\n',
    );
  });

  test('untrusted URLs and invalid floors never generate an insertion', () {
    final floor = FloorData({'id': '1'});
    for (final page in [
      'http://www.nodeseek.com/post-17-1',
      'https://example.invalid/post-17-1',
      'https://nodeseek.com.evil.invalid/post-17-1',
      'https://user@www.nodeseek.com/post-17-1',
      'https://@www.nodeseek.com/post-17-1',
      'https://www.nodeseek.com:444/post-17-1',
      'https://www.nodeseek.com/post-0-1',
      'https://www.nodeseek.com/path/post-17-1',
      'https://www.nodeseek.com//post-17-1',
      'https://www.nodeseek.com/post-17-1%2Fextra',
      'https://www.nodeseek.com/post-17-1\n',
      'javascript:alert(1)',
      'not a URL',
    ]) {
      expect(
        floorReplyInsertion(floor, page, quoting: true, after: ''),
        isNull,
        reason: page,
      );
    }
    for (final id in ['-1', '1.5', 'abc', '']) {
      expect(
        floorReplyInsertion(
          FloorData({'id': id}),
          _page,
          quoting: false,
          after: '',
        ),
        isNull,
      );
    }
  });
}
