import ArgumentParser
import BrainCore
import BrainDatasets
import Foundation

/// Stamps the dev/test split into each scenario file.
///
/// The assignment is a pure function of the scenario id, so **nobody chooses
/// which scenarios are held out** — not Ganesh, not me. Writing it into the
/// files (rather than computing it silently at eval time) makes it auditable in
/// git: anyone can check it was not quietly changed to flatter a result.
struct SplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Assign dev/test splits to scenarios, deterministically from their ids.")

    @Option(name: .long, help: "Scenario directory.")
    var dir: String = "datasets/scenarios"

    @Flag(name: .long, help: "Report the split without writing anything.")
    var dryRun = false

    @Flag(
        name: .long,
        help: "Overwrite splits already stamped. Use only before any test result has been reported."
    )
    var restamp = false

    func run() throws {
        let loaded = try ScenarioLoader.loadAll(in: URL(fileURLWithPath: dir))
        var counts: [String: Int] = [:]
        var ranked: [String: Int] = [:]
        var changed = 0

        // Stratify ranked and unranked scenarios *independently*. Pooling them
        // lets every ranked scenario land on one side by chance, which leaves
        // nothing to tune against (or nothing to validate on).
        let rankedIds = loaded.filter { $0.file.expected != nil }.map(\.file.id)
        let blankIds = loaded.filter { $0.file.expected == nil }.map(\.file.id)
        let assigned = DatasetSplit.stratify(ids: rankedIds)
            .merging(DatasetSplit.stratify(ids: blankIds)) { current, _ in current }

        for scenario in loaded {
            // An existing stamp wins: once a test number has been reported the
            // split must not drift. `--restamp` is the deliberate override.
            let split =
                (restamp ? nil : scenario.file.split)
                ?? (assigned[scenario.file.id] ?? .dev).rawValue
            counts[split, default: 0] += 1
            if scenario.file.expected != nil { ranked[split, default: 0] += 1 }

            if scenario.file.split != split {
                changed += 1
                if !dryRun {
                    var file = scenario.file
                    file.split = split
                    try ScenarioLoader.save(file, to: scenario.path)
                }
            }
        }

        print(
            """

            SCENARIO SPLIT  (\(loaded.count) scenarios)

              dev   \(counts["dev"] ?? 0)   (\(ranked["dev"] ?? 0) ranked)   tune against these
              test  \(counts["test"] ?? 0)   (\(ranked["test"] ?? 0) ranked)   look only at a phase gate

            \(dryRun ? "Dry run — nothing written." : "Stamped \(changed) file\(changed == 1 ? "" : "s").")
            """)

        // State the interval rather than let a small held-out set look authoritative.
        let n = ranked["test"] ?? 0
        if n > 0, n < 30 {
            let halfWidth = 1.96 * (0.9 * 0.1 / Double(n)).squareRoot()
            print(
                """

                  \(n) ranked test scenarios: a measured 90% carries a 95%
                  interval of roughly ±\(Int((halfWidth * 100).rounded())) points. Directional, not decisive.
                  More scenarios (`make add-scenarios`) narrow it.
                """)
        }
    }
}
