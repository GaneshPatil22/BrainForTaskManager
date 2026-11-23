import Foundation
import Testing
@testable import BrainCore

/// Property tests over seeded random graphs. Seeds are listed explicitly so a
/// failure is reproducible from the test name alone — no flaky "random" tests.
@Suite("Properties — invariants from docs/01-domain.md")
struct PropertyTests {

    static let seeds: [UInt64] = [1, 2, 3, 7, 11, 13, 42, 99, 1_000, 31_337]

    /// Invariant 1: the `blocks` subgraph is always a DAG, whatever sequence of
    /// edges is attempted.
    @Test("P1 — no edge sequence can produce a cycle", arguments: seeds)
    func cycleSafety(seed: UInt64) {
        let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 40, edgeAttempts: 300)
        #expect(!graph.hasCycle(), "seed \(seed) produced a cycle")
    }

    /// Invariant 5: scoring is deterministic.
    @Test("P2 — ranking is identical across repeated runs", arguments: seeds)
    func determinism(seed: UInt64) {
        let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 30, edgeAttempts: 150)
        let first = Scoring.rank(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        for _ in 0..<5 {
            let again = Scoring.rank(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
            #expect(first.map(\.itemId) == again.map(\.itemId), "seed \(seed)")
            #expect(first.map(\.leverage) == again.map(\.leverage), "seed \(seed)")
        }
    }

    /// Invariant 4: a strict total order — no two items ever tie.
    @Test("P3 — ranking is a strict total order", arguments: seeds)
    func strictTotalOrder(seed: UInt64) {
        let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 40, edgeAttempts: 200)
        let ranked = Scoring.rank(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        let ids = ranked.map(\.itemId)
        #expect(Set(ids).count == ids.count, "seed \(seed): duplicate ids in ranking")
        #expect(ids.count == graph.openItems.count, "seed \(seed): ranking must cover open items")
    }

    /// Insertion order must not affect the outcome. Same edges, different
    /// sequence, same ranking — otherwise "deterministic" is a lie in practice.
    @Test("P4 — ranking is independent of insertion order", arguments: seeds)
    func orderIndependence(seed: UInt64) throws {
        var gen = Fixtures.generator(seed: seed)
        var rng = SplitMix64(seed: seed)
        let items = (0..<20).map { i -> Item in
            Fixtures.item(
                &gen, "n\(i)",
                effort: EffortBucket.allCases[Int(rng.next() % 6)])
        }
        // A fixed DAG: only forward edges, so no insertion order can cycle.
        var pairs: [(Int, Int)] = []
        for _ in 0..<40 {
            let a = Int(rng.next() % 20), b = Int(rng.next() % 20)
            if a < b { pairs.append((a, b)) }
        }

        func build(_ order: [(Int, Int)]) throws -> BrainGraph {
            var graph = BrainGraph()
            var localGen = Fixtures.generator(seed: seed &+ 1)
            for item in items { graph.insert(item) }
            for (a, b) in order {
                try graph.addEdge(
                    Fixtures.confirmedEdge(
                        &localGen, from: items[a].id,
                        to: items[b].id, kind: .blocks))
            }
            return graph
        }

        let forward = try build(pairs)
        let reversed = try build(pairs.reversed())
        #expect(
            Scoring.rank(graph: forward, now: Fixtures.now, calendar: Fixtures.calendar)
                .map(\.itemId)
                == Scoring.rank(graph: reversed, now: Fixtures.now, calendar: Fixtures.calendar)
                .map(\.itemId),
            "seed \(seed)")
    }

    /// Monotonicity: unblocking strictly more work never lowers your score.
    @Test(
        "P5 — adding a confirmed unblocked item never decreases leverage",
        arguments: seeds)
    func monotonicity(seed: UInt64) throws {
        var gen = Fixtures.generator(seed: seed)
        var graph = BrainGraph()
        let subject = Fixtures.item(&gen, "subject", effort: .medium)
        graph.insert(subject)

        var previous = Scoring.score(
            item: subject, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar
        ).leverage
        for i in 0..<6 {
            let fresh = Fixtures.item(&gen, "down-\(i)")
            graph.insert(fresh)
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: subject.id, to: fresh.id,
                    kind: .blocks))
            let current = Scoring.score(
                item: subject, in: graph, now: Fixtures.now,
                calendar: Fixtures.calendar
            ).leverage
            #expect(
                current >= previous - Scoring.leverageEpsilon,
                "seed \(seed), step \(i): \(current) < \(previous)")
            previous = current
        }
    }

    /// With alpha = 0, unconfirmed edges must have no effect on any score.
    /// This is what "AI proposes, the human confirms" means numerically.
    @Test("P6 — alpha = 0 makes unconfirmed edges inert", arguments: seeds)
    func unconfirmedInert(seed: UInt64) throws {
        var gen = Fixtures.generator(seed: seed)
        var graph = BrainGraph()
        let subject = Fixtures.item(&gen, "subject", effort: .small)
        graph.insert(subject)
        let baseline = Scoring.score(
            item: subject, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar
        ).leverage

        for i in 0..<5 {
            let fresh = Fixtures.item(&gen, "ai-down-\(i)")
            graph.insert(fresh)
            try graph.addEdge(Fixtures.aiEdge(&gen, from: subject.id, to: fresh.id, kind: .blocks))
        }
        let after = Scoring.score(
            item: subject, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar,
            policy: EdgePolicy(alpha: 0)
        ).leverage
        #expect(abs(after - baseline) < Scoring.leverageEpsilon, "seed \(seed)")

        // ...and alpha > 0 must actually move it, or the knob does nothing.
        let weighted = Scoring.score(
            item: subject, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar,
            policy: EdgePolicy(alpha: 0.5)
        ).leverage
        #expect(weighted > baseline, "seed \(seed)")
    }

    /// Quick wins must always be startable — recommending something the user
    /// cannot begin is worse than recommending nothing.
    @Test("P7 — no quick win is blocked", arguments: seeds)
    func quickWinsAreStartable(seed: UInt64) {
        let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 40, edgeAttempts: 200)
        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        for win in outputs.quickWins {
            #expect(
                graph.blockers(of: win.item.id).isEmpty,
                "seed \(seed): blocked item \(win.item.title) offered as a quick win")
            #expect(win.item.effortBucket.isQuick, "seed \(seed): quick win with large effort")
        }
    }

    /// Only open items are ever ranked or offered.
    @Test("P8 — closed items never appear in any output", arguments: seeds)
    func closedItemsExcluded(seed: UInt64) {
        let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 40, edgeAttempts: 200)
        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        let closed = Set(graph.items.values.filter { !$0.status.isOpen }.map(\.id))
        for entry in outputs.ranked { #expect(!closed.contains(entry.item.id)) }
        for entry in outputs.quickWins { #expect(!closed.contains(entry.item.id)) }
        for entry in outputs.blocked { #expect(!closed.contains(entry.item.id)) }
    }

    /// Invariant 6: an entirely unknown item must not crash any stage.
    @Test("P9 — fully abstained items flow through without crashing")
    func abstentionIsSafe() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let blank = Item(id: gen.next(), title: "", createdAt: Fixtures.now)
        graph.insert(blank)
        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(outputs.ranked.count == 1)
        #expect(outputs.next?.reason == "No links or deadline yet")
    }
}

