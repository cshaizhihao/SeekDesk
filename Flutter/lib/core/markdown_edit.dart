import 'dart:math' as math;

import 'package:flutter/services.dart';

enum MarkdownCommand {
  bold,
  italic,
  strike,
  heading,
  quote,
  bullets,
  numbers,
  code,
  link,
  image,
  codeBlock,
  table,
  divider,
}

enum MarkdownTypingCommand { newline, indent, outdent }

/// Handles explicit Return/Tab commands; ordinary typing and pasted text never
/// pass through this function. The input layer owns focus, key modifiers and
/// send-shortcut precedence, and applies the result through DocumentHistory.
///
/// Null means invalid/composing input, or a newline that should use the platform
/// behavior. An outdent with nothing to remove returns the original value so
/// Shift-Tab can stay in the editor without creating a history transaction.
TextEditingValue? applyMarkdownTypingCommand(
  TextEditingValue value,
  MarkdownTypingCommand command,
) {
  final selection = value.selection;
  final source = value.text;
  if (value.composing.isValid && !value.composing.isCollapsed) return null;
  if (!selection.isValid ||
      selection.end > source.length ||
      !_isScalarBoundary(source, selection.start) ||
      !_isScalarBoundary(source, selection.end)) {
    return null;
  }
  final editor = _MarkdownTypingEditor(source, selection.start, selection.end);
  final edit = switch (command) {
    MarkdownTypingCommand.newline => editor.newline(),
    MarkdownTypingCommand.indent => editor.indentation(outdent: false),
    MarkdownTypingCommand.outdent => editor.indentation(outdent: true),
  };
  if (edit == null) {
    return command == MarkdownTypingCommand.outdent ? value : null;
  }
  return _editedValue(value, edit);
}

/// Applies one explicit formatting command without owning focus or undo history.
///
/// Offsets remain UTF-16, as required by [TextEditingValue]. Invalid selections
/// and selections that split a surrogate pair are rejected rather than moved.
/// An active IME composition must finish through the text input system first.
TextEditingValue? applyMarkdownCommand(
  TextEditingValue value,
  MarkdownCommand command,
) {
  final selection = value.selection;
  final source = value.text;
  if (value.composing.isValid && !value.composing.isCollapsed) return null;
  if (!selection.isValid ||
      selection.end > source.length ||
      !_isScalarBoundary(source, selection.start) ||
      !_isScalarBoundary(source, selection.end)) {
    return null;
  }

  final edit = _MarkdownEditor(
    source,
    selection.start,
    selection.end,
  ).apply(command);
  return _editedValue(value, edit);
}

TextEditingValue _editedValue(TextEditingValue value, _MarkdownEdit edit) {
  final selection = value.selection;
  final source = value.text;
  final text = source.replaceRange(edit.start, edit.end, edit.text);
  final reversed = selection.baseOffset > selection.extentOffset;
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: reversed ? edit.selectedEnd : edit.selectedStart,
      extentOffset: reversed ? edit.selectedStart : edit.selectedEnd,
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    ),
    composing: TextRange.empty,
  );
}

class _MarkdownTypingEditor {
  const _MarkdownTypingEditor(this.source, this.start, this.end);

  final String source;
  final int start, end;
  static const _indent = '    ';
  static final _list = RegExp(
    r'^([ \t]*)([-+*]|([0-9]{1,9})([.)]))([ \t]+)(?:\[([ xX])\]([ \t]+))?',
  );

  _MarkdownEdit? newline() {
    // Never split an existing CRLF pair, even if a programmatic selection has
    // placed the caret between its code units.
    if (start != end || _beforeCrLf(source, start) != start) return null;
    final first = _lineStart(source, start);
    final contentEnd = _lineContentEnd(source, first);
    final line = source.substring(first, contentEnd);
    final match = _list.firstMatch(line);
    if (match == null || start < first + match.end || _insideFence(first)) {
      return null;
    }
    if (line.substring(match.end).trim().isEmpty) {
      return _MarkdownEdit(
        start: first,
        end: contentEnd,
        text: '',
        selectedStart: first,
        selectedEnd: first,
      );
    }

    var marker = match.group(2)!;
    if (match.group(3) case final number?) {
      marker = '${math.min(999999999, int.parse(number) + 1)}${match.group(4)}';
    }
    final ending = _lineEnding(first, contentEnd);
    final checkbox = match.group(6) == null ? '' : '[ ] ';
    final insertion = '$ending${match.group(1)}$marker $checkbox';
    return _MarkdownEdit(
      start: start,
      end: end,
      text: insertion,
      selectedStart: start + insertion.length,
      selectedEnd: start + insertion.length,
    );
  }

