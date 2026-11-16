import Foundation

enum ForumFloorDraft {
    static func insertion(for floor: ForumFloor, in page: URL, quoting: Bool, after draft: String) -> String? {
        guard let number = Int(floor.id), number >= 0, Forum.topicID(page) != nil,
              var link = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        link.fragment = String(number)
        guard let url = link.url else { return nil }
        let name = floor.author.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let heading = (name.isEmpty ? "" : "@\(name) ") + "[#\(number)](\(url.absoluteString))"
        let gap = draft.isEmpty || draft.hasSuffix("\n\n") ? "" : draft.hasSuffix("\n") ? "\n" : "\n\n"
        if !quoting { return gap + heading + "\n\n" }
        let original = excerpt(floor.blocks).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "> " + heading
        guard !original.isEmpty else { return gap + prefix + "\n\n" }
        let limited = String(original.prefix(1600))
        let lines = limited.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "> " + $0 }
        return gap + prefix + "\n>\n" + lines.joined(separator: "\n") + (original.count > 1600 ? "…" : "") + "\n\n"
    }

    private static func excerpt(_ blocks: [ForumBlock]) -> String {
        var remaining = 20
        func collect(_ blocks: [ForumBlock]) -> String {
            var parts: [String] = []
            for block in blocks {
                guard remaining > 0 else { break }
                remaining -= 1
                switch block.kind {
                case "text", "heading", "quote", "code": parts.append(block.text)
                case "image": parts.append("[图片]")
                case "terminal", "terminalUnavailable": parts.append("[测评终端]")
                case "tabs":
                    if let first = block.tabs?.first { parts.append(collect(first.blocks)) }
                case "list":
                    for item in block.items ?? [] {
                        guard remaining > 0 else { break }
                        if item.blocks.isEmpty { remaining -= 1 }
                        let text = collect(item.blocks)
                        let indent = String(repeating: " ", count: item.marker.count + 1)
                        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                        parts.append(item.marker + (text.isEmpty ? "" : " " + lines.joined(separator: "\n" + indent)))
                    }
                default: break
                }
            }
            return parts.joined(separator: "\n")
        }
        return collect(blocks)
    }
}

enum MarkdownCommand: String, CaseIterable {
    case bold, italic, strike, heading, quote, bullets, numbers, code, link, image, codeBlock, table, divider

    struct Edit {
        let replaced: NSRange
        let text: String
        let selected: NSRange
    }

