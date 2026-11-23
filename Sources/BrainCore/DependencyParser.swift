import Foundation

/// A dependency stated in the text: "after the client replies", "client ke baad".
///
/// The parser only extracts the *referent text*. Resolving it to a real item is
/// a separate, deliberate step (`TitleMatcher`), because a reference that
/// matches nothing must produce no edge at all rather than a guess.
public struct ParsedDependency: Sendable, Hashable {
    /// The thing being waited on, as written.
    public let targetText: String
    public let span: Span
    public let confidence: Double
    public let rule: String
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

    /// Where the referent sits relative to the marker.
    enum Position { case afterMarker, beforeMarker }

    public func parse(_ text: String, now: Date = Date()) -> [ParsedDependency] {
        let haystack = text.lowercased()
        var found: [ParsedDependency] = []
        var claimed = Set<Int>()

        for (literal, pattern, position, confidence, rule) in Self.rules {
            // Cheap literal check first — see the note on `rules`.
            guard haystack.contains(literal) else { continue }
            guard let match = DateParser.firstMatch(pattern, haystack),
                let referent = DateParser.group(match, 1, haystack)
            else { continue }

            let cleaned = Self.clean(referent)
            guard !cleaned.isEmpty, cleaned.count >= 2 else { continue }

            // "after 3 days" is a deadline, not a dependency. Without this
            // cross-check every relative due date becomes a phantom blocker.
            if position == .afterMarker, Self.isTimeExpression(cleaned, dateParser, now) {
                continue
            }

            // Don't let two rules claim overlapping text.
            let range = match.range.location..<(match.range.location + match.range.length)
            guard !range.contains(where: claimed.contains) else { continue }
            claimed.formUnion(range)

            found.append(
                ParsedDependency(
                    targetText: cleaned,
                    span: Span(start: match.range.location, end: range.upperBound),
                    confidence: confidence, rule: rule))
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
        let bareDuration =
            #"^\d+(?:\.\d+)?\s*"#
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

    /// `(literal, pattern, position, confidence, rule)`, most specific first.
    /// Hinglish puts the referent **before** the marker ("client ke baad"),
    /// English after it — `Position` is what lets one parser handle both.
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
    static let rules: [(String, String, Position, Double, String)] = [
        // Completion reads many ways: "done", but also "green" (CI), "merged",
        // "approved", "back" (a person). Narrow lists cause silent misses.
        (
            "once",
            #"\bonce\s+(.{1,80}?)\s+(?:is\s+|are\s+|has\s+|have\s+)?"#
                + #"(?:done|finished|complete|completed|ready|green|merged|approved|live|back|"#
                + #"signed|confirmed|arrived|replied|landed)\b"#,
            .afterMarker, 0.95, "onceDone"
        ),
        ("blocked by", #"\bblocked\s+by\s+(.{1,80}?)(?:[,.;]|$)"#, .afterMarker, 0.95, "blockedBy"),
        ("depends on", #"\bdepends\s+on\s+(.{1,80}?)(?:[,.;]|$)"#, .afterMarker, 0.95, "blockedBy"),
        (
            "wait", #"\b(?:waiting|wait)\s+(?:for|on)\s+(.{1,80}?)(?:[,.;]|$)"#,
            .afterMarker, 0.9, "waitingFor"
        ),
        ("first", #"\bneeds?\s+(.{1,80}?)\s+first\b"#, .afterMarker, 0.9, "needsFirst"),
        (
            "ke baad", #"\b(.{1,80}?)\s+(?:ho\s+jaye|hone)\s+ke\s+baad\b"#,
            .beforeMarker, 0.95, "honeKeBaadHinglish"
        ),
        ("ke baad", #"\b(.{1,80}?)\s+ke\s+baad\b"#, .beforeMarker, 0.9, "keBaadHinglish"),
        (
            "wait", #"\b(.{1,80}?)\s+k[ae]\s+(?:wait|intezaar|intzaar)\b"#,
            .beforeMarker, 0.85, "kaWaitHinglish"
        ),
        (
            "intezaar", #"\b(.{1,80}?)\s+k[ae]\s+(?:wait|intezaar|intzaar)\b"#,
            .beforeMarker, 0.85, "kaWaitHinglish"
        ),
        ("after", #"\bafter\s+(.{1,80}?)(?:[,.;]|$)"#, .afterMarker, 0.85, "after"),
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
