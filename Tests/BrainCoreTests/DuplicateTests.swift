import Foundation
import Testing

@testable import BrainCore

/// Duplicate detection: "have I written this down already?"
///
/// Nothing in Brain had ever created a `duplicate` edge. The kind existed in
/// the graph and the API, the web prototype's mock invented them, and
/// production could not produce one — so the Inbox looked far richer in the
/// mock than it could ever be for a real user.
///
/// **These pairs are hand-written and that is the point.** The generated
/// corpus cannot contain a duplicate it was not told to generate, and the same
/// circularity that hid the missing `before` rule applies here. Fifteen pairs
/// found the containment flaw that no amount of synthetic data would have.
@Suite("Duplicates")
struct DuplicateTests {

    /// The same intent written twice, across English and both Hinglish styles.
    static let duplicates: [(String, String)] = [
        ("kal manager ko call karna hai about raise", "Call manager about the raise"),
        ("book the scooter test ride", "scooter test ride book karna hai"),
        ("Pay the electricity bill", "electricity bill pay karna h"),
        ("Draft the eval dataset schema", "eval dataset schema draft karna hai"),
        ("outline the swift pune college session", "swift pune college session outline karna hai"),
    ]

    /// Same shape, same verb, **different object.** These are the ones that
    /// matter: a method that cannot tell "about raise" from "about leave" is
    /// worse than no duplicate detection at all.
    static let notDuplicates: [(String, String)] = [
        ("call manager about raise", "call manager about leave"),
        ("pay rent", "pay loan"),
        ("book scooter test ride", "book flight tickets"),
        ("email the client about pricing", "email the client about the timeline"),
        ("read 10 pages", "read the contract"),
        ("the pricing thing", "pricing"),
        ("call the plumber", "call the electrician"),
        ("review the PR", "review the budget"),
    ]

