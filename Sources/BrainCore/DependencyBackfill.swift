import Foundation

/// Resolving dependencies whose referent arrived later than the phrase.
///
/// The gap this closes: "deploy after the pooler thing", captured before the
/// pooler item exists, parses correctly and matches nothing. The pipeline now
/// keeps it as a `PendingReference`; this is what looks again when a new item
/// shows up. Nothing retried before — the sweeper only requeues captures that
/// are `raw`, stuck or `failed`, and a capture whose dependency missed is
/// `enriched` and perfectly healthy.
///
/// **Pure, and deliberately graph-blind.** It sees pending references and one
/// item, never the graph. Two consequences, both intended:
///
/// - It cannot tell whether an equivalent edge already exists. The caller
///   holds the graph and `BrainGraph.insert` is the authority on duplicates.
/// - It cannot tell whether the edge would close a cycle. It does not need
///   to: `BrainGraph.insert` rejects cycle-forming `blocks` edges regardless
///   of which tier proposed them, and the live path in `EnrichmentPipeline`
///   does not pre-check either. Checking here and not there would be the
///   inconsistency, not the fix.
public enum DependencyBackfill {

    /// How long a stated dependency stays worth resolving.
    ///
    /// **Chosen, not measured.** There is no data on how long a referent
    /// takes to arrive, because until now nothing was ever kept long enough
    /// to find out. 30 days is an argument, not a finding: a month is long
    /// enough to cover "I'll capture the other half next week" and short
    /// enough that a phrase from last quarter does not silently attach itself
    /// to an unrelated item that happens to share two words.
    ///
    /// Revisit once there is a month of real pending references to count —
    /// the distribution of `writtenAt` to resolution is exactly the thing
    /// this guesses at.
    public static let defaultHorizon: TimeInterval = 30 * 24 * 60 * 60

    /// How much of the referent and the arriving title must be shared.
    ///
    /// **The live path's matcher cannot be reused here, and that is measured,
    /// not assumed.** `TitleMatcher.score` carries a containment bonus: a
    /// short referent scores 0.850 against any longer title that contains it.
    /// On the live path that is harmless and often right, because
    /// `bestMatch` takes the *argmax* over every open item — when the real
    /// referent exists it scores higher and wins the competition.
    ///
    /// The backfill has no competition. It asks "does this one item satisfy
    /// this reference?" against a floor, one reference at a time, so a 0.850
    /// containment hit is accepted on its own. The first audit of the dev
    /// split showed what that means in practice: **seven resolutions, none of
    /// them correct.** Every one linked an item waiting for X to *another
    /// item waiting for X*, because "after the design review" contains "the
    /// design review" and therefore scores 0.850 against a reference to it.
    ///
    /// Plain overlap separates those cleanly where `score` cannot:
    ///
    /// | pair | `score` | `overlap` |
    /// |---|---|---|
    /// | "the design review" vs "the design review ke baad reply…" | 0.850 | 0.286 |
    /// | "Priya's reply" vs "…restock printer ink waiting for Priya's reply" | 0.850 | 0.250 |
    /// | "lunch" vs "stretch after lunch today 20 minutes" | 0.850 | 0.167 |
    /// | "Priya's reply" vs "reply to priya poora din" | 0.850 | 0.500 |
    /// | "schema review" vs "schema review with the team" | 0.850 | 0.500 |
    /// | "the design review" vs "design review" | 1.000 | 1.000 |
    ///
    /// 0.5 sits in a band from 0.286 to 0.500. **Nine hand-picked pairs are
    /// not a validation set** — the band is wider than the duplicate
    /// threshold's was, which is some comfort and not proof. What is solid is
    /// the negative result: no floor on `score` separates these at all,
    /// because `score` gives 0.850 to the right answers and the wrong ones
    /// alike.
    public static let minimumOverlap = 0.5

    /// One pending reference, satisfied.
    ///
    /// The reference is handed back alongside the edge so the caller can
    /// delete the row it came from. A reference must be consumed once: left
    /// in place, a single phrase would link itself to every future item that
    /// happens to match.
    public struct Resolution: Sendable, Hashable {
        public let reference: PendingReference
        public let edge: Edge
        /// What `TitleMatcher` scored the referent against the new title.
        public let score: Double

        public init(reference: PendingReference, edge: Edge, score: Double) {
            self.reference = reference
            self.edge = edge
            self.score = score
        }
    }

    /// Pending references that `item` satisfies.
    ///
    /// Confidence is `reference.confidence * score`, exactly as the live path
    /// computes it. **No penalty for having waited:** a decay factor would be
    /// invented, and an edge proposed three weeks late is no less likely to
    /// be right than one proposed immediately — it is the same phrase and the
    /// same title match. It is also unconfirmed either way, so the user sees
    /// it before it counts.
    ///
    /// - Parameters:
    ///   - pending: references the caller has kept, in any order.
    ///   - item: the newly arrived item that might satisfy them.
    ///   - now: used only for expiry.
    ///   - minOverlap: how much of the two titles must be shared. See
    ///     `minimumOverlap` for why this is not the live path's floor.
    public static func resolve(
        pending: [PendingReference],
        against item: Item,
        now: Date,
        idGenerator: inout ULIDGenerator,
        minOverlap: Double = minimumOverlap,
        horizon: TimeInterval = defaultHorizon
    ) -> [Resolution] {
        // A closed item satisfies nothing: `EnrichmentPipeline` only ever
        // offers open items as candidates, and "after the thing I already
        // finished" should keep waiting for a new one.
        guard item.status.isOpen else { return [] }

        // Sorted before any id is minted, so the caller's row order cannot
        // change the edge ids. Rows arrive from a database in whatever order
        // the query gives, and `idGenerator` advances per edge — unsorted,
        // the same inputs would produce different ids run to run.
        let candidates =
            Set(pending)
            .filter { $0.itemId != item.id }  // never link an item to itself
            .filter { now.timeIntervalSince($0.writtenAt) <= horizon }
            .sorted {
                ($0.itemId, $0.targetText, $0.direction.rawValue)
                    < ($1.itemId, $1.targetText, $1.direction.rawValue)
            }

        var resolutions: [Resolution] = []
        for reference in candidates {
            // `overlap`, not `score`. Measured, not assumed — see
            // `minimumOverlap`.
            let score = TitleMatcher.overlap(reference.targetText, item.title)
            guard score >= minOverlap else { continue }
            resolutions.append(
                Resolution(
                    reference: reference,
                    edge: Edge.blocking(
                        id: idGenerator.next(), item: reference.itemId, referent: item.id,
                        direction: reference.direction,
                        confidence: reference.confidence * score),
                    score: score))
        }
        return resolutions
    }

    /// References too old to be worth keeping, for the caller to delete.
    ///
    /// Separate from `resolve` on purpose: expiry happens on a schedule,
    /// resolution happens on arrival, and a sweeper should not have to
    /// invent an item to call this.
    public static func expired(
        _ pending: [PendingReference], now: Date, horizon: TimeInterval = defaultHorizon
    ) -> [PendingReference] {
        pending.filter { now.timeIntervalSince($0.writtenAt) > horizon }
    }
}
