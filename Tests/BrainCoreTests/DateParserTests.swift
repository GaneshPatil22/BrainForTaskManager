import Foundation
import Testing
@testable import BrainCore

/// Dates are T0 and always will be (`docs/09-tiering.md`, guard 5). These tests
/// are the specification of the grammar.
///
/// "Now" is fixed at **Monday 23 Nov 2026, 10:00 IST** so weekday and
/// month-boundary arithmetic is checkable by hand.
@Suite("DateParser — English and Hinglish")
struct DateParserTests {
    let parser = DateParser(timeZone: Fixtures.zone)

    /// Asserts the parsed calendar day, ignoring time of day.
    func expectDay(
        _ text: String, _ y: Int, _ m: Int, _ d: Int,
        rule: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let parsed = parser.parse(text, now: Fixtures.now) else {
            Issue.record("no date parsed from \"\(text)\"", sourceLocation: sourceLocation)
            return
        }
        let comps = Fixtures.calendar.dateComponents([.year, .month, .day], from: parsed.date)
        #expect(
            comps.year == y && comps.month == m && comps.day == d,
            "\"\(text)\" → \(comps.year!)-\(comps.month!)-\(comps.day!), expected \(y)-\(m)-\(d)",
            sourceLocation: sourceLocation)
        if let rule {
            #expect(
                parsed.rule == rule, "\"\(text)\" fired \(parsed.rule)",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - Relative day words

    @Test("English day words")
    func englishDayWords() {
        expectDay("today", 2026, 11, 23, rule: "today")
        expectDay("tomorrow", 2026, 11, 24, rule: "kal")
        expectDay("day after tomorrow", 2026, 11, 25, rule: "parso")
        expectDay("tonight", 2026, 11, 23)
    }

    /// "kal" is both yesterday and tomorrow in Hindi; "parso" is both the day
    /// after tomorrow and the day before yesterday. In a capture the future
    /// reading dominates, so we take it — and lower the confidence to say so
    /// rather than pretending the ambiguity isn't there.
    @Test("Hinglish day words resolve to the future reading")
    func hinglishDayWords() throws {
        expectDay("aaj", 2026, 11, 23)
        expectDay("kal", 2026, 11, 24)
        expectDay("parso", 2026, 11, 25)
        expectDay("kal subah plumber ko call karna hai", 2026, 11, 24)

        let kal = try #require(parser.parse("kal", now: Fixtures.now))
        let tomorrow = try #require(parser.parse("tomorrow", now: Fixtures.now))
        #expect(
            kal.confidence < tomorrow.confidence,
            "ambiguous Hinglish must score lower than unambiguous English")
    }

    // MARK: - Weekdays

    @Test("Weekdays resolve strictly into the future")
    func weekdays() {
        // Today IS Monday, so "monday" means the next one, not today.
        expectDay("monday", 2026, 11, 30)
        expectDay("next monday", 2026, 11, 30)
        expectDay("friday", 2026, 11, 27)
        expectDay("sunday", 2026, 11, 29)
    }

    @Test("Hindi weekday names")
    func hindiWeekdays() {
        expectDay("somvaar", 2026, 11, 30)
        expectDay("shukravaar", 2026, 11, 27)
        expectDay("agle shanivaar", 2026, 11, 28)
        expectDay("ravivaar ko milte hain", 2026, 11, 29)
    }

    // MARK: - Offsets

    @Test("Day and week offsets, both languages")
    func offsets() {
        expectDay("in 3 days", 2026, 11, 26, rule: "inNDays")
        expectDay("3 din mein", 2026, 11, 26, rule: "inNDays")
        expectDay("3 din baad", 2026, 11, 26)
        expectDay("after 10 days", 2026, 12, 3)
        expectDay("in 2 weeks", 2026, 12, 7)
        expectDay("next week", 2026, 11, 30, rule: "nextWeek")
        expectDay("agle hafte", 2026, 11, 30)
        expectDay("next month", 2026, 12, 23, rule: "nextMonth")
        expectDay("agle mahine", 2026, 12, 23)
    }

