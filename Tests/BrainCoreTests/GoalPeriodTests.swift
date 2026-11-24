import Foundation
import Testing

@testable import BrainCore

/// Goals with a horizon (`docs/15-planner.md`).
///
/// The point of all this is the last suite in the file: a **lapsed** goal must
/// stop pulling on the ranking, and an **open-ended** one must behave exactly
/// as it always has, so no existing dataset moves.
@Suite("Goal periods")
struct GoalPeriodTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay {
        CalendarDay(year: y, month: m, day: d)!
    }
    static func month(_ y: Int, _ i: Int) -> GoalPeriod {
        GoalPeriod(horizon: .month, year: y, index: i)!
    }
    static func quarter(_ y: Int, _ i: Int) -> GoalPeriod {
        GoalPeriod(horizon: .quarter, year: y, index: i)!
    }

    // MARK: - Construction

    @Test("An index outside the horizon is refused")
    func rejectsBadIndex() {
        #expect(GoalPeriod(horizon: .month, year: 2026, index: 0) == nil)
        #expect(GoalPeriod(horizon: .month, year: 2026, index: 13) == nil)
        #expect(GoalPeriod(horizon: .quarter, year: 2026, index: 5) == nil)
        #expect(GoalPeriod(horizon: .quarter, year: 2026, index: 0) == nil)
        #expect(GoalPeriod(horizon: .month, year: 2026, index: 12) != nil)
        #expect(GoalPeriod(horizon: .quarter, year: 2026, index: 4) != nil)
    }

    @Test("Every day lands in exactly one month and one quarter")
    func containing() {
        let day = Self.day(2026, 11, 24)
        #expect(GoalPeriod.containing(day, horizon: .month) == Self.month(2026, 11))
        #expect(GoalPeriod.containing(day, horizon: .quarter) == Self.quarter(2026, 4))
        #expect(
            GoalPeriod.containing(Self.day(2027, 1, 1), horizon: .quarter) == Self.quarter(2027, 1))
        #expect(
            GoalPeriod.containing(Self.day(2027, 3, 31), horizon: .quarter) == Self.quarter(2027, 1)
        )
        #expect(
            GoalPeriod.containing(Self.day(2027, 4, 1), horizon: .quarter) == Self.quarter(2027, 2))
    }

    // MARK: - Bounds

    @Test("Month bounds know how long the month is")
    func monthBounds() {
        #expect(Self.month(2026, 11).start == Self.day(2026, 11, 1))
        #expect(Self.month(2026, 11).end == Self.day(2026, 11, 30))
        #expect(Self.month(2027, 2).end == Self.day(2027, 2, 28))
        #expect(Self.month(2028, 2).end == Self.day(2028, 2, 29), "leap year")
        #expect(Self.month(2026, 12).end == Self.day(2026, 12, 31))
    }

    @Test("Quarter bounds are calendar quarters")
    func quarterBounds() {
        #expect(Self.quarter(2027, 1).start == Self.day(2027, 1, 1))
        #expect(Self.quarter(2027, 1).end == Self.day(2027, 3, 31))
        #expect(Self.quarter(2027, 2).start == Self.day(2027, 4, 1))
        #expect(Self.quarter(2027, 2).end == Self.day(2027, 6, 30))
        #expect(Self.quarter(2027, 4).end == Self.day(2027, 12, 31))
        #expect(
            Self.quarter(2027, 2).start != Self.day(2027, 4, 1).adding(days: -1),
            "Q2 is April–June, not the Indian financial year")
    }

    @Test("Containment, for days and for other periods")
    func containment() {
        let q4 = Self.quarter(2026, 4)
        #expect(q4.contains(Self.day(2026, 10, 1)))
        #expect(q4.contains(Self.day(2026, 12, 31)))
        #expect(!q4.contains(Self.day(2026, 9, 30)))
        #expect(!q4.contains(Self.day(2027, 1, 1)))

        #expect(q4.contains(Self.month(2026, 11)))
        #expect(q4.contains(Self.month(2026, 10)))
        #expect(q4.contains(Self.month(2026, 12)))
        #expect(!q4.contains(Self.month(2026, 9)))
        #expect(!q4.contains(Self.quarter(2026, 3)))
        #expect(q4.contains(q4), "a period contains itself")
    }

    // MARK: - Walking

    @Test("Next and previous roll the year over")
    func nextPrevious() {
        #expect(Self.month(2026, 12).next == Self.month(2027, 1))
        #expect(Self.month(2027, 1).previous == Self.month(2026, 12))
        #expect(Self.quarter(2026, 4).next == Self.quarter(2027, 1))
        #expect(Self.quarter(2027, 1).previous == Self.quarter(2026, 4))
        #expect(Self.month(2026, 11).next == Self.month(2026, 12))
        #expect(Self.month(2026, 11).previous == Self.month(2026, 10))
    }

    /// What the monthly review does: look back at last month, plan this one.
    @Test("The review's two periods")
    func reviewPeriods() {
        let thisMonth = GoalPeriod.containing(Self.day(2026, 12, 5), horizon: .month)
        #expect(thisMonth.text == "December 2026")
        #expect(thisMonth.previous.text == "November 2026")
    }

    @Test("A month knows its quarter; a quarter has none to find")
    func enclosingQuarter() {
        #expect(Self.month(2026, 11).enclosingQuarter == Self.quarter(2026, 4))
        #expect(Self.month(2027, 1).enclosingQuarter == Self.quarter(2027, 1))
        #expect(Self.month(2027, 3).enclosingQuarter == Self.quarter(2027, 1))
        #expect(Self.month(2027, 4).enclosingQuarter == Self.quarter(2027, 2))
        #expect(Self.quarter(2027, 1).enclosingQuarter == nil)
    }

    @Test("Text and keys are locale-independent")
    func textAndKeys() {
        #expect(Self.month(2026, 11).text == "November 2026")
        #expect(Self.month(2027, 1).text == "January 2027")
        #expect(Self.quarter(2027, 3).text == "Q3 2027")
        #expect(Self.month(2026, 11).description == "2026-11")
        #expect(Self.month(2026, 1).description == "2026-01")
        #expect(Self.quarter(2026, 4).description == "2026-Q4")
    }

    @Test("A quarter and the month that opens it are not equal and do not tie")
    func ordering() {
        let q1 = Self.quarter(2027, 1)
        let jan = Self.month(2027, 1)
        #expect(q1 != jan)
        #expect(jan < q1, "same start, shorter span sorts first")
        #expect(Self.month(2026, 11) < Self.month(2026, 12))
        #expect(Self.quarter(2026, 4) < Self.quarter(2027, 1))
    }

    // MARK: - Goals

    static func goal(
        _ seed: UInt64, _ title: String, status: GoalStatus = .active,
        period: GoalPeriod? = nil, parent: ULID? = nil
    ) -> Goal {
        var gen = ULIDGenerator(seed: seed)
        return Goal(
            id: gen.next(), title: title, status: status, createdAt: Fixtures.now,
            period: period, parentId: parent)
    }

    @Test("An open-ended goal counts whenever it is active")
    func openEndedGoalCounts() {
        let g = Self.goal(1, "ship v1")
        #expect(g.counts(on: Self.day(2026, 11, 24)))
        #expect(g.counts(on: Self.day(2030, 1, 1)), "no period, so it never lapses")
    }

    @Test("A goal that is not active never counts")
    func inactiveGoalNeverCounts() {
        let today = Self.day(2026, 11, 24)
        #expect(
            !Self.goal(1, "done", status: .achieved, period: Self.month(2026, 11)).counts(on: today)
        )
        #expect(!Self.goal(2, "gave up", status: .abandoned).counts(on: today))
    }

    /// The whole reason periods exist: last month stops inflating today.
    @Test("A lapsed period goal stops counting")
    func lapsedGoalStopsCounting() {
        let g = Self.goal(3, "October goal", period: Self.month(2026, 10))
        #expect(g.counts(on: Self.day(2026, 10, 31)), "still live on its last day")
        #expect(!g.counts(on: Self.day(2026, 11, 1)), "lapsed the next morning")
    }

    @Test("A future period goal still counts — working ahead is not penalised")
    func futureGoalCounts() {
        let g = Self.goal(4, "January goal", period: Self.month(2027, 1))
        #expect(g.counts(on: Self.day(2026, 12, 20)))
    }

    @Test("A month goal rolls up only into a quarter that contains it")
    func rollUp() {
        let q4 = Self.goal(5, "iOS contract job", period: Self.quarter(2026, 4))
        let nov = Self.goal(6, "start the hunt flow", period: Self.month(2026, 11))
        let sep = Self.goal(7, "september thing", period: Self.month(2026, 9))

        #expect(nov.canRollUp(into: q4))
        #expect(!sep.canRollUp(into: q4), "September is Q3")
        #expect(!q4.canRollUp(into: q4), "not into itself")
        #expect(
            !q4.canRollUp(into: Self.goal(8, "another", period: Self.quarter(2026, 4))),
            "a quarter does not roll up into a quarter")
        #expect(!Self.goal(9, "no period").canRollUp(into: q4))
        #expect(!nov.canRollUp(into: Self.goal(10, "open-ended parent")))
    }

    // MARK: - The graph

    @Test("Goals can be found by period, and children by parent")
    func graphLookups() {
        var gen = Fixtures.generator()
        let quarterGoal = Goal(
            id: gen.next(), title: "iOS contract job", createdAt: Fixtures.now,
            period: Self.quarter(2026, 4))
        let novGoal = Goal(
            id: gen.next(), title: "start the hunt flow", createdAt: Fixtures.now,
            period: Self.month(2026, 11), parentId: quarterGoal.id)
        // Names a parent it does not fit inside: a bad write, left out.
        let strayGoal = Goal(
            id: gen.next(), title: "september thing", createdAt: Fixtures.now,
            period: Self.month(2026, 9), parentId: quarterGoal.id)
        let openEnded = Goal(id: gen.next(), title: "ship v1", createdAt: Fixtures.now)

        var graph = BrainGraph()
        for g in [quarterGoal, novGoal, strayGoal, openEnded] { graph.insert(g) }

        #expect(graph.goals(in: Self.month(2026, 11)).map(\.id) == [novGoal.id])
        #expect(graph.goals(in: Self.quarter(2026, 4)).map(\.id) == [quarterGoal.id])
        #expect(graph.goals(in: Self.month(2026, 12)).isEmpty)
        #expect(
            graph.children(of: quarterGoal.id).map(\.id) == [novGoal.id],
            "the September goal names this parent but does not fit inside it")
        #expect(graph.children(of: openEnded.id).isEmpty)
    }

    // MARK: - Scoring

    /// `Fixtures.now` is 23 November 2026, so a November goal is live and an
    /// October one has lapsed. Same graph shape, same edges, different period:
    /// only the goal term should differ.
    @Test("A lapsed goal no longer contributes to leverage")
    func lapsedGoalDoesNotScore() {
        var gen = Fixtures.generator()
        let liveGoal = Goal(
            id: gen.next(), title: "November", createdAt: Fixtures.now,
            period: Self.month(2026, 11))
        let lapsedGoal = Goal(
            id: gen.next(), title: "October", createdAt: Fixtures.now,
            period: Self.month(2026, 10))
        let servesLive = Fixtures.item(&gen, "serves the live goal", effort: .small)
        let servesLapsed = Fixtures.item(&gen, "serves the lapsed goal", effort: .small)

        var graph = BrainGraph()
        graph.insert(liveGoal)
        graph.insert(lapsedGoal)
        graph.insert(servesLive)
        graph.insert(servesLapsed)
        try? graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: servesLive.id, to: liveGoal.id, kind: .serves))
        try? graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: servesLapsed.id, to: lapsedGoal.id, kind: .serves))

        let live = Scoring.score(
            item: servesLive, in: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        let lapsed = Scoring.score(
            item: servesLapsed, in: graph, now: Fixtures.now, calendar: Fixtures.calendar)

        #expect(live.goalsConfirmed == 1)
        #expect(lapsed.goalsConfirmed == 0, "October ended three weeks ago")
        #expect(live.leverage > lapsed.leverage, "identical but for the period")
    }

    /// Guards the claim in `goalsServed`'s doc comment, and the reason the
    /// scorecard numbers did not move when periods landed.
    @Test("An open-ended goal scores exactly as it always did")
    func openEndedGoalScoresUnchanged() {
        var gen = Fixtures.generator()
        let goal = Goal(id: gen.next(), title: "ship v1", createdAt: Fixtures.now)
        let item = Fixtures.item(&gen, "serves it", effort: .small)
        var graph = BrainGraph()
        graph.insert(goal)
        graph.insert(item)
        try? graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: item.id, to: goal.id, kind: .serves))

        let breakdown = Scoring.score(
            item: item, in: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(breakdown.goalsConfirmed == 1)

        // And the un-dated path through the graph agrees with the dated one.
        #expect(
            graph.goalsServed(by: item.id, confirmedOnly: true, maxDepth: 3)
                == graph.goalsServed(
                    by: item.id, confirmedOnly: true, maxDepth: 3,
                    on: Self.day(2026, 11, 23)))
    }
}
