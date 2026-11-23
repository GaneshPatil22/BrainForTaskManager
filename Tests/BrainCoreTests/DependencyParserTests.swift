import Foundation
import Testing

@testable import BrainCore

/// Explicit dependencies are T0: *"after X", "once X is done", "X ke baad"* →
/// a deterministic edge (`docs/09-tiering.md`). Only *implicit* semantic
/// dependencies need a model.
@Suite("DependencyParser — English and Hinglish")
struct DependencyParserTests {
    let parser = DependencyParser()
    let now = Fixtures.now

    func expect(
        _ text: String, _ target: String, rule: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = parser.parse(text, now: now)
        guard let first = found.first else {
            Issue.record("no dependency parsed from \"\(text)\"", sourceLocation: sourceLocation)
            return
        }
        #expect(
            first.targetText == target, "\"\(text)\" → \"\(first.targetText)\"",
            sourceLocation: sourceLocation)
        if let rule {
            #expect(
                first.rule == rule, "\"\(text)\" fired \(first.rule)",
                sourceLocation: sourceLocation)
        }
    }

    @Test("English blocking phrases")
    func english() {
        expect("Send the invoice after client approval", "client approval", rule: "after")
        expect("Deploy once the tests are green", "tests", rule: "onceDone")
        expect("Ship it once migration is done", "migration", rule: "onceDone")
        expect("Blocked by the design review", "design review", rule: "blockedBy")
        expect("Waiting for the brand assets", "brand assets", rule: "waitingFor")
        expect("Needs client sign-off first", "client sign-off", rule: "needsFirst")
    }

    /// Hinglish puts the referent *before* the marker, English after it. One
    /// parser handles both word orders.
    @Test("Hinglish blocking phrases put the referent first")
    func hinglish() {
        expect("Client reply ke baad invoice bhejna", "client reply", rule: "keBaadHinglish")
        expect("Migration hone ke baad deploy karna", "migration", rule: "honeKeBaadHinglish")
        expect("Design ka wait hai", "design", rule: "kaWaitHinglish")
    }

    /// The guard that matters most. Without the date cross-check, every
    /// relative due date would become a phantom blocker.
    @Test("A deadline is not a dependency")
    func deadlinesAreNotDependencies() {
        for text in [
            "Ship it after 3 days", "Send after kal", "Deliver after next monday",
            "Review after 15 tarikh",
        ] {
            #expect(parser.parse(text, now: now).isEmpty, "\"\(text)\" must not parse")
        }
    }

    /// The coverage rule earns its keep here: this referent *contains* a date
    /// but is a real dependency. Rejecting anything date-shaped would lose it.
    @Test("A referent that merely mentions a date is still a dependency")
    func dateInsideReferent() {
        expect(
            "Send the deck after the client meeting on monday",
            "client meeting on monday")
    }

    @Test("Text with no dependency abstains")
    func abstains() {
        for text in ["Call the plumber", "", "🎉", "Buy groceries and milk"] {
            #expect(parser.parse(text, now: now).isEmpty, "\"\(text)\"")
        }
    }

    @Test("Articles and punctuation are trimmed from the referent")
    func cleaning() {
        expect("Deploy after the migration.", "migration")
        expect("Send it once my review is complete", "review")
    }

    @Test("Parsing is deterministic")
    func deterministic() {
        for text in ["client reply ke baad", "after the migration", "waiting for assets"] {
            let first = parser.parse(text, now: now)
            for _ in 0..<5 {
                #expect(parser.parse(text, now: now) == first, "\(text)")
            }
        }
    }

    @Test("Every parse cites a span that resolves")
    func spansResolve() throws {
        for text in ["Send the invoice after client approval", "Client reply ke baad bhejna"] {
            let parsed = try #require(parser.parse(text, now: now).first, "\(text)")
            let resolved = try #require(parsed.span.resolve(in: text.lowercased()), "\(text)")
            #expect(!resolved.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Resolving a referent to a real item is deliberately conservative: below the
/// threshold it returns nothing, so an unmatched reference produces **no edge**
/// rather than a wrong one (`docs/04-scorecard.md`: precision over recall).
@Suite("TitleMatcher")
struct TitleMatcherTests {
    func id(_ n: Int) -> ULID {
        ULID(
            timestampMilliseconds: UInt64(n),
            randomness: Array(repeating: UInt8(n % 256), count: 10))
    }

    @Test("An exact title matches")
    func exact() {
        let candidates = [(id: id(1), title: "Get client approval")]
        #expect(TitleMatcher.bestMatch("client approval", in: candidates)?.id == id(1))
    }

    @Test("A short reference matches a longer title")
    func containment() {
        let candidates = [(id: id(1), title: "Email the client about pricing tiers")]
        #expect(TitleMatcher.bestMatch("client", in: candidates) != nil)
    }

    @Test("An unrelated reference matches nothing")
    func noMatch() {
        let candidates = [
            (id: id(1), title: "Buy groceries"), (id: id(2), title: "Water the plants"),
        ]
        #expect(TitleMatcher.bestMatch("client approval", in: candidates) == nil)
    }

    @Test("The best of several candidates wins")
    func best() {
        let candidates = [
            (id: id(1), title: "Client call"),
            (id: id(2), title: "Get client approval on the design"),
        ]
        #expect(TitleMatcher.bestMatch("client approval", in: candidates)?.id == id(2))
    }

    @Test("Ties resolve deterministically to the lowest id")
    func ties() {
        let candidates = [(id: id(2), title: "Review design"), (id: id(1), title: "Review design")]
        #expect(TitleMatcher.bestMatch("review design", in: candidates)?.id == id(1))
    }

    @Test("Hinglish particles are not treated as content")
    func stopWords() {
        // "ka"/"ke" must not create spurious overlap between unrelated titles.
        #expect(TitleMatcher.score("ghar ka kaam", "office ka kaam") < 0.85)
    }

    /// Regression test. A title containing the referent scores identically to
    /// the real target, so the item's own title could win the tie and then be
    /// discarded — losing the genuine match with it. Callers must exclude self
    /// *before* matching, not after.
    @Test("A self-matching title does not shadow the real target")
    func selfMatchDoesNotShadow() {
        let selfId = id(1)
        let all = [
            (id: selfId, title: "deploy once the tests are green"),
            (id: id(2), title: "run the tests"),
        ]
        // Both score the same, so filtering after the fact loses the answer.
        #expect(
            TitleMatcher.score("tests", all[0].title)
                == TitleMatcher.score("tests", all[1].title))
        let others = all.filter { $0.id != selfId }
        #expect(TitleMatcher.bestMatch("tests", in: others)?.id == id(2))
    }

    @Test("Scoring is symmetric-ish and bounded")
    func bounded() {
        for (a, b) in [("client", "client"), ("a b c", "d e f"), ("", "anything")] {
            let value = TitleMatcher.score(a, b)
            #expect(value >= 0 && value <= 1, "\(a) vs \(b) → \(value)")
        }
    }
}
