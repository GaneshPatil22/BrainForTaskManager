import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// Dependencies whose referent has not been captured yet
/// (`docs/15-planner.md`, step 6).
///
/// The capture "deploy after the pooler thing", written before the pooler
/// item exists, used to become a line in `trace.notes` and nothing else. The
/// sweeper requeues captures that are `raw`, stuck or `failed`, and this one
/// is `enriched` and healthy — so nothing ever looked again.
@Suite("Pending dependency references")
struct PendingReferenceTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 1, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    func enrich(_ text: String, into graph: BrainGraph, _ gen: inout ULIDGenerator) async
        -> EnrichmentResult
    {
        let input = Capture(id: gen.next(), rawText: text, createdAt: Self.now)
        return await EnrichmentPipeline(timeZone: Self.zone).enrich(
            capture: input, graph: graph, now: Self.now, idGenerator: &gen, requester: .local)
    }

    @Test("A referent that does not exist yet is kept, not dropped")
    func keptNotDropped() async {
        var gen = generator()
        let result = await enrich(
            "deploy the migration after the pooler thing", into: BrainGraph(), &gen)

        #expect(result.suggestedEdges.filter { $0.kind == .blocks }.isEmpty, "nothing to link to")
        #expect(result.pendingReferences.count == 1)
        let pending = try! #require(result.pendingReferences.first)
        #expect(pending.itemId == result.item.id)
        #expect(pending.targetText.contains("pooler"))
        #expect(pending.direction == .blockedByReferent)
        #expect(pending.writtenAt == Self.now, "when the user wrote it, not when it resolved")
        #expect(pending.confidence > 0)
        #expect(!pending.rule.isEmpty)
    }

    @Test("A referent that does exist produces an edge and nothing pending")
    func matchedLeavesNothingPending() async {
        var gen = generator()
        var graph = BrainGraph()
        graph.insert(
            Item(id: gen.next(), title: "the pooler thing", status: .open, createdAt: Self.now))

        let result = await enrich(
            "deploy the migration after the pooler thing", into: graph, &gen)
        #expect(result.suggestedEdges.contains { $0.kind == .blocks })
        #expect(result.pendingReferences.isEmpty, "it resolved; there is nothing to wait for")
    }

    /// `before` is the direction that used to be unsupported entirely. A
    /// pending reference that forgot it would resolve backwards later.
    @Test("`before` keeps its direction while it waits")
    func beforeKeepsDirection() async {
        var gen = generator()
        let result = await enrich(
            "review the PR before the release call", into: BrainGraph(), &gen)
        #expect(result.pendingReferences.count == 1)
        #expect(result.pendingReferences.first?.direction == .blocksReferent)
    }

    /// The scorecard guard. `BrainEval/Metrics.swift` counts
    /// `trace.unresolved` into `fieldsConsidered`, which is the denominator of
    /// every tier-share percentage — so recording an unmatched dependency
    /// there would move all of them for a bookkeeping reason.
    @Test("An unmatched dependency does not enter the scorecard's denominator")
    func doesNotTouchTheScorecard() async {
        var gen = generator()
        let result = await enrich(
            "deploy the migration after the pooler thing", into: BrainGraph(), &gen)
        #expect(!result.trace.unresolved.contains("blocks"))
        #expect(result.trace.tierByField["blocks"] == nil, "no tier settled it")
    }

    @Test("A capture with no dependency phrase has nothing pending")
    func noPhraseNoPending() async {
        var gen = generator()
        let result = await enrich("pay the electricity bill", into: BrainGraph(), &gen)
        #expect(result.pendingReferences.isEmpty)
    }

    @Test("An empty capture still returns, with nothing pending")
    func degradedIsEmpty() async {
        var gen = generator()
        let result = await enrich("   ", into: BrainGraph(), &gen)
        #expect(result.pendingReferences.isEmpty)
        #expect(result.capture.status == .failed, "kept and retryable")
    }

    /// A closed item is not a referent: "after the thing I already finished"
    /// should wait for a new one, not link to the done one. The candidate
    /// filter already excludes closed items, so this asserts the consequence.
    @Test("A done item does not satisfy a reference")
    func doneItemIsNotAMatch() async {
        var gen = generator()
        var graph = BrainGraph()
        graph.insert(
            Item(id: gen.next(), title: "the pooler thing", status: .done, createdAt: Self.now))
        let result = await enrich(
            "deploy the migration after the pooler thing", into: graph, &gen)
        #expect(result.pendingReferences.count == 1)
    }
}