    @Test("This week and weekend, both languages")
    func thisPeriod() {
        // Today is Monday 23 Nov 2026.
        expectDay("weekend", 2026, 11, 28, rule: "weekend")  // coming Saturday
        expectDay("is weekend", 2026, 11, 28)
        expectDay("this week", 2026, 11, 29, rule: "thisWeek")  // coming Sunday
        expectDay("is hafte", 2026, 11, 29)
        // Must not be swallowed by the `next week` rule.
        expectDay("next week", 2026, 11, 30, rule: "nextWeek")
        expectDay("agle hafte", 2026, 11, 30)
    }

    // MARK: - Month end and day of month

    @Test("Month end, both languages")
    func monthEnd() {
        expectDay("end of month", 2026, 11, 30, rule: "monthEnd")
        expectDay("month end", 2026, 11, 30)
        expectDay("mahine ke end", 2026, 11, 30)
        expectDay("mahine ke akhir", 2026, 11, 30)
    }

    @Test("Day of month rolls forward when already past")
    func dayOfMonth() {
        expectDay("25 tarikh", 2026, 11, 25, rule: "dayOfMonth")  // still ahead
        expectDay("15 tarikh", 2026, 12, 15)  // already passed
        expectDay("15 tarikh ko", 2026, 12, 15)
        expectDay("on the 25th", 2026, 11, 25)
    }

    // MARK: - Explicit dates

    @Test("Numeric dates are day-first, as used in India")
    func numericDates() {
        expectDay("15/12", 2026, 12, 15, rule: "numericDate")
        expectDay("15-12-2026", 2026, 12, 15)
        expectDay("01/01/27", 2027, 1, 1)
        // 15 Nov already passed, so a bare day/month rolls to next year.
        expectDay("15/11", 2027, 11, 15)
    }

    @Test("Month names in either order")
    func monthNames() {
        expectDay("15 dec", 2026, 12, 15, rule: "monthName")
        expectDay("dec 15", 2026, 12, 15)
        expectDay("15th december", 2026, 12, 15)
        expectDay("january 5", 2027, 1, 5)
    }

    // MARK: - Time of day