  String _lineEnding(int first, int contentEnd) {
    final lineEnd = _lineEnd(source, first);
    if (lineEnd > contentEnd) return source.substring(contentEnd, lineEnd);
    // A final line inherits its immediate predecessor's separator, including
    // CRLF and Unicode line endings; a one-line document starts with LF.
    if (first == 0) return '\n';
    final length =
        first >= 2 &&
            source.codeUnitAt(first - 2) == 0x0d &&
            source.codeUnitAt(first - 1) == 0x0a
        ? 2
        : 1;
    return source.substring(first - length, first);
  }

  _MarkdownEdit? indentation({required bool outdent}) {
    final first = _lineStart(source, start);
    final last = _lineEnd(source, end > start ? end - 1 : start);
    final lines = _selectedLines(source, first, last);
    final beforeCaret = source.substring(first, start);
    if (!outdent &&
        start == end &&
        start <= _lineContentEnd(source, first) &&
        _indentationLength(beforeCaret) != beforeCaret.length &&
        _list.firstMatch(lines.first.content) == null) {
      return _MarkdownEdit(
        start: start,
        end: end,
        text: _indent,
        selectedStart: start + _indent.length,
        selectedEnd: start + _indent.length,
      );
    }

    var newStart = start, newEnd = end, location = first;
    final replacement = StringBuffer();
    for (final line in lines) {
      final removed = !outdent
          ? 0
          : line.content.startsWith('\t')
          ? 1
          : math.min(4, _edgeRun(line.content, 0x20));
      final added = outdent ? 0 : _indent.length;
      replacement
        ..write(
          outdent ? line.content.substring(removed) : _indent + line.content,
        )
        ..write(line.ending);
      if (location <= start) {
        newStart += added - math.min(removed, start - location);
      }
      if (location < end || start == end) {
        newEnd += added - math.min(removed, end - location);
      }
      location += line.content.length + line.ending.length;
    }
    final text = replacement.toString();
    if (text == source.substring(first, last)) return null;
    return _MarkdownEdit(
      start: first,
      end: last,
      text: text,
      selectedStart: newStart,
      selectedEnd: newEnd,
    );
  }

  bool _insideFence(int limit) {
    int? character;
    var fenceLength = 0, offset = 0;
    while (offset < limit) {
      final contentEnd = _lineContentEnd(source, offset);
      final line = source.substring(offset, contentEnd);
      offset = _lineEnd(source, offset);
      final leading = _edgeRun(line, 0x20);
      if (leading > 3 || leading == line.length) continue;
      final candidate = line.codeUnitAt(leading);
      if (candidate != 0x60 && candidate != 0x7e) continue;
      final rest = line.substring(leading);
      final count = _edgeRun(rest, candidate);
      if (count < 3) continue;
      final tail = rest.substring(count);
      if (character != null) {
        if (candidate == character &&
            count >= fenceLength &&
            tail.trim().isEmpty) {
          character = null;
          fenceLength = 0;
        }
      } else {
        // Backtick fences cannot contain backticks in their info string.
        if (candidate == 0x60 && tail.contains('`')) continue;
        character = candidate;
        fenceLength = count;
      }
    }
    return character != null;
  }
}

class _MarkdownEdit {
  const _MarkdownEdit({
    required this.start,
    required this.end,
    required this.text,
    required this.selectedStart,
    required this.selectedEnd,
  });

  final int start, end;
  final String text;
  final int selectedStart, selectedEnd;
}

class _MarkdownEditor {
  _MarkdownEditor(this.source, this.start, this.end)
    : selected = source.substring(start, end);

  final String source, selected;
  final int start, end;

