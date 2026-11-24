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

    // MARK: - The point of the whole thing

    /// **Capture order must not change the graph.** Writing the dependency
    /// first and the referent second is the case that used to lose the edge
    /// entirely; writing them the other way round always worked. After the
    /// backfill the two orders agree on direction and on confidence, which is
    /// the only claim this feature really makes.
    @Test("Writing the dependency before the referent gives the same edge")
    func captureOrderDoesNotMatter() async {
        let dependency = "deploy the migration after the pooler thing"
        let referent = "the pooler thing"

        // Order A: referent first. The live path links it immediately.
        var genA = generator()
        var graphA = BrainGraph()
        let firstA = await enrich(referent, into: graphA, &genA)
        graphA.insert(firstA.item)
        let secondA = await enrich(dependency, into: graphA, &genA)
        let liveEdge = try! #require(secondA.suggestedEdges.first { $0.kind == .blocks })
        #expect(secondA.pendingReferences.isEmpty)

        // Order B: dependency first. Nothing to link to, so it waits.
        var genB = generator()
        var graphB = BrainGraph()
        let firstB = await enrich(dependency, into: graphB, &genB)
        graphB.insert(firstB.item)
        #expect(firstB.suggestedEdges.filter { $0.kind == .blocks }.isEmpty)
        #expect(firstB.pendingReferences.count == 1, "this is what used to be lost")

        let secondB = await enrich(referent, into: graphB, &genB)
        let resolved = DependencyBackfill.resolve(
            pending: firstB.pendingReferences, against: secondB.item, now: Self.now,
            idGenerator: &genB)
        let backfilledEdge = try! #require(resolved.first?.edge)

        // Same shape, both orders: referent blocks the dependent task.
        #expect(liveEdge.from == firstA.item.id && liveEdge.to == secondA.item.id)
        #expect(backfilledEdge.from == secondB.item.id && backfilledEdge.to == firstB.item.id)
        #expect(
            abs(liveEdge.confidence - backfilledEdge.confidence) < 0.0001,
            "waiting costs no confidence")
        #expect(liveEdge.kind == backfilledEdge.kind)
        #expect(!backfilledEdge.confirmed && backfilledEdge.source == .t0Rule)
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
