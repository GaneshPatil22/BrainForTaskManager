import ArgumentParser
import BrainCore
import BrainDatasets
import BrainPipeline
import Foundation

/// Does the dependency backfill ever actually fire?
///
/// A feature that cannot be observed on real text is a feature nobody can
/// trust. This replays a split in capture order, keeps every reference whose
/// referent did not exist yet, and offers them back as each later item
/// arrives — exactly what the server will do. It reports how many references
/// were created, how many a later capture resolved, and how many were still
/// waiting at the end.
///
/// **It cannot report precision.** The corpus has no labels for "this
/// dependency is real", so a resolution being *correct* is a judgement the
/// listing leaves to a reader. `--show` prints every pair for that reason.
struct BackfillAuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-audit",
        abstract: "How often a late-arriving referent resolves a kept dependency.")

    @Option(name: .long, help: "Dataset split: dev, test or train.")
    var split: String = "dev"

    @Option(name: .long, help: "IANA timezone.")
    var timezone: String = "Asia/Kolkata"

    @Flag(name: .long, help: "Print every resolved pair, to judge them by eye.")
    var show = false

    @Flag(name: .long, help: "Print the dependencies the live path linked, to judge those too.")
    var showLive = false

    func run() async throws {
        guard let zone = TimeZone(identifier: timezone) else {
            throw ValidationError("unknown timezone: \(timezone)")
        }
        let rows = try SyntheticLoader.load(
            directory: URL(fileURLWithPath: "datasets/v1"), split: split)
        guard !rows.isEmpty else { throw ValidationError("no captures in split \(split)") }

        let outcome = try await Self.replay(rows, zone: zone)

        print("Dependency backfill — \(split) split")
        print("captures                 \(rows.count)")
        print("items                    \(outcome.items)")
        print("dependencies linked live \(outcome.liveEdges)")
        print("references kept          \(outcome.kept)")
        print("…resolved later          \(outcome.resolved)")
        print("…still waiting at the end \(outcome.kept - outcome.resolved)")
        if outcome.kept > 0 {
            let share = Double(outcome.resolved) / Double(outcome.kept) * 100
            print("resolution rate          \(String(format: "%.1f", share))%")
        }
        if showLive {
            print("\nDependencies the live path linked — judge these too")
            for pair in outcome.livePairs {
                print(
                    "\(String(format: "%.3f", pair.score))  \(pair.waiting)"
                        + "\n        ↳ linked to: \(pair.arrival)")
            }
        }
        if show {
            print("\nResolved pairs — judge these by eye")
            for pair in outcome.pairs {
                print(
                    "\(String(format: "%.3f", pair.score))  \(pair.waiting)"
                        + "\n        ↳ resolved by: \(pair.arrival)")
            }
        }
    }

    struct Pair: Sendable {
        let waiting: String
        let arrival: String
        let score: Double
    }

    struct Outcome: Sendable {
        var items = 0
        var liveEdges = 0
        var kept = 0
        var resolved = 0
        var pairs: [Pair] = []
        var livePairs: [Pair] = []
    }

    /// Replays the split the way the server will: enrich, keep what did not
    /// match, then offer the kept references to every later item.
    static func replay(_ rows: [SyntheticCapture], zone: TimeZone) async throws -> Outcome {
        let now = SyntheticLoader.now
        let pipeline = EnrichmentPipeline(timeZone: zone)
        var generator = ULIDGenerator(seed: 20_261_124)
        var graph = BrainGraph()
        var pending: [PendingReference] = []
        var titles: [ULID: String] = [:]
        var outcome = Outcome()

        for row in rows {
            let capture = Capture(
                id: generator.next(), rawText: row.rawText, createdAt: now)
            let result = await pipeline.enrich(
                capture: capture, graph: graph, now: now, idGenerator: &generator,
                requester: .local)
            graph.insert(result.item)
            titles[result.item.id] = result.item.title
            for edge in result.suggestedEdges where edge.kind == .blocks {
                outcome.liveEdges += 1
                let other = edge.from == result.item.id ? edge.to : edge.from
                outcome.livePairs.append(
                    Pair(
                        waiting: result.item.title, arrival: titles[other] ?? "?",
                        score: edge.confidence))
            }

            // Anything waiting that this new item satisfies, before this
            // capture's own references join the pool — an item cannot resolve
            // a reference it wrote itself, and `resolve` guards that too.
            let resolutions = DependencyBackfill.resolve(
                pending: pending, against: result.item, now: now, idGenerator: &generator)
            for resolution in resolutions {
                outcome.resolved += 1
                outcome.pairs.append(
                    Pair(
                        waiting: titles[resolution.reference.itemId]
                            ?? resolution.reference.targetText,
                        arrival: result.item.title, score: resolution.score))
            }
            let consumed = Set(resolutions.map { $0.reference })
            pending.removeAll { consumed.contains($0) }

            outcome.kept += result.pendingReferences.count
            pending.append(contentsOf: result.pendingReferences)
        }
        outcome.items = graph.items.count
        return outcome
    }
}