    func edit(source: String, selection: NSRange) -> Edit? {
        let source = source as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= source.length, selection.length <= source.length - selection.location else { return nil }
        let selected = source.substring(with: selection)
        func wrap(_ start: String, _ end: String, placeholder: String) -> Edit {
            let contents = selected.isEmpty ? placeholder : selected
            return Edit(replaced: selection, text: start + contents + end,
                selected: NSRange(location: selection.location + start.utf16.count, length: contents.utf16.count))
        }
        func toggle(_ marker: String, placeholder: String) -> Edit {
            let width = marker.utf16.count
            func eligible(_ value: String) -> Bool {
                // A pair of asterisks is bold, not an italic wrapper. With
                // three, removing italic must preserve the bold pair.
                marker != "*" || value.prefix(while: { $0 == "*" }).count % 2 == 1
            }
            if selection.length >= width * 2, selected.hasPrefix(marker), selected.hasSuffix(marker),
               eligible(selected), eligible(String(selected.reversed())) {
                let contents = (selected as NSString).substring(with: NSRange(location: width, length: selection.length - width * 2))
                return Edit(replaced: selection, text: contents,
                            selected: NSRange(location: selection.location, length: contents.utf16.count))
            }
            let before = source.substring(to: selection.location)
            let after = source.substring(from: NSMaxRange(selection))
            if before.hasSuffix(marker), after.hasPrefix(marker),
               eligible(String(before.reversed())), eligible(after) {
                return Edit(replaced: NSRange(location: selection.location - width, length: selection.length + width * 2),
                            text: selected, selected: NSRange(location: selection.location - width, length: selection.length))
            }
            return wrap(marker, marker, placeholder: placeholder)
        }
        switch self {
        case .bold: return toggle("**", placeholder: "加粗文字")
        case .italic: return toggle("*", placeholder: "斜体文字")
        case .strike: return toggle("~~", placeholder: "划线文字")
        case .link, .image:
            let label = (selected.isEmpty ? (self == .link ? "链接文字" : "图片说明") : selected)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "\n", with: " ")
            let start = "\(self == .image ? "!" : "")[\(label)]("
            let placeholder = "https://"
            return Edit(replaced: selection, text: start + placeholder + ")",
                selected: NSRange(location: selection.location + start.utf16.count, length: placeholder.utf16.count))
        case .divider:
            return wrap("", "\n\n---\n\n", placeholder: "")
        case .table:
            return wrap("\n\n| ", " | 标题 2 |\n| --- | --- |\n| 内容 1 | 内容 2 |\n\n", placeholder: "标题 1")
        case .code, .codeBlock:
            if let unwrapped = unwrapCode(source: source, selection: selection, selected: selected) { return unwrapped }
            let longest = selected.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            if self == .codeBlock || selected.contains(where: \.isNewline) {
                let fence = String(repeating: "`", count: max(3, longest + 1))
                let hasStart = selection.location == 0 || source.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\n"
                let hasEnd = NSMaxRange(selection) == source.length || source.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) == "\n"
                return wrap((hasStart ? "" : "\n") + fence + "\n", "\n" + fence + (hasEnd ? "" : "\n"), placeholder: "代码")
            }
            let fence = String(repeating: "`", count: longest + 1)
            let needsPadding = selected.first == "`" || selected.last == "`" ||
                (selected.first == " " && selected.last == " " && selected.contains(where: { $0 != " " }))
            return needsPadding
                ? wrap(fence + " ", " " + fence, placeholder: "代码")
                : wrap(fence, fence, placeholder: "代码")
        case .heading, .quote, .bullets, .numbers:
            let lines = MarkdownLineSelection.range(in: source, selection: selection)
            let lineText = source.substring(with: lines)
            var components = lineText.components(separatedBy: "\n")
            let finalNewline = components.count > 1 && components.last == ""
            if finalNewline { components.removeLast() }
            if components == [""] {
                let placeholder = self == .quote ? "引用文字" : self == .heading ? "标题" : "列表项"
                return wrap(prefix(0), "", placeholder: placeholder)
            }
            let markers = components.map { linePrefix(in: $0) }
            let removes = markers.allSatisfy { $0?.matches == true }
            let replacement = components.enumerated().map { index, line in
                let original = line as NSString
                if let marker = markers[index] {
                    return original.replacingCharacters(in: marker.range, with: removes ? "" : prefix(index))
                }
                let indentation = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                return original.replacingCharacters(in: NSRange(location: indentation, length: 0), with: prefix(index))
            }.joined(separator: "\n")
            return Edit(replaced: lines, text: replacement + (finalNewline ? "\n" : ""),
                selected: NSRange(location: lines.location, length: replacement.utf16.count))
        }
    }

    private func linePrefix(in line: String) -> (range: NSRange, matches: Bool)? {
        let pattern: String
        switch self {
        case .heading: pattern = #"^[ \t]*(#{1,6}[ \t]+)"#
        case .quote: pattern = #"^[ \t]*(>[ \t]?)"#
        default: pattern = #"^[ \t]*([-+*][ \t]+|[0-9]{1,9}[.)][ \t]+)"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return nil }
        let range = match.range(at: 1)
        let prefix = (line as NSString).substring(with: range)
        let matches: Bool
        switch self {
        case .heading: matches = prefix.hasPrefix("## ") || prefix.hasPrefix("##\t")
        case .quote: matches = true
        case .bullets: matches = prefix.first.map { "-+*".contains($0) } ?? false
        default: matches = prefix.first?.isNumber == true
        }
        return (range, matches)
    }

    private func unwrapCode(source: NSString, selection: NSRange, selected: String) -> Edit? {
        let before = source.substring(to: selection.location)
        let after = source.substring(from: NSMaxRange(selection))
        if self == .code, !selected.contains(where: \.isNewline) {
            if before.hasSuffix(" "), after.hasPrefix(" ") {
                let left = before.dropLast().reversed().prefix(while: { $0 == "`" }).count
                let right = after.dropFirst().prefix(while: { $0 == "`" }).count
                if left > 0, left == right {
                    return Edit(replaced: NSRange(location: selection.location - left - 1, length: selection.length + left + right + 2),
                                text: selected, selected: NSRange(location: selection.location - left - 1, length: selection.length))
                }
            }
            let left = before.reversed().prefix(while: { $0 == "`" }).count
            let right = after.prefix(while: { $0 == "`" }).count
            if left > 0, left == right {
                return Edit(replaced: NSRange(location: selection.location - left, length: selection.length + left + right),
                            text: selected, selected: NSRange(location: selection.location - left, length: selection.length))
            }
            let opening = selected.prefix(while: { $0 == "`" }).count
            let closing = selected.reversed().prefix(while: { $0 == "`" }).count
            if opening > 0, opening == closing, selection.length > opening + closing {
                let value = (selected as NSString).substring(with: NSRange(location: opening, length: selection.length - opening - closing))
                return Edit(replaced: selection, text: value, selected: NSRange(location: selection.location, length: value.utf16.count))
            }
        }
        // A toolbar-created fenced block keeps the original content selected.
        // Keep surrounding paragraph breaks when removing its fence.
        if before.hasSuffix("\n"), after.hasPrefix("\n") {
            let opening = before.dropLast().split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            let closing = after.dropFirst().split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            if opening.count >= 3, opening.allSatisfy({ $0 == "`" }), closing == opening {
                let width = opening.utf16.count + 1
                return Edit(replaced: NSRange(location: selection.location - width, length: selection.length + width * 2),
                            text: selected, selected: NSRange(location: selection.location - width, length: selection.length))
            }
        }
        return nil
    }

    private func prefix(_ index: Int) -> String {
        switch self {
        case .heading: "## "
        case .quote: "> "
        case .numbers: "\(index + 1). "
        default: "- "
        }
    }
}

