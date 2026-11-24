import Foundation
import Testing

@testable import BrainCore

/// What a dependency phrase actually names.
///
/// **Every case here came from real captures or from the backfill audit, not
/// from imagination.** The English rules capture from the marker to the end
/// of the text, which is correct only when the dependency phrase happens to
/// come last — and when it does not, the referent swallows the task's own
/// deadline and effort. A polluted referent then matches whatever shares
/// those words: "stretch after lunch today 20 minutes" matched "pricing page
/// ko write karna hai today raat 10 baje 20 minutes" at 0.637, on the shared
/// words *today* and *20 minutes*.
@Suite("Referent extraction")
struct ReferentTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_404_600)
    let parser = DependencyParser(timeZone: zone)

    func referent(_ text: String) -> String? {
        parser.parse(text, now: Self.now).first?.targetText
    }

    // MARK: - Times of day are not things to wait for

    /// "after lunch" is a time, not a blocker. Before this, the parser invented
    /// an item named *lunch* and anything else mentioning lunch satisfied it —
    /// two of three backfill resolutions on the train split were this.
    @Test(
        "A time of day is never a dependency",
        arguments: [
            "stretch after lunch", "stretch before bed", "walk after dinner",
            "read before bedtime", "stretch after lunch today 20 minutes",
            "book time for after lunch tomorrow", "after lunch ko walk karna hai",
        ])
    func daypartsAreNotDependencies(text: String) {
        #expect(referent(text) == nil, "\"\(text)\" invented a blocker")
    }

    /// The boundary. These genuinely can be things on the list, so the phrase
    /// is a real dependency and the short daypart list must not reach them.
    @Test(
        "Something that can be on the list is still a dependency",
        arguments: [
            ("walk after the gym", "gym"),
            ("deploy after the schema review", "schema review"),
            ("reply after the standup", "standup"),
        ])
    func realReferentsSurvive(text: String, expected: String) {
        #expect(referent(text) == expected)
    }

    // MARK: - The task's own deadline and effort are not the referent's name

    @Test(
        "A trailing date or effort is trimmed off the referent",
        arguments: [
            ("deploy after schema review tomorrow 2 hours", "schema review"),
            ("deploy after schema review in 3 days", "schema review"),
            ("send it after the client call 45 mins", "client call"),
        ])
    func trailingNoiseTrimmed(text: String, expected: String) {
        #expect(referent(text) == expected)
    }

    /// Cutting a date off the end used to leave the preposition behind —
    /// "client meeting on monday" became "client meeting on", which adds a
    /// token to every overlap comparison and is not part of any name.
    @Test(
        "No dangling connective is left behind",
        arguments: [
            ("Send the deck after the client meeting on monday", "client meeting"),
            ("deploy after the review on friday", "review"),
            ("ship after the standup at 10am", "standup"),
        ])
    func noDanglingConnective(text: String, expected: String) {
        #expect(referent(text) == expected)
    }

    /// Hinglish half of the same defect: an English marker with a Hinglish
    /// tail captures the whole predicate. `ko` ends the object, so what
    /// follows is the speaker's verb and never the referent's name.
    @Test(
        "A Hinglish predicate is not part of the referent",
        arguments: [
            ("invoice bhejna hai after client ko call karna hai", "client"),
            ("ping me after Priya ko reply karna hai", "priya"),
        ])
    func hinglishPredicateCut(text: String, expected: String) {
        #expect(referent(text) == expected)
    }

    /// The trim is safe precisely because it is recoverable: a shorter
    /// referent still finds the longer item, while a polluted one finds the
    /// wrong item and nothing downstream can undo that.
    @Test("A trimmed referent still matches the full title")
    func trimIsRecoverable() {
        var generator = ULIDGenerator(seed: 11)
        let real = generator.next()
        let match = TitleMatcher.bestMatch(
            "client meeting", in: [(id: real, title: "client meeting on monday 3pm")])
        #expect(match?.id == real)
    }

    // MARK: - Nothing that used to work stopped working

    @Test(
        "The cases the parser was built for are untouched",
        arguments: [
            ("deploy the migration after the pooler thing", "pooler thing"),
            ("review the PR before standup", "standup"),
            ("client ke baad invoice bhejna hai", "client"),
            ("waiting for the design review", "design review"),
        ])
    func regressions(text: String, expected: String) {
        #expect(referent(text) == expected)
    }

    /// Still true, and the reason the date cross-check exists at all.
    @Test(
        "A deadline is still not a dependency",
        arguments: ["Ship it after 3 days", "Send after kal", "Deliver after next monday"])
    func deadlinesStillRejected(text: String) {
        #expect(referent(text) == nil)
    }
}
