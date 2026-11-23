import Foundation
import Testing

@testable import BrainCore

/// The category lexicon is T0 (`docs/09-tiering.md`). These tests pin the
/// behaviour that matters; the aggregate accuracy number lives in
/// `brain category-eval`, measured against 1,308 labelled titles.
@Suite("Category — T0 lexicon")
struct CategoryTests {

    @Test("Unambiguous leading verbs land in the right category")
    func leadingVerbs() {
        let cases: [(String, TaskCategory)] = [
            ("Call the plumber", .communication),
            ("Pay the electricity bill", .money),
            ("Buy groceries", .errands),
            ("Clean the kitchen", .chores),
            ("Write the blog post", .deepWork),
            ("Revise chapter 4", .learning),
            ("Renew the passport", .paperwork),
        ]
        for (title, expected) in cases {
            #expect(CategoryClassifier.classify(title).value == expected, "\(title)")
        }
    }

    /// The object helps where the verb is ambiguous, but does not override it.
    @Test("The object breaks ties the verb cannot")
    func objectBreaksTies() {
        #expect(CategoryClassifier.classify("Book flights to Delhi").value == .planning)
        // A strong object outweighs a *weak* verb.
        #expect(CategoryClassifier.classify("Check the pantry").value == .chores)
        #expect(CategoryClassifier.classify("Collect the certificate").value == .paperwork)
    }

    /// Known limitation, pinned so we notice if it changes.
    ///
    /// "Book a dentist appointment" classifies as `planning`, not `health`: the
    /// leading verb outweighs the object. That looks like a bug and is in fact
    /// the measured global optimum — inverting the weights so objects win drops
    /// overall accuracy on 1,308 labelled titles from 67.0% to 64.8%. Recorded
    /// rather than hand-patched, so nobody "fixes" it and makes things worse.
    @Test("Known limitation: a strong leading verb outweighs a strong object")
    func knownLimitation() {
        #expect(CategoryClassifier.classify("Book a dentist appointment").value == .planning)
    }

    @Test("Hinglish terms are recognised")
    func hinglish() {
        #expect(CategoryClassifier.classify("Sabzi lana hai").value == .errands)
        #expect(CategoryClassifier.classify("Almirah saaf karna").value == .chores)
        #expect(CategoryClassifier.classify("Bijli ka bill pay karna").value == .money)
    }

    /// Abstention is a first-class outcome: an abstained field escalates, a
    /// wrong one is silently wrong (`docs/04-scorecard.md`).
    @Test("Titles with no signal abstain rather than guess")
    func abstains() {
        // Note "follow up on it" is deliberately absent: it genuinely is
        // communication, and classifying it so is correct, not a false positive.
        // "sort it out properly" is deliberately absent: `sort` leads, and
        // reading it as a chore is defensible, not a false positive.
        for title in ["", "   ", "that thing", "🎉", "the usual", "maybe later"] {
            #expect(CategoryClassifier.classify(title).value == nil, "\(title)")
        }
    }

    @Test("Classification is deterministic")
    func deterministic() {
        for title in ["Call the plumber", "Book flights", "that thing"] {
            let first = CategoryClassifier.classify(title)
            for _ in 0..<5 {
                #expect(CategoryClassifier.classify(title) == first, "\(title)")
            }
        }
    }

    @Test("Raising the margin never increases the number of answers")
    func marginMonotonic() {
        let titles = [
            "Call the plumber", "Book flights", "Check the pantry",
            "Update the records", "Collect the certificate",
        ]
        var previous = Int.max
        for margin in stride(from: 0.0, through: 0.9, by: 0.1) {
            let answered = titles.filter {
                CategoryClassifier.classify($0, minMargin: margin).value != nil
            }.count
            #expect(answered <= previous)
            previous = answered
        }
    }

    @Test("An item derives its category from its title when none is given")
    func itemDerivesCategory() {
        var gen = Fixtures.generator()
        let item = Fixtures.item(&gen, "Pay the electricity bill")
        #expect(item.category.value == .money)
        #expect(item.category.tier == .t0)
    }
}
