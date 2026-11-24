import Foundation

/// Goals with a horizon: "this month" and "this quarter" (`docs/15-planner.md`).
///
/// **This is what makes leverage mean anything.** `servesGoals` is one of the
/// three terms in the formula, and in production it is 0 for every item,
/// because nothing assigns a goal — so ranking is really just unblocks plus
/// due pressure. A declared month goal, rolling up to a quarter goal, is the
/// missing input.
///
/// A goal with no period is still legal and still counts: not every goal has
/// a deadline, and the five existing ones in the datasets have none.

public enum GoalHorizon: String, Hashable, Sendable, Codable, CaseIterable {
    /// "Start the iOS contract job hunt flow."
    case month
    /// "iOS contract job. 25 reels. 10 videos."
    case quarter
}

/// A specific month or quarter. **Calendar quarters** — January–March is Q1,
/// not the Indian financial year (`docs/15-planner.md`, D3).
public struct GoalPeriod: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let horizon: GoalHorizon
    public let year: Int
    /// 1...12 for a month, 1...4 for a quarter.
    public let index: Int

    /// Fails on an index outside the horizon's range, so "month 13" cannot be
    /// stored and then surprise a view months later.
    public init?(horizon: GoalHorizon, year: Int, index: Int) {
        let upper = horizon == .month ? 12 : 4
        guard (1...upper).contains(index) else { return nil }
        self.horizon = horizon
        self.year = year
        self.index = index
    }

    /// The period a day falls in. Total — every day is in exactly one month
    /// and one quarter.
    public static func containing(_ day: CalendarDay, horizon: GoalHorizon) -> GoalPeriod {
        switch horizon {
        case .month:
            GoalPeriod(horizon: .month, year: day.year, index: day.month)!
        case .quarter:
            GoalPeriod(horizon: .quarter, year: day.year, index: day.quarter)!
        }
    }

    /// First month of the period: the month itself, or the quarter's first.
    var firstMonth: Int { horizon == .month ? index : (index - 1) * 3 + 1 }
    var lastMonth: Int { horizon == .month ? index : (index - 1) * 3 + 3 }

    public var start: CalendarDay {
        CalendarDay(year: year, month: firstMonth, day: 1)
            ?? CalendarDay(year: year, month: 1, day: 1)!
    }

    /// Inclusive, and aware that months are not all the same length.
    public var end: CalendarDay {
        let firstOfLastMonth =
            CalendarDay(year: year, month: lastMonth, day: 1)
            ?? CalendarDay(year: year, month: 12, day: 1)!
        return CalendarDay(
            year: year, month: lastMonth, day: firstOfLastMonth.lastDayOfMonth)
            ?? firstOfLastMonth
    }

    public func contains(_ day: CalendarDay) -> Bool {
        day >= start && day <= end
    }

    /// Whether this period wholly contains another — the test for whether a
    /// month goal may roll up into a quarter goal.
    public func contains(_ other: GoalPeriod) -> Bool {
        other.start >= start && other.end <= end
    }

    /// The month or quarter after this one, rolling the year over.
    public var next: GoalPeriod {
        let upper = horizon == .month ? 12 : 4
        return index == upper
            ? GoalPeriod(horizon: horizon, year: year + 1, index: 1)!
            : GoalPeriod(horizon: horizon, year: year, index: index + 1)!
    }

    /// The month or quarter before this one. What the review looks back at.
    public var previous: GoalPeriod {
        let upper = horizon == .month ? 12 : 4
        return index == 1
            ? GoalPeriod(horizon: horizon, year: year - 1, index: upper)!
            : GoalPeriod(horizon: horizon, year: year, index: index - 1)!
    }

    /// The quarter a month sits in. Nil for a period that is already a
    /// quarter — there is no enclosing quarter to find.
    public var enclosingQuarter: GoalPeriod? {
        guard horizon == .month else { return nil }
        return GoalPeriod(horizon: .quarter, year: year, index: (index - 1) / 3 + 1)
    }

    /// Month names are a fixed table rather than a `DateFormatter`, so the
    /// text is the same on every machine and in every test, whatever the
    /// locale happens to be.
    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    public var text: String {
        switch horizon {
        case .month: "\(Self.monthNames[index - 1]) \(year)"
        case .quarter: "Q\(index) \(year)"
        }
    }

    public var description: String {
        switch horizon {
        case .month: String(format: "%04d-%02d", year, index)
        case .quarter: "\(year)-Q\(index)"
        }
    }

    /// Ordered by when the period starts, then by how long it runs, so a
    /// quarter and the month that opens it never compare equal.
    public static func < (a: GoalPeriod, b: GoalPeriod) -> Bool {
        (a.start, a.end) < (b.start, b.end)
    }
}

extension Goal {
    /// Whether this goal should pull on the ranking on `day`.
    ///
    /// A **lapsed** period goal does not: last month's goal must stop
    /// inflating today's scores, or the ranking drifts further from the user's
    /// actual intent every month. Closing it out is what the monthly review is
    /// for, and until the user does, the period boundary speaks for them.
    ///
    /// A **future** period goal does count. Working ahead on next month's goal
    /// is a good thing, and penalising it would be strange.
    ///
    /// A goal with **no period** always counts while it is active — that is
    /// the behaviour every existing goal has, and it is unchanged.
    public func counts(on day: CalendarDay) -> Bool {
        guard status == .active else { return false }
        guard let period else { return true }
        return day <= period.end
    }

    /// Whether this goal may roll up into `parent`: a month inside a quarter
    /// that actually contains it.
    ///
    /// Deliberately a predicate rather than an enforced invariant. The server
    /// owns rejecting a bad write (`docs/15-planner.md`); `BrainGraph.insert`
    /// stays non-throwing so a single odd row can never cost the user their
    /// whole plan.
    public func canRollUp(into parent: Goal) -> Bool {
        guard parent.id != id else { return false }
        guard let mine = period, let theirs = parent.period else { return false }
        guard mine.horizon == .month, theirs.horizon == .quarter else { return false }
        return theirs.contains(mine)
    }
}
