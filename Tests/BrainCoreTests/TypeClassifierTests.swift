import Foundation
import Testing

@testable import BrainCore

/// The T0 type rules are the B2.5 baseline. Whatever B3's model scores, it has
/// to beat these by enough to justify the quota (`docs/09-tiering.md`).
@Suite("TypeClassifier — T0 rules")
struct TypeClassifierTests {
    let classifier = TypeClassifier(timeZone: Fixtures.zone)
    var now: Date { Fixtures.now }

    func expect(
        _ text: String, _ type: ItemType?, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let got = classifier.classify(text, now: now).value
        #expect(
            got == type, "\"\(text)\" → \(got.map(\.rawValue) ?? "abstained")",
            sourceLocation: sourceLocation)
    }

    @Test("A URL with little else is a link")
    func links() {
        expect("https://arxiv.org/abs/2604.11111", .link)
        expect("read this https://example.com/a", .link)
        expect("dekhna hai https://example.com/a", .link)
    }

    @Test("Idea markers are explicit")
    func ideas() {
        expect("idea: batch the reminders", .idea)
        expect("what if pricing were usage based", .idea)
        expect("kya agar app khud sort kar le", .idea)
    }

    @Test("A leading imperative is a task")
    func tasks() {
        expect("call the plumber", .task)
        expect("pay the electricity bill", .task)
        expect("clean the kitchen tomorrow", .task)
    }

    /// Hinglish marks the imperative at the *end*. A parser that only knows
    /// English word order files half our captures as notes.
    @Test("Hinglish verb-final imperatives are tasks")
    func hinglishTasks() {
        expect("sabzi lana hai", .task)
        expect("plumber ko call karna hai", .task)
        expect("bijli ka bill bharna hai", .task)
    }

    /// The distinction that matters, and the one my generator originally made
    /// unlearnable: a reminder is **time-anchored**, a task merely has a
    /// deadline. Without a clock time nothing in the text separates them.
    @Test("A clock time makes it a reminder, a bare date does not")
    func remindersAreTimeAnchored() {
        expect("call Priya tomorrow", .task)
        expect("call Priya kal subah 9 baje", .reminder)
        expect("clean the kitchen kal", .task)
        expect("clean the kitchen kal shaam 5 baje", .reminder)
    }

    @Test("A short verbless fragment is a note")
    func notes() {
        expect("pricing for the template pack", .note)
        expect("ghar ka hisaab", .note)
    }

    @Test("Empty input abstains")
    func abstains() {
        expect("", nil)
        expect("   ", nil)
    }

    @Test("A verb later in the line still counts")
    func verbNotFirst() {
        // Fillers and dates routinely come first in a real capture.
        expect("btw call the plumber", .task)
        expect("kal buy milk", .task)
    }

    @Test("Classification is deterministic")
    func deterministic() {
        for text in ["call the plumber", "idea: something", "sabzi lana hai"] {
            let first = classifier.classify(text, now: now)
            for _ in 0..<5 { #expect(classifier.classify(text, now: now) == first, "\(text)") }
        }
    }

    @Test("Every classification cites a span that resolves")
    func spansResolve() throws {
        for text in [
            "call the plumber", "idea: batch it", "sabzi lana hai",
            "https://example.com/a",
        ] {
            let result = classifier.classify(text, now: now)
            let span = try #require(result.evidence, "\(text)")
            #expect(span.resolve(in: text.lowercased()) != nil, "\(text)")
        }
    }
}
