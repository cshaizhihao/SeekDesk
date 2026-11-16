import Foundation

/// Automatic quotes can contain the full precision of Decimal division. Keep
/// their transport independent from the 12-place manual amount/rate editor.
/// Flutter accepts the same fixed-point grammar and uses the received string
/// unchanged for calculation and copying: <=256 characters, <=128 places.
enum NativeValueRateWire {
    static let maximumLength = 256
    static let maximumFractionDigits = 128
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let pattern = #"^(?:[0-9]+(?:\.[0-9]{0,128})?|\.[0-9]{1,128})$"#

    static func parse(_ raw: Any?) -> Decimal? {
        guard let text = raw as? String, validSyntax(text) else { return nil }
        let normalized = canonical(text)
        guard let value = Decimal(string: normalized, locale: locale),
              !value.isNaN, value > 0,
              encode(value) == normalized else { return nil }
        // Decimal(string:) can round excessive significant digits or underflow.
        // Exact round-tripping rejects that instead of calculating another rate.
        return value
    }

    static func encode(_ value: Decimal) -> String? {
        guard !value.isNaN, value > 0 else { return nil }
        let raw = NSDecimalNumber(decimal: value).stringValue
        let pieces = raw.components(separatedBy: CharacterSet(charactersIn: "eE"))
        guard pieces.count <= 2, let mantissa = pieces.first else { return nil }
        let expanded: String
        if pieces.count == 1 {
            expanded = mantissa
        } else {
            guard let exponent = Int(pieces[1]), (-256...256).contains(exponent) else { return nil }
            let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            let whole = String(parts[0]), fraction = parts.count == 2 ? String(parts[1]) : ""
            let digits = whole + fraction
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            let point = whole.count + exponent
            if point <= 0 {
                expanded = "0." + String(repeating: "0", count: -point) + digits
            } else if point >= digits.count {
                expanded = digits + String(repeating: "0", count: point - digits.count)
            } else {
                let offset = digits.index(digits.startIndex, offsetBy: point)
                expanded = String(digits[..<offset]) + "." + String(digits[offset...])
            }
        }
        guard validSyntax(expanded) else { return nil }
        let result = canonical(expanded)
        return result == "0" ? nil : result
    }

    /// This is the production value.rate mapping as well as the pure-memory
    /// boundary used by inverse/cross-quote integration checks.
    static func response(_ value: ValueExchangeQuote, pair: ValueCurrencyPair) throws -> [String: Any] {
        guard let rate = encode(value.rate) else {
            throw NativeBridgeError(code: "invalid_rate", message: "未取得有效汇率，请刷新或手动填写。")
        }
        return ["rate": rate, "base": pair.base, "quote": pair.quote,
                "source": value.source.name, "caption": value.caption(),
                "asOf": value.asOf.timeIntervalSince1970 * 1000]
    }

    private static func validSyntax(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumLength else { return false }
        return text.range(of: pattern, options: .regularExpression) == (text.startIndex..<text.endIndex)
    }

    /// Called only after fixed-point syntax validation. Preserve all significant
    /// digits; remove redundant zeroes, not numerical precision.
    private static func canonical(_ text: String) -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let leading = String(parts[0].drop(while: { $0 == "0" }))
        let whole = leading.isEmpty ? "0" : leading
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }
}
