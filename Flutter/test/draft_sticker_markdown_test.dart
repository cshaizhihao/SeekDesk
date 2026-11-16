import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/official_stickers.dart';

JsonMap _item(String code, {String? label, String? url, String? insertion}) => {
  'id': code,
  'label': label ?? '表情 $code',
  'url': url ?? 'https://images.example.test/catalog/$code.png',
  'insertion': insertion ?? ' :$code: ',
};

OfficialStickerCatalog _catalog() => OfficialStickerCatalog.fromPacks([
  {
    'id': 'fixture',
    'title': '本地测试目录',
    'items': [
      _item('ac01'),
      _item('ac02'),
      _item('yct001', url: 'https://cdn.example.test/onion.gif'),
      _item('emoji00'),
    ],
  },
]);

List<md.Node> _parse(String text) =>
    parseDraftMarkdown(text, stickers: _catalog());

List<String> _codes(String text) =>
    draftStickerOccurrences(_parse(text)).map((item) => item.code).toList();

Iterable<md.Element> _elements(Iterable<md.Node> nodes, String tag) sync* {
  for (final node in nodes) {
    if (node is md.Element) {
      if (node.tag == tag) yield node;
      yield* _elements(node.children ?? const [], tag);
    }
  }
}

void main() {
  test('catalog preserves native metadata and is an immutable snapshot', () {
    final item = _item(
      'ac01',
      label: 'AC 娘 01',
      url: 'https://cdn.example.test/custom/path/image.gif?size=small',
    );
    final catalog = OfficialStickerCatalog.fromPacks([
      {
        'items': [item],
      },
    ]);
    final sticker = catalog.byCode['ac01']!;
    expect(sticker.code, 'ac01');
    expect(sticker.label, 'AC 娘 01');
    expect(
      sticker.url,
      'https://cdn.example.test/custom/path/image.gif?size=small',
    );
    expect(sticker.insertion, ' :ac01: ');
    item['url'] = 'https://changed.example.test/image.png';
    expect(catalog.byCode['ac01'], same(sticker));
    expect(() => catalog.byCode['ac02'] = sticker, throwsUnsupportedError);
    expect(
      () => OfficialStickerCatalog.empty.byCode.clear(),
      throwsUnsupportedError,
    );
  });

  test('malformed packs and metadata cannot create official entries', () {
    final badIDs = [
      '',
      'AC01',
      ':ac01:',
      'ac 01',
      'ac01\n',
      'a.*',
      '1ac',
      'ac1',
      'ac12345',
      'emoji1',
      'smile',
    ];
    final badURLs = [
      '',
      'http://images.example.test/ac.png',
      '//images.example.test/ac.png',
      '/ac.png',
      'data:image/png;base64,AA==',
      'javascript:alert(1)',
      'https:///ac.png',
      'https://user:secret@images.example.test/ac.png',
      'https://images.example.test/ac 01.png',
      'https://images.example.test/ac.png\n',
      r'https://images.example.test\ac.png',
      'https://images.example.test:0/ac.png',
      'https://images.example.test:65536/ac.png',
    ];
    final catalog = OfficialStickerCatalog.fromPacks([
      {},
      {'items': 'not a list'},
      {
        'items': [
          null,
          1,
          {},
          for (final id in badIDs) _item(id),
          for (var index = 0; index < badURLs.length; index++)
            _item('ac${1000 + index}', url: badURLs[index]),
          _item('ac2001', label: '  '),
          _item('ac2002', insertion: ':ac01:'),
          _item('ac2003', insertion: ':ac2003: extra content'),
          {..._item('ac2004'), 'id': 12},
          {..._item('ac2005'), 'url': 12},
          {..._item('ac2006'), 'label': null},
          {..._item('ac2007'), 'insertion': null},
        ],
      },
    ]);
    expect(catalog, same(OfficialStickerCatalog.empty));
  });

  test('the first valid duplicate wins without rejecting other entries', () {
    final catalog = OfficialStickerCatalog.fromPacks([
      {
        'items': [_item('ac01', url: 'http://invalid.example.test/a.png')],
      },
      {
        'items': [_item('ac01'), _item('ac02')],
      },
      {
        'items': [_item('ac01', url: 'https://changed.example.test/a.png')],
      },
    ]);
    expect(catalog.byCode.keys, ['ac01', 'ac02']);
    expect(
      catalog.byCode['ac01']!.url,
      'https://images.example.test/catalog/ac01.png',
    );
  });

  test(
    'candidate scan is cheap, case sensitive and not a rendering decision',
    () {
      for (final text in [
        '',
        'ordinary text',
        ':',
        ':AC01:',
        ':bad code:',
        ':unknown:',
        ':smile:',
      ]) {
        expect(hasDraftStickerCandidates(text), isFalse, reason: text);
      }
      for (final text in [':ac01:', ':ac99:', '`code :ac01:`']) {
        expect(hasDraftStickerCandidates(text), isTrue, reason: text);
      }
    },
  );

  test('empty catalog leaves official-looking tokens as ordinary text', () {
    final nodes = parseDraftMarkdown('文字 :ac01: **:ac02:**');
    expect(draftStickerOccurrences(nodes), isEmpty);
    expect(nodes.single.textContent, '文字 :ac01: :ac02:');
  });

  test('visible AST preserves source order, duplicates and sticker text', () {
    final catalog = _catalog();
    final nodes = parseDraftMarkdown(
      '前 :ac01: **:yct001:** :ac01: 后',
      stickers: catalog,
    );
    final occurrences = draftStickerOccurrences(nodes);
    expect(occurrences, [
      catalog.byCode['ac01'],
      catalog.byCode['yct001'],
      catalog.byCode['ac01'],
    ]);
    final stickers = _elements(nodes, draftStickerTag).toList();
    expect(stickers.first.textContent, ':ac01:');
    expect(stickers.first.attributes, {
      'src': catalog.byCode['ac01']!.url,
      'alt': catalog.byCode['ac01']!.label,
      'code': 'ac01',
    });
    expect(nodes.single.textContent, '前 :ac01: :yct001: :ac01: 后');
    expect(() => occurrences.clear(), throwsUnsupportedError);
  });

  test(
    'unknown, differently padded and differently cased tokens stay text',
    () {
      final nodes = _parse(':missing: :ac1: :AC01: :ac01: :emoji0: :emoji00:');
      expect(draftStickerOccurrences(nodes).map((item) => item.code), [
        'ac01',
        'emoji00',
      ]);
      expect(
        nodes.single.textContent,
        ':missing: :ac1: :AC01: :ac01: :emoji0: :emoji00:',
      );
      expect(_codes(List.filled(1000, ':ac99:').join(' ')), isEmpty);
    },
  );

  test(
    'standard GFM emoji survives both default and official catalog parsing',
    () {
      expect(parseDraftMarkdown(':smile:').single.textContent, '😄');
      final nodes = _parse(':smile: :ac01: :heart:');
      expect(nodes.single.textContent, '😄 :ac01: ❤️');
      expect(draftStickerOccurrences(nodes).map((item) => item.code), ['ac01']);
    },
  );

  test('headings, emphasis, lists, quotes and GFM tables retain stickers', () {
    expect(
      _codes('''# 标题 :ac01:

**:ac02:** *:yct001:* ~~:emoji00:~~

- 列表 :ac01:
- [x] 完成 :ac02:

> 引用 :yct001:

| 名称 :emoji00: | 内容 |
| --- | --- |
| 行 :ac01: | :ac02: |
'''),
      [
        'ac01',
        'ac02',
        'yct001',
        'emoji00',
        'ac01',
        'ac02',
        'yct001',
        'emoji00',
        'ac01',
        'ac02',
      ],
    );
  });

  test('escaped colons and all inline code delimiters stay literal', () {
    expect(_codes(r'\:ac01: \\:ac02: `:ac01:` ``:ac02:`` :emoji00:'), [
      'ac02',
      'emoji00',
    ]);
    expect(_codes('`:ac01: ` `` :ac02: ` :yct001: `` :emoji00:'), ['emoji00']);
    expect(_codes(r'\`:ac01:\`'), ['ac01']);
  });

  test('fenced, indented and nested quoted code never create images', () {
    expect(
      _codes(''':ac01:

```md
:ac02:
```

~~~
:yct001:
~~~

    :emoji00:

> ```
> :ac02:
> ```

- item

      :yct001:

:emoji00:
'''),
      ['ac01', 'emoji00'],
    );
  });

  test(
    'link labels render while destinations, titles and autolinks do not',
    () {
      final nodes = _parse(
        '''[看 :ac01:](https://example.test/:ac02: "标题 :yct001:")
<https://example.test/:emoji00:>
https://example.test/:ac02:
''',
      );
      expect(draftStickerOccurrences(nodes).map((item) => item.code), ['ac01']);
      final firstLink = _elements(nodes, 'a').first;
      expect(firstLink.attributes['href'], 'https://example.test/:ac02:');
      expect(firstLink.attributes['title'], '标题 :yct001:');
    },
  );

  test('reference destinations, titles and secondary labels stay metadata', () {
    final nodes = _parse('''[看 :ac01:][隐藏 :ac02:]
![图 :ac01:][隐藏 :ac02:]
[文字 :emoji00:][]

[隐藏 :ac02:]: https://example.test/:yct001: "标题 :emoji00:"
[文字 :emoji00:]: https://example.test/second
''');
    expect(draftStickerOccurrences(nodes).map((item) => item.code), [
      'ac01',
      'emoji00',
    ]);
    final image = _elements(nodes, 'img').single;
    expect(image.attributes['alt'], '图 :ac01:');
    expect(image.attributes['src'], 'https://example.test/:yct001:');
    expect(image.attributes['title'], '标题 :emoji00:');
  });

  test('image alt retains shortcode text without becoming a sticker load', () {
    final nodes = _parse(
      '![:ac01: **:ac02:**](https://example.test/picture.png) :yct001:',
    );
    expect(_elements(nodes, 'img').single.attributes['alt'], ':ac01: :ac02:');
    expect(draftStickerOccurrences(nodes).map((item) => item.code), ['yct001']);
  });

  test(
    'ordinary and explicitly labelled sticker images keep img semantics',
    () {
      final nodes = _parse(
        '![表情](https://images.example.test/catalog/ac01.png) '
        '![普通图](https://example.test/other.png) :ac02:',
      );
      expect(_elements(nodes, 'img').length, 2);
      expect(draftStickerOccurrences(nodes).map((item) => item.code), ['ac02']);
    },
  );

  test('HTML attributes and opaque comments never create hidden stickers', () {
    expect(
      _codes('''前 <span title=":ac01:" data-value='>:ac02:'>:yct001:</span>
注释 <!-- :ac01: <code>:ac02:</code> --> :emoji00:
指令 <?sample :ac01:?>
内容 <![CDATA[<code>:ac02:</code>]]>
声明 <!SAMPLE :ac01:>
'''),
      ['yct001', 'emoji00'],
    );
  });

  test(
    'inline HTML code and raw text protect content until matching close',
    () {
      for (final tag in [
        'code',
        'pre',
        'kbd',
        'samp',
        'script',
        'style',
        'textarea',
        'xmp',
      ]) {
        expect(_codes('前 <$tag data-label=":ac01:">:ac02:</$tag> :emoji00:'), [
          'emoji00',
        ], reason: tag);
      }
      expect(_codes('前 <CoDe>:ac01:</cOdE> :ac02:'), ['ac02']);
      expect(
        _codes(
          '前 <code>**:ac01:** <code>:ac02:</code> :yct001:</code> :emoji00:',
        ),
        ['emoji00'],
      );
      expect(_codes('前 <textarea><code>:ac01:</textarea> :ac02:'), ['ac02']);
    },
  );

  test(
    'HTML protection crosses paragraphs but never leaks across documents',
    () {
      expect(_codes('前 <code>\n\n:ac01:\n\n</code> 后\n\n:ac02:'), ['ac02']);
      expect(_codes('<!-- 注释\n\n:ac01:\n\n-->\n\n:ac02:'), ['ac02']);
      expect(_codes('前 <code>:ac01:'), isEmpty);
      expect(_codes(':ac01:'), ['ac01']);
    },
  );

  test(
    'HTML markers inside Markdown code and escaped text do not open guards',
    () {
      expect(_codes(r'`<code>` :ac01: \<code> :ac02: &lt;code&gt; :emoji00:'), [
        'ac01',
        'ac02',
        'emoji00',
      ]);
      expect(_codes('```html\n<code>\n```\n\n:ac01:'), ['ac01']);
      expect(_codes('前 <span title="<code>">:ac01:</span> :ac02:'), [
        'ac01',
        'ac02',
      ]);
      expect(_codes('前 <code/> :ac01:'), ['ac01']);
    },
  );

  test('collector ignores raw tags and fabricated ordinary elements', () {
    final fake = md.Element.text(draftStickerTag, ':ac01:')
      ..attributes.addAll({
        'src': 'https://example.test/fake.png',
        'alt': 'fake',
        'code': 'ac01',
      });
    expect(draftStickerOccurrences([fake]), isEmpty);
    expect(
      _codes(
        '前 <seekdesk-sticker code="ac01" src="https://example.test/a.png"/>',
      ),
      isEmpty,
    );
  });

  test('decoded and escaped tag text cannot close actual HTML protection', () {
    for (final close in [
      '&lt;/code&gt;',
      '&#60;/code&#62;',
      '&lt;/code>',
      r'\</code>',
    ]) {
      expect(
        _codes('前 <code>:ac01: $close :ac02:</code> :emoji00:'),
        ['emoji00'],
        reason: close,
      );
    }
    expect(
      _codes('前 <textarea> &lt;/textarea&gt; :ac01:</textarea> :ac02:'),
      ['ac02'],
    );
    expect(_codes('前 <plaintext>:ac01:</plaintext> :ac02:'), isEmpty);
  });

  test('real HTML blocks retain protection across paragraphs and nesting', () {
    for (final text in [
      '<code>\n\n:ac01:\n\n</code>\n\n:ac02:',
      '> 前 <code>\n>\n> :ac01:\n>\n> </code> :ac02:',
      '- 前 <code>\n\n  :ac01:\n\n  </code> :ac02:',
    ]) {
      expect(_codes(text), ['ac02'], reason: text);
    }
  });

  test('opaque inline HTML uses source delimiters across paragraphs', () {
    for (final (open, fake, close) in [
      ('<!--', r'--&gt; \--> &#45;->', '-->'),
      ('<![CDATA[', r']]&gt; \]]> &#93;]>', ']]>'),
      ('<?sample', r'?&gt; \?> &#63;>', '?>'),
    ]) {
      final source =
          '前 $open 未闭合\n\n:ac01: $fake :ac02:\n\n$close 后 :emoji00:';
      expect(_codes(source), ['emoji00'], reason: open);
      expect(_codes(':ac01:'), ['ac01']);
    }
  });

  test('opaque boundaries preserve escape parity and Markdown code regions', () {
    for (final (open, close) in [
      ('<!--', '-->'),
      ('<![CDATA[', ']]>'),
      ('<?sample', '?>'),
    ]) {
      for (final protected in [
        '`$close`',
        close == ']]>'
            ? '![`$close`](https://example.test/image.png)'
            : '![$close](https://example.test/image.png)',
        '[label](https://example.test/a "$close")',
        '\\$close',
        '${close.substring(0, close.length - 1)}\\>',
      ]) {
        expect(
          _codes('前 $open\n\n$protected :ac01:\n\n$close :ac02:'),
          ['ac02'],
          reason: '$open $protected',
        );
      }
      expect(_codes('前 $open\n\n\\\\$close :ac02:'), ['ac02']);
      expect(_codes('前 $open\n\n\\\\\\$close :ac01:'), isEmpty);
    }
  });

  test('HTML source tracking keeps GFM table precedence and text', () {
    const source = '<div> | header\n--- | ---\n:ac01: | value';
    final nodes = _parse(source);
    expect(_elements(nodes, 'table'), hasLength(1));
    expect(nodes.single.textContent, '<div>header:ac01:value');
    expect(draftStickerOccurrences(nodes).map((item) => item.code), ['ac01']);
  });

  for (final (context, source) in [
    ('footnote', '注[^n] :ac99:\n\n[^n]: <div>HTML</div>'),
    ('tight list', '- <!--x-->\n  :ac99:'),
  ]) {
    test('HTML source tracking preserves $context structure', () {
      final expected = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(source);
      final nodes = _parse(source);
      expect(md.renderToHtml(nodes), md.renderToHtml(expected));
    });
  }

  test(
    'content without shortcode candidates preserves ordinary GFM output',
    () {
      const source = '''# Heading

**Bold**, *italic*, ~~strike~~ and `code`.

- [x] A task
- A [link](https://example.test/)

| first | second |
| --- | --- |
| a | b |

![image](https://example.test/photo.png)
''';
      final expected = md.Document(extensionSet: md.ExtensionSet.gitHubWeb)
          .parse(source);
      expect(md.renderToHtml(_parse(source)), md.renderToHtml(expected));
    },
  );
}
