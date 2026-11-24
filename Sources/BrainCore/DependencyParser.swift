import Foundation

/// A dependency stated in the text: "after the client replies", "client ke baad".
///
/// The parser only extracts the *referent text*. Resolving it to a real item is
/// a separate, deliberate step (`TitleMatcher`), because a reference that
/// matches nothing must produce no edge at all rather than a guess.
public struct ParsedDependency: Sendable, Hashable {
    /// Which way round the blocking runs.
    ///
    /// Without this, `before` could not be supported at all: `ParsedDependency`
    /// used to mean only "this item is blocked by the referent", and
    /// "review the PR before standup" means the opposite — the PR review has
    /// to finish first. Reusing the old shape would have produced a backwards
    /// edge and made the task look unstartable, which is worse than having no
    /// rule.
    public enum Direction: String, Sendable, Hashable {
        /// "after X", "X ke baad" — the referent must finish first.
        case blockedByReferent
        /// "before X", "X se pehle" — *this item* must finish first.
        case blocksReferent
    }

    /// The thing being waited on, or the thing this item must precede.
    public let targetText: String
    public let span: Span
    public let confidence: Double
    public let rule: String
    public let direction: Direction

    public init(
        targetText: String, span: Span, confidence: Double, rule: String,
        direction: Direction = .blockedByReferent
    ) {
        self.targetText = targetText
        self.span = span
        self.confidence = confidence
        self.rule = rule
        self.direction = direction
    }
}

/// Reads explicit blocking phrases out of text. English and Hinglish.
///
/// **T0, named in `docs/09-tiering.md`:** *"after X", "once X is done",
/// "X ke baad", "waiting for", "blocked by"* → a deterministic edge. Only
/// *implicit* semantic dependencies need a model; a stated one is a grammar.
public struct DependencyParser: Sendable {
    public let dateParser: DateParser

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Kolkata")!) {
        self.dateParser = DateParser(timeZone: timeZone)
    }

    public func parse(_ text: String, now: Date = Date()) -> [ParsedDependency] {
        let haystack = text.lowercased()
        var found: [ParsedDependency] = []
        var claimed = Set<Int>()

        for (literal, pattern, direction, confidence, rule) in Self.rules {
            // Cheap literal check first — see the note on `rules`.
            guard haystack.contains(literal) else { continue }
            guard let match = DateParser.firstMatch(pattern, haystack),
                let referent = DateParser.group(match, 1, haystack)
            else { continue }

            let cleaned = Self.clean(referent)
            guard !cleaned.isEmpty, cleaned.count >= 2 else { continue }

            // "after 3 days" is a deadline, not a dependency. Without this
            // cross-check every relative due date becomes a phantom blocker.
            //
            // This used to run only for `.afterMarker`, which left the
            // Hinglish half unguarded: "3 din ke baad deploy krna h" put the
            // referent *before* the marker, so it skipped the check and
            // produced a phantom dependency on "3 din". English
            // "after 3 days" was correctly ignored the whole time, which is
            // what made the gap easy to miss.
            if Self.isTimeExpression(cleaned, dateParser, now) { continue }

            // Don't let two rules claim overlapping text.
            let range = match.range.location..<(match.range.location + match.range.length)
            guard !range.contains(where: claimed.contains) else { continue }
            claimed.formUnion(range)

            found.append(
                ParsedDependency(
                    targetText: cleaned,
                    span: Span(start: match.range.location, end: range.upperBound),
                    confidence: confidence, rule: rule, direction: direction))
        }
        return found
    }

    /// True when the referent is a *time*, not a thing to wait on.
    ///
    /// Two checks, because one is not enough:
    ///
    /// 1. A bare duration — "3 days". The date grammar needs an "in"/"after"
    ///    prefix to recognise it, and the marker has already been consumed by
    ///    the time we look, so the grammar alone would miss it.
    /// 2. A date expression covering **most of** the referent — "next monday",
    ///    "kal". The coverage requirement matters: "client meeting on monday"
    ///    contains a date but is a genuine dependency, and rejecting it would
    ///    be a false negative.
    static func isTimeExpression(_ referent: String, _ parser: DateParser, _ now: Date) -> Bool {
        // Word numerals count too: "ek mahine ke baad" is a month away, not
        // a thing named "ek mahine". Found by the style tests — the digit-only
        // version passed every Hinglish case that happened to use digits.
        let bareDuration =
            #"^(?:\d+(?:\.\d+)?|"# + DateParser.hindiNumberAlternation + #")\s*"#
            + #"(?:min|mins|minutes?|hours?|hrs?|ghante|ghanta|days?|din|weeks?|haft[ae]"#
            + #"|months?|mahine|years?|saal)$"#
        if DateParser.firstMatch(bareDuration, referent) != nil { return true }

        guard let parsed = parser.parse(referent, now: now) else { return false }
        let covered = Double(parsed.span.end - parsed.span.start)
        return covered / Double(max(referent.utf16.count, 1)) >= 0.6
    }

    /// Trims filler that is never part of the referent's name.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?-–—\"'"))
        for article in ["the ", "a ", "an ", "my ", "that "] where text.hasPrefix(article) {
            text = String(text.dropFirst(article.count))
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Patterns

    /// `(literal, pattern, direction, confidence, rule)`, most specific first.
    /// Hinglish puts the referent **before** the marker ("client ke baad") and
    /// English after it; which side it sits on is expressed by where the
    /// capture group goes in each pattern, not by a separate field. A
    /// `Position` column used to say the same thing a second time and was read
    /// nowhere once 0.6.0 made the time cross-check run for both positions.
    ///
    /// **`literal` is a performance guard, not a nicety.** These patterns open
    /// with a lazy quantifier, which on a 60k-character capture with no match
    /// makes NSRegularExpression retry from every position — measured at
    /// **52 seconds** before this check existed. A `contains` on the marker
    /// costs microseconds and skips the regex entirely when it cannot match.
    ///
    /// The referent is also bounded to 80 characters. A task title is never
    /// longer, and an unbounded lazy quantifier is what turns a linear scan
    /// quadratic.
    static let rules: [(String, String, ParsedDependency.Direction, Double, String)] = [
        // Completion reads many ways: "done", but also "green" (CI), "merged",
        // "approved", "back" (a person). Narrow lists cause silent misses.
        (
            "once",
            #"\bonce\s+(.{1,80}?)\s+(?:is\s+|are\s+|has\s+|have\s+)?"#
                + #"(?:done|finished|complete|completed|ready|green|merged|approved|live|back|"#
                + #"signed|confirmed|arrived|replied|landed)\b"#,
            .blockedByReferent, 0.95, "onceDone"
        ),
        (
            "blocked by", #"\bblocked\s+by\s+(.{1,80}?)(?:[,.;]|$)"#, .blockedByReferent, 0.95,
            "blockedBy"
        ),
        (
            "depends on", #"\bdepends\s+on\s+(.{1,80}?)(?:[,.;]|$)"#, .blockedByReferent, 0.95,
            "blockedBy"
        ),
        (
            "wait", #"\b(?:waiting|wait)\s+(?:for|on)\s+(.{1,80}?)(?:[,.;]|$)"#,
            .blockedByReferent, 0.9, "waitingFor"
        ),
        (
            "first", #"\bneeds?\s+(.{1,80}?)\s+first\b"#, .blockedByReferent, 0.9,
            "needsFirst"
        ),
        (
            "ke baad", #"\b(.{1,80}?)\s+(?:ho\s+jaye|hone)\s+ke\s+baad\b"#,
            .blockedByReferent, 0.95, "honeKeBaadHinglish"
        ),
        // "uske baad" and "iske baad" are the commonest informal forms and
        // the generic rule below cannot reach them: `\bke\b` will not match
        // the "ke" inside "uske". Measured — the formal "client ke baad"
        // parsed while "client approve kare uske baad" did not.
        (
            "ske baad", #"\b(.{1,80}?)\s+[ui]ske\s+baad\b"#,
            .blockedByReferent, 0.9, "uskeBaadHinglish"
        ),
        (
            "ke baad", #"\b(.{1,80}?)\s+ke\s+baad\b"#, .blockedByReferent, 0.9,
            "keBaadHinglish"
        ),
        (
            "wait", #"\b(.{1,80}?)\s+k[ae]\s+(?:wait|intezaar|intzaar)\b"#,
            .blockedByReferent, 0.85, "kaWaitHinglish"
        ),
        (
            "intezaar", #"\b(.{1,80}?)\s+k[ae]\s+(?:wait|intezaar|intzaar)\b"#,
            .blockedByReferent, 0.85, "kaWaitHinglish"
        ),
        (
            "after", #"\bafter\s+(.{1,80}?)(?:[,.;]|$)"#, .blockedByReferent, 0.85,
            "after"
        ),

        // --- the `before` direction ----------------------------------------
        // Every rule above is an *after*: "X must finish before this one".
        // "before" is the mirror and had no rule at all, in English or
        // Hinglish — measured at 0 of 5 across all three writing styles.
        (
            "se pehle", #"\b(.{1,80}?)\s+se\s+pehle\b"#,
            .blocksReferent, 0.9, "sePehleHinglish"
        ),
        (
            "ske pehle", #"\b(.{1,80}?)\s+[ui]ske\s+pehle\b"#,
            .blocksReferent, 0.9, "uskePehleHinglish"
        ),
        (
            "before", #"\bbefore\s+(.{1,80}?)(?:[,.;]|$)"#,
            .blocksReferent, 0.85, "before"
        ),
    ]
}