private enum MarkdownLineSelection {
    static func range(in source: NSString, selection: NSRange) -> NSRange {
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
        guard selection.length > 0 else { return first }
        // Ask for the line containing the final selected UTF-16 code unit,
        // rather than shortening the range and accidentally dropping that unit.
        let last = source.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 1))
        return NSUnionRange(first, last)
    }
}

/// Structural edits for explicit Return/Tab commands. Ordinary typing never
/// scans the document or runs a Markdown parser.
enum MarkdownTypingCommand {
    case newline, indent, outdent

    private static let list = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*]|([0-9]{1,9})([.)]))([ \t]+)(?:\[([ xX])\]([ \t]+))?"#)
    private static let indentation = "    "

    func edit(source: String, selection: NSRange) -> MarkdownCommand.Edit? {
        let text = source as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location else { return nil }
        switch self {
        case .newline: return continuedList(in: text, selection: selection)
        case .indent, .outdent: return indentation(in: text, selection: selection)
        }
    }

    private func continuedList(in source: NSString, selection: NSRange) -> MarkdownCommand.Edit? {
        guard selection.length == 0 else { return nil }
        let lineRange = source.lineRange(for: selection)
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
        guard let match = Self.list.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              selection.location >= lineRange.location + match.range.length,
              !Self.insideFence(source.substring(to: lineRange.location)) else { return nil }
        let contents = line.substring(from: match.range.length)
        if contents.trimmingCharacters(in: .whitespaces).isEmpty {
            return MarkdownCommand.Edit(replaced: NSRange(location: lineRange.location, length: line.length),
                                        text: "", selected: NSRange(location: lineRange.location, length: 0))
        }
        let indentation = line.substring(with: match.range(at: 1))
        var marker = line.substring(with: match.range(at: 2))
        if match.range(at: 3).location != NSNotFound,
           let number = Int(line.substring(with: match.range(at: 3))) {
            marker = "\(min(999_999_999, number + 1))" + line.substring(with: match.range(at: 4))
        }
        let checkbox = match.range(at: 6).location == NSNotFound ? "" : "[ ] "
        let value = "\n" + indentation + marker + " " + checkbox
        return MarkdownCommand.Edit(replaced: selection, text: value,
                                    selected: NSRange(location: selection.location + value.utf16.count, length: 0))
    }

    private func indentation(in source: NSString, selection: NSRange) -> MarkdownCommand.Edit? {
        let selectedLines = MarkdownLineSelection.range(in: source, selection: selection)
        let firstLine = source.substring(with: selectedLines) as NSString
        let firstLinePrefix = firstLine.substring(to: selection.location - selectedLines.location)
        if self == .indent, selection.length == 0,
           !firstLinePrefix.allSatisfy({ $0 == " " || $0 == "\t" }),
           Self.list.firstMatch(in: firstLine as String, range: NSRange(location: 0, length: firstLine.length)) == nil {
            return MarkdownCommand.Edit(replaced: selection, text: Self.indentation,
                                        selected: NSRange(location: selection.location + 4, length: 0))
        }

        // Preserve precisely the selected text, including UTF-16 offsets. The
        // last, unselected line must not move when selection ends at its start.
        var replacement = ""
        var newStart = selection.location
        var newEnd = NSMaxRange(selection)
        var location = selectedLines.location
        repeat {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: range)
            let removed: Int
            let added: Int
            if self == .indent {
                replacement += Self.indentation + line
                removed = 0; added = 4
            } else {
                removed = line.hasPrefix("\t") ? 1 : min(4, line.prefix(while: { $0 == " " }).count)
                replacement += (line as NSString).substring(from: removed)
                added = 0
            }
            if location <= selection.location {
                newStart += added - min(removed, selection.location - location)
            }
            if location < NSMaxRange(selection) || selection.length == 0 {
                newEnd += added - min(removed, NSMaxRange(selection) - location)
            }
            location = NSMaxRange(range)
            if range.length == 0 { break }
        } while location < NSMaxRange(selectedLines)
        guard replacement != source.substring(with: selectedLines) else { return nil }
        return MarkdownCommand.Edit(replaced: selectedLines, text: replacement,
                                    selected: NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    private static func insideFence(_ prefix: String) -> Bool {
        var fence: (character: Character, count: Int)?
        for raw in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
            let leading = raw.prefix(while: { $0 == " " }).count
            guard leading <= 3 else { continue }
            let line = raw.dropFirst(leading)
            guard let first = line.first, first == "`" || first == "~" else { continue }
            let count = line.prefix(while: { $0 == first }).count
            guard count >= 3 else { continue }
            if let current = fence {
                if first == current.character, count >= current.count,
                   line.dropFirst(count).allSatisfy({ $0.isWhitespace }) { fence = nil }
            } else { fence = (first, count) }
        }
        return fence != nil
    }
}
