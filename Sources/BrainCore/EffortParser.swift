import Foundation

/// An effort estimate read out of the text, with the span it came from.
public struct ParsedEffort: Sendable, Hashable {
    public let bucket: EffortBucket
    /// Minutes as written, before bucketing. Kept for tracing.
    public let minutes: Double
    public let span: Span
    public let confidence: Double
    /// Which rule fired, for the per-rule breakdown on the scorecard.
    public let rule: String
}

/// Reads an explicit duration out of a task's text. English and Hinglish.
///
/// **T0, named in `docs/09-tiering.md`:** *"If the user said how long, read it.
/// Don't infer it."* Inferring effort from a title is a model's job (B2.5/B3);
/// reading "2 ghante" is a grammar's job, and belongs here.
public struct EffortParser: Sendable {

    public init() {}

    /// Bucket boundaries are the **geometric** midpoints between bucket
    /// minutes (5, 20, 60, 240, 960), matching the log-scale effort
    /// denominator in `Scoring.effortDenominator`. Arithmetic midpoints would
    /// put the boundaries in the wrong places on a log scale.
    public static func bucket(forMinutes minutes: Double) -> EffortBucket {
        switch minutes {
        case ..<10: .tiny  // √(5×20)
        case ..<35: .small  // √(20×60)
        case ..<120: .medium  // √(60×240)
        case ..<480: .large  // √(240×960)
        default: .xlarge
        }
    }

    /// One working day, not 24 hours: effort means time spent, not elapsed.
    static let workingDayMinutes = 480.0

    /// Words that mean the number after them is a **deadline, not a duration**.
    /// "due in 2 days" is a date; "2 days of work" is an effort. Without this
    /// guard every relative due date would also register as xlarge effort.
    static let dateLeadIns = ["in", "after", "due", "within", "every", "next", "by"]

    public func parse(_ text: String) -> ParsedEffort? {
        let haystack = text.lowercased()

        // Fixed phrases first — they are unambiguous and cheap.
        for (pattern, minutes, rule) in Self.phrases {
            guard let match = DateParser.firstMatch(pattern, haystack) else { continue }
            return ParsedEffort(
                bucket: Self.bucket(forMinutes: minutes), minutes: minutes,
                span: DateParser.span(match), confidence: 0.9, rule: rule)
        }

        // Then `<number> <unit>`.
        for (pattern, multiplier, rule) in Self.quantities {
            guard let match = DateParser.firstMatch(pattern, haystack),
                let amount = DateParser.group(match, 1, haystack).flatMap(Double.init),
                amount > 0
            else { continue }
            guard !Self.isPrecededByDateWord(haystack, at: match.range.location) else { continue }

            let minutes = amount * multiplier
            return ParsedEffort(
                bucket: Self.bucket(forMinutes: minutes), minutes: minutes,
                span: DateParser.span(match), confidence: 0.95, rule: rule)
        }

        // Qualitative hints last, and only the unambiguous ones. "long" and
        // "bada" are deliberately absent: they are vague enough that abstaining
        // and escalating is better than a confident guess.
        for (pattern, minutes, rule) in Self.qualitative {
            guard let match = DateParser.firstMatch(pattern, haystack) else { continue }
            return ParsedEffort(
                bucket: Self.bucket(forMinutes: minutes), minutes: minutes,
                span: DateParser.span(match), confidence: 0.6, rule: rule)
        }
        return nil
    }

    /// True if the two words before `location` mark a deadline rather than a
    /// duration.
    static func isPrecededByDateWord(_ text: String, at location: Int) -> Bool {
        let utf16 = Array(text.utf16)
        guard location > 0, location <= utf16.count else { return false }
        let prefix = String(decoding: utf16[0..<location], as: UTF16.self)
        let words = prefix.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.suffix(2).contains { dateLeadIns.contains($0) }
    }

    // MARK: - Patterns

    /// Fixed phrases with a known duration.
    static let phrases: [(String, Double, String)] = [
        (#"\b(?:aadha|aadhaa|adha)\s+ghant[aey]\b"#, 30, "halfHourHinglish"),
        (#"\b(?:aadhe|adhe)\s+ghante\b"#, 30, "halfHourHinglish"),
        (#"\bhalf\s+an?\s+hour\b"#, 30, "halfHour"),
        (#"\bquarter\s+of\s+an?\s+hour\b"#, 15, "quarterHour"),
        (#"\b(?:poora|pura)\s+din\b"#, workingDayMinutes, "wholeDayHinglish"),
        (#"\b(?:whole|full|all)\s+day\b"#, workingDayMinutes, "wholeDay"),
        (#"\bcouple\s+of\s+hours\b"#, 120, "coupleOfHours"),
    ]

    /// `<number> <unit>`. Hinglish units sit alongside English ones.
    static let quantities: [(String, Double, String)] = [
        (#"\b(\d+(?:\.\d+)?)\s*(?:minutes?|mins?|min)\b"#, 1, "minutes"),
        (#"\b(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\b"#, 60, "hours"),
        (#"\b(\d+(?:\.\d+)?)\s*(?:ghante|ghanta|ghanton|ghante)\b"#, 60, "hoursHinglish"),
        (#"\b(\d+(?:\.\d+)?)\s*(?:days?)\b"#, workingDayMinutes, "days"),
        (#"\b(\d+(?:\.\d+)?)\s*(?:din)\b"#, workingDayMinutes, "daysHinglish"),
        (#"\b(\d+(?:\.\d+)?)\s*(?:weeks?|haft[ae])\b"#, 5 * workingDayMinutes, "weeks"),
    ]

    /// Vague but directional. Low confidence, so the cascade can escalate.
    static let qualitative: [(String, Double, String)] = [
        (#"\bjaldi(?:\s+se)?\b"#, 5, "quickHinglish"),
        (#"\bquick(?:ly)?\b"#, 5, "quick"),
        (#"\b(?:chhota|chota)\s+(?:kaam|task)\b"#, 5, "smallTaskHinglish"),
        (#"\b(?:ek|1)\s+minute\s+ka\s+kaam\b"#, 5, "oneMinuteHinglish"),
    ]
}
