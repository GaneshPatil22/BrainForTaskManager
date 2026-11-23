import ArgumentParser
import BrainCore
import BrainDatasets
import BrainEval
import Foundation

/// Prints why our top pick differs from the human's. Reads only; changes nothing.
struct Diagnose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Explain the ranking disagreements. Diagnosis, not tuning.")

    @OptionGroup var options: EvalOptions

    @Flag(name: .long, help: "List every disagreement, not just the summary.")
    var verbose = false

    func run() throws {
        try options.validateSplit(isGate: false)
        let all = try ScenarioLoader.loadAll(in: URL(fileURLWithPath: options.scenarios))
        let ranked = all.filter {
            ($0.file.split ?? "dev") == options.split && $0.file.expected != nil
        }
        let report = Diagnosis.run(scenarios: ranked)
        guard report.scenarios > 0 else {
            print("No ranked scenarios in split \(options.split).")
            return
        }

        let n = Double(report.scenarios)
        print(
            """

            RANKING DIAGNOSIS  (\(report.scenarios) ranked dev scenarios)

              agreed on #1      \(pct(Double(report.agreed) / n))
              disagreed         \(pct(Double(report.disagreementCount) / n))

            Where the human's pick sat in our ranking:
            """)
        for (rank, count) in report.humanRankHistogram.sorted(by: { $0.key < $1.key }) {
            let label = rank == 0 ? "not startable" : "#\(rank)"
            let bar = String(repeating: "█", count: count)
            print(String(format: "  %-14@ %3d  %@", label as NSString, count, bar as NSString))
        }

        guard !report.disagreements.isEmpty else { return }
        let d = report.disagreements

        func mean(_ get: (Diagnosis.Disagreement) -> Double) -> Double {
            d.reduce(0) { $0 + get($1) } / Double(d.count)
        }
        func share(_ test: (Diagnosis.Disagreement) -> Bool) -> Double {
            Double(d.filter(test).count) / Double(d.count)
        }

        print(
            """

            When we disagree (\(d.count) cases), our pick vs theirs:

                                        ours      theirs
              effort (minutes)       \(fmt(mean(\.ourEffortMinutes)))  \(fmt(mean(\.humanEffortMinutes)))
              due pressure           \(fmt(mean(\.ourDuePressure)))  \(fmt(mean(\.humanDuePressure)))
              unblocks               \(fmt(mean { Double($0.ourUnblocks) }))  \(fmt(mean { Double($0.humanUnblocks) }))
              goals served           \(fmt(mean { Double($0.ourGoals) }))  \(fmt(mean { Double($0.humanGoals) }))
              leverage               \(fmt(mean(\.ourLeverage)))  \(fmt(mean(\.humanLeverage)))

            Direction of the disagreement:
              their pick is heavier       \(pct(share { $0.humanEffortMinutes > $0.ourEffortMinutes }))
              their pick is more urgent   \(pct(share { $0.humanDuePressure > $0.ourDuePressure }))
              their pick unblocks more    \(pct(share { $0.humanUnblocks > $0.ourUnblocks }))
              their pick has no deadline  \(pct(share { $0.humanDuePressure == 0 }))
              our pick has no deadline    \(pct(share { $0.ourDuePressure == 0 }))
            """)

        // Does any single knob close the gap? If one does, the formula is
        // mistuned. If none does, it is missing a term — a far bigger finding.
        print("\nWould one weight fix it? (dev only, nothing changed)\n")
        print("  weight          value   top-1   top-3")
        let sweeps: [(String, WritableKeyPath<ScoringWeights, Double>, [Double])] = [
            ("w_due", \.due, [0.4, 0.8, 1.5, 3.0, 6.0]),
            ("w_unblocked", \.unblocked, [0.5, 1.0, 2.0, 4.0]),
            ("w_goals", \.goals, [0.5, 1.5, 3.0]),
            ("w_base", \.base, [0.1, 0.5, 1.5, 3.0]),
            // The lever the other four do not have: effort is a divisor, not
            // a weighted term, so no weight above can undo its bias.
            ("effortExponent", \.effortExponent, [0.0, 0.25, 0.5, 0.75, 1.0, 1.5]),
        ]
        for (name, keyPath, values) in sweeps {
            for row in Diagnosis.sweep(scenarios: ranked, keyPath: keyPath, values: values) {
                let marker = row.value == ScoringWeights.default[keyPath: keyPath] ? " ←now" : ""
                print(
                    String(
                        format: "  %-14@ %5.1f   %5.1f%%  %5.1f%%%@",
                        name as NSString, row.value,
                        row.top1 * 100, row.top3 * 100, marker as NSString))
            }
        }

        // Grid search, to tell "mistuned" from "missing a term".
        let grid = Diagnosis.grid(scenarios: ranked)
        print(
            """

            Best point on a \(grid.evaluated)-combination grid (dev only, nothing changed):

              top-1  \(pct(grid.top1))   (now \(pct(Double(report.agreed) / n)))
              top-3  \(pct(grid.top3))
              effortExponent \(grid.best.effortExponent) · w_unblocked \(grid.best.unblocked) \
            · w_due \(grid.best.due) · w_goals \(grid.best.goals) · w_base \(grid.best.base)
            """)

        if verbose {
            print("\nEvery disagreement:\n")
            for item in d.sorted(by: { $0.scenarioId < $1.scenarioId }) {
                print("  \(item.scenarioId)  (their pick was our #\(item.humanRankInOurs))")
                print("    ours:   \(item.ourTitle)")
                print("    theirs: \(item.humanTitle)")
            }
        }
    }

    private func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private func fmt(_ value: Double) -> String { String(format: "%8.2f", value) }
}
