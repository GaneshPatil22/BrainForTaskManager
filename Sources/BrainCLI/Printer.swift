import BrainCore
import Foundation

enum Printer {
    /// Pads to a fixed width without bridging to NSString.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? String(text.prefix(width))
            : text + String(repeating: " ", count: width - text.count)
    }

    static func render(
        outputs: BrainOutputs, issues: [DumpFormat.ParseIssue],
        showAll: Bool, timeZone: TimeZone
    ) {
        if !issues.isEmpty {
            print("ISSUES")
            for issue in issues { print("  line \(issue.line): \(issue.message)") }
            print("")
        }

        print("NEXT")
        if let next = outputs.next {
            print("  \(next.item.title)")
            print("  \(next.reason)")
            print(String(format: "  leverage %.3f", next.breakdown.leverage))
        } else if outputs.ranked.isEmpty {
            print("  nothing open")
        } else {
            print("  nothing startable — everything open is blocked")
        }

        let blockedIds = Set(outputs.blocked.map(\.item.id))
        let shown = showAll ? outputs.ranked : Array(outputs.ranked.prefix(8))
        if shown.count > 1 {
            let suffix = showAll ? "" : " (top \(shown.count) of \(outputs.ranked.count))"
            print("\nRANKED\(suffix)")
            for (index, entry) in shown.enumerated() {
                // A blocked item can rank high and still not be actionable.
                let marker = blockedIds.contains(entry.item.id) ? "⊘" : " "
                print(
                    String(
                        format: "  %2d.%@ %@ %6.3f  %@",
                        index + 1, marker, pad(entry.item.title, 38),
                        entry.breakdown.leverage, entry.reason))
            }
            if !outputs.blocked.isEmpty { print("     ⊘ = blocked, cannot start yet") }
        }

        if !outputs.quickWins.isEmpty {
            print("\nQUICK WINS")
            for entry in outputs.quickWins {
                print(
                    String(
                        format: "  %@ %6.3f  %@", pad(entry.item.title, 38),
                        entry.breakdown.leverage, entry.reason))
            }
        }

        if !outputs.blocked.isEmpty {
            print("\nBLOCKED")
            for entry in outputs.blocked {
                print("  \(entry.item.title)")
                print("    waiting on: \(entry.blockers.map(\.title).joined(separator: ", "))")
            }
        }
    }
}
