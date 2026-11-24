import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// Duplicate suggestions reaching the plan (`docs/15-planner.md`, step 6).
@Suite("Duplicate edges")
struct DuplicateEdgeTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 1, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    /// A graph holding one open item with `title`.
    func graph(holding title: String, _ gen: inout ULIDGenerator) -> (BrainGraph, ULID) {
        var graph = BrainGraph()
        let existing = Item(
            id: gen.next(), title: title, status: .open, createdAt: Self.now)
        graph.insert(existing)
        return (graph, existing.id)
    }

    func enrich(_ text: String, into graph: BrainGraph, _ gen: inout ULIDGenerator) async
        -> EnrichmentResult
    {
        let input = Capture(id: gen.next(), rawText: text, createdAt: Self.now)
        return await EnrichmentPipeline(timeZone: Self.zone).enrich(
            capture: input, graph: graph, now: Self.now, idGenerator: &gen, requester: .local)
    }

    @Test("Writing the same thing twice is suggested as a duplicate")
    func suggestsDuplicate() async {
        var gen = generator()
        let (graph, existing) = graph(holding: "Pay the electricity bill", &gen)
        let result = await enrich("electricity bill pay karna h", into: graph, &gen)

        let duplicates = result.suggestedEdges.filter { $0.kind == .duplicate }
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.to == existing)
        #expect(duplicates.first?.from == result.item.id)
        #expect(result.trace.tierByField["duplicate"] == .t0, "no model involved")
    }

    /// Invariant 3: a suggestion is never a decision.
    @Test("A duplicate suggestion is never confirmed")
    func neverConfirmed() async {
        var gen = generator()
        let (graph, _) = graph(holding: "Pay the electricity bill", &gen)
        let result = await enrich("electricity bill pay karna h", into: graph, &gen)
        #expect(result.suggestedEdges.allSatisfy { !$0.confirmed })
        #expect(result.suggestedEdges.allSatisfy { $0.source == .t0Rule })
    }

    @Test("Something merely similar produces no suggestion")
    func noFalsePositive() async {
        var gen = generator()
        let (graph, _) = graph(holding: "call manager about raise", &gen)
        let result = await enrich("call manager about leave", into: graph, &gen)
        #expect(result.suggestedEdges.filter { $0.kind == .duplicate }.isEmpty)
    }

    /// A closed item is not something you are writing down twice — it is
    /// something you already did.
    @Test("Done items are not offered as duplicates")
    func ignoresClosedItems() async {
        var gen = generator()
        var graph = BrainGraph()
        let done = Item(
            id: gen.next(), title: "Pay the electricity bill", status: .done,
            createdAt: Self.now)
        graph.insert(done)
        let result = await enrich("electricity bill pay karna h", into: graph, &gen)
        #expect(result.suggestedEdges.filter { $0.kind == .duplicate }.isEmpty)
    }

    @Test("At most one duplicate is suggested, however many look alike")
    func oneSuggestionOnly() async {
        var gen = generator()
        var graph = BrainGraph()
        for title in [
            "Pay the electricity bill", "pay the electricity bill today",
            "electricity bill pay karna hai",
        ] {
            graph.insert(Item(id: gen.next(), title: title, status: .open, createdAt: Self.now))
        }
        let result = await enrich("electricity bill pay karna h", into: graph, &gen)
        #expect(
            result.suggestedEdges.filter { $0.kind == .duplicate }.count == 1,
            "three cards to dismiss is worse than one")
    }

    @Test("An empty graph is fine, and the capture still becomes an item")
    func emptyGraph() async {
        var gen = generator()
        let result = await enrich("electricity bill pay karna h", into: BrainGraph(), &gen)
        #expect(result.suggestedEdges.isEmpty)
        #expect(result.capture.status == .enriched)
        #expect(!result.item.title.isEmpty)
    }

    /// Both can be true of one capture, and neither should suppress the other.
    @Test("A capture can suggest a dependency and a duplicate at once")
    func dependencyAndDuplicate() async {
        var gen = generator()
        var graph = BrainGraph()
        let blocker = Item(
            id: gen.next(), title: "schema review", status: .open, createdAt: Self.now)
        let twin = Item(
            id: gen.next(), title: "deploy the migration after schema review",
            status: .open, createdAt: Self.now)
        graph.insert(blocker)
        graph.insert(twin)

        let result = await enrich(
            "deploy the migration after schema review", into: graph, &gen)
        #expect(result.suggestedEdges.contains { $0.kind == .blocks })
        #expect(result.suggestedEdges.contains { $0.kind == .duplicate })
    }
}
