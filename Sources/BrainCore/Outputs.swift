import Foundation

/// A ranked item with everything the UI needs to show and justify it.
public struct RankedItem: Sendable, Hashable {
    public let item: Item
    public let breakdown: ScoreBreakdown
    public let reason: String
}

public struct BlockedItem: Sendable, Hashable {
    public let item: Item
    /// Open items that must finish first, in deterministic order.
    public let blockers: [Item]
}

/// Everything the product shows, computed deterministically from the graph.
/// No model participates in any of this.
public struct BrainOutputs: Sendable {
    /// Every open item, ranked. The UI shows all of these — the user decides.
    public let ranked: [RankedItem]
    /// The same order, minus items with an open blocker.
    public let startable: [RankedItem]
    public let quickWins: [RankedItem]
    public let blocked: [BlockedItem]

    /// The highlighted pick: the top **startable** item.
    ///
    /// Deliberately not `ranked.first`. A blocked item can legitimately rank
    /// first — it may unblock half the graph — but telling someone to do a task
    /// they cannot start is worse than saying nothing. It still appears at the
    /// top of `ranked`, with its blockers shown.
    public var next: RankedItem? { startable.first }
}

public enum Brain {

    /// Computes ranking, quick wins and blocked items in one pass.
    public static func compute(
        graph: BrainGraph, now: Date, calendar: Calendar,
        weights: ScoringWeights = .default,
        policy: EdgePolicy = .default
    ) -> BrainOutputs {
        let breakdowns = Scoring.rank(
            graph: graph, now: now, calendar: calendar,
            weights: weights, policy: policy)

        let ranked: [RankedItem] = breakdowns.compactMap { breakdown in
            guard let item = graph.items[breakdown.itemId] else { return nil }
            return RankedItem(
                item: item, breakdown: breakdown,
                reason: Explain.reason(
                    for: item, breakdown: breakdown,
                    now: now, calendar: calendar))
        }

        // Blocked: at least one open blocker. These are excluded from quick wins —
        // suggesting something a user cannot start would be actively unhelpful.
        let blockedIds = Set(ranked.map(\.item.id).filter { !graph.blockers(of: $0).isEmpty })

        let startable = ranked.filter { !blockedIds.contains($0.item.id) }
        let quickWins = Self.quickWins(from: startable)

        let blocked: [BlockedItem] =
            ranked
            .filter { blockedIds.contains($0.item.id) }
            .map { r in
                BlockedItem(
                    item: r.item,
                    blockers: graph.blockers(of: r.item.id).compactMap { graph.items[$0] })
            }

        return BrainOutputs(
            ranked: ranked, startable: startable,
            quickWins: quickWins, blocked: blocked)
    }

    /// Low effort **and** leverage at or above the median of the candidates.
    ///
    /// The median is taken over startable items only, so a backlog full of
    /// blocked work cannot drag the bar down and let weak quick wins through.
    static func quickWins(from candidates: [RankedItem]) -> [RankedItem] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.map(\.breakdown.leverage).sorted()
        let median: Double =
            sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return candidates.filter {
            $0.item.effortBucket.isQuick
                && $0.breakdown.leverage >= median - Scoring.leverageEpsilon
        }
    }
}