  _MarkdownEdit apply(MarkdownCommand command) {
    switch (command) {
      case MarkdownCommand.bold:
        return _toggle('**', placeholder: '加粗文字');
      case MarkdownCommand.italic:
        return _toggle('*', placeholder: '斜体文字');
      case MarkdownCommand.strike:
        return _toggle('~~', placeholder: '划线文字');
      case MarkdownCommand.link:
      case MarkdownCommand.image:
        final image = command == MarkdownCommand.image;
        final label = (selected.isEmpty ? (image ? '图片说明' : '链接文字') : selected)
            .replaceAll(r'\', r'\\')
            .replaceAll('[', r'\[')
            .replaceAll(']', r'\]')
            .replaceAll(_lineBreaks, ' ');
        final prefix = '${image ? '!' : ''}[$label](';
        const url = 'https://';
        return _MarkdownEdit(
          start: start,
          end: end,
          text: '$prefix$url)',
          selectedStart: start + prefix.length,
          selectedEnd: start + prefix.length + url.length,
        );
      case MarkdownCommand.divider:
        return _wrap('', '\n\n---\n\n', placeholder: '');
      case MarkdownCommand.table:
        return _wrap(
          '\n\n| ',
          ' | 标题 2 |\n| --- | --- |\n| 内容 1 | 内容 2 |\n\n',
          placeholder: '标题 1',
        );
      case MarkdownCommand.code:
      case MarkdownCommand.codeBlock:
        return _code(block: command == MarkdownCommand.codeBlock);
      case MarkdownCommand.heading:
      case MarkdownCommand.quote:
      case MarkdownCommand.bullets:
      case MarkdownCommand.numbers:
        return _lines(command);
    }
  }

  _MarkdownEdit _wrap(
    String prefix,
    String suffix, {
    required String placeholder,
  }) {
    final contents = selected.isEmpty ? placeholder : selected;
    return _MarkdownEdit(
      start: start,
      end: end,
      text: prefix + contents + suffix,
      selectedStart: start + prefix.length,
      selectedEnd: start + prefix.length + contents.length,
    );
  }

  _MarkdownEdit _toggle(String marker, {required String placeholder}) {
    final width = marker.length;
    // Two asterisks are bold. Removing italic from three must leave the pair.
    bool eligible(String text, {bool trailing = false}) =>
        marker != '*' || _edgeRun(text, 0x2a, trailing: trailing).isOdd;

    if (selected.length >= width * 2 &&
        selected.startsWith(marker) &&
        selected.endsWith(marker) &&
        eligible(selected) &&
        eligible(selected, trailing: true)) {
      final contents = selected.substring(width, selected.length - width);
      return _MarkdownEdit(
        start: start,
        end: end,
        text: contents,
        selectedStart: start,
        selectedEnd: start + contents.length,
      );
    }

    final before = source.substring(0, start);
    final after = source.substring(end);
    if (before.endsWith(marker) &&
        after.startsWith(marker) &&
        eligible(before, trailing: true) &&
        eligible(after)) {
      return _MarkdownEdit(
        start: start - width,
        end: end + width,
        text: selected,
        selectedStart: start - width,
        selectedEnd: end - width,
      );
    }
    return _wrap(marker, marker, placeholder: placeholder);
  }

  _MarkdownEdit _code({required bool block}) {
    final unwrapped = _unwrapCode(block: block);
    if (unwrapped != null) return unwrapped;
    final longest = _longestBacktickRun(selected);
    if (block || _lineBreaks.hasMatch(selected)) {
      final fence = '`' * math.max(3, longest + 1);
      final atLineStart =
          start == 0 || _isLineBreak(source.codeUnitAt(start - 1));
      final atLineEnd =
          end == source.length || _isLineBreak(source.codeUnitAt(end));
      return _wrap(
        '${atLineStart ? '' : '\n'}$fence\n',
        '\n$fence${atLineEnd ? '' : '\n'}',
        placeholder: '代码',
      );
    }

    final fence = '`' * (longest + 1);
    final needsPadding =
        selected.startsWith('`') ||
        selected.endsWith('`') ||
        (selected.startsWith(' ') &&
            selected.endsWith(' ') &&
            selected.codeUnits.any((unit) => unit != 0x20));
    return needsPadding
        ? _wrap('$fence ', ' $fence', placeholder: '代码')
        : _wrap(fence, fence, placeholder: '代码');
  }

  _MarkdownEdit? _unwrapCode({required bool block}) {
    final before = source.substring(0, start);
    final after = source.substring(end);
    if (!block && !_lineBreaks.hasMatch(selected)) {
      if (before.endsWith(' ') && after.startsWith(' ')) {
        final left = _edgeRun(
          before.substring(0, before.length - 1),
          0x60,
          trailing: true,
        );
        final right = _edgeRun(after.substring(1), 0x60);
        if (left > 0 && left == right) {
          return _removeAround(left + 1, right + 1);
        }
      }
      final left = _edgeRun(before, 0x60, trailing: true);
      final right = _edgeRun(after, 0x60);
      if (left > 0 && left == right) return _removeAround(left, right);
      final opening = _edgeRun(selected, 0x60);
      final closing = _edgeRun(selected, 0x60, trailing: true);
      if (opening > 0 &&
          opening == closing &&
          selected.length > opening + closing) {
        final contents = selected.substring(opening, selected.length - closing);
        return _MarkdownEdit(
          start: start,
          end: end,
          text: contents,
          selectedStart: start,
          selectedEnd: start + contents.length,
        );
      }
    }

    // Toolbar-created fences surround the selected content. Remove only their
    // own line endings, leaving paragraph breaks outside the fences untouched.
    final beforeBreak = _trailingLineBreakLength(before);
    final afterBreak = _leadingLineBreakLength(after);
    if (beforeBreak == 0 || afterBreak == 0) return null;
    final openingEnd = before.length - beforeBreak;
    final openingStart = _lineStart(source, openingEnd);
    final opening = source.substring(openingStart, openingEnd);
    final closingStart = end + afterBreak;
    final closingEnd = _lineContentEnd(source, closingStart);
    final closing = source.substring(closingStart, closingEnd);
    if (opening.length >= 3 &&
        _edgeRun(opening, 0x60) == opening.length &&
        closing == opening) {
      return _removeAround(
        opening.length + beforeBreak,
        closing.length + afterBreak,
      );
    }
    return null;
  }

  _MarkdownEdit _removeAround(int left, int right) => _MarkdownEdit(
    start: start - left,
    end: end + right,
    text: selected,
    selectedStart: start - left,
    selectedEnd: end - left,
  );

  _MarkdownEdit _lines(MarkdownCommand command) {
    final first = _lineStart(source, start);
    // The last selected code unit belongs to the last affected line, even when
    // the selection ends exactly at the start of the following, untouched line.
    final last = _lineEnd(source, end > start ? end - 1 : start);
    final lines = _selectedLines(source, first, last);
    if (lines.length == 1 && lines.single.content.isEmpty) {
      final placeholder = switch (command) {
        MarkdownCommand.heading => '标题',
        MarkdownCommand.quote => '引用文字',
        _ => '列表项',
      };
      return _wrap(_prefix(command, 0), '', placeholder: placeholder);
    }

    final markers = [
      for (final line in lines) _linePrefix(line.content, command),
    ];
    final removes = markers.every((marker) => marker?.matches == true);
    final replacement = StringBuffer();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final marker = markers[index];
      final insertion = removes ? '' : _prefix(command, index);
      final markerStart = marker?.start ?? _indentationLength(line.content);
      final markerEnd = marker?.end ?? markerStart;
      replacement
        ..write(line.content.replaceRange(markerStart, markerEnd, insertion))
        ..write(line.ending);
    }
    final text = replacement.toString();
    return _MarkdownEdit(
      start: first,
      end: last,
      text: text,
      selectedStart: first,
      selectedEnd: first + text.length - lines.last.ending.length,
    );
  }
}

