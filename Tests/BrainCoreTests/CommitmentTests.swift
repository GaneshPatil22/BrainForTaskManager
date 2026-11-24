import Foundation
import Testing

@testable import BrainCore

/// The recurrence engine (`docs/15-planner.md`).
///
/// Every date in here was computed, not assumed. The edge cases are the ones
/// `docs/12-backlog.md` named as the fiddly part of B-05: the 31st in a short
/// month, 29 February, "first Saturday" when the month opens on a Saturday,
/// quarter boundaries, and DST.
@Suite("Commitments and recurrence")
struct CommitmentTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay {
        guard let day = CalendarDay(year: y, month: m, day: d) else {
            Issue.record("\(y)-\(m)-\(d) is not a real day")
            return CalendarDay(year: 1970, month: 1, day: 1)!
        }
        return day
    }

    static func commitment(
        _ rule: RecurrenceRule, kind: CommitmentKind = .habit, minutes: Int = 10,
        from: CalendarDay = day(2026, 1, 1), to: CalendarDay? = nil, paused: Bool = false
    ) -> Commitment {
        var gen = ULIDGenerator(seed: 7)
        return Commitment(
            id: gen.next(), title: "a commitment", kind: kind, rule: rule,
            minutes: minutes, startOn: from, endOn: to, paused: paused)
    }

    // MARK: - CalendarDay

    @Test("A day that does not exist is refused")
    func rejectsImpossibleDays() {
        #expect(CalendarDay(year: 2026, month: 2, day: 30) == nil)
        #expect(CalendarDay(year: 2027, month: 2, day: 29) == nil, "2027 is not a leap year")
        #expect(CalendarDay(year: 2026, month: 13, day: 1) == nil)
        #expect(CalendarDay(year: 2026, month: 4, day: 31) == nil)
        #expect(CalendarDay(year: 2028, month: 2, day: 29) != nil, "2028 is a leap year")
    }

    @Test("Weekdays match the real calendar")
    func weekdays() {
        #expect(Self.day(2026, 11, 24).weekday == .tuesday)
        #expect(Self.day(2026, 11, 29).weekday == .sunday)
        #expect(Self.day(2026, 12, 5).weekday == .saturday)
        #expect(Self.day(2028, 2, 29).weekday == .tuesday)
    }

    @Test("Month length comes from the calendar, leap years included")
    func monthLengths() {
        #expect(Self.day(2027, 2, 1).lastDayOfMonth == 28)
        #expect(Self.day(2028, 2, 1).lastDayOfMonth == 29)
        #expect(Self.day(2027, 4, 1).lastDayOfMonth == 30)
        #expect(Self.day(2027, 1, 1).lastDayOfMonth == 31)
    }

    @Test("Adding days crosses months, years and leap days")
    func addingDays() {
        #expect(Self.day(2026, 12, 31).adding(days: 1) == Self.day(2027, 1, 1))
        #expect(Self.day(2027, 1, 1).adding(days: -1) == Self.day(2026, 12, 31))
        #expect(Self.day(2028, 2, 28).adding(days: 1) == Self.day(2028, 2, 29))
        #expect(Self.day(2027, 2, 28).adding(days: 1) == Self.day(2027, 3, 1))
        #expect(Self.day(2026, 11, 24).adding(days: 365) == Self.day(2027, 11, 24))
    }

    @Test("Ordinal and quarter are plain arithmetic")
    func ordinalAndQuarter() {
        #expect(Self.day(2026, 12, 5).weekdayOrdinal == 1, "the 5th is in the first week")
        #expect(Self.day(2026, 12, 12).weekdayOrdinal == 2)
        #expect(Self.day(2026, 12, 29).weekdayOrdinal == 5)
        #expect(Self.day(2027, 1, 15).quarter == 1)
        #expect(Self.day(2027, 4, 1).quarter == 2)
        #expect(Self.day(2027, 12, 31).quarter == 4)
        #expect(Self.day(2027, 7, 1).isFirstMonthOfQuarter)
        #expect(!Self.day(2027, 8, 1).isFirstMonthOfQuarter)
    }

    @Test("A day is the same day it was parsed from, in the user's zone")
    func roundTrip() {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let day = Self.day(2026, 11, 24)
        #expect(CalendarDay(day.start(in: zone), in: zone) == day)
    }

    /// Kolkata is UTC+5:30, so an instant is on an earlier UTC date only when
    /// the local clock reads before 05:30. 02:00 on the 24th in Kolkata is
    /// 20:30 on the 23rd in UTC — a zone-blind conversion would file an
    /// early-morning capture a day early.
    @Test("Early-morning instants stay on the user's day, not UTC's")
    func zoneBoundary() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let utc = TimeZone(identifier: "UTC")!
        let earlyMorning = Self.day(2026, 11, 24).start(in: kolkata)
            .addingTimeInterval(2 * 3600)
        #expect(CalendarDay(earlyMorning, in: kolkata) == Self.day(2026, 11, 24))
        #expect(CalendarDay(earlyMorning, in: utc) == Self.day(2026, 11, 23))

        // And the reverse end of the day stays put: 23:30 IST is 18:00 UTC,
        // still the 24th in both zones.
        let lateEvening = Self.day(2026, 11, 24).start(in: kolkata)
            .addingTimeInterval(23.5 * 3600)
        #expect(CalendarDay(lateEvening, in: kolkata) == Self.day(2026, 11, 24))
        #expect(CalendarDay(lateEvening, in: utc) == Self.day(2026, 11, 24))
    }

    // MARK: - The five shapes

    @Test("Daily falls on every day in the range")
    func daily() {
        let c = Self.commitment(.daily)
        let days = c.days(from: Self.day(2026, 11, 24), through: Self.day(2026, 12, 3))
        #expect(days.count == 10)
        #expect(days.first == Self.day(2026, 11, 24))
        #expect(days.last == Self.day(2026, 12, 3))
    }

    @Test("Weekly falls on its weekday only")
    func weekly() {
        let c = Self.commitment(.weeklyOn(.sunday), kind: .ritual)
        let days = c.days(from: Self.day(2026, 11, 24), through: Self.day(2026, 12, 20))
        #expect(
            days == [
                Self.day(2026, 11, 29), Self.day(2026, 12, 6),
                Self.day(2026, 12, 13), Self.day(2026, 12, 20),
            ])
        #expect(days.allSatisfy { $0.weekday == .sunday })
    }

    /// Rent on the 4th, loan on the 9th — the brief's actual payments.
    @Test("Monthly on a day-of-month that every month has")
    func monthlyOnOrdinaryDay() {
        let rent = Self.commitment(.monthlyOnDay(4), kind: .payment)
        let days = rent.days(from: Self.day(2026, 12, 1), through: Self.day(2027, 3, 31))
        #expect(
            days == [
                Self.day(2026, 12, 4), Self.day(2027, 1, 4),
                Self.day(2027, 2, 4), Self.day(2027, 3, 4),
            ])
    }

    /// **The one that silently drops payments if you get it wrong.** A rule on
    /// the 31st must land on the last day of a shorter month, not vanish.
    @Test("Monthly on the 31st clamps rather than skipping")
    func monthlyClamps() {
        let c = Self.commitment(.monthlyOnDay(31), kind: .payment)
        let days = c.days(from: Self.day(2027, 1, 1), through: Self.day(2027, 6, 30))
        #expect(
            days == [
                Self.day(2027, 1, 31),
                Self.day(2027, 2, 28),  // 28-day February
                Self.day(2027, 3, 31),
                Self.day(2027, 4, 30),  // 30-day April
                Self.day(2027, 5, 31),
                Self.day(2027, 6, 30),
            ])
        #expect(days.count == 6, "every month gets exactly one, none skipped")
    }

    @Test("Monthly on the 31st lands on 29 February in a leap year")
    func monthlyClampsOnLeapDay() {
        let c = Self.commitment(.monthlyOnDay(31), kind: .payment)
        let days = c.days(from: Self.day(2028, 2, 1), through: Self.day(2028, 2, 29))
        #expect(days == [Self.day(2028, 2, 29)])
    }

    /// The monthly review: first Saturday.
    @Test("Monthly on the nth weekday")
    func monthlyNthWeekday() {
        let c = Self.commitment(.monthlyOnNthWeekday(n: 1, weekday: .saturday), kind: .ritual)
        let days = c.days(from: Self.day(2026, 12, 1), through: Self.day(2027, 2, 28))
        #expect(
            days == [
                Self.day(2026, 12, 5), Self.day(2027, 1, 2), Self.day(2027, 2, 6),
            ])
    }

    /// `12-backlog.md` named this one: *"first Sunday when the month starts on
    /// a Sunday"*. May 2027 opens on a Saturday, so the first Saturday is the
    /// 1st — an off-by-one here would silently return the 8th.
    @Test("First Saturday is the 1st when the month opens on a Saturday")
    func nthWeekdayWhenMonthOpensOnIt() {
        #expect(Self.day(2027, 5, 1).weekday == .saturday, "the premise of this test")
        let c = Self.commitment(.monthlyOnNthWeekday(n: 1, weekday: .saturday), kind: .ritual)
        let days = c.days(from: Self.day(2027, 5, 1), through: Self.day(2027, 5, 31))
        #expect(days == [Self.day(2027, 5, 1)])
    }

    /// A 5th Saturday exists in some months and not others. Skipping is
    /// correct here — unlike day-of-month, there is no "last Saturday" to
    /// clamp to without changing what the user asked for.
    @Test("A 5th weekday simply does not occur in months without one")
    func fifthWeekdayMayNotExist() {
        let c = Self.commitment(.monthlyOnNthWeekday(n: 5, weekday: .saturday))
        let days = c.days(from: Self.day(2027, 1, 1), through: Self.day(2027, 12, 31))
        #expect(days.map(\.month) == [1, 5, 7, 10])
    }

    @Test("Quarterly fires only in the first month of each calendar quarter")
    func quarterly() {
        let c = Self.commitment(
            .quarterlyOnNthWeekday(n: 1, weekday: .saturday), kind: .ritual)
        let days = c.days(from: Self.day(2027, 1, 1), through: Self.day(2027, 12, 31))
        #expect(days.map(\.month) == [1, 4, 7, 10], "calendar quarters, not April–March")
        #expect(days.first == Self.day(2027, 1, 2))
        #expect(days.allSatisfy { $0.weekday == .saturday && $0.weekdayOrdinal == 1 })
    }

    // MARK: - DST

    /// The reason the whole engine works on calendar days instead of `Date`.
    /// America/Los_Angeles springs forward on 2027-03-14 and falls back on
    /// 2027-11-07; a daily commitment must still be exactly one per day across
    /// both, with no doubled and no missing day.
    @Test(
        "DST cannot add or drop an occurrence",
        arguments: [
            (
                CalendarDay(year: 2027, month: 3, day: 10)!,
                CalendarDay(year: 2027, month: 3, day: 18)!, 9
            ),
            (
                CalendarDay(year: 2027, month: 11, day: 3)!,
                CalendarDay(year: 2027, month: 11, day: 11)!, 9
            ),
        ])
    func dstIsIrrelevant(from: CalendarDay, through: CalendarDay, expected: Int) {
        let days = Self.commitment(.daily).days(from: from, through: through)
        #expect(days.count == expected)
        #expect(Set(days).count == expected, "no day appears twice")
    }

    @Test("A weekly commitment still lands on the DST transition day")
    func weeklyAcrossDST() {
        let c = Self.commitment(.weeklyOn(.sunday), kind: .ritual)
        let days = c.days(from: Self.day(2027, 3, 1), through: Self.day(2027, 3, 31))
        #expect(days.contains(Self.day(2027, 3, 14)), "spring forward is a Sunday")
        #expect(days.count == 4)
    }

    // MARK: - Window and pause

    @Test("No occurrence before the start or after the end")
    func window() {
        let c = Self.commitment(
            .daily, from: Self.day(2026, 12, 5), to: Self.day(2026, 12, 8))
        let days = c.days(from: Self.day(2026, 12, 1), through: Self.day(2026, 12, 31))
        #expect(
            days == [
                Self.day(2026, 12, 5), Self.day(2026, 12, 6),
                Self.day(2026, 12, 7), Self.day(2026, 12, 8),
            ])
        #expect(!c.falls(on: Self.day(2026, 12, 4)))
        #expect(!c.falls(on: Self.day(2026, 12, 9)))
    }

    @Test("A paused commitment produces nothing at all")
    func paused() {
        let c = Self.commitment(.daily, paused: true)
        #expect(c.days(from: Self.day(2026, 12, 1), through: Self.day(2026, 12, 31)).isEmpty)
        #expect(!c.falls(on: Self.day(2026, 12, 1)))
        #expect(c.next(onOrAfter: Self.day(2026, 12, 1)) == nil)
        #expect(c.streak(completed: [Self.day(2026, 12, 1)], today: Self.day(2026, 12, 1)) == 0)
    }

    @Test("An inverted range is empty, not a crash")
    func invertedRange() {
        let c = Self.commitment(.daily)
        #expect(c.days(from: Self.day(2026, 12, 10), through: Self.day(2026, 12, 1)).isEmpty)
    }

    @Test("Next occurrence, and nothing past the end of the window")
    func nextOccurrence() {
        let weekly = Self.commitment(.weeklyOn(.friday), kind: .block, minutes: 180)
        #expect(weekly.next(onOrAfter: Self.day(2026, 11, 24)) == Self.day(2026, 11, 27))
        #expect(weekly.next(onOrAfter: Self.day(2026, 11, 27)) == Self.day(2026, 11, 27))

        let ending = Self.commitment(.daily, to: Self.day(2026, 12, 5))
        #expect(ending.next(onOrAfter: Self.day(2026, 12, 6)) == nil)
    }

    // MARK: - Looking back (D2)

    /// A miss is *expected minus actual*, which is why a missed day needs no
    /// stored row (`docs/15-planner.md`, D2).
    @Test("Missed days are the expected ones with no completion")
    func missed() {
        let c = Self.commitment(.daily)
        let completed: Set<CalendarDay> = [Self.day(2026, 11, 24), Self.day(2026, 11, 26)]
        let missed = c.missed(
            completed: completed, from: Self.day(2026, 11, 24),
            through: Self.day(2026, 11, 27), today: Self.day(2026, 11, 27))
        #expect(missed == [Self.day(2026, 11, 25)])
    }

    @Test("Today is never counted as missed — the day is not over")
    func todayIsNotMissed() {
        let c = Self.commitment(.daily)
        let missed = c.missed(
            completed: [], from: Self.day(2026, 11, 24), through: Self.day(2026, 11, 24),
            today: Self.day(2026, 11, 24))
        #expect(missed.isEmpty)
    }

    @Test("A streak counts back from the most recent completion")
    func streak() {
        let c = Self.commitment(.daily, from: Self.day(2026, 11, 1))
        let completed: Set<CalendarDay> = [
            Self.day(2026, 11, 22), Self.day(2026, 11, 23), Self.day(2026, 11, 24),
        ]
        #expect(c.streak(completed: completed, today: Self.day(2026, 11, 24)) == 3)
    }

    /// D2: missing a day resets the streak and that is the only consequence.
    @Test("A gap breaks the streak")
    func streakBreaks() {
        let c = Self.commitment(.daily, from: Self.day(2026, 11, 1))
        let completed: Set<CalendarDay> = [
            Self.day(2026, 11, 20), Self.day(2026, 11, 21),
            // 22nd missed
            Self.day(2026, 11, 23), Self.day(2026, 11, 24),
        ]
        #expect(c.streak(completed: completed, today: Self.day(2026, 11, 24)) == 2)
    }

    @Test("Today being unfinished does not break the streak")
    func todayDoesNotBreakStreak() {
        let c = Self.commitment(.daily, from: Self.day(2026, 11, 1))
        let completed: Set<CalendarDay> = [Self.day(2026, 11, 22), Self.day(2026, 11, 23)]
        #expect(
            c.streak(completed: completed, today: Self.day(2026, 11, 24)) == 2,
            "the day is not over yet")
    }

    @Test("A streak counts occurrences, not days, for a weekly commitment")
    func weeklyStreak() {
        let c = Self.commitment(.weeklyOn(.sunday), kind: .ritual, from: Self.day(2026, 10, 1))
        let completed: Set<CalendarDay> = [
            Self.day(2026, 11, 8), Self.day(2026, 11, 15), Self.day(2026, 11, 22),
        ]
        #expect(c.streak(completed: completed, today: Self.day(2026, 11, 24)) == 3)
    }

    @Test("A streak stops at the commitment's start, not before it")
    func streakFloor() {
        let c = Self.commitment(.daily, from: Self.day(2026, 11, 23))
        let completed: Set<CalendarDay> = [Self.day(2026, 11, 23), Self.day(2026, 11, 24)]
        #expect(c.streak(completed: completed, today: Self.day(2026, 11, 24)) == 2)
    }

    @Test("Hit rate abstains when nothing was expected")
    func hitRate() {
        let daily = Self.commitment(.daily, from: Self.day(2026, 11, 1))
        let week = (from: Self.day(2026, 11, 18), through: Self.day(2026, 11, 24))
        let completed: Set<CalendarDay> = [
            Self.day(2026, 11, 18), Self.day(2026, 11, 19), Self.day(2026, 11, 20),
            Self.day(2026, 11, 23),
        ]
        #expect(
            daily.hitRate(completed: completed, from: week.from, through: week.through) == 4.0 / 7.0
        )

        let monthly = Self.commitment(.monthlyOnDay(4), kind: .payment)
        #expect(
            monthly.hitRate(completed: [], from: week.from, through: week.through) == nil,
            "nothing was due that week; 0% would read as a failure")
    }

    // MARK: - A day's commitments

    @Test("A day's commitments are ordered and never jitter")
    func scheduledOrder() {
        var gen = ULIDGenerator(seed: 3)
        let habit = Commitment(
            id: gen.next(), title: "read 10 pages", kind: .habit, rule: .daily,
            minutes: 20, startOn: Self.day(2026, 1, 1))
        let rent = Commitment(
            id: gen.next(), title: "rent", kind: .payment, rule: .monthlyOnDay(4),
            minutes: 5, startOn: Self.day(2026, 1, 1), note: "22k")
        let block = Commitment(
            id: gen.next(), title: "office improvement block", kind: .block,
            rule: .weeklyOn(.friday), minutes: 180, startOn: Self.day(2026, 1, 1))

        // 4 December 2026 is a Friday, so all three fall on it.
        #expect(Self.day(2026, 12, 4).weekday == .friday)
        let scheduled = Commitment.scheduled(
            [habit, rent, block], on: Self.day(2026, 12, 4), completed: { _ in [] })
        #expect(scheduled.map(\.commitment.kind) == [.payment, .block, .habit])
        #expect(
            Commitment.scheduled(
                [block, habit, rent], on: Self.day(2026, 12, 4), completed: { _ in [] }
            )
            .map(\.commitment.id) == scheduled.map(\.commitment.id), "input order is irrelevant")
    }

    /// B-01: the number subtracted before Brain offers more work.
    @Test("Committed minutes count only what is still to do")
    func committedMinutes() {
        var gen = ULIDGenerator(seed: 4)
        let a = Commitment(
            id: gen.next(), title: "a", kind: .habit, rule: .daily, minutes: 20,
            startOn: Self.day(2026, 1, 1))
        let b = Commitment(
            id: gen.next(), title: "b", kind: .block, rule: .daily, minutes: 180,
            startOn: Self.day(2026, 1, 1))
        let today = Self.day(2026, 12, 4)
        let done = Commitment.scheduled(
            [a, b], on: today, completed: { $0.id == a.id ? [today] : [] })
        #expect(Commitment.committedMinutes(done) == 180, "the finished 20 minutes are not owed")
        #expect(
            Commitment.committedMinutes(
                Commitment.scheduled([a, b], on: today, completed: { _ in [] })) == 200)
    }

    // MARK: - The brief, end to end

    /// Ganesh's actual week, expanded over one month. If this drifts, the
    /// planner is wrong for the person it was built for.
    @Test("The brief's own commitments expand correctly over December 2026")
    func theBrief() {
        var gen = ULIDGenerator(seed: 11)
        let start = Self.day(2026, 1, 1)
        func make(_ title: String, _ kind: CommitmentKind, _ rule: RecurrenceRule, _ mins: Int)
            -> Commitment
        {
            Commitment(
                id: gen.next(), title: title, kind: kind, rule: rule, minutes: mins,
                startOn: start)
        }
        let all = [
            make("read 10 pages", .habit, .daily, 20),
            make("ukulele", .habit, .daily, 20),
            make("3-line journal", .habit, .daily, 5),
            make("plan the week and review the last one", .ritual, .weeklyOn(.sunday), 45),
            make("office improvement block", .block, .weeklyOn(.friday), 180),
            make(
                "month plan and review", .ritual, .monthlyOnNthWeekday(n: 1, weekday: .saturday), 60
            ),
            make("rent", .payment, .monthlyOnDay(4), 5),
            make("loan", .payment, .monthlyOnDay(9), 5),
        ]
        let from = Self.day(2026, 12, 1)
        let through = Self.day(2026, 12, 31)

        let counts = Dictionary(
            uniqueKeysWithValues: all.map {
                ($0.title, $0.days(from: from, through: through).count)
            })
        #expect(counts["read 10 pages"] == 31)
        #expect(counts["3-line journal"] == 31)
        #expect(counts["plan the week and review the last one"] == 4, "Sundays in Dec 2026")
        #expect(counts["office improvement block"] == 4, "Fridays in Dec 2026")
        #expect(counts["month plan and review"] == 1)
        #expect(counts["rent"] == 1)
        #expect(counts["loan"] == 1)

        // The 4th is both a Friday and rent day: 3 habits + block + rent.
        let fourth = Commitment.scheduled(all, on: Self.day(2026, 12, 4), completed: { _ in [] })
        #expect(fourth.count == 5)
        #expect(fourth.first?.commitment.kind == .payment)
        #expect(Commitment.committedMinutes(fourth) == 20 + 20 + 5 + 180 + 5)

        // The 5th is the first Saturday: 3 habits + the month review.
        let fifth = Commitment.scheduled(all, on: Self.day(2026, 12, 5), completed: { _ in [] })
        #expect(fifth.map(\.commitment.title).contains("month plan and review"))
        #expect(fifth.count == 4)
    }

    @Test("Rule text reads as a person would say it")
    func ruleText() {
        #expect(RecurrenceRule.daily.text == "Every day")
        #expect(RecurrenceRule.weeklyOn(.sunday).text == "Every Sunday")
        #expect(RecurrenceRule.monthlyOnDay(4).text == "Monthly on the 4th")
        #expect(RecurrenceRule.monthlyOnDay(1).text == "Monthly on the 1st")
        #expect(RecurrenceRule.monthlyOnDay(2).text == "Monthly on the 2nd")
        #expect(RecurrenceRule.monthlyOnDay(3).text == "Monthly on the 3rd")
        #expect(RecurrenceRule.monthlyOnDay(11).text == "Monthly on the 11th")
        #expect(RecurrenceRule.monthlyOnDay(21).text == "Monthly on the 21st")
        #expect(
            RecurrenceRule.monthlyOnNthWeekday(n: 1, weekday: .saturday).text
                == "Monthly on the 1st Saturday")
        #expect(
            RecurrenceRule.quarterlyOnNthWeekday(n: 1, weekday: .saturday).text
                == "Quarterly on the 1st Saturday")
    }
}