/// Resolves a referent like "client reply" to an existing item.
///
/// Deliberately conservative: below the threshold it returns nothing, so an
/// unmatched reference produces **no edge** rather than a wrong one. A missed
/// link costs the user nothing — they can link manually. A wrong link costs a
/// tap and some trust (`docs/04-scorecard.md`: precision over recall).
public enum TitleMatcher {

    /// Jaccard overlap of normalised word sets, with a containment bonus so a
    /// short reference ("client") still matches a longer title ("email the
    /// client about pricing").
    public static func score(_ needle: String, _ title: String) -> Double {
        let a = tokens(needle)
        let b = tokens(title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        guard shared > 0 else { return 0 }
        let jaccard = Double(shared) / Double(a.union(b).count)
        let containment = Double(shared) / Double(min(a.count, b.count))
        return max(jaccard, containment * 0.85)
    }

    static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "a", "an", "to", "of", "for", "and", "is", "it", "my", "on", "in", "ka",
            "ke", "ki", "ko", "se", "hai", "karna", "kar",
        ]
        return Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 1 && !stop.contains($0) })
    }

    /// Best candidate above `minScore`, or nil. Ties resolve to the lowest id
    /// so the result is deterministic.
    public static func bestMatch(
        _ needle: String, in candidates: [(id: ULID, title: String)], minScore: Double = 0.5
    ) -> (id: ULID, score: Double)? {
        var best: (id: ULID, score: Double)?
        for candidate in candidates {
            let value = score(needle, candidate.title)
            guard value >= minScore else { continue }
            if let current = best {
                if value > current.score || (value == current.score && candidate.id < current.id) {
                    best = (candidate.id, value)
                }
            } else {
                best = (candidate.id, value)
            }
        }
        return best
    }
}
