import Foundation
import Testing

@testable import BrainCore

/// The same intent, written three ways.
///
/// Every T0 rule in Brain was tuned on **one person's** captures, and the
/// headline numbers (type recognition 46.7% → 98.0%) are single-author. That
/// is a real generalisation risk and nothing in the eval could see it: the
/// synthetic corpus is generated from our own rule vocabulary, so it cannot
/// contain a construction we never thought of. Twelve hand-written sentences
/// found three gaps that 69 generated ones did not.
///
/// Pure Devanagari is deliberately **out of scope** — Brain is English and
/// romanised Hinglish only, decided 2026-11-24.
@Suite("Writing styles")
struct WritingStyleTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    /// Monday 23 Nov 2026, 09:00 IST — the clock the datasets use.
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    static func dependencies(_ text: String) -> [ParsedDependency] {
        DependencyParser(timeZone: zone).parse(text, now: now)
    }

    // MARK: - Dependencies, both directions

    /// Regression: there was no `before` rule in **any** language. Measured at
    /// 0 of 5 across English and both Hinglish styles.
    @Test(
        "\"before\" is read in every supported style",
        arguments: [
            "Review the pull request before standup",
            "standup se pehle PR review krna h",
            "standup se pehle PR review karna hai",
            "Finish the deck before the client call",
            "client call se pehle deck finish krna h",
        ])
    func beforeIsParsed(text: String) {
        let found = Self.dependencies(text)
        #expect(!found.isEmpty, "no dependency read from \"\(text)\"")
        #expect(
            found.first?.direction == .blocksReferent,
            "\"before\" must mean this item blocks the referent, not the reverse")
    }

    @Test(
        "\"after\" is read in every supported style",
        arguments: [
            "Send the invoice after the client approves",
            "client approve kare uske baad invoice bhejna h",
            "client ke approve karne ke baad invoice bhejna hai",
            "Deploy once CI is green",
            "CI green hone ke baad deploy krna h",
        ])
    func afterIsParsed(text: String) {
        let found = Self.dependencies(text)
        #expect(!found.isEmpty, "no dependency read from \"\(text)\"")
        #expect(found.first?.direction == .blockedByReferent)
    }

    /// `\bke\b` cannot match the "ke" inside "uske", so the commonest informal
    /// form parsed as nothing while the formal one worked.
    @Test("uske baad and iske baad are read, not just the formal ke baad")
    func informalKeBaad() {
        for text in [
            "client approve kare uske baad invoice bhejna h",
            "deploy iske baad karna h",
        ] {
            #expect(!Self.dependencies(text).isEmpty, "\(text)")
        }
    }

    /// A duration is a deadline, not something to wait on. The cross-check
    /// used to run only for English word order, so Hinglish produced a
    /// phantom blocker called "3 din".
    @Test(
        "A duration never becomes a phantom dependency",
        arguments: [
            "deploy after 3 days", "3 din ke baad deploy krna h",
            "2 hafte ke baad review krna h", "ek mahine ke baad follow up krna h",
        ])
    func durationsAreNotDependencies(text: String) {
        #expect(
            Self.dependencies(text).isEmpty,
            "\"\(text)\" invented a blocker: \(Self.dependencies(text).map(\.targetText))")
    }

    @Test("A real referent is still read when a date sits beside it")
    func datesDoNotSuppressRealDependencies() {
        // The 60% coverage rule exists for exactly this.
        #expect(!Self.dependencies("after the monday client meeting").isEmpty)
    }

    // MARK: - Hindi numerals

    /// `15 tarikh` parsed; `pandrah tarikh` did not. Same for clock times.
    @Test(
        "Spelled-out Hindi numerals match their digit form",
        arguments: [
            ("bill pandrah tarikh ko bharna hai", "bill 15 tarikh ko bharna hai"),
            ("meeting bees tarikh ko hai", "meeting 20 tarikh ko hai"),
            ("teen baje call karna hai", "3 baje call karna hai"),
            ("subah nau baje gym jana hai", "subah 9 baje gym jana hai"),
        ])
    func numeralWordsMatchDigits(spelled: String, digits: String) {
        let parser = DateParser(timeZone: Self.zone)
        let fromWords = parser.parse(spelled, now: Self.now)
        let fromDigits = parser.parse(digits, now: Self.now)
        #expect(fromWords != nil, "\"\(spelled)\" read no date")
        #expect(
            fromWords?.date == fromDigits?.date,
            "\"\(spelled)\" and \"\(digits)\" disagree")
    }

    @Test("Numeral words do not shift spans off the original text")
    func spansStayGrounded() {
        let text = "bill pandrah tarikh ko bharna hai"
        guard let parsed = DateParser(timeZone: Self.zone).parse(text, now: Self.now) else {
            Issue.record("no date parsed")
            return
        }
        let utf16 = Array(text.utf16)
        #expect(parsed.span.start >= 0 && parsed.span.end <= utf16.count)
        let covered = String(
            decoding: utf16[parsed.span.start..<parsed.span.end], as: UTF16.self)
        #expect(covered.contains("pandrah"), "span points at \"\(covered)\"")
    }

    // MARK: - Type, across styles

    @Test(
        "The same intent types the same way in all three styles",
        arguments: [
            ["Call the bank tomorrow", "kal bank ko call krna h", "kal bank ko call karna hai"],
            [
                "What if we moved the standup", "kya agar standup move kar de",
                "kya agar hum standup move kar dein",
            ],
        ])
    func typeAgreesAcrossStyles(variants: [String]) {
        let classifier = TypeClassifier(timeZone: Self.zone)
        let types = variants.map { classifier.classify($0, now: Self.now).value }
        #expect(
            Set(types).count == 1,
            "styles disagree: \(zip(variants, types).map { "\($0.0) → \($0.1)" })")
    }
}
