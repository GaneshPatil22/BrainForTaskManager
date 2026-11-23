import ArgumentParser
import BrainCore
import Foundation

/// Selects the most *informative* scenarios from the generated files and
/// imports them as blank, rankable scenarios.
///
/// The generated task lists are good; only their answer key was worthless
/// (`docs/13-generated-datasets.md`). Stripping the answers and having a human
/// rank them turns 897 unusable scenarios into a pool worth sampling from.
///
/// Random sampling would waste the human's time. Many generated scenarios have
/// a forced answer — a pool of one or two, or every candidate policy agreeing —
/// and ranking those teaches nothing. This picks scenarios where **candidate
/// policies disagree**, which is active learning (§5.7 of the brief): the cases
/// where a human answer actually discriminates between designs.
struct SampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample-scenarios",
        abstract: "Import the most informative generated scenarios for human ranking.")

    @Option(name: .long, help: "Directory of generated .brain files.")
    var from: String = "datasets/generated"

    @Option(name: .long, help: "Where to write rankable scenarios.")
    var out: String = "datasets/scenarios"

    @Option(name: .long, help: "How many to import.")
    var count: Int = 100

    @Option(name: .long, help: "Minimum open, startable tasks for a scenario to be worth ranking.")
    var minPool: Int = 4

    @Flag(name: .long, help: "Report the selection without writing anything.")
    var dryRun = false

    static let canonicalNow = "2026-11-23T09:00:00+05:30"

    func run() throws {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        guard let now = ISO8601DateFormatter().date(from: Self.canonicalNow) else {
            throw ValidationError("bad canonical now")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let files = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: from), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "brain" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw ValidationError("no .brain files in \(from)") }

        var candidates: [Candidate] = []
        var seenSignatures = Set<String>()
        var rejected = (pool: 0, duplicate: 0, unanimous: 0, malformed: 0)

        for file in files {
            let raw = try String(contentsOf: file, encoding: .utf8)
            for block in Self.blocks(in: raw) {
                let parsed = DumpFormat.parse(block.body, now: now, timeZone: zone)
                guard parsed.issues.isEmpty else { rejected.malformed += 1; continue }

                let outputs = Brain.compute(
                    graph: parsed.graph, now: now, calendar: calendar)
                guard outputs.startable.count >= minPool else { rejected.pool += 1; continue }

                // Near-duplicate across the three files: same task titles.
                let signature = parsed.itemOrder
                    .compactMap { parsed.graph.items[$0]?.title.lowercased() }
                    .sorted().joined(separator: "|")
                guard seenSignatures.insert(signature).inserted else {
                    rejected.duplicate += 1
                    continue
                }

                let disagreement = Self.disagreement(outputs: outputs)
                guard disagreement > 0 else { rejected.unanimous += 1; continue }

                candidates.append(
                    Candidate(
                        title: block.title, body: block.body, parsed: parsed,
                        disagreement: disagreement,
                        traits: Self.traits(graph: parsed.graph, outputs: outputs),
                        signature: signature))
            }
        }

        let chosen = Self.select(candidates, count: count)

        print(
            """

            SCENARIO SAMPLING

              candidates           \(candidates.count)
              rejected: pool < \(minPool)   \(rejected.pool)
                        duplicate    \(rejected.duplicate)
                        policies agree \(rejected.unanimous)
                        malformed    \(rejected.malformed)
              selected             \(chosen.count)

            Trait coverage in the selection:
            """)
        var traitCounts: [String: Int] = [:]
        for candidate in chosen {
            for trait in candidate.traits { traitCounts[trait, default: 0] += 1 }
        }
        for (trait, n) in traitCounts.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %-22@ %3d", trait as NSString, n))
        }

        guard !dryRun else {
            print("\nDry run — nothing written.")
            return
        }

        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var next = try NewScenarioCommand.nextAvailableNumber(in: outDir)
        for candidate in chosen {
            let id = String(format: "scenario-%03d", next)
            // `expected` is nil: the generated answer key is deliberately
            // discarded, and never shown to the person ranking.
            let scenario = NewScenarioCommand.build(
                id: id, title: candidate.title, parsed: candidate.parsed,
                now: now, calendar: calendar)
            try ScenarioLoader.save(scenario, to: outDir.appendingPathComponent("\(id).json"))
            next += 1
        }
        print(
            """

            Wrote \(chosen.count) scenarios to \(out), answers stripped.

            Next:  make split     (re-stamp dev/test across the larger set)
                   make rank      (rank them — you will never see the generated answer)
            """)
    }

    // MARK: - Candidates

    struct Candidate {
        let title: String
        let body: String
        let parsed: DumpFormat.Result
        let disagreement: Int
        let traits: [String]
        let signature: String
    }

    /// How many distinct top picks four plausible policies produce. 0 means the
    /// answer is forced and a human ranking it teaches us nothing.
    static func disagreement(outputs: BrainOutputs) -> Int {
        let pool = outputs.startable
        guard pool.count >= 2 else { return 0 }
        var tops = Set<ULID>()
        tops.insert(pool[0].item.id)  // our leverage ranking
        if let earliest = pool.filter({ $0.item.dueAt.value != nil })
            .min(by: { $0.item.dueAt.value! < $1.item.dueAt.value! })
        {
            tops.insert(earliest.item.id)  // deadline-first
        }
        if let lightest = pool.min(by: {
            $0.item.effortBucket.minutes < $1.item.effortBucket.minutes
        }) {
            tops.insert(lightest.item.id)  // quick-win-first
        }
        if let biggest = pool.max(by: {
            $0.breakdown.unblockedConfirmed < $1.breakdown.unblockedConfirmed
        }), biggest.breakdown.unblockedConfirmed > 0 {
            tops.insert(biggest.item.id)  // unblocker-first
        }
        return tops.count - 1
    }

    /// Structural features, so the selection is stratified rather than skewed
    /// toward whatever happens to score highest.
    static func traits(graph: BrainGraph, outputs: BrainOutputs) -> [String] {
        var traits: [String] = []
        if !outputs.blocked.isEmpty { traits.append("has-blocked") }
        if !graph.goals.isEmpty { traits.append("has-goals") }
        let dated = outputs.ranked.filter { $0.item.dueAt.value != nil }.count
        if dated >= 2 {
            traits.append("deadline-conflict")
        } else if dated == 1 {
            traits.append("single-deadline")
        } else {
            traits.append("no-deadline")
        }
        let efforts = Set(outputs.ranked.map(\.item.effortBucket))
        if efforts.count >= 3 { traits.append("mixed-effort") }
        let categories = Set(outputs.ranked.compactMap(\.item.category.value))
        if categories.count >= 3 { traits.append("mixed-category") }
        traits.append(outputs.ranked.count >= 6 ? "large-pool" : "small-pool")
        return traits
    }

    /// Round-robin over traits, taking the highest-disagreement unused scenario
    /// for each in turn, so no single structural shape dominates.
    static func select(_ candidates: [Candidate], count: Int) -> [Candidate] {
        var byTrait: [String: [Candidate]] = [:]
        for candidate in candidates {
            for trait in candidate.traits { byTrait[trait, default: []].append(candidate) }
        }
        for key in byTrait.keys {
            byTrait[key]?.sort {
                $0.disagreement == $1.disagreement
                    ? $0.signature < $1.signature : $0.disagreement > $1.disagreement
            }
        }
        var chosen: [Candidate] = []
        var used = Set<String>()
        let traits = byTrait.keys.sorted()
        var cursor: [String: Int] = [:]

        while chosen.count < count {
            var progressed = false
            for trait in traits where chosen.count < count {
                var index = cursor[trait] ?? 0
                let list = byTrait[trait] ?? []
                while index < list.count, used.contains(list[index].signature) { index += 1 }
                cursor[trait] = index
                guard index < list.count else { continue }
                chosen.append(list[index])
                used.insert(list[index].signature)
                progressed = true
            }
            if !progressed { break }
        }
        return chosen
    }

    // MARK: - Parsing generated files

    /// Splits a generated file into scenarios, discarding the `expect:` blocks.
    static func blocks(in raw: String) -> [NewScenarioCommand.Block] {
        var result: [NewScenarioCommand.Block] = []
        var title: String?
        var body: [String] = []
        var skipping = false

        func flush() {
            if let title, !body.isEmpty {
                result.append(.init(title: title, body: body.joined(separator: "\n")))
            }
            body = []
        }
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "expect:" { skipping = true; continue }
            if trimmed == "end-expect" { skipping = false; continue }
            if skipping { continue }
            if trimmed.lowercased().hasPrefix("scenario:") {
                flush()
                title = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }
}
