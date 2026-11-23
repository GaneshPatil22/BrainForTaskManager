import BrainCore
import BrainDatasets
import Foundation

/// Computes every metric the scorecard reports.
///
/// Nothing here fabricates a number. A metric that cannot be computed from the
/// data present is returned with `value: nil` and a note naming the phase it
/// arrives in (`docs/04-scorecard.md`).
public enum Metrics {

    public struct RankingResult: Sendable {
        public var top1 = 0
        public var top3 = 0
        public var ndcgTotal = 0.0
        public var evaluated = 0
    }

    /// Ranking agreement against human-ranked scenarios.
    ///
    /// "Human's #1 appears in our top 3" replaced "top-1 agreement", which was
    /// self-grading when one person authored both the scenarios and the formula
    /// (`docs/05-targets.md`).
    public static func ranking(
        scenarios: [ScenarioLoader.Loaded], weights: ScoringWeights, policy: EdgePolicy
    ) -> RankingResult {
        var result = RankingResult()

        for scenario in scenarios {
            guard let expected = scenario.file.expected?.rankingTop3, !expected.isEmpty else {
                continue
            }
            // Human picks are short keys ("i3"); map them to the real ids.
            let humanOrder = expected.compactMap { scenario.idsByKey[$0] }
            guard let humanTop = humanOrder.first else { continue }

            let outputs = Brain.compute(
                graph: scenario.graph, now: scenario.now, calendar: scenario.calendar,
                weights: weights, policy: policy)
            // Compare against what the product actually offers as actionable.
            let ours = outputs.startable.map(\.item.id)
            guard !ours.isEmpty else { continue }

            result.evaluated += 1
            if ours.first == humanTop { result.top1 += 1 }
            if ours.prefix(3).contains(humanTop) { result.top3 += 1 }
            result.ndcgTotal += ndcg(ours: ours, humanOrder: humanOrder, k: 5)
        }
        return result
    }

    /// NDCG@k with gains 3 / 2 / 1 for the human's first, second and third pick
    /// and 0 for everything else, against the ideal ordering of those gains.
    public static func ndcg(ours: [ULID], humanOrder: [ULID], k: Int) -> Double {
        var gains: [ULID: Double] = [:]
        for (index, id) in humanOrder.prefix(3).enumerated() {
            gains[id] = Double(3 - index)
        }
        let dcg = ours.prefix(k).enumerated().reduce(0.0) { sum, pair in
            sum + (gains[pair.element] ?? 0) / log2(Double(pair.offset) + 2)
        }
        let idcg = gains.values.sorted(by: >).prefix(k).enumerated().reduce(0.0) { sum, pair in
            sum + pair.element / log2(Double(pair.offset) + 2)
        }
        guard idcg > 0 else { return 0 }
        return dcg / idcg
    }

    // MARK: - T0 coverage

    public struct CoverageResult: Sendable {
        public var categoryResolved = 0
        public var items = 0
    }

    /// What fraction of fields T0 resolves without any model. The number to
    /// drive **up** (`docs/09-tiering.md`).
    public static func t0Coverage(scenarios: [ScenarioLoader.Loaded]) -> CoverageResult {
        var result = CoverageResult()
        for scenario in scenarios {
            for item in scenario.graph.items.values {
                result.items += 1
                if item.category.isKnown { result.categoryResolved += 1 }
            }
        }
        return result
    }

    // MARK: - Dates

    public struct DateResult: Sendable {
        public var parsed = 0
        public var total = 0
        public var unparseable: [String] = []
    }

    /// Parse rate over every distinct `due <text>` string in the corpus.
    ///
    /// Accuracy of the resulting dates is covered by unit tests; what this adds
    /// is **coverage against real phrasing** — which phrasings exist in the data
    /// that the grammar silently drops.
    public static func dates(corpus: [URL], timeZone: TimeZone, now: Date) -> DateResult {
        let parser = DateParser(timeZone: timeZone)
        var seen = Set<String>()
        var result = DateResult()

        for url in corpus {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.components(separatedBy: .newlines) {
                for field in line.components(separatedBy: "|") {
                    let trimmed = field.trimmingCharacters(in: .whitespaces)
                    guard trimmed.lowercased().hasPrefix("due ") else { continue }
                    let text = String(trimmed.dropFirst(4))
                    guard seen.insert(text.lowercased()).inserted else { continue }
                    result.total += 1
                    if parser.parse(text, now: now) != nil {
                        result.parsed += 1
                    } else {
                        result.unparseable.append(text)
                    }
                }
            }
        }
        result.unparseable.sort()
        return result
    }

    // MARK: - Category

    public struct CategoryResult: Sendable {
        public var correct = 0
        public var attempted = 0
        public var total = 0
    }

    public static func category(labels: [String: String]) -> CategoryResult {
        var result = CategoryResult()
        for (title, expected) in labels {
            result.total += 1
            guard let predicted = CategoryClassifier.classify(title).value else { continue }
            result.attempted += 1
            if predicted.rawValue == expected { result.correct += 1 }
        }
        return result
    }

    // MARK: - Robustness

    /// Same graph in, same ranking out — invariant 5 of `docs/01-domain.md`.
    public static func isDeterministic(scenarios: [ScenarioLoader.Loaded]) -> Bool {
        for scenario in scenarios {
            let first = Brain.compute(
                graph: scenario.graph, now: scenario.now, calendar: scenario.calendar)
            for _ in 0..<3 {
                let again = Brain.compute(
                    graph: scenario.graph, now: scenario.now, calendar: scenario.calendar)
                if first.ranked.map(\.item.id) != again.ranked.map(\.item.id) { return false }
                if first.ranked.map(\.breakdown.leverage)
                    != again.ranked.map(\.breakdown.leverage)
                {
                    return false
                }
            }
        }
        return true
    }

    /// The `blocks` subgraph must be acyclic everywhere — invariant 1.
    public static func cycleCount(scenarios: [ScenarioLoader.Loaded]) -> Int {
        scenarios.filter { $0.graph.hasCycle() }.count
    }

    /// Wall-clock cost of ranking one scenario.
    public static func latencies(scenarios: [ScenarioLoader.Loaded]) -> (p50: Double, p95: Double) {
        var samples: [Double] = []
        for scenario in scenarios {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = Brain.compute(
                graph: scenario.graph, now: scenario.now, calendar: scenario.calendar)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        guard !samples.isEmpty else { return (0, 0) }
        samples.sort()
        func percentile(_ p: Double) -> Double {
            samples[min(samples.count - 1, Int(Double(samples.count) * p))]
        }
        return (percentile(0.5), percentile(0.95))
    }
}
