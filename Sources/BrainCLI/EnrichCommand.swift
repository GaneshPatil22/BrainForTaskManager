import ArgumentParser
import BrainCore
import BrainDatasets
import BrainPipeline
import Foundation

/// Runs the full capture → item → graph pipeline over a file of raw captures,
/// then prints what Brain would actually show.
///
/// This is the first command where the product shape is visible: raw lines in,
/// a ranked list with reasons out. No model is involved unless a router is
/// configured, which it is not yet.
struct EnrichCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enrich",
        abstract: "Run the pipeline over raw captures and print the result.")

    @Argument(help: "Text file, one capture per line.")
    var file: String

    @Option(name: .long, help: "IANA timezone.")
    var timezone: String = "Asia/Kolkata"

    @Option(name: .long, help: "Override 'now' as ISO-8601.")
    var now: String?

    @Option(name: .long, help: "How many captures to process.")
    var limit: Int = 1000

    @Flag(name: .long, help: "Print the per-field tier for each capture.")
    var showTiers = false

    func run() async throws {
        guard let zone = TimeZone(identifier: timezone) else {
            throw ValidationError("unknown timezone: \(timezone)")
        }
        let nowDate =
            now.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let raw = try String(contentsOfFile: file, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(limit)

        // No router: T0 only. Escalation arrives when cassettes are recorded.
        let pipeline = EnrichmentPipeline(timeZone: zone, router: nil)
        var generator = ULIDGenerator(seed: 7)
        var graph = BrainGraph()
        var tiers: [String: [Tier: Int]] = [:]
        var lost = 0, failed = 0, edges = 0

        for line in lines {
            let capture = Capture(
                id: generator.next(), rawText: line, createdAt: nowDate)
            let result = await pipeline.enrich(
                capture: capture, graph: graph, now: nowDate, idGenerator: &generator,
                requester: .local)

            if result.capture.status == .failed { failed += 1 }
            graph.insert(result.item)
            for edge in result.suggestedEdges {
                // Cycle rejection still applies to pipeline output (guard 6).
                if (try? graph.addEdge(edge)) != nil { edges += 1 }
            }
            for (field, tier) in result.trace.tierByField {
                tiers[field, default: [:]][tier, default: 0] += 1
            }
        }
        // Every capture must have become an item. Anything else is the one
        // failure mode that is not allowed.
        lost = lines.count - graph.items.count

        print(
            """

            PIPELINE  (\(lines.count) captures)

              items created     \(graph.items.count)
              captures lost     \(lost)\(lost == 0 ? "" : "   ← INVARIANT BREACH")
              marked failed     \(failed)  (retryable, text kept)
              edges suggested   \(edges)  (all unconfirmed)
            """)

        if showTiers {
            print("\nWhich tier settled each field:")
            for (field, counts) in tiers.sorted(by: { $0.key < $1.key }) {
                let detail = counts.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
                print(String(format: "  %-10@ %@", field as NSString, detail as NSString))
            }
        }

        let outputs = Brain.compute(graph: graph, now: nowDate, calendar: calendar)
        Printer.render(outputs: outputs, issues: [], showAll: false, timeZone: zone)
    }
}
