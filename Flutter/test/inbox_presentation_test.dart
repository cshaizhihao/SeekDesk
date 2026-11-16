import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:seekdesk_flutter/core/inbox_presentation.dart';

void main() {
  final now = DateTime(2026, 11, 15, 17, 30);

  group('plain inbox summaries', () {
    test('ordinary text keeps meaning while flattening whitespace', () {
      expect(inboxSummary(''), isEmpty);
      expect(inboxSummary('  \n\t '), isEmpty);
      expect(inboxSummary('第一行\n第二行\t  第三行'), '第一行 第二行 第三行');
      expect(
        inboxSummary('foo_bar 1 < 2 & hello 😀'),
        'foo_bar 1 < 2 & hello 😀',
      );
      expect(
        inboxSummary('https://example.com/plain/path'),
        'https://example.com/plain/path',
      );
    });

    test(
      'named and reference links keep labels instead of destination URLs',
      () {
        expect(
          inboxSummary(
            '通知：[查看 **帖子**](https://www.nodeseek.com/post-12-1#3 "帖子")。',
          ),
          '通知：查看 帖子。',
        );
        expect(
          inboxSummary(
            '打开[帮助文档][help]查看\n\n[help]: https://example.com/a?private=1',
          ),
          '打开帮助文档查看',
        );
        expect(inboxSummary('[说明](https://example.com/a_(b))'), '说明');
        expect(
          inboxSummary('<https://example.com/docs>'),
          'https://example.com/docs',
        );
        expect(
          inboxSummary('[打开](javascript:alert) [本地](file:///tmp/private)'),
          '打开 本地',
        );
      },
    );

    test('images retain descriptions without exposing or fetching sources', () {
      expect(
        inboxSummary('看图 ![**截图**](https://images.example.test/image.png)'),
        '看图 [图片：截图]',
      );
      expect(
        inboxSummary('![](https://images.example.test/image.png)'),
        '[图片]',
      );
      expect(
        inboxSummary('![表情](https://images.example.test/sticker.gif)'),
        '[表情]',
      );
      expect(
        inboxSummary(
          '![示意图][image]\n\n[image]: https://images.example.test/private.png',
        ),
        '[图片：示意图]',
      );
    });

    test('formatting and block boundaries become readable plain text', () {
      expect(inboxSummary('**粗体** _斜体_ ~~删除~~'), '粗体 斜体 删除');
      expect(inboxSummary('# 标题\n\n> 引用\n\n- 第一项\n- 第二项'), '标题 引用 第一项 第二项');
      expect(inboxSummary('- [x] 已完成\n- [ ] 等待'), '已完成 等待');
      expect(
        inboxSummary('| 名称 | 数量 |\n| --- | --- |\n| 节点 | 2 |'),
        '名称 数量 节点 2',
      );
    });

    test(
      'inline and fenced code preserve literal markup and sticker codes',
      () {
        expect(
          inboxSummary('运行 `x < y && :ac01:` 完成'),
          '运行 x < y && :ac01: 完成',
        );
        expect(
          inboxSummary(
            '```dart\nfinal value = "<b>";\n// :smile: [label](https://example.com)\n```',
          ),
          'final value = "<b>"; // :smile: [label](https://example.com)',
        );
      },
    );

    test(
      'emoji aliases and official shortcodes work without a sticker catalog',
      () {
        expect(inboxSummary('😀 :smile: :heart: :+1:'), '😀 😄 ❤️ 👍');
        expect(
          inboxSummary(':ac01: :yct001: :xhj001: :emoji01:'),
          '[表情] [表情] [表情] [表情]',
        );
        expect(
          inboxSummary(':custom_unknown: :ac1: :emoji001:'),
          ':custom_unknown: :ac1: :emoji001:',
        );
      },
    );

    test('HTML links discard attributes and only keep visible text', () {
      expect(
        inboxSummary(
          '<a href="https://example.test/private" onclick="run()">查看通知</a><br>下一行',
        ),
        '查看通知 下一行',
      );
      expect(inboxSummary('<div><b>标题</b></div><p>正文</p>'), '标题 正文');
      expect(
        inboxSummary(
          '<img src="https://example.test/private" onerror="run()">',
        ),
        '[图片]',
      );
      expect(
        inboxSummary('<a title="1 > 0" href="javascript:run()">名称</a>'),
        '名称',
      );
    });

    test(
      'HTML scripts styles comments and embedded document bodies stay hidden',
      () {
        expect(
          inboxSummary(
            '前文<script>alert("private")</script><style>.private {}</style>后文',
          ),
          '前文后文',
        );
        expect(inboxSummary('前<!--private comment-->后'), '前后');
        expect(
          inboxSummary('<iframe src="https://example.test">隐藏内容</iframe>可见文字'),
          '可见文字',
        );
        expect(
          inboxSummary('<script>\n\nprivate body\n\n</script>\n\nvisible body'),
          'visible body',
        );
        expect(inboxSummary('可见文字<script>未闭合脚本'), '可见文字');
        expect(inboxSummary('可见文字<!--未闭合注释'), '可见文字');
      },
    );

    test('escaped tags and entities remain ordinary visible text', () {
      expect(inboxSummary(r'\<b>不是 HTML\</b>'), '<b>不是 HTML</b>');
      expect(
        inboxSummary('&lt;b&gt;字面标签&lt;/b&gt; &amp; &#x1F600; &quot;引用&quot;'),
        '<b>字面标签</b> & 😀 "引用"',
      );
      expect(inboxSummary('`&amp; <b>literal</b>`'), '&amp; <b>literal</b>');
    });

    test('control characters cannot inject lines or bidi spoof the row', () {
      expect(inboxSummary('正\u0000文\u0008\u001b\u202e后\u2066续\u2069'), '正文后续');
      expect(inboxSummary('👨‍👩‍👧‍👦 e\u0301'), '👨‍👩‍👧‍👦 e\u0301');
    });

    test('character bounds keep whole emoji and combining graphemes', () {
      const cluster = '👨‍👩‍👧‍👦';
      final result = inboxSummary(List.filled(300, cluster).join());
      expect(result, '${List.filled(240, cluster).join()}…');
      expect(result.characters.length, 241);
      expect(result, isNot(contains('\uFFFD')));
      final combining = inboxSummary(List.filled(300, 'e\u0301').join());
      expect(combining, '${List.filled(240, 'e\u0301').join()}…');
    });

    test(
      'oversized source is bounded before parsing and does not retain its tail',
      () {
        final first = inboxSummary(
          '${List.filled(100000, '普通文字').join()}private-tail-A',
        );
        final second = inboxSummary(
          '${List.filled(100000, '普通文字').join()}private-tail-B',
        );
        expect(first, second);
        expect(first.characters.length, 241);
        expect(first, endsWith('…'));
        expect(first, isNot(contains('private-tail')));
      },
    );

    test(
      'a destination cut by the input bound still yields the useful label',
      () {
        final destination =
            'https://example.test/${List.filled(10000, 'x').join()}';
        expect(inboxSummary('[查看通知]($destination)'), '查看通知…');
        expect(inboxSummary('![截图]($destination)'), '[图片：截图]…');
      },
    );

    test(
      'pathological nesting delimiter runs and malformed tags are bounded',
      () {
        for (final raw in [
          List.filled(10000, '[').join(),
          List.filled(10000, '> ').join(),
          List.filled(10000, '*_').join(),
          List.filled(10000, '<a ').join(),
          List.filled(10000, '- item\n').join(),
          '<a title="${List.filled(10000, 'x').join()}',
        ]) {
          final summary = inboxSummary(raw);
          expect(summary.characters.length, lessThanOrEqualTo(241));
          expect(summary, endsWith('…'));
          expect(summary, isNot(contains('\n')));
        }
      },
    );

    test('repeated calls cannot mix unrelated conversation summaries', () {
      final original = inboxSummary('[会话甲](https://example.test/a)');
      for (var index = 0; index < 80; index++) {
        expect(
          inboxSummary('[会话 $index](https://example.test/$index)'),
          '会话 $index',
        );
      }
      expect(inboxSummary('[会话甲](https://example.test/a)'), original);
      expect(inboxSummary('[会话乙](https://example.test/a)'), '会话乙');
    });
  });

  test('empty dates do not invent a timestamp or tooltip', () {
    for (final raw in ['', '   ', '\n\t']) {
      final value = inboxDateLabel(raw, now: now);
      expect(value.short, isEmpty);
      expect(value.full, isEmpty);
    }
  });

  test('today shows the clock and keeps seconds in the full local label', () {
    final value = inboxDateLabel(' 2026-11-15T09:06:07 ', now: now);
    expect(value.short, '09:06');
    expect(value.full, '2026年11月15日 09:06:07（本地时间）');
  });

  test('yesterday uses a calendar day across month and year boundaries', () {
    final samples = [
      (DateTime(2027, 1, 1, 1), '2026-12-31T23:08:09'),
      (DateTime(2026, 3, 1, 1), '2026-02-28T23:08:09'),
      (DateTime(2024, 3, 1, 1), '2024-02-29T23:08:09'),
    ];
    for (final sample in samples) {
      expect(inboxDateLabel(sample.$2, now: sample.$1).short, '昨天 23:08');
    }
  });

  test('older dates distinguish this year from previous years', () {
    final currentYear = inboxDateLabel('2026-02-03T01:02:03', now: now);
    expect(currentYear.short, '2月3日');
    expect(currentYear.full, '2026年2月3日 01:02:03（本地时间）');

    final previousYear = inboxDateLabel('2025-12-01T21:04:05', now: now);
    expect(previousYear.short, '2025/12/01');
    expect(previousYear.full, '2025年12月1日 21:04:05（本地时间）');
  });

  test('UTC and explicit offsets describe the same local date and clock', () {
    // Build the instant from local components so this fixture also works on
    // machines whose test process uses a different time zone.
    final local = DateTime(2026, 7, 4, 13, 14, 15);
    final utc = local.toUtc();
    final offsetWall = utc.add(const Duration(hours: 5, minutes: 30));
    final offsetText =
        '${offsetWall.toIso8601String().replaceFirst('Z', '')}+05:30';
    for (final raw in [utc.toIso8601String(), offsetText]) {
      final value = inboxDateLabel(raw, now: local);
      expect(value.short, '13:14');
      expect(value.full, '2026年7月4日 13:14:15（本地时间）');
    }
  });

  test(
    'future dates retain their date instead of a negative relative label',
    () {
      expect(inboxDateLabel('2026-11-20T12:00:00', now: now).short, '11月20日');
      expect(
        inboxDateLabel('2027-01-03T12:00:00', now: now).short,
        '2027/01/03',
      );
    },
  );

  test('unknown server date strings remain available in full', () {
    final brief = inboxDateLabel('  刚刚  ', now: now);
    expect(brief.short, '刚刚');
    expect(brief.full, '刚刚');

    final text = List.filled(20, '😀').join();
    final lengthy = inboxDateLabel(text, now: now);
    expect(lengthy.short, '${List.filled(16, '😀').join()}…');
    expect(lengthy.full, text);
    expect(lengthy.short, isNot(contains('\uFFFD')));
  });
}
