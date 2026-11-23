import Foundation

/// Decides what a capture *is* — task, idea, note, reminder or link.
///
/// **T0, per `docs/09-tiering.md`:** URL-only → `link`; an idea marker → `idea`;
/// a leading imperative → `task`; an imperative with a date → `reminder`; a
/// verbless fragment → `note`. Only what the rules cannot resolve escalates.
///
/// This is the B2.5 baseline. Whatever B3's model scores, it has to beat these
/// numbers by enough to justify the quota, or the model call does not ship.
public struct TypeClassifier: Sendable {
    public let dateParser: DateParser

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Kolkata")!) {
        self.dateParser = DateParser(timeZone: timeZone)
    }

    public func classify(_ text: String, now: Date = Date()) -> Classified<ItemType> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown() }
        let lower = trimmed.lowercased()

        // 1. A URL carrying little else is a link, not a task about a link.
        if let urlSpan = Self.urlSpan(in: lower) {
            let remainder =
                (lower.prefix(urlSpan.start) + lower.dropFirst(urlSpan.end))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A few framing words ("read this", "dekhna hai") still a link; a
            // whole sentence around it is something else.
            if remainder.split(separator: " ").count <= 3 {
                return Classified(.link, confidence: 0.95, tier: .t0, evidence: urlSpan)
            }
        }

        // 2. Idea markers are explicit and unambiguous.
        for marker in Self.ideaMarkers where lower.hasPrefix(marker) || lower.contains(" \(marker)")
        {
            if let range = lower.range(of: marker) {
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                return Classified(
                    .idea, confidence: 0.9, tier: .t0,
                    evidence: Span(start: start, end: start + marker.utf16.count))
            }
        }

        // 3. An imperative makes it actionable. A **clock time** on top makes
        //    it a reminder — not merely a date. "Clean the kitchen tomorrow" is
        //    a task with a deadline; "call Priya tomorrow at 9am" is a reminder.
        //    Using any date here conflated the two, and nothing in the text
        //    could have separated them.
        if let verb = Self.imperativeSpan(in: lower) {
            let hasTime = DateParser.findTime(in: lower) != nil
            return Classified(
                hasTime ? .reminder : .task,
                confidence: hasTime ? 0.85 : 0.8, tier: .t0, evidence: verb)
        }

        // 4. A short verbless fragment is a note. Anything longer is genuinely
        //    ambiguous, and abstaining beats guessing (`docs/04-scorecard.md`).
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "\n" })
        if words.count <= 8 {
            return Classified(
                .note, confidence: 0.6, tier: .t0,
                evidence: Span(start: 0, end: trimmed.utf16.count))
        }
        return .unknown()
    }

    // MARK: - Signals

    static func urlSpan(in text: String) -> Span? {
        guard let match = DateParser.firstMatch(#"https?://\S+|www\.\S+"#, text) else {
            return nil
        }
        return DateParser.span(match)
    }

    static let ideaMarkers = ["idea:", "thought:", "what if", "kya agar", "soch raha", "maybe we"]

    /// Hinglish marks the imperative at the *end* ("... karna hai"), English at
    /// the start ("call the plumber"). Both are checked, because a parser that
    /// only knows English word order silently classifies half our captures as
    /// notes.
    static let hinglishImperatives = [
        "karna hai", "karna h", "karni hai", "karne hai", "lena hai", "dena hai",
        "bhejna hai", "lana hai", "jana hai", "dekhna hai", "bharna hai", "milna hai",
        "karna", "bhejna", "lana",
    ]

    /// Verbs that start an instruction. Deliberately broad — the cost of a miss
    /// is classifying a real task as a note.
    public static let imperativeVerbs: Set<String> = [
        "call", "phone", "ring", "text", "message", "email", "mail", "reply", "respond",
        "send", "forward", "ask", "tell", "inform", "remind", "thank", "invite", "confirm",
        "buy", "purchase", "get", "grab", "fetch", "order", "collect", "pick", "restock",
        "refill", "return", "exchange", "donate", "print", "courier", "deliver",
        "pay", "settle", "transfer", "deposit", "withdraw", "reconcile", "clear",
        "submit", "apply", "renew", "register", "verify", "sign", "upload", "download",
        "scan", "file", "update", "log", "track", "check", "chase",
        "clean", "wash", "tidy", "declutter", "fold", "iron", "sweep", "mop", "dust",
        "vacuum", "cook", "chop", "repair", "fix", "replace", "assemble", "install",
        "charge", "pack", "unpack", "sort", "dispose", "water", "scrub",
        "write", "draft", "design", "edit", "build", "code", "develop", "create",
        "compose", "record", "shoot", "outline", "prototype", "draw", "paint", "sketch",
        "rework", "spike", "finish", "start", "prepare", "review", "make", "test",
        "read", "study", "learn", "revise", "practice", "practise", "solve", "watch",
        "skim", "plan", "schedule", "book", "reserve", "arrange", "compare", "choose",
        "decide", "shortlist", "pencil", "line",
        "walk", "run", "stretch", "meditate", "rest", "sleep", "nap",
        "add", "remove", "move", "copy", "share", "post", "upload", "set", "setup",
        "find", "search", "look", "try", "fill", "close", "open", "cancel", "renew",
    ]

    static func imperativeSpan(in text: String) -> Span? {
        // Hinglish verb-final first: "sabzi lana hai" has no leading verb.
        for marker in hinglishImperatives {
            guard let range = text.range(of: marker) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            return Span(start: start, end: start + marker.utf16.count)
        }
        // English: an imperative verb anywhere in the first three words. Not
        // only the first, because fillers ("btw", "also") and dates ("kal call
        // the plumber") routinely come first.
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
        for word in words.prefix(4) where imperativeVerbs.contains(word) {
            guard let range = text.range(of: word) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            return Span(start: start, end: start + word.utf16.count)
        }
        return nil
    }
}
