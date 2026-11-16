import Foundation

/// A bounded, memory-only cache avoids reparsing every visible paragraph on view updates.
enum DeskMarkdownText {
    private final class Value: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = 512
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func inline(_ source: String) -> AttributedString {
        let key = source as NSString
        if let saved = cache.object(forKey: key) { return saved.text }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        // Large one-off code/report exports should not evict the visible paragraphs.
        if source.utf8.count <= 32_768 {
            cache.setObject(Value(text), forKey: key, cost: max(64, source.utf8.count * 8))
        }
        return text
    }

    static func removeAll() { cache.removeAllObjects() }
}
