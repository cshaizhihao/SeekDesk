import Foundation

/// Small, lightweight pages can finish laying out before the user starts scrolling.
/// Keep long pages and costly reports lazy, so a single page cannot mount an
/// unbounded number of editors, images, terminal reports or interaction controls.
enum ReaderLayoutPolicy {
    static let maximumFloors = 24
    static let maximumBlocks = 128
    static let maximumTextBytes = 48 * 1024

    static func preparesWholePage(_ thread: ForumThread) -> Bool {
        let floorCount = thread.replies.count + (thread.root == nil ? 0 : 1)
        guard floorCount <= maximumFloors else { return false }
        var blocks = 0
        var bytes = 0
        func accepts(_ floor: ForumFloor) -> Bool {
            bytes += floor.author.utf8.count + (floor.signature?.utf8.count ?? 0)
            for block in floor.blocks {
                blocks += 1
                // Complex exports retain their own lazy content and normal first-use loading.
                guard ["text", "heading", "quote", "notice", "rule", "sticker"].contains(block.kind),
                      block.tabs == nil, block.rows == nil, block.terminal == nil else { return false }
                bytes += block.text.utf8.count
                guard blocks <= maximumBlocks, bytes <= maximumTextBytes else { return false }
            }
            return bytes <= maximumTextBytes
        }
        if let root = thread.root, !accepts(root) { return false }
        for floor in thread.replies where !accepts(floor) { return false }
        return true
    }
}
