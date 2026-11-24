import Foundation
import Testing

@testable import BrainCore

/// The load-bearing separation (`docs/15-planner.md`): commitments are
/// **scheduled**, candidates are **ranked**, and the two never mix.
///
/// Nine daily commitments competing in the ranking would make "the one thing
/// to do next" a habit checkbox every day of the year, which would quietly
/// kill the capture product. These tests exist so that cannot regress.
@Suite("Plan: commitments and candidates stay apart")
struct PlanSplitTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay {
        CalendarDay(year: y, month: m, day: d)!
    }

    /// `Fixtures.now` is Monday 23 November 2026, 10:00 IST.
    static let today = day(2026, 11, 23)

    static func graphWithItems(_ gen: inout ULIDGenerator) -> (BrainGraph, [Item]) {
        var graph = BrainGraph()
        let items = [
            Fixtures.item(&gen, "write the migration", effort: .medium),
            Fixtures.item(&gen, "reply to the venue", effort: .tiny),
            Fixtures.item(&gen, "outline the talk", effort: .large),
        ]
        for item in items { graph.insert(item) }
        return (graph, items)
    }

    static func commitments(_ gen: inout ULIDGenerator) -> [Commitment] {
        let start = day(2026, 1, 1)
        return [
            Commitment(
                id: gen.next(), title: "read 10 pages", kind: .habit, rule: .daily,
                minutes: 20, startOn: start),
            Commitment(
                id: gen.next(), title: "ukulele", kind: .habit, rule: .daily,
                minutes: 20, startOn: start),
            Commitment(
                id: gen.next(), title: "plan the week", kind: .ritual,
                rule: .weeklyOn(.sunday), minutes: 45, startOn: start),
            Commitment(
                id: gen.next(), title: "rent", kind: .payment, rule: .monthlyOnDay(4),
                minutes: 5, startOn: start, note: "22k"),
        ]
    }

    // MARK: - The separation

    /// The guarantee is **structural**, not a filter: a `ScheduledCommitment`
    /// is not a `RankedItem`, so there is no code path that could place one in
    /// the other. This test pins the consequence anyway, because the valuable
    /// thing is that the ranking is *untouched* by commitments existing.
    @Test("Commitments do not appear in, or disturb, the ranking")
    func commitmentsStayOutOfRanked() {
        var gen = Fixtures.generator()
        let (graph, items) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)

        let without = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        let with = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments)

        #expect(with.ranked.map(\.item.id) == without.ranked.map(\.item.id))
        #expect(with.startable.map(\.item.id) == without.startable.map(\.item.id))
        #expect(with.quickWins.map(\.item.id) == without.quickWins.map(\.item.id))
        #expect(with.next?.item.id == without.next?.item.id)
        #expect(with.ranked.count == items.count)

        // And the commitments really are there, just elsewhere.
        #expect(!with.commitments.isEmpty)
        #expect(without.commitments.isEmpty)
    }

    @Test("Passing no commitments leaves everything exactly as it was")
    func defaultsChangeNothing() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let outputs = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(outputs.commitments.isEmpty)
        #expect(outputs.committedMinutes == 0)
        #expect(outputs.day == Self.today)
        #expect(!outputs.ranked.isEmpty, "the ranking still works")
    }

    // MARK: - Which ones fall today

    /// 23 November 2026 is a Monday, so the two daily habits fall and the
    /// Sunday ritual and the 4th-of-the-month payment do not.
    @Test("Only the commitments due today are returned")
    func onlyToday() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)

        let outputs = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments)

        #expect(outputs.day == Self.today)
        #expect(Self.today.weekday == .monday, "the premise")
        #expect(
            outputs.commitments.map(\.commitment.title).sorted()
                == ["read 10 pages", "ukulele"])
        #expect(outputs.commitments.allSatisfy { $0.day == Self.today })
    }

    @Test("A commitment's day comes from the user's zone, not the server's")
    func zoneDecidesTheDay() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)

        // 02:00 IST on 23 Nov is still 22 Nov in UTC. The Sunday ritual falls
        // on the 22nd, so a server computing in UTC would show the wrong day's
        // commitments to a user in India.
        var comps = DateComponents(year: 2026, month: 11, day: 23, hour: 2, minute: 0)
        comps.timeZone = Fixtures.zone
        let earlyMonday = Fixtures.calendar.date(from: comps)!

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let inKolkata = Brain.compute(
            graph: graph, now: earlyMonday, calendar: Fixtures.calendar,
            commitments: commitments)
        let inUTC = Brain.compute(
            graph: graph, now: earlyMonday, calendar: utcCalendar,
            commitments: commitments)

        #expect(inKolkata.day == Self.day(2026, 11, 23))
        #expect(inUTC.day == Self.day(2026, 11, 22))
        #expect(
            inUTC.commitments.map(\.commitment.title).contains("plan the week"),
            "22 Nov is a Sunday — the wrong day's ritual, which is the point")
        #expect(!inKolkata.commitments.map(\.commitment.title).contains("plan the week"))
    }

    // MARK: - Done, and what is still owed

    @Test("Completed occurrences are marked, and stop counting as owed")
    func completedMinutes() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)
        let reading = commitments.first { $0.title == "read 10 pages" }!

        let none = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments)
        #expect(none.committedMinutes == 40, "two habits at 20 minutes")
        #expect(none.commitments.allSatisfy { !$0.done })

        let one = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments, completed: [reading.id: [Self.today]])
        #expect(one.committedMinutes == 20, "the finished 20 minutes are not owed")
        #expect(one.commitments.filter(\.done).map(\.commitment.id) == [reading.id])
        #expect(one.commitments.count == 2, "a done commitment is still shown")
    }

    /// A missed day is stored as nothing at all (D2), so a commitment with no
    /// entry in `completed` must be ordinary, not an error.
    @Test("A commitment with no completion history is not an error")
    func missingHistoryIsFine() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)
        let outputs = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments, completed: [:])
        #expect(outputs.commitments.count == 2)
        #expect(outputs.commitments.allSatisfy { !$0.done })
    }

    @Test("Paused commitments never reach the plan")
    func pausedExcluded() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        var commitments = Self.commitments(&gen)
        for i in commitments.indices { commitments[i].paused = true }

        let outputs = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments)
        #expect(outputs.commitments.isEmpty)
        #expect(outputs.committedMinutes == 0)
    }

    @Test("The commitments section is deterministic across calls")
    func deterministic() {
        var gen = Fixtures.generator()
        let (graph, _) = Self.graphWithItems(&gen)
        let commitments = Self.commitments(&gen)
        let a = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments)
        let b = Brain.compute(
            graph: graph, now: Fixtures.now, calendar: Fixtures.calendar,
            commitments: commitments.reversed())
        #expect(a.commitments.map(\.commitment.id) == b.commitments.map(\.commitment.id))
    }
}
