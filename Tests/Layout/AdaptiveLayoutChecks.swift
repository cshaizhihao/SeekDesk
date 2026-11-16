import Foundation

@main
struct AdaptiveLayoutChecks {
    static func main() {
        precondition(!DeskComposerLayout.allowsComparison(width: 500, height: 80))
        precondition(!DeskComposerLayout.allowsComparison(width: 500, height: 220))
        precondition(DeskComposerLayout.allowsComparison(width: 500, height: 221))
        precondition(!DeskComposerLayout.allowsComparison(width: 620, height: 109))
        precondition(DeskComposerLayout.allowsComparison(width: 620, height: 110))
        precondition(!DeskComposerLayout.allowsComparison(width: 0, height: 1000))
        precondition(!DeskComposerLayout.allowsComparison(width: .nan, height: 1000))
        precondition(!DeskMessageLayout.usesColumns(width: 759))
        precondition(DeskMessageLayout.usesColumns(width: 760))

        for height in stride(from: 0, through: 1200, by: 5) {
            for hasStatus in [false, true] {
                let layout = DeskMessageLayout(height: CGFloat(height), hasStatus: hasStatus)
                precondition(layout.editorHeight >= 0 && layout.editorHeight <= 260)
                precondition(layout.historyReserve >= 0)
                let used = layout.headerHeight + layout.accessoryHeight + layout.editorHeight + layout.historyReserve
                if CGFloat(height) >= layout.headerHeight + layout.accessoryHeight {
                    precondition(used <= CGFloat(height) + 0.001, "Editor must leave its reserved history visible at height \(height)")
                } else {
                    precondition(layout.editorHeight == 0 && layout.historyReserve == 0)
                }
                if height >= 250 { precondition(layout.historyReserve >= 45) }
            }
        }
        let short = DeskMessageLayout(height: 250, hasStatus: false)
        precondition(short.compact && short.editorHeight >= 110 && short.historyReserve >= 45)
        let tall = DeskMessageLayout(height: 800, hasStatus: false)
        precondition(!tall.compact && tall.editorHeight == 260 && tall.historyReserve == 140)
        print("Passed actual editor split thresholds, narrow inbox columns and short-window message budgets.")
    }
}