    @Test("Real duplicates clear the threshold", arguments: duplicates)
    func duplicatesFire(a: String, b: String) {
        let score = TitleMatcher.overlap(a, b)
        #expect(
            score >= TitleMatcher.duplicateThreshold,
            "\(a) || \(b) scored \(score)")
    }

    @Test("Same verb, different object is not a duplicate", arguments: notDuplicates)
    func nonDuplicatesDoNotFire(a: String, b: String) {
        let score = TitleMatcher.overlap(a, b)
        #expect(
            score < TitleMatcher.duplicateThreshold,
            "\(a) || \(b) scored \(score)")
    }

    /// The finding that chose the metric. `score`'s containment bonus makes a
    /// short title match anything containing it, which is correct for a
    /// dependency reference and fatal for a duplicate.
    @Test("Containment cannot separate duplicates, and overlap can")
    func containmentIsWrongForDuplicates() {
        let trap = ("the pricing thing", "pricing")
        let real = ("book the scooter test ride", "scooter test ride book karna hai")

        // Under `score` the false positive is indistinguishable from a real one.
        #expect(TitleMatcher.score(trap.0, trap.1) >= 0.8)
        #expect(
            TitleMatcher.score(trap.0, trap.1) >= TitleMatcher.score(real.0, real.1) * 0.8,
            "no threshold on `score` separates these")

        // Under `overlap` they are on opposite sides of the threshold.
        #expect(TitleMatcher.overlap(trap.0, trap.1) < TitleMatcher.duplicateThreshold)
        #expect(TitleMatcher.overlap(real.0, real.1) >= TitleMatcher.duplicateThreshold)
    }

    /// Stated as a test so the cost of the conservative threshold is visible
    /// rather than discovered later. 0.667 is a real duplicate we decline to
    /// flag, because 15 pairs cannot justify moving the bar down to 0.65.
    @Test("A known miss, accepted deliberately")
    func knownMiss() {
        let score = TitleMatcher.overlap("call plumber", "plumber ko call krna h")
        #expect(score > 0.6 && score < TitleMatcher.duplicateThreshold)
    }

    /// Cross-language synonyms are beyond any token-overlap method: "read" and
    /// "padhna" share no characters. Recorded, not fixed — fixing it needs
    /// embeddings, which is T1 and a different phase.
    @Test("Cross-language synonyms are a known limitation, not a bug")
    func crossLanguageLimitation() {
        let score = TitleMatcher.overlap("read 10 pages today", "10 pages padhna hai")
        #expect(score < TitleMatcher.duplicateThreshold, "no token overlap can catch this")
    }

    // MARK: - Links

    /// The false positive that word overlap gets badly wrong. Two unrelated
    /// posts on one domain share every word-like piece of their address, and
    /// the character that distinguishes them is dropped as a single letter.
    @Test(
        "Two different links are never duplicates, however alike the addresses",
        arguments: [
            (
                "https://example.com/blog/a-post?ref=x",
                "https://example.com/blog/b-post?ref=x"
            ),
            (
                "https://news.ycombinator.com/item?id=4242424",
                "https://news.ycombinator.com/item?id=9999999"
            ),
            (
                "read https://blog.swift.org/swift-6-concurrency",
                "read https://blog.swift.org/swift-testing-intro"
            ),
            ("https://youtube.com/watch?v=abc123", "https://youtube.com/watch?v=xyz789"),
        ])
    func differentLinksAreNotDuplicates(a: String, b: String) {
        // Word overlap alone gets these wrong — that is why the rule exists.
        #expect(TitleMatcher.duplicateScore(a, b) == 0, "\(a) || \(b)")
    }

    @Test("Word overlap alone would have called two different posts identical")
    func theBugThisFixed() {
        let a = "https://example.com/blog/a-post?ref=x"
        let b = "https://example.com/blog/b-post?ref=x"
        #expect(TitleMatcher.overlap(a, b) == 1.0, "the measurement that found it")
        #expect(TitleMatcher.duplicateScore(a, b) == 0, "and what it is now")
    }

    /// The opposite mistake: leaving links to word overlap misses the
    /// clearest duplicate of all, because the words around a link are exactly
    /// what differs between two notes about the same thing.
    @Test("The same link saved twice is a duplicate, whatever surrounds it")
    func sameLinkIsADuplicate() {
        let short = "save for later https://news.ycombinator.com/item?id=4242424"
        let wordy = "must read this later when I get a quiet hour https://news.ycombinator.com/item?id=4242424"
        let other = "https://news.ycombinator.com/item?id=4242424 5 min"

        // Word overlap catches the short one only because the prose is short —
        // 0.700, exactly on the threshold. Add a sentence and it misses.
        #expect(abs(TitleMatcher.overlap(short, other) - 0.7) < 0.001, "on the threshold, by luck")
        #expect(TitleMatcher.overlap(wordy, other) < TitleMatcher.duplicateThreshold)

        // The shared address settles both, and settles them confidently.
        #expect(TitleMatcher.duplicateScore(short, other) == 1)
        #expect(TitleMatcher.duplicateScore(wordy, other) == 1)
    }

    @Test("Trailing punctuation does not make a link a different link")
    func punctuationTolerated() {
        #expect(
            TitleMatcher.duplicateScore(
                "read this https://example.com/post.", "https://example.com/post 10 min")
                >= TitleMatcher.duplicateThreshold)
    }

    /// A link against bare prose cannot be judged either way, so it is not
    /// claimed. Recorded as a deliberate miss rather than a gap.
    @Test("A link and prose about it are not claimed as duplicates")
    func linkVersusProse() {
        #expect(
            TitleMatcher.duplicateScore(
                "read the swift concurrency post",
                "https://blog.swift.org/swift-6-concurrency") == 0)
    }

    // MARK: - Picking one

    @Test("The best duplicate is returned, and only one")
    func bestOnly() {
        var gen = Fixtures.generator()
        let a = gen.next()
        let b = gen.next()
        let candidates = [
            (id: a, title: "electricity bill pay karna h"),
            (id: b, title: "pay the electricity bill today"),
        ]
        let found = TitleMatcher.bestDuplicate(of: "Pay the electricity bill", in: candidates)
        #expect(found != nil)
        #expect(found?.id == a, "the closer of the two")
    }

    @Test("Nothing similar enough yields no suggestion at all")
    func noneIsLegal() {
        var gen = Fixtures.generator()
        let candidates = [(id: gen.next(), title: "call the electrician")]
        #expect(TitleMatcher.bestDuplicate(of: "call the plumber", in: candidates) == nil)
    }

    /// Two ULIDs minted in the same millisecond order by their random bytes,
    /// not by the order they were generated in — so the lower id has to be
    /// worked out, not assumed.
    @Test("Ties resolve to the lowest id, so the result never jitters")
    func deterministicTies() {
        var gen = Fixtures.generator()
        let ids = [gen.next(), gen.next()].sorted()
        let title = "pay the electricity bill"
        let forwards = [(id: ids[0], title: title), (id: ids[1], title: title)]
        let backwards = [(id: ids[1], title: title), (id: ids[0], title: title)]

        #expect(
            TitleMatcher.bestDuplicate(of: "electricity bill pay karna h", in: forwards)?.id
                == ids[0])
        #expect(
            TitleMatcher.bestDuplicate(of: "electricity bill pay karna h", in: backwards)?.id
                == ids[0], "input order must not decide the answer")
    }

    @Test("An empty or stopword-only title matches nothing")
    func emptyMatchesNothing() {
        #expect(TitleMatcher.overlap("", "pay the electricity bill") == 0)
        #expect(TitleMatcher.overlap("the a an to of", "pay the electricity bill") == 0)
    }
}
