import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/inbox_peer.dart';

void main() {
  test(
    'lookup accepts positive decimal identifiers and canonical profiles',
    () {
      for (final input in [
        '42',
        '  42\n',
        'https://nodeseek.com/space/42\t',
        '0042',
        'https://www.nodeseek.com/space/42',
        'https://nodeseek.com/space/42/',
        'https://nodeseek.com:443/space/42',
        'HTTPS://WWW.NODESEEK.COM/space/42',
        'https://www.nodeseek.com/space/42?tab=profile#readme',
      ]) {
        expect(parseInboxPeerID(input), 42, reason: input);
      }
      expect(parseInboxPeerID('9007199254740991'), 9007199254740991);
    },
  );

  test(
    'lookup rejects nonidentifiers and values unsafe for native web JSON',
    () {
      for (final input in [
        '',
        '   ',
        '0',
        '-1',
        '+42',
        '4.2',
        '4e2',
        '0x2a',
        '４２',
        '42 43',
        '4\n2',
        '9007199254740992',
        '999999999999999999999999999999999999999999',
        List.filled(2049, '0').join(),
      ]) {
        expect(parseInboxPeerID(input), isNull, reason: input);
      }
    },
  );

  test('lookup validates raw authority and path before URI normalization', () {
    for (final input in [
      'http://www.nodeseek.com/space/42',
      '//www.nodeseek.com/space/42',
      'www.nodeseek.com/space/42',
      'https://www.nodeseek.com.evil.invalid/space/42',
      'https://sub.nodeseek.com/space/42',
      'https://nodeseek.com./space/42',
      'https://evil.invalid/space/42',
      'https://evil.invalid@nodeseek.com/space/42',
      'https://@nodeseek.com/space/42',
      'https://:secret@nodeseek.com/space/42',
      'https://nodeseek.com:8443/space/42',
      'https://nodeseek.com:/space/42',
      'https://nodeseek.com:0443/space/42',
      'https://%6eodeseek.com/space/42',
      'https://nodeseek.com/space/0',
      'https://nodeseek.com/space/-42',
      'https://nodeseek.com/space/+42',
      'https://nodeseek.com/space/42.0',
      'https://nodeseek.com/space/9007199254740992',
      'https://nodeseek.com/Space/42',
      'https://nodeseek.com/post-42-1',
      'https://nodeseek.com/space/42/more',
      'https://nodeseek.com//space/42',
      'https://nodeseek.com/space/42//',
      'https://nodeseek.com/other/../space/42',
      'https://nodeseek.com/space/%34%32',
      'https://nodeseek.com/space%2f42',
      'https://nodeseek.com/space/42%2f',
      'https://nodeseek.com/space/4\n2',
      r'https://nodeseek.com\@evil.invalid/space/42',
    ]) {
      expect(parseInboxPeerID(input), isNull, reason: input);
    }
  });

  test('lookup distinguishes empty, malformed and own-account input', () {
    expect(inboxPeerLookupError(''), contains('请输入对方'));
    expect(inboxPeerLookupError('not a UID'), contains('有效'));
    expect(inboxPeerLookupError('101', owner: 101), contains('不能向自己'));
    expect(
      inboxPeerLookupError('https://nodeseek.com/space/101', owner: 101),
      contains('不能向自己'),
    );
    expect(inboxPeerLookupError('42', owner: 101), isNull);
  });
}
