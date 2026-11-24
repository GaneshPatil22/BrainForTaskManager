import Foundation

/// A date parsed out of raw capture text, with the span it came from.
public struct ParsedDate: Sendable, Hashable {
    public let date: Date
    public let span: Span
    public let confidence: Double
    /// Which rule fired. Recorded for tracing and for the scorecard's
    /// per-rule breakdown.
    public let rule: String
}

/// Deterministic date parsing for English and Hinglish.
///
/// **Dates are never parsed by a model** (`docs/09-tiering.md`). This is a
/// grammar, not a classification problem: an LLM parsing "kal" is the `2+2`
/// mistake. Guard 5 in `docs/07-harness-spec.md` is not toggleable.
///
/// Everything resolves against the *user's* timezone, never the server's.
public struct DateParser: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = cal
    }

    /// Date-only expressions resolve to the end of that day: a task due "kal"
    /// is due *by* the end of tomorrow, not at midnight.
    static let endOfDay = (hour: 23, minute: 59, second: 59)

    // MARK: - Entry point

    /// Returns the first date expression found, by rule priority (most specific
    /// first). Returns nil when there is nothing to parse — abstention, not failure.
    public func parse(_ text: String, now: Date) -> ParsedDate? {
        let haystack = text.lowercased()
        let time = Self.findTime(in: haystack)

        // **Earliest match wins**, ties broken by rule order.
        //
        // Returning on the first *rule* that matched meant order of
        // declaration decided, not the text: "kal kal kal parso kal" returned
        // `parso`, because the parso rule is listed first (it has to be, so
        // "day after tomorrow" is not eaten by the "tomorrow" rule). Position
        // is what a reader expects, and specificity still wins where two rules
        // overlap, because the longer phrase starts earlier.
        var best: (match: Match, ruleIndex: Int)?
        for (index, rule) in Self.rules.enumerated() {
            guard let match = rule.match(haystack, now, calendar) else { continue }
            if let current = best {
                let isEarlier = match.span.start < current.match.span.start
                guard isEarlier else { continue }
            }
            best = (match, index)
        }

        if let match = best?.match {
            var date = match.date
            var span = match.span
            var confidence = match.confidence

            if let time {
                date =
                    calendar.date(
                        bySettingHour: time.hour, minute: time.minute,
                        second: 0, of: date) ?? date
                span = Span(
                    start: min(span.start, time.span.start),
                    end: max(span.end, time.span.end))
                confidence = min(confidence, time.confidence)
            }
            return ParsedDate(date: date, span: span, confidence: confidence, rule: match.rule)
        }

        // A time with no day word: "shaam 5 baje", "9am", "call at 6:30".
        // Previously this returned nil, losing a date the user clearly stated.
        // Resolve to the next occurrence of that clock time — today if it is
        // still ahead, otherwise tomorrow, matching the roll-forward convention
        // the dated rules already use ("15 tarikh" rolls to next month).
        if let time {
            guard
                let todayAtTime = calendar.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: now)
            else { return nil }
            let resolved =
                todayAtTime > now
                ? todayAtTime
                : calendar.date(byAdding: .day, value: 1, to: todayAtTime) ?? todayAtTime
            // Lower than the time's own confidence: the clock time was stated,
            // the day was inferred.
            return ParsedDate(
                date: resolved, span: time.span,
                confidence: time.confidence * 0.9, rule: "timeOnly")
        }
        return nil
    }

    // MARK: - Rule table, most specific first

    struct Rule: Sendable {
        let match: @Sendable (String, Date, Calendar) -> Match?
    }
    struct Match: Sendable {
        let date: Date, span: Span, confidence: Double, rule: String
    }

    static let rules: [Rule] = [
        Rule(match: matchNumericDate),
        Rule(match: matchMonthName),
        Rule(match: matchDayOfMonth),
        Rule(match: matchMonthEnd),
        Rule(match: matchThisPeriod),
        Rule(match: matchNextPeriod),
        Rule(match: matchInNDays),
        Rule(match: matchWeekday),
        Rule(match: matchDayWord),
    ]

    // MARK: - Helpers

    static func endOfDay(_ date: Date, _ cal: Calendar) -> Date {
        cal.date(
            bySettingHour: endOfDay.hour, minute: endOfDay.minute,
            second: endOfDay.second, of: date) ?? date
    }

    public static func firstMatch(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    public static func span(_ result: NSTextCheckingResult) -> Span {
        Span(start: result.range.location, end: result.range.location + result.range.length)
    }

    public static func group(_ result: NSTextCheckingResult, _ index: Int, _ text: String)
        -> String?
    {
        guard index < result.numberOfRanges,
            let range = Range(result.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - Rules

    /// `15/12`, `15-12-2026`, `15.12.26`. Day-first, as used in India.
    static let matchNumericDate: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        guard let m = firstMatch(#"\b(\d{1,2})[/\-.](\d{1,2})(?:[/\-.](\d{2,4}))?\b"#, text),
            let day = group(m, 1, text).flatMap(Int.init),
            let month = group(m, 2, text).flatMap(Int.init),
            (1...31).contains(day), (1...12).contains(month)
        else { return nil }

        var year = cal.component(.year, from: now)
        if let raw = group(m, 3, text).flatMap(Int.init) {
            year = raw < 100 ? 2000 + raw : raw
        }
        var comps = DateComponents(year: year, month: month, day: day)
        comps.hour = endOfDay.hour; comps.minute = endOfDay.minute; comps.second = endOfDay.second
        guard let date = cal.date(from: comps) else { return nil }
        // A bare day/month already past this year means next year.
        let finalDate =
            (group(m, 3, text) == nil && date < now)
            ? cal.date(byAdding: .year, value: 1, to: date) ?? date
            : date
        return Match(date: finalDate, span: span(m), confidence: 0.95, rule: "numericDate")
    }

    static let monthNames = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// `15 dec`, `dec 15`, `15th december`.
    static let matchMonthName: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let months = monthNames.keys.joined(separator: "|")
        let patterns = [
            #"\b(\d{1,2})(?:st|nd|rd|th)?\s+("# + months + #")[a-z]*\b"#,
            #"\b("# + months + #")[a-z]*\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let m = firstMatch(pattern, text) else { continue }
            let dayGroup = index == 0 ? 1 : 2
            let monthGroup = index == 0 ? 2 : 1
            guard let day = group(m, dayGroup, text).flatMap(Int.init),
                let key = group(m, monthGroup, text)?.prefix(3),
                let month = monthNames[String(key)], (1...31).contains(day)
            else { continue }

            var comps = DateComponents(
                year: cal.component(.year, from: now), month: month, day: day)
            comps.hour = endOfDay.hour; comps.minute = endOfDay.minute;
            comps.second = endOfDay.second
            guard let date = cal.date(from: comps) else { continue }
            let finalDate =
                date < now ? cal.date(byAdding: .year, value: 1, to: date) ?? date : date
            return Match(date: finalDate, span: span(m), confidence: 0.95, rule: "monthName")
        }
        return nil
    }

    // MARK: - Hindi numerals

    /// Hindi numbers as people actually romanise them, 1–31: dates need up to
    /// 31, clock times up to 12.
    ///
    /// **Why a lookup and not a text rewrite.** Normalising "pandrah tarikh"
    /// into "15 tarikh" before parsing would be far less code — and would move
    /// every span after it. Spans index the user's original text and
    /// `span-verified rate` is a scorecard invariant at 100%, so the numerals
    /// are matched in place instead.
    ///
    /// `no` for 9 is deliberately absent: it collides with English "no", and a
    /// missed time costs less than a wrong one.
    public static let hindiNumbers: [String: Int] = [
        "ek": 1, "do": 2, "teen": 3, "tin": 3, "char": 4, "chaar": 4,
        "paanch": 5, "panch": 5, "chhe": 6, "che": 6, "cheh": 6, "chah": 6,
        "saat": 7, "sat": 7, "aath": 8, "ath": 8, "nau": 9,
        "das": 10, "dus": 10, "gyarah": 11, "gyara": 11, "barah": 12, "bara": 12,
        "terah": 13, "tera": 13, "chaudah": 14, "chauda": 14,
        "pandrah": 15, "pandra": 15, "solah": 16, "sola": 16,
        "satrah": 17, "satra": 17, "atharah": 18, "athara": 18,
        "unnis": 19, "unis": 19, "bees": 20, "bis": 20,
        "ikkis": 21, "bais": 22, "baees": 22, "teis": 23, "chaubis": 24,
        "pachchis": 25, "pachis": 25, "chhabbis": 26, "sattais": 27,
        "atthais": 28, "untis": 29, "tees": 30, "ikattis": 31,
    ]

    /// The spellings alone, longest first so "teis" is never shadowed by a
    /// shorter alternative that also prefixes it.
    public static let hindiNumberAlternation: String =
        hindiNumbers.keys.sorted { ($0.count, $0) > ($1.count, $1) }.joined(separator: "|")

    /// `\d{1,2}` or any spelling above.
    static let numberToken: String = "(?:\\d{1,2}|" + hindiNumberAlternation + ")"

    /// Digits or a Hindi numeral word.
    public static func numericValue(_ text: String?) -> Int? {
        guard let text else { return nil }
        if let digits = Int(text) { return digits }
        return hindiNumbers[text.lowercased()]
    }

    /// `15 tarikh`, `15 tarikh ko`, `on the 15th`, `pandrah tarikh`.
    static let matchDayOfMonth: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let patterns = [
            #"\b("# + numberToken + #")\s*tarikh(?:\s+ko)?\b"#,
            #"\bon\s+the\s+(\d{1,2})(?:st|nd|rd|th)\b"#,
        ]
        for pattern in patterns {
            guard let m = firstMatch(pattern, text),
                let day = numericValue(group(m, 1, text)),
                (1...31).contains(day)
            else { continue }
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = day
            comps.hour = endOfDay.hour; comps.minute = endOfDay.minute;
            comps.second = endOfDay.second
            guard let date = cal.date(from: comps) else { continue }
            // Already passed this month → next month.
            let finalDate =
                date < now ? cal.date(byAdding: .month, value: 1, to: date) ?? date : date
            return Match(date: finalDate, span: span(m), confidence: 0.9, rule: "dayOfMonth")
        }
        return nil
    }

    /// `end of month`, `month end`, `mahine ke end`, `mahine ke akhir`.
    static let matchMonthEnd: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let pattern =
            #"\b(end\s+of\s+(?:the\s+)?month|month\s*-?\s*end|mahine\s+ke\s+(?:end|akhir|ant))\b"#
        guard let m = firstMatch(pattern, text),
            let range = cal.range(of: .day, in: .month, for: now)
        else { return nil }
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.day = range.count
        comps.hour = endOfDay.hour; comps.minute = endOfDay.minute; comps.second = endOfDay.second
        guard let date = cal.date(from: comps) else { return nil }
        return Match(date: date, span: span(m), confidence: 0.9, rule: "monthEnd")
    }

    /// `this week`, `is hafte`, `weekend`, `is weekend`.
    ///
    /// "This week" resolves to the coming Sunday (week end), "weekend" to the
    /// coming Saturday. Both are stated with lower confidence than an explicit
    /// day, because where a week ends is a matter of personal convention.
    static let matchThisPeriod: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        if let m = firstMatch(#"\b(?:is\s+)?week\s*-?\s*end\b|\bweekend\b"#, text) {
            let today = cal.component(.weekday, from: now)
            var delta = 7 - today  // Saturday == 7
            if delta <= 0 { delta += 7 }
            guard let date = cal.date(byAdding: .day, value: delta, to: now) else { return nil }
            return Match(
                date: endOfDay(date, cal), span: span(m), confidence: 0.75, rule: "weekend")
        }
        if let m = firstMatch(#"\b(this\s+week|is\s+haft[ae]|is\s+week)\b"#, text) {
            let today = cal.component(.weekday, from: now)
            var delta = 1 - today  // Sunday == 1, end of the current week
            if delta <= 0 { delta += 7 }
            guard let date = cal.date(byAdding: .day, value: delta, to: now) else { return nil }
            return Match(
                date: endOfDay(date, cal), span: span(m), confidence: 0.75, rule: "thisWeek")
        }
        return nil
    }

    /// `next week`, `agle hafte`, `next month`, `agle mahine`.
    static let matchNextPeriod: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        if let m = firstMatch(#"\b(next\s+week|agle\s+haft[ae]|agle\s+week)\b"#, text) {
            let date = cal.date(byAdding: .day, value: 7, to: now) ?? now
            return Match(
                date: endOfDay(date, cal), span: span(m), confidence: 0.8, rule: "nextWeek")
        }
        if let m = firstMatch(#"\b(next\s+month|agle\s+mahine|agle\s+month)\b"#, text) {
            let date = cal.date(byAdding: .month, value: 1, to: now) ?? now
            return Match(
                date: endOfDay(date, cal), span: span(m), confidence: 0.8, rule: "nextMonth")
        }
        return nil
    }

    /// `in 3 days`, `3 din mein`, `3 din baad`, `after 3 days`, `in 2 weeks`.
    static let matchInNDays: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let patterns: [(String, Int)] = [
            (#"\b(?:in|after)\s+(\d{1,3})\s+days?\b"#, 1),
            (#"\b(\d{1,3})\s+din\s+(?:mein|me|baad|bad)\b"#, 1),
            (#"\b(?:in|after)\s+(\d{1,3})\s+weeks?\b"#, 7),
            (#"\b(\d{1,3})\s+haft[ae]\s+(?:mein|me|baad|bad)\b"#, 7),
        ]
        for (pattern, multiplier) in patterns {
            guard let m = firstMatch(pattern, text),
                let n = group(m, 1, text).flatMap(Int.init), n > 0
            else { continue }
            let date = cal.date(byAdding: .day, value: n * multiplier, to: now) ?? now
            return Match(
                date: endOfDay(date, cal), span: span(m), confidence: 0.95, rule: "inNDays")
        }
        return nil
    }

    static let weekdays: [String: Int] = [  // Calendar weekday: Sunday = 1
        "sunday": 1, "ravivaar": 1, "ravivar": 1, "raviwar": 1, "itvaar": 1, "etvaar": 1,
        "monday": 2, "somvaar": 2, "somvar": 2, "somwar": 2,
        "tuesday": 3, "mangalvaar": 3, "mangalvar": 3, "mangalwar": 3,
        "wednesday": 4, "budhvaar": 4, "budhvar": 4, "budhwar": 4,
        "thursday": 5, "guruvaar": 5, "guruvar": 5, "guruwar": 5, "brihaspativaar": 5,
        "friday": 6, "shukravaar": 6, "shukravar": 6, "shukrawar": 6,
        "saturday": 7, "shanivaar": 7, "shanivar": 7, "shaniwar": 7,
    ]

    /// `next monday`, `monday`, `agle somvaar`.
    ///
    /// Both bare and "next" forms resolve to the next occurrence **strictly
    /// after today**. "Next Monday" is genuinely ambiguous even among native
    /// English speakers (this week's coming Monday vs. next week's), so the
    /// confidence is lowered rather than the ambiguity hidden.
    static let matchWeekday: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let names = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"\b(?:(next|agle|agla)\s+)?("# + names + #")\b"#
        guard let m = firstMatch(pattern, text),
            let name = group(m, 2, text), let target = weekdays[name]
        else { return nil }

        let today = cal.component(.weekday, from: now)
        var delta = target - today
        if delta <= 0 { delta += 7 }  // strictly future
        let explicitNext = group(m, 1, text) != nil
        guard let date = cal.date(byAdding: .day, value: delta, to: now) else { return nil }
        return Match(
            date: endOfDay(date, cal), span: span(m),
            confidence: explicitNext ? 0.8 : 0.85, rule: "weekday")
    }

    /// `today`/`aaj`, `tomorrow`/`kal`, `day after tomorrow`/`parso`.
    ///
    /// **"kal" means both yesterday and tomorrow in Hindi**, and "parso" both
    /// the day after tomorrow and the day before yesterday. In a capture — where
    /// the user is recording something to do — the future reading dominates
    /// overwhelmingly, so we take it, and record lower confidence to say so.
    static let matchDayWord: @Sendable (String, Date, Calendar) -> Match? = { text, now, cal in
        let rules: [(String, Int, Double, String)] = [
            (#"\b(day\s+after\s+tomorrow|parso|parsoon)\b"#, 2, 0.8, "parso"),
            (#"\b(tomorrow|kal)\b"#, 1, 0.8, "kal"),
            (#"\b(today|aaj|tonight|aaj\s+raat)\b"#, 0, 0.95, "today"),
        ]
        // Earliest match wins here too. Listing `parso` first is necessary so
        // "day after tomorrow" is not eaten by the "tomorrow" rule — but that
        // ordering must not decide between *disjoint* mentions, or
        // "kal kal kal parso kal" resolves to parso.
        var best: Match?
        for (pattern, offset, confidence, rule) in rules {
            guard let m = firstMatch(pattern, text) else { continue }
            if let current = best, current.span.start <= m.range.location { continue }
            let matched = group(m, 1, text) ?? ""
            let isHinglish = ["kal", "parso", "parsoon"].contains(matched)
            guard let date = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            best = Match(
                date: endOfDay(date, cal), span: span(m),
                confidence: isHinglish ? confidence : 0.95, rule: rule)
        }
        return best
    }

    // MARK: - Time of day

    /// A clock time found in the text. Public because `TypeClassifier` uses
    /// its presence to tell a reminder ("call Priya at 9am") from a task with
    /// a deadline ("call Priya tomorrow").
    public struct TimeMatch: Sendable {
        let hour: Int, minute: Int; let span: Span; let confidence: Double
    }

    /// Maps a Hinglish period word plus a clock hour onto a 24-hour value.
    ///
    /// The periods are not simple AM/PM: "raat 2 baje" is 2 a.m., "raat 12 baje"
    /// is midnight, and "dopahar 12 baje" is noon. Each is spelled out rather
    /// than approximated, because this is exactly the kind of thing a model
    /// would get subtly wrong and code gets exactly right.
    static func hour(period: String, rawHour: Int) -> Int {
        let h = rawHour % 12  // 12 maps to 0
        switch period {
        case "subah": return h  // subah 9  -> 09
        case "dopahar": return h == 0 ? 12 : h + 12  // dopahar 12 -> 12, 2 -> 14
        case "shaam": return h == 0 ? 12 : h + 12  // shaam 5  -> 17
        case "raat": return h <= 4 ? h : h + 12  // raat 12 -> 00, 2 -> 02, 10 -> 22
        default: return h
        }
    }

    /// `subah 9 baje`, `shaam 5 baje`, `9 baje`, `9am`, `5:30 pm`.
    public static func findTime(in text: String) -> TimeMatch? {
        // A period word disambiguates completely, so confidence stays high.
        for period in ["subah", "dopahar", "shaam", "raat"] {
            guard
                let m = firstMatch(
                    #"\b"# + period + #"\s+("# + numberToken + #")(?::(\d{2}))?\s*baje\b"#,
                    text),
                let rawHour = numericValue(group(m, 1, text)),
                (1...12).contains(rawHour)
            else { continue }
            let minute = group(m, 2, text).flatMap(Int.init) ?? 0
            return TimeMatch(
                hour: hour(period: period, rawHour: rawHour),
                minute: min(minute, 59), span: span(m), confidence: 0.9)
        }
        // English `9am`, `5:30 pm`.
        if let m = firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, text),
            let rawHour = group(m, 1, text).flatMap(Int.init), (1...12).contains(rawHour)
        {
            let minute = group(m, 2, text).flatMap(Int.init) ?? 0
            let isPM = group(m, 3, text)?.lowercased() == "pm"
            let hour = isPM ? (rawHour % 12) + 12 : rawHour % 12
            return TimeMatch(hour: hour, minute: min(minute, 59), span: span(m), confidence: 0.95)
        }
        // Bare "N baje", no period word. Heuristic: 8-11 reads as morning,
        // everything else as evening ("5 baje" is 5 p.m., "9 baje" is 9 a.m.).
        // Confidence is dropped to 0.7 so it looks like the guess it is.
        if let m = firstMatch(
            #"\b("# + numberToken + #")(?::(\d{2}))?\s*baje\b"#, text),
            let rawHour = numericValue(group(m, 1, text)), (1...12).contains(rawHour)
        {
            let minute = group(m, 2, text).flatMap(Int.init) ?? 0
            let hour = (8...11).contains(rawHour) ? rawHour : (rawHour % 12) + 12
            return TimeMatch(hour: hour, minute: min(minute, 59), span: span(m), confidence: 0.7)
        }
        return nil
    }
}