@Suite("Properties — ULID")
struct ULIDPropertyTests {
    @Test("Encoding round-trips the timestamp", arguments: PropertyTests.seeds)
    func timestampRoundTrip(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<50 {
            let ms = rng.next() % 0xFFFF_FFFF_FFFF  // 48 bits
            let bytes = (0..<10).map { _ in UInt8(rng.next() % 256) }
            let ulid = ULID(timestampMilliseconds: ms, randomness: bytes)
            #expect(ulid.rawValue.count == 26)
            #expect(ulid.timestampMilliseconds == ms)
        }
    }

    @Test("Lexicographic order matches creation order")
    func sortsByTime() {
        var previous: ULID?
        for i in 0..<100 {
            let ulid = ULID(
                timestampMilliseconds: UInt64(1_000_000 + i * 10),
                randomness: Array(repeating: 0, count: 10))
            if let previous { #expect(previous < ulid) }
            previous = ulid
        }
    }

    @Test("Invalid strings are rejected rather than coerced")
    func rejectsInvalid() {
        #expect(ULID("") == nil)
        #expect(ULID("0") == nil)
        #expect(ULID(String(repeating: "A", count: 25)) == nil)
        #expect(ULID(String(repeating: "U", count: 26)) == nil, "U is not in Crockford base32")
        #expect(ULID(String(repeating: "A", count: 26)) != nil)
    }
}
