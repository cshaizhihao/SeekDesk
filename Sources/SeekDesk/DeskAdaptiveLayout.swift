import Foundation

enum DeskComposerLayout {
    static let sideBySideWidth: CGFloat = 620
    private static let comparisonColumnHeight: CGFloat = 110

    static func allowsComparison(width: CGFloat, height: CGFloat) -> Bool {
        guard width.isFinite, height.isFinite else { return false }
        let neededHeight = width >= sideBySideWidth ? comparisonColumnHeight : comparisonColumnHeight * 2 + 1
        return width > 0 && height >= neededHeight
    }
}

/// Budget the complete private-message detail, rather than giving its editor a
/// fixed minimum that can consume the entire history in a short window.
struct DeskMessageLayout {
    let compact: Bool
    let headerHeight: CGFloat
    let editorHeight: CGFloat
    let historyReserve: CGFloat
    let accessoryHeight: CGFloat

    init(height: CGFloat, hasStatus: Bool) {
        let height = height.isFinite ? max(0, height) : 0
        compact = height < 420
        headerHeight = compact ? 40 : 74
        accessoryHeight = (compact ? 54 : 68) + (hasStatus ? 52 : 0) + 1
        let remaining = max(0, height - headerHeight - accessoryHeight)
        historyReserve = min(remaining, min(140, max(40, height * 0.18)))
        editorHeight = min(260, max(0, remaining - historyReserve))
    }

    static func usesColumns(width: CGFloat) -> Bool { width >= 760 }
}
