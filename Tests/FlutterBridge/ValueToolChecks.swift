import Foundation
import WebKit

@MainActor
private final class ValueFixture {
    let suite = "cc.seekdesk.qa.value-tools." + UUID().uuidString
    let defaults: UserDefaults
    let context: SeekDeskBridgeContext
    let services: NativeForumServices

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in fatalError("No vault writes") },
            fetchSubscription: { _ in fatalError("No subscription networking") }, measureNode: { _ in fatalError("No proxy probes") })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: { fatalError("No feed networking") }, fetchPage: { _ in fatalError("No page networking") },
            fetchPeople: { _ in fatalError("No member networking") })
        var requests = NativeForumServices.Requests()
        requests.image = { _, _ in fatalError("No image networking") }
        requests.reader = { _, _, _, _ in fatalError("No reader networking") }
        requests.inbox = { _, _, _, _, _, _ in fatalError("No inbox networking") }
        requests.markRead = { _, _, _ in fatalError("No mark-read writes") }
        requests.profile = { _, _, _ in fatalError("No profile networking") }
        requests.readerAuthor = { _, _, _ in fatalError("No author networking") }
        requests.options = { _, _, _ in fatalError("No composer networking") }
        requests.preparePage = { _, _, _ in fatalError("No page preparation") }
        requests.prepareMessage = { _, _, _ in fatalError("No message preparation") }
        requests.sendMessage = { _, _, _, _ in fatalError("No message sends") }
        requests.refreshMessageUnread = { _ in fatalError("No unread refresh") }
        requests.sendReply = { _, _, _ in fatalError("No reply writes") }
        requests.publish = { _, _, _, _ in fatalError("No post publication") }
        requests.saveEdit = { _, _, _ in fatalError("No edit writes") }
        requests.uploadImage = { _, _ in fatalError("No image uploads") }
        requests.uploadClipboardImage = { _, _ in fatalError("No clipboard upload") }
        let keys = NativeForumServices.KeyStore(configured: { fatalError("No Keychain status query") }, read: { fatalError("No Keychain read") },
            save: { _ in fatalError("No Keychain write") }, remove: { fatalError("No Keychain removal") })
        services = NativeForumServices(context: context, requests: requests, keyStore: keys)
    }

    func calculate(_ args: [String: Any]) async throws -> [String: Any] {
        guard let result = try await services.handle("value.calculate", args) as? [String: Any] else {
            fatalError("Expected a value DTO")
        }
        precondition(JSONSerialization.isValidJSONObject(result), "Value DTO must remain JSON/Flutter-codec compatible")
        return result
    }

    func close() {
        services.dispose()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct ValueToolChecks {
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
    }
    private static func decimal(_ raw: Any?) -> Decimal {
        guard let text = raw as? String,
              let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN else {
            fatalError("Expected a finite decimal string, received \(String(describing: raw))")
        }
        return result
    }
    private static func stamp(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return date.timeIntervalSince1970 * 1000
    }
    private static func values(_ replacement: [String: Any] = [:]) -> [String: Any] {
        ["amount": "10.004", "cycle": 1, "asOf": stamp(2024, 1, 1), "expires": stamp(2024, 2, 1),
         "base": "USD", "quote": "USD", "rate": "1", "asking": "10.00"].merging(replacement) { _, new in new }
    }
    @MainActor
    private static func reject(_ fixture: ValueFixture, _ args: [String: Any], _ code: String, _ label: String) async throws {
        do { _ = try await fixture.calculate(args); fatalError("Accepted invalid input: \(label)") }
        catch let error as NativeBridgeError { check(error.code == code, "\(label): expected \(code), got \(error.code)") }
    }

    @MainActor
    static func main() async throws {
        // The calculation intentionally follows the local calendar like the
        // SwiftUI baseline. Make boundary cases deterministic without network.
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        let f = ValueFixture(); defer { f.close() }
        try await twoDecimalComparisons(f)
        try await zeroDecimalComparisons(f)
        try await conversionAndCompatibility(f)
        try await calendarBoundaries(f)
        try await invalidDates(f)
        try await invalidInputs(f)
        try await automaticRateRoundTrips(f)
        try await rateWireBoundaries(f)
        try await originalCurrencyFormatting(f)
        print("Passed all 9 native value-tool groups using pure arithmetic and memory-only dependencies.")
    }

    @MainActor
    private static func twoDecimalComparisons(_ f: ValueFixture) async throws {
        let cases: [(String, String, String, String, String)] = [
            // amount, asking, converted, difference, label
            ("10.004", "10.00", "10", "0", "与剩余价值一致"),
            ("10.00", "10.004", "10", "0", "与剩余价值一致"),
            ("10.004", "10.005", "10", "0.01", "高于剩余价值"),
            ("10.005", "10.004", "10.01", "-0.01", "低于剩余价值"),
            ("10.005", "10.005", "10.01", "0", "与剩余价值一致"),
            ("10.014", "10.006", "10.01", "0", "与剩余价值一致"),
            ("0", "0", "0", "0", "与剩余价值一致"),
        ]
        for code in ["USD", "CNY", "EUR", "HKD", "TWD"] {
            for (amount, asking, converted, difference, label) in cases {
                let result = try await f.calculate(values(["amount": amount, "asking": asking, "base": code, "quote": code]))
                check(decimal(result["converted"]) == decimal(converted), "\(code) converted rounding")
                let delta = decimal(result["difference"])
                check(delta == decimal(difference), "\(code) compare rounded asking and rounded estimate")
                check(result["differenceLabel"] as? String == label, "\(code) parity/direction follows displayed prices")
                check(result["differenceAmount"] as? String == ValueCurrency.money(delta < 0 ? -delta : delta, code), "Unsigned difference amount")
                if delta == 0 {
                    check(result["difference"] as? String == "0", "Zero must not retain a negative sign")
                    check(label == "与剩余价值一致", "Rounded zero cannot report high/low")
                }
            }
        }
        print("PASS two-decimal currencies, 10.004/10.00, positive/negative/equal comparisons")
    }

    @MainActor
    private static func zeroDecimalComparisons(_ f: ValueFixture) async throws {
        for code in ["JPY", "KRW", "VND", "CLP"] {
            for (amount, asking, expected, label) in [
                ("10.49", "10.4", "0", "与剩余价值一致"),
                ("10.4", "10.49", "0", "与剩余价值一致"),
                ("10.49", "10.5", "1", "高于剩余价值"),
                ("10.5", "10.49", "-1", "低于剩余价值"),
                ("10.5", "10.5", "0", "与剩余价值一致"),
            ] {
                let result = try await f.calculate(values(["amount": amount, "asking": asking, "base": code, "quote": code]))
                check(decimal(result["difference"]) == decimal(expected), "\(code) rounds both values to whole units")
                check(result["differenceLabel"] as? String == label, "\(code) direction")
                check((result["differenceAmount"] as? String)?.hasSuffix(" " + code) == true, "Target currency suffix")
            }
        }
        print("PASS all four zero-decimal currencies and half-unit boundaries")
    }

    @MainActor
    private static func conversionAndCompatibility(_ f: ValueFixture) async throws {
        let converted = try await f.calculate(values(["amount": "1.2505", "rate": "8", "base": "USD", "quote": "CNY"]))
        check(decimal(converted["amount"]) == decimal("1.2505"), "Original amount stays exact")
        check(decimal(converted["converted"]) == 10 && decimal(converted["difference"]) == 0, "Round only after conversion")
        check(converted["base"] as? String == "USD" && converted["quote"] as? String == "CNY", "Pair echoes supplied metadata")
        let originalOnly = try await f.calculate([
            "amount": "12", "cycle": 1, "asOf": stamp(2024, 1, 1), "expires": stamp(2024, 2, 1),
        ])
        check(decimal(originalOnly["amount"]) == 12, "Original-only request remains compatible")
        check(originalOnly["converted"] == nil && originalOnly["difference"] == nil, "No fabricated conversion or exchange rate")
        var legacy = values(["expires": Date().addingTimeInterval(10 * 86400).timeIntervalSince1970 * 1000])
        legacy.removeValue(forKey: "asOf"); legacy.removeValue(forKey: "base")
        let before = Date().timeIntervalSince1970 * 1000
        let result = try await f.calculate(legacy)
        let after = Date().timeIntervalSince1970 * 1000
        let actual = result["asOf"] as? Double ?? -.infinity
        check(actual >= before && actual <= after, "Omitted asOf uses the calculation's current Date")
        check(result["expires"] as? Double == legacy["expires"] as? Double, "Expiry echoes the calculation input")
        check(result["formatted"] is String, "Legacy omitted base still converts")
        var emptyAsking = values(["asking": ""])
        emptyAsking.removeValue(forKey: "rate")
        let empty = try await f.calculate(emptyAsking)
        check(empty["difference"] == nil, "Empty optional asking remains absent")
        print("PASS exact conversion, original-only result, optional fields and Date fallback")
    }

    @MainActor
    private static func calendarBoundaries(_ f: ValueFixture) async throws {
        let monthEnd = try await f.calculate(values([
            "amount": "31", "asOf": stamp(2024, 1, 31), "expires": stamp(2024, 3, 31),
        ]))
        check(monthEnd["days"] as? Int == 60, "Leap Jan31–Mar31 has 60 days")
        check(monthEnd["fullCycles"] as? Int == 1 && monthEnd["partialDays"] as? Int == 29 && monthEnd["partialCycleDays"] as? Int == 29,
              "Monthly boundaries stay anchored to March 31 through February 29")
        check(decimal(monthEnd["amount"]) == 62, "Two full anchored renewals")
        let leapPartial = try await f.calculate(values([
            "amount": "29", "asOf": stamp(2024, 2, 1), "expires": stamp(2024, 3, 31),
        ]))
        check(leapPartial["days"] as? Int == 59 && decimal(leapPartial["amount"]) == 57,
              "Leap partial: one full 29-unit cycle plus 28/29 of another")
        let nonLeap = try await f.calculate(values([
            "amount": "28", "asOf": stamp(2023, 1, 31), "expires": stamp(2023, 3, 31),
        ]))
        check(nonLeap["days"] as? Int == 59 && decimal(nonLeap["amount"]) == 56, "Non-leap month-end keeps original anchor")
        let leapYear = try await f.calculate(values([
            "amount": "366", "cycle": 12, "asOf": stamp(2023, 2, 28), "expires": stamp(2024, 2, 29),
        ]))
        check(leapYear["days"] as? Int == 366 && leapYear["partialCycleDays"] as? Int == 366 && decimal(leapYear["amount"]) == 366,
              "Annual leap-year denominator is actual calendar length")
        for cycle in RenewalCycle.allCases {
            let expiry = Date(timeIntervalSince1970: stamp(2028, 8, 31) / 1000)
            let start = Calendar.current.date(byAdding: .month, value: -cycle.rawValue, to: expiry)!
            let args = values(["amount": "120", "cycle": cycle.rawValue, "asOf": start.timeIntervalSince1970 * 1000,
                               "expires": expiry.timeIntervalSince1970 * 1000])
            let result = try await f.calculate(args)
            check(decimal(result["amount"]) == 120, "Every supported full renewal cycle returns one payment")
            check(result["asOf"] as? Double == args["asOf"] as? Double, "Explicit calculation date echoed")
        }
        for end in [stamp(2024, 1, 1, 3), stamp(2023, 12, 31)] {
            let expired = try await f.calculate(values(["asOf": stamp(2024, 1, 1, 23), "expires": end]))
            check(expired["days"] as? Int == 0 && decimal(expired["amount"]) == 0, "Same/past local day has no remaining value")
        }
        let morning = try await f.calculate(values(["asOf": stamp(2024, 1, 15, 1)]))
        let evening = try await f.calculate(values(["asOf": stamp(2024, 1, 15, 23)]))
        check(decimal(morning["amount"]) == decimal(evening["amount"]), "Calculation uses local days, not partial hours")
        print("PASS explicit asOf, month-end anchoring, leap-year denominator, all cycles and expired dates")
    }

    @MainActor
    private static func invalidDates(_ f: ValueFixture) async throws {
        for key in ["asOf", "expires"] {
            for invalid: Any in [true, "2024-01-01", NSNull(), Double.nan, Double.infinity, -Double.infinity,
                                 -62_135_596_800_001.0, 253_402_300_800_000.0] {
                try await reject(f, values([key: invalid]), "invalid_value", "\(key)=\(invalid)")
            }
        }
        var missing = values(); missing.removeValue(forKey: "expires")
        try await reject(f, missing, "invalid_value", "missing expiry")
        try await reject(f, values(["asOf": stamp(1800, 1, 1), "expires": stamp(2024, 1, 1)]), "invalid_value", "more than 1200 monthly cycles")
        let integerDates = try await f.calculate(values([
            "asOf": Int64(stamp(2024, 1, 1)), "expires": Int64(stamp(2024, 2, 1)),
        ]))
        check(integerDates["days"] as? Int == 31, "Finite integer milliseconds remain compatible")
        print("PASS date types/ranges, finite timestamps and bounded renewal horizon")
    }

    @MainActor
    private static func invalidInputs(_ f: ValueFixture) async throws {
        for key in ["base", "quote"] {
            for invalid: Any in ["BAD", "usd", "", 1, true, NSNull()] {
                try await reject(f, values([key: invalid]), "invalid_currency", "\(key)=\(invalid)")
            }
        }
        for invalid: Any in ["", "-1", "NaN", "1e3", " 10 ", "1,000", "1.0000000000001", String(repeating: "9", count: 33), 10, true, NSNull()] {
            try await reject(f, values(["amount": invalid]), "invalid_value", "amount=\(invalid)")
        }
        for invalid: Any in ["0", "", "-1", "NaN", "1e3", 1, true, NSNull()] {
            try await reject(f, values(["rate": invalid]), "invalid_rate", "rate=\(invalid)")
        }
        for invalid: Any in ["-1", "NaN", "not a number", 10, true, NSNull()] {
            try await reject(f, values(["asking": invalid]), "invalid_value", "asking=\(invalid)")
            var withoutRate = values(["asking": invalid]); withoutRate.removeValue(forKey: "rate")
            try await reject(f, withoutRate, "invalid_value", "invalid asking must not be silently skipped without a rate")
        }
        for cycle in [0, 2, 4, 120] {
            try await reject(f, values(["cycle": cycle]), "invalid_value", "unsupported renewal cycle")
        }
        for invalid: Any in [true, 1.5, "1", NSNull()] {
            try await reject(f, values(["cycle": invalid]), "invalid_arguments", "non-integer renewal cycle")
        }
        var missingQuote = values(); missingQuote.removeValue(forKey: "quote")
        try await reject(f, missingQuote, "invalid_rate", "conversion requires quote")
        var missingAmount = values(); missingAmount.removeValue(forKey: "amount")
        try await reject(f, missingAmount, "invalid_value", "missing amount")
        print("PASS supported currencies, exact decimal inputs, cycle types and optional input validation")
    }

    @MainActor
    private static func roundTripQuote(_ f: ValueFixture, _ quote: ValueExchangeQuote,
                                      pair: ValueCurrencyPair, amount: String = "7.25") async throws -> String {
        // Exercise the same mapper used by value.rate, then cross an actual
        // JSON encode/decode boundary before sending its wire to value.calculate.
        let response = try NativeValueRateWire.response(quote, pair: pair)
        let encoded = try JSONSerialization.data(withJSONObject: response)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        guard let wire = decoded["rate"] as? String else { fatalError("Missing rate wire") }
        check(wire.count <= 256 && !wire.lowercased().contains("e"), "Fixed-point rate fits the Flutter contract")
        check((wire.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0) <= 128 || !wire.contains("."),
              "At most 128 fractional places")
        check(NativeValueRateWire.parse(wire) == quote.rate, "Rate wire preserves the quote's full Decimal precision")
        check(decoded["base"] as? String == pair.base && decoded["quote"] as? String == pair.quote, "Quote retains its currency pair")
        check(decoded["source"] as? String == quote.source.name && decoded["asOf"] as? Double == quote.asOf.timeIntervalSince1970 * 1000,
              "Quote retains actual source and timestamp")
        let result = try await f.calculate(values([
            "amount": amount, "base": pair.base, "quote": pair.quote, "rate": wire,
        ]))
        let expected = ValueCurrency.rounded(decimal(amount) * quote.rate, pair.quote)
        check(decimal(result["converted"]) == expected, "Encoded rate calculates the original Decimal quote without a 12-place truncation")
        check(result["formatted"] as? String == ValueCurrency.money(decimal(amount) * quote.rate, pair.quote),
              "Displayed conversion uses the same exact rate")
        return wire
    }

    @MainActor
    private static func automaticRateRoundTrips(_ f: ValueFixture) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [[String: String]] = [
            ["currency": "USD/EUR", "bid": "3", "ask": "3", "timestamp": "1700000000000"],
            ["currency": "USD/CNY", "bid": "7.2", "ask": "7.2", "timestamp": "1700000000000"],
            ["currency": "USD/JPY", "bid": "5.5", "ask": "5.5", "timestamp": "1700000000000"],
        ]
        let market = try ValueMarketBook(data: JSONSerialization.data(withJSONObject: rows), now: now)
        let hourly = try JSONDecoder().decode(ValueHourlyBook.self, from: Data(#"{"base":"USD","timestamp":1700000000,"rates":{"EUR":3,"CNY":7.2,"JPY":5.5}}"#.utf8))
        var longQuotes = 0
        for pair in [ValueCurrencyPair(base: "EUR", quote: "USD"),
                     ValueCurrencyPair(base: "CNY", quote: "USD"),
                     ValueCurrencyPair(base: "EUR", quote: "JPY"),
                     ValueCurrencyPair(base: "JPY", quote: "CNY")] {
            for quote in [market.quote(pair), hourly.quote(pair, now: now)] {
                guard let quote else { fatalError("Expected pure-memory inverse or cross quote") }
                let wire = try await roundTripQuote(f, quote, pair: pair)
                if ValueNumber.wire(wire) == nil { longQuotes += 1 }
            }
        }
        check(longQuotes >= 4, "Regression inputs must actually exceed the old manual wire precision")
        print("PASS market/hourly inverse and cross rates through production DTO encode/decode and native calculation")
    }

    @MainActor
    private static func rateWireBoundaries(_ f: ValueFixture) async throws {
        for (text, expected) in [("0007.2500", "7.25"), ("1.", "1"), (".125", "0.125"),
                                 ("1.0000000000001", "1.0000000000001")] {
            check(NativeValueRateWire.parse(text) == decimal(expected), "Compatible fixed-point input: \(text)")
            check(NativeValueRateWire.encode(decimal(expected)) == expected, "Canonical fixed-point output")
        }
        check(ValueNumber.wire("1.0000000000001") == nil, "Manual amount/rate grammar remains limited to 12 places")
        for (value, expected) in [
            (decimal("1e-13"), "0." + String(repeating: "0", count: 12) + "1"),
            (decimal("1e-128"), "0." + String(repeating: "0", count: 127) + "1"),
            (decimal("1e127"), "1" + String(repeating: "0", count: 127)),
        ] {
            check(NativeValueRateWire.encode(value) == expected, "Representable extreme rates expand without scientific notation")
            check(NativeValueRateWire.parse(expected) == value && value > 0, "Small positive rates must not become zero")
            let quote = ValueExchangeQuote(rate: value, asOf: Date(timeIntervalSince1970: 1_700_000_000), source: .hourly)
            _ = try await roundTripQuote(f, quote, pair: .init(base: "USD", quote: "CNY"), amount: "1")
        }
        for invalid: Any in ["", "0", "0.000", "-0", "-1", "+1", ".", "NaN", "Infinity", "1e-13", "1E3",
                             "1,000", " 1", "1 ", "1\n", "1\u{200B}", "０.５",
                             "0." + String(repeating: "0", count: 128) + "1",
                             String(repeating: "0", count: 256) + "1",
                             "1" + String(repeating: "0", count: 200),
                             "0." + String(repeating: "1234567890", count: 8),
                             1, true, Double.nan, Double.infinity, NSNull()] {
            check(NativeValueRateWire.parse(invalid) == nil, "Reject invalid, inexact, overflowing or out-of-contract rate")
            try await reject(f, values(["rate": invalid]), "invalid_rate", "invalid rate wire")
        }
        for invalid in [Decimal(0), Decimal(-1), NSDecimalNumber.notANumber.decimalValue] {
            check(NativeValueRateWire.encode(invalid) == nil, "Encoder refuses non-positive or non-finite quotes")
            do {
                _ = try NativeValueRateWire.response(
                    .init(rate: invalid, asOf: Date(), source: .market), pair: .init(base: "USD", quote: "CNY"))
                fatalError("Invalid quote was encoded")
            } catch let failure as NativeBridgeError {
                check(failure.code == "invalid_rate", "Invalid quote reports an explicit rate failure")
            }
        }
        print("PASS 256-character/128-place fixed-point limits, exact roundtrip, extreme positive rates and invalid quote rejection")
    }

    @MainActor
    private static func originalCurrencyFormatting(_ f: ValueFixture) async throws {
        for base in ["USD", "JPY"] {
            let result = try await f.calculate(values([
                "amount": "1", "asOf": stamp(2024, 1, 15), "base": base, "quote": base,
            ]))
            let precise = decimal(result["amount"])
            check(precise == Decimal(17) / Decimal(31), "Exact original partial-cycle amount remains available")
            check(result["originalFormatted"] as? String == ValueCurrency.money(precise, base),
                  "Original display follows the base currency's monetary rounding")
            let expired = try await f.calculate(values([
                "asOf": stamp(2024, 3, 1), "base": base, "quote": base,
            ]))
            check(expired["originalFormatted"] as? String == ValueCurrency.money(0, base), "Expired original value formats as monetary zero")
        }
        var originalOnly = values(); originalOnly.removeValue(forKey: "rate")
        let result = try await f.calculate(originalOnly)
        check(result["originalFormatted"] as? String == ValueCurrency.money(decimal(result["amount"]), "USD"),
              "Missing exchange quote still has a readable original amount")
        originalOnly.removeValue(forKey: "base")
        let legacy = try await f.calculate(originalOnly)
        check(legacy["originalFormatted"] == nil && legacy["amount"] is String, "Omitted legacy base does not invent a currency")
        print("PASS originalFormatted for 0/2-decimal currencies, long exact fractions, expiry and original-only calculations")
    }
}
