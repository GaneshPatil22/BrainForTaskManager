import Foundation
import Testing

@testable import BrainCore

/// Effort is T0 when stated: *"If the user said how long, read it. Don't infer
/// it"* (`docs/09-tiering.md`). Inferring from a bare title is a later phase.
@Suite("EffortParser — English and Hinglish")
struct EffortParserTests {
    let parser = EffortParser()

    func expect(
        _ text: String, _ bucket: EffortBucket, minutes: Double? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let parsed = parser.parse(text) else {
            Issue.record("no effort parsed from \"\(text)\"", sourceLocation: sourceLocation)
            return
        }
        #expect(
            parsed.bucket == bucket, "\"\(text)\" → \(parsed.bucket)",
            sourceLocation: sourceLocation)
        if let minutes {
            #expect(
                parsed.minutes == minutes, "\"\(text)\" → \(parsed.minutes) min",
                sourceLocation: sourceLocation)
        }
    }

    @Test("English durations")
    func english() {
        expect("Call the plumber, 5 min", .tiny, minutes: 5)
        expect("Write the summary 20 minutes", .small, minutes: 20)
        expect("Review the PR, 45 mins", .medium, minutes: 45)
        expect("Refactor auth 3 hours", .large, minutes: 180)
        expect("Migration 2 days", .xlarge, minutes: 960)
        expect("Rewrite the app 2 weeks", .xlarge)
    }

    @Test("Hinglish durations")
    func hinglish() {
        expect("Sink ka kaam 2 ghante", .large, minutes: 120)
        expect("Yeh 1 ghanta lagega", .medium, minutes: 60)
        expect("Safai 3 din ka kaam", .xlarge)
        expect("Aadha ghanta lagega", .small, minutes: 30)
        expect("Poora din chahiye", .xlarge, minutes: 480)
    }

    @Test("Fixed phrases")
    func phrases() {
        expect("Takes half an hour", .small, minutes: 30)
        expect("This is a whole day job", .xlarge, minutes: 480)
        // 120 min is exactly the medium/large boundary (√(60×240)). Boundary
        // values round *up*, which is the conservative choice: over-estimating
        // effort lowers leverage, so a borderline task is never over-promoted.
        expect("Couple of hours of work", .large, minutes: 120)
    }

    @Test("Qualitative hints score low, so the cascade can escalate")
    func qualitative() throws {
        expect("Jaldi se kar lena", .tiny)
        expect("Quick fix for the header", .tiny)
        let vague = try #require(parser.parse("jaldi se kar lena"))
        let explicit = try #require(parser.parse("5 min ka kaam"))
        #expect(vague.confidence < explicit.confidence)
    }

    /// The bug this guard exists for: "due in 2 days" is a deadline. Without
    /// the date-lead-in check, every relative due date would also register as
    /// xlarge effort.
    @Test("A deadline is not a duration")
    func deadlinesAreNotDurations() {
        for text in [
            "Submit the form in 2 days", "Ship it after 3 days",
            "Due in 5 days", "Finish within 2 weeks", "Next 3 days",
        ] {
            #expect(parser.parse(text) == nil, "\"\(text)\" must not parse as effort")
        }
    }

    @Test("Text with no duration abstains")
    func abstains() {
        for text in ["Call the plumber", "", "🎉", "Buy 3 apples", "15 tarikh ko milna"] {
            #expect(parser.parse(text) == nil, "\"\(text)\"")
        }
    }

    /// Boundaries are geometric midpoints, matching the log-scale effort
    /// denominator in `Scoring.effortDenominator`.
    @Test("Bucket boundaries sit at the geometric midpoints")
    func boundaries() {
        #expect(EffortParser.bucket(forMinutes: 9) == .tiny)
        #expect(EffortParser.bucket(forMinutes: 10) == .small)
        #expect(EffortParser.bucket(forMinutes: 34) == .small)
        #expect(EffortParser.bucket(forMinutes: 35) == .medium)
        #expect(EffortParser.bucket(forMinutes: 119) == .medium)
        #expect(EffortParser.bucket(forMinutes: 120) == .large)
        #expect(EffortParser.bucket(forMinutes: 479) == .large)
        #expect(EffortParser.bucket(forMinutes: 480) == .xlarge)
    }

    @Test("Every parse cites a span that resolves")
    func spansResolve() throws {
        for text in ["Sink ka kaam 2 ghante", "Review the PR, 45 mins", "Takes half an hour"] {
            let parsed = try #require(parser.parse(text), "\(text)")
            let resolved = try #require(parsed.span.resolve(in: text.lowercased()), "\(text)")
            #expect(!resolved.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test("Parsing is deterministic")
    func deterministic() {
        for text in ["2 ghante", "45 mins", "half an hour"] {
            let first = parser.parse(text)
            for _ in 0..<5 { #expect(parser.parse(text)?.minutes == first?.minutes, "\(text)") }
        }
    }
}