String _prefix(MarkdownCommand command, int index) => switch (command) {
  MarkdownCommand.heading => '## ',
  MarkdownCommand.quote => '> ',
  MarkdownCommand.numbers => '${index + 1}. ',
  _ => '- ',
};

class _LinePrefix {
  const _LinePrefix(this.start, this.end, this.matches);

  final int start, end;
  final bool matches;
}

final _headingPrefix = RegExp(r'^([ \t]*)(#{1,6}[ \t]+)');
final _quotePrefix = RegExp(r'^([ \t]*)(>[ \t]?)');
final _listPrefix = RegExp(r'^([ \t]*)([-+*][ \t]+|[0-9]{1,9}[.)][ \t]+)');
final _lineBreaks = RegExp(r'\r\n|[\n\r\u000b\u000c\u0085\u2028\u2029]');

_LinePrefix? _linePrefix(String line, MarkdownCommand command) {
  final expression = switch (command) {
    MarkdownCommand.heading => _headingPrefix,
    MarkdownCommand.quote => _quotePrefix,
    _ => _listPrefix,
  };
  final match = expression.firstMatch(line);
  if (match == null) return null;
  final indentation = match.group(1)!.length;
  final marker = match.group(2)!;
  final matches = switch (command) {
    MarkdownCommand.heading =>
      marker.startsWith('## ') || marker.startsWith('##\t'),
    MarkdownCommand.quote => true,
    MarkdownCommand.bullets => '-+*'.contains(marker[0]),
    _ => marker.codeUnitAt(0) >= 0x30 && marker.codeUnitAt(0) <= 0x39,
  };
  return _LinePrefix(indentation, indentation + marker.length, matches);
}