    func expectTime(
        _ text: String, _ hour: Int, _ minute: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let parsed = parser.parse(text, now: Fixtures.now) else {
            Issue.record("no date parsed from \"\(text)\"", sourceLocation: sourceLocation)
            return
        }
        let comps = Fixtures.calendar.dateComponents([.hour, .minute], from: parsed.date)
        #expect(
            comps.hour == hour && comps.minute == minute,
            "\"\(text)\" → \(comps.hour!):\(comps.minute!), expected \(hour):\(minute)",
            sourceLocation: sourceLocation)
    }

    @Test("Hinglish period words map to the right 24-hour value")
    func hinglishTimes() {
        expectTime("kal subah 9 baje", 9, 0)
        expectTime("kal shaam 5 baje", 17, 0)
        expectTime("kal raat 10 baje", 22, 0)
        expectTime("kal dopahar 2 baje", 14, 0)
        expectTime("kal raat 2 baje", 2, 0)  // early hours, not 14:00
        expectTime("kal raat 12 baje", 0, 0)  // midnight
        expectTime("kal dopahar 12 baje", 12, 0)  // noon
        expectTime("kal subah 9:30 baje", 9, 30)
    }

    @Test("English clock times")
    func englishTimes() {
        expectTime("tomorrow 9am", 9, 0)
        expectTime("tomorrow 5:30pm", 17, 30)
        expectTime("tomorrow 12pm", 12, 0)
        expectTime("tomorrow 12am", 0, 0)
    }

    @Test("A bare 'N baje' is a heuristic and is scored as one")
    func bareBaje() throws {
        expectTime("kal 9 baje", 9, 0)
        expectTime("kal 5 baje", 17, 0)
        let bare = try #require(parser.parse("kal 5 baje", now: Fixtures.now))
        let explicit = try #require(parser.parse("kal shaam 5 baje", now: Fixtures.now))
        #expect(bare.confidence < explicit.confidence)
    }

    @Test("A date with no time is due at the end of that day")
    func defaultsToEndOfDay() {
        expectTime("kal", 23, 59)
    }

    // MARK: - Abstention and grounding

    /// A clock time with no day word used to return nil, silently losing a
    /// date the user had clearly stated. Found by the generated datasets:
    /// `shaam 5 baje` and `9am` both parsed to nothing.
    @Test("A time with no day word resolves to the next occurrence")
    func timeWithoutDayWord() throws {
        // "now" is Mon 23 Nov 10:00 IST, so 5pm today is still ahead.
        let evening = try #require(parser.parse("shaam 5 baje", now: Fixtures.now))
        var comps = Fixtures.calendar.dateComponents([.day, .hour, .minute], from: evening.date)
        #expect(comps.day == 23 && comps.hour == 17 && comps.minute == 0)
        #expect(evening.rule == "timeOnly")

        // 9am has already passed at 10:00, so it rolls to tomorrow — matching
        // the roll-forward convention the dated rules already use.
        let morning = try #require(parser.parse("9am", now: Fixtures.now))
        comps = Fixtures.calendar.dateComponents([.day, .hour], from: morning.date)
        #expect(comps.day == 24 && comps.hour == 9)

        // The day was inferred, not stated, so confidence must be lower than
        // the same time with an unambiguous day word. (Comparing against "kal"
        // would be wrong: "kal" is itself ambiguous and scores lower still.)
        let explicit = try #require(parser.parse("tomorrow 5pm", now: Fixtures.now))
        #expect(evening.confidence < explicit.confidence)
    }

    @Test("Text with no date abstains rather than guessing")
    func abstains() {
        for text in [
            "call the plumber", "", "   ", "🎉🎉🎉", "https://example.com",
            "refactor the auth module",
        ] {
            #expect(
                parser.parse(text, now: Fixtures.now) == nil,
                "\"\(text)\" should have abstained")
        }
    }

    /// Guard 2: every extracted value cites a span that resolves to real text.
    @Test("Every parse cites a span that resolves")
    func spansResolve() throws {
        let samples = [
            "kal subah 9 baje call karna hai", "meeting on the 25th",
            "ship it next monday", "deadline 15/12", "3 din mein",
        ]
        for text in samples {
            let parsed = try #require(parser.parse(text, now: Fixtures.now), "\(text)")
            let resolved = try #require(parsed.span.resolve(in: text), "span for \"\(text)\"")
            #expect(
                !resolved.trimmingCharacters(in: .whitespaces).isEmpty,
                "\"\(text)\" cited an empty span")
        }
    }

    @Test("Parsing is deterministic")
    func deterministic() {
        for text in ["kal subah 9 baje", "next monday", "15 tarikh", "in 3 days"] {
            let first = parser.parse(text, now: Fixtures.now)
            for _ in 0..<5 {
                #expect(parser.parse(text, now: Fixtures.now)?.date == first?.date, "\(text)")
            }
        }
    }

    /// Everything resolves in the *user's* timezone. The server's clock is never
    /// consulted — the single most common source of off-by-one-day bugs.
    @Test("Timezone drives the result, not the server clock")
    func timezoneMatters() throws {
        // 23:30 IST on 23 Nov is still 18:00 UTC on 23 Nov.
        var comps = DateComponents(year: 2026, month: 11, day: 23, hour: 23, minute: 30)
        comps.timeZone = Fixtures.zone
        let lateNight = Fixtures.calendar.date(from: comps)!

        let ist = DateParser(timeZone: Fixtures.zone)
        let utc = DateParser(timeZone: TimeZone(identifier: "UTC")!)

        let istResult = try #require(ist.parse("kal", now: lateNight))
        let utcResult = try #require(utc.parse("kal", now: lateNight))

        var istCal = Calendar(identifier: .gregorian); istCal.timeZone = Fixtures.zone
        var utcCal = Calendar(identifier: .gregorian);
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        #expect(istCal.component(.day, from: istResult.date) == 24)
        #expect(utcCal.component(.day, from: utcResult.date) == 24)
        #expect(istResult.date != utcResult.date, "same words, different zones, different instants")
    }

    /// **From a real capture, 2026-11-24.** "Need to pay bill which is due 3
    /// days" got no date at all, while "due *in* 3 days" parsed — the rule
    /// required `in` or `after`. A deadline the parser cannot read is the
    /// worst kind of miss: the item looks like it simply has no deadline.
    @Test(
        "`due N days` is a deadline, with or without `in`",
        arguments: [
            "Need to pay bill which is due 3 days",
            "Need to pay bill which is due in 3 days",
            "bill due 3 days",
            "submit the form due 2 days",
        ])
    func dueWithoutIn(text: String) {
        #expect(parser.parse(text, now: Fixtures.now) != nil, "\"\(text)\" lost its deadline")
    }

}
