import Foundation

/// Weights for the leverage formula. Defaults from `docs/02-scoring-spec.md`.
/// Tunable on the dev split only — never on test.
public struct ScoringWeights: Sendable, Hashable {
    /// Without a base term every unlinked leaf task scores exactly 0 and the
    /// whole list ties. With it, a leaf ranks on effort alone — which is what
    /// "quick win" means. Quick wins fall out of the formula, not a special case.
    public var base: Double = 0.5
    public var unblocked: Double = 1.0
    public var goals: Double = 1.5
    public var due: Double = 0.8
    /// Days out at which deadline pressure reaches zero.
    public var duePressureHorizonDays: Double = 14
    /// Reference bucket for the effort denominator (`small` = 20 min → E = 1).
    public var effortReferenceMinutes: Double = 20

    /// How hard effort is divided out: `numerator / E^effortExponent`.
    ///
    /// 1.0 is leverage-per-unit-effort. **0.0 ignores effort entirely**, which
    /// is not as odd as it sounds: `quick wins` is already a separate list, so
    /// the main ranking does not also have to be the cheap-things list.
    ///
    /// Exists because the diagnosis showed the formula is structurally biased,
    /// not merely mistuned: when our top pick differs from Ganesh's, his is on
    /// average **eight times heavier** (150 min vs 19 min), and heavier in
    /// 77% of disagreements. Dividing by effort is what causes that.
    public var effortExponent: Double = 1.0

    public init() {}
    public static let `default` = ScoringWeights()
}

/// Every term that produced a score, kept so the explanation template is filled
/// from facts rather than recomputed (`Explain.swift`).
public struct ScoreBreakdown: Sendable, Hashable {
    public let itemId: ULID
    /// Items unblocked via confirmed edges — the number shown to the user.
    public let unblockedConfirmed: Int
    /// Additional items reachable only via unconfirmed edges.
    public let unblockedAdditional: Int
    public let goalsConfirmed: Int
    public let goalsAdditional: Int
    public let duePressure: Double
    public let effort: EffortBucket
    public let effortDenominator: Double
    public let leverage: Double
}

public enum Scoring {

    /// Effort denominator: `ln(1 + minutes) / ln(1 + 20)`.
    ///
    /// Compressed deliberately. On raw minutes the tiny:xlarge ratio is 1:192,
    /// and a trivial errand would always outrank a half-day task that unblocks
    /// six things. Compressed, it is ~1:3.8.
    public static func effortDenominator(
        _ bucket: EffortBucket,
        weights: ScoringWeights = .default
    ) -> Double {
        log1p(bucket.minutes) / log1p(weights.effortReferenceMinutes)
    }

    /// Deadline pressure in [0, 1]. Zero when there is no due date.
    ///
    /// Only T0-parsed dates reach here — a model-guessed date never creates
    /// deadline pressure (`docs/07-harness-spec.md`, guard 5).
    public static func duePressure(
        dueAt: Date?, now: Date, calendar: Calendar,
        weights: ScoringWeights = .default
    ) -> Double {
        guard let dueAt else { return 0 }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDue = calendar.startOfDay(for: dueAt)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDue).day ?? 0
        if days <= 0 { return 1.0 }  // overdue or due today
        return max(0, 1 - Double(days) / weights.duePressureHorizonDays)
    }

    /// Computes the full breakdown for one item.
    public static func score(
        item: Item, in graph: BrainGraph, now: Date,
        calendar: Calendar,
        weights: ScoringWeights = .default,
        policy: EdgePolicy = .default
    ) -> ScoreBreakdown {
        let confirmedUnblocked = graph.transitivelyUnblocked(
            from: item.id, confirmedOnly: true, maxDepth: policy.maxDepth)
        let allUnblocked = graph.transitivelyUnblocked(
            from: item.id, confirmedOnly: false, maxDepth: policy.maxDepth)
        let additionalUnblocked = allUnblocked.subtracting(confirmedUnblocked)

        // "Today" in the user's zone, which is what decides whether a period
        // goal has lapsed. No new parameter: the calendar already carries the
        // zone, and the plan is always computed in it.
        let today = CalendarDay(now, in: calendar.timeZone)

        let confirmedGoals = graph.goalsServed(
            by: item.id, confirmedOnly: true, maxDepth: policy.maxDepth, on: today)
        let allGoals = graph.goalsServed(
            by: item.id, confirmedOnly: false, maxDepth: policy.maxDepth, on: today)
        let additionalGoals = allGoals.subtracting(confirmedGoals)

        let u = Double(confirmedUnblocked.count) + policy.alpha * Double(additionalUnblocked.count)
        let g = Double(confirmedGoals.count) + policy.alpha * Double(additionalGoals.count)
        let d = duePressure(
            dueAt: item.dueAt.value, now: now,
            calendar: calendar, weights: weights)

        let bucket = item.effortBucket
        let rawDenominator = effortDenominator(bucket, weights: weights)
        let e = pow(rawDenominator, weights.effortExponent)
        let numerator =
            weights.base
            + weights.unblocked * log1p(u)
            + weights.goals * log1p(g)
            + weights.due * d

        return ScoreBreakdown(
            itemId: item.id,
            unblockedConfirmed: confirmedUnblocked.count,
            unblockedAdditional: additionalUnblocked.count,
            goalsConfirmed: confirmedGoals.count,
            goalsAdditional: additionalGoals.count,
            duePressure: d,
            effort: bucket,
            effortDenominator: e,
            leverage: numerator / e
        )
    }

    /// Scores below this distance apart are treated as tied, so the
    /// deterministic tie-break keys decide instead of floating-point noise.
    static let leverageEpsilon = 1e-9

    /// Ranks all **open** items into a strict total order.
    ///
    /// Tie-break, applied in order (`docs/02-scoring-spec.md`):
    /// 1. leverage descending
    /// 2. dueAt ascending, nulls last
    /// 3. effort minutes ascending
    /// 4. createdAt ascending
    /// 5. id ascending — guarantees no two items ever tie
    /// Whether this item belongs in the plan.
    ///
    /// **An item whose type is not yet known still ranks.** `type` is
    /// `Classified`, and it is nil while the ladder abstained and a T3
    /// question is waiting for an answer. Hiding those would mean a capture
    /// silently absent from the plan until the user answers a question they
    /// have not been shown yet — and a capture is never lost. Showing
    /// something you can dismiss is the recoverable direction.
    public static func appearsInPlan(_ item: Item) -> Bool {
        item.type.value?.appearsInPlan ?? true
    }

    public static func rank(
        graph: BrainGraph, now: Date, calendar: Calendar,
        weights: ScoringWeights = .default,
        policy: EdgePolicy = .default
    ) -> [ScoreBreakdown] {
        let scored = graph.openItems.filter(appearsInPlan).map { item in
            (
                item,
                score(
                    item: item, in: graph, now: now, calendar: calendar,
                    weights: weights, policy: policy)
            )
        }
        return scored.sorted { a, b in
            if abs(a.1.leverage - b.1.leverage) > leverageEpsilon {
                return a.1.leverage > b.1.leverage
            }
            switch (a.0.dueAt.value, b.0.dueAt.value) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true  // nulls last
            case (nil, _?): return false
            default: break
            }
            if a.0.effortBucket.minutes != b.0.effortBucket.minutes {
                return a.0.effortBucket.minutes < b.0.effortBucket.minutes
            }
            if a.0.createdAt != b.0.createdAt { return a.0.createdAt < b.0.createdAt }
            return a.0.id < b.0.id
        }.map(\.1)
    }
}
