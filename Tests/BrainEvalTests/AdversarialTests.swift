import BrainCore
import BrainDatasets
import Foundation
import Testing

@testable import BrainEval

/// The adversarial set is the reason two real bugs were found rather than
/// shipped: 53-second regex backtracking on a 60k capture, and date resolution
/// decided by declaration order instead of text position.
@Suite("Adversarial set")
struct AdversarialTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_000_000)

    func load() throws -> [AdversarialCase] {
        try AdversarialLoader.load(
            directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("datasets/adversarial"))
    }

    @Test("The committed set loads and covers the documented attack types")
    func loads() throws {
        let cases = try load()
        #expect(cases.count >= 30)
        let attacks = Set(cases.map(\.attack))
        // Every type named in docs/03-dataset-schema.md must be present.
        for required in [
            "empty", "whitespace_only", "emoji_only", "huge", "url_only",
            "mixed_script", "prompt_injection", "contradictory",
            "nested_quotes", "control_chars",
        ] {
            #expect(attacks.contains(required), "missing attack type: \(required)")
        }
    }

    /// The headline assertion: every scorable row behaves as its expectation says.
    @Test("Every scorable row passes")
    func allPass() throws {
        let result = Metrics.adversarial(
            cases: try load(), timeZone: Self.zone, now: Self.now)
        #expect(result.scored > 0)
        #expect(result.failures.isEmpty, "\(result.failures.prefix(5).joined(separator: " | "))")
        #expect(result.passed == result.scored)
    }

    /// Regression guard for the 53-second backtracking bug. Without a latency
    /// bound this would have reached production as an unbounded hang.
    @Test("No row exceeds its latency budget")
    func withinBudget() throws {
        let result = Metrics.adversarial(
            cases: try load(), timeZone: Self.zone, now: Self.now)
        #expect(result.tooSlow.isEmpty, "\(result.tooSlow.joined(separator: ", "))")
        #expect(result.slowestMs < 250, "slowest \(result.slowestMs)ms")
    }

    /// Injection rows exist but cannot be scored yet, and the metric must say
    /// so rather than quietly counting them as passes.
    @Test("Injection rows are deferred, not silently counted as passing")
    func injectionDeferred() throws {
        let cases = try load()
        let injection = cases.filter { $0.attack == "prompt_injection" }
        #expect(!injection.isEmpty)
        #expect(injection.allSatisfy { $0.evaluatedAt == "B3" })

        let result = Metrics.adversarial(cases: cases, timeZone: Self.zone, now: Self.now)
        #expect(result.deferred == injection.count)
        #expect(result.scored == cases.count - injection.count)
    }

    @Test("Scoring the adversarial set is deterministic")
    func deterministic() throws {
        let cases = try load()
        let first = Metrics.adversarial(cases: cases, timeZone: Self.zone, now: Self.now)
        for _ in 0..<3 {
            let again = Metrics.adversarial(cases: cases, timeZone: Self.zone, now: Self.now)
            #expect(again.passed == first.passed)
            #expect(again.failures == first.failures)
        }
    }

    /// A row that abstains where it should not must be caught, not excused.
    @Test("The metric fails a row that misbehaves")
    func metricDetectsFailure() {
        let bogus = AdversarialCase(
            id: "x", attack: "synthetic", rawText: "call the plumber kal",
            source: "text",
            expect: .init(
                date: nil,  // claims it must abstain, but "kal" is right there
                effort: nil, category: "communication", dependency: nil,
                maxLatencyMs: 50),
            evaluatedAt: "B2", note: "deliberately wrong expectation")
        let result = Metrics.adversarial(cases: [bogus], timeZone: Self.zone, now: Self.now)
        #expect(result.passed == 0)
        #expect(result.failures.count == 1)
    }
}
