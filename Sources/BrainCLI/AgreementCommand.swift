import ArgumentParser
import BrainCore
import BrainDatasets
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
        // The comparison that actually decides anything: on these same
        // scenarios, how often did WE put his pick in the top 3? Measuring the
        // ceiling in isolation leaves it hanging next to a number from a
        // different sample; paired on identical scenarios, it is decisive.
        var ourTop3 = 0
        var ourTop1 = 0

        var calendarByID: [String: (ScenarioLoader.Loaded, [String])] = [:]
        for scenario in loaded {
            if let first = scenario.file.expected?.rankingTop3 {
                calendarByID[scenario.file.id] = (scenario, first)
            }
        }
        for (id, first, _) in paired {
            guard let (scenario, _) = calendarByID[id],
                let humanTop = first.first.flatMap({ scenario.idsByKey[$0] })
            else { continue }
            let outputs = Brain.compute(
                graph: scenario.graph, now: scenario.now, calendar: scenario.calendar)
            let ours = outputs.startable.map(\.item.id)
            if ours.first == humanTop { ourTop1 += 1 }
            if ours.prefix(3).contains(humanTop) { ourTop3 += 1 }
        }

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

        // Brain, over the same scenarios. These were computed and then thrown
        // away, which left out the only comparison the command exists to make:
        // the ceiling is useless without the number being measured against it.
        let brainTop1 = Double(ourTop1) / n
        let brainTop3 = Double(ourTop3) / n

        print(
            """
            What this means

              The "same #1" figure is the ceiling. A model cannot agree with you
              more often than you agree with yourself.

              Over these same \(paired.count) scenarios:

                                      you      Brain
                same #1             \(col(top1))  \(col(brainTop1))
                top-3               \(col(overlap))  \(col(brainTop3))
            """)

        // Always. A small sample is exactly when an interval matters most, and
        // this used to print only below 20 pairs — so 30 pairs reported a bare
        // headline figure with no uncertainty attached at all.
        let (lo, hi) = Self.wilson(top1Same, paired.count)
        print(
            """

              \(paired.count) paired scenarios: the \(pct(top1)) ceiling has a 95%
              interval of \(pct(lo))–\(pct(hi)). Directional, not decisive — read the
              comparison above, not the decimal places.
            """)

        if brainTop3 >= overlap {
            print(
                """

                  Brain's top-3 agreement (\(pct(brainTop3))) is at or above your own
                  self-overlap (\(pct(overlap))), so there is no headroom left to chase
                  on top-3: further tuning would be fitting to coin flips.
                """)
        }

        // top-1 has **no target** in docs/05-targets.md — it is diagnostic
        // only, and that doc already predicted a ceiling near 1/3 from a
        // 900-combination grid search topping out at 36.5%. This used to claim
        // a "≥90% target" that applies to type accuracy and link precision,
        // not to this metric, and told the reader to revise a target that was
        // already right.
        print(
            """

              top-1 has no target by design (docs/05-targets.md: "no target —
              diagnostic only"), which predicted a ceiling near 1/3. Measured
              here: \(pct(top1)).
            """)
    }

    /// Wilson, not the normal approximation, which is poor at these
    /// proportions and this sample size. Matches the method in
    /// `docs/05-targets.md`.
    static func wilson(_ successes: Int, _ n: Int, z: Double = 1.96) -> (Double, Double) {
        guard n > 0 else { return (0, 1) }
        let p = Double(successes) / Double(n)
        let nd = Double(n)
        let denominator = 1 + z * z / nd
        let centre = (p + z * z / (2 * nd)) / denominator
        let half = z * (p * (1 - p) / nd + z * z / (4 * nd * nd)).squareRoot() / denominator
        return (max(0, centre - half), min(1, centre + half))
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// Right-aligned in a fixed width so the two columns line up.
    private func col(_ value: Double) -> String {
        let text = pct(value)
        return String(repeating: " ", count: max(0, 6 - text.count)) + text
    }
}