int _indentationLength(String text) {
  var length = 0;
  while (length < text.length) {
    final unit = text.codeUnitAt(length);
    if (unit != 0x20 && unit != 0x09) break;
    length++;
  }
  return length;
}

int _edgeRun(String text, int unit, {bool trailing = false}) {
  var length = 0;
  while (length < text.length &&
      text.codeUnitAt(trailing ? text.length - length - 1 : length) == unit) {
    length++;
  }
  return length;
}

int _longestBacktickRun(String text) {
  var longest = 0, current = 0;
  for (final unit in text.codeUnits) {
    current = unit == 0x60 ? current + 1 : 0;
    longest = math.max(longest, current);
  }
  return longest;
}

bool _isScalarBoundary(String text, int offset) =>
    offset == 0 ||
    offset == text.length ||
    !(text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff);

bool _isLineBreak(int unit) =>
    unit == 0x0a ||
    unit == 0x0b ||
    unit == 0x0c ||
    unit == 0x0d ||
    unit == 0x85 ||
    unit == 0x2028 ||
    unit == 0x2029;

int _leadingLineBreakLength(String text) {
  if (text.startsWith('\r\n')) return 2;
  return text.isNotEmpty && _isLineBreak(text.codeUnitAt(0)) ? 1 : 0;
}

int _trailingLineBreakLength(String text) {
  if (text.endsWith('\r\n')) return 2;
  return text.isNotEmpty && _isLineBreak(text.codeUnitAt(text.length - 1))
      ? 1
      : 0;
}

// Treat a position between CR and LF as part of their one shared line ending.
int _beforeCrLf(String text, int offset) =>
    offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset - 1) == 0x0d &&
        text.codeUnitAt(offset) == 0x0a
    ? offset - 1
    : offset;

int _lineStart(String text, int offset) {
  var start = _beforeCrLf(text, offset);
  while (start > 0 && !_isLineBreak(text.codeUnitAt(start - 1))) {
    start--;
  }
  return start;
}

int _lineContentEnd(String text, int offset) {
  var end = _beforeCrLf(text, offset);
  while (end < text.length && !_isLineBreak(text.codeUnitAt(end))) {
    end++;
  }
  return end;
}

int _lineEnd(String text, int offset) {
  final end = _lineContentEnd(text, offset);
  if (end == text.length) return end;
  return end +
      (text.codeUnitAt(end) == 0x0d &&
              end + 1 < text.length &&
              text.codeUnitAt(end + 1) == 0x0a
          ? 2
          : 1);
}

class _MarkdownLine {
  const _MarkdownLine(this.content, this.ending);

  final String content, ending;
}

List<_MarkdownLine> _selectedLines(String source, int start, int end) {
  final lines = <_MarkdownLine>[];
  var offset = start;
  do {
    final contentEnd = _lineContentEnd(source, offset);
    final lineEnd = _lineEnd(source, offset);
    lines.add(
      _MarkdownLine(
        source.substring(offset, contentEnd),
        source.substring(contentEnd, lineEnd),
      ),
    );
    offset = lineEnd;
  } while (offset < end);
  return lines;
}
