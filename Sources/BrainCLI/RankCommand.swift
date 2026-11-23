import ArgumentParser
import BrainCore
import Foundation

/// Blind ranking of scenarios by a human.
///
/// The whole point is that **no score, no leverage number, and no hint of what
/// the scenario is testing is ever shown.** If the person authoring the ground
/// truth can see the formula's opinion, the resulting metric measures nothing
/// (`docs/05-targets.md`).
struct RankCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rank",
        abstract: "Rank scenarios by hand. Resumable — ranked ones are skipped.")

    @Option(name: .long, help: "Scenario directory.")
    var dir: String = "datasets/scenarios"

    @Flag(name: .long, help: "Re-rank scenarios that already have an answer.")
    var redo = false

    @Option(name: .long, help: "How many to do in this sitting.")
    var limit: Int = 30

    func run() throws {
        let directory = URL(fileURLWithPath: dir)
        var loaded = try ScenarioLoader.loadAll(in: directory)

        // Present in a shuffled but reproducible order, so fatigue late in a
        // sitting does not correlate with one kind of scenario.
        var rng = SplitMix64(seed: 20_261_123)
        loaded.sort { a, b in a.file.id < b.file.id }
        for i in stride(from: loaded.count - 1, to: 0, by: -1) {
            loaded.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }

        let pending = loaded.filter { redo || $0.file.expected == nil }
        guard !pending.isEmpty else {
            print("All \(loaded.count) scenarios are ranked. Nothing to do.")
            return
        }

        let total = loaded.count
        let alreadyDone = total - loaded.filter { $0.file.expected == nil }.count
        print(
            """

            BLIND SCENARIO RANKING
            \(pending.count) to go (\(alreadyDone)/\(total) done).

            For each one: if this were your list this morning, which three
            would you actually do first, in order?

            Type three numbers, best first, e.g.  3 1 5
            Commands:  s = skip   q = save and quit   ? = show help again

            There is no right answer. Answer as yourself, not as you think
            the system should answer — the whole measurement depends on that.

            """)

        var completed = 0
        for scenario in pending.prefix(limit) {
            switch try rank(scenario, index: alreadyDone + completed + 1, total: total) {
            case .ranked: completed += 1
            case .skipped: continue
            case .quit:
                print("\nSaved. \(alreadyDone + completed)/\(total) ranked. Run again to resume.")
                return
            }
        }
        print("\nDone for now — \(alreadyDone + completed)/\(total) ranked.")
    }

    enum Outcome { case ranked, skipped, quit }

    private func rank(_ scenario: ScenarioLoader.Loaded, index: Int, total: Int) throws -> Outcome {
        let open = scenario.file.items.filter { $0.status == "open" }
        // Shuffle item order per scenario so position does not bias the choice.
        var rng = SplitMix64(seed: ULID.derived(from: scenario.file.id).timestampMilliseconds)
        var shown = open
        for i in stride(from: shown.count - 1, to: 0, by: -1) {
            shown.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }

        print(String(repeating: "─", count: 72))
        print("[\(index)/\(total)]  Today is Monday 23 Nov 2026, 9:00 am.\n")

        for (position, item) in shown.enumerated() {
            print("  \(position + 1). \(item.title)")
            var facts: [String] = [effortText(item.effort)]
            if let clause = dueText(item.dueAt) { facts.append(clause) }
            for goal in goalsServed(by: item.id, in: scenario.file) {
                facts.append("serves “\(goal)”")
            }
            print("     \(facts.joined(separator: " · "))")
            // Relationships are stated plainly, with no count or score attached.
            let unblocks = scenario.file.edges
                .filter { $0.from == item.id && $0.kind == "blocks" && $0.confirmed }
                .compactMap { to in scenario.file.items.first { $0.id == to.to }?.title }
            if !unblocks.isEmpty {
                print("     needed before: \(unblocks.joined(separator: ", "))")
            }
            let waitingOn = scenario.file.edges
                .filter { $0.to == item.id && $0.kind == "blocks" && $0.confirmed }
                .compactMap { from in scenario.file.items.first { $0.id == from.from }?.title }
                .filter { title in
                    scenario.file.items.first { $0.title == title }?.status == "open"
                }
            if !waitingOn.isEmpty { print("     waiting on: \(waitingOn.joined(separator: ", "))") }
            print("")
        }

        while true {
            print("  Your top 3 (best first), or s / q / ? : ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else { return .quit }
            switch line.lowercased() {
            case "q": return .quit
            case "s": print("  skipped\n"); return .skipped
            case "?":
                print(
                    """

                    Three numbers from the list, best first, e.g.  3 1 5
                    Fewer than three is fine if the list is short.
                    s = skip this one, q = save and quit.

                    """)
                continue
            default: break
            }

            let picks = line.split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Int($0) }
            guard !picks.isEmpty, picks.count <= 3,
                picks.allSatisfy({ (1...shown.count).contains($0) }),
                Set(picks).count == picks.count
            else {
                print("  Need up to 3 distinct numbers between 1 and \(shown.count).")
                continue
            }

            var file = scenario.file
            file.expected = ScenarioFile.Expected(
                rankingTop3: picks.map { shown[$0 - 1].id },
                rankedBy: "human",
                rankedAt: ISO8601DateFormatter().string(from: Date()),
                note: nil)
            try ScenarioLoader.save(file, to: scenario.path)
            print("  recorded: \(picks.map { shown[$0 - 1].title }.joined(separator: " → "))\n")
            return .ranked
        }
    }

    private func goalsServed(by itemId: String, in file: ScenarioFile) -> [String] {
        file.edges
            .filter { $0.from == itemId && $0.kind == "serves" }
            .compactMap { edge in file.goals.first { $0.id == edge.to }?.title }
    }

    private func effortText(_ effort: String) -> String {
        switch effort {
        case "tiny": "about 5 min"
        case "small": "about 20 min"
        case "medium": "about an hour"
        case "large": "about half a day"
        case "xlarge": "several days"
        default: "effort unknown"
        }
    }

    private func dueText(_ offset: String?) -> String? {
        guard let days = offset.flatMap(Int.init) else { return nil }
        switch days {
        case ..<0: return "OVERDUE by \(-days) \(-days == 1 ? "day" : "days")"
        case 0: return "due today"
        case 1: return "due tomorrow"
        default: return "due in \(days) days"
        }
    }
}
