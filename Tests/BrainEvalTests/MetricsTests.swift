import BrainCore
import Foundation
import Testing

@testable import BrainEval

/// The eval harness reports every number this project will ever claim, so it
/// gets tested like shipping code. A scorecard that is quietly wrong is worse
/// than no scorecard.
@Suite("Metrics — NDCG")
struct NDCGTests {
    func id(_ n: Int) -> ULID {
        ULID(
            timestampMilliseconds: UInt64(n),
            randomness: Array(repeating: UInt8(n % 256), count: 10))
    }

    @Test("A perfect ordering scores 1.0")
    func perfect() {
        let order = (1...5).map(id)
        #expect(
            abs(Metrics.ndcg(ours: order, humanOrder: Array(order.prefix(3)), k: 5) - 1.0) < 1e-9)
    }

    @Test("An ordering with none of the human's picks scores 0")
    func miss() {
        let ours = (10...14).map(id)
        let human = (1...3).map(id)
        #expect(Metrics.ndcg(ours: ours, humanOrder: human, k: 5) == 0)
    }

    @Test("Reversing the human's order scores below perfect but above zero")
    func reversed() {
        let human = (1...3).map(id)
        let ours = human.reversed() + [id(4), id(5)]
        let score = Metrics.ndcg(ours: Array(ours), humanOrder: human, k: 5)
        #expect(score > 0 && score < 1)
    }

    @Test("Promoting the human's top pick never lowers the score")
    func monotonic() {
        let human = (1...3).map(id)
        let pool = (1...6).map(id)
        var previous = 0.0
        // Move the human's #1 from last position to first.
        for position in stride(from: 5, through: 0, by: -1) {
            var ours = pool.filter { $0 != human[0] }
            ours.insert(human[0], at: position)
            let score = Metrics.ndcg(ours: ours, humanOrder: human, k: 5)
            #expect(score >= previous - 1e-9, "position \(position)")
            previous = score
        }
    }

    @Test("An empty human list scores 0 rather than dividing by zero")
    func emptyHuman() {
        #expect(Metrics.ndcg(ours: (1...3).map(id), humanOrder: [], k: 5) == 0)
    }
}

@Suite("Scorecard — gate")
struct GateTests {
    func card(
        _ value: Double?, tolerance: Double? = 0.02, mustNotExceed: Double? = nil,
        higherIsBetter: Bool = true
    ) -> Scorecard {
        Scorecard(
            runId: "r", generatedAt: "t", dataset: "v1", split: "dev", sets: [:],
            sections: [
                Section(
                    name: "ranking",
                    metrics: [
                        Metric(
                            name: "m", value: value, unit: .percent, tolerance: tolerance,
                            mustNotExceed: mustNotExceed, higherIsBetter: higherIsBetter)
                    ])
            ])
    }

    @Test("A drop beyond tolerance fails")
    func regressionFails() {
        let result = card(0.80).gate(against: card(0.90))
        #expect(!result.isPass)
    }

    @Test("A drop within tolerance passes")
    func withinTolerance() {
        #expect(card(0.89).gate(against: card(0.90)).isPass)
    }

    /// Improvements must never fail the gate, and must never silently become
    /// the new baseline (`docs/04-scorecard.md`).
    @Test("An improvement passes and is reported, not absorbed")
    func improvementPasses() {
        let result = card(0.99).gate(against: card(0.90))
        #expect(result.isPass)
        #expect(!result.improvements.isEmpty)
    }

    /// Invariants are not tolerances. Any breach fails, whatever the baseline.
    @Test("A hard limit fails unconditionally")
    func hardLimit() {
        let breached = card(1.0, tolerance: 0.5, mustNotExceed: 0)
        #expect(!breached.gate(against: card(0.0, tolerance: 0.5, mustNotExceed: 0)).isPass)
    }

    @Test("A not-measured metric neither passes nor fails")
    func unmeasuredIgnored() {
        let result = card(nil).gate(against: card(0.90))
        #expect(result.isPass)
        #expect(result.improvements.isEmpty)
    }

    @Test("Lower-is-better metrics invert correctly")
    func lowerIsBetter() {
        // Latency rising beyond tolerance is a regression.
        let worse = card(5.0, tolerance: 1.0, higherIsBetter: false)
        #expect(!worse.gate(against: card(1.0, tolerance: 1.0, higherIsBetter: false)).isPass)
        let better = card(0.5, tolerance: 1.0, higherIsBetter: false)
        #expect(better.gate(against: card(1.0, tolerance: 1.0, higherIsBetter: false)).isPass)
    }

    @Test("A metric absent from the baseline is not a failure")
    func newMetric() {
        let baseline = Scorecard(
            runId: "r", generatedAt: "t", dataset: "v1", split: "dev", sets: [:], sections: [])
        #expect(card(0.5).gate(against: baseline).isPass)
    }
}

@Suite("Scorecard — rendering")
struct RenderTests {
    /// A zero that looks like a result is worse than no result, so unmeasured
    /// metrics must never render as a number.
    @Test("Unmeasured metrics print as text, never as 0")
    func unmeasuredRendersHonestly() {
        let metric = Metric(name: "x", value: nil, unit: .percent, note: "B3")
        #expect(metric.formatted() == "not measured")
        #expect(!metric.isMeasured)
    }

    @Test("Units format distinctly")
    func units() {
        #expect(Metric(name: "a", value: 0.875, unit: .percent).formatted() == "87.5%")
        #expect(Metric(name: "b", value: 1, unit: .boolean).formatted() == "yes")
        #expect(Metric(name: "c", value: 0, unit: .boolean).formatted() == "NO")
        #expect(Metric(name: "d", value: 3, unit: .count).formatted() == "3")
    }
}
