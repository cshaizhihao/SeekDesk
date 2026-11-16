import Foundation

/// Static report semantics, not a VT emulator: SGR, BS, CR, CRLF/LF and HT.
/// Width policy is CJK/fullwidth and emoji = 2, ambiguous = 1, graphemes intact.
@main
enum TerminalANSIChecks {
    private static let esc = "\u{001B}["
    private static let red = "rgb(224,108,117)"
    private static let green = "rgb(152,195,121)"
    private static let blue = "rgb(97,175,239)"

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    private static func text(_ input: String) -> [String] {
        ForumTerminalANSI.lines(input).map { $0.map(\.text).joined() }
    }

    private static func span(_ text: String, foreground: String? = nil,
                             background: String? = nil, bold: Bool = false) -> ForumTerminalSpan {
        ForumTerminalSpan(text: text, foreground: foreground, background: background, bold: bold)
    }

    static func main() {
        let gb5 = "单核: \u{0008}|430 多核: \u{0008}|1258"
        check(text(gb5) == ["单核:|430 多核:|1258"], "GB5 must overwrite the preceding space, not merely strip BS")
        check(text("ABCDE\u{0008}\u{0008}\u{0008}XYZ") == ["ABXYZ"], "Backspace must move one column")
        check(text("\u{0008}\u{0008}A") == ["A"], "Backspace must clamp at column zero")
        check(text("AB\u{0008}") == ["AB"], "Backspace alone must not erase a cell")
        print("PASS GB5 cursor overwrite, repeated BS and column-zero clamping")

        let styled = esc + "1;31;44mAB" + esc + "32m\u{0008}X" + esc + "0mZ"
        check(ForumTerminalANSI.lines(styled)[0] == [
            span("A", foreground: red, background: blue, bold: true),
            span("X", foreground: green, background: blue, bold: true), span("Z")
        ], "Overwrite across SGR spans must retain surviving and replacement styles")
        let extended = esc + "38;2;12;34;56;48;5;196mAB" + esc + "38:2::6:7:8m\u{0008}Z"
        check(ForumTerminalANSI.lines(extended)[0] == [
            span("A", foreground: "rgb(12,34,56)", background: "rgb(255,0,0)"),
            span("Z", foreground: "rgb(6,7,8)", background: "rgb(255,0,0)")
        ], "Truecolor, colon syntax and indexed backgrounds must survive composition")
        print("PASS cross-span foreground, background, bold and extended SGR styles")

        check(text("12345\rAB") == ["AB345"], "CR must retain the unoverwritten suffix")
        check(text("ABCDE\r12\u{0008}X") == ["1XCDE"], "CR and BS must share the same cursor")
        let coloredCR = esc + "31mABC\r" + esc + "32mXY"
        check(ForumTerminalANSI.lines(coloredCR)[0] == [span("XY", foreground: green), span("C", foreground: red)],
              "CR replacement must not recolor untouched cells")
        let crlf = ForumTerminalANSI.lines(esc + "31mA\r\nB\nC\r\n")
        check(crlf.count == 4 && crlf[0] == [span("A", foreground: red)] &&
              crlf[1] == [span("B", foreground: red)] && crlf[2] == [span("C", foreground: red)] && crlf[3].isEmpty,
              "CRLF must be a line break, retain SGR state, and preserve the final empty line")
        check(text("A\rB\nC\rD") == ["B", "D"], "Bare CR must remain an inline operation on each line")
        print("PASS CR overwrite, CRLF normalization and color state across lines")

        for (input, expected) in [
            ("中\u{0008}A", " A"), ("中\u{0008}\u{0008}A", "A "),
            ("中x\rA", "A x"), ("ab\r中", "中"), ("abc\r中", "中c"),
            ("Ａ\u{0008}X", " X"), ("·\u{0008}X", "X")
        ] {
            check(text(input) == [expected], "Wide-cell overwrite failed: \(input.debugDescription)")
        }
        let wideStyle = esc + "31m中" + esc + "32;44m\u{0008}X"
        check(ForumTerminalANSI.lines(wideStyle)[0] == [span(" X", foreground: green, background: blue)],
              "Erasing half of a wide glyph must clear both cells using the replacement style")
        print("PASS Chinese/fullwidth cells, partial wide overwrites and ambiguous-width policy")

        check(text("e\u{0301}\u{0008}X") == ["X"], "A combining grapheme must occupy one column")
        let combined = esc + "31me" + esc + "32m\u{0301}" + esc + "0mZ\u{0008}X"
        check(ForumTerminalANSI.lines(combined)[0] == [span("e\u{0301}", foreground: red), span("X")],
              "An SGR boundary inside a grapheme must retain the base glyph's style and width")
        check(text("👩‍💻\u{0008}X") == [" X"], "A ZWJ emoji must occupy two columns, not its scalar count")
        check(text("🇨🇳\u{0008}X") == [" X"], "A flag grapheme must occupy two columns")
        check(text("❤️\u{0008}X") == [" X"], "Emoji variation presentation must occupy two columns")
        check(text("❤︎\u{0008}X") == ["X"], "Text variation presentation must occupy one column")
        let joinedEmoji = esc + "31m👩" + esc + "32m‍💻" + esc + "0mZ\u{0008}X"
        check(ForumTerminalANSI.lines(joinedEmoji)[0] == [span("👩‍💻", foreground: red), span("X")],
              "A ZWJ grapheme split by SGR must remain one glyph with the base style")
        print("PASS combining marks, cross-style graphemes, emoji ZWJ, flags and presentation selectors")

        check(text("a\tb\u{0008}X") == ["a       X"], "HT must advance to an eight-column stop")
        check(text("\t\u{0008}X") == ["       X"], "Backspace after HT must address a real column")
        check(text("ab\r\tX") == ["ab      X"], "HT must not erase existing cells")
        let controls = ForumTerminalANSI.lines(gb5 + "\r\nA\tB\rC").flatMap { $0 }.map(\.text).joined()
        check(!controls.unicodeScalars.contains { [8, 9, 13].contains($0.value) }, "Handled controls must never reach the painter")
        print("PASS tabs and absence of handled control glyphs in rendered spans")

        for prefix in [esc, #"\x1b["#, #"\u001b["#, #"\033["#, "["] {
            check(ForumTerminalANSI.lines(prefix + "31mRED" + prefix + "0m!")[0] == [span("RED", foreground: red), span("!")],
                  "Existing printed/raw SGR input support must remain intact")
        }
        let longLine = String(repeating: "x", count: 250_001)
        check(text(longLine) == [longLine], "Ordinary long reports must retain the complete fast path")
        let report = (0..<1500).map { "row \($0) 中文" }.joined(separator: "\n")
        check(text(report).joined(separator: "\n") == report, "Multi-line reports must not lose rows")
        let overwriteLong = String(repeating: "x", count: 20_000)
        check(text(overwriteLong + "\rA") == ["A" + String(overwriteLong.dropFirst())], "Control composition must preserve long untouched tails")
        print("PASS existing SGR encodings, long ordinary rows and complete static reports")
        print("Passed all terminal ANSI static-report checks.")
    }
}
