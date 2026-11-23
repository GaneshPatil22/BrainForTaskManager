import BrainCore
import BrainDatasets
import Foundation

/// Explains *why* our top pick differs from the human's, rather than only
/// reporting that it does.
///
/// Top-1 agreement is 27.8%. That is either a tuning problem or a structural
/// one, and the difference matters: more scaffolding on top of a structurally
/// wrong formula is wasted work. This looks at the disagreements and says what
/// characterises them.
///
/// **This is diagnosis, not tuning.** It reads the dev split and changes
/// nothing. Weights stay as they are until the full set is ranked.
public enum Diagnosis {

    public struct Disagreement: Sendable {
        public let scenarioId: String
        public let ourTitle: String
        public let humanTitle: String
        /// Where the human's pick sat in our ranking (1-based).
        public let humanRankInOurs: Int
        public let ourEffortMinutes: Double
        public let humanEffortMinutes: Double
        public let ourDuePressure: Double
        public let humanDuePressure: Double
        public let ourUnblocks: Int
        public let humanUnblocks: Int
        public let ourGoals: Int
        public let humanGoals: Int
        public let ourLeverage: Double
        public let humanLeverage: Double
    }

    public struct Report: Sendable {
        public var scenarios = 0
        public var agreed = 0
        public var disagreements: [Disagreement] = []
        /// How often the human's pick sat at each rank in our list.
        public var humanRankHistogram: [Int: Int] = [:]

        public var disagreementCount: Int { disagreements.count }
    }

    public static func run(
        scenarios: [ScenarioLoader.Loaded], weights: ScoringWeights = .default,
        policy: EdgePolicy = .default
    ) -> Report {
        var report = Report()

        for scenario in scenarios {
            guard let expected = scenario.file.expected?.rankingTop3,
                let humanKey = expected.first,
                let humanId = scenario.idsByKey[humanKey]
            else { continue }

            let outputs = Brain.compute(
                graph: scenario.graph, now: scenario.now, calendar: scenario.calendar,
                weights: weights, policy: policy)
            let ours = outputs.startable
            guard let ourPick = ours.first else { continue }

            report.scenarios += 1
            let humanRank = (ours.firstIndex { $0.item.id == humanId } ?? -1) + 1
            report.humanRankHistogram[humanRank, default: 0] += 1

            if ourPick.item.id == humanId {
                report.agreed += 1
                continue
            }
            guard let humanEntry = ours.first(where: { $0.item.id == humanId }) else { continue }

            report.disagreements.append(
                Disagreement(
                    scenarioId: scenario.file.id,
                    ourTitle: ourPick.item.title,
                    humanTitle: humanEntry.item.title,
                    humanRankInOurs: humanRank,
                    ourEffortMinutes: ourPick.item.effortBucket.minutes,
                    humanEffortMinutes: humanEntry.item.effortBucket.minutes,
                    ourDuePressure: ourPick.breakdown.duePressure,
                    humanDuePressure: humanEntry.breakdown.duePressure,
                    ourUnblocks: ourPick.breakdown.unblockedConfirmed,
                    humanUnblocks: humanEntry.breakdown.unblockedConfirmed,
                    ourGoals: ourPick.breakdown.goalsConfirmed,
                    humanGoals: humanEntry.breakdown.goalsConfirmed,
                    ourLeverage: ourPick.breakdown.leverage,
                    humanLeverage: humanEntry.breakdown.leverage))
        }
        return report
    }

    /// Best achievable top-1 over a grid of weight combinations.
    ///
    /// A single-knob sweep cannot distinguish "mistuned" from "missing a
    /// term", because the knobs interact. If the best point on the whole grid
    /// still falls far short, no amount of tuning will close the gap and the
    /// model is missing something — which is a far more useful thing to learn
    /// than another percentage point.
    public static func grid(scenarios: [ScenarioLoader.Loaded])
        -> (best: ScoringWeights, top1: Double, top3: Double, evaluated: Int)
    {
        var best = ScoringWeights.default
        var bestTop1 = -1.0
        var bestTop3 = 0.0
        var count = 0

        for exponent in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for unblocked in [0.5, 1.0, 2.0, 4.0, 8.0] {
                for due in [0.0, 0.8, 2.0, 5.0] {
                    for goals in [0.0, 1.5, 3.0] {
                        for base in [0.1, 0.5, 1.5] {
                            var weights = ScoringWeights.default
                            weights.effortExponent = exponent
                            weights.unblocked = unblocked
                            weights.due = due
                            weights.goals = goals
                            weights.base = base
                            let result = Metrics.ranking(
                                scenarios: scenarios, weights: weights, policy: .default)
                            count += 1
                            let n = Double(max(result.evaluated, 1))
                            let top1 = Double(result.top1) / n
                            if top1 > bestTop1 {
                                bestTop1 = top1
                                bestTop3 = Double(result.top3) / n
                                best = weights
                            }
                        }
                    }
                }
            }
        }
        return (best, bestTop1, bestTop3, count)
    }

    /// What a single weight change would do to top-1 agreement.
    ///
    /// Reported so we can see whether the gap is reachable by tuning at all.
    /// **Nothing is changed by this** — if one knob fixes everything the
    /// formula is merely mistuned; if nothing helps, it is missing a term, and
    /// that is a far more important thing to learn.
    public static func sweep(
        scenarios: [ScenarioLoader.Loaded], keyPath: WritableKeyPath<ScoringWeights, Double>,
        values: [Double]
    ) -> [(value: Double, top1: Double, top3: Double)] {
        values.map { value in
            var weights = ScoringWeights.default
            weights[keyPath: keyPath] = value
            let result = Metrics.ranking(
                scenarios: scenarios, weights: weights, policy: .default)
            let n = Double(max(result.evaluated, 1))
            return (value, Double(result.top1) / n, Double(result.top3) / n)
        }
    }
}
