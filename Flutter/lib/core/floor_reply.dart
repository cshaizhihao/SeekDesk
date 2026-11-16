import 'package:flutter/widgets.dart' show StringCharacters;

import '../models/snapshots.dart';
import 'native_client.dart';

final _newlines = RegExp(r'\r\n|[\n\r\u000b\u000c\u0085\u2028\u2029]');

/// The suffix to append to this topic's draft, matching ForumFloorDraft.
/// Nothing is published and the caller owns the single undoable insertion.
String? floorReplyInsertion(
  FloorData floor,
  String page, {
  required bool quoting,
  required String after,
}) {
  final number = int.tryParse(floor.id);
  final uri = Uri.tryParse(page);
  // Uri normalizes an empty user-info component away; reject the raw authority
  // as well, so https://@www.nodeseek.com cannot pass the no-user-info rule.
  final authority = RegExp(
    r'^https://([^/?#]*)',
    caseSensitive: false,
  ).firstMatch(page)?[1];
  if (number == null ||
      number < 0 ||
      uri == null ||
      authority == null ||
      authority.contains('@') ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(page) ||
      uri.scheme != 'https' ||
      !const ['nodeseek.com', 'www.nodeseek.com'].contains(uri.host) ||
      uri.authority.contains('@') ||
      uri.port != 443) {
    return null;
  }
  final path = uri.pathSegments.toList();
  if (path.isNotEmpty && path.last.isEmpty) path.removeLast();
  if (path.length != 1 || path.single.contains('/')) return null;
  final parts = path.single.split('-');
  if (parts.length < 2 ||
      parts.first != 'post' ||
      (int.tryParse(parts[1]) ?? 0) <= 0) {
    return null;
  }
  // URI parentheses are legal, but unescaped ones terminate Markdown links.
  final link = uri
      .replace(fragment: '$number')
      .toString()
      .replaceAll('(', '%28')
      .replaceAll(')', '%29');
  final name = floor.author
      .split(_newlines)
      .where((line) => line.isNotEmpty)
      .join(' ')
      .trim()
      .replaceAllMapped(
        RegExp(r'[\\`*_{}\[\]()<>!|]'),
        (match) => '\\${match[0]}',
      );
  final heading = '${name.isEmpty ? '' : '@$name '}[#$number]($link)';
  final gap = after.isEmpty || after.endsWith('\n\n')
      ? ''
      : after.endsWith('\n')
      ? '\n'
      : '\n\n';
  if (!quoting) return '$gap$heading\n\n';
  final original = _excerpt(floor.blocks).trim();
  final prefix = '$gap> $heading';
  if (original.isEmpty) return '$prefix\n\n';
  final characters = original.characters;
  final limited = characters.take(1600).toString();
  final lines = limited.split(_newlines).map((line) => '> $line').join('\n');
  return '$prefix\n>\n$lines${characters.length > 1600 ? '…' : ''}\n\n';
}

String _excerpt(List<JsonMap> blocks) {
  var remaining = 20;
  String collect(List<JsonMap> blocks) {
    final parts = <String>[];
    for (final block in blocks) {
      if (remaining == 0) break;
      remaining--;
      switch (block['kind']) {
        case 'text' || 'heading' || 'quote' || 'code':
          parts.add(stringValue(block['text']));
        case 'image':
          parts.add('[图片]');
        case 'terminal' || 'terminalUnavailable':
          parts.add('[测评终端]');
        case 'tabs':
          final tabs = jsonItems(block['tabs']);
          if (tabs.isNotEmpty) {
            parts.add(collect(jsonItems(tabs.first['blocks'])));
          }
        case 'list':
          for (final item in jsonItems(block['items'])) {
            if (remaining == 0) break;
            final children = jsonItems(item['blocks']);
            if (children.isEmpty) remaining--;
            final text = collect(children);
            final marker = stringValue(item['marker']);
            final indent = ' ' * (marker.length + 1);
            parts.add(
              '$marker${text.isEmpty ? '' : ' ${text.replaceAll(_newlines, '\n$indent')}'}',
            );
          }
      }
    }
    return parts.join('\n');
  }

  return collect(blocks);
}
