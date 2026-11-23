import ArgumentParser
import BrainCore
import Foundation

/// Measures how much a human disagrees with their own earlier ranking.
///
/// This number is the **ceiling on any model's achievable agreement**. If the
/// same person picks a different top task 25% of the time, no model can exceed
/// ~75%, and a ≥90% target is fiction (`docs/12-backlog.md` B-03a).
///
/// Nobody can supply this except a human ranking the same scenarios twice, so
/// it is worth the ten minutes it costs.
struct AgreementCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agreement",
        abstract: "Compare first and second ranking passes to find the noise floor.")

    @Option(name: .long, help: "Scenario directory.")
    var dir: String = "datasets/scenarios"

    func run() throws {
        let loaded = try ScenarioLoader.loadAll(in: URL(fileURLWithPath: dir))
        let paired = loaded.compactMap { scenario -> (String, [String], [String])? in
            guard let first = scenario.file.expected?.rankingTop3,
                let second = scenario.file.secondPass?.rankingTop3
            else { return nil }
            return (scenario.file.id, first, second)
        }

        guard !paired.isEmpty else {
            print(
                """
                No second-pass rankings yet.

                Rank some scenarios a second time, on a different day:
                    swift run brain rank --again

                That gives the noise floor — the ceiling on what any model can
                achieve. See docs/12-backlog.md, B-03a.
                """)
            return
        }

        var top1Same = 0
        var top3OverlapTotal = 0
        var exactOrderSame = 0

        for (_, first, second) in paired {
            if first.first == second.first { top1Same += 1 }
            if first == second { exactOrderSame += 1 }
            top3OverlapTotal += Set(first).intersection(Set(second)).count
        }

        let n = Double(paired.count)
        let top1 = Double(top1Same) / n
        let exact = Double(exactOrderSame) / n
        // Average overlap as a fraction of the smaller pick count per scenario.
        let maxOverlap = paired.reduce(0) { $0 + min($1.1.count, $1.2.count) }
        let overlap = Double(top3OverlapTotal) / Double(max(maxOverlap, 1))

        print(
            """

            SELF-AGREEMENT  (\(paired.count) scenarios ranked twice)

              same #1 pick            \(pct(top1))
              top-3 set overlap       \(pct(overlap))
              identical order         \(pct(exact))

            """)

        print(
            """
            What this means

              The "same #1" figure is the ceiling. A model cannot agree with you
              more often than you agree with yourself.
            """)

        // State the interval rather than let a small sample look authoritative.
        let halfWidth = 1.96 * (top1 * (1 - top1) / n).squareRoot()
        if paired.count < 20 {
            print(
                """

                  Only \(paired.count) paired scenarios: 95% interval is roughly
                  ±\(Int((halfWidth * 100).rounded())) points. Directional, not decisive.
                """)
        }
        if top1 < 0.9 {
            print(
                """

                  Measured ceiling is \(pct(top1)), below the ≥90% target in
                  docs/05-targets.md. That target needs revising down to match
                  reality rather than the model being tuned to beat a number no
                  human can hit.
                """)
        }
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
