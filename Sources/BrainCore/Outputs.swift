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

    /// The day `commitments` was computed for, in the user's zone.
    public let day: CalendarDay

    /// Today's standing commitments: habits, rituals, payments and blocks
    /// (`docs/15-planner.md`).
    ///
    /// **A separate section, not rows in `ranked`** — and the separation is
    /// structural rather than a filter, because a `ScheduledCommitment` is not
    /// a `RankedItem` and there is no code path that could put one in the
    /// other. Nine daily commitments competing in the ranking would make "the
    /// one thing to do next" a habit checkbox every day of the year.
    ///
    /// Commitments are *scheduled*: the user already decided them, so they are
    /// never scored, never ranked and never compete with captured work.
    public let commitments: [ScheduledCommitment]

    /// The highlighted pick: the top **startable** item.
    ///
    /// Deliberately not `ranked.first`. A blocked item can legitimately rank
    /// first — it may unblock half the graph — but telling someone to do a task
    /// they cannot start is worse than saying nothing. It still appears at the
    /// top of `ranked`, with its blockers shown.
    public var next: RankedItem? { startable.first }

    /// Minutes still owed to today's commitments — the unfinished ones only.
    ///
    /// Exposed as a number, not applied. Subtracting it from the day and
    /// choosing what still fits is B-01's knapsack, which is a separate
    /// decision about *the user's* available time and does not belong inside
    /// a ranking pass.
    public var committedMinutes: Int { Commitment.committedMinutes(commitments) }
}

public enum Brain {

    /// Computes ranking, quick wins, blocked items and the day's commitments
    /// in one pass.
    ///
    /// `commitments` and `completed` are **defaulted**, so every existing
    /// caller — the server's `/v1/plan` included — keeps compiling and keeps
    /// behaving identically. Passing none yields an empty commitments section
    /// and an unchanged ranking.
    ///
    /// - Parameters:
    ///   - commitments: the user's standing commitments, all of them. Which
    ///     ones fall today is worked out here, in their zone.
    ///   - completed: completed occurrence days per commitment id. Absent
    ///     means none — a missing entry is never an error, because a missed
    ///     day is stored as nothing at all (`docs/15-planner.md`, D2).
    public static func compute(
        graph: BrainGraph, now: Date, calendar: Calendar,
        weights: ScoringWeights = .default,
        policy: EdgePolicy = .default,
        commitments: [Commitment] = [],
        completed: [ULID: Set<CalendarDay>] = [:]
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

        // The user's today, from the calendar's own zone — the same day the
        // scoring used to decide whether a period goal has lapsed.
        let today = CalendarDay(now, in: calendar.timeZone)
        let scheduled = Commitment.scheduled(commitments, on: today) {
            completed[$0.id] ?? []
        }

        return BrainOutputs(
            ranked: ranked, startable: startable,
            quickWins: quickWins, blocked: blocked,
            day: today, commitments: scheduled)
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
