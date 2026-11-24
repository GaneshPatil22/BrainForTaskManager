import Foundation

/// Recurring commitments: the scheduled half of the product (`docs/15-planner.md`).
///
/// **Everything here is calendar arithmetic on wall-calendar days, never on
/// `Date`.** "The first Saturday of March" is a question about a calendar, not
/// about an instant, so DST, leap seconds and zone offsets cannot reach the
/// expansion logic at all. A day becomes an instant only at the boundary,
/// through `start(in:)`, and only when something needs a real timestamp.
///
/// **Commitments never enter `ranked`.** They are scheduled; captured items are
/// ranked. Nine daily commitments in the ranked list would make "the one thing
/// to do next" a habit checkbox every day of the year.

// MARK: - Weekday

/// Deliberately numbered to match `Calendar`'s `weekday` component, where
/// Sunday is 1. A different numbering here would buy nothing and cost an
/// off-by-one at every boundary.
public enum Weekday: Int, Hashable, Sendable, Codable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var name: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }
}

// MARK: - CalendarDay

/// A day on the wall calendar: no time, no zone, no offset.
///
/// Month lengths and leap years come from `Foundation`, not from arithmetic
/// written here — getting February wrong is a classic, and there is no reason
/// to reimplement it.
public struct CalendarDay: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Gregorian in UTC, used purely as a calculator. The zone is irrelevant
    /// because nothing here ever looks at a time of day; UTC simply has no DST
    /// to perturb a `date(byAdding:)`.
    static let math: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Fails on a day that does not exist, such as 30 February.
    public init?(year: Int, month: Int, day: Int) {
        let comps = DateComponents(year: year, month: month, day: day)
        guard comps.isValidDate(in: Self.math) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day an instant falls on **in the user's zone**. This, and
    /// `start(in:)`, are the only places a zone is involved.
    public init(_ date: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(unchecked: c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Midnight at the start of this day in the given zone.
    public func start(in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public var weekday: Weekday {
        guard let date = Self.math.date(from: DateComponents(year: year, month: month, day: day)),
            let w = Weekday(rawValue: Self.math.component(.weekday, from: date))
        else { return .sunday }
        return w
    }

    /// 28, 29, 30 or 31, from `Foundation`.
    public var lastDayOfMonth: Int {
        guard let first = Self.math.date(from: DateComponents(year: year, month: month, day: 1)),
            let range = Self.math.range(of: .day, in: .month, for: first)
        else { return 28 }
        return range.count
    }

    /// Which occurrence of this weekday within the month this day is: the
    /// second Tuesday is 2. Pure arithmetic — no searching needed.
    public var weekdayOrdinal: Int { (day - 1) / 7 + 1 }

    /// 1 for January–March, through 4 for October–December. Calendar quarters,
    /// not the Indian financial year (`docs/15-planner.md`, D3).
    public var quarter: Int { (month - 1) / 3 + 1 }

    /// True for January, April, July and October.
    public var isFirstMonthOfQuarter: Bool { (month - 1) % 3 == 0 }

    public func adding(days: Int) -> CalendarDay {
        guard let base = Self.math.date(from: DateComponents(year: year, month: month, day: day)),
            let moved = Self.math.date(byAdding: .day, value: days, to: base)
        else { return self }
        let c = Self.math.dateComponents([.year, .month, .day], from: moved)
        return CalendarDay(unchecked: c.year ?? year, c.month ?? month, c.day ?? day)
    }

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// ISO-8601 date, which is also what the web app uses as its day key.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - Recurrence

/// The five shapes that cover every commitment in `docs/15-planner.md`.
///
/// **A closed enum, deliberately, rather than RFC 5545 `RRULE`.** Five shapes
/// do not justify a dependency, and a closed set is exhaustively testable —
/// which is the whole argument for keeping this in T0.
public enum RecurrenceRule: Hashable, Sendable, Codable {
    /// Read 10 pages, ukulele, move body, the 3-line journal.
    case daily
    /// The Sunday plan-and-review; the Friday office block.
    case weeklyOn(Weekday)
    /// Rent on the 4th, loan on the 9th. **Clamped**, not skipped: a
    /// commitment on the 31st falls on the 30th in a 30-day month and on the
    /// 28th or 29th in February. Skipping would silently drop a rent payment
    /// in four months of the year.
    case monthlyOnDay(Int)
    /// The monthly review on the first Saturday.
    case monthlyOnNthWeekday(n: Int, weekday: Weekday)
    /// The quarterly review, on the nth weekday of January, April, July or
    /// October.
    case quarterlyOnNthWeekday(n: Int, weekday: Weekday)

    /// Whether this rule puts an occurrence on `day`, ignoring the
    /// commitment's own active window — `Commitment.days(from:through:)` owns
    /// that.
    public func matches(_ day: CalendarDay) -> Bool {
        switch self {
        case .daily:
            true
        case .weeklyOn(let weekday):
            day.weekday == weekday
        case .monthlyOnDay(let wanted):
            day.day == min(max(wanted, 1), day.lastDayOfMonth)
        case .monthlyOnNthWeekday(let n, let weekday):
            day.weekday == weekday && day.weekdayOrdinal == n
        case .quarterlyOnNthWeekday(let n, let weekday):
            day.isFirstMonthOfQuarter && day.weekday == weekday && day.weekdayOrdinal == n
        }
    }

    /// One line for the user. Built from the rule, never by a model.
    public var text: String {
        switch self {
        case .daily: "Every day"
        case .weeklyOn(let w): "Every \(w.name)"
        case .monthlyOnDay(let d): "Monthly on the \(Self.ordinal(d))"
        case .monthlyOnNthWeekday(let n, let w): "Monthly on the \(Self.ordinal(n)) \(w.name)"
        case .quarterlyOnNthWeekday(let n, let w): "Quarterly on the \(Self.ordinal(n)) \(w.name)"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

// MARK: - Commitment

public enum CommitmentKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Read 10 pages, ukulele, move body. Carries a streak.
    case habit
    /// The weekly and monthly reviews. Produces something.
    case ritual
    /// Rent, loan. A reminder on a date — **never an amount to add up**
    /// (`docs/00-charter.md` rejects expense tracking).
    case payment
    /// The Friday 3-hour office block. Time set aside, not a task.
    case block
}

/// A standing decision: something the user committed to once, that recurs.
///
/// **One template, instances materialised lazily** (`docs/15-planner.md`, D1).
/// Expanding a year eagerly would be thousands of rows per user, nearly all of
/// them empty. This type is the template; the days come from
/// `days(from:through:)`, and only a day that *carries state* is ever stored.
public struct Commitment: Hashable, Sendable, Identifiable {
    public let id: ULID
    public var title: String
    public var kind: CommitmentKind
    public var rule: RecurrenceRule

    /// **Minutes, not an `EffortBucket`.** A commitment's duration is stated
    /// by the user ("3 hours on Friday"), not inferred from their words, so
    /// there is nothing to classify and no reason to lose precision: the
    /// buckets jump 60 → 240 and would turn three hours into one or four. The
    /// time-budget arithmetic (B-01) needs the real number.
    public var minutes: Int

    public var category: TaskCategory?
    /// Which goal this serves, if any. Lets a habit roll up to a month goal.
    public var goalId: ULID?

    /// No occurrence before this day. Also the floor for a streak.
    public var startOn: CalendarDay
    /// Inclusive. Nil means open-ended.
    public var endOn: CalendarDay?
    /// Paused commitments produce no occurrences and break no streaks.
    public var paused: Bool

    /// Free text the user attached, such as "22k". **Never parsed, never
    /// summed, never totalled.** The moment amounts are added together this
    /// becomes the expense tracking the charter rejects.
    public var note: String?

    public init(
        id: ULID, title: String, kind: CommitmentKind, rule: RecurrenceRule,
        minutes: Int, category: TaskCategory? = nil, goalId: ULID? = nil,
        startOn: CalendarDay, endOn: CalendarDay? = nil, paused: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rule = rule
        self.minutes = max(0, minutes)
        self.category = category
        self.goalId = goalId
        self.startOn = startOn
        self.endOn = endOn
        self.paused = paused
        self.note = note
    }

    /// Does this commitment fall on `day`? Window and pause included.
    public func falls(on day: CalendarDay) -> Bool {
        guard !paused, day >= startOn else { return false }
        if let endOn, day > endOn { return false }
        return rule.matches(day)
    }

    /// Every day in the closed range this commitment falls on, ascending.
    ///
    /// Walks the range a day at a time. A year of one commitment is 365
    /// `matches` calls, each of them a handful of integer operations; the
    /// clarity is worth more than the cleverness of jumping month to month.
    public func days(from: CalendarDay, through: CalendarDay) -> [CalendarDay] {
        guard !paused, from <= through else { return [] }
        var out: [CalendarDay] = []
        var day = max(from, startOn)
        let last = endOn.map { min(through, $0) } ?? through
        while day <= last {
            if rule.matches(day) { out.append(day) }
            day = day.adding(days: 1)
        }
        return out
    }

    /// The next day on or after `day`, if there is one inside the window.
    ///
    /// Bounded: a `monthlyOnNthWeekday(n: 5, …)` can legitimately skip months,
    /// and an open-ended search on a rule that never matches would not return.
    public func next(onOrAfter day: CalendarDay, within horizon: Int = 400) -> CalendarDay? {
        guard !paused else { return nil }
        var candidate = max(day, startOn)
        for _ in 0..<horizon {
            if let endOn, candidate > endOn { return nil }
            if rule.matches(candidate) { return candidate }
            candidate = candidate.adding(days: 1)
        }
        return nil
    }

    // MARK: Looking back

    /// Days the commitment fell on but was not completed.
    ///
    /// **`today` is excluded: the day is not over.** A miss is otherwise just
    /// *expected minus actual*, which is why `docs/15-planner.md` D2 needs no
    /// stored row for a missed day — the absence of a completion is the miss.
    public func missed(
        completed: Set<CalendarDay>, from: CalendarDay, through: CalendarDay,
        today: CalendarDay
    ) -> [CalendarDay] {
        days(from: from, through: through)
            .filter { $0 < today && !completed.contains($0) }
    }

    /// Consecutive completed occurrences, counting back from the most recent.
    ///
    /// Today's occurrence, if not yet done, does **not** break the streak —
    /// the day is not over. Lifted from the web app's device-local prototype
    /// (`Website/src/local/repeats.ts`), which had this right.
    public func streak(completed: Set<CalendarDay>, today: CalendarDay) -> Int {
        guard !paused else { return 0 }
        var count = 0
        var day = today
        // A streak cannot reach back past the commitment's own start.
        while day >= startOn {
            if rule.matches(day) {
                if completed.contains(day) {
                    count += 1
                } else if day != today {
                    break
                }
            }
            day = day.adding(days: -1)
        }
        return count
    }

    /// Completed over expected, for the weekly and monthly reviews. `nil` when
    /// nothing was expected — a rate of 0 would read as a failure.
    public func hitRate(
        completed: Set<CalendarDay>, from: CalendarDay, through: CalendarDay
    ) -> Double? {
        let expected = days(from: from, through: through)
        guard !expected.isEmpty else { return nil }
        let hit = expected.filter(completed.contains).count
        return Double(hit) / Double(expected.count)
    }
}

// MARK: - A day's commitments

/// One commitment on one day, with whether it is done. The shape the plan's
/// commitments section is built from.
public struct ScheduledCommitment: Hashable, Sendable {
    public let commitment: Commitment
    public let day: CalendarDay
    public let done: Bool

    public init(commitment: Commitment, day: CalendarDay, done: Bool) {
        self.commitment = commitment
        self.day = day
        self.done = done
    }
}

extension Commitment {
    /// What is committed on one day, in a stable order: payments and rituals
    /// first (they are dated for a reason), then blocks, then habits, each
    /// group by id so the order never jitters between calls.
    public static func scheduled(
        _ commitments: [Commitment], on day: CalendarDay,
        completed: (Commitment) -> Set<CalendarDay>
    ) -> [ScheduledCommitment] {
        let order: [CommitmentKind: Int] = [.payment: 0, .ritual: 1, .block: 2, .habit: 3]
        return
            commitments
            .filter { $0.falls(on: day) }
            .sorted {
                (order[$0.kind] ?? 9, $0.id) < (order[$1.kind] ?? 9, $1.id)
            }
            .map {
                ScheduledCommitment(
                    commitment: $0, day: day, done: completed($0).contains(day))
            }
    }

    /// Minutes already committed on a day, counting only what is not done.
    ///
    /// This is the number B-01 subtracts before Brain offers more work: a
    /// planner that recommends a four-hour task into a day with three hours
    /// of commitments left is worse than no planner.
    public static func committedMinutes(_ scheduled: [ScheduledCommitment]) -> Int {
        scheduled.filter { !$0.done }.reduce(0) { $0 + $1.commitment.minutes }
    }
}
