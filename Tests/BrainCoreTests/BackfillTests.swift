import Foundation
import Testing

@testable import BrainCore

/// Resolving dependencies whose referent arrived later (`docs/15-planner.md`,
/// step 6).
@Suite("Dependency backfill")
struct BackfillTests {
    static let now = Date(timeIntervalSince1970: 1_795_404_600)
    static let day: TimeInterval = 24 * 60 * 60

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 7, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    func reference(
        itemId: ULID, text: String = "the pooler thing",
        direction: ParsedDependency.Direction = .blockedByReferent,
        confidence: Double = 0.9, ago: TimeInterval = 0
    ) -> PendingReference {
        PendingReference(
            itemId: itemId, targetText: text, direction: direction,
            confidence: confidence, rule: "afterMarker",
            writtenAt: Self.now.addingTimeInterval(-ago))
    }

    func item(_ id: ULID, _ title: String, status: ItemStatus = .open) -> Item {
        Item(id: id, title: title, status: status, createdAt: Self.now)
    }

    // MARK: - The thing it exists for

    @Test("A referent that arrives later resolves the reference")
    func resolvesOnArrival() {
        var gen = generator()
        let waiter = gen.next()
        let arrival = item(gen.next(), "the pooler thing")

        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: waiter)], against: arrival, now: Self.now,
            idGenerator: &gen)

        #expect(resolved.count == 1)
        let one = try! #require(resolved.first)
        #expect(one.edge.kind == .blocks)
        #expect(one.edge.from == arrival.id, "`after X` means X must finish first")
        #expect(one.edge.to == waiter)
        #expect(!one.edge.confirmed, "invariant 3: a human confirms, not a sweeper")
        #expect(one.edge.source == .t0Rule)
    }

    /// `before` is the direction that would silently invert if the backfill
    /// re-implemented the rule instead of sharing `Edge.blocking`.
    @Test("`before` resolves the other way round")
    func beforeResolvesBackwards() {
        var gen = generator()
        let waiter = gen.next()
        let arrival = item(gen.next(), "the release call")

        let resolved = DependencyBackfill.resolve(
            pending: [
                reference(itemId: waiter, text: "the release call", direction: .blocksReferent)
            ],
            against: arrival, now: Self.now, idGenerator: &gen)

        #expect(resolved.first?.edge.from == waiter, "this item must finish first")
        #expect(resolved.first?.edge.to == arrival.id)
    }

    @Test("Confidence is the phrase times the match, with no penalty for waiting")
    func confidenceFormula() {
        var gen = generator()
        let waiter = gen.next()
        let arrival = item(gen.next(), "the pooler thing")

        let fresh = DependencyBackfill.resolve(
            pending: [reference(itemId: waiter, confidence: 0.8)], against: arrival,
            now: Self.now, idGenerator: &gen)
        let late = DependencyBackfill.resolve(
            pending: [reference(itemId: waiter, confidence: 0.8, ago: 20 * Self.day)],
            against: arrival, now: Self.now, idGenerator: &gen)

        let score = TitleMatcher.score("the pooler thing", "the pooler thing")
        #expect(abs((fresh.first?.edge.confidence ?? 0) - 0.8 * score) < 0.0001)
        #expect(fresh.first?.edge.confidence == late.first?.edge.confidence)
    }

    // MARK: - What it refuses

    @Test("An item never satisfies its own reference")
    func noSelfLink() {
        var gen = generator()
        let itself = gen.next()
        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: itself)], against: item(itself, "the pooler thing"),
            now: Self.now, idGenerator: &gen)
        #expect(resolved.isEmpty)
    }

    @Test(
        "Something merely similar does not resolve",
        arguments: [
            ("pay rent", "pay loan"),
            ("review the PR", "review the budget"),
            ("book scooter test ride", "book flight tickets"),
        ])
    func noLooseMatch(referent: String, arrival: String) {
        var gen = generator()
        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: gen.next(), text: referent)],
            against: item(gen.next(), arrival), now: Self.now, idGenerator: &gen)
        #expect(resolved.isEmpty, "\(referent) || \(arrival)")
    }

    /// **A false positive this shares with the live path, recorded rather
    /// than hidden.** Three shared words out of four clear `TitleMatcher`'s
    /// 0.5 floor: "call manager about raise" scores **0.637** against "call
    /// manager about leave", so a reference to one resolves against the
    /// other. `EnrichmentPipeline` has always behaved this way — `bestMatch`
    /// applies the same floor — so the backfill is not introducing it.
    ///
    /// Left alone deliberately. Raising the floor changes which `blocks`
    /// edges the live path proposes, which changes startability, which moves
    /// the ranking metrics; that is a measured change of its own, not
    /// something to slip in beside a new feature. The number is asserted here
    /// so a later change to the floor shows up as this test failing.
    @Test("A near-miss referent resolves, as it does on the live path")
    func knownFalsePositive() {
        var gen = generator()
        let score = TitleMatcher.score("call manager about raise", "call manager about leave")
        #expect(abs(score - 0.637) < 0.001, "measured, not assumed")

        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: gen.next(), text: "call manager about raise")],
            against: item(gen.next(), "call manager about leave"), now: Self.now,
            idGenerator: &gen)
        #expect(resolved.count == 1, "the floor lets this through, on both paths")
    }

    @Test("A closed item satisfies nothing")
    func closedSatisfiesNothing() {
        var gen = generator()
        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: gen.next())],
            against: item(gen.next(), "the pooler thing", status: .done), now: Self.now,
            idGenerator: &gen)
        #expect(resolved.isEmpty, "\"after the thing I already finished\" keeps waiting")
    }

    @Test(
        "Expiry is by when the phrase was written",
        arguments: [(29.0, 1), (31.0, 0)])
    func horizon(daysAgo: Double, expected: Int) {
        var gen = generator()
        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: gen.next(), ago: daysAgo * Self.day)],
            against: item(gen.next(), "the pooler thing"), now: Self.now, idGenerator: &gen)
        #expect(resolved.count == expected)
    }

    @Test("`expired` names the rows a sweeper should delete")
    func expiredRows() {
        var gen = generator()
        let old = reference(itemId: gen.next(), ago: 40 * Self.day)
        let recent = reference(itemId: gen.next(), ago: 2 * Self.day)
        let expired = DependencyBackfill.expired([old, recent], now: Self.now)
        #expect(expired == [old])
    }

    // MARK: - Determinism

    /// Rows arrive from a database in whatever order the query gives, and a
    /// ULID is minted per edge — so unsorted input would hand the same
    /// dependency a different id on every run.
    @Test("Row order does not change the edges or their ids")
    func orderIndependent() {
        // Two generators seeded alike, advanced alike, so any difference in
        // the edge ids comes from the input order and nothing else.
        var genA = generator()
        var genB = generator()
        var names = generator()
        let a = names.next()
        let b = names.next()
        let arrival = item(names.next(), "the pooler thing")
        let refs = [reference(itemId: a), reference(itemId: b)]

        let forwards = DependencyBackfill.resolve(
            pending: refs, against: arrival, now: Self.now, idGenerator: &genA)
        let backwards = DependencyBackfill.resolve(
            pending: refs.reversed(), against: arrival, now: Self.now, idGenerator: &genB)

        #expect(forwards.count == 2)
        #expect(forwards.map { $0.edge } == backwards.map { $0.edge })
    }

    @Test("The same phrase stored twice resolves once")
    func duplicateRowsResolveOnce() {
        var gen = generator()
        let waiter = gen.next()
        let twice = [reference(itemId: waiter), reference(itemId: waiter)]
        let resolved = DependencyBackfill.resolve(
            pending: twice, against: item(gen.next(), "the pooler thing"), now: Self.now,
            idGenerator: &gen)
        #expect(resolved.count == 1, "one statement, one edge")
    }

    @Test("Two different items waiting on the same thing both resolve")
    func manyWaitersOneArrival() {
        var gen = generator()
        let first = gen.next()
        let second = gen.next()
        let resolved = DependencyBackfill.resolve(
            pending: [reference(itemId: first), reference(itemId: second)],
            against: item(gen.next(), "the pooler thing"), now: Self.now, idGenerator: &gen)
        #expect(resolved.count == 2)
        #expect(Set(resolved.map { $0.edge.to }) == [first, second])
    }

    @Test("Nothing pending is not an error")
    func emptyIsFine() {
        var gen = generator()
        #expect(
            DependencyBackfill.resolve(
                pending: [], against: item(gen.next(), "anything"), now: Self.now,
                idGenerator: &gen
            ).isEmpty)
    }
}
